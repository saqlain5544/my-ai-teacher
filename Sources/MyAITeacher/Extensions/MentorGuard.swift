import Foundation

/// The code mentor's boundary, enforced by the app rather than asked of the model: once a project has its baseline
/// (`project_tests` set), the project's files are the learner's and its tests and record are fixed.
/// - `write` and `edit` into the learner's files are refused, and so is `.teacher/` except `.teacher/mentor` (the
///   mentor's notes); `.teacher/tests` opens only after the learner approves `project_tests` unlock;
/// - a command or program the mentor runs (bash, run_code, the tests, diagnostics) runs inside a `WriteFence`: the OS
///   refuses its writes to those files, so nothing has to be put back and nothing the learner saves meanwhile is
///   touched. Where `sandbox-exec` is missing, the files are copied before the call and put back after it instead;
/// - only read-only sub-agents may be started (a coder or general agent writes, a tester has a shell);
/// - code that writes out one of the project's target functions is masked while the reply streams and withheld from
///   the stored reply, its tool-call inputs, tool output (also live) and thinking.
/// Before the baseline the mentor scaffolds freely: starter files and tests. `project_tests` set then checks that the
/// starter doesn't already implement the targets. What the guard stops is logged on the project (no code in it).
/// It is a safety net with known limits (a solution in prose, in an unrecognised language), not a proof.
@MainActor
final class MentorGuard: AgentExtension {
    let id = "mentor-guard"
    static let commands: Set<String> = ["bash", "run_code", "run_tests", "diagnostics", "project_tests", "project_review"]
    /// Per tool call (fallback without a fence): where its files were copied, and their stamps then.
    private var backups: [String: (dir: URL, stamps: [String: String])] = [:]
    private var fenced: Set<String> = []
    /// Live output per call, for the progress filter; calls whose output is hidden.
    private var live: [String: String] = [:]
    private var hidden: Set<String> = []
    private var cache: (folder: String, at: Date, learner: Learner)?

    static func guarded(_ session: ChatSession) -> Bool {
        session.conversation.mode == .code && ProjectStore.load(session.services.workspace)?.snapshotAt != nil
    }

