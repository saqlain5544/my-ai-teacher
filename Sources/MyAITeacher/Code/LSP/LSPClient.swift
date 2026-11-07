import Foundation
import Darwin

struct LSPError: LocalizedError, Sendable {
    enum Kind: Sendable { case closed, timeout, server(Int), other }
    let message: String
    var kind: Kind = .other
    init(_ m: String, kind: Kind = .other) { message = m; self.kind = kind }
    var errorDescription: String? { message }
    /// ContentModified / ServerCancelled / RequestCancelled: the server wasn't ready for that request; asking again works.
    var isTransient: Bool { if case .server(let c) = kind { return c == -32801 || c == -32802 || c == -32800 }; return false }
    var isClosed: Bool { if case .closed = kind { return true }; return false }
}

/// A language server as a child process, speaking `Content-Length`-framed JSON-RPC on stdin/stdout (LSP's base protocol).
/// Its own process group (ending it ends what it started: cargo, go, node), only fds 0-2 inherited, stderr kept in `log`.
final class LSPStdioTransport: @unchecked Sendable {
    let executable: String, args: [String], env: [String: String], cwd: URL
    let log: MCPLog
    private let lock = NSLock()
    private var input: Int32 = -1
    private var _pid: pid_t = 0
    private var closing = false
    private let writes = DispatchQueue(label: "lsp.stdin")

    init(executable: String, args: [String], env: [String: String], cwd: URL, log: MCPLog) {
        self.executable = executable; self.args = args; self.env = env; self.cwd = cwd; self.log = log
    }
    var pid: pid_t { lock.withLock { _pid } }

