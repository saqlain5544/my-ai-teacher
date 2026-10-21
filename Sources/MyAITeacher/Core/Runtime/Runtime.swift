import Foundation

/// Live processes by pid and name, supervisors by name, and restart counts — read synchronously for metrics.
final class Registry: @unchecked Sendable {
    private struct State {
        var procs: [PID: Proc] = [:]
        var names: [String: PID] = [:]
        var supervisors: [String: Supervisor] = [:]
        var restarts: [String: Int] = [:]
    }
    private let state = Locked(State())

    /// Every process is registered by its name unless another live process holds it (names stay unique).
    func add(_ p: Proc) {
        state.mutate { s in
            s.procs[p.pid] = p
            if s.names[p.name] == nil { s.names[p.name] = p.pid }
        }
    }
    func remove(_ pid: PID) {
        state.mutate { s in
            guard let p = s.procs.removeValue(forKey: pid) else { return }
            if s.names[p.name] == pid { s.names[p.name] = nil }
        }
    }
    func whereis(_ name: String) -> Proc? { state.mutate { s in s.names[name].flatMap { s.procs[$0] } } }
    func noteRestart(_ id: String) { state.mutate { $0.restarts[id, default: 0] += 1 } }
    func restarts(_ id: String) -> Int { state.get().restarts[id] ?? 0 }

    func addSupervisor(_ s: Supervisor) { state.mutate { $0.supervisors[s.name] = s } }
    func removeSupervisor(_ s: Supervisor) { state.mutate { if $0.supervisors[s.name] === s { $0.supervisors[s.name] = nil } } }
    func supervisor(_ name: String) -> Supervisor? { state.get().supervisors[name] }

    func snapshot() -> RuntimeMetrics {
        let s = state.get()
        let now = Date()
        let procs = s.procs.values.sorted { $0.pid < $1.pid }.map {
            RuntimeMetrics.Process(pid: $0.pid, name: $0.name, mailbox: $0.mailboxDepth(), uptime: now.timeIntervalSince($0.startedAt),
                                   restarts: s.restarts[$0.name] ?? 0)
        }
        return RuntimeMetrics(processes: procs, restarts: s.restarts)
    }
}

struct RuntimeMetrics: Sendable {
    struct Process: Sendable { let pid: PID; let name: String; let mailbox: Int; let uptime: TimeInterval; let restarts: Int }
    let processes: [Process]
    /// Restarts per child id since launch (children that ended keep their count).
    let restarts: [String: Int]
    var count: Int { processes.count }
    var mailboxDepth: Int { processes.reduce(0) { $0 + $1.mailbox } }
    var totalRestarts: Int { restarts.values.reduce(0, +) }
    var json: JSON {
        ["processes": .number(Double(count)), "mailbox": .number(Double(mailboxDepth)), "restarts": .number(Double(totalRestarts)),
         "byName": .array(processes.map { ["pid": .string($0.pid.description), "name": .string($0.name), "mailbox": .number(Double($0.mailbox)),
                                           "uptime": .number($0.uptime.rounded()), "restarts": .number(Double($0.restarts))] })]
    }
}

struct RuntimeError: LocalizedError, Sendable {
    let message: String
    var errorDescription: String? { message }
}

/// The app's supervision tree:
///
///     root (one-for-one, never gives up; backoff to 30 s)
///     ├── services  (one-for-one, 5 in 60 s)   permanent periodic work: telemetry.flush
///     ├── jobs      (one-for-one, 20 in 60 s)  one-shot background work: memory.reflect:<lesson>, memory.consolidate,
///     │                                         embeddings.warmup, lesson.compact#n (each with its own restart limit)
///     └── agents    (one-for-one, 30 in 60 s)  sub-agent runs agent:A1… (each 3 restarts in 60 s, backoff 1 → 8 s)
///
/// Started on first use. A supervisor that gives up is restarted by root with backoff; its dynamic children are gone
/// (their `onExit` ran), as with an Erlang simple_one_for_one supervisor.
enum Runtime {
    static let registry = Registry()

    private static let root: Task<Supervisor, Never> = Task {
        await Supervisor.start("root", intensity: Intensity(maxRestarts: .max, period: 60), backoff: Backoff(initial: 1, max: 30), children: [
            .supervisor("services", intensity: Intensity(maxRestarts: 5, period: 60)),
            .supervisor("jobs", intensity: Intensity(maxRestarts: 20, period: 60)),
            .supervisor("agents", intensity: Intensity(maxRestarts: 30, period: 60)),
        ])
    }

