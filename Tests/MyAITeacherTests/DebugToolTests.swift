import XCTest
@testable import MyAITeacher

/// The `debug` tool. The protocol, bounds and clean-up are tested against a stand-in driver (no debugger, no Developer Mode); the
/// real lldb is used for what it can do without launching a program (a binary without symbols), and, when Developer Mode is on
/// and the toolchains exist, for programs that run, break, step, crash, loop and overflow.
final class DebugToolTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("debug-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        DebugSupport.skipDeveloperCheck = true
    }
    override func tearDown() {
        DebugSupport.driverOverride = nil
        DebugSupport.skipDeveloperCheck = false
        DebugSupport.launchGrace = 75
        DebugSessions.shared.killAll()
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor func ctx(_ conv: String = "L") -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: conv, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    func need(_ tool: String) throws { if ProcessRunner.which(tool) == nil { throw XCTSkip("\(tool) is not installed") } }

    nonisolated(unsafe) static var liveProbe: String??

    /// Skips unless a program can be launched under lldb here now: with Developer Mode off, macOS asks an administrator to
    /// approve, and without that approval (or on a machine with no lldb) the live cases have nothing to run on.
    @MainActor func needLive() async throws {
        try need("clang")
        if await DebugSupport.lldbPython() == nil { throw XCTSkip("lldb's Python module is not available") }
        if Self.liveProbe == nil {
            DebugSupport.launchGrace = 5
            try writeC("probe.c", "int main(void) { return 0; }\n")
            let r = try await DebugTool().run(["action": "run", "program": "probe.c", "seconds": 5], ctx("probe"))
            Self.liveProbe = .some(r.isError ? r.text : nil)
        }
        if let why = Self.liveProbe!, !why.isEmpty { throw XCTSkip("no live debugging here: " + String(why.prefix(200))) }
    }

    func alive(_ pid: Int32) -> Bool { pid > 0 && kill(pid, 0) == 0 }

    // MARK: Words and shapes

    func testTheTeachingGraphHasIt() {
        XCTAssertTrue(AgentTree.deferred("code-mentor").contains("debug"))
        XCTAssertFalse(AgentTree.core("code-mentor").contains("debug"), "deferred: the prompt stays small")
        XCTAssertFalse(AgentTree.deferred("tutor").contains("debug"))
        XCTAssertEqual(DebugTool().risk, .execute)
        XCTAssertNil(DebugTool().subAgentVariant, "sub-agents run no debugger: nothing widens")
        XCTAssertTrue(MentorGuard.commands.contains("debug"), "a debugged program runs under the project's write fence")
        XCTAssertTrue(AgentTree.byID["code-mentor"]!.guide.contains("`debug`"))
        // Approved like bash: one grant for shell commands covers it, and a build step can't install packages.
        XCTAssertNotNil(PermissionExtension.packageInstall(tool: DebugTool(), input: ["build": "pip install numpy && make"]))
        XCTAssertNil(PermissionExtension.packageInstall(tool: DebugTool(), input: ["build": "cargo build"]))
    }

    func testCrashesAreExplainedInPlainWords() {
        let sp: UInt64 = 0x16f603000
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0x0)", signo: nil, sp: sp, depth: 3).kind, "null-deref")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0x18)", signo: nil, sp: sp, depth: 3).kind, "null-deref")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0xdeadbeef00)", signo: nil, sp: sp, depth: 3).kind, "bad-address")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=2, address=0x100003f90)", signo: nil, sp: sp, depth: 3).kind, "bad-address")
        XCTAssertTrue(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=2, address=0x100003f90)", signo: nil, sp: sp, depth: 3).detail.contains("read-only"))
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=2, address=0x16f602ff0)", signo: nil, sp: sp, depth: 9).kind, "stack-overflow", "fault at the stack's edge")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=2, address=0x16e800000)", signo: nil, sp: sp, depth: 3000).kind, "stack-overflow", "a stack thousands of frames deep, the fault below it")
        XCTAssertEqual(DebugWords.crash(desc: "signal SIGABRT", signo: 6, sp: sp, depth: 3).kind, "abort")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_ARITHMETIC (code=1, subcode=0x0)", signo: nil, sp: sp, depth: 3).kind, "arithmetic")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BREAKPOINT (code=1, subcode=0x1)", signo: nil, sp: sp, depth: 3).kind, "trap")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_INSTRUCTION (code=1, subcode=0x0)", signo: nil, sp: sp, depth: 3).kind, "illegal-instruction")
        XCTAssertFalse(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0x0)", signo: nil, sp: sp, depth: 3).detail.lowercased().contains("fix"), "what happened, not the fix")
    }

    func testBreakpointsTakeConditions() {
        XCTAssertEqual(DebugTool.breakpoint("main.c:12 if i == 3"), ["at": "main.c:12", "condition": "i == 3"])
        XCTAssertEqual(DebugTool.breakpoint("  parse_args "), ["at": "parse_args"])
    }

    func testNoDebugInfoNamesTheFix() {
        let t = DebugTool.Target(path: "/x/app", display: "app", language: "")
        let text = DebugTool.noDebugInfo(t)
        for fix in ["clang -g -O0", "cargo build", "swift build", "zig build-exe -O Debug"] { XCTAssertTrue(text.contains(fix), fix) }
    }

    func testProgramsAreInferredFromManifests() throws {
        try Data("[package]\nname = \"hello\"\nversion = \"0.1.0\"\n".utf8).write(to: dir.appendingPathComponent("Cargo.toml"))
        XCTAssertEqual(DebugTool.inferProgram(dir), "target/debug/hello")
        try FileManager.default.removeItem(at: dir.appendingPathComponent("Cargo.toml"))
        try Data("// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"P\", targets: [.executableTarget(name: \"tool\")])".utf8).write(to: dir.appendingPathComponent("Package.swift"))
        XCTAssertEqual(DebugTool.inferProgram(dir), ".build/debug/tool")
    }

    // MARK: A stand-in driver: protocol, card, bounds, clean-up

    static let fakeDriver = #"""
    import sys, json, subprocess, time, os
    def send(d): sys.stdout.write('@@DBG@@' + json.dumps(d) + '\n'); sys.stdout.flush()
    child = None
    mode = ''
    n_continue = 0
    SRC = "int f(int n) {\n  int s = 0;\n  s += n;\n  return s;\n}\n"
    def fr(i, fn, l, v):
        return {'i': i, 'fn': fn, 'l': l, 'user': True, 'f': 'main.c', 'src': 'line of ' + fn, 'v': v, 'vo': list(v)}
    def stop(line, locals_):
        return {'ok': True, 'kind': 'breakpoint', 'bp': 1, 'pid': child.pid, 'out': '', 'err': '', 'depth': 2, 'hidden': 0, 'selected': 0,
                'frames': [fr(0, 'f', line, locals_), fr(1, 'main', 9, {})], 'files': {'main.c': SRC}}
    send({'ok': True, 'ready': True})
    sys.stderr.write('greeted\n')
    for line in sys.stdin:
        c = json.loads(line)
        if c['cmd'] == 'start':
            mode = os.path.basename(c['program'])
            if mode == 'hang': time.sleep(600)
            child = subprocess.Popen(['/bin/sleep', '600'])
            r = stop(3, {'s': {'v': '0', 't': 'int'}, 'n': {'v': '3', 't': 'int'}})
            r['breakpoints'] = [{'spec': b['at'], 'locations': 1, 'id': 1, 'line': 3} for b in c['breakpoints']]
            if not c['breakpoints'] and mode == 'segv':      # a crash run has no breakpoints: the first stop is the crash
                r.update({'kind': 'exception', 'desc': 'EXC_BAD_ACCESS (code=1, address=0x0)', 'sp': 6171000000})
            if not c['breakpoints'] and mode == 'sig':
                r.update({'kind': 'signal', 'desc': 'signal SIGUSR1', 'signo': 30}); n_continue = 1
        elif c['cmd'] == 'continue':
            n_continue += 1
            if mode == 'sig' and n_continue == 1:
                r = stop(4, {}); r.update({'kind': 'signal', 'desc': 'signal SIGUSR1', 'signo': 30})
            elif mode == 'segv':
                r = stop(4, {}); r.update({'kind': 'exception', 'desc': 'EXC_BAD_ACCESS (code=1, address=0x0)', 'sp': 6171000000})
            else:
                r = {'ok': True, 'exited': 0, 'out': 'done\n', 'err': '', 'pid': child.pid}
        elif c['cmd'] == 'next':
            r = stop(4, {'s': {'v': '3', 't': 'int'}, 'n': {'v': '3', 't': 'int'}}); r['kind'] = 'step'
        elif c['cmd'] == 'frame':
            i = c['index']
            r = stop(3, {'s': {'v': '0', 't': 'int'}})
            r['selected'] = i; r['depth'] = 40
            r['frames'] = [fr(0, 'f', 3, {'s': {'v': '0', 't': 'int'}})] + ([fr(15, 'deep15', 30, {'depth': {'v': '15', 't': 'int'}})] if i == 15 else [])
        elif c['cmd'] == 'print':
            r = {'ok': True, 'v': '6', 't': 'int', 'expr': c['expr']}
        elif c['cmd'] == 'stop':
            if child: child.kill()
            send({'ok': True, 'bye': True, 'id': c['id']}); break
        r['id'] = c['id']; send(r)
    """#

    func useFake() throws {
        let f = dir.appendingPathComponent("fake-driver.py")
        try Data(Self.fakeDriver.utf8).write(to: f)
        DebugSupport.driverOverride = f.path
        for name in ["prog", "hang", "sig", "segv"] {
            let p = dir.appendingPathComponent(name)
            try Data("#!/bin/sh\n".utf8).write(to: p)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: p.path)
        }
    }

    @MainActor func testASessionStepsAndLeavesNothingRunning() async throws {
        try useFake()
        let c = ctx("S1")
        let started = try await DebugTool().run(["action": "start", "program": "prog", "breakpoints": ["main.c:3"]], c)
        XCTAssertFalse(started.isError, started.text)
        XCTAssertTrue(started.text.contains("breakpoint") && started.text.contains("main.c:3 in f") && started.text.contains("locals: s=0, n=3"), started.text)
        XCTAssertTrue(started.text.contains("call stack") && started.text.contains("main at main.c:9"))
        XCTAssertEqual(started.meta?["steps"]?.array?.count, 1)
        XCTAssertEqual(started.meta?["language"]?.string, "c")
        XCTAssertNotNil(started.meta?["files"]?["main.c"]?.string)
        let session = try XCTUnwrap(DebugSessions.shared.session("S1"))
        let program = session.proc.inferior
        XCTAssertTrue(alive(program))
        let next = try await DebugTool().run(["action": "next"], c)
        XCTAssertTrue(next.text.contains("main.c:4") || next.text.contains("stepped"), next.text)
        XCTAssertEqual(next.meta?["steps"]?.array?.count, 2, "the card keeps the whole history")
        let printed = try await DebugTool().run(["action": "print", "expr": "s * 2"], c)
        XCTAssertEqual(printed.text, "s * 2 = 6  (int)")
        let done = try await DebugTool().run(["action": "continue"], c)
        XCTAssertTrue(done.text.contains("exited with status 0") && done.text.contains("done"), done.text)
        XCTAssertEqual(done.meta?["steps"]?.array?.last?["e"]?.string, "end")
        XCTAssertNil(DebugSessions.shared.session("S1"), "an exited program ends the session")
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(alive(program), "nothing left running")
    }

    @MainActor func testStopEndsTheSessionAndTheProgram() async throws {
        try useFake()
        let c = ctx("S2")
        _ = try await DebugTool().run(["action": "start", "program": "prog"], c)
        let pid = try XCTUnwrap(DebugSessions.shared.session("S2")).proc.inferior
        XCTAssertTrue(alive(pid))
        let r = try await DebugTool().run(["action": "stop"], c)
        XCTAssertTrue(r.text.contains("ended"))
        XCTAssertNil(DebugSessions.shared.session("S2"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(alive(pid))
        let after = try await DebugTool().run(["action": "next"], c)
        XCTAssertTrue(after.isError && after.text.contains("No debugging session"))
    }

    @MainActor func testChatStopAndLessonEndKillTheProgram() async throws {
        try useFake()
        let c = ctx("S3")
        _ = try await DebugTool().run(["action": "start", "program": "prog"], c)
        let pid = try XCTUnwrap(DebugSessions.shared.session("S3")).proc.inferior
        DebugSessions.shared.end("S3")   // what ChatSession.stop() and a deleted lesson do
        XCTAssertNil(DebugSessions.shared.session("S3"))
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(alive(pid))
        _ = try await DebugTool().run(["action": "start", "program": "prog"], c)
        let pid2 = try XCTUnwrap(DebugSessions.shared.session("S3")).proc.inferior
        DebugSessions.shared.killAll()   // app quit
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(alive(pid2))
    }

    @MainActor func testOneSessionPerLesson() async throws {
        try useFake()
        let c = ctx("S4")
        _ = try await DebugTool().run(["action": "start", "program": "prog"], c)
        let first = try XCTUnwrap(DebugSessions.shared.session("S4")).proc.inferior
        let second = try await DebugTool().run(["action": "start", "program": "prog"], c)
        XCTAssertTrue(second.text.contains("previous debugging session"), second.text)
        XCTAssertEqual(DebugSessions.shared.count, 1)
        try await Task.sleep(for: .milliseconds(300))
        XCTAssertFalse(alive(first))
    }

    @MainActor func testADebuggerThatStopsAnsweringIsBoundedAndKilled() async throws {
        try useFake()
        let t0 = Date()
        let r = try await DebugTool().run(["action": "run", "program": "hang", "seconds": 1], ctx("S5"))
        XCTAssertTrue(r.isError && r.text.contains("did not answer"), r.text)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 20)
        XCTAssertEqual(DebugSessions.shared.count, 0)
    }

    @MainActor func testARunReportsStopsUpToTheLimitAndEnds() async throws {
        try useFake()
        let r = try await DebugTool().run(["action": "run", "program": "prog", "breakpoints": ["main.c:3"], "max_stops": 3], ctx("S6"))
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("Stop 1") && r.text.contains("exited with status 0"), r.text)
        XCTAssertEqual(DebugSessions.shared.count, 0, "a one-shot run leaves no session")
        let steps = try XCTUnwrap(r.meta?["steps"]?.array)
        XCTAssertEqual(steps.first?["s"]?.array?.last?["fn"]?.string, "f")
        XCTAssertEqual(steps.first?["s"]?.array?.first?["fn"]?.string, "main", "outermost frame first, as the stepper wants")
    }

    @MainActor func testAnUnapprovedLaunchIsBoundedAndExplained() async throws {
        try useFake()
        DebugSupport.developerModeOverride = true
        DebugSupport.launchGrace = 1
        defer { DebugSupport.developerModeOverride = nil; DebugSupport.launchGrace = 75 }
        let t0 = Date()
        let r = try await DebugTool().run(["action": "run", "program": "hang", "seconds": 1], ctx("S7"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 15)
        XCTAssertTrue(r.isError && r.text.contains("DevToolsSecurity -enable") && r.text.contains("administrator"), r.text)
        XCTAssertEqual(DebugSessions.shared.count, 0)
    }

    // MARK: Real lldb

    /// No program is launched, so no Developer Mode is needed: a binary without symbols is recognised and the fix named.
    @MainActor func testABinaryWithoutSymbolsIsRecognised() async throws {
        try need("clang")
        guard await DebugSupport.lldbPython() != nil else { throw XCTSkip("lldb's Python module is not available") }
        try Data("int main(void) { return 0; }\n".utf8).write(to: dir.appendingPathComponent("a.c"))
        let build = await ProcessRunner.run("/bin/zsh", ["-c", "clang -O2 -o bare a.c && strip bare"], cwd: dir, timeout: 60)
        XCTAssertEqual(build.exitCode, 0, build.combined)
        let r = try await DebugTool().run(["action": "run", "program": "bare"], ctx("R0"))
        XCTAssertTrue(r.isError && r.text.contains("no debug information") && r.text.contains("clang -g -O0"), r.text)
        XCTAssertEqual(DebugSessions.shared.count, 0)
    }

    func writeC(_ name: String, _ source: String) throws {
        try Data(source.utf8).write(to: dir.appendingPathComponent(name))
    }

    @MainActor func testBreakpointWithLocals() async throws {
        try await needLive()
        try writeC("sum.c", """
        #include <stdio.h>
        int sum(int n) {
            int s = 0;
            for (int i = 1; i <= n; i++) {
                s += i;
            }
            return s;
        }
        int main(void) {
            int total = sum(4);
            printf("%d\\n", total);
            return 0;
        }
        """)
        let before = Self.buildFolders()
        let r = try await DebugTool().run(["action": "run", "program": "sum.c", "breakpoints": ["sum.c:5 if i == 3"], "max_stops": 5], ctx("R1"))
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("sum.c:5") && r.text.contains("i=3") && r.text.contains("s=3"), r.text)
        XCTAssertTrue(r.text.contains("exited with status 0") && r.text.contains("10"), r.text)
        XCTAssertEqual(r.meta?["language"]?.string, "c")
        XCTAssertEqual(DebugSessions.shared.count, 0)
        XCTAssertEqual(Self.buildFolders(), before, "the scratch folder of the single-file build is removed")
    }

    static func buildFolders() -> Set<String> {
        Set(((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix("aiteacher-debugbuild-") })
    }

    @MainActor func testSteppingThroughACall() async throws {
        try await needLive()
        try writeC("step.c", "int twice(int x) {\n    int y = x * 2;\n    return y;\n}\nint main(void) {\n    int a = 21;\n    int b = twice(a);\n    return b == 42 ? 0 : 1;\n}\n")
        let c = ctx("R2")
        let s = try await DebugTool().run(["action": "start", "program": "step.c"], c)
        XCTAssertFalse(s.isError, s.text)
        XCTAssertTrue(s.text.contains("step.c:6"), s.text)
        _ = try await DebugTool().run(["action": "next"], c)
        let into = try await DebugTool().run(["action": "step"], c)
        XCTAssertTrue(into.text.contains("twice") && into.text.contains("x=21"), into.text)
        let over = try await DebugTool().run(["action": "next"], c)
        XCTAssertTrue(over.text.contains("y=42"), over.text)
        let p = try await DebugTool().run(["action": "print", "expr": "x + y"], c)
        XCTAssertTrue(p.text.contains("63"), p.text)
        let out = try await DebugTool().run(["action": "finish"], c)
        XCTAssertTrue(out.text.contains("main"), out.text)
        let pid = try XCTUnwrap(DebugSessions.shared.session("R2")).proc.inferior
        _ = try await DebugTool().run(["action": "stop"], c)
        try await Task.sleep(for: .milliseconds(500))
        XCTAssertFalse(alive(pid))
    }

    @MainActor func testNullDereference() async throws {
        try await needLive()
        try writeC("null.c", "struct node { int value; struct node *next; };\nint last(struct node *n) {\n    while (n->next) n = n->next;\n    return n->value;\n}\nint main(void) {\n    struct node *head = 0;\n    return last(head);\n}\n")
        let r = try await DebugTool().run(["action": "crash", "program": "null.c"], ctx("R3"))
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("Null pointer") && r.text.contains("null.c:3") && r.text.contains("last"), r.text)
        XCTAssertTrue(r.text.contains("main at null.c:8"), r.text)
        XCTAssertEqual(r.meta?["steps"]?.array?.last?["e"]?.string, "exception")
    }

    @MainActor func testStackOverflowAndBadAddress() async throws {
        try await needLive()
        try writeC("deep.c", "int down(int n) {\n    char pad[512];\n    pad[0] = (char)n;\n    return down(n + 1) + pad[0];\n}\nint main(void) {\n    return down(0);\n}\n")
        let r = try await DebugTool().run(["action": "crash", "program": "deep.c"], ctx("R4"))
        XCTAssertTrue(r.text.contains("Stack overflow"), r.text)
        XCTAssertLessThan(r.text.count, 14_100, "a deep stack is summarised, not listed")
        try writeC("bad.c", "int main(void) {\n    int *p = (int *)0xdeadbeef00;\n    return *p;\n}\n")
        let b = try await DebugTool().run(["action": "crash", "program": "bad.c"], ctx("R5"))
        XCTAssertTrue(b.text.contains("Invalid memory access") && b.text.contains("bad.c:3"), b.text)
    }

    @MainActor func testARunawayLoopHitsTheTimeBoundAndIsKilled() async throws {
        try await needLive()
        try writeC("spin.c", "int main(void) {\n    volatile int i = 0;\n    for (;;) {\n        i++;\n    }\n}\n")
        let t0 = Date()
        let r = try await DebugTool().run(["action": "crash", "program": "spin.c", "seconds": 2], ctx("R6"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
        XCTAssertTrue(r.text.contains("still running when the time ran out") && r.text.contains("spin.c:"), r.text)
        XCTAssertEqual(DebugSessions.shared.count, 0)
        let left = await ProcessRunner.run("/usr/bin/pgrep", ["-f", "aiteacher-debugbuild-.*/prog"], timeout: 5)
        XCTAssertTrue(left.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no live process: " + left.stdout)
    }

    @MainActor func testRustAndSwiftPrograms() async throws {
        try await needLive()
        if ProcessRunner.which("rustc") != nil {
            try Data("fn add(a: i32, b: i32) -> i32 {\n    let c = a + b;\n    c * 2\n}\nfn main() {\n    let v = add(1, 2);\n    println!(\"{}\", v);\n}\n".utf8).write(to: dir.appendingPathComponent("main.rs"))
            let r = try await DebugTool().run(["action": "run", "program": "main.rs", "breakpoints": ["add"]], ctx("R7"))
            XCTAssertFalse(r.isError, r.text)
            XCTAssertTrue(r.text.contains("main.rs") && r.text.contains("a=1"), r.text)
        }
        if ProcessRunner.which("swiftc") != nil {
            try Data("func add(_ a: Int, _ b: Int) -> Int {\n    let c = a + b\n    return c * 2\n}\nlet v = add(1, 2)\nprint(v)\n".utf8).write(to: dir.appendingPathComponent("main.swift"))
            let r = try await DebugTool().run(["action": "run", "program": "main.swift", "breakpoints": ["main.swift:3"]], ctx("R8"))
            XCTAssertFalse(r.isError, r.text)
            XCTAssertTrue(r.text.contains("main.swift:3") && r.text.contains("c=3"), r.text)
        }
    }

    @MainActor func testTheFenceBindsTheDebuggedProgram() async throws {
        try await needLive()
        guard WriteFence.available else { throw XCTSkip("sandbox-exec is not available") }
        let protected = dir.appendingPathComponent("learner.txt"), free = dir.appendingPathComponent("free.txt")
        try Data("mine".utf8).write(to: protected); try Data("mine".utf8).write(to: free)
        try writeC("w.c", "#include <stdio.h>\nint main(int argc, char **argv) {\n    FILE *f = fopen(argv[1], \"w\");\n    int ok = f != 0;\n    if (f) { fputs(\"overwritten\", f); fclose(f); }\n    return !ok;\n}\n")
        let fence = WriteFence.profile(files: [protected], locked: [], open: [])
        let fenced = try await WriteFence.$profile.withValue(fence) {
            try await DebugTool().run(["action": "run", "program": "w.c", "args": ["learner.txt"], "breakpoints": ["w.c:6"]], ctx("R9"))
        }
        XCTAssertFalse(fenced.isError, fenced.text)
        XCTAssertTrue(fenced.text.contains("ok=0"), "the program ran and its open failed: " + fenced.text)
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "mine", "the debugged program can't write what bash couldn't")
        // The control: the same program, the same fence, a file the fence doesn't cover.
        let control = try await WriteFence.$profile.withValue(fence) {
            try await DebugTool().run(["action": "run", "program": "w.c", "args": ["free.txt"], "breakpoints": ["w.c:6"]], ctx("R10"))
        }
        XCTAssertTrue(control.text.contains("ok=1"), control.text)
        XCTAssertEqual(try String(contentsOf: free, encoding: .utf8), "overwritten", "so the fence, not the program, is what held the first file")
    }

    // MARK: Review fixes

    func testDeepStacksAndNullAreTold() {
        let sp: UInt64 = 0x16f603000
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0x0)", signo: nil, sp: sp, depth: 4000).kind, "null-deref", "a null pointer 4,000 calls deep")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0x1000)", signo: nil, sp: sp, depth: 3000).kind, "null-deref")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=2, address=0x16f602ff0)", signo: nil, sp: sp, depth: 4000).kind, "stack-overflow")
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0xdeadbeef00)", signo: nil, sp: sp, depth: 4000).kind, "bad-address", "depth alone is not an overflow")
        XCTAssertEqual(DebugWords.crash(desc: "Rust panic", signo: nil, sp: nil, depth: 0).kind, "panic")
    }

    func testOnlyRealCrashesAreCrashes() {
        for crash in ["signal SIGSEGV", "signal SIGABRT", "signal SIGBUS", "signal SIGFPE", "signal SIGILL", "signal SIGTRAP", "EXC_BAD_ACCESS (code=1)"] {
            XCTAssertTrue(DebugTool.isCrashSignal(crash), crash)
        }
        for handled in ["signal SIGUSR1", "signal SIGINT", "signal SIGPIPE", "signal SIGALRM"] { XCTAssertFalse(DebugTool.isCrashSignal(handled), handled) }
    }

    @MainActor func testTheFrameAskedForIsTheFrameShown() async throws {
        try useFake()
        let c = ctx("F1")
        _ = try await DebugTool().run(["action": "start", "program": "prog"], c)
        let deep = try await DebugTool().run(["action": "frame", "index": 15], c)
        XCTAssertTrue(deep.text.contains("Frame 15") && deep.text.contains("deep15") && deep.text.contains("depth=15"), deep.text)
        XCTAssertFalse(deep.text.components(separatedBy: "call stack")[0].contains("s=0"), "not frame 0's locals under frame 15: " + deep.text)
        let missing = try await DebugTool().run(["action": "frame", "index": 16], c)
        XCTAssertTrue(missing.text.contains("frame 16 isn't in the report") && !missing.text.contains("line of f"), missing.text)
        _ = try await DebugTool().run(["action": "stop"], c)
    }

    @MainActor func testSignalsAProgramRaisesOnPurposeAreNotCrashes() async throws {
        try useFake()
        let r = try await DebugTool().run(["action": "run", "program": "sig", "breakpoints": ["main.c:3"], "max_stops": 5], ctx("G1"))
        XCTAssertTrue(r.text.contains("SIGUSR1") && r.text.contains("not a crash") && r.text.contains("exited with status 0"), r.text)
        XCTAssertFalse(r.text.contains("CRASH"), r.text)
        let crash = try await DebugTool().run(["action": "crash", "program": "segv"], ctx("G2"))
        XCTAssertTrue(crash.text.contains("CRASH") && crash.text.contains("Null pointer"), crash.text)
        let sig = try await DebugTool().run(["action": "crash", "program": "sig"], ctx("G3"))
        XCTAssertTrue(sig.text.contains("SIGUSR1") && sig.text.contains("ran to completion without crashing"), "the handled signal passes, the run goes on: " + sig.text)
    }

    @MainActor func testKillingASessionNeverWaitsOnTheCaller() async throws {
        try useFake()
        _ = try await DebugTool().run(["action": "start", "program": "prog"], ctx("K1"))
        let session = try XCTUnwrap(DebugSessions.shared.session("K1"))
        let child = session.proc.inferior
        let t0 = Date()
        DebugSessions.shared.end("K1")
        XCTAssertLessThan(Date().timeIntervalSince(t0), 0.1, "no pgrep on the caller's thread")
        for _ in 0..<40 where alive(child) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(alive(child))
    }

    @MainActor func testStopOnTheChatSessionKillsTheProgram() async throws {
        try useFake()
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
        let chat = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        _ = try await DebugTool().run(["action": "start", "program": "prog"], ctx(chat.id))
        let pid = try XCTUnwrap(DebugSessions.shared.session(chat.id)).proc.inferior
        XCTAssertTrue(alive(pid))
        chat.stop()   // the Stop button
        XCTAssertNil(DebugSessions.shared.session(chat.id))
        for _ in 0..<40 where alive(pid) { try await Task.sleep(for: .milliseconds(50)) }
        XCTAssertFalse(alive(pid))
    }

    func testAFenceCoversWhatItStartedWith() throws {
        let old = dir.appendingPathComponent("old.txt"), fresh = dir.appendingPathComponent("fresh.txt")
        try Data("a".utf8).write(to: old)
        let started = WriteFence.profile(files: [old], locked: [], open: [dir.appendingPathComponent("tests")])
        let since = Date()
        XCTAssertTrue(WriteFence.covers(started: started, current: started, since: since))
        XCTAssertTrue(WriteFence.covers(started: started, current: "", since: since), "less to protect now")
        // A build wrote a file after the session began: not a reason to end it.
        Thread.sleep(forTimeInterval: 0.05)
        try Data("b".utf8).write(to: fresh)
        XCTAssertTrue(WriteFence.covers(started: started, current: WriteFence.profile(files: [old, fresh], locked: [], open: [dir.appendingPathComponent("tests")]), since: since))
        // A file that already existed and wasn't fenced, a project opened under a program that started unfenced, tests locked since.
        let existing = dir.appendingPathComponent("existing.txt")
        try Data("c".utf8).write(to: existing)
        XCTAssertFalse(WriteFence.covers(started: started, current: WriteFence.profile(files: [old, existing], locked: [], open: [dir.appendingPathComponent("tests")]), since: Date()))
        XCTAssertFalse(WriteFence.covers(started: "", current: started, since: Date()), "a project opened since")
        XCTAssertFalse(WriteFence.covers(started: started, current: WriteFence.profile(files: [old], locked: [], open: []), since: since), "the tests were unlocked, are locked now")
    }

    @MainActor func testASessionSurvivesABuildWritingAFileButNotANewProject() async throws {
        try useFake()
        let old = dir.appendingPathComponent("learner.txt")
        try Data("a".utf8).write(to: old)
        let fenceAtStart = WriteFence.profile(files: [old], locked: [], open: [])
        let c = ctx("W1")
        _ = try await WriteFence.$profile.withValue(fenceAtStart) { try await DebugTool().run(["action": "start", "program": "prog"], c) }
        try await Task.sleep(for: .milliseconds(60))
        let lock = dir.appendingPathComponent("Cargo.lock")
        try Data("x".utf8).write(to: lock)
        let grown = WriteFence.profile(files: [old, lock], locked: [], open: [])
        let next = try await WriteFence.$profile.withValue(grown) { try await DebugTool().run(["action": "next"], c) }
        XCTAssertFalse(next.isError, next.text)
        // A program that started unfenced doesn't carry on once a project's files are protected.
        _ = try await DebugTool().run(["action": "stop"], c)
        _ = try await DebugTool().run(["action": "start", "program": "prog"], c)
        let denied = try await WriteFence.$profile.withValue(fenceAtStart) { try await DebugTool().run(["action": "next"], c) }
        XCTAssertTrue(denied.isError && denied.text.contains("write protection"), denied.text)
        XCTAssertNil(DebugSessions.shared.session("W1"))
    }

    // MARK: What the learner approves

    @MainActor func testTheApprovalShowsWhatWillRunAndAsksOnlyForNewCode() throws {
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let gate = PermissionExtension(app: AppModel.shared)
        AppModel.shared.setAccess(.write, for: services.workspace)
        defer { AppModel.shared.interactions.cancelAll(conversationID: session.id) }
        let tool = DebugTool()
        func decide(_ input: JSON) -> ToolDecision { gate.shouldRun(Block.toolUse(id: "d", name: "debug", input: input), tool: tool, session: session) }
        // A launch shows the program, the arguments, every breakpoint with its condition, the input.
        guard case .ask(let launch, let resolve) = decide(["action": "run", "program": "a.out", "args": ["-n", "3"],
                                                            "breakpoints": ["f.c:10 if (int)system(\"touch /tmp/x\")", "main"], "stdin": "hello"])
        else { return XCTFail("a launch is asked") }
        for shown in ["a.out -n 3", "f.c:10 if (int)system(\"touch /tmp/x\")", "main", "hello", "inside the program"] { XCTAssertTrue(launch.detail.contains(shown), shown + " in " + launch.detail) }
        XCTAssertFalse(launch.options.map(\.id).contains("rule"), "no command rule for a debugger launch")
        // "Allow for this lesson" is the debugger's own grant: it doesn't open the shell.
        guard case .allow = resolve("lesson") else { return XCTFail("allowed") }
        XCTAssertTrue(AppModel.shared.interactions.isGranted("debug", conversationID: session.id))
        XCTAssertFalse(AppModel.shared.interactions.isGranted("bash", conversationID: session.id), "not every later shell command")
        // Stepping, frames and stop add no code; an expression does, whatever was granted for launching… until the lesson grants it.
        for quiet in ["step", "next", "finish", "continue", "frame", "stop"] {
            guard case .allow = decide(["action": .string(quiet)]) else { return XCTFail("\(quiet) is not asked") }
        }
        guard case .allow = decide(["action": "print", "expr": "x"]) else { return XCTFail("the lesson grant covers print") }
        var conv2 = Conversation(providerID: "x", model: "m"); conv2.mode = .code
        let other = ChatSession(conversation: conv2, app: AppModel.shared, services: services)   // a lesson that granted nothing
        guard case .ask(let eval, _) = gate.shouldRun(Block.toolUse(id: "d", name: "debug", input: ["action": "print", "expr": "(int)system(\"id\")"]), tool: tool, session: other)
        else { return XCTFail("print is asked") }
        XCTAssertTrue(eval.title.contains("evaluate an expression") && eval.detail.contains("(int)system(\"id\")"), eval.title + eval.detail)
        // A build is a shell command: it needs the shell grant, and a shell grant covers the debugger.
        guard case .ask(let build, let rb) = gate.shouldRun(Block.toolUse(id: "d", name: "debug", input: ["action": "run", "build": "make", "program": "prog"]), tool: tool, session: other)
        else { return XCTFail("a build is asked") }
        XCTAssertTrue(build.detail.contains("Build, in a shell: make"))
        guard case .allow = rb("lesson") else { return XCTFail("allowed") }
        XCTAssertTrue(AppModel.shared.interactions.isGranted("bash", conversationID: other.id))
        guard case .allow = gate.shouldRun(Block.toolUse(id: "d", name: "debug", input: ["action": "print", "expr": "1"]), tool: tool, session: other)
        else { return XCTFail("a shell grant implies the debugger's") }
    }

    @MainActor func testNewlinesNeverReachADebuggerScript() async throws {
        for bad in [["breakpoints": ["main.go:7\ncall os.Exit(1)"]], ["breakpoints": ["f.c:1 if 1\n!rm -rf ~"]], ["expr": "x\rcall system(1)"]] as [JSON] {
            var input = bad.object ?? [:]; input["action"] = .string(bad["expr"] != nil ? "print" : "run"); input["program"] = "x"
            let r = try await DebugTool().run(.object(input), ctx("N1"))
            XCTAssertTrue(r.isError && r.text.contains("control characters"), r.text)
            var conv = Conversation(providerID: "x", model: "m"); conv.mode = .code
            let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
            guard case .deny = PermissionExtension(app: AppModel.shared).shouldRun(Block.toolUse(id: "d", name: "debug", input: .object(input)), tool: DebugTool(), session: session)
            else { return XCTFail("the gate refuses it too") }
        }
        XCTAssertNil(DebugTool.invalid(["breakpoints": ["main.c:12 if i == 3"], "expr": "a\tb"]), "tabs are fine")
    }

    @MainActor func testTheFrameChosenIsTheFrameEvaluated() async throws {
        try await needLive()
        try writeC("rec.c", "int rec(int n) {\n    int here = n * 10;\n    if (n == 0) return here;\n    return rec(n - 1) + here;\n}\nint main(void) {\n    return rec(20) == 2100 ? 0 : 1;\n}\n")
        let c = ctx("L1")
        let started = try await DebugTool().run(["action": "start", "program": "rec.c", "breakpoints": ["rec.c:3 if n == 0"]], c)
        XCTAssertFalse(started.isError, started.text)
        let frame = try await DebugTool().run(["action": "frame", "index": 15], c)
        XCTAssertTrue(frame.text.contains("Frame 15") && frame.text.contains("n=15") && frame.text.contains("here=150"), "frame 15's own locals: " + frame.text)
        let printed = try await DebugTool().run(["action": "print", "expr": "n"], c)
        XCTAssertTrue(printed.text.contains("= 15"), "print agrees with the frame shown: " + printed.text)
        _ = try await DebugTool().run(["action": "stop"], c)
    }

    @MainActor func testSignalsExitsAndRustPanics() async throws {
        try await needLive()
        try writeC("usr1.c", "#include <signal.h>\n#include <stdio.h>\nstatic volatile int got = 0;\nstatic void handler(int s) { got = s; }\nint main(void) {\n    signal(SIGUSR1, handler);\n    raise(SIGUSR1);\n    printf(\"%d\\n\", got);\n    return 0;\n}\n")
        let handled = try await DebugTool().run(["action": "crash", "program": "usr1.c"], ctx("L2"))
        XCTAssertTrue(handled.text.contains("ran to completion without crashing") && !handled.text.contains("CRASH"), handled.text)
        try writeC("exit3.c", "int main(void) { return 3; }\n")
        let exit3 = try await DebugTool().run(["action": "crash", "program": "exit3.c"], ctx("L3"))
        XCTAssertTrue(exit3.text.contains("exited with status 3 and no crash signal") && !exit3.text.contains("did not crash"), exit3.text)
        guard ProcessRunner.which("rustc") != nil else { return }
        try Data("fn pick(v: &[i32], i: usize) -> i32 {\n    v[i]\n}\nfn main() {\n    let v = vec![1, 2, 3];\n    println!(\"{}\", pick(&v, 7));\n}\n".utf8).write(to: dir.appendingPathComponent("panic.rs"))
        let panic = try await DebugTool().run(["action": "crash", "program": "panic.rs"], ctx("L4"))
        XCTAssertTrue(panic.text.contains("Rust panic") && panic.text.contains("panic.rs:2") && panic.text.contains("pick"), "the panic and where it started: " + panic.text)
    }

    @MainActor func testAProgramThatNeverStopsPrintingIsStopped() async throws {
        try await needLive()
        try writeC("flood.c", "#include <stdio.h>\nint main(void) {\n    for (;;) {\n        fputs(\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\\n\", stdout);\n        fflush(stdout);\n    }\n}\n")
        let t0 = Date()
        let r = try await DebugTool().run(["action": "crash", "program": "flood.c", "seconds": 40], ctx("L5"))
        XCTAssertTrue(r.text.contains("more than 4 MB of output"), r.text)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 30)
        XCTAssertLessThan(r.text.count, 14_100)
    }

    @MainActor func testGoIsBoundedAndKeepsWhatItPrinted() async throws {
        try await needLive()
        try need("go"); try need("dlv")
        try Data("module example.com/spin\n\ngo 1.22\n".utf8).write(to: dir.appendingPathComponent("go.mod"))
        try Data("package main\n\nimport (\n\t\"fmt\"\n\t\"time\"\n)\n\nfunc main() {\n\tfmt.Println(\"started\")\n\ttime.Sleep(time.Hour)\n}\n".utf8).write(to: dir.appendingPathComponent("main.go"))
        let t0 = Date()
        let r = try await DebugTool().run(["action": "run", "breakpoints": ["main.go:9"], "max_stops": 1, "seconds": 3], ctx("L6"))
        XCTAssertLessThan(Date().timeIntervalSince(t0), 90, "the build is outside the bound, the run inside it")
        let r2 = try await DebugTool().run(["action": "crash", "seconds": 3], ctx("L7"))
        XCTAssertTrue(r2.text.contains("Stopped after 3 s") && r2.text.contains("started"), "partial output survives the timeout: " + r2.text)
        XCTAssertFalse(r.text.isEmpty)
    }
}
