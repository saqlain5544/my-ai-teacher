import Foundation

/// Runs a project's tests from the lesson folder and records the run.
enum ProjectTestRunner {
    static func run(_ command: String, ws: Workspace, timeout: TimeInterval, why: String, progress: (@Sendable (String) -> Void)? = nil) async -> (MentorProject.TestRun, String) {
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let started = Date()
        let r = await ProcessRunner.run(shell, ["-c", command], cwd: ws.url, timeout: timeout, onOutput: progress)
        let parsed = TestOutput.parse(r.combined, exit: r.exitCode)
        let run = MentorProject.TestRun(at: started, passed: parsed.passed, failed: parsed.failed, errored: parsed.errored || r.timedOut, seconds: Date().timeIntervalSince(started),
                                        failing: parsed.failing, exit: r.exitCode, why: why)
        var p = ProjectStore.load(ws) ?? MentorProject()
        p.runs.append(run)
        ProjectStore.save(p, ws)
        return (run, r.combined + (r.timedOut ? "\n[timed out after \(Int(timeout)) s]" : ""))
    }

    static func describe(_ run: MentorProject.TestRun, output: String) -> String {
        var s = run.errored ? "The test runner failed (exit \(run.exit)) — nothing was collected or it didn't compile." : "\(run.passed) passed, \(run.failed) failed (exit \(run.exit), \(String(format: "%.1f", run.seconds)) s)."
        if !run.failing.isEmpty { s += "\nFailing: " + run.failing.joined(separator: ", ") }
        let items = Diagnostics.parse(output)
        if !items.isEmpty { s += "\n" + Diagnostics.summary(items, cap: 20) }
        if run.errored || run.failed > 0 { s += "\n--- output (tail) ---\n" + String(output.suffix(run.errored ? 4000 : 2500)) }
        return s
    }
}

