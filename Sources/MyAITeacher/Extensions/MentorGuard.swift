import Foundation

/// The code mentor's boundary, enforced by the app rather than asked of the model: once a project has its baseline
/// (`project_tests` set), the project's files are the learner's.
/// - `write` and `edit` into them are refused (the mentor's own space is `.teacher/`, where the tests live);
/// - a command or program the mentor runs (bash, run_code, the tests, diagnostics) that changes them is undone: the
///   files are copied (APFS clones) before the call and put back after it, and the mentor is told;
/// - only read-only sub-agents may be started (a coder or general agent writes, a tester has a shell);
/// - a reply that writes out one of the project's TODO functions is withheld before it is stored.
/// Before the baseline the mentor scaffolds freely: starter files and tests.
@MainActor
final class MentorGuard: AgentExtension {
    let id = "mentor-guard"
    static let commands: Set<String> = ["bash", "run_code", "run_tests", "diagnostics", "project_tests", "project_review"]
    /// Per tool call: where its files were copied, and their stamps then.
    private var backups: [String: (dir: URL, stamps: [String: String])] = [:]

    static func guarded(_ session: ChatSession) -> Bool {
        session.conversation.mode == .code && ProjectStore.load(session.services.workspace)?.snapshotAt != nil
    }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard Self.guarded(session) else { return .allow }
        let ws = session.services.workspace
        switch tool.name {
        case "write", "edit":
            guard let p = call.input?["path"]?.string else { return .allow }
            let url = resolvePath(p, workspace: ws.url)
            guard url.isInside(ws.url), !url.isInside(ws.stateDir) else { return .allow }
            return .deny("The project's files are the learner's now (its baseline is set): you don't write or edit \(url.lastPathComponent). Teach with questions, hints and the concept; tests and your own notes go in .teacher/. To show an idea, use a small example in your reply that isn't their solution, or run_code on a separate snippet.")
        case "task":
            let types = AgentCatalog.all(app: session.settings.agents.definitions, folder: ws.url, instructions: session.settings.instructions)
            let name: String = {
                if let r = call.input?["resume"]?.string, let run = SubAgentCenter.shared.run(r) { return run.typeName }
                return AgentDefinition.normalized(call.input?["type"]?.string ?? call.input?["subagent_type"]?.string ?? "explore")
            }()
            if AgentCatalog.find(name, in: types)?.readOnly == true { return .allow }
            return .deny("In a code mentor project only read-only sub-agents run (explore, reviewer): a `\(name)` agent could write the learner's solution.")
        case let n where Self.commands.contains(n):
            pruneBackups()
            if let id = call.id, let b = Self.backup(ws) { backups[id] = b }
            return .allow
        default:
            return .allow
        }
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        // What a tool printed is shown to the learner too (a command echoing the file it wrote).
        if Self.guarded(session), let t = result.text, let names = Self.solution(in: t, learner: Self.learner(session.services.workspace)) {
            result.text = "[Output withheld: it contained the learner's own \(names.joined(separator: ", ")).]"
        }
        guard let id = call.id, let b = backups.removeValue(forKey: id) else { return }
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let put = Self.restore(session.services.workspace, from: b)
        guard !put.isEmpty else { return }
        result.text = (result.text ?? "") + "\n[The app undid what this changed in the learner's files (" + put.joined(separator: ", ") +
            "): they are theirs to write. Teach toward the change instead of making it.]"
    }

    func willStoreReply(_ message: inout ChatMessage, session: ChatSession) {
        guard Self.guarded(session) else { return }
        let learner = Self.learner(session.services.workspace)
        guard !learner.stubs.isEmpty else { return }
        for i in message.blocks.indices {
            switch message.blocks[i].kind {
            case .toolUse:
                // A tool call's input is drawn on its card (a write's content, a command): the solution can't sit there either.
                // Redacted before it runs, so a command carrying it doesn't run.
                guard let input = message.blocks[i].input, let (clean, names) = Self.redact(input, learner: learner) else { continue }
                message.blocks[i].input = clean
                note(names, session)
                continue
            case .thinking where message.blocks[i].signature == nil:
                break   // shown to the learner; a signed block must stay as the provider wrote it
            case .text: break
            default: continue
            }
            guard let t = message.blocks[i].text, let (out, names) = Self.withhold(t, learner: learner) ?? Self.solution(in: t, learner: learner).map({ ("[Withheld: it held the learner's own \($0.joined(separator: ", ")).]", $0) }) else { continue }
            message.blocks[i].text = out
            note(names, session)
        }
    }

    private func note(_ names: [String], _ session: ChatSession) {
        let note = "Your last reply wrote out \(names.joined(separator: ", ")), which the learner is to implement: it was withheld. Teach with questions, hints and the concept, never their code."
        if !session.studyNotes.contains(note) { session.studyNotes.append(note) }
    }

    /// The names of the learner's TODO functions a piece of code defines, when it is more than a signature (four lines).
    nonisolated static func solution(in code: String, learner: Learner) -> [String]? {
        guard !learner.stubs.isEmpty else { return nil }
        let ns = code as NSString, defs = definition.matches(in: code, range: NSRange(location: 0, length: ns.length))
        var hit: [String] = []
        for (k, m) in defs.enumerated() {
            let name = ns.substring(with: m.range(at: 1))
            guard learner.stubs.contains(name) else { continue }
            // New code in that function's body, not their own lines quoted back (a traceback, an echo of the starter):
            // three substantial lines that aren't in their files.
            let end = k + 1 < defs.count ? defs[k + 1].range.location : ns.length
            let body = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
            let novel = body.split(separator: "\n").dropFirst().map(codeLine)
                .filter { $0.count >= 4 && looksLikeCode($0) && !learner.lines.contains($0) }
            if novel.count >= 3 { hit.append(name) }
        }
        return hit.isEmpty ? nil : Array(Set(hit)).sorted()
    }

    /// A line as code, without a diff's or a test runner's markers (`+`, `-`, `>`, pytest's `E`) or indentation.
    nonisolated static func codeLine<S: StringProtocol>(_ l: S) -> String {
        var t = l.trimmingCharacters(in: .whitespaces)
        if let f = t.first, "+->".contains(f), !t.hasPrefix("->"), !t.hasPrefix("--") { t = String(t.dropFirst()).trimmingCharacters(in: .whitespaces) }
        if t.hasPrefix("E ") { t = String(t.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
        return t
    }
    /// Code, not a runner's report ("1 failed", "FAILED a.py::t", "=== summary ==="): an assignment, a call, a return or
    /// a branch, and no comment.
    nonisolated static func looksLikeCode(_ t: String) -> Bool {
        guard !t.hasPrefix("#"), !t.hasPrefix("//"), !t.contains("===="), !t.contains("::") else { return false }
        return t.contains("=") || t.contains("(") || t.hasPrefix("return") || t.hasPrefix("if ") || t.hasPrefix("for ") || t.hasPrefix("while ") || t.hasSuffix("{")
    }

    /// A tool input with every string that holds a solution replaced by a notice.
    nonisolated static func redact(_ input: JSON, learner: Learner) -> (JSON, [String])? {
        var names: [String] = []
        func walk(_ j: JSON) -> JSON {
            switch j {
            case .string(let s):
                guard let n = solution(in: s, learner: learner) else { return j }
                names += n
                return .string("[withheld: the learner's own \(n.joined(separator: ", "))]")
            case .array(let a): return .array(a.map(walk))
            case .object(let o): return .object(o.mapValues(walk))
            default: return j
            }
        }
        let out = walk(input)
        return names.isEmpty ? nil : (out, Array(Set(names)).sorted())
    }

    // MARK: Files

    private func pruneBackups() {
        // A call that a later gate refused never reaches didRun: its copies don't outlive a few more calls.
        while backups.count > 8, let k = backups.keys.first { if let b = backups.removeValue(forKey: k) { try? FileManager.default.removeItem(at: b.dir) } }
    }

    nonisolated static func backup(_ ws: Workspace) -> (dir: URL, stamps: [String: String])? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mentor-guard-\(UUID().uuidString.prefix(8))", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        var stamps: [String: String] = [:]
        for rel in ProjectStore.projectFiles(ws) {
            let src = ws.url.appendingPathComponent(rel), dst = dir.appendingPathComponent(rel)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil { stamps[rel] = stamp(src) }   // a clone on APFS: no data copied
        }
        return (dir, stamps)
    }

    /// Puts back what changed since `backup` (edited, created or deleted project files). Returns the paths it fixed.
    nonisolated static func restore(_ ws: Workspace, from b: (dir: URL, stamps: [String: String])) -> [String] {
        let fm = FileManager.default
        var fixed: [String] = []
        let now = Set(ProjectStore.projectFiles(ws))
        for (rel, st) in b.stamps {
            let live = ws.url.appendingPathComponent(rel)
            guard !now.contains(rel) || stamp(live) != st else { continue }
            try? fm.removeItem(at: live)
            try? fm.createDirectory(at: live.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: b.dir.appendingPathComponent(rel), to: live)) != nil { fixed.append(rel) }
        }
        for rel in now where b.stamps[rel] == nil {
            if (try? fm.removeItem(at: ws.url.appendingPathComponent(rel))) != nil { fixed.append(rel + " (removed)") }
        }
        return fixed.sorted()
    }

    nonisolated private static func stamp(_ u: URL) -> String {
        let a = (try? FileManager.default.attributesOfItem(atPath: u.path)) ?? [:]
        let d = (try? Data(contentsOf: u)).map { String($0.hashValue) } ?? ""
        return "\((a[.size] as? NSNumber)?.intValue ?? 0)/\(d)"
    }

    // MARK: Replies

    nonisolated static let todo = try! NSRegularExpression(pattern: #"TODO|FIXME|todo!\(|unimplemented!\(|NotImplementedError|fatalError\("TODO|@panic\("TODO|raise NotImplemented"#)
    nonisolated static let definition = try! NSRegularExpression(pattern: #"(?m)^\s*(?:pub\s+)?(?:export\s+)?(?:async\s+)?(?:static\s+)?(?:def|func|fn|function)\s+([A-Za-z_][A-Za-z0-9_]*)"#)

    /// The learner's code as the guard needs it: the functions still to write (their own body says TODO or raises
    /// NotImplementedError) and every line already in their files (code that only repeats those lines — a traceback, an
    /// echo of the starter — isn't a solution).
    struct Learner: Sendable { var stubs: Set<String>; var lines: Set<String> }

    nonisolated static func learner(_ ws: Workspace) -> Learner {
        var stubs = Set<String>(), lines = Set<String>()
        for rel in ProjectStore.projectFiles(ws).prefix(200) {
            guard let s = try? String(contentsOf: ws.url.appendingPathComponent(rel), encoding: .utf8), s.count < 400_000 else { continue }
            for l in s.split(separator: "\n") { lines.insert(l.trimmingCharacters(in: .whitespaces)) }
            let ns = s as NSString, defs = definition.matches(in: s, range: NSRange(location: 0, length: ns.length))
            for (k, m) in defs.enumerated() {
                let name = ns.substring(with: m.range(at: 1))
                guard name.count >= 3, !(name.hasPrefix("__") && name.hasSuffix("__")), !["main", "init", "test", "setup"].contains(name) else { continue }
                let end = k + 1 < defs.count ? defs[k + 1].range.location : ns.length
                let body = ns.substring(with: NSRange(location: m.range.location, length: end - m.range.location))
                if todo.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil { stubs.insert(name) }
            }
        }
        return Learner(stubs: stubs, lines: lines)
    }
    nonisolated static func stubNames(_ ws: Workspace) -> Set<String> { learner(ws).stubs }

    /// The text with every code block that defines one of `stubs` (in four or more lines) replaced by a note, and the names
    /// it held; nil when there was none.
    nonisolated static func withhold(_ text: String, learner: Learner) -> (String, [String])? {
        let fence = try! NSRegularExpression(pattern: #"```[^\n]*\n([\s\S]*?)```"#)
        var out = text, names: [String] = []
        for m in fence.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let whole = Range(m.range, in: text), let body = Range(m.range(at: 1), in: text) else { continue }
            guard let hit = solution(in: String(text[body]), learner: learner) else { continue }
            names += hit
            let r = Range(NSRange(whole, in: text), in: out)!
            out.replaceSubrange(r, with: "> [!NOTE] Code withheld\n> This was the learner's own `\(hit.joined(separator: "`, `"))`: they write it. Ask for a hint instead.")
        }
        return names.isEmpty ? nil : (out, Array(Set(names)).sorted())
    }
}
