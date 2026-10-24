import Foundation

/// A code mentor's project in the lesson folder: the test command, every test run, the review rounds with their
/// findings, and a snapshot of the learner's files at the last review (so the next review sees only what changed).
/// Lives in `.teacher/project.json` and `.teacher/review/`, with the folder, like the tests in `.teacher/tests`.
struct MentorProject: Codable, Sendable, Equatable {
    struct TestRun: Codable, Sendable, Equatable {
        var at: Date
        var passed: Int
        var failed: Int
        /// The command itself couldn't run (not found, not executable, timed out): neither green nor red.
        var errored: Bool
        var seconds: Double
        var failing: [String]
        var exit: Int32
        var why: String          // set | run | review
        /// The runner's summary was read into `passed`/`failed`; otherwise only the exit code speaks.
        var counted: Bool? = nil
        /// Green is the exit code: every test runner, in any language, exits 0 when its tests pass.
        var green: Bool { !errored && exit == 0 }
        var line: String {
            if errored { return "the tests could not run" }
            if counted == false { return exit == 0 ? "passed (exit 0)" : "failed (exit \(exit))" }
            return "\(passed) passed, \(failed) failed"
        }
    }
    struct Finding: Codable, Sendable, Equatable, Identifiable {
        var id: Int
        var file: String
        var line: Int?
        var severity: String     // must | should | nit
        var text: String
        var concept: String?
        var resolved = false
        /// A hint ladder toward the fix, never the code: a nudge, a targeted hint, the concept or a worked step on
        /// something else. The learner reveals one rung at a time; `revealed` rungs count as help.
        var hints: [String]? = nil
        var revealed: Int? = nil
    }
    struct Round: Codable, Sendable, Equatable {
        var number: Int
        var at: Date
        var verdict: String      // pass | changes
        var summary: String?
        var findings: [Finding]
        var tests: TestRun?
        /// The learner's own review before this round, and the help they had since the last one.
        var selfReview: SelfReview? = nil
        var help: String? = nil
    }

    var title: String?
    var subject: String?
    var concept: String?
    var testCommand: String?
    var createdAt = Date()
    var runs: [TestRun] = []
    var rounds: [Round] = []
    /// The learner's files at the last baseline (the proven starter, or the last review).
    var snapshotAt: Date?
    var snapshotWhy: String?
    /// The review `start` a round's `findings` belong to: when it ran and which files had changed. A round needs one,
    /// with changes; a pass needs its run green.
    var openReview: OpenReview?
    struct OpenReview: Codable, Sendable, Equatable {
        var at: Date; var changed: [String]; var run: TestRun?
    }

    /// The learner unlocked the tests for the mentor to change (`project_tests` unlock): open until the next `set`.
    var testsUnlockedAt: Date?
    struct SuiteChange: Codable, Sendable, Equatable { var at: Date; var why: String }
    var suiteChanges: [SuiteChange]? = nil
    /// Help the learner had since the last review (hints revealed, hints asked for, a solution seen): a pass after help
    /// is recorded as evidence, not as unaided mastery.
    struct HelpUse: Codable, Sendable, Equatable { var at: Date; var kind: String; var detail: String }   // hint | solution
    var help: [HelpUse]? = nil
    /// What the learner said before asking for a review: what they fixed, what they're unsure of, what they expect to fail.
    struct SelfReview: Codable, Sendable, Equatable { var at: Date; var fixed: String; var unsure: String; var expectFail: String }
    var selfReview: SelfReview? = nil
    /// After a pass: the learner explains a design choice, trade-off or failure mode; the mentor grades it.
    struct ExplainBack: Codable, Sendable, Equatable { var at: Date; var question: String?; var verdict: String?; var round: Int }
    var explainBack: ExplainBack? = nil
    /// What the guard stopped (refused writes, undone changes, withheld code), for the learner to see. No code in it.
    struct GuardEvent: Codable, Sendable, Equatable { var at: Date; var kind: String; var detail: String }
    var guardLog: [GuardEvent]? = nil

