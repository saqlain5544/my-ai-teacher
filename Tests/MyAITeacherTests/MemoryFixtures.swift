import XCTest
@testable import MyAITeacher

/// A throwaway learner DB + folder workspace (never touches the real app data).
final class MemoryFixture {
    let dir: URL
    let hub: MemoryHub
    let learnerDB: Database
    let study: StudyStore

    init() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("memfx-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        learnerDB = try Database(path: dir.appendingPathComponent("learner.sqlite").path)
        try learnerDB.script(Schema_.sql)
        let ws = try Workspace(url: dir)
        hub = MemoryHub(learner: MemoryStore(db: learnerDB, scope: .learner), folder: ws.memory)
        study = StudyStore(db: learnerDB)
    }
    deinit { try? FileManager.default.removeItem(at: dir) }
}

/// Labelled retrieval set: a realistic multi-subject learner and queries with the memories that SHOULD be recalled.
enum LabeledSet {
    struct Item { var key: String; var kind: MemoryKind; var content: String; var subject: String?; var concept: String?; var scope: MemoryScope = .learner }

    static let items: [Item] = [
        .init(key: "p1", kind: .profile, content: "Second-year computer science undergraduate", subject: "computer science", concept: nil),
        .init(key: "p2", kind: .profile, content: "Native Urdu speaker, fluent in English, learning Arabic", subject: nil, concept: nil),
        .init(key: "pr1", kind: .preference, content: "Prefers visual explanations with diagrams before formulas", subject: nil, concept: nil),
        .init(key: "pr2", kind: .preference, content: "Likes short daily practice sessions of about 20 minutes", subject: nil, concept: nil),
        .init(key: "g1", kind: .goal, content: "Wants to pass the AP Calculus BC exam in May", subject: "calculus", concept: nil),
        .init(key: "g2", kind: .goal, content: "Wants to read classical Arabic poetry such as al-Mutanabbi in the original", subject: "arabic", concept: nil),
        .init(key: "g3", kind: .goal, content: "Building a personal website with React and TypeScript", subject: "programming", concept: nil),
        .init(key: "m1", kind: .misconception, content: "Forgets to multiply by the derivative of the inner function when applying the chain rule", subject: "calculus", concept: "chain rule"),
        .init(key: "m2", kind: .misconception, content: "Confuses the signs of velocity and acceleration in projectile motion", subject: "physics", concept: "projectile motion"),
        .init(key: "m3", kind: .misconception, content: "Assumes assigning a Python list makes a copy instead of a shared reference", subject: "python", concept: "python lists"),
        .init(key: "m4", kind: .misconception, content: "Mixes up the Arabic sun and moon letters when pronouncing the definite article al-", subject: "arabic", concept: "sun and moon letters"),
        .init(key: "m5", kind: .misconception, content: "Believes correlation implies causation", subject: "statistics", concept: "correlation"),
        .init(key: "m6", kind: .misconception, content: "Drops the negative sign when distributing subtraction over brackets", subject: "algebra", concept: "distributive law"),
        .init(key: "m7", kind: .misconception, content: "Confuses long and short syllables when scanning Arabic poetry meters", subject: "arabic", concept: "arabic prosody"),
        .init(key: "f1", kind: .fact, content: "Uses VS Code on a MacBook for programming", subject: nil, concept: nil),
        .init(key: "f2", kind: .fact, content: "Plays chess competitively and enjoys strategy analogies", subject: nil, concept: nil),
        .init(key: "f3", kind: .fact, content: "Works part-time as a barista on weekends", subject: nil, concept: nil),
        .init(key: "f4", kind: .fact, content: "Fascinated by black holes and astrophysics documentaries", subject: nil, concept: nil),
        .init(key: "f5", kind: .fact, content: "Revises with a friend who is preparing for the same calculus exam", subject: "calculus", concept: nil),
        .init(key: "k1", kind: .knowledge, content: "Comfortable differentiating polynomials and trig functions", subject: "calculus", concept: nil),
        .init(key: "k2", kind: .knowledge, content: "Can write simple recursive functions in Python", subject: "python", concept: nil),
        .init(key: "k3", kind: .knowledge, content: "Knows the 28 letters of the Arabic alphabet and their forms", subject: "arabic", concept: nil),
        .init(key: "k4", kind: .knowledge, content: "Understands Newton's three laws of motion", subject: "physics", concept: nil),
        .init(key: "k5", kind: .knowledge, content: "Solves quadratic equations by factoring", subject: "algebra", concept: nil),
        .init(key: "e1", kind: .episode, content: "Covered the chain rule with three worked examples; still slow on nested functions", subject: nil, concept: nil, scope: .folder),
        .init(key: "e2", kind: .episode, content: "Practised scansion of a line by al-Mutanabbi; poetry meters are still shaky", subject: nil, concept: nil, scope: .folder),
        .init(key: "ff1", kind: .fact, content: "This folder contains the learner's physics lab reports", subject: "physics", concept: nil, scope: .folder),
    ]

