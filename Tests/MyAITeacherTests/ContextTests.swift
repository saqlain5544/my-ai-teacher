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
        // The summary and the next learner message travel as one learner turn (providers want alternating roles).
        XCTAssertEqual(out.count, msgs.count - 4)
        XCTAssertTrue(out[0].plainText.contains("Covered: X."))
        XCTAssertEqual(out[0].blocks.count, 1 + msgs[4].blocks.count)
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

final class PolicyTests: XCTestCase {
    func testPackageInstallsAreBlocked() {
        let bash = BashTool(), code = RunCodeTool()
        for c in ["pip install numpy", "python3 -m pip install x", "uv pip install y", "conda install z", "brew install wget", "npm i -g serve"] {
            XCTAssertNotNil(PermissionExtension.packageInstall(tool: bash, input: ["command": .string(c)]), c)
        }
        XCTAssertNotNil(PermissionExtension.packageInstall(tool: code, input: ["language": "python", "code": "import subprocess; subprocess.run('pip install x', shell=True)"]))
        for c in ["ls -la", "python3 script.py", "pip list", "echo 'install guide'"] {
            XCTAssertNil(PermissionExtension.packageInstall(tool: bash, input: ["command": .string(c)]), c)
        }
    }

    func testPythonDetection() {
        XCTAssertTrue(PermissionExtension.isPython(MathTool(), ["expression": "x"]))
        XCTAssertTrue(PermissionExtension.isPython(RunCodeTool(), ["language": "Python", "code": "1"]))
        XCTAssertFalse(PermissionExtension.isPython(RunCodeTool(), ["language": "javascript", "code": "1"]))
    }

    func testExperimentArmsAreStableAndSplit() {
        let e = Experiments.visualTool
        XCTAssertEqual(Experiments.arm(e, unit: "lesson-1"), Experiments.arm(e, unit: "lesson-1"))
        let arms = (0..<200).map { Experiments.arm(e, unit: "l\($0)") }
        let share = Double(arms.filter { $0 == "core" }.count) / 200
        XCTAssertGreaterThan(share, 0.35); XCTAssertLessThan(share, 0.65)
    }

    func testConsecutiveLearnerMessagesMergeForProviders() {
        let msgs = [ChatMessage(role: .user, blocks: [.text("q")]),
                    ChatMessage(role: .assistant, blocks: [.toolUse(id: "t", name: "task", input: [:])]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "t", name: "task", content: "started")]),
                    ChatMessage(role: .user, blocks: [.text("<background-agent id=\"A1\">report</background-agent>")])]
        let out = ContextPolicy.mergeConsecutiveUserTurns(msgs)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[2].blocks.map(\.kind), [.toolResult, .text], "tool results stay first")
    }
}
