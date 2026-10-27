import XCTest
@testable import MyAITeacher

/// The mentor reads a language's standard library and installed packages from where they live on this Mac.
final class SourceToolTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("source-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        LibrarySources.forget()
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx() -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }

    @MainActor func testPythonStdlibAndModulesResolveReadAndOutline() async throws {
        try XCTSkipIf(ProcessRunner.which("python3") == nil, "python3 not installed")
        let std = try await SourceTool().run(["library": "python"], ctx())
        XCTAssertFalse(std.isError, std.text); XCTAssertTrue(std.text.contains("python standard library") && std.text.contains("json/"), std.text)
        let json = try await SourceTool().run(["library": "python json", "action": "locate"], ctx())
        XCTAssertTrue(json.text.contains("python json:") && json.text.contains("decoder.py"), json.text)
        let outline = try await SourceTool().run(["library": "python json", "action": "outline", "path": "decoder.py"], ctx())
        XCTAssertFalse(outline.isError, outline.text); XCTAssertTrue(outline.text.contains("JSONDecoder") && outline.text.contains("ƒ"), outline.text)
        let read = try await SourceTool().run(["library": "python json", "action": "read", "path": "decoder.py", "from": 1, "to": 5], ctx())
        XCTAssertTrue(read.text.contains("lines 1–5") && read.text.contains("\n1\t"), read.text)
        let grep = try await SourceTool().run(["library": "python json", "action": "grep", "query": "class JSONDecodeError"], ctx())
        XCTAssertTrue(grep.text.contains("decoder.py\n") && grep.text.contains("JSONDecodeError"), grep.text)
        let find = try await SourceTool().run(["library": "python", "action": "find", "query": "asyncio/queues"], ctx())
        XCTAssertTrue(find.text.contains("asyncio/queues.py"), find.text)
        let builtin = try await SourceTool().run(["library": "python sys"], ctx())
        XCTAssertTrue(builtin.text.contains("built-in module"), builtin.text)
        let bare = try await SourceTool().run(["library": "asyncio"], ctx())
        XCTAssertFalse(bare.isError, "a bare module name is found through Python: \(bare.text)")
        let missing = try await SourceTool().run(["library": "python no_such_module_here"], ctx())
        XCTAssertTrue(missing.isError && missing.text.contains("Couldn't find"), missing.text)
        let folder = try await SourceTool().run(["library": "python", "action": "outline", "path": "json"], ctx())
        XCTAssertTrue(folder.isError && folder.text.contains("is a folder"), folder.text)
        let reversed = try await SourceTool().run(["library": "python json", "action": "read", "path": "decoder.py", "from": 5, "to": 2], ctx())
        XCTAssertTrue(reversed.text.contains("lines 5–5") && reversed.text.contains("\n5\t"), reversed.text)
        let frozen = try await SourceTool().run(["library": "python os", "action": "outline"], ctx())
        XCTAssertFalse(frozen.isError, frozen.text); XCTAssertTrue(frozen.text.contains("os.py") && frozen.text.contains("ƒ"), "a frozen stdlib module is read from its .py: \(frozen.text)")
        XCTAssertEqual(LibrarySources.snake("std.ArrayList"), "std.array_list"); XCTAssertEqual(LibrarySources.snake("HashMap"), "hash_map"); XCTAssertEqual(LibrarySources.snake("io"), "io")
    }

    @MainActor func testPackagesInTheFolderAndTheToolchainsThatAreInstalled() async throws {
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("node_modules/@scope/pkg/lib"), withIntermediateDirectories: true)
        try "module.exports = 1;\n".write(to: dir.appendingPathComponent("node_modules/@scope/pkg/lib/index.js"), atomically: true, encoding: .utf8)
        let npm = try await SourceTool().run(["library": "npm:@scope/pkg", "action": "find", "query": "index"], ctx())
        XCTAssertTrue(npm.text.contains("lib/index.js"), npm.text)
        let bareNpm = try await SourceTool().run(["library": "@scope/pkg"], ctx())
        XCTAssertFalse(bareNpm.isError, bareNpm.text)
        if ProcessRunner.which("zig") != nil {
            let zig = try await SourceTool().run(["library": "zig std"], ctx())
            XCTAssertFalse(zig.isError, zig.text); XCTAssertTrue(zig.text.contains("std.zig") || zig.text.contains("array_list"), zig.text)
            let al = try await SourceTool().run(["library": "zig std.array_list", "action": "outline"], ctx())
            XCTAssertFalse(al.isError, al.text); XCTAssertTrue(al.text.contains("ƒ") && al.text.lowercased().contains("append"), al.text)
            let typed = try await SourceTool().run(["library": "zig std.ArrayList"], ctx())
            XCTAssertFalse(typed.isError, typed.text); XCTAssertTrue(typed.text.contains("array_list.zig"), "the type's spelling finds its file: \(typed.text)")
            let unknown = try await SourceTool().run(["library": "zig std.NoSuchThing"], ctx())
            XCTAssertFalse(unknown.isError, unknown.text); XCTAssertTrue(unknown.text.contains("not a file or folder") && unknown.text.contains("std.zig"), "falls back to std with a note: \(unknown.text)")
        }
        if ProcessRunner.which("go") != nil {
            let go = try await SourceTool().run(["library": "go net/http", "action": "find", "query": "server.go"], ctx())
            XCTAssertTrue(go.text.contains("server.go"), go.text)
        }
        if ProcessRunner.which("rustc") != nil, (try? await SourceTool().run(["library": "rust core"], ctx()))?.isError == false {
            let core = try await SourceTool().run(["library": "rust core", "action": "find", "query": "option.rs"], ctx())
            XCTAssertTrue(core.text.contains("option.rs"), core.text)
        }
        let names = Set(ToolRegistry.active(AppSettings(), loaded: [], mode: .code).map(\.name))
        XCTAssertTrue(names.contains("source") || AgentTree.deferred("code-mentor").contains("source"), "the mentor has it")
        XCTAssertTrue(ToolRegistry.deferredIndex("tutor").contains("`source`"), "loadable in a lesson")
        XCTAssertTrue(Instructions.mode(.code).contains("`source`"))
    }
}
