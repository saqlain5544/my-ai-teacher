import Foundation

/// One compact tool over the learner model (≈200 schema tokens instead of four tools).
/// Ids: "12" learner memory, "f3" folder memory, "c7" concept.
struct MemoryTool: Tool {
    var subAgentVariant: Tool? { MemoryTool(readOnly: true) }   // search only: sub-agents never write the learner model
    let name = "memory"
    /// Sub-agents get a search-only variant.
    var readOnly = false
    var description: String {
        readOnly ? "Search the learner's long-term memory."
        : "Learner model. save ONE durable fact (kind=concept: concept=name, content=note); never one-off details. Ids: 12, f3 folder, c7 concept."
    }
    let risk = ToolRisk.readOnly
    var schema: JSON {
        if readOnly { return Schema.object(["query": ["type": "string"]], required: ["query"]) }
        let s = { (d: String) in JSON.object(["type": "string", "description": .string(d)]) }
        let plain: JSON = ["type": "string"]
        let oneOf = { (v: [String]) in JSON.object(["type": "string", "enum": .array(v.map { .string($0) })]) }
        return Schema.object([
            "action": oneOf(["search", "save", "update", "forget"]),
            "query": plain,
            "content": plain,
            "kind": oneOf(["profile", "preference", "goal", "misconception", "fact", "concept"]),
            "concept": s("concept it's about"),
            "subjects": s("comma-separated"),
            "needs": s("prerequisite concepts"),
            "id": plain,
            "resolved": ["type": "boolean"],
            "scope": oneOf(["learner", "folder"]),
            "explicit": ["type": "boolean", "description": "learner asked to remember"],
        ], required: ["action"])
    }

    func summary(_ input: JSON) -> String {
        switch action(input) {
        case "search": return input["query"]?.string ?? ""
        case "save": return input["content"]?.string ?? ""
        default: return "#" + (Self.id(input) ?? "?")
        }
    }

