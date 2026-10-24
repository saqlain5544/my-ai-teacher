import XCTest
@testable import MyAITeacher

/// The code mentor's review loop as mechanism: tests proven red on the starter, the diff since the last review,
/// structured rounds with findings carried and resolved, mastery on a green pass, and the project state line.
final class CodeMentorTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var ws: Workspace { services.workspace }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mentor-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx() -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    func write(_ name: String, _ text: String) throws {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    static let pytest = "python3 -m pytest -q .teacher/tests"

    // MARK: Parsing test runners

    func testRunnerSummariesAreParsed() {
        let py = TestOutput.parse("FAILED .teacher/tests/test_a.py::test_two - assert 1 == 2\n============ 1 failed, 3 passed in 0.12s ============\n", exit: 1)
        XCTAssertEqual([py.passed, py.failed], [3, 1]); XCTAssertEqual(py.failing, [".teacher/tests/test_a.py::test_two"]); XCTAssertFalse(py.errored)
        let jest = TestOutput.parse("  ✕ adds (3 ms)\n  ✓ subtracts\nTests:       1 failed, 3 passed, 4 total\n", exit: 1)
        XCTAssertEqual([jest.passed, jest.failed], [3, 1]); XCTAssertEqual(jest.failing, ["adds (3 ms)"])
        let swift = TestOutput.parse("Test Case '-[XTests testB]' failed (0.1 seconds).\nExecuted 5 tests, with 1 failure (0 unexpected) in 0.3 (0.3) seconds\n", exit: 1)
        XCTAssertEqual([swift.passed, swift.failed], [4, 1]); XCTAssertEqual(swift.failing, ["testB"])
        let cargo = TestOutput.parse("test tests::b ... FAILED\ntest result: FAILED. 2 passed; 1 failed; 0 ignored\n", exit: 101)
        XCTAssertEqual([cargo.passed, cargo.failed], [2, 1]); XCTAssertEqual(cargo.failing, ["tests::b"])
        let go = TestOutput.parse("--- FAIL: TestAdd (0.00s)\n    add_test.go:9: want 3\n--- PASS: TestSub (0.00s)\nFAIL\nFAIL\tx\t0.1s\n", exit: 1)
        XCTAssertEqual([go.passed, go.failed], [1, 1]); XCTAssertEqual(go.failing, ["TestAdd"])
        XCTAssertEqual(TestOutput.parse("ok  \tx\t0.01s\n", exit: 0).passed, 1)
        XCTAssertEqual(TestOutput.parse("All 7 tests passed.\n", exit: 0).passed, 7)
        let rspec = TestOutput.parse("4 examples, 1 failure\nrspec ./spec/a_spec.rb:3 # Cart totals\n", exit: 1)
        XCTAssertEqual([rspec.passed, rspec.failed], [3, 1]); XCTAssertEqual(rspec.failing, ["Cart totals"])
        let broken = TestOutput.parse("ImportError while loading conftest\n", exit: 2)
        XCTAssertTrue(broken.errored, "nothing collected and a non-zero exit is a broken runner")
        XCTAssertFalse(TestOutput.parse("4 passed in 0.1s\n", exit: 0).errored)
    }

    // MARK: Snapshots and diffs

    func testChangesSinceTheSnapshot() async throws {
        try write("shop.py", "def total(items):\n    raise NotImplementedError\n")
        try write("README.md", "# Shop\n"); try write(".teacher/tests/test_shop.py", "def test_x(): pass\n"); try write("node_modules/x.js", "junk")
        try write(".env", "TOKEN=secret\n"); try write(".github/workflows/ci.yml", "x")
        XCTAssertEqual(ProjectStore.projectFiles(ws), ["README.md", "shop.py"], "the app's state, build folders and dotfiles are not the learner's work")
        XCTAssertFalse(TestOutput.parse("retry 3 failed attempts\n", exit: 0).failed == 3, "a log line is not a test summary")
        ProjectStore.snapshot(ws, why: "starter")
        XCTAssertEqual(ProjectStore.changedCount(ws), 0)
        try write("shop.py", "def total(items):\n    return sum(i['price'] * i['qty'] for i in items)\n")
        try write("util.py", "X = 1\n"); try FileManager.default.removeItem(at: dir.appendingPathComponent("README.md"))
        XCTAssertEqual(ProjectStore.changedCount(ws), 3)
        let ch = await ProjectStore.changes(ws)
        XCTAssertEqual(ch.map { "\($0.kind) \($0.path)" }, ["modified shop.py", "added util.py", "deleted README.md"])
        let shop = ch[0]
        XCTAssertEqual(shop.added, 1); XCTAssertEqual(shop.removed, 1); XCTAssertTrue(shop.diff.contains("-    raise NotImplementedError") && shop.diff.contains("+    return sum"), shop.diff)
        let text = ProjectStore.render(ch)
        XCTAssertTrue(text.hasPrefix("3 files changed (+2 −2)") && text.contains("```diff"), text)
        XCTAssertEqual(ProjectStore.render([]), "No files changed since the last review.")
    }

