import XCTest
@testable import MyAITeacher

/// The code mentor's own tools: running a project's tests, and editing a file in several places at once.
final class CodeMentorToolTests: XCTestCase {
    var dir: URL!
    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cm-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent(".teacher/tests"), withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    func testRunTestsRunsEachFileAndReportsPassAndFail() async throws {
        let t = dir.appendingPathComponent(".teacher/tests")
        try "echo 'checking push'; exit 0".write(to: t.appendingPathComponent("01_push.sh"), atomically: true, encoding: .utf8)
        try "echo 'expected 3, got 2' >&2; exit 1".write(to: t.appendingPathComponent("02_pop.sh"), atomically: true, encoding: .utf8)
        try "notes".write(to: t.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let out = await RunTestsTool.rerun([:], workspace: dir)
        XCTAssertFalse(out.isError, out.text)
        XCTAssertTrue(out.text.hasPrefix("Tests: 1/2 passing"), out.text)
        XCTAssertTrue(out.text.contains("✓ 01_push.sh") && out.text.contains("✗ 02_pop.sh") && out.text.contains("expected 3, got 2"), out.text)
        XCTAssertEqual(out.meta?["passed"]?.int, 1); XCTAssertEqual(out.meta?["total"]?.int, 2)
        XCTAssertEqual(out.meta?["tests"]?[1]?["passed"]?.bool, false)
        // A filter, and a command instead of the folder.
        let filtered = await RunTestsTool.rerun(["filter": "push"], workspace: dir).text
        XCTAssertTrue(filtered.hasPrefix("Tests: 1/1"), filtered)
        let command = await RunTestsTool.rerun(["command": "exit 3"], workspace: dir).text
        XCTAssertTrue(command.hasPrefix("Tests: 0/1"), command)
        // No tests yet: say where they go.
        try FileManager.default.removeItem(at: t)
        let none = await RunTestsTool.rerun([:], workspace: dir)
        XCTAssertTrue(none.isError && none.text.contains(".teacher/tests"), none.text)
    }

    func testRunnerSummariesBecomeCaseCounts() {
        XCTAssertEqual(RunTestsTool.counts("All 4 tests passed.")?.passed, 4)
        let zig = RunTestsTool.counts("3 passed; 1 failed.")
        XCTAssertEqual(zig?.passed, 3); XCTAssertEqual(zig?.failed, 1)
        XCTAssertEqual(RunTestsTool.counts("=== RUN TestA\n--- PASS: TestA\n--- FAIL: TestB")?.failed, 1)
        XCTAssertEqual(RunTestsTool.counts("# pass 5\n# fail 0")?.passed, 5)
        XCTAssertNil(RunTestsTool.counts("compiled fine"))
    }

    func testEditAppliesSeveralChangesOrNone() async throws {
        let f = dir.appendingPathComponent("soa.zig")
        try "const a = 1;\nconst b = 2;\nconst c = 3;\n".write(to: f, atomically: true, encoding: .utf8)
        let ctx = ToolContext(conversationID: "l", workspace: dir, services: Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir)), interactions: await MainActor.run { InteractionCenter() },
                              toolCallID: "e", client: ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m").client(apiKey: nil),
                              model: "m", progress: { _ in })
        let ok = try await EditTool().run(["path": "soa.zig", "edits": [["old_string": "a = 1", "new_string": "a = 10"], ["old_string": "c = 3", "new_string": "c = 30"]]], ctx)
        XCTAssertFalse(ok.isError, ok.text); XCTAssertTrue(ok.text.contains("applied 2 edits"))
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "const a = 10;\nconst b = 2;\nconst c = 30;\n")
        let bad = try await EditTool().run(["path": "soa.zig", "edits": [["old_string": "b = 2", "new_string": "b = 20"], ["old_string": "missing", "new_string": "x"]]], ctx)
        XCTAssertTrue(bad.isError && bad.text.contains("Edit 2") && bad.text.contains("Nothing was changed"), bad.text)
        XCTAssertTrue(try String(contentsOf: f, encoding: .utf8).contains("b = 2;"), "all or nothing")
    }
}
