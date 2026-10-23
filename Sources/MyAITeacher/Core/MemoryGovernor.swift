import Foundation
import Darwin

/// Keeps the app's own memory near-constant. Lessons, images and pages are bounded by design (windows, blobs on disk,
/// byte-capped caches); this is the safety net: it watches the app's footprint and the system's memory pressure, and
/// when either rises it drops everything that can be rebuilt — fetched pages, memory indexes, SQLite page caches, the
/// transcript's render caches — and hands the freed pages back to macOS.
@MainActor
final class MemoryGovernor {
    static let shared = MemoryGovernor()
    /// Above this the app sheds on its own, before macOS has to ask (and long before it would kill the app).
    static let softLimit: UInt64 = 1_536 << 20
    /// Posted when caches should go; observers (transcript pages) drop theirs. `object` is true when critical.
    static let shedNotification = Notification.Name("MemoryGovernor.shed")
    private var source: DispatchSourceMemoryPressure?
    private var timer: Timer?
    private(set) var lastShed: Date?

    func start() {
        guard source == nil else { return }
        URLCache.shared.memoryCapacity = 4 << 20
        let s = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .main)
        s.setEventHandler { [weak self, weak s] in
            let critical = s?.data.contains(.critical) == true
            MainActor.assumeIsolated { self?.shed(critical: critical, reason: critical ? "critical system memory pressure" : "system memory pressure") }
        }
        s.activate()
        source = s
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.check() } }
    }

    private func check() {
        guard let f = Self.footprint(), f > Self.softLimit, lastShed.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return }
        shed(critical: false, reason: "footprint \(f >> 20) MB over \(Self.softLimit >> 20) MB")
    }

    func shed(critical: Bool, reason: String) {
        let before = Self.footprint() ?? 0
        lastShed = Date()
        Task { await FetchCache.shared.clear() }
        MemoryStore.unloadAll()
        Database.releaseAllMemory()
        BlobStore.releaseMemory()
        URLCache.shared.removeAllCachedResponses()
        NotificationCenter.default.post(name: Self.shedNotification, object: critical)
        malloc_zone_pressure_relief(nil, 0)
        AppLog.write("memory: shed caches (\(reason)); footprint \(before >> 20) → \((Self.footprint() ?? 0) >> 20) MB")
    }

    /// The figure macOS judges the app by (Activity Monitor's "Memory", jetsam's limit): dirty + compressed pages.
    nonisolated static func footprint() -> UInt64? {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }
        return kr == KERN_SUCCESS ? info.phys_footprint : nil
    }
}

/// Live instances of a class, held weakly (stores and databases register themselves so the governor can reach them).
final class WeakRegistry<T: AnyObject>: @unchecked Sendable {
    private struct Box { weak var value: T? }
    private var items: [Box] = []
    private let lock = NSLock()
    func add(_ v: T) { lock.withLock { items.removeAll { $0.value == nil }; items.append(Box(value: v)) } }
    var all: [T] { lock.withLock { items.compactMap(\.value) } }
}
