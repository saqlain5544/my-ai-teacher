import XCTest
@testable import MyAITeacher

/// A turn ends when the work is done or the learner is needed, not because a reply stopped early.
final class TurnContinuationTests: XCTestCase {
    func testUnfinishedRepliesAreSentBack() {
        XCTAssertNotNil(ChatSession.unfinished(reply: "  ", usedTools: false, todos: []), "an empty reply")
        XCTAssertNotNil(ChatSession.unfinished(reply: "The build passes.\n\nNow let me run the tests:", usedTools: true, todos: []))
        XCTAssertNotNil(ChatSession.unfinished(reply: "Fixed the import. I'll now check the other two files.", usedTools: true, todos: []))
        let open: [JSON] = [["content": "Write tests", "status": "pending"], ["content": "Fix bug", "status": "completed"]]
        XCTAssertEqual(ChatSession.unfinished(reply: "Fixed the bug.", usedTools: true, todos: open), "your todo list still has 1 open item (Write tests)")
        XCTAssertNotNil(ChatSession.unfinished(reply: "Read the spec first: it's the contract.\n\nThree things I had to change ", usedTools: true, todos: []), "stopped mid-sentence")
    }

    func testRepliesThatShouldEndTheTurnDo() {
        XCTAssertNil(ChatSession.unfinished(reply: "Done: the tests pass.", usedTools: true, todos: []))
        XCTAssertNil(ChatSession.unfinished(reply: "Shall I also update the docs? Let me know what you think?", usedTools: true, todos: []), "a question waits for the learner")
        XCTAssertNil(ChatSession.unfinished(reply: "Let me know if you'd like another example.", usedTools: true, todos: []))
        XCTAssertNil(ChatSession.unfinished(reply: "Let me explain the chain rule:", usedTools: false, todos: []), "a teaching reply without tools this turn")
        XCTAssertNil(ChatSession.unfinished(reply: "Run it:\n\n```\nzig build test\n```", usedTools: true, todos: []), "ends with code")
        XCTAssertNil(ChatSession.unfinished(reply: "Two cases:\n- the empty input\n- a lone operator with no operand", usedTools: true, todos: []), "ends with a list")
        XCTAssertNil(ChatSession.unfinished(reply: "Done.", usedTools: true, todos: [["content": "x", "status": "completed"]]))
        // Hand-offs a mentor ends on, from measured lessons where the old rule sent each one back.
        for line in ["When C1 is done, ask me to review: I'll run the tests, read your diff, and record findings.",
                     "Paste `myprog.py` here and I'll check it.",
                     "When you've made a change, hit **Request review** and I'll look at your diff. Good luck.",
                     "When you're ready, say **\"review\"** and I'll run the suite, read your diff, and go through it line by line.",
                     "When you've written `Clamp.java`, say the word and I'll run a review."] {
            XCTAssertNil(ChatSession.unfinished(reply: "The project is set up.\n\n" + line, usedTools: true, todos: []), line)
        }
    }

    /// The step that must write the reply offers no tools: Anthropic's own API refuses a history with tool calls and no
    /// tools declared (a 400 ended the turn), so it keeps them with tool_choice none; everyone else gets none.
    func testAStepWithToolsOffStillDeclaresThemWhereTheAPINeedsIt() {
        let history = [ChatMessage(role: .user, blocks: [.text("17 × 23?")]),
                       ChatMessage(role: .assistant, blocks: [.toolUse(id: "t1", name: "math", input: ["expression": "17*23"])]),
                       ChatMessage(role: .user, blocks: [.toolResult(id: "t1", name: "math", content: "391")])]
        var r = LLMRequest(model: "claude-opus-5-5", system: "s", messages: history, tools: [MathTool().spec])
        r.toolsOff = true
        let anthropic = ProviderConfig(id: "anthropic", name: "A", api: .anthropic, baseURL: "https://api.anthropic.com/v1", envKeys: [], defaultModel: "claude-opus-5-5")
        let body = AnthropicClient(config: anthropic, apiKey: nil).buildBody(r)
        XCTAssertEqual(body["tools"]?.array?.count, 1)
        XCTAssertEqual(body["tool_choice"]?["type"]?.string, "none")
        let minimax = ProviderCatalog.presets.first { $0.id == "minimax" }!
        let compat = AnthropicClient(config: minimax, apiKey: nil).buildBody(r)
        XCTAssertNil(compat["tools"], "MiniMax ignores tool_choice; without tools it can't call one")
        XCTAssertNil(compat["tool_choice"])
        let openrouter = ProviderCatalog.presets.first { $0.id == "openrouter" }!
        XCTAssertNil(OpenAIClient(config: openrouter, apiKey: nil).buildBody(r)["tools"])
        r.toolsOff = false
        XCTAssertNil(AnthropicClient(config: anthropic, apiKey: nil).buildBody(r)["tool_choice"], "an ordinary step lets the model choose")
    }
}
