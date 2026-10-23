import XCTest
@testable import MyAITeacher

/// Storage atomicity, gate composition and the bounded-output bookkeeping the rest of the app builds on.
final class ArchitectureTests: XCTestCase {
    var dir: URL!
    var db: Database!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("arch-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try Database(path: dir.appendingPathComponent("a.sqlite").path)
        try db.script(Schema_.sql)
        try db.script("CREATE TABLE t(x INTEGER)")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    private func count() throws -> Int { try db.query("SELECT COUNT(*) AS n FROM t").first?.int("n") ?? -1 }

    // MARK: Database

    func testNestedTransactionRollsBackOnlyItsOwnWrites() throws {
        try db.transaction {
            try db.execute("INSERT INTO t VALUES(1)")
            XCTAssertThrowsError(try db.transaction {
                try db.execute("INSERT INTO t VALUES(2)")
                throw SQLiteError(message: "inner")
            })
            try db.execute("INSERT INTO t VALUES(3)")
        }
        XCTAssertEqual(try db.query("SELECT x FROM t ORDER BY x").compactMap { $0.int("x") }, [1, 3])
    }

    func testOuterFailureDiscardsCommittedSavepoints() throws {
        XCTAssertThrowsError(try db.transaction {
            try db.transaction { try db.execute("INSERT INTO t VALUES(1)") }
            throw SQLiteError(message: "outer")
        })
        XCTAssertEqual(try count(), 0)
        // The connection is usable afterwards (no transaction left open).
        try db.transaction { try db.execute("INSERT INTO t VALUES(4)") }
        XCTAssertEqual(try count(), 1)
    }

    func testRunReportsFailureInsteadOfThrowing() {
        XCTAssertNil(db.run("INSERT INTO missing_table VALUES(1)"))
        XCTAssertEqual(db.run("INSERT INTO t VALUES(?)", 7), 1)
    }

    func testWriteRollsBackAsAWhole() throws {
        db.write("test") {
            try db.execute("INSERT INTO t VALUES(1)")
            try db.execute("INSERT INTO missing_table VALUES(1)")
        }
        XCTAssertEqual(try count(), 0)
    }

    func testMessageSaveKeepsBlobReferencesWithTheRow() throws {
        let store = ConversationStore(db: db)
        var m = ChatMessage(role: .user, blocks: [.text("hi")])
        m.blocks[0].blob = "ref-a"
        store.upsert(m, conversationID: "c", seq: 0)
        m.blocks[0].blob = "ref-b"
        store.upsert(m, conversationID: "c", seq: 0)
        let refs = try db.query("SELECT ref FROM blob_refs WHERE message_id=?", m.id).compactMap { $0.string("ref") }
        XCTAssertEqual(refs, ["ref-b"])
        store.deleteMessages("c", fromSeq: 0)
        XCTAssertEqual(store.messageCount("c"), 0)
        XCTAssertTrue(try db.query("SELECT ref FROM blob_refs").isEmpty)
    }

    // MARK: Tool gates

    @MainActor
    func testApprovedGateContinuesToTheNextGate() {
        let ask = ToolDecision.ask(ApprovalRequest(title: "t", detail: "", options: []), resolve: { $0 == "ok" ? .allow : .deny("no") })
        var laterRan = false
        let gates: [@MainActor () -> ToolDecision] = [{ ask }, { laterRan = true; return .deny("second gate") }]
        guard case .ask(_, let resolve) = ExtensionHost.chain(gates[...]) else { return XCTFail("first gate asks") }
        XCTAssertFalse(laterRan, "later gates wait for the answer")
        guard case .deny(let why) = resolve("ok") else { return XCTFail("the second gate still applies") }
        XCTAssertEqual(why, "second gate")
        XCTAssertTrue(laterRan)
    }

    @MainActor
    func testDeclinedGateStopsTheChain() {
        let ask = ToolDecision.ask(ApprovalRequest(title: "t", detail: "", options: []), resolve: { _ in .deny("declined") })
        var laterRan = false
        let gates: [@MainActor () -> ToolDecision] = [{ ask }, { laterRan = true; return .allow }]
        guard case .ask(_, let resolve) = ExtensionHost.chain(gates[...]), case .deny = resolve("no") else { return XCTFail() }
        XCTAssertFalse(laterRan)
        if case .allow = ExtensionHost.chain([][...]) {} else { XCTFail("no gates allow") }
    }

    // MARK: Output bookkeeping

    func testOutputCollectorCountsOnlyTheOverflow() {
        let c = OutputCollector(limit: 10)
        c.append(Data(repeating: 1, count: 15))
        XCTAssertEqual(c.dropped, 5)
        c.append(Data(repeating: 1, count: 4))
        XCTAssertEqual(c.dropped, 9)
    }
}
