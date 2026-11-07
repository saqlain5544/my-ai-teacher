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
            return .deny("Installing packages isn't allowed (\(installing)). Use the standard library or what's already installed.")
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
        // Reading is open everywhere except where people keep credentials (~/.ssh, ~/.aws…): asked once per lesson. The
        // gates compose, so an approval here still meets the others. Commands can't be read for paths; the OS fence covers them.
        if let path = Secrets.credentialPathNamed(by: tool.name, input, workspace: ws.url), !app.interactions.isGranted(Self.credentialRead, conversationID: conv) {
            return .ask(ApprovalRequest(
                title: "Allow Teacher to read credentials?",
                detail: "\(path) holds keys or passwords. What Teacher reads goes to the model provider.",
                options: [ApprovalOption(id: "once", label: "Allow once"),
                          ApprovalOption(id: "lesson", label: "Allow for this lesson"),
                          ApprovalOption(id: "deny", label: "Deny", style: .primary)])) { [weak self] choice in
                switch choice {
                case "once": return .allow
                case "lesson": self?.app.interactions.grant(Self.credentialRead, conversationID: conv); return .allow
                default: return .deny("The learner declined: that is where credentials are kept.")
                }
            }
        }
        // Other folders' lessons are the learner's words from elsewhere, and a search sends what it finds to the model: asked once per lesson.
        if tool.name == "past_lessons", input["scope"]?.string == "all", !app.interactions.isGranted(Self.otherFolders, conversationID: conv) {
            return .ask(ApprovalRequest(
                title: "Allow Teacher to search your lessons in other folders?",
                detail: "Matching passages from lessons in your other folders (\(SessionIndex.known.get().count) known) would be sent to the model. Nothing is changed.",
                options: [ApprovalOption(id: "lesson", label: "Allow for this lesson", style: .primary),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                if choice == "lesson" { self?.app.interactions.grant(Self.otherFolders, conversationID: conv); return .allow }
                return .deny("The learner declined searching their other folders. Search this folder's lessons (without scope \"all\").")
            }
        }
        if tool.name == "lsp", let gate = lspGate(input, ws: ws, conv: conv) { return gate }   // may probe for the binary: off the main actor
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
            // The debugger asks once to launch a program or evaluate an expression in it; stepping and the rest of an approved
            // session add no code. Its grant is its own ("Allow for this lesson" must not allow every later shell command), implied
            // by a shell grant; only a build command, which is a shell command, needs that one.
            if tool.name == "debug" {
                if let bad = DebugTool.invalid(input) { return .deny(bad) }
                if DebugTool.need(input) == .none { return .allow }
            }
            let debugGrant = tool.name == "debug" ? ((input["build"]?.string ?? "").isEmpty ? "debug" : "bash") : nil
            let grant = debugGrant ?? (tool.name == "diagnostics" ? "bash" : Self.runsTests(tool, input) != nil ? "tests" : Self.runsSnippets(tool) ? "run_code" : tool.name)
            let impliedByBash = grant == "tests" || grant == "run_code" || grant == "debug"
            if access == .full || app.interactions.isGranted(grant, conversationID: conv)
                || (impliedByBash && app.interactions.isGranted("bash", conversationID: conv)) { return .allow }
            // The shell command this call runs: bash's, an explicit diagnostics or test command, or the project's test command.
            // `run_tests` without one runs each file in its test folder instead, which no rule for a command covers.
            let folderRun = tool.name == "run_tests" && (input["command"]?.string ?? "").isEmpty
            let command = tool.name == "bash" ? input["command"]?.string ?? ""
                : folderRun ? ""
                : tool.name == "diagnostics" || grant == "tests"
                    ? input["command"]?.string ?? (grant == "tests" ? ProjectStore.load(ws)?.testCommand : nil) ?? "" : ""
            // Looking around needs no approval (`git status`, `ls`, `rg`…: the strict read-only list, run hardened by
            // `bash`), and nor does a command the user always allows in this folder.
            if tool.name == "bash", !command.isEmpty, input["background"]?.bool != true, ReadOnlyShell.allows(command) { return .allow }
            if !command.isEmpty, CommandRules.matches(command, app.settings.value.commandRules[ws.url.path] ?? []) { return .allow }
            let rule = command.isEmpty ? nil : CommandRules.prefix(command)
            var detail = tool.name == "bash" ? command : (input["code"]?.string ?? tool.summary(input))
            var what = tool.name == "bash" ? "run this command" : tool.name == "debug" ? (DebugTool.need(input) == .evaluate ? "evaluate an expression inside your program under the debugger" : "run your program under a debugger") : "run this \(input["language"]?.string ?? (tool.name == "trace" ? "Python" : "")) code"
            if tool.name == "debug" { detail = DebugTool.approvalDetail(input) }
            if grant == "tests" {
                what = tool.name == "project_review" ? "run your tests for the review" : "run the project's tests"
                detail = folderRun
                    ? RunTestsTool.plan(dir: resolvePath(input["path"]?.string ?? ".teacher/tests", workspace: ws.url), filter: input["filter"]?.string)?
                        .map(\.1).joined(separator: "\n") ?? detail
                    : input["command"]?.string ?? ProjectStore.load(ws)?.testCommand ?? detail
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

    /// The hub whose servers `lsp` asks about (tests give their own).
    var lspHub: LSPHub = .shared

    /// `lsp`: a language server runs the project's code while it analyses it (rust-analyzer's build scripts and proc macros,
    /// gopls's `go list`), so the first use of a server in a folder asks, once per folder and server (kept in the app's
    /// settings), or for this lesson. Which server a file needs can mean running `xcrun --find` or a rustup proxy to see
    /// that it works, so that is decided off the main actor (`.pending`). A decline holds for the lesson. nil: no file or
    /// language to decide from (the tool explains).
    private func lspGate(_ input: JSON, ws: Workspace, conv: String) -> ToolDecision? {
        let hub = lspHub, folder = LSPTool.canonical(ws.url)
        guard LSPTool.extensionFor(input, folder: folder, hub: hub) != nil else { return nil }
        return .pending { [weak self] in
            let found = await withCheckedContinuation { (c: CheckedContinuation<(spec: LSPServerSpec, executable: String)?, Never>) in
                DispatchQueue.global(qos: .userInitiated).async { c.resume(returning: LSPTool.server(for: input, hub: hub, folder: folder)) }
            }
            guard let self, let (spec, exe) = found else { return .allow }
            return self.lspDecision(spec, exe, ws: ws, folder: folder, conv: conv, hub: hub)
        }
    }

    private func lspDecision(_ spec: LSPServerSpec, _ exe: String, ws: Workspace, folder: URL, conv: String, hub: LSPHub) -> ToolDecision {
        if app.interactions.isGranted(LSPHub.declined(spec.id), conversationID: conv) {
            return .deny("The learner declined starting \(spec.title) in this folder. Use `symbols`, `code` and `grep` instead.")
        }
        if (app.settings.value.lspApproved[folder.path] ?? []).contains(spec.id) || app.interactions.isGranted(LSPHub.grant(spec.id), conversationID: conv)
            || hub.processApproved(spec.id, folder: folder) { return .allow }
        return .ask(LSPHub.approvalRequest(spec, executable: exe, ws: ws)) { [weak self] choice in
            switch choice {
            case "folder":
                if let self {
                    var ids = self.app.settings.value.lspApproved[folder.path] ?? []
                    if !ids.contains(spec.id) { ids.append(spec.id) }
                    self.app.settings.value.lspApproved[folder.path] = ids
                }
                return .allow
            case "lesson": self?.app.interactions.grant(LSPHub.grant(spec.id), conversationID: conv); return .allow
            default:
                self?.app.interactions.grant(LSPHub.declined(spec.id), conversationID: conv)
                return .deny("The learner declined starting \(spec.title) in this folder. Use `symbols`, `code` and `grep` instead.")
            }
        }
    }

    /// An MCP server's tool: asked every time, whatever the folder's access (a server reaches what the folder grant doesn't
    /// cover: other services, accounts, the network), unless the user allows that server for the lesson or always in
    /// this folder.
    private func mcpGate(_ tool: MCPTool, _ input: JSON, ws: Workspace, conv: String) -> ToolDecision {
        let key = tool.config.grantKey, grant = "mcp:" + key
        let args = input.object?.isEmpty == false ? input.pretty : "(no arguments)"
        // A tool the server added or rewrote since it was last listed isn't covered by an earlier "allow this server":
        // the learner sees the call again, once, and that version is then the approved one.
        if MCPHub.shared.isChanged(tool.config, tool: tool.info.name) {
            let config = tool.config, name = tool.info.name
            return .ask(ApprovalRequest(
                title: "“\(name)” from the MCP server “\(tool.server)” is new or has changed",
                detail: "The server's tool list changed since you last used it, so earlier approvals don't cover this tool.\n\n" + String(args.prefix(3800)),
                options: [ApprovalOption(id: "once", label: "Allow, and trust this version", style: .primary),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { choice in
                guard choice == "once" else { return .deny("The user declined this changed \(config.name) tool.") }
                MCPHub.shared.acknowledge(config, tool: name)
                return .allow
            }
        }
        if app.interactions.isGranted(grant, conversationID: conv) || (app.settings.value.mcpAlwaysAllow[ws.url.path] ?? []).contains(key) { return .allow }
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
                    if !names.contains(key) { names.append(key) }
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
        case "run_tests", "mutate", "coverage": return true
        case "project_tests": return ["set", "run"].contains(action)
        case "project_review": return action == "start"
        default: return nil
        }
    }

    /// The lesson grant for `web_fetch` on this Mac or the local network.
    nonisolated static let localFetch = "local-fetch"
    /// The lesson grant for reading the credential folders.
    nonisolated static let credentialRead = "credential-read"
    nonisolated static let otherFolders = "past-lessons-all"

    /// The tools that run a snippet of the model's code: one lesson grant covers them all.
    nonisolated static func runsSnippets(_ tool: Tool) -> Bool { ["run_code", "trace", "bench"].contains(tool.name) }

    nonisolated static func isPython(_ tool: Tool, _ input: JSON) -> Bool {
        if tool.name == "math" || tool.name == "trace" { return true }
        guard runsSnippets(tool) else { return false }
        return ["python", "python3", "py"].contains((input["language"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
    }

    /// Package installs in shell commands or code (pip, uv, conda, poetry, npm -g…). Returns what matched.
    nonisolated static func packageInstall(tool: Tool, input: JSON) -> String? {
        guard tool.name == "bash" || tool.name == "diagnostics" || tool.name == "debug" || runsSnippets(tool) || runsTests(tool, input) == true else { return nil }
        let text = (input["command"]?.string ?? "") + "\n" + (input["code"]?.string ?? "") + "\n" + (input["build"]?.string ?? "")
        for pattern in installPatterns {
            if let r = text.range(of: pattern, options: [.regularExpression, .caseInsensitive]) { return String(text[r]) }
        }
        return nil
    }

    /// Package managers' install commands (one pattern each, so none can swallow another): pip/pip3/pip3.12, pipx,
    /// conda and friends, gem, cargo, go, brew, port, uv (pip install, add, tool install), poetry/pipenv, `python -m pip`,
    /// and global JavaScript installs (npm -g/--global/--location=global, pnpm/yarn/bun -g, yarn global add); also the
    /// argument lists code passes to subprocess (`["pip", "install", …]`, `[sys.executable, "-m", "pip", …]`).
    nonisolated static let installPatterns = [
        #"["'](pip(3(\.\d+)?)?|pipx|conda|mamba|micromamba|gem|cargo|go|brew|port)["']\s*,\s*["']install["']"#,
        #"["']-m["']\s*,\s*["'](pip|ensurepip)["']"#,
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
