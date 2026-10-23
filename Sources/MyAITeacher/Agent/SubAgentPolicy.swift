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
        case .control: return .deny("Sub-agents don't drive the browser or the Mac: their sites and apps need the learner's approval, and sub-agents can't ask.")
        case .write:
            if scope.readOnly { return .deny("\(who.capitalizedFirst) is read-only: it can't change files.") }
            guard let p = input["path"]?.string else { return .allow }   // the tool reports the missing path itself
            let url = resolvePath(p, workspace: scope.root)
            let state = scope.root.appendingPathComponent(Workspace.stateDirName)
            if url.isInside(state), !url.isInside(state.appendingPathComponent("tests")) {
                return .deny("`.teacher/` is the app's private state folder; only `.teacher/tests` is writable.")
            }
            guard url.isInside(scope.root) else { return .deny("Sub-agents only write inside \(scope.root.path) (use paths relative to it).") }
            guard grants.access >= .write || grants.granted.contains("write") else {
                return .deny("“\(scope.folderName)” is read-only for the teacher, and sub-agents can't ask for more. The learner can grant write access.")
            }
            return .allow
        case .execute:
            if scope.readOnly {
                guard tool.name == "bash", let cmd = input["command"]?.string, ReadOnlyShell.allows(cmd) else {
                    return .deny("\(who.capitalizedFirst) is read-only: it may only run read-only commands (git diff/log/show/status/blame/grep, " +
                                 "ls, cat, grep, rg, find, head, tail, wc, sort, diff…) with their reading flags. They run directly, without a shell: " +
                                 "no redirection, chaining, globs or expansions, and no word with \\ $ { } * ? [ ] ( ) = ! ~. Use read, grep and glob for the rest.")
                }
            }
            guard grants.access == .full || grants.granted.contains(tool.name) else {
                return .deny("Running commands needs full access to “\(scope.folderName)” (or the learner's approval in this lesson), and sub-agents can't ask.")
            }
            return .allow
        }
    }
}

