import XCTest
@testable import MyAITeacher

class MemoryQualityTests: XCTestCase {
    struct PR { var tp = 0, fp = 0, relevant = 0, emptyQueriesWithHits = 0, emptyQueries = 0, items = 0, queries = 0
        var precision: Double { tp + fp == 0 ? 1 : Double(tp) / Double(tp + fp) }
        var recall: Double { relevant == 0 ? 1 : Double(tp) / Double(relevant) }
    }

    private func evaluate(_ fx: MemoryFixture, _ ids: [String: String], _ set: [(String, Set<String>)], k: Int,
                          run: (String) -> [String], verbose: Bool) -> PR {
        var pr = PR()
        for (q, keys) in set {
            let want = Set(keys.compactMap { ids[$0] })
            let got = run(q)
            pr.queries += 1; pr.items += got.count
            pr.relevant += min(k, want.count)
            if want.isEmpty { pr.emptyQueries += 1; if !got.isEmpty { pr.emptyQueriesWithHits += 1 } }
            for g in got { if want.contains(g) { pr.tp += 1 } else { pr.fp += 1 } }
            if verbose, Set(got) != want {
                let name = { (id: String) in ids.first { $0.value == id }?.key ?? id }
                print("  · \(q)\n      want \(want.map(name).sorted()) got \(got.map(name))")
            }
        }
        return pr
    }

    /// Retrieval quality on the labelled set (calibration) and the held-out set.
    func testRetrievalPrecisionRecall() throws {
        let fx = try MemoryFixture()
        let ids = LabeledSet.load(into: fx.hub)
        for (name, set) in [("calibration", LabeledSet.queries), ("held-out", LabeledSet.heldOut)] {
            let s = evaluate(fx, ids, set, k: 2, run: { fx.hub.search($0, limit: 2, minScore: MemoryTuning.recallThreshold).map(\.id) }, verbose: true)
            print(String(format: "[memory] %@ ranking@2: precision %.2f recall %.2f (tp %d fp %d), off-topic queries with hits %d/%d",
                         name, s.precision, s.recall, s.tp, s.fp, s.emptyQueriesWithHits, s.emptyQueries))
            XCTAssertGreaterThanOrEqual(s.precision, 0.75, name)
            XCTAssertGreaterThanOrEqual(s.recall, 0.55, name)
        }
    }

    /// Production per-turn recall (with the real core block excluded): lean and selective.
    func testAutoRecallIsLean() throws {
        let fx = try MemoryFixture()
        let ids = LabeledSet.load(into: fx.hub)
        let core = fx.hub.coreBlock()
        let all = LabeledSet.queries + LabeledSet.heldOut
        // Relevant-and-not-already-in-core is what recall should add.
        let set = all.map { q in (q.0, q.1.filter { !core.contains("[#\(ids[$0]!)]") }) }
        let s = evaluate(fx, ids, set, k: 2, run: { q in fx.hub.recall(q, core: core).memories.map(\.id) }, verbose: false)
        let avg = Double(s.items) / Double(s.queries)
        print(String(format: "[memory] auto-recall: precision %.2f recall %.2f, avg %.2f items/turn, off-topic turns with injection %d/%d",
                     s.precision, s.recall, avg, s.emptyQueriesWithHits, s.emptyQueries))
        XCTAssertLessThanOrEqual(avg, 1.0)
        XCTAssertEqual(fx.hub.recall("What is the capital of Australia?", core: core).note, "")
        XCTAssertEqual(fx.hub.recall("Explain photosynthesis", core: core).note, "")
        XCTAssertLessThanOrEqual(s.emptyQueriesWithHits, 1)
        for q in all { XCTAssertLessThanOrEqual(fx.hub.recall(q.0, core: core).ids.count, 2) }
    }

