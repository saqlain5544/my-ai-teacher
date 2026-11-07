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

    /// What `listing` found and what it left out, by reason: a copy missing files can turn a green suite red, so the
    /// reasons travel with the result instead of the learner being blamed for it.
    struct Listing: Sendable {
        var files: [String] = []; var left: [String: Int] = [:]; var bytes = 0
        var leftOut: String? { left.isEmpty ? nil : left.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", ") }
    }
    static let maxFiles = 2000, maxBytes = 50_000_000
    /// Folders whose absence is the point of a copy (VCS data, the app's state, caches, dependencies linked separately).
    static let silent: Set<String> = [".teacher", ".git", "node_modules", "__pycache__", ".pytest_cache", ".venv", "venv", ".gradle", "DerivedData", ".build", "zig-cache", ".zig-cache"]

    /// The files to copy: the repository's view (tracked and not ignored), run with the app's hardening so a repository's
    /// config starts nothing, else the project's own listing; never the app's state, VCS data or build output.
    /// The registered tests (`.teacher/tests`) are added by the caller.
    static func listing(_ ws: Workspace) async -> Listing {
        var files: [String]? = nil
        if FileManager.default.fileExists(atPath: ws.url.appendingPathComponent(".git").path) {
            let r = await ProcessRunner.run(Worktree.git, Worktree.safe + ["ls-files", "-z", "--cached", "--others", "--exclude-standard"], cwd: ws.url, timeout: 20)
            if r.exitCode == 0 { files = r.stdout.split(separator: "\0").map(String.init) }
        }
        let all = files ?? walk(ws.url)
        var l = Listing(), seen = Set<String>()
        for rel in all where seen.insert(rel).inserted {
            let parts = rel.split(separator: "/").map(String.init)
            if parts.contains(where: { silent.contains($0) }) { continue }
            if let hit = parts.first(where: { excluded.contains($0) }) { l.left["files under a folder named \(hit)", default: 0] += 1; continue }
            let u = ws.url.appendingPathComponent(rel)
            guard let v = try? u.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), v.isRegularFile == true else { l.left["links or special files", default: 0] += 1; continue }
            if (v.fileSize ?? 0) > ProjectStore.maxFileBytes { l.left["files over 1 MB", default: 0] += 1; continue }
            if l.files.count >= maxFiles { l.left["files past the \(maxFiles)-file cap", default: 0] += 1; continue }
            l.files.append(rel); l.bytes += v.fileSize ?? 0
        }
        l.files.sort()
        return l
    }

    /// Every file under a folder that is not in a repository (hidden files and folders are the app's or the tool's, not the project's).
    static func walk(_ root: URL) -> [String] {
        let fm = FileManager.default, base = root.resolvingSymlinksInPath().path
        guard let e = fm.enumerator(at: root.resolvingSymlinksInPath(), includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        while let u = e.nextObject() as? URL {
            if silent.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            let path = u.resolvingSymlinksInPath().path   // the enumerator may answer /private/var/… for /var/…
            if path.hasPrefix(base + "/") { out.append(String(path.dropFirst(base.count + 1))) }
            if out.count > 20_000 { break }
        }
        return out
    }

    /// Entries of `node_modules` (and `@scope` folders in it) that are links resolving outside it: a workspace or `file:`
    /// dependency, which would run the learner's real, unmutated code in every mutant.
    static func linksOutside(_ ws: Workspace) -> [String] {
        let fm = FileManager.default, nm = ws.url.appendingPathComponent("node_modules")
        guard fm.fileExists(atPath: nm.path) else { return [] }
        let real = nm.resolvingSymlinksInPath().path
        var out: [String] = []
        func scan(_ dir: URL, _ prefix: String) {
            for n in (try? fm.contentsOfDirectory(atPath: dir.path)) ?? [] where !n.hasPrefix(".") {
                let u = dir.appendingPathComponent(n)
                if (try? fm.destinationOfSymbolicLink(atPath: u.path)) != nil {
                    if !u.resolvingSymlinksInPath().path.hasPrefix(real + "/") { out.append(prefix + n) }
                } else if n.hasPrefix("@"), prefix.isEmpty { scan(u, n + "/") }
            }
        }
        scan(nm, "")
        return out
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
            for rel in ProjectStore.walk(ws.testsDir).map({ ".teacher/tests/" + $0 }) { try copy(rel) }
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
/// A wrong number is worse than none, so a mutant counts only on positive evidence: a test failing (killed), the tests
/// passing (survived) or the mutant's own time limit (timeout). A change that doesn't build, a crash or a port clash
/// is its own status and is left out of the score.
enum Mutation {
    struct Outcome: Sendable { var mutant: Mutant; var status: String; var seconds: Double }   // killed | survived | timeout | invalid | errored
    struct Report: Sendable {
        var command = ""
        var baseline = 0.0
        var available = 0, planned = 0
        var outcomes: [Outcome] = []
        var note: String? = nil           // why it stopped early, or why it did not run
        var red: String? = nil            // the baseline's output tail when it was not green
        var left: String? = nil           // what the scratch copy left out, by reason
        var scope: [String] = []          // the `files` filter, when the run was limited to some
        var digest = ""                   // the files as they were when the run began
        var killed: Int { outcomes.filter { $0.status == "killed" }.count }
        var timedOut: Int { outcomes.filter { $0.status == "timeout" }.count }
        var survivors: [Outcome] { outcomes.filter { $0.status == "survived" } }
        var invalid: Int { outcomes.filter { $0.status == "invalid" }.count }
        var errored: Int { outcomes.filter { $0.status == "errored" }.count }
        var judged: Int { killed + timedOut + survivors.count }
        var score: Double? { judged == 0 ? nil : Double(killed + timedOut) / Double(judged) }
    }

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p, options: [.anchorsMatchLines]) }
    /// The run itself went wrong, not the code under test: a port another mutant holds.
    static let environment = re(#"(EADDRINUSE|[Aa]ddress already in use|Errno 98|Errno 48)"#)
    static let buildFailure = re(#"(SyntaxError|IndentationError|TabError|error\[E\d+\]|:\d+(?::\d+)?: error:|^error: could not compile|BUILD FAILED|compilation failed|Compilation failed|cannot compile|\[build failed\]|\[setup failed\]|imported and not used|declared and not used|error TS\d+|Test suite failed to run|Cannot find module|ModuleNotFoundError|ImportError)"#)
    /// A test said no.
    static let testFailure = re(#"(AssertionError|Assertion failed|--- FAIL|^FAIL: |not ok \d|✕|✖|✗|FAILED \(|FAILED .*::|assertion failed|XCTAssert|failures?[:=] ?[1-9]|Expected: )"#)
    /// The program ran and died in the code under test, which no build error explains.
    static let uncaught = re(#"(Traceback \(most recent call last\)|\b(TypeError|ReferenceError|RangeError): |\bpanic: )"#)

    static func classify(exit: Int32, timedOut: Bool, output: String) -> String {
        if timedOut { return "timeout" }
        if exit == 0 { return "survived" }
        let r = NSRange(output.startIndex..., in: output)
        func has(_ x: NSRegularExpression) -> Bool { x.firstMatch(in: output, range: r) != nil }
        if has(environment) { return "errored" }
        let strong = has(testFailure)
        if has(buildFailure), !strong { return "invalid" }
        if [126, 127, 134, 137, 139, -1].contains(exit) { return "errored" }
        if strong { return "killed" }
        let parsed = TestOutput.parse(output, exit: exit)
        if parsed.counted, parsed.failed > 0 { return "killed" }
        if has(uncaught) { return "killed" }
        return "errored"
    }

    /// Per-mutant limit from the baseline: a mutant that makes a loop endless is caught by this timeout, quickly.
    static func timeout(baseline: Double) -> TimeInterval { min(120, max(10, baseline * 3 + 5)) }

    final class Queue: @unchecked Sendable {
        private let lock = NSLock(); private var next = 0; private var results: [Outcome] = []
        let mutants: [Mutant]
        init(_ m: [Mutant]) { mutants = m }
        func take() -> Mutant? { lock.lock(); defer { lock.unlock() }; guard next < mutants.count else { return nil }; next += 1; return mutants[next - 1] }
        func put(_ o: Outcome) -> Int { lock.lock(); defer { lock.unlock() }; results.append(o); return results.count }
        var all: [Outcome] { lock.lock(); defer { lock.unlock() }; return results }
    }

    /// Python writes `.pyc` keyed on the source's whole-second mtime and size: a second mutant of the same size in the same
    /// second would load the first one's bytecode. No bytecode is written, and none is left from the baseline.
    static func environment(_ extra: [String: String] = [:]) -> [String: String] {
        ShellEnvironment.shared.all.merging(["PYTHONDONTWRITEBYTECODE": "1"].merging(extra) { $1 }) { $1 }
    }
    static func clearBytecode(_ dir: URL) {
        let fm = FileManager.default
        for rel in (fm.enumerator(atPath: dir.path)?.allObjects as? [String]) ?? [] where rel.hasSuffix("__pycache__") && !rel.hasPrefix("node_modules") { try? fm.removeItem(at: dir.appendingPathComponent(rel)) }
    }

    static func run(ws: Workspace, command: String?, only: [String], limit: Int, budget: TimeInterval, jobs: Int = 4, progress: @escaping @Sendable (String) -> Void) async -> Report {
        var report = Report()
        report.scope = only
        report.digest = ProjectStore.digest(ws)   // before the copy: an edit while this runs makes the result stale, not current
        let started = Date()
        guard let command = command ?? ProjectStore.load(ws)?.testCommand, !command.isEmpty else {
            report.note = "No test command: `project_tests` set registers one (or pass `command`)."
            return report
        }
        report.command = command
        let listing = await Scratch.listing(ws)
        report.left = listing.leftOut
        if listing.bytes > Scratch.maxBytes {
            report.note = "The project's files add up to \(listing.bytes / 1_000_000) MB, over the \(Scratch.maxBytes / 1_000_000) MB a scratch copy may hold; nothing was run."
            return report
        }
        let sources = listing.files.filter { rel in
            Mutator.sourceExtensions.contains((rel as NSString).pathExtension.lowercased()) && !CodeImpact.isTest(rel)
                && (only.isEmpty || only.contains { rel == $0 || rel.hasSuffix("/" + $0) || rel.contains($0) })
        }
        guard !sources.isEmpty else {
            report.note = "No non-test source files to mutate" + (only.isEmpty ? "." : " matching \(only.joined(separator: ", ")).")
            return report
        }
        let outside = Scratch.linksOutside(ws)
        if !outside.isEmpty {
            report.note = "node_modules links to code outside it (\(outside.prefix(4).joined(separator: ", "))): those packages would run the real, unmutated files in every mutant, so every change would falsely survive. Nothing was run."
            return report
        }
        let root: URL
        do { root = try Scratch.make() } catch { report.note = "Could not make a scratch folder: \(error.localizedDescription)"; return report }
        defer { try? FileManager.default.removeItem(at: root) }
        let w0 = root.appendingPathComponent("w0")
        do { try FileManager.default.createDirectory(at: w0, withIntermediateDirectories: true); try Scratch.populate(w0, from: ws, files: listing.files) }
        catch { report.note = "Could not copy the project: \(error.localizedDescription)"; return report }

        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let env = environment()
        // The baseline, in the copy: red or unrunnable tests say nothing about mutants.
        progress("Baseline run of `\(command)`…")
        let t0 = Date()
        let base = await ProcessRunner.run(shell, ["-c", Scratch.command(command, from: ws, to: w0)], cwd: w0, env: env, timeout: min(budget, 600))
        report.baseline = Date().timeIntervalSince(t0)
        clearBytecode(w0)
        if Task.isCancelled { report.note = "Stopped."; return report }
        guard base.exitCode == 0, !base.timedOut else {
            report.red = String(base.combined.suffix(1500))
            let why = listing.leftOut.map { " The scratch copy left out \($0), which may be why: that is the copy, not necessarily the learner's work." } ?? ""
            report.note = (base.timedOut ? "The baseline timed out: mutation testing needs a suite that finishes." : "The baseline is red (exit \(base.exitCode)): mutation testing compares against a green suite. Get the tests passing first.") + why
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
                    // A mutant starts only with time for its whole limit: a timeout cut short by the budget is not "caught".
                    while !Task.isCancelled, deadline.timeIntervalSinceNow >= perMutant, let m = queue.take() {
                        let url = dir.appendingPathComponent(m.file)
                        guard let original = try? Data(contentsOf: url), var lines = String(data: original, encoding: .utf8).map({ $0.components(separatedBy: "\n") }), m.line <= lines.count else { continue }
                        lines[m.line - 1] = m.newLine
                        guard (try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)) != nil else { continue }
                        let t = Date()
                        let r = await ProcessRunner.run(shell, ["-c", Scratch.command(command, from: ws, to: dir)], cwd: dir, env: env, timeout: perMutant)
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
        else if report.outcomes.count < plan.count { report.note = "Time budget (\(Int(budget)) s) reached after \(report.outcomes.count) of \(plan.count) planned mutants; the rest were not started (each needs time for its full \(Int(perMutant)) s limit)." }
        return report
    }

    static func render(_ r: Report, cap: Int = 12) -> String {
        guard r.note == nil || !r.outcomes.isEmpty else {
            return (r.note ?? "") + (r.left.map { "\nLeft out of the copy: \($0)." } ?? "") + (r.red.map { "\n--- baseline output (tail) ---\n" + $0 } ?? "")
        }
        var s = "Mutation testing on a scratch copy (`\(r.command)`, baseline \(String(format: "%.1f", r.baseline)) s): \(r.outcomes.count) of \(r.available) possible mutants tried" + (r.scope.isEmpty ? "" : ", only in files matching \(r.scope.joined(separator: ", "))") + ".\n"
        if let sc = r.score {
            s += "Score \(Int((sc * 100).rounded()))% of the \(r.judged) judged: \(r.killed) killed, \(r.timedOut) timed out (counted as caught), \(r.survivors.count) survived"
                + (r.invalid > 0 ? ", \(r.invalid) did not build" : "") + (r.errored > 0 ? ", \(r.errored) errored (a crash, a clash or no test result)" : "") + (r.invalid + r.errored > 0 ? " (not counted)" : "") + ".\n"
        } else { s += "No mutant could be judged (\(r.invalid) did not build, \(r.errored) errored).\n" }
        if let l = r.left { s += "Left out of the copy: \(l).\n" }
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
                "survived": .number(Double(r.survivors.count)), "invalid": .number(Double(r.invalid)), "errored": .number(Double(r.errored)), "tried": .number(Double(r.outcomes.count)),
                "planned": .number(Double(r.planned)), "available": .number(Double(r.available)), "note": r.note.map { .string($0) } ?? .null, "left": r.left.map { .string($0) } ?? .null,
                "survivors": .array(r.survivors.prefix(40).map(o)), "caught": .array(r.outcomes.filter { $0.status == "killed" || $0.status == "timeout" }.prefix(60).map(o))]
    }

    /// The last run's one-line summary, kept beside the review snapshot and valid only while the files are as they were
    /// when the run began.
    struct Saved: Codable { var digest: String; var at: Date; var score: Double; var tried: Int; var survived: Int; var available: Int?; var scope: [String]? }
    static func saveURL(_ ws: Workspace) -> URL { ws.stateDir.appendingPathComponent("review/mutation.json") }
    static func save(_ r: Report, ws: Workspace) {
        guard let sc = r.score, !r.digest.isEmpty, r.note == nil || !r.outcomes.isEmpty else { return }
        try? FileManager.default.createDirectory(at: saveURL(ws).deletingLastPathComponent(), withIntermediateDirectories: true)
        let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970
        try? e.encode(Saved(digest: r.digest, at: Date(), score: sc, tried: r.outcomes.count, survived: r.survivors.count, available: r.available, scope: r.scope.isEmpty ? nil : r.scope)).write(to: saveURL(ws), options: .atomic)
    }
    /// For `project_review` start: a line when a run exists for the files as they are now (a stat per file).
    static func summaryLine(ws: Workspace) -> String? {
        let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970
        guard let data = try? Data(contentsOf: saveURL(ws)), let s = try? d.decode(Saved.self, from: data), s.digest == ProjectStore.digest(ws) else { return nil }
        let sample = "a sample of \(s.tried)" + (s.available.map { " of \($0) possible" } ?? "") + " mutants" + ((s.scope ?? []).isEmpty ? "" : " in files matching \(s.scope!.joined(separator: ", "))")
        return "Mutation run on these files (\(ProjectTestsTool.ago(s.at))): \(Int((s.score * 100).rounded()))% caught of \(sample), \(s.survived) survived — `mutate` shows them; survivors are tests to ask for, not a grade."
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
