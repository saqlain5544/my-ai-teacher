import Foundation

/// A throwaway copy of the learner's project under the app's temp space, for tools that must run the tests with
/// something changed or measured (mutation, coverage). The learner's folder is only ever read.
enum Scratch {
    static let prefix = "aiteacher-scratch-"
    static let excluded: Set<String> = [".teacher", ".git", "node_modules", "target", ".build", "build", "dist", "__pycache__", ".venv", "venv", "DerivedData", ".pytest_cache", ".gradle", "zig-cache", ".zig-cache"]

    static func make() throws -> URL {
        sweep()
        let d = FileManager.default.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString.prefix(8))
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }
    /// A run that was killed with the app left its folder: remove the ones older than three hours.
    static func sweep() {
        let fm = FileManager.default, tmp = fm.temporaryDirectory
        for n in (try? fm.contentsOfDirectory(atPath: tmp.path)) ?? [] where n.hasPrefix(prefix) {
            let u = tmp.appendingPathComponent(n)
            if let m = (try? fm.attributesOfItem(atPath: u.path))?[.modificationDate] as? Date, Date().timeIntervalSince(m) > 3 * 3600 { try? fm.removeItem(at: u) }
        }
    }

    /// The files to copy: git's view (tracked and not ignored) in a repository, else the project's own listing; never
    /// the app's state, VCS data or build output. The registered tests (`.teacher/tests`) are added by the caller.
    static func listing(_ ws: Workspace) async -> [String] {
        var files: [String]? = nil
        if FileManager.default.fileExists(atPath: ws.url.appendingPathComponent(".git").path), let git = ProcessRunner.which("git") {
            let r = await ProcessRunner.run(git, ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd: ws.url, timeout: 20)
            if r.exitCode == 0 { files = r.stdout.split(separator: "\0").map(String.init) }
        }
        let all = files ?? ProjectStore.projectFiles(ws)
        var seen = Set<String>(), out: [String] = []
        for rel in all where seen.insert(rel).inserted {
            if rel.split(separator: "/").contains(where: { excluded.contains(String($0)) }) { continue }
            let u = ws.url.appendingPathComponent(rel)
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true, (v.fileSize ?? 0) <= ProjectStore.maxFileBytes else { continue }
            out.append(rel)
            if out.count >= 2000 { break }
        }
        return out.sorted()
    }

    /// `files` and the tests copied into `dir`; `node_modules` linked, not copied (read-only use).
    static func populate(_ dir: URL, from ws: Workspace, files: [String]) throws {
        let fm = FileManager.default
        func copy(_ rel: String) throws {
            let dst = dir.appendingPathComponent(rel)
            try fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: ws.url.appendingPathComponent(rel), to: dst)
        }
        for rel in files { try copy(rel) }
        if fm.fileExists(atPath: ws.testsDir.path) {
            let tests = ProjectStore.walk(ws.testsDir).map { ".teacher/tests/" + $0 }
            for rel in tests { try copy(rel) }
        }
        let nm = ws.url.appendingPathComponent("node_modules")
        if fm.fileExists(atPath: nm.path) { try? fm.createSymbolicLink(at: dir.appendingPathComponent("node_modules"), withDestinationURL: nm) }
    }

    /// The registered command with the learner's folder swapped for the copy, in case it names it.
    static func command(_ c: String, from ws: Workspace, to dir: URL) -> String {
        c.replacingOccurrences(of: ws.url.path, with: dir.path)
    }
}

/// Mutation testing without a package: change one thing at a time in a copy of the learner's code, run the registered
/// tests, and see which changes no test noticed. Information, never a gate: it feeds no pass, fail or mastery.
enum Mutation {
    struct Outcome: Sendable { var mutant: Mutant; var status: String; var seconds: Double }   // killed | survived | timeout | invalid
    struct Report: Sendable {
        var command = ""
        var baseline = 0.0
        var available = 0, planned = 0
        var outcomes: [Outcome] = []
        var note: String? = nil           // why it stopped early, or why it did not run
        var red: String? = nil            // the baseline's output tail when it was not green
        var killed: Int { outcomes.filter { $0.status == "killed" }.count }
        var timedOut: Int { outcomes.filter { $0.status == "timeout" }.count }
        var survivors: [Outcome] { outcomes.filter { $0.status == "survived" } }
        var invalid: Int { outcomes.filter { $0.status == "invalid" }.count }
        var judged: Int { killed + timedOut + survivors.count }
        var score: Double? { judged == 0 ? nil : Double(killed + timedOut) / Double(judged) }
    }

