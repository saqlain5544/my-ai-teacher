import Foundation

/// What makes the code agent an engineer rather than a chat with tools, done by the app so it happens every time:
/// a file is backed up before the agent's first change to it in a turn (undo under the reply), every file written or
/// edited is syntax-checked at once and the result rides on the tool result, and the turn's changed files are kept with
/// its metrics. For the code mentor's own scaffolding; other lessons are untouched.
@MainActor
final class CodeAgentExtension: AgentExtension {
    let id = "code-agent"
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    /// The checkpoint a lesson's running turn writes into, started by its first change.
    private var turnKeys: [String: String] = [:]
    static let writers: Set<String> = ["write", "edit"]

    private func key(for session: ChatSession) -> String {
        if let k = turnKeys[session.id] { return k }
        let k = String(Int(Date().timeIntervalSince1970 * 1000))
        turnKeys[session.id] = k
        return k
    }

    func currentTurnKey(_ session: ChatSession) -> String? { Self.covers(session) ? key(for: session) : nil }
    /// The code mentor scaffolding a project in the learner's folder.
    static func covers(_ session: ChatSession) -> Bool { session.conversation.mode == .code }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard Self.covers(session), Self.writers.contains(tool.name), let p = call.input?["path"]?.string else { return .allow }
        Checkpoints.backup(session.services.workspace, turn: key(for: session), file: resolvePath(p, workspace: session.services.workspace.url))
        return .allow
    }

    // The syntax check after a write or edit runs inside the tools themselves (`ctx.codeAgent`), so it is awaited, not blocked on.

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        guard let k = turnKeys.removeValue(forKey: session.id) else { return }
        let ws = session.services.workspace
        let changed = Checkpoints.changed(ws, turn: k)
        guard !changed.isEmpty else { try? FileManager.default.removeItem(at: Checkpoints.dir(ws, turn: k)); return }
        metrics.checkpoint = k
        metrics.changedFiles = changed
        Checkpoints.prune(ws)
    }

    func sessionWillClose(_ session: ChatSession) { turnKeys[session.id] = nil; FileViews.shared.forget(agent: session.id) }

    /// The user pressed Undo under a reply: the turn's files go back, and the agent hears about it with the next message.
    func revert(_ session: ChatSession, turn: String) -> String {
        let later = Checkpoints.laterTurns(session.services.workspace, touching: turn)
        if !later.isEmpty { return "A later turn changed the same file\(later.count == 1 ? "" : "s") again: undo that turn first, then this one." }
        let r = Checkpoints.restore(session.services.workspace, turn: turn)
        let n = r.restored.count + r.removed.count
        guard n > 0 || !r.failed.isEmpty else { return "Nothing to undo: that turn's checkpoint is gone." }
        var note = "The user undid the file changes of your previous turn (" + (r.restored.map { "restored \($0)" } + r.removed.map { "removed \($0)" }).joined(separator: ", ") + "). The files are back as they were; don't redo those changes unless they ask."
        if !r.failed.isEmpty { note += " Could not restore: " + r.failed.joined(separator: ", ") + "." }
        if !session.studyNotes.contains(note) { session.studyNotes.append(note) }
        EventBus.publish(.toolFinished(conversationID: session.id, tool: "edit", callID: "revert", ok: true))   // the Changes panel refreshes
        return "Undone: \(n) file\(n == 1 ? "" : "s") put back" + (r.failed.isEmpty ? "." : "; \(r.failed.count) could not be restored.")
    }
}
