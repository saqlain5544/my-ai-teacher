import Foundation

/// One language server running for one folder: started on first use as a child of Runtime › mcp (the supervisor of
/// the app's external servers), restarted after a crash (3 in 60 s, backoff 1 → 8 s), stopped after `idleSeconds` unused,
/// when the app quits, or when the user stops it. Its stderr is kept in `log`.
final class LSPInstance: @unchecked Sendable {
    enum Phase: String, Sendable { case idle, starting, ready, restarting, failed, stopped }
    struct Status: Sendable {
        var phase: Phase
        var pid: Int32?
        var restarts: Int
        var lastError: String?
        var startedAt: Date?
        var lastUsed: Date
        var server: String
        var activity: String?
    }
    let spec: LSPServerSpec
    let executable: String
    let folder: URL
    let log = MCPLog()
    private struct State {
        var phase: Phase = .idle
        var connection: LSPConnection?
        var restarts = 0
        var lastError: String?
        var startedAt: Date?
        var generation = 0
        var quitting = false
        var idleStop = false
        var lastUsed = Date()
        var serverName = ""
    }
    private let state = Locked(State())
    private static let serials = Locked(0)
    private let serial = LSPInstance.serials.mutate { $0 += 1; return $0 }
    private weak var hub: LSPHub?
    private let backoff: Backoff
    let idleSeconds: TimeInterval

    init(spec: LSPServerSpec, executable: String, folder: URL, hub: LSPHub?, idleSeconds: TimeInterval = LSPHub.idleSeconds,
         backoff: Backoff = Backoff(initial: 1, max: 8)) {
        self.spec = spec; self.executable = executable; self.folder = folder; self.hub = hub
        self.idleSeconds = idleSeconds; self.backoff = backoff
    }

    var status: Status {
        let s = state.get()
        let a = s.connection?.activity
        return Status(phase: s.phase, pid: s.connection.map { $0.transport.pid }.flatMap { $0 > 0 ? $0 : nil }, restarts: s.restarts,
                      lastError: s.lastError, startedAt: s.startedAt, lastUsed: s.lastUsed, server: s.serverName.isEmpty ? spec.title : s.serverName,
                      activity: a.map { $0.title + ($0.percentage.map { " \($0)%" } ?? "") })
    }
    var isRunning: Bool { [.starting, .ready, .restarting].contains(state.get().phase) }
    var lastUsed: Date { state.get().lastUsed }
    func touch() { state.mutate { $0.lastUsed = Date() } }
    private var childID: String { "lsp:\(spec.id)@\(folder.lastPathComponent)#\(serial).\(state.get().generation)" }

    func start() async {
        let go = state.mutate { s -> Bool in
            guard [.idle, .failed, .stopped].contains(s.phase), !s.quitting else { return false }
            s.phase = .starting; s.lastError = nil; s.restarts = 0; s.generation += 1; s.idleStop = false; s.lastUsed = Date()
            return true
        }
        guard go else { return }
        await hub?.makeRoom(for: self)
        let id = childID
        guard let sup = await Runtime.supervisor("mcp") else { return ended(.crashed("the app's runtime isn't available")) }
        let spec = ChildSpec(id: id, restart: .transient, intensity: Intensity(maxRestarts: 3, period: 60), backoff: backoff,
                             shutdownGrace: 5, start: { [self] attempt in
            Proc.spawn(id, of: Never.self) { _ in try await self.incarnation(attempt) }.proc
        }, onExit: { [weak self] reason in self?.ended(reason) })
        if !(await sup.startChild(spec)) { ended(.crashed("couldn't be started")) }
    }

