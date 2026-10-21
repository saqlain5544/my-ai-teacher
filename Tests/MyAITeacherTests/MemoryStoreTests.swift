import XCTest
@testable import MyAITeacher

/// The store's statements use their index: no full scan, no bloom filter over every row, no sort of every row (there is
/// no ANALYZE, so a plan that is fine on a small table is the plan at 500k).
final class MemoryPlanTests: XCTestCase {
    func testStatementsSearchInsteadOfScanning() throws {
        let fx = try MemoryFixture()
        let ordered = [MemorySQL.page, MemorySQL.changed, MemorySQL.topOfKind, MemorySQL.sameNorm, MemorySQL.scan, MemorySQL.rows, MemorySQL.probes]
        for sql in ordered + [MemorySQL.members, MemorySQL.ofConcept, MemorySQL.span, MemorySQL.ftsRows, MemorySQL.ftsCount, MemorySQL.count] {
            let plan = try fx.learnerDB.query("EXPLAIN QUERY PLAN " + sql).compactMap { $0.string("detail") }
            let text = plan.joined(separator: " / ")
            XCTAssertFalse(plan.contains { $0.hasPrefix("SCAN memories") || $0.hasPrefix("SCAN m ") || $0 == "SCAN m" }, "\(sql.prefix(70)): \(text)")
            XCTAssertFalse(text.contains("BLOOM"), "\(sql.prefix(70)): \(text)")
            if ordered.contains(sql) { XCTAssertFalse(text.contains("TEMP B-TREE"), "\(sql.prefix(70)): \(text)") }
        }
        XCTAssertTrue(try fx.learnerDB.query("EXPLAIN QUERY PLAN " + MemorySQL.ftsRows).contains { $0.string("detail")?.contains("memories_active") == true })
    }
}

/// The duplicate sweep's cursor: an older build's marker, the per-run caps, resuming.
final class MemorySweepTests: XCTestCase {
    func testAnOlderBuildsMarkerIsReadAndLeftAsItWas() throws {
        let fx = try MemoryFixture(), st = fx.hub.learner
        st.bulkInsert([(.fact, "Collects antique maps of Persia", nil, nil), (.fact, "collects antique maps of persia!", nil, nil)])
        try fx.learnerDB.execute("UPDATE memories SET updated_at = 1700000000")
        try fx.learnerDB.execute("INSERT INTO memory_meta(key, value) VALUES('sweep_learner', '1700000500')")
        st.bulkInsert([(.fact, "Bakes sourdough bread on Sundays", nil, nil), (.fact, "bakes sourdough bread on sundays.", nil, nil)])
        XCTAssertEqual(st.maintenance().merged, 1, "only what changed after the old marker")
        XCTAssertEqual(st.count(), 3)
        XCTAssertEqual(MemorySchema.meta(fx.learnerDB, "sweep_learner"), "1700000500")
        XCTAssertEqual(MemorySchema.meta(fx.learnerDB, "sweep2_learner")?.split(separator: " ").count, 2)
    }

    func testARunStopsAtItsCapsAndTheNextCarriesOn() throws {
        let fx = try MemoryFixture(), st = fx.hub.learner
        // 1,200 copies of one fact: the merge cap stops the run inside one memory's candidates; it is checked again next run.
        st.bulkInsert((0..<1200).map { _ in (MemoryKind.fact, "Rides a red bicycle to the library", nil, nil) })
        XCTAssertEqual(st.maintenance().merged, MemoryStore.sweepMerges)
        XCTAssertEqual(st.count(), 200)
        XCTAssertEqual(st.maintenance().merged, 199)
        XCTAssertEqual(st.count(), 1)
        // 2,100 distinct facts: a run takes 2,000 of them; the next takes the rest.
        let distinct = (0..<2100).map { i in (MemoryKind.knowledge, "Distinct fact \(i) about field \(i * 7 % 1013)", String?.none, [Float]?.none) }
        st.bulkInsert(distinct)
        st.maintenance()
        let ids = try fx.learnerDB.query("SELECT id FROM memories WHERE kind='knowledge' ORDER BY id").compactMap { $0.int("id") }
        XCTAssertEqual(MemorySchema.meta(fx.learnerDB, "sweep2_learner")?.split(separator: " ").last.map(String.init), String(ids[1999]))
        st.maintenance()
        XCTAssertEqual(MemorySchema.meta(fx.learnerDB, "sweep2_learner")?.split(separator: " ").last.map(String.init), String(ids[2099]))
    }
}

