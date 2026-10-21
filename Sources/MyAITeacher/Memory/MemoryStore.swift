import Foundation

/// Schema additions for the learner model. Idempotent; runs on every open (old databases are migrated in place).
enum MemorySchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS memory_history(id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id INTEGER NOT NULL, content TEXT NOT NULL,
        change TEXT NOT NULL, source TEXT, changed_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS memory_history_m ON memory_history(memory_id);
    CREATE TABLE IF NOT EXISTS memory_meta(key TEXT PRIMARY KEY, value TEXT);
    CREATE INDEX IF NOT EXISTS memories_kind ON memories(archived, kind);
    """
    static let columns: [(String, String)] = [
        ("concept_id", "INTEGER"), ("evidence", "INTEGER NOT NULL DEFAULT 1"), ("status", "TEXT"), ("norm", "TEXT"),
    ]

    static func migrate(_ db: Database) {
        let have = Set(((try? db.query("PRAGMA table_info(memories)")) ?? []).compactMap { $0.string("name") })
        for (c, t) in columns where !have.contains(c) { try? db.execute("ALTER TABLE memories ADD COLUMN \(c) \(t)") }
        try? db.script(sql)
        try? db.script("CREATE INDEX IF NOT EXISTS memories_concept ON memories(concept_id)")
    }

    static func meta(_ db: Database, _ key: String) -> String? {
        (try? db.query("SELECT value FROM memory_meta WHERE key=?", key))?.first?.string("value")
    }
    static func setMeta(_ db: Database, _ key: String, _ value: String) {
        try? db.execute("INSERT INTO memory_meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value)
    }
    static func dataVersion(_ db: Database) -> Int { (try? db.query("PRAGMA data_version"))?.first?.int("data_version") ?? 0 }
}

/// Tunables for retrieval and dedup (calibrated in `MemoryQualityTests`).
enum MemoryTuning {
    /// Lexical evidence saturates: 1 − exp(−Σ normalised-IDF / lexK).
    nonisolated(unsafe) static var lexK = 1.0
    /// Cosine below semLow carries no evidence; at semHigh it is full evidence (NLEmbedding cosines are compressed).
    nonisolated(unsafe) static var semLow = 0.55
    nonisolated(unsafe) static var semHigh = 0.9
    /// Weight of semantic evidence inside the noisy-OR (it is the weakest signal).
    nonisolated(unsafe) static var semWeight = 0.5
    /// Concept-routing evidence for memories attached to a concept named in the query.
    nonisolated(unsafe) static var conceptWeight = 0.6
    /// Per-turn automatic recall threshold on relevance.
    nonisolated(unsafe) static var recallThreshold = 0.65
    /// Threshold for explicit `memory` search.
    nonisolated(unsafe) static var searchThreshold = 0.4
}

/// One memory table with an in-memory index (postings, normalised vectors, LSH buckets, exact-norm buckets)
/// rebuilt from SQLite on open and whenever another connection changes the database.
final class MemoryStore: @unchecked Sendable {
    let db: Database
    let scope: MemoryScope
    /// The concept graph (learner scope only — concepts follow the learner).
    let graph: ConceptGraph?

    private struct Doc {
        var memory: Memory
        var stems: Set<String>
        var vector: [Float]?
        var norm: String
        var lsh: [Int64]
    }
    private let lock = NSRecursiveLock()
    private var docs: [Int64: Doc] = [:]
    private var postings: [String: Set<Int64>] = [:]
    private var byNorm: [String: Int64] = [:]
    private var buckets: [Int64: Set<Int64>] = [:]
    private var loadedVersion: Int?

    init(db: Database, scope: MemoryScope) {
        self.db = db
        self.scope = scope
        MemorySchema.migrate(db)
        graph = scope == .learner ? ConceptGraph(db: db) : nil
    }

    // MARK: Rows & index

    private func row(_ r: Row) -> Memory? {
        guard let id = r.int("id"), let k = r.string("kind").flatMap(MemoryKind.init(rawValue:)), let c = r.string("content") else { return nil }
        return Memory(rowid: Int64(id), scope: scope, kind: k, subject: r.string("subject"), content: c, importance: r.double("importance") ?? 0.5,
                      confidence: r.double("confidence") ?? 0.8, origin: r.string("origin") ?? "inferred", source: r.string("source"),
                      createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date(), lastUsedAt: r.date("last_used_at"),
                      useCount: r.int("use_count") ?? 0, conceptID: r.int("concept_id").map(Int64.init), evidence: r.int("evidence") ?? 1)
    }

    private func indexText(_ m: Memory) -> String { m.content + " " + (m.subject ?? "") }

    private func makeDoc(_ m: Memory, vector raw: [Float]?) -> Doc {
        let v = raw.map(Embedder.normalized)
        return Doc(memory: m, stems: Set(MemoryText.stems(indexText(m))), vector: v, norm: MemoryText.norm(m.content), lsh: v.map(VectorLSH.keys) ?? [])
    }

    private func insertDoc(_ d: Doc) {
        let id = d.memory.rowid
        removeDoc(id)
        docs[id] = d
        for s in d.stems { postings[s, default: []].insert(id) }
        if !d.norm.isEmpty { byNorm[d.memory.kind.rawValue + "|" + d.norm] = id }
        for k in d.lsh { buckets[k, default: []].insert(id) }
    }

    private func removeDoc(_ id: Int64) {
        guard let d = docs.removeValue(forKey: id) else { return }
        for s in d.stems { postings[s]?.remove(id); if postings[s]?.isEmpty == true { postings[s] = nil } }
        let nk = d.memory.kind.rawValue + "|" + d.norm
        if byNorm[nk] == id { byNorm[nk] = nil }
        for k in d.lsh { buckets[k]?.remove(id); if buckets[k]?.isEmpty == true { buckets[k] = nil } }
    }

    /// Loads (or reloads after an external write) the index. O(N) only when the DB changed elsewhere.
    private func ensureLoaded() {
        let v = MemorySchema.dataVersion(db)
        if loadedVersion == v { return }
        docs = [:]; postings = [:]; byNorm = [:]; buckets = [:]
        for r in (try? db.query("SELECT * FROM memories WHERE archived=0")) ?? [] {
            guard let m = row(r) else { continue }
            let e = r.data("embedding").flatMap { $0.isEmpty ? nil : Embedder.decode($0) }
            insertDoc(makeDoc(m, vector: e))
        }
        loadedVersion = v
    }

    private func refresh(_ id: Int64, vector: [Float]? = nil) {
        guard let r = try? db.query("SELECT * FROM memories WHERE id=?", id).first, let m = row(r), r.int("archived") == 0 else {
            lock.lock(); removeDoc(id); lock.unlock(); return
        }
        let e = vector ?? r.data("embedding").flatMap { $0.isEmpty ? nil : Embedder.decode($0) }
        let d = makeDoc(m, vector: e)
        lock.lock(); ensureLoaded(); insertDoc(d); lock.unlock()
    }

    // MARK: Reads

    func all() -> [Memory] {
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let order = Dictionary(uniqueKeysWithValues: MemoryKind.allCases.enumerated().map { ($1, $0) })
        return docs.values.map(\.memory).sorted {
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }
    }
    func count() -> Int { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return docs.count }
    func get(_ id: Int64) -> Memory? { (try? db.query("SELECT * FROM memories WHERE id=?", id))?.first.flatMap(row) }
    func memories(kind: MemoryKind) -> [Memory] { all().filter { $0.kind == kind } }
    func memories(conceptID: Int64) -> [Memory] {
        ((try? db.query("SELECT * FROM memories WHERE archived=0 AND concept_id=? ORDER BY importance DESC", conceptID)) ?? []).compactMap(row)
    }
    func history(_ id: Int64) -> [MemoryHistoryEntry] {
        ((try? db.query("SELECT * FROM memory_history WHERE memory_id=? ORDER BY changed_at DESC", id)) ?? []).map {
            MemoryHistoryEntry(content: $0.string("content") ?? "", change: $0.string("change") ?? "", source: $0.string("source"), date: $0.date("changed_at") ?? Date())
        }
    }

    // MARK: Writes

    /// Removes listing labels a model may echo back ("[#12] (profile, arabic) …").
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"^\s*[-•]?\s*(\[#?[fc]?\d+\]|#[fc]?\d+\b)\s*(\([^)]*\)\s*)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    struct WriteOutcome { var rowid: Int64?; var status: MemoryWriteResult.Status; var reason: String?; var similar: [Int64] }

    /// Adds a memory unless it is not durable or duplicates an existing one (then the existing one is reinforced).
    /// Cost: O(candidates) — exact-norm bucket, shared rare terms and LSH buckets — never a scan of all memories.
    @discardableResult
    func add(kind: MemoryKind, content raw: String, subject: String?, importance: Double, origin: String, source: String?,
             conceptID: Int64? = nil) -> WriteOutcome {
        let content = MemoryText.clip(Self.clean(raw), 400)
        if let why = MemoryPolicy.rejection(content, kind: kind, explicit: origin == "explicit") {
            return WriteOutcome(rowid: nil, status: .rejected, reason: why, similar: [])
        }
        let subject = MemoryText.subject(subject)
        let vec = Embedder.shared.vector(content).map(Embedder.normalized)
        let stems = Set(MemoryText.stems(content + " " + (subject ?? "")))
        let norm = MemoryText.norm(content)

        lock.lock()
        ensureLoaded()
        var dup: Int64? = byNorm[kind.rawValue + "|" + norm]
        var similar: [(Int64, Double)] = []
        if dup == nil {
            var cands = Set<Int64>()
            let n = max(1, docs.count)
            for s in stems { if let p = postings[s], p.count <= max(50, n / 5) { cands.formUnion(p) } }
            if let vec { for k in VectorLSH.keys(vec) { cands.formUnion(buckets[k] ?? []) } }
            var best: (Int64, Double)?
            for id in cands {
                guard let d = docs[id], d.memory.kind == kind else { continue }
                let jac = MemoryText.jaccard(stems, d.stems)
                let cos = (vec != nil && d.vector != nil) ? Double(Embedder.dot(vec!, d.vector!)) : 0
                // A refinement (one side's terms contain the other's) is the same fact stated more specifically.
                let small = min(stems.count, d.stems.count)
                let refines = small >= 3 && jac >= 0.5 && (stems.isSubset(of: d.stems) || d.stems.isSubset(of: stems))
                let isDup = jac >= 0.8 || refines || (cos >= 0.93 && jac >= 0.5) || cos >= 0.985
                if isDup, jac + cos > (best?.1 ?? -1) { best = (id, jac + cos) }
                else if jac >= 0.34 || cos >= 0.86 { similar.append((id, jac + cos)) }
            }
            dup = best?.0
        }
        let existing = dup.flatMap { docs[$0]?.memory }
        lock.unlock()

        let now = Date()
        if let old = existing {
            // Same fact restated. A change of number, of negation, or of words the normaliser ignores (15 → 16 years old,
            // "prefers" → "does not prefer", AB → BC) is an update: the newer text wins and the old one goes to history.
            // Otherwise keep the more specific text: the new one if it covers the old one's terms or is longer.
            let oldStems = Set(MemoryText.stems(old.content))
            let takeNew = MemoryText.isUpdate(content, of: old.content)
                || oldStems.isSubset(of: stems) && content != old.content || content.count > old.content.count + 10
            let newContent = takeNew ? content : old.content
            if takeNew { recordHistory(old.rowid, content: old.content, change: "merged", source: source) }
            try? db.execute("""
                UPDATE memories SET content=?, importance=?, updated_at=?, evidence=evidence+1, concept_id=COALESCE(?, concept_id),
                subject=COALESCE(subject, ?), norm=?, embedding=COALESCE(?, embedding) WHERE id=?
                """, newContent, max(importance, old.importance), now, conceptID, subject, MemoryText.norm(newContent),
                takeNew ? vec.map(Embedder.encode) : nil, old.rowid)
            refresh(old.rowid)
            return WriteOutcome(rowid: old.rowid, status: .merged, reason: nil, similar: [])
        }
        try? db.execute("""
            INSERT INTO memories(kind, subject, content, importance, origin, source, created_at, updated_at, embedding, concept_id, norm, evidence)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,1)
            """, kind.rawValue, subject, content, min(1, max(0, importance)), origin, source, now, now, vec.map(Embedder.encode), conceptID, norm)
        let id = db.lastInsertRowID
        refresh(id, vector: vec)
        return WriteOutcome(rowid: id, status: .added, reason: nil, similar: similar.sorted { $0.1 > $1.1 }.prefix(3).map(\.0))
    }

    private func recordHistory(_ id: Int64, content: String, change: String, source: String?) {
        try? db.execute("INSERT INTO memory_history(memory_id, content, change, source, changed_at) VALUES(?,?,?,?,?)", id, content, change, source, Date())
    }

    func update(_ id: Int64, content: String? = nil, importance: Double? = nil, kind: MemoryKind? = nil, subject: String? = nil,
                conceptID: Int64?? = nil, source: String? = nil) {
        guard var m = get(id) else { return }
        var newVec: [Float]?
        if let content, !Self.clean(content).isEmpty, Self.clean(content) != m.content {
            recordHistory(id, content: m.content, change: "updated", source: source)
            m.content = MemoryText.clip(Self.clean(content), 400)
            newVec = Embedder.shared.vector(m.content)
        }
        if let importance { m.importance = min(1, max(0, importance)) }
        if let kind { m.kind = kind }
        if let subject { m.subject = MemoryText.subject(subject) }
        if let conceptID { m.conceptID = conceptID }
        try? db.execute("UPDATE memories SET content=?, importance=?, kind=?, subject=?, concept_id=?, updated_at=?, norm=?, embedding=COALESCE(?, embedding) WHERE id=?",
                        m.content, m.importance, m.kind.rawValue, m.subject, m.conceptID, Date(), MemoryText.norm(m.content),
                        newVec.map(Embedder.encode), id)
        refresh(id, vector: newVec)
    }

    /// Soft-removes a memory (kept with its history for provenance, excluded everywhere else).
    func archive(_ id: Int64, status: String, source: String? = nil) {
        if let m = get(id) { recordHistory(id, content: m.content, change: status, source: source) }
        try? db.execute("UPDATE memories SET archived=1, status=?, updated_at=? WHERE id=?", status, Date(), id)
        lock.lock(); removeDoc(id); lock.unlock()
    }

    func delete(_ id: Int64) {
        try? db.execute("DELETE FROM memories WHERE id=?", id)
        try? db.execute("DELETE FROM memory_history WHERE memory_id=?", id)
        lock.lock(); removeDoc(id); lock.unlock()
    }
    func deleteAll() {
        try? db.execute("DELETE FROM memories")
        try? db.execute("DELETE FROM memory_history")
        graph?.deleteAll()
        lock.lock(); docs = [:]; postings = [:]; byNorm = [:]; buckets = [:]; lock.unlock()
    }
    func markUsed(_ ids: [Int64]) {
        let now = Date()
        for id in ids { try? db.execute("UPDATE memories SET use_count=use_count+1, last_used_at=? WHERE id=?", now, id) }
        lock.lock()
        for id in ids { docs[id]?.memory.useCount += 1; docs[id]?.memory.lastUsedAt = now }
        lock.unlock()
    }
    /// Re-points memories from merged concepts.
    func reassignConcept(from: [Int64], to: Int64?) {
        for f in from { try? db.execute("UPDATE memories SET concept_id=? WHERE concept_id=?", to, f) }
        lock.lock()
        for (id, d) in docs where d.memory.conceptID.map(from.contains) == true { docs[id]?.memory.conceptID = to }
        lock.unlock()
    }

    // MARK: Retrieval

    /// Hybrid relevance with three independent evidence sources combined by noisy-OR:
    /// lexical (IDF-weighted shared stems), semantic (rescaled cosine, down-weighted) and concept routing.
    /// `minRelevance` applies to pure relevance; ranking adds small importance/recency priors.
    func search(_ query: String, limit: Int, kinds: [MemoryKind]? = nil, minRelevance: Double,
                conceptBoost: [Int64: Double] = [:], queryVector: [Float]? = nil) -> [Memory] {
        let qStems = MemoryText.stems(query, limit: 24)
        let qv = queryVector ?? Embedder.shared.vector(query).map(Embedder.normalized)
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        let n = Double(max(1, docs.count))
        var lexSum: [Int64: Double] = [:]
        for s in qStems {
            guard let p = postings[s] else { continue }
            let idf = log(1 + n / Double(p.count)) / log(1 + n)
            for id in p { lexSum[id, default: 0] += idf }
        }
        var cos: [Int64: Double] = [:]
        if let qv {
            for (id, d) in docs { if let v = d.vector { let c = Double(Embedder.dot(qv, v)); if c > MemoryTuning.semLow { cos[id] = c } } }
        }
        var cands = Set(lexSum.keys).union(cos.keys)
        if !conceptBoost.isEmpty { for (id, d) in docs where d.memory.conceptID.map({ conceptBoost[$0] != nil }) == true { cands.insert(id) } }
        let now = Date()
        var out: [Memory] = []
        for id in cands {
            guard let d = docs[id] else { continue }
            if let kinds, !kinds.contains(d.memory.kind) { continue }
            let lex = 1 - exp(-(lexSum[id] ?? 0) / MemoryTuning.lexK)
            let sem = min(1, max(0, ((cos[id] ?? 0) - MemoryTuning.semLow) / (MemoryTuning.semHigh - MemoryTuning.semLow)))
            let con = d.memory.conceptID.flatMap { conceptBoost[$0] } ?? 0
            let rel = 1 - (1 - lex) * (1 - MemoryTuning.semWeight * sem) * (1 - MemoryTuning.conceptWeight * con)
            guard rel >= minRelevance else { continue }
            var m = d.memory
            m.relevance = rel
            let recency = exp(-now.timeIntervalSince(m.updatedAt) / 86400 / 60)
            m.score = rel * 0.8 + m.importance * 0.12 + recency * 0.08
            out.append(m)
        }
        out.sort { $0.score > $1.score }
        return Array(out.prefix(limit))
    }

    // MARK: Core block & maintenance

    /// The best `limit` items by `before`, in one pass with a small sorted buffer — no sort of every memory (this runs
    /// at every lesson start; with 100k memories a full sort per call cost seconds).
    private func best(_ limit: Int, where keep: (Memory) -> Bool, before: (Memory, Memory) -> Bool) -> [Memory] {
        guard limit > 0 else { return [] }
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        var out: [Memory] = []
        out.reserveCapacity(limit + 1)
        for d in docs.values where keep(d.memory) {
            let m = d.memory
            if out.count == limit, let last = out.last, !before(m, last) { continue }
            let i = out.firstIndex { before(m, $0) } ?? out.count
            out.insert(m, at: i)
            if out.count > limit { out.removeLast() }
        }
        return out
    }
    func top(kinds: [MemoryKind], limit: Int) -> [Memory] {
        let ks = Set(kinds)
        return best(limit, where: { ks.contains($0.kind) }) { $0.importance != $1.importance ? $0.importance > $1.importance : $0.updatedAt > $1.updatedAt }
    }
    func recentEpisodes(limit: Int) -> [Memory] {
        best(limit, where: { $0.kind == .episode }) { $0.createdAt > $1.createdAt }
    }

    struct MaintenanceReport { var decayed = 0, archived = 0, merged = 0 }

    /// Local, deterministic consolidation ("sleep-time"): decay unused inferred items, archive faded ones,
    /// cap episode history, and merge exact/near duplicates that slipped in (each check uses the index — O(N·k)).
    @discardableResult
    func maintenance(now: Date = Date()) -> MaintenanceReport {
        var rep = MaintenanceReport()
        let t = now.timeIntervalSince1970
        rep.decayed = (try? db.execute("""
            UPDATE memories SET importance = MAX(0.05, importance * 0.9) WHERE archived=0 AND origin != 'explicit'
            AND kind IN ('fact','knowledge','misconception','episode') AND COALESCE(last_used_at, updated_at) < ?
            """, t - 90 * 86400)) ?? 0
        let faded = ((try? db.query("SELECT id FROM memories WHERE archived=0 AND origin != 'explicit' AND importance < 0.15 AND COALESCE(last_used_at, updated_at) < ?", t - 180 * 86400)) ?? []).compactMap { $0.int("id") }
        for id in faded { archive(Int64(id), status: "faded") }
        rep.archived += faded.count
        let oldEpisodes = ((try? db.query("SELECT id FROM memories WHERE archived=0 AND kind='episode' ORDER BY created_at DESC LIMIT -1 OFFSET 30")) ?? []).compactMap { $0.int("id") }
        for id in oldEpisodes { archive(Int64(id), status: "rolled-up") }
        rep.archived += oldEpisodes.count
        // Duplicate sweep using the same candidate machinery as `add`.
        lock.lock(); ensureLoaded()
        let snapshot = docs
        lock.unlock()
        var gone = Set<Int64>()
        for (id, d) in snapshot.sorted(by: { $0.key < $1.key }) where !gone.contains(id) {
            var cands = Set<Int64>()
            lock.lock()
            for s in d.stems { if let p = postings[s], p.count <= 50 { cands.formUnion(p) } }
            for k in d.lsh { cands.formUnion(buckets[k] ?? []) }
            lock.unlock()
            for c in cands where c > id && !gone.contains(c) {
                guard let o = snapshot[c], o.memory.kind == d.memory.kind else { continue }
                let jac = MemoryText.jaccard(d.stems, o.stems)
                let cs = (d.vector != nil && o.vector != nil) ? Double(Embedder.dot(d.vector!, o.vector!)) : 0
                guard d.norm == o.norm || jac >= 0.8 || (cs >= 0.95 && jac >= 0.5) else { continue }
                // Keep the older id (stable references); absorb the newer one's evidence.
                let keepNew = o.memory.content.count > d.memory.content.count
                if keepNew { try? db.execute("UPDATE memories SET content=?, norm=?, embedding=(SELECT embedding FROM memories WHERE id=?) WHERE id=?", o.memory.content, o.norm, c, id) }
                try? db.execute("UPDATE memories SET evidence=evidence+?, importance=MAX(importance, ?) WHERE id=?", o.memory.evidence, o.memory.importance, id)
                archive(c, status: "merged into #\(id)")
                if keepNew { refresh(id) }
                gone.insert(c); rep.merged += 1
            }
        }
        return rep
    }

    /// Test/bench helper: inserts many rows quickly with precomputed vectors (no policy, no dedup).
    func bulkInsert(_ rows: [(kind: MemoryKind, content: String, subject: String?, vector: [Float]?)]) {
        let now = Date()
        try? db.transaction {
            for r in rows {
                try db.execute("INSERT INTO memories(kind, subject, content, importance, origin, created_at, updated_at, embedding, norm) VALUES(?,?,?,?,?,?,?,?,?)",
                               r.kind.rawValue, r.subject, r.content, 0.5, "inferred", now, now, r.vector.map(Embedder.encode), MemoryText.norm(r.content))
            }
        }
        lock.lock(); loadedVersion = nil; ensureLoaded(); lock.unlock()
    }
}
