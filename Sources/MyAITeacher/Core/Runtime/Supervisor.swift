import Foundation

/// When a supervisor restarts a child that ended: always · only after a crash · never.
enum Restart: String, Sendable { case permanent, transient, temporary }

/// At most `maxRestarts` restarts within `period` seconds; one more and the supervisor (or the child, for a child's own
/// limit) gives up.
struct Intensity: Sendable, Equatable {
    var maxRestarts: Int
    var period: TimeInterval
}

/// Delay before the n-th restart in a row (n counted within the intensity period): initial × factor^(n−1), capped.
struct Backoff: Sendable, Equatable {
    var initial: TimeInterval = 0.5
    var factor = 2.0
    var max: TimeInterval = 30
    func delay(_ n: Int) -> TimeInterval { n <= 0 ? 0 : Swift.min(max, initial * pow(factor, Double(n - 1))) }
    static let none = Backoff(initial: 0, factor: 1, max: 0)
}

/// How to start and restart one child.
struct ChildSpec: Sendable {
    let id: String
    var restart: Restart = .permanent
    /// A limit for this child alone, on top of the supervisor's: one flaky job among many gives up by itself instead of
    /// exhausting the supervisor's intensity for its siblings. nil = only the supervisor's.
    var intensity: Intensity? = nil
    var backoff: Backoff? = nil
    /// How long stopping it waits before the child is abandoned (`.killed`).
    var shutdownGrace: TimeInterval = 2
    /// Starts one incarnation; `attempt` is 0 the first time, then the number of restarts so far.
    let start: @Sendable (_ attempt: Int) async -> Proc
    /// Called once when the child is gone for good: it ended and isn't restarted, its own limit was reached, it was
    /// terminated, or its supervisor stopped or gave up.
    var onExit: (@Sendable (ExitReason) -> Void)? = nil

    /// A supervisor as a child (supervision trees).
    static func supervisor(_ id: String, strategy: Strategy = .oneForOne, intensity: Intensity, backoff: Backoff = Backoff(),
                           restart: Restart = .permanent, children: [ChildSpec] = []) -> ChildSpec {
        ChildSpec(id: id, restart: restart, shutdownGrace: 30, start: { _ in
            await Supervisor.start(id, strategy: strategy, intensity: intensity, backoff: backoff, children: children).process.proc
        })
    }
}

/// one-for-one: only the child that ended restarts. rest-for-one: the children started after it are stopped (newest
/// first) and everything from it onwards restarts in order — for children that depend on the ones before them.
enum Strategy: String, Sendable { case oneForOne, restForOne }

