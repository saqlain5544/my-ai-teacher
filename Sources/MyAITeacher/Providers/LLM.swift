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
    case off, low, medium, high
    var id: String { rawValue }
    var budget: Int { switch self { case .off: 0; case .low: 2048; case .medium: 8192; case .high: 24576 } }
}

struct ToolSpec: Sendable {
    let name: String
    let description: String
    let schema: JSON
}

struct LLMRequest: Sendable {
    var model: String
    var system: String
    var messages: [ChatMessage]
    var tools: [ToolSpec] = []
    var maxTokens = 16384
    var temperature: Double?
    var thinking: ThinkingLevel = .off
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

    func client(apiKey: String?) -> LLMClient {
        switch api {
        case .anthropic: AnthropicClient(config: self, apiKey: apiKey)
        case .openai: OpenAIClient(config: self, apiKey: apiKey)
        case .gemini: GeminiClient(config: self, apiKey: apiKey)
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
/// Drops a model's raw control markers that some providers leak into text, e.g. DeepSeek's `<｜DSML｜function_calls>`
/// or `<｜tool▁calls▁begin｜>` (full-width bars), even when a marker arrives split across chunks.
struct MarkerFilter {
    private var held = ""
    private static let marker = try! NSRegularExpression(pattern: "</?｜[^<>\n]{0,80}>")

    mutating func feed(_ chunk: String) -> String {
        held += chunk
        held = Self.marker.stringByReplacingMatches(in: held, range: NSRange(held.startIndex..., in: held), withTemplate: "")
        // Hold back a possible unfinished marker at the end.
        if let open = held.range(of: "<", options: .backwards), case let tail = held[open.lowerBound...], tail.count <= 82, !tail.contains(">"),
           tail == "<" || tail == "</" || tail.hasPrefix("<｜") || tail.hasPrefix("</｜") {
            let out = String(held[..<open.lowerBound]); held = String(held[open.lowerBound...]); return out
        }
        defer { held = "" }
        return held
    }
    mutating func flush() -> String { defer { held = "" }; return held }
}

struct ThinkTagSplitter {
    private var inThink = false
    private var pending = ""
    private var sawAnyText = false

    mutating func feed(_ chunk: String) -> [StreamEvent] {
        var out: [StreamEvent] = []
        pending += chunk
        while !pending.isEmpty {
            let tag = inThink ? "</think>" : "<think>"
            if let r = pending.range(of: tag) {
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
        emitText(markers.flush(), into: &out)
        return out
    }

    private var markers = MarkerFilter()

    private mutating func emit(_ s: String, into out: inout [StreamEvent]) {
        guard !s.isEmpty else { return }
        if inThink { out.append(.thinking(s)) } else { emitText(markers.feed(s), into: &out) }
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
