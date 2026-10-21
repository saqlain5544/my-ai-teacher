import XCTest
import Darwin
@testable import MyAITeacher

/// Footprint and latency of the memory index as the learner's memory grows (512-dim vectors, ~14-word contents).
/// 10k (in RAM) and 50k (past the budget) always run. MEMORY_SCALE_500K=1 adds 500k (a ~0.5 GB database) and times
/// the first duplicate sweep at each size (this data is near-duplicate-heavy: the sweep hits its 1,000-merge cap).
/// Latencies are only meaningful in release: `swift build -c release --build-tests -Xswiftc -enable-testing`, then
/// `xcrun xctest -XCTest MyAITeacherTests.MemoryScaleTests .build/out/Products/Release/MyAITeacherTests.xctest`.
final class MemoryScaleTests: XCTestCase {
    private static let topics = ["derivatives", "integrals", "vectors", "matrices", "probability", "verbs", "nouns", "poetry", "loops", "recursion",
                                 "photosynthesis", "cells", "atoms", "bonds", "forces", "energy", "waves", "optics", "history", "economics"]
    private static let queries = ["help me with derivatives", "poetry meters", "recursion in python", "what is energy", "capital of France",
                                  "vectors and matrices", "why do waves interfere", "economics of trade"]

    /// Writes rows straight to SQLite (no index is built yet), so the first search measures the index from nothing.
    private func fill(_ db: Database, _ n: Int) throws {
        let base = (0..<40).map { i in Embedder.shared.vector("Learner struggles with \(Self.topics[i % 20]) when problems involve step \(i)")! }
        var rng = SystemRandomNumberGenerator()
        let now = Date()
        for start in stride(from: 0, to: n, by: 10_000) {
            try db.transaction {
                for i in start..<min(n, start + 10_000) {
                    var v = base[i % base.count]
                    for j in stride(from: i % 7, to: v.count, by: 7) { v[j] += Float.random(in: -0.05...0.05, using: &rng) }
                    let t = Self.topics[i % 20], u = Self.topics[(i / 3) % 20]
                    let c = "Note \(i) on \(t): mixes it up with \(u) at step \(i % 113), variant \(i % 997), case item\(i)"
                    try db.execute("INSERT INTO memories(kind, subject, content, importance, origin, created_at, updated_at, vec, norm) VALUES(?,?,?,?,?,?,?,?,?)",
                                   MemoryKind.allCases[i % 7].rawValue, u, c, 0.5, "inferred", now, now, Embedder.int8(v), MemoryText.norm(c))
                }
            }
        }
    }

    /// SQLite's page caches (8 MB a connection, filled by any full read) are released first: what's left is the index.
    private func settledFootprint() -> Int64 {
        Database.releaseAllMemory(); malloc_zone_pressure_relief(nil, 0)
        return Int64(MemoryGovernor.footprint() ?? 0)
    }

    private func median(_ xs: [Double]) -> Double { xs.sorted()[xs.count / 2] }