    /// One run of the server, from launch to the link ending. Ending by itself is a crash (the supervisor restarts it);
    /// a stop or the idle timeout ends it normally.
    private func incarnation(_ attempt: Int) async throws {
        if attempt > 0 {
            state.mutate { $0.phase = .restarting; $0.restarts = attempt }
            log.note("restarting (\(attempt) of 3)")
        }
        var env = ProcessRunner.environment()
        env["MYAITEACHER_LSP"] = "1"
        let transport = LSPStdioTransport(executable: executable, args: spec.args, env: env, cwd: folder, log: log)
        let conn = LSPConnection(transport: transport, root: folder)
        let idle = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(max(0.05, min(15, (self?.idleSeconds ?? 600) / 4)) * 1e9))
                guard let self, !Task.isCancelled else { return }
                let s = self.state.get()
                if s.phase == .ready, Date().timeIntervalSince(s.lastUsed) > self.idleSeconds {
                    self.log.note("idle for \(Int(self.idleSeconds)) s: stopping")
                    self.state.mutate { $0.idleStop = true }
                    await conn.shutdown()
                    return
                }
            }
        }
        defer { idle.cancel() }
        try await withTaskCancellationHandler {
            do {
                try conn.start()
                let name = try await conn.initialize(timeout: 90)
                state.mutate { $0.connection = conn; $0.phase = .ready; $0.lastError = nil; $0.startedAt = Date(); if !name.isEmpty { $0.serverName = name } }
                log.note("ready: \(name.isEmpty ? spec.title : name)")
            } catch {
                conn.close()
                throw error
            }
            let why = await conn.waitClosed()
            if Task.isCancelled || state.get().quitting || state.get().idleStop { return }
            state.mutate { $0.connection = nil; $0.phase = .restarting; $0.lastError = why }
            throw LSPError("\(spec.title) \(why)")
        } onCancel: {
            Task { await conn.shutdown() }
        }
    }

    private func ended(_ reason: ExitReason) {
        state.mutate { s in
            s.connection = nil
            s.phase = reason.isCrash ? .failed : .stopped
            if reason.isCrash { s.lastError = reason.description }
        }
        log.note(reason.isCrash ? "gave up: \(reason)" : "stopped")
    }

    /// The live link, starting the server first if needed; waits through restarts.
    func connection(timeout: TimeInterval = 90) async throws -> LSPConnection {
        touch()
        let now = state.get()
        if now.phase == .ready, let c = now.connection, c.closedReason == nil { return c }
        await start()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            let s = state.get()
            if s.phase == .ready, let c = s.connection, c.closedReason == nil { return c }
            if s.phase == .failed || s.phase == .stopped {
                // A stop that raced the start (idle timeout, evicted for room): start again once.
                if s.phase == .stopped, !s.quitting, s.lastError == nil, deadline.timeIntervalSinceNow > 5 { await start(); continue }
                throw LSPError("The \(spec.title) language server couldn't start: \(s.lastError ?? "it stopped"). Its log is in the Tasks panel's server entry.")
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw LSPError("The \(spec.title) language server didn't start within \(Int(timeout)) s.")
    }

    /// Runs `body` on the live link; a link that ends mid-call (a crash) is waited for and the call tried once more.
    func perform<T>(_ body: (LSPConnection) async throws -> T) async throws -> T {
        do { return try await body(try await connection()) }
        catch let e as LSPError where e.isClosed {
            log.note("call interrupted (\(e.message)); trying once more")
            return try await body(try await connection())
        }
    }

    func stop() async {
        let id = childID, running = ![.idle, .stopped, .failed].contains(state.get().phase)
        guard running else { return }
        await Runtime.supervisor("mcp")?.terminate(id)
    }

    func terminateNow() {
        let c = state.mutate { s -> LSPConnection? in s.quitting = true; return s.connection }
        c?.terminateNow()
    }
}

/// The app's language servers: an instance per folder and server, at most `maxRunning` at once (a start beyond that stops
/// the one unused longest), and the learner's approvals. Nothing starts until a tool call needs it.
final class LSPHub: @unchecked Sendable {
    static let shared = LSPHub()
    static let maxRunning = 3
    static let idleSeconds: TimeInterval = 600

    let specs: [LSPServerSpec]
    private let instances = Locked<[String: LSPInstance]>([:])
    private let processApprovals = Locked<Set<String>>([])
    let maxRunning: Int
    let idleSeconds: TimeInterval
    let backoff: Backoff

