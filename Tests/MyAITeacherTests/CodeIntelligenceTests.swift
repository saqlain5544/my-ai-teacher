import XCTest
@testable import MyAITeacher

/// The code research index (`code`): search by meaning, definitions, uses, callers and the import graph.
final class CodeIntelligenceTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("code-\(UUID().uuidString.prefix(6))").resolvingSymlinksInPath()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        try write("src/net/retry.py", """
        import random


        def backoff_delay(attempt, base=0.5):
            # Wait longer before each retry, with jitter, so clients don't retry in lockstep.
            return base * (2 ** attempt) + random.random() * base


        class RetryPolicy:
            def __init__(self, attempts=3):
                self.attempts = attempts
        """)
        try write("src/client.py", """
        from src.net.retry import backoff_delay, RetryPolicy


        def fetch(url, policy=None):
            policy = policy or RetryPolicy()
            for attempt in range(policy.attempts):
                delay = backoff_delay(attempt)
            return url
        """)
        try write("src/main.py", """
        from src.client import fetch


        def main():
            print(fetch("https://example.com"))
        """)
        try write("web/parseHeader.ts", """
        export function parseHTTPHeader(line: string): [string, string] {
          const i = line.indexOf(":");
          return [line.slice(0, i).trim(), line.slice(i + 1).trim()];
        }
        """)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func write(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    @MainActor func ctx() -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: "C", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }

    func testWordsSplitIdentifiers() {
        XCTAssertEqual(CodeIndex.split("parseHTTPHeader"), ["parse", "http", "header"])
        XCTAssertEqual(CodeIndex.split("max_retries"), ["max", "retries"])
        XCTAssertTrue(CodeIndex.words("backoffDelay retries").contains("retry"), "stemmed: retries → retry")
    }

    func testTheIndexFindsByMeaningAndGraphsTheProject() async throws {
        let index = CodeIndex(root: dir)
        let built = await index.refresh()
        XCTAssertEqual(built.files, 4)
        // By meaning: the words of the question, not the function's name.
        let found = await index.search("how long to wait before retrying")
        XCTAssertEqual(found.first?.sym?.name, "backoff_delay", found.map { $0.sym?.name ?? $0.path }.description)
        let header = await index.search("parse an http header")
        XCTAssertEqual(header.first?.sym?.name, "parseHTTPHeader")
        // Definitions with their spans; the graph of who uses whom.
        let d = await index.definitions("backoff_delay")
        XCTAssertEqual(d.first?.path, "src/net/retry.py"); XCTAssertEqual(d.first?.sym.line, 4)
        XCTAssertLessThan(d.first?.sym.end ?? 99, 9, "a function ends before the next definition")
        let client = await index.neighbours("src/client.py")
        XCTAssertTrue(client.uses.map(\.0).contains("src/net/retry.py"))
        XCTAssertTrue(client.usedBy.map(\.0).contains("src/main.py"))
        let fetchDefs = await index.definitions("fetch")
        let fetchDef = try XCTUnwrap(fetchDefs.first)
        let callees = await index.callees("src/client.py", fetchDef.sym)
        XCTAssertEqual(Set(callees.map(\.name)), ["RetryPolicy", "backoff_delay"])
        let map = await index.map()
        XCTAssertEqual(map.first?.path, "src/net/retry.py", "the most used file is the most central")
        // Incremental: one changed file is read again, the rest kept.
        try write("src/main.py", "from src.client import fetch\n\n\ndef main():\n    return fetch('x')\n\n\ndef shutdown():\n    pass\n")
        let again = await index.refresh()
        XCTAssertEqual(again.changed, 1)
        let shutdown = await index.definitions("shutdown")
        XCTAssertEqual(shutdown.first?.path, "src/main.py")
    }

    @MainActor func testTheCodeToolAnswersEachQuestion() async throws {
        let tool = CodeTool(), c = ctx()
        let find = try await tool.run(["action": "find", "query": "retry with jitter"], c)
        XCTAssertTrue(find.text.contains("src/net/retry.py:4"), find.text)
        let refs = try await tool.run(["action": "refs", "name": "backoff_delay"], c)
        XCTAssertTrue(refs.text.contains("src/client.py") && refs.text.contains("in fetch"), refs.text)
        XCTAssertFalse(refs.text.contains("retry.py\n  4"), "its definition isn't a use")
        let callers = try await tool.run(["action": "callers", "name": "fetch"], c)
        XCTAssertTrue(callers.text.contains("src/main.py") && callers.text.contains("def main"), callers.text)
        let outline = try await tool.run(["action": "outline", "path": "src/client.py"], c)
        XCTAssertTrue(outline.text.contains("fetch") && outline.text.contains("Used by: src/main.py"), outline.text)
        let related = try await tool.run(["action": "related", "path": "src/client.py"], c)
        XCTAssertTrue(related.text.contains("Uses: src/net/retry.py"), related.text)
        let map = try await tool.run(["action": "map"], c)
        XCTAssertTrue(map.text.contains("4 files") && map.text.contains("backoff_delay"), map.text)
        XCTAssertTrue(AgentTree.deferred("code-mentor").contains("code"), "the code mentor loads it on demand")
    }
}
