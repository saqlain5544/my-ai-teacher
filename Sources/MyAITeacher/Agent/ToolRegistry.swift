import Foundation

enum ToolRegistry {
    /// Always sent to the model: the tools that carry most lessons (measured from recorded tool usage).
    static let core: [Tool] = [
        AskLearnerTool(), MathTool(), RunCodeTool(), ReadTool(), WriteTool(), EditTool(), LsTool(), BashTool(),
        WebSearchTool(), WebFetchTool(), MemoryTool(), LoadToolsTool(),
    ]
    /// Loaded on demand via `load_tools` (listed by one line in the system prompt) to keep every request lean.
    static let deferred: [Tool] = [
        GlobTool(), GrepTool(), TodoWriteTool(), TaskTool(), AgentsTool(), FlashcardsTool(), MasteryTool(), LessonPlanTool(),
    ]
    static let all: [Tool] = core + deferred + [VisualTool(), QuizTool(), ProjectMemoryTool()]

    /// Code agent: the whole coding toolset up front (no load step), project memory instead of the learner's.
    static let agentTools: [Tool] = [
        ReadTool(), WriteTool(), EditTool(), LsTool(), GlobTool(), GrepTool(), BashTool(), RunCodeTool(), TodoWriteTool(),
        TaskTool(), AgentsTool(), WebSearchTool(), WebFetchTool(), ProjectMemoryTool(), AskLearnerTool(),
    ]

