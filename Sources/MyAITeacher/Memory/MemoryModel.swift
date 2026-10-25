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

    /// Recent texts' vectors: the same query is embedded again by the turn's recall, the memory tool's search and a
    /// regenerated reply (~25 ms a piece, on the main thread for recall). Bounded; about 2 KB an entry.
    private var recent: [String: [Float]] = [:]
    private var recentOrder: [String] = []
    static let recentLimit = 128

    /// NLEmbedding is not thread-safe (concurrent calls crash inside BNNS), so every call is serialised.
    func vector(_ text: String) -> [Float]? {
        lock.lock(); defer { lock.unlock() }
        if let v = recent[text] { return v }
        if !loaded { model = NLEmbedding.sentenceEmbedding(for: .english); loaded = true }
        guard let model, Self.isLatinScript(text) else { return nil }
        var sum: [Double]?, n = 0.0
        for p in Self.pieces(String(text.prefix(2000)), max: Self.pieceLength) {
            guard let v = model.vector(for: String(p)) else { continue }
            sum = sum.map { zip($0, v).map(+) } ?? v; n += 1
        }
        guard let out = sum?.map({ Float($0 / n) }) else { return nil }
        if text.utf8.count <= 4_000 {
            if recent.count >= Self.recentLimit, let old = recentOrder.first { recent[old] = nil; recentOrder.removeFirst() }
            recent[text] = out; recentOrder.append(text)
        }
        return out
    }

    /// Apple ships sentence embeddings for English, French, German and Italian at different dimensions, and the store
    /// holds one model's vectors (English, 512). Text in another script is not a weak signal through it, it is noise:
    /// Arabic related and unrelated sentences both scored ~0.97 cosine, and the store's 0.55–0.9 range turned any such
    /// pair into *full* semantic evidence. Until a multilingual embedder is bundled, only Latin-script text gets a vector;
    /// everything else falls back to lexical/FTS matching — honest, instead of confidently wrong.
    static func isLatinScript(_ text: String) -> Bool {
        let sample = String(text.prefix(600))
        var letters = 0, latin = 0
        for u in sample.unicodeScalars where CharacterSet.letters.contains(u) {
            letters += 1
            if isLatin(u.value) { latin += 1 }
        }
        return letters >= 3 && latin * 5 >= letters * 4
    }
    private static func isLatin(_ v: UInt32) -> Bool {
        switch v {
        case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F, 0x1E00...0x1EFF, 0x2C60...0x2C7F, 0xA720...0xA7FF:
            return true
        default:
            return false
        }
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

    /// The model's vector size: what stored vectors must have (a blob of any other size is no vector). nil without a model.
    var dimension: Int? {
        lock.lock(); defer { lock.unlock() }
        if !loaded { model = NLEmbedding.sentenceEmbedding(for: .english); loaded = true }
        return model?.dimension
    }

    /// A unit vector as stored in `memories.vec`: int8 (×127), `dimension` bytes — a quarter of Float32, and the precision
    /// every comparison uses anyway. Older builds wrote Float32 into `embedding`; that column is left to them.
    static func int8(_ v: [Float]) -> Data { Data(quantize(normalized(v)).map { UInt8(bitPattern: $0) }) }
    /// A memory's vector as int8 into `out`. A Float32 `embedding` of the model's size (finite values) comes first: this
    /// version clears it whenever it writes `vec`, so one that is there was written by an older build — after us, if
    /// the learner went back to one, which leaves `vec` stale. Then `vec` of the model's size; otherwise all zeros (no
    /// evidence). False when there is none.
    @discardableResult
    static func decode(vec: UnsafeRawBufferPointer, legacy: UnsafeRawBufferPointer, into out: UnsafeMutableBufferPointer<Int8>) -> Bool {
        let n = out.count
        if n > 0, legacy.count == n * 4 {
            let f = (0..<n).map { legacy.loadUnaligned(fromByteOffset: $0 * 4, as: Float.self) }
            if f.allSatisfy(\.isFinite) {
                for (i, x) in quantize(normalized(f)).enumerated() { out[i] = x }
                return true
            }
        }
        if n > 0, vec.count == n {
            UnsafeMutableRawBufferPointer(out).copyMemory(from: vec)
            return true
        }
        out.update(repeating: 0)
        return false
    }
    static func decode(vec: Data?, legacy: Data?, dimension n: Int) -> [Int8]? {
        var out = [Int8](repeating: 0, count: n)
        let ok = (vec ?? Data()).withUnsafeBytes { v in (legacy ?? Data()).withUnsafeBytes { l in out.withUnsafeMutableBufferPointer { decode(vec: v, legacy: l, into: $0) } } }
        return ok ? out : nil
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
