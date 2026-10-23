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
    Prefer the dedicated read/edit/glob/grep tools for files. Never run destructive commands without the learner's explicit request.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "command": Schema.string("The command to run."),
            "timeout": Schema.integer("Timeout in seconds (default 120, max 600)."),
            "description": Schema.string("5-10 word description of what the command does."),
        ], required: ["command"])
    }
    func summary(_ input: JSON) -> String { input["command"]?.string ?? "" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let command = try input.req("command")
        let timeout = TimeInterval(min(600, max(1, input["timeout"]?.int ?? 120)))
        let session = ctx.shellID ?? ctx.conversationID
        let cwd = await ShellState.shared.dir(session, default: ctx.workspace)
        let cwdFile = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-cwd-\(UUID().uuidString)")
        let script = "trap 'pwd > \(cwdFile.path.shellQuoted)' EXIT\n\(command)"
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let progress = ctx.progress
        let r = await ProcessRunner.run(shell, ["-c", script], cwd: cwd, timeout: timeout, onOutput: { progress($0) })
        if let newDir = try? String(contentsOf: cwdFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines), !newDir.isEmpty {
            await ShellState.shared.set(session, URL(fileURLWithPath: newDir))
        }
        try? FileManager.default.removeItem(at: cwdFile)
        var text = truncateMiddle(r.combined, max: 30_000)
        if text.isEmpty { text = "(no output)" }
        if r.timedOut { text += "\n[timed out after \(Int(timeout)) s]" }
        if r.exitCode != 0 { text += "\n[exit code \(r.exitCode)]" }
        return ToolOutput(text: text, isError: r.exitCode != 0 && !r.timedOut ? false : r.timedOut, meta: ["exit": .number(Double(r.exitCode))])
    }
}

/// Runs a self-contained snippet in a scratch directory. Used by the tutor and by "Run" buttons on code blocks.
struct RunCodeTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { Double(min(300, input["timeout"]?.int ?? 30)) + 60 }   // + compile time
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
                                       stdin: input["stdin"]?.string, timeout: TimeInterval(min(300, input["timeout"]?.int ?? 30)),
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
