import XCTest
@testable import MyAITeacher

/// The code mentor's views of running code: `trace` (a real Python run, step by step) and `bench` (timings over input
/// sizes, with the growth they fit).
final class CodeLabTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("codelab-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx() -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: "l", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }
    func need(_ tool: String) throws { if ProcessRunner.which(tool) == nil { throw XCTSkip("\(tool) is not installed") } }

    func testTheCodeMentorHasTheToolsAndViews() {
        let core = AgentTree.core("code-mentor")
        XCTAssertTrue(core.contains("trace") && AgentTree.deferred("code-mentor").contains("bench"))
        XCTAssertFalse(AgentTree.core("tutor").contains("trace"), "a code mentor's tools, not every teacher's")
        for c in ["trace", "annotate", "predict"] { XCTAssertTrue(AgentTree.components("code-mentor").contains(c), c) }
        // They run code like `run_code`: the Python setting for Python, one lesson grant for all three.
        XCTAssertTrue(PermissionExtension.isPython(TraceTool(), [:]))
        XCTAssertTrue(PermissionExtension.isPython(BenchTool(), ["language": "python"]))
        XCTAssertFalse(PermissionExtension.isPython(BenchTool(), ["language": "javascript"]))
        XCTAssertTrue(PermissionExtension.runsSnippets(BenchTool()) && PermissionExtension.runsSnippets(RunCodeTool()))
        XCTAssertNotNil(PermissionExtension.packageInstall(tool: BenchTool(), input: ["code": "import os\nos.system('pip install numpy')"]))
    }

    func testGrowthFitsTheSimplestModelWithinNoise() {
        let n = BenchTool.defaultSizes
        func fit(_ f: (Double) -> Double, noise: [Double] = [1, 1.04, 0.97, 1.03, 0.98]) -> String? {
            CodeLab.fit(sizes: n, seconds: n.enumerated().map { i, x in f(Double(x)) * noise[i] })?.model
        }
        XCTAssertEqual(fit { _ in 3e-6 }, "O(1)", "flat with noise is not O(log n)")
        XCTAssertEqual(fit { 2e-7 * log($0) }, "O(log n)")
        XCTAssertEqual(fit { 1e-8 * $0 }, "O(n)")
        XCTAssertEqual(fit { 1e-8 * $0 * log($0) }, "O(n log n)")
        XCTAssertEqual(fit { 1e-11 * $0 * $0 }, "O(n²)")
        XCTAssertEqual(CodeLab.fit(sizes: [10, 14, 18, 22], seconds: [10, 14, 18, 22].map { pow(2, Double($0)) * 1e-8 })?.model, "O(2ⁿ)")
        XCTAssertNil(CodeLab.fit(sizes: n, seconds: [1e-3, 2e-3, nil, nil, nil]), "two timed sizes are no curve")
        let slope = CodeLab.fit(sizes: n, seconds: n.map { 1e-11 * Double($0) * Double($0) })!.exponent
        XCTAssertEqual(slope, 2, accuracy: 0.01)
    }

    func testBenchFindsJavaScriptVariantsAndReadsTheMarker() {
        let code = "function setup(n) { return [] }\nfunction run_list(x) {}\nexport const run_set = x => x\nlet runner = 1\nasync function run(x) {}"
        XCTAssertEqual(BenchTool.jsNames(code, "run"), ["run_list", "run_set", "run"])
        XCTAssertEqual(BenchTool.jsNames(code + "\nconst setup_set = n => new Set()", "setup"), ["setup", "setup_set"])
        XCTAssertEqual(CodeLab.marked("hello @@CODELAB@@ in output\n@@CODELAB@@{\"a\":1}\n")?["a"]?.int, 1, "the last marker: the program's own output comes first")
        let out = CodeLab.benchOutput(sizes: [1000, 3000, 10000], series: [CodeLab.Series(name: "list", seconds: [0.001, 0.003, nil])])
        XCTAssertTrue(out.text.contains("list: too few sizes timed") && out.text.contains("—"), out.text)
        XCTAssertEqual(out.meta?["series"]?[0]?["times"]?[2], .null)
    }

    func testTraceStepsIntoTheLessonsModulesAndNarratesChanges() async throws {
        try need("python3")
        try "def total(items):\n    s = 0\n    for price in items:\n        s += price\n    return s\n".write(to: dir.appendingPathComponent("shop.py"), atomically: true, encoding: .utf8)
        let code = "from shop import total\na = [3, 1]\nb = a\nb.append(2)\nprint(total(a))\nclass P:\n    def __init__(self, x): self.x = x\np = P(5)\n"
        let out = try await TraceTool().run(["code": .string(code)], await ctx())
        XCTAssertFalse(out.isError, out.text)
        for line in ["b.append(2) → a=[3, 1, 2], b=[3, 1, 2]", "→ total(items=[3, 1, 2])", "shop.py:4 s += price → s=3", "← total returned 6",
                     "printed \"6\\n\"", "p = P(5) → p=P(x=5)", "end: a=[3, 1, 2], b=[3, 1, 2], p=P(x=5)"] {
            XCTAssertTrue(out.text.contains(line), "missing \(line) in:\n\(out.text)")
        }
        let meta = try XCTUnwrap(out.meta)
        XCTAssertEqual(meta["files"]?["shop.py"]?.string?.hasPrefix("def total"), true, "the module's source, for the stepper")
        XCTAssertNil(meta["summary"], "the summary is the model's, the steps the card's")
        let last = try XCTUnwrap(meta["steps"]?.array?.last)
        XCTAssertEqual(last["e"]?.string, "end")
        let vars = last["s"]?[0]?["v"]
        XCTAssertEqual(vars?["a"]?["r"], vars?["b"]?["r"], "a and b are one object: one badge")
        XCTAssertNotNil(vars?["a"]?["r"]?.int)
    }

    func testTraceReportsErrorsAndStopsAtTheLimit() async throws {
        try need("python3")
        let c = await ctx()
        let err = try await TraceTool().run(["code": "x = 1\ny = x / 0\n"], c)
        XCTAssertTrue(err.isError && err.text.contains("ZeroDivisionError") && err.text.contains("(main.py:2)"), err.text)
        XCTAssertTrue(err.text.contains("raised ZeroDivisionError"), "the step that raised")
        let loop = try await TraceTool().run(["code": "i = 0\nwhile True:\n    i += 1\n", "max_steps": 20], c)
        XCTAssertTrue(!loop.isError && loop.text.contains("Traced 20 steps — stopped at the limit"), loop.text)
        let syntax = try await TraceTool().run(["code": "def f(:\n  pass\n"], c)
        XCTAssertTrue(syntax.isError && syntax.text.contains("SyntaxError") && syntax.text.contains("main.py:1"), syntax.text)
    }

    func testBenchTimesPythonAndJavaScriptVariants() async throws {
        try need("python3")
        let c = await ctx()
        let py = try await BenchTool().run(["language": "python", "sizes": [200, 400, 800],
                                            "code": "def setup(n):\n    return list(range(n))\ndef run_sum(x):\n    sum(x)\ndef run_len(x):\n    len(x)\n"], c)
        XCTAssertFalse(py.isError, py.text)
        XCTAssertEqual(py.meta?["series"]?.array?.compactMap { $0["name"]?.string }, ["sum", "len"])
        XCTAssertTrue(py.text.contains("Growth: sum ≈"), py.text)
        let missing = try await BenchTool().run(["language": "python", "code": "def run(x):\n    pass\n"], c)
        XCTAssertTrue(missing.isError && missing.text.contains("setup(n)"), missing.text)
        // A variant's own input, built outside the timer: the set for run_set, not a set built in every timed call.
        let own = try await BenchTool().run(["language": "python", "sizes": [200, 400, 800], "code": "def setup(n):\n    return list(range(n))\ndef setup_set(n):\n    return set(range(n))\ndef run_list(x):\n    return type(x).__name__ == 'list' or 1 / 0\ndef run_set(x):\n    return type(x).__name__ == 'set' or 1 / 0\n"], c)
        XCTAssertFalse(own.isError, own.text)
        guard ProcessRunner.which("node") != nil else { return }
        let js = try await BenchTool().run(["language": "javascript", "sizes": [200, 400, 800],
                                            "code": "function setup(n) { return Array.from({length: n}, (_, i) => i) }\nfunction run(a) { return a.reduce((s, x) => s + x, 0) }"], c)
        XCTAssertFalse(js.isError, js.text)
        XCTAssertEqual(js.meta?["series"]?[0]?["name"]?.string, "run")
        let jsOwn = try await BenchTool().run(["language": "javascript", "sizes": [200, 400, 800],
                                               "code": "const setup_set = n => new Set(Array.from({length: n}, (_, i) => i))\nfunction run_set(s) { if (!(s instanceof Set)) throw new Error('not a set'); return s.has(1) }"], c)
        XCTAssertFalse(jsOwn.isError, jsOwn.text)
        XCTAssertEqual(jsOwn.meta?["series"]?[0]?["name"]?.string, "set")
    }
}