    func testCoreBlockIsSmallAndStable() throws {
        let fx = try MemoryFixture()
        _ = LabeledSet.load(into: fx.hub)
        // Grow it a lot: many concepts with mastery and many facts.
        for i in 0..<300 {
            fx.study.recordAttempt(subject: ["calculus", "physics", "arabic", "python", "chemistry", "history", "music", "art"][i % 8],
                                   concept: "concept number \(i)", correct: i % 3 != 0, note: nil)
        }
        let rows = (0..<400).map { i in (kind: MemoryKind.allCases[i % 7], content: "Synthetic durable fact \(i) about topic \(i % 37) with detail", subject: String?.none, vector: [Float]?.none) }
        fx.hub.learner.bulkInsert(rows)
        let a = fx.hub.coreBlock(), b = fx.hub.coreBlock()
        let tokens = a.count / 4
        print("[memory] core block: \(a.count) chars ≈ \(tokens) tokens (with 427 memories, 305 concepts)")
        XCTAssertEqual(a, b, "core block must be stable for prompt caching")
        XCTAssertLessThan(a.count, 6000)
        XCTAssertTrue(a.contains("Learning map"))
        XCTAssertTrue(a.contains("## Profile"))
    }

    /// Median ms a 10k search or dedup write may take in a debug build (the disk-path subclass streams every vector).
    class var scaleLimitMs: Double { 30 }

    /// 10k memories: retrieval < 30 ms (warm index), writes with dedup stay fast (no scan of all memories).
    func testScale10k() throws {
        let fx = try MemoryFixture()
        let topics = ["derivatives", "integrals", "vectors", "matrices", "probability", "verbs", "nouns", "poetry", "loops", "recursion",
                      "photosynthesis", "cells", "atoms", "bonds", "forces", "energy", "waves", "optics", "history", "economics"]
        let base = (0..<40).map { i in "Learner struggles with \(topics[i % topics.count]) when problems involve step \(i)" }
        let baseVecs = base.map { Embedder.shared.vector($0)! }
        var rows: [(kind: MemoryKind, content: String, subject: String?, vector: [Float]?)] = []
        var rng = SystemRandomNumberGenerator()
        for i in 0..<10_000 {
            var v = baseVecs[i % baseVecs.count]
            for j in stride(from: i % 7, to: v.count, by: 7) { v[j] += Float.random(in: -0.05...0.05, using: &rng) }
            rows.append((MemoryKind.allCases[i % 7], "Fact \(i): \(topics[i % topics.count]) note \(i % 113) variant \(i % 997) item\(i)", topics[(i / 3) % topics.count], v))
        }
        let t0 = Date()
        fx.hub.learner.bulkInsert(rows)
        print(String(format: "[memory] bulk insert + index 10k: %.0f ms", Date().timeIntervalSince(t0) * 1000))
        XCTAssertEqual(fx.hub.learner.count(), 10_000)
        _ = fx.hub.search("warm up the embedder", limit: 5)
        var times: [Double] = []
        for q in ["help me with derivatives", "poetry meters", "recursion in python", "what is energy", "capital of France", "vectors and matrices"] {
            let s = Date()
            _ = fx.hub.recall(q, core: "")
            times.append(Date().timeIntervalSince(s) * 1000)
        }
        times.sort()
        print(String(format: "[memory] recall over 10k memories: median %.1f ms, max %.1f ms", times[times.count / 2], times.last!))
        XCTAssertLessThan(times[times.count / 2], Self.scaleLimitMs)
        var writes: [Double] = []
        for i in 0..<20 {
            let s = Date()
            fx.hub.add(kind: .fact, content: "Learner enjoys \(topics[i]) puzzles on long train rides number \(i)", origin: "explicit")
            writes.append(Date().timeIntervalSince(s) * 1000)
        }
        writes.sort()
        print(String(format: "[memory] add with dedup at 10k: median %.1f ms", writes[writes.count / 2]))
        XCTAssertLessThan(writes[writes.count / 2], Self.scaleLimitMs)
    }
}

