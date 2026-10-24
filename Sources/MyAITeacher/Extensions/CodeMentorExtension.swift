import Foundation

/// Keeps the code mentor's project in view: a `<project_state>` line on every request (tests, what changed since the
/// last review, open findings), and a nudge to prove the tests once they are written. Code mentor mode only.
@MainActor
final class CodeMentorExtension: AgentExtension {
    let id = "code-mentor"

    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        guard session.conversation.mode == .code else { return }
        let ws = session.services.workspace
        guard let p = ProjectStore.load(ws) else { return }
        Self.inject(Self.stateLine(p, changed: ProjectStore.changedCount(ws)), into: &request)
    }

    nonisolated static func inject(_ line: String, into request: inout LLMRequest) {
        guard let i = request.messages.indices.last, request.messages[i].role == .user else { return }
        request.messages[i].blocks.removeAll { $0.meta?["projectState"]?.bool == true }
        request.messages[i].blocks.append(Block(kind: .text, text: line, meta: ["projectState": true]))
    }

    nonisolated static func stateLine(_ p: MentorProject, changed: Int?) -> String {
        var parts = ["Project: \(p.title ?? "(untitled)")" + (p.concept.map { " (\($0))" } ?? "")]
        if let c = p.testCommand {
            parts.append("tests `\(c)`" + (p.lastRun.map { r in ": \(r.line) (\(ProjectTestsTool.ago(r.at)))" } ?? ": never run"))
        } else { parts.append("tests: no command set — `project_tests` set once the tests are written") }
        if let n = changed { parts.append(n == 0 ? "nothing changed since the \(p.snapshotWhy ?? "baseline")" : "\(n) file\(n == 1 ? "" : "s") changed since the \(p.snapshotWhy ?? "baseline") — review with `project_review` start when they ask") }
        let open = p.openFindings
        if let r = p.rounds.last { parts.append("review round \(r.number): \(r.verdict), \(open.count) open finding\(open.count == 1 ? "" : "s")") }
        if p.testsUnlockedAt != nil { parts.append("tests unlocked by the learner: edit them, then `project_tests` set to re-baseline") }
        if p.helpSinceReview != .none { parts.append("help since the last review: \(p.helpSinceReview == .solution ? "a solution" : "hints")") }
        if let e = p.explainBack, e.verdict == nil { parts.append("explain-back open: ask them to explain one design choice, trade-off or failure mode of their code, then `project_review` explain") }
        return "<project_state>" + parts.joined(separator: " · ") + "</project_state>"
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard session.conversation.mode == .code, result.isError != true, ["write", "edit"].contains(call.name ?? ""),
              let p = call.input?["path"]?.string else { return }
        let ws = session.services.workspace
        let url = resolvePath(p, workspace: ws.url)
        guard ws.isTestsPath(url), ProjectStore.load(ws)?.testCommand == nil else { return }
        result.text = (result.text ?? "") + "\nWhen the starter and the tests are both in place, register the test command with `project_tests` set: it proves the tests fail on the starter and sets the review baseline."
    }
}