    init(specs: [LSPServerSpec] = LSPServers.builtIn, maxRunning: Int = LSPHub.maxRunning, idleSeconds: TimeInterval = LSPHub.idleSeconds,
         backoff: Backoff = Backoff(initial: 1, max: 8)) {
        self.specs = specs; self.maxRunning = maxRunning; self.idleSeconds = idleSeconds; self.backoff = backoff
    }

    private static func key(_ folder: URL, _ id: String) -> String { folder.standardizedFileURL.path + "\n" + id }

    func instance(_ spec: LSPServerSpec, executable: String, folder: URL) -> LSPInstance {
        let k = Self.key(folder, spec.id)
        return instances.mutate { all in
            if let i = all[k], i.executable == executable { return i }
            if let old = all[k] { Task { await old.stop() } }
            let i = LSPInstance(spec: spec, executable: executable, folder: folder, hub: self, idleSeconds: idleSeconds, backoff: backoff)
            all[k] = i
            return i
        }
    }
    func existing(_ id: String, folder: URL) -> LSPInstance? { instances.get()[Self.key(folder, id)] }
    var all: [LSPInstance] { Array(instances.get().values) }

    /// Stops the least recently used running servers so that `instance` fits within the limit.
    func makeRoom(for instance: LSPInstance) async {
        let others = all.filter { $0 !== instance && $0.isRunning }.sorted { $0.lastUsed < $1.lastUsed }
        guard others.count >= maxRunning else { return }
        for i in others.prefix(others.count - maxRunning + 1) {
            i.log.note("stopped to make room for \(instance.spec.title)")
            await i.stop()
        }
    }

    func shutdownNow() { for i in all { i.terminateNow() } }

    // MARK: Approval

    /// Language servers run project code (rust-analyzer: build scripts and proc macros; gopls: `go list`; clangd and the
    /// TypeScript server read project config), so a folder's first use of a server needs the learner's yes. The answer is
    /// stored in the app's settings, never in the folder. `approveForProcess` is for headless runs and tests: it lasts
    /// until the process ends and is written nowhere.
    func approveForProcess(folder: URL, server: String = "*") { processApprovals.mutate { _ = $0.insert(Self.key(folder, server)) } }

    func processApproved(_ id: String, folder: URL) -> Bool {
        let p = processApprovals.get()
        return p.contains(Self.key(folder, id)) || p.contains(Self.key(folder, "*"))
    }

    func isApproved(_ id: String, folder: URL, conversationID: String, interactions: InteractionCenter? = nil) async -> Bool {
        let k = Self.key(folder, id)
        if processApprovals.get().contains(k) || processApprovals.get().contains(Self.key(folder, "*")) { return true }
        return await MainActor.run {
            let app = AppModel.shared
            return (app.settings.value.lspApproved[folder.path] ?? []).contains(id) || (interactions ?? app.interactions).isGranted(Self.grant(id), conversationID: conversationID)
        }
    }
    static func grant(_ id: String) -> String { "lsp:" + id }
    static func declined(_ id: String) -> String { "lsp-declined:" + id }

    /// The question, for the permission gate: nil when this folder already approved the server.
    @MainActor static func approvalRequest(_ spec: LSPServerSpec, executable: String, ws: Workspace) -> ApprovalRequest {
        ApprovalRequest(
            title: "Allow Teacher to start the \(spec.title) language server in “\(ws.name)”?",
            detail: """
                \(executable)

                It gives Teacher the compiler's view of this code (definitions, types, errors). A language server reads this folder's \
                project files and can run its code while it analyses them: \(spec.id == "rust-analyzer" ? "rust-analyzer runs build scripts and procedural macros" : spec.id == "gopls" ? "gopls runs `go list`" : "it follows the project's configuration"). \
                Allow it only for code you trust.
                """,
            options: [ApprovalOption(id: "folder", label: "Allow \(spec.title) in this folder", style: .primary),
                      ApprovalOption(id: "lesson", label: "Allow for this lesson only"),
                      ApprovalOption(id: "deny", label: "Don't allow", style: .danger)])
    }
}