class MemoryModelTests: XCTestCase {
    func testPolicyRejectsDerivableDetails() {
        let reject = [
            "Learner asked for the derivative of sin(x^2)",
            "Learner solved 3x + 2 = 11 and got x = 3",
            "Today the learner worked on fractions",
            "The quiz was interrupted before the learner answered",
            "Learner scored 4/5 on the chain rule quiz",
            "ok",
        ]
        for r in reject { XCTAssertNotNil(MemoryPolicy.rejection(r, kind: .fact, explicit: false), r) }
        let keep = [
            "Learner often asks for worked examples before attempting problems",
            "Preparing for the AP Calculus BC exam in May",
            "Confuses velocity and acceleration signs in projectile motion",
            "Prefers explanations in Urdu when concepts get abstract",
        ]
        for k in keep { XCTAssertNil(MemoryPolicy.rejection(k, kind: .misconception, explicit: false), k) }
        XCTAssertNil(MemoryPolicy.rejection("Asked me to remember that their exam is on 12 May", kind: .goal, explicit: true))
    }

    func testDedupMergesInsteadOfAdding() throws {
        let fx = try MemoryFixture()
        let a = fx.hub.add(kind: .preference, content: "Prefers visual explanations with diagrams")
        let b = fx.hub.add(kind: .preference, content: "prefers visual explanations with diagrams.")
        XCTAssertEqual(a.id, b.id); XCTAssertTrue(b.merged)
        let c = fx.hub.add(kind: .preference, content: "Prefers visual explanations with lots of diagrams and sketches")
        XCTAssertEqual(c.id, a.id, "near-duplicate should merge")
        XCTAssertTrue(fx.hub.get(a.id)!.content.contains("sketches"), "more specific text wins")
        XCTAssertEqual(fx.hub.get(a.id)!.evidence, 3)
        XCTAssertFalse(fx.hub.history(a.id).isEmpty, "superseded text kept as provenance")
        // Same words, different kind → separate.
        let d = fx.hub.add(kind: .goal, content: "Prefers visual explanations with diagrams")
        XCTAssertNotEqual(d.id, a.id)
        // Contradiction-ish but distinct facts both survive (resolved by the LLM, not by heuristics).
        let e = fx.hub.add(kind: .profile, content: "Speaks Arabic at home")
        let f = fx.hub.add(kind: .profile, content: "Speaks French at school")
        XCTAssertNotEqual(e.id, f.id)
        XCTAssertEqual(fx.hub.learner.count(), 4)
    }

    func testConceptGraphCrossSubject() throws {
        let fx = try MemoryFixture()
        let hub = fx.hub, g = hub.graph!
        let prosody = hub.saveConcept(name: "Arabic prosody", subjects: ["Arabic", "poetry"], prerequisites: ["Arabic alphabet"])!
        let kin = hub.saveConcept(name: "Kinematics", subjects: ["physics"], prerequisites: ["derivatives"])!
        hub.saveConcept(name: "derivatives", subjects: ["Maths"])
        hub.saveConcept(name: "Algorithms", subjects: ["computer science"], prerequisites: ["discrete math"])
        hub.saveConcept(name: "discrete math", subjects: ["math"])
        XCTAssertEqual(g.find("the Derivative"), g.find("derivatives"), "aliases normalise")
        XCTAssertEqual(g.concept(prosody)!.subjects.sorted(), ["arabic", "poetry"])
        XCTAssertEqual(g.prerequisites(of: kin).map(\.name), ["derivatives"])
        let links = g.crossSubjectLinks()
        XCTAssertTrue(links.contains { Set([$0.a, $0.b]) == ["arabic", "poetry"] })
        XCTAssertTrue(links.contains { Set([$0.a, $0.b]) == ["math", "physics"] })
        XCTAssertTrue(links.contains { Set([$0.a, $0.b]) == ["computer science", "math"] })
        XCTAssertEqual(g.route("help me with kinematics please")[kin], 1)
        XCTAssertNil(g.route("tell me about the kitchen")[kin])
        // Misconception routed onto the concept automatically.
        let m = hub.add(kind: .misconception, content: "Confuses displacement and distance in kinematics graphs")
        XCTAssertEqual(hub.get(m.id)?.conceptID, kin)
        // Merge concepts: memories, edges and aliases move.
        let dup = hub.saveConcept(name: "Motion kinematics", subjects: ["mechanics"])!
        hub.mergeConcepts(into: "c\(kin)", from: ["c\(dup)"])
        XCTAssertNil(g.concept(dup))
        XCTAssertEqual(g.find("motion kinematics"), kin)
        XCTAssertTrue(g.concept(kin)!.subjects.contains("mechanics"))
    }

