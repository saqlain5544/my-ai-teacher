import XCTest
@testable import MyAITeacher

/// Fixes from the integrated review of the secrets, past-lessons, supervisor and context branches.
final class ReviewFixesTests: XCTestCase {
    var root: URL!
    override func setUp() { root = FileManager.default.temporaryDirectory.appendingPathComponent("review-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
    override func tearDown() { try? FileManager.default.removeItem(at: root) }

    // MARK: One credential list

    func testOneCredentialListFeedsEveryCheck() throws {
        let extra = [".kube", ".npmrc", ".git-credentials", ".config/gcloud"]
        for rel in extra {
            let p = Secrets.home + "/" + rel
            XCTAssertTrue(Secrets.credentialPaths.contains(p), rel)
            XCTAssertTrue(Secrets.isCredentialPath(URL(fileURLWithPath: p)), "the read gate: \(rel)")
            XCTAssertNotNil(Secrets.credentialPathNamed(by: "read", ["path": .string("~/" + rel)], workspace: root), "the file tools ask: \(rel)")
            XCTAssertTrue(Secrets.namesCredential("cat ~/" + rel), "ReadOnlyShell: \(rel)")
            XCTAssertTrue(WriteFence.denyReads.contains(WriteFence.real(URL(fileURLWithPath: p))), "the deny rules: \(rel)")
            XCTAssertTrue(TreeDigest.defaultCredentialRoots().contains(TreeDigest.resolved(p)), "the link check: \(rel)")
        }
        // TreeDigest is the union: it also has the app's settings (MCP tokens), which it lacked.
        XCTAssertTrue(TreeDigest.defaultCredentialRoots().contains(TreeDigest.resolved(AppPaths.settings.path)))
        XCTAssertEqual(Set(TreeDigest.defaultCredentialRoots()), Set(Secrets.credentialPaths.map(TreeDigest.resolved)), "one source")
    }

    // MARK: The plugin folder

    func testCommandsCanReadButNotWriteTheApprovedPluginFiles() throws {
        try XCTSkipUnless(WriteFence.available, "no sandbox-exec")
        let plugins = root.appendingPathComponent("plugins", isDirectory: true)
        try FileManager.default.createDirectory(at: plugins, withIntermediateDirectories: true)
        let file = plugins.appendingPathComponent("approved.md")
        try "approved\n".write(to: file, atomically: true, encoding: .utf8)
        let profile = "(version 1)\n(allow default)\n" + WriteFence.denyRules(dirs: [], files: [], parents: [], writeOnly: [WriteFence.real(plugins)])
        func sh(_ script: String) -> (Int32, String) {
            let (exe, args) = WriteFence.wrap("/bin/sh", ["-c", script], profile: profile)
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args
            let out = Pipe(); p.standardOutput = out; p.standardError = Pipe()
            try? p.run(); let data = out.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        XCTAssertEqual(sh("cat '\(file.path)'").1, "approved\n", "reading is not denied")
        XCTAssertNotEqual(sh("echo evil >> '\(file.path)'").0, 0, "writing is")
        XCTAssertNotEqual(sh("echo x > '\(plugins.path)/new.md'").0, 0, "so is adding a file")
        XCTAssertNotEqual(sh("rm '\(file.path)'").0, 0, "and deleting one")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "approved\n")
        // The real profile: a write-only deny for the plugin folder, no read deny.
        let real = WriteFence.real(Plugins.root)
        let lines = WriteFence.denyReads.components(separatedBy: "\n")
        XCTAssertTrue(lines.contains { $0.hasPrefix("(deny file-write* (subpath") && $0.contains("\"\(real)\"") }, "plugins are write-denied")
        XCTAssertFalse(lines.contains { $0.hasPrefix("(deny file-read*") && $0.contains("\"\(real)\"") }, "and still readable")
    }

    @MainActor func testSettingsInstallAndUpdateStillWriteThePluginFolder() async throws {
        let src = root.appendingPathComponent("src", isDirectory: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent(".claude-plugin"), withIntermediateDirectories: true)
        try #"{"name":"demo","version":"1"}"#.write(to: src.appendingPathComponent(".claude-plugin/plugin.json"), atomically: true, encoding: .utf8)
        try "hi\n".write(to: src.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        let dest = root.appendingPathComponent("installed", isDirectory: true)
        _ = try await PluginInstaller.install(source: src.path, root: dest)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dest.appendingPathComponent("demo/README.md").path))
        try "hello\n".write(to: src.appendingPathComponent("README.md"), atomically: true, encoding: .utf8)
        _ = try await PluginInstaller.install(source: src.path, replacing: "demo", root: dest)
        XCTAssertEqual(try String(contentsOf: dest.appendingPathComponent("demo/README.md"), encoding: .utf8), "hello\n", "the app, not under the profile, updates it")
    }

    // MARK: The mentor's note

    @MainActor func testOnlyARefusalOfAFencedPathIsBlamedOnTheMentorAndLogged() throws {
        let ws = try Workspace(url: root.appendingPathComponent("m", isDirectory: true))
        try "x = 1\n".write(to: ws.url.appendingPathComponent("app.py"), atomically: true, encoding: .utf8)
        var p = MentorProject(); p.title = "t"; p.concept = "c"; p.testCommand = "true"
        ProjectStore.save(p, ws); ProjectStore.snapshot(ws, why: "baseline")
        let services = Services(global: GlobalStore(db: try Database(path: root.appendingPathComponent("g.sqlite").path)), workspace: ws)
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let guardExt = MentorGuard()
        func after(_ output: String) -> (text: String, logged: Int) {
            let call = Block.toolUse(id: UUID().uuidString, name: "bash", input: ["command": "x"])
            _ = guardExt.shouldRun(call, tool: BashTool(), session: session)
            var res = Block.toolResult(id: call.id ?? "", name: "bash", content: output, isError: true)
            guardExt.didRun(call, result: &res, session: session)
            return (res.text ?? "", ProjectStore.load(ws)?.guardLog?.filter { $0.kind == "refused" }.count ?? 0)
        }
        let credential = after("cat: \(Secrets.home)/.aws/credentials: Operation not permitted")
        XCTAssertFalse(credential.text.contains("write fence"), credential.text)
        XCTAssertEqual(credential.logged, 0, "a credential refusal is not the mentor's")
        let nested = after("error: sandbox_apply: Operation not permitted")
        XCTAssertFalse(nested.text.contains("write fence") || nested.logged > 0, nested.text)
        let bare = after("Operation not permitted")
        XCTAssertFalse(bare.text.contains("write fence"), "the bare phrase is not enough")
        let other = after("touch: other-app.py.bak: Operation not permitted")
        XCTAssertFalse(other.text.contains("write fence"), "a path that isn't fenced")
        let fenced = after("zsh: operation not permitted: app.py")
        XCTAssertTrue(fenced.text.contains("write fence"), fenced.text)
        XCTAssertEqual(fenced.logged, 1)
        let absolute = after("tee: \(ws.url.path)/.teacher/state.sqlite: Operation not permitted")
        XCTAssertTrue(absolute.text.contains("write fence"), "the record is fenced too")
        let mentor = after("tee: \(ws.url.path)/.teacher/mentor/notes.md: Operation not permitted")
        XCTAssertFalse(mentor.text.contains("write fence"), "the mentor's own folder is writable, so this wasn't the fence")
    }

    // MARK: past_lessons

    func lesson(_ ws: Workspace, title: String, _ messages: [ChatMessage]) -> Conversation {
        var c = Conversation(providerID: "minimax", model: "MiniMax-M3", mode: .tutor)
        c.title = title; c.updatedAt = Date().addingTimeInterval(-100)
        ws.conversations.save(c)
        for (i, var m) in messages.enumerated() {
            m.createdAt = Date().addingTimeInterval(-100 + Double(i))
            ws.conversations.upsert(m, conversationID: c.id, seq: i)
        }
        return c
    }

    func testASnippetRedactsAKeyTheMatchMarkersSplit() throws {
        let ws = try Workspace(url: root.appendingPathComponent("a", isDirectory: true))
        let key = "sk-ant-api03-Xk29fj3kd9sl2ka8dj3kfs0dk3Qw"
        lesson(ws, title: "Keys", [ChatMessage(role: .user, blocks: [.text("the config holds \(key) and nothing else")])])
        let db = try Database(path: PastLessons.stateFile(ws.url.path), readOnly: true)
        let hits = PastLessons.search(db, folder: ws.url.path, query: "ant config")
        let snippet = try XCTUnwrap(hits.first?.snippet)
        XCTAssertFalse(snippet.contains("api03") || snippet.contains("Xk29"), snippet)
        XCTAssertTrue(snippet.contains("[redacted: API key]"), snippet)
        XCTAssertTrue(snippet.contains("«config»"), "the matched words are still marked: " + snippet)
        // And the window's own text.
        XCTAssertFalse(PastLessons.scrub("see \(key) ok").contains("api03"))
    }

    func testReadingALessonDoesNotReplayWhatFileToolsReturned() throws {
        let ws = try Workspace(url: root.appendingPathComponent("b", isDirectory: true))
        let c = lesson(ws, title: "Creds", [
            ChatMessage(role: .assistant, blocks: [.toolUse(id: "1", name: "read", input: ["path": "~/.aws/credentials"]),
                                                   .toolUse(id: "2", name: "bash", input: ["command": "ls -la"])]),
            ChatMessage(role: .user, blocks: [.toolResult(id: "1", name: "read", content: "[default]\naws_access_key_id = SECRETKEYVALUE12345"),
                                              .toolResult(id: "2", name: "bash", content: "total 8 harmless-listing")]),
            ChatMessage(role: .user, blocks: [.toolResult(id: "3", name: "grep", content: "creds.txt:1: password hunter2hunter2", isError: false),
                                              .toolResult(id: "4", name: "bash", content: "boom: failed head", isError: true)])])
        let db = try Database(path: PastLessons.stateFile(ws.url.path), readOnly: true)
        let w = try XCTUnwrap(PastLessons.window(db, folder: ws.url.path, conversationID: c.id, from: 0, count: 8))
        let out = PastLessonsTool.format(w, ref: c.id, around: nil)
        XCTAssertFalse(out.contains("SECRETKEYVALUE") || out.contains("hunter2"), out)
        XCTAssertEqual(out.components(separatedBy: "[result omitted]").count - 1, 2, "read and grep results are omitted")
        XCTAssertTrue(out.contains("[ran read: ~/.aws/credentials]") && out.contains("[ran bash: ls -la]"), "commands and paths stay")
        XCTAssertTrue(out.contains("harmless-listing") && out.contains("boom: failed head"), "other results keep their heads")
    }
}