    /// Starts the child. `receive` gets every message; `closed` is called once, with why, after the output ended and the
    /// process exited (so no last message is lost).
    func open(receive: @escaping @Sendable (JSON) -> Void, closed: @escaping @Sendable (String) -> Void) throws {
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0], errP: [Int32] = [0, 0]
        guard pipe(&inP) == 0, pipe(&outP) == 0, pipe(&errP) == 0 else { throw LSPError("Couldn't create pipes for the language server.") }
        var fa: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fa)
        defer { posix_spawn_file_actions_destroy(&fa) }
        posix_spawn_file_actions_adddup2(&fa, inP[0], 0)
        posix_spawn_file_actions_adddup2(&fa, outP[1], 1)
        posix_spawn_file_actions_adddup2(&fa, errP[1], 2)
        posix_spawn_file_actions_addchdir_np(&fa, cwd.path)
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        defer { posix_spawnattr_destroy(&attr) }
        posix_spawnattr_setpgroup(&attr, 0)
        var noSignals = sigset_t(), defaults = sigset_t()
        sigemptyset(&noSignals); sigemptyset(&defaults)
        for s in [SIGPIPE, SIGINT, SIGTERM, SIGHUP, SIGCHLD] { sigaddset(&defaults, s) }
        posix_spawnattr_setsigmask(&attr, &noSignals)
        posix_spawnattr_setsigdefault(&attr, &defaults)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &fa, &attr, argv, envp)
        Darwin.close(inP[0]); Darwin.close(outP[1]); Darwin.close(errP[1])
        guard rc == 0 else {
            Darwin.close(inP[1]); Darwin.close(outP[0]); Darwin.close(errP[0])
            throw LSPError("Couldn't start \(executable): \(String(cString: strerror(rc))).")
        }
        _ = fcntl(inP[1], F_SETNOSIGPIPE, 1)
        lock.withLock { input = inP[1]; _pid = child }
        log.note("started pid \(child): \(([executable] + args).joined(separator: " "))")

        let outFD = outP[0], errFD = errP[0], log = log
        let done = Locked((stdout: false, exit: Optional<String>.none))
        let finish = { @Sendable (update: (inout (stdout: Bool, exit: String?)) -> Void) in
            let reason = done.mutate { s -> String? in
                update(&s)
                guard s.stdout, let e = s.exit else { return nil }
                s.exit = nil
                return e
            }
            if let reason { closed(reason) }
        }
        Thread.detachNewThread {
            var parser = LSPFraming()
            var buf = [UInt8](repeating: 0, count: 65_536)
            while true {
                let n = read(outFD, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                parser.feed(Data(buf[0..<n]))
                while let m = parser.next() {
                    if let j = m.json { receive(j) } else { log.note("dropped a message that isn't JSON (\(m.size) bytes)") }
                }
                if let bad = parser.failure { log.note(bad); break }
            }
            Darwin.close(outFD)
            finish { $0.stdout = true }
        }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 16_384)
            while true {
                let n = read(errFD, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                log.append(Data(buf[0..<n]))
            }
            Darwin.close(errFD)
        }
        Thread.detachNewThread { [weak self] in
            var status: Int32 = 0
            while waitpid(child, &status, 0) < 0 && errno == EINTR {}
            self?.lock.withLock { if self?._pid == child { self?._pid = 0 } }
            let sig = status & 0x7f
            let why = sig == 0 ? "exited with status \((status >> 8) & 0xff)" : "was killed by signal \(sig)"
            log.note("pid \(child) \(why)")
            self?.closeInput()
            kill(-child, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish { $0.stdout = true } }
            finish { $0.exit = why }
        }
    }

    func send(_ message: JSON) async throws {
        let body = Data(message.compact.utf8)
        var bytes = Data("Content-Length: \(body.count)\r\n\r\n".utf8)
        bytes.append(body)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                let fd = lock.withLock { input }
                guard fd >= 0 else { return c.resume(throwing: LSPError("the server's input is closed", kind: .closed)) }
                var off = 0
                let ok = bytes.withUnsafeBytes { raw -> Bool in
                    while off < raw.count {
                        let n = write(fd, raw.baseAddress! + off, raw.count - off)
                        if n < 0 { if errno == EINTR { continue }; return false }
                        off += n
                    }
                    return true
                }
                ok ? c.resume() : c.resume(throwing: LSPError("writing to the server failed: \(String(cString: strerror(errno)))", kind: .closed))
            }
        }
    }

    private func closeInput() {
        let fd = lock.withLock { () -> Int32 in let f = input; input = -1; return f }
        if fd >= 0 { writes.async { Darwin.close(fd) } }
    }

    /// After `exit`: close its input, SIGTERM its group a second later, SIGKILL two after.
    func close() {
        let (pid, already) = lock.withLock { () -> (pid_t, Bool) in let r = (_pid, closing); closing = true; return r }
        guard !already else { return }
        closeInput()
        guard pid > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { [weak self] in
            guard self?.pid == pid else { return }
            if kill(pid, 0) == 0 { kill(-pid, SIGTERM); kill(pid, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
                guard self?.pid == pid else { return }
                if kill(-pid, 0) == 0 || kill(pid, 0) == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
            }
        }
    }

    /// The app quitting: the group ends now.
    func terminateNow() {
        let pid = lock.withLock { () -> pid_t in closing = true; return _pid }
        guard pid > 0 else { return }
        kill(-pid, SIGTERM); kill(pid, SIGTERM)
        usleep(200_000)
        if kill(-pid, 0) == 0 || kill(pid, 0) == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
    }
}

/// `Content-Length` framing: headers (any of them, `Content-Length` decides) ended by a blank line, then that many bytes.
struct LSPFraming {
    struct Message { var json: JSON?; var size: Int }
    private var buffer = Data()
    /// Set when the stream can't be parsed any more (no usable length): the link is useless from there.
    private(set) var failure: String?
    static let maxBody = 256_000_000

    mutating func feed(_ d: Data) { buffer.append(d) }

    mutating func next() -> Message? {
        guard failure == nil else { return nil }
        let sep = Data("\r\n\r\n".utf8)
        guard let r = buffer.range(of: sep) else {
            if buffer.count > 16_384 { failure = "no header terminator in 16 KB of output"; buffer.removeAll() }
            return nil
        }
        let header = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
        var length: Int?
        for line in header.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                length = Int(parts[1].trimmingCharacters(in: .whitespaces))
            }
        }
        guard let n = length, n >= 0, n <= Self.maxBody else {
            failure = "a message without a usable Content-Length"
            buffer.removeAll()
            return nil
        }
        let start = r.upperBound
        guard buffer.distance(from: start, to: buffer.endIndex) >= n else { return nil }
        let body = buffer[start..<buffer.index(start, offsetBy: n)]
        let json = JSON.parse(Data(body))
        buffer = Data(buffer[buffer.index(start, offsetBy: n)...])
        return Message(json: json, size: n)
    }
}

