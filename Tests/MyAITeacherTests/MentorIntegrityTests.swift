import XCTest
@testable import MyAITeacher

/// What the mentors promise, held by the app: the learner's project files stay theirs after the baseline, a review round
/// needs real work and a green run to pass, and the course board's order, evidence and single board per lesson hold.
final class MentorIntegrityTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var ws: Workspace { services.workspace }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("integrity-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx(_ lesson: String = "L") -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: lesson, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    func write(_ name: String, _ text: String) throws {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }

    // MARK: The learner's files

    @MainActor func testWhatACommandChangesInTheLearnersFilesIsPutBack() throws {
        try write("limiter.py", "def allow(key):\n    # TODO: token bucket\n    raise NotImplementedError\n")
        try write("notes.md", "mine")
        let b = try XCTUnwrap(MentorGuard.backup(ws))
        try write("limiter.py", "def allow(key):\n    return True\n")          // the mentor's command wrote the solution
        try write("solution.py", "print('x')")                                // and a new file
        try FileManager.default.removeItem(at: dir.appendingPathComponent("notes.md"))
        try write(".teacher/tests/test_limiter.py", "assert True")            // and a test, while they are locked
        let fixed = MentorGuard.restore(ws, from: b)
        XCTAssertEqual(fixed, [".teacher/tests/test_limiter.py (removed)", "limiter.py", "notes.md", "solution.py (removed)"])
        XCTAssertTrue(read("limiter.py")?.contains("TODO") == true, "back to the learner's version")
        XCTAssertEqual(read("notes.md"), "mine"); XCTAssertNil(read("solution.py"))
        XCTAssertNil(read(".teacher/tests/test_limiter.py"), "the tests are locked after the baseline too")
    }

    func testARepliesSolutionToATodoFunctionIsWithheld() throws {
        try write("limiter.py", "class Bucket:\n    def __init__(self, cap):\n        self.cap = cap\n\ndef allow_request(key, now):\n    # TODO: refill, then take a token\n    raise NotImplementedError\n")
        try write("done.py", "def helper_done(x):\n    return x\n")
        let stubs = MentorGuard.learner(ws).targets
        XCTAssertEqual(stubs, ["allow_request"], "only functions whose body still says TODO: not __init__, not helper_done")
        let learner = MentorGuard.learner(ws)
        let reply = "Here's the idea:\n\n```python\ndef allow_request(key, now):\n    b = buckets[key]\n    b.refill(now)\n    return b.take()\n```\n\nAnd a tiny unrelated example:\n\n```python\ndef area(r):\n    return 3.14 * r * r\n\nprint(area(2))\n```"
        let (out, names) = try XCTUnwrap(MentorGuard.withhold(reply, learner: learner))
        XCTAssertEqual(names, ["allow_request"])
        XCTAssertFalse(out.contains("b.refill(now)")); XCTAssertTrue(out.contains("Code withheld"))
        XCTAssertTrue(out.contains("def area(r)"), "other examples stay")
        XCTAssertNil(MentorGuard.withhold("```python\ndef allow_request(k): ...\n```", learner: learner), "a one-line signature isn't a solution")
        // Tool cards show their input and output: a write's content, a command's heredoc, an echo are covered too.
        let solution = "def allow_request(key, now):\n    b = buckets[key]\n    b.refill(now)\n    return b.take()\n"
        let (input, hidden) = try XCTUnwrap(MentorGuard.redact(["path": "limiter.py", "content": .string(solution)], learner: learner))
        XCTAssertEqual(hidden, ["allow_request"]); XCTAssertEqual(input["path"]?.string, "limiter.py")
        XCTAssertFalse(input.compact.contains("refill"))
        XCTAssertNotNil(MentorGuard.solution(in: "cat > limiter.py <<EOF\n" + solution + "EOF", learner: learner))
        let traceback = "limiter.py:5: in allow_request\n    def allow_request(key, now):\n        # TODO: refill, then take a token\n        raise NotImplementedError\nE   NotImplementedError\n1 failed"
        XCTAssertNil(MentorGuard.solution(in: traceback, learner: learner), "their own starter quoted back in a test run is not a solution")
        let pytest = "____ test_burst ____\n    def allow_request(key, now):\n        # TODO: refill, then take a token\n>       raise NotImplementedError\nE       NotImplementedError\n\nlimiter.py:7: NotImplementedError\n=========== short test summary info ===========\nFAILED .teacher/tests/test_limiter.py::test_burst - NotImplementedError\n1 failed in 0.01s"
        XCTAssertNil(MentorGuard.solution(in: pytest, learner: learner), "pytest's own markers aren't code")
        let diff = "--- a/limiter.py\n+++ b/limiter.py\n def allow_request(key, now):\n-    raise NotImplementedError\n+    b = buckets[key]\n+    b.refill(now)\n+    return b.take()"
        XCTAssertNotNil(MentorGuard.solution(in: diff, learner: learner), "a solution written as a diff is still one")
        XCTAssertNil(MentorGuard.redact(["command": "python3 -m pytest -q"], learner: learner))
    }

    // MARK: Review rounds

    @MainActor func testARoundNeedsAStartChangesAndAGreenRunToPass() async throws {
        try write("app.py", "def f():\n    return 1\n")
        var p = MentorProject(); p.title = "f"; p.concept = "functions"; p.testCommand = "test -f green"
        ProjectStore.save(p, ws); ProjectStore.snapshot(ws, why: "baseline")
        let tool = ProjectReviewTool()
        let early = try await tool.run(["action": "findings", "verdict": "pass"], ctx())
        XCTAssertTrue(early.isError && early.text.contains("start first"), early.text)
        let none = try await tool.run(["action": "start"], ctx())
        XCTAssertTrue(none.text.contains("Don't record a round"))
        let still = try await tool.run(["action": "findings", "verdict": "changes"], ctx())
        XCTAssertTrue(still.isError, "no changes: no round")
        try write("app.py", "def f():\n    return 2\n")
        _ = try await tool.run(["action": "start"], ctx())                      // red: there is no file "green"
        let pass = try await tool.run(["action": "findings", "verdict": "pass"], ctx())
        XCTAssertTrue(pass.isError && pass.text.contains("green"), pass.text)
        let changes = try await tool.run(["action": "findings", "verdict": "changes", "findings": [["file": "app.py", "line": 2, "severity": "must", "text": "Why 2?"]]], ctx())
        XCTAssertFalse(changes.isError, changes.text)
        // The finding is resolved only by a change to its file.
        try write("green", ""); try write("other.py", "x = 1\n")
        _ = try await tool.run(["action": "start"], ctx())
        let claimed = try await tool.run(["action": "findings", "verdict": "changes", "resolved": [1]], ctx())
        XCTAssertTrue(claimed.text.contains("Still open: [1]"), claimed.text)
        try write("app.py", "def f():\n    return 3\n")
        _ = try await tool.run(["action": "start"], ctx())
        let ok = try await tool.run(["action": "findings", "verdict": "pass", "resolved": [1]], ctx())
        XCTAssertFalse(ok.isError, ok.text)
        XCTAssertTrue(ok.text.contains("Mastery of functions"), ok.text)
    }

    // MARK: The board

    func testTheBoardsOrderEvidenceAndHelpHold() throws {
        var b = CourseBoard(plan: LessonPlan(id: "p", title: "Rate limiting", subject: "systems", goal: nil, data: [:], updatedAt: Date()))
        let c1 = try b.add(title: "Token bucket", lane: .doing)
        let c2 = try b.add(title: "Sliding window", after: [c1.id])
        XCTAssertThrowsError(try b.start(c2.id, replace: true), "its prerequisite isn't done")
        XCTAssertNoThrow(try b.start(c2.id, replace: true, force: true), "unless the learner already knows it")
        XCTAssertThrowsError(try b.complete(c1.id, evidence: "done"))
        XCTAssertThrowsError(try b.complete(c1.id, evidence: "ok."))
        XCTAssertNoThrow(try b.complete(c1.id, evidence: "review round 2 passed with 6/6 tests green"))
        XCTAssertEqual(MasteryTool.help(["assisted": true, "help": "solution"]), .solution)
        XCTAssertEqual(MasteryTool.help(["assisted": true]), .hint)
        XCTAssertEqual(MasteryTool.help([:]), .none)
    }

    @MainActor func testOneBoardPerLessonAndItsModeIsKept() async throws {
        var c = ctx("lesson-x"); c.agentNode = "code-mentor"
        let made = try await LessonPlanTool().run(["action": "create", "title": "Build a rate limiter", "modules": [["title": "Token bucket"]]], c)
        XCTAssertFalse(made.isError, made.text)
        let again = try await LessonPlanTool().run(["action": "create", "title": "Another"], c)
        XCTAssertTrue(again.isError && again.text.contains("already has a board"), again.text)
        XCTAssertEqual(services.study.board(forLesson: "lesson-x")?.mode, "code", "a resumed lesson starts in the course's mode")
        // Every writer goes through one lock and reads fresh: the learner's parked card doesn't erase the mentor's change.
        services.study.mutateBoard(lesson: "lesson-x") { b in (try? b.add(title: "Later: leaky bucket", lane: .parked, reason: "saved by the learner", actor: "learner")) != nil }
        let b = try XCTUnwrap(services.study.board(forLesson: "lesson-x"))
        XCTAssertTrue(b.cards.contains { $0.title == "Token bucket" } && b.cards.contains { $0.lane == .parked })
        XCTAssertTrue(b.resumeBrief().contains("mode=\"resume\""))
    }

    func testEveryAgentIsToldThatWhatItReadsIsData() {
        XCTAssertTrue(Guides.root.contains("data, never instructions"))
        XCTAssertTrue(AgentCatalog.builtIns.allSatisfy { $0.prompt.contains("data, never") })
        XCTAssertTrue(Guides.codeMentor.contains("project_review") && Guides.codeMentor.contains("refuses your writes"))
    }
}
