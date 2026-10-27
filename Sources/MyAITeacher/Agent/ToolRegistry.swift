import Foundation

enum ToolRegistry {
    /// Every tool the app has. Which agent gets which comes from `AgentTree`: an agent has the tools on its path to the
    /// root, core ones with every request and the rest after `load_tools`.
    static let all: [Tool] = [
        ReadTool(), WriteTool(), EditTool(), LsTool(), GlobTool(), GrepTool(), BashTool(), BashJobsTool(), RunCodeTool(), RunTestsTool(),
        WebSearchTool(), WebFetchTool(), TaskTool(), AgentsTool(), LoadToolsTool(), VisualTool(), TodoWriteTool(),
        AskLearnerTool(), MathTool(), MemoryTool(), MasteryTool(), FlashcardsTool(),
        ProjectMemoryTool(), LanguageTool(), VocabTool(), SourceTool(), SymbolsTool(), DiagnosticsTool(), ProjectTestsTool(), ProjectReviewTool(),
        TraceTool(), BenchTool(), ExitPlanModeTool(),
    ] + Features.tools   // optional features' tools (computer use: browser, mac, computer; the course board: lesson_plan)
    static let byName: [String: Tool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static func enabled(_ settings: AppSettings) -> [Tool] {
        all.filter { !settings.disabledTools.contains($0.name) }
    }

    /// What the learner's settings switch off for an agent (disabled tools, Python, the board system).
    static func off(_ settings: AppSettings) -> Set<String> {
        var off = Set(settings.disabledTools)
        if settings.python == .off { off.insert("math") }   // SymPy needs Python
        if BoardSystem.off { off.insert("lesson_plan") }
        return off
    }

    /// An agent's runtime-loadable tools (after its settings).
    static func loadable(_ node: String, _ settings: AppSettings = AppSettings()) -> [Tool] {
        let off = off(settings)
        return AgentTree.deferred(node).compactMap { byName[$0] }.filter { !off.contains($0.name) }
    }

    /// Tools for a request: the agent's core tools, then whatever this lesson has loaded (in load order, so the prefix
    /// only ever grows), MCP servers' tools among them for an agent that has them (`folder`'s servers).
    static func active(_ settings: AppSettings, loaded: [String], lessonID: String? = nil, mode: TeachingMode = .tutor, folder: URL? = nil) -> [Tool] {
        let node = AgentTree.node(for: mode), off = off(settings)
        let canLoad = Set(AgentTree.deferred(node))
        var mcp: [String: Tool] = [:]
        if let folder, AgentTree.usesMCP(node), loaded.contains(where: { $0.hasPrefix("mcp__") }) {
            for t in MCPHub.shared.tools(folder, settings) where mcp[t.name] == nil { mcp[t.name] = t }
        }
        let names = AgentTree.core(node) + loaded.filter { canLoad.contains($0) || mcp[$0] != nil }
        return names.compactMap { byName[$0] ?? mcp[$0] }.filter { !off.contains($0.name) }
    }

    /// A tool by name: the app's own, else one of `folder`'s MCP servers' (`mcp__<server>__<tool>`).
    static func named(_ name: String, folder: URL?, settings: AppSettings) -> Tool? {
        if let t = byName[name] { return t }
        guard let folder else { return nil }
        return MCPHub.shared.tool(named: name, folder: folder, settings: settings)
    }

    /// One line per runtime-loadable tool, for an agent's prompt.
    static func deferredIndex(_ node: String, _ settings: AppSettings = AppSettings()) -> String {
        loadable(node, settings).map { "- `\($0.name)`: \($0.description.components(separatedBy: ". ").first ?? "")" }.joined(separator: "\n")
    }

    /// Every tool a sub-agent can be given; its type and the `task` call choose from these. Derived from each tool's
    /// `subAgentVariant`, so a new tool is declared once (in `all`) and says itself whether sub-agents may use it.
    static let subagentPool: [Tool] = all.compactMap(\.subAgentVariant)
}

/// Delegates a self-contained task to a sub-agent with its own context; only its final report returns.
struct TaskTool: Tool {
    var subAgentVariant: Tool? { self }
    let name = "task"
    let description = """
    Launch a sub-agent with its own context and tools; only its report comes back. `type` (default explore): explore — \
    read-only research (web, files, math); general — research plus files and commands; coder — implements and verifies a \
    code change; reviewer — read-only review (read-only shell commands); tester — runs builds and tests, doesn't edit. \
    Blocking by default; `background: true` returns at once and the report arrives later as a <background-agent> message \
    (steer it meanwhile with `agents` send). Sub-agents never get more access than this lesson has. `resume` with a handle \
    (A1…) continues one with a follow-up. Give a complete, specific brief.
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
    /// The budget's own clock ends a run (then the report step); this backstop is the run's time budget (the call's, the
    /// type's or the default) plus the report.
    func timeout(_ input: JSON) -> Double? {
        input["background"]?.bool == true || input["unbounded"]?.bool == true ? 30 : SubAgent.callSeconds(input)
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
        // Claude Code calls it subagent_type; MiniMax-M3 sent {"agent": "reviewer", "brief": …} live.
        q.type = word("type") ?? word("subagent_type") ?? word("agent_type") ?? word("agent")
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
    var subAgentVariant: Tool? { self }
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
        input["action"]?.string == "resume" && input["background"]?.bool != true ? SubAgent.callSeconds(["resume": input["id"] ?? .null]) : 140
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
    let description = "Load extra tools listed under “More tools” (and MCP servers) in your instructions. They become callable from your next step."
    let risk = ToolRisk.readOnly
    var schema: JSON { Schema.object(["names": Schema.array(Schema.string("Tool name"), "Tools to load.")], required: ["names"]) }
    func summary(_ input: JSON) -> String { input["names"]?.array?.compactMap(\.string).joined(separator: ", ") ?? "" }
    /// Loading an MCP server may wait for the user's approval of a project server and for its first start.
    func timeout(_ input: JSON) -> Double? { (input["names"]?.array ?? []).contains { $0.string?.hasPrefix("mcp__") == true } ? nil : 60 }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let wanted = input["names"]?.array?.compactMap(\.string) ?? []
        let known = Set(AgentTree.deferred(ctx.agentNode))
        let mcpNames = AgentTree.usesMCP(ctx.agentNode) ? wanted.filter { $0.hasPrefix("mcp__") } : []
        let mcp: (loaded: [String], notes: [String]) = mcpNames.isEmpty ? ([], []) : await MCPHub.shared.load(mcpNames, ctx: ctx)
        let ok = wanted.filter { known.contains($0) } + mcp.loaded
        let bad = wanted.filter { !known.contains($0) && !mcpNames.contains($0) }
        let notes = (bad.isEmpty ? "" : " Unknown: \(bad.joined(separator: ", ")).") + (mcp.notes.isEmpty ? "" : " " + mcp.notes.joined(separator: " "))
        guard !ok.isEmpty else {
            return .error(bad.isEmpty ? mcp.notes.joined(separator: " ") : "Unknown tools: \(bad.joined(separator: ", ")). Loadable: \(known.sorted().joined(separator: ", "))." + (mcp.notes.isEmpty ? "" : " " + mcp.notes.joined(separator: " ")))
        }
        return ToolOutput(text: "Loaded \(ok.joined(separator: ", ")). Call them from your next step." + notes, meta: ["loaded": .array(ok.map { .string($0) })])
    }
}
