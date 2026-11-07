import XCTest
@testable import MyAITeacher

/// Compaction that keeps what matters, `/compact` and `/context`, repeat reads that don't resend a file, and a bound on
/// what one step adds.
final class ContextManagementTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ctxm-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Facts a summary keeps

    private func facts() -> ContextFacts {
        var f = ContextFacts()
        f.goal = "Course: Parsers. Focus: C2 recursive descent"
        f.todos = [("in_progress", "Fix the tokenizer"), ("pending", "Add tests")]
        f.project = ("Calc", "swift test", "3 passed, 1 failed — failing: testPrecedence")
        f.changedFiles = (0..<200).map { "Sources/File\($0).swift" }
        f.running = ["B1 server: npm run dev"]
        f.recentReads = ["Sources/Lexer.swift", "Package.swift"]
        return f
    }

    func testFactsFitTheirBudgetAndKeepTheWholeStateOfSmallLists() {
        let text = facts().render(tokens: 400)
        XCTAssertLessThanOrEqual(ContextPolicy.estimate(text), 420)
        for must in ["recursive descent", "[in_progress] Fix the tokenizer", "swift test", "testPrecedence", "B1 server", "Sources/Lexer.swift", "Sources/File0.swift"] {
            XCTAssertTrue(text.contains(must), must)
        }
        XCTAssertTrue(text.contains("more"), "the long file list is cut by whole lines and says so")
    }

    func testFactsAreStableAndAnOldSectionIsReplacedNotStacked() {
        let a = facts().appended(to: "Goal: parse.", budget: 64_000), b = facts().appended(to: "Goal: parse.", budget: 64_000)
        XCTAssertEqual(a, b, "same facts, same bytes: the prefix stays cacheable")
        let again = facts().appended(to: a, budget: 64_000)
        XCTAssertEqual(again, a)
        XCTAssertEqual(again.components(separatedBy: ContextFacts.marker).count, 2)
        XCTAssertEqual(ContextFacts().appended(to: "only text", budget: 1000), "only text")
    }

    func testSummaryPromptNamesWhatMustSurviveAndFocus() {
        let p = Compaction.prompt([ChatMessage(role: .user, blocks: [.text("hi")])], previous: "old\n\n" + ContextFacts.marker + "\n- x", state: "", focus: "the parser")
        for h in ["Decisions & why", "Open tasks", "misconceptions", "Errors & how they were solved", "Tests & status", "exactly", "the parser"] {
            XCTAssertTrue(p.contains(h), h)
        }
    }

    // MARK: Commands

    func testContextCommands() {
        XCTAssertEqual(ContextCommand.parse("/compact"), .compact(focus: nil))
        XCTAssertEqual(ContextCommand.parse("/compact  keep everything about the parser "), .compact(focus: "keep everything about the parser"))
        XCTAssertEqual(ContextCommand.parse("/context"), .context)
        XCTAssertNil(ContextCommand.parse("/context now?"))
        XCTAssertNil(ContextCommand.parse("compact"))
        XCTAssertNil(ContextCommand.parse("/quiz"))
    }

    func testAShortLessonHasNothingToCompactAndALongOneKeepsItsTail() {
        let short = [ChatMessage(role: .user, blocks: [.text("hi")]), ChatMessage(role: .assistant, blocks: [.text("hello")])]
        XCTAssertNil(Compaction.summaryRange(short, compactedThrough: nil, budget: 64_000, keep: 0.1))
        let long = (0..<20).flatMap { n in [ChatMessage(role: .user, blocks: [.text("q\(n) " + String(repeating: "w ", count: 800))]),
                                              ChatMessage(role: .assistant, blocks: [.text("a\(n) " + String(repeating: "w ", count: 800))])] }
        let manual = Compaction.summaryRange(long, compactedThrough: nil, budget: 64_000, keep: 0.1)
        XCTAssertNil(Compaction.summaryRange(long, compactedThrough: nil, budget: 64_000), "automatic compaction keeps 30% verbatim: nothing to do")
        XCTAssertNotNil(manual)
        XCTAssertEqual(long[manual!.upperBound].role, .user, "the kept tail starts with a learner message")
    }

    func testContextReportNamesTheBiggestThing() {
        let msgs = [ChatMessage(role: .user, blocks: [.text("go")]),
                    ChatMessage(role: .assistant, blocks: [.thinking("hmm"), .toolUse(id: "a", name: "bash", input: ["command": "ls"])]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "a", name: "bash", content: String(repeating: "line of output\n", count: 3000))])]
        let c = Conversation(providerID: "x", model: "m")
        let r = ContextReport.build(system: "You are a tutor.", memory: "", deferred: "", tools: [], prepared: msgs, raw: msgs, conversation: c, budget: 64_000, window: 128_000)
        XCTAssertEqual(r.biggest?.name, "Tool results")
        XCTAssertEqual(r.history.map(\.name), ["Messages", "Tool results", "Images", "Reasoning"])
        XCTAssertTrue(r.lines.joined().contains("Biggest: Tool results"))
    }

    // MARK: Repeat reads

    @MainActor private func ctx(_ call: String, live: Set<String>?) -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: "L-\(dir.lastPathComponent)", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: call,
                            client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.liveResults = live
        return c
    }

    @MainActor func testRepeatReadIsAShortNoteOnlyWhileTheEarlierResultIsLive() async throws {
        let f = dir.appendingPathComponent("a.txt")
        try String(repeating: "alpha\n", count: 500).write(to: f, atomically: true, encoding: .utf8)
        let first = try await ReadTool().run(["path": "a.txt"], ctx("r1", live: []))
        XCTAssertGreaterThan(first.text.count, 2_000)
        // The earlier result is live: a note.
        let again = try await ReadTool().run(["path": "a.txt"], ctx("r2", live: ["r1"]))
        XCTAssertTrue(again.text.hasPrefix("Unchanged since you read it"))
        XCTAssertEqual(again.meta?["sameAs"]?.string, "r1")
        // Not among the live ones (stubbed by microcompaction, summarised, or no history to check): the file.
        let stubbed = try await ReadTool().run(["path": "a.txt"], ctx("r3", live: ["other"]))
        XCTAssertEqual(stubbed.text, first.text)
        let noHistory = try await ReadTool().run(["path": "a.txt"], ctx("r4", live: nil))
        XCTAssertEqual(noHistory.text, first.text, "sub-agents and the CLI always get the file")
        // A different range is a different read.
        let other = try await ReadTool().run(["path": "a.txt", "offset": 10, "limit": 5], ctx("r5", live: ["r1", "r3"]))
        XCTAssertFalse(other.text.hasPrefix("Unchanged"))
        // A changed file is read again.
        try String(repeating: "beta\n", count: 501).write(to: f, atomically: true, encoding: .utf8)
        let changed = try await ReadTool().run(["path": "a.txt"], ctx("r6", live: ["r1", "r3"]))
        XCTAssertTrue(changed.text.contains("beta"))
    }

    func testANoteWhoseEarlierResultWasStubbedOrSummarisedBecomesTheFileAgain() {
        let file = String(repeating: "let x = 1\n", count: 400)
        func lesson() -> [ChatMessage] {
            var m: [ChatMessage] = []
            for n in 0..<6 {
                m.append(ChatMessage(role: .user, blocks: [.text("q\(n)")]))
                m.append(ChatMessage(role: .assistant, blocks: [.toolUse(id: "r\(n)", name: "read", input: ["path": "a"])]))
                m.append(ChatMessage(role: .user, blocks: [n == 0 ? .toolResult(id: "r0", name: "read", content: file)
                                                           : .toolResult(id: "r\(n)", name: "read", content: "Unchanged since you read it: a",
                                                                         meta: ["sameAs": "r0"])]))
                m.append(ChatMessage(role: .assistant, blocks: [.text("a\(n)")]))
            }
            return m
        }
        let msgs = lesson()
        var c = Conversation(providerID: "x", model: "m")
        // Nothing trimmed: the notes stay short.
        var out = ContextPolicy.prepare(msgs, conversation: c, model: "m")
        XCTAssertTrue(out[10].blocks[0].text!.hasPrefix("Unchanged"))
        // Microcompaction stubs the first read: the notes after it carry the file (and are themselves stubbed only by the usual rule).
        c.trimmedThrough = ContextPolicy.nextTrimPoint(msgs, current: nil)
        out = ContextPolicy.prepare(msgs, conversation: c, model: "m")
        XCTAssertTrue(out[2].blocks[0].text!.contains("chars trimmed"), "the first read is stubbed")
        let recent = out.last { $0.isToolResultOnly }!.blocks[0].text!
        XCTAssertEqual(recent, file, "the model still has the content, in the repeat that is still recent")
        // Summary compaction swallows the first read: same.
        c.trimmedThrough = nil
        c.compactedThrough = msgs[3].id; c.compactSummary = "summary"
        out = ContextPolicy.prepare(msgs, conversation: c, model: "m")
        XCTAssertEqual(out.last { $0.isToolResultOnly }!.blocks[0].text, file)
        // The earlier read is not loaded at all (paged out): the model is told to read again.
        out = ContextPolicy.prepare(Array(msgs[8...]), conversation: Conversation(providerID: "x", model: "m"), model: "m")
        XCTAssertTrue(out.first { $0.isToolResultOnly }!.blocks[0].text!.contains("read"))
        XCTAssertFalse(out.first { $0.isToolResultOnly }!.blocks[0].text!.hasPrefix("Unchanged since you read it: a"))
    }

    func testLiveResultsExcludeStubbedCutAndOverBudgetHistory() {
        let msgs = (0..<6).flatMap { n in [ChatMessage(role: .user, blocks: [.text("q\(n)")]),
                                          ChatMessage(role: .user, blocks: [.toolResult(id: "t\(n)", name: "read", content: "x")])] }
        var c = Conversation(providerID: "x", model: "m")
        XCTAssertEqual(ContextPolicy.liveResults(msgs, conversation: c, model: "m", budget: 10_000).count, 6)
        c.trimmedThrough = msgs[3].id
        XCTAssertEqual(ContextPolicy.liveResults(msgs, conversation: c, model: "m", budget: 10_000), ["t2", "t3", "t4", "t5"])
        XCTAssertTrue(ContextPolicy.liveResults(msgs, conversation: c, model: "m", budget: 1).isEmpty, "over budget the squeeze may cut anything")
    }

    // MARK: Bounding a step

    func testAStepIsBoundedAndTheFullOutputIsKept() throws {
        let big = (0..<6).map { Block.toolResult(id: "g\($0)", name: "grep", content: String(repeating: "match line \($0)\n", count: 4_000)) }
        let small = Block.toolResult(id: "s", name: "bash", content: "ok")
        let limit = StepCap.limit(budget: 64_000)
        let out = StepCap.apply(big + [small], limit: limit, dir: dir.appendingPathComponent("outputs"))
        XCTAssertLessThanOrEqual(out.reduce(0) { $0 + ($1.text?.count ?? 0) }, limit + 1_000)
        XCTAssertEqual(out.last?.text, "ok", "small results are never touched")
        let capped = out.compactMap(\.text).filter { $0.contains("Full output saved to") }
        XCTAssertFalse(capped.isEmpty)
        let path = capped[0].components(separatedBy: "saved to ")[1].components(separatedBy: ":")[0]
        XCTAssertEqual((try String(contentsOfFile: path, encoding: .utf8)).count, big[out.firstIndex { $0.text == capped[0] }!].text!.count)
        // Under the limit: untouched.
        XCTAssertEqual(StepCap.apply([small], limit: limit, dir: dir).first?.text, "ok")
    }

    // MARK: A scripted long lesson

    /// 30 turns over four files and parallel greps against a small budget, with and without the new behaviour: the tokens
    /// sent over the lesson, and whether the model ever lost a file's content to a "unchanged" note.
    @MainActor func testScriptedLongLessonSendsLessAndNeverLosesAFile() async throws {
        let budget = 24_000
        func run(dedupe: Bool, cap: Bool) async throws -> (sent: Int, notes: Int) {
            for i in 0..<4 { try String(repeating: "line \(i) of file\n", count: 400).write(to: dir.appendingPathComponent("f\(i).txt"), atomically: true, encoding: .utf8) }
            var msgs: [ChatMessage] = [], c = Conversation(providerID: "x", model: "m")
            var sent = 0, notes = 0, call = 0
            let tag = "d\(dedupe)c\(cap)"
            func request() throws {
                if ContextPolicy.estimateTokens(msgs) > budget * 7 / 10, let next = ContextPolicy.nextTrimPoint(msgs, current: c.trimmedThrough) { c.trimmedThrough = next }
                let prepared = ContextPolicy.prepare(msgs, conversation: c, model: "m")
                sent += ContextPolicy.estimateTokens(prepared)
                // The model must always have the content behind a note: its target is in the request, whole.
                for m in prepared { for b in m.blocks where b.meta?["sameAs"]?.string != nil {
                    notes += 1
                    let target = prepared.flatMap(\.blocks).first { $0.kind == .toolResult && $0.id == b.meta?["sameAs"]?.string }
                    XCTAssertNotNil(target); XCTAssertFalse(target?.text?.contains("chars trimmed") ?? true)
                } }
            }
            for turn in 0..<30 {
                msgs.append(ChatMessage(role: .user, blocks: [.text("turn \(turn)")]))
                try request()
                var uses: [Block] = [], results: [Block] = []
                if turn % 5 == 4 {   // the file changes now and then
                    let f = dir.appendingPathComponent("f\(turn % 4).txt")
                    try (String(contentsOf: f, encoding: .utf8) + "extra\(turn)\n").write(to: f, atomically: true, encoding: .utf8)
                }
                for i in 0..<4 {
                    call += 1
                    let id = "\(tag)\(call)"
                    uses.append(.toolUse(id: id, name: "read", input: ["path": .string("f\(i).txt")]))
                    let live = dedupe ? ContextPolicy.liveResults(msgs, conversation: c, model: "m", budget: budget) : nil
                    var cx = ctx(id, live: live); cx.shellID = "agent-\(tag)"
                    let out = try await ReadTool().run(["path": .string("f\(i).txt")], cx)
                    results.append(.toolResult(id: id, name: "read", content: out.text, meta: out.meta))
                }
                for i in 0..<3 {
                    call += 1
                    uses.append(.toolUse(id: "\(tag)\(call)", name: "grep", input: ["pattern": .string("p\(i)")]))
                    results.append(.toolResult(id: "\(tag)\(call)", name: "grep", content: String(repeating: "src/file.swift:12: match here\n", count: 1_600)))
                }
                if cap { results = StepCap.apply(results, limit: StepCap.limit(budget: budget), dir: dir.appendingPathComponent("outputs")) }
                msgs.append(ChatMessage(role: .assistant, blocks: uses))
                msgs.append(ChatMessage(role: .user, blocks: results))
                try request()
                msgs.append(ChatMessage(role: .assistant, blocks: [.text("answer \(turn)")]))
            }
            return (sent, notes)
        }
        let before = try await run(dedupe: false, cap: false), reads = try await run(dedupe: true, cap: false)
        let capOnly = try await run(dedupe: false, cap: true), after = try await run(dedupe: true, cap: true)
        func less(_ x: Int) -> Int { 100 - x * 100 / before.sent }
        print("SCRIPTED LESSON tokens sent over 30 turns: before \(before.sent); repeat reads only \(reads.sent) (-\(less(reads.sent))%); step cap only \(capOnly.sent) (-\(less(capOnly.sent))%); both \(after.sent) (-\(less(after.sent))%); notes sent: \(after.notes)")
        XCTAssertLessThan(after.sent, before.sent * 8 / 10)
        XCTAssertGreaterThan(after.notes, 0)
    }

    // MARK: Review fixes

    @MainActor func testAReportDeliveredDuringACompactionIsAdoptedNotLost() {
        let conv = Conversation(providerID: "x", model: "m")
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        session.holdBusyForTests(true)   // a /compact (or a turn) is running
        session.deliver(ChatMessage(role: .user, blocks: [Block(kind: .text, text: "report from B1", meta: ["backgroundTask": "B1"])]))
        XCTAssertEqual(session.queuedReports, 1)
        XCTAssertTrue(session.messages.isEmpty)
        session.holdBusyForTests(false)
        session.adoptInbox(wake: false)
        XCTAssertEqual(session.queuedReports, 0)
        XCTAssertEqual(session.messages.count, 1, "the report joins the lesson when the compaction ends")
    }

    func testRepeatReadStaysLiveInACompactedLessonWhoseStoredHistoryIsOverBudget() {
        let old = (0..<20).flatMap { n in [ChatMessage(role: .user, blocks: [.text("old \(n)")]),
                                          ChatMessage(role: .user, blocks: [.toolResult(id: "o\(n)", name: "read", content: String(repeating: "x", count: 20_000))])] }
        let recent = [ChatMessage(role: .user, blocks: [.text("now")]), ChatMessage(role: .user, blocks: [.toolResult(id: "fresh", name: "read", content: "small")])]
        var c = Conversation(providerID: "x", model: "m")
        c.compactedThrough = old.last!.id; c.compactSummary = "summary"
        let msgs = old + recent
        XCTAssertGreaterThan(ContextPolicy.estimateTokens(msgs), 20_000, "the stored lesson is over the budget")
        XCTAssertEqual(ContextPolicy.liveResults(msgs, conversation: c, model: "m", budget: 20_000), ["fresh"], "the request is small, so the note is allowed")
    }

    func testLiveResultsLeaveOutFailedRunningNotesCappedAndAdaptiveClaude() {
        let blocks: [Block] = [.toolResult(id: "ok", name: "read", content: "x"), .toolResult(id: "bad", name: "read", content: "x", isError: true),
                               .toolResult(id: "run", name: "read", content: "", meta: ["running": true]),
                               .toolResult(id: "note", name: "read", content: "n", meta: ["sameAs": "ok"]),
                               .toolResult(id: "cap", name: "grep", content: "x", meta: ["stepCapped": true]),
                               .toolResult(id: "spill", name: "read", content: "preview… saved to .teacher/outputs/x.txt", meta: ["spilled": true])]   // only a preview was kept
        let msgs = [ChatMessage(role: .user, blocks: [.text("go")]), ChatMessage(role: .user, blocks: blocks)]
        let c = Conversation(providerID: "x", model: "m")
        XCTAssertEqual(ContextPolicy.liveResults(msgs, conversation: c, model: "m", budget: 10_000), ["ok"])
        XCTAssertTrue(ContextPolicy.liveResults(msgs, conversation: c, model: "claude-sonnet-5-5", budget: 10_000).isEmpty)
    }

    func testANoteIsDemotedWhenTheSqueezeCutItsTarget() {
        let file = (0..<3000).map { "let value\($0) = \($0)" }.joined(separator: "\n")
        let msgs = [ChatMessage(role: .user, blocks: [.text("go")]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "r0", name: "read", content: file)]),
                    ChatMessage(role: .user, blocks: [.text("again")]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "r1", name: "read", content: "Unchanged since you read it", meta: ["sameAs": "r0"])])]
        let squeezed = ContextPolicy.squeeze(msgs, budget: 3_000)
        XCTAssertTrue(squeezed[1].blocks[0].text!.contains("trimmed to fit the context"))
        let out = ContextPolicy.demoteSqueezedNotes(squeezed)
        XCTAssertNil(out[3].blocks[0].meta?["sameAs"])
        XCTAssertTrue(out[3].blocks[0].text!.contains("read"), "told to read the file again")
        XCTAssertFalse(out[3].blocks[0].text!.hasPrefix("Unchanged"))
        // Not squeezed: the note stays.
        XCTAssertEqual(ContextPolicy.demoteSqueezedNotes(msgs)[3].blocks[0].meta?["sameAs"]?.string, "r0")
    }

    @MainActor func testFilesASubAgentChangedReachTheSummaryFacts() {
        let conv = Conversation(providerID: "x", model: "m")
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        TouchedFiles.record(conversation: session.id, path: dir.appendingPathComponent("Sources/A.swift").path)   // what SubAgent records
        TouchedFiles.record(conversation: "other-lesson", path: "/elsewhere/B.swift")
        let f = session.contextFacts(state: "")
        XCTAssertEqual(f.changedFiles, ["Sources/A.swift"])
        XCTAssertEqual(session.conversation.touchedFiles?.count, 1)
        XCTAssertEqual(TouchedFiles.take(conversation: "other-lesson"), ["/elsewhere/B.swift"], "another lesson's files are its own")
    }

    func testAResultThatQuotesTheSpillPhraseIsStillSpilledByTheCap() throws {
        let quoting = "Full output saved to /nowhere/x.txt\n" + String(repeating: "page text line\n", count: 4_000)
        let out = StepCap.apply([.toolResult(id: "w", name: "web_fetch", content: quoting)], limit: 20_000, dir: dir.appendingPathComponent("outputs"))
        let text = out[0].text!
        let path = text.components(separatedBy: "Full output saved to ").last!.components(separatedBy: ":")[0]
        XCTAssertTrue(FileManager.default.fileExists(atPath: path), "a real copy exists where the note says")
        XCTAssertNotEqual(path, "/nowhere/x.txt")
        // A result the app itself spilled is marked, and gets no second copy.
        let spilled = Block.toolResult(id: "b", name: "bash", content: String(repeating: "y", count: 30_000) + "\n… [Full output saved to /real.txt — use read]", meta: ["spilled": true])
        XCTAssertTrue(StepCap.apply([spilled], limit: 20_000, dir: dir.appendingPathComponent("o2"))[0].text!.contains("saved at the path given at the end"))
    }

    @MainActor func testContextShowsWhileAReplyRunsButCompactWaits() {
        let conv = Conversation(providerID: "x", model: "m")
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        session.holdBusyForTests(true)
        session.send("/compact")
        XCTAssertFalse(session.showContext)
        session.send("/context")
        XCTAssertTrue(session.showContext, "free and read-only: no reason to wait")
        session.holdBusyForTests(false)
    }

    @MainActor func testALiteralMessageIsNeverTheBuiltInContextCommand() {
        let conv = Conversation(providerID: "x", model: "m")
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        session.holdBusyForTests(true)   // a literal message is not a command, so it goes on to wait for the running reply instead
        session.send("/context", literal: true)   // what a custom command whose body is `/context` sends
        XCTAssertFalse(session.showContext, "it is text for the model, not the built-in")
        session.send("/context")
        XCTAssertTrue(session.showContext)
        session.holdBusyForTests(false)
    }

    func testNothingToCompactIsWordedByCause() {
        XCTAssertTrue(ContextCommand.nothingToCompact(messages: 2, turns: 1, tokens: 500).contains("short"))
        let one = ContextCommand.nothingToCompact(messages: 60, turns: 1, tokens: 90_000)
        XCTAssertTrue(one.contains("one long turn")); XCTAssertFalse(one.contains("short"))
        XCTAssertTrue(ContextCommand.nothingToCompact(messages: 60, turns: 5, tokens: 9_000).contains("already summarised"))
    }
}
