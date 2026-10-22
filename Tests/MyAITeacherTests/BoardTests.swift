import XCTest
@testable import MyAITeacher

/// The course board: one focus card, a parked lane, evidence-gated completion, stable ids, a capped header the app
/// appends to every request, and the `lesson_plan` tool contract over it.
final class BoardTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var ctx: ToolContext!
    var study: StudyStore { services.study }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("board-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        ctx = await context("lesson-a")
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func context(_ lesson: String) -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: lesson, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }

    func plan(_ input: JSON, _ c: ToolContext? = nil) async throws -> ToolOutput { try await LessonPlanTool().run(input, c ?? ctx) }

    func sample() throws -> CourseBoard {
        var b = CourseBoard(plan: LessonPlan(id: "plan-1", title: "Calculus I", subject: "calculus", goal: "be ready for the final", data: [:], updatedAt: Date()))
        try b.add(title: "Limits and continuity", lane: .doing, next: "three one-sided-limit problems, then a continuity check",
                  objectives: ["graphical limits", "one-sided limits"], concept: "one-sided limits")
        try b.add(title: "Derivatives", after: ["c1"])
        try b.add(title: "Applications", after: ["c2"])
        try b.add(title: "Review: one-sided limits", lane: .review)
        return b
    }

    // MARK: Model

    func testOneFocusCardAndEvidenceGatedCompletion() throws {
        var b = try sample()
        XCTAssertEqual(b.focusID, "c1")
        XCTAssertThrowsError(try b.start("c2")) { XCTAssertTrue("\($0)".contains("C1"), "the error names the current focus: \($0)") }
        XCTAssertThrowsError(try b.complete("c1", evidence: "  ")) { XCTAssertTrue("\($0)".contains("evidence"), "\($0)") }
        XCTAssertThrowsError(try b.park("c1", reason: "")) { XCTAssertTrue("\($0)".contains("reason"), "\($0)") }
        XCTAssertThrowsError(try b.add(title: "tangent", lane: .parked)) { XCTAssertTrue("\($0)".contains("reason"), "\($0)") }
        try b.start("c2", replace: true)
        XCTAssertEqual(b.focusID, "c2"); XCTAssertEqual(b.card("c1")?.lane, .backlog)
        try b.start("c1", replace: true)
        try b.complete("c1", evidence: "3/3 one-sided limits unaided")
        XCTAssertNil(b.focusID); XCTAssertEqual(b.card("C1")?.lane, .done); XCTAssertEqual(b.card("c1")?.evidence, ["3/3 one-sided limits unaided"])
        try b.start("Deriv")   // title prefix
        XCTAssertEqual(b.focusID, "c2")
        XCTAssertEqual(b.revision, 8); XCTAssertEqual(b.log.count, 8); XCTAssertEqual(b.log.last?.event, "start")
    }

    func testDetoursParkAndResumeWithoutMovingTheFocus() throws {
        var b = try sample()
        let p = try b.add(title: "Why does 0.999… equal 1?", lane: .parked, reason: "learner tangent, answered; return if limits come up again")
        XCTAssertEqual(b.focusID, "c1", "a parked detour does not move the focus")
        XCTAssertEqual(b.lane(.parked).map(\.id), [p.id])
        XCTAssertThrowsError(try b.resume("c2")) { XCTAssertTrue("\($0)".contains("not parked"), "\($0)") }
        try b.park("c1", reason: "learner asked to switch to derivatives for the test tomorrow")
        XCTAssertNil(b.focusID)
        try b.resume(p.id)
        XCTAssertEqual(b.focusID, p.id); XCTAssertNil(b.card(p.id)?.parkedReason)
        XCTAssertEqual(b.card("c1")?.lane, .parked)
        XCTAssertEqual(b.courseCount, 4, "the resumed detour counts; the parked module does not")
    }

    func testNextActionsFollowPrerequisites() throws {
        var b = try sample()
        XCTAssertEqual(b.nextActions(2).map(\.id), ["c4"], "only the review card is unblocked while c1 is doing")
        try b.complete("c1", evidence: "quiz 5/5")
        XCTAssertEqual(b.nextActions(2).map(\.id), ["c2", "c4"])
        try b.complete("c4", evidence: "transfer question right")
        try b.complete("c2", evidence: "derivative rules 4/4")
        XCTAssertEqual(b.nextActions(1).map(\.id), ["c3"])
    }

    func testHeaderIsCompactWhateverTheCourseSize() throws {
        let b = try sample()
        let h = b.header(now: Date(), openLoop: "awaiting the attempt at lim x→2⁻ |x-2|/(x-2)", watch: "one-sided limits 62% (3/5)")
        XCTAssertTrue(h.hasPrefix("<lesson_state rev=\"4\" source=\"app\">\nCourse: Calculus I — be ready for the final · 0/4 done\nFocus: C1 Limits and continuity (doing)\nNext: three one-sided-limit problems, then a continuity check\nThen: C4 Review: one-sided limits (review)"), h)
        XCTAssertTrue(h.contains("Open loop: awaiting") && h.contains("Watch: one-sided") && h.hasSuffix("</lesson_state>"), h)
        XCTAssertLessThan(ContextPolicy.estimate(h), CourseBoard.headerTokenCap)
        var big = CourseBoard(plan: LessonPlan(id: "p", title: "A long course", subject: nil, goal: nil, data: [:], updatedAt: Date()))
        for i in 1...100 { try big.add(title: "Module \(i) with a fairly long descriptive title about topic number \(i)", next: "one concrete action for module \(i)") }
        try big.start("c1")
        for i in 2...30 { try big.add(title: "Parked question \(i) about something the learner asked", lane: .parked, reason: "tangent \(i)") }
        let bh = big.header()
        XCTAssertLessThanOrEqual(ContextPolicy.estimate(bh), CourseBoard.headerTokenCap, bh)
        XCTAssertTrue(bh.contains("Focus: C1 Module 1") && bh.contains("Next: one concrete action for module 1"), "focus and next survive the cap: \(bh)")
        XCTAssertFalse(bh.contains("Module 50"), "the header never lists the whole course")
        XCTAssertTrue(bh.contains("Parked (29)") && bh.contains("; …"), bh)
    }

    func testLegacyPlansConvertAndKeepIdsThroughAModulesUpdate() throws {
        let legacy = LessonPlan(id: "plan-old", title: "Zig", subject: "zig", goal: nil, data: ["modules": [
            ["title": "Orientation", "status": "done", "objectives": ["layout of std"]],
            ["title": "Allocators", "status": "in_progress", "objectives": ["why APIs take an Allocator"]],
            ["title": "Collections", "status": "todo"],
        ]], updatedAt: Date())
        var b = CourseBoard(plan: legacy)
        XCTAssertEqual(b.cards.map(\.id), ["c1", "c2", "c3"]); XCTAssertEqual(b.focusID, "c2"); XCTAssertEqual(b.card("c1")?.lane, .done)
        XCTAssertEqual(b.doneCount, 1); XCTAssertEqual(b.legacyModules.array?.count, 3)
        // The old lossy update: a one-module list no longer wipes the others' objectives silently — it is the full list,
        // but ids and objectives of matching titles survive, and an empty list is refused.
        XCTAssertThrowsError(try b.replaceModules([]))
        try b.replaceModules([["title": "Allocators", "status": "done"], ["title": "Collections", "status": "in_progress"], ["title": "Servers"]])
        XCTAssertEqual(b.cards.map(\.id), ["c2", "c3", "c4"])
        XCTAssertEqual(b.card("c2")?.objectives, ["why APIs take an Allocator"], "objectives survive a status-only rewrite")
        XCTAssertEqual(b.focusID, "c3")
        // Round-trips as version 2.
        let again = CourseBoard(plan: b.plan)
        XCTAssertEqual(again.cards.map(\.id), b.cards.map(\.id)); XCTAssertEqual(again.focusID, "c3"); XCTAssertEqual(again.revision, b.revision)
        XCTAssertEqual(again.log.count, b.log.count)
        // Corrupt data is an empty board, never a crash or a broken request.
        let corrupt = CourseBoard(plan: LessonPlan(id: "x", title: "x", subject: nil, goal: nil, data: ["version": 2, "cards": "nope", "focus": 3], updatedAt: Date()))
        XCTAssertTrue(corrupt.cards.isEmpty); XCTAssertNil(corrupt.focusID)
        XCTAssertTrue(corrupt.header().contains("the board is empty"))
    }

    func testLogIsCapped() throws {
        var b = try sample()
        for i in 0..<300 { try b.note("c1", text: "note \(i)") }
        XCTAssertEqual(b.log.count, CourseBoard.logCap); XCTAssertEqual(b.log.last?.note, "note 299"); XCTAssertEqual(b.revision, 304)
        for i in 0..<20 { _ = b.attachEvidence(concept: "One-Sided Limits", "quiz \(i)") }
        XCTAssertEqual(b.card("c1")?.evidence.count, CourseBoard.evidenceCap)
    }

    // MARK: Tool

    func testToolWalksACourseAndLinksTheLesson() async throws {
        var o = try await plan(["action": "add", "title": "x"])
        XCTAssertTrue(o.isError && o.text.contains("no board"), o.text)
        o = try await plan(["action": "create", "title": "Calculus I", "subject": "calculus", "goal": "pass the final", "deadline": "2099-01-01",
                            "modules": [["title": "Limits", "objectives": ["one-sided limits"], "next": "three one-sided-limit problems", "concept": "one-sided limits"],
                                        ["title": "Derivatives"], ["title": "Applications"]]])
        XCTAssertFalse(o.isError, o.text)
        let id = try XCTUnwrap(o.meta?["id"]?.string)
        XCTAssertTrue(o.text.contains("## Doing (1)") && o.text.contains("**C1** Limits — next: three one-sided-limit problems"), o.text)
        XCTAssertEqual(study.boardID(forLesson: "lesson-a"), id)
        XCTAssertEqual(o.meta?["plan"]?["cards"]?.array?.count, 3); XCTAssertEqual(o.meta?["plan"]?["modules"]?.array?.count, 3)
        o = try await plan(["action": "start", "card": "c2"])
        XCTAssertTrue(o.isError && o.text.contains("C1 Limits is doing"), o.text)
        o = try await plan(["action": "add", "title": "Python list mutation", "lane": "parked", "reason": "tangent; answered briefly"])
        XCTAssertFalse(o.isError, o.text)
        XCTAssertTrue(o.text.contains("Added C4") && o.text.contains("<lesson_state rev=\"2\"") && o.text.contains("Parked (1): Python list mutation"), o.text)
        o = try await plan(["action": "complete", "card": "C1"])
        XCTAssertTrue(o.isError && o.text.contains("evidence"), o.text)
        // Done by evidence while mastery is low: flagged, with a review card.
        _ = study.recordAttempt(subject: "calculus", concept: "one-sided limits", correct: true, note: nil)
        o = try await plan(["action": "complete", "card": "c1", "evidence": "3/3 unaided"])
        XCTAssertFalse(o.isError, o.text)
        XCTAssertTrue(o.text.contains("Done: C1 Limits.") && o.text.contains("added to Review"), o.text)
        var b = try XCTUnwrap(study.board(forLesson: "lesson-a"))
        XCTAssertEqual(b.lane(.review).count, 1); XCTAssertEqual(b.lane(.review)[0].source, "app"); XCTAssertNil(b.focusID)
        o = try await plan(["action": "start", "id": "c2", "next": "power rule on five functions"])
        XCTAssertTrue(o.text.contains("Focus: C2 Derivatives") && o.text.contains("Next: power rule on five functions"), o.text)
        o = try await plan(["action": "note", "card": "c2", "text": "chain rule is the weak spot"])
        XCTAssertTrue(o.text.contains("Focus: C2 Derivatives (doing) — chain rule is the weak spot"), o.text)
        o = try await plan(["action": "move", "card": "c3", "lane": "review"])
        b = try XCTUnwrap(study.board(forLesson: "lesson-a"))
        XCTAssertEqual(b.card("c3")?.lane, .review)
        o = try await plan(["action": "get"])
        XCTAssertTrue(o.text.contains("# Calculus I") && o.text.contains("## Done (1)") && o.text.contains("evidence: 3/3 unaided"), o.text)
        o = try await plan(["action": "list"])
        XCTAssertTrue(o.text.contains("\(id): Calculus I (calculus) — 1/4 done; focus C2 Derivatives ← this lesson"), o.text)
        // Another lesson has no board until it names one; naming it links it.
        let other = await context("lesson-b")
        o = try await plan(["action": "get"], other)
        XCTAssertTrue(o.isError, o.text)
        o = try await plan(["action": "get", "plan": .string(id)], other)
        XCTAssertFalse(o.isError, o.text); XCTAssertEqual(study.boardID(forLesson: "lesson-b"), id)
        o = try await plan(["action": "park", "card": "c2", "reason": "exam moved; derivatives next week"], other)
        XCTAssertFalse(o.isError, o.text)
        XCTAssertEqual(study.board(forLesson: "lesson-a")?.card("c2")?.lane, .parked, "one board, shared by both lessons")
        // The legacy contract still works: a full modules list.
        o = try await plan(["action": "update", "id": .string(id), "modules": [["title": "Derivatives", "status": "in_progress"], ["title": "Applications"], ["title": "Series"]]])
        XCTAssertFalse(o.isError, o.text)
        b = try XCTUnwrap(study.board(forLesson: "lesson-a"))
        XCTAssertEqual(b.cards.filter { $0.lane != .parked }.map(\.title), ["Derivatives", "Applications", "Series"])
        XCTAssertEqual(b.card("Derivatives")?.id, "c2", "ids survive a rewrite"); XCTAssertEqual(b.focusID, "c2")
        XCTAssertEqual(b.lane(.parked).map(\.title), ["Python list mutation"], "parked detours survive a modules rewrite")
        o = try await plan(["action": "update", "id": .string(id), "modules": []])
        XCTAssertTrue(o.isError && o.text.contains("wipe"), o.text)
    }

    // MARK: Request injection

    func testStateCardIsAppendedOnceAtTheTailOfTheRequestOnly() throws {
        let b = try sample()
        let header = b.header()
        let stored = [ChatMessage(role: .user, blocks: [.text("hi")]), ChatMessage(role: .assistant, blocks: [.text("hello")]),
                      ChatMessage(role: .user, blocks: [.text("what is a limit?")])]
        var req = LLMRequest(model: "m", system: "s", messages: stored)
        CourseBoardExtension.inject(header, into: &req)
        CourseBoardExtension.inject(header, into: &req)   // a second pass (another step) replaces, never duplicates
        let last = req.messages.last!
        XCTAssertEqual(last.blocks.count, 2); XCTAssertEqual(last.blocks.last?.text, header)
        XCTAssertEqual(req.messages.flatMap(\.blocks).filter { $0.text?.contains("<lesson_state") == true }.count, 1)
        XCTAssertEqual(stored.last?.blocks.count, 1, "the transcript copy is untouched")
        // Tool results first, then the card: the shape every provider accepts.
        var mid = LLMRequest(model: "m", system: "s", messages: stored + [ChatMessage(role: .assistant, blocks: [.toolUse(id: "t1", name: "math", input: [:])]),
                                                                           ChatMessage(role: .user, blocks: [.toolResult(id: "t1", name: "math", content: "4")])])
        CourseBoardExtension.inject(header, into: &mid)
        XCTAssertEqual(mid.messages.last?.blocks.map(\.kind), [.toolResult, .text])
        var odd = LLMRequest(model: "m", system: "s", messages: [ChatMessage(role: .assistant, blocks: [.text("x")])])
        CourseBoardExtension.inject(header, into: &odd)
        XCTAssertEqual(odd.messages.last?.blocks.count, 1, "never appended to a reply")
        // The summary context is the same card, so compaction can carry it.
        XCTAssertTrue(ContextPolicy.estimate(header) < 200)
    }

    func testObservedSignals() throws {
        let posed = ChatMessage(role: .assistant, blocks: [.text("Try this.\n```problem\n{\"q\":\"Find lim x→2⁻ |x-2|/(x-2)\",\"hints\":[\"sign\"],\"solution\":\"-1\",\"answer\":\"-1\",\"concept\":\"one-sided limits\"}\n```\n")])
        let msgs = [ChatMessage(role: .user, blocks: [.text("ok")]), posed, ChatMessage(role: .user, blocks: [.text("-1?")])]
        XCTAssertEqual(CourseBoardExtension.openLoop(msgs), "awaiting the learner's attempt at: Find lim x→2⁻ |x-2|/(x-2)")
        XCTAssertNil(CourseBoardExtension.openLoop([ChatMessage(role: .user, blocks: [.text("ok")]), ChatMessage(role: .assistant, blocks: [.text("plain")]), ChatMessage(role: .user, blocks: [.text("x")])]))
        var b = try sample()
        _ = study.recordAttempt(subject: "calculus", concept: "One-sided limits", correct: true, note: nil)
        _ = study.recordAttempt(subject: "calculus", concept: "One-sided limits", correct: false, note: nil)
        let w = try XCTUnwrap(CourseBoardExtension.watch(b, study: study))
        XCTAssertTrue(w.hasPrefix("One-sided limits ") && w.hasSuffix("% (1/2)"), w)
        XCTAssertNotNil(b.attachEvidence(concept: "one sided limits", "quiz: one-sided limits 2/3"))
        XCTAssertEqual(b.card("c1")?.evidence, ["quiz: one-sided limits 2/3"]); XCTAssertEqual(b.card("c1")?.lane, .doing, "evidence never moves a card")
        XCTAssertNil(b.attachEvidence(concept: "unrelated", "x"))
        XCTAssertTrue(b.resumeBrief().contains("mode=\"resume\"") && b.resumeBrief().contains("Last time: evidence Limits and continuity: quiz"), b.resumeBrief())
    }

    func testPromptCarriesTheBoardRulesOnce() {
        let p = SystemPrompt.build(settings: AppSettings(), mode: .tutor, coreMemory: "", model: "m")
        XCTAssertEqual(p.components(separatedBy: "# Course board").count, 2)
        XCTAssertTrue(p.contains("<lesson_state>") && p.contains("Never mark a card done without evidence"))
        XCTAssertTrue(SystemPrompt.split(p)[0].contains("# Course board"), "the rules sit in the cached, lesson-independent part")
        XCTAssertFalse(SystemPrompt.buildAgent(settings: AppSettings(), folder: dir, model: "m", projectMemory: "").contains("lesson_state"))
    }
}
