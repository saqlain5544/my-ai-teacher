import Foundation

/// Facade over learner-wide memories (+ the concept graph) and folder memories.
/// Ids are scope-tagged strings: "12" learner memory, "f3" folder memory, "c7" concept.
final class MemoryHub: @unchecked Sendable {
    let learner: MemoryStore
    let folder: MemoryStore
    var graph: ConceptGraph? { learner.graph }
    init(learner: MemoryStore, folder: MemoryStore) { self.learner = learner; self.folder = folder }

    enum Ref { case memory(MemoryStore, Int64), concept(Int64) }

    func ref(_ id: String) -> Ref? {
        var s = id.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        let l = s.lowercased()
        if l.hasPrefix("c"), let n = Int64(s.dropFirst()) { return .concept(n) }
        if l.hasPrefix("f"), let n = Int64(s.dropFirst()) { return .memory(folder, n) }
        if let n = Int64(s) { return .memory(learner, n) }
        return nil
    }

    func resolve(_ id: String) -> (MemoryStore, Int64)? {
        if case .memory(let st, let n) = ref(id) { return (st, n) }
        return nil
    }

    func store(_ scope: MemoryScope) -> MemoryStore { scope == .learner ? learner : folder }
    private func tag(_ scope: MemoryScope, _ n: Int64) -> String { scope == .learner ? String(n) : "f\(n)" }

    // MARK: Writes

    /// Adds a durable memory. Learner-scope misconceptions/goals/knowledge are attached to a concept node
    /// (given explicitly, or routed from the text). `knowledge` with a concept becomes concept evidence, not a sentence.
    @discardableResult
    func add(kind: MemoryKind, content: String, subject: String? = nil, importance: Double = 0.5, origin: String = "inferred",
             source: String? = nil, scope: MemoryScope = .learner, concept: String? = nil) -> MemoryWriteResult {
        var conceptID: Int64?
        if scope == .learner, let graph {
            if let concept, !concept.isEmpty {
                conceptID = graph.upsert(name: concept, subjects: subject.map { [$0] } ?? [], origin: origin, source: source)
            } else if [.misconception, .knowledge, .goal].contains(kind) {
                conceptID = graph.route(content).filter { $0.value >= 1 }.max { $0.key > $1.key }?.key
            }
            if kind == .knowledge, concept != nil, let cid = conceptID {
                let isJustName = MemoryText.norm(content) == MemoryText.norm(concept ?? "")
                graph.update(cid, summary: isJustName ? nil : MemoryText.clip(MemoryStore.clean(content), 240), status: "solid")
                EventBus.publish(.memoryChanged(MemoryChange(kind: .updated, ids: ["c\(cid)"], summary: content, conversationID: source)))
                return MemoryWriteResult(id: "c\(cid)", status: .merged)
            }
        }
        let st = store(scope)
        let r = st.add(kind: kind, content: content, subject: subject ?? concept, importance: importance, origin: origin,
                       source: source, conceptID: conceptID)
        guard let rowid = r.rowid else { return MemoryWriteResult(id: "", status: .rejected, reason: r.reason) }
        let id = tag(scope, rowid)
        EventBus.publish(.memoryChanged(MemoryChange(kind: r.status == .merged ? .merged : .added, ids: [id], summary: content, conversationID: source)))
        return MemoryWriteResult(id: id, status: r.status, similar: r.similar.map { tag(scope, $0) })
    }

    /// Creates/reinforces a concept with subjects and edges (names are created on demand).
    @discardableResult
    func saveConcept(name: String, subjects: [String] = [], prerequisites: [String] = [], related: [String] = [], partOf: [String] = [],
                     summary: String? = nil, status: String? = nil, estimate: Double? = nil, origin: String = "inferred",
                     source: String? = nil) -> Int64? {
        guard let graph, let id = graph.upsert(name: name, subjects: subjects, summary: summary, status: status, origin: origin, source: source) else { return nil }
        for (names, rel) in [(prerequisites, ConceptRelation.prerequisite), (related, .related), (partOf, .partOf)] {
            for n in names {
                // A new neighbour inherits this concept's subjects; an existing one keeps its own (that is how cross-subject links appear).
                let existing = graph.find(n)
                guard let other = existing ?? graph.upsert(name: n, subjects: subjects, origin: origin, source: source) else { continue }
                graph.link(id, other, rel)
            }
        }
        if let estimate { graph.estimate(id, level: min(1, max(0, estimate))) }
        EventBus.publish(.memoryChanged(MemoryChange(kind: .updated, ids: ["c\(id)"], summary: name, conversationID: source)))
        return id
    }

