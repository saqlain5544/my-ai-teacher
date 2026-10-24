import Foundation

// MARK: - Levels per skill, and the grammar syllabus

/// A CEFR level for one skill, with the evidence it rests on ("wrote a 120-word email with past tenses mostly right").
struct SkillLevel: Hashable, Sendable {
    var skill: String       // reading | listening | writing | speaking | vocabulary | grammar
    var level: String       // A1…C2, optionally with a note
    var evidence: String?
    var at: Date
}

/// A grammar point of a language's syllabus, at a CEFR level, with the learner's mastery of it (from what they produced).
struct GrammarPoint: Identifiable, Hashable, Sendable {
    var lang: String
    var name: String
    var level: String
    var description: String?
    var position: Int
    var mastery: MasteryItem?
    var id: String { lang + "/" + name }
    var pKnown: Double { mastery?.pKnown ?? 0 }
    var mastered: Bool { mastery?.mastered ?? false }
    var seen: Bool { (mastery?.attempts ?? 0) > 0 }
}

extension StudyStore {
    static let skills = ["reading", "listening", "writing", "speaking", "vocabulary", "grammar"]
    static let cefr = ["A1", "A2", "B1", "B2", "C1", "C2"]

    /// A CEFR level from free text ("b1+", "A2, strong reading" → A2…); nil when there is none.
    static func cefrLevel(_ s: String) -> String? {
        let m = s.uppercased().range(of: "[ABC][12]", options: .regularExpression)
        return m.map { String(s.uppercased()[$0]) }
    }

    func setSkill(lang raw: String, skill: String, level: String, evidence: String?) -> Bool {
        guard let code = Languages.code(raw), Self.skills.contains(skill.lowercased()), !level.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return (try? db.execute("""
            INSERT INTO language_skills(code, skill, level, evidence, at) VALUES(?,?,?,?,?)
            ON CONFLICT(code, skill) DO UPDATE SET level=excluded.level, evidence=COALESCE(excluded.evidence, language_skills.evidence), at=excluded.at
            """, code, skill.lowercased(), level.trimmingCharacters(in: .whitespaces), evidence, Date())) != nil
    }
    func skills(lang raw: String) -> [SkillLevel] {
        guard let code = Languages.code(raw) else { return [] }
        let rows = (try? db.query("SELECT skill, level, evidence, at FROM language_skills WHERE code=?", code)) ?? []
        return rows.compactMap { r in
            guard let s = r.string("skill"), let l = r.string("level") else { return nil }
            return SkillLevel(skill: s, level: l, evidence: r.string("evidence"), at: r.date("at") ?? Date())
        }.sorted { (Self.skills.firstIndex(of: $0.skill) ?? 9) < (Self.skills.firstIndex(of: $1.skill) ?? 9) }
    }

    /// Mastery of grammar points lives under one subject per language ("spanish grammar").
    static func grammarSubject(_ lang: String) -> String { "\(Languages.englishName(lang)) grammar".lowercased() }

    /// Adds points to a language's syllabus (or updates their level and description), in the order given within a level.
    @discardableResult
    func addGrammarPoints(lang raw: String, _ points: [(name: String, level: String, description: String?)]) -> Int {
        guard let code = Languages.code(raw) else { return 0 }
        var next = ((try? db.query("SELECT MAX(position) AS m FROM grammar_points WHERE lang=?", code))?.first?.int("m") ?? 0) + 1
        var n = 0
        for p in points {
            let name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, let level = Self.cefrLevel(p.level) else { continue }
            let ok = (try? db.execute("""
                INSERT INTO grammar_points(lang, name, level, description, position, created_at) VALUES(?,?,?,?,?,?)
                ON CONFLICT(lang, name) DO UPDATE SET level=excluded.level, description=COALESCE(excluded.description, grammar_points.description)
                """, code, name, level, p.description, next, Date())) != nil
            if ok { n += 1; next += 1 }
        }
        return n
    }
    func removeGrammarPoint(lang raw: String, name: String) -> Bool {
        guard let code = Languages.code(raw) else { return false }
        return ((try? db.execute("DELETE FROM grammar_points WHERE lang=? AND name=?", code, name)) ?? 0) > 0
    }

