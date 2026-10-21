import Foundation

/// After lessons, a background pass distils the transcript into durable memories (mem0-style add/update/delete),
/// writes an episode summary and proposes a better lesson title.
enum Reflection {
    struct Outcome { var title: String?; var applied: Int; var added = 0; var updated = 0; var deleted = 0 }

    static func transcriptExcerpt(_ messages: [ChatMessage], maxChars: Int = 14_000) -> String {
        var parts: [String] = []
        for m in messages {
            for b in m.blocks {
                switch b.kind {
                case .text where b.meta?["hidden"]?.bool != true:
                    parts.append("[\(m.role == .user ? "Learner" : "Teacher")]: \(b.text ?? "")")
                case .toolUse:
                    let input = (b.input ?? .null).compact
                    parts.append("[Teacher used \(b.name ?? "tool")]: \(input.prefix(300))")
                case .toolResult where ["quiz", "ask_learner"].contains(b.name ?? ""):
                    parts.append("[Result of \(b.name ?? "")]: \((b.text ?? "").prefix(1200))")
                case .image: parts.append("[Learner attached an image]")
                case .file: parts.append("[Learner attached file \(b.name ?? "")]")
                default: break
                }
            }
        }
        var s = parts.joined(separator: "\n\n")
        if s.count > maxChars { s = "…" + String(s.suffix(maxChars)) }
        return s
    }

