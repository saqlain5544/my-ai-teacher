import Foundation

/// The parts of a long text that best answer a query, in reading order. Lexical relevance (BM25 over paragraph-sized
/// passages, each scored with its section heading) lets a page's answer cost a few thousand characters instead of the
/// whole page; offsets are character positions in the text, so a caller can say where to read on from.
enum Passages {
    struct Passage: Equatable {
        var heading: String   // "Section › Subsection", or "" before the first heading
        var text: String
        var offset: Int       // character index of the passage in the source text
    }

    /// Passages longer than this are cut at sentence ends; shorter ones stay whole.
    static let maxPassage = 1_100

    /// Markdown split into passages: paragraphs, lists and tables (blank-line separated, a code fence kept whole), each
    /// with the heading path above it. A heading starts a new passage and is not one itself.
    static func split(_ text: String) -> [Passage] {
        var out: [Passage] = []
        var path: [String] = []
        var buf: [Substring] = [], bufStart = 0, offset = 0, inFence = false
        func flush() {
            let t = buf.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            buf = []
            guard !t.isEmpty else { return }
            let heading = path.filter { !$0.isEmpty }.joined(separator: " › ")
            if t.count <= maxPassage { out.append(Passage(heading: heading, text: t, offset: bufStart)); return }
            // A long table or list: pieces of whole rows, a table's header repeated on each (an infobox's "Launch date" row
            // is found with what it means).
            let lines = t.split(separator: "\n", omittingEmptySubsequences: false)
            if lines.count > 3 {
                let header = lines[0].hasPrefix("|") && lines[1].hasPrefix("| ---") && lines[0].count < 200 ? lines[0] + "\n" + lines[1] + "\n" : ""
                var piece = "", pieceStart = bufStart, pos = bufStart
                for (k, line) in lines.enumerated() {
                    if !header.isEmpty && k < 2 { pos += line.count + 1; continue }
                    if !piece.isEmpty && piece.count + line.count > maxPassage {
                        out.append(Passage(heading: heading, text: header + piece.trimmingCharacters(in: .newlines), offset: pieceStart))
                        piece = ""; pieceStart = pos
                    }
                    piece += line + "\n"; pos += line.count + 1
                }
                if !piece.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { out.append(Passage(heading: heading, text: header + piece.trimmingCharacters(in: .newlines), offset: pieceStart)) }
                return
            }
            // A long paragraph: pieces of about maxPassage characters, cut after a sentence.
            var piece = "", pieceStart = bufStart, pos = bufStart
            for s in sentences(t) {
                if !piece.isEmpty && piece.count + s.count > maxPassage {
                    out.append(Passage(heading: heading, text: piece.trimmingCharacters(in: .whitespaces), offset: pieceStart))
                    piece = ""; pieceStart = pos
                }
                piece += s; pos += s.count
            }
            if !piece.trimmingCharacters(in: .whitespaces).isEmpty { out.append(Passage(heading: heading, text: piece.trimmingCharacters(in: .whitespaces), offset: pieceStart)) }
        }
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.drop { $0 == " " }
            if trimmed.hasPrefix("```") { inFence.toggle() }
            if !inFence, trimmed.hasPrefix("#"), let level = headingLevel(trimmed) {
                flush()
                let title = trimmed.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces)
                if path.count >= level { path.removeLast(path.count - level + 1) }
                while path.count < level - 1 { path.append("") }
                path.append(title)
            } else if !inFence && trimmed.isEmpty {
                flush()
            } else {
                if buf.isEmpty { bufStart = offset }
                buf.append(line)
            }
            offset += line.count + 1
        }
        flush()
        return out
    }

    private static func headingLevel(_ line: Substring) -> Int? {
        let hashes = line.prefix { $0 == "#" }.count
        guard (1...6).contains(hashes), line.dropFirst(hashes).first == " " else { return nil }
        return hashes
    }

    /// Sentences with their trailing space, so they join back to the original text.
    private static func sentences(_ t: String) -> [String] {
        var out: [String] = [], cur = ""
        let chars = Array(t)
        for (i, c) in chars.enumerated() {
            cur.append(c)
            let end = (c == "." || c == "?" || c == "!" || c == "\n" || c == "。") && (i + 1 == chars.count || chars[i + 1] == " " || chars[i + 1] == "\n" || c == "。")
            if end && cur.count > 40 { out.append(cur); cur = "" }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    // MARK: Terms

    private static let stopwords: Set<String> = ["a", "an", "the", "and", "or", "of", "to", "in", "on", "for", "with", "is", "are", "was",
        "were", "be", "by", "as", "at", "it", "its", "this", "that", "from", "how", "what", "why", "when", "which", "who", "do", "does",
        "can", "vs", "versus", "into", "about", "i", "you", "my", "me", "we", "your", "their", "there", "than", "then", "not", "no"]

    /// Search terms: lower-cased words without stopwords, lightly stemmed so "reactions" meets "reaction"; scripts written
    /// without spaces (Chinese, Japanese) as character pairs.
    static func terms(_ s: String) -> [String] {
        var out: [String] = []
        for raw in s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let w = String(raw)
            if w.unicodeScalars.contains(where: isCJK) {
                let cs = Array(w)
                if cs.count == 1 { out.append(w) } else { for i in 0..<(cs.count - 1) { out.append(String(cs[i...i + 1])) } }
                continue
            }
            guard !stopwords.contains(w), w.count > 1 || w.first?.isNumber == true else { continue }
            out.append(stem(w))
        }
        return out
    }

    static func stem(_ w: String) -> String {
        guard w.count > 4, w.allSatisfy({ $0.isASCII }) else { return w }
        for suffix in ["ing", "ies", "es", "ed", "s"] where w.hasSuffix(suffix) {
            if suffix == "s" && (w.hasSuffix("ss") || w.hasSuffix("us") || w.hasSuffix("is")) { return w }
            let base = String(w.dropLast(suffix.count))
            return suffix == "ies" ? base + "y" : base
        }
        return w
    }

    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        (0x3040...0x30FF).contains(u.value) || (0x3400...0x4DBF).contains(u.value) || (0x4E00...0x9FFF).contains(u.value) || (0xAC00...0xD7AF).contains(u.value)
    }

    // MARK: Ranking

    /// Each passage's relevance to the query (BM25 over its text and heading, scaled by the share of query terms it
    /// contains, so a passage that covers the question beats one that repeats a single word). Zero for a passage whose own
    /// text has no query term or hardly any prose ("Read the story", a lone image under a matching heading).
    static func scores(_ passages: [Passage], query: String) -> [Double] {
        let q = Array(Set(terms(query)))
        guard !q.isEmpty, !passages.isEmpty else { return passages.map { _ in 0 } }
        var eligible: [Bool] = []
        let docs = passages.map { p -> [String: Int] in
            let prose = p.text.replacingOccurrences(of: #"!?\[[^\]]*\]\([^)]*\)|\[image:[^\]]*\]"#, with: " ", options: .regularExpression)
            var tf: [String: Int] = [:]
            for t in terms(prose) { tf[t, default: 0] += 1 }
            eligible.append(prose.count >= 60 && q.contains { tf[$0] != nil })
            for t in terms(p.heading) { tf[t, default: 0] += 1 }
            return tf
        }
        let lengths = docs.map { Double($0.values.reduce(0, +)) }
        let avg = max(1, lengths.reduce(0, +) / Double(docs.count))
        let n = Double(docs.count)
        var idf: [String: Double] = [:]
        for t in q {
            let df = Double(docs.filter { $0[t] != nil }.count)
            idf[t] = log(1 + (n - df + 0.5) / (df + 0.5))
        }
        let k1 = 1.2, b = 0.75
        return docs.enumerated().map { i, tf in
            guard eligible[i] else { return 0 }
            var s = 0.0, hit = 0
            for t in q {
                guard let f = tf[t].map(Double.init) else { continue }
                hit += 1
                s += (idf[t] ?? 0) * f * (k1 + 1) / (f + k1 * (1 - b + b * lengths[i] / avg))
            }
            // A slight preference for the top of the page, where pages state what they are about.
            return s * (0.4 + 0.6 * Double(hit) / Double(q.count)) * (1 + 0.3 / (1 + Double(i) / 4))
        }
    }

    /// The best passages for `query` that fit in `budget` characters, in reading order. Empty when no passage contains a
    /// query term.
    static func best(_ text: String, query: String, budget: Int) -> [Passage] {
        let ps = split(text)
        let sc = scores(ps, query: query)
        guard let top = sc.max(), top > 0 else { return [] }
        var chosen: [Int] = [], used = 0
        // Weak matches (well under the best) only pad the answer: they are left out.
        for i in sc.indices.sorted(by: { sc[$0] > sc[$1] }) where sc[i] >= top * 0.35 {
            let cost = ps[i].text.count + ps[i].heading.count + 40
            if used + cost > budget { if chosen.isEmpty { chosen.append(i); used += cost }; continue }
            chosen.append(i); used += cost
        }
        return chosen.sorted().map { ps[$0] }
    }

    /// Chosen passages under their headings, each with the `start_index` that reads on from it. Passages that follow each
    /// other in one section share a heading line.
    static func render(_ passages: [Passage], maxPassage: Int? = nil) -> String {
        var out = "", lastHeading: String?
        for p in passages {
            if p.heading != lastHeading || out.isEmpty {
                out += (out.isEmpty ? "" : "\n") + "§ " + (p.heading.isEmpty ? "(top of page)" : p.heading) + " · start_index=\(p.offset)\n"
                lastHeading = p.heading
            }
            var t = p.text
            if let m = maxPassage, t.count > m { t = String(t.prefix(m)) + "…" }
            out += t + "\n\n"
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