    func testMasterySyncReusesBKT() throws {
        let fx = try MemoryFixture()
        fx.study.recordAttempt(subject: "calculus", concept: "Chain rule", correct: true, note: nil)
        fx.study.recordAttempt(subject: "calculus", concept: "Chain rule", correct: false, note: nil)
        XCTAssertEqual(fx.hub.graph!.syncMastery(), 1)
        let id = fx.hub.graph!.find("chain rule")!
        let c = fx.hub.graph!.concept(id)!
        let bkt = fx.study.mastery(subject: "calculus", concept: "Chain rule")!
        XCTAssertEqual(c.pKnown!, bkt.pKnown, accuracy: 1e-9)
        XCTAssertEqual(c.attempts, 2)
        XCTAssertEqual(fx.hub.graph!.syncMastery(), 0, "incremental")
        // Estimates never override real evidence.
        fx.hub.graph!.estimate(id, level: 0.99)
        XCTAssertEqual(fx.hub.graph!.concept(id)!.pKnown!, bkt.pKnown, accuracy: 1e-9)
        XCTAssertTrue(fx.hub.coreBlock().contains("Chain rule #c\(id)"))
    }

    func testReflectionApply() throws {
        let fx = try MemoryFixture()
        let hub = fx.hub
        let old = hub.add(kind: .misconception, content: "Thinks the derivative of x^2 is x", subject: "calculus")
        let goal = hub.add(kind: .goal, content: "Wants to finish the derivatives unit by Friday", subject: "calculus")
        let json = JSON.parse("""
        {"operations":[
          {"op":"add","kind":"misconception","concept":"chain rule","content":"Forgets the inner derivative when applying the chain rule","importance":0.7},
          {"op":"add","kind":"fact","content":"Learner asked for the derivative of sin(x^2)"},
          {"op":"add","kind":"preference","content":"Prefers to try a problem before seeing the worked solution"},
          {"op":"resolve","id":"\(old.id)"},
          {"op":"update","id":"\(goal.id)","content":"Wants to finish the derivatives unit before the mock exam"},
          {"op":"delete","id":"99999"},
          {"op":"noop"}],
         "concepts":[{"name":"chain rule","subjects":["calculus"],"prerequisites":["derivatives"],"status":"learning"},
                     {"name":"related rates","subjects":["calculus","physics"],"prerequisites":["chain rule"]}],
         "episode":"Worked through chain rule examples; nested functions are still slow. Next: related rates.",
         "title":"Chain rule practice"}
        """)!
        let o = Reflection.apply(json, hub: hub, conversationID: "conv1")
        XCTAssertEqual(o.added, 2)
        XCTAssertEqual(o.rejected, 1, "one-off request rejected")
        XCTAssertEqual(o.deleted, 1)
        XCTAssertEqual(o.updated, 1)
        XCTAssertEqual(o.concepts, 2)
        XCTAssertNil(hub.learner.all().first { $0.id == old.id }, "resolved misconception archived")
        XCTAssertEqual(hub.history(old.id).first?.change, "resolved")
        let cr = hub.graph!.find("chain rule")!
        XCTAssertEqual(hub.learner.memories(conceptID: cr).count, 1, "misconception attached to concept")
        XCTAssertEqual(hub.graph!.prerequisites(of: hub.graph!.find("related rates")!).map(\.name), ["chain rule"])
        XCTAssertEqual(hub.folder.recentEpisodes(limit: 5).count, 1)
        XCTAssertTrue(hub.get(goal.id)!.content.contains("mock exam"))
        // Applying the same reflection again does not duplicate anything (update instead of add).
        let before = hub.learner.count()
        _ = Reflection.apply(json, hub: hub, conversationID: "conv1")
        XCTAssertEqual(hub.learner.count(), before)
    }

