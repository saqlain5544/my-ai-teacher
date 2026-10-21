import Foundation
import Accelerate

/// Schema additions for the learner model. Idempotent; runs on every open (old databases are migrated in place).
enum MemorySchema {
    static let sql = """
    CREATE TABLE IF NOT EXISTS memory_history(id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id INTEGER NOT NULL, content TEXT NOT NULL,
        change TEXT NOT NULL, source TEXT, changed_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS memory_history_m ON memory_history(memory_id);
    CREATE TABLE IF NOT EXISTS memory_meta(key TEXT PRIMARY KEY, value TEXT);
    """
    /// This version's indexes (`memories_rank` covers what `memories_kind` did).
    static let indexes = """
    DROP INDEX IF EXISTS memories_kind;
    CREATE INDEX IF NOT EXISTS memories_rank ON memories(archived, kind, importance, updated_at);
    CREATE INDEX IF NOT EXISTS memories_updated ON memories(archived, updated_at);
    CREATE INDEX IF NOT EXISTS memories_norm ON memories(kind, norm) WHERE archived=0;
    """
    static let columns: [(String, String)] = [
        ("concept_id", "INTEGER"), ("evidence", "INTEGER NOT NULL DEFAULT 1"), ("status", "TEXT"), ("norm", "TEXT"),
    ]
    /// Rows this version rewrites: Float32 embeddings (to int8) and rows from before the `norm` column.
    private static let legacy = "(norm IS NULL OR (length(embedding) % 4 = 0 AND length(embedding) > 0))"

    static func migrate(_ db: Database) {
        let have = Set(((try? db.query("PRAGMA table_info(memories)")) ?? []).compactMap { $0.string("name") })
        for (c, t) in columns where !have.contains(c) { try? db.execute("ALTER TABLE memories ADD COLUMN \(c) \(t)") }
        try? db.script(sql)
        try? db.script("CREATE INDEX IF NOT EXISTS memories_concept ON memories(concept_id)")
        // The learner's own data: nothing of this version touches it before a copy exists. Without one (disk full), it
        // stays as it is — Float32 rows still read — and the next open tries again.
        if meta(db, "rows_v2") == nil, (try? db.query("SELECT 1 AS x FROM memories WHERE \(legacy) LIMIT 1"))?.isEmpty == false, !backUp(db) { return }
        try? db.script(indexes)
        if meta(db, "rows_v2") == nil, convert(db) { setMeta(db, "rows_v2", "1") }
    }

    /// The database as it was, copied once beside it (`<db>.pre-int8-<date>.sqlite`) before this version first rewrites
    /// it. The copy is written under a temporary name and renamed, so a crash mid-copy never passes for a backup.
    private static func backUp(_ db: Database) -> Bool {
        guard !db.path.isEmpty, db.path != ":memory:" else { return true }
        let fm = FileManager.default, url = URL(fileURLWithPath: db.path), dir = url.deletingLastPathComponent()
        let prefix = url.lastPathComponent + ".pre-int8-"
        let existing = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
        if existing.contains(where: { $0.hasPrefix(prefix) && $0.hasSuffix(".sqlite") }) { return true }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let final = dir.appendingPathComponent(prefix + day.string(from: Date()) + ".sqlite"), partial = final.appendingPathExtension("partial")
        try? fm.removeItem(at: partial)
        let t0 = Date()
        do {
            try db.execute("VACUUM INTO ?", partial.path)
            try fm.moveItem(at: partial, to: final)
        } catch {
            try? fm.removeItem(at: partial)
            AppLog.write("memory: no backup of \(url.lastPathComponent) (\(error.localizedDescription)); its embeddings stay Float32 until one can be made")
            return false
        }
        AppLog.write(String(format: "memory: backed up %@ to %@ (%.0f ms) before converting it", url.lastPathComponent, final.lastPathComponent, Date().timeIntervalSince(t0) * 1000))
        return true
    }

    /// Float32 embeddings become int8 (a quarter of what the disk path scans) and missing norms are filled in, so
    /// exact-duplicate checks can use `memories_norm`. Each batch commits on its own: a crash leaves whole batches done
    /// and the rest as they were, and the next open carries on. True when every row is done.
    private static func convert(_ db: Database) -> Bool {
        var last = 0, done = 0
        let t0 = Date()
        do {
            while case let rows = try db.query("SELECT id, content, embedding FROM memories WHERE id > ? AND \(legacy) ORDER BY id LIMIT 2048", last),
                  let end = rows.last?.int("id") {
                try db.transaction {
                    for r in rows {
                        let blob = r.data("embedding").flatMap { $0.count % 4 == 0 && !$0.isEmpty ? Embedder.stored(Embedder.decode($0)) : nil }
                        try db.execute("UPDATE memories SET embedding=COALESCE(?, embedding), norm=COALESCE(norm, ?) WHERE id=?",
                                       blob, MemoryText.norm(r.string("content") ?? ""), r.int("id"))
                    }
                }
                last = end; done += rows.count
            }
        } catch {
            AppLog.write("memory: converting \(URL(fileURLWithPath: db.path).lastPathComponent) stopped after \(done) rows (\(error.localizedDescription)); the next open carries on")
            return false
        }
        if done > 0 {
            AppLog.write(String(format: "memory: converted %d rows of %@ (int8 embeddings, norms) in %.0f ms", done, URL(fileURLWithPath: db.path).lastPathComponent, Date().timeIntervalSince(t0) * 1000))
        }
        return true
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
    /// Bytes a store's in-RAM index may use (≈ 40k memories). Past it the store keeps nothing per memory.
    nonisolated(unsafe) static var indexBudget = 32 << 20
}

/// One memory table, indexed for retrieval and dedup. Within `MemoryTuning.indexBudget` the index lives in RAM
/// (`MemoryIndex`, under 1 KB a memory); past it nothing is kept per memory — lexical candidates come from `memories_fts`
/// and vectors stream from the `embedding` column — so the footprint stays flat however many memories there are.
/// Content and subjects stay in SQLite either way; only the rows of results are read. The index is rebuilt on first use
/// and whenever another connection changes the database (`PRAGMA data_version`).
final class MemoryStore: @unchecked Sendable {
    let db: Database
    let scope: MemoryScope
    /// The concept graph (learner scope only — concepts follow the learner).
    let graph: ConceptGraph?