    func get(_ id: String) -> Memory? { resolve(id).flatMap { $0.0.get($0.1) } }
    func concept(_ id: String) -> Concept? { if case .concept(let n) = ref(id) { return graph?.concept(n) }; return nil }
    func exists(_ id: String) -> Bool { get(id).map { _ in true } ?? (concept(id) != nil) }
    func history(_ id: String) -> [MemoryHistoryEntry] { resolve(id).map { $0.0.history($0.1) } ?? [] }

    func update(_ id: String, content: String? = nil, importance: Double? = nil, kind: MemoryKind? = nil, subject: String? = nil,
                concept: String? = nil, source: String? = nil) {
        switch ref(id) {
        case .memory(let st, let n):
            var cid: Int64??
            if let concept, st === learner, let graph { cid = .some(concept.isEmpty ? nil : graph.upsert(name: concept, subjects: subject.map { [$0] } ?? [])) }
            st.update(n, content: content, importance: importance, kind: kind, subject: subject, conceptID: cid, source: source)
        case .concept(let n):
            graph?.update(n, name: content, subjects: subject.map { [$0] })
        case nil: return
        }
        EventBus.publish(.memoryChanged(MemoryChange(kind: .updated, ids: [id], summary: content)))
    }

    /// A resolved misconception or achieved goal is archived (kept in history), not forgotten.
    func resolveItem(_ id: String, source: String? = nil) {
        guard let (st, n) = resolve(id) else { return }
        let kind = st.get(n)?.kind
        st.archive(n, status: kind == .goal ? "achieved" : "resolved", source: source)
        EventBus.publish(.memoryChanged(MemoryChange(kind: .deleted, ids: [id])))
    }

    /// Soft removal with history (used by automatic passes, so a wrong call can be undone).
    func archiveItem(_ id: String, status: String, source: String? = nil) {
        guard let (st, n) = resolve(id) else { return }
        st.archive(n, status: status, source: source)
        EventBus.publish(.memoryChanged(MemoryChange(kind: .deleted, ids: [id])))
    }

    func delete(_ id: String) {
        switch ref(id) {
        case .memory(let st, let n): st.delete(n)
        case .concept(let n): graph?.delete(n); learner.reassignConcept(from: [n], to: nil)
        case nil: return
        }
        EventBus.publish(.memoryChanged(MemoryChange(kind: .deleted, ids: [id])))
    }

    func mergeConcepts(into: String, from: [String]) {
        guard case .concept(let target) = ref(into), let graph else { return }
        let src = from.compactMap { if case .concept(let n) = ref($0) { return n }; return nil }.filter { $0 != target }
        graph.merge(into: target, from: src)
        learner.reassignConcept(from: src, to: target)
        EventBus.publish(.memoryChanged(MemoryChange(kind: .updated, ids: [into])))
    }

    func markUsed(_ ids: [String]) {
        var l: [Int64] = [], f: [Int64] = []
        for id in ids { if let (st, n) = resolve(id) { if st === learner { l.append(n) } else { f.append(n) } } }
        learner.markUsed(l); folder.markUsed(f)
    }

    func all() -> [Memory] { learner.all() + folder.all() }
    /// Memories plus concept nodes (what the learner sees in the Memory screen).
    func count() -> Int { learner.count() + folder.count() + (graph?.count() ?? 0) }
    func deleteAll() { learner.deleteAll(); folder.deleteAll(); EventBus.publish(.memoryChanged(MemoryChange(kind: .deleted))) }

    @discardableResult
    func maintenance() -> MemoryStore.MaintenanceReport {
        graph?.syncMastery()
        let a = learner.maintenance(), b = folder.maintenance()
        // Concepts that share an alias key after renames are merged.
        return .init(decayed: a.decayed + b.decayed, archived: a.archived + b.archived, merged: a.merged + b.merged)
    }