    /// The syllabus in level order (A1 first, then the order points were added), each with its mastery.
    func grammarSyllabus(lang raw: String) -> [GrammarPoint] {
        guard let code = Languages.code(raw) else { return [] }
        let subject = Self.grammarSubject(code)
        let rows = (try? db.query("""
            SELECT g.name, g.level, g.description, g.position, m.subject AS ms, m.concept AS mc, m.p_known, m.attempts, m.correct, m.streak, m.notes, m.updated_at
            FROM grammar_points g LEFT JOIN mastery m ON m.subject=? AND m.concept=g.name COLLATE NOCASE WHERE g.lang=?
            """, subject, code)) ?? []
        return rows.compactMap { r -> GrammarPoint? in
            guard let name = r.string("name"), let level = r.string("level") else { return nil }
            let m = r.string("mc").map { MasteryItem(subject: subject, concept: $0, pKnown: r.double("p_known") ?? 0.2, attempts: r.int("attempts") ?? 0,
                                                     correct: r.int("correct") ?? 0, streak: r.int("streak") ?? 0, notes: r.string("notes"),
                                                     updatedAt: r.date("updated_at") ?? Date()) }
            return GrammarPoint(lang: code, name: name, level: level, description: r.string("description"), position: r.int("position") ?? 0, mastery: m)
        }.sorted { ($0.level, $0.position) < ($1.level, $1.position) }
    }

    /// Evidence from production: the learner used (or got wrong) a grammar point in something they wrote or said.
    /// The point is matched to the syllabus by name; one that isn't there yet is added at `level` (or the learner's).
    @discardableResult
    func recordGrammar(lang raw: String, point: String, correct: Bool, evidence: String?, level: String? = nil, assisted: Bool = false) -> GrammarPoint? {
        guard let code = Languages.code(raw) else { return nil }
        let known = grammarSyllabus(lang: code).first { $0.name.compare(point, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
        let name = known?.name ?? point.trimmingCharacters(in: .whitespacesAndNewlines)
        if known == nil {
            let lv = level.flatMap(Self.cefrLevel) ?? languageProfile(code)?.level.flatMap(Self.cefrLevel) ?? "A1"
            addGrammarPoints(lang: code, [(name, lv, nil)])
        }
        recordAttempt(subject: Self.grammarSubject(code), concept: name, correct: correct, note: evidence.map { "“\($0)”" }, help: assisted ? .hint : .none, evidence: nil)
        return grammarSyllabus(lang: code).first { $0.name == name }
    }

    /// The points to work on next: at or below the learner's level, not mastered — the ones they got wrong first, then
    /// the ones never seen, in syllabus order.
    func nextGrammar(lang: String, limit: Int = 3) -> [GrammarPoint] {
        let all = grammarSyllabus(lang: lang)
        let cap = languageProfile(lang)?.level.flatMap(Self.cefrLevel).flatMap { Self.cefr.firstIndex(of: $0) }
        let open = all.filter { !$0.mastered && (cap == nil || (Self.cefr.firstIndex(of: $0.level) ?? 0) <= cap! + 1) }
        let shaky = open.filter { $0.seen && $0.pKnown < 0.6 }
        return Array((shaky + open.filter { !shaky.contains($0) }).prefix(limit))
    }
}

// MARK: - Kanji and hanzi through the learner's own words

/// A character of the learner's saved words: the words it appears in, and how far along it is — known when a word with
/// it is known (recalled and stable), learning when one is being reviewed, new otherwise.
struct HanCharacter: Identifiable, Hashable, Sendable {
    var char: String
    var words: [VocabItem]
    var status: String { words.contains { $0.status == "known" } ? "known" : words.contains { $0.status == "learning" } ? "learning" : "new" }
    var id: String { char }
}

extension StudyStore {
    static func isHan(_ c: Character) -> Bool {
        c.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) || (0x3400...0x4DBF).contains($0.value) || (0xF900...0xFAFF).contains($0.value) }
    }
    /// The kanji (hanzi) of a language's saved words, in the order the learner met them.
    func hanCharacters(lang: String) -> [HanCharacter] {
        var order: [String] = [], words: [String: [VocabItem]] = [:]
        for v in vocab(lang: lang, limit: 100_000).sorted(by: { $0.createdAt < $1.createdAt }) {
            for c in v.term where Self.isHan(c) {
                let k = String(c)
                if words[k] == nil { order.append(k) }
                if !(words[k]?.contains { $0.id == v.id } ?? false) { words[k, default: []].append(v) }
            }
        }
        return order.map { HanCharacter(char: $0, words: words[$0] ?? []) }
    }
}

