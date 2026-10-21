import Foundation

private func memoryID(_ input: JSON) -> String? {
    input["id"]?.string ?? input["id"]?.int.map(String.init)
}

struct MemorySearchTool: Tool {
    let name = "memory_search"
    let description = "Search long-term memory (the learner's profile, goals, preferences, knowledge, misconceptions, past lessons, and facts about this folder). Use before re-teaching a topic or when the learner refers to the past."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "query": Schema.string("What to look for."),
            "kind": Schema.string("Optional kind filter.", enum: MemoryKind.allCases.map(\.rawValue)),
            "limit": Schema.integer("Max results (default 8)."),
        ], required: ["query"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let q = try input.req("query")
        let kinds = input["kind"]?.string.flatMap(MemoryKind.init(rawValue:)).map { [$0] }
        let found = ctx.services.memory.search(q, limit: input["limit"]?.int ?? 8, kinds: kinds, minScore: 0.15)
        ctx.services.memory.markUsed(found.map(\.id))
        if found.isEmpty { return ToolOutput(text: "No matching memories.") }
        return ToolOutput(text: found.map { "#\($0.id) [\($0.kind.rawValue)\($0.subject.map { "/\($0)" } ?? "")\($0.scope == .folder ? ", this folder" : ""), relevance \(Int($0.relevance * 100))%] \($0.content)" }.joined(separator: "\n"),
                          meta: ["ids": .array(found.map { .string($0.id) })])
    }
}

struct MemorySaveTool: Tool {
    let name = "memory_save"
    let description = """
    Save a durable fact to long-term memory: who the learner is (profile), how they like to learn (preference), \
    goals, concepts they have demonstrated (knowledge), recurring errors (misconception), or other useful facts. \
    scope="learner" (default) follows the learner into every folder; scope="folder" is only about the current folder/project. \
    One atomic fact per call, third person ("Learner prefers visual explanations"). Never store secrets or sensitive data. \
    Near-duplicates merge automatically.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "content": Schema.string("The fact, concise and self-contained."),
            "kind": Schema.string("Memory kind.", enum: MemoryKind.allCases.map(\.rawValue)),
            "scope": Schema.string("learner (default) or folder.", enum: ["learner", "folder"]),
            "subject": Schema.string("Subject area, e.g. calculus, python, arabic."),
            "importance": Schema.number("0..1 (default 0.6). 0.9+ for core identity/goals."),
            "explicit": Schema.boolean("True if the learner explicitly asked you to remember it."),
        ], required: ["content", "kind"])
    }
    func summary(_ input: JSON) -> String { input["content"]?.string ?? "" }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let content = try input.req("content")
        let kind = input["kind"]?.string.flatMap(MemoryKind.init(rawValue:)) ?? .fact
        let scope = input["scope"]?.string.flatMap(MemoryScope.init(rawValue:)) ?? .learner
        let r = ctx.services.memory.add(kind: kind, content: content, subject: input["subject"]?.string,
                                        importance: input["importance"]?.double ?? 0.6,
                                        origin: input["explicit"]?.bool == true ? "explicit" : "inferred", source: ctx.conversationID, scope: scope)
        return ToolOutput(text: r.merged ? "Merged into existing memory #\(r.id)." : "Saved memory #\(r.id).",
                          meta: ["id": .string(r.id), "merged": .bool(r.merged), "write": true])
    }
}

struct MemoryUpdateTool: Tool {
    let name = "memory_update"
    let description = "Update or correct a memory by id (ids appear as #12 or #f3 in memory listings). Use when facts change (a misconception is resolved, a goal is achieved)."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "id": Schema.string("Memory id, e.g. \"12\" or \"f3\"."),
            "content": Schema.string("New content."),
            "importance": Schema.number("New importance 0..1."),
            "kind": Schema.string("New kind.", enum: MemoryKind.allCases.map(\.rawValue)),
        ], required: ["id"])
    }
    func summary(_ input: JSON) -> String { "#\(memoryID(input) ?? "?")" }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let id = memoryID(input), ctx.services.memory.get(id) != nil else { return .error("No memory with that id.") }
        ctx.services.memory.update(id, content: input["content"]?.string, importance: input["importance"]?.double,
                                   kind: input["kind"]?.string.flatMap(MemoryKind.init(rawValue:)))
        return ToolOutput(text: "Updated memory #\(id).", meta: ["id": .string(id), "write": true])
    }
}

struct MemoryForgetTool: Tool {
    let name = "memory_forget"
    let description = "Delete a memory by id — when it is wrong, outdated, or the learner asks you to forget it."
    let risk = ToolRisk.readOnly
    var schema: JSON { Schema.object(["id": Schema.string("Memory id, e.g. \"12\" or \"f3\".")], required: ["id"]) }
    func summary(_ input: JSON) -> String { "#\(memoryID(input) ?? "?")" }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard let id = memoryID(input), ctx.services.memory.get(id) != nil else { return .error("No memory with that id.") }
        ctx.services.memory.delete(id)
        return ToolOutput(text: "Forgot memory #\(id).", meta: ["id": .string(id), "write": true])
    }
}
