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
        DebugSessions.shared.killAll()
        try? FileManager.default.removeItem(at: dir)
    }

    @MainActor func ctx(_ conv: String = "L") -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: conv, workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    func need(_ tool: String) throws { if ProcessRunner.which(tool) == nil { throw XCTSkip("\(tool) is not installed") } }

    /// Whether programs can be launched under a debugger here without a password prompt.
    func needLive() async throws {
        try need("clang")
        if await DebugSupport.lldbPython() == nil { throw XCTSkip("lldb's Python module is not available") }
        let r = await ProcessRunner.run("/usr/sbin/DevToolsSecurity", ["-status"], timeout: 10)
        if r.combined.localizedCaseInsensitiveContains("disabled") { throw XCTSkip("Developer Mode is off: launching under lldb would wait for an administrator's password") }
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
        XCTAssertEqual(DebugWords.crash(desc: "EXC_BAD_ACCESS (code=1, address=0x1000)", signo: nil, sp: nil, depth: 3000).kind, "stack-overflow", "a stack thousands of frames deep")
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
    SRC = "int f(int n) {\n  int s = 0;\n  s += n;\n  return s;\n}\n"
    def stop(line, locals_):
        return {'ok': True, 'kind': 'breakpoint', 'bp': 1, 'pid': child.pid, 'out': '', 'err': '', 'depth': 2, 'hidden': 0, 'selected': 0,
                'frames': [{'i': 0, 'fn': 'f', 'l': line, 'user': True, 'f': 'main.c', 'src': 's += n;', 'v': locals_, 'vo': list(locals_)},
                           {'i': 1, 'fn': 'main', 'l': 9, 'user': True, 'f': 'main.c', 'src': 'f(3);', 'v': {}, 'vo': []}],
                'files': {'main.c': SRC}}
    send({'ok': True, 'ready': True})
    sys.stderr.write('greeted\n')
    for line in sys.stdin:
        c = json.loads(line)
        if c['cmd'] == 'start':
            if os.path.basename(c['program']) == 'hang': time.sleep(600)
            child = subprocess.Popen(['/bin/sleep', '600'])
            r = stop(3, {'s': {'v': '0', 't': 'int'}, 'n': {'v': '3', 't': 'int'}})
            r['breakpoints'] = [{'spec': b['at'], 'locations': 1, 'id': 1, 'line': 3} for b in c['breakpoints']]
        elif c['cmd'] == 'continue':
            r = {'ok': True, 'exited': 0, 'out': 'done\n', 'err': '', 'pid': child.pid}
        elif c['cmd'] == 'next':
            r = stop(4, {'s': {'v': '3', 't': 'int'}, 'n': {'v': '3', 't': 'int'}}); r['kind'] = 'step'
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
        for name in ["prog", "hang"] {
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

    @MainActor func testWithoutDeveloperModeItSaysSoInsteadOfHanging() async throws {
        DebugSupport.skipDeveloperCheck = false
        let status = await ProcessRunner.run("/usr/sbin/DevToolsSecurity", ["-status"], timeout: 10)
        guard status.combined.localizedCaseInsensitiveContains("disabled") else { throw XCTSkip("Developer Mode is on here") }
        try useFake()
        let r = try await DebugTool().run(["action": "run", "program": "prog"], ctx("S7"))
        XCTAssertTrue(r.isError && r.text.contains("DevToolsSecurity -enable"), r.text)
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
        let r = try await DebugTool().run(["action": "run", "program": "sum.c", "breakpoints": ["sum.c:5 if i == 3"], "max_stops": 5], ctx("R1"))
        XCTAssertFalse(r.isError, r.text)
        XCTAssertTrue(r.text.contains("sum.c:5") && r.text.contains("i=3") && r.text.contains("s=3"), r.text)
        XCTAssertTrue(r.text.contains("exited with status 0") && r.text.contains("10"), r.text)
        XCTAssertEqual(r.meta?["language"]?.string, "c")
        XCTAssertEqual(DebugSessions.shared.count, 0)
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
        let protected = dir.appendingPathComponent("learner.txt")
        try Data("mine".utf8).write(to: protected)
        try writeC("w.c", "#include <stdio.h>\nint main(void) {\n    FILE *f = fopen(\"learner.txt\", \"w\");\n    int ok = f != 0;\n    if (f) { fputs(\"overwritten\", f); fclose(f); }\n    return ok;\n}\n")
        let fence = WriteFence.profile(files: [protected], locked: [], open: [])
        let r = try await WriteFence.$profile.withValue(fence) { try await DebugTool().run(["action": "run", "program": "w.c", "breakpoints": ["w.c:6"]], ctx("R9")) }
        XCTAssertEqual(try String(contentsOf: protected, encoding: .utf8), "mine", "the debugged program can't write what bash couldn't: " + r.text)
    }
}
