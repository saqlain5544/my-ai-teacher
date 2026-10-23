import Foundation
import Accelerate

/// Schema additions for the learner model. `migrate` runs on every open and is cheap; `upgrade` does this version's
/// one-time work on an older database, in the background.
enum MemorySchema {
    static let tables = [
        """
        CREATE TABLE IF NOT EXISTS memory_history(id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id INTEGER NOT NULL, content TEXT NOT NULL,
            change TEXT NOT NULL, source TEXT, changed_at REAL NOT NULL)
        """,
        "CREATE INDEX IF NOT EXISTS memory_history_m ON memory_history(memory_id)",
        "CREATE TABLE IF NOT EXISTS memory_meta(key TEXT PRIMARY KEY, value TEXT)",
        "CREATE INDEX IF NOT EXISTS memories_concept ON memories(concept_id)",
    ]
    /// This version's indexes. Every query works without them (only slower), so building them — minutes of CREATE INDEX
    /// on a big database — waits for `upgrade`. `memories_rank` covers what `memories_kind` did; `memories_active` lets
    /// FTS5 matches be checked against active rows without reading the rows.
    static let indexes = [
        "DROP INDEX IF EXISTS memories_kind",
        "CREATE INDEX IF NOT EXISTS memories_rank ON memories(archived, kind, importance, updated_at)",
        "CREATE INDEX IF NOT EXISTS memories_updated ON memories(archived, updated_at)",
        "CREATE INDEX IF NOT EXISTS memories_norm ON memories(kind, norm) WHERE archived=0",
        "CREATE INDEX IF NOT EXISTS memories_active ON memories(id) WHERE archived=0",
    ]
    /// `vec` holds this version's int8 vectors. `embedding` stays the older builds' Float32 column: this version only ever
    /// clears it (after the backup), so a build from before sees a valid vector or none, never bytes it would misread.
    static let columns: [(String, String)] = [
        ("concept_id", "INTEGER"), ("evidence", "INTEGER NOT NULL DEFAULT 1"), ("status", "TEXT"), ("norm", "TEXT"), ("vec", "BLOB"),
    ]
    /// Rows `upgrade` rewrites: a Float32 `embedding` (an older build's) moves to `vec`; rows from before `norm` get one.
    static let legacy = "(embedding IS NOT NULL OR norm IS NULL)"
    static let upgraded = "vec_v1"

    /// On every open: the columns and tables this version reads (cheap, idempotent); the next open retries what failed.
    static func migrate(_ db: Database) {
        let have = Set(((try? db.query("PRAGMA table_info(memories)")) ?? []).compactMap { $0.string("name") })
        run(db, columns.filter { !have.contains($0.0) }.map { "ALTER TABLE memories ADD COLUMN \($0.0) \($0.1)" } + tables)
    }

    /// Statements one by one, stopping at the first that fails (under a lock each would wait out the busy timeout) and
    /// saying which: nothing is silently missing, and whoever called it knows not to count it as done. After a statement
    /// that held the write lock a while (a CREATE INDEX that built something), `pause` lets other connections' writers in.
    @discardableResult
    private static func run(_ db: Database, _ statements: [String], pause: TimeInterval = 0) -> Bool {
        for s in statements {
            let t = Date()
            do { try db.execute(s) } catch {
                AppLog.write("memory: \(name(db)): \(error.localizedDescription) — in: \(s.prefix(90)); the next run retries")
                return false
            }
            if Date().timeIntervalSince(t) > 0.005 { Thread.sleep(forTimeInterval: pause) }
        }
        return true
    }
    private static func name(_ db: Database) -> String { URL(fileURLWithPath: db.path).lastPathComponent }

    private static let upgrading = NSLock()

    /// This version's one-time work, in the background after launch: a backup of what it is about to rewrite; this
    /// version's indexes; then the rows, in batches. Until it is done older rows still decode. It can stop anywhere (a
    /// crash, a lock held past the busy timeout, a full disk) and the next run carries on; only when every step succeeded
    /// is it marked done. True when done.
    @discardableResult
    static func upgrade(_ db: Database) -> Bool {
        upgrading.lock(); defer { upgrading.unlock() }
        // The backup and CREATE INDEX are long: they run on a connection of their own, so the store's stays free.
        let side = db.path.isEmpty || db.path == ":memory:" ? db : (try? Database(path: db.path)) ?? db
        prune(db)
        if meta(db, upgraded) == "1" { return run(side, indexes) }
        let pending = (try? db.query("SELECT 1 AS x FROM memories WHERE \(legacy) LIMIT 1"))?.isEmpty == false
        guard !pending || backUp(side), run(side, indexes, pause: 0.05), convert(db) else { return false }
        setMeta(db, upgraded, "1")
        return true
    }

