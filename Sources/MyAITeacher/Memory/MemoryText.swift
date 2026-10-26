import Foundation

/// Text normalisation shared by indexing, dedup, concept routing and the durability policy.
enum MemoryText {
    /// Words that carry no retrieval signal in a tutor's memory (nearly every memory says "learner …").
    static let stop: Set<String> = FTS.stopwords.union([
        "learner", "learners", "student", "students", "user", "teacher", "lesson", "lessons", "session", "sessions",
        "learn", "learns", "learned", "learning", "study", "studies", "studying", "studied", "know", "knows", "knew", "known",
        "understand", "understands", "understanding", "concept", "concepts", "topic", "topics", "help", "helps", "question",
        "questions", "problem", "problems", "thing", "things", "really", "good", "well", "get", "gets", "got", "think", "work",
        "way", "new", "them", "his", "her", "him", "she", "he", "their", "been", "being", "were", "had", "did", "not", "but",
        "at", "by", "as", "up", "out", "no", "yes", "ok", "okay", "hi", "hello", "thanks", "thank", "may", "might", "much",
        "many", "each", "other", "such", "only", "own", "same", "too", "again", "ever", "even", "still", "yet", "ask",
        "asked", "asking", "say", "said", "something", "anything", "everything", "where", "while", "these", "those",
        "today", "tomorrow", "yesterday", "time", "times", "first", "last", "next", "level", "basic", "basics",
    ])

    private static let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#")).inverted

    /// Lower-cased raw tokens (keeps non-Latin scripts; keeps "c++", "c#").
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        FastText.words(s, isWordByte: { FastText.isAlnum($0) || $0 == 0x2B || $0 == 0x23 }, ascii: { out.append($0) }) { segment in
            out += segment.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
        }
        return out
    }

    /// Significant stems, in first-seen order, deduplicated.
    static func stems(_ s: String, limit: Int = 64) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for t in tokens(s) {
            guard keep(t) else { continue }
            let st = stem(t)
            if seen.insert(st).inserted { out.append(st); if out.count >= limit { break } }
        }
        return out
    }

    /// `stems` with the raw tokens each came from (FTS5 tokenises raw words with its own stemmer, not ours).
    static func terms(_ s: String, limit: Int = 64) -> [(stem: String, tokens: [String])] {
        var at: [String: Int] = [:], out: [(stem: String, tokens: [String])] = []
        for t in tokens(s) where keep(t) {
            let st = stem(t)
            if let i = at[st] { if !out[i].tokens.contains(t) { out[i].tokens.append(t) } }
            else if out.count < limit { at[st] = out.count; out.append((st, [t])) }
        }
        return out
    }

    static func keep(_ t: String) -> Bool {
        if stop.contains(t) { return false }
        if t.unicodeScalars.contains(where: { $0.value > 0x2FF }) { return t.count >= 2 }   // Arabic, CJK, …
        if t.contains(where: \.isNumber) { return t.count >= 1 && t.count <= 8 }
        return t.count >= 3 || ["c", "r", "go", "ai", "ml", "c#", "c++", "js", "ts", "ui", "ux", "pi", "dna", "rna"].contains(t)
    }

    /// Light, deterministic suffix stripping (applied identically to queries and memories).
    static func stem(_ w: String) -> String {
        guard w.count > 4, w.allSatisfy({ $0.isASCII && $0.isLetter }) else { return w }
        var s = w
        func strip(_ suf: String, min: Int, add: String = "") -> Bool {
            if s.hasSuffix(suf) && s.count - suf.count >= min { s = String(s.dropLast(suf.count)) + add; return true }
            return false
        }
        if !strip("ies", min: 3, add: "y") && !strip("sses", min: 3, add: "ss") {
            if s.hasSuffix("s") && !s.hasSuffix("ss") && !s.hasSuffix("us") && !s.hasSuffix("is") && !s.hasSuffix("ics") { s.removeLast() }
        }
        for (suf, min) in [("ational", 4), ("ations", 4), ("ation", 4), ("ments", 4), ("ment", 4), ("ness", 4), ("ities", 4),
                           ("ity", 4), ("ings", 4), ("ing", 4), ("ives", 4), ("ive", 4), ("ally", 4), ("ly", 4), ("ed", 4),
                           ("ate", 4), ("al", 5), ("er", 5)] {
            if strip(suf, min: min) { break }
        }
        return s
    }

    /// Canonical key for duplicate detection: stems in order.
    static func norm(_ s: String) -> String { stems(s, limit: 200).joined(separator: " ") }

    /// Canonical key for a concept/subject name: lower-cased stems, articles dropped, order kept.
    static func conceptKey(_ s: String) -> String {
        tokens(s).filter { !["the", "a", "an", "of", "and", "in", "to", "for"].contains($0) }.map(stem).joined(separator: " ")
    }

    private static let subjectAliases: [String: String] = [
        "maths": "math", "mathematics": "math", "cs": "computer science", "comp sci": "computer science", "compsci": "computer science",
        "swe": "software engineering", "programming": "programming", "coding": "programming", "bio": "biology", "chem": "chemistry",
        "phys": "physics", "econ": "economics", "arabic language": "arabic", "english language": "english", "calc": "calculus",
        "stats": "statistics", "ml": "machine learning", "ai": "artificial intelligence",
    ]

    /// Lower-cased, trimmed, with common aliases folded ("Maths" → "math").
    static func subject(_ s: String?) -> String? {
        guard var t = s?.lowercased().trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return nil }
        t = t.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return subjectAliases[t] ?? t
    }

    static func clip(_ s: String, _ n: Int) -> String { s.count <= n ? s : String(s.prefix(n - 1)) + "…" }

    private static let negation = try! NSRegularExpression(pattern: #"\b(not|no|never|none|cannot|without|nor)\b|n['’]t\b"#, options: [.caseInsensitive])
    private static func negations(_ s: String) -> Int { negation.numberOfMatches(in: s, range: NSRange(s.startIndex..., in: s)) }
    private static func numbers(_ s: String) -> Set<String> { Set(tokens(s).filter { $0.contains(where: \.isNumber) }) }

    /// `new` restates `old` with a changed number, negation, or a short/stop-word difference: an update, not a duplicate.
    static func isUpdate(_ new: String, of old: String) -> Bool {
        guard new != old else { return false }
        if numbers(new) != numbers(old) { return true }
        if negations(new) % 2 != negations(old) % 2 { return true }
        return Set(stems(new)) == Set(stems(old)) && Set(tokens(new)) != Set(tokens(old))
    }
}

