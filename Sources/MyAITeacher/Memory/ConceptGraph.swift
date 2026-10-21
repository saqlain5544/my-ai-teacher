import Foundation

/// The learner model's skeleton: concepts/skills as nodes with multi-subject tags, prerequisite/related edges,
/// and the latest BKT mastery cached from `StudyStore` (which stays the single source of truth for mastery).
/// Lives in the learner DB. An in-memory routing index (stem → concepts) makes "which concepts does this
/// message mention?" O(query terms), independent of graph size.
final class ConceptGraph: @unchecked Sendable {
    let db: Database
    private let lock = NSRecursiveLock()
    private var nodes: [Int64: Concept] = [:]
    private var alias: [String: Int64] = [:]
    private var keyStems: [Int64: [Set<String>]] = [:]
    private var postings: [String: Set<Int64>] = [:]
    private var loadedVersion: Int?

    static let sql = """
    CREATE TABLE IF NOT EXISTS concepts(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, summary TEXT, status TEXT,
        p_known REAL, attempts INTEGER NOT NULL DEFAULT 0, correct INTEGER NOT NULL DEFAULT 0, mastery_at REAL,
        evidence INTEGER NOT NULL DEFAULT 1, origin TEXT NOT NULL DEFAULT 'inferred', source TEXT,
        created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS concept_aliases(norm TEXT PRIMARY KEY, concept_id INTEGER NOT NULL);
    CREATE INDEX IF NOT EXISTS concept_aliases_c ON concept_aliases(concept_id);
    CREATE TABLE IF NOT EXISTS concept_subjects(concept_id INTEGER NOT NULL, subject TEXT NOT NULL, PRIMARY KEY(concept_id, subject));
    CREATE INDEX IF NOT EXISTS concept_subjects_s ON concept_subjects(subject);
    CREATE TABLE IF NOT EXISTS concept_edges(src INTEGER NOT NULL, dst INTEGER NOT NULL, rel TEXT NOT NULL, created_at REAL NOT NULL,
        PRIMARY KEY(src, dst, rel));
    CREATE INDEX IF NOT EXISTS concept_edges_dst ON concept_edges(dst);
    """

    init(db: Database) {
        self.db = db
        try? db.script(Self.sql)
        try? db.script("CREATE INDEX IF NOT EXISTS mastery_updated ON mastery(updated_at)")
    }

    // MARK: Index

    private func ensureLoaded() {
        let v = MemorySchema.dataVersion(db)
        if loadedVersion == v { return }
        nodes = [:]; alias = [:]; keyStems = [:]; postings = [:]
        var subjects: [Int64: [String]] = [:]
        for r in (try? db.query("SELECT concept_id, subject FROM concept_subjects ORDER BY subject")) ?? [] {
            if let c = r.int("concept_id"), let s = r.string("subject") { subjects[Int64(c), default: []].append(s) }
        }
        for r in (try? db.query("SELECT * FROM concepts")) ?? [] {
            guard let id = r.int("id").map(Int64.init) else { continue }
            nodes[id] = Concept(rowid: id, name: r.string("name") ?? "", subjects: subjects[id] ?? [], summary: r.string("summary"),
                                status: r.string("status"), pKnown: r.double("p_known"), attempts: r.int("attempts") ?? 0,
                                correct: r.int("correct") ?? 0, evidence: r.int("evidence") ?? 1, origin: r.string("origin") ?? "inferred",
                                source: r.string("source"), createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date())
        }
        for r in (try? db.query("SELECT norm, concept_id FROM concept_aliases")) ?? [] {
            if let n = r.string("norm"), let c = r.int("concept_id") { indexAlias(n, Int64(c)) }
        }
        loadedVersion = v
    }

    private func indexAlias(_ key: String, _ id: Int64) {
        alias[key] = id
        let st = Set(key.split(separator: " ").map(String.init).filter { MemoryText.keep($0) || $0.count >= 2 })
        guard !st.isEmpty else { return }
        keyStems[id, default: []].append(st)
        for s in st { postings[s, default: []].insert(id) }
    }

    private func reload() { lock.lock(); loadedVersion = nil; ensureLoaded(); lock.unlock() }

    // MARK: Reads

