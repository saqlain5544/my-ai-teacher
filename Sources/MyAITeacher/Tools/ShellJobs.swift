import Foundation
import Darwin

/// A shell command running in its own process group. Everything it starts (npm's node, a server's workers, a `cmd &`)
/// is in that group, so stopping it ends all of it, and the job counts as running while any of it is: a shell's child
/// holding the output pipe open no longer leaves the call waiting for an end that never comes.
final class ShellJob: @unchecked Sendable {
    let command: String
    let title: String
    let conversationID: String
    let started = Date()
    let pid: pid_t

    private let lock = NSLock()
    private var tail = Data()           // the last `limit` bytes of output
    private var total = 0               // bytes ever received
    private var cursor = 0              // `total` when the agent last read
    private var leaderExit: Int32?
    private var leaderExitedAt: Date?
    private var eof = false
    private var _handle: String?
    private var _urls: [String] = []
    private var urlSeenAt: Date?
    private var lastOutputAt = Date()
    private var _stopped = false
    private var _toBackground = false
    private let limit = 1_000_000
    /// Live output while the call that started it is waiting (the tool card's progress); nil once it is backgrounded.
    var onOutput: (@Sendable (String) -> Void)? {
        get { lock.lock(); defer { lock.unlock() }; return _onOutput }
        set { lock.lock(); _onOutput = newValue; lock.unlock() }
    }
    private var _onOutput: (@Sendable (String) -> Void)?

    /// Starts `shell -c script` in `cwd`, with stdin from /dev/null and stdout+stderr on one pipe.
    init(command: String, title: String, conversationID: String, shell: String, script: String, cwd: URL, env: [String: String]) throws {
        self.command = command
        self.title = title
        self.conversationID = conversationID
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw ToolError("Couldn't create a pipe for the command.") }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_addopen(&fa, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 1)
        posix_spawn_file_actions_adddup2(&fa, fds[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, cwd.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)   // its own group: pgid = pid
        var noSignals = sigset_t(), defaults = sigset_t()
        sigemptyset(&noSignals); sigemptyset(&defaults)
        for s in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        // CLOEXEC_DEFAULT: the child gets 0, 1 and 2 only, none of the app's descriptors (databases, sockets).
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = [strdup(shell), strdup("-c"), strdup(script), nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, shell, &fa, &attr, argv, envp)
        close(fds[1])
        guard rc == 0 else { close(fds[0]); throw ToolError("Couldn't start \(shell): \(String(cString: strerror(rc))).") }
        pid = child
        let readFD = fds[0]
        Thread.detachNewThread { [self] in
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(readFD, &buf, buf.count)
                if n > 0 { received(Data(buf[0..<n])) }
                else if n < 0 && errno == EINTR { continue }
                else { break }
            }
            close(readFD)
            lock.lock(); eof = true; lock.unlock()
        }
        Thread.detachNewThread { [self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            let sig = status & 0x7f
            lock.lock(); leaderExit = sig == 0 ? (status >> 8) & 0xff : 128 + sig; leaderExitedAt = Date(); lock.unlock()
        }
    }

    private func received(_ d: Data) {
        let text = String(decoding: d, as: UTF8.self)
        lock.lock()
        tail.append(d)
        if tail.count > limit { tail.removeFirst(tail.count - limit) }
        total += d.count
        lastOutputAt = Date()
        for u in ShellJob.localURLs(in: text) where !_urls.contains(u) { _urls.append(u); urlSeenAt = urlSeenAt ?? Date() }
        let live = _onOutput
        lock.unlock()
        live?(text)
    }

    // MARK: State

    var handle: String? { get { lock.lock(); defer { lock.unlock() }; return _handle } set { lock.lock(); _handle = newValue; lock.unlock() } }
    var urls: [String] { lock.lock(); defer { lock.unlock() }; return _urls }
    var stopped: Bool { lock.lock(); defer { lock.unlock() }; return _stopped }
    /// Whether anything of the job is still alive: its group has members, or someone still holds the pipe.
    var isRunning: Bool {
        lock.lock(); let open = !eof, leaderDone = leaderExit != nil; lock.unlock()
        return !leaderDone || open || kill(-pid, 0) == 0
    }
    /// The shell's own exit status, once it has exited.
    var exitCode: Int32? { lock.lock(); defer { lock.unlock() }; return leaderExit }
    var seconds: Int { Int(Date().timeIntervalSince(started)) }
    fileprivate var timings: (leaderExitedAt: Date?, urlSeenAt: Date?, lastOutputAt: Date, eof: Bool) {
        lock.lock(); defer { lock.unlock() }; return (leaderExitedAt, urlSeenAt, lastOutputAt, eof)
    }