    /// A supervisor of the tree by name, waiting briefly if it is being restarted.
    static func supervisor(_ name: String) async -> Supervisor? {
        _ = await root.value
        for _ in 0..<100 {
            if let s = registry.supervisor(name) { return s }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return nil
    }

    static var metrics: RuntimeMetrics { registry.snapshot() }

    /// Background work under `jobs`: a watchdog, a restart with backoff after a crash (up to `limit`), and a place in the
    /// metrics. One job per name at a time: false when `name` is already running or waiting to restart.
    @discardableResult
    static func job(_ name: String, restart: Restart = .transient, limit: Intensity = Intensity(maxRestarts: 2, period: 60),
                    watchdog: TimeInterval? = 300, _ work: @escaping @Sendable (_ attempt: Int) async throws -> Void) async -> Bool {
        guard let jobs = await supervisor("jobs") else { return false }
        return await jobs.startChild(ChildSpec(id: name, restart: restart, intensity: limit, backoff: Backoff(initial: 1, max: 20), start: { attempt in
            Proc.spawn(name, of: Never.self, watchdog: watchdog) { _ in try await work(attempt) }.proc
        }))
    }

    /// Runs `work` as a job and returns its result. A crash (a thrown error, the watchdog) restarts it with backoff; past
    /// `limit` this throws. Cancelling the caller stops the job.
    static func call<T: Sendable>(_ name: String, limit: Intensity = Intensity(maxRestarts: 2, period: 120), watchdog: TimeInterval? = 300,
                                  _ work: @escaping @Sendable () async throws -> T) async throws -> T {
        guard let jobs = await supervisor("jobs") else { throw RuntimeError(message: "The runtime isn't available.") }
        let id = "\(name)#\(PID.next().id)"
        let result = OneShot<T>()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<T, Error>) in
                result.attach(c)
                Task {
                    guard !result.isDone else { return }
                    let started = await jobs.startChild(ChildSpec(id: id, restart: .transient, intensity: limit, backoff: Backoff(initial: 1, max: 10), start: { _ in
                        Proc.spawn(id, of: Never.self, watchdog: watchdog) { _ in result.finish(.success(try await work())) }.proc
                    }, onExit: { reason in
                        result.finish(.failure(RuntimeError(message: "\(name) failed (\(reason)).")))
                    }))
                    if !started { result.finish(.failure(RuntimeError(message: "\(name) couldn't start."))) }
                }
            }
        } onCancel: {
            result.finish(.failure(CancellationError()))
            Task { await jobs.terminate(id) }
        }
    }

    /// A permanent periodic service under `services`: `tick` every `seconds`; a crash or a tick that hangs past
    /// `watchdog` restarts it with backoff.
    static func every(_ name: String, seconds: TimeInterval, watchdog: TimeInterval = 60, _ tick: @escaping @Sendable () async throws -> Void) async {
        guard let services = await supervisor("services") else { return }
        await services.startChild(ChildSpec(id: name, restart: .permanent, backoff: Backoff(initial: 1, max: 60), start: { _ in
            Proc.spawn(name, of: Never.self, watchdog: watchdog + seconds) { ctx in
                while !ctx.isStopping {
                    _ = await ctx.receive(timeout: seconds)   // an interruptible sleep (nothing is ever sent)
                    if ctx.isStopping { break }
                    try await tick()
                    ctx.heartbeat()
                }
            }.proc
        }))
    }
}

/// One result, from whichever side finishes first (the work, its failure, the caller's cancellation).
final class OneShot<T: Sendable>: @unchecked Sendable {
    private let state = Locked<(cont: CheckedContinuation<T, Error>?, result: Result<T, Error>?)>((nil, nil))
    var isDone: Bool { state.get().result != nil }
    func attach(_ c: CheckedContinuation<T, Error>) {
        let ready = state.mutate { s -> Result<T, Error>? in
            if let r = s.result { return r }
            s.cont = c
            return nil
        }
        if let ready { c.resume(with: ready) }
    }
    func finish(_ r: Result<T, Error>) {
        let c = state.mutate { s -> CheckedContinuation<T, Error>?? in
            guard s.result == nil else { return nil }
            s.result = r
            defer { s.cont = nil }
            return .some(s.cont)
        }
        if case .some(let cont?) = c { cont.resume(with: r) }
    }
}
