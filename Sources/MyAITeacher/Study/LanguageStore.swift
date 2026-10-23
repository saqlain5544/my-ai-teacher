import Foundation

/// A language the learner is learning (or speaks): the mentor's profile of it, kept across lessons.
struct LanguageProfile: Identifiable, Hashable, Sendable {
    var code: String            // ISO 639-1 ("ja")
    var role: String            // "target" | "native"
    var level: String?          // CEFR estimate (A1…C2) or free text
    var notes: String?
    var updatedAt: Date
    var id: String { code }
}

/// A word or phrase the learner is collecting, reviewed as a flashcard (FSRS) in the Flashcards screen.
struct VocabItem: Identifiable, Hashable, Sendable {
    var id: Int64
    var lang: String
    var term: String
    var reading: String?
    var meaning: String
    var pos: String?
    var example: String?
    var exampleMeaning: String?
    var notes: String?
    var tags: [String]
    var cardID: Int64?
    var createdAt: Date
    // From the linked card, when there is one.
    var due: Date?
    var reps = 0
    var stability: Double = 0
    var lapses = 0

    /// Known: recalled several times and stable for weeks; learning: seen but not yet stable; new: never reviewed.
    var status: String { reps == 0 ? "new" : (stability >= 21 && lapses <= reps / 2 ? "known" : "learning") }
}

struct VocabStats: Sendable, Equatable {
    var total = 0, due = 0, known = 0, learning = 0, new = 0
}

/// Languages and vocabulary live in the learner's global store (teacher.sqlite), beside flashcards and mastery.
extension StudyStore {
    // MARK: Language profiles

    func languageProfiles() -> [LanguageProfile] {
        ((try? db.query("SELECT code, role, level, notes, updated_at FROM languages ORDER BY updated_at DESC")) ?? []).compactMap { r in
            guard let code = r.string("code") else { return nil }
            return LanguageProfile(code: code, role: r.string("role") ?? "target", level: r.string("level"), notes: r.string("notes"), updatedAt: r.date("updated_at") ?? Date())
        }
    }
    func languageProfile(_ code: String) -> LanguageProfile? { languageProfiles().first { $0.code == Languages.code(code) } }

    /// Sets or updates a language's profile; empty strings clear a field, nil leaves it.
    func setLanguageProfile(code raw: String, role: String? = nil, level: String? = nil, notes: String? = nil) -> LanguageProfile? {
        guard let code = Languages.code(raw) else { return nil }
        let old = languageProfile(code)
        let r = role ?? old?.role ?? "target"
        let l = level == nil ? old?.level : (level!.isEmpty ? nil : level)
        let n = notes == nil ? old?.notes : (notes!.isEmpty ? nil : notes)
        try? db.execute("INSERT INTO languages(code, role, level, notes, updated_at) VALUES(?,?,?,?,?) ON CONFLICT(code) DO UPDATE SET role=excluded.role, level=excluded.level, notes=excluded.notes, updated_at=excluded.updated_at",
                        code, r, l, n, Date())
        return languageProfile(code)
    }
    func removeLanguageProfile(_ code: String) { try? db.execute("DELETE FROM languages WHERE code=?", Languages.code(code) ?? code) }

    // MARK: Vocabulary

