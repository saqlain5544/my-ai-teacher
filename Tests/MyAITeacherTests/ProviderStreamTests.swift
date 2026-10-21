import XCTest
import Network
@testable import MyAITeacher

/// Replays provider-format SSE streams from a local HTTP server so every adapter is exercised
/// end to end (request → stream parsing → events) without spending real API keys.
final class MockSSEServer: @unchecked Sendable {
    let listener: NWListener
    var port: UInt16 { listener.port!.rawValue }
    var lastRequestBody = ""
    init(body: String, contentType: String = "text/event-stream") throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .global())
            var buf = Data()
            func respond() {
                let head = "HTTP/1.1 200 OK\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
                conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in conn.cancel() })
            }
            func read() {
                conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { data, _, done, _ in
                    if let data { buf.append(data) }
                    let req = String(decoding: buf, as: UTF8.self)
                    if let r = req.range(of: "\r\n\r\n") {
                        let headers = req[..<r.lowerBound].lowercased()
                        let len = headers.components(separatedBy: "\r\n").first { $0.hasPrefix("content-length:") }
                            .flatMap { Int($0.dropFirst(15).trimmingCharacters(in: .whitespaces)) } ?? 0
                        let bodyData = buf[buf.index(buf.startIndex, offsetBy: req[..<r.upperBound].utf8.count)...]
                        if bodyData.count >= len || done {
                            self?.lastRequestBody = String(decoding: bodyData, as: UTF8.self); respond(); return
                        }
                    }
                    if done { respond() } else { read() }
                }
            }
            read()
        }
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { if case .ready = $0 { ready.signal() } }
        listener.start(queue: .global())
        _ = ready.wait(timeout: .now() + 5)
    }
    deinit { listener.cancel() }
}

final class ProviderStreamTests: XCTestCase {
    func collect(_ client: LLMClient, tools: Bool = true) async throws -> (text: String, thinking: String, calls: [Block], usage: Usage?, stop: String?) {
        var text = "", thinking = "", calls: [Block] = [], usage: Usage?, stop: String?
        let req = LLMRequest(model: "m", system: "sys", messages: [ChatMessage(role: .user, blocks: [.text("hi")])],
                             tools: tools ? [ToolSpec(name: "math", description: "d", schema: Schema.object(["expression": Schema.string("e")]))] : [],
                             thinking: .low)
        for try await ev in client.stream(req) {
            switch ev {
            case .text(let t): text += t
            case .thinking(let t): thinking += t
            case .toolCall(let b): calls.append(b)
            case .usage(let u): usage = u
            case .stop(let s): stop = s
            default: break
            }
        }
        return (text, thinking, calls, usage, stop)
    }

