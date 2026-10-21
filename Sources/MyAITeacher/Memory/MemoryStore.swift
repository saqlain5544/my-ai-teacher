import Foundation
import NaturalLanguage

enum MemoryKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case profile, preference, goal, knowledge, misconception, episode, fact
    var id: String { rawValue }
    var title: String {
        switch self {
        case .profile: "About me"
        case .preference: "Learning preferences"
        case .goal: "Goals"
        case .knowledge: "What I know"
        case .misconception: "Misconceptions"
        case .episode: "Lesson history"
        case .fact: "Other facts"
        }
    }
    var symbol: String {
        switch self {
        case .profile: "person.crop.circle"
        case .preference: "slider.horizontal.3"
        case .goal: "flag.checkered"
        case .knowledge: "brain"
        case .misconception: "exclamationmark.triangle"
        case .episode: "clock.arrow.circlepath"
        case .fact: "note.text"
        }
    }
}

/// `learner` memories follow the learner everywhere (global DB); `folder` memories live in `<folder>/.teacher`.
enum MemoryScope: String, Codable, Sendable { case learner, folder }

struct Memory: Identifiable, Hashable, Sendable {
    var rowid: Int64
    var scope: MemoryScope
    var kind: MemoryKind
    var subject: String?
    var content: String
    var importance: Double
    var confidence: Double
    var origin: String          // explicit | inferred | reflection
    var source: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var score: Double = 0
    /// Pure query relevance (0…1), before importance/recency boosts.
    var relevance: Double = 0
    /// Model-facing id: "12" for learner memories, "f12" for folder memories.
    var id: String { scope == .learner ? String(rowid) : "f\(rowid)" }
}

/// On-device sentence embeddings (Apple NaturalLanguage) — free, private, ~1 ms per sentence.
final class Embedder: @unchecked Sendable {
    static let shared = Embedder()
    private let lock = NSLock()
    private var model: NLEmbedding?
    private var loaded = false

    /// NLEmbedding is not thread-safe (concurrent calls crash inside BNNS), so every call is serialised.
    func vector(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { model = NLEmbedding.sentenceEmbedding(for: .english); loaded = true }
        guard let model, let v = model.vector(for: String(text.prefix(2000))) else { return nil }
        return v.map { Float($0) }
    }

    static func encode(_ v: [Float]) -> Data { v.withUnsafeBufferPointer { Data(buffer: $0) } }
    static func decode(_ d: Data) -> [Float] { d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) } }
    static func cosine(_ a: [Float], _ b: [Float]) -> Double {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, na: Float = 0, nb: Float = 0
        for i in 0..<a.count { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        let d = (na.squareRoot() * nb.squareRoot())
        return d > 0 ? Double(dot / d) : 0
    }
}

/// One memory table: hybrid BM25 + vector retrieval, importance × recency ranking, dedup on write.
final class MemoryStore: @unchecked Sendable {
    let db: Database
    let scope: MemoryScope
    init(db: Database, scope: MemoryScope) { self.db = db; self.scope = scope }

    private func row(_ r: Row) -> Memory? {
        guard let id = r.int("id"), let k = r.string("kind").flatMap(MemoryKind.init(rawValue:)), let c = r.string("content") else { return nil }
        return Memory(rowid: Int64(id), scope: scope, kind: k, subject: r.string("subject"), content: c, importance: r.double("importance") ?? 0.5,
                      confidence: r.double("confidence") ?? 0.8, origin: r.string("origin") ?? "inferred", source: r.string("source"),
                      createdAt: r.date("created_at") ?? Date(), updatedAt: r.date("updated_at") ?? Date(), lastUsedAt: r.date("last_used_at"),
                      useCount: r.int("use_count") ?? 0)
    }

    func all() -> [Memory] {
        ((try? db.query("SELECT * FROM memories WHERE archived=0 ORDER BY kind, importance DESC, updated_at DESC")) ?? []).compactMap(row)
    }
    func count() -> Int { (try? db.query("SELECT COUNT(*) AS n FROM memories WHERE archived=0").first?.int("n")) ?? 0 }
    func get(_ id: Int64) -> Memory? { (try? db.query("SELECT * FROM memories WHERE id=?", id))?.first.flatMap(row) }

    @discardableResult
    func add(kind: MemoryKind, content: String, subject: String?, importance: Double, origin: String, source: String?) -> (rowid: Int64, merged: Bool) {
        let content = Self.clean(content)
        let vec = Embedder.shared.vector(content)
        if let vec {
            let rows = (try? db.query("SELECT id, content, embedding, importance FROM memories WHERE archived=0 AND kind=?", kind.rawValue)) ?? []
            for r in rows {
                guard let e = r.data("embedding"), !e.isEmpty else { continue }
                let sim = Embedder.cosine(vec, Embedder.decode(e))
                if sim > 0.93 || r.string("content")?.lowercased() == content.lowercased() {
                    let id = Int64(r.int("id")!)
                    let imp = max(importance, r.double("importance") ?? 0)
                    let newContent = content.count >= (r.string("content")?.count ?? 0) ? content : r.string("content")!
                    try? db.execute("UPDATE memories SET content=?, importance=?, updated_at=?, embedding=? WHERE id=?",
                                    newContent, imp, Date(), Embedder.encode(Embedder.shared.vector(newContent) ?? vec), id)
                    return (id, true)
                }
            }
        }
        try? db.execute("""
            INSERT INTO memories(kind, subject, content, importance, origin, source, created_at, updated_at, embedding)
            VALUES(?,?,?,?,?,?,?,?,?)
            """, kind.rawValue, subject, content, min(1, max(0, importance)), origin, source, Date(), Date(), vec.map(Embedder.encode))
        return (db.lastInsertRowID, false)
    }

