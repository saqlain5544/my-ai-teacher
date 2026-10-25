import Foundation

/// A lightweight process's identity, unique for the app's lifetime (like an Erlang pid).
struct PID: Hashable, Sendable, Comparable, CustomStringConvertible {
    let id: UInt64
    var description: String { "<\(id)>" }
    static func < (a: PID, b: PID) -> Bool { a.id < b.id }
    private static let counter = Locked<UInt64>(0)
    static func next() -> PID { PID(id: counter.mutate { $0 += 1; return $0 }) }
}

/// Why a process ended. `.normal` and `.shutdown` are deliberate; everything else is a crash: it propagates over links
/// and is what `transient` children are restarted for.
enum ExitReason: Sendable, Equatable, CustomStringConvertible {
    case normal                    // the body returned
    case shutdown                  // stopped on purpose (stop(), its supervisor, a parent shutting down)
    case crashed(String)           // the body threw
    case timeout(TimeInterval)     // the watchdog fired: no heartbeat for this long
    case linked(PID, String)       // a linked process crashed
    case killed                    // didn't end within its shutdown grace after a stop, and was abandoned

    var isCrash: Bool { switch self { case .normal, .shutdown: false; default: true } }
    var description: String {
        switch self {
        case .normal: "normal"
        case .shutdown: "shutdown"
        case .crashed(let m): "crashed: \(m)"
        case .timeout(let s): "watchdog: no progress for \(Int(s)) s"
        case .linked(let p, let m): "linked process \(p) died (\(m))"
        case .killed: "killed (ignored the stop)"
        }
    }
}

/// A value behind a lock, for state read synchronously from any thread (metrics, mailbox depth, control flags).
final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    @discardableResult func mutate<R>(_ f: (inout T) -> R) -> R { lock.withLock { f(&value) } }
}

/// FIFO mailbox over an AsyncStream: any number of senders, one receiver (the owning process's body).
/// Timeouts and non-blocking drains work with markers queued behind the messages, so a waiting `next()` is never
/// cancelled (cancelling it would finish the stream for good).
final class Mailbox<M: Sendable>: @unchecked Sendable {
    fileprivate enum Envelope: Sendable { case message(M), marker(UInt64) }
    private let input: AsyncStream<Envelope>.Continuation
    private var iterator: AsyncStream<Envelope>.Iterator   // touched only by the receiving process (and `remaining`)
    private let counts = Locked((queued: 0, marker: UInt64(0)))
    private let receiving = Locked(false)

    init() {
        let (stream, input) = AsyncStream.makeStream(of: Envelope.self)
        self.input = input
        iterator = stream.makeAsyncIterator()
    }

    /// Messages waiting to be received.
    var depth: Int { counts.get().queued }

    /// False once the mailbox is closed (its process ended).
    @discardableResult func send(_ m: M) -> Bool {
        counts.mutate { $0.queued += 1 }   // before the yield, so a fast receiver never counts below zero
        if case .terminated = input.yield(.message(m)) { counts.mutate { $0.queued -= 1 }; return false }
        return true
    }

    /// The next message; nil when the mailbox is closed, the receiver is cancelled, or `timeout` passes first.
    func receive(timeout: TimeInterval? = nil) async -> M? {
        var timer: Task<Void, Never>?
        var mark: UInt64?
        if let timeout {
            let id = newMarker()
            mark = id
            timer = Task { [input] in
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1e9))
                if !Task.isCancelled { input.yield(.marker(id)) }
            }
        }
        defer { timer?.cancel(); receiving.mutate { $0 = false } }
        receiving.mutate { $0 = true }
        while let e = await iterator.next() {
            switch e {
            case .message(let m): counts.mutate { $0.queued -= 1 }; return m
            case .marker(let id): if id == mark { return nil }   // a stale marker from an earlier timed receive is skipped
            }
        }
        return nil
    }

    /// Everything already waiting, without blocking: a marker goes in behind it, and FIFO order means all that comes
    /// out before the marker was queued first.
    func drain() async -> [M] {
        let id = newMarker()
        guard case .enqueued = input.yield(.marker(id)) else { return [] }
        receiving.mutate { $0 = true }
        defer { receiving.mutate { $0 = false } }
        var out: [M] = []
        while let e = await iterator.next() {
            if case .message(let m) = e { counts.mutate { $0.queued -= 1 }; out.append(m) }
            else if case .marker(let x) = e, x == id { break }
        }
        return out
    }

    func close() { input.finish() }

    /// What was sent but never received, once the owning process has ended: a successor (a restarted incarnation)
    /// takes it over, so nothing sent to a process that crashed is lost. Closes the mailbox. Empty if a receive is still
    /// running after a second (an abandoned body stuck inside one): two receivers must never touch the iterator at once.
    func remaining() async -> [M] {
        input.finish()
        for _ in 0..<50 where receiving.get() { try? await Task.sleep(nanoseconds: 20_000_000) }
        guard receiving.mutate({ busy in defer { busy = true }; return !busy }) else { return [] }
        defer { receiving.mutate { $0 = false } }
        var out: [M] = []
        while let e = await iterator.next() { if case .message(let m) = e { counts.mutate { $0.queued -= 1 }; out.append(m) } }
        return out
    }

    private func newMarker() -> UInt64 { counts.mutate { $0.marker += 1; return $0.marker } }
}

