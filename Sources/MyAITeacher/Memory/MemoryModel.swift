import Foundation
import NaturalLanguage
import Accelerate

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
    /// Kinds that are always summarised in the core block (so per-turn recall skips them).
    var isCore: Bool { [.profile, .preference, .goal].contains(self) }
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
    var origin: String          // explicit | inferred | reflection | consolidation
    var source: String?
    var createdAt: Date
    var updatedAt: Date
    var lastUsedAt: Date?
    var useCount: Int
    var conceptID: Int64? = nil
    /// How many times this fact was (re)observed — merges increment it.
    var evidence: Int = 1
    var score: Double = 0
    /// Pure query relevance (0…1), before importance/recency boosts.
    var relevance: Double = 0
    /// Model-facing id: "12" for learner memories, "f12" for folder memories.
    var id: String { scope == .learner ? String(rowid) : "f\(rowid)" }
}

/// A node of the learner model: a concept/skill with subject tags, cached BKT mastery and graph edges.
struct Concept: Identifiable, Hashable, Sendable {
    var rowid: Int64
    var name: String
    var subjects: [String]
    var summary: String?
    /// struggling | learning | solid — a qualitative estimate when no quiz evidence exists.
    var status: String?
    /// Latest BKT estimate from `StudyStore.mastery` (nil = no evidence yet).
    var pKnown: Double?
    var attempts: Int
    var correct: Int
    var evidence: Int
    var origin: String
    var source: String?
    var createdAt: Date
    var updatedAt: Date
    /// When mastery evidence last arrived (a quiz/practice answer).
    var masteryAt: Date? = nil
    var id: String { "c\(rowid)" }
    var masteryLabel: String {
        if let p = pKnown { return "\(Int((p * 100).rounded()))%" + (attempts > 0 ? " (\(correct)/\(attempts))" : "") }
        return status ?? "seen"
    }

    /// Mastery now, with forgetting: since the last practice the estimate decays (never below 40% of what was learned),
    /// and every correct recall lengthens the half-life — the spacing effect (≈5 days new, ≈1.5 years after 8 recalls).
    func effectiveMastery(at now: Date = Date()) -> Double? {
        guard let p = pKnown else { return nil }
        guard let at = masteryAt else { return p }
        let days = max(0, now.timeIntervalSince(at) / 86_400)
        let halfLife = 5.0 * pow(1.8, Double(min(correct, 8)))
        return p * (0.4 + 0.6 * pow(0.5, days / halfLife))
    }
    /// Was solid, is slipping: worth a quick retrieval question.
    func isFading(at now: Date = Date()) -> Bool { (pKnown ?? 0) >= 0.8 && (effectiveMastery(at: now) ?? 1) < 0.7 }
    /// Solid enough to build on.
    func isSolid(at now: Date = Date()) -> Bool { (effectiveMastery(at: now) ?? (status == "solid" ? 0.85 : 0)) >= 0.8 }
}

enum ConceptRelation: String, Codable, CaseIterable, Sendable {
    case prerequisite = "prereq", related, partOf = "part_of"
    init?(loose s: String) {
        switch s.lowercased() {
        case "prereq", "prerequisite", "prerequisites", "requires", "needs": self = .prerequisite
        case "related", "related_to", "relates": self = .related
        case "part_of", "partof", "part": self = .partOf
        default: return nil
        }
    }
}

struct MemoryHistoryEntry: Hashable, Sendable {
    var content: String
    var change: String
    var source: String?
    var date: Date
}

/// Outcome of a write. `id` is empty when the write was rejected.
struct MemoryWriteResult: Sendable {
    enum Status: String, Sendable { case added, merged, rejected }
    var id: String
    var status: Status
    var reason: String? = nil
    /// Similar (not duplicate) memories — the caller may want to update one of them instead.
    var similar: [String] = []
    var merged: Bool { status == .merged }
    var rejected: Bool { status == .rejected }
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
    static func normalized(_ v: [Float]) -> [Float] {
        var n: Float = 0
        vDSP_svesq(v, 1, &n, vDSP_Length(v.count))
        n = n.squareRoot()
        guard n > 0 else { return v }
        var out = [Float](repeating: 0, count: v.count)
        var inv = 1 / n
        vDSP_vsmul(v, 1, &inv, &out, 1, vDSP_Length(v.count))
        return out
    }
    static func dot(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count else { return 0 }
        var r: Float = 0
        vDSP_dotpr(a, 1, b, 1, &r, vDSP_Length(a.count))
        return r
    }
}

/// Random-hyperplane LSH over normalised embeddings: 8 bands × 10 bits. Two vectors with cosine ≥ 0.93 share
/// at least one band with p ≈ 0.93, so near-duplicate checks only verify a handful of candidates.
enum VectorLSH {
    static let bands = 8, bits = 10
    nonisolated(unsafe) private static var planes: [[Float]] = []
    private static let lock = NSLock()

    private static func hyperplanes(dim: Int) -> [[Float]] {
        lock.lock(); defer { lock.unlock() }
        if planes.count == bands * bits, planes.first?.count == dim { return planes }
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> Float {   // SplitMix64 → uniform(-1, 1); deterministic across launches
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            z ^= z >> 31
            return Float(Double(z >> 11) / Double(1 << 53)) * 2 - 1
        }
        planes = (0..<(bands * bits)).map { _ in (0..<dim).map { _ in next() } }
        return planes
    }

    static func keys(_ v: [Float]) -> [Int64] {
        let p = hyperplanes(dim: v.count)
        return (0..<bands).map { b in
            var key: Int64 = 0
            for i in 0..<bits where Embedder.dot(v, p[b * bits + i]) >= 0 { key |= 1 << Int64(i) }
            return Int64(b) << 32 | key
        }
    }
}