/// The project's tests: register the command (which proves the tests fail on the starter), run them, see the history.
struct ProjectTestsTool: Tool {
    let name = "project_tests"
    let description = """
    The learner's project tests. action="set" with `command` (run from the lesson folder, e.g. `python3 -m pytest \
    .teacher/tests -q`, `swift test`, `zig build test`) once the starter and the tests are in place: the app runs them and \
    proves they are red — a suite that passes on the starter is vacuous and is refused, a runner that errors is refused \
    with its output — then records the starter as the review baseline. action="run": run them now (parsed: passed, \
    failed, failing names). action="status": the command, the last runs, what changed since the last review. Set \
    `title`, `subject` and `concept` (the `mastery` concept the project teaches) with set.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["set", "run", "status"]),
            "command": Schema.string("set: the test command, run from the lesson folder."),
            "title": Schema.string("set: the project's name."),
            "subject": Schema.string("set: subject for mastery."),
            "concept": Schema.string("set: the concept the project teaches (recorded as mastered when a review passes with green tests)."),
            "timeout": Schema.integer("Seconds for the run (default 300, max 900)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "") + (input["command"]?.string.map { " " + $0 } ?? "") }
    func timeout(_ input: JSON) -> Double? { Double(min(900, max(10, input["timeout"]?.int ?? 300))) + 15 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let ws = ctx.services.workspace
        let timeout = TimeInterval(min(900, max(10, input["timeout"]?.int ?? 300)))
        switch input["action"]?.string ?? "status" {
        case "set":
            let command = try input.req("command")
            var p = ProjectStore.load(ws) ?? MentorProject()
            if let t = input["title"]?.string, !t.isEmpty { p.title = t }
            if let s = input["subject"]?.string, !s.isEmpty { p.subject = s }
            if let c = input["concept"]?.string, !c.isEmpty { p.concept = c }
            p.testCommand = command
            ProjectStore.save(p, ws)
            let (run, out) = await ProjectTestRunner.run(command, ws: ws, timeout: timeout, why: "set", progress: ctx.progress)
            if run.errored {
                return .error("The tests don't run yet (exit \(run.exit)): fix the command or the test files, then call set again.\n" + String(out.suffix(4000)))
            }
            if run.failed == 0 {
                return .error("Every test passes on the starter (\(run.passed) passed, 0 failed): these tests prove nothing. Tests must fail until the learner implements the behaviour — check that they call the code the learner is to write, and that the starter raises or returns a placeholder. Rewrite them and call set again.")
            }
            ProjectStore.snapshot(ws, why: "starter")
            return ToolOutput(text: "Proven red on the starter: \(run.failed) failing, \(run.passed) passing (\(String(format: "%.1f", run.seconds)) s)." +
                              (run.failing.isEmpty ? "" : "\nFailing: " + run.failing.joined(separator: ", ")) +
                              "\nThe starter is the review baseline: `project_review` start shows what the learner changed since. Tell the learner how to run the tests themselves: `\(command)`.",
                              meta: ["run": Self.json(run), "command": .string(command)])
        case "run":
            guard let p = ProjectStore.load(ws), let command = p.testCommand else { return .error("No test command yet: `project_tests` set with `command` first.") }
            let (run, out) = await ProjectTestRunner.run(command, ws: ws, timeout: timeout, why: "run", progress: ctx.progress)
            return ToolOutput(text: ProjectTestRunner.describe(run, output: out), isError: run.errored, meta: ["run": Self.json(run), "command": .string(command)])
        default:
            guard let p = ProjectStore.load(ws) else { return ToolOutput(text: "No project yet in this folder: write the starter and tests, then `project_tests` set.") }
            var s = "Project: \(p.title ?? "(untitled)")\(p.concept.map { " · concept \($0)" } ?? "")\nTest command: \(p.testCommand ?? "(not set)")"
            if let r = p.lastRun { s += "\nLast run (\(r.why), \(Self.ago(r.at))): \(r.line)" + (r.failing.isEmpty ? "" : " — failing: " + r.failing.joined(separator: ", ")) }
            if !p.runs.isEmpty { s += "\nHistory: " + p.runs.suffix(8).map { "\($0.passed)/\($0.passed + $0.failed)" }.joined(separator: " → ") }
            if let n = ProjectStore.changedCount(ws) { s += "\nChanged since the \(p.snapshotWhy ?? "baseline"): \(n) file\(n == 1 ? "" : "s")" }
            if let r = p.rounds.last { s += "\nReview round \(r.number) (\(Self.ago(r.at))): \(r.verdict), \(r.findings.filter { !$0.resolved }.count) open finding(s)" }
            return ToolOutput(text: s)
        }
    }

    static func json(_ r: MentorProject.TestRun) -> JSON {
        ["passed": .number(Double(r.passed)), "failed": .number(Double(r.failed)), "errored": .bool(r.errored), "seconds": .number(r.seconds),
         "failing": .array(r.failing.map { .string($0) }), "exit": .number(Double(r.exit)), "why": .string(r.why)]
    }
    static func ago(_ d: Date) -> String {
        let s = Int(Date().timeIntervalSince(d))
        return s < 60 ? "just now" : s < 3600 ? "\(s / 60) min ago" : s < 86400 ? "\(s / 3600) h ago" : "\(s / 86400) d ago"
    }
}

/// The review loop as a mechanism: `start` hands the mentor the diff since the last review, the test run and the
/// open findings; `findings` records the round (structured, by file and line), marks earlier findings resolved,
/// snapshots the files for the next round, and credits mastery when a review passes with green tests.
struct ProjectReviewTool: Tool {
    let name = "project_review"
    let description = """
    Review the learner's work on the project. action="start": the app runs the tests and returns what changed since the \
    last review (unified diffs), the test results, and the findings still open from the last round — read the diff, \
    then the files where you need more context. action="findings": record the round — `verdict` pass|changes, a short \
    `summary`, `findings` [{file, line, severity must|should|nit, text, concept}] (point at their lines; questions and \
    hints, never the fix), and `resolved` (ids of earlier findings now fixed). The app shows the round as a card, \
    keeps the rounds, and records the project's concept as mastered when a round passes with every test green. \
    action="status": rounds and open findings.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["start", "findings", "status"]),
            "run_tests": Schema.boolean("start: run the tests first (default true)."),
            "verdict": Schema.string("findings: pass (ready: tests green, nothing blocking) or changes.", enum: ["pass", "changes"]),
            "summary": Schema.string("findings: one or two sentences on the work as a whole."),
            "findings": Schema.array(Schema.object([
                "file": Schema.string("Path relative to the folder."), "line": Schema.integer("Line number."),
                "severity": Schema.string("must (blocks a pass), should, nit.", enum: ["must", "should", "nit"]),
                "text": Schema.string("What is wrong or weak and a question or hint toward the fix — not the fix."),
                "concept": Schema.string("The concept this finding is about."),
            ], required: ["file", "severity", "text"]), "findings: the findings of this round."),
            "resolved": Schema.array(Schema.integer("Finding id"), "findings: ids of open findings from earlier rounds that are now fixed."),
            "timeout": Schema.integer("start: seconds for the test run (default 300, max 900)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { input["action"]?.string ?? "" }
    func timeout(_ input: JSON) -> Double? { input["action"]?.string == "start" ? Double(min(900, max(10, input["timeout"]?.int ?? 300))) + 40 : 30 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let ws = ctx.services.workspace
        switch input["action"]?.string ?? "status" {
        case "start":
            var p = ProjectStore.load(ws) ?? MentorProject()
            let changes = await ProjectStore.changes(ws)
            var s = "Review round \(p.rounds.count + 1)" + (p.title.map { " of \($0)" } ?? "") + ". Project folder: \(ws.url.path) (the learner's files are here and nowhere else).\n"
            if let command = p.testCommand, input["run_tests"]?.bool != false {
                let (run, out) = await ProjectTestRunner.run(command, ws: ws, timeout: TimeInterval(min(900, max(10, input["timeout"]?.int ?? 300))), why: "review", progress: ctx.progress)
                p = ProjectStore.load(ws) ?? p
                s += "Tests (`\(command)`): " + ProjectTestRunner.describe(run, output: out) + "\n\n"
            } else if p.testCommand == nil {
                s += "No test command registered (`project_tests` set): review without a run, and set it.\n\n"
            }
            let open = p.openFindings
            if !open.isEmpty {
                s += "Open findings from round \(p.rounds.last?.number ?? 0) — say which are now resolved (ids) in `findings`:\n" +
                    open.map { "  [\($0.id)] \($0.file)\($0.line.map { ":\($0)" } ?? "") \($0.severity): \($0.text)" }.joined(separator: "\n") + "\n\n"
            }
            s += "Changed since the \(p.snapshotWhy ?? "baseline")\(p.snapshotAt.map { " (\(ProjectTestsTool.ago($0)))" } ?? ""):\n" + ProjectStore.render(changes)
            if changes.isEmpty {
                s += "\n\nNo project file differs from the baseline: the learner hasn't saved any change yet (or saved in an editor buffer, not to disk). Don't look for their files anywhere else. Tell them that nothing has changed on disk in \(ws.url.lastPathComponent), ask them to save and say which file they worked on, and offer to go through the first failing test together. Don't record a round."
            } else {
                s += "\n\nNow review: correctness first (the failing tests and why), then design, edge cases, naming, complexity, the tests they should add. Point at lines. Questions and targeted hints, never the code. Then call `project_review` findings."
            }
            return ToolOutput(text: s, meta: ["changes": .array(changes.map { ["path": .string($0.path), "kind": .string($0.kind), "added": .number(Double($0.added)), "removed": .number(Double($0.removed))] }),
                                            "round": .number(Double(p.rounds.count + 1))])
        case "findings":
            var p = ProjectStore.load(ws) ?? MentorProject()
            let verdict = (input["verdict"]?.string ?? "changes").lowercased() == "pass" ? "pass" : "changes"
            var next = p.nextFindingID
            var findings: [MentorProject.Finding] = []
            for f in input["findings"]?.array ?? [] {
                guard let file = f["file"]?.string, let text = f["text"]?.string, !text.isEmpty else { continue }
                let sev = ["must", "should", "nit"].contains(f["severity"]?.string ?? "") ? f["severity"]!.string! : "should"
                findings.append(MentorProject.Finding(id: next, file: file, line: f["line"]?.int, severity: sev, text: text, concept: f["concept"]?.string))
                next += 1
            }
            let resolvedIDs = Set(input["resolved"]?.array?.compactMap(\.int) ?? [])
            var carried: [MentorProject.Finding] = []
            if let last = p.rounds.indices.last {
                for i in p.rounds[last].findings.indices where !p.rounds[last].findings[i].resolved {
                    if resolvedIDs.contains(p.rounds[last].findings[i].id) { p.rounds[last].findings[i].resolved = true }
                    else { carried.append(p.rounds[last].findings[i]) }
                }
            }
            if verdict == "pass", findings.contains(where: { $0.severity == "must" }) || !carried.filter({ $0.severity == "must" }).isEmpty {
                return .error("A pass can't carry a `must` finding: fix the verdict (changes) or the severities.")
            }
            let round = MentorProject.Round(number: p.rounds.count + 1, at: Date(), verdict: verdict, summary: input["summary"]?.string, findings: carried + findings, tests: p.lastRun)
            p.rounds.append(round)
            ProjectStore.save(p, ws)
            ProjectStore.snapshot(ws, why: "review \(round.number)")
            var text = "Round \(round.number) recorded: \(verdict), \(findings.count) new finding\(findings.count == 1 ? "" : "s"), \(carried.count) carried over, \(resolvedIDs.count) resolved."
            if verdict == "pass" {
                if let r = p.lastRun, r.green, let concept = p.concept {
                    let m = ctx.services.study.recordAttempt(subject: p.subject ?? "programming", concept: concept, correct: true, note: "project review passed with green tests")
                    text += " Mastery of \(concept): \(Int(m.pKnown * 100))%."
                    EventBus.publish(.studyDataChanged)
                } else if p.lastRun?.green != true {
                    text += " (No mastery recorded: the last test run wasn't green.)"
                }
                text += " Raise the bar next: a harder project or a stretch goal on this one."
            } else {
                text += " The learner fixes and asks for the next round; the open findings come back in `start`."
            }
            return ToolOutput(text: text, meta: ["round": Self.json(round), "verdict": .string(verdict)])
        default:
            guard let p = ProjectStore.load(ws), !p.rounds.isEmpty else { return ToolOutput(text: "No review rounds yet.") }
            return ToolOutput(text: p.rounds.map { r in
                "Round \(r.number) (\(ProjectTestsTool.ago(r.at))): \(r.verdict)" + (r.tests.map { " · tests \($0.line)" } ?? "") + (r.summary.map { " — \($0)" } ?? "") + "\n" +
                    r.findings.map { "  [\($0.id)] \($0.resolved ? "✓ " : "")\($0.file)\($0.line.map { ":\($0)" } ?? "") \($0.severity): \($0.text)" }.joined(separator: "\n")
            }.joined(separator: "\n"))
        }
    }

    static func json(_ r: MentorProject.Round) -> JSON {
        ["number": .number(Double(r.number)), "verdict": .string(r.verdict), "summary": r.summary.map { .string($0) } ?? .null,
         "tests": r.tests.map(ProjectTestsTool.json) ?? .null,
         "findings": .array(r.findings.map { ["id": .number(Double($0.id)), "file": .string($0.file), "line": $0.line.map { .number(Double($0)) } ?? .null,
                                              "severity": .string($0.severity), "text": .string($0.text), "concept": $0.concept.map { .string($0) } ?? .null, "resolved": .bool($0.resolved)] })]
    }
}
