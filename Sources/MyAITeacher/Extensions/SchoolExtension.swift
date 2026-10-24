import Foundation

/// Puts the school in each request: the teaching contract for what this lesson studies (its linked competency, or the
/// course board's focus card when that is one of the graph's), so the same agent teaches recursion concretely to one
/// learner and through proofs to another. After a turn, courses the new evidence completes are completed and announced.
@MainActor
final class SchoolExtension: AgentExtension {
    let id = "school"

    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        let mode = session.conversation.mode
        guard !mode.isAgent, mode != .language else { return }
        guard let block = Self.state(for: session) else { return }
        guard let i = request.messages.indices.last, request.messages[i].role == .user else { return }
        request.messages[i].blocks.removeAll { $0.meta?["schoolState"]?.bool == true }
        request.messages[i].blocks.append(Block(kind: .text, text: block, meta: ["schoolState": true]))
    }

    /// The contract, a placement in progress (its open probe, so it carries across turns), or — before the learner has a
    /// school profile — the one line that says the school comes first for a stated goal.
    static func state(for session: ChatSession) -> String? {
        let school = session.services.school
        var parts: [String] = []
        if let p = school.placement, !p.done, let probe = p.probes.last, probe.outcome == nil, let c = school.graph[probe.competency] {
            parts.append("<school_placement>A placement is running (\(p.probes.count) of at most \(p.limit)). Open probe: \(c.title) at \(probe.level.title.lowercased()) level, skill \(probe.skill.rawValue) — \(c.outcome(probe.level)). If their message answers it, judge it (pass, partial or fail; any help) and `school` answer; then ask the next probe it returns. Don't teach until it ends.</school_placement>")
        }
        if let c = contract(for: session) { parts.append(c) }
        else if school.profile == nil {
            parts.append("<school>No school profile yet. When the learner states a learning goal (a level to reach, a subject, their time), set up the school first: `school` profile (goal, track, hours, the evidence they want), then `school` place, one probe at a time — before a course board, which then plans the course they enroll in.</school>")
        }
        return parts.isEmpty ? nil : parts.joined(separator: "\n")
    }

    static func contract(for session: ChatSession) -> String? {
        let school = session.services.school
        let g = school.graph
        let link = school.link(session.id)
        let course = link.course.flatMap { g.course($0) }
        let competency = link.competency.flatMap { g[$0] }
            ?? session.services.study.board(forLesson: session.id)?.focus.flatMap { card in card.concept.flatMap { g.resolve($0) } ?? g.resolve(card.title) }
        guard let c = competency else { return nil }
        let est = school.estimates()
        let e = est[c.id] ?? SchoolStore.estimate(c.id, [])
        return TeachingPolicy.contract(c, estimate: e, target: school.target(c.id, course: course), graph: g, estimates: est,
                                       recent: school.evidence(c.id, limit: 20)).rendered
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        for (course, grade) in session.services.school.progressCourses() {
            EventBus.publish(.notice(conversationID: session.id, text: "Course complete: \(course.id) \(course.title) — \(grade). It's on your transcript."))
            EventBus.publish(.studyDataChanged)
        }
    }
}
