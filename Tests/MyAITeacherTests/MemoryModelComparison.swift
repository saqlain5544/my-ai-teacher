import XCTest
@testable import MyAITeacher

/// Which model keeps the learner model more accurate: LFM3-Omni on this Mac against MiniMax-M3.1-Flash (thinking off),
/// through the app's own reflection and consolidation, on fixed lessons and a fixed memory set whose right answers are
/// known. Every run starts from a fresh database; each result is scored by pattern checks, and the report is printed and
/// written as JSON. Opt-in: MiniMax calls bill the learner's plan (MINIMAX_API_KEY), and tests run in a throwaway profile,
/// so MYAITEACHER_HOME must name one whose `support/liquid` holds the runtime and LFM3-Omni (copies, or links to the files):
///   MEMORY_COMPARE=1 MYAITEACHER_HOME=… [MEMORY_COMPARE_RUNS=3] [MEMORY_COMPARE_OUT=/tmp/r.json] swift test --filter MemoryModelComparison
final class MemoryModelComparison: XCTestCase {
    struct Arm { let name: String; let client: LLMClient; let model: String }

    /// A memory that should (or must not) exist: a case-insensitive pattern on its content, in one of `kinds` (nil: any).
    struct Check {
        let label: String, pattern: String, kinds: [MemoryKind]?, unless: String?
        init(_ label: String, _ pattern: String, _ kinds: [MemoryKind]? = nil, unless: String? = nil) {
            self.label = label; self.pattern = pattern; self.kinds = kinds; self.unless = unless
        }
        func matches(_ m: Memory) -> Bool {
            m.content.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
                && !(unless.map { m.content.range(of: $0, options: [.regularExpression, .caseInsensitive]) != nil } ?? false)
        }
    }

    struct Lesson {
        let name: String
        let existing: [(MemoryKind, String)]
        let turns: [(Role, String)]
        let expect: [Check]       // durable facts it should store (or keep, updated)
        let stale: [Check]        // what the lesson made wrong: no active memory may still say it
        let forbid: [Check]       // never stored (outside the lesson summary)
        let single: [Check]       // exactly one active memory, not a duplicate
    }

