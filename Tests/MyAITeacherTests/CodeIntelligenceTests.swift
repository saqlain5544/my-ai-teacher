import XCTest
@testable import MyAITeacher

/// The code agent's research index, its global lessons and the project history that guards against regressions.
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
        XCTAssertTrue(AgentTree.core("engineer").contains("code") && AgentTree.deferred("engineer").contains("symbols"), "code leads; symbols loads on demand")
    }

    func testLessonsMergeRankAndRetire() {
        let store = CodeLessons(url: dir.appendingPathComponent("lessons.json"))
        let ev = CodeLesson.Evidence(project: "p1", date: Date(), note: "zig build test: use of invalidated slice")
        let a = store.add(language: "Zig", mistake: "Kept a slice of an ArrayList's items across an append", rule: "Re-take list.items after any append: the buffer may move", evidence: ev)
        XCTAssertFalse(a.merged); XCTAssertEqual(a.lesson.language, "zig")
        let b = store.add(language: "zig", mistake: "Held an ArrayList items slice across append", rule: "Re-take list.items after append; the buffer may move", evidence: ev)
        XCTAssertTrue(b.merged, "the same lesson seen again strengthens it"); XCTAssertEqual(b.lesson.hits, 2)
        _ = store.add(language: "py", mistake: "Mutable default argument shared between calls", rule: "Default to None and create the list inside", evidence: ev)
        XCTAssertEqual(store.relevant(languages: ["Python"]).map(\.language), ["python"], "only the project's languages")
        XCTAssertTrue(store.promptSection(languages: ["Zig"])?.contains("(seen 2×)") == true)
        XCTAssertNotNil(store.retire(a.lesson.id, why: "wrong for 0.14"))
        XCTAssertTrue(store.relevant(languages: ["Zig"]).isEmpty, "a retired lesson leaves the prompt")
        XCTAssertEqual(CodeLessons(url: dir.appendingPathComponent("lessons.json")).all.count, 2, "kept on disk")
    }

    @MainActor func testAFixedFailureAsksForALessonAndTheHistoryGuardsTheFile() async throws {
        var conv = Conversation(providerID: "x", model: "m"); conv.mode = .agent
        let session = ChatSession(conversation: conv, app: AppModel.shared, services: services)
        let ext = CodeLearningExtension()
        var m = ChatMessage(role: .user, blocks: [.text("fix the retry")]); ext.willSend(&m, session: session)
        func run(_ name: String, _ input: JSON, _ text: String, error: Bool = false, exit: Int = 0) {
            var r = Block.toolResult(id: UUID().uuidString, name: name, content: text, isError: error); r.meta = ["exit": .number(Double(exit))]
            ext.didRun(Block.toolUse(id: "x", name: name, input: input), result: &r, session: session)
        }
        run("bash", ["command": "python3 -m pytest -q"], "FAILED test_retry.py::test_delay - AssertionError: 0.5 != 1.0", exit: 1)
        run("edit", ["path": "src/net/retry.py"], "Edited")
        run("bash", ["command": "python3 -m pytest -q"], "3 passed")
        let fix = try XCTUnwrap(ext.fixedFailure(session))
        XCTAssertTrue(fix.detail.contains("AssertionError"), fix.detail)
        let ask = await ext.willEndTurn(session, continued: 0)
        XCTAssertTrue(ask?.contains("`lessons` action=add") == true)
        let again = await ext.willEndTurn(session, continued: 1)
        XCTAssertNil(again, "asked once a turn")

        // The person's request, not the app's hidden note that asked for the lesson.
        XCTAssertEqual(CodeLearningExtension.request([ChatMessage(role: .user, blocks: [.text("fix the retry\nplease")]),
                                                      ChatMessage(role: .user, blocks: [Block(kind: .text, text: "<context>\nYou fixed…\n</context>", meta: ["hidden": true])])]),
                       "fix the retry")
        var metrics = TurnMetrics(); metrics.changedFiles = [dir.appendingPathComponent("src/net/retry.py").path]
        ext.didFinishTurn(&metrics, session: session)
        let rec = try XCTUnwrap(ProjectHistory.all(dir).last)
        XCTAssertEqual(rec.files, ["src/net/retry.py"]); XCTAssertTrue(rec.fixed)
        XCTAssertEqual(rec.checks, ["python3 -m pytest -q: passed"])
        XCTAssertTrue(ProjectHistory.promptSection(dir)?.contains("1 of them fixes") == true)

        // The next request edits the same file: the result names the fix and the check that verified it.
        var next = ChatMessage(role: .user, blocks: [.text("tweak it")]); ext.willSend(&next, session: session)
        var edit = Block.toolResult(id: "e2", name: "edit", content: "Edited src/net/retry.py", isError: false)
        ext.didRun(Block.toolUse(id: "e2", name: "edit", input: ["path": "src/net/retry.py"]), result: &edit, session: session)
        XCTAssertTrue(edit.text?.contains("verified by `python3 -m pytest -q`") == true, edit.text ?? "")
        XCTAssertTrue(CodeLearningExtension.prURL("Created https://github.com/a/b/pull/12 ok") == "https://github.com/a/b/pull/12")
    }

    /// From a live session: a failing run piped through `tail` exits 0, and `find … tests` isn't a check.
    @MainActor func testChecksAreTheRunnersAndFailuresAreReadFromTheOutput() {
        XCTAssertEqual(CodeLearningExtension.checkKey("ls -la; python3 -m unittest -q 2>&1 | tail -40"), "python3 -m unittest -q")
        XCTAssertEqual(CodeLearningExtension.checkKey("cd /p && cargo test --lib 2>&1 | head"), "cargo test --lib")
        XCTAssertEqual(CodeLearningExtension.checkKey("npm run test"), "npm run test")
        XCTAssertNil(CodeLearningExtension.checkKey("find cart tests -type f | head; cat tests/*.py"))
        XCTAssertNil(CodeLearningExtension.checkKey("git log -5"))
        XCTAssertTrue(CodeLearningExtension.saysFailed("FAIL: test_new_carts_are_empty\n----\nFAILED (failures=1)"))
        XCTAssertTrue(CodeLearningExtension.saysFailed("=== 2 failed, 10 passed in 0.3s ==="))
        XCTAssertTrue(CodeLearningExtension.saysFailed("src/main.zig:4:5: error: use of undeclared identifier"))
        XCTAssertFalse(CodeLearningExtension.saysFailed("Ran 1 test in 0.000s\n\nOK"))
        XCTAssertFalse(CodeLearningExtension.saysFailed("=== 12 passed in 0.4s ==="))
    }
}
