import Foundation
import CryptoKit

/// Hooks, as in Claude Code: shell commands the user sets to run at points of the code agent's work. PreToolUse runs
/// before a tool call and can block it; PostToolUse runs after one (a formatter after an edit); UserPromptSubmit runs when
/// the user's message starts a turn; Stop runs when the agent would end its turn, and can send it back to work.
enum HookEvent: String, CaseIterable, Sendable {
    case preToolUse = "PreToolUse", postToolUse = "PostToolUse", userPromptSubmit = "UserPromptSubmit", stop = "Stop"
    /// Events whose hooks pick tools with a matcher (the others ignore it).
    var matchesTools: Bool { self == .preToolUse || self == .postToolUse }
}

struct HookCommand: Equatable, Sendable {
    var command: String
    var timeout: TimeInterval = HookCommand.defaultTimeout
    static let defaultTimeout: TimeInterval = 60
}

/// Hooks in Claude Code's format, the `hooks` object of `.claude/settings.json`:
///
///     {"PostToolUse": [{"matcher": "Edit|Write", "hooks": [{"type": "command", "command": "npx prettier --write \"$FILE\"", "timeout": 30}]}]}
struct HookSet: Equatable, Sendable {
    struct Group: Equatable, Sendable { var matcher: String; var commands: [HookCommand] }
    var events: [HookEvent: [Group]] = [:]

    var isEmpty: Bool { events.values.allSatisfy { $0.allSatisfy { $0.commands.isEmpty } } }

    /// Parses a `hooks` object; also returns what was wrong in it (an unknown event, a hook without a command).
    static func parse(_ hooks: JSON?) -> (set: HookSet, problems: [String]) {
        var set = HookSet(), problems: [String] = []
        guard let hooks, !hooks.isNull else { return (set, []) }
        guard let events = hooks.object else { return (set, ["`hooks` must be an object: event name → list of matchers."]) }
        for (name, entries) in events.sorted(by: { $0.key < $1.key }) {
            guard let event = HookEvent(rawValue: name) else {
                problems.append("\(name) isn't an event here (PreToolUse, PostToolUse, UserPromptSubmit, Stop)."); continue
            }
            guard let list = entries.array else { problems.append("\(name): expected a list of {\"matcher\", \"hooks\"} entries."); continue }
            for entry in list {
                var commands: [HookCommand] = []
                for h in entry["hooks"]?.array ?? [] {
                    guard (h["type"]?.string ?? "command") == "command" else { problems.append("\(name): only \"command\" hooks run here."); continue }
                    guard let c = h["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else {
                        problems.append("\(name): a hook without a command."); continue
                    }
                    commands.append(HookCommand(command: c, timeout: min(600, max(1, h["timeout"]?.double ?? HookCommand.defaultTimeout))))
                }
                if !commands.isEmpty { set.events[event, default: []].append(Group(matcher: entry["matcher"]?.string ?? "", commands: commands)) }
            }
        }
        return (set, problems)
    }

