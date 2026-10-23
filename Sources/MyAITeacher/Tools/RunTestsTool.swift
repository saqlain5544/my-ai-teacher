import Foundation

/// Runs a project's tests and reports each one's result, for the code mentor (checking the learner's work) and the code
/// agent. By default the tests are the files in `.teacher/tests`, each run with the runner its language needs (a
/// `run.sh` there runs instead, as the whole suite); a `command` runs that instead. The result is structured, so the page
/// draws a pass/fail card the learner can re-run without asking.
struct RunTestsTool: Tool {
    let name = "run_tests"
    let description = """
    Run the project's tests and report every pass and failure. Default: each file in `.teacher/tests` with its language's \
    runner (`.sh` bash, `.zig` zig test, `_test.go`/`.go` go test, `.py` pytest or python, `.js`/`.mjs` node --test, \
    `.rb` ruby; a `run.sh` there runs as the whole suite). Or pass `command` (e.g. "cargo test", "swift test"). The \
    learner sees a results card they can re-run. Use it to check their work, then read their code to review it.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "command": Schema.string("Run this instead of the test folder (one suite)."),
            "path": Schema.string("Test folder (default .teacher/tests)."),
            "filter": Schema.string("Only test files whose name contains this."),
            "timeout": Schema.integer("Seconds per test file (default 120, max 600)."),
        ])
    }
    func summary(_ input: JSON) -> String { input["command"]?.string ?? input["filter"]?.string ?? "tests" }

    struct Case: Sendable { var name: String; var passed: Bool; var seconds: Double; var output: String; var counts: (passed: Int, failed: Int)? }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        await Self.rerun(input, workspace: ctx.workspace, progress: ctx.progress)
    }

    /// The tests the call names, run in `workspace` (the learner's "Run again" uses this directly).
    static func rerun(_ input: JSON, workspace: URL, progress: @escaping @Sendable (String) -> Void = { _ in }) async -> ToolOutput {
        let ctx = (workspace: workspace, progress: progress)
        let timeout = TimeInterval(min(600, max(1, input["timeout"]?.int ?? 120)))
        let results: [Case]
        if let command = input["command"]?.string, !command.isEmpty {
            results = [await Self.runOne(name: command, command: command, cwd: ctx.workspace, timeout: timeout, progress: ctx.progress)]
        } else {
            let dir = resolvePath(input["path"]?.string ?? ".teacher/tests", workspace: ctx.workspace)
            guard let plan = Self.plan(dir: dir, filter: input["filter"]?.string), !plan.isEmpty else {
                return .error("No tests found in \(dir.path). Write them there first (one file per behaviour), or pass `command`.")
            }
            var out: [Case] = []
            for (name, command) in plan {
                out.append(await Self.runOne(name: name, command: command, cwd: ctx.workspace, timeout: timeout, progress: ctx.progress))
            }
            results = out
        }
        return Self.output(results)
    }

    /// What to run for each test file in `dir`: (display name, shell command).
    static func plan(dir: URL, filter: String?) -> [(String, String)]? {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return nil }
        let q = { (u: URL) in u.path.shellQuoted }
        if let suite = files.first(where: { $0.lastPathComponent == "run.sh" }) { return [("run.sh", "bash \(q(suite))")] }
        var plan: [(String, String)] = []
        var goDone = false
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let n = f.lastPathComponent
            if n.hasPrefix(".") { continue }
            if let filter, !filter.isEmpty, !n.localizedCaseInsensitiveContains(filter) { continue }
            switch f.pathExtension.lowercased() {
            case "sh": plan.append((n, "bash \(q(f))"))
            case "zig": plan.append((n, "zig test \(q(f))"))
            case "go":
                if !goDone { goDone = true; plan.append(("go tests", "go test -count=1 -v \(q(dir))")) }
            case "py": plan.append((n, "if python3 -c 'import pytest' 2>/dev/null; then python3 -m pytest -q \(q(f)); else python3 \(q(f)); fi"))
            case "js", "mjs", "cjs": plan.append((n, "node --test \(q(f))"))
            case "rb": plan.append((n, "ruby \(q(f))"))
            default: continue
            }
        }
        return plan
    }

    static func runOne(name: String, command: String, cwd: URL, timeout: TimeInterval, progress: @escaping @Sendable (String) -> Void) async -> Case {
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let t0 = Date()
        let r = await ProcessRunner.run(shell, ["-c", command], cwd: cwd, timeout: timeout, onOutput: { progress($0) })
        var out = (r.stdout + (r.stderr.isEmpty ? "" : "\n" + r.stderr)).trimmingCharacters(in: .whitespacesAndNewlines)
        if r.timedOut { out += "\n[timed out after \(Int(timeout)) s]" }
        return Case(name: name, passed: r.exitCode == 0 && !r.timedOut, seconds: Date().timeIntervalSince(t0), output: out, counts: counts(out))
    }

    /// Test-case counts from common runners' summaries (nil when the output has none).
    static func counts(_ s: String) -> (passed: Int, failed: Int)? {
        func n(_ p: String) -> Int? {
            guard let r = s.range(of: p, options: [.regularExpression, .caseInsensitive]) else { return nil }
            return Int(s[r].filter(\.isNumber))
        }
        if let all = n(#"All \d+ tests? passed"#) { return (all, 0) }                                    // zig
        if let p = n(#"\d+ passed"#) { return (p, n(#"\d+ failed"#) ?? 0) }                             // zig, pytest
        if let p = n(#"# pass \d+"#) { return (p, n(#"# fail \d+"#) ?? 0) }                              // node --test
        let goPass = s.components(separatedBy: "--- PASS").count - 1, goFail = s.components(separatedBy: "--- FAIL").count - 1
        if goPass + goFail > 0 { return (goPass, goFail) }                                               // go test -v
        if let p = n(#"test result: \w+\. \d+ passed"#) { return (p, n(#"\d+ failed"#) ?? 0) }          // cargo
        return nil
    }

    static func output(_ results: [Case]) -> ToolOutput {
        let passed = results.filter(\.passed).count
        let cases = results.compactMap(\.counts)
        let casePass = cases.map(\.passed).reduce(0, +), caseFail = cases.map(\.failed).reduce(0, +)
        var text = "Tests: \(passed)/\(results.count) passing" + (cases.isEmpty ? "" : " (\(casePass) cases passed, \(caseFail) failed)") + "\n"
        for c in results {
            text += "\(c.passed ? "✓" : "✗") \(c.name) (\(String(format: "%.1f", c.seconds)) s)"
            if !c.passed { text += "\n" + String(c.output.suffix(2500)).split(separator: "\n", omittingEmptySubsequences: false).map { "    " + $0 }.joined(separator: "\n") }
            text += "\n"
        }
        let meta: JSON = ["tests": .array(results.map { c in
            ["name": .string(c.name), "passed": .bool(c.passed), "seconds": .number(c.seconds), "output": .string(String(c.output.suffix(4000))),
             "cases": c.counts.map { ["passed": .number(Double($0.passed)), "failed": .number(Double($0.failed))] } ?? .null]
        }), "passed": .number(Double(passed)), "total": .number(Double(results.count))]
        return ToolOutput(text: text, isError: false, meta: meta)
    }
}