    func testOpenAIStreamWithToolCallsReasoningAndUsage() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{"role":"assistant","reasoning_content":"Let me compute."}}]}

        data: {"choices":[{"index":0,"delta":{"content":"Checking"}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"call_1","type":"function","function":{"name":"math","arguments":"{\\"expr"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"ession\\": \\"17*23\\"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: {"choices":[],"usage":{"prompt_tokens":120,"completion_tokens":30,"prompt_tokens_details":{"cached_tokens":100},"completion_tokens_details":{"reasoning_tokens":12}}}

        data: [DONE]


        """
        let server = try MockSSEServer(body: sse)
        let p = ProviderConfig(id: "openai", name: "OpenAI", api: .openai, baseURL: "http://127.0.0.1:\(server.port)/v1", envKeys: [], defaultModel: "m",
                               quirks: [.maxCompletionTokens, .reasoningEffort])
        let r = try await collect(p.client(apiKey: "k"))
        XCTAssertEqual(r.thinking, "Let me compute.")
        XCTAssertEqual(r.text, "Checking")
        XCTAssertEqual(r.calls.first?.name, "math")
        XCTAssertEqual(r.calls.first?.input?["expression"]?.string, "17*23")
        XCTAssertEqual(r.usage, Usage(input: 20, output: 30, cacheRead: 100, cacheWrite: 0, reasoningTokens: 12))
        XCTAssertEqual(r.stop, "tool_use")
        let sent = JSON.parse(server.lastRequestBody)
        XCTAssertNotNil(sent?["max_completion_tokens"])
        XCTAssertEqual(sent?["reasoning_effort"]?.string, "low")
        XCTAssertEqual(sent?["tools"]?[0]?["function"]?["name"]?.string, "math")
    }

    func testGeminiStreamWithThoughtsSignatureAndFunctionCall() async throws {
        let sse = """
        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Thinking about it","thought":true}]}}]}

        data: {"candidates":[{"content":{"role":"model","parts":[{"text":"Here you go. "}]}}]}

        data: {"candidates":[{"content":{"role":"model","parts":[{"functionCall":{"name":"math","args":{"expression":"2+2"}},"thoughtSignature":"SIG123"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":50,"candidatesTokenCount":10,"thoughtsTokenCount":5,"cachedContentTokenCount":20}}


        """
        let server = try MockSSEServer(body: sse)
        let p = ProviderConfig(id: "google", name: "Gemini", api: .gemini, baseURL: "http://127.0.0.1:\(server.port)/v1beta", envKeys: [], defaultModel: "gemini-3-pro")
        let r = try await collect(p.client(apiKey: "k"))
        XCTAssertEqual(r.thinking, "Thinking about it")
        XCTAssertEqual(r.text, "Here you go. ")
        XCTAssertEqual(r.calls.first?.name, "math")
        XCTAssertEqual(r.calls.first?.signature, "SIG123")
        XCTAssertEqual(r.usage?.input, 30)
        XCTAssertEqual(r.usage?.cacheRead, 20)
        XCTAssertEqual(r.usage?.reasoningTokens, 5)
        XCTAssertEqual(r.stop, "tool_use")
        let sent = JSON.parse(server.lastRequestBody)
        XCTAssertEqual(sent?["systemInstruction"]?["parts"]?[0]?["text"]?.string, "sys")
        XCTAssertEqual(sent?["tools"]?[0]?["functionDeclarations"]?[0]?["name"]?.string, "math")
        XCTAssertEqual(sent?["generationConfig"]?["thinkingConfig"]?["includeThoughts"]?.bool, true)
    }

    func testGeminiReplaysSignatureOnFunctionCall() {
        let c = GeminiClient(config: ProviderConfig(id: "g", name: "g", api: .gemini, baseURL: "x", envKeys: [], defaultModel: "gemini-3-pro"), apiKey: nil)
        let msgs = [ChatMessage(role: .user, blocks: [.text("q")]),
                    ChatMessage(role: .assistant, blocks: [.toolUse(id: "1", name: "math", input: ["e": "1"], signature: "SIG")], model: "gemini-3-pro"),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "1", name: "math", content: "2")])]
        let out = c.convert(msgs, model: "gemini-3-pro")
        XCTAssertEqual(out[1]["parts"]?[0]?["thoughtSignature"]?.string, "SIG")
        XCTAssertEqual(out[2]["parts"]?[0]?["functionResponse"]?["name"]?.string, "math")
    }

    func testAnthropicStreamThinkingSignatureToolUse() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"cache_read_input_tokens":90,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"thinking","thinking":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"thinking_delta","thinking":"hmm"}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"signature_delta","signature":"abc"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":0}

        event: content_block_start
        data: {"type":"content_block_start","index":1,"content_block":{"type":"tool_use","id":"tu1","name":"math","input":{}}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":1,"delta":{"type":"input_json_delta","partial_json":"{\\"expression\\":\\"1+1\\"}"}}

        event: content_block_stop
        data: {"type":"content_block_stop","index":1}

        event: message_delta
        data: {"type":"message_delta","delta":{"stop_reason":"tool_use"},"usage":{"output_tokens":42}}


        """
        let server = try MockSSEServer(body: sse)
        let p = ProviderConfig(id: "anthropic", name: "A", api: .anthropic, baseURL: "http://127.0.0.1:\(server.port)/v1", envKeys: [], defaultModel: "claude-opus-5-5")
        var signature: String?
        var calls: [Block] = []
        let req = LLMRequest(model: "claude-opus-5-5", system: "s", messages: [ChatMessage(role: .user, blocks: [.text("hi")])], thinking: .medium)
        for try await ev in p.client(apiKey: "k").stream(req) {
            if case .thinkingSignature(let s) = ev { signature = s }
            if case .toolCall(let b) = ev { calls.append(b) }
        }
        XCTAssertEqual(signature, "abc")
        XCTAssertEqual(calls.first?.input?["expression"]?.string, "1+1")
        let sent = JSON.parse(server.lastRequestBody)
        XCTAssertEqual(sent?["thinking"]?["type"]?.string, "adaptive")
        XCTAssertEqual(sent?["output_config"]?["effort"]?.string, "medium")
        XCTAssertNil(sent?["temperature"])
    }

    // MARK: Text-embedded tool calls (StreamGuard)

    private let schemas: [String: JSON] = [
        "get_weather": ["type": "object", "properties": ["location": ["type": "string"], "days": ["type": "integer"], "units": ["type": "array"]]],
        "ls": ["type": "object", "properties": ["path": ["type": "string"]]],
    ]

    /// Runs `text` through the parser whole and one character at a time; both must agree.
    private func parse(_ text: String) -> (text: String, thinking: String, calls: [Block], retro: Bool) {
        func run(_ chunks: [String]) -> (String, String, [Block], Bool) {
            var p = TextProtocolParser(tools: schemas)
            var t = "", th = "", calls: [Block] = [], retro = false
            for out in chunks.flatMap({ p.feed($0) }) + p.flush() {
                switch out {
                case .text(let s): t += s
                case .thinking(let s): th += s
                case .call(let b): calls.append(b)
                case .textWasThinking: retro = true
                }
            }
            return (t, th, calls, retro)
        }
        let whole = run([text]), split = run(text.map { String($0) })
        XCTAssertEqual(whole.0, split.0, "text differs when split: \(text.prefix(60))")
        XCTAssertEqual(whole.2.map(\.name), split.2.map(\.name))
        XCTAssertEqual(whole.2.map { $0.input?.compact }, split.2.map { $0.input?.compact })
        return whole
    }

    func testEmbeddedToolCallFormats() {
        let cases: [(String, String)] = [
            ("DSML", "Checking.\n\n<｜DSML｜tool_calls>\n<｜DSML｜invoke name=\"get_weather\">\n<｜DSML｜parameter name=\"location\" string=\"true\">Hangzhou</｜DSML｜parameter>\n<｜DSML｜parameter name=\"days\" string=\"false\">3</｜DSML｜parameter>\n</｜DSML｜invoke>\n</｜DSML｜tool_calls>"),
            ("DeepSeek V3", "<｜tool▁calls▁begin｜><｜tool▁call▁begin｜>function<｜tool▁sep｜>get_weather\n```json\n{\"location\":\"Hangzhou\",\"days\":3}\n```<｜tool▁call▁end｜><｜tool▁calls▁end｜>"),
            ("DeepSeek V3.1", "<｜tool▁call▁begin｜>get_weather<｜tool▁sep｜>{\"location\":\"Hangzhou\",\"days\":3}<｜tool▁call▁end｜>"),
            ("Hermes/Qwen", "Sure.\n<tool_call>\n{\"name\": \"get_weather\", \"arguments\": {\"location\": \"Hangzhou\", \"days\": 3}}\n</tool_call>"),
            ("Qwen3-Coder", "<tool_call>\n<function=get_weather>\n<parameter=location>\nHangzhou\n</parameter>\n<parameter=days>\n3\n</parameter>\n</function>\n</tool_call>"),
            ("GLM", "<tool_call>get_weather\n<arg_key>location</arg_key>\n<arg_value>Hangzhou</arg_value>\n<arg_key>days</arg_key>\n<arg_value>3</arg_value>\n</tool_call>"),
            ("MiniMax M2", "<minimax:tool_call>\n<invoke name=\"get_weather\">\n<parameter name=\"location\">Hangzhou</parameter>\n<parameter name=\"days\">3</parameter>\n</invoke>\n</minimax:tool_call>"),
            ("MiniMax M3", "]<]minimax[>[<tool_call>]<]minimax[>[<invoke name=\"get_weather\">]<]minimax[>[<location>Hangzhou]<]minimax[>[</location>]<]minimax[>[<days>3]<]minimax[>[</days>]<]minimax[>[</invoke>]<]minimax[>[</tool_call>"),
            ("Kimi", "<|tool_calls_section_begin|><|tool_call_begin|>functions.get_weather:0<|tool_call_argument_begin|>{\"location\":\"Hangzhou\",\"days\":3}<|tool_call_end|><|tool_calls_section_end|>"),
            ("Mistral v11", "[TOOL_CALLS]get_weather[ARGS]{\"location\":\"Hangzhou\",\"days\":3}"),
            ("Mistral old", "[TOOL_CALLS][{\"name\":\"get_weather\",\"arguments\":{\"location\":\"Hangzhou\",\"days\":3}}]"),
            ("Llama", "<|python_tag|>{\"name\": \"get_weather\", \"parameters\": {\"location\": \"Hangzhou\", \"days\": 3}}<|eom_id|>"),
            ("Nemotron", "<TOOLCALL>[{\"name\": \"get_weather\", \"arguments\": {\"location\": \"Hangzhou\", \"days\": 3}}]</TOOLCALL>"),
            ("Harmony", "<|channel|>analysis<|message|>Need weather.<|end|><|start|>assistant<|channel|>commentary to=functions.get_weather <|constrain|>json<|message|>{\"location\":\"Hangzhou\",\"days\":3}<|call|>"),
            ("Gemma 4", "<|tool_call>call:get_weather{location:<|\"|>Hangzhou<|\"|>,days:3}<tool_call|>"),
        ]
        for (name, text) in cases {
            let r = parse(text)
            XCTAssertEqual(r.calls.count, 1, "\(name): \(r.text)")
            XCTAssertEqual(r.calls.first?.name, "get_weather", name)
            XCTAssertEqual(r.calls.first?.input?["location"]?.string, "Hangzhou", name)
            XCTAssertEqual(r.calls.first?.input?["days"]?.double, 3, "\(name): days typed as a number")
            XCTAssertFalse(r.text.contains("<") || r.text.contains("[TOOL"), "\(name) leaked markers: \(r.text)")
        }
    }

    func testReasoningTagsAndProse() {
        var r = parse("The user wants x. Let me answer.\n</think>\n\nThe answer is 4.")
        XCTAssertTrue(r.retro, "bare </think>: earlier text was reasoning")
        XCTAssertTrue(r.text.hasSuffix("The answer is 4."))
        r = parse("<mm:think>plan it</mm:think>Hello")
        XCTAssertEqual(r.thinking, "plan it"); XCTAssertEqual(r.text, "Hello")
        r = parse("In HTML you might write <think> as a custom tag.")
        XCTAssertEqual(r.text, "In HTML you might write <think> as a custom tag.", "mid-answer <think> is literal")
        r = parse("Use `<tool_call>` tags in your prompt template.")
        XCTAssertTrue(r.calls.isEmpty && r.text.contains("<tool_call>"), "inline mention is not a call")
        r = parse("Done.<|eot_id|>")
        XCTAssertEqual(r.text, "Done.")
        r = parse("Here.\n\n<｜DSML｜ calls>\n")   // NIM's garbled leftover: dropped, nothing else lost
        XCTAssertEqual(r.text, "Here.\n\n"); XCTAssertTrue(r.calls.isEmpty)
        r = parse("x < 5 and y > 2, a <｜b")
        XCTAssertTrue(r.text.hasPrefix("x < 5 and y > 2"))
    }

    func testArgumentsAreCoercedToTheSchema() {
        let schema: JSON = ["type": "object", "properties": ["questions": ["type": "array"], "n": ["type": "integer"], "graded": ["type": "boolean"], "title": ["type": "string"]]]
        let fixed = ToolArgs.coerce(["questions": "[{\"type\":\"short_text\",\"prompt\":\"x\"}]]", "n": "3", "graded": "true", "title": "42"], schema: schema)
        XCTAssertEqual(fixed["questions"]?.array?.count, 1, "stringified array (with a stray ]) parsed")
        XCTAssertEqual(fixed["n"]?.double, 3); XCTAssertEqual(fixed["graded"]?.bool, true); XCTAssertEqual(fixed["title"]?.string, "42")
    }

    func testGuardDedupesAndSetsToolUseStop() async throws {
        struct Fake: LLMClient {
            func stream(_ r: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
                AsyncThrowingStream { c in
                    c.yield(.text("<tool_call>\n{\"name\":\"ls\",\"arguments\":{\"path\":\".\"}}\n</tool_call>"))
                    c.yield(.toolCall(.toolUse(id: "a", name: "ls", input: ["path": "."])))
                    c.yield(.stop("end_turn")); c.finish()
                }
            }
        }
        var calls = 0, stop = ""
        for try await ev in GuardedClient(inner: Fake()).stream(LLMRequest(model: "m", system: "", messages: [], tools: [ToolSpec(name: "ls", description: "", schema: schemas["ls"]!)])) {
            if case .toolCall = ev { calls += 1 }
            if case .stop(let r) = ev { stop = r }
        }
        XCTAssertEqual(calls, 1, "the same call twice is one call"); XCTAssertEqual(stop, "tool_use")
    }
}