    static let lessons: [Lesson] = [
        Lesson(name: "calculus", existing: [(.goal, "Preparing for the AP Calculus BC exam in May")], turns: [
            (.user, "Can you give me the derivative of sin(x^2)?"),
            (.assistant, "Chain rule: outer sin(u), inner u = x². So it's cos(x²)·2x. Now you try: d/dx cos(3x)?"),
            (.user, "-sin(3x)?"),
            (.assistant, "Close — you forgot to multiply by the derivative of the inner function, 3. It's −3 sin(3x)."),
            (.user, "Argh, I did exactly the same thing yesterday with e^(2x). I always forget to multiply by the inner part."),
            (.assistant, "That's the classic chain-rule slip. Let's build a habit: name the inner function before you differentiate."),
            (.user, "It helps a lot when you draw the composition as boxes before the algebra. Pictures first works way better for me."),
            (.assistant, "Noted — diagram first from now on. You scored 2/3 on that little quiz, nice work."),
            (.user, "Cool. The exam's still in May, so let's keep going tomorrow."),
        ], expect: [Check("chain-rule slip", #"inner|chain"#, [.misconception]),
                    Check("diagram first", #"diagram|picture|visual|draw|box"#, [.preference]),
                    Check("exam goal kept", #"calc|BC"#, [.goal])],
           stale: [],
           // (A misconception may cite the slips as examples: it generalises them, which is what the rules ask.)
           forbid: [Check("the one-off question", #"sin\(x|sin x"#, [.profile, .preference, .goal, .fact, .knowledge]), Check("the quiz score", #"2/3|scored"#),
                    Check("yesterday's slip", #"e\^"#, [.profile, .preference, .goal, .fact, .knowledge])],
           single: [Check("one exam goal", #"calc|BC"#, [.goal])]),
        Lesson(name: "physics update", existing: [(.profile, "Is 15 years old and in Year 10"), (.misconception, "Confuses mass and weight")], turns: [
            (.user, "Quick update: I turned 16 last week and moved up to Year 11."),
            (.assistant, "Happy birthday! Last time mass and weight tripped you up. What's the difference?"),
            (.user, "Mass is how much matter, in kg, the same everywhere. Weight is the force of gravity on it, in newtons, so it changes on the Moon."),
            (.assistant, "Exactly right. Why does a 60 kg astronaut weigh less on the Moon?"),
            (.user, "The Moon's g is about 1.6 instead of 9.8, so the force is smaller but the mass is still 60 kg. I finally get it now."),
            (.assistant, "Perfect. Sorry the chart didn't load earlier."),
            (.user, "No worries, the app glitched. I've got a bad headache today so let's stop here."),
        ], expect: [Check("now 16", #"16"#, [.profile]), Check("now Year 11", #"(year|grade) ?11"#, [.profile])],
           stale: [Check("still 15", #"15 years"#), Check("mass/weight still a misconception", #"mass.*weight|weight.*mass"#, [.misconception])],
           forbid: [Check("the headache", #"headache"#), Check("the app glitch", #"glitch|chart"#)],
           single: [Check("one age", #"years old|\b1[56]\b"#, [.profile])]),
        Lesson(name: "arabic", existing: [], turns: [
            (.user, "I'm a native Urdu speaker, so I can read the script but I don't know any Arabic grammar."),
            (.assistant, "That's a great base. What would you like to be able to do?"),
            (.user, "Read classical Arabic poetry in the original, al-Mutanabbi especially."),
            (.assistant, "Then let's start with the sun and moon letters: al- (al-qamar) vs ash-shams (ash-shams)."),
            (.user, "Please stop writing transliteration under the words. I read the script fine and it slows me down."),
            (.assistant, "Understood, script only. In الشمس the lam assimilates into the shin."),
            (.user, "Got it. By the way my laptop password is hunter2, lol, my brother keeps guessing it."),
            (.assistant, "Please don't share passwords! Back to it: which of ت ب ر assimilate the lam?"),
            (.user, "ت and ر, not ب."),
        ], expect: [Check("native Urdu", #"urdu"#, [.profile]), Check("poetry goal", #"poetry|mutanabbi"#, [.goal]),
                    Check("no transliteration", #"translit"#, [.preference])],
           stale: [],
           forbid: [Check("the password", #"hunter2|password"#), Check("the brother", #"brother"#)],
           single: []),
        Lesson(name: "python", existing: [(.fact, "Uses VS Code for programming")], turns: [
            (.user, "I work as a data analyst, mostly pandas. Also I switched from VS Code to Neovim last month."),
            (.assistant, "Nice. Today: default arguments. With def f(x=[]): x.append(1); return x — what do two calls of f() print?"),
            (.user, "[1] and then [1] again, the list resets each call."),
            (.assistant, "Not quite: [1] then [1, 1]. The default list is created once, when the function is defined."),
            (.user, "Oh. That's exactly the bug I hit at work last week with a dict default. I assumed it was fresh every call."),
            (.assistant, "Same root cause. Use None as the default and create the list inside."),
            (.user, "What's 2**10 again?"),
            (.assistant, "1024."),
            (.user, "Thanks, more of this tomorrow."),
        ], expect: [Check("data analyst", #"analyst"#, [.profile, .fact]), Check("mutable-default slip", #"default"#, [.misconception]),
                    Check("uses Neovim", #"neovim"#)],
           stale: [Check("still VS Code", #"vs ?code"#, unless: #"neovim"#)],
           forbid: [Check("the one-off sum", #"2\*\*10|1024"#)],
           single: []),
    ]

    /// The memory set consolidation should clean: (kind, content, days since updated).
    static let memories: [(MemoryKind, String, Double)] = [
        (.preference, "Prefers to see a worked example before trying a problem alone", 30),
        (.preference, "Learns best when shown a fully solved problem first", 5),
        (.goal, "Preparing for the AP Calculus BC exam in May", 40),
        (.goal, "Has the Calc BC test coming up this May", 3),
        (.profile, "Is 15 years old", 200),
        (.profile, "Turned 16 in October", 2),
        (.fact, "Uses VS Code for programming", 120),
        (.fact, "Switched from VS Code to Neovim last month", 4),
        (.fact, "Asked for the derivative of sin(x^2) on Tuesday", 10),
        (.fact, "Scored 7/10 on the vectors quiz", 8),
        (.fact, "The chart failed to load during the lesson", 6),
        (.profile, "Native speaker of Urdu", 50),
        (.goal, "Wants to read al-Mutanabbi's poetry in the original Arabic", 45),
        (.misconception, "Makes sign errors when expanding brackets with a negative in front", 20),
        (.preference, "Prefers short explanations with a single diagram", 25),
        (.profile, "Works as a data analyst using pandas", 60),
        (.fact, "Plays competitive chess at club level", 70),
        (.misconception, "Thinks Python default arguments are re-created on every call", 15),
        (.profile, "Lives in Sydney, Australia", 90),
    ]
    static let duplicates = [Check("worked-example preference", #"(worked|solved) (example|problem)"#, [.preference]),
                             Check("Calc BC goal", #"calc|BC"#, [.goal])]
    static let contradicted = [Check("still 15", #"15 years"#), Check("still VS Code", #"vs ?code"#, unless: #"neovim"#)]
    static let noise = [Check("one-off question", #"sin\(x"#), Check("quiz score", #"7/10"#), Check("app glitch", #"chart"#)]
    static let keep = [Check("Urdu", #"urdu"#), Check("poetry goal", #"mutanabbi|poetry"#), Check("sign errors", #"sign"#),
                       Check("one diagram", #"diagram"#), Check("analyst", #"analyst|pandas"#), Check("chess", #"chess"#),
                       Check("mutable defaults", #"default"#), Check("Sydney", #"sydney"#)]

    @MainActor func arms() async throws -> [Arm] {
        var out: [Arm] = []
        let presets = ProviderCatalog.presets
        guard LiquidModels.ready(.omni), let local = presets.first(where: { $0.id == LiquidModels.providerID }) else { throw XCTSkip("LFM3-Omni isn't installed") }
        out.append(Arm(name: "LFM3-Omni-2B (this Mac)", client: local.client(apiKey: nil), model: LiquidModels.omniModel))
        guard let mm = presets.first(where: { $0.id == "minimax" }), let key = KeyStore.shared.key(for: mm) else { throw XCTSkip("no MiniMax key") }
        out.append(Arm(name: "MiniMax-M3.1-Flash", client: mm.client(apiKey: key), model: "MiniMax-M3.1-Flash"))
        return out
    }

    func fresh() throws -> (MemoryFixture, Services) {
        let fx = try MemoryFixture()
        return (fx, Services(global: GlobalStore(db: fx.learnerDB), workspace: try Workspace(url: fx.dir)))
    }

    @MainActor func testWhichModelKeepsTheLearnerModelMoreAccurate() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["MEMORY_COMPARE"] != nil else { throw XCTSkip("set MEMORY_COMPARE=1") }
        let runs = Int(env["MEMORY_COMPARE_RUNS"] ?? "") ?? 3
        let arms = try await arms().filter { a in env["MEMORY_COMPARE_ONLY"].map { a.name.localizedCaseInsensitiveContains($0) } ?? true }
        var report: [String: JSON] = [:]
        for arm in arms {
            var reflection: [JSON] = [], consolidation: [JSON] = []
            for run in 1...runs {
                for lesson in Self.lessons { reflection.append(try await reflect(arm, lesson, run: run)) }
                consolidation.append(try await consolidate(arm, run: run))
            }
            report[arm.name] = ["reflection": .array(reflection), "consolidation": .array(consolidation)]
        }
        summarise(report, runs: runs)
        if let out = env["MEMORY_COMPARE_OUT"] { try Data(JSON.object(report).pretty.utf8).write(to: URL(fileURLWithPath: out)) }
    }

    /// One lesson's reflection: what it stored, kept, cleared and leaked.
    func reflect(_ arm: Arm, _ lesson: Lesson, run: Int) async throws -> JSON {
        let (fx, services) = try fresh()
        defer { _ = fx }
        for (kind, content) in lesson.existing { _ = services.memory.add(kind: kind, content: content, origin: "explicit") }
        let t0 = Date()
        let o = await Reflection.run(messages: lesson.turns.map { ChatMessage(role: $0.0, blocks: [.text($0.1)]) }, conversationID: "eval",
                                     client: arm.client, model: arm.model, services: services, needsTitle: false)
        let secs = Date().timeIntervalSince(t0)
        let active = services.memory.all(), notes = active.filter { $0.kind != .episode }
        func score(_ c: Check) -> Double {
            let hits = notes.filter(c.matches)
            if hits.contains(where: { c.kinds?.contains($0.kind) ?? true }) { return 1 }
            return hits.isEmpty ? 0 : 0.5   // there, in the wrong kind
        }
        let expect = lesson.expect.map(score)
        let stale = lesson.stale.map { c in notes.contains(where: { c.matches($0) && (c.kinds?.contains($0.kind) ?? true) }) ? 0.0 : 1 }
        let forbid = lesson.forbid.map { c in notes.contains(where: { c.matches($0) && (c.kinds?.contains($0.kind) ?? true) }) ? 0.0 : 1 }
        let secretAnywhere = active.contains { $0.content.range(of: "hunter2", options: .caseInsensitive) != nil }
        let single = lesson.single.map { c in notes.filter { c.matches($0) && (c.kinds?.contains($0.kind) ?? true) }.count == 1 ? 1.0 : 0 }
        print("[compare] \(arm.name) run \(run) \(lesson.name): \(String(format: "%.0f", secs)) s, stored \(sum(expect))/\(expect.count), cleared \(sum(stale))/\(stale.count), " +
              "kept out \(sum(forbid))/\(forbid.count), no duplicate \(sum(single))/\(single.count)\(o.failed ? ", CALL FAILED" : "")\(o.applied == 0 ? ", NOTHING APPLIED" : ""), rejected \(o.rejected)")
        for m in notes { print("[compare]     \(m.kind.rawValue): \(m.content)") }
        return ["lesson": .string(lesson.name), "run": .number(Double(run)), "seconds": .number(secs), "failed": .bool(o.failed), "applied": .number(Double(o.applied)),
                "rejected": .number(Double(o.rejected)), "expect": .array(expect.map(JSON.number)), "stale": .array(stale.map(JSON.number)),
                "forbid": .array(forbid.map(JSON.number)), "single": .array(single.map(JSON.number)), "secretStored": .bool(secretAnywhere),
                "memories": .array(notes.map { .string("\($0.kind.rawValue): \($0.content)") })]
    }

    /// One consolidation pass over the fixed memory set.
    func consolidate(_ arm: Arm, run: Int) async throws -> JSON {
        let (fx, services) = try fresh()
        defer { _ = fx }
        let hub = services.memory
        hub.learner.bulkInsert(Self.memories.map { ($0.0, $0.1, nil, Embedder.shared.vector($0.1)) })
        for (_, content, days) in Self.memories {
            try fx.learnerDB.execute("UPDATE memories SET updated_at=?, created_at=? WHERE content=?", Date().addingTimeInterval(-days * 86400),
                                     Date().addingTimeInterval(-days * 86400), content)
        }
        let g = try XCTUnwrap(hub.graph)
        for (name, subjects) in [("Chain rule", ["calculus"]), ("chain rule for derivatives", ["calculus"]), ("Derivatives", ["calculus"]),
                                 ("Simple harmonic motion", ["physics"]), ("Sun letters", ["arabic"]), ("Arabic definite article", ["arabic"])] {
            _ = g.upsert(name: name, subjects: subjects)
        }
        let before = Set(hub.all().map(\.id))
        let t0 = Date()
        let o = await Reflection.consolidate(client: arm.client, model: arm.model, services: services)
        let secs = Date().timeIntervalSince(t0)
        let active = hub.all()
        let dup = Self.duplicates.map { c in active.filter { c.matches($0) && (c.kinds?.contains($0.kind) ?? true) }.count == 1 ? 1.0 : 0 }
        let contra = Self.contradicted.map { c in active.contains(where: c.matches) ? 0.0 : 1 }
        let noise = Self.noise.map { c in active.contains(where: c.matches) ? 0.0 : 1 }
        let keep = Self.keep.map { c in active.contains(where: c.matches) ? 1.0 : 0 }
        let concepts = g.all(), names = Dictionary(uniqueKeysWithValues: concepts.map { ($0.rowid, $0.name.lowercased()) })
        let chain = concepts.filter { $0.name.lowercased().contains("chain rule") }.count == 1 ? 1.0 : 0
        func linked(_ a: String, _ b: [String]) -> Double {
            g.edges().contains { e in
                let s = names[e.src] ?? "", d = names[e.dst] ?? ""
                return (s.contains(a) && b.contains(where: d.contains)) || (d.contains(a) && b.contains(where: s.contains))
            } ? 1 : 0
        }
        let links = [linked("harmonic", ["derivative", "chain rule"]), linked("sun letters", ["definite article"])]
        let added = active.filter { !before.contains($0.id) }
        print("[compare] \(arm.name) run \(run) consolidation: \(String(format: "%.0f", secs)) s, duplicates \(sum(dup))/2, contradictions \(sum(contra))/2, " +
              "noise \(sum(noise))/3, kept \(sum(keep))/8, chain-rule merged \(Int(chain))/1, links \(sum(links))/2, added \(added.count)\(o.applied == 0 ? ", NOTHING APPLIED" : "")")
        for m in active { print("[compare]     \(before.contains(m.id) ? "" : "NEW ")\(m.kind.rawValue): \(m.content)") }
        for e in g.edges() { print("[compare]     link \(names[e.src] ?? "?") —\(e.rel.rawValue)→ \(names[e.dst] ?? "?")") }
        return ["run": .number(Double(run)), "seconds": .number(secs), "applied": .number(Double(o.applied)), "duplicates": .array(dup.map(JSON.number)),
                "contradictions": .array(contra.map(JSON.number)), "noise": .array(noise.map(JSON.number)), "keep": .array(keep.map(JSON.number)),
                "chainMerged": .number(chain), "links": .array(links.map(JSON.number)), "added": .array(added.map { .string("\($0.kind.rawValue): \($0.content)") }),
                "memories": .array(active.map { .string("\($0.kind.rawValue): \($0.content)") })]
    }

    func sum(_ xs: [Double]) -> String { let s = xs.reduce(0, +); return s == s.rounded() ? String(Int(s)) : String(format: "%.1f", s) }

    func summarise(_ report: [String: JSON], runs: Int) {
        print("[compare] ===== \(runs) run\(runs == 1 ? "" : "s") per model =====")
        for (name, r) in report.sorted(by: { $0.key < $1.key }) {
            let refl = r["reflection"]?.array ?? [], cons = r["consolidation"]?.array ?? []
            func total(_ rows: [JSON], _ key: String) -> (Double, Double) {
                let xs = rows.flatMap { ($0[key]?.array ?? []).compactMap(\.double) } + rows.compactMap { $0[key]?.double }
                return (xs.reduce(0, +), Double(xs.count))
            }
            func pct(_ t: (Double, Double)) -> String { t.1 == 0 ? "-" : String(format: "%.0f%% (%@/%d)", 100 * t.0 / t.1, sum([t.0]), Int(t.1)) }
            let secsR = refl.compactMap { $0["seconds"]?.double }, secsC = cons.compactMap { $0["seconds"]?.double }
            print("[compare] \(name)")
            print("[compare]   reflection: stored \(pct(total(refl, "expect"))), cleared \(pct(total(refl, "stale"))), kept out \(pct(total(refl, "forbid"))), " +
                  "no duplicates \(pct(total(refl, "single"))), failed \(refl.filter { $0["failed"]?.bool == true }.count), password stored \(refl.filter { $0["secretStored"]?.bool == true }.count), " +
                  "mean \(String(format: "%.0f", secsR.reduce(0, +) / Double(max(1, secsR.count)))) s")
            print("[compare]   consolidation: duplicates \(pct(total(cons, "duplicates"))), contradictions \(pct(total(cons, "contradictions"))), noise \(pct(total(cons, "noise"))), " +
                  "kept \(pct(total(cons, "keep"))), chain-rule merged \(pct(total(cons, "chainMerged"))), links \(pct(total(cons, "links"))), " +
                  "added \(cons.map { $0["added"]?.array?.count ?? 0 }.reduce(0, +)), mean \(String(format: "%.0f", secsC.reduce(0, +) / Double(max(1, secsC.count)))) s")
        }
    }
}
