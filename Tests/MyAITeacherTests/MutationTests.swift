import XCTest
@testable import MyAITeacher

/// How good the learner's tests are: mutation testing on a scratch copy, test coverage, and growth fits with their
/// confidence. Real small projects in temp folders; toolchains that are missing skip.
final class MutationTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mutation-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func need(_ tool: String) throws { if ProcessRunner.which(tool) == nil { throw XCTSkip("\(tool) is not installed") } }
    func put(_ rel: String, _ text: String) throws {
        let u = dir.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: u, atomically: true, encoding: .utf8)
    }
    func scratchCount() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []).filter { $0.hasPrefix(Scratch.prefix) }.count }
    func snapshot() -> [String: Data] {
        var out: [String: Data] = [:]
        for rel in ProjectStore.walk(dir) where !rel.hasPrefix(".teacher/state") { out[rel] = FileManager.default.contents(atPath: dir.appendingPathComponent(rel).path) }
        return out
    }

    static let pySource = """
    def clamp(x, lo, hi):
        if x < lo:
            return lo
        if x > hi:
            return hi
        return x

    def total(xs):
        t = 0
        for x in xs:
            t = t + x
        return t

    def is_adult(age):
        # age >= 18 is the rule
        msg = "age > 18 and True"
        return age >= 18
    """
    static let pyWeak = "import sys; sys.path.insert(0, '.')\nfrom calc import *\nassert clamp(5, 0, 10) == 5\nassert total([1, 2, 3]) == 6\nassert is_adult(30)\n"
    static let pyStrong = pyWeak + "assert clamp(-1, 0, 10) == 0 and clamp(11, 0, 10) == 10 and clamp(0, 0, 10) == 0 and clamp(10, 0, 10) == 10\nassert total([]) == 0\nassert is_adult(18) and not is_adult(17)\n"
    let pyCommand = "python3 .teacher/tests/test_calc.py"

    func python(tests: String) throws -> Workspace {
        try put("calc.py", Self.pySource)
        try put(".teacher/tests/test_calc.py", tests)
        return try Workspace(url: dir)
    }

    // MARK: Reading code, not text

    func testComments_strings_andRegexesAreNeverMutated() {
        let py = "x = a < b  # c < d\ns = \"a < b == c\"\nd = '''\nx < y\n'''\nif k > 1 and ok: pass\n"
        let ms = Mutator.mutants(file: "a.py", text: py)
        XCTAssertTrue(ms.allSatisfy { $0.line != 2 && $0.line != 4 && $0.line != 5 }, "\(ms.map { "\($0.line) \($0.kind)" })")
        XCTAssertTrue(ms.contains { $0.line == 1 && $0.kind == "< → <=" }, "code on a line with a comment is still code")
        XCTAssertFalse(ms.contains { $0.line == 1 && $0.mutated.contains("c <= d") }, "the comment is untouched")
        let js = "const re = /a+b == c/g;\nconst t = `x < ${a + b}`;\n// if (a == b) {}\n/* a < b */\nlet ok = a == b;\n"
        let jm = Mutator.mutants(file: "a.js", text: js)
        XCTAssertEqual(Set(jm.map(\.line)), [5], "\(jm.map { "\($0.line) \($0.kind)" })")
        let rs = "fn f<'a>(x: &'a str) -> char { let c = '<'; if x.len() > 3 { c } else { 'z' } }\n"
        XCTAssertTrue(Mutator.mutants(file: "a.rs", text: rs).allSatisfy { !$0.mutated.contains("'<=") }, "a char literal is not an operator")
    }

    func testMutantsKeepTheLineValid() {
        let src = "def f(a, b):\n    if a and b:\n        return a + b\n    helper(a)\n    return b\n"
        let ms = Mutator.mutants(file: "m.py", text: src)
        let kinds = Set(ms.map(\.kind))
        for k in ["and → or", "+ → -", "negated condition", "return dropped", "call dropped"] { XCTAssertTrue(kinds.contains(k), "\(k) in \(kinds)") }
        XCTAssertEqual(ms.first { $0.kind == "negated condition" }?.newLine, "    if not (a and b):")
        XCTAssertEqual(ms.first { $0.kind == "call dropped" }?.newLine, "    pass")
        XCTAssertTrue(Mutator.mutants(file: "m.swift", text: "func f(a: Int) -> Int {\n    if a > 0 {\n        return a\n    }\n    return 0\n}\n").contains { $0.kind == "negated condition" && $0.newLine == "    if !(a > 0) {" })
    }

    func testSelectionSpreadsAcrossFunctionsAndPrefersChangedCode() {
        var text = ""
        for f in 0..<5 { text += "def f\(f)(a):\n" + (0..<6).map { "    x\($0) = a + \($0 + 2)\n" }.joined() + "    return a\n" }
        let all = Mutator.mutants(file: "m.py", text: text)
        let spread = Mutator.select(all, limit: 5)
        XCTAssertEqual(Set(spread.compactMap(\.function)).count, 5, "one from each function before a second from any")
        let changed = Mutator.mutants(file: "m.py", text: text, changed: [20...22])   // inside f2
        XCTAssertEqual(Mutator.select(changed, limit: 1).first?.function, "f2", "code the learner changed comes first")
    }

    // MARK: The runs

    func testWeakTestsLeaveSurvivorsAndStrongTestsKillThem() async throws {
        try need("python3")
        let ws = try python(tests: Self.pyWeak)
        let before = snapshot(), scratch = scratchCount()
        let weak = await Mutation.run(ws: ws, command: pyCommand, only: [], limit: 60, budget: 240, progress: { _ in })
        XCTAssertNil(weak.note, weak.note ?? "")
        XCTAssertGreaterThan(weak.survivors.count, 0, Mutation.render(weak))
        XCTAssertTrue(weak.survivors.contains { $0.mutant.file == "calc.py" && $0.mutant.original.contains("age >= 18") }, Mutation.render(weak))
        XCTAssertFalse(weak.outcomes.contains { $0.mutant.original.contains("age > 18 and True") || $0.mutant.original.hasPrefix("#") }, "strings and comments are never mutated")
        XCTAssertEqual(snapshot(), before, "the learner's files are byte-identical afterwards")
        XCTAssertEqual(scratchCount(), scratch, "the scratch copy is gone")

        try Self.pyStrong.write(to: ws.testsDir.appendingPathComponent("test_calc.py"), atomically: true, encoding: .utf8)
        let strong = await Mutation.run(ws: ws, command: pyCommand, only: [], limit: 60, budget: 240, progress: { _ in })
        XCTAssertGreaterThan(strong.score ?? 0, weak.score ?? 1, "stronger tests, higher score")
        XCTAssertFalse(strong.survivors.contains { $0.mutant.original.contains("age >= 18") && $0.mutant.kind == ">= → >" }, "the boundary test kills it")
        // Survivors teach: the rendered result asks, it does not hand over a test.
        let text = Mutation.render(weak)
        XCTAssertTrue(text.contains("was:") && text.contains("now:") && text.contains("what test would catch"), text)
        XCTAssertFalse(text.contains("def test"), "no test is written for the learner")
    }

    func testARedBaselineStopsBeforeAnyMutant() async throws {
        try need("python3")
        let ws = try python(tests: "assert False, 'red'\n")
        let r = await Mutation.run(ws: ws, command: pyCommand, only: [], limit: 20, budget: 120, progress: { _ in })
        XCTAssertTrue(r.outcomes.isEmpty)
        XCTAssertTrue(Mutation.render(r).contains("baseline is red"), Mutation.render(r))
        XCTAssertEqual(scratchCount(), 0)
    }

    func testJavaScriptProjectAndDefaultLimits() async throws {
        try need("node")
        try put("calc.js", "function older(a, b) {\n  return a >= b;\n}\nfunction sum(xs) {\n  let t = 0;\n  for (const x of xs) { t = t + x; }\n  return t;\n}\nmodule.exports = { older, sum };\n")
        try put(".teacher/tests/calc.test.js", "const a = require('assert'); const { older, sum } = require('../../calc');\na.strictEqual(older(5, 3), true);\na.strictEqual(sum([1, 2]), 3);\n")
        let ws = try Workspace(url: dir)
        let r = await Mutation.run(ws: ws, command: "node .teacher/tests/calc.test.js", only: [], limit: 100, budget: 120, progress: { _ in })
        XCTAssertNil(r.note, r.note ?? "")
        XCTAssertTrue(r.survivors.contains { $0.mutant.original.contains("a >= b") }, Mutation.render(r))
        XCTAssertGreaterThan(r.killed, 0)
        XCTAssertEqual(MutateTool().timeout(["seconds": 5000]), 960, "the budget is capped at 900 s")
    }

    func testStopLeavesNoProcessesAndNoScratchFolder() async throws {
        try need("python3")
        let ws = try python(tests: "import time\ntime.sleep(1)\n")
        let before = scratchCount()
        let task = Task { await Mutation.run(ws: ws, command: "python3 .teacher/tests/test_calc.py", only: [], limit: 60, budget: 300, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 3_500_000_000)   // past the baseline, mutants running
        task.cancel()
        let r = await task.value
        XCTAssertTrue(r.note?.hasPrefix("Stopped") == true || r.outcomes.count < r.planned, "\(r.note ?? "")")
        try await Task.sleep(nanoseconds: 2_500_000_000)
        XCTAssertEqual(scratchCount(), before, "no scratch folder is left")
        let ps = await ProcessRunner.run("/usr/bin/pgrep", ["-f", "aiteacher-scratch"], timeout: 10)
        XCTAssertTrue(ps.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, "no mutant process is left: \(ps.stdout)")
    }

    func testLearnerEditsMadeWhileItRunsAreNotTouched() async throws {
        try need("python3")
        let ws = try python(tests: "import time\ntime.sleep(0.5)\n" + Self.pyWeak)
        let task = Task { await Mutation.run(ws: ws, command: self.pyCommand, only: [], limit: 8, budget: 120, progress: { _ in }) }
        try await Task.sleep(nanoseconds: 1_200_000_000)
        try "# the learner kept working\n".write(to: dir.appendingPathComponent("notes.py"), atomically: true, encoding: .utf8)
        let source = try String(contentsOf: dir.appendingPathComponent("calc.py"), encoding: .utf8)
        try (source + "\n# edited during the run\n").write(to: dir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        _ = await task.value
        XCTAssertTrue(try String(contentsOf: dir.appendingPathComponent("calc.py"), encoding: .utf8).hasSuffix("# edited during the run\n"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("notes.py").path))
    }

    func testTheResultIsStoredForTheCurrentFilesOnlyAndIsNeverAGate() async throws {
        try need("python3")
        let ws = try python(tests: Self.pyWeak)
        let r = await Mutation.run(ws: ws, command: pyCommand, only: [], limit: 6, budget: 120, progress: { _ in })
        Mutation.save(r, ws: ws)
        XCTAssertNotNil(Mutation.summaryLine(ws: ws))
        XCTAssertEqual(MentorProject.TestRun(at: Date(), passed: 1, failed: 0, errored: false, seconds: 1, failing: [], exit: 0, why: "run").green, true)
        try "\n# changed\n".write(to: dir.appendingPathComponent("calc.py"), atomically: true, encoding: .utf8)
        XCTAssertNil(Mutation.summaryLine(ws: ws), "files changed since: no stale line")
    }

    @MainActor func testRegistrationGatesAndTeaching() {
        XCTAssertTrue(AgentTree.deferred("code-mentor").contains("mutate") && AgentTree.deferred("code-mentor").contains("coverage"))
        XCTAssertFalse(AgentTree.deferred("tutor").contains("mutate"))
        XCTAssertTrue(MentorGuard.commands.contains("mutate") && MentorGuard.commands.contains("coverage"), "same fence as run_tests")
        XCTAssertEqual(PermissionExtension.runsTests(MutateTool(), [:]), true, "the tests grant covers it")
        XCTAssertTrue(Guides.codeMentor.contains("mutate") && Guides.codeMentor.contains("never write it"))
        XCTAssertNil(MutateTool().subAgentVariant)
    }

    // MARK: Coverage

    func testCoverageParsers() {
        let go = "mode: set\nm/pkg/a.go:3.10,5.2 2 1\nm/pkg/a.go:6.2,8.3 3 0\nm/pkg/a.go:7.2,7.9 1 1\n"
        let g = Coverage.goProfile(go, module: "m")
        XCTAssertEqual(g.first?.path, "pkg/a.go"); XCTAssertEqual(g.first?.covered, 3); XCTAssertEqual(g.first?.total, 6)
        XCTAssertEqual(g.first?.missing, [6...6, 8...8], "a line covered by another block is not missing")
        let llvm = #"{"data":[{"files":[{"filename":"/r/Sources/A.swift","segments":[[1,1,5,true,true,false],[3,1,0,true,true,false],[5,1,0,false,false,false]],"summary":{"lines":{"count":5,"covered":2,"percent":40}}}]}]}"#
        let l = Coverage.llvmJSON(Data(llvm.utf8), root: "/r")
        XCTAssertEqual(l.first?.path, "Sources/A.swift"); XCTAssertEqual(l.first?.missing, [3...4]); XCTAssertEqual(l.first?.covered, 2)
        let node = "ℹ file      | line % | branch % | funcs % | uncovered lines\nℹ calc.js   |  33.33 |   100.00 |   50.00 | 2-5 8\nℹ all files |  33.33 |   100.00 |   50.00 | \n"
        XCTAssertEqual(Coverage.table(node).first?.missing, [2...5, 8...8]); XCTAssertEqual(Coverage.table(node).first?.path, "calc.js")
        let jest = "File      | % Stmts | % Branch | % Funcs | % Lines | Uncovered Line #s\nAll files |   50 | 0 | 50 | 50 |\n src      |   50 | 0 | 50 | 50 |\n  a.js    |   50 | 0 | 50 | 50 | 3-4\n"
        XCTAssertEqual(Coverage.table(jest).first?.path, "src/a.js"); XCTAssertEqual(Coverage.table(jest).first?.missing, [3...4])
        let py = #"{"files":{"a.py":{"executed_lines":[1,2],"missing_lines":[4,5,9],"summary":{"percent_covered":40}}}}"#
        XCTAssertEqual(Coverage.coveragePy(Data(py.utf8)).first?.missing, [4...5, 9...9])
        XCTAssertFalse(Coverage.isMine(".teacher/tests/test_a.py") || Coverage.isMine("pkg/a_test.go") || Coverage.isMine("node_modules/x/i.js"))
        XCTAssertTrue(Coverage.isMine("src/stack.py"))
    }

    func testPythonCoverageNamesTheLinesNoTestRuns() async throws {
        try need("python3")
        try put("calc.py", "def used(x):\n    return x + 1\n\ndef unused(x):\n    y = x * 2\n    return y\n")
        try put(".teacher/tests/test_calc.py", "import sys; sys.path.insert(0, '.')\nfrom calc import used\nassert used(1) == 2\n")
        let ws = try Workspace(url: dir), before = snapshot(), scratch = scratchCount()
        let r = await Coverage.run(ws: ws, command: "python3 .teacher/tests/test_calc.py", seconds: 120, progress: { _ in })
        XCTAssertNil(r.note, "\(r.note ?? "") \(r.output)")
        let f = try XCTUnwrap(r.files.first { $0.path == "calc.py" }, "\(r.files.map(\.path))")
        XCTAssertTrue(f.missing.contains { $0.contains(5) } && f.missing.contains { $0.contains(6) } && !f.missing.contains { $0.contains(2) }, "\(f.missing)")
        XCTAssertFalse(r.files.contains { $0.path.contains("test_calc") }, "tests are not the learner's coverage")
        XCTAssertTrue(Coverage.render(r, ws: ws).contains("in unused"), Coverage.render(r, ws: ws))
        XCTAssertEqual(snapshot(), before, "no .coverage or .cover file in their folder"); XCTAssertEqual(scratchCount(), scratch)
    }

    func testNodeAndGoCoverage() async throws {
        if ProcessRunner.which("node") != nil {
            try put("calc.js", "function add(a,b){return a+b}\nfunction div(a,b){\n  if (b===0) { throw new Error('x') }\n  return a/b\n}\nmodule.exports={add,div}\n")
            try put(".teacher/tests/calc.test.js", "const t=require('node:test');const a=require('node:assert');const {add}=require('../../calc');\nt.test('add',()=>a.equal(add(1,2),3))\n")
            let r = await Coverage.run(ws: try Workspace(url: dir), command: "node --test .teacher/tests/calc.test.js", seconds: 120, progress: { _ in })
            XCTAssertEqual(r.files.first { $0.path == "calc.js" }?.missing.first?.lowerBound, 2, "\(r.note ?? "") \(r.output)")
        }
        if ProcessRunner.which("go") != nil {
            let g = dir.appendingPathComponent("gomod"); try FileManager.default.createDirectory(at: g, withIntermediateDirectories: true)
            try "module demo\n\ngo 1.20\n".write(to: g.appendingPathComponent("go.mod"), atomically: true, encoding: .utf8)
            try "package demo\n\nfunc Used() int { return 1 }\n\nfunc Unused(x int) int {\n\tif x > 0 {\n\t\treturn x\n\t}\n\treturn 0\n}\n".write(to: g.appendingPathComponent("demo.go"), atomically: true, encoding: .utf8)
            try "package demo\n\nimport \"testing\"\n\nfunc TestUsed(t *testing.T) { if Used() != 1 { t.Fatal(\"x\") } }\n".write(to: g.appendingPathComponent("demo_test.go"), atomically: true, encoding: .utf8)
            let r = await Coverage.run(ws: try Workspace(url: g), command: "go test ./...", seconds: 180, progress: { _ in })
            XCTAssertNotNil(r.files.first { $0.path == "demo.go" }?.missing.first, "\(r.note ?? "") \(r.output)")
        }
    }

    func testAToolThatIsNotInstalledIsNamedNotInstalled() async throws {
        let unknown = await Coverage.run(ws: try Workspace(url: dir), command: "make test", seconds: 10, progress: { _ in })
        XCTAssertTrue(unknown.note?.contains("make test") == true)
        if ProcessRunner.which("cargo") != nil, ProcessRunner.which("cargo-llvm-cov") == nil {
            try put("Cargo.toml", "[package]\nname = \"d\"\nversion = \"0.1.0\"\nedition = \"2021\"\n")
            let r = await Coverage.run(ws: try Workspace(url: dir), command: "cargo test", seconds: 60, progress: { _ in })
            XCTAssertTrue(r.note?.contains("cargo-llvm-cov") == true && r.note?.contains("nothing was installed") == true, r.note ?? "")
        }
    }

    // MARK: Growth

    func testGrowthIsClaimedWithEvidenceOnKnownWorkloads() {
        let sizes = [100, 300, 1000, 3000, 10000, 30000]
        let wobble = [1.0, 1.03, 0.97, 1.02, 0.99, 1.01]
        func g(_ f: (Double) -> Double) -> CodeLab.Growth { CodeLab.assess(sizes: sizes, seconds: sizes.enumerated().map { f(Double($1)) * wobble[$0] }) }
        let n = g { 2e-7 * $0 }, n2 = g { 3e-10 * $0 * $0 }, flat = g { _ in 5e-6 }
        XCTAssertEqual(n.model, "O(n)"); XCTAssertEqual(n2.model, "O(n²)")
        XCTAssertEqual(n2.confidence, "high", n2.claim)
        XCTAssertTrue(n2.claim.hasPrefix("looks like O(n²)") && n2.claim.contains("slope 2.0") && n2.claim.contains("6 sizes"), n2.claim)
        XCTAssertEqual(flat.model, "O(1)"); XCTAssertEqual(flat.confidence, "low", "5 µs is mostly the timer")
    }

    func testGrowthRefusesTooFewTooNarrowOrTooNoisyPoints() {
        let two = CodeLab.assess(sizes: [1000, 3000, 10000, 30000], seconds: [1e-3, 3e-3, nil, nil])
        XCTAssertNil(two.model); XCTAssertTrue(two.claim.contains("too few sizes"), two.claim)
        let three = CodeLab.assess(sizes: [1000, 10000, 100000], seconds: [1e-3, 1e-2, 1e-1])
        XCTAssertNil(three.model, "three points are not a curve")
        let narrow = CodeLab.assess(sizes: [100, 120, 150, 200, 250], seconds: [1e-3, 1.3e-3, 1.5e-3, 2e-3, 2.4e-3])
        XCTAssertNil(narrow.model); XCTAssertTrue(narrow.claim.contains("span only"), narrow.claim)
        let noisy = CodeLab.assess(sizes: [100, 300, 1000, 3000, 10000], seconds: [1e-3, 9e-3, 2e-3, 8e-2, 1e-3])
        XCTAssertNil(noisy.model); XCTAssertTrue(noisy.claim.contains("noisy"), noisy.claim)
        let timer = CodeLab.assess(sizes: [100, 300, 1000, 3000, 10000], seconds: [1e-6, 2e-6, 4e-6, 1.2e-5, 4e-5].map { $0 / 4 })
        XCTAssertNil(timer.model, "timer noise is not growth: \(timer.claim)")
        let close = CodeLab.assess(sizes: [100, 200, 400, 800, 1600, 3200], seconds: [100, 200, 400, 800, 1600, 3200].map { 1e-8 * Double($0) * log(Double($0)) })
        XCTAssertNotEqual(close.confidence, "high", "n and n log n over a 32× span can't be told apart: \(close.claim)")
    }

    func testBenchCarriesTheClaimToTheCardAndScaleMakesSizes() {
        let sizes = [100, 300, 1000, 3000, 10000]
        let out = CodeLab.benchOutput(sizes: sizes, series: [CodeLab.Series(name: "pairs", seconds: sizes.map { 1e-9 * Double($0) * Double($0) })])
        XCTAssertEqual(out.meta?["series"]?[0]?["fit"]?.string, "O(n²)")
        XCTAssertEqual(out.meta?["series"]?[0]?["confidence"]?.string, "high")
        XCTAssertTrue(out.text.contains("looks like O(n²)"), out.text)
        let few = CodeLab.benchOutput(sizes: sizes, series: [CodeLab.Series(name: "x", seconds: [1e-3, nil, nil, nil, nil])])
        XCTAssertEqual(few.meta?["series"]?[0]?["fit"], .null); XCTAssertTrue(few.text.contains("no growth claim"))
        let s = BenchTool.scaled(1_000_000)
        XCTAssertEqual(s.first, 1000); XCTAssertEqual(s.last, 1_000_000); XCTAssertEqual(s.count, 7)
    }

    func testBenchMeasuresQuadraticPythonAsQuadratic() async throws {
        try need("python3")
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        let ctx = await MainActor.run { ToolContext(conversationID: "l", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c", client: cfg.client(apiKey: nil), model: "m", progress: { _ in }) }
        let code = "def setup(n): return list(range(n))\ndef run_pairs(xs):\n    c = 0\n    for a in xs:\n        for b in xs:\n            c += 1\n    return c\ndef run_scan(xs): return sum(xs)\n"
        let out = try await BenchTool().run(["language": "python", "code": .string(code), "sizes": [100, 300, 1000, 2000, 4000]], ctx)
        XCTAssertFalse(out.isError, out.text)
        XCTAssertEqual(out.meta?["series"]?[0]?["fit"]?.string, "O(n²)", out.text)
        XCTAssertNotEqual(out.meta?["series"]?[1]?["fit"]?.string, "O(n²)", "a single pass is never called quadratic (it may be refused as too fast to time): \(out.text)")
    }
}