/// The parts of a process touched synchronously from any thread: its tasks, heartbeat and stop request.
/// The first `end` wins; later ones (the abandoned body finishing after all, a second stop) are ignored.
final class ProcControl: @unchecked Sendable {
    private struct State {
        var work: Task<Void, Never>?, dog: Task<Void, Never>?, killer: Task<Void, Never>?
        var stopReason: ExitReason?
        var ended = false, started = false
        var startWaiters: [CheckedContinuation<Void, Never>] = []
        var lastBeat = Date()
    }
    private let state = Locked(State())
    fileprivate var onEnd: (@Sendable (ExitReason) -> Void)?

    func beat() { state.mutate { $0.lastBeat = Date() } }
    var silence: TimeInterval { Date().timeIntervalSince(state.get().lastBeat) }
    var stopReason: ExitReason? { state.get().stopReason }
    var hasEnded: Bool { state.get().ended }

    /// The body has begun running (its task is scheduled and inside the body).
    fileprivate func markStarted() { wake { $0.started = true } }
    /// Returns once the body has begun, or the process ended before it could. A supervisor starts children one after
    /// another this way, as OTP does: a later child never starts before the one it may depend on.
    func started() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = state.mutate { s -> Bool in
                if s.started || s.ended { return true }
                s.startWaiters.append(c); return false
            }
            if now { c.resume() }
        }
    }
    private func wake(_ change: (inout State) -> Void) {
        let waiters = state.mutate { s -> [CheckedContinuation<Void, Never>] in change(&s); defer { s.startWaiters = [] }; return s.startWaiters }
        waiters.forEach { $0.resume() }
    }

    fileprivate func attach(work: Task<Void, Never>, dog: Task<Void, Never>?) {
        let late = state.mutate { s -> Bool in
            if s.ended { return true }
            s.work = work; s.dog = dog
            return false
        }
        if late { work.cancel(); dog?.cancel() }
    }

    /// Asks the body to stop (cancellation); after `grace` it is abandoned and the process ends `.killed`.
    func stop(_ reason: ExitReason = .shutdown, grace: TimeInterval = 2) {
        let work = state.mutate { s -> Task<Void, Never>? in
            if s.ended { return nil }
            if s.stopReason == nil { s.stopReason = reason }
            return s.work
        }
        guard let work else { return }
        work.cancel()
        guard grace.isFinite else { return }
        let killer = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, grace) * 1e9))
            if !Task.isCancelled { self?.end(.killed) }
        }
        let kept = state.mutate { s -> Bool in
            guard !s.ended else { return false }
            s.killer?.cancel(); s.killer = killer
            return true
        }
        if !kept { killer.cancel() }
    }

    fileprivate func end(_ r: ExitReason) {
        let tasks = state.mutate { s -> [Task<Void, Never>?]? in
            if s.ended { return nil }
            s.ended = true
            defer { s.work = nil; s.dog = nil; s.killer = nil }
            return [s.work, s.dog, s.killer]
        }
        guard let tasks else { return }
        tasks.forEach { $0?.cancel() }
        wake { _ in }   // ended before it started: nobody waits forever
        onEnd?(r)
    }
}

