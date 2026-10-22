import XCTest
@testable import MyAITeacher

/// Code mentor projects: sandboxed runs, hidden tests proved against a hidden solution, and a mentor that can't write the
/// learner's code or show the solution.
final class ExerciseTests: XCTestCase {
    var dir: URL!
    var ctx: ToolContext!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("exercise-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let interactions = await MainActor.run { InteractionCenter() }
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        ctx = ToolContext(conversationID: "lesson-\(UUID().uuidString.prefix(6))", workspace: dir,
                          services: Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir)),
                          interactions: interactions, toolCallID: "c", client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testSandboxKeepsCodeInItsFolderAndOffTheNetwork() async throws {
        let run = dir.appendingPathComponent("run"); try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let ok = await Sandbox.run("python3 -c 'print(6*7)' && echo data > out.txt && cat out.txt", in: run, writable: [])
        XCTAssertTrue(ok.passed && ok.output.contains("42") && ok.output.contains("data"), ok.output)
        let outside = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("teacher-escape-\(UUID().uuidString.prefix(6)).txt")
        let escape = await Sandbox.run("echo x > '\(outside.path)'", in: run, writable: [])
        XCTAssertFalse(escape.passed); XCTAssertFalse(FileManager.default.fileExists(atPath: outside.path), "no writes outside the run folder")
        let net = await Sandbox.run("curl -s -m 5 https://example.com > /dev/null", in: run, writable: [])
        XCTAssertFalse(net.passed, "no network")
        let secret = await Sandbox.run("ls '\(AppPaths.support.path)'", in: run, writable: [])
        XCTAssertFalse(secret.passed, "the app's data (keys, hidden tests, solutions) can't be read: \(secret.output)")
        let env = await Sandbox.run("env | grep -c _API_KEY || true", in: run, writable: [])
        XCTAssertEqual(env.output.trimmingCharacters(in: .whitespacesAndNewlines), "0", "no API keys in the environment")
        let slow = await Sandbox.run("sleep 5", in: run, writable: [], timeout: 1)
        XCTAssertTrue(slow.timedOut && !slow.passed)
    }

    static let starter = ["wordfreq.py": "def top_words(text, n):\n    \"\"\"The n most frequent words (case-insensitive), ties alphabetical.\"\"\"\n    raise NotImplementedError\n"]
    static let solution = ["wordfreq.py": """
        import re
        from collections import Counter

        def top_words(text, n):
            counts = Counter(re.findall(r"[a-z']+", text.lower()))
            ranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))
            return [word for word, _ in ranked[:n]]
        """]
    static let tests = ["test_wordfreq.py": """
        import unittest
        from wordfreq import top_words

        class T(unittest.TestCase):
            def test_counts(self): self.assertEqual(top_words("b a b c a b", 2), ["b", "a"])
            def test_case(self): self.assertEqual(top_words("Go go GO stop", 1), ["go"])
            def test_ties(self): self.assertEqual(top_words("z y x", 2), ["x", "y"])
            def test_empty(self): self.assertEqual(top_words("", 3), [])
        """]

    func create(starter: [String: String] = starter, solution: [String: String] = solution, tests: [String: String] = tests) async throws -> ToolOutput {
        func obj(_ d: [String: String]) -> JSON { .object(d.mapValues { .string($0) }) }
        return try await ExerciseTool().run(["action": "create", "title": "Word frequencies", "language": "python", "concept": "hash maps",
            "brief": "Implement `top_words(text, n)`: the n most frequent words, case-insensitive, ties broken alphabetically. Handle empty input.",
            "files": obj(starter), "tests": obj(tests), "solution": obj(solution), "test": "python3 -m unittest -q"], ctx)
    }

