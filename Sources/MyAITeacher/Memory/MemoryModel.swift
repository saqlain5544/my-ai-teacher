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
    /// The model's working memory grows with its input and malloc keeps it afterwards (2,000 characters in one call left
    /// ~80 MB in the app's footprint, 400 ~15 MB), so longer text is embedded in pieces and averaged: about as fast, and
    /// the mean ranks related memories at least as well as one long vector.
    static let pieceLength = 400

    /// NLEmbedding is not thread-safe (concurrent calls crash inside BNNS), so every call is serialised.
    func vector(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { model = NLEmbedding.sentenceEmbedding(for: .english); loaded = true }
        guard let model else { return nil }
        var sum: [Double]?, n = 0.0
        for p in Self.pieces(String(text.prefix(2000)), max: Self.pieceLength) {
            guard let v = model.vector(for: String(p)) else { continue }
            sum = sum.map { zip($0, v).map(+) } ?? v; n += 1
        }
        return sum?.map { Float($0 / n) }
    }

    /// Consecutive pieces of at most `max` characters, cut at a space when there is one.
    static func pieces(_ s: String, max: Int) -> [Substring] {
        var out: [Substring] = [], rest = Substring(s)
        while rest.count > max {
            let window = rest.prefix(max), cut = window.lastIndex(of: " ") ?? window.endIndex
            if cut > rest.startIndex { out.append(rest[..<cut]) }
            rest = rest[cut...].drop { $0 == " " }
        }
        if !rest.isEmpty { out.append(rest) }
        return out
    }

    /// Stored form: a one-byte tag, then the unit vector as int8 (×127) — a quarter of Float32, and the precision every
    /// comparison uses anyway. Blobs whose length is a multiple of 4 are the older Float32 form; they still decode.
    static func encode(_ v: [Float]) -> Data { stored(quantize(normalized(v))) }
    static func stored(_ q: [Int8]) -> Data { Data([1] + q.map { UInt8(bitPattern: $0) }) }
    static func dimension(_ blob: UnsafeRawBufferPointer) -> Int { blob.isEmpty ? 0 : blob.count % 4 == 0 ? blob.count / 4 : blob.count - 1 }
    /// A stored vector as int8 into `out`; all zeros (no evidence) when absent or of another dimension.
    @discardableResult
    static func decode(_ blob: UnsafeRawBufferPointer, into out: UnsafeMutableBufferPointer<Int8>) -> Bool {
        let n = out.count
        if blob.count == n + 1, blob.count % 4 != 0, blob[0] == 1 {
            UnsafeMutableRawBufferPointer(out).copyMemory(from: UnsafeRawBufferPointer(rebasing: blob[1...]))
            return true
        }
        if n > 0, blob.count == n * 4 {
            for (i, x) in quantize(normalized((0..<n).map { blob.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) })).enumerated() { out[i] = x }
            return true
        }
        out.update(repeating: 0)
        return false
    }
    static func decode(_ d: Data) -> [Int8] {
        d.withUnsafeBytes { b in
            var v = [Int8](repeating: 0, count: dimension(b))
            v.withUnsafeMutableBufferPointer { _ = decode(b, into: $0) }
            return v
        }
    }
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
    /// A unit vector as int8 (×127).
    static func quantize(_ v: [Float]) -> [Int8] { v.map { Int8(max(-127, min(127, ($0 * 127).rounded()))) } }
    /// Cosine of a unit float vector and a quantised one.
    /// (Accelerate: int8 → float into a stack buffer, then a vectorised dot product.)
    static func dot(_ a: [Float], _ b: [Int8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(b.count)
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: b.count) { tmp in
            vDSP_vflt8(b, 1, tmp.baseAddress!, 1, n)
            var r: Float = 0
            vDSP_dotpr(a, 1, tmp.baseAddress!, 1, &r, n)
            return r / 127
        }
    }
    /// Cosine of two quantised unit vectors.
    static func dot(_ a: [Int8], _ b: [Int8]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        let n = vDSP_Length(a.count)
        return withUnsafeTemporaryAllocation(of: Float.self, capacity: a.count * 2) { tmp in
            let x = tmp.baseAddress!, y = tmp.baseAddress! + a.count
            vDSP_vflt8(a, 1, x, 1, n); vDSP_vflt8(b, 1, y, 1, n)
            var r: Float = 0
            vDSP_dotpr(x, 1, y, 1, &r, n)
            return r / (127 * 127)
        }
    }
}