/// A lightweight process (Erlang-style, on Swift concurrency — not an OS process): a body running in its own task, a
/// mailbox, links and monitors. A thrown error or a watchdog timeout is a crash the process's supervisor can act on;
/// a Swift trap is not (it still ends the app — see ARCHITECTURE.md › Runtime).
actor Proc {
    nonisolated let pid: PID
    nonisolated let name: String
    nonisolated let startedAt = Date()
    nonisolated let control = ProcControl()
    nonisolated let mailboxDepth: @Sendable () -> Int
    private(set) var exitReason: ExitReason?
    private var links: [PID: Proc] = [:]
    private var monitors: [UInt64: @Sendable (PID, ExitReason) -> Void] = [:]
    private var nextMonitor: UInt64 = 0
    private var waiters: [CheckedContinuation<ExitReason, Never>] = []
    /// Set: exit signals from linked processes are handed here instead of taking this process down (supervisors).
    private var trap: (@Sendable (PID, ExitReason) -> Void)?

    private init(name: String, mailboxDepth: @escaping @Sendable () -> Int) {
        pid = .next(); self.name = name; self.mailboxDepth = mailboxDepth
    }

    /// Starts `body` as a process. `watchdog` is the longest it may go without a heartbeat (receiving a message, or
    /// `ctx.heartbeat()`) before it is cancelled and ends `.timeout` — a hung body is abandoned, never awaited.
    static func spawn<M: Sendable>(_ name: String, of _: M.Type = M.self, watchdog: TimeInterval? = nil,
                                   _ body: @escaping @Sendable (ProcContext<M>) async throws -> Void) -> ProcRef<M> {
        let mailbox = Mailbox<M>()
        let proc = Proc(name: name, mailboxDepth: { mailbox.depth })
        let control = proc.control
        control.onEnd = { reason in
            mailbox.close()
            Task { await proc.terminate(reason) }
        }
        Runtime.registry.add(proc)
        let ctx = ProcContext(pid: proc.pid, name: name, mailbox: mailbox, control: control)
        let work = Task.detached {
            let reason: ExitReason
            control.markStarted()
            do {
                try await body(ctx)
                reason = control.stopReason ?? .normal
            } catch {
                // A stop shows up as cancellation (or whatever the body throws on it): it ends with the stop's reason.
                reason = control.stopReason ?? (error is CancellationError ? .shutdown : .crashed(Self.describe(error)))
            }
            control.end(reason)
        }
        let dog = watchdog.map { limit in
            Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: UInt64(min(1, max(0.02, limit / 4)) * 1e9))
                    if control.silence > limit, !control.hasEnded {
                        control.stop(.timeout(limit), grace: .infinity)   // cancels the body; it ends now, not after a grace
                        control.end(.timeout(limit))
                        return
                    }
                }
            }
        }
        control.attach(work: work, dog: dog)
        return ProcRef(proc: proc, mailbox: mailbox)
    }

    static func describe(_ e: Error) -> String {
        (e as? LocalizedError)?.errorDescription ?? String(describing: e)
    }

    // MARK: Exit, links, monitors

    private func terminate(_ reason: ExitReason) {
        guard exitReason == nil else { return }
        exitReason = reason
        Runtime.registry.remove(pid)
        let ls = links, ms = monitors, ws = waiters
        links = [:]; monitors = [:]; waiters = []
        for w in ws { w.resume(returning: reason) }
        for (_, m) in ms { m(pid, reason) }
        for (_, other) in ls { Task { await other.linkedExit(from: pid, reason) } }
    }

    private func linkedExit(from other: PID, _ reason: ExitReason) {
        guard links.removeValue(forKey: other) != nil else { return }
        signal(from: other, reason)
    }

    /// An exit signal: a trapping process is told; otherwise anything but a normal exit takes this one down too.
    private func signal(from other: PID, _ reason: ExitReason) {
        guard exitReason == nil else { return }
        if let trap { trap(other, reason); return }
        if reason != .normal { control.stop(.linked(other, reason.description), grace: 1) }
    }

    /// Links both ways: when either ends abnormally, the other gets the signal. Linking to an ended process signals at
    /// once. Our side is recorded before the await, so an exit that races the link still finds it.
    func link(_ other: Proc) async {
        guard other !== self, exitReason == nil else { return }
        links[other.pid] = other
        if let r = await other.acceptLink(self), links.removeValue(forKey: other.pid) != nil { signal(from: other.pid, r) }
    }
    private func acceptLink(_ from: Proc) -> ExitReason? {
        if let r = exitReason { return r }
        links[from.pid] = from
        return nil
    }
    func unlink(_ other: Proc) async {
        links[other.pid] = nil
        await other.dropLink(pid)
    }
    private func dropLink(_ p: PID) { links[p] = nil }

    func trapExits(_ handler: (@Sendable (PID, ExitReason) -> Void)?) { trap = handler }

    /// Calls `handler` once when this process ends (at once if it already has). Returns a token for `demonitor`.
    @discardableResult func monitor(_ handler: @escaping @Sendable (PID, ExitReason) -> Void) -> UInt64 {
        if let r = exitReason { handler(pid, r); return 0 }
        nextMonitor += 1
        monitors[nextMonitor] = handler
        return nextMonitor
    }
    func demonitor(_ token: UInt64) { monitors[token] = nil }

    /// Waits for this process to end.
    func wait() async -> ExitReason {
        if let r = exitReason { return r }
        return await withCheckedContinuation { waiters.append($0) }
    }
}

/// A typed handle to a process: send to its mailbox, stop it, wait for it.
struct ProcRef<M: Sendable>: Sendable {
    let proc: Proc
    let mailbox: Mailbox<M>
    var pid: PID { proc.pid }
    var name: String { proc.name }
    @discardableResult func send(_ m: M) -> Bool { mailbox.send(m) }
    func stop(_ reason: ExitReason = .shutdown, grace: TimeInterval = 2) { proc.control.stop(reason, grace: grace) }
    func wait() async -> ExitReason { await proc.wait() }
}

/// What a process body gets: its identity and mailbox, and the heartbeat its watchdog listens for.
struct ProcContext<M: Sendable>: Sendable {
    let pid: PID
    let name: String
    let mailbox: Mailbox<M>
    let control: ProcControl

    /// The next message (a heartbeat); nil when the process is stopping or `timeout` passes.
    func receive(timeout: TimeInterval? = nil) async -> M? {
        heartbeat()
        let m = await mailbox.receive(timeout: timeout)
        heartbeat()
        return m
    }
    /// Messages already waiting, without blocking.
    func drain() async -> [M] { heartbeat(); return await mailbox.drain() }
    /// Tells the watchdog the body is making progress.
    func heartbeat() { control.beat() }
    var isStopping: Bool { Task.isCancelled || control.stopReason != nil }
}
