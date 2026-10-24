import XCTest
@testable import MyAITeacher

/// The code mentor's project after the baseline: commands run inside a write fence, the tests and the record are fixed
/// (a review sees any change), help shapes what a pass records, and the guard sees definitions in the common languages.
final class MentorCockpitTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var ws: Workspace { services.workspace }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("cockpit-\(UUID().uuidString.prefix(6))")
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
    func read(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    func sh(_ script: String) async -> ProcessResult {
        await WriteFence.$profile.withValue(MentorGuard.fence(ws)) { await ProcessRunner.run("/bin/zsh", ["-c", script], cwd: dir, timeout: 20) }
    }

    // MARK: The fence

    func testCommandsCantWriteTheLearnersFilesOrTheTests() async throws {
        try XCTSkipUnless(WriteFence.available)
        try write("src/lexer.zig", "pub fn next() void { @panic(\"TODO\"); }\n")
        try write(".teacher/tests/spec.zig", "test \"x\" {}\n")
        let r = await sh("""
            echo hacked > src/lexer.zig; rm -f src/lexer.zig; echo new > src/solution.zig; echo t > .teacher/tests/spec.zig
            echo '{}' > .teacher/project.json
            mkdir -p .zig-cache zig-out src/__pycache__ && echo c > .zig-cache/o.zig && echo b > zig-out/bin && echo p > src/__pycache__/x.pyc
            echo note > .teacher/mentor/plan.md; echo done
            """)
        XCTAssertTrue(r.stdout.contains("done"), r.stdout + r.stderr)
        XCTAssertTrue(r.stderr.lowercased().contains("operation not permitted"), r.stderr)
        XCTAssertEqual(read("src/lexer.zig"), "pub fn next() void { @panic(\"TODO\"); }\n", "the learner's file is untouched")
        XCTAssertNil(read("src/solution.zig"), "no new source file")
        XCTAssertEqual(read(".teacher/tests/spec.zig"), "test \"x\" {}\n", "the tests are locked")
        XCTAssertNil(read(".teacher/project.json"), "the record can't be written by a command")
        XCTAssertEqual(read(".zig-cache/o.zig"), "c\n"); XCTAssertEqual(read("zig-out/bin"), "b\n"); XCTAssertEqual(read("src/__pycache__/x.pyc"), "p\n")
        XCTAssertEqual(read(".teacher/mentor/plan.md"), "note\n", "the mentor's own notes")
        // Unlocked by the learner: the tests open, the learner's files stay closed.
        ProjectStore.mutate(ws) { $0.testsUnlockedAt = Date() }
        _ = await sh("echo t2 > .teacher/tests/spec.zig; echo x > src/lexer.zig")
        XCTAssertEqual(read(".teacher/tests/spec.zig"), "t2\n")
        XCTAssertEqual(read("src/lexer.zig"), "pub fn next() void { @panic(\"TODO\"); }\n")
        // Without a fence nothing changes for other lessons.
        _ = await ProcessRunner.run("/bin/zsh", ["-c", "echo free > src/lexer.zig"], cwd: dir, timeout: 10)
        XCTAssertEqual(read("src/lexer.zig"), "free\n")
    }

    @MainActor func testTheBashToolRunsInsideTheFenceToo() async throws {
        try XCTSkipUnless(WriteFence.available)
        try write("calc.py", "def evaluate(src):\n    raise NotImplementedError\n")
        let fence = MentorGuard.fence(ws)
        let c = ctx()
        let out = try await WriteFence.$profile.withValue(fence) {
            try await BashTool().run(["command": "printf 'def evaluate(src):\\n    return 42\\n' > calc.py; echo after"], c)
        }
        XCTAssertTrue(out.text.contains("after"), out.text)
        XCTAssertTrue(out.text.lowercased().contains("operation not permitted"), out.text)
        XCTAssertEqual(read("calc.py"), "def evaluate(src):\n    raise NotImplementedError\n")
    }

    // MARK: Registering the tests

    @MainActor func testSetStoresNothingUntilAcceptedAndChecksTheStarter() async throws {
        let tool = ProjectTestsTool()
        try write("calc.py", "def evaluate(src):\n    tokens = src.split()\n    total = 0\n    for t in tokens:\n        total += int(t)\n    return total\n")
        let bad = try await tool.run(["action": "set", "command": "exit 3"], ctx())
        XCTAssertTrue(bad.isError && bad.text.contains("Nothing was registered"), bad.text)
        XCTAssertNil(ProjectStore.load(ws)?.testCommand, "a refused command isn't kept")
        let red = "echo '1 passed, 1 failed in 0.1s'; exit 1"
        let given = try await tool.run(["action": "set", "command": .string(red), "targets": ["evaluate"]], ctx())
        XCTAssertTrue(given.isError && given.text.contains("already implements evaluate"), given.text)
        try write("calc.py", "def evaluate(src):\n    raise NotImplementedError\n")
        let ok = try await tool.run(["action": "set", "command": .string(red), "title": "calc", "concept": "parsing"], ctx())
        XCTAssertFalse(ok.isError, ok.text)
        let p = try XCTUnwrap(ProjectStore.load(ws))
        XCTAssertEqual(p.targets, ["evaluate"], "the placeholder function is a target without being named")
        XCTAssertNotNil(p.testsDigest); XCTAssertNotNil(p.snapshotAt)
        let again = try await tool.run(["action": "set", "command": "true"], ctx())
        XCTAssertTrue(again.isError && again.text.contains("locked"), again.text)
        _ = try await tool.run(["action": "unlock"], ctx())
        try write(".teacher/tests/test_more.py", "def test_more(): pass\n")
        let re = try await tool.run(["action": "set", "command": .string(red)], ctx())
        XCTAssertTrue(re.text.contains("Re-baselined"), re.text)
        let q = try XCTUnwrap(ProjectStore.load(ws))
        XCTAssertNil(q.testsUnlockedAt); XCTAssertEqual(q.suiteChanges?.count, 1)
        XCTAssertEqual(q.testsDigest, ProjectStore.testsDigest(ws, command: red))
    }

    // MARK: Reviews

    @MainActor func testAPassNeedsTheSuiteAndTheRecordAsTheAppLeftThem() async throws {
        try write("app.py", "def f():\n    return 1\n")
        try write(".teacher/tests/test_app.py", "def test_f(): pass\n")
        ProjectStore.mutate(ws) { $0.title = "f"; $0.concept = "functions"; $0.testCommand = "true"; $0.testsDigest = ProjectStore.testsDigest(ws, command: "true") }
        ProjectStore.snapshot(ws, why: "starter")
        let tool = ProjectReviewTool()
        try write("app.py", "def f():\n    return 2\n")
        try write(".teacher/tests/test_app.py", "def test_f(): assert True\n")      // the suite changed
        let s1 = try await tool.run(["action": "start"], ctx())
        XCTAssertTrue(s1.text.contains("tests changed since the baseline"), s1.text)
        let p1 = try await tool.run(["action": "findings", "verdict": "pass"], ctx())
        XCTAssertTrue(p1.isError && p1.text.contains("changed"), p1.text)
        // Back as it was, but the record edited by hand.
        try write(".teacher/tests/test_app.py", "def test_f(): pass\n")
        var raw = try XCTUnwrap(read(".teacher/project.json")); raw = raw.replacingOccurrences(of: "\"functions\"", with: "\"anything\"")
        try write(".teacher/project.json", raw)
        XCTAssertFalse(ProjectStore.intact(ws))
        _ = try await tool.run(["action": "start"], ctx())
        let p2 = try await tool.run(["action": "findings", "verdict": "pass"], ctx())
        XCTAssertTrue(p2.isError && p2.text.contains("outside the app"), p2.text)
    }

    @MainActor func testAPassAfterHintsIsEvidenceNotMasteryThenExplainBack() async throws {
        try write("app.py", "def f():\n    return 1\n")
        ProjectStore.mutate(ws) { $0.title = "f"; $0.concept = "recursion"; $0.testCommand = "true" }
        ProjectStore.snapshot(ws, why: "starter")
        let tool = ProjectReviewTool()
        try write("app.py", "def f():\n    return 2\n")
        _ = try await tool.run(["action": "start"], ctx())
        _ = try await tool.run(["action": "findings", "verdict": "changes", "findings": [["file": "app.py", "line": 2, "severity": "should", "text": "What's the base case?", "hints": ["Look at n == 0.", "What should f(0) return?"]]]], ctx())
        let id = try XCTUnwrap(ProjectStore.load(ws)?.rounds.last?.findings.first?.id)
        XCTAssertEqual(ProjectStore.load(ws)?.rounds.last?.findings.first?.hints?.count, 2)
        // The learner reveals a hint in the Project panel: recorded as help.
        ProjectStore.mutate(ws) { p in p.rounds[p.rounds.count - 1].findings[0].revealed = 1; p.help = [MentorProject.HelpUse(at: Date(), kind: "hint", detail: "finding [\(id)], hint 1")] }
        XCTAssertEqual(ProjectStore.load(ws)?.helpSinceReview, .hint)
        try write("app.py", "def f():\n    return 3\n")
        _ = try await tool.run(["action": "start"], ctx())
        let before = services.study.mastery(subject: "programming", concept: "recursion")?.pKnown ?? 0.2
        let pass = try await tool.run(["action": "findings", "verdict": "pass", "resolved": [.number(Double(id))]], ctx())
        XCTAssertTrue(pass.text.contains("helped pass") && pass.text.contains("explain-back"), pass.text)
        XCTAssertEqual(services.study.mastery(subject: "programming", concept: "recursion")?.pKnown ?? 0, before, accuracy: 0.0001, "help doesn't raise mastery")
        XCTAssertEqual(ProjectStore.load(ws)?.rounds.last?.help, "hint")
        let ex = try await tool.run(["action": "explain", "verdict": "pass", "question": "Why does f need a base case?"], ctx())
        XCTAssertFalse(ex.isError, ex.text)
        XCTAssertGreaterThan(services.study.mastery(subject: "programming", concept: "recursion")?.pKnown ?? 0, before, "an unaided explanation counts")
        XCTAssertEqual(ProjectStore.load(ws)?.explainBack?.verdict, "pass")
    }

    // MARK: The guard's eyes

    func testDefinitionsAndPlaceholdersAcrossLanguages() {
        let code = """
        func (b *Bucket) Allow(now int64) bool {
        export const tokenize = (src: string): Token[] => {
        public int evaluate(String expr) throws ParseError {
        pub fn next(self: *Lexer) !Token {
        fun parseExpr(tokens: List<Token>): Expr {
        static int peek(struct lexer *l) {
        async function fetchAll(urls) {
        if (x > 0) {
        """
        XCTAssertEqual(MentorGuard.definitions(in: code).map(\.name), ["Allow", "tokenize", "evaluate", "next", "parseExpr", "peek", "fetchAll"])
        let java = "class Calc {\n    public int evaluate(String e) {\n        throw new UnsupportedOperationException();\n    }\n    public int size() {\n        return 0;\n    }\n}\n"
        XCTAssertEqual(MentorGuard.stubs(in: java), ["evaluate"])
        XCTAssertEqual(MentorGuard.stubs(in: "func Allow() bool {\n\tpanic(\"not implemented\")\n}\n"), ["Allow"])
        // A target's one-line fix is a solution; their own line quoted back is not.
        let learner = MentorGuard.Learner(targets: ["next"], lines: ["pub fn next(self: *Lexer) !Token {", "@panic(\"TODO\");"])
        XCTAssertNotNil(MentorGuard.solution(in: "pub fn next(self: *Lexer) !Token {\n    return self.scan();\n}", learner: learner))
        XCTAssertNil(MentorGuard.solution(in: "pub fn next(self: *Lexer) !Token {\n    @panic(\"TODO\");\n}", learner: learner))
        // A skeleton — the shape, the work left as TODO — is teaching; past a couple of lines of real code it isn't.
        XCTAssertNil(MentorGuard.solution(in: "pub fn next(self: *Lexer) !Token {\n    const c = self.peek();\n    // TODO: classify c\n    @panic(\"TODO\");\n}", learner: learner))
        XCTAssertNotNil(MentorGuard.solution(in: "pub fn next(self: *Lexer) !Token {\n    const c = self.peek();\n    if (c == '+') return .plus;\n    if (c == '-') return .minus;\n    // TODO: the rest\n    @panic(\"TODO\");\n}", learner: learner))
        // While streaming: an open block that already writes the target is cut from its fence.
        let masked = MentorGuard.mask("Look:\n\n```zig\npub fn next(self: *Lexer) !Token {\n    const c = self.src[self.i];\n", learner: learner)
        XCTAssertEqual(masked?.contains("self.src"), false); XCTAssertEqual(masked?.contains("Code withheld"), true)
        XCTAssertNil(MentorGuard.mask("Look:\n\n```zig\nconst x = 1;\n", learner: learner))
    }

    func testOneTestCanBeRerun() {
        XCTAssertEqual(ProjectTestRunner.filtered("python3 -m pytest .teacher/tests -q", test: ".teacher/tests/test_a.py::test_two"), "python3 -m pytest .teacher/tests -q -k 'test_two'")
        XCTAssertEqual(ProjectTestRunner.filtered("zig test .teacher/tests/spec.zig", test: "spec.test.empty input"), "zig test .teacher/tests/spec.zig --test-filter 'empty input'")
        XCTAssertEqual(ProjectTestRunner.filtered("go test ./...", test: "TestAllow"), "go test ./... -run '^TestAllow$'")
        XCTAssertEqual(ProjectTestRunner.filtered("npx jest", test: "adds"), "npx jest -t 'adds'")
        XCTAssertNil(ProjectTestRunner.filtered("zig build test", test: "spec.test.x"), "the build script decides")
    }
}
