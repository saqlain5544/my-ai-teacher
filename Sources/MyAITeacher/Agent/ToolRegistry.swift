import Foundation

enum ToolRegistry {
    /// Always sent to the model: the tools that carry most lessons (measured from recorded tool usage).
    static let core: [Tool] = [
        AskLearnerTool(), MathTool(), RunCodeTool(), ReadTool(), WriteTool(), EditTool(), LsTool(), BashTool(),
        WebSearchTool(), WebFetchTool(), MemoryTool(), LoadToolsTool(),
    ]
    /// Loaded on demand via `load_tools` (listed by one line in the system prompt) to keep every request lean.
    static let deferred: [Tool] = [
        GlobTool(), GrepTool(), TodoWriteTool(), TaskTool(), FlashcardsTool(), MasteryTool(), LessonPlanTool(),
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
    Launch a sub-agent to research or read independently (web search/fetch, read files, math). It has a fresh context and \
    returns only its final report — use it for broad research or reading many pages without filling the lesson context. \
    Launch several in parallel for independent sub-questions. Give a complete, specific brief.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "description": Schema.string("3-6 word label."),
            "prompt": Schema.string("Full brief: what to find out, what to return, and how detailed."),
        ], required: ["description", "prompt"])
    }
    func summary(_ input: JSON) -> String { input["description"]?.string ?? "sub-agent" }
    func timeout(_ input: JSON) -> Double? { SubAgent.budget + 120 }   // the report step comes after the budget

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
        var model = ctx.model
        if let m = input["model"]?.string?.trimmingCharacters(in: .whitespaces), !m.isEmpty, m != ctx.model {
            guard ctx.subAgentModels.isEmpty || ctx.subAgentModels.contains(m) else {
                return .error("Model `\(m)` isn't available for sub-agents here. Choose one of: \(ctx.subAgentModels.prefix(30).joined(separator: ", ")), or omit `model`.")
            }
            model = m
        }
        return await SubAgent.run(brief: prompt, title: input["description"]?.string ?? "Sub-agent", model: model, ctx: ctx)
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
