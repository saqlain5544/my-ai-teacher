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

    /// A page of unclosed, deeply nested lists once took 90 s of CPU and 14 GB in the converter; it must stay fast and bounded.
    func testHTMLToMarkdownSurvivesPathologicalNesting() {
        let item = String(repeating: "word ", count: 400)
        let html = "<html><body>" + String(repeating: "<ul><li><b>\(item)</b><a href=\"/x\">\(item)</a>", count: 600) + "</body></html>"
        let t0 = Date()
        let r = HTMLToMarkdown.convert(html: html, baseURL: URL(string: "https://example.com/"))
        let secs = Date().timeIntervalSince(t0)
        XCTAssertLessThan(secs, 3, "took \(secs)s")
        XCTAssertTrue(r.markdown.contains("word word"), String(r.markdown.prefix(200)))
        XCTAssertLessThanOrEqual(r.markdown.count, HTMLToMarkdown.maxOutput + 1000)
    }

    /// The one-pass preprocessor does what the eight regex passes did (comments, scripts/styles/SVG/templates and plain
    /// MathML out; TeX lifted from annotations; HTML5 blocks to divs, inline tags to spans), case-insensitively.
    func testHTMLPreprocessMatchesTheRegexPasses() {
        func regexes(_ html: String) -> String {
            var s = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
            s = s.replacingOccurrences(of: "<(script|style|noscript|svg|template)\\b[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<math\\b([^>]*)>(?:(?!</math>)[\\s\\S])*?<annotation[^>]*encoding=\"application/x-tex\"[^>]*>([\\s\\S]*?)</annotation>(?:(?!</math>)[\\s\\S])*?</math>",
                                       with: "<span data-tex=\"1\"$1>$2</span>", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "<math\\b[\\s\\S]*?</math>", with: "", options: [.regularExpression, .caseInsensitive])
            let blocks = "article|main|nav|footer|aside|header|section|figure|figcaption|details|summary|hgroup|address|search|dialog"
            s = s.replacingOccurrences(of: "<(\\/?)(\(blocks))\\b", with: "<$1div data-h5=\"$2\"", options: [.regularExpression, .caseInsensitive])
            s = s.replacingOccurrences(of: "</div data-h5=\"[a-z]+\"", with: "</div", options: .regularExpression)
            return s.replacingOccurrences(of: "<(\\/?)(mark|time|picture|data|bdi|output)\\b", with: "<$1span", options: [.regularExpression, .caseInsensitive])
        }
        let pages = [
            "<html><head><title>T</title><style>p{}</style><script>var a = 1 < 2;</script></head><body><!-- note --><nav><a href='/'>home</a></nav>",
            "<main><article class=\"x\"><header><h1>Hi</h1></header><section><p>Text <mark>marked</mark> at <time datetime=\"2026\">now</time>.</p></section></article></main>",
            "<p>Inline <math display=\"block\"><semantics><mrow><mi>E</mi></mrow><annotation encoding=\"application/x-tex\">E = mc^2</annotation></semantics></math> and plain <math><mi>x</mi></math>.</p>",
            "<figure><picture><img src=\"a.png\"></picture><figcaption>Cap</figcaption></figure><details><summary>More</summary><p>hidden</p></details>",
            "<SCRIPT type=\"text/javascript\">x()</SCRIPT><Svg><path/></Svg><template><p>t</p></template><noscript>js off</noscript><mainly>not a tag we map</mainly>",
            "<data value=\"7\">seven</data> <output>out</output> <bdi>ب</bdi> <timeline>kept</timeline> <dialog open>d</dialog> <search>s</search> <hgroup><h2>h</h2></hgroup> <address>a</address> <aside>x</aside> <footer>f</footer>",
            "<p>unterminated <!-- comment and <script> without an end",
            "<p>é ü 漢字 😀 <mark>ü</mark></p>",
        ]
        for p in pages + [pages.joined()] { XCTAssertEqual(HTMLToMarkdown.preprocess(p), regexes(p), p) }
    }

    /// A 3 MB page: the regex passes grew the footprint by ~65 MB (kept by the allocator); one pass stays near the page's size.
    func testHTMLPreprocessMemoryStaysNearThePageSize() {
        func footprintMB() -> Double {
            var info = task_vm_info_data_t(), count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
            _ = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) } }
            return Double(info.phys_footprint) / 1_048_576
        }
        let unit = "<section><h2>S</h2><p>Light-dependent reactions make <b>ATP</b> and <mark>NADPH</mark>.</p><!-- c --><script>x++</script>" +
            "<math><semantics><mi>E</mi><annotation encoding=\"application/x-tex\">E = h\\nu</annotation></semantics></math></section>"
        let html = "<html><body><main>" + String(repeating: unit, count: 3_000_000 / unit.utf8.count) + "</main></body></html>"
        let before = footprintMB()
        let out = autoreleasepool { HTMLToMarkdown.preprocess(html) }
        let grew = footprintMB() - before
        print(String(format: "PREPROCESS 3 MB: footprint +%.1f MB", grew))
        XCTAssertTrue(out.contains("<div data-h5=\"section\">") && out.contains("<span data-tex=\"1\">E = h\\nu</span>") && !out.contains("x++"))
        XCTAssertLessThan(grew, 30)
    }

    /// The fetch tool's deadline cancels the task; the converter must notice instead of burning CPU after the tool gave up.
    func testHTMLToMarkdownStopsWhenCancelled() async {
        let html = "<html><body>" + String(repeating: "<p>" + String(repeating: "word ", count: 50) + "</p>", count: 20_000) + "</body></html>"
        let task = Task { HTMLToMarkdown.convert(html: html, baseURL: nil).markdown.count }
        task.cancel()
        let n = await task.value
        XCTAssertLessThan(n, 100_000)
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
        XCTAssertGreaterThan(TaskTool().timeout(.object([:])) ?? 0, Double(SubAgentSettings().seconds))
    }

    func testLongLessonsLoadAsAWindow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("win-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Services(global: GlobalStore(), workspace: try Workspace(url: dir)).conversations
        let msgs = (0..<1000).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, blocks: [.text("m\($0)")]) }
        for (i, m) in msgs.enumerated() { store.upsert(m, conversationID: "L", seq: i) }
        XCTAssertEqual(store.messageCount("L"), 1000)
        let tail = store.messages("L", from: 600)
        XCTAssertEqual(tail.count, 400); XCTAssertEqual(tail.first?.plainText, "m600")
        XCTAssertEqual(store.messages("L", from: 400, to: 600).map(\.plainText).last, "m599")
        XCTAssertEqual(store.seq(ofMessage: msgs[742].id), 742)
    }

    /// Lesson search ranks only the newest matches with a rowid range; `rowid IN (subquery)` ran one full-text lookup per
    /// rowid (64 s on 200k messages). A common word over many messages must stay fast, and the newest lesson wins.
    func testLessonSearchStaysFastOnCommonWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("fts-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = Services(global: GlobalStore(), workspace: try Workspace(url: dir)).conversations
        try store.db.execute("BEGIN")
        for i in 0..<20_000 {
            store.upsert(ChatMessage(role: .user, blocks: [.text("momentum and energy in collisions, part \(i)" + (i == 77 ? " zebrafish" : ""))]),
                         conversationID: "L\(i / 2_000)", seq: i % 2_000)
        }
        try store.db.execute("COMMIT")
        let t = Date()
        let hits = store.search("momentum energy")
        XCTAssertLessThan(Date().timeIntervalSince(t), 1.0)
        XCTAssertEqual(hits.first?.id, "L9", "newest matches are the ones ranked")
        XCTAssertEqual(store.search("zebrafish").map(\.id), ["L0"], "a rare word is found anywhere")
    }

    func testGradingReadsNumbersAndKeepsMeaningfulPunctuation() {
        let cases: [(String, Double)] = [("12 seconds", 12), ("12 m/s", 12), ("1 1/2", 1.5), ("3/4", 0.75), ("3,5", 3.5), ("1,234", 1234),
                                         ("5%", 5), ("10^3", 1000), ("2.5e3", 2500), ("−4", -4), ("about 9.81 m/s²", 9.81)]
        for (s, v) in cases { XCTAssertEqual(Questions.number(.string(s))!, v, accuracy: 1e-9, s) }
        XCTAssertNotEqual(Questions.norm("-5"), Questions.norm("5"))
        XCTAssertNotEqual(Questions.norm("C#"), Questions.norm("C"))
        XCTAssertNotEqual(Questions.norm("3.14"), Questions.norm("3 14"))
        XCTAssertEqual(Questions.norm("Paris!"), Questions.norm("paris"))
    }

    func testFSRSIntervalsAreBounded() {
        var st = FSRS.State(stability: 0, difficulty: 0, reps: 0, lapses: 0, lastReview: nil)
        var now = Date(), days = 0.0
        for _ in 0..<30 { (st, days) = FSRS.review(st, rating: .easy, now: now); now = now.addingTimeInterval(days * 86_400) }
        XCTAssertLessThanOrEqual(st.stability, FSRS.maxStability)
        XCTAssertLessThan(days, 365 * 12, "longest interval about a decade")
    }

    /// The page renders the newest messages of the window, starting at a learner's message so no tool result lands
    /// without its card.
    @MainActor
    func testTranscriptPageStartsAtALearnerTurn() {
        let msgs = (0..<1000).map { PerfSeed.message($0) }   // turns of four: question, tool call, tool result, reply
        typealias C = TranscriptView.Coordinator
        XCTAssertEqual(C.pageStart(Array(msgs.prefix(200)), keep: C.pageWindow), 0, "a short lesson renders whole")
        let start = C.pageStart(msgs, keep: C.pageWindow)
        XCTAssertEqual(start, 700, "the newest 300, already at a question")
        let odd = C.pageStart(msgs, keep: 301)
        XCTAssertTrue(msgs[odd].role == .user && !msgs[odd].isToolResultOnly && odd >= 1000 - 301 && odd < 1000 - 301 + 4, "\(odd)")
    }

    /// The transcript gets each message as JSON text in one pass; it must say exactly what the JSON-tree route said.
    @MainActor
    func testTranscriptScriptMatchesTheJSONTree() {
        var m = ChatMessage(role: .assistant, blocks: [.text("Say \"hi\" </script>\u{2028} é 𝑥\n$x^2$"), .thinking("plan", signature: "sig"),
                                                       .toolUse(id: "t1", name: "read", input: ["path": "/tmp/a b", "n": 3, "deep": ["k": [1, true, .null]]])],
                            model: "m")
        m.turn = TurnMetrics(startedAt: Date(timeIntervalSince1970: 1_700_000_000.25), duration: 1.5, steps: 2)
        m.meta = ["recalled": [["id": "12", "score": 0.82]]]
        let r = ChatMessage(role: .user, blocks: [.toolResult(id: "t1", name: "read", content: "1\tok", isError: false, meta: ["ms": 12.5])])
        for msg in [m, r] {
            XCTAssertEqual(JSON.parse(TranscriptView.Coordinator.script(msg)), TranscriptView.Coordinator.encode(msg))
        }
    }

    @MainActor
    func testChangesPanelTracksEditsAndCheckpoints() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("chg-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        try "a\nb\n".write(to: dir.appendingPathComponent("x.py"), atomically: true, encoding: .utf8)
        _ = try Workspace(url: dir)   // creates .teacher with its state database
        let m = ChangesModel()
        await m.reload(dir)
        XCTAssertEqual(m.state, .notRepo)
        await m.initRepo(dir)
        XCTAssertEqual(m.state, .ready); XCTAssertTrue(m.files.isEmpty, "starting point recorded")
        try "a\nB\nc\n".write(to: dir.appendingPathComponent("x.py"), atomically: true, encoding: .utf8)
        try "new\n".write(to: dir.appendingPathComponent("y.txt"), atomically: true, encoding: .utf8)
        await m.reload(dir)
        let x = m.files.first { $0.path == "x.py" }, y = m.files.first { $0.path == "y.txt" }
        XCTAssertEqual(x?.status, "M"); XCTAssertEqual(x?.added, 2); XCTAssertEqual(x?.removed, 1)
        XCTAssertEqual(y?.status, "??")
        XCTAssertFalse(m.files.contains { $0.path.hasPrefix(".teacher/state") }, "the app's lesson data is never a change: \(m.files.map(\.path))")
        await m.loadDiff(dir, "x.py")
        XCTAssertTrue(m.diff.contains("+B") && m.diff.contains("-b"), "\(m.diff)")
        await m.checkpoint(dir)
        XCTAssertTrue(m.files.isEmpty); XCTAssertTrue(m.lastCommit?.hasPrefix("Checkpoint") == true)
    }
}
