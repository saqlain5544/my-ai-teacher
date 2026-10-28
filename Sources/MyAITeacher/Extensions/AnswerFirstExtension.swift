import Foundation

/// A teaching turn that keeps checking without answering is told to answer. "Verify before you teach" has no natural
/// end for a model: in measured lessons an expert's question about Rust's borrow checker took 34 tool calls of reading
/// rustc's source, and a PhD question had the model writing its own type-inference engine, both silent past three
/// minutes. After `limit` tool calls with no reply the learner can read, each result carries a note to answer now with
/// what it has, say what it couldn't verify, and offer to go further. Some models ignore notes in tool results (one
/// built the OCaml compiler from source through seven of them), so at `cutoff` calls the next request offers no tools
/// and the model has to write the answer. Every teaching mode.
@MainActor
final class AnswerFirstExtension: AgentExtension {
    let id = "answer-first"
    static let limit = 12, every = 6, cutoff = 24
    private var turnStart: [String: Int] = [:]
    private var calls: [String: Int] = [:]

    /// A turn starts at its first request, whatever started it (a message, regenerate, retry, a background report): set
    /// only on sending, a regenerated turn inherited the last turn's count and lost its tools on its first request.
    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        if turnStart[session.id] == nil { turnStart[session.id] = max(0, session.messages.count - 1); calls[session.id] = 0 }
        guard (calls[session.id] ?? 0) >= Self.cutoff, !answered(session) else { return }
        request.toolsOff = true
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) { turnStart[session.id] = nil; calls[session.id] = nil }

    private func answered(_ session: ChatSession) -> Bool {
        let start = min(turnStart[session.id] ?? 0, session.messages.count)
        return session.messages[start...].contains { m in
            m.role == .assistant && m.meta?["superseded"]?.bool != true && m.blocks.contains { $0.kind == .text && ($0.text?.count ?? 0) >= 400 }
        }
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        let n = (calls[session.id] ?? 0) + 1
        calls[session.id] = n
        guard n >= Self.limit, (n - Self.limit) % Self.every == 0, !answered(session) else { return }
        result.text = (result.text ?? "") + "\n[\(n) tool calls and the learner has no answer yet. Answer now with what you have: say plainly what you couldn't verify, and offer to check further if they want. No more tools before the answer.]"
    }

    func sessionWillClose(_ session: ChatSession) { turnStart[session.id] = nil; calls[session.id] = nil }
}
