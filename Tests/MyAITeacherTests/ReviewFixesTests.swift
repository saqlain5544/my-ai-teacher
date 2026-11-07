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

    @MainActor func testADebugSessionEndedByTheFenceGrowingNamesTheCredentialSetting() async throws {
        try XCTSkipUnless(WriteFence.available, "no sandbox-exec")
        let driver = root.appendingPathComponent("idle2.py")
        try "import time\ntime.sleep(120)\n".write(to: driver, atomically: true, encoding: .utf8)
        let ws = try Workspace(url: root.appendingPathComponent("df", isDirectory: true))
        let services = Services(global: GlobalStore(db: try Database(path: root.appendingPathComponent("gf.sqlite").path)), workspace: ws)
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        let ctx = ToolContext(conversationID: "FENCE", workspace: ws.url, services: services, interactions: InteractionCenter(), toolCallID: "c",
                              client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        let proc = try DebugProcess(driver: driver, lldbPython: "", cwd: root)
        let session = DebugSession(conversationID: "FENCE", proc: proc, tmp: root.appendingPathComponent("tmp-f"), program: "./demo", fence: "")   // started with no protection
        _ = DebugSessions.shared.set(session)
        defer { DebugSessions.shared.killAll() }
        let saved = Secrets.current.protectCredentials
        defer { Secrets.update { $0.protectCredentials = saved } }
        Secrets.update { $0.protectCredentials = true }
        let out = try await WriteFence.$profile.withValue(WriteFence.guarded(nil)) { try await DebugTool().run(["action": "step"], ctx) }
        XCTAssertTrue(out.isError && out.text.contains("Commands can't read credential folders"), out.text)
        XCTAssertNil(DebugSessions.shared.session("FENCE"), "and it ended")
    }

    // MARK: The sandbox hint

    func testTheHintFollowsWhichFenceIsOnAndSwiftCommandsAreFlaggedForEither() async throws {
        try XCTSkipUnless(WriteFence.available, "no sandbox-exec")
        let saved = Secrets.current.protectCredentials
        defer { Secrets.update { $0.protectCredentials = saved } }
        let err = "error: sandbox_apply: Operation not permitted"
        let plain = root.appendingPathComponent("plain", isDirectory: true), project = root.appendingPathComponent("proj", isDirectory: true)
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let ws = try Workspace(url: project)
        try "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"x\")\n".write(to: project.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        var p = MentorProject(); p.title = "t"; p.concept = "c"; p.testCommand = "true"
        ProjectStore.save(p, ws); ProjectStore.snapshot(ws, why: "baseline")
        XCTAssertTrue(ProjectProfile.mentorFenceOpen(project)); XCTAssertFalse(ProjectProfile.mentorFenceOpen(plain))
        Secrets.update { $0.protectCredentials = true }
        let credentialsOnly = try XCTUnwrap(Secrets.hint(for: err, folder: plain))
        XCTAssertTrue(credentialsOnly.contains("Settings") && !credentialsOnly.contains("mentor"), credentialsOnly)
        let both = try XCTUnwrap(Secrets.hint(for: err, folder: project))
        XCTAssertTrue(both.contains("Settings") && both.contains("mentor's write fence is on for this folder too"), both)
        Secrets.update { $0.protectCredentials = false }
        let mentorOnly = try XCTUnwrap(Secrets.hint(for: err, folder: project))
        XCTAssertTrue(mentorOnly.contains("mentor's write fence") && !mentorOnly.contains("Settings"), "the switch is off: it must not be blamed: " + mentorOnly)
        // Swift commands carry the flag for either fence.
        let mentorProfile = await ProjectProfile.detect(project)
        XCTAssertEqual(mentorProfile.commands.test.first, "swift test --disable-sandbox", "a mentor project's fence alone needs it")
        let none = await ProjectProfile.detect(plain.appendingPathComponent("."))
        XCTAssertNotEqual(none.commands.test.first, "swift test --disable-sandbox")
        // A background job's report carries it too.
        let job = try ShellJob(command: "swift build", title: "t", conversationID: "c", shell: "/bin/sh", script: "echo '\(err)'", cwd: project, env: ["PATH": "/usr/bin:/bin"])
        for _ in 0..<100 where job.isRunning { try await Task.sleep(for: .milliseconds(50)) }
        try await Task.sleep(for: .milliseconds(200))
        let report = ShellJobs.finishedMessage(job, handle: "B1").blocks.first?.text ?? ""
        XCTAssertTrue(report.contains("[Hint:") && report.contains("--disable-sandbox"), report)
    }

    // MARK: coverage

    func testCoverageWithNoFilesSaysWhyAndSwiftCarriesTheSandboxFlagUnderAFence() {
        var r = Coverage.Report(); r.tool = "swift test --enable-code-coverage"
        r.note = "swift test produced no coverage JSON (the tests may not build)."
        r.output = "error: sandbox_apply: Operation not permitted\nerror: manifest could not be loaded"
        let text = Coverage.render(r)
        XCTAssertTrue(text.contains("[Hint:") && text.contains("--disable-sandbox"), text)
        XCTAssertTrue(text.contains("manifest could not be loaded"), "the end of the output too")
        r.output = "error: cannot find 'foo' in scope"
        XCTAssertTrue(Coverage.render(r).contains("cannot find 'foo' in scope"), "no hint: the output tail")
        r.output = ""
        XCTAssertEqual(Coverage.render(r), r.note, "nothing to add")
        let fenced = Coverage.swiftCommands("swift test --filter CalcTests", fenced: true)
        XCTAssertEqual(fenced.run, "swift test --enable-code-coverage --disable-sandbox --filter CalcTests")
        XCTAssertEqual(fenced.path, "swift test --show-codecov-path --disable-sandbox")
        XCTAssertEqual(Coverage.swiftCommands("swift test --disable-sandbox", fenced: true).run, "swift test --enable-code-coverage --disable-sandbox")
        let open = Coverage.swiftCommands("swift test", fenced: false)
        XCTAssertEqual(open.run, "swift test --enable-code-coverage"); XCTAssertEqual(open.path, "swift test --show-codecov-path")
    }

    // MARK: A folder's own state

    func testAFolderWhoseTeacherStateIsCommittedToGitIsNotTrusted() throws {
        func git(_ dir: URL, _ args: [String]) throws {
            let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/git"); p.currentDirectoryURL = dir
            p.arguments = ["-c", "user.name=t", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"] + args
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
        }
        func folder(_ name: String) throws -> URL {
            let dir = root.appendingPathComponent(name, isDirectory: true)
            let ws = try Workspace(url: dir)
            var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
            ws.conversations.save(conv)
            return dir
        }
        let mine = try folder("mine"), forged = try folder("forged")
        try git(mine, ["init", "-q"])   // a repository, `.teacher` not committed
        XCTAssertTrue(EngineerStore.ranCodeMentor(mine.path), "the learner's own state in a repository is fine")
        try git(forged, ["init", "-q"])
        // The repository's own config tries to run a program on any index-reading command.
        let marker = root.appendingPathComponent("fsmonitor-ran")
        let hook = root.appendingPathComponent("fsm.sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try git(forged, ["config", "core.fsmonitor", hook.path])
        try git(forged, ["add", "-f", ".teacher/state.sqlite"])   // (this unhardened call may run it: the check is for the app's)
        try? FileManager.default.removeItem(at: marker)
        XCTAssertFalse(EngineerStore.ranCodeMentor(forged.path), "its state came with the repository")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "and git ran without the repository's fsmonitor")
        // Not a repository at all: unchanged.
        let plain = try folder("plain")
        XCTAssertTrue(EngineerStore.ranCodeMentor(plain.path))
    }

    // MARK: Open debugging sessions

    @MainActor func testAnOpenDebugSessionIsListedStoppableKeptInTheSummaryFactsAndReapedByATimer() async throws {
        let driver = root.appendingPathComponent("idle.py")
        try "import time\ntime.sleep(120)\n".write(to: driver, atomically: true, encoding: .utf8)
        let ws = try Workspace(url: root.appendingPathComponent("d", isDirectory: true))
        let services = Services(global: GlobalStore(db: try Database(path: root.appendingPathComponent("gd.sqlite").path)), workspace: ws)
        let chat = ChatSession(conversation: Conversation(providerID: "x", model: "m"), app: AppModel.shared, services: services)
        func open(_ conv: String) throws -> DebugSession {
            let proc = try DebugProcess(driver: driver, lldbPython: "", cwd: root)
            return DebugSession(conversationID: conv, proc: proc, tmp: root.appendingPathComponent("tmp-\(conv)"), program: "./demo", fence: "")
        }
        let sessions = DebugSessions.shared
        defer { sessions.killAll(); sessions.idle = DebugSessions.idleSeconds; sessions.reapEvery = 60 }
        let s = try open(chat.id)
        _ = sessions.set(s)
        let task = try XCTUnwrap(BackgroundTasks.snapshot().first { $0.kind == .debug }, "listed in the Tasks panel")
        XCTAssertEqual(task.conversationID, chat.id); XCTAssertTrue(task.state.active); XCTAssertTrue(task.title.contains("./demo"))
        XCTAssertTrue(BackgroundTasks.canStop(task))
        XCTAssertTrue(chat.contextFacts(state: "").running.contains { $0.hasPrefix("debug") }, "kept in the summary's running work: \(chat.contextFacts(state: "").running)")
        BackgroundTasks.stop(task)   // Stop
        XCTAssertNil(sessions.session(chat.id))
        XCTAssertFalse(BackgroundTasks.snapshot().contains { $0.kind == .debug })
        // Nobody calls debug again: the timer ends an abandoned session.
        sessions.idle = 0.2; sessions.reapEvery = 0.1
        let idle = try open("idle-lesson")
        _ = sessions.set(idle)
        for _ in 0..<60 where sessions.session("idle-lesson") != nil { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNil(sessions.session("idle-lesson"), "reaped without another debug call")
        let pid = idle.proc.pid
        for _ in 0..<40 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 100_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "and its debugger process is gone")
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