/// Commands a read-only agent may run — never through a shell. The command is split into a pipeline of argument
/// lists (quotes honoured) and each program runs directly (`run`), so nothing a shell would interpret exists: no globs,
/// expansions, substitutions, redirections or chaining. On top of that every word is checked: a bare program name from
/// the list (no paths), only its allowlisted flags (short ones combine only when each is allowed), and no word with
/// `\ $ { } * ? [ ] ( ) = ! ~` (`find . -de\lete`, `$'-delete'`, `-{delete,print}`, `=(…)`, `--outp=x`, `--config-env=…`).
/// git runs with fsmonitor, hooks, external diff and text conversion off, so a repository's config can't start programs.
enum ReadOnlyShell {
    struct Rules {
        var flags: Set<String> = []
        /// Flags that take the next word as their value.
        var valued: Set<String> = []
        /// `-la` = `-l -a` (each must be an allowed single-letter flag).
        var combinable = false
        /// `-20` (head, tail, git log).
        var count = false
    }
    static let grep = Rules(flags: ["-i", "-n", "-r", "-R", "-l", "-L", "-c", "-v", "-w", "-x", "-E", "-F", "-o", "-h", "-H", "-s", "-q"],
                            valued: ["-A", "-B", "-C", "-m", "-e"], combinable: true)
    static let programs: [String: Rules] = [
        "ls": Rules(flags: ["-l", "-a", "-A", "-h", "-R", "-1", "-t", "-S", "-r", "-d", "-F"], combinable: true),
        "cat": Rules(flags: ["-n", "-b"], combinable: true),
        "head": Rules(valued: ["-n", "-c"], count: true), "tail": Rules(valued: ["-n", "-c"], count: true),
        "wc": Rules(flags: ["-l", "-w", "-c", "-m"], combinable: true),
        "grep": grep, "egrep": grep, "fgrep": grep,
        "rg": Rules(flags: ["-i", "-n", "-l", "-c", "-w", "-v", "-F", "-S", "-s", "-u", "-o", "-N", "--files", "--hidden", "--no-ignore", "--count",
                            "--files-with-matches", "--line-number", "--ignore-case", "--fixed-strings", "--word-regexp"],
                    valued: ["-A", "-B", "-C", "-m", "-e", "-t", "-T"], combinable: true),
        "find": Rules(flags: ["-print", "-print0", "-not", "-and", "-or", "-empty", "-L", "-H"],
                      valued: ["-name", "-iname", "-type", "-path", "-ipath", "-maxdepth", "-mindepth", "-size", "-mtime", "-newer"]),
        "stat": Rules(flags: ["-L", "-l", "-x"]), "pwd": Rules(),
        "du": Rules(flags: ["-s", "-h", "-k", "-a", "-c"], valued: ["-d"], combinable: true),
        "diff": Rules(flags: ["-u", "-q", "-r", "-N", "-w", "-b", "-i", "-B", "-y"], valued: ["-U"], combinable: true),
        "cmp": Rules(flags: ["-l", "-s"]), "which": Rules(flags: ["-a"]),
        "sort": Rules(flags: ["-n", "-r", "-u", "-f", "-b", "-h", "-V"], valued: ["-k", "-t"], combinable: true),
        "cut": Rules(valued: ["-d", "-f", "-c"]), "basename": Rules(), "dirname": Rules(), "realpath": Rules(), "echo": Rules(flags: ["-n"]),
        "git": Rules(),   // its subcommands' rules are in `git`
    ]
    /// Read-only git subcommands, each with its own flags. Before the subcommand only `-C dir` and `--no-pager`.
    static let git: [String: Rules] = [
        "status": Rules(flags: ["-s", "-b", "--short", "--branch", "--porcelain", "-u", "--untracked-files"], combinable: true),
        "diff": Rules(flags: ["--stat", "--name-only", "--name-status", "--cached", "--staged", "--shortstat", "--numstat", "--no-color", "-w",
                              "--ignore-all-space", "-b", "--summary", "--minimal", "-R", "-p"], valued: ["-U"]),
        "log": Rules(flags: ["--oneline", "--stat", "--graph", "--decorate", "--all", "-p", "--name-only", "--name-status", "--no-merges", "--reverse",
                             "--first-parent", "--abbrev-commit", "--shortstat"], valued: ["-n", "--author", "--since", "--until", "--grep", "--max-count"], count: true),
        "show": Rules(flags: ["--stat", "--name-only", "--name-status", "--oneline", "--no-patch", "-s", "--shortstat", "--summary"]),
        "blame": Rules(flags: ["-w", "-e", "-s", "-l"], valued: ["-L"]),
        "ls-files": Rules(flags: ["-c", "-m", "-o", "-d", "-s", "--cached", "--modified", "--others", "--deleted", "--exclude-standard", "--stage"], combinable: true),
        "grep": Rules(flags: ["-n", "-i", "-l", "-w", "-v", "-c", "-E", "-F", "-h", "--cached", "--count", "--line-number", "--ignore-case",
                              "--files-with-matches", "--untracked"], valued: ["-e", "-A", "-B", "-C"], combinable: true),
        "rev-parse": Rules(flags: ["--show-toplevel", "--abbrev-ref", "--short", "--verify", "--git-dir", "--is-inside-work-tree"]),
        "shortlog": Rules(flags: ["-s", "-n", "-e", "--summary", "--numbered", "--email"], combinable: true),
        "describe": Rules(flags: ["--tags", "--always", "--long", "--dirty"]),
        "ls-tree": Rules(flags: ["-r", "-d", "-t", "-l", "--name-only", "--long"], combinable: true),
        "cat-file": Rules(flags: ["-p", "-t", "-s", "-e"]),
    ]
    static let unsafe = Set("\\$={}*?[]()!~`;&<>\n")

    static func allows(_ command: String) -> Bool { parse(command) != nil }

    /// The pipeline as argument lists, or nil when anything in it isn't allowed.
    static func parse(_ command: String) -> [[String]]? {
        var pipeline: [[String]] = []
        for segment in segments(command) {
            guard let words = tokens(segment), let first = words.first, let rules = programs[first] else { return nil }   // a bare name, no paths
            guard words.allSatisfy({ !$0.contains(where: unsafe.contains) }) else { return nil }
            var args = words.dropFirst()
            if first == "git" {
                while let a = args.first, a.hasPrefix("-") {   // global options
                    if a == "--no-pager" { args = args.dropFirst() }
                    else if a == "-C", args.count > 1 { args = args.dropFirst(2) }
                    else { return nil }
                }
                guard let sub = args.first, let r = git[sub], check(args.dropFirst(), r) else { return nil }
            } else if !check(args, rules) { return nil }
            pipeline.append(words)
        }
        return pipeline.isEmpty ? nil : pipeline
    }

    private static func check(_ args: ArraySlice<String>, _ r: Rules) -> Bool {
        var it = args.makeIterator(), options = true
        while let a = it.next() {
            guard options, a.hasPrefix("-"), a != "-" else { continue }   // a path, pattern or revision
            if a == "--" { options = false; continue }
            if r.flags.contains(a) { continue }
            if r.valued.contains(a) { guard it.next() != nil else { return false }; continue }
            let letters = a.dropFirst()
            if r.count, letters.count > 0, letters.allSatisfy(\.isNumber) { continue }
            if r.combinable, !a.hasPrefix("--"), letters.count > 1, letters.allSatisfy({ r.flags.contains("-\($0)") }) { continue }
            return false
        }
        return true
    }

