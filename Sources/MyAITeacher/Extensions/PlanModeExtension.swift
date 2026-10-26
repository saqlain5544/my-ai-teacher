import Foundation

/// Plan mode, as in Claude Code: the code agent researches with read-only tools and presents a plan; nothing in the folder
/// changes until the user approves it. The user turns it on in the composer (⇧⌘P); the agent ends it only through
/// `exit_plan_mode`, which shows the plan with Approve / Keep planning. Registered before the permission gate, so a call
/// plan mode refuses never asks for approval first.
@MainActor
final class PlanModeExtension: AgentExtension {
    let id = "plan-mode"
    /// Whether the last message to the agent said plan mode was on (so turning it off is announced once).
    private var told: [String: Bool] = [:]

    static func isOn(_ session: ChatSession) -> Bool { session.conversation.mode.isAgent && session.conversation.planMode == true }

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        guard session.conversation.mode.isAgent else { return }
        let on = Self.isOn(session), was = told[session.id] ?? false
        told[session.id] = on
        guard on || was else { return }
        message.blocks.insert(Block(kind: .text, text: on ? Self.onNote : Self.offNote, meta: ["hidden": true, "ephemeral": true]), at: 0)
    }

    static let onNote = """
    <context>
    Plan mode is on: the user wants a plan before any change. Research with read-only tools (`read`, `grep`, `glob`, \
    `symbols`, read-only `bash` such as `git log` or `rg`, `explore` sub-agents), then call `exit_plan_mode` with the plan: \
    what you will change, file by file, in what order, how you will verify it, and the risks or open questions. Don't edit \
    files or run commands that change anything; a question you need answered first goes to `ask_learner`.
    </context>
    """
    static let offNote = "<context>\nPlan mode is off: you may change files and run commands again.\n</context>"

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        guard Self.isOn(session) else {
            return tool.name == ExitPlanModeTool.toolName ? .deny("Plan mode is off, so there is nothing to approve: carry on with the work.") : .allow
        }
        if let why = Self.refusal(tool, call.input ?? .object([:])) { return .deny(why) }
        return .allow
    }

    /// Why a call can't run in plan mode, or nil when it only looks.
    nonisolated static func refusal(_ tool: Tool, _ input: JSON) -> String? {
        let present = "Plan mode is on: nothing may change until the user approves your plan. Finish researching, then present the plan with `exit_plan_mode`."
        switch tool.name {
        case ExitPlanModeTool.toolName, "todo_write", "project_memory", "ask_learner": return nil
        case "browser":
            // Reading pages is research; clicking, typing and submitting can change things on a site.
            let reading: Set<String> = ["navigate", "back", "forward", "reload", "snapshot", "screenshot", "text", "find", "tabs", "new_tab",
                                        "switch_tab", "close_tab", "scroll", "wait", "console", "network"]
            return reading.contains(input["action"]?.string ?? "") ? nil : "\(present) In the browser only reading runs now (navigate, snapshot, text, screenshot, scroll…)."
        case "bash":
            let cmd = input["command"]?.string ?? ""
            return input["background"]?.bool != true && ReadOnlyShell.allows(cmd)
                ? nil : "\(present) Only read-only commands run now (`ls`, `rg`, `git status|diff|log|show`…; no `&&`, redirections or `$`)."
        case "task":
            let type = (input["type"]?.string ?? input["subagent_type"]?.string ?? "explore").lowercased()
            if input["resume"]?.string?.isEmpty == false { return "\(present) Resuming a sub-agent waits until the plan is approved." }
            return ["explore", "reviewer"].contains(type) ? nil : "\(present) Only `explore` and `reviewer` sub-agents run in plan mode."
        case "agents":
            // A resumed or steered sub-agent may be a coder from before plan mode.
            return ["resume", "send"].contains(input["action"]?.string ?? "") ? "\(present) Steering or resuming sub-agents waits until the plan is approved." : nil
        default:
            switch tool.risk {
            case .readOnly, .network, .interactive: return nil
            case .write, .execute, .control: return present
            }
        }
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard call.name == ExitPlanModeTool.toolName, result.meta?["planApproved"]?.bool == true else { return }
        told[session.id] = false   // the tool result says plan mode is off
        session.setPlanMode(false)
    }

    func sessionWillClose(_ session: ChatSession) { told[session.id] = nil }
}

/// Ends plan mode: shows the plan to the user, who approves it or asks for more planning.
struct ExitPlanModeTool: Tool {
    static let toolName = "exit_plan_mode"
    let name = toolName
    let description = """
    In plan mode: present your plan for the user's approval (Markdown: the changes file by file, the order, how you'll \
    verify, risks and open questions). Approved, plan mode ends and you carry it out at once; otherwise the user says what \
    to change. Only in plan mode.
    """
    let risk = ToolRisk.interactive
    var schema: JSON { Schema.object(["plan": Schema.string("The plan, in Markdown.")], required: ["plan"]) }
    func summary(_ input: JSON) -> String { "plan for approval" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let plan = try input.req("plan")
        let reply = await ctx.interactions.request(id: ctx.toolCallID, kind: "permission", conversationID: ctx.conversationID, payload: [
            "tool": .string(name), "title": "Approve this plan?",
            "detail": "Approving ends plan mode: the agent then changes files and runs commands as usual.",
            "options": .array([["id": "approve", "label": "Approve and start", "style": "primary"],
                               ["id": "keep", "label": "Keep planning", "style": "normal"]]),
            "plan": .string(plan),
        ])
        if reply["cancelled"]?.bool == true { throw CancellationError() }
        guard reply["decision"]?.string == "approve" else {
            return ToolOutput(text: "The user wants to keep planning; plan mode stays on. Stop here: ask what they'd like changed in the plan, in one short question, and wait for their answer.")
        }
        return ToolOutput(text: "The user approved the plan and plan mode is off. Carry it out now, step by step (keep `todo_write` current), verifying as you go.",
                          meta: ["planApproved": true])
    }
}
