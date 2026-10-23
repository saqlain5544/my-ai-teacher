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

    func testCardsCarryABookStyleOutlineWithProgress() throws {
        var b = try sample()
        let outline: [JSON] = [
            ["title": "What a limit is", "points": ["epsilon-delta idea", "limits that fail to exist"], "sections": [["title": "Graphical limits"], ["title": "Numerical tables"]]],
            ["title": "One-sided limits", "sections": [["title": "Left and right"], ["title": "Jump discontinuities"]]],
            ["title": "Continuity"],
        ]
        var c = try b.setOutline("c1", outline)
        XCTAssertEqual(CourseBoard.flatten(c.outline).map(\.id), ["1", "1.1", "1.2", "2", "2.1", "2.2", "3"])
        XCTAssertEqual(CourseBoard.leaves(c.outline).count, 5); XCTAssertEqual(c.at, "1.1")
        XCTAssertEqual(c.outline[0].points, ["epsilon-delta idea", "limits that fail to exist"])
        c = try b.section("c1", "1.1"); XCTAssertEqual(c.at, "1.2")
        c = try b.section("c1", "Numerical tables"); XCTAssertEqual(c.at, "2.1")
        XCTAssertTrue(c.outline[0].done, "a section is done when its subsections are")
        XCTAssertEqual(b.position(c), "§2.1 Left and right (2/5 sections)")
        XCTAssertTrue(b.header().contains("Focus: C1 Limits and continuity (doing) — §2.1 Left and right (2/5 sections)"), b.header())
        // Refining the outline (renumbered, a section added) keeps what was done.
        c = try b.setOutline("c1", [["title": "Why limits"]] + outline)
        XCTAssertEqual(CourseBoard.leaves(c.outline).filter(\.done).map(\.title), ["Graphical limits", "Numerical tables"])
        XCTAssertEqual(c.at, "3.1", "the pointer follows the renumbered section")
        c = try b.section("c1", "§2.2", done: false); XCTAssertEqual(c.at, "2.2", "reopening goes back to it")
        XCTAssertThrowsError(try b.section("c1", "Quantum gravity")) { XCTAssertTrue("\($0)".contains("2.1 Graphical limits"), "\($0)") }
        XCTAssertThrowsError(try b.section("c2", "1")) { XCTAssertTrue("\($0)".contains("no outline"), "\($0)") }
        XCTAssertThrowsError(try b.setOutline("c1", []))
        // Round-trips, and the full board reads as a table of contents.
        let again = CourseBoard(plan: b.plan)
        XCTAssertEqual(again.card("c1")?.outline, b.card("c1")?.outline); XCTAssertEqual(again.card("c1")?.at, "2.2")
        let md = b.markdown()
        XCTAssertTrue(md.contains("- [x] 2.1 Graphical limits") && md.contains("2.2 Numerical tables  ← now") && md.contains("· epsilon-delta idea"), md)
        // A whole book stays out of the per-request header.
        var big = CourseBoard(plan: LessonPlan(id: "p", title: "Book", subject: nil, goal: nil, data: [:], updatedAt: Date()))
        try big.add(title: "Chapter 1", lane: .doing, next: "read 1.1")
        _ = try big.setOutline("c1", (1...30).map { i in ["title": .string("Section \(i) with a long descriptive title"), "sections": .array((1...10).map { j in ["title": .string("Subsection \(i).\(j)"), "points": ["a", "b"]] })] })
        XCTAssertLessThanOrEqual(ContextPolicy.estimate(big.header()), CourseBoard.headerTokenCap)
        XCTAssertTrue(big.header().contains("§1.1 Subsection 1.1 (0/300 sections)"), big.header())
    }

    func testSectionTitlesLoseTheModelsOwnNumbers() {
        XCTAssertEqual(CourseBoard.unnumbered("1. The execution model"), "The execution model")
        XCTAssertEqual(CourseBoard.unnumbered("2.1 Left and right"), "Left and right")
        XCTAssertEqual(CourseBoard.unnumbered("§3) Types"), "Types")
        XCTAssertEqual(CourseBoard.unnumbered("64-bit atomics"), "64-bit atomics")
        XCTAssertEqual(CourseBoard.unnumbered("2"), "2")
    }

    @MainActor func testANewLessonIsPointedAtTheLearnersExistingBoards() throws {
        let b = try sample()
        let note = CourseBoardExtension.noBoard(existing: [b])
        XCTAssertTrue(note.contains(b.id) && note.contains("action=get plan=") && note.contains("don't create a duplicate"), note)
        XCTAssertFalse(CourseBoardExtension.noBoard(existing: []).contains("plan="), "no boards: just the reminder")
    }

    func testTheLearnerChoosesTheBoardSystem() throws {
        defer { Experiments.chosen = [:]; Experiments.forced = [:] }
        XCTAssertEqual(Experiments.evaluationArm(Experiments.courseBoard), "nested", "book outlines by default")
        Experiments.choose("shallow", for: "course_board")
        XCTAssertEqual(Experiments.evaluationArm(Experiments.courseBoard), "shallow")
        Experiments.choose("off", for: "course_board")
        XCTAssertTrue(Experiments.boardOff)
        Experiments.forced["course_board"] = "nested"
        XCTAssertFalse(Experiments.boardOff, "an evaluation run's forced arm wins")
        let saved = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"courseBoard":"bogus"}"#.utf8))
        XCTAssertEqual(saved.courseBoard, "nested", "an unknown value falls back to the default")
    }

    func testProgressCountsSectionsOfTheCardInProgress() throws {
        var b = try sample()
        let before = b.progress
        _ = try b.setOutline("c1", [["title": "A"], ["title": "B"], ["title": "C"], ["title": "D"]])
        _ = try b.section("c1", "1"); _ = try b.section("c1", "2")
        XCTAssertGreaterThan(b.progress, before, "half a chapter done shows as progress")
        XCTAssertEqual(b.sectionCounts?.done, 2); XCTAssertEqual(b.sectionCounts?.total, 4)
        let done = try b.complete("c1", evidence: "explained the cubic function unaided")
        XCTAssertTrue(CourseBoard.leaves(done.outline).allSatisfy(\.done), "a completed card's sections are all ticked")
        XCTAssertNil(done.at)
    }

    func testSectionsFoundTheWayTheBoardShowsThem() throws {
        var b = try sample()
        let outline: [JSON] = [["title": "1. The execution model"], ["title": "Type functions"], ["title": "Reflection"]]
        XCTAssertEqual(try b.setOutline("c1", outline).outline[0].title, "The execution model")
        XCTAssertEqual(try b.section("c1", "1 The execution model").outline[0].done, true)   // as displayed
        XCTAssertEqual(try b.section("c1", "2 2. Type functions").outline[1].done, true)    // the old doubled label
        XCTAssertEqual(try b.section("c1", "3. Reflection").outline[2].done, true)
    }

    func testOutlinesInTheShapesModelsActuallySend() throws {
        // Recorded from MiniMax-M3.1-Flash in a live lesson (rejected by the first parser, three times, until the teacher
        // gave up and sent a one-line outline): untitled groupings, {"item": …} wrappers, a section object instead of a list.
        let sent = JSON.parse(#"""
        [{"sections": [{"title": "Memtable, WAL, SST files", "points": ["Write buffer, WAL before memtable flush", "SST: blocks, index, filters, block cache"]},
          {"points": ["Leveled compaction", "Universal compaction", "T and L"], "sections": {"item": [
            {"points": {"item": ["WA ≈ T×L ideal vs observed", "Read path: bloom filters, block cache, L0 overlap"]}, "title": "Compaction strategies and their cost model"},
            {"sections": {"item": {"title": "Read path in detail", "points": {"item": ["Point lookups", "Range scans"]}}}}]}}]},
         "Space amplification", {"name": "Tombstones", "bullets": "Deletes are writes"}]
        """#)!.array!
        let secs = CourseBoard.sections(from: sent, prefix: "", old: [])
        XCTAssertEqual(CourseBoard.flatten(secs).map { "\($0.id) \($0.title)" }, [
            "1 Memtable, WAL, SST files", "2 Compaction strategies and their cost model", "3 Read path in detail",
            "4 Space amplification", "5 Tombstones"])
        XCTAssertEqual(secs[1].points, ["Leveled compaction", "Universal compaction", "T and L", "WA ≈ T×L ideal vs observed", "Read path: bloom filters, block cache, L0 overlap"])
        XCTAssertEqual(secs[2].points, ["Point lookups", "Range scans"]); XCTAssertEqual(secs[4].points, ["Deletes are writes"])
        // Nesting that is spelled out is kept.
        let nested = CourseBoard.sections(from: [["heading": "B-trees", "subsections": [["label": "Fanout"], ["topic": "Splits", "children": ["item": ["Fill factor"]]]]]], prefix: "", old: [])
        XCTAssertEqual(CourseBoard.flatten(nested).map(\.id), ["1", "1.1", "1.2", "1.2.1"])
        XCTAssertEqual(CourseBoard.sections(from: [["points": []], .null, 3], prefix: "", old: []), [], "nothing usable is still nothing")
    }

    func testParallelBoardWritesNeverLoseACard() async throws {
        _ = try await plan(["action": "create", "title": "Parallel", "modules": [["title": "First"]]])
        let c = ctx!
        try await withThrowingTaskGroup(of: ToolOutput.self) { group in
            for i in 0..<20 { group.addTask { try await LessonPlanTool().run(["action": "add", "title": .string("Card \(i)")], c) } }
            for try await o in group { XCTAssertFalse(o.isError, o.text) }
        }
        let b = try XCTUnwrap(study.board(forLesson: "lesson-a"))
        XCTAssertEqual(b.cards.count, 21, "every parallel add landed")
        XCTAssertEqual(Set(b.cards.map(\.id)).count, 21, "ids are unique")
        XCTAssertEqual(b.revision, 21)
    }

    func testToolOutlinesACourseLikeABook() async throws {
        var o = try await plan(["action": "create", "title": "Zig systems", "modules": [
            ["title": "RESP key-value server", "next": "parse a RESP array", "outline": [["title": "RESP framing", "sections": [["title": "Simple strings"], ["title": "Bulk strings"]]], ["title": "The store"]]],
            ["title": "Event loop"]]])
        XCTAssertFalse(o.isError, o.text)
        XCTAssertTrue(o.text.contains("- [ ] 1.1 Simple strings  ← now"), o.text)
        o = try await plan(["action": "outline", "card": "c2", "outline": [["title": "kqueue"], ["title": "io_uring"]]])
        XCTAssertTrue(o.text.contains("Outlined C2 Event loop: §1 kqueue (0/2 sections)"), o.text)
        o = try await plan(["action": "section", "card": "c1", "section": "1.1"])
        XCTAssertTrue(o.text.contains("§1.2 Bulk strings (1/3 sections)") && o.text.contains("<lesson_state"), o.text)
        XCTAssertEqual(o.meta?["plan"]?["cards"]?[0]?["at"]?.string, "1.2")
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

    func testEveryMentorIsToldToVisualise() {
        for mode in TeachingMode.allCases where !mode.isAgent {
            let p = SystemPrompt.build(settings: AppSettings(), mode: mode, coreMemory: "", model: "m")
            XCTAssertTrue(p.contains("```mermaid") && p.contains("```visual") && p.contains("3D") && p.contains("Show it as well as say it"), "\(mode)")
            XCTAssertFalse(p.contains("lightest form"), "nothing discourages visuals")
        }
        let agent = SystemPrompt.buildAgent(settings: AppSettings(), folder: dir, model: "m", projectMemory: "")
        XCTAssertTrue(agent.contains("```mermaid") && agent.contains("```visual") && agent.contains("three"), "the code agent can draw too")
    }

    func testInstructionsAreLeanAndEditable() {
        var settings = AppSettings()
        let lean = SystemPrompt.build(settings: settings, mode: .tutor, coreMemory: "", model: "m")
        XCTAssertLessThan(ContextPolicy.estimate(SystemPrompt.split(lean)[0]), 2_200, "the shared instructions stay lean")
        XCTAssertFalse(lean.contains("{learner}") || lean.contains("{more_tools}"), "placeholders are filled")
        // An edit replaces the default for new lessons; clearing it brings the default back.
        settings.instructions[Instructions.Key.teacher.raw] = "You are a terse physics coach for {learner}."
        settings.learnerName = "Ada"
        let edited = SystemPrompt.build(settings: settings, mode: .tutor, coreMemory: "", model: "m")
        XCTAssertTrue(edited.hasPrefix("You are a terse physics coach for Ada."), String(edited.prefix(80)))
        XCTAssertTrue(Instructions.isEdited(.teacher, settings))
        settings.instructions[Instructions.Key.mode(.code).raw] = "Mentor in Zig only."
        XCTAssertTrue(SystemPrompt.build(settings: settings, mode: .code, coreMemory: "", model: "m").contains("Mentor in Zig only."))
        settings.instructions[Instructions.Key.codeAgent.raw] = "Ship it carefully."
        XCTAssertTrue(SystemPrompt.buildAgent(settings: settings, folder: dir, model: "m", projectMemory: "").hasPrefix("Ship it carefully."))
        settings.instructions[Instructions.Key.teacher.raw] = "   "
        XCTAssertFalse(Instructions.isEdited(.teacher, settings), "a blank edit is no edit")
        XCTAssertTrue(SystemPrompt.build(settings: settings, mode: .tutor, coreMemory: "", model: "m").hasPrefix("You are Teacher"))
        // A built-in sub-agent's instructions can be edited; its tools and read-only status stay the app's.
        let types = AgentCatalog.all(app: [], folder: nil, instructions: [Instructions.Key.subAgent("explore").raw: "Research like a librarian."])
        let explore = try! XCTUnwrap(AgentCatalog.find("explore", in: types))
        XCTAssertEqual(explore.prompt, "Research like a librarian."); XCTAssertTrue(explore.readOnly)
        XCTAssertEqual(Instructions.all.count, Set(Instructions.all.map(\.raw)).count, "every agent once")
        // Settings round-trip.
        let back = try! JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings))
        XCTAssertEqual(back.instructions[Instructions.Key.codeAgent.raw], "Ship it carefully.")
    }

    func testPromptCarriesTheBoardRulesOnce() {
        let p = SystemPrompt.build(settings: AppSettings(), mode: .tutor, coreMemory: "", model: "m")
        XCTAssertEqual(p.components(separatedBy: "# Course board").count, 2)
        XCTAssertTrue(p.contains("<lesson_state>") && p.contains("complete a card only with evidence") && p.contains("not a script"))
        XCTAssertTrue(SystemPrompt.split(p)[0].contains("# Course board"), "the rules sit in the cached, lesson-independent part")
        XCTAssertFalse(SystemPrompt.buildAgent(settings: AppSettings(), folder: dir, model: "m", projectMemory: "").contains("lesson_state"))
    }
}