    /// Backups go after this long: by then the conversion they cover is long done.
    static let backupDays = 30.0
    private static func backups(of db: Database) -> [URL] {
        let url = URL(fileURLWithPath: db.path), dir = url.deletingLastPathComponent(), prefix = url.lastPathComponent + ".pre-int8-"
        return ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted().map { dir.appendingPathComponent($0) }
    }
    /// At launch: backups older than `backupDays` (with their journals), and temporary copies an earlier build left.
    private static func prune(_ db: Database) {
        guard !db.path.isEmpty, db.path != ":memory:" else { return }
        let fm = FileManager.default, cutoff = Date().addingTimeInterval(-backupDays * 86_400)
        for f in backups(of: db) {
            let stamp = (try? fm.attributesOfItem(atPath: f.path))?[.modificationDate] as? Date ?? .distantFuture
            guard f.pathExtension == "partial" || stamp < cutoff else { continue }
            try? fm.removeItem(at: f)
            AppLog.write("memory: removed \(f.lastPathComponent)")
        }
    }

    /// Before this version rewrites a row: what it rewrites — `id, embedding, norm` of every row about to change — into a
    /// small database beside it (`<db>.pre-int8-<date>.sqlite`, a table `memories`; ARCHITECTURE says how to restore it).
    /// SQLite's own transactions and file locks make it safe to interrupt and to write from two processes at once (the
    /// app and the CLI after an update): the table is created if missing and rows are added if missing, so a later run
    /// also covers rows an older build wrote since. Only the main database is read, so nothing waits for it. False when it
    /// could not be written.
    static func backUp(_ db: Database) -> Bool {
        guard !db.path.isEmpty, db.path != ":memory:" else { return true }
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyy-MM-dd"
        let url = URL(fileURLWithPath: db.path)
        let file = backups(of: db).last { $0.pathExtension == "sqlite" }
            ?? url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".pre-int8-" + day.string(from: Date()) + ".sqlite")
        let t0 = Date()
        var added = 0
        do {
            try db.execute("ATTACH DATABASE ? AS backup", file.path)
            defer { _ = db.run("DETACH DATABASE backup") }
            try db.execute("PRAGMA backup.page_size=16384")   // a new file only: 2 KB rows would leave half of each 4 KB page empty
            try db.execute("CREATE TABLE IF NOT EXISTS backup.memories(id INTEGER PRIMARY KEY, embedding BLOB, norm TEXT)")
            added = try db.execute("INSERT OR IGNORE INTO backup.memories(id, embedding, norm) SELECT id, embedding, norm FROM main.memories WHERE \(legacy)")
        } catch {
            AppLog.write("memory: no backup of \(name(db)) (\(error.localizedDescription)); nothing converted, the next launch tries again")
            return false
        }
        AppLog.write(String(format: "memory: backed up %d rows of %@ to %@ (%.0f ms) before converting them", added, name(db), file.lastPathComponent,
                            Date().timeIntervalSince(t0) * 1000))
        return true
    }

    /// A Float32 `embedding` of the model's size moves to `vec` (int8: a quarter of what the disk path scans) and missing
    /// norms are filled in, 128 rows a transaction on the store's connection, read and written inside it: an edit from
    /// another thread or process can't land between the two (it would be overwritten with the vector of the text it
    /// replaced). After each batch it steps aside for 10 ms, so writers get in — this connection's, and other processes',
    /// whose busy handlers poll: measured at 20k rows, the worst stall is 31 ms here and 125 ms there (918 ms without the
    /// pause). On a utility thread the pause stretches (timer coalescing), so the upgrade takes ~3× longer; it is one-time
    /// and in the background. A crash leaves whole batches done and the rest as they were. True when every row is.
    private static func convert(_ db: Database) -> Bool {
        let dim = Embedder.shared.dimension
        var last = 0, done = 0, more = true
        let t0 = Date()
        do {
            while more {
                try db.transaction {
                    let rows = try db.query("SELECT id, content, embedding FROM memories WHERE id > ? AND \(legacy) ORDER BY id LIMIT 128", last)
                    for r in rows {
                        // Any other blob (another model's size) is left as it is, for the build that wrote it.
                        let v = dim.flatMap { d in Embedder.decode(vec: nil, legacy: r.data("embedding"), dimension: d) }.map { Data($0.map { UInt8(bitPattern: $0) }) }
                        try db.execute("UPDATE memories SET vec=COALESCE(?, vec), embedding=CASE WHEN ? IS NULL THEN embedding END, norm=COALESCE(norm, ?) WHERE id=?",
                                       v, v, MemoryText.norm(r.string("content") ?? ""), r.int("id"))
                    }
                    last = rows.last?.int("id") ?? last; done += rows.count; more = rows.count == 128
                }
                if more { Thread.sleep(forTimeInterval: 0.01) }
            }
        } catch {
            AppLog.write("memory: converting \(name(db)) stopped after \(done) rows (\(error.localizedDescription)); the next launch carries on")
            return false
        }
        if done > 0 { AppLog.write(String(format: "memory: converted %d rows of %@ (int8 vectors, norms) in %.0f ms", done, name(db), Date().timeIntervalSince(t0) * 1000)) }
        return true
    }

    static func meta(_ db: Database, _ key: String) -> String? {
        (try? db.query("SELECT value FROM memory_meta WHERE key=?", key))?.first?.string("value")
    }
    static func setMeta(_ db: Database, _ key: String, _ value: String) {
        db.run("INSERT INTO memory_meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", key, value)
    }
    static func dataVersion(_ db: Database) -> Int { (try? db.query("PRAGMA data_version"))?.first?.int("data_version") ?? 0 }
}