    /// All the output kept (the last megabyte), ANSI codes removed.
    var output: String {
        lock.lock(); defer { lock.unlock() }
        let dropped = total - tail.count
        return (dropped > 0 ? "… [\(dropped) earlier bytes not kept]\n" : "") + ShellJob.plain(String(decoding: tail, as: UTF8.self))
    }
    /// Output since the agent's last read, and the read moves on.
    func readNew() -> String {
        lock.lock(); defer { lock.unlock() }
        let fresh = total - cursor
        cursor = total
        guard fresh > 0 else { return "" }
        let kept = min(fresh, tail.count)
        let text = ShellJob.plain(String(decoding: tail.suffix(kept), as: UTF8.self))
        return (fresh > kept ? "… [\(fresh - kept) bytes not kept]\n" : "") + text
    }
    func markRead() { lock.lock(); cursor = total; lock.unlock() }

    /// The learner pressed Background on the running card: the waiting call returns and the job carries on.
    func moveToBackground() { lock.lock(); _toBackground = true; lock.unlock() }
    private var toBackground: Bool { lock.lock(); defer { lock.unlock() }; return _toBackground }

    /// Ends the whole group: SIGTERM, then SIGKILL two seconds later to whatever is left.
    func stop() {
        lock.lock(); _stopped = true; lock.unlock()
        kill(-pid, SIGTERM); kill(pid, SIGTERM)
        let pid = self.pid
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(-pid, 0) == 0 { kill(-pid, SIGKILL) } }
    }

    /// Waits until the job ends, the time is up, or it shows itself to be a server or a process left running.
    func wait(timeout: TimeInterval, mode: WaitMode) async -> WaitOutcome {
        let deadline = started.addingTimeInterval(timeout)
        let serverLike = ShellJob.looksLikeServer(command)
        while true {
            if Task.isCancelled { return .cancelled }
            if toBackground { return .learner }
            let t = timings, now = Date()
            if let exited = t.leaderExitedAt {
                if t.eof && kill(-pid, 0) != 0 { return .finished }
                // The shell is done but something it started holds on (`cmd &`, a daemon): that keeps running on its own.
                if now.timeIntervalSince(exited) > 1.5 { return .left }
            }
            if mode != .foreground {
                if let seen = t.urlSeenAt, now.timeIntervalSince(seen) > 1.5 { return .server }
                let settle: TimeInterval = mode == .background ? 4 : 12
                if (mode == .background || serverLike), now.timeIntervalSince(started) > settle,
                   now.timeIntervalSince(t.lastOutputAt) > 1 || now.timeIntervalSince(started) > settle * 2 {
                    return serverLike || !urls.isEmpty ? .server : .background
                }
            }
            if now >= deadline { return .timedOut }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    enum WaitMode { case foreground, auto, background }
    enum WaitOutcome { case finished, timedOut, cancelled, server, left, background, learner }

    // MARK: Recognising servers

    /// Commands that serve or watch until stopped. A guess from the command alone: a printed local URL is the other sign.
    static func looksLikeServer(_ command: String) -> Bool {
        command.range(of: serverPattern, options: [.regularExpression, .caseInsensitive]) != nil
    }
    static let serverPattern = #"\b(npm|pnpm|yarn|bun)\s+(run\s+)?(dev|start|serve|preview|watch)\b|\bnpx\s+(serve|http-server|live-server|vite(?!\s+build))\b|\bnext\s+(dev|start)\b|\bvite(\s+(dev|serve|preview))?\s*($|[;&|])|\b(nodemon|live-server|http-server|browser-sync)\b|\bhttp\.server\b|\bmanage\.py\s+runserver\b|\bflask\s+run\b|\b(uvicorn|gunicorn|hypercorn)\b|\brails\s+s(erver)?\b|\b(hugo|zola)\s+serve(r)?\b|\bjekyll\s+serve\b|\bphp\s+-S\b|\bdocker[\s-]compose\s+up\b(?!.*\s-d\b)|\btail\s+-[fF]\b|\b(cargo\s+watch|watchexec)\b|\bswift\s+run\b.*\bserve\b|--watch\b"#

    /// http://localhost:5173/ and the like, and "listening on port 3000".
    static func localURLs(in text: String) -> [String] {
        let s = plain(text)
        var out: [String] = []
        let ns = s as NSString
        let full = try! NSRegularExpression(pattern: #"https?://(localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1?\]|[a-z0-9-]+\.local)(:\d{2,5})?(/[^\s'"\)\]>]*)?"#, options: [.caseInsensitive])
        for m in full.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out.append(ns.substring(with: m.range).replacingOccurrences(of: "0.0.0.0", with: "localhost").trimmingCharacters(in: CharacterSet(charactersIn: ".,;")))
        }
        if out.isEmpty {
            let port = try! NSRegularExpression(pattern: #"(listening|running|serving|started|available)\b[^\n]{0,40}?\b(port|:)\s*(\d{2,5})\b"#, options: [.caseInsensitive])
            for m in port.matches(in: s, range: NSRange(location: 0, length: ns.length)) { out.append("http://localhost:\(ns.substring(with: m.range(at: 3)))") }
        }
        return out
    }

    /// Without terminal colour and cursor codes, and with carriage-return redraws reduced to their last state.
    static func plain(_ s: String) -> String {
        var t = s.replacingOccurrences(of: #"\u001B\[[0-9;?]*[ -/]*[@-~]|\u001B[()][A-Z0-9]|\u001B[=>]"#, with: "", options: .regularExpression)
        if t.contains("\r") {
            t = t.split(separator: "\n", omittingEmptySubsequences: false)
                .map { line in line.split(separator: "\r", omittingEmptySubsequences: false).last(where: { !$0.isEmpty }).map(String.init) ?? "" }
                .joined(separator: "\n")
        }
        return t
    }
}

/// The lesson's background commands (B1, B2…): servers and watchers the agent started, still running for it to read,
/// and stopped when the lesson is deleted or the app quits.
final class ShellJobs: @unchecked Sendable {
    static let shared = ShellJobs()
    private let lock = NSLock()
    private var jobs: [String: [String: ShellJob]] = [:]
    private var counters: [String: Int] = [:]
    /// Commands a call is still waiting on, by tool call id (the card's Background button finds them here).
    private var waiting: [String: ShellJob] = [:]

    init() {
        NotificationCenter.default.addObserver(forName: NSNotification.Name("NSApplicationWillTerminateNotification"), object: nil, queue: nil) { _ in
            ShellJobs.shared.stopEverything()
        }
    }

    /// Keeps a job that outlived its call, under the lesson's next handle.
    @discardableResult
    func adopt(_ job: ShellJob) -> String {
        lock.lock(); defer { lock.unlock() }
        if let h = job.handle { return h }
        counters[job.conversationID, default: 0] += 1
        let h = "B\(counters[job.conversationID]!)"
        job.handle = h
        jobs[job.conversationID, default: [:]][h] = job
        return h
    }
    func waitingOn(_ callID: String, _ job: ShellJob?) { lock.lock(); waiting[callID] = job; lock.unlock() }
    /// Background for a running call's command; false when it has already finished.
    @discardableResult
    func moveToBackground(callID: String) -> Bool {
        lock.lock(); let j = waiting[callID]; lock.unlock()
        j?.moveToBackground()
        return j != nil
    }

    func job(_ conv: String, _ handle: String) -> ShellJob? {
        lock.lock(); defer { lock.unlock() }
        return jobs[conv]?[handle.uppercased()]
    }
    func list(_ conv: String) -> [ShellJob] {
        lock.lock(); defer { lock.unlock() }
        return (jobs[conv] ?? [:]).values.sorted { $0.started < $1.started }
    }
    func forget(_ conv: String, _ handle: String) {
        lock.lock(); jobs[conv]?[handle] = nil; lock.unlock()
    }
    func stopAll(_ conv: String) {
        lock.lock(); let js = (jobs[conv] ?? [:]).values; jobs[conv] = nil; lock.unlock()
        js.forEach { $0.stop() }
    }
    func stopEverything() {
        lock.lock(); let js = jobs.values.flatMap(\.values); jobs = [:]; lock.unlock()
        js.forEach { $0.stop() }
    }

    /// One line per background job, for the end of every shell result: the agent always knows what it left running.
    func summary(_ conv: String, except: String? = nil) -> String {
        let lines = list(conv).filter { $0.handle != except }.map(Self.line)
        return lines.isEmpty ? "" : "Background jobs: " + lines.joined(separator: "; ") + "."
    }
    static func line(_ j: ShellJob) -> String {
        let state = j.isRunning ? "running \(j.seconds) s" : "exited \(j.exitCode.map(String.init) ?? "?")"
        return "\(j.handle ?? "?") `\(j.command.prefix(60))` \(state)" + (j.urls.isEmpty ? "" : " at \(j.urls[0])")
    }
}