    func testFootprintAndLatency() throws {
        var sizes = [10_000, 50_000]
        let full = ProcessInfo.processInfo.environment["MEMORY_SCALE_500K"] != nil
        if full { sizes.append(500_000) }
        let qvs = Self.queries.map { Embedder.shared.vector($0).map(Embedder.normalized) }
        for n in sizes {
            let fx = try MemoryFixture(), store = fx.hub.learner
            let t0 = Date()
            try fill(fx.learnerDB, n)
            let insert = Date().timeIntervalSince(t0)
            let before = settledFootprint()
            _ = store.search("warm up", limit: 8, minRelevance: 0.4, queryVector: qvs[0])
            let added = settledFootprint() - before, bytes = store.indexBytes
            XCTAssertEqual(store.count(), n)
            if n <= 10_000 {
                XCTAssertGreaterThan(bytes, 0, "fits the budget: indexed in RAM")
                // Under 1 KB a memory, plus the scan's reusable buffers (a constant malloc keeps).
                XCTAssertLessThan(bytes, n * 1024)
                XCTAssertLessThan(added, Int64(n) * 1024 + (4 << 20))
            } else {
                XCTAssertEqual(bytes, 0, "past the budget: nothing in RAM per memory")
                XCTAssertLessThan(added, 8 << 20, "flat whatever the count")
            }
            let search = zip(Self.queries, qvs).map { q, v in
                let s = Date(); _ = store.search(q, limit: 8, minRelevance: 0.4, queryVector: v); return Date().timeIntervalSince(s) * 1000
            }
            let recall = Self.queries.map { q in let s = Date(); _ = fx.hub.recall(q, core: ""); return Date().timeIntervalSince(s) * 1000 }
            print(String(format: "[memory-scale] %dk: insert %.1f s, footprint %+.1f MB (%.0f B/memory; index %.1f MB), search median %.1f ms (max %.1f), recall median %.1f ms",
                         n / 1000, insert, Double(added) / 1_048_576, Double(added) / Double(n), Double(bytes) / 1_048_576,
                         median(search), search.max()!, median(recall)))
            guard full else { continue }
            // The first sweep after a bulk load: 2,000 changed memories against everything.
            let m0 = Date()
            let merged = store.maintenance().merged, took = Date().timeIntervalSince(m0), after = settledFootprint() - before
            // A run's work is capped (2,000 changed, 1,000 merges), so what it leaves behind is a constant too.
            if bytes == 0 { XCTAssertLessThan(after, 16 << 20, "the sweep stays flat too") }
            print(String(format: "[memory-scale] %dk: first sweep %.1f s, %d merged, footprint after %+.1f MB", n / 1000, took, merged, Double(after) / 1_048_576))
        }
    }

    /// Past the budget, retrieval on the labelled set returns what the in-RAM index returns: per-turn recall exactly;
    /// broader searches up to near-ties (FTS5's porter stemmer counts documents a little differently from our stems).
    func testDiskPathAgreesWithTheIndex() throws {
        let fx = try MemoryFixture()
        _ = LabeledSet.load(into: fx.hub)
        let qs = (LabeledSet.queries + LabeledSet.heldOut).map(\.0)
        let run = { (qs.map { fx.hub.search($0, limit: 2, minScore: MemoryTuning.recallThreshold).map(\.id) },
                     qs.map { Set(fx.hub.search($0, limit: 5, minScore: MemoryTuning.searchThreshold).map(\.id)) }) }
        let inRAM = run()
        let saved = MemoryTuning.indexBudget
        MemoryTuning.indexBudget = 0
        defer { MemoryTuning.indexBudget = saved }
        MemoryStore.unloadAll()
        let onDisk = run()
        XCTAssertEqual(fx.hub.learner.indexBytes, 0)
        XCTAssertEqual(inRAM.0, onDisk.0, "per-turn recall")
        let shared = zip(inRAM.1, onDisk.1).reduce(0) { $0 + $1.0.intersection($1.1).count }, all = inRAM.1.reduce(0) { $0 + $1.count }
        print("[memory-scale] disk path vs index on the labelled set: recall identical, broad search \(shared)/\(all) results shared")
        XCTAssertGreaterThanOrEqual(Double(shared), 0.9 * Double(all))
    }
}

/// The quality, dedup, reflection, routing, consolidation and correctness tests again, with every store on the disk path
/// (lexical candidates from FTS5, vectors streamed from SQLite): past the budget the results keep their meaning.
private func onDiskPath(_ body: () throws -> Void) rethrows {
    let saved = MemoryTuning.indexBudget
    MemoryTuning.indexBudget = 0
    defer { MemoryTuning.indexBudget = saved }
    try body()
}

final class MemoryQualityOnDiskTests: MemoryQualityTests {
    override func invokeTest() { onDiskPath { super.invokeTest() } }
    override class var scaleLimitMs: Double { 80 }   // ~13 ms measured; room for a loaded machine (e2e builds alongside)
}
final class MemoryModelOnDiskTests: MemoryModelTests {
    override func invokeTest() { onDiskPath { super.invokeTest() } }
}
final class MemoryCorrectnessOnDiskTests: MemoryCorrectnessTests {
    override func invokeTest() { onDiskPath { super.invokeTest() } }
}
