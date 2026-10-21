import Foundation
import AppKit
import os

/// Local-only telemetry recorder. Never makes network requests.
///
/// `record` is the only call on the caller's thread: it takes a lock and appends to an in-memory buffer (O(1)).
/// A utility-QoS queue flushes the buffer to SQLite every `flushInterval` seconds and on quit, and prunes raw rows
/// older than 30 days a few times a day. Disabled via Settings → General (UserDefaults `telemetryEnabled`).
final class Telemetry: @unchecked Sendable {
    static let enabledKey = "telemetryEnabled"
    static let shared = Telemetry()

    private static let registerDefaults: Void = UserDefaults.standard.register(defaults: [enabledKey: true])
    static var isEnabled: Bool {
        _ = registerDefaults
        return UserDefaults.standard.bool(forKey: enabledKey)
    }

    struct Overhead: Sendable {
        var events = 0
        var dropped = 0
        var recordNanos: UInt64 = 0       // caller-thread time inside record() (lock + append)
        var mapNanos: UInt64 = 0          // main-thread time building events from metrics (TelemetryExtension)
        var flushes = 0
        var flushNanos: UInt64 = 0        // background time writing to SQLite
        var lastFlushEvents = 0
        var lastFlushMillis = 0.0
        var sampleNanos: UInt64 = 0       // background time sampling resources
        var samples = 0
        var recordMicrosPerEvent: Double { events > 0 ? Double(recordNanos) / Double(events) / 1000 : 0 }
        var mapMicrosPerEvent: Double { events > 0 ? Double(mapNanos) / Double(events) / 1000 : 0 }
        var flushMicrosPerEvent: Double { events > 0 ? Double(flushNanos) / Double(events) / 1000 : 0 }
    }

    private let lock = OSAllocatedUnfairLock()
    private var buffer: [TelemetryEvent] = []
    private var stats = Overhead()
    private var enabledFlag: Bool
    private(set) var store: TelemetryStore?
    private let queue = DispatchQueue(label: "app.teacher.telemetry", qos: .utility)
    private var lastPrune: Double = 0
    private var defaultsObserver: NSObjectProtocol?
    private var quitObserver: NSObjectProtocol?
    let sampler = ResourceSampler()

    let flushInterval: Double
    let maxBuffer: Int

    init(store: TelemetryStore? = nil, flushInterval: Double = 5, maxBuffer: Int = 20_000, enabled: Bool? = nil) {
        self.store = store
        self.flushInterval = flushInterval
        self.maxBuffer = maxBuffer
        self.enabledFlag = enabled ?? Telemetry.isEnabled
    }

    var enabled: Bool { lock.withLock { enabledFlag } }

    /// Opens the store and starts the flush service + resource sampler. Call once at app start.
    func start(db: Database) {
        let s = TelemetryStore(db: db)
        lock.withLock { store = s }
        defaultsObserver = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: nil) { [weak self] _ in
            self?.setEnabled(Telemetry.isEnabled)
        }
        quitObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { [weak self] _ in
            self?.flushSync()
        }
        // A supervised service (Runtime › services): a flush that hangs (a locked database) is ended by the watchdog and
        // the service restarts with backoff. The work itself stays on the telemetry queue (serial, utility QoS).
        Task { [weak self, queue, flushInterval] in
            await Runtime.every("telemetry.flush", seconds: flushInterval, watchdog: 60) {
                await withCheckedContinuation { c in queue.async { self?.tick(); c.resume() } }
            }
        }
        queue.async { [weak self] in self?.pruneIfDue(force: true) }
    }

    func setEnabled(_ on: Bool) {
        lock.withLock {
            enabledFlag = on
            if !on { buffer.removeAll(keepingCapacity: false) }
        }
    }

    // MARK: Recording (any thread)

    func record(_ e: TelemetryEvent) {
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.withLock {
            guard enabledFlag else { return }
            if buffer.count >= maxBuffer { stats.dropped += 1; return }
            buffer.append(e)
            stats.events += 1
            stats.recordNanos += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
        }
    }

    func record(_ events: [TelemetryEvent]) {
        guard !events.isEmpty else { return }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        lock.withLock {
            guard enabledFlag else { return }
            let room = max(0, maxBuffer - buffer.count)
            if room < events.count { stats.dropped += events.count - room }
            buffer.append(contentsOf: events.prefix(room))
            stats.events += min(room, events.count)
            stats.recordNanos += clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
        }
    }

    /// Accounts time the caller spent building events (reported as main-thread overhead).
    func addMappingTime(_ nanos: UInt64) { lock.withLock { stats.mapNanos += nanos } }
    func addSampleTime(_ nanos: UInt64) { lock.withLock { stats.sampleNanos += nanos; stats.samples += 1 } }

    var overhead: Overhead { lock.withLock { stats } }
    var buffered: Int { lock.withLock { buffer.count } }

    // MARK: Flushing (telemetry queue)

    private func tick() {
        if enabled { sampler.sample(into: self) }
        flushNow()
        pruneIfDue(force: false)
    }

    /// Writes the buffer synchronously on the caller's thread (used by the timer, on quit, and by tests).
    func flushNow() {
        let (batch, store): ([TelemetryEvent], TelemetryStore?) = lock.withLock {
            let b = buffer
            buffer.removeAll(keepingCapacity: true)
            return (b, self.store)
        }
        guard let store, !batch.isEmpty else { return }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        do { try store.write(batch) } catch { AppLog.write("telemetry flush failed: \(error.localizedDescription)") }
        let dt = clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0
        lock.withLock {
            stats.flushes += 1; stats.flushNanos += dt
            stats.lastFlushEvents = batch.count; stats.lastFlushMillis = Double(dt) / 1e6
        }
    }

    /// Flush on quit (blocks briefly on the telemetry queue so it doesn't race the timer).
    func flushSync() { queue.sync { flushNow() } }

    /// Runs `body` on the telemetry queue after pending writes (dashboard reads).
    func read<T: Sendable>(_ body: @escaping @Sendable (TelemetryStore) -> T) async -> T? {
        await withCheckedContinuation { cont in
            queue.async { [weak self] in
                self?.flushNow()
                cont.resume(returning: self?.store.map(body))
            }
        }
    }

    func clear() {
        queue.async { [weak self] in
            guard let self else { return }
            self.lock.withLock { self.buffer.removeAll() }
            self.store?.clear()
        }
    }

    private func pruneIfDue(force: Bool) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastPrune > 6 * 3600, let store else { return }
        lastPrune = now
        store.prune(now: now)
    }
}

