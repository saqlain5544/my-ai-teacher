import Foundation

/// Persistent working directory per conversation, like Claude Code's Bash tool.
actor ShellState {
    static let shared = ShellState()
    private var cwd: [String: URL] = [:]
    func dir(_ conv: String, default d: URL) -> URL { cwd[conv] ?? d }
    func set(_ conv: String, _ u: URL) { cwd[conv] = u }
}

struct BashTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { Double(min(600, max(1, input["timeout"]?.int ?? 120))) + 20 }
    let name = "bash"
    let description = """
    Run a shell command (zsh) on the learner's Mac. The working directory persists between calls (starts in the workspace). \
    Default timeout 120 s (max 600 s via `timeout`). Output over ~30k characters is truncated. \
    Servers and watchers (`npm run dev`, `python -m http.server`, anything that prints a localhost URL and keeps running) \
    move to the background on their own and the call returns with a handle (B1…) and the URL; `background: true` does \
    that for any command. Read or stop background jobs with `bash_jobs`. Never `sleep` waiting for a server: it is \
    ready when the call returns. \
    Prefer the dedicated read/edit/glob/grep tools for files. Never run destructive commands without the learner's explicit request.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "command": Schema.string("The command to run."),
            "timeout": Schema.integer("Timeout in seconds (default 120, max 600)."),
            "description": Schema.string("5-10 word description of what the command does."),
            "background": Schema.boolean("Start it and return after its first output, leaving it running (a server, a watcher, a long build)."),
        ], required: ["command"])
    }
    func summary(_ input: JSON) -> String { input["command"]?.string ?? "" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let command = try input.req("command")
        let session = ctx.shellID ?? ctx.conversationID
        let cwd = await ShellState.shared.dir(session, default: ctx.workspace)
        let timeout = TimeInterval(min(600, max(1, input["timeout"]?.int ?? 120)))
        let cwdFile = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-cwd-\(UUID().uuidString)")
        let script = "trap 'pwd > \(cwdFile.path.shellQuoted)' EXIT\n\(command)"
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let job = try ShellJob(command: command, title: input["description"]?.string ?? String(command.prefix(80)), conversationID: ctx.conversationID,
                               shell: shell, script: script, cwd: cwd, env: ProcessRunner.environment())
        job.onOutput = ctx.progress
        ShellJobs.shared.waitingOn(ctx.toolCallID, job)
        let outcome = await job.wait(timeout: timeout, mode: input["background"]?.bool == true ? .background : .auto)
        ShellJobs.shared.waitingOn(ctx.toolCallID, nil)
        job.onOutput = nil
        if let newDir = try? String(contentsOf: cwdFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !newDir.isEmpty {
            await ShellState.shared.set(session, URL(fileURLWithPath: newDir))
            try? FileManager.default.removeItem(at: cwdFile)
        }
        switch outcome {
        case .finished, .timedOut, .cancelled:
            if outcome != .finished { job.stop() }
            if outcome == .cancelled { throw CancellationError() }
            var text = truncateMiddle(job.output, max: 30_000).trimmingTrailingNewlines
            if text.isEmpty { text = "(no output)" }
            let code = job.exitCode ?? -1
            if outcome == .timedOut { text += "\n[timed out after \(Int(timeout)) s and stopped, with everything it started. A server or watcher belongs in the background: `background: true`.]" }
            else if code != 0 { text += "\n[exit code \(code)]" }
            let jobs = ShellJobs.shared.summary(ctx.conversationID)
            if !jobs.isEmpty { text += "\n" + jobs }
            return ToolOutput(text: text, isError: outcome == .timedOut, meta: ["exit": .number(Double(code))])
        case .server, .left, .background, .learner:
            let handle = ShellJobs.shared.adopt(job)
            job.markRead()
            let why = switch outcome {
            case .server: job.urls.isEmpty ? "It keeps running (a server or watcher), so it" : "It is serving at \(job.urls.joined(separator: ", ")), so it"
            case .left: "The command finished but left a process running, which"
            case .learner: "The learner moved it to the background (carry on with other work; don't wait for it), so it"
            default: "It"
            }
            var text = truncateMiddle(job.output, max: 12_000).trimmingTrailingNewlines
            if text.isEmpty { text = "(no output yet)" }
            text += "\n[\(why) now runs in the background as \(handle). If it ends by itself, its output arrives as a <background-task id=\"\(handle)\"> message: carry on meanwhile, don't poll. New output now: bash_jobs {\"action\": \"output\", \"handle\": \"\(handle)\"}; stop it with {\"action\": \"stop\", \"handle\": \"\(handle)\"}. Don't start it again.]"
            let others = ShellJobs.shared.summary(ctx.conversationID, except: handle)
            if !others.isEmpty { text += "\n" + others }
            var meta: [String: JSON] = ["background": .string(handle)]
            if let u = job.urls.first { meta["url"] = .string(u) }
            return ToolOutput(text: text, meta: .object(meta))
        }
    }
}

private extension String {
    var trimmingTrailingNewlines: String { var s = self; while s.hasSuffix("\n") { s.removeLast() }; return s }
}

/// The background jobs `bash` left running: list them, read what they printed since the last look, stop them.
struct BashJobsTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { Double(min(60, max(0, input["wait"]?.int ?? 0))) + 15 }
    let name = "bash_jobs"
    let description = """
    The lesson's background shell jobs (servers, watchers, anything `bash` moved to the background). \
    `list` (default): each job, running or exited, and its URL. `output`: what a job printed since you last looked; \
    `wait` (seconds, max 60) waits for new output first. `stop`: ends the job and everything it started.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("What to do (default list).", enum: ["list", "output", "stop"]),
            "handle": Schema.string("The job's handle, B1…"),
            "wait": Schema.integer("For output: seconds to wait for new output or the job's end (max 60)."),
        ])
    }
    func summary(_ input: JSON) -> String { [input["action"]?.string ?? "list", input["handle"]?.string].compactMap { $0 }.joined(separator: " ") }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let conv = ctx.conversationID
        // The words models reach for: "wait" is output after waiting, "read"/"logs"/"tail" are output, "kill" is stop.
        var action = input["action"]?.string?.lowercased() ?? "list"
        switch action {
        case "wait": action = "output"
        case "read", "logs", "log", "tail", "status": action = "output"
        case "kill", "end", "terminate": action = "stop"
        case "jobs", "ls": action = "list"
        default: break
        }
        let waitDefault = input["action"]?.string?.lowercased() == "wait" ? 60 : 0
        if action == "list" {
            let all = ShellJobs.shared.list(conv)
            for j in all where !j.isRunning { j.exitSeen = true }
            return ToolOutput(text: all.isEmpty ? "No background jobs." : all.map(ShellJobs.line).joined(separator: "\n"))
        }
        guard let h = input["handle"]?.string, let job = ShellJobs.shared.job(conv, h) else {
            let known = ShellJobs.shared.list(conv).compactMap(\.handle)
            throw ToolError("No background job \(input["handle"]?.string ?? "(no handle)")." + (known.isEmpty ? " There are none." : " Jobs: \(known.joined(separator: ", ")).") )
        }
        switch action {
        case "stop":
            let wasRunning = job.isRunning
            job.stop()
            ShellJobs.shared.forget(conv, job.handle ?? h)
            return ToolOutput(text: wasRunning ? "Stopped \(job.handle ?? h) (`\(job.command.prefix(80))`) and everything it started." : "\(job.handle ?? h) had already exited (code \(job.exitCode ?? -1)).")
        case "output":
            var text = job.readNew()
            let wait = Double(min(60, max(0, input["wait"]?.int ?? waitDefault)))
            if text.isEmpty, wait > 0 {
                let until = Date().addingTimeInterval(wait)
                while text.isEmpty, job.isRunning, Date() < until, !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    text = job.readNew()
                }
                if text.isEmpty { text = job.readNew() }
            }
            text = truncateMiddle(text, max: 30_000).trimmingTrailingNewlines
            if !job.isRunning { job.exitSeen = true }   // the agent knows it ended: no report of it afterwards
            return ToolOutput(text: (text.isEmpty ? "(nothing new)" : text) + "\n[" + ShellJobs.line(job) + "]")
        default:
            throw ToolError("Unknown action \(action): use list, output or stop.")
        }
    }
}