    static let buildFailure = try! NSRegularExpression(pattern: #"(SyntaxError|IndentationError|TabError|error\[E\d+\]|:\d+(?::\d+)?: error:|^error: could not compile|BUILD FAILED|compilation failed|Compilation failed|cannot compile)"#, options: [.anchorsMatchLines])
    static let testFailure = try! NSRegularExpression(pattern: #"(AssertionError|--- FAIL|not ok \d|✕|✖|FAILED .*::|assertion failed|XCTAssert)"#)

    /// A failing run is a kill unless it never got to run a test: a mutant that doesn't parse or build says nothing about the tests.
    static func classify(exit: Int32, timedOut: Bool, output: String) -> String {
        if timedOut { return "timeout" }
        if exit == 0 { return "survived" }
        let r = NSRange(output.startIndex..., in: output)
        if buildFailure.firstMatch(in: output, range: r) != nil, testFailure.firstMatch(in: output, range: r) == nil { return "invalid" }
        return "killed"
    }

    /// Per-mutant limit from the baseline: a mutant that makes a loop endless is a kill by timeout, quickly.
    static func timeout(baseline: Double) -> TimeInterval { min(120, max(10, baseline * 3 + 5)) }

    final class Queue: @unchecked Sendable {
        private let lock = NSLock(); private var next = 0; private var results: [Outcome] = []
        let mutants: [Mutant]
        init(_ m: [Mutant]) { mutants = m }
        func take() -> Mutant? { lock.lock(); defer { lock.unlock() }; guard next < mutants.count else { return nil }; next += 1; return mutants[next - 1] }
        func put(_ o: Outcome) -> Int { lock.lock(); defer { lock.unlock() }; results.append(o); return results.count }
        var all: [Outcome] { lock.lock(); defer { lock.unlock() }; return results }
    }

    static func run(ws: Workspace, command: String?, only: [String], limit: Int, budget: TimeInterval, jobs: Int = 4, progress: @escaping @Sendable (String) -> Void) async -> Report {
        var report = Report()
        let started = Date()
        guard let command = command ?? ProjectStore.load(ws)?.testCommand, !command.isEmpty else {
            report.note = "No test command: `project_tests` set registers one (or pass `command`)."
            return report
        }
        report.command = command
        let listing = await Scratch.listing(ws)
        let sources = listing.filter { rel in
            Mutator.sourceExtensions.contains((rel as NSString).pathExtension.lowercased()) && !CodeImpact.isTest(rel)
                && (only.isEmpty || only.contains { rel == $0 || rel.hasSuffix("/" + $0) || rel.contains($0) })
        }
        guard !sources.isEmpty else {
            report.note = "No non-test source files to mutate" + (only.isEmpty ? "." : " matching \(only.joined(separator: ", ")).")
            return report
        }
        let root: URL
        do { root = try Scratch.make() } catch { report.note = "Could not make a scratch folder: \(error.localizedDescription)"; return report }
        defer { try? FileManager.default.removeItem(at: root) }
        let w0 = root.appendingPathComponent("w0")
        do { try FileManager.default.createDirectory(at: w0, withIntermediateDirectories: true); try Scratch.populate(w0, from: ws, files: listing) }
        catch { report.note = "Could not copy the project: \(error.localizedDescription)"; return report }

        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        // The baseline, in the copy: red or unrunnable tests say nothing about mutants.
        progress("Baseline run of `\(command)`…")
        let t0 = Date()
        let base = await ProcessRunner.run(shell, ["-c", Scratch.command(command, from: ws, to: w0)], cwd: w0, timeout: min(budget, 600))
        report.baseline = Date().timeIntervalSince(t0)
        if Task.isCancelled { report.note = "Stopped."; return report }
        guard base.exitCode == 0, !base.timedOut else {
            report.red = String(base.combined.suffix(1500))
            report.note = base.timedOut ? "The baseline timed out: mutation testing needs a suite that finishes." : "The baseline is red (exit \(base.exitCode)): mutation testing compares against a green suite. Get the tests passing first."
            return report
        }

        // The mutants: code the learner changed first, spread over functions.
        var changedRanges: [String: [ClosedRange<Int>]] = [:]
        if ProjectStore.load(ws)?.snapshotAt != nil {
            changedRanges = CodeImpact.parse(await ProjectStore.changes(ws).map(\.diff).joined(separator: "\n")).ranges
        }
        var all: [Mutant] = []
        for rel in sources {
            guard let text = try? String(contentsOf: w0.appendingPathComponent(rel), encoding: .utf8) else { continue }
            all += Mutator.mutants(file: rel, text: text, changed: changedRanges[rel] ?? [])
        }
        report.available = all.count
        let plan = Mutator.select(all, limit: limit)
        report.planned = plan.count
        guard !plan.isEmpty else { report.note = "No mutable operators found in \(sources.count) source file\(sources.count == 1 ? "" : "s")."; return report }

        let workers = min(jobs, plan.count)
        var dirs = [w0]
        for k in 1..<max(1, workers) {
            let d = root.appendingPathComponent("w\(k)")
            if (try? FileManager.default.copyItem(at: w0, to: d)) != nil { dirs.append(d) }
        }
        let perMutant = timeout(baseline: report.baseline)
        let deadline = started.addingTimeInterval(budget)
        let queue = Queue(plan)
        await withTaskGroup(of: Void.self) { group in
            for dir in dirs {
                group.addTask {
                    while !Task.isCancelled, Date() < deadline, let m = queue.take() {
                        let url = dir.appendingPathComponent(m.file)
                        guard let original = try? Data(contentsOf: url), var lines = String(data: original, encoding: .utf8).map({ $0.components(separatedBy: "\n") }), m.line <= lines.count else { continue }
                        lines[m.line - 1] = m.newLine
                        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
                        let t = Date()
                        let r = await ProcessRunner.run(shell, ["-c", Scratch.command(command, from: ws, to: dir)], cwd: dir, timeout: min(perMutant, max(5, deadline.timeIntervalSinceNow)))
                        try? original.write(to: url)
                        if Task.isCancelled { break }
                        let status = classify(exit: r.exitCode, timedOut: r.timedOut, output: r.combined)
                        let n = queue.put(Outcome(mutant: m, status: status, seconds: Date().timeIntervalSince(t)))
                        progress("\(n)/\(plan.count) mutants: \(m.file):\(m.line) \(status)")
                    }
                }
            }
        }
        report.outcomes = queue.all.sorted { ($0.mutant.file, $0.mutant.line, $0.mutant.kind) < ($1.mutant.file, $1.mutant.line, $1.mutant.kind) }
        if Task.isCancelled { report.note = "Stopped after \(report.outcomes.count) of \(plan.count) mutants." }
        else if report.outcomes.count < plan.count { report.note = "Time budget (\(Int(budget)) s) reached after \(report.outcomes.count) of \(plan.count) planned mutants; the rest were not tried." }
        return report
    }

    static func render(_ r: Report, cap: Int = 12) -> String {
        guard r.note == nil || !r.outcomes.isEmpty else {
            return (r.note ?? "") + (r.red.map { "\n--- baseline output (tail) ---\n" + $0 } ?? "")
        }
        var s = "Mutation testing on a scratch copy (`\(r.command)`, baseline \(String(format: "%.1f", r.baseline)) s): \(r.outcomes.count) of \(r.available) possible mutants tried.\n"
        if let sc = r.score {
            s += "Score \(Int((sc * 100).rounded()))%: \(r.killed) killed, \(r.timedOut) timed out (counted as caught), \(r.survivors.count) survived" + (r.invalid > 0 ? ", \(r.invalid) did not build (not counted)" : "") + ".\n"
        } else { s += "No mutant could be judged (\(r.invalid) did not build).\n" }
        if let n = r.note { s += n + "\n" }
        if !r.survivors.isEmpty {
            s += "\nSurvivors: each changed line passed every test, so no test noticed it.\n"
            for (i, o) in r.survivors.prefix(cap).enumerated() {
                let m = o.mutant
                s += "S\(i + 1) \(m.file):\(m.line)\(m.function.map { " (in \($0))" } ?? "")  [\(m.kind)]\n    was:  \(m.original)\n    now:  \(m.mutated)\n"
            }
            if r.survivors.count > cap { s += "… \(r.survivors.count - cap) more survivors\n" }
            s += "\nA survivor is a missing test or an equivalent change (behaviour identical). For each, ask the learner what input would make the two lines behave differently and what test would catch it; do not write the test. Information only: it does not change pass or fail."
        } else if r.judged > 0 {
            s += "No survivors among the mutants tried: the tests noticed every change. That is evidence about these mutants, not proof the suite is complete."
        }
        return s
    }

    static func meta(_ r: Report) -> JSON {
        func o(_ x: Outcome) -> JSON {
            ["file": .string(x.mutant.file), "line": .number(Double(x.mutant.line)), "kind": .string(x.mutant.kind), "was": .string(x.mutant.original), "now": .string(x.mutant.mutated),
             "function": x.mutant.function.map { .string($0) } ?? .null, "status": .string(x.status)]
        }
        return ["score": r.score.map { .number(($0 * 1000).rounded() / 1000) } ?? .null, "killed": .number(Double(r.killed)), "timedOut": .number(Double(r.timedOut)),
                "survived": .number(Double(r.survivors.count)), "invalid": .number(Double(r.invalid)), "tried": .number(Double(r.outcomes.count)),
                "planned": .number(Double(r.planned)), "available": .number(Double(r.available)), "note": r.note.map { .string($0) } ?? .null,
                "survivors": .array(r.survivors.prefix(40).map(o)), "caught": .array(r.outcomes.filter { $0.status != "survived" && $0.status != "invalid" }.prefix(60).map(o))]
    }

    /// The last run's one-line summary, kept beside the review snapshot and valid only while the files are as they were.
    struct Saved: Codable { var digest: String; var at: Date; var score: Double; var tried: Int; var survived: Int }
    static func saveURL(_ ws: Workspace) -> URL { ws.stateDir.appendingPathComponent("review/mutation.json") }
    static func save(_ r: Report, ws: Workspace) {
        guard let sc = r.score, r.note == nil || !r.outcomes.isEmpty else { return }
        try? FileManager.default.createDirectory(at: saveURL(ws).deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        try? e.encode(Saved(digest: ProjectStore.digest(ws), at: Date(), score: sc, tried: r.outcomes.count, survived: r.survivors.count)).write(to: saveURL(ws), options: .atomic)
    }
    /// For `project_review` start: a line when a run exists for the files as they are now (a stat per file).
    static func summaryLine(ws: Workspace) -> String? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: saveURL(ws)), let s = try? d.decode(Saved.self, from: data), s.digest == ProjectStore.digest(ws) else { return nil }
        return "Mutation run on these files (\(ProjectTestsTool.ago(s.at))): \(Int((s.score * 100).rounded()))% of \(s.tried) mutants caught, \(s.survived) survived — `mutate` shows them; survivors are tests to ask for, not a grade."
    }
}

struct MutateTool: Tool {
    let name = "mutate"
    let description = """
    Mutation testing: how well do the learner's tests notice a bug? On a scratch copy (their folder is never touched) \
    it changes one thing at a time in their non-test code (`<`↔`<=`, `==`↔`!=`, `+`↔`-`, `&&`↔`||`, true↔false, a number ±1, a \
    negated condition, a dropped return or call) and runs the registered test command; a change the tests still pass is a \
    survivor — something no test noticed. Needs a green baseline. Default 20 mutants (max 60), 4 at a time, spread over \
    functions, code they changed first; `files` narrows it. You get the score and each survivor's `file:line`, original and \
    mutated line; the learner gets a card. Survivors are questions for them ("what test would catch this?"), never a test \
    you write, and the score is information, not a grade.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "limit": Schema.integer("Mutants to try (default 20, max 60)."),
            "files": Schema.array(Schema.string("Path or name"), "Only mutate source files matching these."),
            "seconds": Schema.integer("Time budget for the whole run, baseline included (default 300, max 900)."),
            "command": Schema.string("Test command (default: the project's registered one)."),
        ])
    }
    func summary(_ input: JSON) -> String { "mutation testing" + ((input["files"]?.array?.compactMap(\.string)).map { $0.isEmpty ? "" : " of " + $0.joined(separator: ", ") } ?? "") }
    func timeout(_ input: JSON) -> Double? { Double(min(900, max(30, input["seconds"]?.int ?? 300))) + 60 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let ws = ctx.services.workspace
        let limit = min(60, max(1, input["limit"]?.int ?? 20))
        let budget = TimeInterval(min(900, max(30, input["seconds"]?.int ?? 300)))
        let r = await Mutation.run(ws: ws, command: input["command"]?.string, only: input["files"]?.array?.compactMap(\.string) ?? [], limit: limit, budget: budget, progress: ctx.progress)
        Mutation.save(r, ws: ws)
        return ToolOutput(text: Mutation.render(r), isError: r.outcomes.isEmpty && r.note != nil, meta: Mutation.meta(r))
    }
}
