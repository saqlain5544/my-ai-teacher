import XCTest
@testable import MyAITeacher

/// A scripted language server (Python) in a temp folder: framing, the server's own requests, progress, diagnostics by
/// version, a crash and its restart, timeouts, idle stop, the limit of running servers. Then the tool on top of it.
final class LSPTests: XCTestCase {
    var dir: URL!
    var script: URL!
    var logFile: URL!

    static let fake = #"""
    import sys, json, os, time, threading
    log = open(os.environ.get("FAKE_LOG", os.devnull), "a", buffering=1)
    lock = threading.Lock()
    def note(x): log.write(json.dumps(x) + "\n")
    def read():
        headers = {}
        while True:
            line = sys.stdin.buffer.readline()
            if not line: return None
            line = line.strip()
            if not line: break
            k, v = line.decode().split(":", 1); headers[k.lower()] = v.strip()
        return json.loads(sys.stdin.buffer.read(int(headers["content-length"])))
    def send(m, chunks=1):
        b = json.dumps(m).encode()
        data = b"Content-Length: %d\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n" % len(b) + b
        with lock:
            step = max(1, len(data) // chunks)
            for i in range(0, len(data), step):
                sys.stdout.buffer.write(data[i:i+step]); sys.stdout.buffer.flush()
                if chunks > 1: time.sleep(0.05)
    def progress():
        send({"jsonrpc": "2.0", "id": "p1", "method": "window/workDoneProgress/create", "params": {"token": "idx"}})
        send({"jsonrpc": "2.0", "id": 100, "method": "workspace/configuration", "params": {"items": [{"section": "a"}, {"section": "b"}]}})
        send({"jsonrpc": "2.0", "id": 101, "method": "client/registerCapability", "params": {"registrations": []}})
        send({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "idx", "value": {"kind": "begin", "title": "Indexing", "percentage": 10}}})
        time.sleep(0.8)
        send({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "idx", "value": {"kind": "report", "percentage": 60}}})
        time.sleep(0.5)
        send({"jsonrpc": "2.0", "method": "$/progress", "params": {"token": "idx", "value": {"kind": "end"}}})
    docs = {}
    def enc(uri):
        if os.environ.get("FAKE_ENCODE") == "1": return uri.replace("(", "%28").replace(")", "%29").replace("+", "%2B").replace("@", "%40")
        return uri
    def diag(uri, version=None):
        text, doc_version = docs[uri]
        version = doc_version if version is None else version
        send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": enc(uri), "version": version,
              "diagnostics": [{"range": {"start": {"line": 0, "character": 1}, "end": {"line": 0, "character": 2}}, "severity": 1,
                               "message": "v%d:%d" % (version, len(text)), "source": "fake"}]}})
    shut = False
    while True:
        m = read()
        if m is None: break
        note({"in": m.get("method") or "reply", "id": m.get("id"), "result": m.get("result")})
        meth = m.get("method"); p = m.get("params") or {}
        if meth == "initialize":
            for a in sys.argv:
                if a.startswith("--init-delay="): time.sleep(float(a.split("=")[1]))
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"capabilities": {"definitionProvider": True, "hoverProvider": True}, "serverInfo": {"name": "fake-ls", "version": "1"}}})
        elif meth == "initialized":
            if os.environ.get("FAKE_PROGRESS") == "1": threading.Thread(target=progress, daemon=True).start()
        elif meth == "textDocument/didOpen":
            d = p["textDocument"]; docs[d["uri"]] = (d["text"], d["version"]); diag(d["uri"])
        elif meth == "textDocument/didChange":
            d = p["textDocument"]; docs[d["uri"]] = (p["contentChanges"][0]["text"], d["version"]); diag(d["uri"])
            if os.environ.get("FAKE_STALE") == "1": diag(d["uri"], d["version"] - 1)   # a late publish for the text before this one
        elif meth == "textDocument/definition":
            uri = p["textDocument"]["uri"]
            send({"jsonrpc": "2.0", "id": m["id"], "result": [{"targetUri": uri, "targetRange": {"start": {"line": 0, "character": 0}, "end": {"line": 1, "character": 0}},
                  "targetSelectionRange": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 7}}},
                  {"uri": uri, "range": {"start": {"line": 0, "character": 4}, "end": {"line": 0, "character": 7}}}]})
        elif meth == "textDocument/hover":
            send({"jsonrpc": "2.0", "id": m["id"], "result": {"contents": {"kind": "markdown", "value": "**pos** %d:%d" % (p["position"]["line"], p["position"]["character"])}}})
        elif meth == "test/slow": pass
        elif meth == "test/write":
            try:
                open(p["path"], "w").write("changed"); send({"jsonrpc": "2.0", "id": m["id"], "result": "wrote"})
            except Exception as e: send({"jsonrpc": "2.0", "id": m["id"], "result": "denied: %s" % e})
        elif meth == "test/flood":
            for i in range(250):
                send({"jsonrpc": "2.0", "method": "textDocument/publishDiagnostics", "params": {"uri": "file:///flood/f%d.fk" % i, "diagnostics": []}})
            send({"jsonrpc": "2.0", "id": m["id"], "result": "done"})
        elif meth == "test/crash": os._exit(3)
        elif meth == "test/big": send({"jsonrpc": "2.0", "id": m["id"], "result": "x" * 300000}, chunks=4)
        elif meth == "test/split": send({"jsonrpc": "2.0", "id": m["id"], "result": {"ok": True}}, chunks=5)
        elif meth == "test/fail": send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32602, "message": "bad params"}})
        elif meth == "shutdown": shut = True; send({"jsonrpc": "2.0", "id": m["id"], "result": None})
        elif meth == "exit": sys.exit(0 if shut else 1)
        elif "id" in m and meth: send({"jsonrpc": "2.0", "id": m["id"], "error": {"code": -32601, "message": "no"}})
    """#

    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        dir = dir.resolvingSymlinksInPath()
        script = dir.appendingPathComponent("fake_ls.py")
        logFile = dir.appendingPathComponent("received.log")
        try? Self.fake.write(to: script, atomically: true, encoding: .utf8)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Helpers

    func connection(progress: Bool = false, extra: [String: String] = [:]) throws -> LSPConnection {
        var env = ProcessInfo.processInfo.environment
        env["FAKE_LOG"] = logFile.path
        if progress { env["FAKE_PROGRESS"] = "1" }
        for (k, v) in extra { env[k] = v }
        let t = LSPStdioTransport(executable: "/usr/bin/python3", args: ["-I", script.path], env: env, cwd: dir, log: MCPLog())
        let c = LSPConnection(transport: t, root: dir)
        try c.start()
        return c
    }
    func received() -> [[String: Any]] {
        let text = (try? String(contentsOf: logFile, encoding: .utf8)) ?? ""
        return text.split(separator: "\n").compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }
    func methods() -> [String] { received().compactMap { $0["in"] as? String } }
    func waitFor(_ what: String, timeout: TimeInterval = 5, _ cond: @escaping () -> Bool) async {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { try? await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertTrue(cond(), "timed out waiting for \(what)")
    }
    func spec(id: String = "fake", ext: String = "fk") -> LSPServerSpec {
        LSPServerSpec(id: id, title: "Fake LS", binaries: ["fake-ls"], args: ["-I", script.path], languages: [ext: "fake"], extraDirs: [],
                      install: "n/a", executable: "/usr/bin/python3")
    }
    func write(_ rel: String, _ text: String) throws -> URL {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
        return u
    }

    // MARK: Framing

    func testFramingHandlesSplitChunksExtraHeadersAndTwoMessagesAtOnce() {
        var f = LSPFraming()
        let a = #"{"jsonrpc":"2.0","id":1,"result":"é"}"#, b = #"{"jsonrpc":"2.0","method":"x"}"#
        let wire = "Content-Length: \(a.utf8.count)\r\nContent-Type: application/vscode-jsonrpc; charset=utf-8\r\n\r\n\(a)Content-Length: \(b.utf8.count)\r\n\r\n\(b)"
        let bytes = Data(wire.utf8)
        for i in stride(from: 0, to: bytes.count - 7, by: 7) { f.feed(bytes[i..<i + 7]) }
        f.feed(bytes[(bytes.count / 7 * 7)...])
        var got: [JSON] = []
        while let m = f.next() { if let j = m.json { got.append(j) } }
        XCTAssertEqual(got.count, 2)
        XCTAssertEqual(got.first?["result"]?.string, "é", "length is in bytes, not characters")
        XCTAssertEqual(got.last?["method"]?.string, "x")
    }

    func testFramingFailsOnAMessageWithoutLength() {
        var f = LSPFraming()
        f.feed(Data("Garbage: 1\r\n\r\n{}".utf8))
        XCTAssertNil(f.next()); XCTAssertNotNil(f.failure)
    }

    // MARK: Connection

    func testHandshakeAnswersTheServersRequestsAndTracksProgress() async throws {
        let c = try connection(progress: true)
        defer { c.close() }
        let name = try await c.initialize(timeout: 10)
        XCTAssertEqual(name, "fake-ls 1")
        XCTAssertTrue(c.supports("definitionProvider") && !c.supports("renameProvider"))
        await waitFor("progress to start") { c.activity != nil }
        XCTAssertEqual(c.activity?.title, "Indexing")
        XCTAssertEqual(c.activity?.percentage, 10)
        // The replies to the server's requests: one null per configuration item, null for the rest.
        await waitFor("replies logged") { self.received().filter { $0["in"] as? String == "reply" }.count >= 3 }
        let replies = received().filter { $0["in"] as? String == "reply" }
        XCTAssertEqual(replies.first { ($0["id"] as? Int) == 100 }?["result"] as? [NSNull], [NSNull(), NSNull()])
        XCTAssertTrue(replies.contains { ($0["id"] as? String) == "p1" })
        let t0 = Date()
        let still = await c.awaitIdle(0.2)
        XCTAssertNotNil(still, "bounded: it returns while the server is busy")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1)
        let done = await c.awaitIdle(10)
        XCTAssertNil(done, "returns once the progress ends")
    }

    func testDocumentsSyncFromDiskAndDiagnosticsFollowTheVersion() async throws {
        let c = try connection()
        defer { c.close() }
        try await c.initialize(timeout: 10)
        let f = try write("a.fk", "one\n")
        let uri = LSPConnection.uri(f)
        var since = try await c.sync(f, languageId: "fake")
        var p = await c.awaitDiagnostics(uri, since: since, seconds: 5)
        XCTAssertEqual(p?.items.first?["message"]?.string, "v1:4")
        // Nothing changed: no second didOpen, no didChange.
        since = try await c.sync(f, languageId: "fake")
        XCTAssertEqual(methods().filter { $0 == "textDocument/didOpen" }.count, 1)
        XCTAssertEqual(methods().filter { $0 == "textDocument/didChange" }.count, 0)
        // The file was edited behind the server's back (write/edit): the next question sends the new text.
        try "one\ntwo\n".write(to: f, atomically: true, encoding: .utf8)
        since = try await c.sync(f, languageId: "fake")
        p = await c.awaitDiagnostics(uri, since: since, seconds: 5)
        XCTAssertEqual(p?.items.first?["message"]?.string, "v2:8", "not the stale v1 result")
        XCTAssertEqual(c.documentVersion(uri), 2)
        XCTAssertTrue(methods().contains("textDocument/didSave"))
        // A second open file changed on disk is re-sent when another file is asked about; a deleted one is closed.
        let g = try write("b.fk", "b\n")
        _ = try await c.sync(g, languageId: "fake")
        try "bb\n".write(to: g, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: f)
        _ = try await c.sync(try write("c.fk", "c\n"), languageId: "fake")
        await waitFor("didChange for b and didClose for a") {
            self.methods().filter { $0 == "textDocument/didChange" }.count >= 2 && self.methods().contains("textDocument/didClose")
        }
        XCTAssertFalse(c.openDocuments.contains(uri))
    }

    func testRequestsMatchRepliesSplitAndLargeMessagesAndErrors() async throws {
        let c = try connection()
        defer { c.close() }
        try await c.initialize(timeout: 10)
        async let big = c.request("test/big", timeout: 10)
        async let split = c.request("test/split", timeout: 10)
        let (b, s) = try await (big, split)
        XCTAssertEqual(b.string?.count, 300_000)
        XCTAssertEqual(s["ok"]?.bool, true)
        do { _ = try await c.request("test/fail", timeout: 5); XCTFail("expected an error") }
        catch let e as LSPError { XCTAssertTrue(e.message.contains("bad params")); if case .server(let code) = e.kind { XCTAssertEqual(code, -32602) } else { XCTFail() } }
    }

    func testATimeoutAndACancellationTellTheServer() async throws {
        let c = try connection()
        defer { c.close() }
        try await c.initialize(timeout: 10)
        do { _ = try await c.request("test/slow", timeout: 0.3); XCTFail() }
        catch let e as LSPError { if case .timeout = e.kind {} else { XCTFail("\(e)") } }
        await waitFor("$/cancelRequest") { self.methods().contains("$/cancelRequest") }
        let t = Task { try await c.request("test/slow", timeout: 30) }
        try await Task.sleep(nanoseconds: 200_000_000)
        t.cancel()
        do { _ = try await t.value; XCTFail() } catch { XCTAssertTrue(error is CancellationError) }
        await waitFor("a second $/cancelRequest") { self.methods().filter { $0 == "$/cancelRequest" }.count >= 2 }
    }

    func testACrashFailsEveryWaitingCallAndEndsTheLink() async throws {
        let c = try connection()
        try await c.initialize(timeout: 10)
        async let a: JSON = c.request("test/slow", timeout: 30)
        async let b: JSON = c.request("test/crash", timeout: 30)
        for r in [0, 1] {
            do { _ = r == 0 ? try await a : try await b; XCTFail("expected the link to fail") }
            catch let e as LSPError { XCTAssertTrue(e.isClosed, e.message); XCTAssertTrue(e.message.contains("exited with status 3"), e.message) }
        }
        let why = await c.waitClosed()
        XCTAssertTrue(why.contains("status 3"), why)
        do { _ = try await c.request("textDocument/hover"); XCTFail() } catch let e as LSPError { XCTAssertTrue(e.isClosed) }
    }

    func testShutdownThenExitEndsTheProcessCleanly() async throws {
        let c = try connection()
        try await c.initialize(timeout: 10)
        await c.shutdown()
        let why = await c.waitClosed()
        XCTAssertEqual(why, "exited with status 0", "exit after shutdown is status 0")
        XCTAssertEqual(methods().suffix(2), ["shutdown", "exit"])
    }

    // MARK: Supervision

    func testAnInstanceStartsOnFirstUseRestartsAfterACrashAndKeepsItsDocumentsFresh() async throws {
        let hub = LSPHub(specs: [spec()], backoff: Backoff(initial: 0.1, max: 0.2))
        let inst = hub.instance(spec(), executable: "/usr/bin/python3", folder: dir)
        XCTAssertEqual(inst.status.phase, .idle, "nothing starts until it is used")
        XCTAssertTrue(hub.all.allSatisfy { !$0.isRunning })
        defer { Task { await inst.stop() } }
        let c1 = try await inst.connection()
        XCTAssertEqual(inst.status.phase, .ready)
        XCTAssertNotNil(inst.status.pid)
        do { _ = try await c1.request("test/crash", timeout: 10) } catch {}
        // perform() waits through the restart and asks again on the new link.
        let again: String = try await inst.perform { c in
            let r = try await c.request("textDocument/hover", ["textDocument": ["uri": "file:///x"], "position": ["line": 1, "character": 2]], timeout: 10)
            return r["contents"]?["value"]?.string ?? ""
        }
        XCTAssertEqual(again, "**pos** 1:2")
        XCTAssertEqual(inst.status.restarts, 1)
        XCTAssertEqual(inst.status.phase, .ready)
    }

    func testAServerThatCantStartFailsAtOnceWithItsLastWordsAndIsNotRetried() async throws {
        let bad = LSPServerSpec(id: "bad", title: "Bad LS", binaries: [], args: ["-c", "echo 'Unknown binary' >&2; exit 1"], languages: ["fk": "fake"], extraDirs: [], install: "n/a", executable: "/bin/sh")
        let hub = LSPHub(specs: [bad])
        let inst = hub.instance(bad, executable: "/bin/sh", folder: dir)
        let t0 = Date()
        do { _ = try await inst.connection(); XCTFail("expected a failure") }
        catch { XCTAssertTrue(error.localizedDescription.contains("couldn't start") && error.localizedDescription.contains("Unknown binary"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4, "no restarts with backoff for a server that never worked")
        XCTAssertEqual(inst.status.phase, .failed); XCTAssertEqual(inst.status.restarts, 0)
    }

    func testAnIdleServerStopsAndStartsAgainOnNextUse() async throws {
        let hub = LSPHub(specs: [spec()], idleSeconds: 0.8)
        let inst = hub.instance(spec(), executable: "/usr/bin/python3", folder: dir)
        _ = try await inst.connection()
        let pid = inst.status.pid
        await waitFor("the idle stop", timeout: 10) { inst.status.phase == .stopped }
        if let pid { XCTAssertNotEqual(kill(pid, 0), 0, "the process is gone") }
        let c = try await inst.connection()
        XCTAssertEqual(inst.status.phase, .ready); XCTAssertNil(c.closedReason)
        await inst.stop()
    }

    func testNoMoreThanTheLimitRunAndTheLeastRecentlyUsedStops() async throws {
        let hub = LSPHub(specs: [spec()], maxRunning: 2)
        var insts: [LSPInstance] = []
        for n in 0..<3 {
            let folder = dir.appendingPathComponent("p\(n)", isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let i = hub.instance(spec(), executable: "/usr/bin/python3", folder: folder)
            _ = try await i.connection()
            insts.append(i)
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { for i in insts { Task { await i.stop() } } }
        await waitFor("the oldest to stop") { insts[0].status.phase == .stopped }
        XCTAssertEqual(hub.all.filter(\.isRunning).count, 2)
        XCTAssertTrue(insts[1].isRunning && insts[2].isRunning)
    }

    @MainActor func testTheTasksPanelListsAServerAndStopWorks() async throws {
        let sp = spec(id: "fake-panel")
        let inst = LSPHub.shared.instance(sp, executable: "/usr/bin/python3", folder: dir)
        _ = try await inst.connection()
        let t = try XCTUnwrap(BackgroundTasks.snapshot().first { $0.kind == .lsp && $0.id.hasSuffix(":fake-panel") })
        XCTAssertEqual(t.state, .running); XCTAssertNotNil(t.pid); XCTAssertTrue(BackgroundTasks.canStop(t))
        BackgroundTasks.stop(t)
        for _ in 0..<100 where inst.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(inst.status.phase, .stopped)
        XCTAssertEqual(BackgroundTasks.snapshot().first { $0.id == t.id }?.state, .stopped)
    }

    // MARK: The tool

    func ctx(depth: Int = 0, conv: String = "L") async throws -> ToolContext {
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: conv, workspace: dir, services: services, interactions: await MainActor.run { InteractionCenter() }, toolCallID: "c",
                            client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.agentDepth = depth
        return c
    }

    func testTheToolExplainsAMissingServerAndNeverInstallsAnything() async throws {
        _ = try write("x.fk", "x\n")
        let tool = LSPTool(hub: LSPHub(specs: []))
        let none = try await tool.run(["action": "hover", "file": "x.fk", "line": 1, "symbol": "x"], try await ctx())
        XCTAssertTrue(none.isError && none.text.contains("No language server is set up for .fk") && none.text.contains("`code` and `symbols` still work"), none.text)
        var missing = spec(); missing = LSPServerSpec(id: "nope", title: "Nope LS", binaries: ["definitely-not-installed-ls"], args: [], languages: ["fk": "fake"], extraDirs: [], install: "brew install nope-ls")
        let r = try await LSPTool(hub: LSPHub(specs: [missing])).run(["action": "hover", "file": "x.fk", "line": 1, "symbol": "x"], try await ctx())
        XCTAssertTrue(r.isError && r.text.contains("brew install nope-ls") && r.text.contains("never installs"), r.text)
    }

    func testAServerThatIsntApprovedDoesNotStartAndASubAgentIsToldWhy() async throws {
        _ = try write("x.fk", "def foo\n")
        let hub = LSPHub(specs: [spec()])
        let tool = LSPTool(hub: hub)
        let input: JSON = ["action": "hover", "file": "x.fk", "line": 1, "symbol": "foo"]
        let main = try await tool.run(input, try await ctx())
        XCTAssertTrue(main.isError && main.text.contains("isn't approved"), main.text)
        let sub = try await tool.run(input, try await ctx(depth: 1))
        XCTAssertTrue(sub.isError && sub.text.contains("sub-agent can't ask"), sub.text)
        XCTAssertTrue(hub.all.isEmpty && hub.all.allSatisfy { !$0.isRunning }, "no server started for a refused call")
        XCTAssertNotNil(tool.subAgentVariant)
        // A lesson grant from the permission gate counts; so does the process-wide approval of a headless run.
        let c = try await ctx(conv: "G")
        await MainActor.run { c.interactions.grant(LSPHub.grant("fake"), conversationID: "G") }
        let ok = try await tool.run(input, c)
        XCTAssertFalse(ok.isError, ok.text)
        for i in hub.all { await i.stop() }
    }

    func testDefinitionResolvesTheColumnFromTheSymbolAndGroupsResults() async throws {
        _ = try write("x.fk", "def foo(a)\n  foo(1) + foo(2)\n")
        let hub = LSPHub(specs: [spec()])
        hub.approveForProcess(folder: dir)
        defer { Task { for i in hub.all { await i.stop() } } }
        let tool = LSPTool(hub: hub)
        let hover = try await tool.run(["action": "hover", "file": "x.fk", "line": 2, "symbol": "foo", "column": 12], try await ctx())
        XCTAssertFalse(hover.isError, hover.text)
        XCTAssertTrue(hover.text.contains("**pos** 1:11"), "the second foo on the line, by column: \(hover.text)")
        let first = try await tool.run(["action": "hover", "file": "x.fk", "line": 2, "symbol": "foo"], try await ctx())
        XCTAssertTrue(first.text.contains("**pos** 1:2") && first.text.contains("appears 2 times"), first.text)
        // LocationLink and Location to the same place are one result, with the source line.
        let def = try await tool.run(["action": "definition", "file": "x.fk", "line": 1, "symbol": "foo"], try await ctx())
        XCTAssertTrue(def.text.hasPrefix("1 definition of `foo`:\nx.fk:1  def foo(a)"), def.text)
        // A line number a bit off still finds the symbol.
        let off = try await tool.run(["action": "definition", "file": "x.fk", "line": 2, "symbol": "a"], try await ctx())
        XCTAssertTrue(off.text.contains("found it on line 1"), off.text)
        let bad = try await tool.run(["action": "definition", "file": "x.fk", "line": 1, "symbol": "zzz"], try await ctx())
        XCTAssertTrue(bad.isError && bad.text.contains("isn't on line 1"), bad.text)
        XCTAssertEqual(def.meta?["server"]?.string, "fake")
    }

    func testResultsAreFreshAfterTheFileIsEditedByTheAgent() async throws {
        let f = try write("y.fk", "def foo\n")
        let hub = LSPHub(specs: [spec()])
        hub.approveForProcess(folder: dir)
        defer { Task { for i in hub.all { await i.stop() } } }
        let tool = LSPTool(hub: hub)
        let a = try await tool.run(["action": "diagnostics", "file": "y.fk"], try await ctx())
        XCTAssertTrue(a.text.contains("v1:8") && a.text.contains("1 error"), a.text)
        // `edit`/`write` change the file; nothing tells the tool, the stamp check does.
        let before = f
        _ = try await EditTool().run(["path": "y.fk", "old_string": "def foo", "new_string": "def foobar"], try await ctx())
        let b = try await tool.run(["action": "diagnostics", "file": "y.fk"], try await ctx())
        XCTAssertTrue(b.text.contains("v2:11"), b.text)
        _ = before
    }


    // MARK: Review findings

    func testDiagnosticsOnAnUnchangedOpenFileAnswerAtOnceAndKeepTheirErrors() async throws {
        _ = try write("u.fk", "def foo\n")
        let hub = LSPHub(specs: [spec()])
        hub.approveForProcess(folder: dir)
        defer { Task { for i in hub.all { await i.stop() } } }
        let tool = LSPTool(hub: hub)
        // A hover opens the file (the server publishes then); diagnostics on the unchanged file is not "nothing published".
        _ = try await tool.run(["action": "hover", "file": "u.fk", "line": 1, "symbol": "foo"], try await ctx())
        try await Task.sleep(nanoseconds: 300_000_000)
        for n in 1...2 {   // twice in a row: the second is unchanged too
            let t0 = Date()
            let d = try await tool.run(["action": "diagnostics", "file": "u.fk"], try await ctx())
            XCTAssertLessThan(Date().timeIntervalSince(t0), 4, "call \(n) must not wait out the 10 s for a publish that already happened")
            XCTAssertTrue(d.text.contains("1 error") && d.text.contains("v1:8"), d.text)
        }
    }

    func testPublishesAreFoundWhateverWayTheServerEncodesThePath() async throws {
        let odd = dir.appendingPathComponent("p(1)+x@y", isDirectory: true)
        try FileManager.default.createDirectory(at: odd, withIntermediateDirectories: true)
        let f = odd.appendingPathComponent("a.fk")
        try "x\n".write(to: f, atomically: true, encoding: .utf8)
        let c = try connection(extra: ["FAKE_ENCODE": "1"])
        defer { c.close() }
        try await c.initialize(timeout: 10)
        let since = try await c.sync(f, languageId: "fake")
        let p = await c.awaitDiagnostics(LSPConnection.uri(f), since: since, seconds: 5)
        XCTAssertEqual(p?.items.first?["message"]?.string, "v1:2", "the server wrote %28 %29 %2B %40; we look up the same file")
        XCTAssertEqual(LSPConnection.normalized(f.absoluteString.replacingOccurrences(of: "(", with: "%28")), LSPConnection.uri(f))
    }

    func testALatePublishForOlderTextIsIgnored() async throws {
        let c = try connection(extra: ["FAKE_STALE": "1"])
        defer { c.close() }
        try await c.initialize(timeout: 10)
        let f = try write("s.fk", "one\n")
        var since = try await c.sync(f, languageId: "fake")
        _ = await c.awaitDiagnostics(LSPConnection.uri(f), since: since, seconds: 5)
        try "one\ntwo\n".write(to: f, atomically: true, encoding: .utf8)
        since = try await c.sync(f, languageId: "fake")
        let p = await c.awaitDiagnostics(LSPConnection.uri(f), since: since, seconds: 5)
        try await Task.sleep(nanoseconds: 400_000_000)   // the stale one has certainly arrived
        XCTAssertEqual(c.published(LSPConnection.uri(f))?.items.first?["message"]?.string, "v2:8", "kept the publish for the current text")
        XCTAssertEqual(p?.version, 2)
    }

    func testStopPressedDuringACallEndsItAndStaysStopped() async throws {
        let hub = LSPHub(specs: [spec()], backoff: Backoff(initial: 0.1, max: 0.2))
        let inst = hub.instance(spec(), executable: "/usr/bin/python3", folder: dir)
        _ = try await inst.connection()
        let call = Task { () -> String in
            do { _ = try await inst.perform { c in try await c.request("test/slow", timeout: 30) }; return "finished" }
            catch { return error.localizedDescription }
        }
        try await Task.sleep(nanoseconds: 400_000_000)
        await inst.stop()   // the Tasks panel's Stop
        let outcome = await call.value
        XCTAssertTrue(outcome.contains("was stopped") && outcome.contains("Stop"), outcome)
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(inst.status.phase, .stopped, "not started again behind the learner's back")
        XCTAssertFalse(inst.isRunning)
        // A later call is a new use: it starts it.
        let c = try await inst.connection()
        XCTAssertNil(c.closedReason)
        await inst.stop()
    }

    func testQuittingWhileAServerIsStillStartingEndsItsProcess() async throws {
        let slow = LSPServerSpec(id: "slow", title: "Slow LS", binaries: [], args: ["-I", script.path, "--init-delay=30"], languages: ["fk": "fake"], extraDirs: [], install: "n/a", executable: "/usr/bin/python3")
        let hub = LSPHub(specs: [slow])
        let inst = hub.instance(slow, executable: "/usr/bin/python3", folder: dir)
        let starting = Task { try? await inst.connection(timeout: 20) }
        var pid: Int32?
        for _ in 0..<60 where pid == nil { try await Task.sleep(nanoseconds: 100_000_000); pid = inst.status.pid }
        let p = try XCTUnwrap(pid, "the child is known from launch, not only once initialize answers")
        XCTAssertEqual(kill(p, 0), 0)
        hub.shutdownNow()
        try await Task.sleep(nanoseconds: 800_000_000)
        XCTAssertNotEqual(kill(p, 0), 0, "quitting ended the child while it was initialising")
        starting.cancel()
    }

    func testTheServerRunsUnderTheMentorsWriteFence() async throws {
        try XCTSkipUnless(WriteFence.available, "no sandbox-exec")
        let learner = try write("learner.txt", "mine\n")
        let fence = WriteFence.profile(files: [learner], locked: [], open: [])
        let hub = LSPHub(specs: [spec()])
        let inst = hub.instance(spec(), executable: "/usr/bin/python3", folder: dir, fence: fence)
        defer { Task { await inst.stop() } }
        let denied: String = try await inst.perform { c in try await c.request("test/write", ["path": .string(learner.path)], timeout: 10).string ?? "" }
        XCTAssertTrue(denied.hasPrefix("denied"), denied)
        XCTAssertEqual(try String(contentsOf: learner, encoding: .utf8), "mine\n")
        let fresh = dir.appendingPathComponent("build-output.txt")
        let ok: String = try await inst.perform { c in try await c.request("test/write", ["path": .string(fresh.path)], timeout: 10).string ?? "" }
        XCTAssertEqual(ok, "wrote", "everything the fence doesn't name stays writable")
        // The fence changing (the project passed, its tests unlocked) replaces the server instead of leaving the old protection running.
        let other = hub.instance(spec(), executable: "/usr/bin/python3", folder: dir, fence: nil)
        XCTAssertFalse(other === inst)
        for _ in 0..<60 where inst.isRunning { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertFalse(inst.isRunning)
        await other.stop()
    }

    func testTheToolFencesAServerOnlyWhileAProjectIsOpen() async throws {
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g2.sqlite").path)), workspace: try Workspace(url: dir))
        XCTAssertNil(LSPTool.fence(for: services.workspace), "no project: unfenced")
        _ = try write("app.py", "x = 1\n")
        var p = MentorProject(); p.title = "t"; p.concept = "c"; p.testCommand = "true"
        ProjectStore.save(p, services.workspace); ProjectStore.snapshot(services.workspace, why: "baseline")
        let fence = try XCTUnwrap(LSPTool.fence(for: services.workspace), "a project is open")
        XCTAssertEqual(fence, MentorGuard.fence(services.workspace), "the profile the mentor's own commands get")
        XCTAssertTrue(fence.contains("app.py"))
    }

    func testBigFilesAreRefusedAndPublishedDiagnosticsAreBounded() async throws {
        let big = try write("big.fk", String(repeating: "x", count: LSPConnection.maxFileBytes + 10))
        let hub = LSPHub(specs: [spec()])
        hub.approveForProcess(folder: dir)
        defer { Task { for i in hub.all { await i.stop() } } }
        let r = try await LSPTool(hub: hub).run(["action": "hover", "file": "big.fk", "line": 1, "symbol": "x"], try await ctx())
        XCTAssertTrue(r.isError && r.text.contains("too large"), r.text)
        _ = big
        let c = try connection()
        defer { c.close() }
        try await c.initialize(timeout: 10)
        _ = try await c.request("test/flood", timeout: 20)
        XCTAssertLessThanOrEqual(c.allPublished().count, LSPConnection.maxPublished)
    }

    func testRenamePreviewSaysWhenItStoppedListing() throws {
        let f = try write("many.fk", (0..<30).map { "foo \($0)" }.joined(separator: "\n"))
        let edits: [JSON] = (0..<30).map { ["range": ["start": ["line": .number(Double($0)), "character": 0], "end": ["line": .number(Double($0)), "character": 3]], "newText": "bar"] }
        let out = LSPFormat(folder: dir, limit: 5).renamePreview(["changes": [f.absoluteString: .array(edits)]], from: "foo", to: "bar", prefix: "")
        XCTAssertTrue(out.text.contains("30 edits"), out.text)
        XCTAssertTrue(out.text.contains("… and 25 more edits"), out.text)
    }

    // The permission gate: no approval asks; the answers store what they say.
    @MainActor func testTheGateAsksOnceStoresTheAnswerAndRemembersADecline() async throws {
        _ = try write("g.fk", "x\n")
        let hub = LSPHub(specs: [spec()])
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g3.sqlite").path)), workspace: try Workspace(url: dir))
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let gate = PermissionExtension(app: AppModel.shared)
        gate.lspHub = hub
        let tool = LSPTool(hub: hub)
        let call = Block.toolUse(id: "g1", name: "lsp", input: ["action": "hover", "file": "g.fk", "line": 1, "symbol": "x"])
        func decide() async -> ToolDecision {
            let d = gate.shouldRun(call, tool: tool, session: session)
            if case .pending(let f) = d { return await f() }
            return d
        }
        AppModel.shared.settings.value.lspApproved = [:]
        let folder = LSPTool.canonical(dir).path
        guard case .ask(let req, let resolve) = await decide() else { return XCTFail("the first use in a folder asks") }
        XCTAssertTrue(req.title.contains("Fake LS") && req.title.contains("language server"), req.title)
        XCTAssertEqual(req.options.map(\.id), ["folder", "lesson", "deny"])
        guard case .allow = resolve("lesson") else { return XCTFail() }
        XCTAssertNil(AppModel.shared.settings.value.lspApproved[folder], "a lesson grant isn't stored in the settings")
        guard case .allow = await decide() else { return XCTFail("allowed for this lesson") }
        // A different lesson isn't covered by it.
        var other = Conversation(providerID: "x", model: "m"); other.mode = .code
        let session2 = ChatSession(conversation: other, app: AppModel.shared, services: services)
        let d2 = gate.shouldRun(call, tool: tool, session: session2)
        guard case .pending(let f2) = d2, case .ask(_, let resolve2) = await f2() else { return XCTFail("another lesson asks again") }
        guard case .allow = resolve2("folder") else { return XCTFail() }
        XCTAssertEqual(AppModel.shared.settings.value.lspApproved[folder], ["fake"], "stored in the app's settings, not the folder")
        guard case .allow = await decide() else { return XCTFail("approved for the folder") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".teacher/lsp").path))
        // A decline holds for the lesson.
        AppModel.shared.settings.value.lspApproved = [:]
        var third = Conversation(providerID: "x", model: "m"); third.mode = .code
        let session3 = ChatSession(conversation: third, app: AppModel.shared, services: services)
        func decide3() async -> ToolDecision { if case .pending(let f) = gate.shouldRun(call, tool: tool, session: session3) { return await f() } else { return .allow } }
        guard case .ask(_, let resolve3) = await decide3() else { return XCTFail() }
        guard case .deny = resolve3("deny") else { return XCTFail("declined") }
        guard case .deny(let why) = await decide3() else { return XCTFail("a decline holds for the lesson") }
        XCTAssertTrue(why.contains("symbols"), why)
        // The sub-agent: the tool itself refuses without an approval, and takes the folder's stored one.
        let sub = try await tool.run(["action": "hover", "file": "g.fk", "line": 1, "symbol": "x"], try await ctx(depth: 1, conv: "sub-no"))
        XCTAssertTrue(sub.isError && sub.text.contains("sub-agent can't ask"), sub.text)
        AppModel.shared.settings.value.lspApproved = [:]
    }

    // MARK: Positions and output

    func testPositionResolution() throws {
        let lines = ["let x = fooBar(1)", "  fooBar(fooBar(2))", "héllo foo", "", "a::b::c()"]
        func at(_ l: Int, _ s: String?, _ c: Int? = nil) throws -> LSPPosition { try LSPPosition.resolve(lines: lines, line: l, symbol: s, column: c).get() }
        XCTAssertEqual(try at(1, "fooBar").character, 8)
        XCTAssertEqual(try at(1, "foo").line, 2, "a whole word, so not inside fooBar: the nearest line that has it")
        XCTAssertEqual(try at(2, "fooBar", 10).character, 9, "the occurrence nearest the column")
        XCTAssertEqual(try at(3, "foo").character, 6, "UTF-16 offset after the é")
        XCTAssertEqual(try at(5, "a::b::c").character, 6, "qualified: the cursor goes on the last name")
        XCTAssertEqual(try at(1, nil, 9).symbol, "fooBar")
        XCTAssertThrowsError(try at(1, "nothere"))
        XCTAssertThrowsError(try at(99, "x"))
        XCTAssertThrowsError(try at(1, nil))
    }

    func testRenamePreviewListsEditsAndAppliesNothing() throws {
        let f = try write("r.fk", "foo(1)\nlet foo = foo + 1\n")
        let fmt = LSPFormat(folder: dir)
        let uri = f.absoluteString
        let edit: JSON = ["changes": [uri: [
            ["range": ["start": ["line": 0, "character": 0], "end": ["line": 0, "character": 3]], "newText": "bar"],
            ["range": ["start": ["line": 1, "character": 4], "end": ["line": 1, "character": 7]], "newText": "bar"],
            ["range": ["start": ["line": 1, "character": 10], "end": ["line": 1, "character": 13]], "newText": "bar"]]]]
        let out = fmt.renamePreview(edit, from: "foo", to: "bar", prefix: "")
        XCTAssertTrue(out.text.contains("3 edits in 1 file (nothing was applied)"), out.text)
        XCTAssertTrue(out.text.contains("r.fk:2  - let foo = foo + 1\n    + let bar = bar + 1"), out.text)
        XCTAssertEqual(try String(contentsOf: f, encoding: .utf8), "foo(1)\nlet foo = foo + 1\n")
    }

    func testLocationsAreGroupedSortedDedupedAndCapped() throws {
        let f = try write("l.fk", (1...60).map { "line \($0)" }.joined(separator: "\n"))
        let locs: [JSON] = (1...50).reversed().map { ["uri": .string(f.absoluteString), "range": ["start": ["line": .number(Double($0)), "character": 0], "end": ["line": .number(Double($0)), "character": 1]]] }
        let out = LSPFormat(folder: dir, limit: 5).locationsResult(.array(locs + [locs[0]]), headline: { "\($0) things" }, empty: "none")
        let lines = out.text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines[0], "50 things:")
        XCTAssertEqual(lines[1], "l.fk:2  line 2", "sorted, relative, with the source line")
        XCTAssertEqual(lines.count, 7)
        XCTAssertTrue(lines.last!.hasPrefix("… and 45 more"))
        XCTAssertEqual(LSPFormat.hoverText(["contents": [["language": "go", "value": "var s Shape"], "docs"]]), "```go\nvar s Shape\n```\n\ndocs")
    }

    // MARK: Wiring

    func testTheToolIsDeferredForTheCodeMentorOnlyAndItsGateIsAnApprovalNotAnAllow() {
        XCTAssertTrue(AgentTree.deferred("code-mentor").contains("lsp"))
        XCTAssertFalse(AgentTree.deferred("tutor").contains("lsp") || AgentTree.core("code-mentor").contains("lsp"))
        XCTAssertNotNil(ToolRegistry.byName["lsp"]); XCTAssertNotNil(ToolRegistry.subagentPool.first { $0.name == "lsp" })
        var s = AppSettings(); s.lspApproved["/f"] = ["gopls"]
        let again = try? JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(s))
        XCTAssertEqual(again?.lspApproved["/f"], ["gopls"])
        XCTAssertEqual((try? JSONDecoder().decode(AppSettings.self, from: Data("{}".utf8)))?.lspApproved, [:], "older settings files decode")
    }

    func testTheRegistryFindsServersByExtensionAndSaysWhatToInstall() {
        XCTAssertEqual(LSPServers.builtIn.filter { $0.languages["py"] != nil }.map(\.id), ["pyright", "pylsp"])
        for ext in ["rs", "go", "swift", "ts", "c", "cpp", "zig", "py"] { XCTAssertFalse(LSPServers.builtIn.filter { $0.languages[ext] != nil }.isEmpty, ext) }
        let u = LSPUnavailable(ext: "py", candidates: LSPServers.builtIn.filter { $0.languages["py"] != nil })
        XCTAssertTrue(u.message.contains("pyright") && u.message.contains("npm install -g pyright") && u.message.contains("python-lsp-server") && u.message.contains("never installs"))
        XCTAssertTrue(LSPUnavailable(ext: "lua", candidates: []).message.contains("`code` and `symbols` still work"))
        XCTAssertEqual(LSPTool.extensionFor(["language": "rust"], folder: dir, hub: LSPHub()), "rs")
        XCTAssertEqual(LSPTool.extensionFor(["language": "typescript"], folder: dir, hub: LSPHub()), "ts")
    }
}

/// Real servers on tiny temp projects. Skipped where the server isn't installed.
final class LSPRealServerTests: XCTestCase {
    var dir: URL!
    override func setUp() {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lsp-real-\(UUID().uuidString.prefix(8))", isDirectory: true).resolvingSymlinksInPath()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func run(_ hub: LSPHub, _ input: JSON) async throws -> ToolOutput {
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        let ctx = ToolContext(conversationID: "R", workspace: dir, services: services, interactions: await MainActor.run { InteractionCenter() }, toolCallID: "c",
                              client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        return try await LSPTool(hub: hub).run(input, ctx)
    }
    func hub(_ id: String) throws -> LSPHub {
        let spec = try XCTUnwrap(LSPServers.spec(id: id))
        try XCTSkipIf(LSPServers.executable(spec) == nil, "\(id) isn't installed")
        let h = LSPHub()
        h.approveForProcess(folder: dir)
        return h
    }
    func finish(_ h: LSPHub) async { for i in h.all { await i.stop() } }

    func testGopls() async throws {
        let h = try hub("gopls"); defer { Task { await finish(h) } }
        try write("go.mod", "module example.com/demo\n\ngo 1.21\n")
        try write("main.go", "package main\n\ntype Shape interface{ Area() float64 }\n\ntype Rect struct{ W, H float64 }\n\nfunc (r Rect) Area() float64 { return r.W * r.H }\n\nfunc total(s []Shape) float64 {\n\tt := 0.0\n\tfor _, x := range s {\n\t\tt += x.Area()\n\t}\n\treturn t\n}\n")
        let refs = try await run(h, ["action": "references", "file": "main.go", "line": 9, "symbol": "total"])
        XCTAssertFalse(refs.isError, refs.text); XCTAssertTrue(refs.text.contains("main.go:9  func total"), refs.text)
        let impl = try await run(h, ["action": "implementation", "file": "main.go", "line": 3, "symbol": "Area"])
        XCTAssertTrue(impl.text.contains("main.go:7  func (r Rect) Area"), impl.text)
        let type = try await run(h, ["action": "type_definition", "file": "main.go", "line": 11, "symbol": "x"])
        XCTAssertTrue(type.text.contains("main.go:3  type Shape"), type.text)
        try write("bad.go", "package main\n\nfunc bad() int { return \"x\" }\n")
        let d = try await run(h, ["action": "diagnostics", "file": "bad.go"])
        XCTAssertTrue(d.text.contains("1 error") && d.text.contains("bad.go:3"), d.text)
        // The file is fixed on disk: the next answer is not the stale error.
        try write("bad.go", "package main\n\nfunc bad() int { return 1 }\n")
        let fixed = try await run(h, ["action": "diagnostics", "file": "bad.go"])
        XCTAssertTrue(fixed.text.contains("0 errors") || fixed.text.contains("no problems"), fixed.text)
    }

    func testClangd() async throws {
        let h = try hub("clangd"); defer { Task { await finish(h) } }
        try write("compile_flags.txt", "-std=c11\n")
        try write("util.h", "int twice(int x);\n")
        try write("util.c", "#include \"util.h\"\nint twice(int x) { return x * 2; }\n")
        try write("main.c", "#include \"util.h\"\nint main(void) {\n  return twice(21);\n}\n")
        let def = try await run(h, ["action": "definition", "file": "main.c", "line": 3, "symbol": "twice"])
        XCTAssertFalse(def.isError, def.text); XCTAssertTrue(def.text.contains("util.h:1") || def.text.contains("util.c:2"), def.text)
        let refs = try await run(h, ["action": "references", "file": "main.c", "line": 3, "symbol": "twice"])
        XCTAssertTrue(refs.text.contains("main.c:3"), refs.text)
        try write("err.c", "int f(void) { return undefined_name; }\n")
        let d = try await run(h, ["action": "diagnostics", "file": "err.c"])
        XCTAssertTrue(d.text.contains("undefined_name") || d.text.contains("undeclared"), d.text)
    }

    func testSourceKitLSP() async throws {
        let h = try hub("sourcekit-lsp"); defer { Task { await finish(h) } }
        try write("Package.swift", "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Demo\", targets: [.executableTarget(name: \"Demo\", path: \"Sources/Demo\")])\n")
        try write("Sources/Demo/Shapes.swift", "protocol Shape { func area() -> Double }\nstruct Rect: Shape {\n    var w = 1.0, h = 2.0\n    func area() -> Double { w * h }\n}\n")
        try write("Sources/Demo/main.swift", "func total(_ s: [Shape]) -> Double { s.reduce(0) { $0 + $1.area() } }\nprint(total([Rect()]))\n")
        let def = try await run(h, ["action": "definition", "file": "Sources/Demo/main.swift", "line": 2, "symbol": "total"])
        XCTAssertFalse(def.isError, def.text); XCTAssertTrue(def.text.contains("main.swift:1"), def.text)
        let syms = try await run(h, ["action": "document_symbols", "file": "Sources/Demo/Shapes.swift"])
        XCTAssertTrue(syms.text.contains("Rect") && syms.text.contains("area"), syms.text)
        try write("Sources/Demo/Bad.swift", "let x: Int = \"no\"\n")
        let d = try await run(h, ["action": "diagnostics", "file": "Sources/Demo/Bad.swift"])
        XCTAssertTrue(d.text.contains("error"), d.text)
    }
}
