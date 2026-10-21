import Foundation

/// Behaviour switches for the many OpenAI-compatible servers.
enum Quirk: String, Codable, Sendable {
    case maxCompletionTokens      // OpenAI reasoning models reject `max_tokens`
    case reasoningEffort          // send `reasoning_effort`
    case openrouterReasoning      // send `reasoning: {effort}`
    case reasoningContentBack     // replay `reasoning_content` on assistant tool-call turns (DeepSeek, Kimi)
    case chatTemplateThinking     // vLLM/NIM hosts: "off" goes in `chat_template_kwargs` (thinking / enable_thinking)
    case deepseekThinking         // DeepSeek V4: `thinking: {type: enabled|disabled}` (on by default) + `reasoning_effort`
    case noStreamOptions          // server rejects `stream_options`
}

/// OpenAI Chat Completions API — OpenAI, OpenRouter, Groq, Mistral, DeepSeek, NVIDIA, Ollama, LM Studio,
/// OpenCode Zen, xAI, Together, Cerebras, Fireworks and any custom compatible server.
struct OpenAIClient: LLMClient {
    let config: ProviderConfig
    let apiKey: String?

    /// Models that rejected `reasoning: {enabled: false}` (learned at runtime; "off" then means the lowest effort).
    nonisolated(unsafe) private static var mandatoryReasoning = Set<String>()
    private static let lock = NSLock()
    static func reasoningIsMandatory(_ model: String) -> Bool { lock.withLock { mandatoryReasoning.contains(model) } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        guard request.thinking == .off, config.quirks.contains(.openrouterReasoning), !Self.reasoningIsMandatory(request.model) else {
            return streamOnce(request)
        }
        // One retry if the endpoint says reasoning can't be disabled; nothing has been yielded at that point.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await ev in streamOnce(request) { continuation.yield(ev) }
                    continuation.finish()
                } catch let e as HTTPError where e.status == 400 && e.body.localizedCaseInsensitiveContains("mandatory") {
                    _ = Self.lock.withLock { Self.mandatoryReasoning.insert(request.model) }
                    do { for try await ev in streamOnce(request) { continuation.yield(ev) }; continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamOnce(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        var headers = config.headers
        if let apiKey { headers["Authorization"] = "Bearer \(apiKey)" }
        let req = URLRequest.json(config.baseURL.joinedURL("/chat/completions"), body: buildBody(request), headers: headers)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var calls: [Int: PartialToolCall] = [:]
                var order: [Int] = []
                var splitter = ThinkTagSplitter()
                var usage: Usage?
                var finish: String?
                do {
                    for try await ev in SSEClient.stream(req) {
                        if SSEClient.trace { FileHandle.standardError.write(Data(("SSE " + ev.data + "\n").utf8)) }
                        if ev.event == "__json__" { Self.emitNonStreaming(ev.data, continuation); continue }
                        if ev.data == "[DONE]" { break }
                        guard let j = JSON.parse(ev.data) else { continue }
                        if let err = j["error"], !err.isNull {
                            throw HTTPError(status: 500, body: ev.data)
                        }
                        if let u = j["usage"], !u.isNull { usage = Self.usage(u) }
                        guard let choice = j["choices"]?[0] else { continue }
                        let d = choice["delta"] ?? choice["message"]
                        if let r = d?["reasoning_content"]?.string ?? d?["reasoning"]?.string, !r.isEmpty {
                            continuation.yield(.thinking(r))
                        }
                        switch d?["content"] {
                        case .string(let s): splitter.feed(s).forEach { continuation.yield($0) }
                        case .array(let parts): // Mistral-style typed chunks
                            for p in parts {
                                if p["type"]?.string == "thinking" {
                                    let t = p["thinking"]?.array?.compactMap { $0["text"]?.string }.joined() ?? p["thinking"]?.string ?? ""
                                    if !t.isEmpty { continuation.yield(.thinking(t)) }
                                } else if let t = p["text"]?.string { splitter.feed(t).forEach { continuation.yield($0) } }
                            }
                        default: break
                        }
                        for tc in d?["tool_calls"]?.array ?? [] {
                            let newID = tc["id"]?.string.flatMap { $0.isEmpty ? nil : $0 }
                            var idx: Int
                            if let i = tc["index"]?.int {
                                idx = i
                                // Some servers reuse index 0 for every call: a different id at a busy index is a new call.
                                if let cur = calls[idx], let nid = newID, nid != cur.id, !cur.args.isEmpty {
                                    idx = 10_000 + order.count
                                }
                            } else if let nid = newID {
                                // No index: a new id starts a call; a known id continues its call.
                                idx = order.first { calls[$0]?.id == nid } ?? (10_000 + order.count)
                            } else {
                                idx = order.last ?? 0   // a bare argument chunk continues the current call
                            }
                            if calls[idx] == nil {
                                let id = tc["id"]?.string.flatMap { $0.isEmpty ? nil : $0 } ?? "call_\(UUID().uuidString.prefix(12))"
                                let name = tc["function"]?["name"]?.string ?? ""
                                calls[idx] = PartialToolCall(id: id, name: name)
                                order.append(idx)
                                if !name.isEmpty { continuation.yield(.toolCallStarted(id: id, name: name)) }
                            } else if let n = tc["function"]?["name"]?.string, !n.isEmpty, calls[idx]!.name.isEmpty {
                                calls[idx]!.name = n
                                continuation.yield(.toolCallStarted(id: calls[idx]!.id, name: n))
                            }
                            if let a = tc["function"]?["arguments"]?.string, !a.isEmpty {
                                // Arguments re-sent whole after streaming them: replace, don't double them.
                                if a.hasPrefix("{"), !calls[idx]!.args.isEmpty, JSON.parse(calls[idx]!.args) != nil, JSON.parse(a) != nil {
                                    calls[idx]!.args = a
                                } else {
                                    calls[idx]!.args += a
                                }
                                continuation.yield(.toolCallArgs(id: calls[idx]!.id, partial: a))
                            } else if let obj = tc["function"]?["arguments"], obj.object != nil {
                                calls[idx]!.args = obj.compact
                            }
                            if let sig = tc["extra_content"]?["google"]?["thought_signature"]?.string { calls[idx]!.signature = sig }
                        }
                        if let f = choice["finish_reason"]?.string { finish = f }
                    }
                    splitter.flush().forEach { continuation.yield($0) }
                    for idx in order { if let c = calls[idx], !c.name.isEmpty { continuation.yield(.toolCall(c.finish())) } }
                    if let usage { continuation.yield(.usage(usage)) }
                    continuation.yield(.stop(Self.normalize(finish, hasTools: !order.isEmpty)))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func normalize(_ finish: String?, hasTools: Bool) -> String {
        switch finish {
        case "tool_calls", "function_call": return "tool_use"
        case "length": return "max_tokens"
        case nil: return hasTools ? "tool_use" : "end_turn"
        default: return hasTools ? "tool_use" : "end_turn"
        }
    }

    /// Normalised so `input` excludes cached tokens (matching Anthropic's accounting).
    static func usage(_ u: JSON) -> Usage {
        let cached = u["prompt_tokens_details"]?["cached_tokens"]?.int ?? u["prompt_cache_hit_tokens"]?.int ?? 0
        return Usage(input: max(0, (u["prompt_tokens"]?.int ?? 0) - cached), output: u["completion_tokens"]?.int ?? 0,
                     cacheRead: cached, cacheWrite: 0,
                     reasoningTokens: u["completion_tokens_details"]?["reasoning_tokens"]?.int ?? u["reasoning_tokens"]?.int)
    }

    private static func emitNonStreaming(_ body: String, _ c: AsyncThrowingStream<StreamEvent, Error>.Continuation) {
        guard let j = JSON.parse(body), let m = j["choices"]?[0]?["message"] else { return }
        if let r = m["reasoning_content"]?.string ?? m["reasoning"]?.string { c.yield(.thinking(r)) }
        var splitter = ThinkTagSplitter()
        if let t = m["content"]?.string { splitter.feed(t).forEach { c.yield($0) } }
        splitter.flush().forEach { c.yield($0) }
        for tc in m["tool_calls"]?.array ?? [] {
            var p = PartialToolCall(id: tc["id"]?.string ?? UUID().uuidString, name: tc["function"]?["name"]?.string ?? "")
            p.args = tc["function"]?["arguments"]?.string ?? "{}"
            c.yield(.toolCall(p.finish()))
        }
        if let u = j["usage"] { c.yield(.usage(usage(u))) }
        c.yield(.stop(normalize(j["choices"]?[0]?["finish_reason"]?.string, hasTools: !(m["tool_calls"]?.array?.isEmpty ?? true))))
    }

    // MARK: Request

    func buildBody(_ r: LLMRequest) -> JSON {
        let q = Set(config.quirks)
        var body: [String: JSON] = [
            "model": .string(config.currentModel(r.model)),
            "stream": true,
            "messages": .array(convert(r)),
        ]
        body[q.contains(.maxCompletionTokens) ? "max_completion_tokens" : "max_tokens"] = .number(Double(r.maxTokens))
        if !q.contains(.noStreamOptions) { body["stream_options"] = ["include_usage": true] }
        if !r.tools.isEmpty {
            body["tools"] = .array(r.tools.map { t in
                ["type": "function", "function": ["name": .string(t.name), "description": .string(t.description), "parameters": t.schema]]
            })
        }
        // OpenRouter enables reasoning by default on many models, so "off" must be explicit (saves thousands of tokens).
        if r.thinking == .off, q.contains(.openrouterReasoning) {
            body["reasoning"] = Self.reasoningIsMandatory(r.model) ? ["effort": "low", "exclude": false] : ["enabled": false]
        }
        // Open-weight models on vLLM-style hosts think unless the chat template is told not to. The key differs by family
        // and some templates fail on a key they don't know (NIM answers 500), so only a known family gets one.
        if r.thinking == .off, q.contains(.chatTemplateThinking), let key = Self.templateThinkingKey(r.model) {
            body["chat_template_kwargs"] = .object([key: false])
        }
        // DeepSeek thinks unless told not to (default effort high); it maps medium/xhigh to its own low/high/max.
        if q.contains(.deepseekThinking) { body["thinking"] = ["type": r.thinking == .off ? "disabled" : "enabled"] }
        if r.thinking != .off {
            if q.contains(.reasoningEffort) || q.contains(.deepseekThinking) { body["reasoning_effort"] = .string(r.thinking.rawValue) }
            if q.contains(.openrouterReasoning) { body["reasoning"] = ["effort": .string(r.thinking.rawValue)] }
        } else if let t = r.temperature {
            body["temperature"] = .number(t)
        }
        return .object(body)
    }

    static func templateThinkingKey(_ model: String) -> String? {
        let m = model.lowercased()
        if m.contains("deepseek") || m.contains("kimi") { return "thinking" }
        if m.contains("qwen") || m.contains("nemotron") || m.contains("glm") { return "enable_thinking" }
        return nil
    }

    func convert(_ r: LLMRequest) -> [JSON] {
        let replayReasoning = config.quirks.contains(.reasoningContentBack)
        var out: [JSON] = []
        if !r.system.isEmpty { out.append(["role": "system", "content": .string(r.system)]) }
        for m in r.messages {
            switch m.role {
            case .user:
                var parts: [JSON] = []
                var pendingImages: [JSON] = []
                for b in m.blocks {
                    switch b.kind {
                    case .toolResult:
                        out.append(["role": "tool", "tool_call_id": .string(b.id ?? ""),
                                    "content": .string((b.text?.isEmpty ?? true) ? "(no output)" : b.text!)])
                        if let d = b.payload, let mime = b.mime {
                            pendingImages.append(["type": "image_url", "image_url": ["url": .string("data:\(mime);base64,\(d)")]])
                        }
                    case .text: if let t = b.text, !t.isEmpty { parts.append(["type": "text", "text": .string(t)]) }
                    case .file: parts.append(["type": "text", "text": .string("<file name=\"\(b.name ?? "file")\">\n\(b.text ?? "")\n</file>")])
                    case .image: parts.append(["type": "image_url", "image_url": ["url": .string("data:\(b.mime ?? "image/png");base64,\(b.payload ?? "")")]])
                    default: break
                    }
                }
                if !pendingImages.isEmpty {
                    out.append(["role": "user", "content": .array([["type": "text", "text": "(images returned by the tool above)"]] + pendingImages)])
                }
                if parts.isEmpty { continue }
                if parts.count == 1, let t = parts[0]["text"]?.string, parts[0]["type"]?.string == "text" {
                    out.append(["role": "user", "content": .string(t)])
                } else {
                    out.append(["role": "user", "content": .array(parts)])
                }
            case .assistant:
                let text = m.blocks.filter { $0.kind == .text }.compactMap(\.text).joined()
                let thinking = m.blocks.filter { $0.kind == .thinking }.compactMap(\.text).joined()
                let calls = m.toolUses
                var o: [String: JSON] = ["role": "assistant"]
                o["content"] = text.isEmpty ? (calls.isEmpty ? "" : .null) : .string(text)
                if !calls.isEmpty {
                    o["tool_calls"] = .array(calls.map { c in
                        var call: [String: JSON] = ["id": .string(c.id ?? ""), "type": "function",
                                                    "function": ["name": .string(c.name ?? ""), "arguments": .string((c.input ?? .object([:])).compact)]]
                        if let sig = c.signature { call["extra_content"] = ["google": ["thought_signature": .string(sig)]] }
                        return .object(call)
                    })
                }
                // With tools, DeepSeek V4 needs every earlier turn's reasoning back (400 otherwise), not only tool-call turns.
                if replayReasoning, !thinking.isEmpty { o["reasoning_content"] = .string(thinking) }
                if text.isEmpty && calls.isEmpty { continue }
                out.append(.object(o))
            }
        }
        return out
    }
}