    /// The text of the app's hooks setting: a `hooks` object, or a whole settings file with one. Nil set: not JSON.
    static func parse(text: String) -> (set: HookSet?, problems: [String]) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty { return (HookSet(), []) }
        guard let j = JSON.parse(t), j.object != nil else { return (nil, ["Not valid JSON."]) }
        let r = parse(j["hooks"]?.object != nil ? j["hooks"] : j)
        return (r.set, r.problems)
    }

    /// A folder's own hooks: `.claude/settings.json`, then `.claude/settings.local.json`.
    static func project(_ folder: URL) -> HookSet {
        var set = HookSet()
        for name in ["settings.json", "settings.local.json"] {
            guard let d = try? Data(contentsOf: folder.appendingPathComponent(".claude/\(name)")), let j = JSON.parse(d) else { continue }
            set = set.merged(parse(j["hooks"]).set)
        }
        return set
    }

    func merged(_ other: HookSet) -> HookSet {
        var m = self
        for (e, groups) in other.events { m.events[e, default: []] += groups }
        return m
    }

    /// The commands `event` runs (for a tool event, the ones whose matcher picks `tool`), each once.
    func commands(_ event: HookEvent, tool: String = "") -> [HookCommand] {
        var seen = Set<String>(), out: [HookCommand] = []
        for g in events[event] ?? [] where !event.matchesTools || Self.matches(g.matcher, tool: tool) {
            for c in g.commands where seen.insert(c.command).inserted { out.append(c) }
        }
        return out
    }

    /// Claude Code's names for this app's tools, so a matcher written for it (`Edit|Write`, `Bash`) picks the same tools.
    static let claudeNames: [String: [String]] = [
        "bash": ["Bash"], "read": ["Read"], "write": ["Write"], "edit": ["Edit", "MultiEdit"], "glob": ["Glob"], "grep": ["Grep"], "ls": ["LS"],
        "web_fetch": ["WebFetch"], "web_search": ["WebSearch"], "todo_write": ["TodoWrite"], "task": ["Task", "Agent"],
        "bash_jobs": ["BashOutput", "KillShell"], "exit_plan_mode": ["ExitPlanMode"],
    ]

    /// Claude Code's matcher rules: empty or `*` picks every tool; tool names joined by `|` pick those exactly (case
    /// matters); anything else is a regular expression over the whole name. This app's own names work as well.
    static func matches(_ matcher: String, tool: String) -> Bool {
        let m = matcher.trimmingCharacters(in: .whitespaces)
        if m.isEmpty || m == "*" { return true }
        let names = [tool] + (claudeNames[tool] ?? [])
        if m.allSatisfy({ $0.isLetter || $0.isNumber || "_|- ".contains($0) }) {
            let alternatives = Set(m.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) })
            return names.contains { alternatives.contains($0) }
        }
        guard let re = try? NSRegularExpression(pattern: "^(?:" + m + ")$") else { return false }
        return names.contains { re.firstMatch(in: $0, range: NSRange($0.startIndex..., in: $0)) != nil }
    }

    /// One line per command, for the approval card and Settings.
    var lines: [String] {
        HookEvent.allCases.flatMap { e in
            (events[e] ?? []).flatMap { g in
                g.commands.map { c in
                    e.rawValue + (e.matchesTools ? " [\(g.matcher.isEmpty ? "*" : g.matcher)]" : "") + ": " + c.command
                        + (c.timeout == HookCommand.defaultTimeout ? "" : "  (timeout \(Int(c.timeout)) s)")
                }
            }
        }
    }

    /// What approving a folder's hooks is bound to: any change to them (a pull, the agent editing the file) asks again.
    var fingerprint: String {
        let canonical = HookEvent.allCases.flatMap { e in
            (events[e] ?? []).flatMap { g in g.commands.map { "\(e.rawValue)\t\(g.matcher)\t\($0.timeout)\t\($0.command)" } }
        }.joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// What one hook command said.
struct HookOutcome: Equatable, Sendable {
    /// PreToolUse: the call is refused; PostToolUse: feedback for the agent; UserPromptSubmit: the message is held back;
    /// Stop: the agent goes back to work. The text is the reason.
    var block: String?
    /// PreToolUse: the user is asked before the call runs.
    var ask: String?
    /// Added to what the agent sees (PostToolUse, UserPromptSubmit).
    var context: String?
    /// The hook failed (another exit code, a timeout): the user is told, and the work goes on.
    var error: String?
}

/// Runs hook commands: `/bin/sh -c` in the folder, the event as JSON on stdin, off the main actor, each with its timeout.
enum HookRunner {
    /// Bytes of a hook's stdout kept (a quarter of it for stderr), and characters of it the agent is shown.
    static let outputLimit = 64_000
    static let contextLimit = 8_000

    /// Runs `hooks` at once, as Claude Code does, and returns what each said, in their order.
    static func fire(_ hooks: [HookCommand], event: HookEvent, input: JSON, folder: URL) async -> [(hook: HookCommand, outcome: HookOutcome)] {
        await withTaskGroup(of: (Int, HookOutcome).self) { group in
            for (i, h) in hooks.enumerated() { group.addTask { (i, await run(h, event: event, input: input, folder: folder)) } }
            var said: [(Int, HookOutcome)] = []
            for await r in group { said.append(r) }
            return said.sorted { $0.0 < $1.0 }.map { (hooks[$0.0], $0.1) }
        }
    }

    static func run(_ hook: HookCommand, event: HookEvent, input: JSON, folder: URL) async -> HookOutcome {
        var env = ShellEnvironment.shared.all
        env["CLAUDE_PROJECT_DIR"] = folder.path   // what Claude Code's hooks use to find the project's scripts
        let r = await ProcessRunner.run("/bin/sh", ["-c", hook.command], cwd: folder, env: env, stdin: input.compact + "\n",
                                        timeout: hook.timeout, outputLimit: outputLimit)
        if r.timedOut { return HookOutcome(error: "timed out after \(Int(hook.timeout)) s") }
        return outcome(event, exit: r.exitCode, stdout: r.stdout, stderr: r.stderr)
    }

    /// Claude Code's rules. Exit 0: success, and stdout is either JSON with a decision (`{"decision": "block", "reason": …}`,
    /// or `hookSpecificOutput` with `permissionDecision` and `additionalContext`) or, for PostToolUse and
    /// UserPromptSubmit, context for the agent. Exit 2: blocks, with stderr as the reason. Any other exit: an error the
    /// user sees, and the work goes on. A hook never approves a call: "allow" leaves it to the permission gate.
    static func outcome(_ event: HookEvent, exit: Int32, stdout: String, stderr: String) -> HookOutcome {
        let out = stdout.trimmingCharacters(in: .whitespacesAndNewlines), err = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
        let clip = { (s: String) in truncateMiddle(s, max: contextLimit) }
        switch exit {
        case 0:
            guard out.hasPrefix("{"), let j = JSON.parse(out), j.object != nil else {
                return HookOutcome(context: [.postToolUse, .userPromptSubmit].contains(event) && !out.isEmpty ? clip(out) : nil)
            }
            let specific = j["hookSpecificOutput"]
            let reason = (specific?["permissionDecisionReason"]?.string ?? j["reason"]?.string).map(clip)
            var o = HookOutcome()
            switch specific?["permissionDecision"]?.string ?? j["decision"]?.string {
            case "block", "deny": o.block = reason ?? "no reason given"
            case "ask" where event == .preToolUse: o.ask = reason ?? "A hook asks you to confirm this call."
            default: break
            }
            if let c = specific?["additionalContext"]?.string, !c.isEmpty { o.context = clip(c) }
            return o
        case 2:
            return HookOutcome(block: clip(err.isEmpty ? (out.isEmpty ? "no reason given (exit 2)" : out) : err))
        default:
            return HookOutcome(error: "exit \(exit)" + (err.isEmpty ? "" : ": " + String(err.prefix(300))))
        }
    }

    /// Long strings cut (a written file's content, a long tool result), so the event stays small on stdin.
    static func clamp(_ j: JSON, max: Int = 12_000) -> JSON {
        switch j {
        case .string(let s): return s.count > max ? .string(String(s.prefix(max)) + "… [\(s.count - max) more characters]") : j
        case .array(let a): return .array(a.map { clamp($0, max: max) })
        case .object(let o): return .object(o.mapValues { clamp($0, max: max) })
        default: return j
        }
    }
}

/// Runs the user's hooks in the code agent: theirs from Settings, and the folder's own (`.claude/settings.json`) once they
/// approve them. A folder's hooks are asked about at the agent's first tool call in a lesson there (a card shows every
/// command), bound to their exact configuration: a cloned repo never runs a command by itself, and a changed one asks
/// again. Registered after plan mode (a call it refuses runs no hook) and before permissions (a call a hook blocks is
/// never put to the user).
@MainActor
final class HooksExtension: AgentExtension {
    let id = "hooks"

    /// Where hooks come from and where approvals are kept: the app's settings, or a test's.
    struct Source {
        var userHooks: @MainActor () -> String
        var approved: @MainActor (_ folder: String) -> String?
        var approve: @MainActor (_ folder: String, _ fingerprint: String) -> Void
    }
    private let source: Source
    init(source: Source) { self.source = source }
    convenience init(app: AppModel) {
        self.init(source: Source(userHooks: { [unowned app] in app.settings.value.hooks },
                                 approved: { [unowned app] in app.settings.value.approvedHooks[$0] },
                                 approve: { [unowned app] in app.settings.value.approvedHooks[$0] = $1 }))
    }

    /// A folder's hooks turned down in a lesson, and those being asked about (lesson id + fingerprint).
    private var declined: Set<String> = []
    private var asking: Set<String> = []
    private var parsed: (text: String, set: HookSet)?

    static func covers(_ session: ChatSession) -> Bool { session.conversation.mode.isAgent }

    enum Trust: Equatable { case approved, declined, unasked }
    /// The approval rule: a folder's hooks run only when exactly this configuration was approved for this folder.
    nonisolated static func trust(_ fingerprint: String, approved: String?, declinedHere: Bool) -> Trust {
        if approved == fingerprint { return .approved }
        return declinedHere ? .declined : .unasked
    }

    private func userHooks() -> HookSet {
        let text = source.userHooks()
        if let p = parsed, p.text == text { return p.set }
        let set = HookSet.parse(text: text).set ?? HookSet()
        parsed = (text, set)
        return set
    }

    private func project(_ session: ChatSession) -> (hooks: HookSet, trust: Trust)? {
        let folder = session.services.workspace.url
        let hooks = HookSet.project(folder)
        guard !hooks.isEmpty else { return nil }
        let key = session.id + hooks.fingerprint
        return (hooks, Self.trust(hooks.fingerprint, approved: source.approved(folder.path), declinedHere: declined.contains(key) || asking.contains(key)))
    }

    /// The hooks that run in this lesson now: the user's, and the folder's once approved.
    func active(_ session: ChatSession) -> HookSet {
        guard Self.covers(session) else { return HookSet() }
        var set = userHooks()
        if let p = project(session), p.trust == .approved { set = set.merged(p.hooks) }
        return set
    }

    // MARK: PreToolUse

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard Self.covers(session) else { return .allow }
        guard let p = project(session), p.trust == .unasked else { return preToolUse(call, tool: tool.name, session: session) }
        let folder = session.services.workspace.url, key = session.id + p.hooks.fingerprint
        asking.insert(key)
        let request = ApprovalRequest(
            title: "Run the hooks in this folder's .claude settings?",
            detail: "“\(folder.lastPathComponent)” has hooks: shell commands that run with your permissions at each matching step of the agent.\n\n"
                + p.hooks.lines.joined(separator: "\n")
                + "\n\nAllowed, they run in every lesson in this folder until their configuration changes. Either way, this call goes on.",
            options: [ApprovalOption(id: "allow", label: "Run this folder's hooks", style: .primary),
                      ApprovalOption(id: "deny", label: "Don't run them", style: .danger)])
        return .ask(request) { [weak self] choice in
            guard let self else { return .allow }
            self.asking.remove(key)
            if choice == "allow" { self.source.approve(folder.path, p.hooks.fingerprint) } else { self.declined.insert(key) }
            return self.preToolUse(call, tool: tool.name, session: session)
        }
    }

    private func preToolUse(_ call: Block, tool: String, session: ChatSession) -> ToolDecision {
        let hooks = active(session).commands(.preToolUse, tool: tool)
        guard !hooks.isEmpty else { return .allow }
        let folder = session.services.workspace.url
        let input = payload(.preToolUse, session: session, Self.toolFields(call, tool: tool, folder: folder))
        return .pending { [weak self] in
            let said = await HookRunner.fire(hooks, event: .preToolUse, input: input, folder: folder)
            self?.reportErrors(said, event: .preToolUse, session: session)
            let blocks = said.compactMap(\.outcome.block)
            if !blocks.isEmpty { return .deny("A PreToolUse hook blocked this call: " + blocks.joined(separator: "\n")) }
            let asks = said.compactMap(\.outcome.ask)
            guard !asks.isEmpty else { return .allow }
            return .ask(ApprovalRequest(title: "A hook asks you to confirm this \(tool) call", detail: asks.joined(separator: "\n"),
                                        options: [ApprovalOption(id: "once", label: "Allow", style: .primary), ApprovalOption(id: "deny", label: "Deny", style: .danger)])) {
                $0 == "once" ? .allow : .deny("The user declined it when a hook asked them to confirm.")
            }
        }
    }

    // MARK: PostToolUse

    func afterRun(_ call: Block, result: inout Block, session: ChatSession) async {
        guard Self.covers(session), result.isError != true, let tool = call.name else { return }
        let hooks = active(session).commands(.postToolUse, tool: tool)
        guard !hooks.isEmpty else { return }
        let folder = session.services.workspace.url
        var fields = Self.toolFields(call, tool: tool, folder: folder)
        fields["tool_response"] = HookRunner.clamp(["output": .string(result.text ?? ""), "is_error": false])
        // A file the call wrote: a hook that rewrites it (a formatter) leaves the agent's copy stale, so it is told.
        let file = ["write", "edit"].contains(tool) ? call.input?["path"]?.string.map { resolvePath($0, workspace: folder) } : nil
        let before = file.flatMap(Self.contents)
        let said = await HookRunner.fire(hooks, event: .postToolUse, input: payload(.postToolUse, session: session, fields), folder: folder)
        reportErrors(said, event: .postToolUse, session: session)
        var notes = said.compactMap { h, o -> String? in
            let text = [o.block, o.context].compactMap { $0 }.joined(separator: "\n")
            return text.isEmpty ? nil : "[PostToolUse hook `\(Self.short(h.command))`]\n" + text
        }
        if let file, let before, let after = Self.contents(file), after != before {
            notes.append("A PostToolUse hook changed \(file.lastPathComponent) after your change (a formatter, say): `read` it before editing it again.")
        }
        guard !notes.isEmpty else { return }
        result.text = (result.text ?? "") + "\n\n" + notes.joined(separator: "\n\n")
    }

    private static func contents(_ url: URL) -> Data? {
        guard let s = FileViews.stamp(url), s.size < 4_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }

    // MARK: UserPromptSubmit

    func willStartTurn(_ message: inout ChatMessage, session: ChatSession) async -> String? {
        let hooks = active(session).commands(.userPromptSubmit)
        guard !hooks.isEmpty else { return nil }
        let prompt = message.blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n\n")
        let folder = session.services.workspace.url
        let said = await HookRunner.fire(hooks, event: .userPromptSubmit, input: payload(.userPromptSubmit, session: session, ["prompt": .string(prompt)]), folder: folder)
        reportErrors(said, event: .userPromptSubmit, session: session)
        let blocks = said.compactMap(\.outcome.block)
        if !blocks.isEmpty { return "A UserPromptSubmit hook held your message back: " + blocks.joined(separator: " ") }
        let context = said.compactMap(\.outcome.context)
        if !context.isEmpty {
            message.blocks.append(Block(kind: .text, text: "<context>\nFrom the user's UserPromptSubmit hook:\n" + context.joined(separator: "\n\n") + "\n</context>",
                                        meta: ["hidden": true]))
        }
        return nil
    }

    // MARK: Stop

    func willEndTurn(_ session: ChatSession, continued: Int) async -> String? {
        let hooks = active(session).commands(.stop)
        guard !hooks.isEmpty else { return nil }
        let folder = session.services.workspace.url
        let said = await HookRunner.fire(hooks, event: .stop, input: payload(.stop, session: session, ["stop_hook_active": .bool(continued > 0)]), folder: folder)
        reportErrors(said, event: .stop, session: session)
        let blocks = said.compactMap(\.outcome.block)
        return blocks.isEmpty ? nil : "A Stop hook sent you back to work before ending your turn:\n" + blocks.joined(separator: "\n") + "\nDeal with it, then finish."
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        asking = asking.filter { !$0.hasPrefix(session.id) }   // a card the user never answered (Stop) is asked again next turn
    }

    func sessionWillClose(_ session: ChatSession) {
        declined = declined.filter { !$0.hasPrefix(session.id) }
        asking = asking.filter { !$0.hasPrefix(session.id) }
    }

    // MARK: The event

    /// What a hook reads on stdin, in Claude Code's shape.
    private func payload(_ event: HookEvent, session: ChatSession, _ fields: [String: JSON]) -> JSON {
        var o: [String: JSON] = ["hook_event_name": .string(event.rawValue), "session_id": .string(session.id),
                                 "cwd": .string(session.services.workspace.url.path),
                                 "permission_mode": .string(PlanModeExtension.isOn(session) ? "plan" : "default")]
        for (k, v) in fields { o[k] = v }
        return .object(o)
    }

    /// `tool_name` is Claude Code's name where it has one (`Edit`, `Bash`), so its hooks work unchanged; `app_tool_name` is
    /// this app's. A file tool's path is also `file_path`, absolute, as Claude Code's hooks read it.
    static func toolFields(_ call: Block, tool: String, folder: URL) -> [String: JSON] {
        var input = call.input?.object ?? [:]
        if ["read", "write", "edit"].contains(tool), let p = input["path"]?.string, input["file_path"] == nil {
            input["file_path"] = .string(resolvePath(p, workspace: folder).path)
        }
        return ["tool_name": .string(HookSet.claudeNames[tool]?.first ?? tool), "app_tool_name": .string(tool),
                "tool_input": HookRunner.clamp(.object(input)), "tool_use_id": .string(call.id ?? "")]
    }

    private func reportErrors(_ said: [(hook: HookCommand, outcome: HookOutcome)], event: HookEvent, session: ChatSession) {
        for (h, o) in said {
            guard let e = o.error else { continue }
            AppLog.write("hook \(event.rawValue) `\(h.command)`: \(e)")
            session.sink?.notice("\(event.rawValue) hook `\(Self.short(h.command))` failed (\(e)); the agent carries on.")
        }
    }

    private static func short(_ command: String) -> String {
        let one = command.replacingOccurrences(of: "\n", with: " ")
        return one.count > 60 ? String(one.prefix(57)) + "…" : one
    }
}