// MARK: - Vocabulary in and out (Anki, spreadsheets)

/// Vocabulary to and from files: tab-separated text with Anki's header lines (Anki 2.1.55+ imports it with the deck and
/// tags; older versions and spreadsheets take it as plain TSV), CSV, and Anki packages (.apkg) on import.
enum VocabTransfer {
    static let columns = ["term", "reading", "meaning", "pos", "example", "example_meaning", "notes", "tags"]
    struct Entry: Equatable, Sendable {
        var term: String, meaning: String
        var reading: String? = nil, pos: String? = nil, example: String? = nil, exampleMeaning: String? = nil, notes: String? = nil
        var tags: [String] = []
    }

    private static func fields(_ v: VocabItem) -> [String] {
        [v.term, v.reading ?? "", v.meaning, v.pos ?? "", v.example ?? "", v.exampleMeaning ?? "", v.notes ?? "", v.tags.joined(separator: " ")]
    }
    /// Tab-separated, one word per line, with Anki's headers (tabs and newlines inside a field become spaces and <br>).
    static func tsv(_ items: [VocabItem], lang: String) -> String {
        let clean = { (s: String) in s.replacingOccurrences(of: "\t", with: " ").replacingOccurrences(of: "\r\n", with: "<br>").replacingOccurrences(of: "\n", with: "<br>") }
        var out = "#separator:tab\n#html:true\n#notetype:Basic\n#deck:\(StudyStore.vocabDeck(lang))\n#tags column:\(columns.count)\n#columns:" + columns.joined(separator: "\t") + "\n"
        for v in items { out += fields(v).map(clean).joined(separator: "\t") + "\n" }
        return out
    }
    /// Comma-separated with a header row (RFC 4180 quoting), for spreadsheets.
    static func csv(_ items: [VocabItem]) -> String {
        let q = { (s: String) -> String in s.contains(where: { ",\"\n\r".contains($0) }) ? "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" : s }
        return ([columns.joined(separator: ",")] + items.map { fields($0).map(q).joined(separator: ",") }).joined(separator: "\n") + "\n"
    }

    /// Rows of a delimited text: quoted fields may hold the delimiter, quotes ("") and newlines.
    static func rows(_ text: String, separator sep: Character) -> [[String]] {
        var rows: [[String]] = [], row: [String] = [], field = "", quoted = false, atStart = true
        let it = Array(text.replacingOccurrences(of: "\r\n", with: "\n")); var i = 0
        while i < it.count {
            let c = it[i]
            if quoted {
                if c == "\"" { if i + 1 < it.count && it[i + 1] == "\"" { field.append("\""); i += 1 } else { quoted = false } }
                else { field.append(c) }
            } else if c == "\"" && atStart { quoted = true; atStart = false }
            else if c == sep { row.append(field); field = ""; atStart = true; i += 1; continue }
            else if c == "\n" { row.append(field); rows.append(row); row = []; field = ""; atStart = true; i += 1; continue }
            else { field.append(c); atStart = false }
            i += 1
        }
        if !field.isEmpty || !row.isEmpty { row.append(field); rows.append(row) }
        return rows.filter { !($0.count == 1 && $0[0].trimmingCharacters(in: .whitespaces).isEmpty) }
    }