    /// Replays what a two-question geography/planets test lesson produced before the guards existed.
    func testReflectionDoesNotSpamConcepts() throws {
        let fx = try MemoryFixture()
        let hub = fx.hub
        _ = hub.saveConcept(name: "basic world geography", subjects: ["geography"])
        let json = JSON.parse("""
        {"operations":[{"op":"add","kind":"misconception","content":"The learner may confuse Jupiter with Saturn as the largest planet"},
                       {"op":"add","kind":"misconception","content":"Repeatedly mixes up Jupiter and Saturn when ranking planets by size"}],
         "concepts":[{"name":"favourite planet"},{"name":"solar system structure"},{"name":"planetary order and size"},
                     {"name":"planet size"},{"name":"Italian geography"},{"name":"world geography basics"},{"name":"orbits"}]}
        """)!
        let o = Reflection.apply(json, hub: hub, conversationID: "c")
        let names = Set(hub.graph!.all().map(\.name))
        XCTAssertFalse(names.contains("favourite planet"), "preferences are not concepts")
        XCTAssertFalse(names.contains("world geography basics"), "folded into 'basic world geography'")
        XCTAssertEqual(names.count, 4, "existing + at most 3 new: \(names.sorted())")
        XCTAssertFalse(names.contains("orbits"), "4th new concept rejected")
        XCTAssertEqual(o.added, 1, "speculative misconception rejected, the repeated one kept")
        XCTAssertTrue(Reflection.sameConcept("Chain Rule", "chain rule for derivatives"))
        XCTAssertFalse(Reflection.sameConcept("chain rule", "product rule"))
    }

    func testLocalConsolidation() throws {
        let fx = try MemoryFixture()
        let st = fx.hub.learner
        // Duplicates that bypassed dedup (e.g. written by an older version).
        st.bulkInsert([(.fact, "Uses VS Code for programming", nil, Embedder.shared.vector("Uses VS Code for programming")),
                       (.fact, "uses vs code for programming!", nil, Embedder.shared.vector("uses vs code for programming!")),
                       (.fact, "Plays the violin in an orchestra", nil, Embedder.shared.vector("Plays the violin in an orchestra"))])
        // A faded inferred fact: old, unused, low importance.
        let r = fx.hub.add(kind: .fact, content: "Once mentioned liking crossword puzzles")
        try fx.learnerDB.execute("UPDATE memories SET importance=0.1, updated_at=? WHERE id=?", Date().addingTimeInterval(-400 * 86400), Int64(r.id)!)
        let rep = fx.hub.maintenance()
        XCTAssertEqual(rep.merged, 1)
        XCTAssertEqual(rep.archived, 1)
        XCTAssertEqual(st.count(), 2)
        // Episodes are capped (oldest rolled up).
        for i in 0..<35 { fx.hub.folder.bulkInsert([(.episode, "Lesson \(i) covered topic \(i)", nil, nil)]) }
        fx.hub.maintenance()
        XCTAssertEqual(fx.hub.folder.recentEpisodes(limit: 100).count, 30)
    }