// MARK: - Process info

enum ProcessClock {
    /// Wall-clock time this process started (kinfo_proc.p_starttime).
    static let startTime: Double = {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0 else { return Date().timeIntervalSince1970 }
        let tv = info.kp_proc.p_un.__p_starttime
        return Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6
    }()
}

/// Samples app + web-content-process resource usage (off the main thread).
final class ResourceSampler: @unchecked Sendable {
    private let lock = OSAllocatedUnfairLock()
    private var webPIDs: Set<pid_t> = []
    private var last: (wall: Double, cpu: Double, web: [pid_t: Double])?
    private var lastSample: Double = 0
    var interval: Double = 60

    func registerWebProcess(_ pid: pid_t) {
        guard pid > 0 else { return }
        _ = lock.withLock { webPIDs.insert(pid) }
    }

    func sample(into t: Telemetry, force: Bool = false) {
        let now = Date().timeIntervalSince1970
        guard force || now - lastSample >= interval else { return }
        lastSample = now
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let footprint = Double(Self.footprintBytes()) / 1_048_576
        let cpu = Self.cpuSeconds()
        var webMB = 0.0, webCPU: [pid_t: Double] = [:]
        var alive = 0
        for pid in lock.withLock({ webPIDs }) {
            guard let r = Self.processUsage(pid) else { _ = lock.withLock { webPIDs.remove(pid) }; continue }
            alive += 1
            webMB += Double(r.footprint) / 1_048_576
            webCPU[pid] = r.cpu
        }
        var attrs: [String: Double] = ["footprintMB": footprint.rounded(toPlaces: 1), "webProcs": Double(alive)]
        if alive > 0 { attrs["webMB"] = webMB.rounded(toPlaces: 1) }
        if let l = last, now - l.wall > 1 {
            attrs["cpuPct"] = (max(0, cpu - l.cpu) / (now - l.wall) * 100).rounded(toPlaces: 2)
            let webDelta = webCPU.reduce(0.0) { acc, kv in acc + max(0, kv.value - (l.web[kv.key] ?? kv.value)) }
            if alive > 0 { attrs["webCpuPct"] = (webDelta / (now - l.wall) * 100).rounded(toPlaces: 2) }
        }
        last = (now, cpu, webCPU)
        t.record(TelemetryEvent(ts: now, kind: .resource, attrs: attrs))
        t.addSampleTime(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0)
    }

    static func footprintBytes() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : 0
    }

    static func cpuSeconds() -> Double {
        var u = rusage()
        getrusage(RUSAGE_SELF, &u)
        return Double(u.ru_utime.tv_sec) + Double(u.ru_utime.tv_usec) / 1e6 + Double(u.ru_stime.tv_sec) + Double(u.ru_stime.tv_usec) / 1e6
    }

    private static let timebase: Double = {
        var tb = mach_timebase_info_data_t()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    /// Footprint and CPU seconds of another process owned by this user.
    static func processUsage(_ pid: pid_t) -> (footprint: UInt64, cpu: Double)? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V4, $0) }
        }
        guard rc == 0 else { return nil }
        let cpu = Double(info.ri_user_time + info.ri_system_time) * timebase / 1e9
        return (info.ri_phys_footprint, cpu)
    }
}

private extension Double {
    func rounded(toPlaces p: Int) -> Double { let m = pow(10, Double(p)); return (self * m).rounded() / m }
}