    func testAnExerciseIsProvedThenHandedOverWithoutItsSecrets() async throws {
        let out = try await create()
        XCTAssertFalse(out.isError, out.text)
        let id = try XCTUnwrap(out.meta?["exercise"]?.string), e = try XCTUnwrap(ExerciseStore.load(id))
        let learner = ExerciseStore.read(e.dir)
        XCTAssertEqual(Set(learner.keys), ["wordfreq.py", "BRIEF.md"], "the learner gets the starter and the brief, nothing else")
        XCTAssertFalse(learner.values.joined().contains("Counter("), "no solution in their folder")
        XCTAssertTrue(FileManager.default.fileExists(atPath: ExerciseStore.tests(id).appendingPathComponent("test_wordfreq.py").path))
        XCTAssertTrue(e.dir.path.hasPrefix(dir.path + "/exercises/"), e.dir.path)
        // The starter fails; the learner's own correct work passes; the tests never land in their folder.
        let fail = await ExerciseStore.runTests(e, project: e.dir)
        XCTAssertFalse(fail.passed)
        try ExerciseStore.write(Self.solution, to: e.dir)
        let pass = await ExerciseStore.runTests(e, project: e.dir)
        XCTAssertTrue(pass.passed, pass.output)
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.dir.appendingPathComponent("test_wordfreq.py").path))
        let check = try await ExerciseTool().run(["action": "check", "id": .string(id)], ctx)
        XCTAssertTrue(check.text.contains("PASS"), check.text)
        let read = try await ExerciseTool().run(["action": "read", "id": .string(id)], ctx)
        XCTAssertTrue(read.text.contains("--- wordfreq.py") && read.text.contains("top_words"), read.text)
    }

    func testBrokenOrTrivialExercisesAreSentBack() async throws {
        let wrong = try await create(solution: ["wordfreq.py": "def top_words(text, n):\n    return []\n"])
        XCTAssertTrue(wrong.isError && wrong.text.contains("reference solution fails"), wrong.text)
        let trivial = try await create(starter: Self.solution, solution: ["wordfreq.py": Self.solution["wordfreq.py"]! + "\n# tidy\n"])
        XCTAssertTrue(trivial.isError && trivial.text.contains("starter already passes"), trivial.text)
        let none = try await create(solution: [:])
        XCTAssertTrue(none.isError && none.text.contains("No reference solution"), none.text)
        let unsafe = try await create(starter: ["../escape.py": "x = 1"])
        XCTAssertTrue(unsafe.isError && unsafe.text.contains("Unsafe path"), unsafe.text)
        XCTAssertTrue(ExerciseStore.list(conversationID: ctx.conversationID).isEmpty, "nothing half-made is left behind")
        XCTAssertTrue(((try? FileManager.default.contentsOfDirectory(atPath: ExerciseStore.root.path)) ?? []).allSatisfy { ExerciseStore.load($0)?.conversationID != ctx.conversationID },
                      "no drafts left on disk either")
    }

    /// A real project is built in steps: draft, add (starter, tests, solution), publish.
    func testAProjectBuiltInSteps() async throws {
        func obj(_ d: [String: String]) -> JSON { .object(d.mapValues { .string($0) }) }
        let t = ExerciseTool()
        let d = try await t.run(["action": "draft", "title": "Word frequencies", "language": "python", "test": "python3 -m unittest -q",
                                 "brief": "Implement `top_words(text, n)`: the n most frequent words, case-insensitive, ties alphabetical, empty input allowed."], ctx)
        let id = try XCTUnwrap(d.meta?["exercise"]?.string)
        let early = try await t.run(["action": "publish", "id": .string(id)], ctx)
        XCTAssertTrue(early.isError && early.text.contains("No starter files"), early.text)
        for (part, files) in [("starter", Self.starter), ("tests", Self.tests), ("solution", Self.solution)] {
            let a = try await t.run(["action": "add", "id": .string(id), "part": .string(part), "files": obj(files)], ctx)
            XCTAssertFalse(a.isError, a.text)
        }
        let out = try await t.run(["action": "publish", "id": .string(id)], ctx)
        XCTAssertFalse(out.isError, out.text)
        let e = try XCTUnwrap(ExerciseStore.load(id))
        XCTAssertEqual(Set(ExerciseStore.read(e.dir).keys), ["wordfreq.py", "BRIEF.md"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: ExerciseStore.draftStarter(id).path), "the draft's starter moved to the learner")
        let again = try await t.run(["action": "add", "id": .string(id), "part": "solution", "files": obj(Self.solution)], ctx)
        XCTAssertTrue(again.isError, "a published exercise can't be changed behind the learner's back")
    }

    func testSolutionCodeInARepliesIsWithheld() {
        let solution = ExerciseStore.signatureLines(Self.solution["wordfreq.py"]!)
        let leak = "Here's one way:\n```python\ncounts = Counter(re.findall(r\"[a-z']+\", text.lower()))\nranked = sorted(counts.items(), key=lambda kv: (-kv[1], kv[0]))\nreturn [word for word, _ in ranked[:n]]\n```\nTry it."
        let out = ExerciseExtension.withhold(leak, solution: solution)
        XCTAssertNotNil(out); XCTAssertFalse(out!.contains("Counter("), out!); XCTAssertTrue(out!.contains("Code withheld") && out!.contains("Try it."))
        let teaching = "Think about this:\n```python\nwords = text.split()\nprint(len(words))\n```"
        // Quoting the learner's own starter back (signatures, docstrings) is never withheld.
        let secret = ExerciseStore.signatureLines(Self.solution["wordfreq.py"]!).subtracting(ExerciseStore.signatureLines(Self.starter["wordfreq.py"]!))
        let quote = "Your function:\n```python\ndef top_words(text, n):\n    \"\"\"The n most frequent words (case-insensitive), ties alphabetical.\"\"\"\n```"
        XCTAssertNil(ExerciseExtension.withhold(quote, solution: secret))
        XCTAssertNil(ExerciseExtension.withhold(teaching, solution: solution), "unrelated code stays")
    }

    func testTheMentorsShellCantWriteTheLearnersFiles() {
        let f = ["/Users/x/AI Teacher Workspace/exercises/word-frequencies"]
        XCTAssertTrue(ExerciseExtension.writesInto("cat > exercises/word-frequencies/wordfreq.py <<EOF", folders: f))
        XCTAssertTrue(ExerciseExtension.writesInto("sed -i '' 's/a/b/' exercises/word-frequencies/wordfreq.py", folders: f))
        XCTAssertFalse(ExerciseExtension.writesInto("cat exercises/word-frequencies/wordfreq.py", folders: f), "reading is fine")
        XCTAssertFalse(ExerciseExtension.writesInto("ls > /tmp/x", folders: f), "elsewhere is fine")
    }

    /// A live mentor built its reference solution with run_code heredocs into the learner's folder (an absolute path).
    func testTheMentorsOwnCodeStaysInItsScratchFolder() async throws {
        // A lesson folder lives under the home folder (temp is writable to the sandbox on purpose: compilers need it).
        let scratch = dir.appendingPathComponent("scratch")
        let learner = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".teacher-sandbox-test-\(UUID().uuidString.prefix(6))/ruletec-dev")
        defer { try? FileManager.default.removeItem(at: learner.deletingLastPathComponent()) }
        let r = try await RunCodeTool.execute(language: "bash", code: "mkdir -p '\(learner.path)' && echo solution > '\(learner.path)/x.py'; echo here > ok.txt; cat ok.txt",
                                              stdin: nil, timeout: 30, workingDirectory: { try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true); return scratch }(),
                                              sandboxed: true)
        XCTAssertTrue(r.text.contains("here"), r.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: learner.appendingPathComponent("x.py").path), "nothing written outside the scratch folder")
        // A learner's project in a place that is otherwise writable (temp) is still off limits to the mentor's code.
        let project = dir.appendingPathComponent("exercises/dsquery"); try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        _ = try await RunCodeTool.execute(language: "python", code: "open(r'\(project.path)/lexer.py', 'w').write('solution')", stdin: nil, timeout: 30,
                                          workingDirectory: scratch, sandboxed: true, readOnly: [project])
        XCTAssertFalse(FileManager.default.fileExists(atPath: project.appendingPathComponent("lexer.py").path), "the learner's project is read-only to the mentor")
    }

    func testCodeMentorSetsRealProjectsAndEveryModeHasTheDepthStandard() {
        let mentor = SystemPrompt.build(settings: AppSettings(), mode: .code, coreMemory: "", model: "m")
        XCTAssertTrue(mentor.contains("`exercise`") && mentor.contains("never toy snippets") && mentor.contains("never show the solution"))
        for mode in TeachingMode.allCases where !mode.isAgent {
            XCTAssertTrue(SystemPrompt.build(settings: AppSettings(), mode: mode, coreMemory: "", model: "m").contains("No toy or textbook-filler content"), "\(mode)")
        }
        XCTAssertTrue(ToolRegistry.active(AppSettings(), loaded: [], mode: .code).contains { $0.name == "exercise" }, "ready in code mentor")
        let mentorTools = Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .code).map(\.name))
        XCTAssertTrue(mentorTools.isDisjoint(with: ["write", "edit", "bash"]), "the mentor writes no code files: \(mentorTools)")
        XCTAssertTrue(mentorTools.contains("run_code"), "demonstrations still run in a scratch space")
        XCTAssertFalse(ToolRegistry.active(AppSettings(), loaded: [], mode: .tutor).contains { $0.name == "exercise" }, "loaded on demand elsewhere")
        XCTAssertEqual(AppSettings().thinking, .high)
        XCTAssertEqual(SubAgentSettings().effort, .high)
    }
}
