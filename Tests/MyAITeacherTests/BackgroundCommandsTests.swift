import XCTest
@testable import MyAITeacher

/// Background shell commands are listed per lesson and end when the lesson is stopped.
final class BackgroundCommandsTests: XCTestCase {
    /// Its own shell session: the shell state is app-wide, and other suites use "L" too.
    let lesson = "bg-" + UUID().uuidString
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("bgcmd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx() -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: lesson, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    func waitEmpty(_ conv: String, seconds: Double) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if await ShellState.shared.running(conv).isEmpty { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return false
    }

    func testStopAllEndsARunningBackgroundCommand() async throws {
        let c = await ctx()
        let out = await BashTool.background("sleep 30", input: JSON.object([:]), cwd: dir, ctx: c)
        XCTAssertTrue(out.text.contains("B"), out.text)
        let running = await ShellState.shared.running(lesson)
        XCTAssertEqual(running.count, 1)
        await ShellState.shared.stopAll(lesson)
        let empty = await waitEmpty(lesson, seconds: 2)
        XCTAssertTrue(empty)
        // The process itself ends: the stopped command leaves the "stopping" set once ProcessRunner returns.
        let end = Date().addingTimeInterval(5)
        while Date() < end, await ShellState.shared.stillStopping(lesson) > 0 { try? await Task.sleep(nanoseconds: 50_000_000) }
        let left = await ShellState.shared.stillStopping(lesson)
        XCTAssertEqual(left, 0, "the sleep was terminated, not left running")
    }

    func testAFinishedCommandUnregistersItself() async throws {
        let c = await ctx()
        _ = await BashTool.background("echo hi", input: JSON.object([:]), cwd: dir, ctx: c)
        let empty = await waitEmpty(lesson, seconds: 5)
        XCTAssertTrue(empty)
    }
}
