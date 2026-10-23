import XCTest
@testable import MyAITeacher

/// A coder sub-agent working in the lesson's folder is part of the turn's Undo.
final class SubAgentUndoTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var interactions: InteractionCenter!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("subundo-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try "old\n".write(to: dir.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        interactions = await MainActor.run { InteractionCenter() }
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func runCoder(turn: String?) async throws {
        let llm = ScriptedLLM([step(.tools([("write", ["path": "a.txt", "content": "new\n"])])), step(.text("Report: wrote a.txt."))])
        let id = UUID().uuidString.prefix(8)
        var c = ToolContext(conversationID: "su-\(id)", workspace: dir, services: services, interactions: interactions, toolCallID: "call-\(id)",
                            client: llm, model: "m", progress: { _ in }, subAgentModels: [])
        var host = FakeHost(folder: dir)
        host.lessonGrants = LessonGrants(access: .write)
        c.agentHost = host
        c.checkpointTurn = turn
        let o = try await TaskTool().run(["description": "W", "prompt": "rewrite a.txt", "type": "coder"], c)
        XCTAssertFalse(o.isError, o.text)
    }

    func testCoderWriteIsCheckpointedAndUndone() async throws {
        try await runCoder(turn: "t9")
        let url = dir.appendingPathComponent("a.txt")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "new\n")
        XCTAssertEqual(Checkpoints.changed(services.workspace, turn: "t9"), ["a.txt"])
        _ = Checkpoints.restore(services.workspace, turn: "t9")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "old\n")
    }

    func testNoTurnKeyNoCheckpoint() async throws {
        try await runCoder(turn: nil)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "new\n")
        XCTAssertNil(Checkpoints.manifest(services.workspace, turn: "t9"))
    }
}
