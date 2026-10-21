import Foundation

enum ToolRegistry {
    /// Always sent to the model: the tools that carry most lessons (measured from recorded tool usage).
    static let core: [Tool] = [
        AskLearnerTool(), MathTool(), RunCodeTool(), ReadTool(), WriteTool(), EditTool(), LsTool(), BashTool(),
        WebSearchTool(), WebFetchTool(), VisualTool(), MemoryTool(), LoadToolsTool(),
    ]
    /// Loaded on demand via `load_tools` (listed by one line in the system prompt) to keep every request lean.
    static let deferred: [Tool] = [
        GlobTool(), GrepTool(), TodoWriteTool(), TaskTool(), FlashcardsTool(), MasteryTool(), LessonPlanTool(),
    ]
    static let all: [Tool] = core + deferred + [QuizTool()]
    static let byName: [String: Tool] = Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    static func enabled(_ settings: AppSettings) -> [Tool] {
        all.filter { !settings.disabledTools.contains($0.name) }
    }

    /// Tools for a request: core + whatever this lesson has loaded (in load order, so the prefix only ever grows).
    static func active(_ settings: AppSettings, loaded: [String]) -> [Tool] {
        let off = Set(settings.disabledTools)
        let extra = loaded.compactMap { name in deferred.first { $0.name == name } }
        return (core + extra).filter { !off.contains($0.name) }
    }

    /// One line per deferred tool for the system prompt.
    static var deferredIndex: String {
        deferred.map { "- `\($0.name)`: \($0.description.components(separatedBy: ". ").first ?? "")" }.joined(separator: "\n")
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

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let prompt = try input.req("prompt")
        let system = """
        You are a meticulous research sub-agent working for a tutor. Complete the brief using your tools, then reply with a \
        concise, well-organised report (Markdown, LaTeX for math) that cites sources as markdown links. Don't ask questions; \
        make reasonable assumptions and note them. Today is \(Date().formatted(date: .complete, time: .omitted)).
        """
        var messages = [ChatMessage(role: .user, blocks: [.text(prompt)])]
        let tools = ToolRegistry.subagentTools
        var steps = 0
        var finalText = ""
        while steps < 16 {
            steps += 1
            try Task.checkCancellation()
            var assistant = ChatMessage(role: .assistant, blocks: [], model: ctx.model)
            var text = ""
            for try await ev in ctx.client.stream(LLMRequest(model: ctx.model, system: system, messages: messages, tools: tools.map(\.spec), maxTokens: 8192)) {
                switch ev {
                case .text(let t): text += t
                case .toolCall(let b): assistant.blocks.append(b); ctx.progress("→ \(b.name ?? "") \(tools.first { $0.name == b.name }?.summary(b.input ?? .null) ?? "")\n")
                default: break
                }
            }
            if !text.isEmpty { assistant.blocks.insert(.text(text), at: 0) }
            messages.append(assistant)
            let calls = assistant.toolUses
            if calls.isEmpty { finalText = text; break }
            let results = await withTaskGroup(of: (Int, Block).self) { group -> [Block] in
                for (i, c) in calls.enumerated() {
                    group.addTask {
                        guard let tool = tools.first(where: { $0.name == c.name }) else {
                            return (i, .toolResult(id: c.id ?? "", name: c.name ?? "", content: "Unknown tool", isError: true))
                        }
                        let sub = ToolContext(conversationID: ctx.conversationID, workspace: ctx.workspace, services: ctx.services,
                                              interactions: ctx.interactions, toolCallID: c.id ?? "", client: ctx.client, model: ctx.model, progress: { _ in })
                        do {
                            let out = try await tool.run(c.input ?? .object([:]), sub)
                            return (i, .toolResult(id: c.id ?? "", name: tool.name, content: truncateMiddle(out.text, max: 40_000), isError: out.isError, images: out.images))
                        } catch {
                            return (i, .toolResult(id: c.id ?? "", name: tool.name, content: error.localizedDescription, isError: true))
                        }
                    }
                }
                var out: [(Int, Block)] = []
                for await r in group { out.append(r) }
                return out.sorted { $0.0 < $1.0 }.map(\.1)
            }
            messages.append(ChatMessage(role: .user, blocks: results))
        }
        if finalText.isEmpty { finalText = "(The sub-agent stopped without a final report.)" }
        return ToolOutput(text: finalText)
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
        let known = Set(ToolRegistry.deferred.map(\.name))
        let ok = wanted.filter { known.contains($0) }, bad = wanted.filter { !known.contains($0) }
        guard !ok.isEmpty else { return .error("Unknown tools: \(bad.joined(separator: ", ")). Loadable: \(known.sorted().joined(separator: ", ")).") }
        return ToolOutput(text: "Loaded \(ok.joined(separator: ", ")). Call them from your next step." + (bad.isEmpty ? "" : " Unknown: \(bad.joined(separator: ", ")).") ,
                          meta: ["loaded": .array(ok.map { .string($0) })])
    }
}
