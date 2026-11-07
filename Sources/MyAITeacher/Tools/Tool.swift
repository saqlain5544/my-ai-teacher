import Foundation

enum ToolRisk: String, Sendable {
    case readOnly      // never needs approval
    case network       // reads the web
    case write         // modifies files
    case execute       // runs programs
    case interactive   // waits for the learner (quiz, questions)
    case control       // drives the browser or the Mac; gated per site / app by ComputerUseExtension, never parallel
}

struct ToolOutput: Sendable {
    var text: String
    var isError = false
    var images: [Block] = []
    var meta: JSON?

    static func error(_ s: String) -> ToolOutput { ToolOutput(text: s, isError: true) }
}

struct ToolError: LocalizedError { let message: String; var errorDescription: String? { message }
    init(_ m: String) { message = m } }

/// Everything a tool may need at run time.
struct ToolContext: Sendable {
    let conversationID: String
    let workspace: URL
    let services: Services
    let interactions: InteractionCenter
    let toolCallID: String
    /// The model driving this conversation (used by sub-agents).
    let client: LLMClient
    let model: String
    /// Lets long-running tools stream progress text into their card.
    let progress: @Sendable (String) -> Void
    /// Models the lesson may hand to a sub-agent (the provider's fetched list; free-only when the lesson is free).
    var subAgentModels: [String] = []
    /// Other providers, limits and the lesson's grants for sub-agents; nil runs them on the lesson's client with defaults.
    var agentHost: AgentHost? = nil
    /// 0 for the teacher; n inside a sub-agent n levels down.
    var agentDepth = 0
    /// Inside a sub-agent: what its own sub-agents may not exceed.
    var agentCeiling: AgentCeiling? = nil
    /// Inside a sub-agent on another provider: the provider of `client` (nil = the lesson's).
    var agentProvider: String? = nil
    /// The shell session `bash` keeps its working directory in (each sub-agent has its own); nil = the lesson's.
    var shellID: String? = nil
    /// Whether the lesson's model accepts images (screenshots are replaced by text trees when it doesn't).
    var vision = true
    /// Whether the learner wants to be tested (Settings `quizzes`, or a Quiz/Exam mode): graded questions are refused when not.
    var quizzes = true
    /// The agent's node in `AgentTree` (what it may load at runtime).
    var agentNode = "tutor"
    /// Code agent mode: files written or edited are syntax-checked at once, and `bash` may run in the background.
    var codeAgent = false
    /// The code agent's checkpoint key for this turn: sub-agents working in the lesson's folder back files up under it.
    var checkpointTurn: String? = nil
    /// The teacher's tool results the model is sent intact right now (set for `read`): a repeat read of an unchanged file
    /// may answer "unchanged" only when its earlier result is among them. Nil (sub-agents, the CLI): always the file.
    var liveResults: Set<String>? = nil
}

protocol Tool: Sendable {
    var name: String { get }
    var description: String { get }
    var schema: JSON { get }
    var risk: ToolRisk { get }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput
    /// One-line human summary, shown on the tool card and in approval prompts.
    func summary(_ input: JSON) -> String
    /// Hard limit for one call (seconds); nil = none (waits for the learner). Past it the call is abandoned and the
    /// model gets an error it can act on, so a stalled site or process never hangs the lesson.
    func timeout(_ input: JSON) -> Double?
    /// What a sub-agent gets of this tool: itself, a restricted variant (memory: search only), or nil (the default) when
    /// sub-agents can't have it — interactive and teaching tools, since a sub-agent can't wait for the learner.
    var subAgentVariant: Tool? { get }
}

