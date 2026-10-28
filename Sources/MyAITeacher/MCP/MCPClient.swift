import Foundation
import Darwin

struct MCPError: LocalizedError, Sendable {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

/// Carries JSON-RPC messages to and from one server. `receive` gets every message the server sends; `closed` is
/// called once, when the link ends, with why.
protocol MCPTransport: AnyObject, Sendable {
    func open(receive: @escaping @Sendable (JSON) -> Void, closed: @escaping @Sendable (String) -> Void) async throws
    func send(_ message: JSON) async throws
    /// After `initialize`: the protocol version both sides speak (HTTP sends it as a header).
    func negotiated(_ version: String)
    func close()
}

/// What a server says about itself in `initialize`.
struct MCPServerInfo: Sendable {
    var name = "", version = "", protocolVersion = "", instructions: String?
}

/// One tool a server offers, as `tools/list` describes it.
struct MCPToolInfo: Sendable, Equatable {
    let name: String
    let description: String
    let inputSchema: JSON
    /// The server says it only reads (`annotations.readOnlyHint`); the prompt marks the tool read-only.
    let readOnly: Bool

    init(name: String, description: String, inputSchema: JSON, readOnly: Bool) {
        self.name = name; self.description = description; self.inputSchema = inputSchema; self.readOnly = readOnly
    }
    init?(json: JSON) {
        guard let name = json["name"]?.string, !name.isEmpty else { return nil }
        let title = json["annotations"]?["title"]?.string ?? json["title"]?.string
        self.init(name: name, description: json["description"]?.string ?? title ?? "",
                  inputSchema: json["inputSchema"]?.object != nil ? json["inputSchema"]! : ["type": "object", "properties": [:]],
                  readOnly: json["annotations"]?["readOnlyHint"]?.bool == true)
    }
    var json: JSON {
        ["name": .string(name), "description": .string(description), "inputSchema": inputSchema, "annotations": ["readOnlyHint": .bool(readOnly)]]
    }
}

/// A JSON-RPC 2.0 session with one MCP server over a transport: requests matched to their responses by id, the
/// server's own requests answered (`ping`, `roots/list`), progress routed to the call that asked for it, and every
/// waiting call failed at once when the link ends.
final class MCPConnection: @unchecked Sendable {
    static let protocolVersion = "2025-11-25"
    static let knownVersions: Set<String> = ["2025-11-25", "2025-06-18", "2025-03-26", "2024-11-05"]

    let transport: MCPTransport
    let roots: [URL]
    /// Notifications other than progress (`notifications/tools/list_changed`, `notifications/message`…).
    var onNotification: (@Sendable (String, JSON) -> Void)?

    private final class Waiter: @unchecked Sendable {
        let once = OneShot<JSON>()
        var progress: (@Sendable (String) -> Void)?
    }
    private struct State {
        var next = 0
        var waiting: [Int: Waiter] = [:]
        var closed: String?
        var closeWaiters: [CheckedContinuation<String, Never>] = []
    }
    private let state = Locked(State())

    init(transport: MCPTransport, roots: [URL] = []) {
        self.transport = transport
        self.roots = roots
    }

    func start() async throws {
        try await transport.open(receive: { [weak self] in self?.received($0) }, closed: { [weak self] in self?.ended($0) })
    }

    /// Why the link ended, once it has.
    var closedReason: String? { state.get().closed }

    /// Waits until the link ends; returns why.
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

    func close() { transport.close() }

    // MARK: Requests

