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

/// Sub-agent context: older tool results inside one brief are stubbed, the latest kept; never with signed thinking.
final class SubAgentLeanTests: XCTestCase {
    private func run(signed: Bool) -> [ChatMessage] {
        var msgs = [ChatMessage(role: .user, blocks: [.text("brief")])]
        for i in 0..<6 {
            var a = ChatMessage(role: .assistant, blocks: [.toolUse(id: "c\(i)", name: "web_fetch", input: ["url": "u"])])
            if signed { a.blocks.insert(.thinking("why", signature: "sig"), at: 0) }
            msgs.append(a)
            msgs.append(ChatMessage(role: .user, blocks: [.toolResult(id: "c\(i)", name: "web_fetch", content: String(repeating: "x", count: 40_000))]))
        }
        return SubAgent.lean(msgs)
    }

    func testOlderResultsInsideOneBriefAreStubbed() {
        let sizes = run(signed: false).filter(\.isToolResultOnly).map { $0.blocks[0].text?.count ?? 0 }
        XCTAssertEqual(sizes.count, 6)
        XCTAssertTrue(sizes.prefix(2).allSatisfy { $0 < 2_000 }, "older results stubbed: \(sizes)")
        XCTAssertTrue(sizes.suffix(SubAgent.recentResultsKept).allSatisfy { $0 == 40_000 }, "latest kept verbatim")
    }

    func testSignedThinkingKeepsResultsIntact() {
        XCTAssertTrue(run(signed: true).filter(\.isToolResultOnly).allSatisfy { $0.blocks[0].text?.count == 40_000 })
    }
}

/// Compaction, apart from the lesson loop: the range a summary replaces and the summary calls.
final class CompactionTests: XCTestCase {
    /// Learner/teacher pairs of `chars` characters each.
    private func lesson(_ turns: Int, _ text: (Int) -> String) -> [ChatMessage] {
        (0..<turns).flatMap { i in [ChatMessage(role: .user, blocks: [.text(text(i))]), ChatMessage(role: .assistant, blocks: [.text(text(i))])] }
    }

    func testRangeKeepsAShareOfTheBudgetAndStartsTheTailWithTheLearner() throws {
        let msgs = lesson(20) { _ in String(repeating: "a", count: 4_000) }   // ~1k tokens per message
        let r = try XCTUnwrap(Compaction.summaryRange(msgs, compactedThrough: nil, budget: 10_000))
        XCTAssertEqual(r.lowerBound, 0)
        XCTAssertEqual(msgs[r.upperBound].role, .user, "the verbatim tail starts with a learner message")
        let kept = ContextPolicy.estimateTokens(Array(msgs[r.upperBound...]))
        XCTAssertLessThanOrEqual(kept, 3_000 + 1_000)
    }

    func testRangeCountsCJKInTokens() throws {
        // 1,000 CJK characters ≈ 1,000 tokens (counting chars ÷ 4 kept 4× too much).
        let msgs = lesson(20) { _ in String(repeating: "学", count: 1_000) }
        let r = try XCTUnwrap(Compaction.summaryRange(msgs, compactedThrough: nil, budget: 10_000))
        XCTAssertLessThanOrEqual(ContextPolicy.estimateTokens(Array(msgs[r.upperBound...])), 4_000)
    }

    func testRangeStartsAfterThePreviousCompaction() throws {
        let msgs = lesson(20) { _ in String(repeating: "a", count: 4_000) }
        let r = try XCTUnwrap(Compaction.summaryRange(msgs, compactedThrough: msgs[5].id, budget: 10_000))
        XCTAssertEqual(r.lowerBound, 6)
        XCTAssertNil(Compaction.summaryRange(msgs, compactedThrough: msgs[r.upperBound - 1].id, budget: 10_000), "nothing new to summarise")
        XCTAssertNil(Compaction.summaryRange(Array(msgs.prefix(2)), compactedThrough: nil, budget: 100_000), "small lessons stay whole")
    }

    private struct Scripted: LLMClient {
        let reply: String
        func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.text(reply)); c.yield(.usage(Usage(input: 100, output: 20))); c.yield(.stop("end_turn")); c.finish()
            }
        }
    }

    func testSummaryUsesTheModelAndCountsEveryCall() async {
        let msgs = lesson(3) { "turn \($0) about momentum" }
        let good = String(repeating: "Goal: momentum. ", count: 10)
        let s = await Compaction.summarise(msgs, previous: nil, state: "", client: Scripted(reply: "<think>x</think>" + good), model: "m", sessionID: "c")
        XCTAssertFalse(s.cancelled)
        XCTAssertEqual(s.text, good.trimmingCharacters(in: .whitespaces), "reasoning before </think> is dropped")
        XCTAssertEqual(s.usage.count, 1)
        XCTAssertEqual(s.usage.first?.output, 20)
    }

    func testFailedSummaryFallsBackToADigestWithTheCourseState() async {
        let msgs = lesson(3) { "turn \($0) about momentum" }
        let s = await Compaction.summarise(msgs, previous: nil, state: "Focus: collisions", client: Scripted(reply: "ok"), model: "m", sessionID: "c")
        XCTAssertTrue(s.text.contains("Learner: turn 0 about momentum"), s.text)
        XCTAssertTrue(s.text.contains("Focus: collisions"))
    }
}

/// The tool registry is declared once; everything else is derived from it and must stay consistent.
final class ToolRegistryTests: XCTestCase {
    func testSubAgentPoolIsDerivedAndUnchanged() {
        let names = Set(ToolRegistry.subagentPool.map(\.name))
        XCTAssertEqual(names, ["read", "ls", "glob", "grep", "web_search", "web_fetch", "math", "memory", "write", "edit", "bash", "run_code", "task", "agents"])
        XCTAssertEqual(ToolRegistry.subagentPool.count, names.count, "no duplicates")
        let memory = ToolRegistry.subagentPool.first { $0.name == "memory" } as? MemoryTool
        XCTAssertEqual(memory?.readOnly, true, "sub-agents only search memory")
        XCTAssertFalse(ToolRegistry.subagentPool.contains { $0.risk == .interactive }, "sub-agents can't wait for the learner")
    }

    func testEveryToolAnAgentCanGetExists() {
        XCTAssertEqual(ToolRegistry.byName.count, ToolRegistry.all.count, "tool names are unique")
        for node in AgentTree.nodes {
            for name in AgentTree.core(node.id) + AgentTree.deferred(node.id) {
                XCTAssertNotNil(ToolRegistry.byName[name], "\(node.id) refers to unknown tool \(name)")
            }
        }
    }
}
