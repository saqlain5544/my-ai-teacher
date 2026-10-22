import Foundation

enum APIKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case anthropic, openai, gemini
    var id: String { rawValue }
    var title: String {
        switch self {
        case .anthropic: "Anthropic Messages"
        case .openai: "OpenAI Chat Completions"
        case .gemini: "Google Gemini"
        }
    }
}

enum ThinkingLevel: String, Codable, CaseIterable, Sendable, Identifiable {
    case off, low, medium, high, max
    var id: String { rawValue }
    var budget: Int { switch self { case .off: 0; case .low: 2048; case .medium: 8192; case .high: 24576; case .max: 32768 } }

    /// What the model can take: `max` only where the model lists it (DeepSeek V4, Claude); elsewhere `high`.
    func supported(by info: ModelInfo?) -> ThinkingLevel {
        self == .max && !(info?.efforts?.contains("max") ?? false) ? .high : self
    }
}

struct ToolSpec: Sendable {
    let name: String
    let description: String
    let schema: JSON
    /// A provider-native definition sent instead (Anthropic's computer-use tool), with the beta header it needs.
    var native: JSON? = nil
    var nativeBeta: String? = nil
}

struct LLMRequest: Sendable {
    var model: String
    var system: String
    var messages: [ChatMessage]
    var tools: [ToolSpec] = []
    var maxTokens = 16384
    var temperature: Double?
    var thinking: ThinkingLevel = .off
    /// Stable for one lesson (or sub-agent run): providers with a `sessionHeader` route and cache by it.
    var sessionID: String?
}

enum StreamEvent: Sendable {
    case text(String)
    case thinking(String)
    case thinkingSignature(String)
    case toolCallStarted(id: String, name: String)
    case toolCallArgs(id: String, partial: String)
    case toolCall(Block)
    case usage(Usage)
    case stop(String)
    /// Everything streamed as text so far in this reply was reasoning (a bare </think> arrived: the template opened it).
    case textWasThinking
}

protocol LLMClient: Sendable {
    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error>
}

struct ProviderConfig: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var name: String
    var api: APIKind
    var baseURL: String
    var envKeys: [String]
    var defaultModel: String
    var keyOptional = false
    var headers: [String: String] = [:]
    var isCustom = false
    var supportsVision = true
    /// Suggested models shown before the live list loads (and for providers without /models).
    var suggestedModels: [String] = []
    var quirks: [Quirk] = []
    var note: String?
    /// Model ids the provider retired → what now serves them (a saved lesson on an old id keeps working).
    var retired: [String: String]?
    /// A header carrying `LLMRequest.sessionID` on every request (OpenCode Go refuses requests without `x-opencode-session`).
    var sessionHeader: String?
    /// The provider's id on models.dev: context windows, output limits, free models, and which API serves each model,
    /// for providers whose own /models lists only ids.
    var modelsDev: String?
    /// One provider behind several APIs (OpenCode Go): the base URL of each API other than `api` (`APIKind` raw value → URL).
    /// Each request goes to the API that serves its model (`ModelRoutes`).
    var apiBases: [String: String]?
    /// Where the model list lives when it isn't `<baseURL>/models` (OpenCode Go lists at …/go/v1/models while chat
    /// completions live under …/go/openai/v1).
    var modelsURL: String?

    func currentModel(_ id: String) -> String { retired?[id] ?? id }

    /// The configured headers plus the session header, when the provider wants one.
    func headers(for request: LLMRequest) -> [String: String] {
        var h = headers
        if let name = sessionHeader { h[name] = request.sessionID ?? UUID().uuidString }
        return h
    }

    /// The provider's client behind the stream guard (text-embedded tool calls, reasoning tags, end tokens, duplicates).
    func client(apiKey: String?) -> LLMClient {
        if apiBases != nil { return GuardedClient(inner: RoutedClient(config: self, apiKey: apiKey)) }
        return switch api {
        case .anthropic: GuardedClient(inner: AnthropicClient(config: self, apiKey: apiKey))
        case .openai: GuardedClient(inner: OpenAIClient(config: self, apiKey: apiKey))
        case .gemini: GuardedClient(inner: GeminiClient(config: self, apiKey: apiKey))
        }
    }
}

/// Accumulates a streamed tool call's JSON arguments.
struct PartialToolCall {
    var id: String
    var name: String
    var args = ""
    var signature: String?

    func finish() -> Block {
        let trimmed = args.trimmingCharacters(in: .whitespacesAndNewlines)
        let input: JSON = trimmed.isEmpty ? .object([:]) : (JSON.parse(trimmed) ?? Self.repair(trimmed))
        return .toolUse(id: id, name: name, input: input, signature: signature)
    }

    /// Best-effort repair of truncated JSON (closes open strings/brackets).
    static func repair(_ s: String) -> JSON {
        var stack: [Character] = []
        var inString = false, escape = false
        for ch in s {
            if escape { escape = false; continue }
            if ch == "\\" { escape = true; continue }
            if ch == "\"" { inString.toggle(); continue }
            if inString { continue }
            if ch == "{" { stack.append("}") } else if ch == "[" { stack.append("]") }
            else if ch == "}" || ch == "]" { _ = stack.popLast() }
        }
        var fixed = s
        if inString { fixed += "\"" }
        fixed += String(stack.reversed())
        return JSON.parse(fixed) ?? .object(["_raw": .string(s)])
    }
}

/// Splits `<think>…</think>` reasoning that some OpenAI-compatible models inline in content.
struct ThinkTagSplitter {
    private var inThink = false
    private var pending = ""
    private var sawAnyText = false

    mutating func feed(_ chunk: String) -> [StreamEvent] {
        var out: [StreamEvent] = []
        pending += chunk
        while !pending.isEmpty {
            let tag = inThink ? "</think>" : "<think>"
            // A literal "<think>" mid-answer is text; only an opening one starts reasoning (a bare "</think>" is the guard's).
            if let r = pending.range(of: tag), inThink || !sawAnyText {
                let before = String(pending[..<r.lowerBound])
                emit(before, into: &out)
                pending = String(pending[r.upperBound...])
                inThink.toggle()
                if !inThink { pending = pending.replacingOccurrences(of: "^\\s+", with: "", options: .regularExpression) }
                continue
            }
            // Keep a possible partial tag at the end.
            var keep = 0
            for n in stride(from: min(tag.count - 1, pending.count), through: 1, by: -1) {
                if tag.hasPrefix(pending.suffix(n)) { keep = n; break }
            }
            let emitPart = String(pending.dropLast(keep))
            emit(emitPart, into: &out)
            pending = String(pending.suffix(keep))
            break
        }
        return out
    }

    mutating func flush() -> [StreamEvent] {
        var out: [StreamEvent] = []
        emit(pending, into: &out); pending = ""
        return out
    }

    private mutating func emit(_ s: String, into out: inout [StreamEvent]) {
        guard !s.isEmpty else { return }
        if inThink { out.append(.thinking(s)) } else { emitText(s, into: &out) }
    }

    private mutating func emitText(_ s: String, into out: inout [StreamEvent]) {
        guard !s.isEmpty else { return }
        if !sawAnyText && s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return }
        sawAnyText = true
        out.append(.text(s))
    }
}

extension URLRequest {
    static func json(_ url: URL, body: JSON, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url)
        r.httpMethod = "POST"
        r.httpBody = body.data
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }
}

extension String {
    func joinedURL(_ path: String) -> URL {
        var base = self
        while base.hasSuffix("/") { base.removeLast() }
        return URL(string: base + (path.hasPrefix("/") ? path : "/" + path))!
    }
}
