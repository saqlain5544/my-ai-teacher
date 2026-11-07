import Foundation
import Darwin

/// The lldb driver (`DebugDriver`) as a child process: JSON commands in on stdin, `@@DBG@@` replies out on stdout. It runs
/// under the current `WriteFence` (the sandbox is inherited by debugserver and by the program it launches), so a debugged
/// program can't write what a `bash` command couldn't.
final class DebugProcess: @unchecked Sendable {
    private let process = Process()
    private let input = Pipe(), output = Pipe(), errors = Pipe()
    private let lock = NSLock()
    private var queue: [JSON] = []
    private var partial = Data()
    private var errTail = Data()
    private var sent = 0
    private let ended = Locked(false)
    private let writer: FileHandle
    /// The program being debugged (set from the first reply that names it), so ending the session can't leave it running.
    private(set) var inferior: Int32 = 0

    init(driver: URL, lldbPython: String, cwd: URL) throws {
        writer = input.fileHandleForWriting
        let (exe, args) = WriteFence.wrap("/usr/bin/python3", ["-I", driver.path, lldbPython])
        process.executableURL = URL(fileURLWithPath: exe)
        process.arguments = args
        process.currentDirectoryURL = cwd
        var env = ProcessRunner.environment()
        env["PYTHONDONTWRITEBYTECODE"] = "1"
        process.environment = env
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.received(d)
        }
        errors.fileHandleForReading.readabilityHandler = { [weak self] h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; return }
            self?.lock.withLock { self?.errTail.append(d); if let n = self?.errTail.count, n > 8000 { self?.errTail.removeFirst(n - 8000) } }
        }
        _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
        process.terminationHandler = { [ended] _ in ended.mutate { $0 = true } }
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { !ended.get() }
    var exitStatus: Int32 { isRunning ? -1 : process.terminationStatus }
    var stderrTail: String { lock.withLock { String(decoding: errTail, as: UTF8.self) } }

    private func received(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        partial.append(d)
        while let nl = partial.firstIndex(of: 0x0A) {
            let line = partial[partial.startIndex..<nl]
            partial.removeSubrange(partial.startIndex...nl)
            let marker = Data("@@DBG@@".utf8)
            guard line.starts(with: marker), let j = JSON.parse(Data(line.dropFirst(marker.count))) else { continue }
            if let p = j["pid"]?.int, p > 0 { inferior = Int32(p) }
            queue.append(j)
        }
    }

    func send(_ cmd: JSON) {
        sent += 1
        var o = cmd.object ?? [:]
        o["id"] = .number(Double(sent))
        try? writer.write(contentsOf: Data((JSON.object(o).compact + "\n").utf8))
    }

    /// The next reply, or nil when none came in `timeout` seconds, the driver died, or the call was cancelled.
    func next(timeout: TimeInterval) async -> JSON? {
        let until = Date().addingTimeInterval(timeout)
        while !Task.isCancelled {
            if let j = lock.withLock({ () -> JSON? in queue.isEmpty ? Optional<JSON>.none : queue.removeFirst() }) { return j }
            if !isRunning {
                try? await Task.sleep(for: .milliseconds(50))   // its last words may still be in the pipe
                return lock.withLock { () -> JSON? in queue.isEmpty ? Optional<JSON>.none : queue.removeFirst() }
            }
            if Date() >= until { return nil }
            try? await Task.sleep(for: .milliseconds(15))
        }
        return nil
    }

    /// Ends the driver and everything under it at once (Stop, quit, a stuck reply): no graceful goodbye.
    func killNow(wait: Bool = false) {
        let pid = process.processIdentifier
        guard pid > 0 else { return }
        output.fileHandleForReading.readabilityHandler = nil
        errors.fileHandleForReading.readabilityHandler = nil
        // At once and without a subprocess: the program, and the driver frozen so it starts nothing new. Finding what else is under
        // it (debugserver) takes `pgrep` per level, so that happens off the caller's thread; the driver is killed last, because
        // its children would otherwise be handed to launchd and could no longer be found.
        let program = inferior
        if program > 0 { kill(program, SIGKILL) }
        if isRunning { kill(pid, SIGSTOP) }
        let sweep = { @Sendable in
            for q in Self.descendants(of: pid) { kill(q, SIGKILL) }
            if program > 0 { kill(program, SIGKILL) }
            kill(pid, SIGKILL)
        }
        if wait { sweep() } else { DispatchQueue.global(qos: .userInitiated).async(execute: sweep) }
    }

    /// Asks the driver to kill the program and leave; whatever is left after a second is killed.
    func end() async {
        if isRunning {
            send(["cmd": "stop"])
            for _ in 0..<60 where isRunning { try? await Task.sleep(for: .milliseconds(25)) }
        }
        killNow()
    }

    static func descendants(of root: Int32) -> [Int32] {
        var all: [Int32] = [], frontier = [root]
        for _ in 0..<6 where !frontier.isEmpty {
            frontier = frontier.flatMap(children)
            all = frontier + all
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
}

/// One debugging session: the driver, the program, and everything shown so far (the stepper card is the whole history).
final class DebugSession: @unchecked Sendable {
    let conversationID: String
    let proc: DebugProcess
    let tmp: URL
    let program: String
    let fence: String
    /// A scratch folder holding a single-file build, removed with the session.
    let scratch: URL?
    let started = Date()
    var lastKind = ""
    var exitCode = 0
    var lastUsed = Date()
    var busy = false
    var steps: [JSON] = []
    var files: [String: String] = [:]
    var output = ""
    var stops = 0
    var breakpoints: [JSON] = []
    var exited = false

    static let stepLimit = 80

    init(conversationID: String, proc: DebugProcess, tmp: URL, program: String, fence: String, scratch: URL? = nil) {
        self.conversationID = conversationID; self.proc = proc; self.tmp = tmp; self.program = program; self.fence = fence; self.scratch = scratch
    }

    /// One command and its reply. `seconds` is the program's wall-time budget; the driver gets a few more to answer.
    func request(_ cmd: [String: JSON], seconds: Double, grace: Double = 8) async -> JSON {
        guard !busy else { return ["ok": false, "error": "the debugger is still working on the previous command"] }
        busy = true; defer { busy = false; lastUsed = Date() }
        var c = cmd
        c["seconds"] = .number(seconds)
        proc.send(.object(c))
        guard let r = await proc.next(timeout: seconds + grace) else {
            let why = proc.isRunning ? "did not answer within \(Int(seconds + grace)) s" : "ended unexpectedly"
            let tail = proc.stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
            proc.killNow()
            return ["ok": false, "dead": true, "error": .string("The debugger \(why); it was stopped with the program." + (tail.isEmpty ? "" : "\n" + truncateMiddle(tail, max: 800)))]
        }
        if let f = r["files"]?.object { for (k, v) in f { files[k] = v.string ?? "" } }
        return r
    }

    /// Ends the driver and the program and removes the scratch folder.
    func end() async {
        await proc.end()
        removeFolders()
    }
    /// `wait`: the app is quitting, so the tree is walked and killed before returning.
    func killNow(wait: Bool = false) {
        proc.killNow(wait: wait)
        removeFolders()
    }
    private func removeFolders() {
        try? FileManager.default.removeItem(at: tmp)
        if let scratch { try? FileManager.default.removeItem(at: scratch) }
    }
}

/// The lesson's debugging session (at most one each), ended on Stop, when the lesson is deleted and when the app quits.
final class DebugSessions: @unchecked Sendable {
    static let shared = DebugSessions()
    private let lock = NSLock()
    private var byConversation: [String: DebugSession] = [:]
    /// A session nobody has touched for this long ends the next time any debugging starts (nothing runs a timer for it).
    static let idleSeconds: TimeInterval = 15 * 60

    init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil) { _ in
            DebugSessions.shared.killAll()
        }
    }

    func session(_ conv: String) -> DebugSession? { lock.withLock { byConversation[conv] } }
    /// Registers `s` and returns the session it replaced, if any.
    func set(_ s: DebugSession) -> DebugSession? { lock.withLock { let old = byConversation[s.conversationID]; byConversation[s.conversationID] = s; return old } }
    func remove(_ s: DebugSession) { lock.withLock { if byConversation[s.conversationID] === s { byConversation[s.conversationID] = nil } } }
    var count: Int { lock.withLock { byConversation.count } }

    /// Stop, a deleted lesson: the program and its debugger end now.
    func end(_ conv: String) {
        guard let s = lock.withLock({ byConversation.removeValue(forKey: conv) }) else { return }
        s.killNow()
    }
    func reapIdle() {
        let old = lock.withLock { byConversation.values.filter { Date().timeIntervalSince($0.lastUsed) > Self.idleSeconds && !$0.busy } }
        for s in old { remove(s); s.killNow() }
    }
    func killAll() {
        let all = lock.withLock { let v = Array(byConversation.values); byConversation = [:]; return v }
        for s in all { s.killNow(wait: true) }
    }
}
