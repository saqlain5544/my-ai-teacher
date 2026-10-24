import Foundation

/// Folds a model's stream into the reply message, apart from any UI: each event updates the message and returns what the
/// transcript should do about it. `ChatSession` carries the effects out; a test (or another agent loop) can read them.
enum ReplyBuilder {
    enum Effect: Equatable {
        /// Text or thinking appended to block `index`.
        case delta(index: Int, kind: Block.Kind, text: String)
        /// The message changed shape (a tool call appeared or completed, text became thinking): redraw it.
        case upsert
        /// The reply is visible: a status line ("Thinking…") goes.
        case clearStatus
        case thinking
        case toolStarted(String)
        case todos([JSON])
    }

    static func apply(_ ev: StreamEvent, to m: inout ChatMessage) -> [Effect] {
        switch ev {
        case .text(let t):
            return [append(t, kind: .text, to: &m), .clearStatus]
        case .thinking(let t):
            return [append(t, kind: .thinking, to: &m), .thinking]
        case .thinkingSignature(let s):
            // A signature closes the open thinking block; new reasoning after it starts another.
            if let last = m.blocks.indices.last, m.blocks[last].kind == .thinking, m.blocks[last].signature == nil {
                m.blocks[last].signature = s
            } else {
                m.blocks.append(.thinking("", signature: s))
            }
            return []
        case .toolCallStarted(let id, let name):
            var b = Block.toolUse(id: id, name: name, input: .object([:]))
            b.meta = ["pending": true]
            m.blocks.append(b)
            return [.upsert, .toolStarted(name)]
        case .toolCall(let block):
            if let i = m.blocks.firstIndex(where: { $0.kind == .toolUse && $0.id == block.id }) { m.blocks[i] = block }
            else { m.blocks.append(block) }
            return block.name == "todo_write" ? [.upsert, .todos(block.input?["todos"]?.array ?? [])] : [.upsert]
        case .textWasThinking:
            // The reply so far was reasoning (a bare </think>): move its text into one thinking block.
            let t = m.blocks.filter { $0.kind == .text }.compactMap(\.text).joined()
            m.blocks.removeAll { $0.kind == .text }
            if !t.isEmpty { m.blocks.insert(.thinking(t), at: 0) }
            return [.upsert]
        case .toolCallArgs, .usage, .stop:
            return []
        }
    }

    /// Text joins the last block of its kind while one is open (thinking: until it is signed); otherwise a new block.
    private static func append(_ t: String, kind: Block.Kind, to m: inout ChatMessage) -> Effect {
        if let last = m.blocks.indices.last, m.blocks[last].kind == kind, kind == .text || m.blocks[last].signature == nil {
            m.blocks[last].text = (m.blocks[last].text ?? "") + t
            return .delta(index: last, kind: kind, text: t)
        }
        m.blocks.append(kind == .text ? .text(t) : .thinking(t))
        return .delta(index: m.blocks.count - 1, kind: kind, text: t)
    }
}