extension Tool {
    var subAgentVariant: Tool? { nil }
    var spec: ToolSpec { ToolSpec(name: name, description: description, schema: schema) }
    func timeout(_ input: JSON) -> Double? {
        switch risk {
        case .interactive: nil
        case .readOnly, .network: 60
        case .write, .control: 120
        case .execute: 330      // processes carry their own (shorter) timeouts; this is the backstop
        }
    }
    /// Runs the tool under its timeout. The one place every model-started call passes through (the lesson's loop and the
    /// sub-agents' alike), so the learner's secrets are held back here: a URL or query that carries one is refused, the
    /// commands it starts run without the secret environment and without reading the credential folders, and a secret
    /// in the result is redacted before the model sees it (`meta.redacted` tells the card).
    func runBounded(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let sp = Signposts.begin("tool", name); defer { Signposts.end("tool", sp) }
        let input = ToolArgs.coerce(input, schema: schema)   // "[…]" strings for arrays, "3" for numbers…
        if let refused = Secrets.outbound(tool: name, input) ?? Secrets.introducesMarker(tool: name, input, workspace: ctx.workspace) { return .error(refused) }
        let tool = self
        // A file tool that names a credential location got here only because the learner (or the lesson's grant) allowed
        // it, so its own program (rg, grep) runs without the deny-read rules; no other call does.
        let approved = Secrets.credentialPathNamed(by: name, input, workspace: ctx.workspace) != nil
        let fence = approved ? WriteFence.profile : WriteFence.guarded(WriteFence.profile)
        var out: ToolOutput
        do {
            out = try await Secrets.$agentCall.withValue(true) {
                try await WriteFence.$profile.withValue(fence) {
                    guard let limit = tool.timeout(input) else { return try await tool.run(input, ctx) }
                    return try await withDeadline(seconds: limit) { try await tool.run(input, ctx) }
                }
            }
        } catch is CancellationError {
            throw CancellationError()
        } catch let e as TimeoutError {
            throw e
        } catch {
            // An error message can echo what it was given (an MCP server repeating a key): the model reads it, so it is redacted.
            let message = error.localizedDescription, r = Secrets.redact(message)
            if r.kinds.isEmpty { throw error }
            throw ToolError(r.text)
        }
        if let hint = Secrets.hint(for: out.text, folder: ctx.workspace), !out.text.contains(hint) { out.text += "\n" + hint }
        return Secrets.redacted(tool: name, out)
    }
    func summary(_ input: JSON) -> String {
        for k in ["command", "path", "file_path", "query", "url", "pattern", "title", "question", "concept", "action"] {
            if let s = input[k]?.string { return s }
        }
        return ""
    }
}

extension JSON {
    func req(_ key: String) throws -> String {
        guard let s = self[key]?.string, !s.isEmpty else { throw ToolError("Missing required parameter `\(key)`.") }
        return s
    }
}

/// Resolves a user/model supplied path against the workspace; expands ~.
func resolvePath(_ raw: String, workspace: URL) -> URL {
    var p = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    if p.hasPrefix("~") { p = (p as NSString).expandingTildeInPath }
    if p.hasPrefix("/") { return URL(fileURLWithPath: p).standardizedFileURL }
    return workspace.appendingPathComponent(p).standardizedFileURL
}

func truncateMiddle(_ s: String, max: Int) -> String {
    guard s.count > max else { return s }
    let head = s.prefix(max * 2 / 3), tail = s.suffix(max / 3)
    return "\(head)\n\n… [\(s.count - max) characters truncated] …\n\n\(tail)"
}

// MARK: - Process runner

struct ProcessResult: Sendable {
    var stdout: String
    var stderr: String
    var exitCode: Int32
    var timedOut: Bool
    var combined: String {
        var s = stdout
        if !stderr.isEmpty { s += (s.isEmpty ? "" : "\n") + stderr }
        return s
    }
}

