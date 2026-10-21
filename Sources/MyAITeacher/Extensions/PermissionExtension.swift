import Foundation

/// Enforces the folder access model:
/// - reading is always allowed, anywhere on the Mac;
/// - writing inside the loaded folder needs `write` (or a one-off approval); outside it is always asked;
/// - running commands/code needs `full` (or approval, optionally remembered for the lesson);
/// - the folder's `.teacher/` state directory is app-managed and never written by tools.
@MainActor
final class PermissionExtension: AgentExtension {
    let id = "permissions"
    unowned let app: AppModel
    init(app: AppModel) { self.app = app }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        let ws = session.services.workspace
        let access = app.access(for: ws)
        let input = call.input ?? .object([:])
        let conv = session.id
        switch tool.risk {
        case .readOnly, .network, .interactive:
            return .allow
        case .write:
            guard let p = input["path"]?.string else { return .allow }
            let url = resolvePath(p, workspace: ws.url)
            let verb = tool.name == "edit" ? "edit" : "write"
            if ws.isStatePath(url) {
                return .deny("`.teacher/` is the app's private state folder. Write somewhere else in the folder.")
            }
            if ws.contains(url) {
                if access >= .write || app.interactions.isGranted("write", conversationID: conv) { return .allow }
                let rel = String(url.path.dropFirst(ws.url.path.count + 1))
                return .ask(ApprovalRequest(
                    title: "Allow Teacher to \(verb) \(rel)?",
                    detail: "“\(ws.name)” is read-only for Teacher.",
                    options: [ApprovalOption(id: "grant_write", label: "Allow writing in this folder", style: .primary),
                              ApprovalOption(id: "once", label: "Allow once"),
                              ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                    switch choice {
                    case "grant_write": self?.app.setAccess(.write, for: ws); return .allow
                    case "once": return .allow
                    default: return .deny("The learner declined.")
                    }
                }
            }
            return .ask(ApprovalRequest(
                title: "Allow Teacher to \(verb) a file outside “\(ws.name)”?",
                detail: url.path,
                options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { choice in
                choice == "once" ? .allow : .deny("The learner declined writing outside the folder.")
            }
        case .execute:
            if access == .full || app.interactions.isGranted(tool.name, conversationID: conv) { return .allow }
            let detail = tool.name == "bash" ? (input["command"]?.string ?? "") : (input["code"]?.string ?? tool.summary(input))
            let what = tool.name == "bash" ? "run this command" : "run this \(input["language"]?.string ?? "") code"
            return .ask(ApprovalRequest(
                title: "Allow Teacher to \(what)?",
                detail: String(detail.prefix(4000)),
                options: [ApprovalOption(id: "once", label: "Allow once", style: .primary),
                          ApprovalOption(id: "lesson", label: "Allow for this lesson"),
                          ApprovalOption(id: "grant_full", label: "Give full access to “\(ws.name)”"),
                          ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
                switch choice {
                case "once": return .allow
                case "lesson": self?.app.interactions.grant(tool.name, conversationID: conv); return .allow
                case "grant_full": self?.app.setAccess(.full, for: ws); return .allow
                default: return .deny("The learner declined.")
                }
            }
        }
    }
}
