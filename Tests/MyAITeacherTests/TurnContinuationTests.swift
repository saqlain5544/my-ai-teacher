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
    }
}
