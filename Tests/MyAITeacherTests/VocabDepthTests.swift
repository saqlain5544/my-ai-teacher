import XCTest
@testable import MyAITeacher

/// Words worth trusting: register, collocations and the word family on the card, readings checked against the dictionary.
final class VocabDepthTests: XCTestCase {
    @MainActor func testRegisterCollocationsAndFamilyGoOnTheCard() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("vocabdepth-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        let ctx = ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "t1",
                              client: ScriptedLLM([]), model: "m", progress: { _ in })
        _ = services.study.setLanguageProfile(code: "ja", role: "target", level: "A2")
        let out = try await VocabTool().run(["action": "add", "words": [["term": "書類", "reading": "しょるい", "meaning": "documents", "register": "business",
                                                                             "collocations": ["書類を出す", "書類を作る"], "family": ["書く", "読書"]]]], ctx)
        XCTAssertFalse(out.isError, out.text)
        let card = services.study.allCards(deck: StudyStore.vocabDeck("ja")).first
        XCTAssertTrue(card?.back.contains("Register: business") ?? false, card?.back ?? "")
        XCTAssertTrue(card?.back.contains("Goes with: 書類を出す, 書類を作る") ?? false)
        XCTAssertTrue(card?.back.contains("Family: 書く, 読書") ?? false)
        let bad = try await VocabTool().run(["action": "add", "words": [["term": "出社", "reading": "しゅくしゃ", "meaning": "going to work"]]], ctx)
        XCTAssertTrue(bad.text.contains("isn't the dictionary's"), bad.text)
    }
}
