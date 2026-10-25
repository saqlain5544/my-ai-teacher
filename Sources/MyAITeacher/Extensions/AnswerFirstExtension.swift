import Foundation

/// A teaching turn that keeps checking without answering is told to answer. "Verify before you teach" has no natural
/// end for a model: in measured lessons an expert's question about Rust's borrow checker took 34 tool calls of reading
/// rustc's source, and a PhD question had the model writing its own type-inference engine, both silent past three
/// minutes. After `limit` tool calls with no reply the learner can read, each result carries a note to answer now with
/// what it has, say what it couldn't verify, and offer to go further. Teaching modes only; the code agent works on.
@MainActor
final class AnswerFirstExtension: AgentExtension {
    let id = "answer-first"
    static let limit = 12, every = 6
    private var turnStart: [String: Int] = [:]
    private var calls: [String: Int] = [:]

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        turnStart[session.id] = session.messages.count
        calls[session.id] = 0
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard !session.conversation.mode.isAgent else { return }
        let n = (calls[session.id] ?? 0) + 1
        calls[session.id] = n
        guard n >= Self.limit, (n - Self.limit) % Self.every == 0 else { return }
        let start = min(turnStart[session.id] ?? 0, session.messages.count)
        let answered = session.messages[start...].contains { m in
            m.role == .assistant && m.meta?["superseded"]?.bool != true && m.blocks.contains { $0.kind == .text && ($0.text?.count ?? 0) >= 400 }
        }
        guard !answered else { return }
        result.text = (result.text ?? "") + "\n[\(n) tool calls and the learner has no answer yet. Answer now with what you have: say plainly what you couldn't verify, and offer to check further if they want. No more tools before the answer.]"
    }

    func sessionWillClose(_ session: ChatSession) { turnStart[session.id] = nil; calls[session.id] = nil }
}
