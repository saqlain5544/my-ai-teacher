import Foundation
import NaturalLanguage

// MARK: - Transliteration and analysis (on device, ICU and NaturalLanguage)

enum Transliteration {
    /// Target scripts the `language` tool offers (ICU transforms: no dictionaries, no network).
    static let targets: [String: StringTransform] = [
        "latin": .toLatin, "hiragana": .latinToHiragana, "katakana": .latinToKatakana, "hangul": .latinToHangul, "arabic": .latinToArabic,
        "cyrillic": .latinToCyrillic, "greek": .latinToGreek, "hebrew": .latinToHebrew, "thai": .latinToThai, "pinyin": .mandarinToLatin,
        "ascii": StringTransform("Any-Latin; Latin-ASCII"), "halfwidth": .fullwidthToHalfwidth,
    ]
    static func apply(_ text: String, to target: String) -> String? {
        let key = target.lowercased()
        if key == "hiragana" || key == "katakana" {
            // Kana ↔ kana, and romaji through the keyboard's own table (ICU reads "nn" as a doubled consonant).
            var t = text.applyingTransform(.hiraganaToKatakana, reverse: key == "hiragana") ?? text
            if t.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) {
                t = ScriptComposer.romaji(t.hasSuffix("n") || t.hasSuffix("N") ? t + "'" : t, katakana: key == "katakana")
            }
            return t
        }
        guard let t = targets[key] else { return nil }
        return text.applyingTransform(t, reverse: false)
    }
}

enum TextAnalysis {
    struct Token: Sendable { var text: String; var lemma: String?; var pos: String?; var reading: String? }

    /// Words with lemma and part of speech where the on-device tagger knows the language, and a Latin reading for
    /// other scripts. Japanese and Chinese are segmented into words (no spaces in the source).
    static func tokens(_ text: String, language: String?) -> [Token] {
        let code = language.flatMap(Languages.code) ?? (text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) } ? "ja" : nil)
        if code == "ja" { return japaneseTokens(text) }
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .lemma])
        tagger.string = text
        if let l = language.flatMap(Languages.code) { tagger.setLanguage(NLLanguage(l), range: text.startIndex..<text.endIndex) }
        var out: [Token] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lexicalClass, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
            let w = String(text[range])
            let lemma = tagger.tag(at: range.lowerBound, unit: .word, scheme: .lemma).0?.rawValue
            let latin = ScriptRuns.runs(w).contains { $0.script != .latin && $0.script != .neutral } ? w.applyingTransform(.toLatin, reverse: false) : nil
            let pos = tag?.rawValue.lowercased()
            out.append(Token(text: w, lemma: lemma == w ? nil : lemma, pos: pos == "otherword" ? nil : pos, reading: latin == w ? nil : latin))
            return true
        }
        return out
    }

    /// Japanese words with Japanese readings. The generic path read kanji as Mandarin (担当 [dān dāng]) and tagged every
    /// word "otherword"; the system's Japanese tokenizer segments the sentence and gives each word's reading in romaji,
    /// shown with its hiragana (担当 [たんとう tantou]).
    static func japaneseTokens(_ text: String) -> [Token] {
        let ns = text as NSString
        guard let tok = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: ns.length), kCFStringTokenizerUnitWordBoundary,
                                                Locale(identifier: "ja") as CFLocale) else { return [] }
        var out: [Token] = []
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let w = ns.substring(with: NSRange(location: r.location, length: r.length))
            guard w.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }   // punctuation, spaces
            let latin = (CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String)?.lowercased()
            let hasKanji = w.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
            let kana = hasKanji ? latin.flatMap { $0.applyingTransform(.latinToHiragana, reverse: false) } : nil
            // は, へ and を standing alone are the particles, read wa, e and o (the tokenizer spells them ha, he, wo).
            if let particle = ["は": "wa", "へ": "e", "を": "o"][w] { out.append(Token(text: w, lemma: nil, pos: "particle", reading: particle)); continue }
            let reading = [kana, latin == w.lowercased() ? nil : latin].compactMap { $0 }.joined(separator: " ")
            out.append(Token(text: w, lemma: nil, pos: nil, reading: reading.isEmpty ? nil : reading))
        }
        return out
    }
    /// The whole text's reading in hiragana (words with kanji by the tokenizer's reading, kana as written, punctuation
    /// and spaces dropped): 私は食べる → わたしはたべる. Dictation and speech are compared on this.
    static func japaneseKana(_ text: String) -> String {
        let ns = text as NSString
        guard let tok = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: ns.length), kCFStringTokenizerUnitWordBoundary,
                                                Locale(identifier: "ja") as CFLocale) else { return text }
        var out = "", lastWord = "", lastKana = 0
        while CFStringTokenizerAdvanceToNextToken(tok) != [] {
            let r = CFStringTokenizerGetCurrentTokenRange(tok)
            let w = ns.substring(with: NSRange(location: r.location, length: r.length))
            guard w.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
            let hasKanji = w.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
            if w == "時", let r = LanguageWork.hours[lastWord] { out.removeLast(lastKana); out += r; lastWord = ""; continue }   // 七時 しちじ
            let before = out.count
            defer { lastWord = w; lastKana = out.count - before }
            if let common = commonReadings[w] { out += common; continue }
            if hasKanji, let latin = CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String,
               let kana = latin.lowercased().applyingTransform(.latinToHiragana, reverse: false), !kana.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) {
                out += kana
            } else {
                out += ScriptComposer.toHiragana(w).filter { $0.isLetter || $0.isNumber || $0 == "ー" }
            }
        }
        return out
    }
    /// Everyday readings where the system's tokenizer picks the formal or rarer one (私 → わたくし): a learner writing
    /// わたし is right.
    static let commonReadings: [String: String] = [
        "私": "わたし", "今日": "きょう", "明日": "あした", "昨日": "きのう", "何": "なに", "一人": "ひとり", "二人": "ふたり", "大人": "おとな",
        "今年": "ことし", "今朝": "けさ", "上手": "じょうず", "下手": "へた", "眼鏡": "めがね", "部屋": "へや", "時計": "とけい", "果物": "くだもの",
    ]
    static func sentences(_ text: String) -> [String] {
        let tok = NLTokenizer(unit: .sentence); tok.string = text
        return tok.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
    static func languages(_ text: String, max: Int = 3) -> [(String, Double)] {
        let rec = NLLanguageRecognizer(); rec.processString(text)
        return rec.languageHypotheses(withMaximum: max).sorted { $0.value > $1.value }.map { ($0.key.rawValue, $0.value) }
    }
}

