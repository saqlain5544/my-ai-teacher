import XCTest
@testable import MyAITeacher

final class ContextTests: XCTestCase {
    private func turn(_ n: Int, bulk: Int = 5_000) -> [ChatMessage] {
        [ChatMessage(role: .user, blocks: [.text("question \(n)")]),
         ChatMessage(role: .assistant, blocks: [.thinking("reasoning \(n)"), .toolUse(id: "t\(n)", name: "read", input: ["path": "a"])]),
         ChatMessage(role: .user, blocks: [.toolResult(id: "t\(n)", name: "read", content: String(repeating: "x", count: bulk))]),
         ChatMessage(role: .assistant, blocks: [.text("answer \(n)")])]
    }

    func testTrimEpochKeepsRecentTurnsVerbatim() {
        let msgs = (0..<6).flatMap { turn($0) }
        var c = Conversation(providerID: "openrouter", model: "x")
        c.trimmedThrough = ContextPolicy.nextTrimPoint(msgs, current: nil)
        XCTAssertNotNil(c.trimmedThrough)
        let out = ContextPolicy.prepare(msgs, conversation: c, model: "x")
        XCTAssertEqual(out.count, msgs.count)
        // Turns 0–2 trimmed, 3–5 intact.
        XCTAssertLessThan(out[2].blocks[0].text!.count, 1_400)
        XCTAssertEqual(out[14].blocks[0].text!.count, 5_000)
        XCTAssertLessThan(ContextPolicy.estimateTokens(out), ContextPolicy.estimateTokens(msgs) * 7 / 10)
        // Same trim point → stable (cache-friendly) prefix.
        XCTAssertNil(ContextPolicy.nextTrimPoint(msgs, current: c.trimmedThrough))
    }

    func testOldThinkingDroppedExceptAdaptiveClaude() {
        let msgs = (0..<2).flatMap { turn($0) }
        let c = Conversation(providerID: "x", model: "x")
        let lean = ContextPolicy.prepare(msgs, conversation: c, model: "deepseek-chat")
        XCTAssertFalse(lean[1].blocks.contains { $0.kind == .thinking })
        XCTAssertTrue(lean[5].blocks.contains { $0.kind == .thinking })   // current turn keeps it
        let claude = ContextPolicy.prepare(msgs, conversation: c, model: "claude-opus-5-5")
        XCTAssertTrue(claude[1].blocks.contains { $0.kind == .thinking })
    }

    func testSummaryReplacesPrefix() {
        let msgs = (0..<3).flatMap { turn($0) }
        var c = Conversation(providerID: "x", model: "x")
        c.compactedThrough = msgs[3].id; c.compactSummary = "Covered: X."
        let out = ContextPolicy.prepare(msgs, conversation: c, model: "x")
        XCTAssertEqual(out.count, msgs.count - 4 + 1)
        XCTAssertTrue(out[0].plainText.contains("Covered: X."))
    }

    func testBudgetCapsAtHalfWindow() {
        XCTAssertEqual(ContextPolicy.budget(setting: 48_000, contextWindow: 32_768), 16_384)
        XCTAssertEqual(ContextPolicy.budget(setting: 48_000, contextWindow: 1_000_000), 48_000)
        XCTAssertEqual(ContextPolicy.budget(setting: 48_000, contextWindow: nil), 48_000)
    }

    func testModelInfoParsesProviderShapes() {
        let p = ProviderCatalog.presets[0]
        let or: JSON = ["id": "minimax/minimax-m3.1-flash:free", "context_length": 196_608,
                        "top_provider": ["max_completion_tokens": 32_000], "supported_parameters": ["tools", "reasoning"],
                        "architecture": ["input_modalities": ["text", "image"]], "pricing": ["prompt": "0", "completion": "0"]]
        let a = ModelInfo.parse(id: "minimax/minimax-m3.1-flash:free", or, provider: p)
        XCTAssertEqual(a.contextWindow, 196_608); XCTAssertEqual(a.maxOutput, 32_000)
        XCTAssertEqual(a.reasoning, true); XCTAssertEqual(a.tools, true); XCTAssertEqual(a.vision, true); XCTAssertEqual(a.free, true)
        let gem: JSON = ["name": "models/gemini-3-flash", "inputTokenLimit": 1_048_576, "outputTokenLimit": 65_536, "thinking": true]
        let g = ModelInfo.parse(id: "gemini-3-flash", gem, provider: p)
        XCTAssertEqual(g.contextWindow, 1_048_576); XCTAssertEqual(g.maxOutput, 65_536); XCTAssertEqual(g.reasoning, true)
        let groq: JSON = ["id": "llama", "context_window": 131_072, "max_completion_tokens": 8192, "supported_features": ["tools"]]
        let q = ModelInfo.parse(id: "llama", groq, provider: p)
        XCTAssertEqual(q.contextWindow, 131_072); XCTAssertEqual(q.reasoning, false)
        XCTAssertEqual(ChatSession.maxTokens(provider: p, model: "llama", info: q), 8192)
    }

    func testDeferredToolsLoadOnDemand() async throws {
        let s = AppSettings()
        let base = ToolRegistry.active(s, loaded: []).map(\.name)
        XCTAssertFalse(base.contains("grep")); XCTAssertTrue(base.contains("load_tools"))
        XCTAssertEqual(ToolRegistry.active(s, loaded: ["grep", "nope"]).map(\.name), base + ["grep"])
    }
}