    // MARK: The tools

    @MainActor func testTestsMustBeRedOnTheStarterAndReviewRoundsCarryFindings() async throws {
        try XCTSkipIf(ProcessRunner.which("python3") == nil, "python3 not installed")
        let check = await ProcessRunner.run(ProcessRunner.which("python3")!, ["-c", "import pytest"], timeout: 20)
        try XCTSkipIf(check.exitCode != 0, "pytest not installed")
        try write("shop.py", "def total(items):\n    raise NotImplementedError\n")
        // Vacuous tests: refused.
        try write(".teacher/tests/test_shop.py", "def test_nothing():\n    assert True\n")
        var out = try await ProjectTestsTool().run(["action": "set", "command": .string(Self.pytest), "title": "Shop", "concept": "cart totals", "subject": "python"], ctx())
        XCTAssertTrue(out.isError && out.text.contains("prove nothing"), out.text)
        // Broken tests: refused with the output.
        try write(".teacher/tests/test_shop.py", "import nothing_here\n")
        out = try await ProjectTestsTool().run(["action": "set", "command": .string(Self.pytest)], ctx())
        XCTAssertTrue(out.isError && out.text.contains("don't run"), out.text)
        // Real tests: red on the starter, baseline taken.
        try write(".teacher/tests/test_shop.py", "import sys, os\nsys.path.insert(0, os.getcwd())\nfrom shop import total\n\ndef test_plain():\n    assert total([{'price': 2, 'qty': 3}]) == 6\n\ndef test_empty():\n    assert total([]) == 0\n")
        out = try await ProjectTestsTool().run(["action": "set", "command": .string(Self.pytest)], ctx())
        XCTAssertFalse(out.isError, out.text); XCTAssertTrue(out.text.contains("Proven red on the starter: 2 failing, 0 passing"), out.text)
        let p1 = ProjectStore.load(ws)!
        XCTAssertEqual(p1.title, "Shop"); XCTAssertEqual(p1.concept, "cart totals"); XCTAssertEqual(p1.snapshotWhy, "starter"); XCTAssertEqual(p1.runs.count, 3)
        let state = CodeMentorExtension.stateLine(p1, changed: ProjectStore.changedCount(ws))
        XCTAssertTrue(state.contains("Project: Shop (cart totals)") && state.contains("0 passed, 2 failed") && state.contains("nothing changed since the starter"), state)

        // The learner works; the review starts with the diff, the run and no open findings.
        try write("shop.py", "def total(items):\n    return sum(i['price'] * i['qty'] for i in items)\n")
        let start = try await ProjectReviewTool().run(["action": "start"], ctx())
        XCTAssertFalse(start.isError, start.text)
        XCTAssertTrue(start.text.contains("Review round 1 of Shop") && start.text.contains("2 passed, 0 failed") && start.text.contains("shop.py (modified") && start.text.contains("+    return sum"), start.text)
        XCTAssertEqual(start.meta?["changes"]?.array?.count, 1)
        var findings = try await ProjectReviewTool().run(["action": "findings", "verdict": "pass", "findings": [["file": "shop.py", "line": 2, "severity": "must", "text": "Empty list?"]]], ctx())
        XCTAssertTrue(findings.isError, "a pass can't carry a must")
        findings = try await ProjectReviewTool().run(["action": "findings", "verdict": "changes", "summary": "Works, but brittle.", "findings": [
            ["file": "shop.py", "line": 2, "severity": "must", "text": "What happens when qty is missing?", "concept": "defensive input"],
            ["file": "shop.py", "line": 1, "severity": "nit", "text": "A docstring would help."]]], ctx())
        XCTAssertFalse(findings.isError, findings.text); XCTAssertTrue(findings.text.contains("Round 1 recorded: changes, 2 new"), findings.text)
        let p2 = ProjectStore.load(ws)!
        XCTAssertEqual(p2.rounds.count, 1); XCTAssertEqual(p2.openFindings.map(\.id), [1, 2]); XCTAssertEqual(p2.snapshotWhy, "review 1")
        XCTAssertEqual(ProjectStore.changedCount(ws), 0, "the review is the new baseline")
        XCTAssertTrue(CodeMentorExtension.stateLine(p2, changed: 0).contains("review round 1: changes, 2 open findings"))

        // Round 2: the open findings come back; one is resolved; a pass with green tests records mastery.
        try write("shop.py", "def total(items):\n    \"\"\"Sum of price*qty.\"\"\"\n    return sum(i.get('price', 0) * i.get('qty', 0) for i in items)\n")
        let start2 = try await ProjectReviewTool().run(["action": "start"], ctx())
        XCTAssertTrue(start2.text.contains("Review round 2") && start2.text.contains("Open findings from round 1") && start2.text.contains("[1] shop.py:2 must"), start2.text)
        let pass = try await ProjectReviewTool().run(["action": "findings", "verdict": "pass", "summary": "Good.", "resolved": [1, 2]], ctx())
        XCTAssertFalse(pass.isError, pass.text); XCTAssertTrue(pass.text.contains("Mastery of cart totals"), pass.text)
        let p3 = ProjectStore.load(ws)!
        XCTAssertEqual(p3.rounds.count, 2); XCTAssertTrue(p3.openFindings.isEmpty); XCTAssertEqual(p3.rounds[0].findings.filter(\.resolved).count, 2)
        XCTAssertNotNil(services.study.mastery(subject: "python", concept: "cart totals"))
        let status = try await ProjectReviewTool().run(["action": "status"], ctx())
        XCTAssertTrue(status.text.contains("Round 2") && status.text.contains("✓ shop.py:2"), status.text)
        let tstatus = try await ProjectTestsTool().run(["action": "status"], ctx())
        XCTAssertTrue(tstatus.text.contains("History:") && tstatus.text.contains("Review round 2"), tstatus.text)
    }

