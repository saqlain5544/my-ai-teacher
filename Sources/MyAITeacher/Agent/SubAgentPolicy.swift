import Foundation

/// The lesson's grants as a sub-agent sees them: a ceiling, never a prompt (sub-agents run unsupervised and can't ask
/// the learner), so a sub-agent can do what the lesson may do without asking — and nothing more.
struct LessonGrants: Sendable, Equatable {
    var access: FolderAccess = .read
    /// Approvals the learner gave in this lesson ("write", "bash", "run_code", "python").
    var granted: Set<String> = []
    var python: PythonPolicy = .allow
    /// Tools the learner turned off (Settings → Tools).
    var disabled: Set<String> = []
}

/// What one run may touch: its tools, whether it is read-only, and the directory its writes must land in (the lesson's
/// folder, or the worktree it works on).
struct AgentScope: Sendable {
    var type: String
    var tools: Set<String>
    var readOnly: Bool
    var root: URL
    var folderName: String
}

/// What a sub-agent's own sub-agents may not exceed.
struct AgentCeiling: Sendable {
    /// The sub-agent whose calls these are (the parent of any it starts).
    var handle: String
    var readOnly: Bool
    var tools: Set<String>
}

enum SubAgentPolicy {
    /// Allow or deny one tool call of a sub-agent. Never asks.
    static func decide(_ tool: Tool, _ input: JSON, scope: AgentScope, grants: LessonGrants) -> ToolDecision {
        let who = "this \(scope.type) agent"
        guard scope.tools.contains(tool.name), !grants.disabled.contains(tool.name) else { return .deny("`\(tool.name)` isn't one of \(who)'s tools.") }
        if let installing = PermissionExtension.packageInstall(tool: tool, input: input) {
            return .deny("Installing packages isn't allowed (\(installing)).")
        }
        if PermissionExtension.isPython(tool, input) {
            switch grants.python {
            case .off: return .deny("The learner has turned Python off.")
            case .ask where !grants.granted.contains("python"):
                return .deny("Python needs the learner's approval in this lesson, and sub-agents can't ask. Work without it or report what you'd run.")
            default: if tool.name == "math" { return .allow }   // SymPy computes; it changes nothing
            }
        }
        switch tool.risk {
        case .readOnly, .network: return .allow
        case .interactive: return .deny("Sub-agents can't wait for the learner.")
        case .write:
            if scope.readOnly { return .deny("\(who.capitalizedFirst) is read-only: it can't change files.") }
            guard let p = input["path"]?.string else { return .allow }   // the tool reports the missing path itself
            let url = resolvePath(p, workspace: scope.root)
            if inside(url, scope.root.appendingPathComponent(Workspace.stateDirName)) {
                return .deny("`.teacher/` is the app's private state folder.")
            }
            guard inside(url, scope.root) else { return .deny("Sub-agents only write inside \(scope.root.path) (use paths relative to it).") }
            guard grants.access >= .write || grants.granted.contains("write") else {
                return .deny("“\(scope.folderName)” is read-only for the teacher, and sub-agents can't ask for more. The learner can grant write access.")
            }
            return .allow
        case .execute:
            if scope.readOnly {
                guard tool.name == "bash", let cmd = input["command"]?.string, ReadOnlyShell.allows(cmd) else {
                    return .deny("\(who.capitalizedFirst) is read-only: it may only run read-only commands (git diff/log/show/status, ls, cat, " +
                                 "grep, rg, find, head, tail, wc…) without redirection or chaining into other programs.")
                }
            }
            guard grants.access == .full || grants.granted.contains(tool.name) else {
                return .deny("Running commands needs full access to “\(scope.folderName)” (or the learner's approval in this lesson), and sub-agents can't ask.")
            }
            return .allow
        }
    }

    static func inside(_ url: URL, _ base: URL) -> Bool {
        let p = url.standardizedFileURL.resolvingSymlinksInPath().path, b = base.standardizedFileURL.resolvingSymlinksInPath().path
        return p == b || p.hasPrefix(b + "/")
    }
}

/// Shell commands a read-only agent may run: one pipeline of programs that only read, with no redirection,
/// substitution, background jobs or flags that write (`find -delete`, `git diff --output`, `sort -o`, `rg --pre`).
enum ReadOnlyShell {
    static let programs: Set<String> = ["ls", "cat", "head", "tail", "wc", "grep", "egrep", "fgrep", "rg", "find", "file", "stat", "pwd", "tree",
                                        "du", "diff", "cmp", "which", "sort", "uniq", "cut", "nl", "basename", "dirname", "realpath", "echo", "git"]
    static let git: Set<String> = ["diff", "log", "show", "status", "blame", "ls-files", "grep", "rev-parse", "shortlog", "describe", "ls-tree", "cat-file"]
    /// Per program: flags that write a file or start another program (`git -c` could set a pager or diff driver).
    static let forbidden: [String: [String]] = [
        "find": ["-delete", "-exec", "-execdir", "-ok", "-okdir", "-fprint", "-fprint0", "-fprintf", "-fls"],
        "sort": ["-o", "--output"], "tree": ["-o"], "rg": ["--pre"],
        "git": ["-c", "--output", "-O", "--open-files-in-pager", "--ext-diff", "--textconv", "--exec-path"],
    ]

    static func allows(_ command: String) -> Bool {
        // Anything that could write or start another program outside the pipeline: redirection, substitution, chaining.
        for bad in [">", "<", "`", "$(", "&", ";", "\n"] where command.contains(bad) { return false }
        for segment in segments(command) {
            let words = tokens(segment)
            guard let first = words.first, !first.contains("=") else { return false }
            let prog = (first as NSString).lastPathComponent
            guard programs.contains(prog) else { return false }
            let args = words.dropFirst(), bad = forbidden[prog] ?? []
            // `-o`, `-ofile`, `--output`, `--output=file`.
            if args.contains(where: { a in bad.contains { a == $0 || a.hasPrefix($0 + "=") || ($0.count == 2 && a.hasPrefix($0)) } }) { return false }
            if prog == "git" {
                // `git -C dir diff`: the first word that isn't an option (or -C's value) is the subcommand.
                var it = args.makeIterator(), sub: String?
                while let a = it.next() {
                    if a == "-C" { _ = it.next(); continue }
                    if a.hasPrefix("-") { continue }
                    sub = a; break
                }
                guard let sub, git.contains(sub) else { return false }
            }
        }
        return true
    }

    /// The commands of a pipeline: split at each `|` outside quotes (`rg 'a|b'` is one command).
    static func segments(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?
        for c in s {
            if let q = quote { if c == q { quote = nil }; cur.append(c); continue }
            if c == "'" || c == "\"" { quote = c }
            if c == "|" { out.append(cur); cur = ""; continue }
            cur.append(c)
        }
        return out + [cur]
    }

    /// Words of a simple command, honouring single and double quotes.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, any = false
        for c in s {
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "'" || c == "\"" { quote = c; any = true; continue }
            if c == " " || c == "\t" { if any || !cur.isEmpty { out.append(cur) }; cur = ""; any = false; continue }
            cur.append(c)
        }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
