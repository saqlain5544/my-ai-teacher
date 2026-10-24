import Foundation

/// The agent's door into the school. The app owns the record: the agent proposes (evidence it saw, a competency the
/// curriculum lacks, a lesson's focus) and the app validates, computes levels and decides progression and grades.
struct SchoolTool: Tool {
    let name = "school"
    let description = """
    The learner's school: a competency graph, their evidence-based level per competency, courses and a transcript. \
    The app sets levels and completes courses from evidence; you never declare a level. action="status": profile, \
    courses and what's next. "profile": record goal, track (school|college|university|research), hours_per_week, wants \
    (understanding, project, portfolio, certificate, research), languages. "catalog": courses with prerequisites. \
    "enroll" course. "focus" competency (and course): what this lesson studies; returns the teaching contract. \
    "contract" competency. "evidence": what you saw — competency, skill (recall, explanation, tracing, application, \
    debugging, design, transfer, communication), outcome (pass, partial, fail), help (none, hint, solution), source \
    (unseen: a task they hadn't seen; quiz; practice; defence: they explained or defended it; self: their own report), \
    level (default: the level being taught), misconception. "place": start an adaptive placement (targets: competency \
    or course ids; default from their goal) and get the first probe; "answer" (outcome, help) records it and returns the \
    next. "propose": a competency the curriculum lacks (a library, a topic): id, title, kind, prereqs, transfers, \
    aliases, outcomes {school, college, university, research}, misconceptions, sources. "level" competency. "transcript".
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["status", "profile", "catalog", "enroll", "focus", "contract", "evidence", "place", "answer", "propose", "level", "transcript"]),
            "competency": Schema.string("A competency id or name (\"recursion\", \"zig.memory\", \"context-free grammars\")."),
            "course": Schema.string("A course id (PF101, PL330, LANG-ZIG…)."),
            "goal": Schema.string("profile: what they want to be able to do."),
            "track": Schema.string("profile: school, college, university or research.", enum: ["school", "college", "university", "research"]),
            "hours_per_week": Schema.integer("profile: time they have."),
            "wants": Schema.array(Schema.string("understanding | project | portfolio | certificate | research"), "profile: the evidence they want at the end."),
            "languages": Schema.array(Schema.string("Language"), "profile: programming languages they use or want."),
            "skill": Schema.string("evidence: what the task showed.", enum: Skill.allCases.map(\.rawValue)),
            "outcome": Schema.string("evidence/answer: how it went.", enum: ["pass", "partial", "fail"]),
            "help": Schema.string("evidence/answer: the most help they had.", enum: ["none", "hint", "solution"]),
            "source": Schema.string("evidence: what kind of task.", enum: ["unseen", "quiz", "practice", "defence", "self"]),
            "level": Schema.string("evidence: the task's level (default: the level being taught).", enum: ["school", "college", "university", "research"]),
            "misconception": Schema.string("evidence: a misconception the answer showed."),
            "note": Schema.string("evidence: what they did, briefly."),
            "targets": Schema.array(Schema.string("Competency or course id"), "place: what to place them on."),
            "id": Schema.string("propose: a short id (\"lib.tokio\", \"category-theory\")."),
            "title": Schema.string("propose: its name."),
            "kind": Schema.string("propose: kind.", enum: ["concept", "language", "library", "toolchain", "research"]),
            "prereqs": Schema.array(Schema.string("Competency id"), "propose: prerequisites in the graph."),
            "transfers": Schema.array(Schema.string("Competency id"), "propose: the concepts it builds on (for an overlay)."),
            "aliases": Schema.array(Schema.string("Name"), "propose: other names."),
            "outcomes": Schema.object(["school": Schema.string("What they can do at school level."), "college": Schema.string("At college level."),
                                       "university": Schema.string("At university level."), "research": Schema.string("At research level.")]),
            "misconceptions": Schema.array(Schema.string("Misconception"), "propose: common misconceptions."),
            "sources": Schema.array(Schema.string("Reference"), "propose: canonical references."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { [input["action"]?.string, input["competency"]?.string ?? input["course"]?.string].compactMap { $0 }.joined(separator: " ") }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let school = ctx.services.school
        let g = school.graph
        defer { EventBus.publish(.studyDataChanged) }
        func competency() throws -> Competency {
            let name = try input.req("competency")
            guard let c = g.resolve(name) else {
                throw ToolError("No competency matches “\(name)”. Use an id from the catalog, or `school` propose it (with its prerequisites) if the curriculum lacks it.")
            }
            return c
        }
        func contract(_ c: Competency, course: Course? = nil) -> String {
            let est = school.estimates()
            let e = est[c.id] ?? SchoolStore.estimate(c.id, [])
            let target = school.target(c.id, course: course)
            return TeachingPolicy.contract(c, estimate: e, target: target, graph: g, estimates: est, recent: school.evidence(c.id, limit: 20)).rendered
        }

        switch input["action"]?.string ?? "status" {
        case "profile":
            var p = school.profile ?? SchoolProfile()
            if let s = input["goal"]?.string, !s.isEmpty { p.goal = s }
            if let t = input["track"]?.string.flatMap(Level.init(name:)) { p.track = t }
            if let h = input["hours_per_week"]?.int { p.hoursPerWeek = max(1, min(80, h)) }
            if let w = input["wants"]?.array?.compactMap(\.string), !w.isEmpty { p.wants = w }
            if let l = input["languages"]?.array?.compactMap(\.string), !l.isEmpty { p.languages = l }
            p.updatedAt = Date()
            school.profile = p
            return ToolOutput(text: "Profile saved: \(p.track.title) track, \(p.hoursPerWeek) h/week, goal “\(p.goal)”" + (p.wants.isEmpty ? "" : ", wants \(p.wants.joined(separator: ", "))") + ". Next: a placement (`school` place) unless their level is already on record.")

        case "catalog":
            let est = school.estimates()
            let done = Set(school.enrollments().filter { $0.status == "completed" }.map(\.course))
            let lines = g.courses.map { c -> String in
                let unmet = school.unmetPrerequisites(c, graph: g, estimates: est)
                let state = done.contains(c.id) ? "completed" : unmet.isEmpty ? "open" : "needs \(unmet.joined(separator: ", "))"
                return "\(c.id) · \(c.title) (\(c.level.title), \(c.hours) h) — \(state)"
            }
            return ToolOutput(text: lines.joined(separator: "\n"))

        case "enroll":
            let id = try input.req("course")
            if let why = school.enroll(id) { return .error("Can't enroll in \(id): \(why).") }
            let c = g.course(id)!
            let next = school.progress(c).next(g).flatMap { g[$0] }
            if let next { school.setLink(ctx.conversationID, competency: next.id, course: c.id) }
            return ToolOutput(text: "Enrolled in \(c.id) \(c.title) (\(c.level.title)). Outcomes: \(c.competencies.compactMap { g[$0]?.title }.joined(separator: ", ")). Assessed by \(c.assessments.joined(separator: ", ")); the app completes it when the evidence shows every outcome at \(c.level.title.lowercased()) level with a summative task." +
                              (next.map { "\nThis lesson now studies \($0.title):\n" + contract($0, course: c) } ?? ""))

        case "focus", "contract":
            let c = try competency()
            let course = input["course"]?.string.flatMap { g.course($0) } ?? school.link(ctx.conversationID).course.flatMap { g.course($0) }
            if input["action"]?.string == "focus" { school.setLink(ctx.conversationID, competency: c.id, course: course?.id) }
            return ToolOutput(text: contract(c, course: course))

        case "evidence":
            let c = try competency()
            guard let skill = input["skill"]?.string.flatMap(Skill.init(rawValue:)) else { return .error("`skill` is one of \(Skill.allCases.map(\.rawValue).joined(separator: ", ")).") }
            guard let outcome = input["outcome"]?.string.flatMap(Evidence.Outcome.init(rawValue:)) else { return .error("`outcome` is pass, partial or fail.") }
            let source = input["source"]?.string.flatMap(Evidence.Source.init(rawValue:)) ?? .practice
            let help = MasteryTool.help(input)
            let course = school.link(ctx.conversationID).course.flatMap { g.course($0) }
            let target = school.target(c.id, course: course)
            var level = input["level"]?.string.flatMap(Level.init(name:)) ?? target
            // A claim far above where they are is checked by a task at the next level first, not taken on one answer.
            if let above = target.next, level > above { level = above }
            school.record(Evidence(competency: c.id, skill: skill, level: level, outcome: outcome, help: help, source: source,
                                   note: input["note"]?.string, misconception: input["misconception"]?.string, conversationID: ctx.conversationID))
            let e = school.estimate(c.id)
            var text = "Recorded: \(c.title), \(skill.rawValue) at \(level.title.lowercased()) level, \(outcome.rawValue)\(help == .none ? "" : " with help") (\(source.rawValue)). Now: \(e.line)."
            for (course, grade) in school.progressCourses() {
                text += "\nThe evidence completes \(course.id) \(course.title): \(grade). It's on their transcript (an internal record, not an accredited qualification)."
            }
            return ToolOutput(text: text)

        case "place":
            let named = (input["targets"]?.array ?? []).compactMap(\.string)
            var targets = named.flatMap { t -> [String] in g.course(t)?.competencies ?? [g.resolve(t)?.id].compactMap { $0 } }
            // Courses named alone: placing for them (often prerequisites) needs no probe above their level.
            let courses = named.compactMap { g.course($0) }
            let ceiling: Level? = !courses.isEmpty && courses.count == named.count ? courses.map(\.level).max() : nil
            if targets.isEmpty, let goal = school.profile?.goal, !goal.isEmpty {
                targets = g.courses.filter { c in c.title.lowercased().split(separator: " ").contains { goal.lowercased().contains($0) && $0.count > 3 } }.flatMap(\.competencies)
            }
            if targets.isEmpty { targets = ["functions", "recursion", "complexity", "testing", "memory", "concurrency"] }
            var p = PlacementEngine.start(targets: Array(NSOrderedSet(array: targets)).compactMap { $0 as? String }, graph: g, track: school.profile?.track ?? .college, ceiling: ceiling)
            let probe = PlacementEngine.next(&p, graph: g)
            Self.stamp(&p, ctx)
            school.placement = p
            return ToolOutput(text: "Placement started on \(p.queue.count) competencies (at most \(p.limit) short tasks; each answer moves the next one up or down\(ceiling.map { ", none above \($0.title.lowercased()) level" } ?? "")). Ask how sure they are before each answer.\n" + Self.describe(probe, g))

        case "answer":
            guard var p = school.placement, !p.done else { return .error("No placement is running: `school` place starts one.") }
            guard let outcome = input["outcome"]?.string.flatMap(Evidence.Outcome.init(rawValue:)) else { return .error("`outcome` is pass, partial or fail.") }
            // An answer is the learner's: a probe handed out this turn can't be judged before they reply.
            if let asked = p.probes.last?.repliesAtAsk, Self.replies(ctx) <= asked {
                return .error("The learner hasn't answered this probe yet. Ask it, end your reply, and judge their answer next turn. Nothing was recorded.")
            }
            if let e = PlacementEngine.answer(&p, outcome: outcome, help: MasteryTool.help(input), conversationID: ctx.conversationID) { school.record(e) }
            let probe = PlacementEngine.next(&p, graph: g)
            Self.stamp(&p, ctx)
            school.placement = p
            if let probe { return ToolOutput(text: Self.describe(probe, g)) }
            return ToolOutput(text: Self.placementSummary(p, school: school, graph: g))

        case "propose":
            let id = try input.req("id"), title = try input.req("title")
            var o: [Int: String] = [:]
            for l in Level.allCases { if let s = input["outcomes"]?[l.title.lowercased()]?.string, !s.isEmpty { o[l.rawValue] = s } }
            let c = Competency(id: id, title: title, kind: input["kind"]?.string.flatMap(Competency.Kind.init(rawValue:)) ?? .concept, domain: "programming",
                               prereqs: (input["prereqs"]?.array ?? []).compactMap(\.string).compactMap { g.resolve($0)?.id },
                               transfers: (input["transfers"]?.array ?? []).compactMap(\.string).compactMap { g.resolve($0)?.id },
                               aliases: (input["aliases"]?.array ?? []).compactMap(\.string), misconceptions: (input["misconceptions"]?.array ?? []).compactMap(\.string),
                               outcomes: o, sources: (input["sources"]?.array ?? []).compactMap(\.string))
            if let why = school.propose(c, conversationID: ctx.conversationID) { return .error("Not added: \(why).") }
            return ToolOutput(text: "Added \(c.title) to the graph (proposed, marked as such)\(c.prereqs.isEmpty ? "" : ", after \(c.prereqs.joined(separator: ", "))"). `school` focus it to teach it.")

        case "level":
            let c = try competency()
            let e = school.estimate(c.id)
            let skills = e.skills.sorted { $0.key.rawValue < $1.key.rawValue }.map { "\($0.key.rawValue) \($0.value.title.lowercased())" }.joined(separator: ", ")
            return ToolOutput(text: "\(c.title): \(e.line) (\(e.evidenceCount) piece\(e.evidenceCount == 1 ? "" : "s") of evidence)" +
                              (skills.isEmpty ? "" : ". Skills shown unaided: \(skills)") +
                              (e.independence.map { ". Independence \(Int($0 * 100))%" } ?? "") + (e.recheckDue ? ". Due a re-check." : "."))

        case "transcript":
            return ToolOutput(text: SchoolReport.markdown(school))

        default:
            let p = school.profile
            var s = p.map { "Profile: \($0.track.title) track, \($0.hoursPerWeek) h/week. Goal: \($0.goal.isEmpty ? "—" : $0.goal)." } ?? "No profile yet: ask their goal, track, time and what evidence they want, then `school` profile."
            let est = school.estimates()
            for e in school.enrollments() where e.status == "enrolled" {
                guard let c = g.course(e.course) else { continue }
                let pr = school.progress(c, estimates: est)
                s += "\n\(c.id) \(c.title): \(pr.met.count)/\(c.competencies.count) outcomes" + (pr.next(g).flatMap { g[$0] }.map { "; next: \($0.title)" } ?? "")
            }
            let due = est.values.filter(\.recheckDue).compactMap { g[$0.competency]?.title }
            if !due.isEmpty { s += "\nDue a re-check: " + due.prefix(6).joined(separator: ", ") }
            if let pl = school.placement, !pl.done { s += "\nA placement is in progress (\(pl.probes.count) answered): `school` answer continues it." }
            return ToolOutput(text: s)
        }
    }

    /// The learner's answers so far in this lesson: messages of their own (not notes) and non-empty answers to questions
    /// that waited for them (`ask_learner`, `quiz`).
    static func replies(_ ctx: ToolContext) -> Int {
        ctx.services.conversations.messages(ctx.conversationID).filter { $0.role == .user }.flatMap(\.blocks).filter { b in
            if b.kind == .text { return b.meta?["hidden"]?.bool != true && !(b.text ?? "").isEmpty }
            guard b.kind == .toolResult, ["ask_learner", "quiz"].contains(b.name ?? ""), b.isError != true, let meta = b.meta else { return false }
            return !(meta["text"]?.string ?? "").isEmpty || !(meta["selected"]?.array ?? []).isEmpty || !(meta["answers"]?.array ?? []).isEmpty
        }.count
    }

    /// Stamps a probe just handed out with the replies so far.
    static func stamp(_ p: inout Placement, _ ctx: ToolContext) {
        if let i = p.probes.indices.last, p.probes[i].outcome == nil, p.probes[i].repliesAtAsk == nil { p.probes[i].repliesAtAsk = replies(ctx) }
    }

    static func describe(_ p: Placement.Probe?, _ g: CompetencyGraph) -> String {
        guard let p, let c = g[p.competency] else { return "No more probes." }
        return "Next probe: \(c.title) at \(p.level.title.lowercased()) level, skill \(p.skill.rawValue). Ask ONE \(p.skill.rawValue) task that someone at this level can do: \(c.outcome(p.level)). " +
            "Make it unseen and short (a few minutes), ask how sure they are, then `school` answer with the outcome and any help. Don't teach until the placement ends."
    }

    static func placementSummary(_ p: Placement, school: SchoolStore, graph g: CompetencyGraph) -> String {
        var s = "Placement done (\(p.probes.count) questions). Placed:\n"
        var seen: [String] = []
        for pr in p.probes where !seen.contains(pr.competency) {
            seen.append(pr.competency)
            let at = PlacementEngine.placed(p, pr.competency)
            s += "- \(g[pr.competency]?.title ?? pr.competency): " + (at.map { "shown at \($0.title.lowercased())" } ?? "not shown yet") + " — evidence: \(school.estimate(pr.competency).line)\n"
        }
        let est = school.estimates()
        let open = g.courses.filter { c in school.unmetPrerequisites(c, graph: g, estimates: est).isEmpty && !school.progress(c, estimates: est).completable }
        if let first = open.first(where: { $0.level == (school.profile?.track ?? .college) }) ?? open.first {
            s += "Suggested course: \(first.id) \(first.title) (\(first.level.title)). Tell them what the placement showed, kindly and concretely, and offer to enroll (`school` enroll)."
        }
        return s
    }
}

/// The transcript as Markdown: competencies with level and evidence, courses with grades, measures of learning, and the
/// plain statement that it is an internal record.
enum SchoolReport {
    static func markdown(_ school: SchoolStore, now: Date = Date()) -> String {
        let g = school.graph, est = school.estimates(now: now)
        let df = DateFormatter(); df.dateStyle = .medium
        var s = "# Transcript\n\n_An internal learning record from My AI Teacher: evidence-backed, not an accredited qualification._\n\n"
        if let p = school.profile { s += "Track: \(p.track.title). Goal: \(p.goal.isEmpty ? "—" : p.goal).\n\n" }
        let courses = school.enrollments()
        if !courses.isEmpty {
            s += "## Courses\n\n"
            for e in courses { s += "- \(e.course) \(g.course(e.course)?.title ?? "") — \(e.status)" + (e.grade.map { ", \($0)" } ?? "") + (e.completedAt.map { " (\(df.string(from: $0)))" } ?? "") + "\n" }
            s += "\n"
        }
        s += "## Competencies\n\n| Competency | Level | Skills shown unaided | Independence | Evidence |\n|---|---|---|---|---|\n"
        for (id, e) in est.sorted(by: { ($0.value.level?.rawValue ?? 0, $0.key) > ($1.value.level?.rawValue ?? 0, $1.key) }) {
            let skills = e.skills.keys.map(\.rawValue).sorted().joined(separator: ", ")
            s += "| \(g[id]?.title ?? id) | \(e.line) | \(skills) | \(e.independence.map { "\(Int($0 * 100))%" } ?? "—") | \(e.evidenceCount) |\n"
        }
        let m = school.measures(now: now)
        s += "\n## Learning measures\n\n- Hint dependence (30 days): \(m.hintDependence.map { "\(Int($0 * 100))%" } ?? "—")\n- Retention (unaided, 30+ days after first evidence): \(m.retention.map { "\(Int($0 * 100))%" } ?? "—")\n- Transfer: \(m.transfer.map { "\(Int($0 * 100))%" } ?? "—")\n"
        return s
    }
}