    /// Runs an allowed pipeline without a shell: each program directly, connected by pipes as a shell would (so a
    /// reader that stops early, like `head`, ends its writer the usual way).
    static func run(_ command: String, cwd: URL, timeout: TimeInterval) async -> ToolOutput {
        guard let pipeline = parse(command) else { return .error("Not a read-only command this agent may run.") }
        var env = ShellEnvironment.shared.all
        env.merge(["TERM": "dumb", "NO_COLOR": "1", "PAGER": "cat", "GIT_PAGER": "cat"]) { $1 }
        var built: [Process] = []
        for words in pipeline {
            guard let exe = ProcessRunner.which(words[0]) else { return .error("`\(words[0])` isn't installed.") }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: exe)
            p.arguments = words[0] == "git" ? hardened(Array(words.dropFirst())) : Array(words.dropFirst())
            p.currentDirectoryURL = cwd
            p.environment = env
            built.append(p)
        }
        let procs = built
        let out = OutputCollector(limit: 2_000_000), err = OutputCollector(limit: 500_000)
        // File handles, not Pipe objects: Process closes a Pipe's parent end after the first launch, and every program
        // here shares the error pipe. The parent's ends are closed once all have started, so readers see the end.
        let outPipe = Pipe(), errPipe = Pipe(), links = (1..<procs.count).map { _ in Pipe() }
        procs[0].standardInput = FileHandle.nullDevice
        for (i, p) in procs.enumerated() {
            p.standardError = errPipe.fileHandleForWriting
            if i > 0 { p.standardInput = links[i - 1].fileHandleForReading }
            p.standardOutput = i < links.count ? links[i].fileHandleForWriting : outPipe.fileHandleForWriting
        }
        let parentEnds = [outPipe.fileHandleForWriting, errPipe.fileHandleForWriting] + links.flatMap { [$0.fileHandleForReading, $0.fileHandleForWriting] }
        for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
            pipe.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                if d.isEmpty { h.readabilityHandler = nil } else { sink.append(d) }
            }
        }
        let timedOut = TimeoutFlag()
        let status: Int32 = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Int32, Never>) in
                let left = Locked(procs.count)
                for p in procs {
                    p.terminationHandler = { _ in
                        guard left.mutate({ $0 -= 1; return $0 }) == 0 else { return }
                        for (pipe, sink) in [(outPipe, out), (errPipe, err)] {
                            pipe.fileHandleForReading.readabilityHandler = nil
                            sink.append(pipe.fileHandleForReading.readDataToEndOfFile())
                        }
                        c.resume(returning: procs[procs.count - 1].terminationStatus)
                    }
                }
                for p in procs {
                    do { try p.run() } catch {
                        procs.forEach { if $0.isRunning { $0.terminate() } }
                        left.mutate { $0 = -1 }
                        parentEnds.forEach { try? $0.close() }
                        c.resume(returning: -1)
                        return
                    }
                }
                parentEnds.forEach { try? $0.close() }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if procs.contains(where: \.isRunning) { timedOut.value = true; procs.forEach { if $0.isRunning { $0.terminate() } } }
                }
            }
        } onCancel: { procs.forEach { if $0.isRunning { $0.terminate() } } }
        var text = truncateMiddle(out.string + (err.string.isEmpty || out.string.isEmpty ? "" : "\n") + err.string, max: 30_000)
        if text.isEmpty { text = "(no output)" }
        if timedOut.value { text += "\n[timed out after \(Int(timeout)) s]" }
        if status != 0 { text += "\n[exit code \(status)]" }
        return ToolOutput(text: text, isError: timedOut.value, meta: ["exit": .number(Double(status)), "readOnlyShell": true])
    }

    /// git with nothing a repository's config could run: no fsmonitor, hooks, pager, external diff or text conversion.
    static func hardened(_ args: [String]) -> [String] {
        var head: [String] = [], rest = args[...]
        while let a = rest.first, a.hasPrefix("-") {
            head.append(a); rest = rest.dropFirst()
            if a == "-C", let d = rest.first { head.append(d); rest = rest.dropFirst() }
        }
        guard let sub = rest.first else { return args }
        let extra = ["diff", "log", "show"].contains(sub) ? ["--no-ext-diff", "--no-textconv"] : ["grep", "blame"].contains(sub) ? ["--no-textconv"] : []
        return ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "diff.external=", "--no-pager"] + head + [sub] + extra + Array(rest.dropFirst())
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

    /// Words of a simple command, honouring single and double quotes; nil when a quote is left open.
    static func tokens(_ s: String) -> [String]? {
        var out: [String] = [], cur = "", quote: Character?, any = false
        for c in s {
            if let q = quote { if c == q { quote = nil } else { cur.append(c) }; continue }
            if c == "'" || c == "\"" { quote = c; any = true; continue }
            if c == " " || c == "\t" { if any || !cur.isEmpty { out.append(cur) }; cur = ""; any = false; continue }
            cur.append(c)
        }
        if quote != nil { return nil }
        if any || !cur.isEmpty { out.append(cur) }
        return out
    }
}

private extension String {
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
