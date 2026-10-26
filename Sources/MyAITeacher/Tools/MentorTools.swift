import Foundation

/// Runs a project's tests from the lesson folder and records the run.
enum ProjectTestRunner {
    static func run(_ command: String, ws: Workspace, timeout: TimeInterval, why: String, record: Bool = true, progress: (@Sendable (String) -> Void)? = nil) async -> (MentorProject.TestRun, String) {
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let started = Date()
        let r = await ProcessRunner.run(shell, ["-c", command], cwd: ws.url, timeout: timeout, onOutput: progress)
        let parsed = TestOutput.parse(r.combined, exit: r.exitCode)
        let run = MentorProject.TestRun(at: started, passed: parsed.passed, failed: parsed.failed, errored: parsed.errored || r.timedOut, seconds: Date().timeIntervalSince(started),
                                        failing: parsed.failing, exit: r.exitCode, why: why, counted: parsed.counted)
        if record { ProjectStore.mutate(ws) { $0.runs.append(run) } }
        return (run, r.combined + (r.timedOut ? "\n[timed out after \(Int(timeout)) s]" : ""))
    }

    /// The command narrowed to one test, for the runners that can (pytest, jest/vitest, go, cargo, swift, zig test);
    /// nil when the command's runner can't be narrowed from outside (`zig build test`, a make target).
    static func filtered(_ command: String, test: String) -> String? {
        let name = shortName(test)
        guard !name.isEmpty else { return nil }
        let q = "'" + name.replacingOccurrences(of: "'", with: "'\\''") + "'"
        let c = command.trimmingCharacters(in: .whitespaces)
        if c.contains("pytest") { return c + " -k " + q }
        if c.contains("jest") || c.contains("vitest") { return c + " -t " + q }
        if c.hasPrefix("npm test") || c.hasPrefix("npm run test") || c.hasPrefix("pnpm test") || c.hasPrefix("yarn test") { return c + " -- -t " + q }
        if c.contains("go test") { return c + " -run '^" + NSRegularExpression.escapedPattern(for: name) + "$'" }
        if c.contains("cargo test") { return c.contains(" -- ") ? nil : c + " " + q }
        if c.contains("swift test") { return c + " --filter " + q }
        if c.range(of: #"(^|\s|/)zig test\b"#, options: .regularExpression) != nil { return c + " --test-filter " + q }
        return nil
    }
    /// A failing test's own name, from a runner's id ("tests/test_a.py::test_two", "spec.test.empty input").
    static func shortName(_ id: String) -> String {
        var n = id
        if let r = n.range(of: "::", options: .backwards) { n = String(n[r.upperBound...]) }
        if let r = n.range(of: ".test.") { n = String(n[r.upperBound...]) }
        return n.trimmingCharacters(in: .whitespaces)
    }

    static func describe(_ run: MentorProject.TestRun, output: String) -> String {
        let exit = run.line.contains("(exit") ? "" : "exit \(run.exit), "   // an uncounted run's line already says it
        var s = run.errored ? "The test command couldn't run (exit \(run.exit))." : "\(run.line) (\(exit)\(String(format: "%.1f", run.seconds)) s)."
        if !run.failing.isEmpty { s += "\nFailing: " + run.failing.joined(separator: ", ") }
        let items = Diagnostics.parse(output)
        if !items.isEmpty { s += "\n" + Diagnostics.summary(items, cap: 20) }
        if !run.green { s += "\n--- output (tail) ---\n" + String(output.suffix(run.errored || run.counted == false ? 4000 : 2500)) }
        return s
    }
}

/// The project's tests: register the command (which proves the tests fail on the starter), run them, see the history.
/// After the baseline the tests are locked: `unlock` (the learner approves) lets the mentor change them, and `set`
/// re-baselines them.
struct ProjectTestsTool: Tool {
    let name = "project_tests"
    let description = """
    The learner's project tests. action="set" with `command` (run from the lesson folder, whatever the language: \
    `python3 -m pytest .teacher/tests -q`, `cargo test`, `make test`, `mix test`, `dotnet test`…) once the starter and \
    the tests are in place: the app runs them first and stores nothing unless the run fails (exit code not 0) — a suite \
    that passes on the starter proves nothing — then records the starter as the review baseline and locks the tests. \
    Read the output it returns: red should mean failing tests, not a build error. After a review passes, `set` starts \
    the next project. action="run": run them now (`test` narrows to one where the runner allows it). action="status": \
    the command, the runs, the locks, what changed since the last review. action="unlock": ask the learner to let you \
    change the locked tests (a wrong test, a stretch goal); edit them, then `set` again to re-baseline. Until the learner \
    changes a file the tests are still your draft: fix them and `set` again, no unlock. action="park" with `reason`: the \
    learner moves on before a pass — they approve, it stays on the record as unfinished, and `set` starts the next \
    project (its own folder, tests in `.teacher/tests/<name>/`). Never record a pass to get out of a project.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["set", "run", "status", "unlock", "park"]),
            "reason": Schema.string("park: why it's put aside (the learner's words)."),
            "command": Schema.string("set: the test command, run from the lesson folder."),
            "test": Schema.string("run: only this test (a failing test's name as reported)."),
            "title": Schema.string("set: the project's name."),
            "subject": Schema.string("set: subject for mastery."),
            "concept": Schema.string("set: the concept the project teaches (recorded as mastered when a review passes with green tests)."),
            "timeout": Schema.integer("Seconds for the run (default 300, max 900)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "") + (input["command"]?.string.map { " " + $0 } ?? "") + (input["test"]?.string.map { " " + $0 } ?? "") }
    func timeout(_ input: JSON) -> Double? { Double(min(900, max(10, input["timeout"]?.int ?? 300))) + 15 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let ws = ctx.services.workspace
        let timeout = TimeInterval(min(900, max(10, input["timeout"]?.int ?? 300)))
        switch input["action"]?.string ?? "status" {
        case "set":
            let command = try input.req("command")
            let p = ProjectStore.load(ws) ?? MentorProject()
            // A passed project is finished: `set` starts the next one (the last record is kept beside it).
            let next = p.snapshotAt != nil && !p.isOpen
            // Still the mentor's draft (no review, the learner hasn't changed a file): set again as if it were the first.
            let draft = p.isOpen && p.testsUnlockedAt == nil && ProjectStore.testsAreDraft(ws, p)
            let rebaseline = p.isOpen && !draft
            if rebaseline, p.testsUnlockedAt == nil {
                return .error("This project has its baseline and its tests are locked: a review measures the learner against them. To change the tests or the command, call `project_tests` unlock (the learner approves), edit the tests, then set again.")
            }
            // Nothing is stored until the run is accepted: a refused command used to stay registered.
            let (run, out) = await ProjectTestRunner.run(command, ws: ws, timeout: timeout, why: "set", record: false, progress: ctx.progress)
            if run.errored {
                return .error("The test command couldn't run (exit \(run.exit)): fix the command, then call set again. Nothing was registered.\n" + String(out.suffix(4000)))
            }
            if !rebaseline, run.green {
                return .error("The tests pass on the starter (exit 0): they prove nothing. Tests must fail until the learner does the work — check that they exercise what the learner is to write or fix. Rewrite them and call set again.")
            }
            if next { ProjectStore.archive(ws) }
            ProjectStore.mutate(ws) { q in
                if next { q = MentorProject() }
                if let t = input["title"]?.string, !t.isEmpty { q.title = t }
                if let s = input["subject"]?.string, !s.isEmpty { q.subject = s }
                if let c = input["concept"]?.string, !c.isEmpty { q.concept = c }
                q.runs.append(run)
                q.testCommand = command
                if rebaseline {
                    q.testsUnlockedAt = nil
                    q.suiteChanges = (q.suiteChanges ?? []) + [MentorProject.SuiteChange(at: Date(), why: "re-baselined after the learner unlocked them: \(run.line)")]
                }
            }
            if rebaseline {
                return ToolOutput(text: "Re-baselined: the new tests run (\(run.line)) and are locked again. The change is on the project's record. Tell the learner what changed in the tests and why.",
                                  meta: ["run": Self.json(run), "command": .string(command)])
            }
            ProjectStore.snapshot(ws, why: "starter")
            return ToolOutput(text: "Red on the starter: \(run.line) (\(String(format: "%.1f", run.seconds)) s)." +
                              (run.failing.isEmpty ? "" : "\nFailing: " + run.failing.joined(separator: ", ")) +
                              "\n--- output (tail) ---\n" + String(out.suffix(2000)) + "\nCheck the output: red should mean failing tests, not a build or import error (if it is, unlock the tests, fix them and set again)." +
                              "\nThe starter is the review baseline and the tests are locked: `project_review` start shows what the learner changed since. Tell the learner how to run the tests themselves: `\(command)` (or Run tests in the Project panel).",
                              meta: ["run": Self.json(run), "command": .string(command)])
        case "park":
            guard let p = ProjectStore.load(ws), p.isOpen else { return ToolOutput(text: "No open project to put aside: `set` starts one.") }
            let why = input["reason"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            ProjectStore.mutate(ws) { q in
                q.parkedAt = Date(); q.parkedWhy = why.isEmpty ? nil : why
                q.log("parked", "put aside unfinished" + (why.isEmpty ? "" : ": " + why))
            }
            return ToolOutput(text: "“\(p.title ?? "The project")” is put aside unfinished (\(p.lastRun?.line ?? "no runs yet")): on the record as not passed. `set` starts the next project — its own folder, tests in `.teacher/tests/<name>/` — and the learner can come back to this one.")
        case "unlock":
            guard let p = ProjectStore.load(ws), p.snapshotAt != nil else { return ToolOutput(text: "The tests aren't locked yet: there is no baseline (`project_tests` set takes it).") }
            ProjectStore.mutate(ws) { $0.testsUnlockedAt = Date(); $0.log("unlocked", "the learner let the mentor change the tests") }
            return ToolOutput(text: "The learner unlocked the tests: edit them in .teacher/tests, then `project_tests` set (same or new command) to re-baseline; until then a review can't pass.")
        case "run":
            guard let p = ProjectStore.load(ws), let command = p.testCommand else { return .error("No test command yet: `project_tests` set with `command` first.") }
            var cmd = command, note = ""
            if let t = input["test"]?.string, !t.isEmpty {
                if let f = ProjectTestRunner.filtered(command, test: t) { cmd = f } else { note = "\n(This runner can't be narrowed to one test from outside: the whole suite ran.)" }
            }
            let (run, out) = await ProjectTestRunner.run(cmd, ws: ws, timeout: timeout, why: cmd == command ? "run" : "run one", progress: ctx.progress)
            return ToolOutput(text: ProjectTestRunner.describe(run, output: out) + note, isError: run.errored, meta: ["run": Self.json(run), "command": .string(cmd)])
        default:
            guard let p = ProjectStore.load(ws) else { return ToolOutput(text: "No project yet in this folder: write the starter and tests, then `project_tests` set.") }
            var s = "Project: \(p.title ?? "(untitled)")\(p.concept.map { " · concept \($0)" } ?? "")\nTest command: \(p.testCommand ?? "(not set)")"
            if p.isOpen { s += "\nTests: " + (p.testsUnlockedAt != nil ? "unlocked by the learner (set re-baselines)" : "locked since the baseline") }
            else if p.parkedAt != nil { s += "\nPut aside unfinished\(p.parkedWhy.map { " (\($0))" } ?? ""): `set` starts the next project." }
            else if p.snapshotAt != nil { s += "\nPassed: `set` starts the next project." }
            if let r = p.lastRun { s += "\nLast run (\(r.why), \(Self.ago(r.at))): \(r.line)" + (r.failing.isEmpty ? "" : " — failing: " + r.failing.joined(separator: ", ")) }
            if !p.runs.isEmpty { s += "\nHistory: " + p.runs.suffix(8).map { "\($0.passed)/\($0.passed + $0.failed)" }.joined(separator: " → ") }
            if let n = ProjectStore.changedCount(ws) { s += "\nChanged since the \(p.snapshotWhy ?? "baseline"): \(n) file\(n == 1 ? "" : "s")" }
            if let r = p.rounds.last { s += "\nReview round \(r.number) (\(Self.ago(r.at))): \(r.verdict), \(r.findings.filter { !$0.resolved }.count) open finding(s)" }
            if p.helpSinceReview != .none { s += "\nHelp since the last review: \(p.helpSinceReview == .solution ? "a solution" : "hints")" }
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

/// The review loop as a mechanism: `start` hands the mentor the diff since the last review, the test run, the open
/// findings and the learner's self-review; `findings` records the round (structured, by file and line, each with a hint
/// ladder), marks earlier findings resolved, snapshots the files for the next round, and on a pass with green tests
/// records mastery — unaided only when the learner had no help — and opens an explain-back; `explain` grades it.
struct ProjectReviewTool: Tool {
    let name = "project_review"
    let description = """
    Review the learner's work on the project. action="start": the app runs the tests and returns what changed since the \
    last review (unified diffs), the test results, the findings still open, and the learner's self-review if they wrote \
    one — read the diff, then the files where you need more context. action="findings": record the round — `verdict` \
    pass|changes, a short `summary`, `findings` [{file, line, severity must|should|nit, text, concept, hints}] (point at \
    their lines; `text` is a question or hint, never the fix; `hints` is a ladder of 2–3 rungs, each a little more \
    specific: a nudge, a targeted hint, the concept or a worked step on a different example — never their code), \
    `resolved` (ids of earlier findings now fixed), and `help` (none|hint|solution: what you gave since the last round). \
    A pass needs this review's tests green, the tests locked, and no `must` open, and when all three hold it is a pass \
    (`should`/`nit` stay open as suggestions): what must change before it passes is a `must`. A pass records the \
    concept's mastery (as helped if there was help) and opens an explain-back. action="explain": after a pass, record \
    the learner's own explanation (a skipped question is none) — `question` you asked and `verdict` pass|partial|fail. action="status": rounds and open findings.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "action": Schema.string("Action.", enum: ["start", "findings", "explain", "status"]),
            "run_tests": Schema.boolean("start: run the tests first (default true)."),
            "verdict": Schema.string("findings: pass (ready: tests green, nothing blocking) or changes. explain: pass, partial or fail.", enum: ["pass", "changes", "partial", "fail"]),
            "summary": Schema.string("findings: one or two sentences on the work as a whole."),
            "findings": Schema.array(Schema.object([
                "file": Schema.string("Path relative to the folder."), "line": Schema.integer("Line number."),
                "severity": Schema.string("must (blocks a pass), should, nit.", enum: ["must", "should", "nit"]),
                "text": Schema.string("What is wrong or weak and a question or hint toward the fix — not the fix."),
                "concept": Schema.string("The concept this finding is about."),
                "hints": Schema.array(Schema.string("One rung"), "A hint ladder (2–3 rungs, each more specific), never the code."),
            ], required: ["file", "severity", "text"]), "findings: the findings of this round."),
            "resolved": Schema.array(Schema.integer("Finding id"), "findings: ids of open findings from earlier rounds that are now fixed."),
            "help": Schema.string("findings: the help you gave since the last round.", enum: ["none", "hint", "solution"]),
            "question": Schema.string("explain: the explain-back question you asked."),
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
            if p.testsUnlockedAt != nil { s += "The tests are unlocked and not re-baselined yet: this round can't pass until `project_tests` set locks them again.\n" }
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
                    open.map { "  [\($0.id)] \($0.file)\($0.line.map { ":\($0)" } ?? "") \($0.severity): \($0.text)" + (($0.revealed ?? 0) > 0 ? " (they revealed \($0.revealed!) hint rung\($0.revealed! == 1 ? "" : "s"))" : "") }.joined(separator: "\n") + "\n\n"
            }
            if let sr = p.selfReview, sr.at > (p.rounds.last?.at ?? .distantPast) {
                s += "The learner's self-review (answer it in your summary: where they're right, what they missed):\n  fixed: \(sr.fixed)\n  unsure about: \(sr.unsure)\n  expect to fail: \(sr.expectFail)\n\n"
            }
            if p.helpSinceReview != .none { s += "Help since the last round: \(p.helpSinceReview == .solution ? "a solution" : "hints") (a pass records it as helped).\n\n" }
            s += "Changed since the \(p.snapshotWhy ?? "baseline")\(p.snapshotAt.map { " (\(ProjectTestsTool.ago($0)))" } ?? ""):\n" + ProjectStore.render(changes)
            // The round this start opens: findings are recorded against it (what changed, the run it made, the checks).
            let ran = input["run_tests"]?.bool != false
            ProjectStore.mutate(ws) { q in
                q.openReview = changes.isEmpty ? nil : MentorProject.OpenReview(at: Date(), changed: changes.map(\.path), run: ran ? q.lastRun : nil)
            }
            if changes.isEmpty {
                s += "\n\nNo project file differs from the baseline: the learner hasn't saved any change yet (or saved in an editor buffer, not to disk). Don't look for their files anywhere else. Tell them that nothing has changed on disk in \(ws.url.lastPathComponent), ask them to save and say which file they worked on, and offer to go through the first failing test together. Don't record a round."
            } else {
                s += "\n\nNow review: correctness first (the failing tests and why), then design, edge cases, naming, complexity, the tests they should add. Point at lines. Questions and a hint ladder per finding, never the code. Then call `project_review` findings."
            }
            return ToolOutput(text: s, meta: ["changes": .array(changes.map { ["path": .string($0.path), "kind": .string($0.kind), "added": .number(Double($0.added)), "removed": .number(Double($0.removed))] }),
                                            "round": .number(Double(p.rounds.count + 1))])
        case "findings":
            let p = ProjectStore.load(ws) ?? MentorProject()
            let verdict = (input["verdict"]?.string ?? "changes").lowercased() == "pass" ? "pass" : "changes"
            // A round reviews work: a `start` that found the learner's changes comes first, and a pass needs that start's
            // tests green and the tests locked.
            guard let open = p.openReview else {
                return .error("No review is open: call `project_review` start first. A round needs the learner's changes since the last review; with none, there is nothing to record.")
            }
            if verdict == "pass" {
                guard let run = open.run, run.green else {
                    return .error("A pass needs the tests green in this review's run (" + (open.run.map(\.line) ?? "no run") + "). Record `changes`, or have them fix what fails first.")
                }
                if p.testsUnlockedAt != nil { return .error("A pass needs the tests locked, and they are unlocked: re-baseline them (`project_tests` set) and review again, or record `changes`.") }
            }
            // Findings are about the learner's work. A live review, told its green run with nothing blocking was a pass,
            // filed a `must` against its own test file (the tests didn't check a rule the learner's code already met).
            if let mine = (input["findings"]?.array ?? []).compactMap({ $0["file"]?.string }).first(where: { $0.hasPrefix(".teacher/") || $0.hasPrefix("./.teacher/") || $0.contains("/.teacher/") }) {
                return .error("Nothing recorded: `\(mine)` is yours, not the learner's — findings point at their files. A rule your tests miss is your gap: if their code meets it, it isn't a finding (tighten the tests for the next project, or `project_tests` unlock if a test is wrong).")
            }
            let stated: Help = ["hint": .hint, "solution": .solution][input["help"]?.string ?? ""] ?? .none
            let helped = Help(rawValue: max(stated.rawValue, p.helpSinceReview.rawValue)) ?? .none
            var next = p.nextFindingID
            var findings: [MentorProject.Finding] = []
            for f in input["findings"]?.array ?? [] {
                guard let file = f["file"]?.string, let text = f["text"]?.string, !text.isEmpty else { continue }
                let sev = ["must", "should", "nit"].contains(f["severity"]?.string ?? "") ? f["severity"]!.string! : "should"
                let hints = (f["hints"]?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }.prefix(3)
                findings.append(MentorProject.Finding(id: next, file: file, line: f["line"]?.int, severity: sev, text: text, concept: f["concept"]?.string,
                                                      hints: hints.isEmpty ? nil : Array(hints)))
                next += 1
            }
            var resolvedIDs = Set(input["resolved"]?.array?.compactMap(\.int) ?? [])
            // A `must` is resolved by the learner's change to its file, not by saying so.
            let changed = Set(open.changed)
            var kept: [Int] = []
            if let last = p.rounds.last {
                for f in last.findings where resolvedIDs.contains(f.id) && f.severity == "must" && !changed.contains(f.file) {
                    resolvedIDs.remove(f.id); kept.append(f.id)
                }
            }
            var carried: [MentorProject.Finding] = []
            var rounds = p.rounds
            if let last = rounds.indices.last {
                for i in rounds[last].findings.indices where !rounds[last].findings[i].resolved {
                    if resolvedIDs.contains(rounds[last].findings[i].id) { rounds[last].findings[i].resolved = true }
                    else { carried.append(rounds[last].findings[i]) }
                }
            }
            let blocking = findings.contains { $0.severity == "must" } || carried.contains { $0.severity == "must" }
            if verdict == "pass", blocking {
                return .error("A pass can't carry a `must` finding: fix the verdict (changes) or the severities.")
            }
            // The pass bar is the tests and the `must`s, not the reviewer's appetite: green, locked and nothing blocking is a
            // pass, and the `should`s and `nit`s stay open as suggestions. A "changes" with nothing blocking says two things
            // at once, so it goes back for a decision instead of being guessed at: one live review asked for a third round
            // with 19/19 green over wording; another, promoted to a pass, had its reply ask for a fix it had filed as `should`.
            if verdict == "changes", !blocking, open.run?.green == true, p.testsUnlockedAt == nil {
                return .error("Nothing recorded: the tests are green and no finding is a `must`, which is a pass — unless something must change before it passes, and then that finding is a `must`. Send `findings` again: verdict pass (the `should`/`nit` findings stay open as suggestions), or the blocking findings as `must`.")
            }
            let selfReview = p.selfReview.flatMap { $0.at > (p.rounds.last?.at ?? .distantPast) ? $0 : nil }
            let round = MentorProject.Round(number: p.rounds.count + 1, at: Date(), verdict: verdict, summary: input["summary"]?.string, findings: carried + findings,
                                            tests: open.run ?? p.lastRun, selfReview: selfReview, help: helped == .none ? nil : helped == .solution ? "solution" : "hint")
            ProjectStore.mutate(ws) { q in
                q.rounds = rounds + [round]
                q.openReview = nil
                q.selfReview = nil
                if stated != .none { q.help = (q.help ?? []) + [MentorProject.HelpUse(at: Date(), kind: stated == .solution ? "solution" : "hint", detail: "the mentor's account at round \(round.number)")] }
                if verdict == "pass" {
                    q.explainBack = MentorProject.ExplainBack(at: Date(), question: nil, verdict: nil, round: round.number)
                }
            }
            ProjectStore.snapshot(ws, why: "review \(round.number)")
            var text = "Round \(round.number) recorded: \(verdict), \(findings.count) new finding\(findings.count == 1 ? "" : "s"), \(carried.count) carried over, \(resolvedIDs.count) resolved."
            if !kept.isEmpty { text += " Still open: \(kept.map { "[\($0)]" }.joined(separator: ", ")) — a `must` is resolved when its file has changed, and it hasn't." }
            if findings.contains(where: { $0.hints == nil }) { text += " Give each finding a hint ladder (`hints`) next time: the learner reveals one rung at a time instead of being handed the answer." }
            if verdict == "pass" {
                if let r = open.run, r.green, let concept = p.concept {
                    let study = ctx.services.study
                    let m = study.recordAttempt(subject: p.subject ?? "programming", concept: concept, correct: true,
                                                note: helped == .none ? "project review passed with green tests" : "project review passed with green tests, after \(helped == .solution ? "seeing a solution" : "hints")", help: helped)
                    text += helped == .none ? " Mastery of \(concept): \(Int(m.pKnown * 100))%." : " Recorded as a helped pass (they had \(helped == .solution ? "a solution" : "hints")): evidence, not unaided mastery (\(Int(m.pKnown * 100))%)."
                    // Durable knowledge, not one green run: a smaller reimplementation in a few days, in a new context.
                    study.scheduleFollowUp(subject: p.subject ?? "programming", concept: concept, kind: .transfer,
                                           note: "passed the project \(p.title.map { "“\($0)” " } ?? "")\(helped == .none ? "" : "with help "): ask them to reimplement one of its functions from scratch with a twist, or a variant with a different constraint", after: helped == .none ? 4 : 2)
                    EventBus.publish(.studyDataChanged)
                } else if p.lastRun?.green != true {
                    text += " (No mastery recorded: the last test run wasn't green.)"
                }
                text += " Now the explain-back: ask the learner one question about a design choice, trade-off or failure mode in their own code (in their own words, no code needed), then record it with `project_review` explain. Then raise the bar: a harder project or a stretch goal."
            } else {
                text += " The learner fixes and asks for the next round; the open findings come back in `start`."
            }
            return ToolOutput(text: text, meta: ["round": Self.json(round), "verdict": .string(verdict)])
        case "explain":
            guard let p = ProjectStore.load(ws), let eb = p.explainBack, eb.verdict == nil else {
                return .error("No explain-back is open: it opens when a review passes.")
            }
            let v = input["verdict"]?.string ?? ""
            guard ["pass", "partial", "fail"].contains(v) else { return .error("`verdict` is pass, partial or fail.") }
            ProjectStore.mutate(ws) { $0.explainBack = MentorProject.ExplainBack(at: Date(), question: input["question"]?.string ?? eb.question, verdict: v, round: eb.round) }
            var text = "Explain-back recorded: \(v)."
            if let concept = p.concept {
                let m = ctx.services.study.recordAttempt(subject: p.subject ?? "programming", concept: concept, correct: v == "pass",
                                                        note: "explain-back after the project passed: \(v)", help: v == "partial" ? .hint : .none)
                text += " Mastery of \(concept): \(Int(m.pKnown * 100))%."
                EventBus.publish(.studyDataChanged)
            }
            if v != "pass" { text += " Go through the gap with them: a question at a time, then ask them to explain it again." }
            return ToolOutput(text: text)
        default:
            guard let p = ProjectStore.load(ws), !p.rounds.isEmpty else { return ToolOutput(text: "No review rounds yet.") }
            return ToolOutput(text: p.rounds.map { r in
                "Round \(r.number) (\(ProjectTestsTool.ago(r.at))): \(r.verdict)" + (r.tests.map { " · tests \($0.line)" } ?? "") + (r.help.map { " · help: \($0)" } ?? "") + (r.summary.map { " — \($0)" } ?? "") + "\n" +
                    r.findings.map { "  [\($0.id)] \($0.resolved ? "✓ " : "")\($0.file)\($0.line.map { ":\($0)" } ?? "") \($0.severity): \($0.text)" }.joined(separator: "\n")
            }.joined(separator: "\n") + (p.explainBack.map { "\nExplain-back (round \($0.round)): \($0.verdict ?? "pending")" } ?? ""))
        }
    }

    static func json(_ r: MentorProject.Round) -> JSON {
        ["number": .number(Double(r.number)), "verdict": .string(r.verdict), "summary": r.summary.map { .string($0) } ?? .null,
         "tests": r.tests.map(ProjectTestsTool.json) ?? .null, "help": r.help.map { .string($0) } ?? .null,
         "findings": .array(r.findings.map { ["id": .number(Double($0.id)), "file": .string($0.file), "line": $0.line.map { .number(Double($0)) } ?? .null,
                                              "severity": .string($0.severity), "text": .string($0.text), "concept": $0.concept.map { .string($0) } ?? .null, "resolved": .bool($0.resolved),
                                              "hints": .number(Double($0.hints?.count ?? 0))] })]
    }
}
