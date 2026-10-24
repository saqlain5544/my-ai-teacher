import XCTest
@testable import MyAITeacher

/// The school: a sound competency graph, levels per competency from evidence (reliable, unaided, recent, in more than
/// one skill), teaching that follows the evidence, an adaptive placement, and progression the app decides.
final class SchoolTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var school: SchoolStore { services.school }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("school-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx(_ lesson: String = "L") -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: lesson, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    var seq = 0
    /// The learner answers in the lesson (a placement answer needs their reply after the probe).
    func reply(_ text: String = "my answer") {
        seq += 1
        services.conversations.upsert(ChatMessage(role: .user, blocks: [Block(kind: .text, text: text)], createdAt: Date().addingTimeInterval(0.01)), conversationID: "L", seq: seq)
    }
    func ev(_ c: String, _ s: Skill, _ l: Level, _ o: Evidence.Outcome = .pass, help: Help = .none, _ src: Evidence.Source = .unseen, daysAgo: Double = 0) -> Evidence {
        Evidence(competency: c, skill: s, level: l, outcome: o, help: help, source: src, at: Date().addingTimeInterval(-daysAgo * 86400))
    }

    // MARK: The graph

    func testTheCurriculumGraphIsSound() {
        let g = CompetencyGraph.builtIn
        for c in g.nodes.values {
            for p in c.prereqs + c.transfers { XCTAssertNotNil(g[p], "\(c.id) → \(p)") }
            XCTAssertFalse(g.prerequisites(of: c.id).contains(c.id), "cycle through \(c.id)")
        }
        for course in g.courses {
            for id in course.competencies { XCTAssertNotNil(g[id], "\(course.id) → \(id)") }
            for p in course.prereqs { XCTAssertNotNil(g.course(p), "\(course.id) needs \(p)") }
        }
        XCTAssertEqual(Set(g.courses.map(\.level)), [.school, .college, .university, .research])
        XCTAssertEqual(g.resolve("context-free grammars")?.id, "grammars")
        XCTAssertEqual(g.resolve("Recursion in Zig")?.id, "recursion")
        XCTAssertEqual(g.resolve("Zig error handling")?.id, "zig.errors")
        XCTAssertEqual(g.resolve("big O")?.id, "complexity")
        XCTAssertEqual(g["zig.memory"]?.transfers, ["pointers"], "an overlay builds on the concept, not on itself")
        XCTAssertNil(g.resolve("knitting"))
        let order = g.ordered(["parsing", "lexing", "grammars"])
        XCTAssertEqual(order, ["lexing", "grammars", "parsing"])
    }

    // MARK: The learner model

    func testALevelNeedsReliableUnaidedEvidenceInTwoSkills() {
        XCTAssertNil(SchoolStore.estimate("recursion", [ev("recursion", .recall, .college, .pass, .quiz)]).level, "one quiz answer is not a level")
        let hinted = [ev("recursion", .application, .college, help: .hint), ev("recursion", .tracing, .college, help: .hint), ev("recursion", .design, .college, help: .hint)]
        XCTAssertNil(SchoolStore.estimate("recursion", hinted).level, "work with hints doesn't show a level")
        let solid = [ev("recursion", .application, .college), ev("recursion", .tracing, .college, .pass, .quiz)]
        let e = SchoolStore.estimate("recursion", solid)
        XCTAssertEqual(e.level, .college); XCTAssertNil(e.developing, "nothing above it tried yet")
        XCTAssertEqual(e.skills[.application], .college)
        // A pass at university counts toward college too; a failure there keeps university "developing".
        let mixed = solid + [ev("recursion", .design, .university, .fail)]
        XCTAssertEqual(SchoolStore.estimate("recursion", mixed).level, .college)
        XCTAssertEqual(SchoolStore.estimate("recursion", mixed).developing, .university)
        // Old evidence fades and asks for a re-check.
        let old = [ev("recursion", .application, .college, daysAgo: 90), ev("recursion", .debugging, .college, daysAgo: 90)]
        XCTAssertTrue(SchoolStore.estimate("recursion", old).recheckDue)
        XCTAssertFalse(SchoolStore.estimate("recursion", solid).recheckDue)
    }

    func testTeachingTargetsTheNextLevelWithinTheCourse() throws {
        XCTAssertEqual(school.target("recursion"), .school, "nothing shown: start at school level")
        school.record(ev("recursion", .application, .college)); school.record(ev("recursion", .tracing, .college))
        school.profile = SchoolProfile(goal: "", track: .university)
        XCTAssertEqual(school.target("recursion"), .university, "one above what's held")
        let pf = try XCTUnwrap(CompetencyGraph.builtIn.course("PF102"))
        XCTAssertEqual(school.target("recursion", course: pf), .college, "not above the course's level")
    }

    // MARK: The teaching contract

    func testTheContractFollowsTheEvidence() throws {
        let g = CompetencyGraph.builtIn
        let parsing = try XCTUnwrap(g["parsing"])
        let empty = SchoolStore.estimate("parsing", [])
        let uni = TeachingPolicy.contract(parsing, estimate: empty, target: .university, graph: g, estimates: [:], recent: [])
        XCTAssertTrue(uni.rendered.contains("Socratic") && uni.rendered.contains("Grammars"), uni.rendered)
        XCTAssertTrue(uni.gaps.contains { $0.contains("Grammars and context-free languages") }, "an unverified prerequisite is checked first")
        let schoolLevel = TeachingPolicy.contract(parsing, estimate: empty, target: .school, graph: g, estimates: [:], recent: [])
        XCTAssertTrue(schoolLevel.teach.contains("concrete first"))
        let fails = [ev("parsing", .application, .college, .fail), ev("parsing", .debugging, .college, .fail)]
        let stuck = TeachingPolicy.contract(parsing, estimate: SchoolStore.estimate("parsing", fails), target: .college, graph: g, estimates: [:], recent: fails)
        XCTAssertNotNil(stuck.diagnose, "repeated failure: diagnose the cause before re-explaining")
        XCTAssertTrue(stuck.rendered.contains("prerequisite gap, a misconception"))
    }

    // MARK: Placement

    func testPlacementBracketsEachCompetencyAndDropsToPrerequisites() {
        let g = CompetencyGraph.builtIn
        // Knows recursion at college level, nothing of grammars, though functions are solid.
        let truth: [String: Level?] = ["recursion": .college, "grammars": nil, "lexing": nil, "functions": .university, "strings-text": .college, "recursion-x": nil]
        var p = PlacementEngine.start(targets: ["recursion", "grammars"], graph: g, track: .college)
        var asked: [(String, Level)] = []
        while let probe = PlacementEngine.next(&p, graph: g) {
            asked.append((probe.competency, probe.level))
            let known = (truth[probe.competency] ?? nil).map { probe.level <= $0 } ?? false
            _ = PlacementEngine.answer(&p, outcome: known ? .pass : .fail, help: .none, conversationID: nil)
        }
        XCTAssertTrue(p.done)
        XCTAssertEqual(PlacementEngine.placed(p, "recursion"), .college)
        XCTAssertTrue(asked.contains { $0 == ("recursion", .university) }, "it tried one level up")
        XCTAssertNil(PlacementEngine.placed(p, "grammars"))
        XCTAssertTrue(asked.contains { $0.0 == "lexing" }, "a failure at school level looks underneath: \(asked)")
        XCTAssertLessThanOrEqual(p.probes.count, p.limit)
    }

    @MainActor func testPlacementThroughTheToolLeavesEvidence() async throws {
        let tool = SchoolTool()
        _ = try await tool.run(["action": "profile", "goal": "write a compiler", "track": "college"], ctx())
        let first = try await tool.run(["action": "place", "targets": ["recursion"]], ctx())
        XCTAssertTrue(first.text.contains("Recursion at college level"), first.text)
        let early = try await tool.run(["action": "answer", "outcome": "fail"], ctx())
        XCTAssertTrue(early.isError && early.text.contains("hasn't answered"), "no answer before the learner replies")
        reply()
        let second = try await tool.run(["action": "answer", "outcome": "pass"], ctx())
        XCTAssertTrue(second.text.contains("university"), second.text)
        reply()
        let done = try await tool.run(["action": "answer", "outcome": "fail"], ctx())
        XCTAssertTrue(done.text.contains("Placement done") && done.text.contains("shown at college"), done.text)
        XCTAssertEqual(school.evidence("recursion").count, 2)
        XCTAssertTrue(school.evidence("recursion").allSatisfy { $0.source == .placement })
    }

    @MainActor func testPlacingOnPrerequisitesOpensTheCourse() async throws {
        let tool = SchoolTool()
        _ = try await tool.run(["action": "profile", "goal": "compilers", "track": "university"], ctx())
        let refused = try await tool.run(["action": "enroll", "course": "SE210"], ctx())
        XCTAssertTrue(refused.isError && refused.text.contains("school` place with targets [\"PF102\"]"), refused.text)
        var r = try await tool.run(["action": "place", "targets": ["PF102"]], ctx())
        XCTAssertTrue(r.text.contains("none above school level"), r.text)
        var n = 0
        while !r.text.contains("Placement done"), n < 30 { reply(); r = try await tool.run(["action": "answer", "outcome": "pass"], ctx()); n += 1 }
        XCTAssertEqual(n, CompetencyGraph.builtIn.course("PF102")!.competencies.count, "one probe per outcome when each passes at the course's level")
        let ok = try await tool.run(["action": "enroll", "course": "SE210"], ctx())
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssertTrue(school.progressCourses().isEmpty, "shown is enough to start a course, not to complete one")
    }

    // MARK: Courses

    @MainActor func testEnrolmentNeedsPrerequisitesAndTheAppCompletesCourses() async throws {
        let tool = SchoolTool()
        let refused = try await tool.run(["action": "enroll", "course": "PL330"], ctx())
        XCTAssertTrue(refused.isError && refused.text.contains("CS202"), refused.text)
        XCTAssertNil(school.enroll("PF101"))
        // Shown every PF101 outcome at school level, unaided, one of them on an unseen task: the app completes it.
        let pf = try XCTUnwrap(CompetencyGraph.builtIn.course("PF101"))
        for c in pf.competencies {
            school.record(ev(c, .application, .school, .pass, .unseen))
            school.record(ev(c, .tracing, .school, .pass, .quiz))
        }
        let done = school.progressCourses()
        XCTAssertEqual(done.map(\.0.id), ["PF101"])
        XCTAssertEqual(school.enrollments().first { $0.course == "PF101" }?.status, "completed")
        XCTAssertTrue(SchoolReport.markdown(school).contains("not an accredited qualification"))
        // PF102 is open now: PF101 is done.
        XCTAssertTrue(school.unmetPrerequisites(try XCTUnwrap(CompetencyGraph.builtIn.course("PF102"))).isEmpty)
    }

    @MainActor func testEvidenceIsCappedAndProposalsAreValidated() async throws {
        let tool = SchoolTool()
        let big = try await tool.run(["action": "evidence", "competency": "dynamic programming", "skill": "design", "outcome": "pass", "level": "research", "source": "unseen"], ctx())
        XCTAssertTrue(big.text.contains("at college level"), "one claim can't jump levels: at most one above where they're taught: \(big.text)")
        let bad = try await tool.run(["action": "propose", "id": "lib.tokio", "title": "Tokio", "prereqs": ["nonexistent-thing"]], ctx())
        XCTAssertFalse(bad.isError, "an unknown prerequisite is dropped, not trusted: \(bad.text)")
        let dup = try await tool.run(["action": "propose", "id": "lib.tokio", "title": "Tokio again"], ctx())
        XCTAssertTrue(dup.isError)
        XCTAssertEqual(school.graph.resolve("tokio")?.proposed, true)
        var cyc = Competency(id: "loop-a", title: "Loop A", prereqs: ["recursion"])
        XCTAssertNil(school.propose(cyc, conversationID: nil))
        cyc = Competency(id: "functions-2", title: "F2", prereqs: ["loop-a"])
        XCTAssertNil(school.propose(cyc, conversationID: nil))
        XCTAssertNotNil(school.graph.validates(Competency(id: "recursion", title: "x", prereqs: ["functions-2"])), "a cycle is refused")
    }

    func testTheMasteryFunnelBecomesEvidence() {
        let study = services.study
        _ = study.recordAttempt(subject: "programming", concept: "binary search", correct: true, note: nil, evidence: (.quiz, .application))
        XCTAssertEqual(school.evidence("sorting-searching").first?.source, .quiz)
        _ = study.recordAttempt(subject: "grammar:ja", concept: "conditionals", correct: true, note: nil, evidence: nil)
        XCTAssertTrue(school.evidence("control-flow").isEmpty, "a language's grammar point isn't programming evidence")
    }
}