/// What a language server is busy with: `$/progress` tokens in flight and, for rust-analyzer, `experimental/serverStatus`.
struct LSPActivity: Sendable, Equatable {
    var title: String
    var message: String?
    var percentage: Int?
}

/// A JSON-RPC 2.0 session with one language server: requests matched to responses by id (with timeouts, `$/cancelRequest`
/// on cancel, every waiting call failed when the link ends), the server's own requests answered, `$/progress` tracked,
/// `publishDiagnostics` kept per file, and open documents synchronised from disk.
final class LSPConnection: @unchecked Sendable {
    let transport: LSPStdioTransport
    let root: URL
    private final class Waiter: @unchecked Sendable { let once = OneShot<JSON>() }
    struct Doc { var version: Int; var text: String; var stamp: FileViews.Stamp?; var used: Date }
    struct Published { var items: [JSON]; var version: Int?; var at: Date; var count: Int }
    private struct State {
        var next = 0
        var waiting: [Int: Waiter] = [:]
        var closed: String?
        var closeWaiters: [CheckedContinuation<String, Never>] = []
        var docs: [String: Doc] = [:]
        var published: [String: Published] = [:]
        var progress: [String: LSPActivity] = [:]
        var lastProgressAt = Date.distantPast
        /// rust-analyzer's `quiescent` (false while it loads or checks); nil: this server doesn't say.
        var quiescent: Bool?
        var initializedAt: Date?
        var capabilities: JSON = .object([:])
    }
    private let state = Locked(State())
    /// How many documents stay open in the server; the least recently used close first.
    static let maxOpen = 40
    var log: MCPLog { transport.log }

    init(transport: LSPStdioTransport, root: URL) {
        self.transport = transport
        self.root = root
    }

    func start() throws {
        try transport.open(receive: { [weak self] in self?.received($0) }, closed: { [weak self] in self?.ended($0) })
    }
    var closedReason: String? { state.get().closed }
    var capabilities: JSON { state.get().capabilities }

    func waitClosed() async -> String {
        await withCheckedContinuation { c in
            let done = state.mutate { s -> String? in
                if let r = s.closed { return r }
                s.closeWaiters.append(c)
                return nil
            }
            if let done { c.resume(returning: done) }
        }
    }

    // MARK: Requests

