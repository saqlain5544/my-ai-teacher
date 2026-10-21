import Foundation

/// After lessons, a background pass distils the transcript into the learner model (mem0-style
/// ADD/UPDATE/DELETE/NOOP against retrieved neighbours, plus concept-graph operations), writes an episode summary
/// and proposes a lesson title. The LLM only proposes; `apply` validates every operation deterministically.
enum Reflection {
    struct Outcome {
        var title: String?
        var applied: Int
        var added = 0, updated = 0, deleted = 0, rejected = 0, concepts = 0
        var rejections: [String] = []
    }

    static func transcriptExcerpt(_ messages: [ChatMessage], maxChars: Int = 14_000) -> String {
        var parts: [String] = []
        for m in messages {
            for b in m.blocks {
                switch b.kind {
                case .text where b.meta?["hidden"]?.bool != true:
                    parts.append("[\(m.role == .user ? "Learner" : "Teacher")]: \(b.text ?? "")")
                case .toolUse where !(b.name ?? "").hasPrefix("memory"):
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

    static let extractionRules = """
    You maintain the long-term LEARNER MODEL of a personal AI tutor. It is not a log: store only durable, non-derivable \
    facts that change how to teach this learner in FUTURE lessons.
    Memory kinds: profile (who they are: age/grade/job, languages, background) · preference (how they learn best) · \
    goal (exams, projects, deadlines) · misconception (a specific, recurring error — say exactly what they confuse) · \
    fact (other durable facts: tools, interests).
    Concepts (skills/topics) are graph nodes, NOT memories: report each concept the lesson really worked on, with its \
    subjects (one concept may belong to several subjects, e.g. "Arabic prosody" → ["arabic","poetry"]), its \
    prerequisites (other concepts it builds on, possibly from other subjects) and a status: struggling | learning | solid. \
    Optional "mastery" 0..1 only when the lesson gives clear evidence and no quiz measured it.
    NEVER store: individual questions or answers ("asked for the derivative of sin(x²)"), one-off results or scores \
    (quizzes are tracked automatically), things only true today, anything about the app/tools/errors/interruptions, \
    secrets, health or financial details. Generalise: "makes sign errors when expanding brackets", not "got 3−(−2) wrong".
    Prefer UPDATE of an existing memory (by id) over ADD; DELETE or RESOLVE memories that are now wrong or no longer \
    true (a resolved misconception → resolve; an achieved goal → resolve). If nothing durable was learned, return no operations.
    """

    static func run(messages: [ChatMessage], conversationID: String, client: LLMClient, model: String,
                    services: Services, needsTitle: Bool) async -> Outcome {
        let excerpt = transcriptExcerpt(messages)
        guard excerpt.count > 80 else { return Outcome(title: nil, applied: 0) }
        let hub = services.memory
        let existing = hub.coreBlock(maxChars: 4000)
        let related = hub.search(String(excerpt.suffix(3000)), limit: 15, minScore: 0.25)
            .filter { !existing.contains("[#\($0.id)]") }
            .map { "- [#\($0.id)] (\($0.kind.rawValue)\($0.scope == .folder ? ", folder" : "")) \($0.content)" }.joined(separator: "\n")
        let concepts = hub.concepts(matching: excerpt, limit: 25).map { "- " + hub.conceptLine($0, detail: false) }.joined(separator: "\n")
        let system = extractionRules + """

        Scope: "learner" (default, applies everywhere) or "folder" (only about the current folder/project).
        Reply with ONLY a JSON object:
        {"operations":[{"op":"add","kind":"misconception","scope":"learner","concept":"chain rule","content":"…","importance":0.7},
          {"op":"update","id":"12","content":"…"},{"op":"resolve","id":"9"},{"op":"delete","id":"f7"}],
         "concepts":[{"name":"chain rule","subjects":["calculus"],"prerequisites":["derivatives"],"status":"learning"}],
         "episode":"2-3 sentences: what was covered, how it went, what to do next time",
         "title":"short lesson title (≤ 6 words)"}
        """
        let user = """
        # Learner model (existing)
        \(existing.isEmpty ? "(empty)" : existing)
        \(related.isEmpty ? "" : "\n# Possibly related memories\n" + related)
        \(concepts.isEmpty ? "" : "\n# Known concepts mentioned\n" + concepts)

        # Lesson excerpt
        \(excerpt)
        """
        guard let json = await complete(client: client, model: model, system: system, user: user) else { return Outcome(title: nil, applied: 0) }
        var out = apply(json, hub: hub, conversationID: conversationID)
        out.title = needsTitle ? json["title"]?.string?.trimmingCharacters(in: CharacterSet(charactersIn: "\"' \n")) : nil
        return out
    }

    private static func complete(client: LLMClient, model: String, system: String, user: String) async -> JSON? {
        var text = ""
        do {
            let req = LLMRequest(model: model, system: system, messages: [ChatMessage(role: .user, blocks: [.text(user)])], maxTokens: 4096, thinking: .off)
            for try await ev in client.stream(req) { if case .text(let t) = ev { text += t } }
        } catch { return nil }
        return extractJSON(text)
    }

    private static func strings(_ j: JSON?) -> [String] {
        if let s = j?.string { return s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } }
        return (j?.array ?? []).compactMap(\.string).filter { !$0.isEmpty }
    }

    /// Validates and applies model-proposed operations. Deterministic (unit-tested without a model).
    static func apply(_ json: JSON, hub: MemoryHub, conversationID: String?, origin: String = "reflection") -> Outcome {
        var out = Outcome(title: nil, applied: 0)
        // Concepts first, so memory adds can attach to them.
        for c in json["concepts"]?.array ?? [] {
            guard let name = c["name"]?.string, !name.isEmpty else { continue }
            if hub.saveConcept(name: name, subjects: strings(c["subjects"]) + strings(c["subject"]),
                               prerequisites: strings(c["prerequisites"]) + strings(c["prereqs"]), related: strings(c["related"]),
                               partOf: strings(c["part_of"]), summary: c["summary"]?.string, status: c["status"]?.string,
                               estimate: c["mastery"]?.double, origin: origin, source: conversationID) != nil { out.concepts += 1 }
        }
        for m in json["merge_concepts"]?.array ?? [] {
            guard let into = m["into"]?.string, hub.concept(into) != nil else { continue }
            hub.mergeConcepts(into: into, from: strings(m["from"])); out.updated += 1
        }
        for l in json["links"]?.array ?? [] {
            guard let a = l["from"]?.string, let b = l["to"]?.string, let graph = hub.graph,
                  let ca = hub.concept(a), let cb = hub.concept(b) else { continue }
            graph.link(ca.rowid, cb.rowid, ConceptRelation(loose: l["rel"]?.string ?? "related") ?? .related); out.updated += 1
        }
        for op in json["operations"]?.array ?? [] {
            let id = op["id"]?.string ?? op["id"]?.int.map(String.init)
            switch op["op"]?.string?.lowercased() {
            case "add":
                guard let c = op["content"]?.string, !c.isEmpty else { continue }
                let kind = op["kind"]?.string.flatMap(MemoryKind.init(rawValue:)) ?? .fact
                guard kind != .episode else { continue }
                let r = hub.add(kind: kind, content: c, subject: op["subject"]?.string, importance: op["importance"]?.double ?? 0.5,
                                origin: origin, source: conversationID,
                                scope: op["scope"]?.string.flatMap(MemoryScope.init(rawValue:)) ?? .learner, concept: op["concept"]?.string)
                switch r.status {
                case .added: out.added += 1
                case .merged: out.updated += 1
                case .rejected: out.rejected += 1; out.rejections.append("\(c) — \(r.reason ?? "")")
                }
            case "update":
                guard let id, hub.exists(id) else { continue }
                hub.update(id, content: op["content"]?.string, importance: op["importance"]?.double,
                           kind: op["kind"]?.string.flatMap(MemoryKind.init(rawValue:)), concept: op["concept"]?.string, source: conversationID)
                out.updated += 1
            case "resolve", "achieve", "archive":
                guard let id, hub.get(id) != nil else { continue }
                hub.resolveItem(id, source: conversationID); out.deleted += 1
            case "delete":
                guard let id, hub.exists(id) else { continue }
                hub.delete(id); out.deleted += 1
            default: continue
            }
        }
        if let ep = json["episode"]?.string, ep.count > 10 {
            hub.add(kind: .episode, content: ep, importance: 0.4, origin: origin, source: conversationID, scope: .folder)
        }
        hub.maintenance()
        out.applied = out.added + out.updated + out.deleted + out.concepts
        return out
    }

    /// Periodic hygiene ("sleep-time" consolidation): a deterministic local pass, then the model merges duplicates,
    /// sharpens vague facts, resolves contradictions, links/merges concepts and may add cross-subject insights.
    static func consolidate(client: LLMClient, model: String, services: Services) async -> Outcome {
        let hub = services.memory
        let local = hub.maintenance()
        let all = hub.all().filter { $0.kind != .episode }.sorted { $0.importance > $1.importance }.prefix(150)
        let concepts = (hub.graph?.all() ?? []).sorted { $0.updatedAt > $1.updatedAt }.prefix(120)
        guard all.count + concepts.count >= 2 else { return Outcome(title: nil, applied: local.merged) }
        let listing = all.map { "- [#\($0.id)] (\($0.kind.rawValue)\($0.scope == .folder ? ", folder" : "")\($0.subject.map { ", \($0)" } ?? "")) \($0.content)" }.joined(separator: "\n")
        let conceptListing = concepts.map { "- " + hub.conceptLine($0, detail: true) }.joined(separator: "\n")
        let system = """
        You curate a personal tutor's learner model. Improve it without inventing facts:
        - merge duplicate memories (update one, delete the others); rewrite vague ones to be specific and general;
        - resolve contradictions (keep the newest/most specific; delete or update the other);
        - delete noise and derivable trivia (single questions, one-off answers or scores, app/tool mechanics);
        - merge duplicate concepts ("Chain Rule" / "chain rule for derivatives") and add missing prerequisite or related \
          links between concepts — especially across subjects (e.g. physics kinematics needs calculus derivatives);
        - optionally add at most 3 cross-subject insights (kind fact/preference/misconception) that are clearly supported \
          by several memories (e.g. "makes sign errors in both algebra and physics problems").
        Ids must be exactly as given. Content is plain text without "[#id]" labels.
        Reply with ONLY JSON: {"operations":[{"op":"update","id":"12","content":"…"},{"op":"delete","id":"f3"},{"op":"add","kind":"fact","content":"…"}],
         "merge_concepts":[{"into":"c3","from":["c9"]}],"links":[{"from":"c4","to":"c2","rel":"prereq"}],
         "concepts":[{"name":"…","subjects":["…"]}]}
        """
        let user = "# Memories\n\(listing)\n\n# Concepts\n\(conceptListing.isEmpty ? "(none)" : conceptListing)"
        guard let json = await complete(client: client, model: model, system: system, user: user) else { return Outcome(title: nil, applied: local.merged) }
        // Only touch ids that were shown.
        let known = Set(all.map(\.id) + concepts.map(\.id))
        var filtered = json.object ?? [:]
        filtered["operations"] = .array((json["operations"]?.array ?? []).filter { op in
            op["op"]?.string == "add" || (op["id"]?.string ?? op["id"]?.int.map(String.init)).map(known.contains) == true
        })
        var out = apply(.object(filtered), hub: hub, conversationID: nil, origin: "consolidation")
        out.updated += local.merged
        out.applied += local.merged
        UserDefaults.standard.set(Date(), forKey: "memory.lastConsolidated")
        UserDefaults.standard.set(hub.count(), forKey: "memory.countAtConsolidation")
        return out
    }

    /// Consolidate weekly, or whenever memory has grown by 10+ items since the last pass.
    static func consolidationDue(_ services: Services) -> Bool {
        let last = UserDefaults.standard.object(forKey: "memory.lastConsolidated") as? Date ?? .distantPast
        let n = services.memory.count()
        let grown = n - UserDefaults.standard.integer(forKey: "memory.countAtConsolidation")
        return n >= 4 && (grown >= 10 || Date().timeIntervalSince(last) > 7 * 86400)
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