    /// Words from a text export: Anki's (headers `#separator:`, `#html:`, `#columns:`, `#tags column:`), this app's,
    /// or a spreadsheet's (a header row naming the columns, or term and meaning first).
    static func parse(_ text: String) -> [Entry] {
        var lines = text.components(separatedBy: "\n")
        var sep: Character? = nil, html = false, names: [String]? = nil, tagsColumn: Int? = nil
        while let first = lines.first, first.hasPrefix("#"), first.contains(":") {
            let kv = first.dropFirst().split(separator: ":", maxSplits: 1).map(String.init)
            let key = kv[0].lowercased(), value = kv.count > 1 ? kv[1].trimmingCharacters(in: .whitespaces) : ""
            switch key {
            case "separator": sep = ["tab": "\t", "comma": ",", "semicolon": ";", "pipe": "|", "space": " ", "colon": ":"][value.lowercased()] ?? value.first
            case "html": html = value.lowercased() == "true"
            case "columns": names = value.components(separatedBy: sep.map(String.init) ?? "\t")
            case "tags column": tagsColumn = Int(value).map { $0 - 1 }
            default: break
            }
            lines.removeFirst()
        }
        let body = lines.joined(separator: "\n")
        let delimiter: Character = sep ?? {
            let head = body.prefix(2000)
            let counts: [(Character, Int)] = ["\t", ",", ";"].map { c in (c, head.filter { $0 == c }.count) }
            return counts.max { $0.1 < $1.1 }.map { $0.1 > 0 ? $0.0 : "\t" } ?? "\t"
        }()
        var table = rows(body, separator: delimiter)
        // A header row: names this app, Anki or a spreadsheet would use.
        let aliases: [String: String] = ["term": "term", "word": "term", "front": "term", "expression": "term", "vocab": "term", "kanji": "term",
                                         "reading": "reading", "pronunciation": "reading", "kana": "reading", "pinyin": "reading", "furigana": "reading",
                                         "meaning": "meaning", "back": "meaning", "translation": "meaning", "definition": "meaning", "english": "meaning",
                                         "pos": "pos", "part of speech": "pos", "example": "example", "sentence": "example",
                                         "example_meaning": "example_meaning", "example meaning": "example_meaning", "sentence meaning": "example_meaning",
                                         "notes": "notes", "note": "notes", "tags": "tags"]
        func mapped(_ header: [String]) -> [String?] { header.map { aliases[$0.trimmingCharacters(in: .whitespaces).lowercased()] } }
        var map: [String?]
        if let n = names { map = mapped(n) }
        else if let h = table.first, mapped(h).contains("term"), mapped(h).contains("meaning") { map = mapped(h); table.removeFirst() }
        else { map = ["term", "meaning"] }
        if let t = tagsColumn { while map.count <= t { map.append(nil) }; map[t] = "tags" }
        if !map.contains("term") || !map.contains("meaning") { map = ["term", "meaning"] }
        return table.compactMap { r in
            var e: [String: String] = [:]
            for (i, key) in map.enumerated() { if let key, i < r.count { e[key] = html ? plain(r[i]) : r[i].trimmingCharacters(in: .whitespacesAndNewlines) } }
            guard let term = e["term"], !term.isEmpty, let meaning = e["meaning"], !meaning.isEmpty else { return nil }
            let opt = { (k: String) -> String? in e[k].flatMap { $0.isEmpty ? nil : $0 } }
            return Entry(term: term, meaning: meaning, reading: opt("reading"), pos: opt("pos"), example: opt("example"), exampleMeaning: opt("example_meaning"),
                         notes: opt("notes"), tags: (e["tags"] ?? "").split(whereSeparator: { $0 == " " || $0 == "," }).map(String.init))
        }
    }

