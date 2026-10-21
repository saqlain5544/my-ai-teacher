import XCTest
@testable import MyAITeacher

/// OpenCode Go: one key, several APIs (picked per model from models.dev), and a session header on every request.
final class OpenCodeGoTests: XCTestCase {
    let go = ProviderCatalog.presets.first { $0.id == "opencode-go" }!

    func testPresetRoutesAndAsksForASession() {
        XCTAssertEqual(go.baseURL, "https://opencode.ai/inference/go/openai/v1")
        XCTAssertEqual(go.modelsURL, "https://opencode.ai/inference/go/v1/models", "the list isn't under the chat base (that path is a 404)")
        XCTAssertEqual(go.envKeys, ["OPENCODE_API_KEY"], "the same key as OpenCode Zen")
        XCTAssertEqual(go.sessionHeader, "x-opencode-session")
        let h = go.headers(for: LLMRequest(model: "kimi-k3", system: "", messages: [], sessionID: "lesson-42"))
        XCTAssertEqual(h["x-opencode-session"], "lesson-42", "stable per lesson")
        XCTAssertEqual(h["User-Agent"], "my-ai-teacher/1.0", "Go asks clients to name themselves")
        let oneOff = go.headers(for: LLMRequest(model: "kimi-k3", system: "", messages: []))
        XCTAssertFalse(oneOff["x-opencode-session"]?.isEmpty ?? true, "a call outside a lesson still has one (Go refuses requests without)")
        XCTAssertNil(ProviderCatalog.presets.first { $0.id == "opencode" }!.headers(for: LLMRequest(model: "m", system: "", messages: []))["x-opencode-session"])
    }

    /// Just the provider's object is cut out of the 6 MB catalogue: braces and quotes inside strings don't fool the scan.
    func testCutsOneProviderOutOfTheCatalogue() throws {
        let doc = #"{"other":{"x":"}"},"opencode-go": {"name":"Go \"quoted\" {brace}","models":{"a":{"limit":{"context":1}}}},"zed":{}}"#
        let slice = try XCTUnwrap(ModelsDev.object(named: "opencode-go", in: Data(doc.utf8)))
        let j = try XCTUnwrap(JSON.parse(slice))
        XCTAssertEqual(j["name"]?.string, "Go \"quoted\" {brace}")
        XCTAssertEqual(j["models"]?["a"]?["limit"]?["context"]?.int, 1)
        XCTAssertNil(ModelsDev.object(named: "missing", in: Data(doc.utf8)))
    }

    func testModelsDevPicksEachModelsAPIAndFillsTheGaps() throws {
        let provider = try XCTUnwrap(JSON.parse(#"""
        {"npm": "@ai-sdk/openai-compatible", "models": {
          "deepseek-v4.1-flash": {"name": "DeepSeek V4.1 Flash", "reasoning": true, "tool_call": true, "limit": {"context": 1000000, "output": 384000},
                                  "modalities": {"input": ["text", "image"]}, "cost": {"input": 0.15, "output": 0.6}},
          "qwen3.8-max": {"provider": {"npm": "@ai-sdk/anthropic"}, "limit": {"context": 1000000, "output": 131072}, "cost": {"input": 2, "output": 8}},
          "gemini-4-argon-contributor": {"provider": {"npm": "@ai-sdk/google"}},
          "gpt-6-luna": {"provider": {"npm": "@ai-sdk/openai"}},
          "minimax-m3.1-flash-free": {"cost": {"input": 0, "output": 0}}
        }}
        """#))
        let live = ["deepseek-v4.1-flash", "qwen3.8-max", "gemini-4-argon-contributor", "gpt-6-luna", "minimax-m3.1-flash-free", "brand-new-model"].map { ModelInfo(id: $0) }
        let out = Dictionary(uniqueKeysWithValues: ModelsDev.enrich(live, with: provider).map { ($0.id, $0) })
        XCTAssertNil(out["gpt-6-luna"], "Responses-API models are left out: the app doesn't speak it")
        XCTAssertEqual(out["deepseek-v4.1-flash"]?.api, .openai)
        XCTAssertEqual(out["deepseek-v4.1-flash"]?.contextWindow, 1_000_000)
        XCTAssertEqual(out["deepseek-v4.1-flash"]?.maxOutput, 384_000)
        XCTAssertEqual(out["deepseek-v4.1-flash"]?.vision, true)
        XCTAssertEqual(out["deepseek-v4.1-flash"]?.free, false)
        XCTAssertEqual(out["qwen3.8-max"]?.api, .anthropic)
        XCTAssertEqual(out["gemini-4-argon-contributor"]?.api, .gemini)
        XCTAssertEqual(out["minimax-m3.1-flash-free"]?.free, true, "free lessons can use it")
        XCTAssertEqual(out["brand-new-model"]?.api, .openai, "a model models.dev doesn't know yet takes the default API")
    }

    func testWithoutModelsDevTheFamiliesStillRoute() {
        XCTAssertEqual(ModelsDev.fallback(ModelInfo(id: "claude-haiku-5-5"))?.api, .anthropic)
        XCTAssertEqual(ModelsDev.fallback(ModelInfo(id: "glm-5.3"))?.api, .openai)
        XCTAssertNil(ModelsDev.fallback(ModelInfo(id: "grok-4.7")))
        XCTAssertEqual(ModelsDev.fallback(ModelInfo(id: "beam-free"))?.free, true)
    }

    /// Before any list has loaded (or when it can't), a model's family still picks its API.
    func testUnknownRoutesFallBackToTheModelsFamily() {
        ModelRoutes.set(provider: "opencode-go", [])
        let r = RoutedClient(config: go, apiKey: "k")
        XCTAssertEqual(r.config(for: "claude-haiku-5-5").api, .anthropic)
        XCTAssertEqual(r.config(for: "claude-haiku-5-5").baseURL, "https://opencode.ai/inference/go/anthropic/v1")
        XCTAssertEqual(r.config(for: "gemini-4-argon-contributor").api, .gemini)
        XCTAssertEqual(r.config(for: "kimi-k3").api, .openai)
        XCTAssertEqual(r.config(for: "gpt-6-luna").api, .openai, "an API the app doesn't speak: the main one, and the server says no")
    }

    func testEachModelGoesToItsAPIsBaseURL() {
        ModelRoutes.set(provider: "opencode-go", [
            ModelInfo(id: "qwen3.8-max", api: .anthropic), ModelInfo(id: "kimi-k3", api: .openai), ModelInfo(id: "gemini-4-argon-contributor", api: .gemini),
        ])
        let r = RoutedClient(config: go, apiKey: "k")
        XCTAssertEqual(r.config(for: "qwen3.8-max").api, .anthropic)
        XCTAssertEqual(r.config(for: "qwen3.8-max").baseURL, "https://opencode.ai/inference/go/anthropic/v1")
        XCTAssertEqual(r.config(for: "kimi-k3").baseURL, "https://opencode.ai/inference/go/openai/v1")
        XCTAssertEqual(r.config(for: "gemini-4-argon-contributor").baseURL, "https://opencode.ai/inference/go/google/v1beta")
        XCTAssertEqual(r.config(for: "unknown").api, .openai, "unknown models use the provider's main API")
        XCTAssertNil(r.config(for: "qwen3.8-max").apiBases, "the routed config is a plain single-API provider")
        XCTAssertEqual(r.config(for: "qwen3.8-max").sessionHeader, "x-opencode-session", "and still sends the session")
    }
}
