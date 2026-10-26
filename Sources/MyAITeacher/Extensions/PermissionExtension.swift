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
            // The project tools run the project's tests only in some actions (status, findings, park… run nothing).
            if let runs = Self.runsTests(tool, input), !runs { return .allow }
            // One grant per kind of run: diagnostics runs shell commands like bash; the three test tools run the project's
            // tests (asking three times in one lesson for the same suite was the mentor's main friction), and a lesson
            // that may run shell commands may run its tests.
            let grant = tool.name == "diagnostics" ? "bash" : Self.runsTests(tool, input) != nil ? "tests" : tool.name
            if access == .full || app.interactions.isGranted(grant, conversationID: conv)
                || (grant == "tests" && app.interactions.isGranted("bash", conversationID: conv)) { return .allow }
            var detail = tool.name == "bash" ? (input["command"]?.string ?? "") : (input["code"]?.string ?? tool.summary(input))
            var what = tool.name == "bash" ? "run this command" : "run this \(input["language"]?.string ?? "") code"
            if grant == "tests" {
                what = tool.name == "project_review" ? "run your tests for the review" : "run the project's tests"
                detail = input["command"]?.string ?? ProjectStore.load(ws)?.testCommand ?? detail
            }
            return .ask(ApprovalRequest(
                title: "Allow Teacher to \(what)?",
                detail: String(detail.prefix(4000)),
                options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                          ApprovalOption(id: "lesson", label: "Allow for this lesson"),
                          ApprovalOption(id: "grant_full", label: "Give full access to “\(ws.name)”"),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                switch choice {
                case "once": return .allow
                case "lesson": self?.app.interactions.grant(grant, conversationID: conv); return .allow
                case "grant_full": self?.app.setAccess(.full, for: ws); return .allow
                default: return .deny("The learner declined.")
                }
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

    nonisolated static func isPython(_ tool: Tool, _ input: JSON) -> Bool {
        if tool.name == "math" { return true }
        guard tool.name == "run_code" else { return false }
        return ["python", "python3", "py"].contains((input["language"]?.string ?? "").lowercased())
    }

    /// Package installs in shell commands or code (pip, uv, conda, poetry, npm -g…). Returns what matched.
    nonisolated static func packageInstall(tool: Tool, input: JSON) -> String? {
        guard tool.name == "bash" || tool.name == "run_code" else { return nil }
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
