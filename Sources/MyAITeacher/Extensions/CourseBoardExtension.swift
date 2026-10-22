import Foundation

/// Keeps the mentor oriented on its course board: the compact `<lesson_state>` card is appended to the last learner
/// message of every request (request copy only — never stored, so the cached prefix and the transcript stay clean), the
/// board survives summary compaction, and graded answers attach evidence to the card that teaches the concept.
@MainActor
final class CourseBoardExtension: AgentExtension {
    let id = "course-board"

    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        guard !session.conversation.mode.isAgent, let header = Self.stateBlock(session) else { return }
        Self.inject(header, into: &request)
    }

    func summaryContext(_ session: ChatSession) -> [String] {
        guard let b = session.services.study.board(forLesson: session.id) else { return [] }
        return [b.header()]
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard !session.conversation.mode.isAgent, result.isError != true else { return }
        let study = session.services.study
        switch call.name {
        case "mastery":
            guard call.input?["action"]?.string == "record", let concept = call.input?["concept"]?.string, var b = study.board(forLesson: session.id) else { return }
            let right = call.input?["correct"]?.bool ?? false
            let helped = call.input?["assisted"]?.bool == true
            guard b.attachEvidence(concept: concept, "\(concept): \(right ? "correct" : "incorrect")\(helped ? " with help" : " unaided")") != nil else { return }
            study.save(b, conversationID: session.id)
        case "ask_learner", "quiz":
            guard let graded = result.meta?["graded"]?.array, !graded.isEmpty, let questions = call.input?["questions"]?.array,
                  var b = study.board(forLesson: session.id) else { return }
            var tally: [String: (right: Int, total: Int, hinted: Int)] = [:]
            var order: [String] = []
            for (i, g) in graded.enumerated() {
                guard let c = g["correct"]?.bool, let concept = questions[safe: i]?["concept"]?.string, !concept.isEmpty else { continue }
                if tally[concept] == nil { order.append(concept); tally[concept] = (0, 0, 0) }
                tally[concept]!.total += 1
                if c { tally[concept]!.right += 1 }
                if (g["hints"]?.int ?? 0) > 0 { tally[concept]!.hinted += 1 }
            }
            var touched = false
            for concept in order {
                let t = tally[concept]!
                let text = "quiz: \(concept) \(t.right)/\(t.total)" + (t.hinted > 0 ? " (\(t.hinted) with hints)" : "")
                if b.attachEvidence(concept: concept, text) != nil { touched = true }
            }
            if touched { study.save(b, conversationID: session.id); EventBus.publish(.studyDataChanged) }
        default: break
        }
    }

    // MARK: The state card

    /// The board's header enriched with what the app observed: the problem awaiting an attempt, the focus concept's mastery.
    static func stateBlock(_ session: ChatSession) -> String? {
        guard let b = session.services.study.board(forLesson: session.id) else { return nil }
        return b.header(openLoop: openLoop(session.messages), watch: watch(b, study: session.services.study))
    }

    /// Appends the card to the last learner message of the request (after tool results, so every provider accepts it).
    nonisolated static func inject(_ header: String, into request: inout LLMRequest) {
        guard let i = request.messages.indices.last, request.messages[i].role == .user else { return }
        request.messages[i].blocks.removeAll { $0.meta?["lessonState"]?.bool == true }
        request.messages[i].blocks.append(Block(kind: .text, text: header, meta: ["lessonState": true]))
    }

    /// A ```problem the mentor posed in its last reply is an open loop until the learner's attempt is handled.
    nonisolated static func openLoop(_ messages: [ChatMessage]) -> String? {
        guard let lastUser = messages.lastIndex(where: { $0.role == .user && !$0.isToolResultOnly }),
              let reply = messages[..<lastUser].last(where: { $0.role == .assistant && !$0.plainText.isEmpty }) else { return nil }
        let text = reply.plainText
        guard let fence = text.range(of: "```problem", options: .backwards) else { return nil }
        let after = text[fence.upperBound...]
        let body = after.range(of: "```").map { String(after[..<$0.lowerBound]) } ?? String(after)
        guard let j = JSON.parse(body.trimmingCharacters(in: .whitespacesAndNewlines)), let q = j["q"]?.string else { return nil }
        return "awaiting the learner's attempt at: " + MemoryText.clip(q.replacingOccurrences(of: "\n", with: " "), 100)
    }

    /// The focus card's concept, as `mastery` currently sees it.
    nonisolated static func watch(_ b: CourseBoard, study: StudyStore) -> String? {
        guard let f = b.focus else { return nil }
        let keys = ([f.concept].compactMap { $0 } + f.objectives).map(MemoryText.conceptKey)
        let items = study.allMastery().filter { keys.contains(MemoryText.conceptKey($0.concept)) }.prefix(3)
        guard !items.isEmpty else { return nil }
        return items.map { m in
            "\(m.concept) \(Int(m.pKnown * 100))% (\(m.correct)/\(m.attempts)\(m.streak >= 2 ? ", streak \(m.streak)" : ""))"
        }.joined(separator: "; ")
    }
}