/// Decides whether a candidate memory is durable and non-derivable. Explicit requests ("remember that…") bypass it.
enum MemoryPolicy {
    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.caseInsensitive]) }
    private static let habitual = re(#"\b(often|always|usually|frequently|repeatedly|tends? to|keeps?|regularly|consistently|every time|prefers?|likes?|struggles?|confuses?|mixes up)\b"#)
    private static let request = re(#"\b(asked|asks|requested|wanted to know|wants to know|wondered|inquired|queried|was curious|needed help with|asked for help)\b"#)
    private static let oneOffResult = re(#"\b(solved|computed|calculated|answered|scored|got \d|attempted|submitted)\b|\b(worked (on|through)|completed|finished) (the|this|a|an|that|its|their|one|two|\d+) (quiz|problem|exercise|question|task|worksheet|example|practice|flashcards?|review)s?\b"#)
    private static let sessionBound = re(#"\b(today|tonight|this (lesson|session|conversation|chat|turn)|just now|right now|earlier in|in the last message|in this quiz)\b"#)
    private static let mechanics = re(#"\b(the app (crashed|froze|closed|showed|opened|failed)|tool calls?|(memory|quiz|search) tool|interrupted|cancell?ed|skipped (the|a) (question|quiz)|api (key|error)|error message|the assistant|the teacher (used|called|ran|showed)|system prompt|flashcard screen)\b"#)

    /// Returns a reason when the content should NOT be stored.
    static func rejection(_ content: String, kind: MemoryKind, explicit: Bool) -> String? {
        let c = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if c.count < 8 || MemoryText.stems(c).isEmpty { return "too short or empty" }
        if explicit { return nil }
        let r = NSRange(c.startIndex..., in: c)
        func m(_ x: NSRegularExpression) -> Bool { x.firstMatch(in: c, range: r) != nil }
        if m(mechanics) { return "about the app or tools, not the learner" }
        if kind == .episode { return nil }
        let habit = m(habitual)
        if m(request) && !habit { return "a one-off request (derivable from the lesson transcript)" }
        if m(oneOffResult) && !habit && kind != .goal { return "a one-off result (quiz results and mastery are tracked separately)" }
        if m(sessionBound) && !habit { return "only true for this lesson" }
        return nil
    }
}
