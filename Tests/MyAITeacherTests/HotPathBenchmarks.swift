import XCTest
@testable import MyAITeacher

/// Timings of the hot paths a long reply or a tool-heavy lesson runs per step. Run with `BENCH=1 swift test --filter
/// HotPathBenchmarks` (release: add `-c release -Xswiftc -enable-testing`); without BENCH they only check the results.
final class HotPathBenchmarks: XCTestCase {
    let bench = ProcessInfo.processInfo.environment["BENCH"] != nil
    func time(_ name: String, _ body: () -> Void) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1e6
        if bench { print(String(format: "BENCH %-38@ %9.2f ms", name as NSString, ms)) }
    }
    var n: Int { bench ? 1 : 0 }

    func testStreamFold() {
        var m = ChatMessage(role: .assistant, blocks: [])
        let deltas = bench ? 60_000 : 2_000
        time("fold \(deltas) one-character deltas") { for _ in 0..<deltas { _ = ReplyBuilder.apply(.text("a"), to: &m) } }
        XCTAssertEqual(m.blocks.first?.text?.count, deltas)
    }

    func testParserOnPlainProse() {
        var p = TextProtocolParser(tools: [:])
        let chunk = "The derivative of x squared is two x, which you can check with the limit definition. "
        let chunks = bench ? 3_000 : 100
        var out = 0
        time("parse \(chunks) prose chunks") { for _ in 0..<chunks { out += p.feed(chunk).count } }
        XCTAssertGreaterThan(out, 0)
    }

    func testTokenEstimateWithLargeToolInputs() {
        let content = String(repeating: "let value = compute(input) // a line of code\n", count: 230)   // ~10 KB
        let msgs = (0..<100).map { i in
            ChatMessage(role: .assistant, blocks: [Block(kind: .toolUse, id: "t\(i)", name: "write", input: ["path": .string("f\(i).swift"), "content": .string(content)])])
        }
        var total = 0
        time("estimate 100×10 KB tool inputs (cold)") { total = ContextPolicy.estimateTokens(msgs) }
        time("estimate again ×3 (cached)") { for _ in 0..<3 { total = ContextPolicy.estimateTokens(msgs) } }
        XCTAssertGreaterThan(total, 100 * 2_000)
    }

    func testTokensOfEnglishText() {
        let s = String(repeating: "Plain English prose in a long lesson reply. ", count: 20_000)   // ~900 KB
        var t = 0
        time("tokens of 900 KB of ASCII") { t = ContextPolicy.estimate(s) }
        XCTAssertEqual(t, s.utf8.count / 4)
        XCTAssertEqual(ContextPolicy.estimate("日本語のテキスト"), 8, "CJK still one per character")
        XCTAssertEqual(ContextPolicy.estimate("café"), 1, "four non-CJK scalars")
    }

    func testToolSpecsPerStep() {
        var specs = 0
        time("tool specs for 20 steps (engineer)") {
            for _ in 0..<20 { specs += ToolRegistry.active(AppSettings(), loaded: [], mode: .agent).map(\.spec).count }
        }
        XCTAssertGreaterThan(specs, 200)
    }

    func testJSONCompactAndParse() {
        let input: JSON = ["path": "a.swift", "content": .string(String(repeating: "x = 1\n", count: 2_000)), "n": 3]
        var size = 0
        time("compact a 12 KB input ×2,000") { for _ in 0..<(bench ? 2_000 : 20) { size += input.compact.utf8.count } }
        let data = Data(#"{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hello"}}"#.utf8)
        time("parse an SSE event ×50,000") { for _ in 0..<(bench ? 50_000 : 100) { size += JSON.parse(data) == nil ? 0 : 1 } }
        XCTAssertGreaterThan(size, 0)
    }

    /// The fast serializer and parser agree with the Codable path they replaced.
    func testJSONMatchesTheCodablePath() throws {
        let v: JSON = ["b": true, "a": [1, 2.5, -3, 1e20, .null], "s": "quote \" back \\ nl \n tab \t ctl \u{01} slash / 日本 é 🙂",
                       "nested": ["z": "", "y": false, "x": 0]]
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let old = try XCTUnwrap(try? JSONDecoder().decode(JSON.self, from: enc.encode(v)))
        XCTAssertEqual(JSON.parse(v.compact), v, "round trip")
        XCTAssertEqual(JSON.parse(v.compact), old, "same value as the Codable path")
        XCTAssertEqual(v["nested"]?.compact, #"{"x":0,"y":false,"z":""}"#, "sorted keys, integral numbers without a fraction")
        XCTAssertEqual(JSON.parse("true"), .bool(true)); XCTAssertEqual(JSON.parse("1"), .number(1), "1 is a number, not true")
        XCTAssertEqual(JSON.parse("\"x\""), .string("x")); XCTAssertNil(JSON.parse("{bad"))
        XCTAssertEqual(JSON.number(.infinity).compact, "null")
        XCTAssertEqual(v.approxBytes, v.compact.utf8.count, accuracy: v.compact.utf8.count / 3, "approxBytes is about the size")
    }

    func testRepeatedQueryEmbeddingIsCached() {
        let q = "How does the chain rule work when one function is inside another? \(UUID().uuidString)"
        var a: [Float]?, b: [Float]?
        time("embed a new query") { a = Embedder.shared.vector(q) }
        time("embed the same query again") { b = Embedder.shared.vector(q) }
        XCTAssertEqual(a, b)
    }

    /// The page and text scans a web lesson runs: converting a fetched page, ranking its passages, indexing words.
    func testPageAndTextScans() {
        let row = "<p>Photosynthesis <a href=\"/wiki/Light\">light</a> reactions split <b>water</b> and release oxygen —\u{00A0}“quoted”.</p>\n"
        let html = "<html><head><title>T</title></head><body><div id=\"content\">" + String(repeating: row, count: bench ? 8_000 : 50) + "</div></body></html>"
        let prose = String(repeating: "The light reactions of photosynthesis happen in the thylakoid membranes — “quoted” text 1234. ", count: bench ? 10_000 : 100)
        var md = "", ws = "", terms: [String] = [], stems: [String] = []
        time("collapse whitespace, \(prose.utf8.count / 1000) KB") { ws = HTMLToMarkdown.collapseWhitespace(prose) }
        time("HTML→Markdown, \(html.utf8.count / 1000) KB page") { md = HTMLToMarkdown.convert(html: html, baseURL: URL(string: "https://en.wikipedia.org/wiki/X")).markdown }
        time("passage terms, \(prose.utf8.count / 1000) KB") { terms = Passages.terms(prose) }
        time("best passages of the page") { _ = Passages.best(md, query: "what splits water in photosystem II", budget: 6000) }
        time("memory stems, \(prose.utf8.count / 1000) KB") { stems = MemoryText.stems(prose, limit: 100_000) }
        XCTAssertEqual(ws.count, prose.count)
        XCTAssertTrue(md.contains("reactions split **water** and release oxygen — “quoted”."), String(md.prefix(200)))
        if bench, let page = ProcessInfo.processInfo.environment["BENCH_HTML"].flatMap({ try? String(contentsOfFile: $0, encoding: .utf8) }) {
            time("HTML→Markdown, \(page.utf8.count / 1000) KB real page") { md = HTMLToMarkdown.convert(html: page, baseURL: URL(string: "https://en.wikipedia.org/wiki/X")).markdown }
            time("best passages of the real page") { _ = Passages.best(md, query: "what splits water in photosystem II", budget: 6000) }
        }
        XCTAssertTrue(terms.contains("reaction") && terms.contains("thylakoid"))
        XCTAssertTrue(stems.contains("photosynthesi") || stems.contains("photosynthesis"), "\(stems.prefix(8))")
    }
}