    private func vocabItem(_ r: Row) -> VocabItem? {
        guard let id = r.int("id"), let term = r.string("term") else { return nil }
        return VocabItem(id: Int64(id), lang: r.string("lang") ?? "", term: term, reading: r.string("reading"), meaning: r.string("meaning") ?? "",
                         pos: r.string("pos"), example: r.string("example"), exampleMeaning: r.string("example_meaning"), notes: r.string("notes"),
                         tags: (r.string("tags") ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
                         cardID: r.int("card_id").map(Int64.init), createdAt: r.date("created_at") ?? Date(),
                         due: r.date("due"), reps: r.int("reps") ?? 0, stability: r.double("stability") ?? 0, lapses: r.int("lapses") ?? 0)
    }
    private static let vocabSelect = "SELECT v.*, c.due AS due, c.reps AS reps, c.stability AS stability, c.lapses AS lapses FROM vocab v LEFT JOIN cards c ON c.id = v.card_id"

    /// The deck a language's words are reviewed in.
    static func vocabDeck(_ lang: String) -> String { "\(Languages.englishName(lang)) vocabulary" }

    /// Adds a word (or updates its meaning/example) and its flashcard. Returns the item.
    @discardableResult
    func addVocab(lang raw: String, term: String, reading: String? = nil, meaning: String, pos: String? = nil, example: String? = nil,
                  exampleMeaning: String? = nil, notes: String? = nil, tags: [String] = [], source: String? = nil) -> VocabItem? {
        let lang = Languages.code(raw) ?? raw.lowercased()
        let term = term.trimmingCharacters(in: .whitespacesAndNewlines), meaning = meaning.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty, !meaning.isEmpty else { return nil }
        let clean = { (s: String?) -> String? in s.flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 } }
        let existing = (try? db.query("SELECT card_id, reading, example, example_meaning FROM vocab WHERE lang=? AND term=?", lang, term))?.first
        let r = clean(reading) ?? existing?.string("reading"), ex = clean(example) ?? existing?.string("example"), exm = clean(exampleMeaning) ?? existing?.string("example_meaning")
        let front = r.map { "\(term)\n\n*\($0)*" } ?? term
        var back = meaning
        if let e = ex { back += "\n\n> \(e)" + (exm.map { "\n> *\($0)*" } ?? "") }
        var cardID = existing?.int("card_id").map(Int64.init)
        if let c = cardID { try? db.execute("UPDATE cards SET front=?, back=? WHERE id=?", front, back, c) }
        else { cardID = addCard(deck: Self.vocabDeck(lang), front: front, back: back, concept: nil, subject: lang, source: source) }
        try? db.execute("""
            INSERT INTO vocab(lang, term, reading, meaning, pos, example, example_meaning, notes, tags, card_id, source, created_at) VALUES(?,?,?,?,?,?,?,?,?,?,?,?)
            ON CONFLICT(lang, term) DO UPDATE SET reading=COALESCE(excluded.reading, vocab.reading), meaning=excluded.meaning, pos=COALESCE(excluded.pos, vocab.pos),
            example=COALESCE(excluded.example, vocab.example), example_meaning=COALESCE(excluded.example_meaning, vocab.example_meaning),
            notes=COALESCE(excluded.notes, vocab.notes), tags=CASE WHEN excluded.tags='' THEN vocab.tags ELSE excluded.tags END, card_id=COALESCE(vocab.card_id, excluded.card_id)
            """, lang, term, clean(reading), meaning, clean(pos), clean(example), clean(exampleMeaning), clean(notes), tags.joined(separator: ","), cardID, source, Date())
        return (try? db.query(Self.vocabSelect + " WHERE v.lang=? AND v.term=?", lang, term))?.first.flatMap(vocabItem)
    }

