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

    func testADiffParsesToChangedLinesAndRemovedText() {
        let diff = """
        diff --git a/src/a.py b/src/a.py
        --- a/src/a.py
        +++ b/src/a.py
        @@ -4,2 +4,3 @@ def f():
        -    return 1
        -    pass
        +    return 2
        +    pass
        +    # more
        @@ -20 +20,0 @@ def g():
        -def gone():
        diff --git a/old.py b/old.py
        --- a/old.py
        +++ /dev/null
        @@ -1 +0,0 @@
        -def legacy(): pass
        """
        let d = CodeImpact.parse(diff)
        XCTAssertEqual(d.ranges["src/a.py"], [4...6, 20...20], "a pure deletion marks the line it sits after")
        XCTAssertEqual(d.removed["src/a.py"]?.last, "def gone():")
        XCTAssertEqual(d.removed["old.py"], ["def legacy(): pass"], "a deleted file is keyed by its old path")
        XCTAssertNil(d.ranges["old.py"])
    }

    @MainActor func testImpactTracesAChangeToItsCallersTestsAndBrokenNames() async throws {
        try write("tests/test_retry.py", """
        from src.net.retry import backoff_delay


        def test_delay_grows():
            assert backoff_delay(2) > backoff_delay(1)
        """)
        func git(_ args: String...) async { _ = await Worktree.run(["-C", dir.path] + args) }
        await git("init", "-q"); await git("add", "-A")
        await git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
        let tool = CodeTool(), c = ctx()
        let clean = try await tool.run(["action": "impact"], c)
        XCTAssertTrue(clean.text.contains("No uncommitted changes"), clean.text)

        // backoff_delay's body changes, RetryPolicy goes (client.py still builds one), and a new file adds a function.
        try write("src/net/retry.py", """
        import random


        def backoff_delay(attempt, base=0.5):
            # Wait longer before each retry, with jitter, so clients don't retry in lockstep.
            return min(30, base * (2 ** attempt)) + random.random() * base
        """)
        try write("src/net/limits.py", """
        def clamp_delay(d, ceiling=30):
            return min(d, ceiling)
        """)
        let out = try await tool.run(["action": "impact"], c)
        let t = out.text
        XCTAssertTrue(t.contains("REMOVED BUT STILL NAMED") && t.contains("RetryPolicy (was in src/net/retry.py)") && t.contains("src/client.py:"), t)
        XCTAssertTrue(t.contains("src/net/retry.py:4 ƒ def backoff_delay") && t.contains("in fetch"), "its caller outside the change: " + t)
        XCTAssertTrue(t.contains("tests/test_retry.py — backoff_delay"), "the test that names it: " + t)
        XCTAssertTrue(t.contains("clamp_delay [new]"), "an untracked file's definitions are new and used nowhere: " + t)
        XCTAssertFalse(t.contains("backoff_delay [new]"), "an edited definition isn't new")

        try write("REVIEW.md", "Retries must be capped.")
        let review = try await tool.run(["action": "review"], c)
        XCTAssertTrue(review.text.hasPrefix("REVIEW BRIEF") && review.text.contains("+    return min(30,") && review.text.contains("## Reach")
                      && review.text.contains("Retries must be capped.") && review.text.contains("## How to review"), review.text)
        let since = try await tool.run(["action": "impact", "base": "HEAD"], c)
        XCTAssertTrue(since.text.contains("since `HEAD`"), since.text)
        let bad = try? await tool.run(["action": "impact", "base": "--output=/tmp/x"], c)
        XCTAssertNil(bad, "a base that is an option is refused")
    }

    func testImpactCountsOnlyUsesThatCanBeTheDefinitions() {
        func u(_ path: String, _ text: String) -> CodeTool.Use { CodeTool.Use(path: path, line: 1, text: text, within: nil) }
        let uses = [u("a.js", "const x = blank(v);"), u("a.js", "<input class=\"blank\">"), u("a.js", "el.querySelector('input.blank')"),
                    u("a.js", "foo(); // blank here"), u("a.js", "'q-blank' + blank_fix"), u("b.swift", "blank(1)"), u("a.js", "let y = a.blank")]
        let kept = CodeImpact.plausible(uses, name: "blank", from: "z.js", local: false)
        XCTAssertEqual(kept.map(\.text), ["const x = blank(v);", "let y = a.blank"], "not strings, comments, other identifiers or another language")
        XCTAssertTrue(CodeImpact.plausible([u("a.swift", "f()"), u("b.swift", "f()")], name: "f", from: "a.swift", local: true).count == 1, "private: its own file only")
    }

    func testReviewRulesComeFromTheRepository() throws {
        XCTAssertNil(CodeImpact.rules(root: dir))
        try write("REVIEW.md", "  \nEvery retry must be capped.\n")
        XCTAssertEqual(CodeImpact.rules(root: dir), "Every retry must be capped.")
        try write("REVIEW.md", String(repeating: "x", count: 5000))
        XCTAssertTrue(CodeImpact.rules(root: dir, limit: 100)?.contains("REVIEW.md goes on") == true)
    }

    @MainActor func testReviewsRememberWhatTheUserCorrected() async throws {
        defer { try? FileManager.default.removeItem(at: ReviewMemory.url(dir)) }
        XCTAssertTrue(ReviewMemory.load(dir).isEmpty)
        let tool = CodeTool(), c = ctx()
        var out = try await tool.run(["action": "learn", "query": "Retries without jitter are fine in tests/\nfixtures"], c)
        XCTAssertTrue(out.text.contains("1. Retries without jitter are fine in tests/ fixtures"), out.text)
        _ = try await tool.run(["action": "learn", "query": "retries without jitter are fine in tests/ fixtures"], c)
        XCTAssertEqual(ReviewMemory.load(dir).count, 1, "the same rule twice is kept once")
        _ = try await tool.run(["action": "learn", "query": "Always check the migration"], c)
        try write("src/net/retry.py", "import random\n\n\ndef backoff_delay(attempt):\n    return 1\n")
        let git = { (a: [String]) async in _ = await Worktree.run(["-C", self.dir.path] + a) }
        await git(["init", "-q"]); await git(["add", "-A"])
        await git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "b"])
        try write("src/net/retry.py", "import random\n\n\ndef backoff_delay(attempt):\n    return 2\n")
        out = try await tool.run(["action": "review"], c)
        XCTAssertTrue(out.text.contains("Learned from earlier reviews") && out.text.contains("2. Always check the migration"), out.text)
        out = try await tool.run(["action": "forget", "query": "migration"], c)
        XCTAssertTrue(out.text.contains("Dropped 1"), out.text)
        XCTAssertEqual(ReviewMemory.load(dir).map(\.text), ["Retries without jitter are fine in tests/ fixtures"])
        for i in 0..<ReviewMemory.maxRules + 5 { ReviewMemory.learn("rule \(i)", root: dir) }
        XCTAssertEqual(ReviewMemory.load(dir).count, ReviewMemory.maxRules, "bounded; the oldest go first")
    }
}
