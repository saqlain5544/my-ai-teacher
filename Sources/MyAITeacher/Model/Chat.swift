import Foundation

enum Role: String, Codable, Sendable { case user, assistant }

/// One content block of a message. A flat struct (rather than an enum) keeps storage and the
/// JS bridge simple: the web view receives these blocks verbatim as JSON.
struct Block: Codable, Sendable, Hashable {
    enum Kind: String, Codable, Sendable { case text, thinking, image, file, toolUse, toolResult }

    var kind: Kind
    var text: String?
    var signature: String?      // Anthropic thinking signature / Gemini thoughtSignature
    var id: String?             // tool call id
    var name: String?           // tool name or file name
    var input: JSON?            // tool input
    var isError: Bool?
    var mime: String?
    var data: String?           // base64 payload for images
    var meta: JSON?             // UI-only metadata (search results, quiz state, timings…)

    static func text(_ s: String) -> Block { Block(kind: .text, text: s) }
    static func thinking(_ s: String, signature: String? = nil) -> Block { Block(kind: .thinking, text: s, signature: signature) }
    static func image(mime: String, base64: String, name: String? = nil) -> Block {
        Block(kind: .image, name: name, mime: mime, data: base64)
    }
    static func file(name: String, content: String) -> Block { Block(kind: .file, text: content, name: name) }
    static func toolUse(id: String, name: String, input: JSON, signature: String? = nil) -> Block {
        Block(kind: .toolUse, signature: signature, id: id, name: name, input: input)
    }
    static func toolResult(id: String, name: String, content: String, isError: Bool = false,
                           images: [Block] = [], meta: JSON? = nil) -> Block {
        var b = Block(kind: .toolResult, text: content, id: id, name: name, isError: isError, meta: meta)
        if let img = images.first { b.mime = img.mime; b.data = img.data }
        return b
    }
}

struct Usage: Codable, Sendable, Hashable {
    var input = 0          // uncached input tokens
    var output = 0         // output tokens (including reasoning where the provider counts it there)
    var cacheRead = 0
    var cacheWrite = 0
    var reasoningTokens: Int? = nil

    var reasoning: Int { reasoningTokens ?? 0 }
    var promptTotal: Int { input + cacheRead + cacheWrite }
    var total: Int { promptTotal + output }

    static func + (a: Usage, b: Usage) -> Usage {
        Usage(input: a.input + b.input, output: a.output + b.output, cacheRead: a.cacheRead + b.cacheRead,
              cacheWrite: a.cacheWrite + b.cacheWrite,
              reasoningTokens: (a.reasoningTokens == nil && b.reasoningTokens == nil) ? nil : a.reasoning + b.reasoning)
    }
}

struct ChatMessage: Codable, Sendable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var role: Role
    var blocks: [Block]
    var createdAt = Date()
    var model: String?
    var usage: Usage?
    var error: String?
    /// Per-LLM-call metrics (assistant messages).
    var metrics: StepMetrics?
    /// Whole-turn metrics, attached to the last assistant message of a turn.
    var turn: TurnMetrics?
    /// Extension-owned metadata (recalled memories, detected languages…).
    var meta: JSON?

    var plainText: String {
        blocks.filter { $0.kind == .text }.compactMap(\.text).joined(separator: "\n")
    }
    var toolUses: [Block] { blocks.filter { $0.kind == .toolUse } }
    var isToolResultOnly: Bool { !blocks.isEmpty && blocks.allSatisfy { $0.kind == .toolResult } }
}

enum TeachingMode: String, Codable, CaseIterable, Identifiable, Sendable {
    case tutor, socratic, explain, quiz, exam, code, eli5, research
    var id: String { rawValue }
    var title: String {
        switch self {
        case .tutor: "Tutor"
        case .socratic: "Socratic"
        case .explain: "Explain"
        case .quiz: "Quiz me"
        case .exam: "Exam prep"
        case .code: "Code mentor"
        case .eli5: "ELI5"
        case .research: "Research"
        }
    }
    var symbol: String {
        switch self {
        case .tutor: "graduationcap"
        case .socratic: "questionmark.bubble"
        case .explain: "text.book.closed"
        case .quiz: "checklist"
        case .exam: "pencil.and.list.clipboard"
        case .code: "chevron.left.forwardslash.chevron.right"
        case .eli5: "face.smiling"
        case .research: "globe"
        }
    }
}

struct Conversation: Codable, Sendable, Identifiable, Hashable {
    var id: String = UUID().uuidString
    var title: String = "New lesson"
    var createdAt = Date()
    var updatedAt = Date()
    var providerID: String
    var model: String
    var mode: TeachingMode = .tutor
    var subject: String?
    var pinned = false
    var reflectedAt: Date?
    /// Frozen at the first turn so the prompt prefix (and thinking signatures) stay valid for the whole lesson.
    var systemPrompt: String?
    var compactSummary: String?
    var compactedThrough: String?
    var reflectedCount: Int?
    var usage: Usage?
    var stats: ConversationStats?
    /// Deferred tools this lesson has loaded (append-only).
    var loadedTools: [String]?
    /// Microcompaction epoch: blocks up to this message are trimmed in requests.
    var trimmedThrough: String?
}