/// The statements whose plans matter at scale (`MemoryPlanTests` checks each with EXPLAIN QUERY PLAN). Nothing runs
/// ANALYZE, so the planner guesses; `+archived` keeps it off an index on `archived` where a rowid lookup is meant.
enum MemorySQL {
    static let columns = "id, kind, subject, content, importance, confidence, origin, source, created_at, updated_at, last_used_at, use_count, concept_id, evidence"
    static let rows = "SELECT \(columns) FROM memories WHERE +archived=0 AND id IN (SELECT value FROM json_each(?))"
    static let probes = "SELECT id, kind, content, subject, vec, embedding FROM memories WHERE +archived=0 AND id IN (SELECT value FROM json_each(?))"
    static let members = "SELECT id, concept_id FROM memories WHERE +archived=0 AND concept_id IN (SELECT value FROM json_each(?)) ORDER BY importance DESC LIMIT 512"
    static let ofConcept = "SELECT \(columns) FROM memories WHERE +archived=0 AND concept_id=? ORDER BY importance DESC"
    static let page = "SELECT id, kind, content, subject, importance, updated_at, vec, embedding FROM memories WHERE id > ? AND +archived=0 ORDER BY id LIMIT 2048"
    static let span = "SELECT (SELECT min(id) FROM memories) AS lo, (SELECT max(id) FROM memories) AS hi"
    /// The disk path's pass walks the table in rowid order (an index entry plus a b-tree seek per row would be 2× slower).
    static let scan = "SELECT id, CASE kind " + MemoryKind.allCases.enumerated().map { "WHEN '\($1.rawValue)' THEN \($0) " }.joined()
        + "ELSE 255 END, importance, updated_at, vec, embedding FROM memories WHERE id BETWEEN ? AND ? AND +archived=0"
    /// FTS5 matches that are active memories: the FTS table also holds archived ones. Driven from the match, checked
    /// against `memories_active` (never `rowid IN (subquery)`, which re-runs the match per row).
    static let ftsRows = "SELECT m.id FROM memories_fts f JOIN memories m ON m.id = f.rowid WHERE memories_fts MATCH ? AND m.archived=0 LIMIT ?"
    static let ftsCount = "SELECT count(*) AS n FROM memories_fts f JOIN memories m ON m.id = f.rowid WHERE memories_fts MATCH ? AND m.archived=0"
    static let changed = "SELECT id, updated_at FROM memories WHERE archived=0 AND (updated_at, id) > (?, ?) ORDER BY updated_at, id LIMIT 2000"
    static let topOfKind = "SELECT id, importance, updated_at FROM memories WHERE archived=0 AND kind=? ORDER BY importance DESC, updated_at DESC LIMIT ?"
    static let sameNorm = "SELECT id FROM memories WHERE archived=0 AND kind=? AND norm=? ORDER BY id"
    static let count = "SELECT count(*) AS n FROM memories WHERE archived=0"
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
    /// Bytes a store's in-RAM index may use (≈ 40k memories). It loads only under 80% of it and leaves for the disk path
    /// past 100%, so a load near the line doesn't flip with every write. Past it the store keeps nothing per memory.
    nonisolated(unsafe) static var indexBudget = 32 << 20
}

/// One memory table, indexed for retrieval and dedup. Within `MemoryTuning.indexBudget` the index lives in RAM
/// (`MemoryIndex`, under 1 KB a memory); past it nothing is kept per memory — lexical candidates come from `memories_fts`
/// and vectors stream from SQLite — so the footprint stays flat however many memories there are. Content and subjects
/// stay in SQLite either way; only the rows of results are read. The index is rebuilt on first use and whenever another
/// connection changes the database (`PRAGMA data_version`).
final class MemoryStore: @unchecked Sendable {
    let db: Database
    let scope: MemoryScope
    /// The concept graph (learner scope only — concepts follow the learner).
    let graph: ConceptGraph?
    /// This version's one-time work on an older database (`MemorySchema.upgrade`), off the launch path.
    let upgrade: Task<Bool, Never>

