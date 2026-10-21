import Foundation

/// Anthropic Messages API (also used by Anthropic-compatible endpoints: MiniMax, DeepSeek, Kimi, Z.ai…).
struct AnthropicClient: LLMClient {
    let config: ProviderConfig
    let apiKey: String?

    private var isFirstParty: Bool { config.baseURL.contains("api.anthropic.com") }

    /// Claude 4.6+ / 5.x use adaptive thinking + effort; budget_tokens and sampling params are rejected.
    static func isAdaptiveClaude(_ model: String) -> Bool {
        let m = model.lowercased()
        guard m.hasPrefix("claude-") || m.contains("/claude-") || m.hasPrefix("anthropic.claude") else { return false }
        if m.contains("fable") || m.contains("mythos") { return true }
        for tag in ["-4-6", "-4-7", "-4-8", "-4.6", "-4.7", "-4.8", "-5"] where m.contains(tag) { return true }
        return false
    }

    /// Models on compatible hosts that reject `thinking: disabled` (learned at runtime).
    nonisolated(unsafe) private static var adaptiveOnlyModels = Set<String>()
    private static let lock = NSLock()
    static func adaptiveOnly(_ model: String) -> Bool { lock.withLock { adaptiveOnlyModels.contains(model) } }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        guard request.thinking == .off, !isFirstParty, !Self.adaptiveOnly(request.model) else { return streamOnce(request) }
        // One retry if the host says thinking can't be disabled for this model; nothing has been yielded then.
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await ev in streamOnce(request) { continuation.yield(ev) }
                    continuation.finish()
                } catch let e as HTTPError where e.status == 400 && e.body.localizedCaseInsensitiveContains("adaptive") {
                    _ = Self.lock.withLock { Self.adaptiveOnlyModels.insert(request.model) }
                    do { for try await ev in streamOnce(request) { continuation.yield(ev) }; continuation.finish() }
                    catch { continuation.finish(throwing: error) }
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private func streamOnce(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let body = buildBody(request)
        var headers = config.headers
        headers["anthropic-version"] = "2023-06-01"
        if let apiKey {
            headers["x-api-key"] = apiKey
            if !isFirstParty { headers["Authorization"] = "Bearer \(apiKey)" }
        }
        if isFirstParty, Self.supportsFallback(request.model) {
            headers["anthropic-beta"] = "server-side-fallback-2026-07-01"
        }
        let req = URLRequest.json(config.baseURL.joinedURL("/messages"), body: body, headers: headers)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var tools: [Int: PartialToolCall] = [:]
                var thinkingSig: [Int: String] = [:]
                var usage = Usage()
                do {
                    for try await ev in SSEClient.stream(req) {
                        if SSEClient.trace { FileHandle.standardError.write(Data(("SSE " + ev.data + "\n").utf8)) }
                        if ev.event == "__json__" {
                            try Self.emitNonStreaming(ev.data, continuation); continue
                        }
                        guard let j = JSON.parse(ev.data), let type = j["type"]?.string else { continue }
                        switch type {
                        case "message_start":
                            if let u = j["message"]?["usage"] { usage = Self.usage(u, base: usage) }
                        case "content_block_start":
                            let idx = j["index"]?.int ?? 0
                            let cb = j["content_block"]
                            switch cb?["type"]?.string {
                            case "tool_use", "server_tool_use":
                                let id = cb?["id"]?.string ?? UUID().uuidString
                                let name = cb?["name"]?.string ?? "tool"
                                tools[idx] = PartialToolCall(id: id, name: name)
                                continuation.yield(.toolCallStarted(id: id, name: name))
                            case "thinking":
                                if let t = cb?["thinking"]?.string, !t.isEmpty { continuation.yield(.thinking(t)) }
                            case "redacted_thinking":
                                // Keep encrypted reasoning so it can be replayed unchanged.
                                continuation.yield(.thinkingSignature("redacted:" + (cb?["data"]?.string ?? "")))
                            case "text":
                                if let t = cb?["text"]?.string, !t.isEmpty { continuation.yield(.text(t)) }
                            default: break
                            }
                        case "content_block_delta":
                            let idx = j["index"]?.int ?? 0
                            let d = j["delta"]
                            switch d?["type"]?.string {
                            case "text_delta": if let t = d?["text"]?.string { continuation.yield(.text(t)) }
                            case "thinking_delta": if let t = d?["thinking"]?.string { continuation.yield(.thinking(t)) }
                            case "signature_delta": if let s = d?["signature"]?.string { thinkingSig[idx, default: ""] += s }
                            case "input_json_delta":
                                if let p = d?["partial_json"]?.string {
                                    tools[idx]?.args += p
                                    if let t = tools[idx] { continuation.yield(.toolCallArgs(id: t.id, partial: p)) }
                                }
                            default: break
                            }
                        case "content_block_stop":
                            let idx = j["index"]?.int ?? 0
                            if let sig = thinkingSig.removeValue(forKey: idx) { continuation.yield(.thinkingSignature(sig)) }
                            if let t = tools.removeValue(forKey: idx) { continuation.yield(.toolCall(t.finish())) }
                        case "message_delta":
                            if let u = j["usage"] { usage = Self.usage(u, base: usage) }
                            if let r = j["delta"]?["stop_reason"]?.string {
                                continuation.yield(.usage(usage))
                                if r == "refusal" {
                                    let why = j["delta"]?["stop_details"]?["explanation"]?.string ?? "The model declined this request."
                                    continuation.yield(.text("\n\n> ⚠️ \(why)"))
                                }
                                continuation.yield(.stop(r))
                            }
                        case "error":
                            let msg = j["error"]?["message"]?.string ?? ev.data
                            throw HTTPError(status: 500, body: "{\"error\":{\"message\":\(JSON.string(msg).compact)}}")
                        default: break
                        }
                    }
                    for (_, t) in tools { continuation.yield(.toolCall(t.finish())) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func supportsFallback(_ model: String) -> Bool {
        ["claude-fable-5-1", "claude-opus-5-5", "claude-opus-5", "claude-sonnet-5-5"].contains(model)
    }

    private static func usage(_ u: JSON, base: Usage) -> Usage {
        var r = base
        if let v = u["input_tokens"]?.int { r.input = v }
        if let v = u["output_tokens"]?.int { r.output = v }
        if let v = u["cache_read_input_tokens"]?.int { r.cacheRead = v }
        if let v = u["cache_creation_input_tokens"]?.int { r.cacheWrite = v }
        if let v = u["output_tokens_details"]?["thinking_tokens"]?.int ?? u["output_tokens_details"]?["reasoning_tokens"]?.int { r.reasoningTokens = v }
        return r
    }

    private static func emitNonStreaming(_ body: String, _ c: AsyncThrowingStream<StreamEvent, Error>.Continuation) throws {
        guard let j = JSON.parse(body) else { return }
        for b in j["content"]?.array ?? [] {
            switch b["type"]?.string {
            case "text": c.yield(.text(b["text"]?.string ?? ""))
            case "thinking":
                c.yield(.thinking(b["thinking"]?.string ?? ""))
                if let s = b["signature"]?.string { c.yield(.thinkingSignature(s)) }
            case "tool_use":
                c.yield(.toolCall(.toolUse(id: b["id"]?.string ?? UUID().uuidString, name: b["name"]?.string ?? "",
                                           input: b["input"] ?? .object([:]))))
            default: break
            }
        }
        if let u = j["usage"] { c.yield(.usage(usage(u, base: Usage()))) }
        c.yield(.stop(j["stop_reason"]?.string ?? "end_turn"))
    }

    // MARK: Request

    func buildBody(_ r: LLMRequest) -> JSON {
        let adaptive = Self.isAdaptiveClaude(r.model)
        var body: [String: JSON] = [
            "model": .string(r.model),
            "max_tokens": .number(Double(r.maxTokens)),
            "stream": true,
        ]
        if !r.system.isEmpty {
            // Two cached blocks: the instructions shared by every lesson, then this lesson's context (date, memory, folder).
            // A change in the second (a new memory, a new day) keeps the first one's cache hit.
            let parts = SystemPrompt.split(r.system)
            body["system"] = .array(parts.map { ["type": "text", "text": .string($0), "cache_control": ["type": "ephemeral"]] })
        }
        if !r.tools.isEmpty {
            var tools: [JSON] = r.tools.map { t in
                var o: [String: JSON] = ["name": .string(t.name), "description": .string(t.description), "input_schema": t.schema]
                if isFirstParty { o["eager_input_streaming"] = true }
                return .object(o)
            }
            if case .object(var last) = tools[tools.count - 1] {
                last["cache_control"] = ["type": "ephemeral"]
                tools[tools.count - 1] = .object(last)
            }
            body["tools"] = .array(tools)
        }
        if adaptive {
            if r.thinking != .off {
                body["thinking"] = ["type": "adaptive", "display": "summarized"]
                body["output_config"] = ["effort": .string(r.thinking.rawValue)]
            } else {
                body["output_config"] = ["effort": "low"]
            }
            if isFirstParty, Self.supportsFallback(r.model) { body["fallbacks"] = "default" }
        } else {
            if r.thinking != .off {
                let budget = min(r.thinking.budget, max(1024, r.maxTokens - 1024))
                body["thinking"] = ["type": "enabled", "budget_tokens": .number(Double(budget))]
            } else if !isFirstParty {
                // Compatible hosts (MiniMax…) think by default: "off" must be explicit. Models that only allow adaptive
                // thinking (learned from their 400) get the lowest effort instead.
                if Self.adaptiveOnly(r.model) {
                    body["thinking"] = ["type": "adaptive"]
                    body["output_config"] = ["effort": "low"]
                } else {
                    body["thinking"] = ["type": "disabled"]
                }
                if let t = r.temperature { body["temperature"] = .number(t) }
            } else if let t = r.temperature {
                body["temperature"] = .number(t)
            }
        }
        body["messages"] = .array(Self.convert(r.messages, model: r.model))
        return .object(body)
    }

    static func convert(_ messages: [ChatMessage], model: String) -> [JSON] {
        var out: [(role: String, content: [JSON])] = []
        for m in messages {
            var content: [JSON] = []
            for b in m.blocks {
                switch b.kind {
                case .text:
                    if let t = b.text, !t.isEmpty { content.append(["type": "text", "text": .string(t)]) }
                case .thinking:
                    // Thinking blocks are only valid when replayed to the model that produced them.
                    guard m.role == .assistant, m.model == model, let sig = b.signature, !sig.isEmpty else { continue }
                    if sig.hasPrefix("redacted:") {
                        content.append(["type": "redacted_thinking", "data": .string(String(sig.dropFirst(9)))])
                    } else {
                        content.append(["type": "thinking", "thinking": .string(b.text ?? ""), "signature": .string(sig)])
                    }
                case .image:
                    content.append(["type": "image", "source": ["type": "base64", "media_type": .string(b.mime ?? "image/png"), "data": .string(b.payload ?? "")]])
                case .file:
                    content.append(["type": "text", "text": .string("<file name=\"\(b.name ?? "file")\">\n\(b.text ?? "")\n</file>")])
                case .toolUse:
                    content.append(["type": "tool_use", "id": .string(b.id ?? ""), "name": .string(b.name ?? ""), "input": b.input ?? .object([:])])
                case .toolResult:
                    var parts: [JSON] = [["type": "text", "text": .string((b.text?.isEmpty ?? true) ? "(no output)" : b.text!)]]
                    if let d = b.payload, let mime = b.mime {
                        parts.append(["type": "image", "source": ["type": "base64", "media_type": .string(mime), "data": .string(d)]])
                    }
                    var o: [String: JSON] = ["type": "tool_result", "tool_use_id": .string(b.id ?? ""), "content": .array(parts)]
                    if b.isError == true { o["is_error"] = true }
                    content.append(.object(o))
                }
            }
            if content.isEmpty { continue }
            let role = m.role.rawValue
            if let last = out.last, last.role == role {
                out[out.count - 1].content += content
            } else {
                out.append((role, content))
            }
        }
        // Anthropic requires the first message to be from the user.
        if out.first?.role == "assistant" { out.insert(("user", [["type": "text", "text": "(continue)"]]), at: 0) }
        // Cache breakpoint on the final block of the conversation so the next turn reuses the prefix.
        if var last = out.last, case .object(var lb) = last.content[last.content.count - 1] {
            lb["cache_control"] = ["type": "ephemeral"]
            last.content[last.content.count - 1] = .object(lb)
            out[out.count - 1] = last
        }
        return out.map { ["role": .string($0.role), "content": .array($0.content)] }
    }
}