    func testOneMemoryToolIsCompact() async throws {
        let tool = MemoryTool()
        let specChars = tool.description.count + tool.schema.compact.count + tool.name.count
        print("[memory] tool schema ≈ \(specChars / 4) tokens (\(specChars) chars)")
        XCTAssertLessThanOrEqual(specChars / 4, 200)
        let fx = try MemoryFixture()
        let ws = try Workspace(url: fx.dir)
        let services = Services(global: try GlobalStoreFixture.make(fx), workspace: ws)
        let interactions = await MainActor.run { InteractionCenter() }
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        let ctx = ToolContext(conversationID: "t", workspace: fx.dir, services: services, interactions: interactions, toolCallID: "c",
                              client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        var o = try await tool.run(["action": "save", "kind": "misconception", "content": "Mixes up mitosis and meiosis outcomes", "concept": "cell division", "subjects": "biology"], ctx)
        XCTAssertTrue(o.text.hasPrefix("Saved #"), o.text)
        o = try await tool.run(["action": "save", "kind": "fact", "content": "Learner asked what mitosis is"], ctx)
        XCTAssertTrue(o.text.hasPrefix("Not saved"), o.text)
        o = try await tool.run(["action": "save", "kind": "concept", "content": "meiosis", "subjects": "biology", "needs": "cell division"], ctx)
        XCTAssertTrue(o.text.contains("#c"), o.text)
        o = try await tool.run(["action": "search", "query": "mitosis vs meiosis"], ctx)
        XCTAssertTrue(o.text.contains("Mixes up mitosis"), o.text)
        o = try await tool.run(["action": "save", "kind": "fact", "content": "Keeps lab notes in this folder", "scope": "folder"], ctx)
        XCTAssertTrue(o.text.contains("#f"), o.text)
        // A concept described at length in `content` (what models actually send) is saved, not rejected.
        let long = "Knows atomic structure and ions; needs reinforcement on reading ion charges and on electron shells driving chemical stability."
        o = try await tool.run(["action": "save", "kind": "concept", "content": .string(long), "subject": "chemistry"], ctx)
        XCTAssertFalse(o.isError, o.text)
        let saved = services.memory.concept(o.meta?["id"]?.string ?? "")
        XCTAssertEqual(saved?.name, "Knows atomic structure and ions")
        XCTAssertEqual(saved?.subjects, ["chemistry"])
        XCTAssertTrue(saved?.summary?.contains("electron shells") == true)
        XCTAssertEqual(MemoryTool.conceptName(String(repeating: "word ", count: 30)).count <= 60, true)
    }
}

/// GlobalStore always opens the real app DB; build Services over the fixture DB instead.
enum GlobalStoreFixture {
    static func make(_ fx: MemoryFixture) throws -> GlobalStore { GlobalStore(db: fx.learnerDB) }
}

/// Correctness guards found by stress testing: updates win, nothing is folded or deleted that shouldn't be.
class MemoryCorrectnessTests: XCTestCase {
    func testUpdatesSupersedeAndKeepHistory() throws {
        let fx = try MemoryFixture()
        let a = fx.hub.add(kind: .profile, content: "The learner is 15 years old and in year 10", subject: nil, importance: 0.6, origin: "inferred", source: "t")
        let b = fx.hub.add(kind: .profile, content: "The learner is 16 years old and in year 10", subject: nil, importance: 0.6, origin: "inferred", source: "t")
        XCTAssertEqual(a.id, b.id, "same fact restated")
        XCTAssertTrue(fx.hub.get(a.id)!.content.contains("16"), "the newer number wins")
        XCTAssertTrue(fx.hub.history(a.id).contains { $0.content.contains("15") }, "the old value is in history")
        let p = fx.hub.add(kind: .preference, content: "Prefers Python for scripting exercises", subject: nil, importance: 0.6, origin: "inferred", source: "t")
        _ = fx.hub.add(kind: .preference, content: "Does not prefer Python for scripting exercises", subject: nil, importance: 0.6, origin: "inferred", source: "t")
        XCTAssertTrue(fx.hub.get(p.id)!.content.hasPrefix("Does not"), "a negation is an update, not lost")
    }