/// Runs a self-contained snippet in a scratch directory. Used by the tutor and by "Run" buttons on code blocks.
struct RunCodeTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { Double(min(300, max(1, input["timeout"]?.int ?? 30))) + 60 }   // + compile time
    let name = "run_code"
    let description = """
    Execute a code snippet and return stdout/stderr. Languages: python, javascript, typescript, swift, c, cpp, go, rust, zig, ruby, bash, java. \
    Use it to verify answers, demonstrate concepts, check the learner's code, or compute results exactly. Optional `stdin`. \
    The program runs in the lesson's folder, so relative paths refer to the learner's files.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "language": Schema.string("Programming language."),
            "code": Schema.string("Complete program source."),
            "stdin": Schema.string("Optional standard input."),
            "timeout": Schema.integer("Seconds (default 30, max 300)."),
        ], required: ["language", "code"])
    }
    func summary(_ input: JSON) -> String { "\(input["language"]?.string ?? "code") snippet" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let (code, strayEOF) = HeredocSlip.strip(try input.req("code"))
        let r = try await Self.execute(language: try input.req("language"), code: code,
                                       stdin: input["stdin"]?.string, timeout: TimeInterval(min(300, max(1, input["timeout"]?.int ?? 30))),
                                       workingDirectory: ctx.workspace, progress: ctx.progress)
        return ToolOutput(text: r.text + (strayEOF ? "\n" + HeredocSlip.note : ""), isError: r.failed)
    }

    struct RunResult: Sendable { var text: String; var failed: Bool }

    static func normalize(_ lang: String) -> String {
        switch lang.lowercased() {
        case "py", "python3", "python": "python"
        case "js", "javascript", "node", "mjs": "javascript"
        case "ts", "typescript": "typescript"
        case "sh", "shell", "zsh", "bash", "console": "bash"
        case "c++", "cpp", "cc", "cxx": "cpp"
        case "golang", "go": "go"
        case "rs", "rust": "rust"
        case "rb", "ruby": "ruby"
        default: lang.lowercased()
        }
    }

    static let runnable: Set<String> = ["python", "javascript", "typescript", "swift", "c", "cpp", "go", "rust", "ruby", "bash", "java", "zig"]

    /// Sources/binaries live in a scratch dir; the program runs in `workingDirectory` (the lesson's folder)
    /// so relative paths like open("notes.txt") work.
    static func execute(language: String, code: String, stdin: String?, timeout: TimeInterval,
                        workingDirectory: URL? = nil, progress: (@Sendable (String) -> Void)? = nil) async throws -> RunResult {
        let lang = normalize(language)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-run-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        func write(_ name: String) throws -> String {
            let f = dir.appendingPathComponent(name); try Data(code.utf8).write(to: f); return f.path
        }
        func need(_ tool: String) throws -> String {
            guard let p = ProcessRunner.which(tool) else { throw ToolError("`\(tool)` is not installed on this Mac.") }
            return p
        }
        var steps: [(String, [String])] = []
        switch lang {
        case "python": steps = [(try need("python3"), ["-u", try write("main.py")])]
        case "javascript": steps = [(try need("node"), [try write("main.mjs")])]
        case "typescript":
            if let bun = ProcessRunner.which("bun") { steps = [(bun, ["run", try write("main.ts")])] }
            else if let deno = ProcessRunner.which("deno") { steps = [(deno, ["run", "-A", try write("main.ts")])] }
            else { steps = [(try need("node"), ["--experimental-strip-types", try write("main.ts")])] }
        case "swift": steps = [(try need("swift"), [try write("main.swift")])]
        case "c":
            let src = try write("main.c")
            steps = [(try need("clang"), [src, "-O1", "-lm", "-o", dir.appendingPathComponent("a.out").path]), (dir.appendingPathComponent("a.out").path, [])]
        case "cpp":
            let src = try write("main.cpp")
            steps = [(try need("clang++"), ["-std=c++20", "-O1", src, "-o", dir.appendingPathComponent("a.out").path]), (dir.appendingPathComponent("a.out").path, [])]
        case "go": steps = [(try need("go"), ["run", try write("main.go")])]
        case "rust":
            let src = try write("main.rs")
            steps = [(try need("rustc"), ["--edition", "2021", "-O", src, "-o", dir.appendingPathComponent("main").path]), (dir.appendingPathComponent("main").path, [])]
        case "ruby": steps = [(try need("ruby"), [try write("main.rb")])]
        case "zig":   // built in the scratch dir (its .zig-cache stays there), run in the lesson's folder
            let src = try write("main.zig"), bin = dir.appendingPathComponent("main").path
            steps = [(try need("zig"), ["build-exe", src, "-femit-bin=" + bin]), (bin, [])]
        case "bash": steps = [("/bin/zsh", [try write("main.sh")])]
        case "java":
            let cls = code.range(of: #"public\s+class\s+(\w+)"#, options: .regularExpression)
                .map { String(code[$0]).components(separatedBy: .whitespaces).last ?? "Main" } ?? "Main"
            steps = [(try need("java"), [try write("\(cls).java")])]
        default: throw ToolError("Unsupported language: \(language)")
        }
        var output = ""
        let start = Date()
        for (i, step) in steps.enumerated() {
            let isLast = i == steps.count - 1
            let cwd = isLast ? (workingDirectory ?? dir) : dir
            let r = await ProcessRunner.run(step.0, step.1, cwd: cwd, stdin: isLast ? stdin : nil, timeout: timeout, onOutput: isLast ? progress : nil)
            if !isLast {
                if r.exitCode != 0 { return RunResult(text: "Compilation failed:\n" + truncateMiddle(r.combined, max: 20_000), failed: true) }
                continue
            }
            output = truncateMiddle(r.combined, max: 30_000)
            let elapsed = String(format: "%.2f s", Date().timeIntervalSince(start))
            if r.timedOut { return RunResult(text: output + "\n[timed out after \(Int(timeout)) s]", failed: true) }
            return RunResult(text: (output.isEmpty ? "(no output)" : output) + "\n[exit \(r.exitCode) · \(elapsed)]", failed: r.exitCode != 0)
        }
        return RunResult(text: output, failed: false)
    }
}

extension String {
    var shellQuoted: String { "'" + replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