    /// Sends a request and waits for its result. A JSON-RPC error, the link ending, `timeout` or cancellation throws;
    /// the last two also tell the server (`notifications/cancelled`).
    func request(_ method: String, _ params: JSON = .object([:]), timeout: TimeInterval = 60,
                 progress: (@Sendable (String) -> Void)? = nil) async throws -> JSON {
        let w = Waiter()
        w.progress = progress
        let id: Int? = state.mutate { s in
            guard s.closed == nil else { return nil }
            s.next += 1
            s.waiting[s.next] = w
            return s.next
        }
        guard let id else { throw MCPError("The server isn't connected (\(closedReason ?? "closed")).") }
        var p = params.object ?? [:]
        if progress != nil { p["_meta"] = ["progressToken": .number(Double(id))] }
        let message: JSON = ["jsonrpc": "2.0", "id": .number(Double(id)), "method": .string(method), "params": .object(p)]
        let timer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0.1, timeout) * 1e9))
            guard !Task.isCancelled else { return }
            self?.abandon(id, reason: "timed out after \(Int(timeout)) s")
            w.once.finish(.failure(MCPError("\(method) timed out after \(Int(timeout)) s.")))
        }
        defer { timer.cancel(); _ = state.mutate { $0.waiting.removeValue(forKey: id) } }
        // Sent in its own task: an HTTP response may stream for as long as the call runs, and its result arrives
        // through `received` meanwhile.
        let transport = transport
        Task {
            do { try await transport.send(message) } catch { w.once.finish(.failure(MCPError("Couldn't send \(method): \(error.localizedDescription)"))) }
        }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<JSON, Error>) in w.once.attach(c) }
        } onCancel: { [weak self] in
            self?.abandon(id, reason: "cancelled by the user")
            w.once.finish(.failure(CancellationError()))
        }
    }

    func notify(_ method: String, _ params: JSON? = nil) async {
        var m: [String: JSON] = ["jsonrpc": "2.0", "method": .string(method)]
        if let params { m["params"] = params }
        try? await transport.send(.object(m))
    }

    private func abandon(_ id: Int, reason: String) {
        let was = state.mutate { $0.waiting.removeValue(forKey: id) != nil }
        guard was else { return }
        Task { await notify("notifications/cancelled", ["requestId": .number(Double(id)), "reason": .string(reason)]) }
    }

    // MARK: Incoming

    private func received(_ message: JSON) {
        if let batch = message.array { batch.forEach(received); return }
        let method = message["method"]?.string
        if let method, let id = message["id"], !id.isNull {
            answer(id: id, method: method, params: message["params"] ?? .null)
        } else if let method {
            if method == "notifications/progress", let token = message["params"]?["progressToken"]?.int,
               let w = state.get().waiting[token], let report = w.progress {
                let p = message["params"]!
                let amount = [p["progress"]?.double, p["total"]?.double].compactMap { $0 }.map { String(Int($0)) }.joined(separator: "/")
                report([amount, p["message"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " "))
            } else {
                onNotification?(method, message["params"] ?? .null)
            }
        } else if let id = message["id"]?.int ?? message["id"]?.string.flatMap({ Int($0) }) {
            guard let w = state.get().waiting[id] else { return }   // late: timed out or cancelled
            if let e = message["error"] {
                let detail = e["data"].map { " " + String($0.compact.prefix(400)) } ?? ""
                w.once.finish(.failure(MCPError("\(e["message"]?.string ?? "error") (\(e["code"]?.int ?? 0))\(detail)")))
            } else {
                w.once.finish(.success(message["result"] ?? .object([:])))
            }
        }
    }

    /// The server's own requests: pings, and the folders the client works in. Nothing else was declared.
    private func answer(id: JSON, method: String, params: JSON) {
        var reply: [String: JSON] = ["jsonrpc": "2.0", "id": id]
        switch method {
        case "ping": reply["result"] = .object([:])
        case "roots/list":
            reply["result"] = ["roots": .array(roots.map { ["uri": .string($0.absoluteString), "name": .string($0.lastPathComponent)] })]
        default: reply["error"] = ["code": -32601, "message": .string("Method not found: \(method)")]
        }
        let transport = transport
        Task { try? await transport.send(.object(reply)) }
    }

    private func ended(_ reason: String) {
        let (waiting, closers) = state.mutate { s -> ([Waiter], [CheckedContinuation<String, Never>]) in
            guard s.closed == nil else { return ([], []) }
            s.closed = reason
            defer { s.waiting = [:]; s.closeWaiters = [] }
            return (Array(s.waiting.values), s.closeWaiters)
        }
        for w in waiting { w.once.finish(.failure(MCPError("The server \(reason)."))) }
        for c in closers { c.resume(returning: reason) }
    }

    // MARK: MCP

    func initialize(timeout: TimeInterval = 60) async throws -> MCPServerInfo {
        let r = try await request("initialize", [
            "protocolVersion": .string(Self.protocolVersion),
            "capabilities": ["roots": ["listChanged": false]],
            "clientInfo": ["name": "my-ai-teacher", "title": "My AI Teacher", "version": .string(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")],
        ], timeout: timeout)
        let version = r["protocolVersion"]?.string ?? ""
        guard !version.isEmpty else { throw MCPError("The server's initialize reply has no protocol version.") }
        transport.negotiated(version)
        await notify("notifications/initialized")
        return MCPServerInfo(name: r["serverInfo"]?["name"]?.string ?? "", version: r["serverInfo"]?["version"]?.string ?? "",
                             protocolVersion: version, instructions: r["instructions"]?.string)
    }

    /// Every tool, following `nextCursor` pages (at most 50 of them).
    func listTools(timeout: TimeInterval = 30) async throws -> [MCPToolInfo] {
        var out: [MCPToolInfo] = [], cursor: String?
        for _ in 0..<50 {
            let r = try await request("tools/list", cursor.map { ["cursor": .string($0)] } ?? .object([:]), timeout: timeout)
            out += (r["tools"]?.array ?? []).compactMap(MCPToolInfo.init(json:))
            guard let next = r["nextCursor"]?.string, !next.isEmpty, next != cursor else { break }
            cursor = next
        }
        return out
    }

    func callTool(_ name: String, _ arguments: JSON, timeout: TimeInterval, progress: (@Sendable (String) -> Void)? = nil) async throws -> ToolOutput {
        let r = try await request("tools/call", ["name": .string(name), "arguments": arguments.object != nil ? arguments : .object([:])],
                                  timeout: timeout, progress: progress)
        return Self.output(r)
    }

    /// A `tools/call` result as a tool's output: text parts joined, images kept, the rest described in a line.
    static func output(_ r: JSON) -> ToolOutput {
        var parts: [String] = [], images: [Block] = []
        for c in r["content"]?.array ?? [] {
            switch c["type"]?.string {
            case "text": parts.append(c["text"]?.string ?? "")
            case "image":
                if let data = c["data"]?.string { images.append(.image(mime: c["mimeType"]?.string ?? "image/png", base64: data)) }
            case "audio": parts.append("[audio: \(c["mimeType"]?.string ?? "audio")]")
            case "resource_link":
                parts.append("[resource: \(c["uri"]?.string ?? "")\(c["name"]?.string.map { " (\($0))" } ?? "")]")
            case "resource":
                let res = c["resource"] ?? .null
                parts.append(res["text"]?.string ?? "[resource: \(res["uri"]?.string ?? "") \(res["mimeType"]?.string ?? "")]")
            default: parts.append(c.compact)
            }
        }
        if parts.allSatisfy({ $0.isEmpty }), let structured = r["structuredContent"], !structured.isNull { parts = [structured.pretty] }
        var text = parts.joined(separator: "\n")
        if text.isEmpty { text = images.isEmpty ? "(no output)" : "(\(images.count) image\(images.count == 1 ? "" : "s"))" }
        return ToolOutput(text: text, isError: r["isError"]?.bool == true, images: images)
    }
}

/// The last `limit` bytes a server wrote to stderr (and the app's own lines about it), for Settings → MCP.
final class MCPLog: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()
    private let limit: Int
    init(limit: Int = 64_000) { self.limit = limit }
    func append(_ d: Data) {
        lock.lock(); defer { lock.unlock() }
        data.append(d)
        if data.count > limit { data.removeFirst(data.count - limit) }
    }
    func note(_ line: String) {
        let df = DateFormatter(); df.dateFormat = "HH:mm:ss"
        append(Data("[\(df.string(from: Date()))] \(line)\n".utf8))
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}

// MARK: - stdio

/// A server as a child process: newline-delimited JSON-RPC on its stdin and stdout, stderr kept in `log`. It runs in its
/// own process group, so ending it ends whatever it started (npx's node, uvx's python).
final class MCPStdioTransport: MCPTransport, @unchecked Sendable {
    let executable: String, args: [String], env: [String: String], cwd: URL
    let log: MCPLog
    private let lock = NSLock()
    private var input: Int32 = -1
    private var _pid: pid_t = 0
    private var closing = false
    private let writes = DispatchQueue(label: "mcp.stdin")

    init(executable: String, args: [String], env: [String: String], cwd: URL, log: MCPLog) {
        self.executable = executable; self.args = args; self.env = env; self.cwd = cwd; self.log = log
    }

    var pid: pid_t { lock.lock(); defer { lock.unlock() }; return _pid }

    func negotiated(_ version: String) {}

    func open(receive: @escaping @Sendable (JSON) -> Void, closed: @escaping @Sendable (String) -> Void) async throws {
        var inP: [Int32] = [0, 0], outP: [Int32] = [0, 0], errP: [Int32] = [0, 0]
        guard pipe(&inP) == 0, pipe(&outP) == 0, pipe(&errP) == 0 else { throw MCPError("Couldn't create pipes for the server.") }
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
        // The child gets 0, 1 and 2 only, none of the app's descriptors.
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_SETSIGMASK | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_CLOEXEC_DEFAULT))
        let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + args).map { strdup($0) } + [nil]
        let envp: [UnsafeMutablePointer<CChar>?] = env.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { argv.forEach { free($0) }; envp.forEach { free($0) } }
        var child: pid_t = 0
        let rc = posix_spawn(&child, executable, &fa, &attr, argv, envp)
        Darwin.close(inP[0]); Darwin.close(outP[1]); Darwin.close(errP[1])
        guard rc == 0 else {
            Darwin.close(inP[1]); Darwin.close(outP[0]); Darwin.close(errP[0])
            throw MCPError("Couldn't start \(executable): \(String(cString: strerror(rc))).")
        }
        _ = fcntl(inP[1], F_SETNOSIGPIPE, 1)   // a server that died mid-write is an error here, not a signal that ends the app
        lock.withLock { input = inP[1]; _pid = child }
        log.note("started pid \(child): \(([executable] + args).joined(separator: " "))")

        let outFD = outP[0], errFD = errP[0], log = log
        let done = Locked((stdout: false, exit: Optional<String>.none))
        let finish = { @Sendable (update: (inout (stdout: Bool, exit: String?)) -> Void) in
            // Closed once both the output has been read to its end and the process has exited, so no last reply is lost.
            let reason = done.mutate { s -> String? in update(&s); return s.stdout ? s.exit : nil }
            if let reason { closed(reason) }
        }
        Thread.detachNewThread {
            var buf = [UInt8](repeating: 0, count: 65_536), line = Data()
            while true {
                let n = read(outFD, &buf, buf.count)
                if n < 0 && errno == EINTR { continue }
                if n <= 0 { break }
                var start = 0
                for i in 0..<n where buf[i] == 0x0A {
                    line.append(contentsOf: buf[start..<i]); start = i + 1
                    if let j = JSON.parse(line) { receive(j) }
                    else if !line.isEmpty { log.append(Data("stdout (not JSON): ".utf8) + line.prefix(500) + Data("\n".utf8)) }
                    line.removeAll(keepingCapacity: true)
                }
                line.append(contentsOf: buf[start..<n])
                if line.count > 64_000_000 { log.note("dropped a 64 MB line with no end"); line.removeAll() }
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
            let sig = status & 0x7f
            let why = sig == 0 ? "exited with status \((status >> 8) & 0xff)" : "was killed by signal \(sig)"
            log.note("pid \(child) \(why)")
            self?.closeInput()
            kill(-child, SIGTERM)   // whatever it left behind in its group
            // Its output may stay open in a grandchild that ignores the signal: the exit decides, a moment later.
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { finish { $0.stdout = true } }
            finish { $0.exit = why }
        }
    }

    func send(_ message: JSON) async throws {
        let bytes = Data((message.compact + "\n").utf8)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                lock.lock(); let fd = input; lock.unlock()
                guard fd >= 0 else { return c.resume(throwing: MCPError("the server's input is closed")) }
                var off = 0
                let ok = bytes.withUnsafeBytes { raw -> Bool in
                    while off < raw.count {
                        let n = write(fd, raw.baseAddress! + off, raw.count - off)
                        if n < 0 { if errno == EINTR { continue }; return false }
                        off += n
                    }
                    return true
                }
                ok ? c.resume() : c.resume(throwing: MCPError("writing to the server failed: \(String(cString: strerror(errno)))"))
            }
        }
    }

    /// Closes the server's stdin. On the writes queue, so a write in progress finishes first and none ever goes to a
    /// descriptor number the system has since given to another file.
    private func closeInput() {
        lock.lock(); let fd = input; input = -1; lock.unlock()
        if fd >= 0 { writes.async { Darwin.close(fd) } }
    }

    /// The MCP way to end a stdio server: close its input, then SIGTERM its group a second later, SIGKILL two after.
    func close() {
        lock.lock(); let pid = _pid, already = closing; closing = true; lock.unlock()
        guard !already else { return }
        closeInput()
        guard pid > 0 else { return }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) {
            if kill(pid, 0) == 0 { kill(-pid, SIGTERM); kill(pid, SIGTERM) }
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) { if kill(-pid, 0) == 0 || kill(pid, 0) == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) } }
        }
    }

    /// For the app quitting: no time for the polite way. SIGTERM now, SIGKILL to what is left after a short wait.
    func terminateNow() {
        let pid = self.pid
        guard pid > 0 else { return }
        kill(-pid, SIGTERM); kill(pid, SIGTERM)
        for _ in 0..<10 where kill(pid, 0) == 0 { usleep(20_000) }
        if kill(-pid, 0) == 0 || kill(pid, 0) == 0 { kill(-pid, SIGKILL); kill(pid, SIGKILL) }
    }
}