    private func action(_ input: JSON) -> String {
        if readOnly { return "search" }
        return input["action"]?.string ?? (input["query"] != nil ? "search" : input["content"] != nil && input["id"] == nil ? "save" : "update")
    }
    static func id(_ input: JSON) -> String? { input["id"]?.string ?? input["id"]?.int.map(String.init) }
    /// A short concept name from a longer description: its first clause, cut at a word boundary (≤ 60 chars).
    static func conceptName(_ text: String) -> String {
        let clause = text.components(separatedBy: CharacterSet(charactersIn: ".:;—\n(")).first?.trimmingCharacters(in: .whitespaces) ?? ""
        let base = clause.isEmpty ? text : clause
        guard base.count > 60 else { return base }
        var out = ""
        for w in base.split(separator: " ") where out.count + w.count + 1 <= 60 { out += (out.isEmpty ? "" : " ") + w }
        return out.isEmpty ? String(base.prefix(60)) : out
    }
    private static func list(_ j: JSON?) -> [String] {
        if let a = j?.array { return a.compactMap(\.string) }
        return (j?.string ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let hub = ctx.services.memory
        switch action(input) {
        case "search":
            let q = input["query"]?.string ?? input["content"]?.string ?? ""
            guard !q.isEmpty else { return .error("Missing `query`.") }
            let found = hub.search(q, limit: 8)
            let concepts = hub.concepts(matching: q, limit: 3)
            hub.markUsed(found.map(\.id))
            if found.isEmpty && concepts.isEmpty { return ToolOutput(text: "No matching memories.") }
            var lines = found.map { m in
                "#\(m.id) \(m.kind.rawValue)\(m.subject.map { " (\($0))" } ?? "")\(m.scope == .folder ? " [folder]" : ""): \(m.content)"
            }
            lines += concepts.map { "concept " + hub.conceptLine($0, detail: true) }
            return ToolOutput(text: lines.joined(separator: "\n"), meta: ["ids": .array((found.map(\.id) + concepts.map(\.id)).map { .string($0) })])

        case "save":
            // A concept may come with just its name in `concept`.
            let content = (input["content"]?.string).flatMap { $0.isEmpty ? nil : $0 } ?? input["concept"]?.string ?? ""
            guard !content.isEmpty else { return .error("Missing `content` (or, for kind=concept, `concept`).") }
            let kindRaw = input["kind"]?.string ?? "fact"
            let subjects = Self.list(input["subjects"]) + Self.list(input["subject"])   // models often write `subject`
            if kindRaw == "concept" || kindRaw == "knowledge" {
                // Models often describe the concept in `content`: the name is `concept`, or a short `content`, or its first
                // clause; a longer description becomes the concept's summary instead of an error.
                let named = input["concept"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
                let name = !named.isEmpty ? named : content.count <= 80 ? content : Self.conceptName(content)
                guard let id = hub.saveConcept(name: name, subjects: subjects, prerequisites: Self.list(input["needs"]),
                                               summary: name == content ? nil : String(content.prefix(400)),
                                               status: kindRaw == "knowledge" ? "solid" : nil, origin: "inferred", source: ctx.conversationID)
                else { return .error("Concept names must be short (≤ 80 chars): put a name like \"ionic bonding\" in `concept` and any detail in `content`.") }
                return ToolOutput(text: "Concept #c\(id) saved.", meta: ["id": .string("c\(id)"), "write": true])
            }
            let kind = MemoryKind(rawValue: kindRaw) ?? .fact
            let scope = input["scope"]?.string.flatMap(MemoryScope.init(rawValue:)) ?? .learner
            let r = hub.add(kind: kind, content: content, subject: subjects.first, importance: input["explicit"]?.bool == true ? 0.8 : 0.6,
                            origin: input["explicit"]?.bool == true ? "explicit" : "inferred", source: ctx.conversationID,
                            scope: scope, concept: input["concept"]?.string)
            switch r.status {
            case .rejected:
                return ToolOutput(text: "Not saved: \(r.reason ?? "not durable"). Memory keeps only durable facts that matter in future lessons.",
                                  meta: ["write": false])
            case .merged:
                return ToolOutput(text: "Already known — reinforced #\(r.id).", meta: ["id": .string(r.id), "merged": true, "write": true])
            case .added:
                var t = "Saved #\(r.id)."
                let sim = r.similar.compactMap { hub.get($0) }
                if !sim.isEmpty { t += " Similar: " + sim.map { "#\($0.id) “\(MemoryText.clip($0.content, 80))”" }.joined(separator: "; ") + " — if one is now outdated, update or forget it." }
                return ToolOutput(text: t, meta: ["id": .string(r.id), "merged": false, "write": true])
            }

        case "update":
            guard let id = Self.id(input), hub.exists(id) else { return .error("No memory with that id.") }
            if input["resolved"]?.bool == true, hub.get(id) != nil {
                hub.resolveItem(id, source: ctx.conversationID)
                return ToolOutput(text: "Marked #\(id) resolved.", meta: ["id": .string(id), "write": true])
            }
            if let c = hub.concept(id) {
                let subjects = Self.list(input["subjects"])
                hub.saveConcept(name: c.name, subjects: subjects, prerequisites: Self.list(input["needs"]), source: ctx.conversationID)
                if let n = input["content"]?.string, !n.isEmpty, n != c.name { hub.update(id, content: n) }
                return ToolOutput(text: "Updated concept #\(id).", meta: ["id": .string(id), "write": true])
            }
            hub.update(id, content: input["content"]?.string, kind: input["kind"]?.string.flatMap(MemoryKind.init(rawValue:)),
                       concept: input["concept"]?.string, source: ctx.conversationID)
            return ToolOutput(text: "Updated #\(id).", meta: ["id": .string(id), "write": true])

        case "forget":
            guard let id = Self.id(input), hub.exists(id) else { return .error("No memory with that id.") }
            hub.delete(id)
            return ToolOutput(text: "Forgot #\(id).", meta: ["id": .string(id), "write": true])

        default:
            return .error("Unknown action.")
        }
    }
}
