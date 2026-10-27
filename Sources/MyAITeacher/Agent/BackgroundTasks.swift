import Foundation

/// Everything running in the background, in one list for the Tasks panel (Claude Code's background tasks): the agents'
/// shell jobs (builds and test runs, servers and watchers), sub-agents, MCP servers, and the app's own jobs (memory
/// consolidation, embedding warm-up, compaction, maintenance). Each with its times: when it was asked for, when it began
/// (and so how long it waited), how long it has run or took, and how it ended.
struct BackgroundTask: Identifiable, Sendable, Equatable {
    enum Kind: String, Sendable { case shell, server, agent, mcp, app
        var title: String {
            switch self { case .shell: "Command"; case .server: "Server"; case .agent: "Sub-agent"; case .mcp: "MCP server"; case .app: "App job" }
        }
        var symbol: String {
            switch self { case .shell: "terminal"; case .server: "server.rack"; case .agent: "person.2"; case .mcp: "puzzlepiece.extension"; case .app: "gearshape.2" }
        }
    }
    enum State: String, Sendable { case queued, running, done, failed, stopped
        var active: Bool { self == .queued || self == .running }
    }
    let id: String
    var kind: Kind
    var title: String
    var detail: String?
    /// The lesson it belongs to (nil: the app's).
    var conversationID: String?
    var handle: String?
    var queuedAt: Date?
    var startedAt: Date?
    var endedAt: Date?
    var state: State
    var exitCode: Int?
    var url: String?
    var pid: Int?
    var restarts = 0
    /// What it's doing now, or why it ended.
    var note: String?

    /// How long it waited between being asked for and starting.
    var waited: TimeInterval? {
        guard let q = queuedAt, let s = startedAt else { return nil }
        let w = s.timeIntervalSince(q)
        return w >= 0.05 ? w : nil
    }
    /// How long it has run (to now) or ran.
    func ran(now: Date = Date()) -> TimeInterval? { startedAt.map { (endedAt ?? now).timeIntervalSince($0) } }
}

/// The app's own jobs (`Runtime.job`, `Runtime.call`): asked for, started, ended. The last 40 finished are kept.
final class AppJobs: @unchecked Sendable {
    static let shared = AppJobs()
    private let lock = NSLock()
    private var tasks: [String: BackgroundTask] = [:]
    private var finished: [String] = []

    func queued(_ id: String, name: String) {
        lock.lock(); defer { lock.unlock() }
        tasks[id] = BackgroundTask(id: "app:" + id, kind: .app, title: name, queuedAt: Date(), state: .queued)
    }
    func started(_ id: String, attempt: Int) {
        lock.lock(); defer { lock.unlock() }
        guard var t = tasks[id] else { return }
        if t.startedAt == nil { t.startedAt = Date() }
        t.state = .running; t.restarts = max(0, attempt - 1); t.endedAt = nil; t.note = nil   // a restart runs again
        tasks[id] = t
    }
    func ended(_ id: String, error: String?) {
        lock.lock(); defer { lock.unlock() }
        guard var t = tasks[id], t.endedAt == nil || error != nil, t.state != .failed else { return }   // its first end stands
        t.endedAt = t.endedAt ?? Date(); t.state = error == nil ? .done : .failed; t.note = error
        if t.startedAt == nil { t.startedAt = t.endedAt }
        tasks[id] = t
        if !finished.contains(id) { finished.append(id) }
        while finished.count > 40 { tasks[finished.removeFirst()] = nil }
    }
    func list() -> [BackgroundTask] { lock.lock(); defer { lock.unlock() }; return Array(tasks.values) }
}