    func vocab(lang: String? = nil, tag: String? = nil, limit: Int = 200) -> [VocabItem] {
        var sql = Self.vocabSelect, params: [SQLBindable?] = []
        var conds: [String] = []
        if let l = lang.flatMap(Languages.code) { conds.append("v.lang=?"); params.append(l) }
        if let t = tag, !t.isEmpty { conds.append("(',' || v.tags || ',') LIKE ?"); params.append("%,\(t),%") }
        if !conds.isEmpty { sql += " WHERE " + conds.joined(separator: " AND ") }
        sql += " ORDER BY v.created_at DESC LIMIT ?"; params.append(limit)
        return ((try? db.query(sql, params: params)) ?? []).compactMap(vocabItem)
    }
    func dueVocab(lang: String? = nil, limit: Int = 50, now: Date = Date()) -> [VocabItem] {
        var sql = Self.vocabSelect + " WHERE c.suspended=0 AND c.due<=?", params: [SQLBindable?] = [now]
        if let l = lang.flatMap(Languages.code) { sql += " AND v.lang=?"; params.append(l) }
        sql += " ORDER BY c.due LIMIT ?"; params.append(limit)
        return ((try? db.query(sql, params: params)) ?? []).compactMap(vocabItem)
    }
    func searchVocab(_ query: String, lang: String? = nil, limit: Int = 50) -> [VocabItem] {
        var sql = Self.vocabSelect + " WHERE (v.term LIKE ? OR v.meaning LIKE ? OR v.reading LIKE ?)", params: [SQLBindable?] = ["%\(query)%", "%\(query)%", "%\(query)%"]
        if let l = lang.flatMap(Languages.code) { sql += " AND v.lang=?"; params.append(l) }
        sql += " ORDER BY v.created_at DESC LIMIT ?"; params.append(limit)
        return ((try? db.query(sql, params: params)) ?? []).compactMap(vocabItem)
    }
    func removeVocab(lang: String, term: String) -> Bool {
        guard let l = Languages.code(lang), let row = (try? db.query("SELECT id, card_id FROM vocab WHERE lang=? AND term=?", l, term))?.first, let id = row.int("id") else { return false }
        if let c = row.int("card_id") { try? db.execute("DELETE FROM cards WHERE id=?", Int64(c)) }
        try? db.execute("DELETE FROM vocab WHERE id=?", Int64(id))
        return true
    }
    func vocabStats(lang: String? = nil, now: Date = Date()) -> VocabStats {
        var s = VocabStats()
        for v in vocab(lang: lang, limit: 100_000) {
            s.total += 1
            if let d = v.due, d <= now { s.due += 1 }
            switch v.status { case "known": s.known += 1; case "learning": s.learning += 1; default: s.new += 1 }
        }
        return s
    }
    /// Languages with saved words, most recently added first.
    func vocabLanguages() -> [String] {
        ((try? db.query("SELECT lang, MAX(created_at) AS t FROM vocab GROUP BY lang ORDER BY t DESC")) ?? []).compactMap { $0.string("lang") }
    }
}

/// Language names and codes: ISO 639-1 both ways, in English and in the language's own name.
enum Languages {
    /// Names (lower-case, English and endonyms) → code. Used to read "I want to learn Japanese" and tool arguments.
    static let names: [String: String] = [
        "english": "en", "spanish": "es", "español": "es", "castellano": "es", "french": "fr", "français": "fr", "german": "de", "deutsch": "de",
        "italian": "it", "italiano": "it", "portuguese": "pt", "português": "pt", "japanese": "ja", "日本語": "ja", "nihongo": "ja", "korean": "ko", "한국어": "ko",
        "chinese": "zh", "mandarin": "zh", "中文": "zh", "汉语": "zh", "普通话": "zh", "cantonese": "yue", "arabic": "ar", "العربية": "ar", "russian": "ru", "русский": "ru",
        "hindi": "hi", "हिन्दी": "hi", "urdu": "ur", "اردو": "ur", "persian": "fa", "farsi": "fa", "فارسی": "fa", "hebrew": "he", "עברית": "he", "greek": "el", "ελληνικά": "el",
        "turkish": "tr", "türkçe": "tr", "dutch": "nl", "nederlands": "nl", "swedish": "sv", "svenska": "sv", "norwegian": "no", "norsk": "no", "danish": "da", "dansk": "da",
        "finnish": "fi", "suomi": "fi", "polish": "pl", "polski": "pl", "czech": "cs", "čeština": "cs", "slovak": "sk", "ukrainian": "uk", "українська": "uk",
        "romanian": "ro", "română": "ro", "hungarian": "hu", "magyar": "hu", "vietnamese": "vi", "tiếng việt": "vi", "thai": "th", "ไทย": "th", "indonesian": "id",
        "bahasa indonesia": "id", "malay": "ms", "bengali": "bn", "bangla": "bn", "বাংলা": "bn", "tamil": "ta", "telugu": "te", "punjabi": "pa", "gujarati": "gu", "marathi": "mr",
        "swahili": "sw", "kiswahili": "sw", "esperanto": "eo", "latin": "la", "catalan": "ca", "català": "ca", "croatian": "hr", "serbian": "sr", "bulgarian": "bg",
        "icelandic": "is", "irish": "ga", "welsh": "cy", "afrikaans": "af", "filipino": "tl", "tagalog": "tl", "malayalam": "ml", "kannada": "kn", "sinhala": "si",
        "nepali": "ne", "pashto": "ps", "kurdish": "ku", "amharic": "am", "yoruba": "yo", "zulu": "zu", "hawaiian": "haw", "mongolian": "mn", "georgian": "ka", "armenian": "hy",
        "lithuanian": "lt", "latvian": "lv", "estonian": "et", "slovenian": "sl", "albanian": "sq", "macedonian": "mk", "basque": "eu", "galician": "gl", "yiddish": "yi",
        "sanskrit": "sa", "ancient greek": "grc", "old english": "ang", "scottish gaelic": "gd", "maori": "mi", "māori": "mi", "samoan": "sm", "tongan": "to", "burmese": "my", "khmer": "km", "lao": "lo",
    ]
    /// A two-letter code for a name or code ("Japanese", "ja", "ja-JP", "jpn" → "ja"); nil for nonsense.
    static func code(_ raw: String) -> String? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !s.isEmpty else { return nil }
        if let c = names[s] { return c }
        let base = String(s.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(s))
        if base.count == 2, base.allSatisfy(\.isLetter) { return base }
        if base.count == 3, base.allSatisfy(\.isLetter), let two = Locale.LanguageCode(base).identifier(.alpha2) { return two }
        if names.values.contains(base) { return base }
        return nil
    }
    static func englishName(_ code: String) -> String {
        Locale(identifier: "en").localizedString(forLanguageCode: code).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? code
    }
    /// The language's own name ("日本語", "Español"), as the keyboard panel shows it.
    static func nativeName(_ code: String) -> String {
        Locale(identifier: code).localizedString(forLanguageCode: code).map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? englishName(code)
    }
    static let rightToLeft: Set<String> = ["ar", "he", "fa", "ur", "ps", "yi", "dv", "ku", "sd", "ug"]
    /// Scripts that are not the Latin alphabet (the learner needs a keyboard or transliteration for them).
    static let scripted: Set<String> = ["ja", "ko", "zh", "yue", "ar", "he", "fa", "ur", "ru", "uk", "bg", "sr", "mk", "el", "hi", "mr", "ne", "sa", "bn", "ta", "te", "kn", "ml", "gu", "pa", "si", "th", "lo", "km", "my", "ka", "hy", "am", "yi", "ps", "ku", "sd", "ug", "mn", "grc"]
}


