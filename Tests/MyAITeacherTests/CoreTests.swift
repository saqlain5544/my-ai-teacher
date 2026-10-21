import XCTest
@testable import MyAITeacher

final class CoreTests: XCTestCase {
    func testThinkTagSplitterAcrossChunks() {
        var s = ThinkTagSplitter()
        var thinking = "", text = ""
        for chunk in ["<thi", "nk>The user", " asks</th", "ink>\n\nHello", " world"] {
            for e in s.feed(chunk) {
                if case .thinking(let t) = e { thinking += t }
                if case .text(let t) = e { text += t }
            }
        }
        for e in s.flush() { if case .text(let t) = e { text += t } }
        XCTAssertEqual(thinking, "The user asks")
        XCTAssertEqual(text, "Hello world")
    }

    func testJSONRepair() {
        let j = PartialToolCall.repair(#"{"a": "hel"#)
        XCTAssertEqual(j["a"]?.string, "hel")
        XCTAssertEqual(PartialToolCall.repair(#"{"x":[1,2"#)["x"]?.array?.count, 2)
    }

    func testFSRSIntervalsGrow() {
        var s = FSRS.State(stability: 0, difficulty: 0, reps: 0, lapses: 0, lastReview: nil)
        var now = Date()
        var last = 0.0
        for _ in 0..<4 {
            let (n, days) = FSRS.review(s, rating: .good, now: now)
            XCTAssertGreaterThan(days, last)
            last = days; s = n
            now = now.addingTimeInterval(days * 86400)
        }
        let (_, again) = FSRS.review(s, rating: .again, now: now)
        XCTAssertLessThan(again, 1)
    }

    func testBKT() {
        var p = 0.2
        for _ in 0..<6 { p = BKT.update(p, correct: true) }
        XCTAssertGreaterThan(p, 0.9)
        XCTAssertLessThan(BKT.update(0.9, correct: false), 0.9)
    }

    func testGlobRegex() throws {
        let re = try NSRegularExpression(pattern: GlobTool.globToRegex("**/*.py"))
        let ok = { (s: String) in re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
        XCTAssertTrue(ok("a/b/c.py")); XCTAssertTrue(ok("c.py")); XCTAssertFalse(ok("c.pyc"))
        let re2 = try NSRegularExpression(pattern: GlobTool.globToRegex("*.{js,ts}"))
        XCTAssertTrue(re2.firstMatch(in: "src/x.ts", range: NSRange(location: 0, length: 8)) != nil)
    }

    func testHTMLToMarkdown() {
        let html = """
        <html><head><title>T</title></head><body><nav>menu</nav><article><h2>Heading</h2><p>Hello <b>bold</b> and <a href="/x">link</a>.</p>
        <ul><li>one</li><li>two</li></ul><pre><code class="language-python">print(1)</code></pre></article></body></html>
        """
        let r = HTMLToMarkdown.convert(html: html, baseURL: URL(string: "https://example.com/a/"))
        XCTAssertEqual(r.title, "T")
        XCTAssertTrue(r.markdown.contains("## Heading"), r.markdown)
        XCTAssertTrue(r.markdown.contains("**bold**"), r.markdown)
        XCTAssertTrue(r.markdown.contains("[link](https://example.com/x)"), r.markdown)
        XCTAssertTrue(r.markdown.contains("- one"), r.markdown)
        XCTAssertTrue(r.markdown.contains("```python"), r.markdown)
        XCTAssertFalse(r.markdown.contains("menu"))
    }

    func testAnthropicConversionMergesAndCaches() {
        let msgs = [
            ChatMessage(role: .user, blocks: [.text("hi")]),
            ChatMessage(role: .assistant, blocks: [.toolUse(id: "t1", name: "math", input: ["x": 1])], model: "m"),
            ChatMessage(role: .user, blocks: [.toolResult(id: "t1", name: "math", content: "2")]),
        ]
        let out = AnthropicClient.convert(msgs, model: "m")
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[2]["content"]?[0]?["type"]?.string, "tool_result")
        XCTAssertNotNil(out[2]["content"]?[0]?["cache_control"])
    }

    func testMathSafety() {
        XCTAssertTrue(MathTool.safe("integrate(x**2*sin(x), x)"))
        XCTAssertFalse(MathTool.safe("__import__('os').system('ls')"))
        XCTAssertFalse(MathTool.safe("open('/etc/passwd')"))
    }

    func testReflectionJSONExtraction() {
        let j = Reflection.extractJSON("<think>hmm {not json}</think>\nHere: ```json\n{\"operations\":[{\"op\":\"add\",\"content\":\"a}b\"}]}\n```")
        XCTAssertEqual(j?["operations"]?[0]?["content"]?.string, "a}b")
    }

    func testJSONFromFoundationKeepsZeroAndOneAsNumbers() {
        let j = JSON(any: [NSNumber(value: 1), NSNumber(value: 0), NSNumber(value: 2.5), true, NSNumber(value: false)] as [Any])
        XCTAssertEqual(j, [1, 0, 2.5, true, false])
    }

    // MARK: Deadlines (tools must never hang a lesson)

    func testDeadlineReturnsTheResult() async throws {
        let v = try await withDeadline(seconds: 5) { 42 }
        XCTAssertEqual(v, 42)
    }

    func testDeadlineAbandonsWorkThatIgnoresCancellation() async {
        let t0 = Date()
        do {
            _ = try await withDeadline(seconds: 0.3) { () async -> Int in
                await withCheckedContinuation { (_: CheckedContinuation<Void, Never>) in }   // never resumes, ignores cancel
                return 1
            }
            XCTFail("should time out")
        } catch let e as TimeoutError {
            XCTAssertEqual(e.seconds, 0.3)
        } catch { XCTFail("wrong error \(error)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }

    func testDeadlineFollowsCallerCancellation() async {
        let t0 = Date()
        let task = Task { try await withDeadline(seconds: 30) { try await Task.sleep(nanoseconds: 20_000_000_000); return 1 } }
        try? await Task.sleep(nanoseconds: 100_000_000)
        task.cancel()
        let r = await task.result
        if case .success = r { XCTFail("should be cancelled") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2)
    }

    func testToolTimeoutsCoverEveryNonInteractiveTool() {
        for t in ToolRegistry.all {
            let limit = t.timeout(.object([:]))
            if t.risk == .interactive { XCTAssertNil(limit, t.name) } else { XCTAssertNotNil(limit, t.name); XCTAssertLessThanOrEqual(limit ?? 0, 700, t.name) }
        }
        XCTAssertEqual(WebSearchTool().timeout(.object([:])), 30)
        XCTAssertGreaterThan(TaskTool().timeout(.object([:])) ?? 0, SubAgent.budget)
    }
}
