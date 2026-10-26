import XCTest
@testable import MyAITeacher

/// Exercises every Claude-Code-equivalent tool against a real temporary folder.
final class ToolParityTests: XCTestCase {
    var dir: URL!
    var ctx: ToolContext!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("parity-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src"), withIntermediateDirectories: true)
        try "alpha\nbeta\ngamma\n".write(to: dir.appendingPathComponent("src/a.txt"), atomically: true, encoding: .utf8)
        try "print('hi')\n".write(to: dir.appendingPathComponent("src/b.py"), atomically: true, encoding: .utf8)
        let ws = try Workspace(url: dir)
        let db = try Database(path: dir.appendingPathComponent("g.sqlite").path)
        try db.script(Schema_.sql)
        let interactions = await MainActor.run { InteractionCenter() }
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        ctx = ToolContext(conversationID: "t", workspace: dir, services: Services(global: GlobalStore(), workspace: ws),
                          interactions: interactions, toolCallID: "c", client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        // A refused connection is a provider error that may pass: runs restart (and resume) a few times; quickly here.
        SubAgent.recovery = (limit: Intensity(maxRestarts: 2, period: 60), backoff: Backoff(initial: 0.01, factor: 1, max: 0.01))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func run(_ name: String, _ input: JSON) async throws -> ToolOutput {
        try await ToolRegistry.byName[name]!.run(input, ctx)
    }

    func testAskLearnerWithoutQuestionsSaysWhatToSend() async throws {
        for input: JSON in [["graded": true, "title": "Atoms"], ["title": "Atoms"], [:]] {
            let o = try await AskLearnerTool().run(input, ctx)   // returns at once: nothing to show, nothing to wait for
            XCTAssertTrue(o.isError && o.text.contains("\"questions\":[{") && o.text.contains("\"options\""), o.text)
        }
    }

    func testCodeAgentHasItsToolsetAndProjectMemory() async throws {
        let names = Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .agent).map(\.name))
        for t in ["read", "write", "edit", "glob", "grep", "bash", "todo_write", "task", "project_memory"] { XCTAssertTrue(names.contains(t), t) }
        for t in ["memory", "flashcards", "mastery", "lesson_plan"] { XCTAssertFalse(names.contains(t), t) }
        XCTAssertTrue(names.contains("run_tests") && names.contains("load_tools"), "the root's runtime loading: `visual` comes in on demand")
        XCTAssertTrue(ToolRegistry.deferredIndex("engineer").contains("`visual`"))
        var o = try await ProjectMemoryTool().run(["action": "add", "section": "Commands", "text": "Run tests: swift test"], ctx)
        XCTAssertTrue(o.text.contains("Commands"), o.text)
        o = try await ProjectMemoryTool().run(["action": "add", "section": "Commands", "text": "Run tests: swift test"], ctx)
        XCTAssertEqual(o.text, "Already noted.")
        _ = try await ProjectMemoryTool().run(["action": "add", "section": "Gotchas", "text": "The build needs Xcode 27"], ctx)
        let doc = ProjectMemory.read(dir)
        XCTAssertTrue(doc.contains("## Commands\n- Run tests: swift test") && doc.contains("## Gotchas"), doc)
        try "Use tabs.".write(to: dir.appendingPathComponent("AGENTS.md"), atomically: true, encoding: .utf8)
        let prompt = SystemPrompt.buildAgent(settings: AppSettings(), folder: dir, model: "m", projectMemory: ProjectMemory.contextBlock(dir))
        XCTAssertTrue(prompt.contains("Run tests: swift test") && prompt.contains("Use tabs.") && prompt.contains("coding agent"))
        _ = try await ProjectMemoryTool().run(["action": "remove", "text": "xcode"], ctx)
        XCTAssertFalse(ProjectMemory.read(dir).contains("Xcode"))
    }

    /// The brief under another name (MiniMax-M3 sent `action` + `role`) still starts the sub-agent; no brief at all is an error.
    func testSubAgentBriefAliases() async throws {
        var c = ctx!
        c = ToolContext(conversationID: "alias-lesson", workspace: c.workspace, services: c.services, interactions: c.interactions, toolCallID: "al-1",
                        client: c.client, model: "m", progress: { _ in })
        let o = try await TaskTool().run(["agent_id": "researcher", "action": "find three facts", "role": "Researcher", "background": true], c)
        let handle = try XCTUnwrap(o.meta?["handle"]?.string, o.text)
        let title = await SubAgentCenter.shared.run(handle)?.title
        XCTAssertEqual(title, "Researcher")
        do { _ = try await TaskTool().run(["description": "x", "background": true], c); XCTFail("no brief must fail") }
        catch { XCTAssertTrue("\(error)".contains("prompt"), "\(error)") }
    }

    func testBackgroundSubAgentReportsLaterAndCanBeManaged() async throws {
        let got = expectation(description: "report delivered")
        await MainActor.run { SubAgentCenter.shared.onReport = { run, out in if run.title == "BG" { got.fulfill() } } }
        var c = ctx!
        c = ToolContext(conversationID: "bg-lesson", workspace: c.workspace, services: c.services, interactions: c.interactions, toolCallID: "bg-1",
                        client: c.client, model: "m", progress: { _ in })
        let t0 = Date()
        let o = try await TaskTool().run(["description": "BG", "prompt": "find x", "background": true], c)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1, "background returns at once")
        XCTAssertTrue(o.text.contains("background") && o.meta?["handle"]?.string?.hasPrefix("A") == true, o.text)
        let handle = o.meta!["handle"]!.string!
        await fulfillment(of: [got], timeout: 5)   // the provider refuses at once, so it fails fast and reports
        var a = try await AgentsTool().run(["action": "list"], c)
        XCTAssertTrue(a.text.contains(handle) && a.text.contains("failed"), a.text)
        a = try await AgentsTool().run(["action": "status", "id": .string(handle)], c)
        XCTAssertTrue(a.text.contains("BG"), a.text)
        // Resume continues the same run (same handle, its context kept); blocking this time.
        let before = await SubAgentCenter.shared.run(handle)!.messages.count
        let r = try await TaskTool().run(["description": "BG", "prompt": "try again", "resume": .string(handle)], c)
        XCTAssertEqual(r.meta?["handle"]?.string, handle)
        let after = await SubAgentCenter.shared.run(handle)!.messages.count
        XCTAssertGreaterThan(after, before)
        let other = ToolContext(conversationID: "other", workspace: c.workspace, services: c.services, interactions: c.interactions, toolCallID: "x",
                                client: c.client, model: "m", progress: { _ in })
        let foreign = try await AgentsTool().run(["action": "status", "id": .string(handle)], other)
        XCTAssertTrue(foreign.isError, "another lesson can't see it")
        await MainActor.run { SubAgentCenter.shared.onReport = nil }
    }

    func testSubAgentModelChoiceIsListedAndChecked() async throws {
        let spec = TaskTool.spec(models: ["a:free", "b:free"], current: "a:free")
        XCTAssertTrue(spec.schema["properties"]?["model"]?["description"]?.string?.contains("b:free") == true)
        XCTAssertNil(TaskTool.spec(models: [], current: "a").schema["properties"]?["model"], "no list, no choice")
        var c = ctx!
        c.subAgentModels = ["m", "small:free"]
        let o = try await TaskTool().run(["description": "x", "prompt": "y", "model": "paid-big"], c)
        XCTAssertTrue(o.isError && o.text.contains("small:free"), o.text)
    }

    func testSubAgentFailsCleanlyWhenItsProviderIsDown() async throws {
        let o = try await TaskTool().run(["description": "Down", "prompt": "find x", "model": "m"], ctx)   // 127.0.0.1:1 refuses
        XCTAssertTrue(o.isError && o.text.contains("failed"), o.text)
        let run = await SubAgentCenter.shared.run("c")
        let state = await run?.state, model = await run?.model
        XCTAssertEqual(state, .failed); XCTAssertEqual(model, "m")
        XCTAssertNotNil(o.meta?["subagent"]?["messages"]?.array, "transcript kept for reopening")
    }

    func testSubAgentStopsPromptlyWhenCancelled() async throws {
        // A provider that never answers (non-routable address): only cancellation can end this.
        let cfg = ProviderConfig(id: "hang", name: "hang", api: .openai, baseURL: "http://10.255.255.1:9", envKeys: [], defaultModel: "m")
        let hanging = ToolContext(conversationID: "t", workspace: dir, services: ctx.services, interactions: ctx.interactions, toolCallID: "hang-1",
                                  client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        let t0 = Date()
        let task = Task { try await TaskTool().runBounded(["description": "Hang", "prompt": "x"], hanging) }
        try await Task.sleep(nanoseconds: 300_000_000)
        task.cancel()
        _ = await task.result
        XCTAssertLessThan(Date().timeIntervalSince(t0), 3, "stop must not wait for the network")
        try await Task.sleep(nanoseconds: 300_000_000)
        let state = await SubAgentCenter.shared.run("hang-1")?.state
        XCTAssertEqual(state, .stopped)
    }

    func testClaudeCodeEquivalentTools() async throws {
        // Read (cat -n, offset/limit)
        var o = try await run("read", ["path": "src/a.txt", "offset": 2, "limit": 1])
        XCTAssertTrue(o.text.contains("2\tbeta") && !o.text.contains("alpha"), o.text)
        // Write
        o = try await run("write", ["path": "notes/n.md", "content": "hello world"])
        XCTAssertFalse(o.isError)
        // Edit (unique match, then replace_all)
        o = try await run("edit", ["path": "notes/n.md", "old_string": "world", "new_string": "teacher"])
        XCTAssertFalse(o.isError)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("notes/n.md"), encoding: .utf8), "hello teacher")
        o = try await run("edit", ["path": "src/a.txt", "old_string": "zzz", "new_string": "y"])
        XCTAssertTrue(o.isError)
        // LS
        o = try await run("ls", ["path": "src"])
        XCTAssertTrue(o.text.contains("a.txt") && o.text.contains("b.py"))
        // Glob
        o = try await run("glob", ["pattern": "**/*.py"])
        XCTAssertTrue(o.text.contains("b.py") && !o.text.contains("a.txt"))
        // Grep (content mode)
        o = try await run("grep", ["pattern": "gam+a", "output_mode": "content"])
        XCTAssertTrue(o.text.contains("gamma"), o.text)
        // Files with matches: paths relative to the folder searched, with their match counts, most first.
        o = try await run("grep", ["pattern": "a|i"])
        XCTAssertEqual(o.text.split(separator: "\n").dropFirst().map(String.init), ["src/a.txt:3", "notes/n.md:1", "src/b.py:1"], o.text)
        // Bash with persistent cwd
        o = try await run("bash", ["command": "cd src && pwd"])
        o = try await run("bash", ["command": "ls"])
        XCTAssertTrue(o.text.contains("a.txt"), "cwd should persist: \(o.text)")
        // TodoWrite
        o = try await run("todo_write", ["todos": [["content": "x", "status": "in_progress"]]])
        XCTAssertTrue(o.text.contains("[~] x"))
        // Extras: run_code in the folder, math
        o = try await run("run_code", ["language": "python", "code": "print(open('src/a.txt').read().count('a'))"])
        XCTAssertTrue(o.text.hasPrefix("5"), o.text)
        o = try await run("math", ["operation": "solve", "expression": "x**2 = 4"])
        XCTAssertTrue(o.text.contains("[-2, 2]"), o.text)
        // Memory tools
        o = try await run("memory", ["action": "save", "content": "Learner likes visual proofs", "kind": "preference", "scope": "folder"])
        XCTAssertTrue(o.text.contains("#f"))
    }

    func testWebToolsLive() async throws {
        let s = try await run("web_search", ["query": "Pythagorean theorem", "max_results": 3])
        XCTAssertFalse(s.isError, s.text)
        let f = try await run("web_fetch", ["url": "https://example.com", "max_length": 2000])
        XCTAssertTrue(f.text.contains("Example Domain"), f.text)
    }
}