/// The in-RAM index and its budget.
final class MemoryIndexTests: XCTestCase {
    private static let things = ["violins", "volcanoes", "orchids", "submarines", "glaciers", "beetles", "telescopes", "pottery", "chess openings",
                                 "sourdough", "comets", "origami", "lighthouses", "fossils", "cacti", "bridges", "jazz records", "kites", "maps"]
    private static let places = ["Lisbon", "Oslo", "Kyoto", "Lagos", "Quito", "Hanoi", "Dakar", "Lima", "Perth", "Tunis", "Riga", "Cusco",
                                 "Sapporo", "Zanzibar", "Tbilisi", "Valparaiso", "Galway", "Bergen", "Cairo", "Havana", "Kraków", "Muscat", "Nairobi"]
    /// Memories different enough that dedup keeps every one (two share at most two of their stems).
    private func distinct(_ i: Int) -> String { "Collects \(Self.things[i % 19]) in \(Self.places[i / 19 % 23]) since \(1900 + i)" }

    /// Loads under 80% of the budget, leaves past 100%, comes back once removals bring it under 80% again — so a load near
    /// the line doesn't flip with each write.
    func testTheBudgetHasHysteresis() throws {
        let fx = try MemoryFixture(), st = fx.hub.learner, dim = Embedder.shared.dimension!
        let saved = MemoryTuning.indexBudget
        defer { MemoryTuning.indexBudget = saved }
        MemoryTuning.indexBudget = MemoryIndex.cost(100, dim: dim) * 5 / 4
        st.bulkInsert((0..<100).map { (MemoryKind.fact, distinct($0), nil, nil) })
        XCTAssertGreaterThan(st.indexBytes, 0, "at 80% of the budget: in RAM")
        for i in 100..<108 { XCTAssertEqual(st.add(kind: .fact, content: distinct(i), subject: nil, importance: 0.5, origin: "explicit", source: nil).status, .added) }
        XCTAssertGreaterThan(st.indexBytes, 0, "a few writes later: still in RAM")
        var i = 108
        while st.indexBytes > 0, i < 400 {
            XCTAssertEqual(st.add(kind: .fact, content: distinct(i), subject: nil, importance: 0.5, origin: "explicit", source: nil).status, .added)
            i += 1
        }
        XCTAssertEqual(st.indexBytes, 0, "past the budget: the disk path")
        XCTAssertGreaterThan(i, 125, "not before the budget is reached")
        let ids = try fx.learnerDB.query("SELECT id FROM memories WHERE archived=0 ORDER BY id").compactMap { $0.int("id") }
        for id in ids.prefix(ids.count - 90) { st.archive(Int64(id), status: "test") }
        XCTAssertGreaterThan(st.indexBytes, 0, "under 80% again: back in RAM")
        XCTAssertEqual(st.search(distinct(i - 1), limit: 1, minRelevance: 0.1).first?.content, distinct(i - 1))
    }

    /// The vector size comes from the model: a malformed blob first in the table is no vector, not the size of the rest.
    func testAMalformedVectorDoesNotSetTheSize() throws {
        let fx = try MemoryFixture(), st = fx.hub.learner
        try fx.learnerDB.execute("INSERT INTO memories(kind, content, created_at, updated_at, vec, norm) VALUES('fact', 'A broken row', 0, 0, ?, 'broken row')", Data([1, 2, 3, 4, 5, 6, 7]))
        let v = Embedder.shared.vector("Enjoys hiking in the mountains every summer")!
        st.bulkInsert([(.fact, "Enjoys hiking in the mountains every summer", nil, v)])
        // A query sharing no words, with that memory's own vector: found only through its vector.
        XCTAssertEqual(st.search("zzz", limit: 1, minRelevance: 0.3, queryVector: Embedder.normalized(v)).first?.content, "Enjoys hiking in the mountains every summer")
    }
}

