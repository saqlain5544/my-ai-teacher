import XCTest
@testable import MyAITeacher

/// Opening a database written by the previous version: it is copied first, then converted in batches that survive a crash.
final class MemoryMigrationTests: XCTestCase {
    private var dir: URL!
    private var path: String { dir.appendingPathComponent("teacher.sqlite").path }
    private static let known = "Prefers worked examples before theory"

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memmig-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    /// What the previous version left: Float32 embeddings, rows from before the `norm` column, the old kind index.
    private func writeOldDatabase(_ n: Int) throws {
        let db = try Database(path: path)
        try db.script(Schema_.sql)
        for (c, t) in MemorySchema.columns { try db.execute("ALTER TABLE memories ADD COLUMN \(c) \(t)") }
        try db.script("CREATE INDEX memories_kind ON memories(archived, kind)")
        let real = Embedder.shared.vector(Self.known)!
        var rng = SystemRandomNumberGenerator()
        try db.transaction {
            for i in 0..<n {
                let v = i == 0 ? real : (0..<real.count).map { _ in Float.random(in: -1...1, using: &rng) }
                try db.execute("INSERT INTO memories(kind, content, created_at, updated_at, embedding) VALUES('preference', ?, ?, ?, ?)",
                               i == 0 ? Self.known : "Old memory number \(i) about topic \(i % 50)", Date(), Date(), v.withUnsafeBufferPointer { Data(buffer: $0) })
            }
        }
    }

    private func backups() -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix("teacher.sqlite.pre-int8-") && $0.hasSuffix(".sqlite") }.sorted()
    }
    private func count(_ db: Database, _ condition: String) throws -> Int {
        try db.query("SELECT count(*) AS n FROM memories WHERE \(condition)").first?.int("n") ?? -1
    }

    func testOldDatabaseIsBackedUpThenConvertedOnce() throws {
        try writeOldDatabase(3000)
        let db = try Database(path: path)
        let store = MemoryStore(db: db, scope: .learner)
        XCTAssertEqual(backups().count, 1)
        XCTAssertFalse(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).contains { $0.hasSuffix(".partial") }, "the copy was renamed into place")
        let copy = try Database(path: dir.appendingPathComponent(backups()[0]).path, readOnly: true)
        XCTAssertEqual(try count(copy, "length(embedding) = 2048 AND norm IS NULL"), 3000, "the backup is the database as it was")
        XCTAssertEqual(try count(db, "length(embedding) = 513 AND norm IS NOT NULL"), 3000, "every row converted")
        let indexes = Set(try db.query("SELECT name FROM sqlite_master WHERE type='index'").compactMap { $0.string("name") })
        XCTAssertFalse(indexes.contains("memories_kind"))
        XCTAssertTrue(indexes.isSuperset(of: ["memories_rank", "memories_updated", "memories_norm"]))
        XCTAssertEqual(store.search("worked examples", limit: 1, minRelevance: 0.3).first?.content, Self.known)
        // The next launch: nothing to do, nothing written, no second copy.
        let stamp = try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(backups()[0]).path)[.modificationDate] as? Date
        let again = try Database(path: path)
        _ = MemoryStore(db: again, scope: .learner)
        XCTAssertEqual(try again.query("SELECT total_changes() AS n").first?.int("n"), 0)
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: dir.appendingPathComponent(backups()[0]).path)[.modificationDate] as? Date, stamp)
    }

    func testACrashBetweenBatchesStillOpensAndResumes() throws {
        try writeOldDatabase(5000)
        let db = try Database(path: path)
        // The process dies during the second batch: its transaction never commits (a temporary trigger, on this connection
        // only, aborts it — the database is left as a crash would leave it).
        try db.script("CREATE TEMP TRIGGER crash BEFORE UPDATE OF embedding ON memories WHEN old.id > 2048 BEGIN SELECT RAISE(ABORT, 'simulated crash'); END")
        let store = MemoryStore(db: db, scope: .learner)
        XCTAssertEqual(try count(db, "length(embedding) = 513"), 2048, "the first batch committed")
        XCTAssertEqual(try count(db, "length(embedding) = 2048 AND norm IS NULL"), 2952, "the rest as it was")
        XCTAssertNil(MemorySchema.meta(db, "rows_v2"), "not marked done")
        XCTAssertEqual(store.count(), 5000)
        XCTAssertEqual(store.search("worked examples", limit: 1, minRelevance: 0.3).first?.content, Self.known, "mixed rows still read")
        // The next launch carries on; the copy from before the first batch stays the only one.
        let next = try Database(path: path)
        let resumed = MemoryStore(db: next, scope: .learner)
        XCTAssertEqual(try count(next, "length(embedding) = 513 AND norm IS NOT NULL"), 5000)
        XCTAssertEqual(MemorySchema.meta(next, "rows_v2"), "1")
        XCTAssertEqual(backups().count, 1)
        XCTAssertEqual(try count(try Database(path: dir.appendingPathComponent(backups()[0]).path, readOnly: true), "length(embedding) = 2048"), 5000)
        XCTAssertEqual(resumed.search("worked examples", limit: 1, minRelevance: 0.3).first?.content, Self.known)
    }

    func testANewDatabaseNeedsNoBackup() throws {
        let db = try Database(path: path)
        try db.script(Schema_.sql)
        _ = MemoryStore(db: db, scope: .learner)
        XCTAssertEqual(backups(), [])
        XCTAssertEqual(MemorySchema.meta(db, "rows_v2"), "1")
    }
}
