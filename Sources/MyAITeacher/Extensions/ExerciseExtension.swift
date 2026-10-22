import Foundation

/// The learner writes their exercise's code; the teacher never does, and never shows the solution.
/// - Writes into an exercise's folder (write, edit, or a shell command that writes there) are refused.
/// - A code block in a reply that repeats the hidden reference solution is withheld before the reply is stored.
@MainActor
final class ExerciseExtension: AgentExtension {
    let id = "exercises"
    private var cache: [String: (at: Date, exercises: [Exercise])] = [:]
    private var signatures: [String: Set<String>] = [:]
    /// run_code calls since the lesson's last `exercise` call (a mentor building the project there first, before any draft).
    private var runsSinceExercise: [String: Int] = [:]

    func exercises(_ lesson: String) -> [Exercise] {
        if let c = cache[lesson], Date().timeIntervalSince(c.at) < 30 { return c.exercises }
        let list = ExerciseStore.list(conversationID: lesson)
        cache[lesson] = (Date(), list)
        return list
    }

    static let refusal = """
        Refused: the learner writes this project's code, not you. Read their files with `exercise` (action read), run the \
        hidden tests on their work with `exercise` (action check), and teach with questions and targeted hints.
        """

    static let buildInDraft = """
        Not now: you've run code twenty times without setting the project. Write it straight into an exercise draft \
        (action draft, then add the starter, tests and solution, then publish): publish runs your tests on your solution and on \
        the starter, and shows you any failure to fix. Building and checking it here first doubles the learner's wait.
        """

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard !session.conversation.mode.isAgent else { return .allow }
        // A code mentor sets projects through `exercise`; prototyping one in run_code first keeps the learner waiting.
        if session.conversation.mode == .code, tool.name == "run_code", exercises(session.id).isEmpty {
            let n = runsSinceExercise[session.id, default: 0]
            if n >= 20 { return .deny(Self.buildInDraft) }
            runsSinceExercise[session.id] = n + 1
        }
        let folders = exercises(session.id).map { $0.dir.standardizedFileURL.path }
        guard !folders.isEmpty else { return .allow }
        let input = call.input ?? .object([:])
        switch tool.name {
        case "write", "edit":
            guard let p = input["path"]?.string else { return .allow }
            let url = p.hasPrefix("/") || p.hasPrefix("~") ? URL(fileURLWithPath: (p as NSString).expandingTildeInPath)
                : session.services.workspace.url.appendingPathComponent(p)
            let path = url.standardizedFileURL.path
            return folders.contains { path == $0 || path.hasPrefix($0 + "/") } ? .deny(Self.refusal) : .allow
        case "bash":
            return Self.writesInto(input["command"]?.string ?? "", folders: folders) ? .deny(Self.refusal) : .allow
        default:
            return .allow
        }
    }

    /// A shell command that names an exercise folder and changes files (redirects, editors in place, copies, removals…).
    nonisolated static func writesInto(_ command: String, folders: [String]) -> Bool {
        let names = folders.flatMap { [$0, "exercises/" + ($0 as NSString).lastPathComponent] }
        guard names.contains(where: { command.contains($0) }) || command.contains("exercises/") else { return false }
        let writes = [">", "tee ", "sed -i", "perl -i", "cp ", "mv ", "rm ", "touch ", "mkdir ", "patch ", "git apply", "git checkout",
                      "git restore", "open(", ".write", "truncate", "dd ", "install ", "rsync ", "ln "]
        return writes.contains { command.contains($0) }
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        if call.name == "exercise" { cache[session.id] = nil; runsSinceExercise[session.id] = 0 }
    }

    func willStoreReply(_ message: inout ChatMessage, session: ChatSession) {
        let list = exercises(session.id)
        guard !list.isEmpty else { return }
        let solution = list.reduce(into: Set<String>()) { $0.formUnion(signature($1.id)) }
        guard !solution.isEmpty else { return }
        for i in message.blocks.indices where message.blocks[i].kind == .text {
            if let t = message.blocks[i].text, let redacted = Self.withhold(t, solution: solution) { message.blocks[i].text = redacted }
        }
    }

    private func signature(_ id: String) -> Set<String> {
        if let s = signatures[id] { return s }
        let s = ExerciseStore.secretLines(id)
        signatures[id] = s
        return s
    }

    /// The text with every fenced code block that repeats the solution replaced; nil when nothing leaked.
    nonisolated static func withhold(_ text: String, solution: Set<String>) -> String? {
        guard text.contains("```"), let re = try? NSRegularExpression(pattern: "```([^\\n`]*)\\n([\\s\\S]*?)```") else { return nil }
        var out = text, changed = false
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let body = Range(m.range(at: 2), in: text), let whole = Range(m.range, in: out),
                  ExerciseStore.leaks(String(text[body]), solution: solution) else { continue }
            out.replaceSubrange(whole, with: "```text\n(Code withheld: it repeats the exercise's solution. You write this one.)\n```")
            changed = true
        }
        return changed ? out : nil
    }
}