// MARK: - Streamable HTTP

/// A server at a URL (MCP's streamable HTTP): each message is a POST; a request's reply comes back as JSON or as a
/// server-sent-event stream (which may carry the server's own requests and progress first). The session id the server
/// assigns in `initialize` goes with every later message.
final class MCPHTTPTransport: MCPTransport, @unchecked Sendable {
    let url: URL
    let headers: [String: String]
    let log: MCPLog
    private let state = Locked((session: String?.none, version: String?.none, closed: false))
    private var receive: (@Sendable (JSON) -> Void)?
    private var closed: (@Sendable (String) -> Void)?
    private static let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 300   // silence limit: a long tool call streams progress or keep-alives
        c.timeoutIntervalForResource = 3600
        return URLSession(configuration: c)
    }()

    init(url: URL, headers: [String: String], log: MCPLog) {
        self.url = url; self.headers = headers; self.log = log
    }

    func open(receive: @escaping @Sendable (JSON) -> Void, closed: @escaping @Sendable (String) -> Void) async throws {
        self.receive = receive
        self.closed = closed
        log.note("using \(url.absoluteString)")
    }

    func negotiated(_ version: String) { state.mutate { $0.version = version } }

    func send(_ message: JSON) async throws {
        guard !state.get().closed else { throw MCPError("the connection is closed") }
        var rq = URLRequest(url: url)
        rq.httpMethod = "POST"
        rq.httpBody = Data(message.compact.utf8)
        rq.setValue("application/json", forHTTPHeaderField: "Content-Type")
        rq.setValue("application/json, text/event-stream", forHTTPHeaderField: "Accept")
        let s = state.get()
        if let id = s.session { rq.setValue(id, forHTTPHeaderField: "Mcp-Session-Id") }
        if let v = s.version { rq.setValue(v, forHTTPHeaderField: "MCP-Protocol-Version") }
        for (k, v) in headers { rq.setValue(v, forHTTPHeaderField: k) }
        let (bytes, response) = try await Self.session.bytes(for: rq)
        let http = response as? HTTPURLResponse
        let status = http?.statusCode ?? 0
        if let id = http?.value(forHTTPHeaderField: "Mcp-Session-Id"), !id.isEmpty { state.mutate { $0.session = id } }
        if status == 202 || status == 204 { return }
        if status == 404, s.session != nil {
            // The server forgot the session: this link is over; the supervisor starts a new one.
            closed?("ended the session (HTTP 404)")
            throw MCPError("the server ended the session")
        }
        let type = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        if status >= 400 {
            var body = Data()
            for try await b in bytes { body.append(b); if body.count > 4000 { break } }
            throw HTTPError(status: status, body: String(decoding: body, as: UTF8.self))
        }
        if type.contains("text/event-stream") {
            // Server-sent events, by hand: `lines` would drop the blank lines that end each event.
            var line = Data(), data: [String] = []
            func dispatch() {
                if !data.isEmpty, let j = JSON.parse(data.joined(separator: "\n")) { receive?(j) }
                data.removeAll()
            }
            for try await b in bytes {
                if b != 0x0A { line.append(b); continue }
                if line.last == 0x0D { line.removeLast() }
                let l = String(decoding: line, as: UTF8.self)
                line.removeAll(keepingCapacity: true)
                if l.isEmpty { dispatch() }
                else if l.hasPrefix("data:") { data.append(String(l.dropFirst(5).drop { $0 == " " })) }
            }
            dispatch()
        } else {
            var body = Data()
            for try await b in bytes { body.append(b) }
            if let j = JSON.parse(body) { receive?(j) }
        }
    }

    func close() {
        let s = state.mutate { s -> (String?, Bool) in defer { s.closed = true }; return (s.session, s.closed) }
        guard !s.1 else { return }
        if let id = s.0 {
            var rq = URLRequest(url: url)
            rq.httpMethod = "DELETE"
            rq.setValue(id, forHTTPHeaderField: "Mcp-Session-Id")
            for (k, v) in headers { rq.setValue(v, forHTTPHeaderField: k) }
            Self.session.dataTask(with: rq).resume()
        }
        closed?("was disconnected")
    }
}
