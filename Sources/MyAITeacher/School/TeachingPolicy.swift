import Foundation

/// How a competency is taught, from the evidence rather than a persona: the same recursion is taught concretely with
/// worked examples at school level and through proofs and trade-offs at university level. The policy is deterministic:
/// the app composes a short contract for each request, instead of a long "you are a professor" prompt.
struct TeachingContract: Sendable, Equatable {
    var competency: String
    var title: String
    var held: String
    var target: Level
    var outcome: String
    var teach: String
    var practise: String
    var assess: String
    var hints: String
    var sources: String
    var gaps: [String]              // prerequisites to check before going on
    var misconceptions: [String]
    var diagnose: String?           // after repeated failure: find the cause before re-explaining
    var nextEvidence: String

    var rendered: String {
        var s = "<school competency=\"\(competency)\" held=\"\(held)\" target=\"\(target.title.lowercased())\">\n"
        s += "\(title) at \(target.title.lowercased()) level: \(outcome).\n"
        if !gaps.isEmpty { s += "Check first: \(gaps.joined(separator: "; ")).\n" }
        if let diagnose { s += "Diagnose: \(diagnose)\n" }
        s += "Teach: \(teach)\nPractise: \(practise)\nAssess: \(assess)\nHints: \(hints)\nSources: \(sources)\n"
        if !misconceptions.isEmpty { s += "Watch for: \(misconceptions.prefix(3).joined(separator: "; ")).\n" }
        s += "Evidence still needed: \(nextEvidence). Record what you see with `school` evidence; the app sets the level.\n</school>"
        return s
    }
}

enum TeachingPolicy {
    /// The style of each level, from the school's teaching guide.
    static func style(_ l: Level) -> (teach: String, practise: String, assess: String, hints: String, sources: String) {
        switch l {
        case .school:
            return ("concrete first, one idea at a time, short explanations with an everyday analogy or a picture, then a worked example",
                    "tracing, modify-and-run and short drills; faded examples (each one leaves more for them); a 1–3 file project at most",
                    "frequent checks: recall, tracing and a small program they write alone; ask them to explain it back in their own words",
                    "generous and immediate, but always after their attempt; never the whole answer",
                    "one clear reference; you choose it")
        case .college:
            return ("principles and reasons, not only recipes; worked example, then a faded one, then an independent problem",
                    "multi-file programs with tests, debugging tasks, problem sets; projects of one to three weeks",
                    "unseen problems, code their tests check, a short design question",
                    "moderate: a question or a targeted hint after a real attempt; record any help",
                    "the official documentation; they read it with you")
        case .university:
            return ("theory and systems: trade-offs in performance, correctness and security; Socratic questions over explanation",
                    "open-ended projects with requirements to interpret; reading real source and papers",
                    "open design questions, source analysis, a project defence (they justify every choice), written critique",
                    "sparse: questions, not answers; expect independence",
                    "primary sources: specifications, real implementations (`source`), papers; cite file and line")
        case .research, .expert:
            return ("advisor-style: critique their question, method and evidence; no answer key",
                    "a research log; literature search; experiments with baselines and threats to validity; reproduction",
                    "an original artifact or paper, reproducibility, a defence, peer review. Say plainly that frontier judgement needs human experts",
                    "none as answers: point at the literature and at weaknesses in their method",
                    "the literature itself (search and read papers), artifacts, datasets; they find and judge sources")
        }
    }

    /// The contract for teaching `c` now, from its evidence and the learner's place in the graph.
    static func contract(_ c: Competency, estimate e: Estimate, target: Level, graph: CompetencyGraph, estimates: [String: Estimate], recent: [Evidence]) -> TeachingContract {
        let st = style(target)
        // A prerequisite with no evidence, or one held below what this level builds on, is checked before going on.
        let needed = target.previous ?? .school
        let gaps = c.prereqs.compactMap { id -> String? in
            guard let p = graph[id] else { return nil }
            let pe = estimates[id]
            if pe == nil || pe!.evidenceCount == 0 { return target > .school ? "\(p.title) (no evidence yet: one quick question)" : nil }
            if let l = pe!.level, l >= needed { return nil }
            if pe!.level == nil, target == .school { return nil }
            return "\(p.title) (held: \(pe!.line))"
        }
        // Two or more recent failures here: the cause decides the move, not a louder repeat.
        let fails = recent.prefix(6).filter { $0.outcome == .fail }
        let diagnose: String? = fails.count >= 2
            ? "they failed \(fails.count) of the last \(min(6, recent.count)) tries. Before explaining again, find out which it is: a prerequisite gap, a misconception, reading the problem, the tooling, or too little practice — one diagnostic question — then change the representation (concrete, visual, formal, worked example) rather than repeating it."
            : nil
        var hints = st.hints
        if let ind = e.independence, ind < 0.5, e.evidenceCount >= 4 {
            hints += ". They lean on help (\(Int((1 - ind) * 100))% of passes had it): fade support and ask for one unaided attempt before moving on"
        }
        let missing: String = {
            let skillsAt = Set(recent.filter { $0.level >= target && $0.outcome == .pass && $0.help == .none }.map(\.skill))
            if skillsAt.isEmpty { return "an unaided task at \(target.title.lowercased()) level, in a skill of use (apply, debug, design or transfer)" }
            if !skillsAt.contains(where: \.isUse) { return "a task where they use it (apply, debug, design or transfer), unaided" }
            if skillsAt.count < 2 { return "a second skill at this level (explaining it, tracing, or a transfer to a new context)" }
            return "one more unaided success at this level, from a reliable source (an unseen task, their own code under tests, a defence)"
        }()
        return TeachingContract(competency: c.id, title: c.title, held: e.line.lowercased(), target: target, outcome: c.outcome(target),
                                teach: st.teach, practise: st.practise, assess: st.assess, hints: hints, sources: c.sources.isEmpty ? st.sources : st.sources + " (" + c.sources.joined(separator: ", ") + ")",
                                gaps: gaps, misconceptions: e.misconceptions + c.misconceptions, diagnose: diagnose, nextEvidence: missing)
    }
}

