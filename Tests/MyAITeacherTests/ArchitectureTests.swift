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
            _ = try db.transaction { try db.execute("INSERT INTO t VALUES(1)") }
            throw SQLiteError(message: "outer")
        })
        XCTAssertEqual(try count(), 0)
        // The connection is usable afterwards (no transaction left open).
        _ = try db.transaction { try db.execute("INSERT INTO t VALUES(4)") }
        XCTAssertEqual(try count(), 1)
    }

    func testRunReportsFailureInsteadOfThrowing() {
        XCTAssertNil(db.run("INSERT INTO missing_table VALUES(1)"))
        XCTAssertEqual(db.run("INSERT INTO t VALUES(?)", 7), 1)
    }

    func testInsertReturnsItsOwnRowOrNil() throws {
        let a = db.insert("INSERT INTO t VALUES(1)"), b = db.insert("INSERT INTO t VALUES(2)")
        XCTAssertNotNil(a); XCTAssertEqual(b, a.map { $0 + 1 })
        XCTAssertNil(db.insert("INSERT INTO missing_table VALUES(1)"), "a failed insert never reports an earlier row's id")
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

    func testFeatureModulesAddTheirToolsWithoutReordering() {
        // The order before modules existed: it shapes sub-agents' tool lists and Settings → Tools (lesson requests follow
        // AgentTree), so moving a tool into a module shouldn't reshuffle them unnoticed.
        XCTAssertEqual(ToolRegistry.all.map(\.name), [
            "read", "write", "edit", "ls", "glob", "grep", "bash", "run_code", "run_tests", "web_search", "web_fetch", "task",
            "agents", "load_tools", "visual", "todo_write", "ask_learner", "quiz", "math", "memory", "lesson_plan", "mastery",
            "flashcards", "project_memory", "browser", "mac", "computer"])
        XCTAssertEqual(Set(Features.all.map(\.id)).count, Features.all.count, "module ids are unique")
        for t in Features.tools { XCTAssertNotNil(ToolRegistry.byName[t.name], "\(t.name) reaches the registry") }
        XCTAssertEqual(Features.computerUse.tools.map(\.name), ["browser", "mac", "computer"])
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

final class StreamErrorTests: XCTestCase {
    /// In-stream errors keep their meaning: only overload and rate limits are transient.
    func testTypedStreamErrorsAreRetriedOnlyWhenTransient() {
        let transient = { (t: String) in ChatSession.isTransient(HTTPError(status: HTTPError.status(errorType: t), body: "")) }
        XCTAssertTrue(transient("overloaded_error"))
        XCTAssertTrue(transient("rate_limit_error"))
        XCTAssertTrue(transient("api_error"))
        XCTAssertFalse(transient("invalid_request_error"))
        XCTAssertFalse(transient("authentication_error"))
        XCTAssertFalse(transient("request_too_large"))
    }
}

final class BlobCacheTests: XCTestCase {
    func testLRUIsBoundedByBytesAndKeepsRecentlyUsed() {
        var c = BlobStore.LRU(limit: 10)
        c.put("a", "1234"); c.put("b", "1234")
        XCTAssertEqual(c.get("a"), "1234")          // a is now the most recent
        c.put("c", "1234")                           // 12 bytes > 10: the least recent (b) goes
        XCTAssertNil(c.get("b"))
        XCTAssertNotNil(c.get("a")); XCTAssertNotNil(c.get("c"))
        XCTAssertLessThanOrEqual(c.bytes, 10)
        c.put("huge", String(repeating: "x", count: 11))
        XCTAssertNil(c.get("huge"), "an entry bigger than the cache isn't kept")
        c.put("a", "12"); XCTAssertEqual(c.bytes, 6, "replacing an entry recounts its size")
    }

    func testBase64ComesBackFromTheCacheAfterTheFileIsGone() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("blobs-\(UUID().uuidString.prefix(6))")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = BlobStore(dir: dir)
        let payload = Data((0..<40_000).map { UInt8($0 % 251) }).base64EncodedString()
        let ref = try XCTUnwrap(store.put(base64: payload))
        XCTAssertEqual(BlobStore.base64(ref), payload)
        try FileManager.default.removeItem(at: BlobStore.file(ref, in: dir))
        XCTAssertEqual(BlobStore.base64(ref), payload, "served from the cache, no disk read")
        BlobStore.releaseMemory()
        XCTAssertNil(BlobStore.base64(ref), "after memory pressure it is read from disk again")
    }
}

final class FetchCacheTests: XCTestCase {
    func testAPageLargerThanTheCacheDoesNotEvictEverything() async {
        let c = FetchCache()
        await c.put("a", "small page", nil)
        await c.put("huge", String(repeating: "x", count: FetchCache.maxChars + 1), nil)
        let a = await c.get("a"), huge = await c.get("huge")
        XCTAssertNotNil(a, "the other pages stay")
        XCTAssertNil(huge, "an oversized page isn't cached")
        let n = await c.cachedChars
        XCTAssertLessThanOrEqual(n, FetchCache.maxChars)
    }
}

@MainActor
final class InteractionWaitTests: XCTestCase {
    func testCancellingTheWaitingTaskEndsTheWaitAndClosesTheCard() async {
        let center = InteractionCenter()
        let waiter = Task { await center.request(id: "c1", kind: "quiz", conversationID: "L", payload: [:]) }
        while center.pending["c1"] == nil { await Task.yield() }
        waiter.cancel()
        let reply = await waiter.value
        XCTAssertEqual(reply["cancelled"]?.bool, true)
        XCTAssertNil(center.pending["c1"], "the card goes with the wait")
    }

    func testASecondRequestUnderTheSameIdReleasesTheFirst() async {
        let center = InteractionCenter()
        let first = Task { await center.request(id: "c1", kind: "permission", conversationID: "L", payload: [:]) }
        while center.pending["c1"] == nil { await Task.yield() }
        let second = Task { await center.request(id: "c1", kind: "permission", conversationID: "L", payload: [:]) }
        let r1 = await first.value
        XCTAssertEqual(r1["cancelled"]?.bool, true, "the first waiter is not orphaned")
        while center.pending["c1"] == nil { await Task.yield() }
        center.resolve("c1", ["decision": "once"])
        let r2 = await second.value
        XCTAssertEqual(r2["decision"]?.string, "once")
    }
}
