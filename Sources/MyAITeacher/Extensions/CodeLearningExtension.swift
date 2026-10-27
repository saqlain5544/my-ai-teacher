import Foundation

/// How the code agent learns from its work and keeps a project from regressing:
///
/// * While a turn runs it notes each check (diagnostics, tests, a build or test command): what failed, what passed, and
///   the edits between. A check that failed and then passed after the agent's edits is a fixed failure.
/// * Before such a turn ends, the agent is asked once whether the cause is a mistake that could recur in other projects;
///   if so it records the rule with `lessons` (global, `CodeLessons`). Only verified fixes prompt this, so lessons rest on
///   evidence rather than guesses.
/// * After a turn that changed files, the project's history gets a record (`ProjectHistory`): the request, the files,
///   the checks and how they ended, the fix, commits and the pull request, the lessons drawn.
/// * When the agent edits a file an earlier fix touched, the edit's result says so and names the check that verified
///   it, so a later change runs it again instead of quietly undoing the fix.
@MainActor
final class CodeLearningExtension: AgentExtension {
    let id = "code-learning"

    struct Check { var key: String; var ok: Bool; var detail: String; var afterEdits: Int }
    private struct Turn {
        var checks: [Check] = []
        var edits = 0
        var commits: [String] = []
        var pr: String?
        var lessons: [String] = []
        var asked = false
        var warned: Set<String> = []
    }
    private var turns: [String: Turn] = [:]