/// Adaptive placement: per competency, start at the learner's stated track and move up on a pass, down on a failure,
/// until it is bracketed (a pass at one level and a failure above it) or at a bound; a failure at school level queues
/// its prerequisites, which is where the gap is. Every answer is evidence (source: placement).
enum PlacementEngine {
    static func start(targets: [String], graph: CompetencyGraph, track: Level, ceiling: Level? = nil) -> Placement {
        let ids = targets.filter { graph[$0] != nil }
        var p = Placement(id: UUID().uuidString.prefix(8).lowercased(), targets: ids, queue: graph.ordered(ids), startLevel: min(track, ceiling ?? .university, .university), ceiling: ceiling)
        p.limit = min(30, max(Placement.maxProbes, ids.count + 6))
        return p
    }

    /// The skill a probe asks for at a level, varied so a placement sees more than one kind of ability.
    static func skill(_ l: Level, _ n: Int) -> Skill {
        let byLevel: [Level: [Skill]] = [.school: [.tracing, .recall, .explanation], .college: [.application, .debugging, .tracing],
                                         .university: [.design, .debugging, .explanation], .research: [.explanation, .design], .expert: [.design]]
        let list = byLevel[l] ?? [.application]
        return list[n % list.count]
    }

    /// The highest level a competency is placed at in this placement (nil: not shown at any).
    static func placed(_ p: Placement, _ id: String) -> Level? {
        p.probes.filter { $0.competency == id && $0.outcome == "pass" }.map(\.level).max()
    }

    /// The next probe, or nil when the placement is done.
    static func next(_ p: inout Placement, graph: CompetencyGraph) -> Placement.Probe? {
        if p.done { return nil }
        if p.probes.count >= p.limit { p.done = true; return nil }
        if let open = p.probes.last, open.outcome == nil { return open }
        while let id = p.queue.first {
            let mine = p.probes.filter { $0.competency == id }
            guard let c = graph[id] else { p.queue.removeFirst(); continue }
            let top: Level = min(c.kind == .research || c.outcomes[Level.research.rawValue] != nil ? .research : .university, p.ceiling ?? .expert)
            let level: Level? = {
                guard let last = mine.last else { return min(p.startLevel, top) }
                let passed = mine.filter { $0.outcome == "pass" }.map(\.level).max()
                let failed = mine.filter { $0.outcome == "fail" }.map(\.level).min()
                if last.outcome == "partial" { return nil }
                if last.outcome == "pass" { return last.level.next.flatMap { $0 <= top && (failed == nil || $0 < failed!) ? $0 : nil } }
                return last.level.previous.flatMap { (passed == nil || $0 > passed!) ? $0 : nil }
            }()
            if let level {
                let probe = Placement.Probe(competency: id, level: level, skill: skill(level, p.probes.count))
                p.probes.append(probe)
                return probe
            }
            p.queue.removeFirst()
            // Not shown even at school level: the gap is underneath; place its prerequisites next.
            if mine.allSatisfy({ $0.outcome == "fail" }), mine.contains(where: { $0.level == .school }) {
                let pre = (c.prereqs).filter { pid in !p.probes.contains { $0.competency == pid } && !p.queue.contains(pid) }
                p.queue.insert(contentsOf: pre, at: 0)
            }
        }
        p.done = true
        return nil
    }

    /// Records the answer to the open probe. Returns the evidence it makes.
    static func answer(_ p: inout Placement, outcome: Evidence.Outcome, help: Help, conversationID: String?) -> Evidence? {
        guard let i = p.probes.indices.last, p.probes[i].outcome == nil else { return nil }
        // Help in a placement means it wasn't shown: a pass with help is placed as partial.
        let o: Evidence.Outcome = help != .none && outcome == .pass ? .partial : outcome
        p.probes[i].outcome = o.rawValue
        let pr = p.probes[i]
        return Evidence(competency: pr.competency, skill: pr.skill, level: pr.level, outcome: o, help: help, source: .placement, conversationID: conversationID)
    }
}
