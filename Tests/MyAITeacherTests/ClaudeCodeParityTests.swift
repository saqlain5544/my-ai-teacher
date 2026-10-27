import XCTest
@testable import MyAITeacher

/// What brings the code agent to Claude Code's level: writes that never erase unseen work, read-only commands without
/// approval (run hardened), "always allow" command rules, plan mode, Claude Code's argument names, gitignore-aware
/// search, instruction files from parents, imports and subfolders, `.claude/` commands and agents, `/init`, `/review`
/// and `/compact`.
final class ClaudeCodeParityTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("ccparity-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx(codeAgent: Bool = true, conversation: String = "L-\(UUID().uuidString.prefix(4))") -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: conversation, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                            client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.codeAgent = codeAgent
        return c
    }
    func write(_ name: String, _ text: String, in base: URL? = nil) throws {
        let u = (base ?? dir).appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func text(_ name: String) -> String? { try? String(contentsOf: dir.appendingPathComponent(name), encoding: .utf8) }
    func git(_ args: String...) async { _ = await ProcessRunner.run("/usr/bin/git", ["-C", dir.path] + args, timeout: 20) }

    // MARK: Writes never erase what the agent hasn't seen

    @MainActor func testWriteNeedsAReadAndRefusesAFileThatChangedSince() async throws {
        let c = ctx()
        try write("app.py", "print('user')\n")
        var out = try await WriteTool().run(["path": "app.py", "content": "print('agent')\n"], c)
        XCTAssertTrue(out.isError && out.text.contains("haven't read it"), out.text)
        XCTAssertEqual(text("app.py"), "print('user')\n", "nothing was written")
        _ = try await ReadTool().run(["path": "app.py"], c)
        out = try await WriteTool().run(["path": "app.py", "content": "print('agent')\n"], c)
        XCTAssertFalse(out.isError, out.text)
        // The user saves the file in their editor: the agent's next overwrite would erase it.
        try await Task.sleep(for: .milliseconds(20))
        try write("app.py", "print('user again')\n# their work\n")
        out = try await WriteTool().run(["path": "app.py", "content": "print('stale')\n"], c)
        XCTAssertTrue(out.isError && out.text.contains("changed since"), out.text)
        XCTAssertTrue(text("app.py")!.contains("their work"))
        // Exact-match edits still apply, with a note that the picture is old.
        let e = try await EditTool().run(["path": "app.py", "old_string": "print('user again')", "new_string": "print('merged')"], c)
        XCTAssertFalse(e.isError, e.text)
        XCTAssertTrue(e.text.contains("had changed since you last read it"), e.text)
        // After its own edit the agent has the file current: a write goes through.
        out = try await WriteTool().run(["path": "app.py", "content": "print('whole')\n"], c)
        XCTAssertFalse(out.isError, out.text)
        // New files need no read; other agents (a sub-agent) have their own views; lessons outside code are unguarded.
        let fresh = try await WriteTool().run(["path": "new/mod.py", "content": "x = 1\n"], c)
        XCTAssertFalse(fresh.isError, fresh.text)
        var sub = c; sub.shellID = c.conversationID + "/A1"
        let unseen = try await WriteTool().run(["path": "app.py", "content": "y\n"], sub)
        XCTAssertTrue(unseen.isError, "a sub-agent hasn't read it")
        let lesson = try await WriteTool().run(["path": "app.py", "content": "z\n"], ctx(codeAgent: false))
        XCTAssertFalse(lesson.isError, lesson.text)
        _ = try await ReadTool().run(["path": "app.py"], sub)
        XCTAssertEqual(FileViews.shared.state(dir.appendingPathComponent("app.py"), agent: sub.shellID!), .current)
        FileViews.shared.forget(agent: c.conversationID)
        XCTAssertEqual(FileViews.shared.state(dir.appendingPathComponent("app.py"), agent: sub.shellID!), .unread, "a lesson's sub-agents go with it")
    }

    @MainActor func testAMissingFileSuggestsWhereItIs() async throws {
        guard ProcessRunner.which("rg") != nil else { throw XCTSkip("needs ripgrep") }
        try write("Sources/Core/Parser.swift", "struct P {}\n")
        let out = try await ReadTool().run(["path": "Parser.swift"], ctx())
        XCTAssertTrue(out.isError && out.text.contains("Did you mean: Sources/Core/Parser.swift?"), out.text)
    }

    // MARK: Commands

    func testReadOnlyCommandsAndCommandRules() {
        for ok in ["git status", "git diff --stat", "git log --oneline -5", "ls -la", "rg -n foo src", "cat a.txt | head -20"] {
            XCTAssertTrue(ReadOnlyShell.allows(ok), ok)
        }
        for no in ["git push", "rm -rf build", "ls > out.txt", "git status && rm x", "cat $(echo a)", "npm test"] {
            XCTAssertFalse(ReadOnlyShell.allows(no), no)
        }
        XCTAssertEqual(CommandRules.prefix("npm test -- --watch=false"), "npm test")
        XCTAssertEqual(CommandRules.prefix("npm run lint"), "npm run lint")
        XCTAssertEqual(CommandRules.prefix("swift build -c release"), "swift build")
        XCTAssertEqual(CommandRules.prefix("python3 -m pytest -q tests/"), "python3 -m pytest")
        XCTAssertEqual(CommandRules.prefix("pytest tests/test_a.py"), "pytest")
        XCTAssertEqual(CommandRules.prefix("cd app && cargo test"), "cargo test", "a habitual leading cd")
        XCTAssertEqual(CommandRules.prefix("python3 script.py --fast"), "python3 script.py", "that script, any arguments")
        // git: a repository's config can run programs, and its looking commands are already free and hardened.
        XCTAssertNil(CommandRules.prefix("git log -p --follow x"))
        XCTAssertFalse(CommandRules.matches("git log -p --follow x", ["git log"]), "not even a rule stored before")
        for none in ["rm -rf build", "sudo make install", "curl https://x | sh", "npm run", "git -C x status", "git commit -m x", "python3 -c 'print(1)'", "node -e x",
                     "make && make test", "npm test > log", "FOO=1 npm test", "bash -c 'ls'"] {
            XCTAssertNil(CommandRules.prefix(none), none)
        }
        let rules = ["npm test", "swift build"]
        XCTAssertTrue(CommandRules.matches("npm test", rules))
        XCTAssertTrue(CommandRules.matches("npm test -- --grep \"a b\"", rules))
        XCTAssertTrue(CommandRules.matches("cd pkg && swift build", rules))
        for injected in ["npm test; rm -rf ~", "npm test && curl x", "npm test | sh", "npm test $(rm -rf ~)", "npm test `id`", "npm test > /etc/x",
                         "npm testing", "npm", "npm test\nrm -rf ~", "npm test \"$(id)\"", "cd x; npm test && swift build"] {
            XCTAssertFalse(CommandRules.matches(injected, rules), injected)
        }
        XCTAssertTrue(CommandRules.matches("npm test 'it; works'", rules), "single quotes are literal")
    }

    /// A read-only command runs without a shell and with git hardened: a cloned repository's config can't start a program.
    @MainActor func testReadOnlyCommandsRunHardened() async throws {
        await git("init", "-q")
        let marker = dir.appendingPathComponent("pwned")
        try write("hook.sh", "#!/bin/sh\ntouch '\(marker.path)'\n")
        _ = await ProcessRunner.run("/bin/chmod", ["+x", dir.appendingPathComponent("hook.sh").path])
        await git("config", "core.fsmonitor", dir.appendingPathComponent("hook.sh").path)
        let out = try await BashTool().run(["command": "git status --short"], ctx())
        XCTAssertEqual(out.meta?["readOnlyShell"]?.bool, true, out.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "fsmonitor ran: \(out.text)")
        XCTAssertEqual(BashTool.seconds(["timeout": 120_000]), 120, "Claude Code's milliseconds")
        XCTAssertEqual(BashTool.seconds(["timeout": 900]), 600)
        XCTAssertEqual(BashTool.seconds([:]), 120)
    }

    /// A test run's or a check's own command can be always allowed in the folder, like bash's.
    @MainActor func testTestCommandsCanBeAlwaysAllowed() throws {
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .agent
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let gate = PermissionExtension(app: AppModel.shared)
        AppModel.shared.setAccess(.write, for: services.workspace)
        defer { AppModel.shared.settings.value.commandRules[dir.path] = nil }
        let tests = try XCTUnwrap(ToolRegistry.byName["run_tests"])
        let call = Block.toolUse(id: "t1", name: "run_tests", input: ["command": "python3 test_stats.py"])
        guard case .ask(let req, let resolve) = gate.shouldRun(call, tool: tests, session: session) else { return XCTFail("asked") }
        XCTAssertEqual(req.options.map(\.id), ["once", "rule", "lesson", "grant_full", "deny"])
        guard case .allow = resolve("rule") else { return XCTFail("allowed") }
        XCTAssertEqual(AppModel.shared.settings.value.commandRules[dir.path], ["python3 test_stats.py"])
        guard case .allow = gate.shouldRun(call, tool: tests, session: session) else { return XCTFail("the rule covers the test run") }
        let bash = try XCTUnwrap(ToolRegistry.byName["bash"])
        guard case .allow = gate.shouldRun(Block.toolUse(id: "b1", name: "bash", input: ["command": "python3 test_stats.py -v"]), tool: bash, session: session)
        else { return XCTFail("and the same command through bash") }
        let check = try XCTUnwrap(ToolRegistry.byName["diagnostics"])
        guard case .ask(let chained, _) = gate.shouldRun(Block.toolUse(id: "d1", name: "diagnostics", input: ["what": "command", "command": "make && ./run"]), tool: check, session: session)
        else { return XCTFail("a chained check is asked") }
        XCTAssertFalse(chained.options.map(\.id).contains("rule"), "no rule for a chained command")
    }

    // MARK: Goal

    @MainActor func testGoalIsSetShownResumedAndCleared() async throws {
        XCTAssertEqual(ProjectCommands.goalArgument("/goal  make the tests pass "), "make the tests pass")
        XCTAssertEqual(ProjectCommands.goalArgument("/goal"), "")
        XCTAssertNil(ProjectCommands.goalArgument("/goals"))
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .agent
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        XCTAssertFalse(session.goalCommand(""), "showing it sends nothing")
        XCTAssertTrue(session.goalCommand("Make every test pass"), "a new goal goes to the agent")
        XCTAssertEqual(session.conversation.goal?.text, "Make every test pass")
        XCTAssertEqual(session.conversation.goal?.state, .active)

        // Every message carries it while it's open.
        var m = ChatMessage(role: .user, blocks: [.text("hi")])
        GoalExtension().willSend(&m, session: session)
        XCTAssertTrue(m.blocks.first?.text?.contains("Make every test pass") == true && m.blocks.first?.meta?["hidden"]?.bool == true)

        // The agent reports it blocked: paused, with what it needs; met ends it.
        let ext = GoalExtension()
        let blocked = try await GoalTool().run(["status": "blocked", "evidence": "Which database?"], ctx())
        var result = Block.toolResult(id: "g1", name: "goal", content: blocked.text, isError: false); result.meta = blocked.meta
        ext.didRun(Block.toolUse(id: "g1", name: "goal", input: [:]), result: &result, session: session)
        XCTAssertEqual(session.conversation.goal?.state, .paused); XCTAssertEqual(session.conversation.goal?.note, "Which database?")
        var quiet = ChatMessage(role: .user, blocks: [.text("hi")]); ext.willSend(&quiet, session: session)
        XCTAssertEqual(quiet.blocks.count, 1, "a paused goal isn't pressed on the agent")
        guard case .deny = ext.shouldRun(Block.toolUse(id: "g2", name: "goal", input: [:]), tool: GoalTool(), session: session) else { return XCTFail("nothing to report while paused") }
        let met = try await GoalTool().run(["status": "met", "evidence": "pytest: 12 passed"], ctx())
        XCTAssertEqual(met.meta?["goalStatus"]?.string, "met")
        let bare = try await GoalTool().run(["status": "met", "evidence": " "], ctx())
        XCTAssertTrue(bare.isError, "met needs evidence")

        // After each turn: on to the next while open; a stop, a failure or the cap pauses it.
        let open = SessionGoal(text: "x")
        XCTAssertEqual(ChatSession.afterTurn(open, cancelled: false, error: nil).state, .active)
        XCTAssertEqual(ChatSession.afterTurn(open, cancelled: false, error: nil).turns, 1)
        XCTAssertEqual(ChatSession.afterTurn(open, cancelled: true, error: nil).state, .paused)
        XCTAssertEqual(ChatSession.afterTurn(open, cancelled: false, error: "HTTP 500").note, "A turn failed: HTTP 500")
        var late = open; late.turns = SessionGoal.maxTurns - 1
        XCTAssertEqual(ChatSession.afterTurn(late, cancelled: false, error: nil).state, .paused, "the cap")

        XCTAssertFalse(session.goalCommand("clear"))
        XCTAssertNil(session.conversation.goal)
        XCTAssertTrue(AgentTree.deferred("engineer").contains("goal") && !AgentTree.deferred("tutor").contains("goal"), "a code agent's tool")
    }

    // MARK: Plan mode

    func testPlanModeOnlyLooks() {
        let refuse = { (t: Tool, i: JSON) in PlanModeExtension.refusal(t, i) != nil }
        XCTAssertTrue(refuse(WriteTool(), ["path": "a", "content": "b"]))
        XCTAssertTrue(refuse(EditTool(), ["path": "a"]))
        XCTAssertTrue(refuse(BashTool(), ["command": "npm test"]))
        XCTAssertTrue(refuse(BashTool(), ["command": "git status", "background": true]))
        XCTAssertFalse(refuse(BashTool(), ["command": "git log --oneline -5"]))
        XCTAssertTrue(refuse(RunTestsTool(), [:]))
        XCTAssertTrue(refuse(RunCodeTool(), ["language": "python", "code": "1"]))
        XCTAssertFalse(refuse(TaskTool(), ["prompt": "find x"]), "explore by default")
        XCTAssertFalse(refuse(TaskTool(), ["prompt": "x", "type": "reviewer"]))
        XCTAssertTrue(refuse(TaskTool(), ["prompt": "x", "type": "coder"]))
        for t: Tool in [ReadTool(), GrepTool(), GlobTool(), ExitPlanModeTool(), TodoWriteTool(), WebSearchTool()] { XCTAssertFalse(refuse(t, [:]), t.name) }
        XCTAssertTrue(refuse(TaskTool(), ["prompt": "go on", "resume": "A1"]), "a resumed sub-agent may be a coder")
        XCTAssertTrue(refuse(AgentsTool(), ["action": "resume", "id": "A1", "message": "go on"]))
        XCTAssertFalse(refuse(AgentsTool(), ["action": "list"]))
        if let browser = ToolRegistry.byName["browser"] {
            XCTAssertFalse(refuse(browser, ["action": "snapshot"]))
            XCTAssertTrue(refuse(browser, ["action": "click", "ref": "e3"]), "clicking can change a site")
            XCTAssertTrue(refuse(browser, ["action": "fill", "ref": "e3", "text": "x"]))
        }
        XCTAssertTrue(AgentTree.core("engineer").contains("exit_plan_mode"))
    }

    @MainActor func testPlanModeIsAnnouncedAndEndsOnApproval() async throws {
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .agent
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let ext = PlanModeExtension()
        func note(_ m: ChatMessage) -> String { m.blocks.filter { $0.meta?["hidden"]?.bool == true }.compactMap(\.text).joined() }
        session.setPlanMode(true)
        var m = ChatMessage(role: .user, blocks: [.text("add caching")])
        ext.willSend(&m, session: session)
        XCTAssertTrue(note(m).contains("Plan mode is on"))
        let write = Block.toolUse(id: "w", name: "write", input: ["path": "a", "content": "b"])
        guard case .deny = ext.shouldRun(write, tool: WriteTool(), session: session) else { return XCTFail("a write in plan mode") }
        var result = Block.toolResult(id: "p", name: "exit_plan_mode", content: "approved", meta: ["planApproved": true])
        ext.didRun(.toolUse(id: "p", name: "exit_plan_mode", input: ["plan": "x"]), result: &result, session: session)
        XCTAssertNil(session.conversation.planMode, "approval ends plan mode")
        guard case .allow = ext.shouldRun(write, tool: WriteTool(), session: session) else { return XCTFail("writes run again") }
        guard case .deny = ext.shouldRun(.toolUse(id: "q", name: "exit_plan_mode", input: [:]), tool: ExitPlanModeTool(), session: session) else {
            return XCTFail("nothing to approve outside plan mode")
        }
        // Turned off by the user instead: the agent hears it once.
        session.setPlanMode(true)
        var a = ChatMessage(role: .user, blocks: [.text("go")]); ext.willSend(&a, session: session)
        session.setPlanMode(false)
        var b = ChatMessage(role: .user, blocks: [.text("go")]); ext.willSend(&b, session: session)
        var c = ChatMessage(role: .user, blocks: [.text("go")]); ext.willSend(&c, session: session)
        XCTAssertTrue(note(b).contains("Plan mode is off")); XCTAssertEqual(note(c), "")
        var lesson = Conversation(providerID: "x", model: "m"); lesson.mode = .tutor
        let tutor = ChatSession(conversation: lesson, app: AppModel.shared, services: services)
        tutor.setPlanMode(true)
        XCTAssertNil(tutor.conversation.planMode, "plan mode is the code agent's")
    }

    // MARK: Arguments, search

    func testClaudeCodeArgumentNames() {
        let w = ToolArgs.canonical(["file_path": "a.py", "content": "x"], schema: WriteTool().schema)
        XCTAssertEqual(w["path"]?.string, "a.py"); XCTAssertNil(w["file_path"])
        let both = ToolArgs.canonical(["file_path": "b", "path": "a"], schema: ReadTool().schema)
        XCTAssertEqual(both["path"]?.string, "a", "the tool's own name wins")
        XCTAssertEqual(ToolArgs.canonical(["command": "x", "run_in_background": true], schema: BashTool().schema)["background"]?.bool, true)
        XCTAssertEqual(ToolArgs.canonical(["file_path": "q"], schema: WebSearchTool().schema)["file_path"]?.string, "q", "only where the tool has the property")
    }

    @MainActor func testSearchHonoursGitignoreAndPages() async throws {
        guard ProcessRunner.which("rg") != nil else { throw XCTSkip("needs ripgrep") }
        await git("init", "-q")
        try write(".gitignore", "dist/\n")
        try write("src/a.js", "const token = 1\nfunction f() {\n  return token\n}\n")
        try write("src/b.ts", "let token = 2\n")
        try write("dist/bundle.js", "var token=1\n")
        let g = try await GlobTool().run(["pattern": "**/*.js"], ctx())
        XCTAssertTrue(g.text.contains("src/a.js") && !g.text.contains("dist/"), g.text)
        let ignored = try await GlobTool().run(["pattern": "dist/*.js"], ctx())
        XCTAssertTrue(ignored.text.contains("dist/bundle.js"), "naming an ignored path still finds it: \(ignored.text)")
        let typed = try await GrepTool().run(["pattern": "token", "type": "ts"], ctx())
        XCTAssertTrue(typed.text.contains("src/b.ts") && !typed.text.contains("a.js"), typed.text)
        let after = try await GrepTool().run(["pattern": "function f", "output_mode": "content", "-A": 1, "path": "src"], ctx())
        XCTAssertTrue(after.text.contains("return token"), after.text)
        let multi = try await GrepTool().run(["pattern": "f\\(\\) \\{.*return", "multiline": true, "output_mode": "content"], ctx())
        XCTAssertTrue(multi.text.contains("a.js"), multi.text)
        let page = try await GrepTool().run(["pattern": "token", "output_mode": "content", "head_limit": 1, "offset": 1, "path": "src/a.js"], ctx())
        XCTAssertTrue(page.text.contains("3:") && !page.text.contains("1:const"), page.text)
        let badType = try await GrepTool().run(["pattern": "x", "type": "nolang"], ctx())
        XCTAssertTrue(badType.isError, badType.text)
    }

    // MARK: Instructions, commands, agents

    @MainActor func testInstructionFilesFromParentsImportsAndSubfolders() async throws {
        let home = dir.appendingPathComponent("home"), repo = home.appendingPathComponent("code/mono"), pkg = repo.appendingPathComponent("packages/web")
        try write(".claude/CLAUDE.md", "Prefer pnpm.", in: home)
        try write("AGENTS.md", "Monorepo: run tasks with turbo.\nSee @docs/style.md and @MainActor isolation; mail a@b.io.", in: repo)
        try write("docs/style.md", "Two-space indent. @deep.md", in: repo)
        try write("docs/deep.md", "Deep rule.", in: repo)
        try write("CLAUDE.md", "Web package: Next.js.", in: pkg)
        try write("CLAUDE.local.md", "My local note.", in: pkg)
        try write("src/ui/AGENTS.md", "UI components: no default exports.", in: pkg)
        try write("src/ui/Button.tsx", "export const Button = 1\n", in: pkg)
        let block = ProjectMemory.contextBlock(pkg, home: home)
        let order = ["Prefer pnpm.", "Monorepo: run tasks with turbo.", "Two-space indent.", "Deep rule.", "Web package: Next.js.", "My local note."]
        let at = order.map { block.range(of: $0)?.lowerBound }
        XCTAssertFalse(at.contains(nil), block)
        XCTAssertEqual(at.compactMap { $0 }, at.compactMap { $0 }.sorted(), "user, then parents outermost first, imports after their file, then the project")
        XCTAssertFalse(block.contains("Imported from @MainActor") || block.contains("Imported from @b.io"), "only files that exist are imported")
        XCTAssertFalse(block.contains("no default exports"), "a subfolder's file comes with the first read there")
        XCTAssertEqual(ProjectMemory.nested(for: pkg.appendingPathComponent("src/ui/Button.tsx"), workspace: pkg).map(\.lastPathComponent), ["AGENTS.md"])
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: "N-\(UUID().uuidString.prefix(4))", workspace: pkg, services: services, interactions: InteractionCenter(),
                            toolCallID: "c", client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.codeAgent = true
        let first = try await ReadTool().run(["path": "src/ui/Button.tsx"], c)
        XCTAssertTrue(first.text.contains("Project instructions from src/ui/AGENTS.md") && first.text.contains("no default exports"), first.text)
        let again = try await ReadTool().run(["path": "src/ui/Button.tsx"], c)
        XCTAssertFalse(again.text.contains("no default exports"), "once")
    }

    /// Typing `/` lists every command with what it does; typing on narrows it; a space (arguments) closes it.
    func testTheSlashMenuListsAndNarrowsCommands() throws {
        let home = dir.appendingPathComponent("home")
        let cmds = dir.appendingPathComponent(".claude/commands")
        try FileManager.default.createDirectory(at: cmds.appendingPathComponent("frontend"), withIntermediateDirectories: true)
        try "---\ndescription: Ship a release with notes\n---\nTag and push $ARGUMENTS".write(to: cmds.appendingPathComponent("release.md"), atomically: true, encoding: .utf8)
        try "Run the UI tests for $1".write(to: cmds.appendingPathComponent("frontend/test.md"), atomically: true, encoding: .utf8)
        let all = ProjectCommands.suggestions(dir, home: home)
        XCTAssertEqual(Array(all.prefix(4).map(\.name)), ["goal", "review", "compact", "init"], "the built-ins first")
        XCTAssertEqual(all.first { $0.name == "release" }?.detail, "Ship a release with notes")
        XCTAssertEqual(all.first { $0.name == "frontend:test" }?.detail, "Run the UI tests for $1")
        XCTAssertEqual(all.first { $0.name == "release" }?.source, "this project")
        XCTAssertEqual(ProjectCommands.matches("/", in: all)?.count, all.count, "a bare / shows them all")
        XCTAssertEqual(ProjectCommands.matches("/re", in: all)?.map(\.name), ["review", "release"])
        XCTAssertEqual(ProjectCommands.matches("/test", in: all)?.map(\.name), ["frontend:test"], "a name inside counts too")
        XCTAssertNil(ProjectCommands.matches("/review src/app.py", in: all), "arguments being typed: no menu")
        XCTAssertNil(ProjectCommands.matches("hello /re", in: all))

        // A teaching lesson: the follow-ups and the other modes.
        let lesson = ProjectCommands.lessonSuggestions(current: .tutor)
        XCTAssertEqual(Array(lesson.prefix(5).map(\.name)), ["simpler", "deeper", "example", "quiz", "flashcards"])
        XCTAssertTrue(lesson.contains { $0.name == "socratic" } && !lesson.contains { $0.name == "tutor" }, "the other modes, not the current one")
        XCTAssertEqual(ProjectCommands.lessonCommand("/simpler"), .prompt("Can you explain that again more simply, with an everyday analogy?"))
        XCTAssertEqual(ProjectCommands.lessonCommand("/socratic why is the sky blue?"), .mode(.socratic, then: "why is the sky blue?"))
        XCTAssertNil(ProjectCommands.lessonCommand("/nothing"))
        XCTAssertNil(ProjectCommands.lessonCommand("the /socratic method"))
    }

    func testCommandsFromClaudeFoldersAndBuiltIns() throws {
        let home = dir.appendingPathComponent("home")
        try write(".claude/commands/fix-issue.md", "---\ndescription: Fix an issue\nargument-hint: [number] [priority]\n---\nFix issue #$1 at priority $2. All: $ARGUMENTS", in: dir)
        try write(".claude/commands/frontend/test.md", "Run the frontend tests.", in: dir)
        try write(".teacher/commands/fix-issue.md", "Teacher's own fix-issue: $1", in: dir)
        try write(".claude/commands/standup.md", "Write my standup.", in: home)
        XCTAssertEqual(ProjectCommands.expand("/fix-issue 42 high", folder: dir, home: home)?.contains("Teacher's own fix-issue: 42"), true, ".teacher wins")
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".teacher/commands/fix-issue.md"))
        let e = ProjectCommands.expand("/fix-issue 42 high", folder: dir, home: home) ?? ""
        XCTAssertTrue(e.contains("Fix issue #42 at priority high. All: 42 high") && e.contains(".claude/commands/fix-issue.md") && !e.contains("argument-hint"), e)
        XCTAssertTrue(ProjectCommands.expand("/frontend:test", folder: dir, home: home)?.contains("Run the frontend tests.") == true)
        XCTAssertTrue(ProjectCommands.expand("/standup", folder: dir, home: home)?.contains("Write my standup.") == true)
        XCTAssertEqual(ProjectCommands.names(dir, home: home), ["fix-issue", "frontend:test", "standup"])
        XCTAssertEqual(ProjectCommands.names(dir, home: nil), ["fix-issue", "frontend:test"])
        XCTAssertTrue(ProjectCommands.expand("/init", folder: dir, home: home)?.contains("AGENTS.md") == true)
        XCTAssertTrue(ProjectCommands.expand("/review the auth module", folder: dir, home: home)?.contains("the auth module") == true)
        XCTAssertNil(ProjectCommands.expand("/nope", folder: dir, home: home))
        XCTAssertNil(ProjectCommands.expand("/../../etc/passwd", folder: dir, home: home))
        XCTAssertEqual(ProjectCommands.compactFocus("/compact"), "")
        XCTAssertEqual(ProjectCommands.compactFocus("/compact keep the API decisions"), "keep the API decisions")
        XCTAssertNil(ProjectCommands.compactFocus("/compactor"))
        XCTAssertNil(ProjectCommands.compactFocus("compact it"))
    }

    func testClaudeCodeAgentDefinitions() throws {
        try write(".claude/agents/db-reader.md", "---\nname: db-reader\ndescription: Reads the schema\ntools: Read, Grep, Glob, Bash, WebFetch\nmodel: sonnet\n---\nYou read schemas.")
        try write(".teacher/agents/db-reader.md", "---\nname: db-reader\ndescription: Teacher's\n---\nMine.")
        try write(".claude/agents/fixer.md", "---\nname: fixer\ndescription: Fixes\ntools: Read, Edit, MultiEdit, Write\nmodel: inherit\n---\nFix.")
        let defs = AgentCatalog.project(dir)
        XCTAssertEqual(defs.first { $0.name == "db-reader" }?.description, "Teacher's", ".teacher wins")
        let fixer = try XCTUnwrap(defs.first { $0.name == "fixer" })
        XCTAssertEqual(fixer.tools, ["read", "edit", "write"])
        XCTAssertNil(fixer.model)
        try FileManager.default.removeItem(at: dir.appendingPathComponent(".teacher/agents/db-reader.md"))
        let reader = try XCTUnwrap(AgentCatalog.project(dir).first { $0.name == "db-reader" })
        XCTAssertEqual(reader.tools, ["read", "grep", "glob", "bash", "web_fetch"])
        XCTAssertNil(reader.model, "Claude Code's model aliases mean the lesson's model")
    }

    func testCodingSummaryPrompt() {
        let p = Compaction.codingPrompt([ChatMessage(role: .user, blocks: [.text("fix the parser")])], previous: nil, focus: "the API decisions")
        XCTAssertTrue(p.contains("Files read and changed") && p.contains("Current work") && p.contains("the API decisions"), p)
        XCTAssertFalse(p.contains("misconceptions") || p.contains("tutoring"), "an engineering summary, not a lesson's")
    }
}