    var helpSinceReview: Help {
        let since = rounds.last?.at ?? .distantPast
        let kinds = (help ?? []).filter { $0.at > since }.map(\.kind)
        return kinds.contains("solution") ? .solution : kinds.isEmpty ? .none : .hint
    }
    mutating func log(_ kind: String, _ detail: String) {
        var l = guardLog ?? []
        l.append(GuardEvent(at: Date(), kind: kind, detail: detail))
        if l.count > 50 { l.removeFirst(l.count - 50) }
        guardLog = l
    }

    var lastRun: TestRun? { runs.last }
    /// Baselined and not yet passed: the learner is working on it, so its files are theirs.
    var isOpen: Bool { snapshotAt != nil && rounds.last?.verdict != "pass" }
    var openFindings: [Finding] { rounds.last?.findings.filter { !$0.resolved } ?? [] }
    var nextFindingID: Int { (rounds.flatMap(\.findings).map(\.id).max() ?? 0) + 1 }
}

/// Where a project's state and snapshots live, and what changed since the snapshot.
enum ProjectStore {
    static let maxFiles = 400, maxFileBytes = 1_000_000, maxDiffLines = 400, maxDiffChars = 24_000

    static func file(_ ws: Workspace) -> URL { ws.stateDir.appendingPathComponent("project.json") }
    static func snapshotDir(_ ws: Workspace) -> URL { ws.stateDir.appendingPathComponent("review/snapshot", isDirectory: true) }
    private static func manifestURL(_ ws: Workspace) -> URL { ws.stateDir.appendingPathComponent("review/snapshot.json") }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; e.outputFormatting = [.prettyPrinted, .sortedKeys]; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    static func load(_ ws: Workspace) -> MentorProject? {
        guard let d = try? Data(contentsOf: file(ws)) else { return nil }
        return try? dec.decode(MentorProject.self, from: d)
    }
    /// Every change to a project goes through here: the record is read fresh and written under one lock
    /// (the mentor's tools, the guard and the Project panel all write it).
    static let writes = NSRecursiveLock()
    @discardableResult
    static func mutate(_ ws: Workspace, _ body: (inout MentorProject) -> Void) -> MentorProject {
        writes.lock(); defer { writes.unlock() }
        var p = load(ws) ?? MentorProject()
        body(&p)
        save(p, ws)
        return p
    }
    static func save(_ p: MentorProject, _ ws: Workspace) {
        writes.lock(); defer { writes.unlock() }
        var p = p
        if p.runs.count > 60 { p.runs.removeFirst(p.runs.count - 60) }
        try? FileManager.default.createDirectory(at: ws.stateDir, withIntermediateDirectories: true)
        guard let d = try? enc.encode(p) else { return }
        try? d.write(to: file(ws), options: .atomic)
        EventBus.publish(.projectChanged(folder: ws.url.path))
    }
    /// The learner's project files: text files under the folder, outside the app's state and build folders, bounded.
    static func projectFiles(_ ws: Workspace) -> [String] {
        let fm = FileManager.default
        // Resolved paths on both sides: the enumerator returns /private/var/… for a folder given as /var/… .
        let root = ws.url.resolvingSymlinksInPath()
        guard let e = fm.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsPackageDescendants]) else { return [] }
        var out: [String] = []
        while let raw = e.nextObject() as? URL {
            let u = raw.resolvingSymlinksInPath()
            let name = u.lastPathComponent
            let v = try? u.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true { if ProjectProfile.skip.contains(name) || name.hasPrefix(".") { e.skipDescendants() }; continue }
            // Dotfiles (.env, .npmrc) hold secrets, not the learner's work: never snapshotted, never in a diff.
            if name.hasPrefix(".") || ProjectProfile.skip.contains(name) { continue }
            if (v?.fileSize ?? 0) > maxFileBytes { continue }
            guard Self.isText(u) else { continue }
            guard u.path.hasPrefix(root.path + "/") else { continue }
            out.append(String(u.path.dropFirst(root.path.count + 1)))
            if out.count >= maxFiles { break }
        }
        return out.sorted()
    }

    /// A text file, judged by its first 4 KB (the whole file is never read just to list it).
    static func isText(_ u: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: u) else { return false }
        defer { try? h.close() }
        let head = (try? h.read(upToCount: 4096)) ?? Data()
        return !head.contains(0)
    }
    /// The files the snapshot holds, from its manifest.
    private static func snapshotted(_ ws: Workspace) -> Set<String> {
        guard let d = try? Data(contentsOf: manifestURL(ws)), let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return [] }
        return Set(m.keys)
    }

    /// Keeps a finished project's record as `.teacher/projects/<n>.json`, before the next project replaces it.
    static func archive(_ ws: Workspace) {
        writes.lock(); defer { writes.unlock() }
        let dir = ws.stateDir.appendingPathComponent("projects", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let n = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).count + 1
        try? FileManager.default.copyItem(at: file(ws), to: dir.appendingPathComponent("\(n).json"))
    }

    /// Records the project's files as the baseline for the next review.
    static func snapshot(_ ws: Workspace, why: String) {
        let fm = FileManager.default
        let dir = snapshotDir(ws)
        try? fm.removeItem(at: dir)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var manifest: [String: String] = [:]
        for rel in projectFiles(ws) {
            let src = ws.url.appendingPathComponent(rel), dst = dir.appendingPathComponent(rel)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil { manifest[rel] = stamp(src) }
        }
        if let d = try? JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys]) { try? d.write(to: manifestURL(ws), options: .atomic) }
        if load(ws) != nil { mutate(ws) { $0.snapshotAt = Date(); $0.snapshotWhy = why } }
    }
    private static func stamp(_ u: URL) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
        return "\(((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0))/\((a[.size] as? NSNumber)?.intValue ?? 0)"
    }

    /// How many files differ from the snapshot by date or size (cheap: for the state line on every request).
    static func changedCount(_ ws: Workspace) -> Int? {
        guard let d = try? Data(contentsOf: manifestURL(ws)), let m = try? JSONSerialization.jsonObject(with: d) as? [String: String] else { return nil }
        let now = projectFiles(ws)
        var n = 0
        for rel in now where m[rel] != stamp(ws.url.appendingPathComponent(rel)) { n += 1 }
        n += m.keys.filter { !now.contains($0) }.count
        return n
    }

    struct Change: Sendable, Equatable { var path: String; var kind: String; var diff: String; var added: Int; var removed: Int }

    /// What changed since the snapshot, as unified diffs (capped). No snapshot: every file counts as added.
    static func changes(_ ws: Workspace) async -> [Change] {
        let fm = FileManager.default
        let dir = snapshotDir(ws)
        let before = snapshotted(ws)
        let now = projectFiles(ws)
        var out: [Change] = []
        for rel in now {
            let cur = ws.url.appendingPathComponent(rel), old = dir.appendingPathComponent(rel)
            if before.contains(rel) {
                if fm.contents(atPath: cur.path) == fm.contents(atPath: old.path) { continue }
                out.append(await change(rel, kind: "modified", old: old, new: cur))
            } else {
                out.append(await change(rel, kind: "added", old: nil, new: cur))
            }
        }
        for rel in before.sorted() where !now.contains(rel) { out.append(await change(rel, kind: "deleted", old: dir.appendingPathComponent(rel), new: nil)) }
        return out
    }

    private static func change(_ rel: String, kind: String, old: URL?, new: URL?) async -> Change {
        let r = await ProcessRunner.run("/usr/bin/diff", ["-u", "--label", "a/\(rel)", "--label", "b/\(rel)", old?.path ?? "/dev/null", new?.path ?? "/dev/null"], timeout: 20)
        var lines = r.stdout.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count, removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
        if lines.count > maxDiffLines { lines = Array(lines.prefix(maxDiffLines)) + ["… \(lines.count - maxDiffLines) more lines"] }
        return Change(path: rel, kind: kind, diff: lines.joined(separator: "\n"), added: added, removed: removed)
    }

    /// The diffs as one block for the model, within the cap (the largest files are cut first).
    static func render(_ changes: [Change]) -> String {
        guard !changes.isEmpty else { return "No files changed since the last review." }
        let head = "\(changes.count) file\(changes.count == 1 ? "" : "s") changed (+\(changes.reduce(0) { $0 + $1.added }) −\(changes.reduce(0) { $0 + $1.removed })): " +
            changes.map { "\($0.path) (\($0.kind), +\($0.added) −\($0.removed))" }.joined(separator: ", ")
        var budget = maxDiffChars
        var parts: [String] = []
        for c in changes.sorted(by: { $0.diff.count < $1.diff.count }) {
            if c.diff.count <= budget { parts.append(c.diff); budget -= c.diff.count }
            else { parts.append("--- \(c.path): \(c.diff.count) characters of diff, too long to show; `read` the file."); }
        }
        return head + "\n```diff\n" + parts.joined(separator: "\n") + "\n```"
    }
}