    /// Removes listing labels a model may echo back ("[#12] (profile, arabic) …").
    static func clean(_ s: String) -> String {
        s.replacingOccurrences(of: #"^\s*\[#?f?\d+\]\s*(\([^)]*\)\s*)?"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func update(_ id: Int64, content: String? = nil, importance: Double? = nil, kind: MemoryKind? = nil, subject: String? = nil) {
        guard var m = get(id) else { return }
        if let content, !Self.clean(content).isEmpty { m.content = Self.clean(content) }
        if let importance { m.importance = min(1, max(0, importance)) }
        if let kind { m.kind = kind }
        if let subject { m.subject = subject }
        try? db.execute("UPDATE memories SET content=?, importance=?, kind=?, subject=?, updated_at=?, embedding=? WHERE id=?",
                        m.content, m.importance, m.kind.rawValue, m.subject, Date(), Embedder.shared.vector(m.content).map(Embedder.encode), id)
    }

    func delete(_ id: Int64) { try? db.execute("DELETE FROM memories WHERE id=?", id) }
    func deleteAll() { try? db.execute("DELETE FROM memories") }
    func markUsed(_ ids: [Int64]) {
        let now = Date()
        for id in ids { try? db.execute("UPDATE memories SET use_count=use_count+1, last_used_at=? WHERE id=?", now, id) }
    }

    /// Hybrid retrieval: FTS5 finds keyword candidates, on-device embeddings find semantic ones.
    /// Relevance = 0.65 × cosine + 0.35 × query-term coverage (absolute, so one generic word can't score high).
    func search(_ query: String, limit: Int, kinds: [MemoryKind]?, minScore: Double) -> [Memory] {
        var candidates: [Int64: Memory] = [:]
        let terms = FTS.terms(query)
        let q = FTS.query(query)
        if !q.isEmpty, let rows = try? db.query("""
            SELECT m.* FROM memories_fts JOIN memories m ON m.id = memories_fts.rowid
            WHERE memories_fts MATCH ? AND m.archived=0 ORDER BY bm25(memories_fts) LIMIT 40
            """, q) {
            for r in rows { if let m = row(r) { candidates[m.rowid] = m } }
        }
        var cos: [Int64: Double] = [:]
        if let qv = Embedder.shared.vector(query), let rows = try? db.query("SELECT * FROM memories WHERE archived=0 AND embedding IS NOT NULL") {
            for r in rows {
                guard let m = row(r), let e = r.data("embedding") else { continue }
                let sim = Embedder.cosine(qv, Embedder.decode(e))
                cos[m.rowid] = sim
                if sim > 0.45 { candidates[m.rowid] = m }
            }
        }
        let now = Date()
        var scored: [Memory] = candidates.values.compactMap { m in
            if let kinds, !kinds.contains(m.kind) { return nil }
            let text = (m.content + " " + (m.subject ?? "")).lowercased()
            let coverage = terms.isEmpty ? 0 : Double(terms.filter { text.contains($0) }.count) / Double(terms.count)
            let rel = 0.65 * max(0, cos[m.rowid] ?? 0) + 0.35 * coverage
            let recency = exp(-now.timeIntervalSince(m.updatedAt) / 86400 / 60)
            var mm = m
            mm.relevance = rel
            mm.score = rel * 0.75 + m.importance * 0.15 + recency * 0.10
            return mm
        }
        scored.removeAll { $0.score < minScore }
        scored.sort { $0.score > $1.score }
        return Array(scored.prefix(limit))
    }

    /// Ordered memories for the always-in-context block.
    func coreMemories() -> (core: [Memory], episodes: [Memory]) {
        let core = ((try? db.query("""
            SELECT * FROM memories WHERE archived=0 AND kind IN ('profile','preference','goal','misconception')
            ORDER BY CASE kind WHEN 'profile' THEN 0 WHEN 'goal' THEN 1 WHEN 'preference' THEN 2 ELSE 3 END, importance DESC, updated_at DESC
            """)) ?? []).compactMap(row)
        let episodes = ((try? db.query("SELECT * FROM memories WHERE archived=0 AND kind='episode' ORDER BY created_at DESC LIMIT 3")) ?? []).compactMap(row)
        return (core, episodes)
    }

    func topFacts(limit: Int) -> [Memory] {
        ((try? db.query("SELECT * FROM memories WHERE archived=0 AND kind NOT IN ('episode') ORDER BY importance DESC, updated_at DESC LIMIT ?", limit)) ?? []).compactMap(row)
    }

    func maintenance() {
        let now = Date().timeIntervalSince1970
        try? db.execute("UPDATE memories SET importance = MAX(0.05, importance * 0.9) WHERE origin != 'explicit' AND kind IN ('fact','knowledge') AND COALESCE(last_used_at, updated_at) < ?", now - 90 * 86400)
        try? db.execute("UPDATE memories SET archived=1 WHERE archived=0 AND importance < 0.15 AND COALESCE(last_used_at, updated_at) < ?", now - 180 * 86400)
    }
}

/// Facade over learner-wide and folder memories. Ids are scope-tagged strings ("12", "f3").
final class MemoryHub: @unchecked Sendable {
    let learner: MemoryStore
    let folder: MemoryStore
    init(learner: MemoryStore, folder: MemoryStore) { self.learner = learner; self.folder = folder }