    /// A field's text without Anki's HTML and sound references (<br> → newline, entities decoded).
    static func plain(_ s: String) -> String {
        s.replacingOccurrences(of: "(?i)<br\\s*/?>|</div>|</p>", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\[sound:[^\\]]*\\]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
            .replacingOccurrences(of: "&nbsp;", with: " ").replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&#39;", with: "'").replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "\n{3,}", with: "\n\n", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    enum APKGError: LocalizedError {
        case unreadable, newFormat
        var errorDescription: String? {
            switch self {
            case .unreadable: "This isn't an Anki package the app can read."
            case .newFormat: "This package uses Anki's newer compressed format. In Anki, export the deck again with “Support older Anki versions” ticked (or as “Notes in Plain Text”), then import that."
            }
        }
    }
    /// Notes of an Anki package: its first field as the term, the second as the meaning, any others kept as notes.
    /// Reads the SQLite collection inside the zip (collection.anki21 or .anki2); the zstd-compressed .anki21b of
    /// Anki 2.1.50+ isn't readable without a zstd decoder, so that case says how to export a readable one.
    static func apkg(_ url: URL) async throws -> [Entry] {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("apkg-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let r = await ProcessRunner.run("/usr/bin/ditto", ["-x", "-k", url.path, dir.path])
        guard r.exitCode == 0 else { throw APKGError.unreadable }
        let candidates = ["collection.anki21", "collection.anki2"].map { dir.appendingPathComponent($0) }.filter { FileManager.default.fileExists(atPath: $0.path) }
        for file in candidates {
            guard let db = try? Database(path: file.path, readOnly: true), let notes = try? db.query("SELECT flds, tags FROM notes") else { continue }
            let out = notes.compactMap { n -> Entry? in
                let f = (n.string("flds") ?? "").components(separatedBy: "\u{1f}").map(plain)
                guard f.count >= 2, !f[0].isEmpty, !f[1].isEmpty else { return nil }
                let rest = f.dropFirst(2).filter { !$0.isEmpty }
                return Entry(term: f[0], meaning: f[1], notes: rest.isEmpty ? nil : rest.joined(separator: "\n"),
                             tags: (n.string("tags") ?? "").split(separator: " ").map(String.init))
            }
            // Anki 2.1.50+ puts a single "please update" note in the old file next to the real .anki21b.
            if out.count <= 1, FileManager.default.fileExists(atPath: dir.appendingPathComponent("collection.anki21b").path) { throw APKGError.newFormat }
            return out
        }
        if FileManager.default.fileExists(atPath: dir.appendingPathComponent("collection.anki21b").path) { throw APKGError.newFormat }
        throw APKGError.unreadable
    }

    /// A file the learner picked (Anki package, Anki or app text export, CSV/TSV) into their vocabulary; what happened, in a sentence.
    static func importFile(_ url: URL, lang: String, into study: StudyStore) async throws -> String {
        let entries: [Entry]
        if url.pathExtension.lowercased() == "apkg" { entries = try await apkg(url) }
        else {
            guard let text = (try? String(contentsOf: url, encoding: .utf8)) ?? (try? String(contentsOf: url, encoding: .utf16)) else { throw APKGError.unreadable }
            entries = parse(text)
        }
        guard !entries.isEmpty else { return "No words found: each line needs a term and its meaning." }
        let r = importEntries(entries, lang: lang, into: study, source: "import: \(url.lastPathComponent)")
        await MainActor.run { EventBus.publish(.studyDataChanged) }
        return "Imported \(r.added) new word\(r.added == 1 ? "" : "s")" + (r.updated > 0 ? ", updated \(r.updated)" : "") + " — reviewed as flashcards in “\(StudyStore.vocabDeck(lang))”."
    }

    /// Saves entries as vocabulary (each with its flashcard); words already saved are updated, not duplicated.
    static func importEntries(_ entries: [Entry], lang: String, into study: StudyStore, source: String) -> (added: Int, updated: Int) {
        var added = 0, updated = 0
        let existing = Set(study.vocab(lang: lang, limit: 100_000).map(\.term))
        for e in entries {
            let tags = e.tags.filter { !$0.isEmpty && $0.lowercased() != "marked" && $0.lowercased() != "leech" }
            guard study.addVocab(lang: lang, term: e.term, reading: e.reading, meaning: e.meaning, pos: e.pos, example: e.example,
                                 exampleMeaning: e.exampleMeaning, notes: e.notes, tags: tags, source: source) != nil else { continue }
            if existing.contains(e.term) { updated += 1 } else { added += 1 }
        }
        return (added, updated)
    }
}