    private let lock = NSRecursiveLock()
    /// nil before the first use, and on the disk path.
    private var index: MemoryIndex?
    private var loadedVersion: Int?
    /// The disk path's vector scans run on their own read-only, memory-mapped connections (opened on first use).
    private var scanners: [Database] = []

    init(db: Database, scope: MemoryScope) {
        self.db = db
        self.scope = scope
        MemorySchema.migrate(db)
        graph = scope == .learner ? ConceptGraph(db: db) : nil
        Self.live.add(self)
    }

    private static let live = WeakRegistry<MemoryStore>()
    /// Frees every index; each rebuilds from the database on its next use (memory pressure: see MemoryGovernor).
    static func unloadAll() { live.all.forEach { $0.unload() } }
    func unload() {
        lock.lock(); defer { lock.unlock() }
        index = nil; loadedVersion = nil; scanners = []
    }
    /// Bytes held by the in-RAM index (0 on the disk path).
    var indexBytes: Int { lock.lock(); defer { lock.unlock() }; ensureLoaded(); return index?.bytes ?? 0 }

    // MARK: Rows & index

    private static let columns = "id, kind, subject, content, importance, confidence, origin, source, created_at, updated_at, last_used_at, use_count, concept_id, evidence"

    private func row(_ r: Row) -> Memory? {
        guard let id = r.int("id"), let k = r.string("kind").flatMap(MemoryKind.init(rawValue:)), let c = r.string("content") else { return nil }
        return Memory(rowid: Int64(id), scope: scope, kind: k, subject: r.string("subject"), content: c, importance: r.double("importance") ?? 0.5,
                      confidence: r.double("confidence") ?? 0.8, origin: r.string("origin") ?? "inferred", source: r.string("source"),
                      createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date(), lastUsedAt: r.date("last_used_at"),
                      useCount: r.int("use_count") ?? 0, conceptID: r.int("concept_id").map(Int64.init), evidence: r.int("evidence") ?? 1)
    }

    /// Active memories by id, in one statement whatever their number (the ids go in as a JSON array).
    private func rows(_ ids: some Collection<Int64>) -> [Memory] {
        guard !ids.isEmpty else { return [] }
        return ((try? db.query("SELECT \(Self.columns) FROM memories WHERE archived=0 AND id IN (SELECT value FROM json_each(?))", Self.json(ids))) ?? []).compactMap(row)
    }
    private static func json(_ ids: some Sequence<Int64>) -> String { "[" + ids.map(String.init).joined(separator: ",") + "]" }
    private static func indexText(_ content: String, _ subject: String?) -> String { content + " " + (subject ?? "") }

    /// Builds the index — or, past the budget, settles on the disk path — when this connection hasn't seen the latest
    /// data. Rows stream in, so loading never holds more than the index itself.
    private func ensureLoaded() {
        let v = MemorySchema.dataVersion(db)
        if loadedVersion == v { return }
        index = nil; loadedVersion = v
        let n = count()
        guard n * MemoryIndex.estimate <= MemoryTuning.indexBudget else { return }
        let ix = MemoryIndex(capacity: n)
        try? db.each("SELECT id, kind, content, subject, importance, updated_at, embedding FROM memories WHERE archived=0") { r in
            if let k = r.text(1).flatMap(MemoryKind.init(rawValue:)) {
                ix.insert(r.int64(0), kind: k.code, importance: r.double(4), updated: r.double(5), text: Self.indexText(r.text(2) ?? "", r.text(3)), vector: r.blob(6))
            }
            return ix.bytes <= MemoryTuning.indexBudget
        }
        if ix.bytes <= MemoryTuning.indexBudget { ix.repack(); index = ix }
    }

    /// Re-indexes one memory after our own write: O(1), not a reload (the disk path has nothing to update).
    private func refresh(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let ix = index else { return }
        ix.remove(id)
        try? db.each("SELECT kind, content, subject, importance, updated_at, embedding FROM memories WHERE id=? AND archived=0", id) { r in
            if let k = r.text(0).flatMap(MemoryKind.init(rawValue:)) {
                ix.insert(id, kind: k.code, importance: r.double(3), updated: r.double(4), text: Self.indexText(r.text(1) ?? "", r.text(2)), vector: r.blob(5))
            }
            return false
        }
        if ix.bytes > MemoryTuning.indexBudget { index = nil }   // the disk path until the next reload
    }

    // MARK: Reads