    /// (query, keys that should be recalled). Empty = nothing should be injected.
    static let queries: [(String, Set<String>)] = [
        ("What is the capital of Australia?", []),
        ("How do I differentiate sin(x^2) with the chain rule?", ["m1", "k1"]),
        ("Can you explain the chain rule again?", ["m1", "e1"]),
        ("Why is the velocity negative at the top of a projectile's path?", ["m2"]),
        ("I copied a list in Python and changing one changed the other", ["m3"]),
        ("How do I pronounce al-shams? Is the l silent?", ["m4"]),
        ("Help me scan this line of Arabic poetry", ["m7", "e2", "g2"]),
        ("Ice cream sales correlate with drowning, so does ice cream cause drowning?", ["m5"]),
        ("Simplify 3 - (x - 2) for me", ["m6"]),
        ("Tell me a joke", []),
        ("What's the weather like on Mars?", []),
        ("Recommend a documentary about black holes", ["f4"]),
        ("Let's practise for my calculus exam", ["g1", "f5"]),
        ("How do React hooks work?", ["g3"]),
        ("Explain photosynthesis", []),
        ("Who won the 1998 football world cup?", []),
        ("Teach me a good chess opening", ["f2"]),
        ("What's a good editor setup for TypeScript?", ["f1", "g3"]),
        ("How do I write a recursive Fibonacci function in Python?", ["k2"]),
        ("What are Newton's laws?", ["k4"]),
        ("Translate 'good morning' into French", []),
        ("Solve the quadratic x^2 - 5x + 6 = 0", ["k5"]),
        ("What does the Arabic letter ba sound like?", ["k3"]),
        ("What's the boiling point of water in Kelvin?", []),
        ("Can you check my physics lab report on pendulums?", ["ff1"]),
        ("What did we do last time in Arabic poetry?", ["e2", "m7", "g2"]),
        ("List the capitals of European countries", []),
        ("How many weeks until my calculus exam in May?", ["g1"]),
        ("Write a haiku about autumn", []),
        ("What is 17 times 23?", []),
        ("Explain how a neural network learns", []),
        ("What year did World War II end?", []),
    ]

    /// Held-out queries (never used for calibration) — reported separately.
    static let heldOut: [(String, Set<String>)] = [
        ("Integrate x^3 from 0 to 2", []),
        ("Is my chain rule working right for e^(3x)?", ["m1"]),
        ("A ball is thrown upward at 20 m/s, find its acceleration at the top", ["m2"]),
        ("Why did my Python function modify the list I passed in?", ["m3"]),
        ("Give me practice reading Arabic poems by al-Mutanabbi", ["g2", "e2"]),
        ("What is the difference between correlation and causation?", ["m5"]),
        ("What's the best pizza topping?", []),
        ("Plan my revision for the AP Calculus BC exam", ["g1", "f5"]),
        ("Set up TypeScript with React for my website", ["g3"]),
        ("How do the Arabic sun letters change pronunciation?", ["m4"]),
        ("Who painted the Mona Lisa?", []),
        ("Explain the French revolution briefly", []),
        ("How do I debug a segmentation fault in C?", []),
        ("Compare black holes and neutron stars", ["f4"]),
    ]

    /// Loads the set; returns key → model id.
    static func load(into hub: MemoryHub) -> [String: String] {
        let g = hub.graph!
        hub.saveConcept(name: "derivatives", subjects: ["calculus"])
        hub.saveConcept(name: "chain rule", subjects: ["calculus"], prerequisites: ["derivatives"])
        hub.saveConcept(name: "projectile motion", subjects: ["physics"], prerequisites: ["derivatives"])
        hub.saveConcept(name: "arabic alphabet", subjects: ["arabic"])
        hub.saveConcept(name: "arabic prosody", subjects: ["arabic", "poetry"], prerequisites: ["arabic alphabet"])
        _ = g
        var ids: [String: String] = [:]
        for it in items {
            let r = hub.add(kind: it.kind, content: it.content, subject: it.subject, importance: 0.6, origin: "explicit",
                            scope: it.scope, concept: it.concept)
            precondition(!r.id.isEmpty, "fixture rejected: \(it.content)")
            ids[it.key] = r.id
        }
        return ids
    }
}