    func testReflectionOnlyTouchesWhatItWasShownAndNeverHardDeletes() throws {
        let fx = try MemoryFixture()
        let keep = fx.hub.add(kind: .goal, content: "Wants to pass the AP Physics exam in May", subject: "physics", importance: 0.7, origin: "explicit", source: "t")
        let shown = fx.hub.add(kind: .fact, content: "Works night shifts as a nurse on weekdays", subject: nil, importance: 0.6, origin: "inferred", source: "t")
        _ = Reflection.apply(["operations": [["op": "delete", "id": .string(keep.id)], ["op": "delete", "id": .string(shown.id)]]],
                             hub: fx.hub, conversationID: "c", allowed: [shown.id])
        XCTAssertTrue(fx.hub.all().contains { $0.id == keep.id }, "not shown → untouched")
        XCTAssertFalse(fx.hub.all().contains { $0.id == shown.id }, "shown and deleted → gone from the active model")
        XCTAssertFalse(fx.hub.history(shown.id).isEmpty, "…but archived with its history, not hard-deleted")
        _ = Reflection.apply(["operations": [["op": "update", "id": .string(keep.id), "kind": "episode"]]], hub: fx.hub, conversationID: "c")
        XCTAssertEqual(fx.hub.get(keep.id)?.kind, .goal, "a goal never turns into an episode")
    }

    func testDistinctConceptsDoNotFold() {
        for (a, b) in [("Calculus", "Multivariable calculus"), ("Algebra", "Linear algebra"), ("WWI", "WWII"),
                       ("Big O", "Big Theta"), ("Newton's 1st law", "Newton's 2nd law"), ("Integration by parts", "Integration by substitution")] {
            XCTAssertFalse(Reflection.sameConcept(a, b), "\(a) vs \(b)")
        }
        XCTAssertTrue(Reflection.sameConcept("Planets", "planet"))
    }

    func testDurableFactsAreNotRejected() {
        for c in ["Is a backend developer building a REST API", "Works as a tool and die maker", "Has completed a bachelor's degree in physics",
                  "Finished high school in 2019"] {
            XCTAssertNil(MemoryPolicy.rejection(c, kind: .profile, explicit: false), c)
        }
        XCTAssertNotNil(MemoryPolicy.rejection("Completed the quiz on fractions", kind: .fact, explicit: false))
        XCTAssertNotNil(MemoryPolicy.rejection("The app crashed during the quiz", kind: .fact, explicit: false))
    }

    func testMasteryIsOneRowPerConceptWhateverTheCase() throws {
        let fx = try MemoryFixture()
        fx.study.recordAttempt(subject: "Calculus", concept: "Chain rule", correct: false, note: nil)
        fx.study.recordAttempt(subject: "calculus", concept: "chain rule", correct: true, note: nil)
        fx.study.recordAttempt(subject: "calculus", concept: "Chain Rule", correct: true, note: nil)
        let rows = fx.study.allMastery().filter { $0.concept.lowercased() == "chain rule" }
        XCTAssertEqual(rows.count, 1); XCTAssertEqual(rows.first?.attempts, 3)
    }

    func testPrerequisitesStayAcyclicAndGraphWritesScale() throws {
        let fx = try MemoryFixture()
        guard let g = fx.hub.graph else { return XCTFail("graph") }
        let a = g.upsert(name: "Limits")!, b = g.upsert(name: "Derivatives")!, c = g.upsert(name: "Integrals")!
        g.link(b, a, .prerequisite); g.link(c, b, .prerequisite)
        g.link(a, c, .prerequisite)   // would close A→…→A
        let edges = (try fx.learnerDB.query("SELECT src, dst FROM concept_edges WHERE rel='prereq'")).map { "\($0.int("src")!)>\($0.int("dst")!)" }
        XCTAssertFalse(edges.contains("\(a)>\(c)"), "cycle refused: \(edges)")
        let t0 = Date()
        for i in 0..<3000 { _ = g.upsert(name: "Concept \(i) of the big graph", subjects: ["s\(i % 7)"]) }
        let per = Date().timeIntervalSince(t0) / 3000 * 1000
        print("[memory] concept upsert at 3k: \(String(format: "%.2f", per)) ms each")
        XCTAssertLessThan(per, 5, "incremental index: no full reload per write")
        XCTAssertNotNil(g.find("concept 2999 of the big graph"))
    }
}

final class LearningModelTests: XCTestCase {
    func testMasteryFadesAndPracticeMakesItLast() {
        let now = Date()
        var c = Concept(rowid: 1, name: "x", subjects: [], pKnown: 0.95, attempts: 1, correct: 1, evidence: 1, origin: "t",
                        createdAt: now, updatedAt: now, masteryAt: now.addingTimeInterval(-30 * 86_400))
        let once = c.effectiveMastery(at: now)!
        c.correct = 8; c.attempts = 8
        let practised = c.effectiveMastery(at: now)!
        XCTAssertLessThan(once, 0.7, "a month after one success it has faded")
        XCTAssertGreaterThan(practised, 0.9, "after 8 successful recalls it lasts")
        XCTAssertGreaterThanOrEqual(once, 0.95 * 0.4, "never below 40% of what was learned")
        c.correct = 1; XCTAssertTrue(c.isFading(at: now))
    }

