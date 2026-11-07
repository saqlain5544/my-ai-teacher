import XCTest
@testable import MyAITeacher

/// Follow-ups to the secret guards that touch no credential or key file: real tool output shapes, path tricks, thrown
/// errors, the deny rules on a fake home, and the image fetch's limits.
final class SecretShapeTests: XCTestCase {
    private struct Fake: Tool {
        var name = "fake"; var description = ""; var schema: JSON = ["type": "object"]; var risk: ToolRisk = .readOnly
        var body: @Sendable (JSON) async throws -> ToolOutput
        func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput { try await body(input) }
    }
    private func ctx() async throws -> ToolContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ss-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ToolContext(conversationID: "l", workspace: dir, services: Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir)),
                           interactions: await MainActor.run { InteractionCenter() }, toolCallID: "c",
                           client: ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m").client(apiKey: nil), model: "m", progress: { _ in })
    }
    override func tearDown() { Secrets.update { $0.savedKeys = []; $0.mcpSecrets = []; $0.envAllow = []; $0.protectCredentials = true } }

    // MARK: .env lines as the tools print them

    func testDotenvValuesAreRedactedInReadAndGrepOutput() {
        let read = "     1\tNODE_ENV=production\n     2\tDB_PASSWORD=hunter2hunter2\n     3\texport API_TOKEN=\"abcd efgh ijkl\"\n"
        XCTAssertEqual(Secrets.redact(read).text, "     1\tNODE_ENV=production\n     2\tDB_PASSWORD=[redacted: .env value]\n     3\texport API_TOKEN=[redacted: .env value]\n")
        XCTAssertEqual(Secrets.redact("app/.env:3:STRIPE_SECRET=sk_abc_1234567890\nother:1:x=y").text, "app/.env:3:STRIPE_SECRET=[redacted: .env value]\nother:1:x=y")
        XCTAssertEqual(Secrets.redact("7:AUTH_TOKEN=Zm9vYmFyMTIz\n8:PORT=3000").text, "7:AUTH_TOKEN=[redacted: .env value]\n8:PORT=3000")
    }

    func testDotenvDoesNotTouchCodeOrSettings() {
        for line in ["MAX_TOKENS = 4096", "MAX_TOKENS=4096", "PASSWORD_FIELD = \"password\"", "PASSWORD_FIELD=password", "SECRET_KEY_BASE=", "     4\tTOKEN_URL=https://example.com",
                     "API_KEY = os.environ[\"API_KEY\"]", "PASSWORD=$DB_PASS", "AUTH_TOKEN=12345678"] {
            let out = Secrets.redact(line + "\n")
            XCTAssertEqual(out.text, line + "\n", line)
            XCTAssertTrue(out.kinds.isEmpty, line)
        }
    }

    // MARK: Paths

    func testGlobAndDotDotTricksAreAsked() {
        let ws = URL(fileURLWithPath: Secrets.home + "/proj-that-does-not-exist")
        for (tool, input) in [("read", ["path": "*/../../.ssh/id_rsa"]), ("read", ["path": "x[1]/../../.ssh/config"]), ("read", ["path": "../.aws/credentials"]),
                              ("read", ["path": "~/.SSH/id_rsa"]), ("ls", ["path": "../.GnuPG"]), ("read", ["path": Secrets.home.uppercased() + "/.ssh/id_rsa"]),
                              ("glob", ["pattern": "*/../../.ssh/*"]), ("glob", ["pattern": "../.ssh/*"]), ("glob", ["pattern": "*", "path": "../.ssh"]),
                              ("grep", ["pattern": "x", "path": "../.aws"])] {
            XCTAssertNotNil(Secrets.credentialPathNamed(by: tool, JSON.object(input.mapValues { .string($0) }), workspace: ws), "\(tool) \(input)")
        }
        XCTAssertNil(Secrets.credentialPathNamed(by: "read", ["path": "src/main.swift"], workspace: ws))
        XCTAssertNil(Secrets.credentialPathNamed(by: "glob", ["pattern": "**/*.swift"], workspace: ws))
        XCTAssertNil(Secrets.credentialPathNamed(by: "read", ["path": "a/../b.txt"], workspace: ws))
    }

    func testASymlinkIntoACredentialLocationIsAsked() throws {
        let ws = FileManager.default.temporaryDirectory.appendingPathComponent("lnk-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let support = AppPaths.support   // holds the (test profile's) keys file and settings
        try FileManager.default.createSymbolicLink(at: ws.appendingPathComponent("link"), withDestinationURL: support)
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "read", ["path": .string("link/" + AppPaths.keys.lastPathComponent)], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "read", ["path": .string("link/" + AppPaths.settings.lastPathComponent)], workspace: ws))
        XCTAssertNil(Secrets.credentialPathNamed(by: "read", ["path": "link/other.txt"], workspace: ws))
    }

    // MARK: Thrown errors, MCP secrets

    func testAThrownErrorIsRedactedToo() async throws {
        let c = try await ctx()
        struct Echo: LocalizedError { var errorDescription: String? { "server said: bad key sk-live-1234567890abcdefghij" } }
        do {
            _ = try await Fake { _ in throw Echo() }.runBounded([:], c)
            XCTFail("should throw")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("sk-live"), error.localizedDescription)
            XCTAssertTrue(error.localizedDescription.contains("[redacted: API key]"), error.localizedDescription)
        }
        do { _ = try await Fake { _ in throw ToolError("plain failure") }.runBounded([:], c); XCTFail() } catch { XCTAssertEqual(error.localizedDescription, "plain failure") }
    }

    func testMCPServerTokensInSettingsAreMatchedExactly() async {
        await MainActor.run {
            let store = SettingsStore()
            var cfg = MCPServerConfig(name: "docs", command: "/bin/echo")
            cfg.env = ["DOCS_TOKEN": "mcp-token-abcdef123456", "SHORT": "abc"]; cfg.headers = ["X-Api": "hdrvalue-1234567890"]
            store.value.mcpServers = [cfg]
        }
        let r = Secrets.redact("env mcp-token-abcdef123456 and Bearer hdrvalue-1234567890 and abc")
        XCTAssertEqual(r.text, "env [redacted: MCP server secret] and Bearer [redacted: MCP server secret] and abc")
        await MainActor.run { let s = SettingsStore(); s.value.mcpServers = [] }
    }

    func testAMarkerIsRefusedOnlyForAFileThisAgentReadRedacted() async throws {
        let c = try await ctx()
        let f = c.workspace.appendingPathComponent("a.txt")
        try "key = real\n".write(to: f, atomically: true, encoding: .utf8)
        let input: JSON = ["path": "a.txt", "content": "key = [redacted: API key]\n"]
        XCTAssertNil(Secrets.introducesMarker(tool: "write", input, workspace: c.workspace, agent: "A"), "never read: a file about the marker is fine")
        Secrets.noteRedactedRead(agent: "A", path: f)
        XCTAssertNotNil(Secrets.introducesMarker(tool: "write", input, workspace: c.workspace, agent: "A"))
        XCTAssertNil(Secrets.introducesMarker(tool: "write", input, workspace: c.workspace, agent: "B"), "another agent did not read it")
        XCTAssertTrue(Secrets.introducesMarker(tool: "write", input, workspace: c.workspace, agent: "A")?.contains(f.path) == true, "the message names the file")
    }

    func testBackgroundOutputIsRedactedBeforeItIsDelivered() async throws {
        let job = try ShellJob(command: "echo", title: "t", conversationID: "c", shell: "/bin/sh", script: "echo key=sk-live-1234567890abcdefghij", cwd: FileManager.default.temporaryDirectory, env: ["PATH": "/usr/bin:/bin"])
        for _ in 0..<100 where job.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        let text = ShellJobs.finishedMessage(job, handle: "B1").blocks.first?.text ?? ""
        XCTAssertFalse(text.contains("sk-live"), text)
        XCTAssertTrue(text.contains("[redacted: API key]"), text)
    }

    // MARK: The fence

    func testDenyRulesOnAFakeHomeBlockReadsMovesAndLinksButNotOrdinaryWork() async throws {
        try XCTSkipUnless(WriteFence.available)
        let fm = FileManager.default
        let home = URL(fileURLWithPath: WriteFence.real(fm.temporaryDirectory.appendingPathComponent("fakehome-\(UUID().uuidString)")))
        for d in [".ssh", ".config/gh", "other"] { try fm.createDirectory(at: home.appendingPathComponent(d), withIntermediateDirectories: true) }
        try "PRIVATE".write(to: home.appendingPathComponent(".ssh/id_rsa"), atomically: true, encoding: .utf8)
        try "gh-token".write(to: home.appendingPathComponent(".config/gh/hosts.yml"), atomically: true, encoding: .utf8)
        try "ok".write(to: home.appendingPathComponent("other/f"), atomically: true, encoding: .utf8)
        try "netrc".write(to: home.appendingPathComponent(".netrc"), atomically: true, encoding: .utf8)
        let h = home.path
        let profile = "(version 1)\n(allow default)\n" + WriteFence.denyRules(dirs: [h + "/.ssh", h + "/.config/gh"], files: [h + "/.netrc"], parents: [h, h + "/.config"])
        func sh(_ script: String) async -> ProcessResult {
            await WriteFence.$profile.withValue(profile) { await ProcessRunner.run("/bin/sh", ["-c", script], timeout: 10) }
        }
        let elsewhere = home.deletingLastPathComponent().appendingPathComponent("moved-\(UUID().uuidString)").path
        // Reads, and every way around them.
        var r = await sh("cat '\(h)/.ssh/id_rsa'"); XCTAssertNotEqual(r.exitCode, 0); XCTAssertFalse(r.combined.contains("PRIVATE"))
        r = await sh("mv '\(h)/.ssh' '\(elsewhere)-a'; cat '\(elsewhere)-a/id_rsa'"); XCTAssertFalse(r.combined.contains("PRIVATE"), r.combined)
        r = await sh("mv '\(h)/.config' '\(elsewhere)-b'; cat '\(elsewhere)-b/gh/hosts.yml'"); XCTAssertFalse(r.combined.contains("gh-token"), r.combined)
        r = await sh("ln '\(h)/.ssh/id_rsa' '\(elsewhere)-c'; cat '\(elsewhere)-c'"); XCTAssertFalse(r.combined.contains("PRIVATE"), r.combined)
        r = await sh("ln -s '\(h)/.ssh' '\(elsewhere)-d'; cat '\(elsewhere)-d/id_rsa'"); XCTAssertFalse(r.combined.contains("PRIVATE"), r.combined)
        r = await sh("cp '\(h)/.netrc' '\(elsewhere)-e'"); XCTAssertNotEqual(r.exitCode, 0)
        r = await sh("echo x > '\(h)/.ssh/new'"); XCTAssertNotEqual(r.exitCode, 0, "no writing into a credential folder")
        for suffix in ["a", "b", "c", "e"]   /* "d" is only a symlink, which reads nothing */ { XCTAssertFalse(fm.fileExists(atPath: "\(elsewhere)-\(suffix)"), suffix) }
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent(".ssh/id_rsa"), encoding: .utf8), "PRIVATE", "still where it was")
        // Ordinary work next to them goes on.
        r = await sh("echo hi > '\(h)/other/g' && mv '\(h)/other/f' '\(h)/other/h' && touch '\(h)/.config/new' && cat '\(h)/other/g'")
        XCTAssertEqual(r.exitCode, 0, r.combined); XCTAssertTrue(r.stdout.contains("hi"))
        // The file tools run in the app, not under this profile: a write the learner approved is not blocked by it.
        try "approved".write(to: home.appendingPathComponent(".ssh/known_hosts"), atomically: true, encoding: .utf8)
    }

    // MARK: Image fetch

    func testTheImageFetchRefusesLocalAndSecretURLs() {
        func target(_ u: String) -> URL? {
            RemoteImageSchemeHandler.target(URL(string: "teacher-remote://img/?k=\(RemoteImageSchemeHandler.key)&u=\(u.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!)")!)
        }
        XCTAssertNotNil(target("https://example.com/a.png"))
        for bad in ["https://localhost/a.png", "https://127.0.0.1/a.png", "https://192.168.1.5/a.png", "https://10.0.0.2/x", "https://[::1]/x", "https://printer/x",
                    "https://nas.local/x", "http://example.com/a.png", "https://example.com/?k=ghp_" + String(repeating: "Ab1", count: 12)] {
            XCTAssertNil(target(bad), bad)
        }
        // A redirect is held to the same rule.
        XCTAssertNil(RemoteImageSchemeHandler.allowed(URL(string: "http://localhost:8080/")!))
        XCTAssertNotNil(RemoteImageSchemeHandler.allowed(URL(string: "https://cdn.example.com/a.png")!))
    }
}