/// Past the budget, the score of a memory is what the index gives it — archived rows (still in FTS5) and terms with
/// more rows than the FTS read cap included.
final class MemoryDiskParityTests: XCTestCase {
    private func relevance(_ fx: MemoryFixture, _ query: String, onDisk: Bool) -> Double? {
        let saved = MemoryTuning.indexBudget
        defer { MemoryTuning.indexBudget = saved }
        if onDisk { MemoryTuning.indexBudget = 0 }
        MemoryStore.unloadAll()
        return fx.hub.learner.search(query, limit: 1, minRelevance: 0).first?.relevance
    }

    func testArchivedRowsDoNotChangeTheScore() throws {
        for archived in [300, 3000] {
            let fx = try MemoryFixture(), st = fx.hub.learner
            st.bulkInsert((0..<50).map { (MemoryKind.fact, "Unrelated fact \($0) about gardening", nil, nil) })
            st.bulkInsert([(.fact, "Practises the oud every evening before dinner", nil, Embedder.shared.vector("Practises the oud every evening before dinner"))])
            st.bulkInsert((0..<archived).map { (MemoryKind.fact, "Practised the oud on evening \($0)", nil, nil) })
            try fx.learnerDB.execute("UPDATE memories SET archived=1 WHERE content LIKE 'Practised the oud on evening %'")
            let ram = try XCTUnwrap(relevance(fx, "oud practice in the evening", onDisk: false))
            let disk = try XCTUnwrap(relevance(fx, "oud practice in the evening", onDisk: true))
            XCTAssertEqual(disk, ram, accuracy: 1e-9, "\(archived) archived rows share its terms")
            XCTAssertGreaterThan(ram, 0.65)
        }
    }

    func testATermPastTheReadCapIsCountedExactly() throws {
        let fx = try MemoryFixture(), st = fx.hub.learner
        st.bulkInsert((0..<1500).map { (MemoryKind.fact, "Owns violin number \($0)", nil, nil) })
        st.bulkInsert((0..<400).map { (MemoryKind.fact, "Owned violin number \($0) once", nil, nil) })
        try fx.learnerDB.execute("UPDATE memories SET archived=1 WHERE content LIKE 'Owned violin number %'")
        st.bulkInsert([(.fact, "Tunes the violin with a metronome app", nil, nil)])
        let ram = try XCTUnwrap(relevance(fx, "violin metronome", onDisk: false))
        let disk = try XCTUnwrap(relevance(fx, "violin metronome", onDisk: true))
        XCTAssertEqual(disk, ram, accuracy: 1e-9)
    }
}

final class MemoryHubTopTests: XCTestCase {
    /// What consolidation shows the model: the most important memories of both scopes, episodes left out, without
    /// reading every memory.
    func testTopAcrossScopesSkipsTheExcludedKind() throws {
        let fx = try MemoryFixture()
        fx.hub.add(kind: .fact, content: "Keeps bees on the roof of the school", importance: 0.9, origin: "explicit")
        fx.hub.add(kind: .goal, content: "Wants to run a marathon in under four hours", importance: 0.7, origin: "explicit")
        fx.hub.add(kind: .fact, content: "This folder holds the bee-keeping logbook", importance: 0.8, origin: "explicit", scope: .folder)
        fx.hub.add(kind: .episode, content: "Covered hive inspections and swarm signs in depth", importance: 1, origin: "explicit", scope: .folder)
        fx.hub.add(kind: .preference, content: "Likes short answers with one example", importance: 0.2, origin: "explicit")
        XCTAssertEqual(fx.hub.top(excluding: .episode, limit: 3).map(\.importance), [0.9, 0.8, 0.7])
    }
}
