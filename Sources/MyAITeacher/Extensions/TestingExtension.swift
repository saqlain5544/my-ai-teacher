import Foundation

/// Whether the learner is being tested, and what a skipped question tells the teacher.
///
/// The learner switches quizzes off and on from the toolbar; the switch is sticky (off stays off until they turn it back
/// on) and takes effect from their next message. Quiz and Exam prep modes always test: testing is what they are for.
enum Testing {
    static func on(_ settings: AppSettings, _ mode: TeachingMode) -> Bool {
        settings.quizzes || mode == .quiz || mode == .exam
    }

    /// Appended to the learner's message (request copy only) while quizzes are off.
    static let offNote = """
        <context>The learner has turned quizzes off. Teach without testing them: no graded questions, quizzes, ```problem \
        or ```practice blocks, and no mastery checks, until they turn quizzes back on. If they ask to be tested, tell them \
        the Quizzes switch in the toolbar turns testing on, and don't set the test in prose instead. Asking what they want \
        or what they think as part of teaching is fine.</context>
        """

    /// What a graded `ask_learner` says when the teacher tries to test anyway.
    static let refusal = "Quizzes are off: the learner turned testing off. Don't test them; teach, and carry on with the lesson. (Plain, ungraded `ask_learner` questions about what they want are fine.)"

    /// Why the learner skipped a quiz or a question, and what the teacher should do about it.
    enum SkipReason: String, CaseIterable, Sendable {
        case needMore = "need_more", tooEasy = "too_easy", notNow = "not_now", unclear

        var label: String {
            switch self {
            case .needMore: "needs more explanation first"
            case .tooEasy: "too easy"
            case .notNow: "not now"
            case .unclear: "unclear or wrong"
            }
        }
        var guidance: String {
            switch self {
            case .needMore:
                "They haven't understood enough to attempt it: a teaching gap, not a mistake (record nothing). Don't test again now. Teach the idea more deeply from a different angle (the mechanism, a worked example, a visual), check for a missing prerequisite, then carry on. Test it later, in a new context."
            case .tooEasy:
                "They found it a no-brainer: don't repeat this level. Skip what they clearly know, raise the difficulty, and make the next check a real exam-grade problem."
            case .notNow:
                "They want to keep going: continue with the lesson or what they asked for, and don't test again in this turn."
            case .unclear:
                "They found it unclear or wrong: re-read your questions, say plainly what was wrong if anything, and don't ask them again as they were."
            }
        }
    }

    /// The tool result for a skip: the reason (when the learner gave one) and what to do about it.
    static func skipped(_ what: String, reason: String?) -> String {
        guard let r = reason.flatMap(SkipReason.init(rawValue:)) else {
            return "The learner skipped the \(what). Don't ask it again right away; carry on with the lesson."
        }
        return "The learner skipped the \(what) — \(r.label). \(r.guidance)"
    }
}

/// Tells the teacher, on every request, when the learner has switched quizzes off.
@MainActor
final class TestingExtension: AgentExtension {
    let id = "testing"

    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        guard !session.conversation.mode.isAgent, !Testing.on(session.settings, session.conversation.mode),
              let i = request.messages.indices.last, request.messages[i].role == .user else { return }
        request.messages[i].blocks.removeAll { $0.meta?["testingOff"]?.bool == true }
        request.messages[i].blocks.append(Block(kind: .text, text: Testing.offNote, meta: ["testingOff": true]))
    }
}