final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    private(set) var dropped = 0
    init(limit: Int) { self.limit = limit }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        // Room is measured before appending (measured after, every byte of a chunk that filled the buffer counted as dropped).
        let room = max(0, limit - data.count)
        data.append(d.prefix(room))
        dropped += max(0, d.count - room)
    }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum ProcessRunner {
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil,
                    stdin: String? = nil, timeout: TimeInterval = 120, outputLimit: Int = 2_000_000,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> ProcessResult {
        let p = Process()
        var args = args
        // A shell the model asked for: scrubbed names unset inside it too (zsh -c re-sources ~/.zshenv).
        if Secrets.agentCall, args.count == 2, args[0] == "-c", ["zsh", "bash", "sh"].contains((executable as NSString).lastPathComponent) { args[1] = Secrets.shellScript(args[1]) }
        let (exe, argv) = WriteFence.wrap(executable, args)
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = argv
        if let cwd { p.currentDirectoryURL = cwd }
        p.environment = environment(env)
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = Pipe()
        p.standardInput = inPipe
        let out = OutputCollector(limit: outputLimit), err = OutputCollector(limit: outputLimit / 4)
        let closed = DispatchGroup()
        closed.enter(); closed.enter()
        let outLeft = Locked(false), errLeft = Locked(false)
        let leaveOut = { @Sendable in if outLeft.mutate({ was in defer { was = true }; return !was }) { closed.leave() } }
        let leaveErr = { @Sendable in if errLeft.mutate({ was in defer { was = true }; return !was }) { closed.leave() } }
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; leaveOut(); return }
            out.append(d)
            onOutput?(String(decoding: d, as: UTF8.self))
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; leaveErr(); return }
            err.append(d)
            onOutput?(String(decoding: d, as: UTF8.self))
        }
        let timedOut = TimeoutFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ProcessResult, Never>) in
                p.terminationHandler = { proc in
                    // The rest of the output, for as long as the pipes take to close. A child the program left running
                    // (a server it started) holds them open: reading to the end waited for it forever.
                    let lingering = closed.wait(timeout: .now() + 1.5) == .timedOut
                    if lingering {
                        outPipe.fileHandleForReading.readabilityHandler = nil; leaveOut()
                        errPipe.fileHandleForReading.readabilityHandler = nil; leaveErr()
                    }
                    var o = out.string
                    if lingering { o += "\n[a process it started is still running; its output is not shown]" }
                    if out.dropped > 0 { o += "\n… [\(out.dropped) bytes of output dropped]" }
                    c.resume(returning: ProcessResult(stdout: o, stderr: err.string, exitCode: proc.terminationStatus, timedOut: timedOut.value))
                }
                do {
                    try p.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil; leaveOut()
                    errPipe.fileHandleForReading.readabilityHandler = nil; leaveErr()
                    c.resume(returning: ProcessResult(stdout: "", stderr: "Failed to launch \(executable): \(error.localizedDescription)", exitCode: -1, timedOut: false))
                    return
                }
                // Cancelled before the launch (Stop right after a background start): the handler had nothing to end.
                if Task.isCancelled { endTree(p) }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { timedOut.value = true; p.interrupt(); endTree(p) }
                }
                // A program that exits without reading its input (a hook running a formatter) closes the pipe: writing
                // then fails instead of raising SIGPIPE, which would end the app. The write is off this thread: input
                // larger than the pipe's buffer, to a program that never reads it, blocks until the timeout ends it.
                let writer = inPipe.fileHandleForWriting
                if let stdin {
                    _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
                    DispatchQueue.global().async { try? writer.write(contentsOf: Data(stdin.utf8)); try? writer.close() }
                } else {
                    try? writer.close()
                }
            }
        } onCancel: {
            if p.isRunning { endTree(p) }
        }
    }

    /// Ends a process and what it started: SIGTERM to the tree, SIGKILL two seconds later to what is left. A program's
    /// children (`node` under `npm`, a compiled binary under `go run`) otherwise outlive it.
    static func endTree(_ p: Process) {
        let pid = p.processIdentifier
        let tree = descendants(of: pid) + [pid]
        for q in tree { kill(q, SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { for q in tree where kill(q, 0) == 0 { kill(q, SIGKILL) } }
    }
    private static func descendants(of root: Int32) -> [Int32] {
        var all: [Int32] = [], frontier = [root]
        for _ in 0..<6 where !frontier.isEmpty {   // a shell, its script, their children…
            frontier = frontier.flatMap(children)
            all = frontier + all                   // deepest first
        }
        return all
    }
    private static func children(of pid: Int32) -> [Int32] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-P", String(pid)]
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [] }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0.trimmingCharacters(in: .whitespaces)) }
    }

    /// The learner's shell environment, made for output read by a model: no colours, pagers or prompts.
    /// Inside a tool call the model started, the login shell's variables come without the learner's secrets
    /// (`Secrets.scrub`); a caller that passes its own `base` (hooks) or `scrub: false` (MCP servers) gets what it asks for.
    static func environment(_ base: [String: String]? = nil, scrub: Bool? = nil) -> [String: String] {
        var e = base ?? ShellEnvironment.shared.all
        if scrub ?? (base == nil && Secrets.agentCall) { e = Secrets.scrub(e) }
        e["TERM"] = "dumb"
        e["NO_COLOR"] = "1"
        e["FORCE_COLOR"] = "0"
        e["PAGER"] = "cat"
        e["GIT_PAGER"] = "cat"
        e["CI"] = e["CI"] ?? "1"          // dev servers and test runners skip interactive prompts and keypress menus
        e["BROWSER"] = "none"             // `npm start` and friends don't open the learner's browser
        e["PYTHONUNBUFFERED"] = "1"       // a Python server's "Serving on…" line arrives when printed, not at exit
        return e
    }

    /// Finds an executable on the user's PATH.
    static func which(_ name: String) -> String? {
        let path = ShellEnvironment.shared.get("PATH") ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = ["/opt/homebrew/bin", "/usr/local/bin", "\(NSHomeDirectory())/.cargo/bin", "\(NSHomeDirectory())/.bun/bin", "/usr/local/go/bin"]
        for dir in path.split(separator: ":").map(String.init) + extra {
            let candidate = (dir as NSString).appendingPathComponent(name)
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }
}

final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var v = false
    var value: Bool {
        get { lock.lock(); defer { lock.unlock() }; return v }
        set { lock.lock(); v = newValue; lock.unlock() }
    }
}
