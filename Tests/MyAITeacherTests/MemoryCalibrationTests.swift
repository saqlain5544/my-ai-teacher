import XCTest
@testable import MyAITeacher

/// Sweeps retrieval tunables on the labelled set and prints the best configurations (no assertions).
/// Run: MEMORY_SWEEP=1 swift test --filter MemoryCalibrationTests
final class MemoryCalibrationTests: XCTestCase {
    func testSweep() throws {
        guard ProcessInfo.processInfo.environment["MEMORY_SWEEP"] != nil else { throw XCTSkip("set MEMORY_SWEEP=1") }
        let fx = try MemoryFixture()
        let ids = LabeledSet.load(into: fx.hub)
        let vecs = LabeledSet.queries.map { Embedder.shared.vector($0.0).map(Embedder.normalized) }
        let saved = (MemoryTuning.lexK, MemoryTuning.semLow, MemoryTuning.semHigh, MemoryTuning.semWeight, MemoryTuning.conceptWeight)
        var rows: [(Double, String)] = []
        for lexK in [0.6, 1.0, 1.5] { for low in [0.5, 0.6, 0.7] { for high in [0.85, 0.95] { for w in [0.3, 0.55, 0.8] { for cw in [0.5, 0.75] {
            MemoryTuning.lexK = lexK; MemoryTuning.semLow = low; MemoryTuning.semHigh = high; MemoryTuning.semWeight = w; MemoryTuning.conceptWeight = cw
            for th in stride(from: 0.4, through: 0.8, by: 0.05) {
                var tp = 0, fp = 0, rel = 0
                for (i, q) in LabeledSet.queries.enumerated() {
                    let want = Set(q.1.compactMap { ids[$0] })
                    let got = fx.hub.search(q.0, limit: 2, minScore: th, queryVector: vecs[i]).map(\.id)
                    rel += min(2, want.count)
                    for g in got { if want.contains(g) { tp += 1 } else { fp += 1 } }
                }
                let p = tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp), r = Double(tp) / Double(rel)
                let f = 2 * p * r / max(1e-9, p + r)
                // Precision matters more than recall for injected context: F0.5.
                let f05 = 1.25 * p * r / max(1e-9, 0.25 * p + r)
                rows.append((f05, String(format: "F0.5 %.3f F1 %.3f P %.2f R %.2f | lexK %.1f low %.2f high %.2f w %.2f cw %.2f th %.2f fp %d", f05, f, p, r, lexK, low, high, w, cw, th, fp)))
            }
        } } } } }
        (MemoryTuning.lexK, MemoryTuning.semLow, MemoryTuning.semHigh, MemoryTuning.semWeight, MemoryTuning.conceptWeight) = saved
        for r in rows.sorted(by: { $0.0 > $1.0 }).prefix(25) { print(r.1) }
    }
}