    /// Test and build runners (the program, not a path that happens to say "tests").
    static let checkCommand = try! NSRegularExpression(pattern: #"(?:^|[\s;&|(])((?:python3?\s+-m\s+)?(?:pytest|unittest)\b|jest\b|vitest\b|mocha\b|rspec\b|cargo\s+(?:test|build|check|clippy)\b|go\s+(?:test|build|vet)\b|zig\s+build\b|swift\s+(?:build|test)\b|xcodebuild\b|(?:npm|pnpm|yarn|bun)\s+(?:run\s+)?(?:test|build|lint|typecheck|check)\b|make\b|tsc\b|mypy\b|ruff\s+check\b|eslint\b|gradle\w*\s|mvn\s|dotnet\s+(?:build|test)\b|deno\s+test\b|mix\s+test\b|ctest\b|node\s+--test\b)"#, options: [.caseInsensitive])

    /// The check a command runs: the stretch of it with the runner, without pipes or redirections
    /// (`cd x && python3 -m unittest -q 2>&1 | tail -40` → `python3 -m unittest -q`), or nil when it runs none.
    static func checkKey(_ raw: String) -> String? {
        // Redirections out first (`2>&1` holds an `&` the segments split at).
        let command = raw.replacingOccurrences(of: #"\s*\d?>&\d"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"\s*\d?>>?\s*[^\s;&|]+"#, with: "", options: .regularExpression)
        guard let m = checkCommand.firstMatch(in: command, range: NSRange(command.startIndex..., in: command)),
              let r = Range(m.range(at: 1), in: command) else { return nil }
        let before = command[..<r.lowerBound], after = command[r.lowerBound...]
        let start = before.lastIndex(where: { ";&|(\n".contains($0) }).map { command.index(after: $0) } ?? command.startIndex
        let end = after.firstIndex(where: { ";&|)\n".contains($0) }) ?? command.endIndex
        let seg = String(command[start..<end])
        let key = seg.trimmingCharacters(in: .whitespaces)
        return key.isEmpty ? nil : String(key.prefix(120))
    }

    /// Whether a run's output says it failed, whatever its exit code (piped through `tail`, a runner's exit is lost).
    static func saysFailed(_ text: String) -> Bool {
        text.range(of: #"(?m)(\bFAILED\b|^FAIL[: ]|\bfailures=\d|\b[1-9]\d* (failed|failing|errors?)\b|Traceback \(most recent call last\)|^error(\[\w+\])?:|\berror: |panicked at|\bnot ok \d|Build FAILED|BUILD FAILURE|✗|✘)"#,
                   options: .regularExpression) != nil
    }

    private static func covers(_ s: ChatSession) -> Bool { s.conversation.mode.isAgent }

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        guard Self.covers(session) else { return }
        turns[session.id] = Turn(warned: turns[session.id]?.warned ?? [])   // a new request starts a new turn's record
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard Self.covers(session), let name = call.name else { return }
        var t = turns[session.id] ?? Turn()
        let input = call.input ?? .object([:])
        let ok = result.isError != true && (result.meta?["exit"]?.int ?? 0) == 0
        switch name {
        case "edit", "write":
            if ok {
                t.edits += 1
                if let p = input["path"]?.string { warnIfFixedBefore(p, session: session, result: &result, turn: &t) }
            }
        case "diagnostics", "run_tests":
            let key = name + " " + (input["command"]?.string ?? input["what"]?.string ?? "")
            let passed = ok && !Self.saysFailed(result.text ?? "") && (result.meta?["failed"]?.int ?? 0) == 0
            t.checks.append(Check(key: key.trimmingCharacters(in: .whitespaces), ok: passed, detail: Self.failure(result.text ?? ""), afterEdits: t.edits))
        case "bash":
            let cmd = input["command"]?.string ?? ""
            if input["background"]?.bool != true, let key = Self.checkKey(cmd) {
                let passed = ok && !Self.saysFailed(result.text ?? "")
                t.checks.append(Check(key: key, ok: passed, detail: Self.failure(result.text ?? ""), afterEdits: t.edits))
            }
            if let url = Self.prURL(result.text ?? ""), cmd.contains("gh pr create") { t.pr = url }
        case "lessons":
            if let id = result.meta?["lesson"]?.string { t.lessons.append(id) }
        default: break
        }
        turns[session.id] = t
    }

    /// A commit's hash, read after `git commit` succeeds (the result doesn't always show it).
    func afterRun(_ call: Block, result: inout Block, session: ChatSession) async {
        guard Self.covers(session), call.name == "bash", result.isError != true,
              let cmd = call.input?["command"]?.string, cmd.range(of: #"\bgit\s+(-c\s+\S+\s+)*commit\b"#, options: .regularExpression) != nil,
              let git = ProcessRunner.which("git") else { return }
        let r = await ProcessRunner.run(git, ["-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "rev-parse", "--short", "HEAD"], cwd: session.services.workspace.url, timeout: 10)
        let h = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        if r.exitCode == 0, !h.isEmpty, h.count <= 40 { turns[session.id, default: Turn()].commits.append(h) }
    }

    /// A failure fixed during the turn: the first check that failed and later passed after an edit.
    func fixedFailure(_ session: ChatSession) -> Check? {
        guard let t = turns[session.id] else { return nil }
        for (i, c) in t.checks.enumerated() where !c.ok {
            if t.checks[(i + 1)...].contains(where: { $0.ok && $0.afterEdits > c.afterEdits && Self.sameCheck($0.key, c.key) }) { return c }
        }
        return nil
    }

    func willEndTurn(_ session: ChatSession, continued: Int) async -> String? {
        guard Self.covers(session), var t = turns[session.id], !t.asked, t.lessons.isEmpty, let fix = fixedFailure(session) else { return nil }
        t.asked = true; turns[session.id] = t
        return """
        You fixed a failure this turn: `\(fix.key)` failed (\(fix.detail.isEmpty ? "see above" : fix.detail)) and passed after your edits. \
        If its cause is a mistake that could recur in other projects (a language pitfall, an API misuse, a habit), record it with \
        `lessons` action=add (language, mistake, rule, evidence), or confirm the lesson it repeats. If it was specific to this \
        project, don't. Then finish your reply as you were going to.
        """
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        guard Self.covers(session), let t = turns[session.id] else { return }
        let files = metrics.changedFiles ?? []
        guard !files.isEmpty || !t.commits.isEmpty || t.pr != nil else { return }
        let request = Self.request(session.messages)
        let reply = session.messages.last { $0.role == .assistant }?.plainText ?? ""
        var last: [String: Bool] = [:], order: [String] = []
        for c in t.checks { if last[c.key] == nil { order.append(c.key) }; last[c.key] = c.ok }
        let root = session.services.workspace.url.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        let rel = files.map { $0.hasPrefix(root) ? String($0.dropFirst(root.count)) : $0 }
        ProjectHistory.append(ChangeRecord(t: Date(), request: String(request.prefix(200)), summary: String(reply.split(separator: "\n").first?.prefix(200) ?? ""),
                                           files: rel, checks: order.map { "\($0): \(last[$0]! ? "passed" : "failed")" },
                                           fixed: fixedFailure(session) != nil, commits: t.commits, pr: t.pr, lessons: t.lessons),
                              folder: session.services.workspace.url)
        ActivityLog.record("history", conv: session.id, ["files": .number(Double(rel.count)), "fixed": .bool(fixedFailure(session) != nil),
                                                         "commits": .array(t.commits.map { .string($0) }), "lessons": .array(t.lessons.map { .string($0) })])
    }

    func sessionWillClose(_ session: ChatSession) { turns[session.id] = nil }

    /// An edit to a file an earlier fix touched: the result names that fix and the check that verified it (once per file
    /// per lesson session).
    private func warnIfFixedBefore(_ path: String, session: ChatSession, result: inout Block, turn: inout Turn) {
        let rel = CodeTool.relative(path, root: session.services.workspace.url)
        guard !turn.warned.contains(rel), let fix = ProjectHistory.touching(rel, folder: session.services.workspace.url).first(where: \.fixed) else { return }
        turn.warned.insert(rel)
        let checks = fix.checks.filter { $0.hasSuffix(": passed") }.map { "`\($0.dropLast(": passed".count))`" }
        result.text = (result.text ?? "") + "\n[History: this file was part of a fix on \(fix.t.formatted(.iso8601.year().month().day())) (“\(fix.request.prefix(80))”)"
            + (checks.isEmpty ? "" : ", verified by \(checks.prefix(2).joined(separator: ", "))") + ". If your change touches that behaviour, run that check again before you finish.]"
    }

    /// The person's latest request, first line: the app's hidden notes (a goal nudge, the lesson question) are user
    /// messages too, and don't count.
    nonisolated static func request(_ messages: [ChatMessage]) -> String {
        let visible = { (m: ChatMessage) in m.blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text)
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) }
        return messages.last { $0.role == .user && !$0.isToolResultOnly && !visible($0).isEmpty }
            .map(visible)?.split(separator: "\n").first.map(String.init) ?? ""
    }

    /// The first lines of a failure that say what failed (error lines first).
    static func failure(_ text: String) -> String {
        let lines = text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        let errs = lines.filter { $0.range(of: #"(?i)\b(error|failed|failure|panic|exception|assert)"#, options: .regularExpression) != nil }
        return String((errs.isEmpty ? Array(lines.prefix(2)) : Array(errs.prefix(2))).joined(separator: " · ").prefix(240))
    }
    static func prURL(_ text: String) -> String? {
        text.range(of: #"https://github\.com/[\w.-]+/[\w.-]+/pull/\d+"#, options: .regularExpression).map { String(text[$0]) }
    }
    /// The same check run again (a test command with other flags or a narrower filter counts).
    static func sameCheck(_ a: String, _ b: String) -> Bool {
        if a == b { return true }
        let wa = Set(a.split(separator: " ").prefix(3)), wb = Set(b.split(separator: " ").prefix(3))
        return !wa.isEmpty && wa == wb
    }
}
