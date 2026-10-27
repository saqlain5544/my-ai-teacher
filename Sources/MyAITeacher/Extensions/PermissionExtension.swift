import Foundation

/// Enforces the folder access model:
/// - reading is always allowed, anywhere on the Mac;
/// - writing inside the loaded folder needs `write` (or a one-off approval); outside it is always asked;
/// - running commands/code needs `full` (or approval, optionally remembered for the lesson);
/// - the folder's `.teacher/` state directory is app-managed and never written by tools.
@MainActor
final class PermissionExtension: AgentExtension {
    let id = "permissions"
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        let ws = session.services.workspace
        let access = app.access(for: ws)
        let input = call.input ?? .object([:])
        let conv = session.id
        if let installing = Self.packageInstall(tool: tool, input: input) {
            // An engineer installs a project's dependencies as part of the work, with the user's say-so; a lesson doesn't.
            guard session.conversation.mode.isAgent else {
                return .deny("Installing packages isn't allowed (\(installing)). Use the standard library or what's already installed.")
            }
            return .ask(ApprovalRequest(
                title: "Allow the agent to install packages?",
                detail: String((input["command"]?.string ?? input["code"]?.string ?? installing).prefix(4000)),
                options: [ApprovalOption(id: "once", label: "Allow this install", style: .primary),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { choice in
                choice == "once" ? .allow : .deny("The user declined the install. Work with what is installed, or ask them to install it.")
            }
        }
        // Python follows the learner's Python setting, independent of folder access.
        if Self.isPython(tool, input) {
            switch app.settings.value.python {
            case .allow: return .allow
            case .off: return .deny("The learner has turned Python off. Explain or calculate without running code.")
            case .ask:
                if app.interactions.isGranted("python", conversationID: conv) { return .allow }
                let detail = tool.name == "math" ? "\(input["operation"]?.string ?? "evaluate"): \(input["expression"]?.string ?? "")" : (input["code"]?.string ?? "")
                return .ask(ApprovalRequest(
                    title: tool.name == "math" ? "Allow Teacher to calculate with Python (SymPy)?" : "Allow Teacher to run this Python code?",
                    detail: String(detail.prefix(4000)),
                    options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                              ApprovalOption(id: "lesson", label: "Allow Python for this lesson"),
                              ApprovalOption(id: "always", label: "Always allow Python"),
                              ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                    switch choice {
                    case "once": return .allow
                    case "lesson": self?.app.interactions.grant("python", conversationID: conv); return .allow
                    case "always": self?.app.settings.value.python = .allow; return .allow
                    default: return .deny("The learner declined running Python.")
                    }
                }
            }
        }
        // The learner's own servers and devices are fetched only with their approval, as the browser's local sites are.
        if tool.name == "web_fetch", let host = WebFetchTool.localHost(input) {
            if app.interactions.isGranted(Self.localFetch, conversationID: conv) { return .allow }
            return .ask(ApprovalRequest(
                title: "Allow Teacher to fetch from \(host)?",
                detail: "\(input["url"]?.string ?? host) is on this Mac or your local network.",
                options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                          ApprovalOption(id: "lesson", label: "Allow local fetches for this lesson"),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                switch choice {
                case "once": return .allow
                case "lesson": self?.app.interactions.grant(Self.localFetch, conversationID: conv); return .allow
                default: return .deny("The learner declined fetching from their own Mac or network.")
                }
            }
        }
        switch tool.risk {
        case .readOnly, .network, .interactive, .control:   // .control: sites and apps are gated by ComputerUseExtension
            return .allow
        case .write:
            guard let p = input["path"]?.string else { return .allow }
            let url = resolvePath(p, workspace: ws.url)
            let verb = tool.name == "edit" ? "edit" : "write"
            if ws.isStatePath(url), !ws.isTestsPath(url), !ws.isMentorPath(url) {
                return .deny("`.teacher/` is the app's private state folder. Tests go in `.teacher/tests`, a code mentor's notes in `.teacher/mentor`; write everything else in the folder.")
            }
            if ws.contains(url) {
                if access >= .write || app.interactions.isGranted("write", conversationID: conv) { return .allow }
                let rel = String(url.path.dropFirst(ws.url.path.count + 1))
                return .ask(ApprovalRequest(
                    title: "Allow Teacher to \(verb) \(rel)?",
                    detail: "“\(ws.name)” is read-only for Teacher.",
                    options: [ApprovalOption(id: "grant_write", label: "Allow writing in this folder", style: .primary),
                              ApprovalOption(id: "once", label: "Allow once"),
                              ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                    switch choice {
                    case "grant_write": self?.app.setAccess(.write, for: ws); return .allow
                    case "once": return .allow
                    default: return .deny("The learner declined.")
                    }
                }
            }
            // Scratch files in the system's temporary folder (a code mentor checks its tests against a reference solution
            // there, never in the learner's folder): no one's data, so no question each time.
            if Self.isScratch(url) { return .allow }
            return .ask(ApprovalRequest(
                title: "Allow Teacher to \(verb) a file outside “\(ws.name)”?",
                detail: url.path,
                options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { choice in
                choice == "once" ? .allow : .deny("The learner declined writing outside the folder.")
            }
        case .execute:
            if let mcp = tool as? MCPTool { return mcpGate(mcp, input, ws: ws, conv: conv) }
            // The project tools run the project's tests only in some actions (status, findings, park… run nothing).
            if let runs = Self.runsTests(tool, input), !runs { return .allow }
            // One grant per kind of run: diagnostics runs shell commands like bash; the three test tools run the project's
            // tests (asking three times in one lesson for the same suite was the mentor's main friction), and a lesson
            // that may run shell commands may run its tests and code snippets (a live lesson asked for both, minutes apart).
            let grant = tool.name == "diagnostics" ? "bash" : Self.runsTests(tool, input) != nil ? "tests" : Self.runsSnippets(tool) ? "run_code" : tool.name
            let impliedByBash = grant == "tests" || grant == "run_code"
            if access == .full || app.interactions.isGranted(grant, conversationID: conv)
                || (impliedByBash && app.interactions.isGranted("bash", conversationID: conv)) { return .allow }
            let command = tool.name == "bash" ? input["command"]?.string ?? "" : ""
            // Looking around needs no approval (`git status`, `ls`, `rg`…: the strict read-only list, run hardened by
            // `bash`), and nor does a command the user always allows in this folder.
            if !command.isEmpty, input["background"]?.bool != true, ReadOnlyShell.allows(command) { return .allow }
            if !command.isEmpty, CommandRules.matches(command, app.settings.value.commandRules[ws.url.path] ?? []) { return .allow }
            let rule = command.isEmpty ? nil : CommandRules.prefix(command)
            var detail = tool.name == "bash" ? command : (input["code"]?.string ?? tool.summary(input))
            var what = tool.name == "bash" ? "run this command" : "run this \(input["language"]?.string ?? (tool.name == "trace" ? "Python" : "")) code"
            if grant == "tests" {
                what = tool.name == "project_review" ? "run your tests for the review" : "run the project's tests"
                detail = input["command"]?.string ?? ProjectStore.load(ws)?.testCommand ?? detail
            }
            var options = [ApprovalOption(id: "once", label: "Allow once", style: .primary)]
            if let rule { options.append(ApprovalOption(id: "rule", label: "Always allow “\(rule) …” in this folder")) }
            options += [ApprovalOption(id: "lesson", label: "Allow for this lesson"),
                        ApprovalOption(id: "grant_full", label: "Give full access to “\(ws.name)”"),
                        ApprovalOption(id: "deny", label: "Deny", style: .danger)]
            return .ask(ApprovalRequest(title: "Allow Teacher to \(what)?", detail: String(detail.prefix(4000)), options: options)) { [weak self] choice in
                switch choice {
                case "once": return .allow
                case "rule":
                    if let rule, let self {
                        var rules = self.app.settings.value.commandRules[ws.url.path] ?? []
                        if !rules.contains(rule) { rules.append(rule) }
                        self.app.settings.value.commandRules[ws.url.path] = rules
                    }
                    return .allow
                case "lesson": self?.app.interactions.grant(grant, conversationID: conv); return .allow
                case "grant_full": self?.app.setAccess(.full, for: ws); return .allow
                default: return .deny("The learner declined.")
                }
            }
        }
    }

    /// An MCP server's tool: asked every time, whatever the folder's access (a server reaches what the folder grant doesn't
    /// cover: other services, accounts, the network), unless the user allows that server for the lesson or always in
    /// this folder.
    private func mcpGate(_ tool: MCPTool, _ input: JSON, ws: Workspace, conv: String) -> ToolDecision {
        let grant = "mcp:" + tool.server
        if app.interactions.isGranted(grant, conversationID: conv) || (app.settings.value.mcpAlwaysAllow[ws.url.path] ?? []).contains(tool.server) { return .allow }
        let args = input.object?.isEmpty == false ? input.pretty : "(no arguments)"
        return .ask(ApprovalRequest(
            title: "Allow Teacher to use “\(tool.info.name)” from the MCP server “\(tool.server)”?",
            detail: String(args.prefix(4000)) + (tool.readOnly ? "\n\nThe server marks this tool read-only." : ""),
            options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                      ApprovalOption(id: "lesson", label: "Allow “\(tool.server)” for this lesson"),
                      ApprovalOption(id: "always", label: "Always allow “\(tool.server)” in this folder"),
                      ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
            switch choice {
            case "once": return .allow
            case "lesson": self?.app.interactions.grant(grant, conversationID: conv); return .allow
            case "always":
                if let self {
                    var names = self.app.settings.value.mcpAlwaysAllow[ws.url.path] ?? []
                    if !names.contains(tool.server) { names.append(tool.server) }
                    self.app.settings.value.mcpAlwaysAllow[ws.url.path] = names
                }
                return .allow
            default: return .deny("The user declined this \(tool.server) call.")
            }
        }
    }

    /// Inside the system's temporary folder ($TMPDIR, /tmp).
    nonisolated static func isScratch(_ url: URL) -> Bool {
        let roots = [FileManager.default.temporaryDirectory, URL(fileURLWithPath: "/tmp"), URL(fileURLWithPath: "/private/tmp")]
        return roots.contains { url.isInside($0) }
    }

    /// For the project tools: whether this call runs the tests (nil for any other tool).
    nonisolated static func runsTests(_ tool: Tool, _ input: JSON) -> Bool? {
        let action = input["action"]?.string ?? ""
        switch tool.name {
        case "run_tests": return true
        case "project_tests": return ["set", "run"].contains(action)
        case "project_review": return action == "start"
        default: return nil
        }
    }

    /// The lesson grant for `web_fetch` on this Mac or the local network.
    nonisolated static let localFetch = "local-fetch"

    /// The tools that run a snippet of the model's code: one lesson grant covers them all.
    nonisolated static func runsSnippets(_ tool: Tool) -> Bool { ["run_code", "trace", "bench"].contains(tool.name) }

    nonisolated static func isPython(_ tool: Tool, _ input: JSON) -> Bool {
        if tool.name == "math" || tool.name == "trace" { return true }
        guard runsSnippets(tool) else { return false }
        return ["python", "python3", "py"].contains((input["language"]?.string ?? "").lowercased())
    }

    /// Package installs in shell commands or code (pip, uv, conda, poetry, npm -g…). Returns what matched.
    nonisolated static func packageInstall(tool: Tool, input: JSON) -> String? {
        guard tool.name == "bash" || runsSnippets(tool) else { return nil }
        let text = (input["command"]?.string ?? "") + "\n" + (input["code"]?.string ?? "")
        for pattern in installPatterns {
            if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return String(text[r]) }
        }
        return nil
    }

    /// Package managers' install commands (one pattern each, so none can swallow another): pip/pip3/pip3.12, pipx,
    /// conda and friends, gem, cargo, go, brew, port, uv (pip install, add, tool install), poetry/pipenv, `python -m pip`,
    /// and global JavaScript installs (npm -g/--global/--location=global, pnpm/yarn/bun -g, yarn global add).
    nonisolated static let installPatterns = [
        #"\b(pip(3(\.\d+)?)?|pipx|conda|mamba|micromamba|easy_install|gem|cargo|go|brew|port)\s+install\b"#,
        #"\buv\s+(pip\s+install|add|tool\s+install)\b"#,
        #"\b(poetry\s+add|pipenv\s+install)\b"#,
        #"\bpython(3(\.\d+)?)?\s+-m\s+(pip|ensurepip)\b|\bensurepip\b"#,
        #"\b(npm|pnpm|bun)\s+(i|install|add)\b[^\n;&|]*?\s(-g|--global|--location[= ]global)\b"#,
        #"\b(npm|pnpm|bun)\s+(-g|--global|--location[= ]global)\s+(i|install|add)\b"#,
        #"\byarn\s+global\s+add\b"#,
    ]
}

/// "Always allow in this folder" for shell commands, like Claude Code's `Bash(npm test:*)`: a rule is a command's leading
/// words (`npm test`, `swift build`, `npm run lint`, `python3 -m pytest`), and a command matches when it is one simple
/// command starting with them. Chaining, pipes, redirections and substitutions never match (they could append anything),
/// except one leading `cd dir &&`, which models add out of habit.
enum CommandRules {
    /// Programs that take a subcommand: a rule without one ("git", "npm") would allow everything they do.
    static let needsSubcommand: Set<String> = ["git", "npm", "pnpm", "yarn", "bun", "npx", "bunx", "cargo", "go", "swift", "docker", "kubectl", "gh",
                                               "brew", "pip", "pip3", "uv", "poetry", "deno", "dotnet", "mvn", "gradle", "./gradlew", "zig",
                                               "rustup", "xcrun", "bundle", "rails", "mix", "composer", "terraform", "make",
                                               "python", "python3", "node", "ruby", "perl"]
    /// Never offered as a rule: removing, privilege, raw devices, network transfer, process control, running other code.
    /// git and hg too: a repository's own config can make them run programs (fsmonitor, diff drivers, hooks), and their
    /// looking commands already run hardened without asking; a rule would let a variant of those run unhardened.
    static let never: Set<String> = ["git", "hg", "rm", "rmdir", "sudo", "su", "doas", "dd", "mkfs", "chmod", "chown", "chflags", "kill", "killall", "pkill",
                                     "curl", "wget", "ssh", "scp", "sftp", "rsync", "nc", "sh", "bash", "zsh", "fish", "eval", "exec", "env",
                                     "xargs", "osascript", "open", "launchctl", "defaults", "security", "diskutil", "shutdown", "reboot", "crontab",
                                     "mv", "cp", "ln", "tee", "truncate", "shred", "find"]
    static let runners: Set<String> = ["npm", "pnpm", "yarn", "bun"]

    /// The rule to offer for `command`, or nil when it can't have one.
    static func prefix(_ command: String) -> String? {
        guard let words = simpleWords(command), let w0 = words.first, !never.contains(w0), !w0.contains("=") else { return nil }
        let isWord = { (w: String) in !w.hasPrefix("-") && w.allSatisfy { $0.isLetter || $0.isNumber || "-_:.@".contains($0) } && !w.isEmpty }
        var rule = [w0]
        if ["python", "python3"].contains(w0), words.count > 2, words[1] == "-m", isWord(words[2]) { rule += ["-m", words[2]] }
        else if words.count > 1, isWord(words[1]) {
            rule.append(words[1])
            if runners.contains(w0), ["run", "run-script", "exec", "x"].contains(words[1]), words.count > 2, isWord(words[2]) { rule.append(words[2]) }
        }
        if rule.count == 1, needsSubcommand.contains(w0) { return nil }
        // A runner's bare `run`/`exec` would allow every script or binary.
        if rule.count == 2, runners.contains(w0), ["run", "run-script", "exec", "x"].contains(rule[1]) { return nil }
        return rule.joined(separator: " ")
    }

    static func matches(_ command: String, _ rules: [String]) -> Bool {
        guard !rules.isEmpty, let words = simpleWords(command), let w0 = words.first, !never.contains(w0) else { return false }
        return rules.contains { r in
            let rw = r.split(separator: " ").map(String.init)
            return !rw.isEmpty && words.count >= rw.count && Array(words.prefix(rw.count)) == rw
        }
    }

    /// The words of a single simple command (after one optional `cd dir &&`), or nil when it is anything more.
    static func simpleWords(_ command: String) -> [String]? {
        var c = command.trimmingCharacters(in: .whitespacesAndNewlines)
        if let r = c.range(of: #"^cd\s+[^\s;&|<>$`\\(){}'"]+\s*&&\s*"#, options: .regularExpression) { c = String(c[r.upperBound...]) }
        guard !c.isEmpty, isSimple(c), let words = ReadOnlyShell.tokens(c), !words.isEmpty else { return nil }
        return words
    }

    /// No shell syntax outside single quotes beyond words: no `; & | < > ( ) { }` or newlines, no `$`, backquotes or
    /// backslashes (which also expand inside double quotes).
    static func isSimple(_ s: String) -> Bool {
        var quote: Character?
        for ch in s {
            if quote == "'" { if ch == "'" { quote = nil }; continue }
            if quote == "\"" {
                if ch == "\"" { quote = nil } else if "$`\\".contains(ch) { return false }
                continue
            }
            if ch == "'" || ch == "\"" { quote = ch; continue }
            if ";&|<>(){}$`\\\n".contains(ch) { return false }
        }
        return quote == nil
    }
}