    @MainActor func testTheStateLineRidesOnTheRequestAndTestsWritesNudge() {
        var p = MentorProject(title: "Cache", concept: "LRU", testCommand: nil)
        let none = CodeMentorExtension.stateLine(p, changed: nil)
        XCTAssertTrue(none.contains("no command set"), none)
        p.testCommand = "swift test"
        XCTAssertTrue(CodeMentorExtension.stateLine(p, changed: 3).contains("3 files changed since the baseline — review with `project_review` start"))
        var r = LLMRequest(model: "m", system: "", messages: [ChatMessage(role: .user, blocks: [.text("check my work")])])
        CodeMentorExtension.inject("<project_state>x</project_state>", into: &r); CodeMentorExtension.inject("<project_state>y</project_state>", into: &r)
        XCTAssertEqual(r.messages[0].blocks.filter { $0.meta?["projectState"]?.bool == true }.count, 1)
        XCTAssertEqual(r.messages[0].blocks.last?.text, "<project_state>y</project_state>")
    }

    func testMentorModeHasTheEngineersToolsAndTheLoopInItsInstructions() {
        let names = Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .code).map(\.name))
        for t in ["project_tests", "project_review", "diagnostics", "symbols", "ask_learner", "lesson_plan"] { XCTAssertTrue(names.contains(t), t) }
        XCTAssertFalse(Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .tutor).map(\.name)).contains("project_review"))
        XCTAssertFalse(ToolRegistry.deferredIndex("code-mentor").contains("`diagnostics`"))
        let text = Instructions.mode(.code)
        XCTAssertTrue(text.contains("`project_tests` set") && text.contains("`project_review` start"))
        XCTAssertTrue(text.contains("Never write or show the solution"))
    }
}