    func all() -> [Memory] {
        let order = Dictionary(uniqueKeysWithValues: MemoryKind.allCases.enumerated().map { ($1, $0) })
        return ((try? db.query("SELECT \(Self.columns) FROM memories WHERE archived=0")) ?? []).compactMap(row).sorted {
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }
    }
    func count() -> Int { (try? db.query("SELECT count(*) AS n FROM memories WHERE archived=0"))?.first?.int("n") ?? 0 }
    func get(_ id: Int64) -> Memory? { (try? db.query("SELECT \(Self.columns) FROM memories WHERE id=?", id))?.first.flatMap(row) }
    func memories(conceptID: Int64) -> [Memory] {
        ((try? db.query("SELECT \(Self.columns) FROM memories WHERE archived=0 AND concept_id=? ORDER BY importance DESC", conceptID)) ?? []).compactMap(row)
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
    /// Cost: O(candidates) — equal norms, shared rarer terms, near vectors (one pass) — never a read of every row.
    @discardableResult
    func add(kind: MemoryKind, content raw: String, subject: String?, importance: Double, origin: String, source: String?,
             conceptID: Int64? = nil) -> WriteOutcome {
        let content = MemoryText.clip(Self.clean(raw), 400)
        if let why = MemoryPolicy.rejection(content, kind: kind, explicit: origin == "explicit") {
            return WriteOutcome(rowid: nil, status: .rejected, reason: why, similar: [])
        }
        let subject = MemoryText.subject(subject)
        let vec = Embedder.shared.vector(content).map(Embedder.normalized)
        let terms = MemoryText.terms(Self.indexText(content, subject))
        let norm = MemoryText.norm(content)

        lock.lock()
        ensureLoaded()
        var dup = sameNorm(kind, norm).first
        var similar: [(Int64, Double)] = []
        if dup == nil {
            let n = index?.live ?? count()
            var cands = Set(lexical(terms, maxDF: max(50, n / 5), limit: 256, n: n).ids.keys)
            if let vec { cands.formUnion(near([(0, kind.code, vec)], minCos: 0.86, cap: 64)[0]) }
            let mine = keys(terms.map(\.stem))
            var best: (Int64, Double)?
            for (id, p) in probes(cands) where p.kind == kind.code {
                let shared = Self.overlap(mine, p.stems), jac = Double(shared) / Double(terms.count + p.stems.count - shared)
                let cos = vec.map { Double(Embedder.dot($0, p.vector)) } ?? 0   // float · int8
                // A refinement (one side's terms contain the other's) is the same fact stated more specifically.
                let refines = min(terms.count, p.stems.count) >= 3 && jac >= 0.5 && (shared == terms.count || shared == p.stems.count)
                let isDup = jac >= 0.8 || refines || (cos >= 0.93 && jac >= 0.5) || cos >= 0.985
                if isDup, jac + cos > (best?.1 ?? -1) { best = (id, jac + cos) }
                else if jac >= 0.34 || cos >= 0.86 { similar.append((id, jac + cos)) }
            }
            dup = best?.0
        }
        lock.unlock()
        let existing = dup.flatMap(get)

        let now = Date()
        if let old = existing {
            // Same fact restated. A change of number, of negation, or of words the normaliser ignores (15 → 16 years old,
            // "prefers" → "does not prefer", AB → BC) is an update: the newer text wins and the old one goes to history.
            // Otherwise keep the more specific text: the new one if it covers the old one's terms or is longer.
            let oldStems = Set(MemoryText.stems(old.content))
            let takeNew = MemoryText.isUpdate(content, of: old.content)
                || oldStems.isSubset(of: Set(terms.map(\.stem))) && content != old.content || content.count > old.content.count + 10
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
        refresh(id)
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
        refresh(id)
    }

    /// Soft-removes a memory (kept with its history for provenance, excluded everywhere else).
    func archive(_ id: Int64, status: String, source: String? = nil) {
        if let m = get(id) { recordHistory(id, content: m.content, change: status, source: source) }
        try? db.execute("UPDATE memories SET archived=1, status=?, updated_at=? WHERE id=?", status, Date(), id)
        lock.lock(); index?.remove(id); lock.unlock()
    }

    func delete(_ id: Int64) {
        try? db.execute("DELETE FROM memories WHERE id=?", id)
        try? db.execute("DELETE FROM memory_history WHERE memory_id=?", id)
        lock.lock(); index?.remove(id); lock.unlock()
    }
    func deleteAll() {
        try? db.execute("DELETE FROM memories")
        try? db.execute("DELETE FROM memory_history")
        graph?.deleteAll()
        lock.lock(); index = nil; loadedVersion = nil; lock.unlock()
    }
    func markUsed(_ ids: [Int64]) {
        let now = Date()
        for id in ids { try? db.execute("UPDATE memories SET use_count=use_count+1, last_used_at=? WHERE id=?", now, id) }
    }
    /// Re-points memories from merged concepts.
    func reassignConcept(from: [Int64], to: Int64?) {
        for f in from { try? db.execute("UPDATE memories SET concept_id=? WHERE concept_id=?", to, f) }
    }

    // MARK: Retrieval

    /// Hybrid relevance with three independent evidence sources combined by noisy-OR:
    /// lexical (IDF-weighted shared stems), semantic (rescaled cosine, down-weighted) and concept routing.
    /// `minRelevance` applies to pure relevance; ranking adds small importance/recency priors.
    func search(_ query: String, limit: Int, kinds: [MemoryKind]? = nil, minRelevance: Double,
                conceptBoost: [Int64: Double] = [:], queryVector: [Float]? = nil) -> [Memory] {
        let terms = MemoryText.terms(query, limit: 24)
        let qv = queryVector ?? Embedder.shared.vector(query).map(Embedder.normalized)
        let allowed = kinds.map { Set($0.map(\.code)) }
        let members = conceptMembers(conceptBoost)
        let now = Date().timeIntervalSinceReferenceDate
        lock.lock(); defer { lock.unlock() }
        ensureLoaded()
        if let ix = index {
            // Exact: every memory sharing a stem, every cosine above semLow, every memory on a routed concept. The index's
            // ranking fields pick the best `limit`; their rows then give the exact scores.
            let n = Double(max(1, ix.live))
            var lex = [Double](repeating: 0, count: ix.ids.count), cos = [Float](repeating: 0, count: ix.ids.count)
            for t in terms {
                guard let s = ix.vocab[t.stem], case let p = ix.postings[Int(s)], !p.isEmpty else { continue }
                let idf = log(1 + n / Double(p.count)) / log(1 + n)
                for x in p { lex[Int(x)] += idf }
            }
            if let qv { _ = scan([qv], into: ()) { _, c in for i in 0..<c.count { cos[c.first + i] = c.cos[i] } } }
            var best = TopK<(id: Int64, lex: Double, cos: Double)>(k: limit)
            for s in ix.ids.indices where ix.ids[s] != 0 {
                let id = ix.ids[s], x = Double(cos[s]), con = members[id] ?? 0
                guard lex[s] > 0 || x > MemoryTuning.semLow || con > 0, allowed?.contains(ix.kinds[s]) ?? true else { continue }
                let rel = Self.relevance(lex[s], x, con)
                guard rel >= minRelevance else { continue }
                best.add(Self.score(rel, Double(ix.importance[s]), age: now - Double(ix.updated[s])), (id, lex[s], x))
            }
            let ev = Dictionary(best.items.map { ($0.value.id, ($0.value.lex, $0.value.cos)) }, uniquingKeysWith: { a, _ in a })
            return rank(ev.keys, limit: limit, kinds: kinds, minRelevance: minRelevance, conceptBoost: conceptBoost) { ev[$0.rowid] ?? (0, 0) }
        }
        // Past the budget: rows of the rarer terms (FTS5) and of routed concepts are candidates; one streamed pass over the
        // vectors gives their cosines and the best other matches, admitted on their cosine plus the most the unread common
        // terms could add. Lexical evidence is recounted with our stems from the few rows read at the end.
        let lx = lexical(terms, maxDF: .max, limit: 256, n: count())
        let watch = Set(lx.ids.keys).union(members.keys)
        var cos: [Int64: Double] = [:]
        var best = TopK<(id: Int64, cos: Double)>(k: max(32, limit * 4))
        if let qv {
            let parts = scan([qv], into: (cos: [Int64: Double](), best: best)) { acc, c in
                for i in 0..<c.count {
                    let id = c.ids[i], x = Double(c.cos[i])
                    if watch.contains(id) { acc.cos[id] = x; continue }
                    guard x > MemoryTuning.semLow || lx.unread > 0, allowed?.contains(c.kinds[i]) ?? true else { continue }
                    let rel = Self.relevance(lx.unread, x, 0)
                    if rel >= minRelevance { acc.best.add(Self.score(rel, Double(c.importance[i]), age: now - Double(c.updated[i])), (id, x)) }
                }
            }
            for p in parts { cos.merge(p.cos) { a, _ in a }; for b in p.best.items { best.add(b.score, b.value) } }
        }
        for b in best.items { cos[b.value.id] = b.value.cos }
        return rank(watch.union(cos.keys), limit: limit, kinds: kinds, minRelevance: minRelevance, conceptBoost: conceptBoost) { m in
            (MemoryText.stems(Self.indexText(m.content, m.subject)).reduce(0) { $0 + (lx.idf[$1] ?? 0) }, cos[m.rowid] ?? 0)
        }
    }

    private static func relevance(_ lexSum: Double, _ cos: Double, _ con: Double) -> Double {
        let lex = 1 - exp(-lexSum / MemoryTuning.lexK)
        let sem = min(1, max(0, (cos - MemoryTuning.semLow) / (MemoryTuning.semHigh - MemoryTuning.semLow)))
        return 1 - (1 - lex) * (1 - MemoryTuning.semWeight * sem) * (1 - MemoryTuning.conceptWeight * con)
    }
    private static func score(_ relevance: Double, _ importance: Double, age: TimeInterval) -> Double {
        relevance * 0.8 + importance * 0.12 + exp(-age / 86400 / 60) * 0.08
    }

    /// Exact relevance and score of the candidates, from their rows; the best `limit`.
    private func rank(_ ids: some Collection<Int64>, limit: Int, kinds: [MemoryKind]?, minRelevance: Double, conceptBoost: [Int64: Double],
                      evidence: (Memory) -> (lex: Double, cos: Double)) -> [Memory] {
        let now = Date()
        let out = rows(ids).compactMap { m -> Memory? in
            guard kinds?.contains(m.kind) ?? true else { return nil }
            var m = m
            let e = evidence(m)
            m.relevance = Self.relevance(e.lex, e.cos, m.conceptID.flatMap { conceptBoost[$0] } ?? 0)
            guard m.relevance >= minRelevance else { return nil }
            m.score = Self.score(m.relevance, m.importance, age: now.timeIntervalSince(m.updatedAt))
            return m
        }
        return Array(out.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Memories attached to a routed concept (candidates whatever their words), with that concept's boost.
    private func conceptMembers(_ boost: [Int64: Double]) -> [Int64: Double] {
        guard !boost.isEmpty else { return [:] }
        var out: [Int64: Double] = [:]
        try? db.each("SELECT id, concept_id FROM memories WHERE archived=0 AND concept_id IN (SELECT value FROM json_each(?)) ORDER BY importance DESC LIMIT 512",
                     Self.json(boost.keys)) { r in out[r.int64(0)] = boost[r.int64(1)]; return true }
        return out
    }

    // MARK: Candidates (from the index, or from SQLite past the budget; callers hold the lock)

    private func sameNorm(_ kind: MemoryKind, _ norm: String) -> [Int64] {
        guard !norm.isEmpty else { return [] }
        return ((try? db.query("SELECT id FROM memories WHERE archived=0 AND kind=? AND norm=? ORDER BY id", kind.rawValue, norm)) ?? []).compactMap { $0.int("id").map(Int64.init) }
    }

    /// Memories sharing a stem that at most `maxDF` of the `n` memories have, with the summed idf of what they share
    /// (best `limit`), each term's idf, and the idf of the terms whose rows were not read. From the postings or, past the
    /// budget, from FTS5, whose porter tokens approximate our stems. FTS5's bm25 ranking would score every match of a
    /// common term (~1 s for 100k), so each term's rows are read up to a small cap instead (exact df for rare terms, cheap
    /// at any size); a term past it is counted, and read only while a budget lasts, rarest first.
    private func lexical(_ terms: [(stem: String, tokens: [String])], maxDF: Int, limit: Int, n: Int) -> (ids: [Int64: Double], idf: [String: Double], unread: Double) {
        var acc: [Int64: Double] = [:], idf: [String: Double] = [:], unread = 0.0
        let nd = Double(max(1, n))
        func weight(_ df: Int) -> Double { log(1 + nd / Double(df)) / log(1 + nd) }
        if let ix = index {
            for t in terms {
                guard let s = ix.vocab[t.stem], case let p = ix.postings[Int(s)], !p.isEmpty else { continue }
                let w = weight(p.count)
                idf[t.stem] = w
                if p.count <= maxDF { for x in p { acc[ix.ids[Int(x)], default: 0] += w } } else { unread += w }
            }
        } else {
            let cap = 1024
            var common: [(stem: String, match: String, df: Int)] = []
            for t in terms {
                let match = t.tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
                var rows: [Int64] = []
                try? db.each("SELECT rowid FROM memories_fts WHERE memories_fts MATCH ? LIMIT ?", match, cap + 1) { rows.append($0.int64(0)); return true }
                if rows.count <= cap {
                    guard !rows.isEmpty else { continue }
                    let w = weight(rows.count)
                    idf[t.stem] = w
                    if rows.count <= maxDF { for r in rows { acc[r, default: 0] += w } } else { unread += w }
                } else if maxDF > cap, let df = (try? db.query("SELECT count(*) AS n FROM memories_fts WHERE memories_fts MATCH ?", match))?.first?.int("n") {
                    common.append((t.stem, match, df))
                }
            }
            var budget = 32_768
            for t in common.sorted(by: { $0.df < $1.df }) {
                let w = weight(t.df)
                idf[t.stem] = w
                guard t.df <= min(maxDF, budget) else { unread += w; continue }
                budget -= t.df
                try? db.each("SELECT rowid FROM memories_fts WHERE memories_fts MATCH ?", t.match) { acc[$0.int64(0), default: 0] += w; return true }
            }
        }
        guard acc.count > limit else { return (acc, idf, unread) }
        return (Dictionary(uniqueKeysWithValues: acc.sorted { $0.value > $1.value }.prefix(limit).map { ($0.key, $0.value) }), idf, unread)
    }

    /// For each probe, the same-kind memories whose vector has cosine ≥ `minCos` with it (best `cap`, itself excluded),
    /// all from one pass over the vectors.
    private func near(_ probes: [(id: Int64, kind: UInt8, vector: [Float])], minCos: Double, cap: Int) -> [[Int64]] {
        let dim = probes.first { !$0.vector.isEmpty }?.vector.count ?? 0
        let parts = scan(probes.map { $0.vector.count == dim ? $0.vector : [Float](repeating: 0, count: dim) }, into: probes.map { _ in TopK<Int64>(k: cap) }) { best, c in
            var top: Float = 0
            vDSP_maxv(c.cos.baseAddress!, 1, &top, vDSP_Length(c.cos.count))
            guard Double(top) >= minCos else { return }   // the usual case: nothing near in this chunk
            for i in 0..<c.count {
                let id = c.ids[i]
                for j in probes.indices where c.kinds[i] == probes[j].kind && id != probes[j].id && id != 0 {
                    let x = Double(c.cos[i * probes.count + j])
                    if x >= minCos { best[j].add(x, id) }
                }
            }
        }
        return probes.indices.map { j in
            var t = TopK<Int64>(k: cap)
            for p in parts { for e in p[j].items { t.add(e.score, e.value) } }
            return t.items.map(\.value)
        }
    }

    /// What dedup compares — kind, sorted stem keys and the int8 vector — by id: from the index, or from the rows.
    private struct Probe { var kind: UInt8; var stems: [UInt32]; var vector: [Int8] }
    private func probes(_ ids: some Collection<Int64>) -> [Int64: Probe] {
        var out: [Int64: Probe] = [:]
        if let ix = index {
            for id in ids { if let s = ix.slot[id].map(Int.init) { out[id] = Probe(kind: ix.kinds[s], stems: Array(ix.stems(s)), vector: ix.vector(s)) } }
        } else if !ids.isEmpty {
            try? db.each("SELECT id, kind, content, subject, embedding FROM memories WHERE archived=0 AND id IN (SELECT value FROM json_each(?))", Self.json(ids)) { r in
                if let k = r.text(1).flatMap(MemoryKind.init(rawValue:)) {
                    let b = r.blob(4)
                    var v = [Int8](repeating: 0, count: Embedder.dimension(b))
                    v.withUnsafeMutableBufferPointer { _ = Embedder.decode(b, into: $0) }
                    out[r.int64(0)] = Probe(kind: k.code, stems: keys(MemoryText.stems(Self.indexText(r.text(2) ?? "", r.text(3)))), vector: v)
                }
                return true
            }
        }
        return out
    }
    /// Stem keys comparable with `probes`: index ids (a stem it has never seen can't be shared, so it is left out — callers
    /// count it), or 32-bit hashes past the budget.
    private func keys(_ stems: [String]) -> [UInt32] {
        (index.map { ix in stems.compactMap { ix.vocab[$0] } } ?? stems.map { $0.utf8.reduce(2_166_136_261) { ($0 ^ UInt32($1)) &* 16_777_619 } }).sorted()
    }
    private static func overlap(_ a: [UInt32], _ b: [UInt32]) -> Int {
        var i = 0, j = 0, n = 0
        while i < a.count, j < b.count {
            if a[i] == b[j] { n += 1; i += 1; j += 1 } else if a[i] < b[j] { i += 1 } else { j += 1 }
        }
        return n
    }

    /// A chunk of stored vectors with their ranking fields: row i's cosines with the queries are at
    /// `cos[i * queries ..< (i + 1) * queries]`; `first` is row 0's slot in the index (0 on the disk path). Id 0 is a free slot.
    private struct Chunk {
        let ids: UnsafeBufferPointer<Int64>, kinds: UnsafeBufferPointer<UInt8>, importance: UnsafeBufferPointer<Float>, updated: UnsafeBufferPointer<Float>
        let cos: UnsafeBufferPointer<Float>, first: Int
        var count: Int { ids.count }
    }

    /// Walks the table in rowid order: `+archived` keeps the planner off `memories_rank`, which would turn every row into
    /// an index entry plus a b-tree seek (2× slower).
    private static let scanSQL = "SELECT id, CASE kind " + MemoryKind.allCases.enumerated().map { "WHEN '\($1.rawValue)' THEN \($0) " }.joined()
        + "ELSE 255 END, importance, updated_at, embedding FROM memories WHERE id BETWEEN ? AND ? AND +archived=0"

    /// Every active vector's cosines with `queries`, `Cosines.chunk` rows at a time, folded into one accumulator per
    /// partition: the slab as one partition or, past the budget, the `embedding` column streamed by rowid range on up to
    /// four read-only connections in parallel, each into buffers allocated once — O(chunk) memory whatever the count.
    private func scan<A>(_ queries: [[Float]], into initial: A, _ body: (inout A, Chunk) -> Void) -> [A] {
        if let ix = index {
            guard var k = Cosines(queries), ix.dim == k.dim else { return [] }
            var acc = initial
            ix.ids.withUnsafeBufferPointer { ids in ix.kinds.withUnsafeBufferPointer { kinds in ix.importance.withUnsafeBufferPointer { imp in
                ix.updated.withUnsafeBufferPointer { upd in ix.slab.withUnsafeBufferPointer { slab in
                    for first in stride(from: 0, to: ids.count, by: Cosines.chunk) {
                        let r = first ..< min(ids.count, first + Cosines.chunk)
                        k.run(slab.baseAddress! + first * k.dim, rows: r.count)
                        k.withOut(rows: r.count) { body(&acc, Chunk(ids: .init(rebasing: ids[r]), kinds: .init(rebasing: kinds[r]), importance: .init(rebasing: imp[r]),
                                                                    updated: .init(rebasing: upd[r]), cos: $0, first: first)) }
                    }
                } }
            } } }
            return [acc]
        }
        guard let span = (try? db.query("SELECT min(id) AS lo, max(id) AS hi FROM memories"))?.first, let lo = span.int("lo"), let hi = span.int("hi") else { return [] }
        // Parallel once there are enough rows to split (measured at 500k: 4 connections ≈ 2× one; more add little).
        let want = hi - lo < 16_384 ? 1 : 4
        if !(db.path.isEmpty || db.path == ":memory:") {
            while scanners.count < want, let s = try? Database(path: db.path, readOnly: true) { scanners.append(s) }
        }
        let conns = scanners.isEmpty ? [db] : Array(scanners.prefix(want)), parts = conns.count
        let out = UnsafeMutableBufferPointer<A>.allocate(capacity: parts)
        out.initialize(repeating: initial)
        defer { out.deinitialize(); out.deallocate() }
        DispatchQueue.concurrentPerform(iterations: parts) { p in
            stream(conns[p], ids: lo + (hi - lo + 1) * p / parts ... lo + (hi - lo + 1) * (p + 1) / parts - 1, queries) { body(&out[p], $0) }
        }
        return Array(out)
    }

    /// One rowid range of the disk scan, on its own connection.
    private func stream(_ conn: Database, ids range: ClosedRange<Int>, _ queries: [[Float]], _ body: (Chunk) -> Void) {
        guard var k = Cosines(queries) else { return }
        let size = Cosines.chunk, d = k.dim
        let ids = UnsafeMutableBufferPointer<Int64>.allocate(capacity: size), kinds = UnsafeMutableBufferPointer<UInt8>.allocate(capacity: size)
        let imp = UnsafeMutableBufferPointer<Float>.allocate(capacity: size), upd = UnsafeMutableBufferPointer<Float>.allocate(capacity: size)
        let vecs = UnsafeMutableBufferPointer<Int8>.allocate(capacity: size * d)
        defer { ids.deallocate(); kinds.deallocate(); imp.deallocate(); upd.deallocate(); vecs.deallocate() }
        var n = 0
        func flush() {
            guard n > 0 else { return }
            k.run(vecs.baseAddress!, rows: n)
            let r = 0..<n
            k.withOut(rows: n) { body(Chunk(ids: .init(rebasing: ids[r]), kinds: .init(rebasing: kinds[r]), importance: .init(rebasing: imp[r]),
                                            updated: .init(rebasing: upd[r]), cos: $0, first: 0)) }
            n = 0
        }
        try? conn.each(Self.scanSQL, range.lowerBound, range.upperBound) { r in
            let i = n
            ids[i] = r.int64(0); kinds[i] = UInt8(truncatingIfNeeded: r.int64(1)); imp[i] = Float(r.double(2))
            upd[i] = Float(r.double(3) - Date.timeIntervalBetween1970AndReferenceDate)
            Embedder.decode(r.blob(4), into: .init(rebasing: vecs[i * d ..< (i + 1) * d]))
            n = i + 1
            if n == size { flush() }
            return true
        }
        flush()
    }

    // MARK: Core block & maintenance

    /// The best `limit` by importance, then recency: ids from the covering index (`memories_rank`), then those rows only.
    func top(kinds: [MemoryKind], limit: Int) -> [Memory] {
        guard limit > 0, !kinds.isEmpty else { return [] }
        let list = kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")
        let ids = ((try? db.query("SELECT id FROM memories WHERE archived=0 AND kind IN (\(list)) ORDER BY importance DESC, updated_at DESC LIMIT ?", limit)) ?? [])
            .compactMap { $0.int("id").map(Int64.init) }
        let byID = Dictionary(uniqueKeysWithValues: rows(ids).map { ($0.rowid, $0) })
        return ids.compactMap { byID[$0] }
    }
    func recentEpisodes(limit: Int) -> [Memory] {
        guard limit > 0 else { return [] }
        return ((try? db.query("SELECT \(Self.columns) FROM memories WHERE archived=0 AND kind='episode' ORDER BY created_at DESC LIMIT ?", limit)) ?? []).compactMap(row)
    }

    struct MaintenanceReport { var decayed = 0, archived = 0, merged = 0 }

    /// Local, deterministic consolidation ("sleep-time"): decay unused inferred items, archive faded ones,
    /// cap episode history, and merge exact/near duplicates that slipped in.
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
        sweep(&rep)
        return rep
    }

    /// Duplicate sweep, incremental: memories changed since the last sweep (oldest first, resuming where the last run
    /// stopped) are checked against everything through the candidates `add` uses — equal norms, shared rare terms, near
    /// vectors (one pass per 128 changed) — so it costs O(changed), not O(all). A run stops after 2,000 changed memories
    /// or 1,000 merges (a bulk import of near-copies), whichever comes first; the next run carries on.
    private func sweep(_ rep: inout MaintenanceReport) {
        let key = "sweep_\(scope.rawValue)", mark = (MemorySchema.meta(db, key) ?? "").split(separator: " ")
        // "time id" of the last memory swept; a bare time (older versions) means everything up to that time.
        let at = mark.first.flatMap { Double($0) } ?? -1, after = mark.count > 1 ? Int64(mark[1]) ?? 0 : .max
        // In `memories_updated` order, so this reads 2,000 index entries, not a sort of every memory.
        let changed = ((try? db.query("SELECT id, updated_at FROM memories WHERE archived=0 AND (updated_at, id) > (?, ?) ORDER BY updated_at, id LIMIT 2000",
                                      at, after)) ?? []).compactMap { r in r.int("id").map { (id: Int64($0), at: r.double("updated_at") ?? 0) } }
        var gone = Set<Int64>(), done: (id: Int64, at: Double)?
        var n = 0, close: [Int64: [Int64]] = [:]
        for (i, e) in changed.enumerated() {
            if i % 128 == 0 {
                let batch = changed[i..<min(changed.count, i + 128)].map(\.id)
                lock.lock(); ensureLoaded()
                n = index?.live ?? count()
                let ps = probes(batch), order = batch.filter { ps[$0] != nil }
                close = Dictionary(uniqueKeysWithValues: zip(order, near(order.map { (id: $0, kind: ps[$0]!.kind, vector: ps[$0]!.vector.map { Float($0) / 127 }) },
                                                                         minCos: 0.95, cap: 200)))
                lock.unlock()
            }
            guard rep.merged < 1000 else { break }
            done = e
            let id = e.id
            guard !gone.contains(id), let m = get(id) else { continue }
            lock.lock()
            let equal = Set(sameNorm(m.kind, MemoryText.norm(m.content)))
            var cands = equal.union(lexical(MemoryText.terms(Self.indexText(m.content, m.subject)), maxDF: 50, limit: 256, n: n).ids.keys).union(close[id] ?? [])
            cands.remove(id); cands.subtract(gone)
            let others = probes(cands.union([id]))
            lock.unlock()
            guard let p = others[id] else { continue }
            for c in cands.sorted() where !gone.contains(c) {
                guard let o = others[c], o.kind == p.kind else { continue }
                let shared = Self.overlap(p.stems, o.stems), jac = Double(shared) / Double(max(1, p.stems.count + o.stems.count - shared))
                let cs = Double(Embedder.dot(p.vector, o.vector))
                guard equal.contains(c) || jac >= 0.8 || (cs >= 0.95 && jac >= 0.5) else { continue }
                // Keep the older id (stable references); absorb the other's evidence. The newer text wins when it is an
                // update (changed number/negation), otherwise the longer one.
                let (keep, drop) = id < c ? (id, c) : (c, id)
                guard let k = get(keep), let x = get(drop) else { continue }
                let newer = x.updatedAt > k.updatedAt ? x : k, older = newer.rowid == x.rowid ? k : x
                let keepNew = MemoryText.isUpdate(newer.content, of: older.content) ? newer.rowid == drop : x.content.count > k.content.count
                if keepNew { try? db.execute("UPDATE memories SET content=?, norm=?, embedding=(SELECT embedding FROM memories WHERE id=?) WHERE id=?", x.content, MemoryText.norm(x.content), drop, keep) }
                try? db.execute("UPDATE memories SET evidence=evidence+?, importance=MAX(importance, ?) WHERE id=?", x.evidence, x.importance, keep)
                archive(drop, status: "merged into #\(keep)")
                if keepNew { refresh(keep) }
                gone.insert(drop); rep.merged += 1
                if drop == id { break }
            }
        }
        if let done { MemorySchema.setMeta(db, key, "\(done.at) \(done.id)") }
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
        lock.lock(); loadedVersion = nil; lock.unlock()
    }
}

/// The in-RAM index, struct-of-arrays by slot: under 1 KB a memory, most of it the vector. Stems are interned as UInt32
/// ids with sorted slot postings; vectors sit in one contiguous int8 slab; ranking fields are Float32. Content, subjects
/// and norms are not here — they stay in SQLite.
private final class MemoryIndex {
    /// Bytes a memory costs (measured: 512-dim vector, ~15 stems), to decide before loading; `bytes` is the real account.
    static let estimate = 840
    private(set) var dim = 0
    private(set) var ids: [Int64] = []            // slot → rowid; 0 for a free slot
    private(set) var kinds: [UInt8] = []
    private(set) var importance: [Float] = []
    private(set) var updated: [Float] = []        // seconds since the reference date (recency only: 64 s resolution)
    private(set) var slab: [Int8] = []            // slots × dim: unit vectors ×127, zeros when a memory has none
    private(set) var slot: [Int64: Int32] = [:]
    private(set) var vocab: [String: UInt32] = [:]
    private(set) var postings: [[UInt32]] = []    // stem id → sorted slots
    private var stemAt: [UInt32] = [], stemCount: [UInt8] = [], pool: [UInt32] = []   // each slot's sorted stem ids, packed
    private var free: [Int32] = []
    private var holes = 0, lists = 0, entries = 0

    /// Memories expected (a load knows its count): arrays are sized once instead of growing by doubling.
    private let capacity: Int

    init(capacity: Int = 0) {
        self.capacity = capacity
        ids.reserveCapacity(capacity); kinds.reserveCapacity(capacity); importance.reserveCapacity(capacity)
        updated.reserveCapacity(capacity); stemAt.reserveCapacity(capacity); stemCount.reserveCapacity(capacity)
        slot.reserveCapacity(capacity)
    }

    /// After a bulk load: lists grown one slot at a time are copied to their exact size, in one sweep, so the freed
    /// growth buffers leave whole malloc pages to return instead of holes between live lists.
    func repack() {
        for t in postings.indices where postings[t].capacity > postings[t].count { postings[t] = postings[t].map { $0 } }
        pool = pool.map { $0 }
    }

    var live: Int { slot.count }
    /// Capacities in bytes, with dictionary buckets and per-list allocations at their usual cost.
    var bytes: Int {
        slab.capacity + ids.capacity * 8 + kinds.capacity + stemCount.capacity
            + (importance.capacity + updated.capacity + stemAt.capacity + pool.capacity + free.capacity) * 4
            + slot.capacity * 12 + vocab.capacity * 20 + postings.capacity * 8 + lists * 48 + entries * 6
    }

    func stems(_ s: Int) -> ArraySlice<UInt32> { pool[Int(stemAt[s]) ..< Int(stemAt[s]) + Int(stemCount[s])] }
    func vector(_ s: Int) -> [Int8] { Array(slab[s * dim ..< (s + 1) * dim]) }

    func insert(_ id: Int64, kind: UInt8, importance imp: Double, updated upd: Double, text: String, vector: UnsafeRawBufferPointer) {
        remove(id)
        if dim == 0, !vector.isEmpty {
            dim = Embedder.dimension(vector)
            slab = [Int8](repeating: 0, count: ids.count * dim)
            slab.reserveCapacity(max(capacity, ids.count + 1) * dim)
        }
        let s: Int
        if let f = free.popLast() { s = Int(f) } else {
            s = ids.count
            ids.append(0); kinds.append(0); importance.append(0); updated.append(0); stemAt.append(0); stemCount.append(0)
            slab.append(contentsOf: repeatElement(0, count: dim))
        }
        ids[s] = id; slot[id] = Int32(s); kinds[s] = kind; importance[s] = Float(imp)
        updated[s] = Float(upd - Date.timeIntervalBetween1970AndReferenceDate)
        if dim > 0 { slab.withUnsafeMutableBufferPointer { _ = Embedder.decode(vector, into: UnsafeMutableBufferPointer(rebasing: $0[s * dim ..< (s + 1) * dim])) } }
        let ts = MemoryText.stems(text).map { st -> UInt32 in
            if let t = vocab[st] { return t }
            vocab[st] = UInt32(postings.count); postings.append([])
            return UInt32(postings.count - 1)
        }.sorted()
        stemAt[s] = UInt32(pool.count); stemCount[s] = UInt8(ts.count); pool += ts
        for t in ts.map(Int.init) {
            if postings[t].isEmpty { lists += 1 }
            postings[t].insert(UInt32(s), at: postings[t].lowerBound(UInt32(s)))
        }
        entries += ts.count
    }

    func remove(_ id: Int64) {
        guard let s32 = slot.removeValue(forKey: id) else { return }
        let s = Int(s32)
        for t in stems(s).map(Int.init) {
            postings[t].remove(at: postings[t].lowerBound(UInt32(s)))
            if postings[t].isEmpty { postings[t] = []; lists -= 1 }
        }
        entries -= Int(stemCount[s]); holes += Int(stemCount[s])
        ids[s] = 0; stemCount[s] = 0
        free.append(s32)
        if holes > 4096, holes * 2 > pool.count {   // repack the stem pool once half of it is gaps
            var p: [UInt32] = []
            p.reserveCapacity(pool.count - holes)
            for s in ids.indices where ids[s] != 0 { let st = stems(s); stemAt[s] = UInt32(p.count); p += st }
            pool = p; holes = 0
        }
    }
}

/// Cosines of unit query vectors with int8 ones (unit ×127), a chunk at a time: one vDSP conversion and one matrix
/// multiply per chunk, into buffers reused for the whole pass.
private struct Cosines {
    static let chunk = 512
    let dim: Int, nq: Int
    private let qt: [Float]                       // dim × nq, ÷127
    private var x: [Float]
    private var out: [Float]                      // chunk × nq

    init?(_ queries: [[Float]]) {
        guard let d = queries.first?.count, d > 0, queries.allSatisfy({ $0.count == d }) else { return nil }
        dim = d; nq = queries.count
        var t = [Float](repeating: 0, count: d * nq)
        for (j, q) in queries.enumerated() { for i in 0..<d { t[i * nq + j] = q[i] / 127 } }
        qt = t
        x = [Float](repeating: 0, count: Self.chunk * d)
        out = [Float](repeating: 0, count: Self.chunk * nq)
    }

    func withOut(rows: Int, _ f: (UnsafeBufferPointer<Float>) -> Void) { out.withUnsafeBufferPointer { f(.init(rebasing: $0[0 ..< rows * nq])) } }

    mutating func run(_ v: UnsafePointer<Int8>, rows: Int) {
        x.withUnsafeMutableBufferPointer { x in
            vDSP_vflt8(v, 1, x.baseAddress!, 1, vDSP_Length(rows * dim))
            out.withUnsafeMutableBufferPointer { vDSP_mmul(x.baseAddress!, 1, qt, 1, $0.baseAddress!, 1, vDSP_Length(rows), vDSP_Length(nq), vDSP_Length(dim)) }
        }
    }
}

/// The best `k` values by score in one pass, in a small sorted buffer (no sort of everything).
private struct TopK<T> {
    let k: Int
    private(set) var items: [(score: Double, value: T)] = []
    mutating func add(_ score: Double, _ value: T) {
        guard k > 0, items.count < k || score > items[items.count - 1].score else { return }
        items.insert((score, value), at: items.firstIndex { score > $0.score } ?? items.count)
        if items.count > k { items.removeLast() }
    }
}

private extension MemoryKind {
    /// Position in `allCases`: the index keeps a kind in one byte.
    var code: UInt8 { UInt8(Self.allCases.firstIndex(of: self)!) }
}

private extension Array where Element == UInt32 {
    /// First position whose element is ≥ x (the array is sorted).
    func lowerBound(_ x: UInt32) -> Int {
        var lo = 0, hi = count
        while lo < hi { let m = (lo + hi) / 2; if self[m] < x { lo = m + 1 } else { hi = m } }
        return lo
    }
}