/// Test runners' own summaries, read into numbers and the names of the failing tests: pytest, jest/vitest, mocha,
/// go test, swift test, cargo test, zig test, rspec, mix test, ctest, and anything that prints "N passed, M failed".
enum TestOutput {
    /// `counted`: a runner's summary was recognised. Red or green never depends on it — the exit code decides — so a
    /// runner this list doesn't know (any language's) works the same, with only the counts missing.
    struct Result: Sendable, Equatable { var passed: Int; var failed: Int; var failing: [String]; var errored: Bool; var counted = true }

    private static func int(_ s: Substring) -> Int { Int(s) ?? 0 }
    private static func first(_ pattern: String, in text: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]), let m = re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        return (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: text).map { String(text[$0]) } ?? "" }
    }
    private static func all(_ pattern: String, in text: String, group: Int = 1) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.anchorsMatchLines]) else { return [] }
        return re.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { m in Range(m.range(at: group), in: text).map { String(text[$0]).trimmingCharacters(in: .whitespaces) } }
    }

    static func parse(_ raw: String, exit: Int32) -> Result {
        // Colour codes (deno, ExUnit, bun) would hide every summary below.
        let output = raw.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[A-Za-z]", with: "", options: .regularExpression)
        // 126/127: the shell couldn't find or run the command — nothing ran.
        let couldNotRun = exit == 126 || exit == 127
        var passed = 0, failed = 0, found = false
        // pytest: "3 passed, 1 failed in 0.1s" / "4 passed" / "1 failed, 3 passed, 2 errors"
        // pytest's banner line, or a bare summary line ("4 passed in 0.1s"): never a count buried in a log line.
        if let m = first(#"^=+ .*?(\d+ (?:passed|failed|error)[^=]*?) in [\d.]+s"#, in: output) ?? first(#"^\s*(\d+ (?:passed|failed)\b[^\n]*?) in [\d.]+s"#, in: output) {
            found = true
            for (n, kind) in all(#"(\d+) (passed|failed|errors?)"#, in: m[1], group: 0).compactMap({ s -> (Int, String)? in let p = s.split(separator: " "); return p.count == 2 ? (Int(p[0]) ?? 0, String(p[1])) : nil }) {
                if kind == "passed" { passed += n } else { failed += n }
            }
        }
        // jest / vitest: "Tests: 1 failed, 3 passed, 4 total" / "Tests  1 failed | 3 passed (4)"
        if let m = first(#"^\s*Tests:?\s+(.+)$"#, in: output) {
            found = true; passed = 0; failed = 0
            for (n, kind) in all(#"(\d+) (passed|failed)"#, in: m[1], group: 0).compactMap({ s -> (Int, String)? in let p = s.split(separator: " "); return p.count == 2 ? (Int(p[0]) ?? 0, String(p[1])) : nil }) {
                if kind == "passed" { passed += n } else { failed += n }
            }
        }
        // swift test: "Executed 5 tests, with 1 failure"
        if let m = first(#"Executed (\d+) tests?, with (\d+) failures?"#, in: output) {
            found = true; let total = Int(m[1]) ?? 0; failed = Int(m[2]) ?? 0; passed = max(0, total - failed)
        }
        // cargo: "test result: ok. 3 passed; 1 failed;"
        if let m = first(#"test result: \w+\. (\d+) passed; (\d+) failed"#, in: output) { found = true; passed = Int(m[1]) ?? 0; failed = Int(m[2]) ?? 0 }
        // zig: "All 5 tests passed." / "3 passed; 1 skipped; 2 failed." / zig build: "1/4 tests passed (1 skipped, 1 failed, 1 crashed)"
        if let m = first(#"All (\d+) tests passed"#, in: output) { found = true; passed = Int(m[1]) ?? 0; failed = 0 }
        if let m = first(#"(\d+) passed; (?:(\d+) skipped; )?(\d+) failed"#, in: output), !output.contains("test result:") { found = true; passed = Int(m[1]) ?? 0; failed = Int(m[3]) ?? 0 }
        if let m = first(#"^Build Summary: .*?(\d+)/(\d+) tests passed(?: \(([^)]*)\))?"#, in: output) {
            found = true; passed = Int(m[1]) ?? 0
            let skipped = Int(first(#"(\d+) skipped"#, in: m[3])?[1] ?? "") ?? 0
            failed = max(0, (Int(m[2]) ?? 0) - passed - skipped)
        }
        // rspec / minitest / mix: "4 examples, 1 failure" / "4 tests, 1 failure"
        if let m = first(#"(\d+) (?:examples|tests|runs), (\d+) failures?"#, in: output) { found = true; let total = Int(m[1]) ?? 0; failed = Int(m[2]) ?? 0; passed = max(0, total - failed) }
        // go test: per-package ok/FAIL lines and "--- FAIL: TestX"
        let goFails = all(#"^--- FAIL: (\S+)"#, in: output)
        if !goFails.isEmpty || first(#"^ok\s+\S+\s+[\d.]+s"#, in: output) != nil {
            found = true
            let goPass = all(#"^--- PASS: (\S+)"#, in: output).count
            if !goFails.isEmpty || goPass > 0 { failed = goFails.count; passed = goPass }
            else if first(#"^ok\s"#, in: output) != nil && failed == 0 && passed == 0 { passed = max(passed, 1) }
        }
        // ctest: "100% tests passed, 0 tests failed out of 5"
        if let m = first(#"(\d+)% tests passed, (\d+) tests failed out of (\d+)"#, in: output) { found = true; failed = Int(m[2]) ?? 0; passed = max(0, (Int(m[3]) ?? 0) - failed) }
        var failing = all(#"^FAILED (\S+)"#, in: output) + goFails + all(#"^\s*[✕×] (.+)$"#, in: output) + all(#"Test Case '-\[\S+ (\S+)\]' failed"#, in: output)
            + all(#"^test (\S+) \.\.\. FAILED"#, in: output) + all(#"^rspec \S+ # (.+)$"#, in: output) + all(#"^error: '([^']+)' (?:failed|terminated)"#, in: output)
        failing = Array(NSOrderedSet(array: failing)).compactMap { $0 as? String }.prefix(30).map { $0 }
        if !found { return Result(passed: 0, failed: 0, failing: failing, errored: couldNotRun, counted: false) }
        if failing.count > failed { failed = max(failed, failing.count) }
        // A summary that disagrees with the exit code (cargo's first "test result" is the lib's own, often 0/0) isn't trusted.
        if (exit == 0) != (failed == 0) { return Result(passed: 0, failed: 0, failing: failing, errored: couldNotRun, counted: false) }
        return Result(passed: passed, failed: failed, failing: failing, errored: couldNotRun)
    }
}

