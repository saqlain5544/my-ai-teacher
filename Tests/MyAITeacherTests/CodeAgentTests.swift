import XCTest
@testable import MyAITeacher

/// The coding tools' engineering loop (the code mentor's): the project profile in its prompt, parsed diagnostics and
/// syntax checks after edits, per-turn checkpoints with undo, definitions by name, tolerant edits.
final class CodeAgentTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codeagent-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx(codeAgent: Bool = true) -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        var c = ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                            client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        c.codeAgent = codeAgent
        return c
    }
    func write(_ name: String, _ text: String) throws {
        let u = dir.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }

    // MARK: Project profile

    func testProjectProfileReadsTheManifests() async throws {
        try write("Package.swift", "// swift-tools-version: 6.0")
        try write("package.json", #"{"name":"x","scripts":{"build":"vite build","test":"vitest run","lint":"eslint .","typecheck":"tsc --noEmit"},"workspaces":["packages/*"]}"#)
        try write("pnpm-lock.yaml", ""); try write("tsconfig.json", "{}")
        try write("Cargo.toml", "[package]"); try write("go.mod", "module x"); try write("build.zig", "")
        try write("Makefile", "build:\n\tswift build\ntest: build\n\tswift test\n.PHONY: build\nCC := clang\n")
        try write("src/a.swift", "let a = 1"); try write("src/b.ts", "export const b = 1"); try write("src/c.ts", ""); try write("src/d.ts", "")
        let p = await ProjectProfile.detect(dir)
        XCTAssertTrue(p.kinds.contains("Swift package") && p.kinds.contains("npm package (pnpm)") && p.kinds.contains("TypeScript") && p.kinds.contains("Cargo (no lockfile yet)") && p.kinds.contains("Go module") && p.kinds.contains("Zig") && p.kinds.contains("Makefile"), "\(p.kinds)")
        XCTAssertEqual(p.commands.check.first, "swift build")
        XCTAssertTrue(p.commands.check.contains("pnpm run typecheck") && p.commands.check.contains("cargo check") && p.commands.check.contains("go vet ./..."), "\(p.commands.check)")
        XCTAssertTrue(p.commands.test.contains("pnpm run test") && p.commands.test.contains("swift test") && p.commands.test.contains("zig build test"), "\(p.commands.test)")
        XCTAssertEqual(p.commands.lint, ["pnpm run lint", "cargo clippy"])
        XCTAssertEqual(p.makeTargets, ["build", "test"], "targets, not variables or .PHONY")
        XCTAssertEqual(p.languages.first?.0, "TypeScript")
        XCTAssertTrue(p.notes.contains { $0.contains("monorepo") })
        let s = p.section()!
        XCTAssertTrue(s.hasPrefix("# Project") && s.contains("`swift build`"), s)
        let empty = await ProjectProfile.detect(FileManager.default.temporaryDirectory.appendingPathComponent("nothing-here-\(UUID().uuidString.prefix(4))"))
        // An empty folder still says what it can be built with: the toolchains on this Mac, with their versions.
        XCTAssertEqual(empty.section(), empty.toolchains.isEmpty ? nil : "# Project\n- Installed: " + empty.toolchains.joined(separator: ", "))
        XCTAssertEqual(ProjectProfile.version("swift-driver version: 1.168.6 Apple Swift version 6.4 (swiftlang-6.4.0.34.1 clang-2100.3.34.1)\nTarget: arm64"), "6.4")
        XCTAssertEqual(ProjectProfile.version("v22.3.0\n"), "22.3.0")
        XCTAssertEqual(ProjectProfile.version("go version go1.23.0 darwin/arm64"), "1.23.0")
        XCTAssertEqual(ProjectProfile.version("\nPython 3.12.4"), "3.12.4")
        XCTAssertNil(ProjectProfile.version("Unable to locate a Java Runtime."))
    }

    // MARK: Diagnostics

    func testDiagnosticsParseCompilersAndRunners() {
        let swift = "/x/Sources/A.swift:12:9: error: cannot find 'foo' in scope\n/x/Sources/A.swift:14:1: warning: variable 'y' was never used\n/x/Sources/A.swift:14:1: note: did you mean\n"
        let items = Diagnostics.parse(swift, folder: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(items.map { "\($0.file):\($0.line):\($0.severity)" }, ["Sources/A.swift:12:error", "Sources/A.swift:14:warning"], "notes are noise")
        let tsc = Diagnostics.parse("src/app.ts(3,7): error TS2322: Type 'string' is not assignable to type 'number'.\n")
        XCTAssertEqual(tsc.first?.line, 3); XCTAssertEqual(tsc.first?.column, 7); XCTAssertEqual(tsc.first?.message, "Type 'string' is not assignable to type 'number'.")
        let rust = Diagnostics.parse("error[E0308]: mismatched types\n --> src/main.rs:4:5\n  |\nwarning: unused variable: `x`\n --> src/main.rs:9:9\nerror: aborting due to 1 previous error\n")
        XCTAssertEqual(rust.map { "\($0.file):\($0.line) \($0.severity) \($0.message)" }, ["src/main.rs:4 error mismatched types", "src/main.rs:9 warning unused variable: `x`"])
        let py = Diagnostics.parse("  File \"/x/app.py\", line 7\n    def f(:\n          ^\nSyntaxError: invalid syntax\n", folder: URL(fileURLWithPath: "/x"))
        XCTAssertEqual(py.first?.file, "app.py"); XCTAssertEqual(py.first?.line, 7); XCTAssertEqual(py.first?.message, "SyntaxError: invalid syntax")
        let go = Diagnostics.parse("./main.go:10:2: undefined: fmt.Printl\n")
        XCTAssertEqual(go.first?.severity, "error"); XCTAssertEqual(go.first?.file, "main.go")
        let summary = Diagnostics.summary(items)
        XCTAssertTrue(summary.hasPrefix("1 error, 1 warning") && summary.contains("Sources/A.swift:") && summary.contains("12:9 error:"), summary)
        XCTAssertEqual(Diagnostics.summary([]), "No problems reported.")
        XCTAssertTrue(Diagnostics.parse("Build complete! (2.1s)\n[3/5] Compiling X\n").isEmpty, "progress lines are not diagnostics")
    }

    @MainActor func testWritesAreSyntaxCheckedInAgentMode() async throws {
        try XCTSkipIf(ProcessRunner.which("python3") == nil, "python3 not installed")
        let bad = try await WriteTool().run(["path": "bad.py", "content": "def f(:\n    pass\n"], ctx())
        XCTAssertTrue(bad.text.contains("Syntax check found problems"), bad.text)
        XCTAssertTrue(bad.text.contains("SyntaxError") || bad.text.contains("invalid syntax"), bad.text)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("__pycache__").path), "the check leaves nothing in the project")
        XCTAssertEqual(bad.meta?["syntaxErrors"]?.bool, true)
        let good = try await WriteTool().run(["path": "good.py", "content": "def f():\n    pass\n"], ctx())
        XCTAssertTrue(good.text.contains("Syntax check: ok"), good.text)
        let lesson = try await WriteTool().run(["path": "bad2.py", "content": "def f(:\n"], ctx(codeAgent: false))
        XCTAssertFalse(lesson.text.contains("Syntax check"), "lessons are not checked")
        let json = try await WriteTool().run(["path": "x.json", "content": "{\"a\": }"], ctx())
        XCTAssertTrue(json.text.contains("Syntax check found problems"), json.text)
        let edited = try await EditTool().run(["path": "good.py", "old_string": "    pass", "new_string": "    return 1"], ctx())
        XCTAssertTrue(edited.text.contains("Syntax check: ok"), edited.text)
    }

    @MainActor func testDiagnosticsToolRunsTheProjectCheck() async throws {
        try XCTSkipIf(ProcessRunner.which("python3") == nil, "python3 not installed")
        try write("pyproject.toml", "[project]\nname='x'\n")
        try write("app.py", "def f(:\n")
        let out = try await DiagnosticsTool().run(["what": "check"], ctx())
        XCTAssertTrue(out.isError); XCTAssertTrue(out.text.contains("compileall") && out.text.contains("app.py"), out.text)
        XCTAssertEqual(out.meta?["errors"]?.int, 1)
        try write("app.py", "def f():\n    return 1\n")
        let ok = try await DiagnosticsTool().run(["what": "check"], ctx())
        XCTAssertFalse(ok.isError); XCTAssertTrue(ok.text.contains("No problems"), ok.text)
        let none = try await DiagnosticsTool().run(["what": "lint"], ctx())
        XCTAssertTrue(none.isError && none.text.contains("No lint command"), none.text)
        let custom = try await DiagnosticsTool().run(["what": "command", "command": "echo 'x.py:3:1: error: boom'; exit 1"], ctx())
        XCTAssertTrue(custom.text.contains("x.py:") && custom.text.contains("3:1 error: boom"), custom.text)
    }

    // MARK: Checkpoints and undo

    func testCheckpointsUndoATurnsChanges() throws {
        let ws = services.workspace
        try write("a.txt", "one\n"); try write("sub/b.txt", "two\n")
        XCTAssertTrue(Checkpoints.backup(ws, turn: "t1", file: dir.appendingPathComponent("a.txt")))
        XCTAssertTrue(Checkpoints.backup(ws, turn: "t1", file: dir.appendingPathComponent("a.txt")), "a second backup of the same file is a no-op")
        XCTAssertTrue(Checkpoints.backup(ws, turn: "t1", file: dir.appendingPathComponent("new.txt")), "a file that doesn't exist yet is remembered as created")
        XCTAssertTrue(Checkpoints.backup(ws, turn: "t1", file: dir.appendingPathComponent("sub/b.txt")))
        XCTAssertFalse(Checkpoints.backup(ws, turn: "t1", file: ws.stateDir.appendingPathComponent("x")), "never the app's own state")
        try write("a.txt", "ONE\n"); try write("new.txt", "created\n")   // sub/b.txt is left alone
        XCTAssertEqual(Checkpoints.changed(ws, turn: "t1"), ["a.txt", "new.txt"], "only files that differ count as changed")
        let r = Checkpoints.restore(ws, turn: "t1")
        XCTAssertEqual(r.restored.sorted(), ["a.txt", "sub/b.txt"]); XCTAssertEqual(r.removed, ["new.txt"]); XCTAssertEqual(r.failed, [])
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("a.txt"), encoding: .utf8), "one\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("new.txt").path))
        XCTAssertEqual(Checkpoints.restore(ws, turn: "nope").restored, [])
        XCTAssertEqual(Checkpoints.restore(ws, turn: "t1").restored, [], "an undo happens once: the checkpoint is gone")
        // A later turn that touched the same file blocks the older undo (it would wipe the later change).
        try write("c.txt", "v1\n")
        Checkpoints.backup(ws, turn: "1000", file: dir.appendingPathComponent("c.txt")); try write("c.txt", "v2\n")
        Checkpoints.backup(ws, turn: "2000", file: dir.appendingPathComponent("c.txt")); try write("c.txt", "v3\n")
        Checkpoints.backup(ws, turn: "3000", file: dir.appendingPathComponent("a.txt"))
        XCTAssertEqual(Checkpoints.laterTurns(ws, touching: "1000"), ["2000"]); XCTAssertEqual(Checkpoints.laterTurns(ws, touching: "2000"), [])
        XCTAssertEqual(Checkpoints.restore(ws, turn: "2000").restored, ["c.txt"]); XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("c.txt"), encoding: .utf8), "v2\n")
        XCTAssertEqual(Checkpoints.laterTurns(ws, touching: "1000"), [], "once the later turn is undone, the older one may be")
        for i in 0..<(Checkpoints.keep + 5) { Checkpoints.backup(ws, turn: "p\(i)", file: dir.appendingPathComponent("a.txt")) }
        Checkpoints.prune(ws)
        let left = try FileManager.default.contentsOfDirectory(atPath: ws.stateDir.appendingPathComponent("checkpoints").path)
        XCTAssertEqual(left.count, Checkpoints.keep)
    }

    @MainActor func testTheExtensionCheckpointsAgentWritesAndRecordsThemOnTheTurn() throws {
        let app = AppModel.shared
        var conv = Conversation(providerID: "x", model: "m")
        conv.mode = .code
        let session = ChatSession(conversation: conv, app: app, services: services)
        let ext = CodeAgentExtension(app: app)
        try write("f.swift", "let x = 1\n")
        let call = Block.toolUse(id: "c1", name: "write", input: ["path": "f.swift", "content": "let x = 2\n"])
        if case .allow = ext.shouldRun(call, tool: WriteTool(), session: session) {} else { XCTFail("the extension never gates") }
        try write("f.swift", "let x = 2\n")
        var metrics = TurnMetrics()
        ext.didFinishTurn(&metrics, session: session)
        XCTAssertNotNil(metrics.checkpoint); XCTAssertEqual(metrics.changedFiles, ["f.swift"])
        let note = ext.revert(session, turn: metrics.checkpoint!)
        XCTAssertTrue(note.hasPrefix("Undone: 1 file"), note)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("f.swift"), encoding: .utf8), "let x = 1\n")
        XCTAssertTrue(session.studyNotes.first?.contains("undid the file changes") == true, "the agent hears about it")
        // A lesson (not an agent) is left alone.
        var lesson = Conversation(providerID: "x", model: "m"); lesson.mode = .tutor
        let s2 = ChatSession(conversation: lesson, app: app, services: services)
        _ = ext.shouldRun(call, tool: WriteTool(), session: s2)
        var m2 = TurnMetrics(); ext.didFinishTurn(&m2, session: s2)
        XCTAssertNil(m2.checkpoint)
        // Old turn metrics without the new fields still decode.
        let old = #"{"startedAt":0,"duration":1,"steps":1,"tools":[],"usage":{"input":0,"output":0,"cacheRead":0,"cacheWrite":0},"generationSeconds":0,"memoriesRecalled":[],"memoryWrites":0,"languages":[],"cancelled":false}"#
        XCTAssertNoThrow(try JSONDecoder().decode(TurnMetrics.self, from: Data(old.utf8)))
    }

    // MARK: Symbols

    @MainActor func testSymbolsOutlineAndDefinitions() async throws {
        try write("Sources/Shop.swift", """
        import Foundation
        /// A cart.
        public struct Cart: Codable {
            var items: [Item] = []
            public func total() -> Int { items.count }
            mutating func add(_ i: Item) { items.append(i) }
        }
        enum Status { case open }
        private let secret = 1
        func checkout(_ c: Cart) {}
        """)
        try write("app.py", "class Shop:\n    def __init__(self):\n        pass\n    async def run(self): pass\nMAX = 3\ndef main():\n    pass\n")
        try write("web/app.ts", "export interface Cart { n: number }\nexport const total = (c: Cart) => c.n;\nfunction helper() {}\nexport default class Shop {\n  async run(): Promise<void> {\n  }\n}\nexport type Id = string;\n")
        let sw = SymbolsTool.outline(try String(contentsOf: dir.appendingPathComponent("Sources/Shop.swift"), encoding: .utf8), ext: "swift")
        XCTAssertEqual(sw.map { "\($0.kind) \($0.name)" }, ["type Cart", "function total", "function add", "type Status", "constant secret", "function checkout"])
        let py = SymbolsTool.outline(try String(contentsOf: dir.appendingPathComponent("app.py"), encoding: .utf8), ext: "py")
        XCTAssertEqual(py.map(\.name), ["Shop", "__init__", "run", "MAX", "main"])
        let ts = SymbolsTool.outline(try String(contentsOf: dir.appendingPathComponent("web/app.ts"), encoding: .utf8), ext: "ts")
        XCTAssertEqual(ts.map(\.name), ["Cart", "total", "helper", "Shop", "run", "Id"], "\(ts)")
        let out = try await SymbolsTool().run(["path": "Sources/Shop.swift"], ctx())
        XCTAssertTrue(out.text.contains("6 definitions") && out.text.contains("ƒ  public func total()"), out.text)
        let defs = try await SymbolsTool().run(["query": "Cart"], ctx())
        XCTAssertTrue(defs.text.contains("Sources/Shop.swift:3") && defs.text.contains("web/app.ts:1"), defs.text)
        XCTAssertFalse(defs.text.contains("checkout"), "a use is not a definition")
        let fns = try await SymbolsTool().run(["query": "total", "kind": "function"], ctx())
        XCTAssertTrue(fns.text.contains("Shop.swift:5"), fns.text)
        let none = try await SymbolsTool().run(["query": "nothingHere"], ctx())
        XCTAssertTrue(none.text.contains("No definition"))
    }

    // MARK: Tolerant edits, commands, toolset

    @MainActor func testEditMatchesAcrossIndentationAndReindents() async throws {
        try write("x.py", "class A:\n    def f(self):\n        return 1\n\n    def g(self):\n        return 2\n")
        let r = try await EditTool().run(["path": "x.py", "old_string": "def f(self):\n    return 1", "new_string": "def f(self):\n    return 10"], ctx(codeAgent: false))
        XCTAssertFalse(r.isError, r.text); XCTAssertTrue(r.text.contains("different indentation"), r.text)
        XCTAssertEqual(try String(contentsOf: dir.appendingPathComponent("x.py"), encoding: .utf8), "class A:\n    def f(self):\n        return 10\n\n    def g(self):\n        return 2\n")
        let dup = try await EditTool().run(["path": "x.py", "old_string": "return 99", "new_string": "x"], ctx(codeAgent: false))
        XCTAssertTrue(dup.isError && dup.text.contains("not found"))
        let ambiguous = try await EditTool().run(["path": "x.py", "old_string": "  def", "new_string": "def"], ctx(codeAgent: false))
        XCTAssertTrue(ambiguous.isError, "two lines match loosely: no guess")
    }

    @MainActor func testTheCodeMentorsToolset() async throws {
        // Always sent, or loaded on demand (one line each in the prompt; a direct call loads one).
        let names = Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .code).map(\.name) + AgentTree.deferred("code-mentor"))
        for t in ["diagnostics", "symbols", "source", "bash", "bash_jobs", "edit", "code", "browser"] { XCTAssertTrue(names.contains(t), t) }
        XCTAssertFalse(Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .tutor).map(\.name)).contains("diagnostics"))
        // Background commands are ShellJobs (handles, servers, the report when one ends): ShellJobsTests.
    }
}