    // MARK: Retrieval

    /// Explicit search (the `memory` tool and the Memory screen). `minScore` is a relevance threshold.
    func search(_ query: String, limit: Int = 8, kinds: [MemoryKind]? = nil, minScore: Double = MemoryTuning.searchThreshold,
                queryVector: [Float]? = nil) -> [Memory] {
        let qv = queryVector ?? Embedder.shared.vector(query).map(Embedder.normalized)
        let routed = graph?.route(query) ?? [:]
        let merged = learner.search(query, limit: limit, kinds: kinds, minRelevance: minScore, conceptBoost: routed, queryVector: qv)
            + folder.search(query, limit: limit, kinds: kinds, minRelevance: minScore, queryVector: qv)
        return Array(merged.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Concepts mentioned by the text, strongest first.
    func concepts(matching text: String, limit: Int = 4) -> [Concept] {
        guard let graph else { return [] }
        return graph.route(text).sorted { $0.value > $1.value }.prefix(limit).compactMap { graph.concept($0.key) }
    }

    struct Recall { var memories: [Memory]; var concepts: [Concept]; var note: String; var ids: [String] { memories.map(\.id) + concepts.map(\.id) } }

    private static let pastCue = try! NSRegularExpression(pattern: #"\b(last time|remember|previous(ly)?|earlier|before|we did|we covered|again|continue|pick up|where we left)\b"#, options: .caseInsensitive)

    /// Per-turn automatic recall: 0–2 items, only when clearly relevant and not already in the core block.
    func recall(_ message: String, core: String, maxItems: Int = 2) -> Recall {
        let text = String(message.prefix(1500))
        let qv = Embedder.shared.vector(text).map(Embedder.normalized)
        let routed = (graph?.route(text) ?? [:]).filter { $0.value >= 1 }
        let past = Self.pastCue.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        let th = MemoryTuning.recallThreshold
        var hits = (learner.search(text, limit: 6, minRelevance: th, conceptBoost: routed, queryVector: qv)
            + folder.search(text, limit: 4, minRelevance: th, queryVector: qv)).sorted { $0.score > $1.score }
        hits.removeAll { m in core.contains("[#\(m.id)]") || (m.kind == .episode && !past && m.relevance < 0.85) }
        var mems = Array(hits.prefix(maxItems))
        // A concept card when the message names a known concept with state worth knowing right now
        // (a weak prerequisite, an attached misconception not already in context, or "struggling").
        var cards: [Concept] = []
        if mems.count < maxItems, let graph,
           let c = routed.keys.compactMap({ graph.concept($0) }).max(by: { ($0.name.count, $1.rowid) < ($1.name.count, $0.rowid) }) {
            let weak = graph.prerequisites(of: c.rowid).contains { ($0.pKnown ?? 1) < 0.6 || $0.status == "struggling" }
            let mis = learner.memories(conceptID: c.rowid).filter { m in
                m.kind == .misconception && !core.contains("[#\(m.id)]") && !mems.contains(where: { $0.id == m.id })
            }
            if weak || !mis.isEmpty || c.status == "struggling" { cards.append(c) }
        }
        if mems.count + cards.count > maxItems { mems = Array(mems.prefix(maxItems - cards.count)) }
        guard !mems.isEmpty || !cards.isEmpty else { return Recall(memories: [], concepts: [], note: "") }
        var lines = mems.map { "- [#\($0.id)] (\($0.kind.rawValue)) \(MemoryText.clip($0.content, 220))" }
        lines += cards.map { "- " + conceptLine($0, detail: true) }
        return Recall(memories: mems, concepts: cards, note: "<context>\nRelevant memory:\n" + lines.joined(separator: "\n") + "\n</context>")
    }

    /// "chain rule [#c4] (calculus) 40% (2/5); needs: derivatives 92%; watch: #9 …"
    func conceptLine(_ c: Concept, detail: Bool) -> String {
        var s = "\(c.name) [#c\(c.rowid)]"
        if !c.subjects.isEmpty { s += " (\(c.subjects.joined(separator: ", ")))" }
        s += " \(c.masteryLabel)"
        guard detail, let graph else { return s }
        let pre = graph.prerequisites(of: c.rowid)
        if !pre.isEmpty { s += "; needs: " + pre.prefix(4).map { "\($0.name) \($0.masteryLabel)" }.joined(separator: ", ") }
        let deps = graph.dependents(of: c.rowid)
        if !deps.isEmpty { s += "; leads to: " + deps.prefix(3).map(\.name).joined(separator: ", ") }
        let mis = learner.memories(conceptID: c.rowid).filter { $0.kind == .misconception }
        if !mis.isEmpty { s += "; watch: " + mis.prefix(2).map { "[#\($0.id)] \(MemoryText.clip($0.content, 120))" }.joined(separator: " ") }
        return s
    }

    // MARK: Core block

    /// The always-in-context learner model. Built once per lesson (prompt-cache stable), hard-capped at `maxChars`
    /// (~4 chars/token → ≤ 1.3k tokens). Sections are filled in priority order, rendered in reading order.
    func coreBlock(maxChars: Int = 5200) -> String {
        graph?.syncMastery()
        func items(_ ms: [Memory]) -> [String] {
            ms.map { "- [#\($0.id)] \(($0.subject ?? "").isEmpty ? "" : "(\($0.subject!)) ")\(MemoryText.clip($0.content, 200))" }
        }
        var map: [String] = []
        if let graph {
            for (subject, cs) in graph.subjects().prefix(6) {
                let shown = cs.prefix(6).map { c -> String in
                    var t = "\(c.name) #c\(c.rowid)" + (c.pKnown == nil && c.status == nil ? "" : " \(c.masteryLabel)")
                    if (c.pKnown ?? 0) >= 0.95 { t += " ✓" }
                    return t
                }
                map.append("- \(subject): " + shown.joined(separator: " · ") + (cs.count > 6 ? " · +\(cs.count - 6) more" : ""))
            }
            for l in graph.crossSubjectLinks(limit: 3) {
                map.append("- link \(l.a) ↔ \(l.b): " + l.via.prefix(2).map { MemoryText.clip($0, 70) }.joined(separator: "; "))
            }
        }
        let df = DateFormatter(); df.dateStyle = .medium
        let episodes = (learner.recentEpisodes(limit: 2) + folder.recentEpisodes(limit: 3)).sorted { $0.createdAt > $1.createdAt }.prefix(3)
        let folderFacts = folder.top(kinds: MemoryKind.allCases.filter { $0 != .episode }, limit: 8)
        // (title, lines) in reading order with a fill priority.
        var sections: [(order: Int, prio: Int, title: String, lines: [String])] = [
            (0, 0, "Profile", items(learner.top(kinds: [.profile], limit: 8))),
            (1, 1, "Goals", items(learner.top(kinds: [.goal], limit: 6))),
            (2, 3, "Learning preferences", items(learner.top(kinds: [.preference], limit: 6))),
            (3, 4, "Learning map (subject: concept mastery)", map),
            (4, 2, "Watch for (misconceptions)", items(learner.top(kinds: [.misconception], limit: 6))),
            (5, 6, "Other facts", items(learner.top(kinds: [.fact, .knowledge], limit: 5))),
            (6, 5, "About this folder", folderFacts.map { "- [#\($0.id)] (\($0.kind.rawValue)) \(MemoryText.clip($0.content, 200))" }),
            (7, 7, "Recent lessons", episodes.reversed().map { "- \(df.string(from: $0.createdAt))\($0.scope == .folder ? " (this folder)" : ""): \(MemoryText.clip($0.content, 240))" }),
        ]
        sections.removeAll { $0.lines.isEmpty }
        guard !sections.isEmpty else { return "" }
        var budget = maxChars
        var kept: [Int: [String]] = [:]
        for s in sections.sorted(by: { $0.prio < $1.prio }) {
            budget -= s.title.count + 5
            var ls: [String] = []
            for l in s.lines where l.count + 1 <= budget { ls.append(l); budget -= l.count + 1 }
            if !ls.isEmpty { kept[s.order] = ls } else { budget += s.title.count + 5 }
        }
        return sections.sorted { $0.order < $1.order }.compactMap { s in
            kept[s.order].map { "## \(s.title)\n" + $0.joined(separator: "\n") }
        }.joined(separator: "\n\n")
    }
}