    /// The learner's code as the guard needs it, read at most every two seconds (it runs at each streamed line).
    private func current(_ session: ChatSession) -> Learner? {
        guard Self.guarded(session) else { return nil }
        let ws = session.services.workspace
        if let c = cache, c.folder == ws.url.path, Date().timeIntervalSince(c.at) < 2 { return c.learner }
        let l = Self.learner(ws)
        cache = (ws.url.path, Date(), l)
        return l
    }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard Self.guarded(session) else { return .allow }
        let ws = session.services.workspace
        switch tool.name {
        case "write", "edit":
            guard let p = call.input?["path"]?.string else { return .allow }
            let url = resolvePath(p, workspace: ws.url)
            guard url.isInside(ws.url) else { return .allow }
            if ws.isMentorPath(url) { return .allow }
            if ws.isTestsPath(url) {
                if ProjectStore.load(ws)?.testsUnlockedAt != nil { return .allow }
                log(ws, "refused", "a \(tool.name) of the tests (\(url.lastPathComponent)): they are locked")
                return .deny("The project's tests are locked since its baseline: a review measures the learner against them. To change them (a wrong test, a new stretch goal), call `project_tests` unlock — the learner approves it — then edit, then `project_tests` set to re-baseline.")
            }
            if ws.isStatePath(url) {
                log(ws, "refused", "a \(tool.name) of the project's state (\(url.lastPathComponent))")
                return .deny("`.teacher/` is the app's state for this project (its record and reviews): you don't write there. Your own notes go in `.teacher/mentor/`.")
            }
            log(ws, "refused", "a \(tool.name) of \(url.lastPathComponent), the learner's file")
            return .deny("The project's files are the learner's now (its baseline is set): you don't write or edit \(url.lastPathComponent). Teach with questions, hints and the concept; your notes go in .teacher/mentor/. To show an idea, use a small example in your reply that isn't their solution, or run_code on a separate snippet.")
        case "task":
            let types = AgentCatalog.all(app: session.settings.agents.definitions, folder: ws.url, instructions: session.settings.instructions)
            let name: String = {
                if let r = call.input?["resume"]?.string, let run = SubAgentCenter.shared.run(r) { return run.typeName }
                return AgentDefinition.normalized(call.input?["type"]?.string ?? call.input?["subagent_type"]?.string ?? "explore")
            }()
            if AgentCatalog.find(name, in: types)?.readOnly == true { return .allow }
            log(ws, "refused", "a `\(name)` sub-agent (it can write)")
            return .deny("In a code mentor project only read-only sub-agents run (explore, reviewer): a `\(name)` agent could write the learner's solution.")
        case "project_tests" where call.input?["action"]?.string == "unlock":
            return .ask(ApprovalRequest(
                title: "Let the mentor change the project's tests?",
                detail: "The tests are locked so a review measures your work against the same bar. Unlocking lets the mentor edit .teacher/tests until it re-baselines; the change is recorded on the project.",
                options: [ApprovalOption(id: "unlock", label: "Unlock the tests", style: .primary), ApprovalOption(id: "deny", label: "Keep them locked", style: .danger)])) { [weak self] choice in
                if choice == "unlock" { return .allow }
                self?.log(ws, "refused", "unlocking the tests (the learner kept them locked)")
                return .deny("The learner kept the tests locked.")
            }
        case let n where Self.commands.contains(n):
            pruneBackups()
            if WriteFence.available { if let id = call.id { fenced.insert(id) } }
            else if let id = call.id, let b = Self.backup(ws) { backups[id] = b }
            return .allow
        default:
            return .allow
        }
    }

    func writeFence(_ call: Block, tool: Tool, session: ChatSession) -> String? {
        guard WriteFence.available, Self.commands.contains(tool.name), Self.guarded(session) else { return nil }
        return Self.fence(session.services.workspace)
    }

    /// The fence for a guarded project: the learner's files can't be written, nothing new created outside build and
    /// cache folders, nothing under `.teacher/` but the mentor's notes (and the tests while unlocked).
    nonisolated static func fence(_ ws: Workspace) -> String {
        let unlocked = ProjectStore.load(ws)?.testsUnlockedAt != nil
        try? FileManager.default.createDirectory(at: ws.mentorDir, withIntermediateDirectories: true)
        return WriteFence.profile(root: ws.url, files: ProjectStore.projectFiles(ws).map { ws.url.appendingPathComponent($0) },
                                  locked: [ws.stateDir], open: [ws.mentorDir] + (unlocked ? [ws.testsDir] : []),
                                  buildDirs: ProjectProfile.skip.subtracting([Workspace.stateDirName]))
    }

    func filterProgress(_ callID: String, text: String, session: ChatSession) -> String? {
        if hidden.contains(callID) { return nil }
        guard text.contains("\n"), let learner = current(session), !learner.targets.isEmpty else { return text }
        let buf = String(((live[callID] ?? "") + text).suffix(8000))
        live[callID] = buf
        guard let names = Self.solution(in: buf, learner: learner) else { return text }
        hidden.insert(callID)
        return "\n[Live output hidden: it showed the learner's own \(names.joined(separator: ", ")).]\n"
    }

    func streamMask(_ message: ChatMessage, session: ChatSession) -> ChatMessage? {
        guard let learner = current(session), !learner.targets.isEmpty else { return nil }
        var m = message, changed = false
        for i in m.blocks.indices where m.blocks[i].kind == .text || m.blocks[i].kind == .thinking {
            guard let t = m.blocks[i].text, t.contains("```"), let masked = Self.mask(t, learner: learner) else { continue }
            m.blocks[i].text = masked; changed = true
        }
        return changed ? m : nil
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        let ws = session.services.workspace
        if let id = call.id { live[id] = nil; hidden.remove(id) }
        // What a tool printed is shown to the learner too (a command echoing the file it wrote).
        if Self.guarded(session), let t = result.text, let names = Self.solution(in: t, learner: Self.learner(ws)) {
            result.text = "[Output withheld: it contained the learner's own \(names.joined(separator: ", ")).]"
            log(ws, "withheld", "\(call.name ?? "a tool")'s output (it held \(names.joined(separator: ", ")))")
        }
        if let id = call.id, fenced.remove(id) != nil, let t = result.text, t.range(of: "operation not permitted", options: .caseInsensitive) != nil {
            result.text = t + "\n[The app's write fence refused that: the learner's files, the project's tests and its record can't be written by your commands. Teach toward the change instead; scratch files go in .teacher/mentor/ or a temporary folder.]"
            log(ws, "refused", "a command's write into the project (\(call.name ?? "command"))")
        }
        guard let id = call.id, let b = backups.removeValue(forKey: id) else { return }
        defer { try? FileManager.default.removeItem(at: b.dir) }
        let put = Self.restore(ws, from: b)
        guard !put.isEmpty else { return }
        log(ws, "undone", "a command's changes to " + put.joined(separator: ", "))
        result.text = (result.text ?? "") + "\n[The app undid what this changed in the learner's files (" + put.joined(separator: ", ") +
            "): they are theirs to write. Teach toward the change instead of making it.]"
    }

    func willStoreReply(_ message: inout ChatMessage, session: ChatSession) {
        guard Self.guarded(session) else { return }
        let learner = Self.learner(session.services.workspace)
        guard !learner.targets.isEmpty else { return }
        for i in message.blocks.indices {
            switch message.blocks[i].kind {
            case .toolUse:
                // A tool call's input is drawn on its card (a write's content, a command): the solution can't sit there either.
                // Redacted before it runs, so a command carrying it doesn't run.
                guard let input = message.blocks[i].input, let (clean, names) = Self.redact(input, learner: learner) else { continue }
                message.blocks[i].input = clean
                note(names, session)
                continue
            case .thinking where message.blocks[i].signature != nil:
                // A signed block must go back to the provider as it was written: only its drawing is replaced.
                guard let t = message.blocks[i].text, let names = Self.solution(in: t, learner: learner) else { continue }
                var meta = message.blocks[i].meta?.object ?? [:]
                meta["shown"] = .string("[Thinking withheld: it worked out the learner's own \(names.joined(separator: ", ")).]")
                message.blocks[i].meta = .object(meta)
                note(names, session)
                continue
            case .text, .thinking: break
            default: continue
            }
            guard let t = message.blocks[i].text, let (out, names) = Self.withhold(t, learner: learner) ?? Self.solution(in: t, learner: learner).map({ ("[Withheld: it held the learner's own \($0.joined(separator: ", ")).]", $0) }) else { continue }
            message.blocks[i].text = out
            note(names, session)
        }
    }

    private func note(_ names: [String], _ session: ChatSession) {
        log(session.services.workspace, "withheld", "code for \(names.joined(separator: ", ")) in the mentor's reply")
        let note = "Your last reply wrote out \(names.joined(separator: ", ")), which the learner is to implement: it was withheld. Teach with questions, hints and the concept, never their code."
        if !session.studyNotes.contains(note) { session.studyNotes.append(note) }
    }

    private func log(_ ws: Workspace, _ kind: String, _ detail: String) {
        ProjectStore.mutate(ws) { $0.log(kind, detail) }
    }

    // MARK: Detection

    /// The names of the learner's target functions a piece of code defines with a body of new code (a line of code that
    /// isn't already in their files: their own lines quoted back, in a traceback or an echo of the starter, don't count;
    /// a skeleton that still says TODO may have two).
    nonisolated static func solution(in code: String, learner: Learner) -> [String]? {
        guard !learner.targets.isEmpty else { return nil }
        let defs = definitions(in: code)
        var hit: [String] = []
        let ns = code as NSString
        for (k, d) in defs.enumerated() where learner.targets.contains(d.name) {
            let end = k + 1 < defs.count ? defs[k + 1].at : ns.length
            let body = ns.substring(with: NSRange(location: d.at, length: end - d.at))
            let novel = body.split(separator: "\n").dropFirst().map(codeLine)
                .filter { $0.count >= 4 && looksLikeCode($0) && !learner.lines.contains($0) }
            // A body that still ends in a placeholder is a skeleton (the shape, with the work left as TODO): it gives the
            // answer away only past a few lines. A finished body gives it away in one.
            let skeleton = todo.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil
            if novel.count >= (skeleton ? 3 : 1) { hit.append(d.name) }
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
    /// Code, not a runner's report ("1 failed", "FAILED a.py::t", "=== summary ===") or a comment: an assignment, a call,
    /// a return or a branch.
    nonisolated static func looksLikeCode(_ t: String) -> Bool {
        guard !t.hasPrefix("#"), !t.hasPrefix("//"), !t.hasPrefix("/*"), !t.hasPrefix("*"), !t.contains("===="), !t.contains("::"), todo.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) == nil else { return false }
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

    // MARK: Files (fallback without a fence)

    private func pruneBackups() {
        // A call that a later gate refused never reaches didRun: its copies don't outlive a few more calls.
        while backups.count > 8, let k = backups.keys.first { if let b = backups.removeValue(forKey: k) { try? FileManager.default.removeItem(at: b.dir) } }
        if fenced.count > 32 { fenced.removeAll() }
    }

    /// The files a command must not change: the learner's, and the tests while they are locked.
    nonisolated static func protected(_ ws: Workspace) -> [String] {
        var files = ProjectStore.projectFiles(ws)
        if ProjectStore.load(ws)?.testsUnlockedAt == nil, let e = FileManager.default.enumerator(at: ws.testsDir.resolvingSymlinksInPath(), includingPropertiesForKeys: nil) {
            let root = ws.url.resolvingSymlinksInPath().path
            while let u = e.nextObject() as? URL {
                let r = u.resolvingSymlinksInPath()
                if r.pathComponents.contains("__pycache__") || r.hasDirectoryPath || (try? r.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
                if r.path.hasPrefix(root + "/") { files.append(String(r.path.dropFirst(root.count + 1))) }
            }
        }
        return files
    }

    nonisolated static func backup(_ ws: Workspace) -> (dir: URL, stamps: [String: String])? {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("mentor-guard-\(UUID().uuidString.prefix(8))", isDirectory: true)
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        var stamps: [String: String] = [:]
        for rel in protected(ws) {
            let src = ws.url.appendingPathComponent(rel), dst = dir.appendingPathComponent(rel)
            try? fm.createDirectory(at: dst.deletingLastPathComponent(), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: src, to: dst)) != nil { stamps[rel] = stamp(src) }   // a clone on APFS: no data copied
        }
        return (dir, stamps)
    }

    /// Puts back what changed since `backup` (edited, created or deleted protected files). Returns the paths it fixed.
    nonisolated static func restore(_ ws: Workspace, from b: (dir: URL, stamps: [String: String])) -> [String] {
        let fm = FileManager.default
        var fixed: [String] = []
        let now = Set(protected(ws))
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

    // MARK: Code

    /// A placeholder body: the starter's marker that the learner writes this.
    nonisolated static let todo = try! NSRegularExpression(pattern: #"TODO|FIXME|todo!\(|unimplemented|not implemented|NotImplemented|UnsupportedOperationException|@compileError\("|#error\b|raise NotImplemented"#, options: [.caseInsensitive])
    /// Function and method definitions in the common languages: Python, Go (methods too), Rust, Zig, Swift, Kotlin,
    /// JavaScript and TypeScript (functions, arrows, methods), and C-family definitions (C, C++, Java, C#).
    nonisolated static let definitionPatterns: [NSRegularExpression] = [
        #"(?m)^[ \t]*(?:(?:pub|export|async|static|public|private|protected|internal|override|open|inline|extern|unsafe|final|suspend|default)[ \t]+)*(?:def|func|fn|fun|function\*?)[ \t]+(?:\([^)\n]*\)[ \t]*)?(?:[A-Za-z_][\w]*\.)?([A-Za-z_][\w]*)"#,
        #"(?m)^[ \t]*(?:export[ \t]+)?(?:const|let|var)[ \t]+([A-Za-z_$][\w$]*)[ \t]*=[ \t]*(?:async[ \t]*)?(?:function\b|\([^)\n]*\)[ \t]*(?::[^=\n]+)?=>|[A-Za-z_$][\w$]*[ \t]*=>)"#,
        #"(?m)^[ \t]*(?:[A-Za-z_][\w<>\[\],.:*& \t]*?[ \t*&]+)?([A-Za-z_][\w]*)[ \t]*\([^;{}\n]*\)[ \t]*(?:const[ \t]*)?(?:noexcept[ \t]*)?(?:throws[ \t]+[\w., \t]+)?(?:->[^{\n]+)?(?::[^{=\n]+)?\{[ \t]*$"#,
    ].map { try! NSRegularExpression(pattern: $0) }
    nonisolated static let notNames: Set<String> = ["if", "for", "while", "switch", "catch", "return", "else", "do", "sizeof", "new", "with", "elif", "match", "when", "until", "foreach", "lock", "using", "synchronized", "defer", "guard", "try", "except", "function"]

    /// Every definition in `code`: its name and where it starts, in order.
    nonisolated static func definitions(in code: String) -> [(name: String, at: Int)] {
        let ns = code as NSString, range = NSRange(location: 0, length: ns.length)
        var seen: [Int: String] = [:]
        for re in definitionPatterns {
            for m in re.matches(in: code, range: range) {
                let line = ns.lineRange(for: NSRange(location: m.range.location, length: 0)).location
                let name = ns.substring(with: m.range(at: 1))
                if seen[line] == nil, !notNames.contains(name) { seen[line] = name }
            }
        }
        return seen.sorted { $0.key < $1.key }.map { ($0.value, $0.key) }
    }

    /// The learner's code as the guard needs it: the functions they write (the project's named targets and every
    /// function whose own body is still a placeholder) and every line already in their files.
    struct Learner: Sendable { var targets: Set<String>; var lines: Set<String> }

    nonisolated static func learner(_ ws: Workspace) -> Learner {
        var targets = Set(ProjectStore.load(ws)?.targets ?? []), lines = Set<String>()
        for rel in ProjectStore.projectFiles(ws).prefix(ProjectStore.maxFiles) {
            guard let s = try? String(contentsOf: ws.url.appendingPathComponent(rel), encoding: .utf8), s.count < 1_000_000 else { continue }
            for l in s.split(separator: "\n") { lines.insert(l.trimmingCharacters(in: .whitespaces)) }
            targets.formUnion(stubs(in: s))
        }
        return Learner(targets: targets, lines: lines)
    }

    /// The functions in a file whose own body is a placeholder (TODO, unimplemented, NotImplementedError…).
    nonisolated static func stubs(in s: String) -> Set<String> {
        var out = Set<String>()
        let ns = s as NSString, defs = definitions(in: s)
        for (k, d) in defs.enumerated() {
            guard d.name.count >= 3, !(d.name.hasPrefix("__") && d.name.hasSuffix("__")), !["main", "init", "test", "setup"].contains(d.name) else { continue }
            let end = k + 1 < defs.count ? defs[k + 1].at : ns.length
            let body = ns.substring(with: NSRange(location: d.at, length: end - d.at))
            if todo.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil { out.insert(d.name) }
        }
        return out
    }

    /// The targets the starter already implements (a body of three or more lines of code and no placeholder): a
    /// baseline on them would hand the learner the answer.
    nonisolated static func implemented(_ targets: Set<String>, in ws: Workspace) -> [String] {
        var out: [String] = []
        for rel in ProjectStore.projectFiles(ws) {
            guard let s = try? String(contentsOf: ws.url.appendingPathComponent(rel), encoding: .utf8) else { continue }
            let ns = s as NSString, defs = definitions(in: s)
            for (k, d) in defs.enumerated() where targets.contains(d.name) {
                let end = k + 1 < defs.count ? defs[k + 1].at : ns.length
                let body = ns.substring(with: NSRange(location: d.at, length: end - d.at))
                if todo.firstMatch(in: body, range: NSRange(body.startIndex..., in: body)) != nil { continue }
                let code = body.split(separator: "\n").dropFirst().map(codeLine).filter { $0.count >= 4 && looksLikeCode($0) }
                if code.count >= 3 { out.append("\(d.name) (\(rel))") }
            }
        }
        return out.sorted()
    }

    /// The text with every code block that defines one of the targets replaced by a note, and the names it held; nil
    /// when there was none.
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

    /// For a reply still streaming: `withhold`, and a code block still open at the end that already defines a target
    /// is cut from its opening fence.
    nonisolated static func mask(_ text: String, learner: Learner) -> String? {
        var out = withhold(text, learner: learner)?.0 ?? text
        let parts = out.components(separatedBy: "```")
        if parts.count % 2 == 0, let open = out.range(of: "```", options: .backwards) {
            let tail = String(out[open.upperBound...])
            if solution(in: tail.split(separator: "\n", maxSplits: 1).dropFirst().joined(), learner: learner) != nil {
                out = String(out[..<open.lowerBound]) + "> [!NOTE] Code withheld\n> The mentor started writing the learner's own code."
            }
        }
        return out == text ? nil : out
    }
}
