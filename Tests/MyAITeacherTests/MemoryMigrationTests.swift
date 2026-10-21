import XCTest
@testable import MyAITeacher

/// Opening a database written by an older build: it is copied first, then upgraded in the background in batches that
/// survive a crash or a busy database, and an older build can still open the result.
final class MemoryMigrationTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("teacher.sqlite").path }
    private static let known = "Prefers worked examples before theory"
    private static let oldSweep = "1729000000.5"
    private let dim = Embedder.shared.dimension!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memmig-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// What an older build left: Float32 embeddings, rows from before the `norm` column, the old kind index, its sweep
    /// marker, history and concept links.
    private func writeOldDatabase(_ n: Int) throws {
        let db = try Database(path: path)
        try db.script(Schema_.sql)
        for (c, t) in MemorySchema.columns where c != "vec" { try db.execute("ALTER TABLE memories ADD COLUMN \(c) \(t)") }
        try db.script("""
            CREATE INDEX memories_kind ON memories(archived, kind);
            CREATE TABLE memory_meta(key TEXT PRIMARY KEY, value TEXT);
            CREATE TABLE memory_history(id INTEGER PRIMARY KEY AUTOINCREMENT, memory_id INTEGER NOT NULL, content TEXT NOT NULL,
                change TEXT NOT NULL, source TEXT, changed_at REAL NOT NULL);
            """)
        try db.execute("INSERT INTO memory_meta(key, value) VALUES('sweep_learner', ?)", Self.oldSweep)
        let real = Embedder.shared.vector(Self.known)!
        var rng = SystemRandomNumberGenerator()
        try db.transaction {
            for i in 0..<n {
                let v = i == 0 ? real : (0..<real.count).map { _ in Float.random(in: -1...1, using: &rng) }
                try db.execute("""
                    INSERT INTO memories(kind, subject, content, importance, created_at, updated_at, embedding, concept_id, evidence)
                    VALUES('preference', ?, ?, ?, ?, ?, ?, ?, ?)
                    """, i % 3 == 0 ? "music" : nil, i == 0 ? Self.known : "Old memory number \(i) about topic \(i % 50)", Double(i % 10) / 10,
                    Date(timeIntervalSince1970: 1_700_000_000 + Double(i)), Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
                    v.withUnsafeBufferPointer { Data(buffer: $0) }, i % 5 == 0 ? Int64(i % 7) : nil, 1 + i % 4)
            }
            try db.execute("INSERT INTO memory_history(memory_id, content, change, changed_at) VALUES(2, 'an older text', 'updated', 1700000000)")
        }
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("teacher.sqlite.pre-int8-") && $0.hasSuffix(".sqlite") }.sorted()
    }
    private func count(_ db: Database, _ condition: String) throws -> Int {
        try db.query("SELECT count(*) AS n FROM memories WHERE \(condition)").first?.int("n") ?? -1
    }
    /// Everything the upgrade must not change.
    private func untouched(_ db: Database) throws -> [String] {
        let cols = ["id", "kind", "subject", "content", "importance", "created_at", "updated_at", "concept_id", "evidence", "archived"]
        return try db.query("SELECT \(cols.joined(separator: ", ")) FROM memories ORDER BY id").map { r in cols.map { r.string($0) ?? "∅" }.joined(separator: "|") }
            + db.query("SELECT memory_id, content, change, changed_at FROM memory_history ORDER BY id").map { "\($0.string("memory_id") ?? "")|\($0.string("content") ?? "")" }
    }

    func testOldDatabaseIsBackedUpThenUpgradedOnce() throws {
        try writeOldDatabase(1500)
        let before = try untouched(try Database(path: path))
        let db = try Database(path: path)
        let t0 = Date()
        let store = MemoryStore(db: db, scope: .learner)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.1, "opening doesn't wait for the conversion (it runs in the background)")
        XCTAssertTrue(store.upgraded())
        // The copy is the database as it was (with this version's new, empty columns; nothing else).
        XCTAssertEqual(backups().count, 1)
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".partial") })
        let copy = try Database(path: dir.appendingPathComponent(backups()[0]).path, readOnly: true)
        XCTAssertEqual(try count(copy, "length(embedding) = \(dim * 4) AND norm IS NULL AND vec IS NULL"), 1500)
        // Upgraded: int8 vectors in `vec`, norms filled in, nothing else changed.
        XCTAssertEqual(try count(db, "length(vec) = \(dim) AND embedding IS NULL AND norm IS NOT NULL"), 1500)
        XCTAssertEqual(try untouched(db), before)
        let indexes = Set(try db.query("SELECT name FROM sqlite_master WHERE type='index'").compactMap { $0.string("name") })
        XCTAssertFalse(indexes.contains("memories_kind"))
        XCTAssertTrue(indexes.isSuperset(of: ["memories_rank", "memories_updated", "memories_norm", "memories_active"]))
        XCTAssertEqual(store.search("worked examples", limit: 1, minRelevance: 0.3).first?.content, Self.known)
        // An older build opening it finds a valid Float32 vector or none — never bytes it would read as other floats — and
        // its own sweep marker as it left it (this version keeps its own).
        store.add(kind: .fact, content: "Keeps a practice diary in a blue notebook", subject: nil, importance: 0.5, origin: "explicit", source: nil)
        store.maintenance()
        for r in try db.query("SELECT embedding FROM memories") { XCTAssertNil(r.data("embedding")) }
        XCTAssertEqual(MemorySchema.meta(db, "sweep_learner"), Self.oldSweep)
        XCTAssertNotNil(MemorySchema.meta(db, "sweep2_learner"))
        // The next launch: nothing to do, nothing written, no second copy.
        let stamp = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(backups()[0]).path)[.modificationDate] as? Date
        let again = try Database(path: path)
        XCTAssertTrue(MemoryStore(db: again, scope: .learner).upgraded())
        XCTAssertEqual(try again.query("SELECT total_changes() AS n").first?.int("n"), 0)
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(backups()[0]).path)[.modificationDate] as? Date, stamp)
    }

    func testACrashBetweenBatchesStillOpensAndResumes() throws {
        try writeOldDatabase(1300)
        let db = try Database(path: path)
        // The process dies during the second batch: its transaction never commits (a temporary trigger, on this connection
        // only, aborts it — the database is left as a crash would leave it).
        try db.script("CREATE TEMP TRIGGER crash BEFORE UPDATE OF vec ON memories WHEN old.id > 512 BEGIN SELECT RAISE(ABORT, 'simulated crash'); END")
        let store = MemoryStore(db: db, scope: .learner)
        XCTAssertFalse(store.upgraded())
        XCTAssertEqual(try count(db, "vec IS NOT NULL"), 512, "the first batch committed")
        XCTAssertEqual(try count(db, "length(embedding) = \(dim * 4) AND norm IS NULL"), 788, "the rest as it was")
        XCTAssertNil(MemorySchema.meta(db, MemorySchema.upgraded), "not marked done")
        XCTAssertEqual(store.count(), 1300)
        XCTAssertEqual(store.search("worked examples", limit: 1, minRelevance: 0.3).first?.content, Self.known, "mixed rows still read")
        // The next launch carries on; the copy from before the first batch stays the only one.
        let next = try Database(path: path)
        let resumed = MemoryStore(db: next, scope: .learner)
        XCTAssertTrue(resumed.upgraded())
        XCTAssertEqual(try count(next, "length(vec) = \(dim) AND embedding IS NULL AND norm IS NOT NULL"), 1300)
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try count(try Database(path: dir.appendingPathComponent(backups()[0]).path, readOnly: true), "length(embedding) = \(dim * 4)"), 1300)
        XCTAssertEqual(resumed.search("worked examples", limit: 1, minRelevance: 0.3).first?.content, Self.known)
    }

    /// A lock another connection holds: held past the busy timeout, the upgrade stops (CREATE INDEX fails), says so and
    /// is not marked done; released within it, the upgrade waits and completes.
    func testABusyDatabaseDelaysTheUpgradeButNeverMarksItDoneEarly() throws {
        try writeOldDatabase(600)
        let saved = Database.busyTimeout
        Database.busyTimeout = 300
        defer { Database.busyTimeout = saved }
        let db = try Database(path: path)
        MemorySchema.migrate(db)
        let holder = try Database(path: path)
        try holder.script("BEGIN IMMEDIATE")
        XCTAssertFalse(MemorySchema.upgrade(db), "the lock outlasts the busy timeout")
        XCTAssertNil(MemorySchema.meta(db, MemorySchema.upgraded))
        XCTAssertEqual(try count(db, "vec IS NOT NULL"), 0)
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) { try? holder.script("COMMIT") }
        XCTAssertTrue(MemorySchema.upgrade(db))
        XCTAssertEqual(try count(db, "vec IS NOT NULL"), 600)
        XCTAssertEqual(backups().count, 1)
    }

    func testANewDatabaseNeedsNoBackup() throws {
        let db = try Database(path: path)
        try db.script(Schema_.sql)
        XCTAssertTrue(MemoryStore(db: db, scope: .learner).upgraded())
        XCTAssertEqual(backups(), [])
        XCTAssertEqual(MemorySchema.meta(db, MemorySchema.upgraded), "1")
    }
}
