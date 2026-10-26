import XCTest
@testable import MyAITeacher

/// MCP client support for the code agent: `.mcp.json` and app-level servers, the JSON-RPC client over stdio and
/// streamable HTTP (against tiny fake servers written in Python here), supervision (restart after a crash, a limit,
/// ending with the app), deferred `mcp__<server>__<tool>` tools, project servers' approval, the permission gate's
/// per-server "always allow", and plan mode's read-only rule.
final class MCPTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var saved: AppSettings!

    /// A stdio MCP server: pages of tools, text/structured/error/image results, progress, a crash, a request of its
    /// own (roots/list) answered by the client, and stderr. Each start appends a line to $FAKE_STARTS.
    static let fakeServer = #"""
    import json, os, sys, time
    if os.environ.get("FAKE_STARTS"):
        with open(os.environ["FAKE_STARTS"], "a") as f: f.write("start\n")
    sys.stderr.write("fake server starting\n"); sys.stderr.flush()
    def send(m): sys.stdout.write(json.dumps(m) + "\n"); sys.stdout.flush()
    def text(t, err=False): return {"content": [{"type": "text", "text": t}], "isError": err}
    obj = {"type": "object", "properties": {}}
    page1 = [{"name": "echo", "description": "Echo the text back. More words here.", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}, "required": ["text"]}},
             {"name": "add", "description": "Add two numbers", "inputSchema": {"$schema": "http://json-schema.org/draft-07/schema#", "type": "object", "properties": {"a": {"type": "number"}, "b": {"type": "number"}}}}]
    page2 = [{"name": "fail", "description": "Always fails", "inputSchema": obj},
             {"name": "crash", "description": "Exits without replying", "inputSchema": obj},
             {"name": "slow", "description": "Reports progress", "inputSchema": obj},
             {"name": "peek", "description": "Looks at nothing", "inputSchema": obj, "annotations": {"readOnlyHint": True}},
             {"name": "roots", "description": "Asks the client for its roots", "inputSchema": obj},
             {"name": "image", "description": "A one-pixel image", "inputSchema": obj},
             {"name": "env", "description": "Shows FAKE_TOKEN and the working directory", "inputSchema": obj}]
    for line in sys.stdin:
        line = line.strip()
        if not line: continue
        m = json.loads(line)
        mid, method, params = m.get("id"), m.get("method"), m.get("params") or {}
        if method is None: continue
        if mid is None: continue
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": params["protocolVersion"], "capabilities": {"tools": {"listChanged": True}},
                  "serverInfo": {"name": "fake", "version": "1.0"}, "instructions": "Fake server for tests."}})
        elif method == "tools/list":
            if params.get("cursor") == "p2": send({"jsonrpc": "2.0", "id": mid, "result": {"tools": page2}})
            else: send({"jsonrpc": "2.0", "id": mid, "result": {"tools": page1, "nextCursor": "p2"}})
        elif method == "tools/call":
            name, args = params["name"], params.get("arguments") or {}
            if name == "echo":
                sys.stderr.write("echoing\n"); sys.stderr.flush()
                send({"jsonrpc": "2.0", "id": mid, "result": text("echo: " + args.get("text", ""))})
            elif name == "add": send({"jsonrpc": "2.0", "id": mid, "result": {"content": [], "structuredContent": {"sum": args["a"] + args["b"]}}})
            elif name == "fail": send({"jsonrpc": "2.0", "id": mid, "result": text("it failed", True)})
            elif name == "crash": sys.exit(3)
            elif name == "slow":
                token = (params.get("_meta") or {}).get("progressToken")
                send({"jsonrpc": "2.0", "method": "notifications/progress", "params": {"progressToken": token, "progress": 1, "total": 2, "message": "halfway"}})
                time.sleep(0.2)
                send({"jsonrpc": "2.0", "id": mid, "result": text("slow done")})
            elif name == "roots":
                send({"jsonrpc": "2.0", "id": "r1", "method": "roots/list"})
                while True:
                    r = json.loads(sys.stdin.readline())
                    if r.get("id") == "r1": break
                send({"jsonrpc": "2.0", "id": mid, "result": text(r["result"]["roots"][0]["uri"])})
            elif name == "image":
                send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "image", "mimeType": "image/png", "data": "iVBORw0KGgo="}]}})
            elif name == "env": send({"jsonrpc": "2.0", "id": mid, "result": text(os.environ.get("FAKE_TOKEN", "") + " " + os.getcwd())})
            else: send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32602, "message": "Unknown tool " + name}})
        else:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "Method not found"}})
    """#

    /// A streamable-HTTP server: a session id from initialize that every later message must carry, a JSON reply, and an
    /// SSE reply with a notification before the result. Prints its port first.
    static let fakeHTTPServer = #"""
    import json, sys, http.server
    class H(http.server.BaseHTTPRequestHandler):
        def log_message(self, *a): pass
        def reply(self, code, body=None, sse=False, headers={}):
            self.send_response(code)
            for k, v in headers.items(): self.send_header(k, v)
            if body is None: self.send_header("Content-Length", "0"); self.end_headers(); return
            data = ("event: message\ndata: " + json.dumps({"jsonrpc": "2.0", "method": "notifications/message", "params": {"level": "info", "data": "listing"}}) + "\n\n" +
                    "data: " + json.dumps(body) + "\n\n").encode() if sse else json.dumps(body).encode()
            self.send_header("Content-Type", "text/event-stream" if sse else "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers(); self.wfile.write(data)
        def do_DELETE(self): self.reply(200)
        def do_POST(self):
            m = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
            method, mid = m.get("method"), m.get("id")
            if method == "initialize":
                return self.reply(200, {"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2025-06-18", "capabilities": {"tools": {}}, "serverInfo": {"name": "web", "version": "2"}}},
                                  headers={"Mcp-Session-Id": "s-42"})
            if self.headers.get("Mcp-Session-Id") != "s-42" or self.headers.get("MCP-Protocol-Version") != "2025-06-18":
                return self.reply(400, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32600, "message": "no session"}})
            if mid is None: return self.reply(202)
            if method == "tools/list":
                return self.reply(200, {"jsonrpc": "2.0", "id": mid, "result": {"tools": [{"name": "shout", "description": "Upper-cases", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}]}}, sse=True)
            if method == "tools/call":
                return self.reply(200, {"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": m["params"]["arguments"]["text"].upper()}]}})
            self.reply(200, {"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}})
    s = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    print(s.server_address[1], flush=True)
    s.serve_forever()
    """#

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcp-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try Self.fakeServer.write(to: dir.appendingPathComponent("fake_mcp.py"), atomically: true, encoding: .utf8)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        saved = await MainActor.run { AppModel.shared.settings.value }
    }
    override func tearDown() async throws {
        for i in MCPHub.shared.all where i.folder == dir { await i.stop() }
        let s = saved!
        await MainActor.run { AppModel.shared.settings.value = s }
        try? FileManager.default.removeItem(at: dir)
    }

    var fake: MCPServerConfig { MCPServerConfig(name: "fake", command: "python3", args: ["-u", dir.appendingPathComponent("fake_mcp.py").path]) }

    @MainActor func ctx(node: String = "engineer", interactions: InteractionCenter? = nil) -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: "L-\(UUID().uuidString.prefix(4))", workspace: dir, services: services, interactions: interactions ?? InteractionCenter(),
                            toolCallID: "c\(UUID().uuidString.prefix(4))", client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.agentNode = node
        c.codeAgent = node == "engineer"
        return c
    }

    func connect(_ config: MCPServerConfig, log: MCPLog = MCPLog()) async throws -> (MCPConnection, MCPStdioTransport) {
        var env = ProcessRunner.environment()
        for (k, v) in config.env { env[k] = v }
        let t = MCPStdioTransport(executable: try XCTUnwrap(ProcessRunner.which(config.command)), args: config.args, env: env, cwd: dir, log: log)
        let c = MCPConnection(transport: t, roots: [dir])
        try await c.start()
        return (c, t)
    }

    // MARK: Config

    func testClaudeCodesMcpJsonIsReadAndVariablesExpand() throws {
        try """
        {"mcpServers": {
          "files": {"command": "npx", "args": ["-y", "@modelcontextprotocol/server-filesystem", "${HOME}"], "env": {"TOKEN": "${MCP_TEST_UNSET:-fallback}"}},
          "web": {"type": "http", "url": "https://example.com/mcp", "headers": {"Authorization": "Bearer ${MCP_TEST_UNSET}"}},
          "old": {"type": "sse", "url": "https://example.com/sse"}
        }}
        """.write(to: MCPConfig.file(dir), atomically: true, encoding: .utf8)
        let (servers, error) = MCPConfig.project(dir)
        XCTAssertNil(error)
        XCTAssertEqual(servers.map(\.name), ["files", "old", "web"])
        let files = servers[0].expanded(["HOME": "/Users/me"])
        XCTAssertEqual(files.args.last, "/Users/me")
        XCTAssertEqual(files.env["TOKEN"], "fallback")
        XCTAssertEqual(servers[2].expanded([:]).headers["Authorization"], "Bearer ", "an unset variable without a default is empty")
        XCTAssertTrue(servers[2].isHTTP)
        XCTAssertFalse(servers[0].isHTTP)
        XCTAssertEqual(servers[0].summary, "npx -y @modelcontextprotocol/server-filesystem ${HOME}", "approvals show the config unexpanded")

        var changed = servers[0]; changed.args.append("/etc")
        XCTAssertNotEqual(changed.fingerprint, servers[0].fingerprint, "a changed command is a different server to approve")
        XCTAssertEqual(MCPServerConfig(name: "files", json: JSON.parse(#"{"args":["-y","@modelcontextprotocol/server-filesystem","${HOME}"],"command":"npx","env":{"TOKEN":"${MCP_TEST_UNSET:-fallback}"}}"#)!, scope: .project)?.fingerprint,
                       servers[0].fingerprint, "key order doesn't matter")

        let entries = MCPConfig.entries(dir, AppSettings())
        XCTAssertEqual(entries.first { $0.config.name == "old" }?.standing, .unsupported)
        XCTAssertEqual(entries.first { $0.config.name == "files" }?.standing, .needsApproval)

        try "{not json".write(to: MCPConfig.file(dir), atomically: true, encoding: .utf8)
        XCTAssertNotNil(MCPConfig.project(dir).error)
    }

    func testToolNamesAreClaudeCodesAndFitProviders() {
        XCTAssertEqual(MCPConfig.toolName(server: "github", tool: "create_issue"), "mcp__github__create_issue")
        XCTAssertEqual(MCPConfig.toolName(server: "my server", tool: "do.it"), "mcp__my_server__do_it")
        let long = MCPConfig.toolName(server: "a-very-long-server-name-indeed", tool: String(repeating: "x", count: 80))
        XCTAssertEqual(long.count, 64)
        XCTAssertNotEqual(long, MCPConfig.toolName(server: "a-very-long-server-name-indeed", tool: String(repeating: "x", count: 81)), "cut names stay distinct")
        XCTAssertNotNil(long.range(of: #"^[A-Za-z0-9_-]+$"#, options: .regularExpression))
    }

    func testAppServersAndProjectServersMergeProjectWinning() throws {
        var s = AppSettings()
        s.mcpServers = [MCPServerConfig(name: "shared", command: "a"), MCPServerConfig(name: "mine", command: "b", enabled: false)]
        try #"{"mcpServers": {"shared": {"command": "c"}}}"#.write(to: MCPConfig.file(dir), atomically: true, encoding: .utf8)
        let e = MCPConfig.entries(dir, s)
        XCTAssertEqual(e.map(\.config.name), ["mine", "shared"])
        XCTAssertEqual(e[0].standing, .disabled)
        XCTAssertEqual(e[1].config.scope, .project, "the folder's server of the same name wins")
        XCTAssertEqual(e[1].standing, .needsApproval)
        s.mcpProjectDecisions[dir.path] = ["shared": MCPDecision(fingerprint: e[1].config.fingerprint, allowed: true)]
        XCTAssertEqual(MCPConfig.entries(dir, s)[1].standing, .usable)
        s.mcpProjectDecisions[dir.path] = ["shared": MCPDecision(fingerprint: e[1].config.fingerprint, allowed: false)]
        XCTAssertEqual(MCPConfig.entries(dir, s)[1].standing, .declined)
        XCTAssertEqual(MCPConfig.entries(nil, s).map(\.config.scope), [.app, .app], "no folder: only the user's servers")
    }

    // MARK: The client over stdio

    func testStdioClientSpeaksMCP() async throws {
        let log = MCPLog()
        var config = fake
        config.env["FAKE_TOKEN"] = "tok-1"
        let (c, t) = try await connect(config, log: log)
        defer { c.close() }
        let info = try await c.initialize()
        XCTAssertEqual(info.name, "fake")
        XCTAssertEqual(info.protocolVersion, MCPConnection.protocolVersion)
        XCTAssertEqual(info.instructions, "Fake server for tests.")

        let tools = try await c.listTools()
        XCTAssertEqual(tools.map(\.name), ["echo", "add", "fail", "crash", "slow", "peek", "roots", "image", "env"], "both pages")
        XCTAssertEqual(tools.filter(\.readOnly).map(\.name), ["peek"])

        let echo = try await c.callTool("echo", ["text": "hi"], timeout: 10)
        XCTAssertEqual(echo.text, "echo: hi")
        XCTAssertFalse(echo.isError)
        let sum = try await c.callTool("add", ["a": 2, "b": 3], timeout: 10)
        XCTAssertTrue(sum.text.contains("\"sum\""), "structured content when there is no text: \(sum.text)")
        XCTAssertTrue(sum.text.contains("5"))
        let failed = try await c.callTool("fail", [:], timeout: 10)
        XCTAssertTrue(failed.isError)
        XCTAssertEqual(failed.text, "it failed")
        let image = try await c.callTool("image", [:], timeout: 10)
        XCTAssertEqual(image.images.count, 1)
        XCTAssertEqual(image.images.first?.mime, "image/png")

        let seen = Locked<[String]>([])
        let slow = try await c.callTool("slow", [:], timeout: 10) { p in seen.mutate { $0.append(p) } }
        XCTAssertEqual(slow.text, "slow done")
        XCTAssertEqual(seen.get(), ["1/2 halfway"], "progress reaches the call that asked for it")

        let roots = try await c.callTool("roots", [:], timeout: 10)
        XCTAssertEqual(roots.text, dir.absoluteString, "the client answers the server's roots/list with the folder")
        let env = try await c.callTool("env", [:], timeout: 10)
        XCTAssertTrue(env.text.hasPrefix("tok-1 /") && env.text.hasSuffix("/" + dir.lastPathComponent), "the config's env, run in the folder: \(env.text)")

        do { _ = try await c.request("nope/nope", timeout: 10); XCTFail("an unknown method is an error") }
        catch { XCTAssertTrue(error.localizedDescription.contains("Method not found"), error.localizedDescription) }

        XCTAssertTrue(log.text.contains("fake server starting"))
        XCTAssertTrue(log.text.contains("echoing"), "stderr is kept for Settings → MCP")
        XCTAssertGreaterThan(t.pid, 0)
    }

    func testACrashFailsTheWaitingCallAtOnce() async throws {
        let (c, _) = try await connect(fake)
        defer { c.close() }
        _ = try await c.initialize()
        let t0 = Date()
        do { _ = try await c.callTool("crash", [:], timeout: 30); XCTFail("the call can't succeed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("exited with status 3"), error.localizedDescription) }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 5, "not left waiting for its timeout")
        let reason = await c.waitClosed()
        XCTAssertTrue(reason.contains("status 3"))
    }

    func testATimedOutCallSaysSo() async throws {
        let (c, _) = try await connect(fake)
        defer { c.close() }
        _ = try await c.initialize()
        // `slow` takes 0.2 s.
        do { _ = try await c.request("tools/call", ["name": "slow"], timeout: 0.1); XCTFail("too short to finish") }
        catch { XCTAssertTrue(error.localizedDescription.contains("timed out"), error.localizedDescription) }
        let ok = try await c.callTool("echo", ["text": "still here"], timeout: 10)
        XCTAssertEqual(ok.text, "echo: still here", "the link survives a timed-out call")
    }

    // MARK: Supervision

    func testACrashedServerIsRestartedAndGivesUpPastItsLimit() async throws {
        let starts = dir.appendingPathComponent("starts.txt")
        var config = fake
        config.env["FAKE_STARTS"] = starts.path
        let i = MCPInstance(config: config, folder: dir, hub: nil, backoff: .none)
        let first = try await i.call("echo", ["text": "a"])
        XCTAssertEqual(first.text, "echo: a")
        XCTAssertEqual(i.status.phase, .ready)
        XCTAssertEqual(i.status.tools?.count, 9)
        let pid = try XCTUnwrap(i.status.pid)

        do { _ = try await i.call("crash", [:]); XCTFail("crashes") } catch {}
        let again = try await i.call("echo", ["text": "b"])
        XCTAssertEqual(again.text, "echo: b", "restarted by its supervisor")
        XCTAssertEqual(i.status.restarts, 1)
        XCTAssertNotEqual(i.status.pid, pid)
        XCTAssertEqual(try String(contentsOf: starts, encoding: .utf8).split(separator: "\n").count, 2)
        XCTAssertTrue(i.log.text.contains("restarting"))

        for _ in 0..<3 { _ = try? await i.call("crash", [:]) }
        for _ in 0..<100 where i.status.phase != .failed { try await Task.sleep(nanoseconds: 50_000_000) }
        XCTAssertEqual(i.status.phase, .failed, "a fourth crash within a minute is the end")
        XCTAssertTrue(i.status.lastError?.contains("gave up") == true, i.status.lastError ?? "")
        // A later use starts it afresh (the user may have fixed what broke it).
        let fresh = try await i.call("echo", ["text": "c"])
        XCTAssertEqual(fresh.text, "echo: c")
        await i.stop()
        XCTAssertEqual(i.status.phase, .stopped)
    }

    func testAServerThatCantStartFailsWithItsReason() async throws {
        let missing = MCPInstance(config: MCPServerConfig(name: "nope", command: "no-such-mcp-server-xyz"), folder: dir, hub: nil, backoff: .none)
        do { _ = try await missing.connection(timeout: 20); XCTFail("nothing to run") }
        catch { XCTAssertTrue(error.localizedDescription.contains("command not found: no-such-mcp-server-xyz"), error.localizedDescription) }
        let dies = MCPInstance(config: MCPServerConfig(name: "dies", command: "/bin/sh", args: ["-c", "echo broken >&2; exit 1"]), folder: dir, hub: nil, backoff: .none)
        do { _ = try await dies.connection(timeout: 20); XCTFail("it exits before initialize") }
        catch { XCTAssertTrue(error.localizedDescription.contains("couldn't start"), error.localizedDescription) }
        XCTAssertTrue(dies.log.text.contains("broken"), "its stderr says why")
    }

    func testServersEndWithTheApp() async throws {
        let hub = MCPHub(cacheURL: dir.appendingPathComponent("cache.json"))
        let i = hub.instance(fake, folder: dir)
        _ = try await i.connection()
        let pid = try XCTUnwrap(i.status.pid)
        XCTAssertEqual(kill(pid, 0), 0)
        hub.shutdownNow()
        for _ in 0..<100 where kill(pid, 0) == 0 { try await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotEqual(kill(pid, 0), 0, "the server's process is gone")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertNil(i.status.pid, "and not restarted: the app is quitting")
        await i.stop()
    }

    // MARK: Streamable HTTP

    func testStreamableHTTPKeepsTheSessionAndReadsEventStreams() async throws {
        let script = dir.appendingPathComponent("fake_http.py")
        try Self.fakeHTTPServer.write(to: script, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessRunner.which("python3")))
        p.arguments = ["-u", script.path]
        let out = Pipe(); p.standardOutput = out
        try p.run()
        defer { p.terminate() }
        let port = String(decoding: out.fileHandleForReading.availableData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertFalse(port.isEmpty)

        let i = MCPInstance(config: MCPServerConfig(name: "web", type: "http", url: "http://127.0.0.1:\(port)/mcp"), folder: dir, hub: nil, backoff: .none)
        let shout = try await i.call("shout", ["text": "quiet"])
        XCTAssertEqual(shout.text, "QUIET", "every message after initialize carried the session id and protocol version")
        XCTAssertEqual(i.status.tools?.map(\.name), ["shout"], "tools/list came back as server-sent events")
        XCTAssertEqual(i.status.server?.name, "web")
        XCTAssertTrue(i.log.text.contains("listing"), "a log notification in the stream is kept")
        await i.stop()
    }

    // MARK: Tools for the code agent

    @MainActor func testServersToolsAreDeferredWithALineEachAndLoadable() async throws {
        AppModel.shared.settings.value.mcpServers = [fake]
        let settings = AppModel.shared.settings.value
        XCTAssertNil(MCPHub.shared.knownTools(fake, folder: dir), "never run: nothing known yet")
        let prompt = await MCPHub.shared.promptSection(dir, settings)
        let section = try XCTUnwrap(prompt)
        XCTAssertTrue(section.contains("# MCP servers"))
        XCTAssertTrue(section.contains("- `mcp__fake__echo`: Echo the text back\n"), "one line each, first sentence: \(section)")
        XCTAssertTrue(section.contains("- `mcp__fake__peek`: Looks at nothing (read-only)"))
        XCTAssertTrue(section.contains("Fake server for tests."), "the server's instructions")

        let before = ToolRegistry.active(settings, loaded: [], mode: .agent, folder: dir).map(\.name)
        XCTAssertFalse(before.contains { $0.hasPrefix("mcp__") }, "deferred: nothing sent until loaded")
        let loaded = try await LoadToolsTool().run(["names": ["mcp__fake"]], ctx())
        XCTAssertFalse(loaded.isError, loaded.text)
        let names = loaded.meta?["loaded"]?.array?.compactMap(\.string) ?? []
        XCTAssertEqual(names.count, 9, "a whole server by its name")
        let active = ToolRegistry.active(settings, loaded: ["mcp__fake__echo", "mcp__fake__add"], mode: .agent, folder: dir)
        XCTAssertEqual(active.suffix(2).map(\.name), ["mcp__fake__echo", "mcp__fake__add"])
        let add = try XCTUnwrap(active.last as? MCPTool)
        XCTAssertEqual(add.risk, .execute)
        XCTAssertNil(add.schema["$schema"], "providers refuse the meta-schema key")
        XCTAssertEqual(add.schema["properties"]?["a"]?["type"]?.string, "number")
        XCTAssertEqual(ToolRegistry.active(settings, loaded: ["mcp__fake__echo"], mode: .tutor, folder: dir).filter { $0.name.hasPrefix("mcp__") }.count, 0,
                       "only the code agent has MCP tools")

        let one = try await LoadToolsTool().run(["names": ["mcp__fake__echo", "mcp__fake__nope", "mcp__other"]], ctx())
        XCTAssertEqual(one.meta?["loaded"]?.array?.compactMap(\.string), ["mcp__fake__echo"])
        XCTAssertTrue(one.text.contains("has no such tool"), one.text)
        XCTAssertTrue(one.text.contains("no MCP server by that name"), one.text)
        let tutor = try await LoadToolsTool().run(["names": ["mcp__fake"]], ctx(node: "tutor"))
        XCTAssertTrue(tutor.isError, "a teacher can't load them")

        let out = try await add.run(["a": 1, "b": 41], ctx())
        XCTAssertTrue(out.text.contains("42"))
        XCTAssertEqual(add.summary(["a": 1, "b": 41]), "fake · add — a: 1, b: 41")
        XCTAssertEqual(ChatSession.toolVerb("mcp__fake__add"), "Using fake: add…")

        // Remembered for the next lesson: listing the tools again starts nothing.
        await MCPHub.shared.existing("fake", folder: dir)?.stop()
        let again = MCPHub.shared.tools(dir, settings).map(\.name)
        XCTAssertEqual(again.count, 9)
        XCTAssertEqual(MCPHub.shared.existing("fake", folder: dir)?.status.phase, .stopped)
    }

    @MainActor func testAProjectServerRunsOnlyAfterTheUserApprovesThatExactConfig() async throws {
        let starts = dir.appendingPathComponent("starts.txt")
        func writeConfig(_ extra: [String] = []) throws {
            let args = (["-u", dir.appendingPathComponent("fake_mcp.py").path] + extra).map { "\"\($0)\"" }.joined(separator: ", ")
            try #"{"mcpServers": {"proj": {"command": "python3", "args": [\#(args)], "env": {"FAKE_STARTS": "\#(starts.path)"}}}}"#
                .write(to: MCPConfig.file(dir), atomically: true, encoding: .utf8)
        }
        try writeConfig()
        AppModel.shared.settings.value.mcpProjectDecisions = [:]
        var settings = AppModel.shared.settings.value
        let prompt = await MCPHub.shared.promptSection(dir, settings)
        let section = try XCTUnwrap(prompt)
        XCTAssertTrue(section.contains("`mcp__proj`: a server in this folder's .mcp.json the user hasn't approved"), section)
        XCTAssertTrue(MCPHub.shared.tools(dir, settings).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: starts.path), "nothing ran before the approval")

        // The agent loads it: the user is asked, and declines.
        let center = InteractionCenter()
        func answer(_ decision: String, on c: ToolContext) -> Task<String, Never> {
            Task { @MainActor in
                for _ in 0..<400 {
                    if let p = center.pending.values.first {
                        XCTAssertEqual(p.id, c.toolCallID, "on the load_tools call's own card")
                        center.resolve(p.id, ["decision": .string(decision)])
                        return p.payload["detail"]?.string ?? ""
                    }
                    try? await Task.sleep(nanoseconds: 10_000_000)
                }
                return ""
            }
        }
        var c = ctx(interactions: center)
        let asked = answer("deny", on: c)
        let denied = try await LoadToolsTool().run(["names": ["mcp__proj"]], c)
        let detail = await asked.value
        XCTAssertTrue(detail.contains("python3 -u"), "the approval shows what would run: \(detail)")
        XCTAssertTrue(detail.contains("FAKE_STARTS=\(starts.path)"), "and the environment it sets")
        XCTAssertTrue(denied.isError)
        XCTAssertTrue(denied.text.contains("didn't allow"), denied.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: starts.path))
        settings = AppModel.shared.settings.value
        XCTAssertEqual(MCPConfig.entries(dir, settings).first?.standing, .declined, "remembered: not asked again")

        // Allowed (from Settings, say, after declining): it starts and lists its tools.
        AppModel.shared.settings.value.mcpProjectDecisions = [:]
        c = ctx(interactions: center)
        let allowed = answer("allow", on: c)
        let ok = try await LoadToolsTool().run(["names": ["mcp__proj__echo"]], c)
        _ = await allowed.value
        XCTAssertEqual(ok.meta?["loaded"]?.array?.compactMap(\.string), ["mcp__proj__echo"], ok.text)
        XCTAssertEqual(MCPConfig.entries(dir, AppModel.shared.settings.value).first?.standing, .usable)
        XCTAssertTrue(FileManager.default.fileExists(atPath: starts.path))

        // The repo changes the command: approval is for what the user saw, so it is asked again.
        try writeConfig(["--extra"])
        XCTAssertEqual(MCPConfig.entries(dir, AppModel.shared.settings.value).first?.standing, .needsApproval)
        XCTAssertTrue(MCPHub.shared.tools(dir, AppModel.shared.settings.value).isEmpty, "its tools are gone until then")
    }

    // MARK: Gates

    @MainActor func testEveryCallIsAskedUnlessTheServerIsAlwaysAllowedHere() throws {
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .agent
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let gate = PermissionExtension(app: AppModel.shared)
        AppModel.shared.setAccess(.full, for: services.workspace)
        let tool = MCPTool(config: fake, info: MCPToolInfo(name: "echo", description: "Echo", inputSchema: ["type": "object"], readOnly: false))
        let call = Block.toolUse(id: "m1", name: tool.name, input: ["text": "hi"])
        guard case .ask(let req, let resolve) = gate.shouldRun(call, tool: tool, session: session) else { return XCTFail("asked, even with full folder access") }
        XCTAssertTrue(req.title.contains("“echo” from the MCP server “fake”"), req.title)
        XCTAssertTrue(req.detail.contains("\"text\" : \"hi\"") || req.detail.contains("\"text\": \"hi\""), req.detail)
        XCTAssertEqual(req.options.map(\.id), ["once", "lesson", "always", "deny"])
        guard case .deny = resolve("deny") else { return XCTFail("declined") }
        guard case .allow = resolve("always") else { return XCTFail("allowed") }
        XCTAssertEqual(AppModel.shared.settings.value.mcpAlwaysAllow[dir.path], ["fake"])
        guard case .allow = gate.shouldRun(call, tool: tool, session: session) else { return XCTFail("always allowed in this folder") }
        AppModel.shared.settings.value.mcpAlwaysAllow = [:]
        guard case .ask(_, let again) = gate.shouldRun(call, tool: tool, session: session) else { return XCTFail("asked again") }
        _ = again("lesson")
        guard case .allow = gate.shouldRun(call, tool: tool, session: session) else { return XCTFail("allowed for the lesson") }
    }

    func testPlanModeRunsOnlyToolsTheServerMarksReadOnly() {
        let info = { (ro: Bool) in MCPToolInfo(name: "t", description: "", inputSchema: ["type": "object"], readOnly: ro) }
        XCTAssertNil(PlanModeExtension.refusal(MCPTool(config: fake, info: info(true)), [:]))
        XCTAssertTrue(PlanModeExtension.refusal(MCPTool(config: fake, info: info(false)), [:])?.contains("read-only") == true)
        XCTAssertEqual(MCPToolInfo(json: ["name": "x", "annotations": ["readOnlyHint": true]])?.readOnly, true)
        XCTAssertEqual(MCPToolInfo(json: ["name": "x", "annotations": ["destructiveHint": false]])?.readOnly, false, "only readOnlyHint counts")
    }

    func testResultsBecomeToolOutput() {
        let r = MCPConnection.output(["content": [["type": "text", "text": "a"], ["type": "resource_link", "uri": "file:///x", "name": "x"],
                                                  ["type": "resource", "resource": ["uri": "file:///y", "text": "inline"]]], "isError": true])
        XCTAssertEqual(r.text, "a\n[resource: file:///x (x)]\ninline")
        XCTAssertTrue(r.isError)
        XCTAssertEqual(MCPConnection.output(["content": []]).text, "(no output)")
    }
}