    func all() -> [Concept] { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return nodes.values.sorted { $0.name < $1.name } }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return nodes.count }
    func concept(_ id: Int64) -> Concept? { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return nodes[id] }
    func find(_ name: String) -> Int64? {
        let k = MemoryText.conceptKey(name)
        guard !k.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }; ensureLoaded()
        return alias[k]
    }

    /// Subjects with their concepts (most recently touched first).
    func subjects() -> [(subject: String, concepts: [Concept])] {
        var by: [String: [Concept]] = [:]
        for c in all() { for s in (c.subjects.isEmpty ? ["general"] : c.subjects) { by[s, default: []].append(c) } }
        return by.map { ($0.key, $0.value.sorted { $0.updatedAt > $1.updatedAt }) }
            .sorted { ($0.concepts.first?.updatedAt ?? .distantPast) > ($1.concepts.first?.updatedAt ?? .distantPast) }
    }

    struct Edge: Hashable, Sendable { var src: Int64; var dst: Int64; var rel: ConceptRelation }
    func edges() -> [Edge] {
        ((try? db.query("SELECT src, dst, rel FROM concept_edges")) ?? []).compactMap { r in
            guard let s = r.int("src"), let d = r.int("dst"), let rel = r.string("rel").flatMap(ConceptRelation.init(rawValue:)) else { return nil }
            return Edge(src: Int64(s), dst: Int64(d), rel: rel)
        }
    }
    /// What `id` builds on (its prerequisites).
    func prerequisites(of id: Int64) -> [Concept] {
        ((try? db.query("SELECT dst FROM concept_edges WHERE src=? AND rel='prereq'", id)) ?? []).compactMap { $0.int("dst").flatMap { concept(Int64($0)) } }
    }
    /// What builds on `id`.
    func dependents(of id: Int64) -> [Concept] {
        ((try? db.query("SELECT src FROM concept_edges WHERE dst=? AND rel='prereq'", id)) ?? []).compactMap { $0.int("src").flatMap { concept(Int64($0)) } }
    }
    func related(to id: Int64) -> [Concept] {
        ((try? db.query("SELECT CASE WHEN src=? THEN dst ELSE src END AS o FROM concept_edges WHERE (src=? OR dst=?) AND rel!='prereq'", id, id, id)) ?? [])
            .compactMap { $0.int("o").flatMap { concept(Int64($0)) } }
    }

    struct SubjectLink: Hashable, Sendable { var a: String; var b: String; var via: [String] }
    /// Cross-subject structure: concepts tagged with several subjects, and edges whose ends sit in different subjects.
    /// One pass over concepts + edges (linear).
    func crossSubjectLinks(limit: Int = 12) -> [SubjectLink] {
        var via: [String: [String]] = [:]
        func add(_ a: String, _ b: String, _ why: String) {
            guard a != b, a != "general", b != "general" else { return }
            let k = a < b ? "\(a)|\(b)" : "\(b)|\(a)"
            if !(via[k]?.contains(why) ?? false) { via[k, default: []].append(why) }
        }
        let cs = all()
        for c in cs where c.subjects.count > 1 {
            for i in 0..<c.subjects.count { for j in (i + 1)..<c.subjects.count { add(c.subjects[i], c.subjects[j], c.name) } }
        }
        for e in edges() {
            guard let s = concept(e.src), let d = concept(e.dst) else { continue }
            for a in s.subjects where !d.subjects.contains(a) {
                for b in d.subjects where !s.subjects.contains(b) {
                    add(a, b, e.rel == .prerequisite ? "\(s.name) needs \(d.name)" : "\(s.name) ~ \(d.name)")
                }
            }
        }
        return via.map { k, v in let p = k.split(separator: "|").map(String.init); return SubjectLink(a: p[0], b: p[1], via: v) }
            .sorted { $0.via.count != $1.via.count ? $0.via.count > $1.via.count : $0.a + $0.b < $1.a + $1.b }
            .prefix(limit).map { $0 }
    }

    /// Concepts named in `text`: strength 1 when every stem of a name/alias appears, partial for long names.
    func route(_ text: String) -> [Int64: Double] {
        let q = Set(MemoryText.stems(text, limit: 64))
        guard !q.isEmpty else { return [:] }
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        var cands = Set<Int64>()
        for s in q { cands.formUnion(postings[s] ?? []) }
        var out: [Int64: Double] = [:]
        for id in cands {
            for st in keyStems[id] ?? [] {
                let cov = Double(st.intersection(q).count) / Double(st.count)
                let strength = cov >= 1 ? 1 : (st.count >= 3 && cov >= 0.66 ? cov * 0.8 : 0)
                if strength > (out[id] ?? 0) { out[id] = strength }
            }
        }
        return out.filter { $0.value > 0 }
    }

    // MARK: Writes

    /// Creates or reinforces a concept (matched by normalised name/alias) and merges its subject tags.
    @discardableResult
    func upsert(name raw: String, subjects: [String] = [], summary: String? = nil, status: String? = nil,
                origin: String = "inferred", source: String? = nil) -> Int64? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = MemoryText.conceptKey(name)
        guard !key.isEmpty, name.count <= 80 else { return nil }
        let now = Date()
        let id: Int64
        if let existing = find(name) {
            id = existing
            try? db.execute("UPDATE concepts SET evidence=evidence+1, updated_at=?, summary=COALESCE(?, summary), status=COALESCE(?, status) WHERE id=?",
                            now, summary.map { MemoryText.clip($0, 240) }, Self.status(status), id)
        } else {
            try? db.execute("INSERT INTO concepts(name, summary, status, origin, source, created_at, updated_at) VALUES(?,?,?,?,?,?,?)",
                            name, summary.map { MemoryText.clip($0, 240) }, Self.status(status), origin, source, now, now)
            id = db.lastInsertRowID
            try? db.execute("INSERT OR IGNORE INTO concept_aliases(norm, concept_id) VALUES(?,?)", key, id)
        }
        for s in subjects.compactMap(MemoryText.subject) where s != "general" {
            try? db.execute("INSERT OR IGNORE INTO concept_subjects(concept_id, subject) VALUES(?,?)", id, s)
        }
        reload()
        return id
    }

    static func status(_ s: String?) -> String? {
        guard let s = s?.lowercased() else { return nil }
        if ["struggling", "weak", "confused"].contains(s) { return "struggling" }
        if ["solid", "mastered", "strong", "known"].contains(s) { return "solid" }
        if ["learning", "practising", "practicing", "developing", "new"].contains(s) { return "learning" }
        return nil
    }

    func addAlias(_ id: Int64, _ name: String) {
        let k = MemoryText.conceptKey(name)
        guard !k.isEmpty else { return }
        try? db.execute("INSERT OR IGNORE INTO concept_aliases(norm, concept_id) VALUES(?,?)", k, id)
        reload()
    }

    func link(_ src: Int64, _ dst: Int64, _ rel: ConceptRelation) {
        guard src != dst else { return }
        // Prerequisite edges must not form a 2-cycle (A needs B and B needs A): keep the newest claim.
        if rel == .prerequisite { try? db.execute("DELETE FROM concept_edges WHERE src=? AND dst=? AND rel='prereq'", dst, src) }
        try? db.execute("INSERT OR IGNORE INTO concept_edges(src, dst, rel, created_at) VALUES(?,?,?,?)", src, dst, rel.rawValue, Date())
    }
    func unlink(_ src: Int64, _ dst: Int64) { try? db.execute("DELETE FROM concept_edges WHERE (src=? AND dst=?) OR (src=? AND dst=?)", src, dst, dst, src) }

    func update(_ id: Int64, name: String? = nil, summary: String? = nil, status: String? = nil, subjects: [String]? = nil) {
        if let name, !name.trimmingCharacters(in: .whitespaces).isEmpty {
            try? db.execute("UPDATE concepts SET name=? WHERE id=?", name.trimmingCharacters(in: .whitespaces), id)
            try? db.execute("INSERT OR IGNORE INTO concept_aliases(norm, concept_id) VALUES(?,?)", MemoryText.conceptKey(name), id)
        }
        if let summary { try? db.execute("UPDATE concepts SET summary=? WHERE id=?", summary.isEmpty ? nil : summary, id) }
        if let s = Self.status(status) { try? db.execute("UPDATE concepts SET status=? WHERE id=?", s, id) }
        if let subjects {
            try? db.execute("DELETE FROM concept_subjects WHERE concept_id=?", id)
            for s in subjects.compactMap(MemoryText.subject) { try? db.execute("INSERT OR IGNORE INTO concept_subjects(concept_id, subject) VALUES(?,?)", id, s) }
        }
        try? db.execute("UPDATE concepts SET updated_at=? WHERE id=?", Date(), id)
        reload()
    }

    /// Merges `from` concepts into `into`: aliases, subjects, edges and evidence move; memories are re-pointed by the caller.
    func merge(into: Int64, from: [Int64]) {
        for f in from where f != into {
            try? db.execute("UPDATE OR IGNORE concept_aliases SET concept_id=? WHERE concept_id=?", into, f)
            try? db.execute("INSERT OR IGNORE INTO concept_subjects(concept_id, subject) SELECT ?, subject FROM concept_subjects WHERE concept_id=?", into, f)
            try? db.execute("INSERT OR IGNORE INTO concept_edges(src, dst, rel, created_at) SELECT ?, dst, rel, created_at FROM concept_edges WHERE src=? AND dst!=?", into, f, into)
            try? db.execute("INSERT OR IGNORE INTO concept_edges(src, dst, rel, created_at) SELECT src, ?, rel, created_at FROM concept_edges WHERE dst=? AND src!=?", into, f, into)
            try? db.execute("UPDATE concepts SET evidence=evidence+(SELECT evidence FROM concepts WHERE id=?) WHERE id=?", f, into)
            // Keep the better mastery evidence.
            try? db.execute("""
                UPDATE concepts SET p_known=(SELECT p_known FROM concepts WHERE id=?), attempts=(SELECT attempts FROM concepts WHERE id=?),
                correct=(SELECT correct FROM concepts WHERE id=?), mastery_at=(SELECT mastery_at FROM concepts WHERE id=?)
                WHERE id=? AND COALESCE((SELECT mastery_at FROM concepts WHERE id=?), 0) > COALESCE(mastery_at, 0)
                """, f, f, f, f, into, f)
            deleteRow(f)
        }
        reload()
    }

    private func deleteRow(_ id: Int64) {
        try? db.execute("DELETE FROM concept_aliases WHERE concept_id=?", id)
        try? db.execute("DELETE FROM concept_subjects WHERE concept_id=?", id)
        try? db.execute("DELETE FROM concept_edges WHERE src=? OR dst=?", id, id)
        try? db.execute("DELETE FROM concepts WHERE id=?", id)
    }
    func delete(_ id: Int64) {
        deleteRow(id)
        try? db.execute("UPDATE memories SET concept_id=NULL WHERE concept_id=?", id)
        reload()
    }
    func deleteAll() {
        try? db.script("DELETE FROM concept_edges; DELETE FROM concept_subjects; DELETE FROM concept_aliases; DELETE FROM concepts;")
        MemorySchema.setMeta(db, "mastery_sync", "0")
        reload()
    }

    // MARK: Mastery (StudyStore stays the source of truth)

    /// Incremental: only mastery rows changed since the last sync are read. Unknown concepts become nodes
    /// tagged with the mastery subject, so quizzes populate the learner model automatically.
    @discardableResult
    func syncMastery() -> Int {
        let mark = Double(MemorySchema.meta(db, "mastery_sync") ?? "0") ?? 0
        let rows = (try? db.query("SELECT * FROM mastery WHERE updated_at > ? ORDER BY updated_at", mark)) ?? []
        guard !rows.isEmpty else { return 0 }
        var newest = mark
        for r in rows {
            guard let name = r.string("concept"), let at = r.double("updated_at") else { continue }
            let subject = r.string("subject")
            let id = find(name) ?? upsert(name: name, subjects: subject.map { [$0] } ?? [], origin: "mastery")
            guard let id else { continue }
            if let s = subject, s != "general" { try? db.execute("INSERT OR IGNORE INTO concept_subjects(concept_id, subject) VALUES(?,?)", id, s) }
            try? db.execute("""
                UPDATE concepts SET p_known=?, attempts=?, correct=?, mastery_at=?, updated_at=MAX(updated_at, ?)
                WHERE id=? AND COALESCE(mastery_at, 0) <= ?
                """, r.double("p_known"), r.int("attempts") ?? 0, r.int("correct") ?? 0, at, at, id, at)
            newest = max(newest, at)
        }
        MemorySchema.setMeta(db, "mastery_sync", String(newest))
        reload()
        return rows.count
    }

    /// A qualitative estimate from a lesson becomes a BKT prior — but never overrides real quiz evidence.
    func estimate(_ id: Int64, level: Double) {
        guard let c = concept(id), c.attempts == 0 else { return }
        StudyStore(db: db).setMastery(subject: c.subjects.first ?? "general", concept: c.name, level: level, note: "estimated from a lesson")
        syncMastery()
    }
}