    private let lock = NSRecursiveLock()
    /// nil before the first use, and on the disk path.
    private var index: MemoryIndex?
    private var loadedVersion: Int?
    /// The disk path's vector scans run on their own read-only, memory-mapped connections (opened on first use).
    private var scanners: [Database] = []
    /// `count()` as of a database state: (data_version, this connection's total changes).
    private var counted: (key: [Int], n: Int)?

    init(db: Database, scope: MemoryScope) {
        self.db = db
        self.scope = scope
        MemorySchema.migrate(db)
        graph = scope == .learner ? ConceptGraph(db: db) : nil
        // On a GCD thread: the work blocks on SQLite, and must not hold one of Swift concurrency's few threads meanwhile.
        upgrade = Task { await withCheckedContinuation { done in DispatchQueue.global(qos: .utility).async { done.resume(returning: MemorySchema.upgrade(db)) } } }
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
        return ((try? db.query(MemorySQL.rows, Self.json(ids))) ?? []).compactMap(row)
    }
    private static func json(_ ids: some Sequence<Int64>) -> String { "[" + ids.map(String.init).joined(separator: ",") + "]" }
    private static func indexText(_ content: String, _ subject: String?) -> String { content + " " + (subject ?? "") }
    private var onDiskPath: Bool { loadedVersion != nil && index == nil }

    /// Builds the index — or, past 80% of the budget, settles on the disk path — when this connection hasn't seen the
    /// latest data. It pages through the table (2,048 rows a statement), so other users of the connection get it between
    /// pages, and arrays are sized for a quarter more than the load, so the next writes don't regrow them.
    private func ensureLoaded() {
        let v = MemorySchema.dataVersion(db)
        if loadedVersion == v { return }
        index = nil; loadedVersion = v
        let n = count(), dim = Embedder.shared.dimension ?? 0
        guard MemoryIndex.cost(n, dim: dim) <= MemoryTuning.indexBudget / 5 * 4 else { return }
        let ix = MemoryIndex(capacity: n + n / 4 + 64, dim: dim)
        var last: Int64 = 0, page = 2048
        while page == 2048 {
            page = 0
            try? db.each(MemorySQL.page, last) { r in
                last = r.int64(0); page += 1
                if let k = r.text(1).flatMap(MemoryKind.init(rawValue:)) {
                    ix.insert(last, kind: k.code, importance: r.double(4), updated: r.double(5), text: Self.indexText(r.text(2) ?? "", r.text(3)),
                              vec: r.blob(6), legacy: r.blob(7))
                }
                return true
            }
            if ix.bytes > MemoryTuning.indexBudget { return }
        }
        ix.repack()
        index = ix
    }

    /// Re-indexes one memory after our own write: O(1), not a reload (the disk path has nothing to update). Past the
    /// budget it leaves for the disk path (`removed` brings it back).
    private func refresh(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        guard let ix = index else { return }
        ix.remove(id)
        try? db.each("SELECT kind, content, subject, importance, updated_at, vec, embedding FROM memories WHERE id=? AND archived=0", id) { r in
            if let k = r.text(0).flatMap(MemoryKind.init(rawValue:)) {
                ix.insert(id, kind: k.code, importance: r.double(3), updated: r.double(4), text: Self.indexText(r.text(1) ?? "", r.text(2)),
                          vec: r.blob(5), legacy: r.blob(6))
            }
            return false
        }
        if ix.bytes > MemoryTuning.indexBudget { index = nil }
    }

    // MARK: Reads

