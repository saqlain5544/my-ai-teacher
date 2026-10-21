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
    static let all: [Tool] = core + deferred + [VisualTool(), QuizTool()]

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
    static func active(_ settings: AppSettings, loaded: [String], lessonID: String? = nil) -> [Tool] {
        var off = Set(settings.disabledTools)
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
    static let subagentTools: [Tool] = [ReadTool(), LsTool(), GlobTool(), GrepTool(), WebSearchTool(), WebFetchTool(), MathTool(), MemoryTool(readOnly: true)]
}

/// Delegates a self-contained research/reading task to a sub-agent with its own context; only its final report returns.
struct TaskTool: Tool {
    let name = "task"
    let description = """
    Launch a sub-agent to research or read independently (web search/fetch, read files, math) with its own context; only its \
    report comes back. Blocking (default) when you need the answer before replying; `background: true` when the lesson can go \
    on without it — its report arrives later as a <background-agent> message. Several can run at once; `resume` with an \
    agent's handle (A1…) continues it with a follow-up. Give a complete, specific brief.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "description": Schema.string("3-6 word label."),
            "prompt": Schema.string("Full brief: what to find out, what to return, and how detailed (or the follow-up, with resume)."),
            "background": Schema.boolean("Run without waiting; the report arrives as a message when done."),
            "resume": Schema.string("Handle of a finished sub-agent (A1…) to continue with this prompt."),
        ], required: ["description", "prompt"])
    }
    func summary(_ input: JSON) -> String { input["description"]?.string ?? "sub-agent" }
    func timeout(_ input: JSON) -> Double? { input["background"]?.bool == true ? 30 : SubAgent.budget + 120 }   // the report step comes after the budget

    /// The spec with this lesson's choosable models listed under `model` (fetched per provider, never hard-coded).
    static func spec(models: [String], current: String) -> ToolSpec {
        let t = TaskTool()
        guard models.count > 1, var props = t.schema["properties"]?.object, var obj = t.schema.object else { return t.spec }
        props["model"] = Schema.string("Optional model for this sub-agent: a smaller, faster one for simple look-ups, a stronger one for hard " +
                                       "analysis. Omit to use the lesson's model (\(current)). One of: " + models.prefix(30).joined(separator: ", ") +
                                       (models.count > 30 ? " (and \(models.count - 30) more from this provider)" : ""))
        obj["properties"] = .object(props)
        return ToolSpec(name: t.name, description: t.description, schema: .object(obj))
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let prompt = try input.req("prompt")
        var model: String?
        if let m = input["model"]?.string?.trimmingCharacters(in: .whitespaces), !m.isEmpty {
            guard m == ctx.model || ctx.subAgentModels.isEmpty || ctx.subAgentModels.contains(m) else {
                return .error("Model `\(m)` isn't available for sub-agents here. Choose one of: \(ctx.subAgentModels.prefix(30).joined(separator: ", ")), or omit `model`.")
            }
            model = m
        }
        let resume = input["resume"]?.string.flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
        return await SubAgent.run(brief: prompt, title: input["description"]?.string ?? "Sub-agent", model: model,
                                  background: input["background"]?.bool == true, resume: resume, ctx: ctx)
    }
}


/// Manage this lesson's sub-agents: list them, check one, wait for one, stop one.
struct AgentsTool: Tool {
    let name = "agents"
    let description = "Manage this lesson's sub-agents (from `task`): list, status, wait (for a background one, up to 120 s), stop."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": ["type": "string", "enum": ["list", "status", "wait", "stop"]],
            "id": Schema.string("Agent handle (A1…), for status/wait/stop."),
            "seconds": Schema.integer("wait: how long to wait at most (default 60, max 120)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "") + (input["id"]?.string.map { " " + $0 } ?? "") }
    func timeout(_ input: JSON) -> Double? { 140 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let center = SubAgentCenter.shared
        let action = input["action"]?.string ?? "list"
        if action == "list" {
            let lines = await center.runs(in: ctx.conversationID).map(\.summaryLine)
            return ToolOutput(text: lines.isEmpty ? "No sub-agents in this lesson yet." : lines.joined(separator: "\n"))
        }
        guard let key = input["id"]?.string, let run = await center.run(key), await run.conversationID == ctx.conversationID else {
            return .error("Unknown sub-agent. `agents` with action list shows the handles.")
        }
        switch action {
        case "stop":
            await run.stop()
            return ToolOutput(text: "Stopping \(await run.handle). Its partial findings arrive like any report.")
        case "wait":
            let limit = Double(min(120, max(1, input["seconds"]?.int ?? 60)))
            let t0 = Date()
            while await run.isRunning, Date().timeIntervalSince(t0) < limit {
                try await Task.sleep(nanoseconds: 400_000_000)
            }
            if await run.isRunning { return ToolOutput(text: "\(await run.handle) is still working after \(Int(limit)) s (\(await run.status ?? "running")).") }
            // Waiting for a background agent hands its report over here (it won't be delivered again).
            for _ in 0..<20 where await run.report == nil { try await Task.sleep(nanoseconds: 100_000_000) }
            await MainActor.run { run.reportConsumed = true }
            return ToolOutput(text: "\(await run.summaryLine)\n\n\(await run.report ?? "(no report)")")
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
