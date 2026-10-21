import Foundation

/// Google Gemini API (generativelanguage.googleapis.com) with native thought parts and signatures.
struct GeminiClient: LLMClient {
    let config: ProviderConfig
    let apiKey: String?

    private static func usesThinkingLevel(_ model: String) -> Bool {
        let m = model.lowercased()
        return !(m.contains("gemini-2") || m.contains("gemini-1") || m.contains("gemma"))
    }

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        var headers = config.headers
        if let apiKey { headers["x-goog-api-key"] = apiKey }
        let model = request.model.hasPrefix("models/") ? String(request.model.dropFirst(7)) : request.model
        let url = config.baseURL.joinedURL("/models/\(model):streamGenerateContent?alt=sse")
        let req = URLRequest.json(url, body: buildBody(request), headers: headers)
        return AsyncThrowingStream { continuation in
            let task = Task {
                var usage: Usage?
                var finish = "end_turn"
                var sawCall = false
                do {
                    for try await ev in SSEClient.stream(req) {
                        let payloads: [JSON]
                        if ev.event == "__json__" {
                            let j = JSON.parse(ev.data)
                            payloads = j?.array ?? (j.map { [$0] } ?? [])
                        } else {
                            guard let j = JSON.parse(ev.data) else { continue }
                            payloads = [j]
                        }
                        for j in payloads {
                            if let err = j["error"], !err.isNull { throw HTTPError(status: err["code"]?.int ?? 500, body: ev.data) }
                            if let u = j["usageMetadata"] {
                                let cached = u["cachedContentTokenCount"]?.int ?? 0
                                usage = Usage(input: max(0, (u["promptTokenCount"]?.int ?? 0) - cached),
                                              output: (u["candidatesTokenCount"]?.int ?? 0) + (u["thoughtsTokenCount"]?.int ?? 0),
                                              cacheRead: cached, reasoningTokens: u["thoughtsTokenCount"]?.int)
                            }
                            guard let cand = j["candidates"]?[0] else { continue }
                            for p in cand["content"]?["parts"]?.array ?? [] {
                                if let fc = p["functionCall"] {
                                    sawCall = true
                                    let id = fc["id"]?.string ?? "call_\(UUID().uuidString.prefix(12))"
                                    let name = fc["name"]?.string ?? ""
                                    continuation.yield(.toolCallStarted(id: id, name: name))
                                    continuation.yield(.toolCall(.toolUse(id: id, name: name, input: fc["args"] ?? .object([:]),
                                                                          signature: p["thoughtSignature"]?.string)))
                                } else if let t = p["text"]?.string {
                                    if p["thought"]?.bool == true {
                                        continuation.yield(.thinking(t))
                                        if let s = p["thoughtSignature"]?.string { continuation.yield(.thinkingSignature(s)) }
                                    } else if !t.isEmpty {
                                        continuation.yield(.text(t))
                                    }
                                }
                            }
                            if let f = cand["finishReason"]?.string {
                                switch f {
                                case "MAX_TOKENS": finish = "max_tokens"
                                case "SAFETY", "RECITATION", "PROHIBITED_CONTENT", "BLOCKLIST":
                                    continuation.yield(.text("\n\n> ⚠️ Response stopped by the provider (\(f.lowercased()))."))
                                default: break
                                }
                            }
                        }
                    }
                    if let usage { continuation.yield(.usage(usage)) }
                    continuation.yield(.stop(sawCall ? "tool_use" : finish))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func buildBody(_ r: LLMRequest) -> JSON {
        var body: [String: JSON] = ["contents": .array(convert(r.messages, model: r.model))]
        if !r.system.isEmpty { body["systemInstruction"] = ["parts": [["text": .string(r.system)]]] }
        if !r.tools.isEmpty {
            body["tools"] = [["functionDeclarations": .array(r.tools.map { t in
                ["name": .string(t.name), "description": .string(t.description), "parametersJsonSchema": t.schema]
            })]]
        }
        var gen: [String: JSON] = ["maxOutputTokens": .number(Double(r.maxTokens))]
        let level = Self.usesThinkingLevel(r.model)
        if r.thinking != .off {
            gen["thinkingConfig"] = level
                ? ["includeThoughts": true, "thinkingLevel": .string(r.thinking == .high ? "high" : (r.thinking == .medium ? "medium" : "low"))]
                : ["includeThoughts": true, "thinkingBudget": .number(Double(r.thinking.budget))]
        } else {
            if level { gen["thinkingConfig"] = ["thinkingLevel": "low"] }
            else if r.model.contains("flash") { gen["thinkingConfig"] = ["thinkingBudget": 0] }
            if let t = r.temperature { gen["temperature"] = .number(t) }
        }
        body["generationConfig"] = .object(gen)
        return .object(body)
    }

    func convert(_ messages: [ChatMessage], model: String) -> [JSON] {
        var out: [(role: String, parts: [JSON])] = []
        for m in messages {
            var parts: [JSON] = []
            for b in m.blocks {
                switch b.kind {
                case .text: if let t = b.text, !t.isEmpty { parts.append(["text": .string(t)]) }
                case .thinking:
                    if m.role == .assistant, m.model == model, let sig = b.signature, !sig.hasPrefix("redacted:") {
                        parts.append(["text": .string(b.text ?? ""), "thought": true, "thoughtSignature": .string(sig)])
                    }
                case .image: parts.append(["inlineData": ["mimeType": .string(b.mime ?? "image/png"), "data": .string(b.payload ?? "")]])
                case .file: parts.append(["text": .string("<file name=\"\(b.name ?? "file")\">\n\(b.text ?? "")\n</file>")])
                case .toolUse:
                    var p: [String: JSON] = ["functionCall": ["name": .string(b.name ?? ""), "args": b.input ?? .object([:])]]
                    if let s = b.signature, m.model == model { p["thoughtSignature"] = .string(s) }
                    else if Self.usesThinkingLevel(model) { p["thoughtSignature"] = "skip_thought_signature_validator" }
                    parts.append(.object(p))
                case .toolResult:
                    parts.append(["functionResponse": ["name": .string(b.name ?? ""),
                                                       "response": ["result": .string(b.text ?? ""), "is_error": .bool(b.isError ?? false)]]])
                    if let d = b.payload, let mime = b.mime { parts.append(["inlineData": ["mimeType": .string(mime), "data": .string(d)]]) }
                }
            }
            if parts.isEmpty { continue }
            let role = m.role == .assistant ? "model" : "user"
            if let last = out.last, last.role == role { out[out.count - 1].parts += parts }
            else { out.append((role, parts)) }
        }
        return out.map { ["role": .string($0.role), "parts": .array($0.parts)] }
    }
}
