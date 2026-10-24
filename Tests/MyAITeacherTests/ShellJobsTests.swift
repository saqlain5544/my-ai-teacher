import XCTest
@testable import MyAITeacher

/// Commands that never end on their own (servers, watchers, `cmd &`) must not hold the agent: they move to the
/// background with a handle, and stopping one ends everything it started.
final class ShellJobsTests: XCTestCase {
    var dir: URL!
    var conv: String!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("jobs-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        conv = "jobs-\(UUID().uuidString.prefix(6))"
    }
    override func tearDown() {
        ShellJobs.shared.stopAll(conv)
        try? FileManager.default.removeItem(at: dir)
    }

    private func ctx() async throws -> ToolContext {
        ToolContext(conversationID: conv, workspace: dir,
                    services: Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir)),
                    interactions: await MainActor.run { InteractionCenter() }, toolCallID: "b",
                    client: ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m").client(apiKey: nil),
                    model: "m", progress: { _ in })
    }

    private func gone(_ pid: pid_t, within seconds: Double = 5) async -> Bool {
        let until = Date().addingTimeInterval(seconds)
        while Date() < until { if kill(-pid, 0) != 0 { return true }; try? await Task.sleep(for: .milliseconds(100)) }
        return false
    }

    func testAServerThatPrintsItsURLMovesToTheBackgroundAndStops() async throws {
        let c = try await ctx()
        let t0 = Date()
        let out = try await BashTool().run(["command": "echo 'ready at http://localhost:4567/'; sleep 60"], c)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 8, "returns once the URL is up, not at the timeout")
        XCTAssertEqual(out.meta?["background"]?.string, "B1")
        XCTAssertEqual(out.meta?["url"]?.string, "http://localhost:4567/")
        XCTAssertTrue(out.text.contains("ready at"), out.text)
        let job = try XCTUnwrap(ShellJobs.shared.job(conv, "b1"), "handles are case-insensitive")
        XCTAssertTrue(job.isRunning)
        let list = try await BashJobsTool().run([:], c)
        XCTAssertTrue(list.text.contains("B1") && list.text.contains("running"), list.text)
        let stop = try await BashJobsTool().run(["action": "stop", "handle": "B1"], c)
        XCTAssertTrue(stop.text.hasPrefix("Stopped B1"), stop.text)
        let gone = await gone(job.pid)
        XCTAssertTrue(gone, "the shell and its sleep are both ended")
        XCTAssertNil(ShellJobs.shared.job(conv, "B1"))
    }

    func testACommandThatLeavesAChildRunningReturns() async throws {
        // `cmd &`: the shell exits at once, its child keeps the output pipe open (this waited until the timeout and
        // then forever, since nothing ended the child).
        let c = try await ctx()
        let t0 = Date()
        let out = try await BashTool().run(["command": "(sleep 60; echo late) & echo started"], c)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
        XCTAssertTrue(out.text.contains("left a process running"), out.text)
        let job = try XCTUnwrap(ShellJobs.shared.job(conv, out.meta?["background"]?.string ?? ""))
        ShellJobs.shared.stopAll(conv)
        let gone = await gone(job.pid)
        XCTAssertTrue(gone, "the orphaned child was in the job's group")
    }

    func testATimeoutEndsTheWholeTree() async throws {
        let c = try await ctx()
        let out = try await BashTool().run(["command": "zsh -c 'sleep 60' ; echo never", "timeout": 1], c)
        XCTAssertTrue(out.isError)
        XCTAssertTrue(out.text.contains("timed out after 1 s"), out.text)
        XCTAssertTrue(ShellJobs.shared.list(conv).isEmpty, "a timed-out job is not kept")
    }

    func testOrdinaryCommandsStillReturnTheirOutputAndExitCode() async throws {
        let c = try await ctx()
        let out = try await BashTool().run(["command": "mkdir -p sub && cd sub && printf '\\033[31mred\\033[0m\\n'; exit 3"], c)
        XCTAssertEqual(out.text, "red\n[exit code 3]", "colour codes removed")
        XCTAssertEqual(out.meta?["exit"]?.int, 3)
        let pwd = try await BashTool().run(["command": "pwd"], c)
        XCTAssertTrue(pwd.text.hasSuffix("/sub"), "the working directory still persists: \(pwd.text)")
        XCTAssertTrue(ShellJobs.shared.list(conv).isEmpty)
    }

    func testBackgroundOnRequestAndReadingNewOutput() async throws {
        let c = try await ctx()
        let out = try await BashTool().run(["command": "echo one; sleep 7; echo two; sleep 60", "background": true], c)
        let h = try XCTUnwrap(out.meta?["background"]?.string)
        XCTAssertTrue(out.text.contains("one"))
        let next = try await BashJobsTool().run(["action": "output", "handle": .string(h), "wait": 10], c)
        XCTAssertTrue(next.text.hasPrefix("two\n["), "only what is new: \(next.text)")
        let none = try await BashJobsTool().run(["action": "output", "handle": .string(h)], c)
        XCTAssertTrue(none.text.hasPrefix("(nothing new)"), none.text)
    }

    /// The runner under run_code and the app's own commands: a child that outlives its program no longer holds the call.
    func testProcessRunnerReturnsWhenAChildKeepsThePipeOpen() async {
        let t0 = Date()
        let r = await ProcessRunner.run("/bin/zsh", ["-c", "sleep 41.25 & echo hi"], timeout: 30)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5)
        XCTAssertTrue(r.stdout.hasPrefix("hi") && r.stdout.contains("still running"), r.stdout)
        _ = await ProcessRunner.run("/usr/bin/pkill", ["-f", "sleep 41.25"], timeout: 5)
    }

    func testProcessRunnerTimeoutEndsGrandchildren() async throws {
        let t0 = Date()
        let r = await ProcessRunner.run("/bin/zsh", ["-c", "zsh -c 'sleep 42.25'; echo after"], timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 6)
        try await Task.sleep(for: .seconds(2.5))
        let left = await ProcessRunner.run("/usr/bin/pgrep", ["-f", "sleep 42.25"], timeout: 5)
        XCTAssertEqual(left.stdout.trimmingCharacters(in: .whitespacesAndNewlines), "", "the grandchild was ended too")
    }

    /// A background job that ends by itself is reported to the lesson in the <background-task> format the transcript draws.
    func testAFinishedBackgroundJobIsReported() async throws {
        let c = try await ctx()
        let out = try await BashTool().run(["command": "echo building; sleep 5; echo built; exit 2", "background": true], c)
        let job = try XCTUnwrap(ShellJobs.shared.job(conv, out.meta?["background"]?.string ?? ""))
        while job.isRunning { try await Task.sleep(for: .milliseconds(100)) }
        let msg = ShellJobs.finishedMessage(job, handle: "B1")
        let text = msg.blocks[0].text ?? ""
        XCTAssertTrue(text.hasPrefix("<background-task id=\"B1\" command=\"echo building;") && text.contains("exit=\"2\""), text)
        let body = text.split(separator: "\n").dropFirst().joined(separator: "\n")
        XCTAssertTrue(body.hasPrefix("built") && !body.contains("building"), "only what the agent hasn't seen: \(text)")
        XCTAssertEqual(msg.blocks[0].meta?["backgroundTask"]?.string, "B1")
    }

    func testRecognisingServersAndTheirURLs() {
        for cmd in ["npm run dev", "pnpm dev", "yarn start", "bun run dev -- --port 3000", "npx vite", "vite", "python3 -m http.server 8000",
                    "python manage.py runserver", "flask run", "uvicorn app:app --reload", "rails s", "php -S localhost:8000", "next dev", "tail -f log.txt"] {
            XCTAssertTrue(ShellJob.looksLikeServer(cmd), cmd)
        }
        for cmd in ["npm install", "npm run build", "vite build", "npm test", "python3 main.py", "docker compose up -d", "ls -la"] {
            XCTAssertFalse(ShellJob.looksLikeServer(cmd), cmd)
        }
        XCTAssertEqual(ShellJob.localURLs(in: "  \u{1B}[32m➜\u{1B}[39m  Local:   \u{1B}[36mhttp://localhost:\u{1B}[1m5173\u{1B}[22m/\u{1B}[39m"), ["http://localhost:5173/"])
        XCTAssertEqual(ShellJob.localURLs(in: "Serving HTTP on 0.0.0.0 port 8000 (http://0.0.0.0:8000/) ..."), ["http://localhost:8000/"])
        XCTAssertEqual(ShellJob.localURLs(in: "Server listening on port 3000"), ["http://localhost:3000"])
        XCTAssertEqual(ShellJob.localURLs(in: "see https://example.com/docs"), [])
        XCTAssertEqual(ShellJob.plain("50%\r75%\r100%\ndone"), "100%\ndone")
    }
}