    func resolve(_ id: String) -> (MemoryStore, Int64)? {
        var s = id.trimmingCharacters(in: .whitespaces)
        if s.hasPrefix("#") { s.removeFirst() }
        if s.lowercased().hasPrefix("f"), let n = Int64(s.dropFirst()) { return (folder, n) }
        if let n = Int64(s) { return (learner, n) }
        return nil
    }

    func store(_ scope: MemoryScope) -> MemoryStore { scope == .learner ? learner : folder }

    @discardableResult
    func add(kind: MemoryKind, content: String, subject: String? = nil, importance: Double = 0.5, origin: String = "inferred",
             source: String? = nil, scope: MemoryScope = .learner) -> (id: String, merged: Bool) {
        let st = store(scope)
        let r = st.add(kind: kind, content: content, subject: subject, importance: importance, origin: origin, source: source)
        let id = scope == .learner ? String(r.rowid) : "f\(r.rowid)"
        EventBus.publish(.memoryChanged(MemoryChange(kind: r.merged ? .merged : .added, ids: [id], summary: content, conversationID: source)))
        return (id, r.merged)
    }

    func get(_ id: String) -> Memory? { resolve(id).flatMap { $0.0.get($0.1) } }

    func update(_ id: String, content: String? = nil, importance: Double? = nil, kind: MemoryKind? = nil, subject: String? = nil) {
        guard let (st, n) = resolve(id) else { return }
        st.update(n, content: content, importance: importance, kind: kind, subject: subject)
        EventBus.publish(.memoryChanged(MemoryChange(kind: .updated, ids: [id], summary: content)))
    }

    func delete(_ id: String) {
        guard let (st, n) = resolve(id) else { return }
        st.delete(n)
        EventBus.publish(.memoryChanged(MemoryChange(kind: .deleted, ids: [id])))
    }

    func markUsed(_ ids: [String]) {
        var l: [Int64] = [], f: [Int64] = []
        for id in ids { if let (st, n) = resolve(id) { if st === learner { l.append(n) } else { f.append(n) } } }
        learner.markUsed(l); folder.markUsed(f)
    }

    func all() -> [Memory] { learner.all() + folder.all() }
    func count() -> Int { learner.count() + folder.count() }
    func deleteAll() { learner.deleteAll(); folder.deleteAll(); EventBus.publish(.memoryChanged(MemoryChange(kind: .deleted))) }
    func maintenance() { learner.maintenance(); folder.maintenance() }

    func search(_ query: String, limit: Int = 8, kinds: [MemoryKind]? = nil, minScore: Double = 0.25) -> [Memory] {
        let merged = learner.search(query, limit: limit, kinds: kinds, minScore: minScore) + folder.search(query, limit: limit, kinds: kinds, minScore: minScore)
        return Array(merged.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// The always-in-context memory block. Built once per lesson so the prompt prefix stays cacheable.
    func coreBlock(maxChars: Int = 5000) -> String {
        let (core, episodes) = learner.coreMemories()
        let folderFacts = folder.topFacts(limit: 12)
        let folderEpisodes = folder.coreMemories().episodes
        guard !core.isEmpty || !episodes.isEmpty || !folderFacts.isEmpty else { return "" }
        var out = ""
        var current: MemoryKind?
        var misconceptions = 0
        for m in core {
            if m.kind == .misconception { misconceptions += 1; if misconceptions > 6 { continue } }
            if m.kind != current { out += "\n## \(m.kind.title)\n"; current = m.kind }
            let line = "- [#\(m.id)] \(m.subject.map { "(\($0)) " } ?? "")\(m.content)\n"
            if out.count + line.count > maxChars { break }
            out += line
        }
        if !folderFacts.isEmpty {
            out += "\n## About this folder\n"
            for m in folderFacts { out += "- [#\(m.id)] (\(m.kind.rawValue)) \(m.content)\n" }
        }
        let recent = (episodes + folderEpisodes).sorted { $0.createdAt > $1.createdAt }.prefix(4)
        if !recent.isEmpty {
            out += "\n## Recent lessons\n"
            let df = DateFormatter(); df.dateStyle = .medium
            for e in recent.reversed() { out += "- \(df.string(from: e.createdAt))\(e.scope == .folder ? " (this folder)" : ""): \(e.content)\n" }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