    /// Every memory (the Memory screen lists them all); consolidation and the core block use `top` instead.
    func all() -> [Memory] {
        let order = Dictionary(uniqueKeysWithValues: MemoryKind.allCases.enumerated().map { ($1, $0) })
        return ((try? db.query("SELECT \(MemorySQL.columns) FROM memories WHERE archived=0")) ?? []).compactMap(row).sorted {
            if $0.kind != $1.kind { return order[$0.kind]! < order[$1.kind]! }
            if $0.importance != $1.importance { return $0.importance > $1.importance }
            return $0.updatedAt > $1.updatedAt
        }
    }
    /// Active memories, counted once per database state (a count reads every active row's index entry: 8 ms at 500k).
    func count() -> Int {
        lock.lock(); defer { lock.unlock() }
        let key = [MemorySchema.dataVersion(db), db.totalChanges]
        if let c = counted, c.key == key { return c.n }
        let n = (try? db.query(MemorySQL.count))?.first?.int("n") ?? 0
        counted = (key, n)
        return n
    }
    func get(_ id: Int64) -> Memory? { (try? db.query("SELECT \(MemorySQL.columns) FROM memories WHERE id=?", id))?.first.flatMap(row) }
    func memories(conceptID: Int64) -> [Memory] { ((try? db.query(MemorySQL.ofConcept, conceptID)) ?? []).compactMap(row) }
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
            let newContent = takeNew ? content : old.content, blob = takeNew ? vec.map(Embedder.int8) : nil
            if takeNew { recordHistory(old.rowid, content: old.content, change: "merged", source: source) }
            // A new vector replaces an older build's Float32 one, which would otherwise win over it (see Embedder.decode).
            db.run("""
                UPDATE memories SET content=?, importance=?, updated_at=?, evidence=evidence+1, concept_id=COALESCE(?, concept_id),
                subject=COALESCE(subject, ?), norm=?, vec=COALESCE(?, vec), embedding=CASE WHEN ? IS NULL THEN embedding END WHERE id=?
                """, newContent, max(importance, old.importance), now, conceptID, subject, MemoryText.norm(newContent), blob, blob, old.rowid)
            refresh(old.rowid)
            return WriteOutcome(rowid: old.rowid, status: .merged, reason: nil, similar: [])
        }
        guard let id = db.insert("""
            INSERT INTO memories(kind, subject, content, importance, origin, source, created_at, updated_at, vec, concept_id, norm, evidence)
            VALUES(?,?,?,?,?,?,?,?,?,?,?,1)
            """, kind.rawValue, subject, content, min(1, max(0, importance)), origin, source, now, now, vec.map(Embedder.int8), conceptID, norm)
        else { return WriteOutcome(rowid: nil, status: .rejected, reason: "The memory could not be saved.", similar: []) }
        refresh(id)
        return WriteOutcome(rowid: id, status: .added, reason: nil, similar: similar.sorted { $0.1 > $1.1 }.prefix(3).map(\.0))
    }

    private func recordHistory(_ id: Int64, content: String, change: String, source: String?) {
        db.run("INSERT INTO memory_history(memory_id, content, change, source, changed_at) VALUES(?,?,?,?,?)", id, content, change, source, Date())
    }

    func update(_ id: Int64, content: String? = nil, importance: Double? = nil, kind: MemoryKind? = nil, subject: String? = nil,
                conceptID: Int64?? = nil, source: String? = nil) {
        guard var m = get(id) else { return }
        var blob: Data?
        if let content, !Self.clean(content).isEmpty, Self.clean(content) != m.content {
            recordHistory(id, content: m.content, change: "updated", source: source)
            m.content = MemoryText.clip(Self.clean(content), 400)
            blob = Embedder.shared.vector(m.content).map(Embedder.int8)
        }
        if let importance { m.importance = min(1, max(0, importance)) }
        if let kind { m.kind = kind }
        if let subject { m.subject = MemoryText.subject(subject) }
        if let conceptID { m.conceptID = conceptID }
        db.run("""
            UPDATE memories SET content=?, importance=?, kind=?, subject=?, concept_id=?, updated_at=?, norm=?, vec=COALESCE(?, vec),
            embedding=CASE WHEN ? IS NULL THEN embedding END WHERE id=?
            """, m.content, m.importance, m.kind.rawValue, m.subject, m.conceptID, Date(), MemoryText.norm(m.content), blob, blob, id)
        refresh(id)
    }

    /// Soft-removes a memory (kept with its history for provenance, excluded everywhere else).
    func archive(_ id: Int64, status: String, source: String? = nil) {
        if let m = get(id) { recordHistory(id, content: m.content, change: status, source: source) }
        db.run("UPDATE memories SET archived=1, status=?, updated_at=? WHERE id=?", status, Date(), id)
        removed(id)
    }

    func delete(_ id: Int64) {
        db.write("memory delete") {
            try db.execute("DELETE FROM memories WHERE id=?", id)
            try db.execute("DELETE FROM memory_history WHERE memory_id=?", id)
        }
        removed(id)
    }
    private func removed(_ id: Int64) {
        lock.lock(); defer { lock.unlock() }
        index?.remove(id)
        if onDiskPath { loadedVersion = nil }   // fewer memories: the next use checks whether they fit in RAM again
    }
    func deleteAll() {
        db.write("memory delete all") {
            try db.execute("DELETE FROM memories")
            try db.execute("DELETE FROM memory_history")
        }
        graph?.deleteAll()
        lock.lock(); index = nil; loadedVersion = nil; lock.unlock()
    }
    func markUsed(_ ids: [Int64]) {
        let now = Date()
        db.write("memory use") {   // one commit for the recall, not one per memory
            for id in ids { try db.execute("UPDATE memories SET use_count=use_count+1, last_used_at=? WHERE id=?", now, id) }
        }
    }
    /// Re-points memories from merged concepts.
    func reassignConcept(from: [Int64], to: Int64?) {
        for f in from { db.run("UPDATE memories SET concept_id=? WHERE concept_id=?", to, f) }
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
        // Past the budget: active rows sharing the rarer terms (FTS5) and on routed concepts are candidates; one streamed
        // pass over the vectors gives their cosines and the best other matches with semantic evidence, admitted on their
        // cosine plus the most the unread common terms could add. Lexical evidence is then recounted with our stems from
        // the few rows read at the end. Where it can differ from the index: a row whose only evidence is common terms
        // past the row budget (no cosine above semLow) is not a candidate; a concept contributes its 512 most important
        // memories; FTS5's porter stemmer counts documents a little differently from our stems.
        let lx = lexical(terms, maxDF: .max, limit: 256, n: count())
        let watch = Set(lx.ids.keys).union(members.keys)
        var cos: [Int64: Double] = [:]
        var best = TopK<(id: Int64, cos: Double)>(k: max(32, limit * 4))
        if let qv {
            let parts = scan([qv], into: (cos: [Int64: Double](), best: best)) { acc, c in
                for i in 0..<c.count {
                    let id = c.ids[i], x = Double(c.cos[i])
                    if watch.contains(id) { acc.cos[id] = x; continue }
                    guard x > MemoryTuning.semLow, allowed?.contains(c.kinds[i]) ?? true else { continue }
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
        try? db.each(MemorySQL.members, Self.json(boost.keys)) { r in out[r.int64(0)] = boost[r.int64(1)]; return true }
        return out
    }

    // MARK: Candidates (from the index, or from SQLite past the budget; callers hold the lock)

    private func sameNorm(_ kind: MemoryKind, _ norm: String) -> [Int64] {
        guard !norm.isEmpty else { return [] }
        return ((try? db.query(MemorySQL.sameNorm, kind.rawValue, norm)) ?? []).compactMap { $0.int("id").map(Int64.init) }
    }

    /// Active memories sharing a stem that at most `maxDF` of the `n` active memories have, with the summed idf of what
    /// they share (best `limit`), each term's idf, and the idf of the common terms whose rows were not read (counted only
    /// when `maxDF` allows rows past the cap). From the postings or, past the budget, from FTS5 matches checked against
    /// `memories_active`, whose porter tokens approximate our stems. FTS5's bm25 ranking would score every match of a
    /// common term (~1 s for 100k), so each term's active rows are read up to a small cap instead (exact df for rare
    /// terms, cheap at any size); a term past it is counted (8 ms for 42k matches at 500k), and its rows read only while
    /// a budget lasts, rarest first.
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
            let cap = min(1024, maxDF)
            var common: [(stem: String, match: String, df: Int)] = []
            for t in terms {
                let match = t.tokens.map { "\"\($0)\"" }.joined(separator: " OR ")
                var rows: [Int64] = []
                try? db.each(MemorySQL.ftsRows, match, cap + 1) { rows.append($0.int64(0)); return true }
                if rows.count <= cap {
                    guard !rows.isEmpty else { continue }
                    let w = weight(rows.count)
                    idf[t.stem] = w
                    for r in rows { acc[r, default: 0] += w }
                } else if maxDF > cap, let df = (try? db.query(MemorySQL.ftsCount, match))?.first?.int("n") {
                    common.append((t.stem, match, df))
                }
            }
            var budget = 32_768
            for t in common.sorted(by: { $0.df < $1.df }) {
                let w = weight(t.df)
                idf[t.stem] = w
                guard t.df <= min(maxDF, budget) else { unread += w; continue }
                budget -= t.df
                try? db.each(MemorySQL.ftsRows, t.match, t.df) { acc[$0.int64(0), default: 0] += w; return true }
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
            let dim = Embedder.shared.dimension ?? 0
            try? db.each(MemorySQL.probes, Self.json(ids)) { r in
                if let k = r.text(1).flatMap(MemoryKind.init(rawValue:)) {
                    var v = [Int8](repeating: 0, count: dim)
                    v.withUnsafeMutableBufferPointer { _ = Embedder.decode(vec: r.blob(4), legacy: r.blob(5), into: $0) }
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

    /// Every active vector's cosines with `queries`, `Cosines.chunk` rows at a time, folded into one accumulator per
    /// partition: the slab as one partition or, past the budget, the table streamed by rowid range on up to four
    /// read-only connections in parallel, each into buffers allocated once — O(chunk) memory whatever the count.
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
        guard let span = (try? db.query(MemorySQL.span))?.first, let lo = span.int("lo"), let hi = span.int("hi") else { return [] }
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
        try? conn.each(MemorySQL.scan, range.lowerBound, range.upperBound) { r in
            let i = n
            ids[i] = r.int64(0); kinds[i] = UInt8(truncatingIfNeeded: r.int64(1)); imp[i] = Float(r.double(2))
            upd[i] = Float(r.double(3) - Date.timeIntervalBetween1970AndReferenceDate)
            Embedder.decode(vec: r.blob(4), legacy: r.blob(5), into: .init(rebasing: vecs[i * d ..< (i + 1) * d]))
            n = i + 1
            if n == size { flush() }
            return true
        }
        flush()
    }

    // MARK: Core block & maintenance

    /// The best `limit` by importance, then recency: each kind read in `memories_rank` order (`limit` index entries, not a
    /// sort of the kind's rows), merged, then only those rows.
    func top(kinds: [MemoryKind], limit: Int) -> [Memory] {
        guard limit > 0 else { return [] }
        var ranked: [(id: Int64, importance: Double, updated: Double)] = []
        for k in kinds {
            for r in (try? db.query(MemorySQL.topOfKind, k.rawValue, limit)) ?? [] {
                if let id = r.int("id") { ranked.append((Int64(id), r.double("importance") ?? 0, r.double("updated_at") ?? 0)) }
            }
        }
        ranked.sort { $0.importance != $1.importance ? $0.importance > $1.importance : $0.updated > $1.updated }
        let best = ranked.prefix(limit).map(\.id)
        let byID = Dictionary(uniqueKeysWithValues: rows(best).map { ($0.rowid, $0) })
        return best.compactMap { byID[$0] }
    }
    func recentEpisodes(limit: Int) -> [Memory] {
        guard limit > 0 else { return [] }
        return ((try? db.query("SELECT \(MemorySQL.columns) FROM memories WHERE archived=0 AND kind='episode' ORDER BY created_at DESC LIMIT ?", limit)) ?? []).compactMap(row)
    }

    struct MaintenanceReport { var decayed = 0, archived = 0, merged = 0 }

    /// Local, deterministic consolidation ("sleep-time"): decay unused inferred items, archive faded ones,
    /// cap episode history, and merge exact/near duplicates that slipped in.
    @discardableResult
    func maintenance(now: Date = Date()) -> MaintenanceReport {
        var rep = MaintenanceReport()
        let t = now.timeIntervalSince1970
        rep.decayed = (db.run("""
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

    /// A run of the duplicate sweep stops after this many merges (a bulk import of near-copies); the next one carries on.
    static let sweepMerges = 1000

    /// Duplicate sweep, incremental: memories changed since the last sweep (2,000 a run, oldest first) are checked
    /// against everything through the candidates `add` uses — equal norms, shared rare terms, near vectors (one pass per
    /// 128 changed) — so it costs O(changed), not O(all). It resumes after the last memory it finished: a memory cut off
    /// by the merge cap is checked again next run.
    private func sweep(_ rep: inout MaintenanceReport) {
        // Its own marker ("time id"); the first run starts from an older build's (a bare time, under the key that build
        // still reads and that is left to it).
        let key = "sweep2_\(scope.rawValue)"
        let mark = (MemorySchema.meta(db, key) ?? MemorySchema.meta(db, "sweep_\(scope.rawValue)") ?? "").split(separator: " ")
        let at = mark.first.flatMap { Double($0) } ?? -1, after = mark.count > 1 ? Int64(mark[1]) ?? 0 : .max
        let changed = ((try? db.query(MemorySQL.changed, at, after)) ?? []).compactMap { r in r.int("id").map { (id: Int64($0), at: r.double("updated_at") ?? 0) } }
        var gone = Set<Int64>(), done: (id: Int64, at: Double)?
        var n = 0, close: [Int64: [Int64]] = [:]
        sweeping: for (i, e) in changed.enumerated() {
            if i % 128 == 0 {
                let batch = changed[i..<min(changed.count, i + 128)].map(\.id)
                lock.lock(); ensureLoaded()
                n = index?.live ?? count()
                let ps = probes(batch), order = batch.filter { ps[$0] != nil }
                close = Dictionary(uniqueKeysWithValues: zip(order, near(order.map { (id: $0, kind: ps[$0]!.kind, vector: ps[$0]!.vector.map { Float($0) / 127 }) },
                                                                         minCos: 0.95, cap: 200)))
                lock.unlock()
            }
            let id = e.id
            guard !gone.contains(id), let m = get(id) else { done = e; continue }
            lock.lock()
            let equal = Set(sameNorm(m.kind, MemoryText.norm(m.content)))
            var cands = equal.union(lexical(MemoryText.terms(Self.indexText(m.content, m.subject)), maxDF: 50, limit: 256, n: n).ids.keys).union(close[id] ?? [])
            cands.remove(id); cands.subtract(gone)
            let others = probes(cands.union([id]))
            lock.unlock()
            guard let p = others[id] else { done = e; continue }
            for c in cands.sorted() where !gone.contains(c) {
                guard let o = others[c], o.kind == p.kind else { continue }
                let shared = Self.overlap(p.stems, o.stems), jac = Double(shared) / Double(max(1, p.stems.count + o.stems.count - shared))
                let cs = Double(Embedder.dot(p.vector, o.vector))
                guard equal.contains(c) || jac >= 0.8 || (cs >= 0.95 && jac >= 0.5) else { continue }
                guard rep.merged < Self.sweepMerges else { break sweeping }
                // Keep the older id (stable references); absorb the other's evidence. The newer text wins when it is an
                // update (changed number/negation), otherwise the longer one.
                let (keep, drop) = id < c ? (id, c) : (c, id)
                guard let k = get(keep), let x = get(drop) else { continue }
                let newer = x.updatedAt > k.updatedAt ? x : k, older = newer.rowid == x.rowid ? k : x
                let keepNew = MemoryText.isUpdate(newer.content, of: older.content) ? newer.rowid == drop : x.content.count > k.content.count
                if keepNew {
                    db.run("""
                        UPDATE memories SET content=?, norm=?, vec=(SELECT vec FROM memories WHERE id=?), embedding=(SELECT embedding FROM memories WHERE id=?) WHERE id=?
                        """, x.content, MemoryText.norm(x.content), drop, drop, keep)
                }
                db.run("UPDATE memories SET evidence=evidence+?, importance=MAX(importance, ?) WHERE id=?", x.evidence, x.importance, keep)
                archive(drop, status: "merged into #\(keep)")
                if keepNew { refresh(keep) }
                gone.insert(drop); rep.merged += 1
                if drop == id { break }
            }
            done = e
        }
        if let done { MemorySchema.setMeta(db, key, "\(done.at) \(done.id)") }
    }

    /// Test/bench helper: inserts many rows quickly with precomputed vectors (no policy, no dedup).
    func bulkInsert(_ rows: [(kind: MemoryKind, content: String, subject: String?, vector: [Float]?)]) {
        let now = Date()
        try? db.transaction {
            for r in rows {
                try db.execute("INSERT INTO memories(kind, subject, content, importance, origin, created_at, updated_at, vec, norm) VALUES(?,?,?,?,?,?,?,?,?)",
                               r.kind.rawValue, r.subject, r.content, 0.5, "inferred", now, now, r.vector.map(Embedder.int8), MemoryText.norm(r.content))
            }
        }
        lock.lock(); loadedVersion = nil; lock.unlock()
    }
}

/// The in-RAM index, struct-of-arrays by slot: under 1 KB a memory, most of it the vector. Stems are interned as UInt32
/// ids with sorted slot postings; vectors sit in one contiguous int8 slab; ranking fields are Float32. Content, subjects
/// and norms are not here — they stay in SQLite.
final class MemoryIndex {
    /// The model's vector size (from the embedder, never from the data: a malformed blob is no vector, not a new size).
    let dim: Int
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

    init(capacity: Int, dim: Int) {
        self.dim = dim
        ids.reserveCapacity(capacity); kinds.reserveCapacity(capacity); importance.reserveCapacity(capacity)
        updated.reserveCapacity(capacity); stemAt.reserveCapacity(capacity); stemCount.reserveCapacity(capacity)
        slot.reserveCapacity(capacity); slab.reserveCapacity(capacity * dim)
    }

    /// After a bulk load: lists grown one slot at a time are copied to their exact size, in one sweep, so the freed
    /// growth buffers leave whole malloc pages to return instead of holes between live lists.
    func repack() {
        for t in postings.indices where postings[t].capacity > postings[t].count { postings[t] = postings[t].map { $0 } }
        pool = pool.map { $0 }
    }

    var live: Int { slot.count }
    /// What the index holds, by count: capacities come and go with growth, so judging the budget on them would flip a load
    /// near the line to the disk path on the next write. Per slot the vector and ranking fields, per stem occurrence a
    /// pool entry and a posting, per distinct stem a vocabulary entry and its list (malloc rounding included).
    var bytes: Int { ids.count * (dim + 22) + slot.count * 16 + pool.count * 4 + entries * 4 + lists * 48 + vocab.count * 28 }
    /// The same for `n` memories before loading them (measured: ~15 stems, ~2 of them unique, a memory).
    static func cost(_ n: Int, dim: Int) -> Int { n * (dim + 300) }

    func stems(_ s: Int) -> ArraySlice<UInt32> { pool[Int(stemAt[s]) ..< Int(stemAt[s]) + Int(stemCount[s])] }
    func vector(_ s: Int) -> [Int8] { Array(slab[s * dim ..< (s + 1) * dim]) }

    func insert(_ id: Int64, kind: UInt8, importance imp: Double, updated upd: Double, text: String, vec: UnsafeRawBufferPointer, legacy: UnsafeRawBufferPointer) {
        remove(id)
        let s: Int
        if let f = free.popLast() { s = Int(f) } else {
            s = ids.count
            ids.append(0); kinds.append(0); importance.append(0); updated.append(0); stemAt.append(0); stemCount.append(0)
            slab.append(contentsOf: repeatElement(0, count: dim))
        }
        ids[s] = id; slot[id] = Int32(s); kinds[s] = kind; importance[s] = Float(imp)
        updated[s] = Float(upd - Date.timeIntervalBetween1970AndReferenceDate)
        if dim > 0 { slab.withUnsafeMutableBufferPointer { _ = Embedder.decode(vec: vec, legacy: legacy, into: UnsafeMutableBufferPointer(rebasing: $0[s * dim ..< (s + 1) * dim])) } }
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
