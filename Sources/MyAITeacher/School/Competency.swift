import Foundation

/// The school is a curriculum-and-evidence system with an agent inside: a graph of competencies (what can be learned and
/// in what order), a learner model built from evidence per competency and skill (`SchoolStore`), a teaching policy that
/// changes how the same competency is taught at each level (`TeachingPolicy`), placement, courses and a transcript.
/// Level is a vector, not a label: a learner can be university-level at algorithms and school-level at concurrency.

/// How deep a competency is held. Not difficulty: what the learner can do with it.
enum Level: Int, Codable, CaseIterable, Comparable, Sendable, Identifiable {
    case school = 1, college, university, research, expert
    var id: Int { rawValue }
    static func < (a: Level, b: Level) -> Bool { a.rawValue < b.rawValue }

    var title: String {
        switch self { case .school: "School"; case .college: "College"; case .university: "University"; case .research: "Research"; case .expert: "Expert" }
    }
    /// What holding a competency at this level means, whatever the competency.
    var descriptor: String {
        switch self {
        case .school: "recognise it, explain it in concrete terms, trace it, modify working code with scaffolding"
        case .college: "apply it, analyse and debug with it, design small multi-part programs with moderate independence"
        case .university: "synthesise and evaluate trade-offs, read primary sources and real implementations, design under constraints and defend the choices"
        case .research: "find a gap in the literature, choose methods, produce a reproducible original contribution, critique and defend it"
        case .expert: "work at the frontier: set the problem, lead original work, review others at expert level"
        }
    }
    init?(name: String) {
        switch name.lowercased().trimmingCharacters(in: .whitespaces) {
        case "school", "beginner", "1": self = .school
        case "college", "intermediate", "2": self = .college
        case "university", "advanced", "undergraduate", "3": self = .university
        case "research", "phd", "graduate", "4": self = .research
        case "expert", "postdoc", "post-phd", "5": self = .expert
        default: return nil
        }
    }
    var next: Level? { Level(rawValue: rawValue + 1) }
    var previous: Level? { Level(rawValue: rawValue - 1) }
}

/// What a piece of evidence shows the learner can do with a competency.
enum Skill: String, Codable, CaseIterable, Sendable {
    case recall, explanation, tracing, application, debugging, design, transfer, communication
    /// Skills that show use rather than recognition: a level is demonstrated only with one of these among its evidence.
    var isUse: Bool { [.application, .debugging, .design, .transfer].contains(self) }
}

/// One node of the graph. Concepts transfer between languages; a language, library or toolchain node is an overlay on
/// the concepts it builds on (`transfers`), so knowing recursion in Python leaves only Zig's syntax and idioms to learn.
struct Competency: Codable, Sendable, Identifiable, Hashable {
    enum Kind: String, Codable, Sendable { case concept, language, library, toolchain, research }
    var id: String
    var title: String
    var kind: Kind = .concept
    var domain: String = "programming"
    var prereqs: [String] = []
    var transfers: [String] = []
    var aliases: [String] = []
    var misconceptions: [String] = []
    /// What the learner can do at each level, for this competency (the level's generic descriptor fills a gap).
    var outcomes: [Int: String] = [:]
    /// The canonical references to teach from.
    var sources: [String] = []
    /// A competency the agent proposed (a library, a new topic): validated by the app, marked as such.
    var proposed = false

    func outcome(_ l: Level) -> String { outcomes[l.rawValue] ?? l.descriptor }
}

/// A course: a coherent unit at one level with outcomes (its competencies at that level), prerequisites, workload and
/// the assessments that count for it. Completion is the app's to decide, from evidence.
struct Course: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var title: String
    var level: Level
    var summary: String
    var competencies: [String]
    var prereqs: [String] = []          // course ids
    var hours: Int
    var assessments: [String]           // quiz, unseen, lab, project, defence, exam, review, paper
    var program: String = "programming"
}

/// The graph: the built-in curriculum plus the competencies proposed in this learner's lessons.
struct CompetencyGraph: Sendable {
    let nodes: [String: Competency]
    let courses: [Course]

    static let builtIn = CompetencyGraph(nodes: Dictionary(uniqueKeysWithValues: Curriculum.competencies.map { ($0.id, $0) }), courses: Curriculum.courses)

    func with(_ extra: [Competency]) -> CompetencyGraph {
        var n = nodes
        for c in extra where n[c.id] == nil { n[c.id] = c }
        return CompetencyGraph(nodes: n, courses: courses)
    }

    subscript(_ id: String) -> Competency? { nodes[id] }
    func course(_ id: String) -> Course? { courses.first { $0.id.caseInsensitiveCompare(id) == .orderedSame } }

    /// The competency a concept's name refers to (its title, id or an alias), ignoring case and punctuation.
    func resolve(_ name: String) -> Competency? {
        let k = Self.key(name)
        guard !k.isEmpty else { return nil }
        if let c = nodes[name] ?? nodes[k] { return c }
        if let c = nodes.values.first(where: { Self.key($0.title) == k || Self.key($0.id) == k || $0.aliases.contains { Self.key($0) == k } }) { return c }
        // "recursion in Zig" → recursion; "Zig error unions" → zig.errors (a title or alias inside the name, longest first)
        let hits = nodes.values.flatMap { c in ([c.title] + c.aliases).map { (c, Self.key($0)) } }
            .filter { $0.1.count >= 5 && k.contains($0.1) }
            .sorted { $0.1.count > $1.1.count }
        return hits.first?.0
    }
    static func key(_ s: String) -> String {
        s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Every prerequisite of `id`, transitively, nearest first.
    func prerequisites(of id: String) -> [String] {
        var seen: [String] = [], queue = nodes[id]?.prereqs ?? []
        while let p = queue.first {
            queue.removeFirst()
            guard !seen.contains(p), nodes[p] != nil else { continue }
            seen.append(p)
            queue += nodes[p]?.prereqs ?? []
        }
        return seen
    }
    /// Whether adding `c` keeps the graph acyclic and its references known.
    func validates(_ c: Competency) -> String? {
        for p in c.prereqs + c.transfers where nodes[p] == nil { return "unknown competency `\(p)`" }
        if prerequisites(of: c.id).contains(c.id) || c.prereqs.contains(where: { prerequisites(of: $0).contains(c.id) }) { return "it would make a prerequisite cycle" }
        return nil
    }
    /// `ids` in an order where each comes after its prerequisites.
    func ordered(_ ids: [String]) -> [String] {
        var out: [String] = []
        func visit(_ id: String, _ depth: Int) {
            guard depth < 64, !out.contains(id) else { return }
            for p in nodes[id]?.prereqs ?? [] where ids.contains(p) { visit(p, depth + 1) }
            out.append(id)
        }
        ids.forEach { visit($0, 0) }
        return out
    }
}
