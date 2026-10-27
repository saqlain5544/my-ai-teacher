import Foundation

/// `/goal <objective>` in a code session: a standing objective the agent works toward turn after turn, without the user
/// having to say "continue". Every message to the agent carries the goal; when a turn ends with the goal still open, the
/// session starts the next one by itself (`ChatSession.advanceGoal`). It ends when the agent reports it met with the
/// evidence (`goal` status=met), pauses when the agent is blocked on the user (status=blocked), the user stops a turn,
/// a turn fails, or `SessionGoal.maxTurns` turns have gone by. `/goal` shows it, `/goal resume` carries on, `/goal clear`
/// drops it.
@MainActor
final class GoalExtension: AgentExtension {
    let id = "goal"

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        guard session.conversation.mode.isAgent, let g = session.conversation.goal, g.state == .active else { return }
        message.blocks.insert(Block(kind: .text, text: Self.note(g), meta: ["hidden": true, "ephemeral": true]), at: 0)
    }

    static func note(_ g: SessionGoal) -> String {
        """
        <context>
        The user's goal for this session (turn \(g.turns + 1) of at most \(SessionGoal.maxTurns)): \(g.text)
        Work toward it on your own, a meaningful step per turn, verifying as you go; you'll be sent back to it after each \
        turn until it's done. When it is fully met and verified, call `goal` with status=met and the evidence (what you \
        ran and what it showed). If you can't go on without the user (a decision, access, missing information), call \
        `goal` with status=blocked and what you need. Don't claim it's met without evidence.
        </context>
        """
    }

    static let continueNote = "<context>\nThe goal is not met yet. Carry on with the next step toward it.\n</context>"

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard tool.name == GoalTool.toolName, session.conversation.goal?.state != .active else { return .allow }
        return .deny("No goal is active, so there is nothing to report: answer the user as usual.")
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard call.name == GoalTool.toolName, var g = session.conversation.goal, let status = result.meta?["goalStatus"]?.string else { return }
        g.note = result.meta?["goalNote"]?.string
        g.state = status == "met" ? .met : .paused
        g.turns += 1   // this turn ends the run, so `advanceGoal` won't count it
        session.updateGoal(g, notice: status == "met" ? "Goal met: \(g.text)" : "Goal paused: the agent needs you. /goal resume carries on.")
    }
}

/// The agent's report on the session's goal.
struct GoalTool: Tool {
    static let toolName = "goal"
    let name = toolName
    let description = "Report on the session's goal (the user set it with /goal): status=met with the evidence ends it; status=blocked with what you need from the user pauses it."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object(["status": Schema.string("met or blocked.", enum: ["met", "blocked"]),
                       "evidence": Schema.string("met: what you ran and what it showed. blocked: what you need from the user.")],
                      required: ["status", "evidence"])
    }
    func summary(_ input: JSON) -> String { input["status"]?.string ?? "" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let status = try input.req("status"), evidence = input["evidence"]?.string ?? ""
        guard ["met", "blocked"].contains(status) else { return .error("status is met or blocked.") }
        guard !evidence.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .error(status == "met" ? "Give the evidence it's met: what you ran and what it showed." : "Say what you need from the user.")
        }
        let text = status == "met" ? "Goal marked met. Give the user a short report: what changed, how it was verified, anything left."
                                   : "Goal paused. Ask the user for what you need, in one short message, and stop."
        return ToolOutput(text: text, meta: ["goalStatus": .string(status), "goalNote": .string(evidence)])
    }
}
