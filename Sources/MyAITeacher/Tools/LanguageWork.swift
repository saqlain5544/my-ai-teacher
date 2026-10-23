import Foundation
import NaturalLanguage
import CoreServices
#if canImport(Translation)
import Translation
#endif

/// What the page's reading and lookup components ask the app (components/langwork.js): a passage's words with readings,
/// a word's dictionary entry, a sentence translated on device, and the log of what the learner has read. All of it is the
/// app's own work, never the model's: the model garbles text sometimes, and a reading or a definition must be right.
enum LanguageWork {
    // MARK: Passages

    /// Words of `text` with their UTF-16 offsets (`s`, `e`), reading (`r`: kana for Japanese, pinyin for Chinese, a Latin
    /// transliteration for other scripts), lemma (`l`), and whether the learner has saved it (`saved`) or knows it
    /// (`known`); and the sentences' offsets.
    static func analyze(_ text: String, lang: String?, study: StudyStore?) -> JSON {
        let code = lang.flatMap(Languages.code)
        let ns = text as NSString
        var tokens: [JSON] = []
        let deck = Dictionary((study?.vocab(lang: code, limit: 5000) ?? []).map { ($0.term, $0) }, uniquingKeysWith: { a, _ in a })
        func mark(_ w: String, lemma: String?) -> (saved: Bool, known: Bool) {
            guard let v = deck[w] ?? lemma.flatMap({ deck[$0] }) else { return (false, false) }
            return (true, v.status == "known")
        }
        if code == "ja" || (code == nil && text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }) {
            if let tok = CFStringTokenizerCreate(nil, text as CFString, CFRange(location: 0, length: ns.length), kCFStringTokenizerUnitWordBoundary, Locale(identifier: "ja") as CFLocale) {
                while CFStringTokenizerAdvanceToNextToken(tok) != [] {
                    let r = CFStringTokenizerGetCurrentTokenRange(tok)
                    let w = ns.substring(with: NSRange(location: r.location, length: r.length))
                    guard w.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { continue }
                    let hasKanji = w.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) }
                    let latin = (CFStringTokenizerCopyCurrentTokenAttribute(tok, kCFStringTokenizerAttributeLatinTranscription) as? String)?.lowercased()
                    let kana = hasKanji ? (TextAnalysis.commonReadings[w] ?? latin.flatMap { $0.applyingTransform(.latinToHiragana, reverse: false) }) : nil
                    let m = mark(w, lemma: nil)
                    var j: [String: JSON] = ["s": .number(Double(r.location)), "e": .number(Double(r.location + r.length))]
                    if let kana, !kana.unicodeScalars.contains(where: { $0.isASCII && $0.properties.isAlphabetic }) { j["r"] = .string(kana) }
                    if m.saved { j["saved"] = true }; if m.known { j["known"] = true }
                    tokens.append(.object(j))
                }
            }
        } else {
            let tagger = NLTagger(tagSchemes: [.lemma])
            tagger.string = text
            if let code { tagger.setLanguage(NLLanguage(code), range: text.startIndex..<text.endIndex) }
            let scripted = code.map { Languages.scripted.contains($0) } ?? false
            tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .lemma, options: [.omitWhitespace, .omitPunctuation]) { tag, range in
                let w = String(text[range])
                let nr = NSRange(range, in: text)
                var j: [String: JSON] = ["s": .number(Double(nr.location)), "e": .number(Double(nr.location + nr.length))]
                let lemma = tag?.rawValue
                if let lemma, lemma.lowercased() != w.lowercased() { j["l"] = .string(lemma) }
                if scripted || code == "zh" {
                    let t = code == "zh" ? w.applyingTransform(.mandarinToLatin, reverse: false) : w.applyingTransform(.toLatin, reverse: false)
                    if let t, t != w { j["r"] = .string(t) }
                }
                let m = mark(w, lemma: lemma)
                if m.saved { j["saved"] = true }; if m.known { j["known"] = true }
                tokens.append(.object(j))
                return true
            }
        }
        // Clock times: the tokenizer splits 七時 into 七 (なな) and 時 (じ), and 七時 is しちじ, 四時 よじ, 九時 くじ.
        if code == "ja" {
            var merged: [JSON] = []
            for t in tokens {
                if let prev = merged.last, let ps = prev["s"]?.int, let pe = prev["e"]?.int, let s = t["s"]?.int, let e = t["e"]?.int, pe == s,
                   ns.substring(with: NSRange(location: s, length: e - s)) == "時",
                   let r = hours[ns.substring(with: NSRange(location: ps, length: pe - ps))] {
                    merged[merged.count - 1] = ["s": .number(Double(ps)), "e": .number(Double(e)), "r": .string(r)]
                    continue
                }
                merged.append(t)
            }
            tokens = merged
        }
        var sentences: [JSON] = []
        let st = NLTokenizer(unit: .sentence)
        st.string = text
        if let code { st.setLanguage(NLLanguage(code)) }
        st.enumerateTokens(in: text.startIndex..<text.endIndex) { r, _ in
            let nr = NSRange(r, in: text)
            sentences.append([.number(Double(nr.location)), .number(Double(nr.location + nr.length))])
            return true
        }
        return ["tokens": .array(tokens), "sentences": .array(sentences)]
    }

    static let hours: [String: String] = ["一": "いちじ", "二": "にじ", "三": "さんじ", "四": "よじ", "五": "ごじ", "六": "ろくじ", "七": "しちじ", "八": "はちじ",
                                          "九": "くじ", "十": "じゅうじ", "十一": "じゅういちじ", "十二": "じゅうにじ", "何": "なんじ"]

    // MARK: Lookup

    struct Sense: Sendable { var pos: String?; var text: String }
    nonisolated(unsafe) private static var cache: [String: JSON] = [:]
    private static let cacheLock = NSLock()

    /// A word's reading, dictionary form and senses (Wiktionary, else the Mac's own dictionaries), and whether the learner
    /// has it saved. `lemma` is the page's guess at the dictionary form.
    static func lookup(_ word: String, lemma: String?, lang: String?, study: StudyStore?) async -> JSON {
        let code = lang.flatMap(Languages.code)
        let cacheKey = (code ?? "") + "|" + word
        if let hit = cacheLock.withLock({ cache[cacheKey] }) { return withDeck(hit, word: word, lang: code, study: study) }
        let tok = TextAnalysis.tokens(word, language: code).first
        var reading: String? = tok?.reading
        if code == "ja", let r = reading { reading = r.split(separator: " ").first.map(String.init) }   // the kana; romaji is noise here
        let dict = lemma ?? tok?.lemma
        var senses: [Sense] = []
        var source: String?
        for w in [word, dict].compactMap({ $0 }).reduce(into: [String](), { if !$0.contains($1) { $0.append($1) } }) {
            if let s = await wiktionary(w, lang: code), !s.isEmpty { senses = s; source = "Wiktionary · en.wiktionary.org/wiki/\(w)"; break }
        }
        if senses.isEmpty, let d = macDictionary(word) { senses = [Sense(pos: nil, text: d)]; source = "macOS Dictionary" }
        var j: [String: JSON] = ["word": .string(word), "senses": .array(senses.map { ["pos": $0.pos.map { .string($0) } ?? .null, "text": .string($0.text)] })]
        if let reading, reading != word { j["reading"] = .string(reading) }
        if let dict, dict != word { j["lemma"] = .string(dict) }
        if let source { j["source"] = .string(source) } else { j["note"] = "No dictionary entry found (Wiktionary, the Mac's dictionaries). Ask your teacher about it." }
        let out = JSON.object(j)
        cacheLock.withLock { if cache.count > 2000 { cache.removeAll() }; cache[cacheKey] = out }
        return withDeck(out, word: word, lang: code, study: study)
    }
    private static func withDeck(_ j: JSON, word: String, lang: String?, study: StudyStore?) -> JSON {
        guard let lang, let study, var o = j.object else { return j }
        let lemma = j["lemma"]?.string
        if let v = study.vocab(lang: lang, limit: 5000).first(where: { $0.term == word || $0.term == lemma }) { o["saved"] = .string(v.status) }
        return .object(o)
    }

    /// Wiktionary's REST definitions for one language's section, as senses (nil: no entry or no network).
    static func wiktionary(_ word: String, lang: String?) async -> [Sense]? {
        guard let enc = word.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://en.wiktionary.org/api/rest_v1/page/definition/\(enc)?redirect=true") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 12)
        req.setValue("MyAITeacher/\(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev") (language mentor; learning app)", forHTTPHeaderField: "User-Agent")
        guard let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
              let sections = JSON.parse(data)?.object else { return nil }
        let keys = lang.map { c in sections.keys.filter { $0 == c || $0.hasPrefix(c + "-") } } ?? Array(sections.keys)
        var out: [Sense] = []
        for k in keys.sorted() {
            for entry in sections[k]?.array ?? [] {
                for d in (entry["definitions"]?.array ?? []).prefix(4) {
                    let t = LanguageTool.strip(d["definition"]?.string ?? "")
                    if !t.isEmpty { out.append(Sense(pos: entry["partOfSpeech"]?.string, text: t)) }
                }
            }
        }
        return out
    }

    /// The Mac's installed dictionaries (Dictionary.app): offline, and only as good as the dictionaries the learner has
    /// turned on (a bilingual one for their language makes it useful).
    static func macDictionary(_ word: String) -> String? {
        let ns = word as NSString
        guard let d = DCSCopyTextDefinition(nil, word as CFString, CFRangeMake(0, ns.length))?.takeRetainedValue() as String? else { return nil }
        let t = d.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        return t.isEmpty ? nil : String(t.prefix(400))
    }

    // MARK: Pages

    /// A web page the learner wants to read, as plain text for the reading component: the main content (HTML cleaned by
    /// the same converter as `web_fetch`, cached with it), Markdown taken out, at most `limit` characters cut at a
    /// paragraph. Returns {title, text, url, truncated, shown, total} or {note}.
    static func page(_ raw: String, limit: Int = 8000) async -> JSON {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.hasPrefix("http") { s = "https://" + s }
        guard let url = URL(string: s), ["http", "https"].contains(url.scheme ?? "") else { return ["note": "That isn't a web address."] }
        var md: String, title: String?
        if let cached = await FetchCache.shared.get(url.absoluteString) { (md, title) = cached }
        else {
            var req = URLRequest(url: url, timeoutInterval: 25)
            req.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml;q=0.9,text/plain;q=0.8", forHTTPHeaderField: "Accept")
            guard let (data, resp) = try? await URLSession.shared.data(for: req) else { return ["note": "The page didn't load."] }
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard code < 400 else { return ["note": .string("The site answered \(code).")] }
            let ct = ((resp as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if ct.contains("html") || ct.isEmpty || ct.contains("xml") {
                let r = HTMLToMarkdown.convert(html: String(decoding: data.prefix(6_000_000), as: UTF8.self), baseURL: resp.url ?? url)
                (md, title) = (r.markdown, r.title)
            } else if ct.contains("text/") {
                (md, title) = (String(decoding: data.prefix(2_000_000), as: UTF8.self), nil)
            } else { return ["note": "That link isn't a page of text."] }
            await FetchCache.shared.put(url.absoluteString, md, title)
        }
        md = plainText(md)
        guard md.count >= 20 else { return ["note": "The page has no text to read (it may need JavaScript)."] }
        let total = md.count
        var text = md
        if total > limit {
            let cut = String(md.prefix(limit))
            text = cut.range(of: "\n\n", options: .backwards).map { String(cut[..<$0.lowerBound]) } ?? cut
        }
        return ["title": .string(title ?? url.host ?? ""), "text": .string(text), "url": .string(url.absoluteString),
                "truncated": .bool(text.count < total), "shown": .number(Double(text.count)), "total": .number(Double(total))]
    }

    /// Markdown as text to read: no images, link targets, emphasis marks, code fences, tables' rules or heading marks.
    static func plainText(_ md: String) -> String {
        var t = md
        for (p, r) in [("!\\[[^\\]]*\\]\\([^)]*\\)", ""), ("\\[([^\\]]*)\\]\\([^)]*\\)", "$1"), ("```[\\s\\S]*?```", ""), ("(?m)^[ \\t]*[|:\\-][|:\\- ]*$", ""),
                       ("(?m)^#{1,6}\\s*", ""), ("(?m)^>\\s?", ""), ("[*_`]{1,3}", ""), ("(?m)^[ \\t]*[-+*][ \\t]+", ""), ("\\|", " "), ("\\^?\\[\\d{1,3}\\]\\^?", ""), ("[ \\t]+", " "), ("(?m)^ ", ""), ("\\n{3,}", "\n\n")] {
            t = t.replacingOccurrences(of: p, with: r, options: .regularExpression)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Translation

    /// A sentence translated on device (Apple's Translation, macOS 26+, with the language pair installed in System
    /// Settings › General › Language & Region › Translation Languages). Returns {text, source} or {note}.
    static func translate(_ text: String, from: String?, to: String) async -> JSON {
        guard let from = from.flatMap(Languages.code) else { return ["note": "Which language is this? Set the lesson's language first."] }
        let apple = await translateWithTranslation(text, from: from, to: to)
        // No installed Translation pair: Apple's on-device language model, when it knows both languages (said as such).
        if apple["text"] == nil, let t = try? await withDeadline(seconds: 20, { await OnDevice.translate(text, from: from, to: to) }) {
            return ["text": .string(t), "source": "On-device Apple Intelligence model (not a translation engine: may be loose)"]
        }
        return apple
    }
    static func translateWithTranslation(_ text: String, from: String, to: String) async -> JSON {
        #if canImport(Translation)
        if #available(macOS 26.0, *) {
            do {
                return try await withDeadline(seconds: 15) {
                    let src = Locale.Language(identifier: from), dst = Locale.Language(identifier: to)
                    let status = await LanguageAvailability().status(from: src, to: dst)
                    switch status {
                    case .installed:
                        let session = TranslationSession(installedSource: src, target: dst)
                        let r = try await session.translate(text)
                        return ["text": .string(r.targetText), "source": "On-device translation (Apple)"]
                    case .supported:
                        return ["note": .string("On-device translation from \(Languages.englishName(from)) needs its language download: System Settings › General › Language & Region › Translation Languages. Or ask your teacher.")]
                    default:
                        return ["note": .string("The Mac has no on-device translation from \(Languages.englishName(from)) to \(Languages.englishName(to)). Ask your teacher.")]
                    }
                }
            } catch {
                return ["note": .string("On-device translation didn't answer (\(error.localizedDescription)). Ask your teacher.")]
            }
        }
        #endif
        return ["note": "On-device translation needs macOS 26 or later. Ask your teacher."]
    }
}

extension StudyStore {
    // MARK: Reading log

    /// A passage the learner finished reading (the ```reading component's Done): extensive reading, counted per language.
    func logReading(lang raw: String, title: String?, words: Int, unit: String?, conversationID: String?) {
        guard let lang = Languages.code(raw), words > 0 else { return }
        try? db.execute("INSERT INTO reading_log(lang, title, words, unit, at, conversation_id) VALUES(?,?,?,?,?,?)", lang, title, words, unit, Date(), conversationID)
    }
    /// Words (or characters, for unspaced scripts) read in the last `days` days, and passages finished.
    func readingStats(lang raw: String, days: Double = 7, now: Date = Date()) -> (words: Int, passages: Int, unit: String) {
        guard let lang = Languages.code(raw), let r = (try? db.query("SELECT COALESCE(SUM(words),0) AS w, COUNT(*) AS n, MAX(unit) AS u FROM reading_log WHERE lang=? AND at>=?", lang, now.addingTimeInterval(-days * 86400)))?.first
        else { return (0, 0, "words") }
        return (r.int("w") ?? 0, r.int("n") ?? 0, r.string("u") ?? "words")
    }
}