// MARK: - The `language` tool

/// Language facts the mentor can get right without guessing: the learner's language profile, transliteration between
/// scripts, word-level analysis, and dictionary entries from Wiktionary.
struct LanguageTool: Tool {
    let name = "language"
    let description = """
    Language-learning utilities. action="profile": set or read which language the learner is learning (`target`, e.g. \
    "ja"), their own language (`native`), and a CEFR `level` (A1–C2) — the app shows the right on-screen keyboard and \
    tells you the state on every request. action="transliterate": convert `text` to a script (`to`: latin, hiragana, \
    katakana, hangul, arabic, cyrillic, greek, hebrew, thai, pinyin, ascii) — romanised text only: write foreign names by \
    sound yourself. action="analyze": segment `text` into words with their readings (Japanese in kana and romaji, \
    Chinese in pinyin, other scripts in Latin), lemma and part of speech where the system knows them, plus sentence \
    count and detected languages. action="dictionary": Wiktionary definitions of `word` (with `lang` to pick the language \
    section). Use these to check readings and forms before teaching them; the learner never sees the calls.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["profile", "transliterate", "analyze", "dictionary"]),
            "target": Schema.string("profile: the language being learned (name or ISO code)."),
            "native": Schema.string("profile: the learner's own language."),
            "level": Schema.string("profile: CEFR level estimate (A1, A2, B1, B2, C1, C2), optionally with a note (\"A2, strong reading\")."),
            "notes": Schema.string("profile: goals, exam, dialect, what they struggle with."),
            "text": Schema.string("transliterate/analyze: the text."),
            "to": Schema.string("transliterate: target script.", enum: Array(Transliteration.targets.keys).sorted()),
            "lang": Schema.string("analyze/dictionary: the text's language (ISO code or name)."),
            "word": Schema.string("dictionary: the word or phrase to look up."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String {
        let a = input["action"]?.string ?? ""
        return a + " " + (input["word"]?.string ?? input["target"]?.string ?? input["text"]?.string?.prefix(40).description ?? "")
    }
    func timeout(_ input: JSON) -> Double? { input["action"]?.string == "dictionary" ? 30 : 20 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let study = ctx.services.study
        switch input["action"]?.string ?? "profile" {
        case "profile":
            var lines: [String] = []
            if let t = input["target"]?.string, !t.isEmpty {
                guard let code = Languages.code(t) else { return .error("Unknown language “\(t)”: give its English name or ISO 639-1 code.") }
                guard let p = study.setLanguageProfile(code: code, role: "target", level: input["level"]?.string, notes: input["notes"]?.string) else { return .error("Couldn't save the profile.") }
                lines.append("Target language: \(Languages.englishName(p.code)) (\(p.code))\(p.level.map { ", level \($0)" } ?? "")\(p.notes.map { " — \($0)" } ?? "").")
                let kb = KeyboardLayouts.layout(for: code)
                lines.append(kb.map { "The learner has an on-screen \($0.english) keyboard\($0.modes.contains("romaji") ? " (kana, or romaji typed as kana)" : $0.compose == "hangul" ? " (jamo compose into syllables)" : $0.compose == "pinyin" ? " (pinyin with a tone-mark key; 汉字 through the Mac's own input source)" : "") for quiz answers." } ?? "The learner types \(Languages.englishName(code)) with the ordinary keyboard.")
            } else if let l = input["level"]?.string, let p = study.languageProfiles().first(where: { $0.role == "target" }) {
                _ = study.setLanguageProfile(code: p.code, level: l, notes: input["notes"]?.string)
                lines.append("\(Languages.englishName(p.code)): level \(l).")
            }
            if let n = input["native"]?.string, !n.isEmpty {
                guard let code = Languages.code(n) else { return .error("Unknown language “\(n)”.") }
                _ = study.setLanguageProfile(code: code, role: "native")
                lines.append("Learner's language: \(Languages.englishName(code)) (\(code)).")
            }
            if !lines.isEmpty { EventBus.publish(.studyDataChanged) }
            let all = study.languageProfiles()
            if lines.isEmpty {
                guard !all.isEmpty else { return ToolOutput(text: "No language profile yet. Set one with target (and native, level) once you know what they're learning.") }
            }
            lines.append("Profiles: " + all.map { p in
                let st = p.role == "target" ? study.vocabStats(lang: p.code) : nil
                return "\(Languages.englishName(p.code)) (\(p.code), \(p.role)\(p.level.map { ", \($0)" } ?? ""))" + (st.map { " — \($0.total) words saved, \($0.due) due, \($0.known) known" } ?? "")
            }.joined(separator: "; ") + ".")
            return ToolOutput(text: lines.joined(separator: "\n"), meta: ["profiles": .array(all.map { ["code": .string($0.code), "role": .string($0.role), "level": $0.level.map { .string($0) } ?? .null] })])
        case "transliterate":
            let text = try input.req("text")
            let to = input["to"]?.string?.lowercased() ?? "latin"
            guard let out = Transliteration.apply(text, to: to) else { return .error("Unknown target script “\(to)”. One of: \(Transliteration.targets.keys.sorted().joined(separator: ", ")).") }
            // Letters left over mean the text wasn't romanisation of that script (an English name to katakana gave
            // "サm Cアrテr"): say so instead of handing back a half-converted word.
            if !["latin", "ascii", "pinyin", "halfwidth"].contains(to), out.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) {
                return .error("“\(text)” isn't a romanisation of \(to), so it can't be converted letter by letter (it would give “\(out)”). Write foreign words and names by sound yourself (Sam Carter → サム・カーター in katakana), then check the reading with action=analyze.")
            }
            return ToolOutput(text: out, meta: ["text": .string(out)])
        case "analyze":
            let text = try input.req("text")
            let lang = input["lang"]?.string
            let toks = TextAnalysis.tokens(text, language: lang)
            var s = "Languages: " + TextAnalysis.languages(text).map { "\($0.0) \(Int($0.1 * 100))%" }.joined(separator: ", ")
            s += "\nSentences: \(TextAnalysis.sentences(text).count); words: \(toks.count)\n"
            s += toks.map { t in
                var parts = [t.text]
                if let r = t.reading { parts.append("[\(r)]") }
                if let p = t.pos { parts.append(p) }
                if let l = t.lemma { parts.append("← \(l)") }
                return parts.joined(separator: " ")
            }.joined(separator: "\n")
            return ToolOutput(text: s, meta: ["tokens": .array(toks.map { ["text": .string($0.text), "lemma": $0.lemma.map { .string($0) } ?? .null, "pos": $0.pos.map { .string($0) } ?? .null, "reading": $0.reading.map { .string($0) } ?? .null] })])
        case "dictionary":
            let word = try input.req("word")
            return await Self.dictionary(word, lang: input["lang"]?.string)
        default:
            return .error("Unknown action. Use profile, transliterate, analyze or dictionary.")
        }
    }

    /// Wiktionary's REST definitions (keyless): `{lang: [{partOfSpeech, definitions: [{definition, examples}]}]}`.
    static func dictionary(_ word: String, lang: String?) async -> ToolOutput {
        let code = lang.flatMap(Languages.code)
        let candidates = [word, word.lowercased(), word.prefix(1).uppercased() + word.dropFirst()].reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        for title in candidates {
            guard let enc = title.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed), let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(enc)?redirect=true") else { continue }
            var req = URLRequest(url: url, timeoutInterval: 20)
            req.setValue("MyAITeacher/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (language mentor; learning app)", forHTTPHeaderField: "User-Agent")
            req.setValue("application/json", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse else { continue }
            if http.statusCode == 404 { continue }
            guard http.statusCode == 200, let j = JSON.parse(data), let sections = j.object else { return .error("Wiktionary answered \(http.statusCode).") }
            let keys = code.map { c in sections.keys.filter { $0 == c || $0.hasPrefix(c + "-") } } ?? Array(sections.keys)
            guard !keys.isEmpty else { return ToolOutput(text: "Wiktionary has “\(title)” but no \(code.map(Languages.englishName) ?? "") section (sections: \(sections.keys.sorted().joined(separator: ", "))).") }
            var out = "Wiktionary: \(title)\n"
            for k in keys.sorted() {
                for entry in sections[k]?.array ?? [] {
                    out += "\n## \(entry["language"]?.string ?? k) · \(entry["partOfSpeech"]?.string ?? "")\n"
                    for (i, d) in (entry["definitions"]?.array ?? []).prefix(8).enumerated() {
                        let def = Self.strip(d["definition"]?.string ?? "")
                        guard !def.isEmpty else { continue }
                        out += "\(i + 1). \(def)\n"
                        for ex in (d["examples"]?.array ?? []).prefix(2).compactMap(\.string) { out += "   e.g. \(Self.strip(ex))\n" }
                    }
                }
            }
            out += "\nSource: https://en.wiktionary.org/wiki/\(enc)"
            return ToolOutput(text: String(out.prefix(12_000)))
        }
        return .error("Wiktionary has no entry for “\(word)”. Try the dictionary form (infinitive, singular), or `web_search`.")
    }
    static func strip(_ html: String) -> String {
        html.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - The `vocab` tool

/// The learner's own vocabulary: words saved with reading, meaning and an example, reviewed as flashcards (FSRS) in the
/// Flashcards screen, and brought back by the mentor when due.
struct VocabTool: Tool {
    let name = "vocab"
    let description = """
    The learner's vocabulary for the language they are learning. action="add": save words (`words`: term, reading, \
    meaning, pos, example, example_meaning, notes, tags) — each becomes a flashcard in the language's deck; adding a word \
    already saved updates it (no need to remove it first); the learner \
    also saves words themselves from ```vocab cards. action="due": words due for review now (start lessons with these). \
    action="list" (recent, or by `tag`), "search" (`query`), "stats" (counts: new, learning, known, due), "remove" (`term`). \
    Save the words you teach, with an example sentence from the lesson; don't save what they already knew.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["add", "due", "list", "search", "stats", "remove"]),
            "lang": Schema.string("Language (ISO code or name); default: the learner's target language."),
            "words": Schema.array(Schema.object([
                "term": Schema.string("The word or phrase, in its script."), "reading": Schema.string("Pronunciation: kana, pinyin, romanisation (non-Latin scripts)."),
                "meaning": Schema.string("Meaning in the learner's language."), "pos": Schema.string("Part of speech."),
                "example": Schema.string("An example sentence in the target language."), "example_meaning": Schema.string("Its translation."),
                "notes": Schema.string("Usage notes, a mnemonic."), "tags": Schema.array(Schema.string("Tag"), "Topic tags."),
                "register": Schema.string("Where it fits: formal, polite, casual, written, slang…"),
                "collocations": Schema.array(Schema.string("Collocation"), "Words it goes with (電話をかける, make a decision)."),
                "family": Schema.array(Schema.string("Related word"), "Its word family: same root or kanji (書く, 書類, 読書)."),
            ], required: ["term", "meaning"]), "add: the words."),
            "tag": Schema.string("list: only words with this tag."),
            "query": Schema.string("search: text in the term, reading or meaning."),
            "term": Schema.string("remove: the term."),
            "limit": Schema.integer("list/due/search: at most this many (default 40)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "") + (input["words"]?.array.map { " · \($0.count) words" } ?? "") + (input["query"]?.string.map { " \($0)" } ?? "") }

    /// The saved reading against the system's for a Japanese word with kanji, or a Chinese word's pinyin; nil when they
    /// agree (or there is nothing to compare). Some words have more than one reading, so it is a question, not an error.
    static func readingMismatch(_ v: VocabItem, lang: String) -> String? {
        guard let reading = v.reading, !reading.isEmpty else { return nil }
        let isKana: (Character) -> Bool = { c in c.unicodeScalars.allSatisfy { (0x3041...0x30FC).contains($0.value) } }
        if lang == "ja", v.term.unicodeScalars.contains(where: { (0x4E00...0x9FFF).contains($0.value) }) {
            guard let given = reading.split(whereSeparator: { " /,(（・".contains($0) }).map(String.init).first(where: { !$0.isEmpty && $0.allSatisfy(isKana) }) else { return nil }
            let expected = TextAnalysis.japaneseKana(v.term)
            guard !expected.isEmpty, ScriptComposer.toHiragana(given) != expected else { return nil }
            return "“\(v.term)”: the reading “\(given)” isn't the dictionary's (“\(expected)”) — check it; if the word has two readings, say which in notes"
        }
        if lang == "zh", let expected = v.term.applyingTransform(.mandarinToLatin, reverse: false) {
            // Letters and the sequence of tones, however they are written (marks or numbers, spaced or not).
            func parts(_ p: String) -> (String, [Int]) {
                let spaced = p.lowercased().replacingOccurrences(of: "([āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜ])", with: "$1 ", options: .regularExpression)
                let n = Questions.pinyinNumbers(spaced)
                return (n.filter(\.isLetter), n.compactMap { $0.wholeNumberValue }.filter { (1...4).contains($0) })
            }
            let (la, ta) = parts(reading), (lb, tb) = parts(expected)
            guard !la.isEmpty, la != lb || (!ta.isEmpty && ta != tb) else { return nil }
            return "“\(v.term)”: the pinyin “\(reading)” isn't the dictionary's (“\(expected)”) — check it (tone sandhi aside)"
        }
        return nil
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let study = ctx.services.study
        let lang = input["lang"]?.string.flatMap(Languages.code) ?? study.languageProfiles().first { $0.role == "target" }?.code ?? study.vocabLanguages().first
        let limit = min(200, max(1, input["limit"]?.int ?? 40))
        let line = { (v: VocabItem) -> String in
            "• \(v.term)\(v.reading.map { " [\($0)]" } ?? "") — \(v.meaning)\(v.pos.map { " (\($0))" } ?? "")\(v.example.map { " · e.g. \($0)" } ?? "") · \(v.status)\(v.due.map { $0 <= Date() ? ", due" : "" } ?? "")"
        }
        switch input["action"]?.string ?? "list" {
        case "add":
            guard let lang else { return .error("Which language? Give `lang`, or set the target language with `language` action=profile first.") }
            var added: [VocabItem] = []
            for w in input["words"]?.array ?? [] {
                guard let term = w["term"]?.string ?? w["word"]?.string, let meaning = w["meaning"]?.string ?? w["translation"]?.string else { continue }
                // Register, collocations and the word family go on the card with the notes (the back of the flashcard).
                var notes = [w["notes"]?.string].compactMap { $0 }.filter { !$0.isEmpty }
                if let r = w["register"]?.string, !r.isEmpty { notes.append("Register: \(r)") }
                if let c = w["collocations"]?.array?.compactMap(\.string), !c.isEmpty { notes.append("Goes with: " + c.joined(separator: ", ")) }
                if let f = w["family"]?.array?.compactMap(\.string), !f.isEmpty { notes.append("Family: " + f.joined(separator: ", ")) }
                if let v = study.addVocab(lang: lang, term: term, reading: w["reading"]?.string, meaning: meaning, pos: w["pos"]?.string, example: w["example"]?.string,
                                          exampleMeaning: w["example_meaning"]?.string, notes: notes.isEmpty ? nil : notes.joined(separator: " · "), tags: w["tags"]?.array?.compactMap(\.string) ?? [], source: ctx.conversationID) { added.append(v) }
            }
            guard !added.isEmpty else { return .error("No words saved: each needs `term` and `meaning`.") }
            EventBus.publish(.studyDataChanged)
            let st = study.vocabStats(lang: lang)
            // A slip into another script (a Korean word in a Japanese example) is easy to miss in a long list: name it.
            var slips = added.compactMap { v -> String? in
                for (field, text) in [("term", v.term), ("example", v.example ?? "")] {
                    if let s = ScriptCheck.slip(text, lang: lang) { return "“\(v.term)”: its \(field) \(s)" }
                }
                return nil
            }
            // A reading that isn't the dictionary's (出社 saved as しゅくしゃ): readings are what the learner memorises.
            slips += added.compactMap { v in VocabTool.readingMismatch(v, lang: lang) }
            let check = slips.isEmpty ? "" : "\nCheck and re-add (adding again updates the word):\n" + slips.map { "- " + $0 }.joined(separator: "\n")
            return ToolOutput(text: "Saved \(added.count) word(s) to \(Languages.englishName(lang)) (\(st.total) in all, \(st.due) due for review):\n" + added.map(line).joined(separator: "\n") + check,
                              meta: ["count": .number(Double(added.count)), "lang": .string(lang)])
        case "due":
            let due = study.dueVocab(lang: lang, limit: limit)
            if due.isEmpty { return ToolOutput(text: "No \(lang.map(Languages.englishName) ?? "") words are due right now.") }
            // Leeches (forgotten again and again) need a new way in, not another repetition.
            let leeches = due.filter { $0.lapses >= 3 }.map(\.term)
            return ToolOutput(text: "\(due.count) word(s) due for review — bring them back in use (a sentence to complete, a quick translation, a dictation), not as a list:\n" + due.map(line).joined(separator: "\n")
                              + (leeches.isEmpty ? "" : "\nForgotten 3+ times: \(leeches.joined(separator: ", ")) — teach these differently (a contrast with the word it's confused with, a mnemonic, the kanji's parts, a vivid sentence)."))
        case "list":
            let items = study.vocab(lang: lang, tag: input["tag"]?.string, limit: limit)
            if items.isEmpty { return ToolOutput(text: "No words saved yet\(lang.map { " for \(Languages.englishName($0))" } ?? "").") }
            return ToolOutput(text: items.map(line).joined(separator: "\n"))
        case "search":
            let q = try input.req("query")
            let items = study.searchVocab(q, lang: lang, limit: limit)
            return ToolOutput(text: items.isEmpty ? "Nothing matches “\(q)”." : items.map(line).joined(separator: "\n"))
        case "stats":
            let langs = lang.map { [$0] } ?? study.vocabLanguages()
            if langs.isEmpty { return ToolOutput(text: "No vocabulary yet.") }
            return ToolOutput(text: langs.map { l in let s = study.vocabStats(lang: l); return "\(Languages.englishName(l)): \(s.total) words — \(s.new) new, \(s.learning) learning, \(s.known) known, \(s.due) due" }.joined(separator: "\n"))
        case "remove":
            let term = try input.req("term")
            guard let lang, study.removeVocab(lang: lang, term: term) else { return .error("No such word.") }
            EventBus.publish(.studyDataChanged)
            return ToolOutput(text: "Removed “\(term)”.")
        default: return .error("Unknown action.")
        }
    }
}