    static func run(messages: [ChatMessage], conversationID: String, client: LLMClient, model: String,
                    services: Services, needsTitle: Bool) async -> Outcome {
        let excerpt = transcriptExcerpt(messages)
        guard excerpt.count > 80 else { return Outcome(title: nil, applied: 0) }
        let existing = services.memory.coreBlock(maxChars: 4000)
        let related = services.memory.search(String(excerpt.suffix(3000)), limit: 20, minScore: 0.2)
            .map { "- [#\($0.id)] (\($0.kind.rawValue)\($0.scope == .folder ? ", folder" : "")) \($0.content)" }.joined(separator: "\n")
        let system = """
        You maintain the long-term memory of a personal AI tutor. From the lesson excerpt, extract durable facts that will help \
        teach this learner better in future lessons. Kinds:
        - profile: who they are (age/grade/occupation, languages, background)
        - preference: how they like to learn (pace, examples, visuals, tone)
        - goal: what they want to achieve (exams, projects, deadlines)
        - knowledge: concepts they have clearly demonstrated understanding of
        - misconception: specific recurring errors or confusions (be precise)
        - fact: other useful facts (tools they use, interests)
        Scope: "learner" (default) for facts about the learner that apply everywhere; "folder" for facts only about the current \
        folder/project (what it contains, its purpose, project-specific decisions).
        Only record facts about the learner (or the folder's subject matter). Never record anything about the app, tools, \
        errors, interrupted or skipped questions, or how the conversation was run.
        Rules: atomic third-person statements; skip trivia and anything already known (update instead of duplicating); \
        never store secrets, passwords, health or financial details; update or delete memories that are now wrong \
        (e.g. a misconception that was resolved → delete or rewrite it). Importance 0..1.
        Reply with ONLY a JSON object:
        {"operations":[{"op":"add","kind":"goal","scope":"learner","subject":"calculus","content":"…","importance":0.8},{"op":"update","id":"12","content":"…","importance":0.6},{"op":"delete","id":"f7"}],
         "episode":"2-3 sentences: what was covered, how it went, what to do next time",
         "title":"short lesson title (≤ 6 words)"}
        """
        let user = """
        # Existing memories
        \(existing.isEmpty ? "(none)" : existing)
        \(related.isEmpty ? "" : "\n# Possibly related\n" + related)

        # Lesson excerpt
        \(excerpt)
        """
        var text = ""
        do {
            let req = LLMRequest(model: model, system: system, messages: [ChatMessage(role: .user, blocks: [.text(user)])], maxTokens: 4096)
            for try await ev in client.stream(req) { if case .text(let t) = ev { text += t } }
        } catch {
            return Outcome(title: nil, applied: 0)
        }
        guard let json = extractJSON(text) else { return Outcome(title: nil, applied: 0) }
        var out = Outcome(title: nil, applied: 0)
        for op in json["operations"]?.array ?? [] {
            let id = op["id"]?.string ?? op["id"]?.int.map(String.init)
            switch op["op"]?.string {
            case "add":
                guard let c = op["content"]?.string, !c.isEmpty else { continue }
                services.memory.add(kind: op["kind"]?.string.flatMap(MemoryKind.init(rawValue:)) ?? .fact, content: c,
                                    subject: op["subject"]?.string, importance: op["importance"]?.double ?? 0.5,
                                    origin: "reflection", source: conversationID,
                                    scope: op["scope"]?.string.flatMap(MemoryScope.init(rawValue:)) ?? .learner)
                out.added += 1
            case "update":
                guard let id, services.memory.get(id) != nil else { continue }
                services.memory.update(id, content: op["content"]?.string, importance: op["importance"]?.double)
                out.updated += 1
            case "delete":
                guard let id, services.memory.get(id) != nil else { continue }
                services.memory.delete(id); out.deleted += 1
            default: continue
            }
        }
        if let ep = json["episode"]?.string, ep.count > 10 {
            services.memory.add(kind: .episode, content: ep, importance: 0.4, origin: "reflection", source: conversationID, scope: .folder)
        }
        services.memory.maintenance()
        out.applied = out.added + out.updated + out.deleted
        out.title = needsTitle ? json["title"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n")) : nil
        return out
    }

    /// Periodic hygiene over ALL memories: merge duplicates, rewrite vague or stale facts, resolve contradictions,
    /// and delete noise (anything about the app/tools rather than the learner). Keeps memory improving over time.
    static func consolidate(client: LLMClient, model: String, services: Services) async -> Outcome {
        let all = services.memory.all().filter { $0.kind != .episode }
        guard all.count >= 2 else { return Outcome(title: nil, applied: 0) }
        let listing = all.map { "- [#\($0.id)] (\($0.kind.rawValue)\($0.scope == .folder ? ", folder" : "")\($0.subject.map { ", \($0)" } ?? "")) \($0.content)" }.joined(separator: "\n")
        let system = """
        You curate a personal tutor's long-term memory about one learner. Improve the list:
        - merge duplicates or near-duplicates into one precise memory (update one, delete the others);
        - rewrite vague memories to be specific and atomic; fix contradictions (keep the newest/most specific);
        - delete noise: anything about the app, tools, errors, interrupted or skipped questions, or conversation mechanics.
          Example of noise to delete: "Teacher attempted a quiz but the call was interrupted before the learner answered."
          (Keep any real learner fact inside it only if it is stated elsewhere or can be rewritten without the mechanics.)
        - never invent new facts. Content must be plain text without the "[#id] (kind…)" labels. Keep ids exactly as given.
        Reply with ONLY JSON: {"operations":[{"op":"update","id":"12","content":"…","importance":0.7},{"op":"delete","id":"f3"}]}
        """
        var text = ""
        do {
            let req = LLMRequest(model: model, system: system, messages: [ChatMessage(role: .user, blocks: [.text("# Memories\n" + listing)])], maxTokens: 4096)
            for try await ev in client.stream(req) { if case .text(let t) = ev { text += t } }
        } catch { return Outcome(title: nil, applied: 0) }
        guard let json = extractJSON(text) else { return Outcome(title: nil, applied: 0) }
        var out = Outcome(title: nil, applied: 0)
        let known = Set(all.map(\.id))
        for op in json["operations"]?.array ?? [] {
            guard let id = op["id"]?.string ?? op["id"]?.int.map(String.init), known.contains(id) else { continue }
            switch op["op"]?.string {
            case "update":
                services.memory.update(id, content: op["content"]?.string, importance: op["importance"]?.double); out.updated += 1
            case "delete":
                services.memory.delete(id); out.deleted += 1
            default: break
            }
        }
        out.applied = out.updated + out.deleted
        UserDefaults.standard.set(Date(), forKey: "memory.lastConsolidated")
        UserDefaults.standard.set(services.memory.count(), forKey: "memory.countAtConsolidation")
        return out
    }

    /// Consolidate weekly, or whenever memory has grown by 10+ items since the last pass.
    static func consolidationDue(_ services: Services) -> Bool {
        let last = UserDefaults.standard.object(forKey: "memory.lastConsolidated") as? Date ?? .distantPast
        let grown = services.memory.count() - UserDefaults.standard.integer(forKey: "memory.countAtConsolidation")
        return services.memory.count() >= 4 && (grown >= 10 || Date().timeIntervalSince(last) > 7 * 86400)
    }

    /// Pulls the first balanced {...} object out of model output (tolerates code fences and prose).
    static func extractJSON(_ s: String) -> JSON? {
        var t = s
        if let r = t.range(of: "</think>") { t = String(t[r.upperBound...]) }
        guard let start = t.firstIndex(of: "{") else { return nil }
        var depth = 0, inStr = false, esc = false
        var idx = start
        while idx < t.endIndex {
            let c = t[idx]
            if esc { esc = false } else if c == "\\" { esc = true } else if c == "\"" { inStr.toggle() }
            else if !inStr {
                if c == "{" { depth += 1 } else if c == "}" { depth -= 1; if depth == 0 { return JSON.parse(String(t[start...idx])) } }
            }
            idx = t.index(after: idx)
        }
        return PartialToolCall.repair(String(t[start...])).object != nil ? PartialToolCall.repair(String(t[start...])) : nil
    }
}
