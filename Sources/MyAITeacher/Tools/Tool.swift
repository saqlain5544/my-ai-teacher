import Foundation

enum ToolRisk: String, Sendable {
    case readOnly      // never needs approval
    case network       // reads the web
    case write         // modifies files
    case execute       // runs programs
    case interactive   // waits for the learner (quiz, questions)
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
}

extension Tool {
    var spec: ToolSpec { ToolSpec(name: name, description: description, schema: schema) }
    func timeout(_ input: JSON) -> Double? {
        switch risk {
        case .interactive: nil
        case .readOnly, .network: 60
        case .write: 120
        case .execute: 330      // processes carry their own (shorter) timeouts; this is the backstop
        }
    }
    /// Runs the tool under its timeout.
    func runBounded(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let limit = timeout(input) else { return try await run(input, ctx) }
        let tool = self
        return try await withDeadline(seconds: limit) { try await tool.run(input, ctx) }
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
        if data.count < limit { data.append(d.prefix(limit - data.count)); dropped += max(0, d.count - (limit - data.count)) }
        else { dropped += d.count }
    }
    var string: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

enum ProcessRunner {
    static func run(_ executable: String, _ args: [String], cwd: URL? = nil, env: [String: String]? = nil,
                    stdin: String? = nil, timeout: TimeInterval = 120, outputLimit: Int = 2_000_000,
                    onOutput: (@Sendable (String) -> Void)? = nil) async -> ProcessResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        if let cwd { p.currentDirectoryURL = cwd }
        var environment = env ?? ShellEnvironment.shared.all
        environment["TERM"] = "dumb"
        environment["NO_COLOR"] = "1"
        environment["PAGER"] = "cat"
        environment["GIT_PAGER"] = "cat"
        p.environment = environment
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        let inPipe = Pipe()
        p.standardInput = inPipe
        let out = OutputCollector(limit: outputLimit), err = OutputCollector(limit: outputLimit / 4)
        outPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            out.append(d)
            onOutput?(String(decoding: d, as: UTF8.self))
        }
        errPipe.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            err.append(d)
            onOutput?(String(decoding: d, as: UTF8.self))
        }
        let timedOut = TimeoutFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<ProcessResult, Never>) in
                p.terminationHandler = { proc in
                    // Drain remaining output.
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    var o = out.string
                    if out.dropped > 0 { o += "\n… [\(out.dropped) bytes of output dropped]" }
                    c.resume(returning: ProcessResult(stdout: o, stderr: err.string, exitCode: proc.terminationStatus, timedOut: timedOut.value))
                }
                do {
                    try p.run()
                } catch {
                    c.resume(returning: ProcessResult(stdout: "", stderr: "Failed to launch \(executable): \(error.localizedDescription)", exitCode: -1, timedOut: false))
                    return
                }
                if let stdin { inPipe.fileHandleForWriting.write(Data(stdin.utf8)) }
                try? inPipe.fileHandleForWriting.close()
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
                    if p.isRunning { timedOut.value = true; p.interrupt(); p.terminate()
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if p.isRunning { kill(p.processIdentifier, SIGKILL) } }
                    }
                }
            }
        } onCancel: {
            if p.isRunning { p.terminate() }
        }
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
