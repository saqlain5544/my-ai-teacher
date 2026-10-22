import XCTest
@testable import MyAITeacher

/// Getting the most out of the model: context that scales with it, its highest effort, a real "off", and plan → verify.
final class IntelligenceTests: XCTestCase {
    func testContextBudgetScalesWithTheModel() {
        XCTAssertEqual(ContextPolicy.budget(setting: 0, contextWindow: 1_000_000), 400_000, "a 1M model gets 400k, not 48k")
        XCTAssertEqual(ContextPolicy.budget(setting: 0, contextWindow: 200_000), 100_000)
        XCTAssertEqual(ContextPolicy.budget(setting: 0, contextWindow: nil), 64_000)
        XCTAssertEqual(ContextPolicy.budget(setting: 120_000, contextWindow: 1_000_000), 120_000, "a chosen budget stays")
        XCTAssertEqual(AppSettings().compactAtTokens, 0, "automatic by default")
        let saved = try! JSONDecoder().decode(AppSettings.self, from: Data(#"{"compactAtTokens": 48000}"#.utf8))
        XCTAssertEqual(saved.compactAtTokens, 0, "the old 48k default becomes automatic")
    }

    func testMaxEffortOnlyWhereTheModelTakesIt() {
        var deepseek = ModelInfo(id: "deepseek-v4.1-flash"); deepseek.efforts = ["low", "medium", "high", "max"]
        var other = ModelInfo(id: "glm-5.3"); other.efforts = ["low", "medium", "high"]
        XCTAssertEqual(ThinkingLevel.max.supported(by: deepseek), .max)
        XCTAssertEqual(ThinkingLevel.max.supported(by: other), .high)
        XCTAssertEqual(ThinkingLevel.max.supported(by: nil), .high)
        XCTAssertEqual(ThinkingLevel.medium.supported(by: other), .medium)
        let provider = try! XCTUnwrap(JSON.parse(#"{"models": {"deepseek-v4.1-flash": {"reasoning": true}, "glm-5.3": {"reasoning": true}}}"#))
        let out = ModelsDev.enrich([ModelInfo(id: "deepseek-v4.1-flash"), ModelInfo(id: "glm-5.3")], with: provider)
        XCTAssertEqual(out.first { $0.id == "deepseek-v4.1-flash" }?.efforts?.last, "max")
        XCTAssertEqual(out.first { $0.id == "glm-5.3" }?.efforts?.last, "high")
    }

    /// On OpenCode Go "off" left DeepSeek reasoning; its own switch works there, and MiniMax (mandatory thinking) must not get it.
    func testThinkingOffReallyTurnsDeepSeekOff() {
        let go = ProviderCatalog.presets.first { $0.id == "opencode-go" }!
        let client = OpenAIClient(config: go, apiKey: nil)
        let off = client.buildBody(LLMRequest(model: "deepseek-v4.1-flash", system: "", messages: [], thinking: .off))
        XCTAssertEqual(off["thinking"]?["type"]?.string, "disabled")
        let mm = client.buildBody(LLMRequest(model: "minimax-m3.1-flash-free", system: "", messages: [], thinking: .off))
        XCTAssertNil(mm["thinking"], "MiniMax refuses thinking=disabled")
        let max = client.buildBody(LLMRequest(model: "deepseek-v4.1-flash", system: "", messages: [], thinking: .max))
        XCTAssertEqual(max["reasoning_effort"]?.string, "max")
        XCTAssertEqual(max["thinking"]?["type"]?.string, "enabled")
    }

    func testSubstantialRequestsGetPlannedAndChecked() {
        XCTAssertTrue(DeepWork.isSubstantial("Explain how TCP congestion control works"))
        XCTAssertTrue(DeepWork.isSubstantial("Teach me the chain rule"))
        XCTAssertTrue(DeepWork.isSubstantial(String(repeating: "I am preparing for an exam on thermodynamics next week ", count: 3)))
        XCTAssertFalse(DeepWork.isSubstantial("thanks!"))
        XCTAssertFalse(DeepWork.isSubstantial("continue"))
        XCTAssertFalse(DeepWork.isSubstantial("x = 4"))
        XCTAssertFalse(DeepWork.isSubstantial("My attempt at “Solve 3x+7=22”: I subtracted 7 and why not divide first"))
        XCTAssertFalse(DeepWork.isSubstantial("I've submitted “LRU cache”: some tests still fail."))
    }

    func testTheReviewersVerdict() {
        XCTAssertEqual(DeepWork.verdict("VERDICT: OK"), .init(revise: false, issues: []))
        let v = DeepWork.verdict("VERDICT: REVISE\n- The derivative of x^2 is 2x, not x.\n- The example is a toy: use a real one.")
        XCTAssertTrue(v.revise); XCTAssertEqual(v.issues.count, 2)
        XCTAssertFalse(DeepWork.verdict("VERDICT: REVISE").revise, "a revision needs a reason")
        XCTAssertTrue(DeepWork.revisionNote(v.issues).contains("2x, not x"))
        XCTAssertTrue(DeepWork.planNote("Outline: …").contains("Check before teaching"))
    }
}

/// The code mentor designs, researches and tests a lesson before teaching it; the learner works in Helix.
final class MentorLessonTests: XCTestCase {
    func testTheMentorDesignsTheLessonFirst() {
        let ask = DeepWork.planRequest(.code)
        for part in ["Real system", "Concepts", "analogy", "Research", "Working examples", "Exercises", "Pitfalls"] { XCTAssertTrue(ask.contains(part), part) }
        XCTAssertEqual(DeepWork.planRequest(.tutor), DeepWork.planRequest, "other modes keep the general plan")
        let note = DeepWork.planNote("Real system: Redis eviction", mode: .code)
        XCTAssertTrue(note.contains("working examples with `run_code`") && note.contains("Helix") && note.contains("Never show solutions"), note)
        let prompt = SystemPrompt.build(settings: AppSettings(), mode: .code, coreMemory: "", model: "m")
        XCTAssertTrue(prompt.contains("design each lesson before teaching it") && prompt.contains("Helix"))
    }

    func testHelixOpensInTheLearnersTerminal() {
        let dir = URL(fileURLWithPath: "/Users/x/AI Teacher Workspace/exercises/lru cache")
        let script = URL(fileURLWithPath: "/tmp/h.command")
        XCTAssertEqual(ExternalEditor.launch(helix: "/opt/homebrew/bin/hx", dir: dir, terminal: "/Applications/Ghostty.app", script: script).arguments,
                       ["-na", "/Applications/Ghostty.app", "--args", "--working-directory=\(dir.path)", "-e", "/opt/homebrew/bin/hx", "."])
        XCTAssertEqual(ExternalEditor.launch(helix: "/opt/homebrew/bin/hx", dir: dir, terminal: "/Applications/Alacritty.app", script: script).arguments,
                       ["-na", "/Applications/Alacritty.app", "--args", "--working-directory", dir.path, "-e", "/opt/homebrew/bin/hx", "."])
        XCTAssertEqual(ExternalEditor.launch(helix: "hx", dir: dir, terminal: "/System/Applications/Utilities/Terminal.app", script: script).arguments,
                       ["-a", "/System/Applications/Utilities/Terminal.app", "/tmp/h.command"])
        XCTAssertEqual(ExternalEditor.script(helix: "/opt/homebrew/bin/hx", dir: URL(fileURLWithPath: "/tmp/it's here")),
                       "#!/bin/zsh -l\ncd '/tmp/it'\\''s here' && exec '/opt/homebrew/bin/hx' .\n", "quotes survive")
    }
}
