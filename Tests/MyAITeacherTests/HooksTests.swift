import XCTest
@testable import MyAITeacher

/// User-configurable hooks (`HooksExtension`): Claude Code's matchers and exit-code rules, blocking a call, context for the
/// agent, and the rule that a folder's own hooks run only once the user approved exactly that configuration.
final class HooksTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("hooks-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ name: String, _ text: String) throws {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func exists(_ name: String) -> Bool { FileManager.default.fileExists(atPath: dir.appendingPathComponent(name).path) }

    @MainActor func session(_ mode: TeachingMode = .agent) -> ChatSession {
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = mode
        return ChatSession(conversation: conv, app: AppModel.shared, services: services)
    }

    /// An extension with these user hooks, and approvals kept in `approved` (folder path → fingerprint).
    final class Approvals { var byFolder: [String: String] = [:] }
    @MainActor func hooks(_ user: String = "", _ approvals: Approvals = Approvals()) -> HooksExtension {
        HooksExtension(source: .init(userHooks: { user }, approved: { approvals.byFolder[$0] }, approve: { approvals.byFolder[$0] = $1 }))
    }
    static func config(_ event: String, matcher: String = "", _ command: String, timeout: Int? = nil) -> String {
        let t = timeout.map { ", \"timeout\": \($0)" } ?? ""
        return #"{"\#(event)": [{"matcher": \#(JSON.string(matcher).compact), "hooks": [{"type": "command", "command": \#(JSON.string(command).compact)\#(t)}]}]}"#
    }

    @MainActor func settle(_ d: ToolDecision) async -> ToolDecision {
        if case .pending(let decide) = d { return await settle(decide()) }
        return d
    }
    func reason(_ d: ToolDecision) -> String? { if case .deny(let r) = d { return r }; return nil }
    func isAllow(_ d: ToolDecision) -> Bool { if case .allow = d { return true }; return false }

    // MARK: Matching and parsing

    func testMatchersFollowClaudeCodesRulesAndThisAppsNames() {
        XCTAssertTrue(HookSet.matches("", tool: "edit"))
        XCTAssertTrue(HookSet.matches("*", tool: "bash"))
        XCTAssertTrue(HookSet.matches("Edit|Write", tool: "edit"))
        XCTAssertTrue(HookSet.matches("Edit|Write", tool: "write"))
        XCTAssertFalse(HookSet.matches("Edit|Write", tool: "bash"))
        XCTAssertTrue(HookSet.matches("MultiEdit", tool: "edit"), "Claude Code's MultiEdit is this app's edit")
        XCTAssertTrue(HookSet.matches("bash", tool: "bash"), "this app's own names work too")
        XCTAssertTrue(HookSet.matches("Bash", tool: "bash"))
        XCTAssertFalse(HookSet.matches("BASH", tool: "bash"), "names are case-sensitive, as in Claude Code")
        XCTAssertFalse(HookSet.matches("Edit", tool: "write"), "a plain name matches exactly")
        XCTAssertTrue(HookSet.matches("Web.*", tool: "web_fetch"))
        XCTAssertTrue(HookSet.matches("Web.*", tool: "web_search"))
        XCTAssertFalse(HookSet.matches("Web.*", tool: "read"))
        XCTAssertFalse(HookSet.matches("Notebook.*", tool: "edit"), "a regular expression spans the whole name")
        XCTAssertFalse(HookSet.matches("(", tool: "edit"), "a broken expression matches nothing")

        let (set, problems) = HookSet.parse(text: """
        {"PreToolUse": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "a"}]},
                        {"matcher": "*", "hooks": [{"type": "command", "command": "b"}, {"type": "command", "command": "a"}]}],
         "UserPromptSubmit": [{"matcher": "Bash", "hooks": [{"type": "command", "command": "c"}]}]}
        """)
        XCTAssertEqual(problems, [])
        XCTAssertEqual(set?.commands(.preToolUse, tool: "bash").map(\.command), ["a", "b"], "each command once, in order")
        XCTAssertEqual(set?.commands(.preToolUse, tool: "read").map(\.command), ["b", "a"], "the * group's own commands")
        XCTAssertEqual(set?.commands(.userPromptSubmit).map(\.command), ["c"], "a prompt event ignores the matcher")
        XCTAssertEqual(set?.commands(.postToolUse, tool: "bash"), [])
    }

    func testParsingTakesAWholeSettingsFileAndSaysWhatIsWrong() {
        let whole = HookSet.parse(text: #"{"permissions": {}, "hooks": {"Stop": [{"hooks": [{"type": "command", "command": "make test", "timeout": 9000}]}]}}"#)
        XCTAssertEqual(whole.set?.commands(.stop), [HookCommand(command: "make test", timeout: 600)], "a timeout is kept within 10 minutes")
        XCTAssertNil(HookSet.parse(text: "{nope").set)
        XCTAssertEqual(HookSet.parse(text: "  ").set, HookSet())
        let wrong = HookSet.parse(text: #"{"SessionStart": [], "PreToolUse": [{"hooks": [{"type": "prompt", "prompt": "x"}, {"type": "command"}]}]}"#)
        XCTAssertEqual(wrong.problems.count, 3, wrong.problems.joined(separator: " | "))
        XCTAssertTrue(wrong.set?.isEmpty == true)
    }

    // MARK: Exit codes and decisions

    func testOutcomesFollowClaudeCodesExitCodesAndJSONDecisions() {
        XCTAssertEqual(HookRunner.outcome(.preToolUse, exit: 2, stdout: "", stderr: "use rg\n").block, "use rg")
        XCTAssertEqual(HookRunner.outcome(.preToolUse, exit: 0, stdout: #"{"decision": "block", "reason": "not today"}"#, stderr: "").block, "not today")
        let deny = #"{"hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny", "permissionDecisionReason": "secrets"}}"#
        XCTAssertEqual(HookRunner.outcome(.preToolUse, exit: 0, stdout: deny, stderr: "").block, "secrets")
        let allow = HookRunner.outcome(.preToolUse, exit: 0, stdout: #"{"hookSpecificOutput": {"permissionDecision": "allow"}}"#, stderr: "")
        XCTAssertEqual(allow, HookOutcome(), "a hook never approves a call past the permission gate")
        XCTAssertEqual(HookRunner.outcome(.preToolUse, exit: 0, stdout: #"{"hookSpecificOutput": {"permissionDecision": "ask", "permissionDecisionReason": "sure?"}}"#, stderr: "").ask, "sure?")
        XCTAssertNil(HookRunner.outcome(.preToolUse, exit: 0, stdout: "checked\n", stderr: "").context, "PreToolUse output isn't context")
        XCTAssertEqual(HookRunner.outcome(.postToolUse, exit: 0, stdout: "formatted 1 file\n", stderr: "").context, "formatted 1 file")
        XCTAssertEqual(HookRunner.outcome(.userPromptSubmit, exit: 0, stdout: #"{"hookSpecificOutput": {"additionalContext": "on branch main"}}"#, stderr: "").context, "on branch main")
        let failed = HookRunner.outcome(.postToolUse, exit: 1, stdout: "", stderr: "prettier: not found")
        XCTAssertNil(failed.block); XCTAssertTrue(failed.error?.contains("prettier: not found") == true, "another exit is an error for the user, not a block")
        let long = HookRunner.outcome(.postToolUse, exit: 0, stdout: String(repeating: "x", count: 100_000), stderr: "").context ?? ""
        XCTAssertLessThan(long.count, HookRunner.contextLimit + 200, "what the agent sees is capped")
    }

    func testAHookThatOverrunsItsTimeoutIsStoppedAndReported() async {
        let t0 = Date()
        let o = await HookRunner.run(HookCommand(command: "sleep 20", timeout: 1), event: .stop, input: [:], folder: dir)
        XCTAssertTrue(o.error?.contains("timed out") == true, String(describing: o))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8)
    }

    // MARK: Blocking

    @MainActor func testAPreToolUseHookBlocksTheCallWithItsReason() async throws {
        let s = session()
        let ext = hooks(Self.config("PreToolUse", matcher: "Bash", #"cat > "$CLAUDE_PROJECT_DIR/seen.json"; echo 'Use rg, not grep -r.' >&2; exit 2"#))
        let bash = Block.toolUse(id: "b1", name: "bash", input: ["command": "grep -r foo ."])
        let decision = await settle(ext.shouldRun(bash, tool: BashTool(), session: s))
        XCTAssertEqual(reason(decision), "A PreToolUse hook blocked this call: Use rg, not grep -r.")
        // The event on stdin, in Claude Code's shape.
        let seen = try XCTUnwrap(JSON.parse(try Data(contentsOf: dir.appendingPathComponent("seen.json"))))
        XCTAssertEqual(seen["hook_event_name"]?.string, "PreToolUse")
        XCTAssertEqual(seen["tool_name"]?.string, "Bash"); XCTAssertEqual(seen["app_tool_name"]?.string, "bash")
        XCTAssertEqual(seen["tool_input"]?["command"]?.string, "grep -r foo .")
        XCTAssertEqual(seen["session_id"]?.string, s.id); XCTAssertEqual(seen["cwd"]?.string, dir.path)
        // A tool the matcher doesn't pick runs no hook at all (not even a pending gate).
        XCTAssertTrue(isAllow(ext.shouldRun(.toolUse(id: "r", name: "read", input: ["path": "a"]), tool: ReadTool(), session: s)))
        // Only the code agent runs hooks.
        XCTAssertTrue(isAllow(ext.shouldRun(bash, tool: BashTool(), session: session(.tutor))))
    }

    @MainActor func testAHooksAnswerJoinsTheGateChainAndRunsOffTheMainActor() async {
        var laterRan = false
        let allowLater: ToolDecision = .pending { try? await Task.sleep(for: .milliseconds(20)); return .allow }
        let gates: [@MainActor () -> ToolDecision] = [{ allowLater }, { laterRan = true; return .deny("second gate") }]
        let first = await settle(ExtensionHost.chain(gates[...]))
        XCTAssertEqual(reason(first), "second gate", "an allowing hook goes on to the next gate")
        XCTAssertTrue(laterRan)
        laterRan = false
        let blocked: [@MainActor () -> ToolDecision] = [{ .pending { .deny("hook") } }, { laterRan = true; return .allow }]
        let second = await settle(ExtensionHost.chain(blocked[...]))
        XCTAssertEqual(reason(second), "hook")
        XCTAssertFalse(laterRan, "a blocked call is never put to the permission gate")

        // A slow hook leaves the main actor free.
        let ext = hooks(Self.config("PreToolUse", "sleep 1"))
        let pending = ext.shouldRun(.toolUse(id: "w", name: "write", input: ["path": "a", "content": "b"]), tool: WriteTool(), session: session())
        let t0 = Date()
        let answer = Task { await settle(pending) }
        for _ in 0..<5 { try? await Task.sleep(for: .milliseconds(40)) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.8, "the main actor kept running while the hook slept")
        let settled = await answer.value
        XCTAssertTrue(isAllow(settled))
        XCTAssertGreaterThan(Date().timeIntervalSince(t0), 0.9, "the hook did run")
    }

    // MARK: Context

    @MainActor func testAPostToolUseHookFormatsTheFileAndTheAgentHearsOfIt() async throws {
        try write("app.js", "const x = 1\n")
        let s = session()
        let ext = hooks(Self.config("PostToolUse", matcher: "Edit|Write", #"f=$(/usr/bin/jq -r .tool_input.file_path); tr a-z A-Z < "$f" > "$f.t" && mv "$f.t" "$f"; echo "formatted $(basename "$f")""#))
        let call = Block.toolUse(id: "e1", name: "edit", input: ["path": "app.js", "old_string": "1", "new_string": "2"])
        var result = Block.toolResult(id: "e1", name: "edit", content: "Edited app.js")
        await ext.afterRun(call, result: &result, session: s)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("app.js"), encoding: .utf8), "CONST X = 1\n")
        let text = result.text ?? ""
        XCTAssertTrue(text.hasPrefix("Edited app.js"), text)
        XCTAssertTrue(text.contains("formatted app.js"), "the hook's output reaches the agent: \(text)")
        XCTAssertTrue(text.contains("changed app.js after your change"), text)
        // A failed call runs no PostToolUse hook.
        var failed = Block.toolResult(id: "e2", name: "edit", content: "old_string not found", isError: true)
        await ext.afterRun(call, result: &failed, session: s)
        XCTAssertEqual(failed.text, "old_string not found")
    }

    @MainActor func testAUserPromptSubmitHookAddsContextOrHoldsTheMessageBack() async {
        let s = session()
        var m = ChatMessage(role: .user, blocks: [.text("fix the build")])
        let context = hooks(Self.config("UserPromptSubmit", #"jq -r .prompt | sed 's/^/asked: /'; echo 'on branch main'"#))
        let held = await context.willStartTurn(&m, session: s)
        XCTAssertNil(held)
        let added = m.blocks.last
        XCTAssertEqual(added?.meta?["hidden"]?.bool, true)
        XCTAssertTrue(added?.text?.contains("asked: fix the build\non branch main") == true, added?.text ?? "")

        var n = ChatMessage(role: .user, blocks: [.text("deploy")])
        let block = hooks(Self.config("UserPromptSubmit", "echo 'No deploys on Fridays.' >&2; exit 2"))
        let why = await block.willStartTurn(&n, session: s)
        XCTAssertEqual(why, "A UserPromptSubmit hook held your message back: No deploys on Fridays.")
        XCTAssertEqual(n.blocks.count, 1, "a held message gains nothing")
    }

    @MainActor func testAStopHookSendsTheAgentBackWithItsReason() async throws {
        let s = session()
        let ext = hooks(Self.config("Stop", #"cat > "$CLAUDE_PROJECT_DIR/stop.json"; echo '2 tests fail' >&2; exit 2"#))
        let why = await ext.willEndTurn(s, continued: 0)
        XCTAssertTrue(why?.contains("2 tests fail") == true, why ?? "nil")
        XCTAssertEqual(JSON.parse(try Data(contentsOf: dir.appendingPathComponent("stop.json")))?["stop_hook_active"]?.bool, false)
        _ = await ext.willEndTurn(s, continued: 1)
        XCTAssertEqual(JSON.parse(try Data(contentsOf: dir.appendingPathComponent("stop.json")))?["stop_hook_active"]?.bool, true,
                       "a hook can tell it already sent the agent back")
        let quiet = await hooks(Self.config("Stop", "echo all good")).willEndTurn(s, continued: 0)
        XCTAssertNil(quiet, "exit 0 lets the turn end")
    }

    // MARK: A folder's own hooks

    func testTheApprovalRuleBindsAFolderToOneConfiguration() {
        XCTAssertEqual(HooksExtension.trust("abc", approved: nil, declinedHere: false), .unasked)
        XCTAssertEqual(HooksExtension.trust("abc", approved: "abc", declinedHere: false), .approved)
        XCTAssertEqual(HooksExtension.trust("abc", approved: "old", declinedHere: false), .unasked, "a changed configuration asks again")
        XCTAssertEqual(HooksExtension.trust("abc", approved: "old", declinedHere: true), .declined)
        XCTAssertEqual(HooksExtension.trust("abc", approved: "abc", declinedHere: true), .approved)
        let a = HookSet.parse(text: Self.config("Stop", "make test")).set!, b = HookSet.parse(text: Self.config("Stop", "make test && rm -rf ~")).set!
        XCTAssertNotEqual(a.fingerprint, b.fingerprint)
        XCTAssertEqual(a.fingerprint, HookSet.parse(text: Self.config("Stop", "make test")).set!.fingerprint)
    }

    @MainActor func testAClonedFoldersHooksNeverRunUntilTheUserApprovesThem() async throws {
        try write(".claude/settings.json", #"{"hooks": "# + Self.config("PreToolUse", "touch ran-pre") + "}")
        try write(".claude/settings.local.json", #"{"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "touch ran-prompt"}]}], "Stop": [{"hooks": [{"type": "command", "command": "touch ran-stop"}]}]}}"#)
        let approvals = Approvals()
        let ext = hooks("", approvals)
        let s = session()
        let read = Block.toolUse(id: "r1", name: "read", input: ["path": "a.txt"])
        // Before any answer, nothing runs at any event.
        var m = ChatMessage(role: .user, blocks: [.text("hi")])
        _ = await ext.willStartTurn(&m, session: s)
        _ = await ext.willEndTurn(s, continued: 0)
        guard case .ask(let card, let resolve) = ext.shouldRun(read, tool: ReadTool(), session: s) else { return XCTFail("the first call asks about the folder's hooks") }
        XCTAssertTrue(card.detail.contains("PreToolUse [*]: touch ran-pre") && card.detail.contains("Stop: touch ran-stop"), "the card shows every command: \(card.detail)")
        XCTAssertTrue(isAllow(ext.shouldRun(read, tool: ReadTool(), session: s)), "a second call while the card is open doesn't ask again")
        // Turned down: the call goes on, the hooks don't run, and this lesson isn't asked again.
        let declined = await settle(resolve("deny"))
        XCTAssertTrue(isAllow(declined))
        XCTAssertTrue(isAllow(ext.shouldRun(read, tool: ReadTool(), session: s)))
        XCTAssertFalse(exists("ran-pre") || exists("ran-prompt") || exists("ran-stop"))
        XCTAssertTrue(approvals.byFolder.isEmpty)

        // Another lesson asks again; approved, the folder's hooks run, for every event.
        let s2 = session()
        guard case .ask(_, let approve) = ext.shouldRun(read, tool: ReadTool(), session: s2) else { return XCTFail("a new lesson asks") }
        let approved = await settle(approve("allow"))
        XCTAssertTrue(isAllow(approved))
        XCTAssertTrue(exists("ran-pre"))
        XCTAssertEqual(approvals.byFolder[dir.path], HookSet.project(dir).fingerprint)
        var m2 = ChatMessage(role: .user, blocks: [.text("hi")])
        _ = await ext.willStartTurn(&m2, session: s2)
        XCTAssertTrue(exists("ran-prompt"))
        XCTAssertFalse(exists("ran-stop")); _ = await ext.willEndTurn(s2, continued: 0); XCTAssertTrue(exists("ran-stop"))
        guard case .pending = ext.shouldRun(read, tool: ReadTool(), session: session()) else { return XCTFail("approved once, every lesson here runs them") }

        // The configuration changes (a pull, or the agent editing it): asked again before the new command runs.
        try write(".claude/settings.json", #"{"hooks": "# + Self.config("PreToolUse", "touch ran-changed") + "}")
        guard case .ask(let again, _) = ext.shouldRun(read, tool: ReadTool(), session: s2) else { return XCTFail("a changed configuration asks again") }
        XCTAssertTrue(again.detail.contains("touch ran-changed"))
        XCTAssertFalse(exists("ran-changed"))
    }
}