/// Writing systems a language's words are written in, to catch a slip into another script (a Korean word in a Japanese
/// example sentence, Cyrillic in a Greek one). Latin, digits and punctuation are always allowed: names, romanisation
/// and brand names are fine in any language.
enum ScriptCheck {
    static let scripts: [(name: String, ranges: [ClosedRange<UInt32>])] = [
        ("Hiragana", [0x3040...0x309F]), ("Katakana", [0x30A0...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F]),
        ("Han", [0x4E00...0x9FFF, 0x3400...0x4DBF, 0xF900...0xFAFF]), ("Hangul", [0xAC00...0xD7AF, 0x1100...0x11FF, 0x3130...0x318F]),
        ("Arabic", [0x0600...0x06FF, 0x0750...0x077F, 0xFB50...0xFDFF, 0xFE70...0xFEFF]), ("Hebrew", [0x0590...0x05FF]),
        ("Cyrillic", [0x0400...0x04FF]), ("Greek", [0x0370...0x03FF]), ("Devanagari", [0x0900...0x097F]), ("Bengali", [0x0980...0x09FF]),
        ("Thai", [0x0E00...0x0E7F]),
    ]
    /// The non-Latin scripts each language uses.
    static let allowed: [String: Set<String>] = [
        "ja": ["Hiragana", "Katakana", "Han"], "zh": ["Han"], "yue": ["Han"], "ko": ["Hangul", "Han"],
        "ar": ["Arabic"], "fa": ["Arabic"], "ur": ["Arabic"], "he": ["Hebrew"], "ru": ["Cyrillic"], "uk": ["Cyrillic"],
        "el": ["Greek"], "hi": ["Devanagari"], "bn": ["Bengali"], "th": ["Thai"],
    ]
    /// The first script in `text` that `lang` isn't written in (nil when it fits, or the language isn't one we know).
    static func foreign(_ text: String, lang: String) -> String? {
        // Latin-script languages: any non-Latin script is foreign.
        let ok = allowed[lang] ?? []
        for u in text.unicodeScalars {
            guard let s = scripts.first(where: { $0.ranges.contains { $0.contains(u.value) } }) else { continue }
            if !ok.contains(s.name) { return s.name }
        }
        return nil
    }
}