    func testFrontierAndFading() throws {
        let fx = try MemoryFixture()
        guard let g = fx.hub.graph else { return XCTFail() }
        let limits = g.upsert(name: "Limits", subjects: ["calculus"])!, deriv = g.upsert(name: "Derivatives", subjects: ["calculus"])!
        let chain = g.upsert(name: "Chain rule", subjects: ["calculus"])!
        g.link(deriv, limits, .prerequisite); g.link(chain, deriv, .prerequisite)
        for _ in 0..<4 { fx.study.recordAttempt(subject: "calculus", concept: "Limits", correct: true, note: nil) }
        g.syncMastery()
        let ready = g.readyToLearn().map(\.name)
        XCTAssertTrue(ready.contains("Derivatives"), "its prerequisite is solid: \(ready)")
        XCTAssertFalse(ready.contains("Chain rule"), "needs derivatives first")
        XCTAssertFalse(ready.contains("Limits"), "already solid")
        let later = Date().addingTimeInterval(90 * 86_400)
        XCTAssertEqual(g.fading(now: later).map(\.name), ["Limits"], "three months later it needs review")
        XCTAssertFalse(g.readyToLearn(now: later).map(\.name).contains("Limits"), "slipping = review, not new learning")
        XCTAssertTrue(fx.hub.studyNext().joined().contains("Derivatives"))
        _ = chain
    }
}

final class ConceptRoutingTests: XCTestCase {
    func testOneWordConceptsNeedRealEvidence() throws {
        let fx = try MemoryFixture()
        guard let g = fx.hub.graph else { return XCTFail() }
        let c = g.upsert(name: "C", subjects: ["programming"])!, go = g.upsert(name: "Go", subjects: ["programming"])!
        let energy = g.upsert(name: "Energy", subjects: ["physics"])!
        XCTAssertNil(g.route("Vitamin c is good for colds")[c])
        XCTAssertNotNil(g.route("I want to learn C pointers")[c])
        XCTAssertNil(g.route("I should go home now")[go])
        XCTAssertNotNil(g.route("How do Go channels work?")[go])
        XCTAssertNil(g.route("no energy today")[energy])
        XCTAssertNotNil(g.route("explain kinetic energy")[energy])
        XCTAssertNotNil(g.route("what is energy?")[energy])
    }
}

/// Apple's sentence embedding is English-only in practice: other languages encoded by it were noise (Arabic related and
/// unrelated sentences both ~0.97 cosine, which the store's thresholds turned into full semantic evidence).
final class EmbeddingLanguageTests: XCTestCase {
    func testSemanticVectorsAreEnglishOnlyUntilAMultilingualModelIsBundled() {
        XCTAssertNotNil(Embedder.shared.vector("The cat sat on the mat"))
        XCTAssertNil(Embedder.shared.vector("قطة تجلس على السجادة"))
        XCTAssertNil(Embedder.shared.vector("日本語の文章です。"))
        XCTAssertNil(Embedder.shared.vector("Кот сидит на коврике"))
    }
}