@MainActor
enum BackgroundTasks {
    /// Everything now, running first (oldest first), then what ended (latest first).
    static func snapshot(app: AppModel = .shared) -> [BackgroundTask] {
        var out: [BackgroundTask] = []
        for j in ShellJobs.shared.all() {
            let server = ShellJob.looksLikeServer(j.command) || !j.urls.isEmpty
            let code = j.exitCode.map(Int.init)
            let state: BackgroundTask.State = j.isRunning ? .running : j.stopped ? .stopped : code == 0 ? .done : .failed
            out.append(BackgroundTask(id: "shell:\(j.conversationID):\(j.handle ?? j.command)", kind: server ? .server : .shell, title: j.title,
                                      detail: j.command, conversationID: j.conversationID, handle: j.handle, queuedAt: j.started, startedAt: j.started,
                                      endedAt: j.isRunning ? nil : (j.endedAt ?? Date()), state: state, exitCode: j.isRunning ? nil : code,
                                      url: j.urls.first.map(openable), pid: Int(j.pid)))
        }
        for r in SubAgentCenter.shared.runs {
            let state: BackgroundTask.State = switch r.state { case .running: .running; case .done: .done; case .stopped: .stopped; case .failed: .failed }
            var detail = [r.config.map { $0.type.name }, r.config.map { $0.model }].compactMap { $0 }.joined(separator: " · ")
            if r.steps > 0 { detail += (detail.isEmpty ? "" : " · ") + "\(r.steps) steps, \(r.totalUsage.total) tokens" }
            out.append(BackgroundTask(id: "agent:" + r.id, kind: .agent, title: r.title, detail: detail.isEmpty ? nil : detail,
                                      conversationID: r.conversationID, handle: r.handle, queuedAt: r.startedAt, startedAt: r.startedAt,
                                      endedAt: r.endedAt, state: state, restarts: r.restarts, note: r.status))
        }
        for i in MCPHub.shared.all {
            let s = i.status
            let state: BackgroundTask.State = switch s.phase {
            case .idle: .stopped; case .starting, .restarting: .queued; case .ready: .running; case .failed: .failed; case .stopped: .stopped
            }
            out.append(BackgroundTask(id: "mcp:\(i.folder.path):\(i.config.name)", kind: .mcp, title: i.config.name,
                                      detail: (s.tools.map { "\($0.count) tools · " } ?? "") + i.folder.lastPathComponent,
                                      startedAt: s.startedAt, state: state, pid: s.pid.map(Int.init), restarts: s.restarts, note: s.lastError))
        }
        out += AppJobs.shared.list()
        let running = out.filter { $0.state.active }.sorted { ($0.startedAt ?? .distantFuture) < ($1.startedAt ?? .distantFuture) }
        let ended = out.filter { !$0.state.active }.sorted { ($0.endedAt ?? .distantPast) > ($1.endedAt ?? .distantPast) }
        return running + ended.prefix(50)
    }

    /// A server's "every address" URL as one a browser opens: http://[::]:8799/ → http://localhost:8799/.
    nonisolated static func openable(_ url: String) -> String {
        url.replacingOccurrences(of: "://[::]", with: "://localhost").replacingOccurrences(of: "://0.0.0.0", with: "://localhost")
    }

    /// How many are running now (the sidebar's badge).
    static var runningCount: Int { snapshot().filter { $0.state.active }.count }

    /// Whether it can be stopped from the panel, and stops it.
    static func canStop(_ t: BackgroundTask) -> Bool { t.state.active && t.kind != .app }
    static func stop(_ t: BackgroundTask) {
        switch t.kind {
        case .shell, .server:
            if let conv = t.conversationID, let h = t.handle, let j = ShellJobs.shared.job(conv, h) { j.stop() }
        case .agent:
            SubAgentCenter.shared.runs.first { "agent:" + $0.id == t.id }?.stop()
        case .mcp:
            if let i = MCPHub.shared.all.first(where: { "mcp:\($0.folder.path):\($0.config.name)" == t.id }) { Task { await i.stop() } }
        case .app: break
        }
        ActivityLog.record("task.stop", conv: t.conversationID, ["kind": .string(t.kind.rawValue), "title": .string(t.title)])
    }

    /// "2m 14s", "1h 3m", "850 ms".
    nonisolated static func duration(_ s: TimeInterval) -> String {
        if s < 1 { return "\(Int((s * 1000).rounded())) ms" }
        let n = Int(s.rounded())
        if n < 60 { return "\(n)s" }
        if n < 3600 { return "\(n / 60)m \(n % 60)s" }
        return "\(n / 3600)h \((n % 3600) / 60)m"
    }
}
