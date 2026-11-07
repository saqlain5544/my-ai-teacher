import Foundation
import XCTest

/// How much slower this machine is right now than the idle one the time limits were set on. Performance gates scale
/// their limit by it, so a busy machine (a build, other tests) doesn't fail them, while a real regression (an
/// algorithm gone quadratic is 10x or more) still does.
enum MachineSpeed {
    /// Median seconds the calibration took on an idle machine (debug build).
    static let idleSeconds = 0.03
    /// A fixed amount of pure CPU work: integer mixing and a few allocations, so neither a tight loop nor the allocator dominates.
    @inline(never) static func work() -> Int {
        var h = 1469598103934665603, keep = 0
        for i in 0..<400_000 {
            h = (h ^ i) &* 1099511628211
            if i % 5_000 == 0 { keep &+= Array(repeating: h, count: 64).count }
        }
        return h &+ keep
    }
    static func seconds() -> Double {
        let t = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        if work() == 0 { print("") }
        return Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t) / 1e9
    }
    /// Measured at each call (load changes during a run); never below 1, so a fast machine keeps the written limit.
    static var slowdown: Double {
        let runs = (0..<5).map { _ in seconds() }.sorted()
        return min(40, max(1, runs[2] / idleSeconds))
    }
    /// A limit written for an idle machine, scaled to the current one.
    static func scaled(_ limit: Double) -> Double { limit * slowdown }
    /// The same for a limit that guards "did not wait out a longer wait": never more than `cap`, so a regression to that wait still fails.
    static func scaled(_ limit: Double, under cap: Double) -> Double { min(limit * slowdown, cap) }
}

final class MachineSpeedTests: XCTestCase {
    func testPrintsTheCalibration() {
        let one = MachineSpeed.seconds()
        print(String(format: "MACHINE SPEED: one run %.4f s (idle %.4f), slowdown x%.2f", one, MachineSpeed.idleSeconds, MachineSpeed.slowdown))
        XCTAssertGreaterThanOrEqual(MachineSpeed.slowdown, 1)
    }
}
