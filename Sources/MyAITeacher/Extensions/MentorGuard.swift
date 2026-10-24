import Foundation

/// The code mentor's boundary, enforced by the app rather than asked of the model, while a project is open (its baseline
/// is set and no review has passed yet): the learner's files are theirs and the tests are fixed.
/// - `write` and `edit` of the learner's existing files are refused, and so is `.teacher/` except `.teacher/mentor`
///   (the mentor's notes); `.teacher/tests` opens only after the learner approves `project_tests` unlock. New files are
///   allowed: a second exercise, a scratch example, build output;
/// - a command the mentor runs (bash, run_code, the tests, diagnostics) runs inside a `WriteFence`: the OS refuses its
///   writes to those same files, so nothing has to be put back and nothing the learner saves meanwhile is touched;
/// - only read-only sub-agents may be started (a coder or general agent writes, a tester has a shell).
/// It knows no language: what a file holds is never parsed. Not handing out the solution is the mentor's instruction
/// (and the reviewer's check), not a pattern match. What the guard stops is logged on the project.
@MainActor
final class MentorGuard: AgentExtension {
    let id = "mentor-guard"
    static let commands: Set<String> = ["bash", "run_code", "run_tests", "diagnostics", "project_tests", "project_review"]
    private var fenced: Set<String> = []

    static func guarded(_ session: ChatSession) -> Bool {
        session.conversation.mode == .code && ProjectStore.load(session.services.workspace)?.isOpen == true
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
            guard FileManager.default.fileExists(atPath: url.path) else { return .allow }
            log(ws, "refused", "a \(tool.name) of \(url.lastPathComponent), the learner's file")
            return .deny("\(url.lastPathComponent) is the learner's file while their project is open: you don't change it. Teach toward the change with questions, hints and the concept; show an idea on a separate example (a new file, or run_code).")
        case "task":
            let types = AgentCatalog.all(app: session.settings.agents.definitions, folder: ws.url, instructions: session.settings.instructions)
            let name: String = {
                if let r = call.input?["resume"]?.string, let run = SubAgentCenter.shared.run(r) { return run.typeName }
                return AgentDefinition.normalized(call.input?["type"]?.string ?? call.input?["subagent_type"]?.string ?? "explore")
            }()
            if AgentCatalog.find(name, in: types)?.readOnly == true { return .allow }
            log(ws, "refused", "a `\(name)` sub-agent (it can write)")
            return .deny("While the learner's project is open only read-only sub-agents run (explore, reviewer): a `\(name)` agent could change the learner's files.")
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
            if fenced.count > 32 { fenced.removeAll() }
            if let id = call.id { fenced.insert(id) }
            return .allow
        default:
            return .allow
        }
    }

    func writeFence(_ call: Block, tool: Tool, session: ChatSession) -> String? {
        guard Self.commands.contains(tool.name), Self.guarded(session) else { return nil }
        return Self.fence(session.services.workspace)
    }

    /// The fence for an open project: the learner's files can't be changed, nothing under `.teacher/` but the mentor's
    /// notes (and the tests while unlocked). Anything else — build output, caches, new files — is writable.
    nonisolated static func fence(_ ws: Workspace) -> String {
        let unlocked = ProjectStore.load(ws)?.testsUnlockedAt != nil
        try? FileManager.default.createDirectory(at: ws.mentorDir, withIntermediateDirectories: true)
        return WriteFence.profile(files: ProjectStore.projectFiles(ws).map { ws.url.appendingPathComponent($0) },
                                  locked: [ws.stateDir], open: [ws.mentorDir] + (unlocked ? [ws.testsDir] : []))
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard let id = call.id, fenced.remove(id) != nil, let t = result.text,
              t.range(of: "operation not permitted", options: .caseInsensitive) != nil else { return }
        let ws = session.services.workspace
        result.text = t + "\n[The app's write fence refused a write: the learner's files, the project's tests and its record can't be changed by your commands. Teach toward the change instead; scratch files go in .teacher/mentor/ or a new file.]"
        log(ws, "refused", "a command's write into the project (\(call.name ?? "command"))")
    }

    private func log(_ ws: Workspace, _ kind: String, _ detail: String) {
        ProjectStore.mutate(ws) { $0.log(kind, detail) }
    }
}