    /// Sends a request and waits for its result. A server error, the link ending, `timeout` or cancellation throws;
    /// the last two also tell the server (`$/cancelRequest`).
    func request(_ method: String, _ params: JSON = .null, timeout: TimeInterval = 30) async throws -> JSON {
        let w = Waiter()
        let id: Int? = state.mutate { s in
            guard s.closed == nil else { return nil }
            s.next += 1
            s.waiting[s.next] = w
            return s.next
        }
        guard let id else { throw LSPError("The language server isn't running (\(closedReason ?? "closed")).", kind: .closed) }
        var message: [String: JSON] = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method)]
        if !params.isNull { message["params"] = params }
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.05, timeout) * 1e9))
            guard !Task.isCancelled else { return }
            self?.abandon(id)
            w.once.finish(.failure(LSPError("\(method) timed out after \(Int(timeout)) s.", kind: .timeout)))
        }
        let transport = transport
        let sending = Task {
            do { try await transport.send(.object(message)) } catch { w.once.finish(.failure(error)) }
        }
        defer { timer.cancel(); sending.cancel(); _ = state.mutate { $0.waiting.removeValue(forKey: id) } }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in w.once.attach(c) }
        } onCancel: { [weak self] in
            self?.abandon(id)
            w.once.finish(.failure(CancellationError()))
        }
    }

    func notify(_ method: String, _ params: JSON = .null) async {
        var m: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if !params.isNull { m["params"] = params }
        try? await transport.send(.object(m))
    }

    private func abandon(_ id: Int) {
        guard state.mutate({ $0.waiting.removeValue(forKey: id) != nil }) else { return }
        Task { await notify("$/cancelRequest", ["id": .number(Double(id))]) }
    }

    // MARK: Incoming

    private func received(_ message: JSON) {
        if let batch = message.array { batch.forEach(received); return }
        let method = message["method"]?.string
        if let method, let id = message["id"], !id.isNull {
            answer(id: id, method: method, params: message["params"] ?? .null)
        } else if let method {
            notification(method, message["params"] ?? .null)
        } else if let id = message["id"]?.int ?? message["id"]?.string.flatMap({ Int($0) }) {
            guard let w = state.get().waiting[id] else { return }
            if let e = message["error"] {
                let code = e["code"]?.int ?? 0
                w.once.finish(.failure(LSPError("\(e["message"]?.string ?? "error") (\(code))", kind: .server(code))))
            } else {
                w.once.finish(.success(message["result"] ?? .null))
            }
        }
    }

    /// The server's own requests. Answered at once from the receiving thread's task; unknown ones get "method not found".
    private func answer(id: JSON, method: String, params: JSON) {
        var reply: [String: JSON] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "workspace/configuration":
            // No settings of ours: null per item makes the server use its defaults.
            reply["result"] = .array((params["items"]?.array ?? []).map { _ in .null })
        case "client/registerCapability", "client/unregisterCapability", "window/workDoneProgress/create",
             "workspace/diagnostic/refresh", "workspace/inlayHint/refresh", "workspace/semanticTokens/refresh",
             "workspace/codeLens/refresh", "workspace/inlineValue/refresh":
            reply["result"] = .null
        case "workspace/workspaceFolders":
            reply["result"] = [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]]
        case "window/showMessageRequest": reply["result"] = .null
        case "workspace/applyEdit":
            // The mentor never lets a server change files.
            reply["result"] = ["applied": false, "failureReason": "this client doesn't apply edits from the server"]
        case "ping": reply["result"] = .null
        default: reply["error"] = ["code": -32601, "message": .string("Method not found: \(method)")]
        }
        let transport = transport
        Task { try? await transport.send(.object(reply)) }
    }

    private static func token(_ t: JSON?) -> String? { t?.string ?? t?.int.map(String.init) }

    private func notification(_ method: String, _ params: JSON) {
        switch method {
        case "$/progress":
            guard let t = Self.token(params["token"]) else { return }
            let v = params["value"] ?? .null
            state.mutate { s in
                s.lastProgressAt = Date()
                switch v["kind"]?.string {
                case "begin": s.progress[t] = LSPActivity(title: v["title"]?.string ?? "", message: v["message"]?.string, percentage: v["percentage"]?.int)
                case "report":
                    var a = s.progress[t] ?? LSPActivity(title: "")
                    if let m = v["message"]?.string { a.message = m }
                    if let p = v["percentage"]?.int { a.percentage = p }
                    s.progress[t] = a
                case "end": s.progress[t] = nil
                default: break
                }
            }
        case "textDocument/publishDiagnostics":
            guard let uri = params["uri"]?.string else { return }
            let items = params["diagnostics"]?.array ?? []
            state.mutate { s in
                let n = (s.published[uri]?.count ?? 0) + 1
                s.published[uri] = Published(items: items, version: params["version"]?.int, at: Date(), count: n)
            }
        case "experimental/serverStatus":
            state.mutate { $0.quiescent = params["quiescent"]?.bool; $0.lastProgressAt = Date() }
        case "window/logMessage", "window/showMessage":
            log.note("\(params["message"]?.string.map { String($0.prefix(300)) } ?? "")")
        default: break
        }
    }

    private func ended(_ reason: String) {
        let (waiting, closers) = state.mutate { s -> ([Waiter], [CheckedContinuation<String, Never>]) in
            guard s.closed == nil else { return ([], []) }
            s.closed = reason
            defer { s.waiting = [:]; s.closeWaiters = [] }
            return (Array(s.waiting.values), s.closeWaiters)
        }
        for w in waiting { w.once.finish(.failure(LSPError("The language server \(reason).", kind: .closed))) }
        for c in closers { c.resume(returning: reason) }
    }

    // MARK: Lifecycle

    static func capabilitiesJSON() -> JSON {
        [
            "general": ["positionEncodings": ["utf-16"]],
            "workspace": ["configuration": true, "workspaceFolders": true, "applyEdit": false,
                          "symbol": ["dynamicRegistration": false], "didChangeWatchedFiles": ["dynamicRegistration": false]],
            "window": ["workDoneProgress": true, "showMessage": ["messageActionItem": ["additionalPropertiesSupport": false]]],
            "textDocument": [
                "synchronization": ["dynamicRegistration": false, "didSave": true, "willSave": false],
                "publishDiagnostics": ["relatedInformation": true, "versionSupport": true],
                "definition": ["linkSupport": true], "typeDefinition": ["linkSupport": true], "implementation": ["linkSupport": true],
                "references": ["dynamicRegistration": false],
                "hover": ["contentFormat": ["markdown", "plaintext"]],
                "documentSymbol": ["hierarchicalDocumentSymbolSupport": true],
                "callHierarchy": ["dynamicRegistration": false],
                "rename": ["prepareSupport": false],
            ],
            "experimental": ["serverStatusNotification": true],
        ]
    }

    /// initialize + initialized. Returns the server's name and version when it says.
    @discardableResult
    func initialize(timeout: TimeInterval = 60) async throws -> String {
        let r = try await request("initialize", [
            "processId": .number(Double(ProcessInfo.processInfo.processIdentifier)),
            "clientInfo": ["name": "my-ai-teacher", "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")],
            "rootUri": .string(root.absoluteString), "rootPath": .string(root.path),
            "workspaceFolders": [["uri": .string(root.absoluteString), "name": .string(root.lastPathComponent)]],
            "capabilities": Self.capabilitiesJSON(),
            "trace": "off",
        ], timeout: timeout)
        state.mutate { $0.capabilities = r["capabilities"] ?? .object([:]); $0.initializedAt = Date() }
        await notify("initialized", .object([:]))
        let info = r["serverInfo"]
        return [info?["name"]?.string, info?["version"]?.string].compactMap { $0 }.joined(separator: " ")
    }

    /// Whether the server advertises a capability (`definitionProvider`…): present and not false.
    func supports(_ provider: String) -> Bool {
        guard let c = capabilities[provider] else { return false }
        return c.bool != false && !c.isNull
    }

    /// shutdown, exit, then the process ends (SIGTERM and SIGKILL follow if it lingers).
    func shutdown() async {
        if closedReason == nil {
            _ = try? await request("shutdown", timeout: 3)
            await notify("exit")
        }
        transport.close()
    }
    func close() { transport.close() }
    func terminateNow() { transport.terminateNow() }

    // MARK: Progress

    /// What the server is busy with now (indexing, loading, checking), nil when idle.
    var activity: (title: String, percentage: Int?)? {
        let s = state.get()
        if let a = s.progress.values.sorted(by: { ($0.percentage ?? 101) < ($1.percentage ?? 101) }).first(where: { !$0.title.isEmpty || $0.percentage != nil }) {
            return (a.title.isEmpty ? (a.message ?? "working") : a.title, a.percentage)
        }
        if !s.progress.isEmpty { return ("working", nil) }
        if s.quiescent == false { return ("loading the project", nil) }
        return nil
    }

    /// Waits for the server to settle after start-up (no progress in flight for a moment), at most `seconds`. Returns what
    /// it is still busy with when time ran out.
    @discardableResult
    func awaitIdle(_ seconds: TimeInterval) async -> (title: String, percentage: Int?)? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            let s = state.get()
            let quiet = s.lastProgressAt.timeIntervalSinceNow < -0.4 && (s.initializedAt.map { $0.timeIntervalSinceNow < -0.4 } ?? false)
            if activity == nil && quiet { return nil }
            if Date() >= deadline || closedReason != nil || Task.isCancelled { return activity ?? ("starting up", nil) }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    // MARK: Documents

    static func uri(_ url: URL) -> String { url.standardizedFileURL.absoluteString }

    /// Makes the server's copy of `url` what is on disk now: opened if new, `didChange` (and `didSave`, which is what
    /// triggers rust-analyzer's cargo check) when the text differs. Also re-syncs every other open document whose
    /// file stamp moved, and closes the ones that were deleted or are least recently used.
    @discardableResult
    func sync(_ url: URL, languageId: String) async throws -> Date {
        let key = Self.uri(url)
        guard let data = FileManager.default.contents(atPath: url.path) else { throw LSPError("\(url.lastPathComponent) can't be read.") }
        let text = String(decoding: data, as: UTF8.self)
        let stamp = FileViews.stamp(url)
        let syncedAt = Date()
        enum Action { case open(Int), change(Int), none }
        let action = state.mutate { s -> Action in
            if var d = s.docs[key] {
                d.used = syncedAt
                if d.text == text { d.stamp = stamp; s.docs[key] = d; return .none }
                d.version += 1; d.text = text; d.stamp = stamp
                s.docs[key] = d
                s.published[key] = nil
                return .change(d.version)
            }
            s.docs[key] = Doc(version: 1, text: text, stamp: stamp, used: syncedAt)
            return .open(1)
        }
        switch action {
        case .open(let v):
            // A file made after the server started (the mentor writes new files) isn't in the project the server loaded: say so.
            if let born = stamp?.modified, let up = state.get().initializedAt, born > up {
                await notify("workspace/didChangeWatchedFiles", ["changes": [["uri": .string(key), "type": 1]]])
            }
            await notify("textDocument/didOpen", ["textDocument": ["uri": .string(key), "languageId": .string(languageId), "version": .number(Double(v)), "text": .string(text)]])
            await notify("textDocument/didSave", ["textDocument": ["uri": .string(key)]])
        case .change(let v):
            await notify("textDocument/didChange", ["textDocument": ["uri": .string(key), "version": .number(Double(v))], "contentChanges": [["text": .string(text)]]])
            await notify("textDocument/didSave", ["textDocument": ["uri": .string(key)]])
        case .none: break
        }
        await resyncOthers(except: key)
        return syncedAt
    }

    /// The other open documents, by file stamp (the cheap check): a changed one is sent again, a deleted one closed;
    /// the least recently used go when more than `maxOpen` are open.
    private func resyncOthers(except key: String) async {
        let docs = state.get().docs
        for (k, d) in docs where k != key {
            guard let url = URL(string: k), url.isFileURL else { continue }
            guard let now = FileViews.stamp(url) else { await close(k); continue }
            guard now != d.stamp, let data = FileManager.default.contents(atPath: url.path) else { continue }
            let text = String(decoding: data, as: UTF8.self)
            let v = state.mutate { s -> Int? in
                guard var cur = s.docs[k] else { return nil }
                cur.stamp = now
                var bumped = false
                if cur.text != text { cur.version += 1; cur.text = text; s.published[k] = nil; bumped = true }
                s.docs[k] = cur
                return bumped ? cur.version : nil
            }
            if let v {
                await notify("textDocument/didChange", ["textDocument": ["uri": .string(k), "version": .number(Double(v))], "contentChanges": [["text": .string(text)]]])
                await notify("textDocument/didSave", ["textDocument": ["uri": .string(k)]])
            }
        }
        let over = state.get().docs.sorted { $0.value.used < $1.value.used }.dropLast(Self.maxOpen).map(\.key)
        for k in over where k != key { await close(k) }
    }

    func close(_ uri: String) async {
        guard state.mutate({ s -> Bool in s.published[uri] = nil; return s.docs.removeValue(forKey: uri) != nil }) else { return }
        await notify("textDocument/didClose", ["textDocument": ["uri": .string(uri)]])
    }

    var openDocuments: [String] { state.get().docs.keys.sorted() }
    func documentText(_ uri: String) -> String? { state.get().docs[uri]?.text }
    func documentVersion(_ uri: String) -> Int? { state.get().docs[uri]?.version }

    // MARK: Diagnostics

    func published(_ uri: String) -> Published? { state.get().published[uri] }
    func allPublished() -> [String: Published] { state.get().published }

    /// Diagnostics for a document after a sync at `since`: waits (at most `seconds`) for the server to publish after it,
    /// then a moment more for a second publish (syntax first, types after). nil: nothing was published in time.
    func awaitDiagnostics(_ uri: String, since: Date, seconds: TimeInterval) async -> Published? {
        let deadline = Date().addingTimeInterval(seconds)
        while true {
            if let p = published(uri), p.at >= since {
                // An empty first publish is often the syntax pass (sourcekit-lsp, clangd): wait longer before believing it,
                // and while the server is still loading the project.
                let settle = p.items.isEmpty ? 1.5 : 0.7
                if (p.at.timeIntervalSinceNow < -settle && activity == nil) || Date() >= deadline { return p }
            } else if Date() >= deadline { return nil }
            if closedReason != nil || Task.isCancelled { return published(uri) }
            try? await Task.sleep(nanoseconds: 80_000_000)
        }
    }
}