/// Erlang/OTP-style supervisor: starts children in order, monitors them, restarts them by their `Restart` and the
/// strategy after a backoff, and gives up past its restart intensity — stopping every child and ending its own process
/// with a crash, which its parent supervisor sees like any child's. Children are linked to the supervisor's process,
/// so they end with it even if it is abandoned.
actor Supervisor {
    nonisolated let name: String
    nonisolated let strategy: Strategy
    nonisolated let intensity: Intensity
    nonisolated let backoff: Backoff
    private struct Child {
        var spec: ChildSpec
        var proc: Proc?
        var attempt = 0
        var recent: [Date] = []
    }
    private var children: [Child] = []
    private var log: [Date] = []
    private var stopping = false
    private(set) var restarts = 0
    /// The supervisor's own process (set while it boots, before anyone else sees the supervisor).
    nonisolated var process: ProcRef<Never> { box.get()! }
    private nonisolated let box = Locked<ProcRef<Never>?>(nil)

    private init(name: String, strategy: Strategy, intensity: Intensity, backoff: Backoff) {
        self.name = name; self.strategy = strategy; self.intensity = intensity; self.backoff = backoff
    }

    static func start(_ name: String, strategy: Strategy = .oneForOne, intensity: Intensity = Intensity(maxRestarts: 3, period: 5),
                      backoff: Backoff = Backoff(), children: [ChildSpec] = []) async -> Supervisor {
        let s = Supervisor(name: name, strategy: strategy, intensity: intensity, backoff: backoff)
        await s.boot(children)
        return s
    }

    private func boot(_ specs: [ChildSpec]) async {
        let sup = self
        // The supervisor's own process only waits; when it is stopped (or gives up) it takes its children down first.
        let ref = Proc.spawn(name, of: Never.self) { ctx in
            _ = await ctx.receive()
            await sup.terminateChildren(ctx.control.stopReason ?? .shutdown)
        }
        box.mutate { $0 = ref }
        await ref.proc.trapExits { _, _ in }   // children's exits arrive through monitors
        Runtime.registry.addSupervisor(self)
        for spec in specs { _ = await startChild(spec) }
    }

    // MARK: Children

    /// Adds and starts a child (dynamic supervision). False if one with this id is already here (running, or waiting
    /// to restart) or the supervisor is stopping — which makes ids a way to keep one job of a kind at a time.
    @discardableResult func startChild(_ spec: ChildSpec) async -> Bool {
        guard !stopping, index(spec.id) == nil else { return false }
        children.append(Child(spec: spec))
        await launch(spec.id)
        return true
    }

    /// Stops a child and forgets it (no restart); its `onExit` gets `.shutdown`.
    func terminate(_ id: String) async {
        guard let k = index(id) else { return }
        let c = children.remove(at: k)
        if let p = c.proc { p.control.stop(.shutdown, grace: c.spec.shutdownGrace); _ = await p.wait() }
        c.spec.onExit?(.shutdown)
    }

    var childIDs: [String] { children.map(\.spec.id) }
    func child(_ id: String) -> Proc? { index(id).flatMap { children[$0].proc } }

    /// Stops every child (newest first), then the supervisor's own process.
    func stop() async {
        process.stop(.shutdown, grace: 30)
        _ = await process.wait()
    }

    private func index(_ id: String) -> Int? { children.firstIndex { $0.spec.id == id } }

    private func launch(_ id: String) async {
        guard let i = index(id) else { return }
        let spec = children[i].spec
        let proc = await spec.start(children[i].attempt)
        // Removed, replaced or shutting down while it started: it isn't ours to keep.
        guard !stopping, let j = index(id), children[j].proc == nil else {
            proc.control.stop(.shutdown, grace: spec.shutdownGrace); return
        }
        children[j].proc = proc
        await process.proc.link(proc)
        let sup = self
        await proc.monitor { pid, reason in Task { await sup.childExited(id, pid, reason) } }
        await proc.control.started()   // in order: the next child starts once this one runs
    }

    private func childExited(_ id: String, _ pid: PID, _ reason: ExitReason) async {
        guard !stopping, let i = index(id), children[i].proc?.pid == pid else { return }   // stale: stopped or replaced
        children[i].proc = nil
        let spec = children[i].spec
        let wanted: Bool = switch spec.restart {
        case .permanent: true
        case .transient: reason.isCrash
        case .temporary: false
        }
        guard wanted else { children.remove(at: i); spec.onExit?(reason); return }
        let now = Date()
        let window = spec.intensity?.period ?? intensity.period
        children[i].recent = children[i].recent.filter { now.timeIntervalSince($0) < window } + [now]
        if let own = spec.intensity, children[i].recent.count > own.maxRestarts {
            children.remove(at: i)
            spec.onExit?(.crashed("gave up after \(own.maxRestarts) restart\(own.maxRestarts == 1 ? "" : "s") in \(Int(own.period)) s (last: \(reason))"))
            return
        }
        log = log.filter { now.timeIntervalSince($0) < intensity.period } + [now]
        if log.count > intensity.maxRestarts { await giveUp(reason); return }
        restarts += 1
        Runtime.registry.noteRestart(id)
        let delay = (spec.backoff ?? backoff).delay(children[i].recent.count)
        var again = [id]
        if strategy == .restForOne {
            again += children[(i + 1)...].map(\.spec.id)
            for sid in again.dropFirst().reversed() {
                guard let k = index(sid), let p = children[k].proc else { continue }
                children[k].proc = nil   // its exit is now stale: it is restarted below, not on its own
                p.control.stop(.shutdown, grace: children[k].spec.shutdownGrace)
                _ = await p.wait()
            }
        }
        for sid in again { if let k = index(sid) { children[k].attempt += 1 } }
        // The actor stays responsive during the backoff (other children's exits, stops); state is re-checked after.
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }
        for sid in again where !stopping {
            if let k = index(sid), children[k].proc == nil { await launch(sid) }
        }
    }

    private func giveUp(_ last: ExitReason) async {
        let why = ExitReason.crashed("\(name) gave up: more than \(intensity.maxRestarts) restarts in \(Int(intensity.period)) s (last: \(last))")
        await terminateChildren(why)
        process.stop(why, grace: 1)   // its own process ends with the crash: the parent decides what happens next
    }

    private func terminateChildren(_ reason: ExitReason) async {
        guard !stopping else { return }
        stopping = true
        for c in children.reversed() {
            if let p = c.proc { p.control.stop(.shutdown, grace: c.spec.shutdownGrace); _ = await p.wait() }
            c.spec.onExit?(reason.isCrash ? reason : .shutdown)
        }
        children = []
        Runtime.registry.removeSupervisor(self)
    }
}