    /// Core and deferred sets for a lesson, after its experiment arms (stable for the lesson's lifetime).
    static func layout(_ lessonID: String?) -> (core: [Tool], deferred: [Tool]) {
        let visualInCore = Experiments.arm(Experiments.visualTool, unit: lessonID ?? "") == "core"
        return visualInCore ? (core.dropLast() + [VisualTool(), LoadToolsTool()], deferred) : (core, deferred + [VisualTool()])
    }
    static let byName: [String: Tool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static func enabled(_ settings: AppSettings) -> [Tool] {
        all.filter { !settings.disabledTools.contains($0.name) }
    }

    /// Tools for a request: core + whatever this lesson has loaded (in load order, so the prefix only ever grows).
    static func active(_ settings: AppSettings, loaded: [String], lessonID: String? = nil, mode: TeachingMode = .tutor) -> [Tool] {
        var off = Set(settings.disabledTools)
        if mode.isAgent { return agentTools.filter { !off.contains($0.name) } }
        if settings.python == .off { off.insert("math") }   // SymPy needs Python
        let l = layout(lessonID)
        let extra = loaded.compactMap { name in l.deferred.first { $0.name == name } }
        return (l.core + extra).filter { !off.contains($0.name) }
    }

    /// One line per deferred tool for the system prompt.
    static func deferredIndex(_ lessonID: String? = nil) -> String {
        layout(lessonID).deferred.map { "- `\($0.name)`: \($0.description.components(separatedBy: ". ").first ?? "")" }.joined(separator: "\n")
    }

    /// Tools a research sub-agent may use without supervision.
    /// Every tool a sub-agent can be given; its type and the `task` call choose from these. Never the interactive or
    /// teaching tools (sub-agents can't wait for the learner), and memory is search-only.
    static let subagentPool: [Tool] = [ReadTool(), LsTool(), GlobTool(), GrepTool(), WebSearchTool(), WebFetchTool(), MathTool(), MemoryTool(readOnly: true),
                                       WriteTool(), EditTool(), BashTool(), RunCodeTool(), TaskTool(), AgentsTool()]
}

/// Delegates a self-contained task to a sub-agent with its own context; only its final report returns.
struct TaskTool: Tool {
    let name = "task"
    let description = """
    Launch a sub-agent with its own context and tools; only its report comes back. `type` (default explore): explore — \
    read-only research (web, files, math); general — research plus files and commands; coder — implements and verifies a \
    code change; reviewer — read-only review (read-only shell commands); tester — runs builds and tests, doesn't edit. \
    Blocking by default; `background: true` returns at once and the report arrives later as a <background-agent> message \
    (steer it meanwhile with `agents` send). Per call: `model` (and `provider`), `effort` (off/low/medium/high), a budget \
    (`max_steps`, `max_seconds`, `max_tokens`), `tools`/`deny_tools` to narrow the type's tools, and `output_schema` (a \
    JSON Schema the report must match; checked, one repair turn). Sub-agents never get more access than this lesson has. \
    `resume` with a handle (A1…) continues one with a follow-up. Give a complete, specific brief.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "description": Schema.string("3-6 word label."),
            "prompt": Schema.string("Full brief: what to do, what to return, and how detailed (or the follow-up, with resume)."),
            "type": Schema.string("Agent type (default explore)."),
            "background": Schema.boolean("Run without waiting; the report arrives as a message when done."),
            "resume": Schema.string("Handle of a finished sub-agent (A1…) to continue with this prompt."),
            "provider": Schema.string("Provider for this sub-agent (default: the lesson's)."),
            "model": Schema.string("Model for this sub-agent (default: the type's, else the lesson's)."),
            "effort": Schema.string("Reasoning effort (default from Settings → Agents, usually off).", enum: ThinkingLevel.allCases.map(\.rawValue)),
            "max_steps": Schema.integer("Model calls before it must report."),
            "max_seconds": Schema.integer("Seconds before it must report."),
            "max_tokens": Schema.integer("Tokens (input + output, all steps) before it must report."),
            "unbounded": Schema.boolean("No budget at all (only when Settings allows it; runs in the background, stoppable)."),
            "tools": Schema.array(Schema.string("Tool name"), "Only these of the type's tools."),
            "deny_tools": Schema.array(Schema.string("Tool name"), "Not these tools."),
            "output_schema": ["type": "object", "description": "JSON Schema the final report must match; you get the JSON back."],
            "isolation": Schema.string("worktree: a coder works on a git worktree of the folder (code agent, git repo); its changes stay there.", enum: ["none", "worktree"]),
        ], required: ["description", "prompt"])
    }
    func summary(_ input: JSON) -> String { input["description"]?.string ?? "sub-agent" }
    /// The budget's own clock ends a run (then the report step); this backstop is the asked-for (or default) time plus the report.
    func timeout(_ input: JSON) -> Double? {
        if input["background"]?.bool == true || input["unbounded"]?.bool == true { return 30 }
        let limits = SubAgent.lastLimits.get()
        return Double(min(input["max_seconds"]?.int ?? limits.seconds, limits.maxSeconds)) + 180
    }

    /// The spec a lesson sends: the provider's choosable models under `model` (fetched, never hard-coded), other
    /// providers under `provider`, every agent type under `type`, and the limits from Settings → Agents.
    static func spec(models: [String], current: String, provider: String = "", others: [String] = [], types: [AgentDefinition] = AgentCatalog.builtIns,
                     limits: SubAgentSettings = SubAgentSettings(), codeMode: Bool = false) -> ToolSpec {
        let t = TaskTool()
        guard var obj = t.schema.object, var props = obj["properties"]?.object else { return t.spec }
        let custom = types.filter { $0.source != .builtIn }
        props["type"] = Schema.string("Agent type (default explore)." + (custom.isEmpty ? "" : " Also: " + custom.map { "\($0.name) — \($0.description)" }.joined(separator: "; ") + "."),
                                      enum: types.map(\.name))
        if models.count > 1 || !others.isEmpty {
            props["model"] = Schema.string("Optional model for this sub-agent: a smaller, faster one for simple look-ups, a stronger one for hard " +
                                           "analysis. Omit to use the lesson's model (\(current))." + (models.count > 1 ? " One of: " + models.prefix(30).joined(separator: ", ") +
                                           (models.count > 30 ? " (and \(models.count - 30) more from this provider)" : "") : "") +
                                           (others.isEmpty ? "" : " With `provider`, one of that provider's models (a wrong id is refused with its list)."))
        } else { props["model"] = nil }
        if others.isEmpty { props["provider"] = nil }
        else { props["provider"] = Schema.string("Optional provider for this sub-agent (default: this lesson's\(provider.isEmpty ? "" : ", \(provider)")): " + others.joined(separator: ", ") + ".") }
        if !limits.allowUnbounded { props["unbounded"] = nil }
        if !codeMode { props["isolation"] = nil }
        obj["properties"] = .object(props)
        return ToolSpec(name: t.name, description: t.description + " " + limits.limitsLine, schema: .object(obj))
    }

    /// Models also put the brief under other names (MiniMax-M3 sent {"agent_id": "researcher", "action": "Find three…"}).
    static let briefKeys = ["prompt", "task", "action", "instructions", "brief", "query", "goal", "request", "message"]

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let prompt = Self.briefKeys.lazy.compactMap({ input[$0]?.string }).first(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        else { throw ToolError("Missing required parameter `prompt`.") }
        let word = { (k: String) in input[k]?.string?.trimmingCharacters(in: .whitespaces).nonEmpty }
        let names = { (k: String) -> [String]? in
            input[k]?.array?.compactMap(\.string) ?? word(k)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        var q = TaskRequest(brief: prompt, title: input["description"]?.string ?? input["title"]?.string ?? input["role"]?.string ?? "Sub-agent")
        q.type = word("type") ?? word("subagent_type") ?? word("agent_type")   // Claude Code's name for it
        q.provider = word("provider")
        q.model = word("model")
        q.effort = word("effort").flatMap { e in ThinkingLevel(rawValue: e.lowercased()) ?? ["none": .off, "minimal": .low, "xhigh": .high, "max": .high][e.lowercased()] }
        q.budget = AgentBudget(steps: input["max_steps"]?.int, seconds: input["max_seconds"]?.int, tokens: input["max_tokens"]?.int,
                               unbounded: input["unbounded"]?.bool == true)
        q.tools = names("tools")
        q.deny = names("deny_tools") ?? []
        q.schema = input["output_schema"].flatMap { $0.string.flatMap(JSON.parse) ?? $0 }
        q.isolation = word("isolation")?.lowercased() == "worktree"
        q.background = input["background"]?.bool == true
        q.resume = word("resume")
        return await SubAgent.run(q, ctx: ctx)
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
}


/// Manage this lesson's sub-agents: list them with their usage, check one, steer one, wait for one, stop or resume one.
struct AgentsTool: Tool {
    let name = "agents"
    let description = """
    Manage this lesson's sub-agents (from `task`): list (type, model, effort, budget use, tokens, time, cost), status, send \
    (a note a running agent reads before its next step — to steer it), wait (for a background one, up to 120 s; you then \
    have its report), stop, resume (a finished one, with `message` as the follow-up).
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": ["type": "string", "enum": ["list", "status", "send", "wait", "stop", "resume"]],
            "id": Schema.string("Agent handle (A1…), for everything but list."),
            "message": Schema.string("send: the note; resume: the follow-up brief."),
            "seconds": Schema.integer("wait: how long to wait at most (default 60, max 120)."),
            "background": Schema.boolean("resume: don't wait for it."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "") + (input["id"]?.string.map { " " + $0 } ?? "") }
    func timeout(_ input: JSON) -> Double? {
        input["action"]?.string == "resume" && input["background"]?.bool != true ? Double(SubAgent.lastLimits.get().seconds) + 180 : 140
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let center = await SubAgentCenter.shared
        let action = input["action"]?.string ?? "list"
        if action == "list" {
            let lines = await MainActor.run { center.runs(in: ctx.conversationID).map(\.summaryLine) }
            return ToolOutput(text: lines.isEmpty ? "No sub-agents in this lesson yet." : lines.joined(separator: "\n"))
        }
        guard let key = input["id"]?.string ?? input["handle"]?.string, let run = await center.run(key), run.conversationID == ctx.conversationID else {
            return .error("Unknown sub-agent. `agents` with action list shows the handles.")
        }
        let message = (input["message"]?.string ?? input["note"]?.string ?? input["prompt"]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch action {
        case "stop":
            await run.stop()
            return ToolOutput(text: "Stopping \(run.handle). Its partial findings arrive like any report.")
        case "send":
            guard !message.isEmpty else { return .error("Give the note as `message`.") }
            guard await run.steer(message, from: "teacher") else {
                return .error("\(run.handle) isn't running any more; `agents` resume (or `task` with resume) continues it with a follow-up.")
            }
            return ToolOutput(text: "Sent to \(run.handle); it reads the note before its next step.")
        case "resume":
            guard !message.isEmpty else { return .error("Give the follow-up as `message`.") }
            return await SubAgent.run(TaskRequest(brief: message, title: run.title, background: input["background"]?.bool == true, resume: run.handle), ctx: ctx)
        case "wait":
            let limit = Double(min(120, max(1, input["seconds"]?.int ?? 60)))
            // Waiting hands a background agent's report over here (it won't be delivered again).
            guard let out = await run.wait(seconds: limit) else {
                return ToolOutput(text: "\(run.handle) is still working after \(Int(limit)) s (\(await run.status ?? "running")).\n\(await run.summaryLine)")
            }
            return ToolOutput(text: "\(await run.summaryLine)\n\n\(out.text)", meta: out.meta?["structured"].map { ["structured": $0] })
        default:
            let tail = await run.messages.last { $0.role == .assistant }?.plainText.suffix(600) ?? ""
            return ToolOutput(text: "\(await run.summaryLine)\(await run.status.map { "\nNow: " + $0 } ?? "")\(tail.isEmpty ? "" : "\nLatest output: …" + tail)")
        }
    }
}

/// Runtime tool discovery: loads deferred tools into the lesson.
struct LoadToolsTool: Tool {
    let name = "load_tools"
    let description = "Load extra tools listed under “More tools” in your instructions. They become callable from your next step."
    let risk = ToolRisk.readOnly
    var schema: JSON { Schema.object(["names": Schema.array(Schema.string("Tool name"), "Tools to load.")], required: ["names"]) }
    func summary(_ input: JSON) -> String { input["names"]?.array?.compactMap(\.string).joined(separator: ", ") ?? "" }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let wanted = input["names"]?.array?.compactMap(\.string) ?? []
        let known = Set(ToolRegistry.layout(ctx.conversationID).deferred.map(\.name))
        let ok = wanted.filter { known.contains($0) }, bad = wanted.filter { !known.contains($0) }
        guard !ok.isEmpty else { return .error("Unknown tools: \(bad.joined(separator: ", ")). Loadable: \(known.sorted().joined(separator: ", ")).") }
        return ToolOutput(text: "Loaded \(ok.joined(separator: ", ")). Call them from your next step." + (bad.isEmpty ? "" : " Unknown: \(bad.joined(separator: ", ")).") ,
                          meta: ["loaded": .array(ok.map { .string($0) })])
    }
}
