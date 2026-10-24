import Foundation

/// One observation of what the learner can do: a competency, a skill, the level of the task, how it went, how much help
/// they had, and where it came from (which sets how much it counts). The school's record is these rows; levels,
/// course completion and grades are computed from them, never written by the agent.
struct Evidence: Sendable, Identifiable, Hashable {
    enum Outcome: String, Sendable, CaseIterable { case pass, partial, fail
        var score: Double { switch self { case .pass: 1; case .partial: 0.5; case .fail: 0 } }
    }
    /// Where evidence comes from, by how much it can be trusted: an unseen task or tests the learner's own code passes
    /// count fully; a practice question less; a self-report little.
    enum Source: String, Sendable, CaseIterable {
        case unseen, tests, review, defence, placement, quiz, practice, mastery, `self`
        var reliability: Double {
            switch self {
            case .unseen: 1.0; case .tests: 0.95; case .review: 0.9; case .defence: 0.9; case .placement: 0.8
            case .quiz: 0.75; case .practice: 0.6; case .mastery: 0.6; case .self: 0.3
            }
        }
        /// Summative: counts toward completing a course.
        var summative: Bool { [.unseen, .tests, .review, .defence].contains(self) }
    }
    var id: Int64 = 0
    var competency: String
    var skill: Skill
    var level: Level
    var outcome: Outcome
    var help: Help = .none
    var source: Source
    var note: String?
    var misconception: String?
    var conversationID: String?
    var at = Date()

    /// How much this row counts: its source's reliability, less with help (a solution, not at all), and — for weighing
    /// mixed results, where recent evidence should win — less with age. Age doesn't erase a level: it makes it due a re-check.
    func weight(now: Date = Date(), aged: Bool = true) -> Double {
        let helpFactor = help == .none ? 1 : help == .hint ? 0.35 : 0
        let days = max(0, now.timeIntervalSince(at) / 86400)
        return source.reliability * helpFactor * (aged ? pow(0.5, days / SchoolStore.halfLifeDays) : 1)
    }
}

/// What the evidence says about one competency: the level demonstrated, the level being worked toward, per-skill bests,
/// independence and the checks due.
struct Estimate: Sendable, Hashable {
    var competency: String
    /// The highest level held with enough reliable, unaided evidence across skills; nil before any.
    var level: Level?
    /// Evidence above `level` that is mixed: working toward it.
    var developing: Level?
    var confidence: Double          // 0…1, from how much evidence there is at `level`
    var skills: [Skill: Level]      // the best level each skill has passed at, unaided
    var independence: Double?       // share of passes that had no help
    var evidenceCount: Int
    var lastUnaided: Date?
    var misconceptions: [String]
    var recheckDue: Bool            // held, but not shown unaided for a while
    /// The highest level with one unaided pass on reliable evidence: shown once, not yet held.
    var shown: Level? = nil

    var line: String {
        if let level { return level.title + (developing.map { ", developing \($0.title.lowercased())" } ?? "") }
        if let shown { return "shown once at \(shown.title.lowercased()) level, not yet held" }
        return "not yet shown" + (developing.map { ", developing \($0.title.lowercased())" } ?? "")
    }
}

/// Who the learner is as a student: what they want, the track they aim for, the time they have, the evidence they want.
struct SchoolProfile: Codable, Sendable, Equatable {
    var goal: String = ""
    var track: Level = .college
    var hoursPerWeek: Int = 5
    var wants: [String] = []        // understanding | project | portfolio | certificate | research
    var languages: [String] = []
    var updatedAt = Date()
}

/// An adaptive placement: probes (competency, level) asked one at a time; each answer moves the next probe up or down.
struct Placement: Codable, Sendable, Equatable {
    struct Probe: Codable, Sendable, Equatable {
        var competency: String
        var level: Level
        var skill: Skill
        var outcome: String?        // pass | partial | fail once answered
        /// How many answers the learner had given in the lesson when it was handed out: judging it needs one more.
        var repliesAtAsk: Int? = nil
    }
    var id: String
    var targets: [String]
    var probes: [Probe] = []
    var queue: [String]             // competencies still to place, prerequisites first
    var startLevel: Level
    /// Placing for a course's prerequisites: no need to probe above their level.
    var ceiling: Level?
    var limit = Placement.maxProbes
    var done = false
    var createdAt = Date()
    static let maxProbes = 14
}

struct Enrollment: Sendable, Hashable {
    var course: String
    var status: String              // enrolled | completed | dropped
    var enrolledAt: Date
    var completedAt: Date?
    var grade: String?
}

/// The learner's school record, in the app's database (shared across folders, like mastery).
final class SchoolStore: @unchecked Sendable {
    static let halfLifeDays = 120.0
    static let recheckDays = 60.0
    let db: Database

    static let schema = """
    CREATE TABLE IF NOT EXISTS school_evidence(id INTEGER PRIMARY KEY AUTOINCREMENT, competency TEXT NOT NULL, skill TEXT NOT NULL,
        level INTEGER NOT NULL, outcome TEXT NOT NULL, help INTEGER NOT NULL DEFAULT 0, source TEXT NOT NULL, note TEXT,
        misconception TEXT, conversation_id TEXT, at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS school_evidence_c ON school_evidence(competency, at);
    CREATE TABLE IF NOT EXISTS school_kv(key TEXT PRIMARY KEY, value TEXT NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS school_competencies(id TEXT PRIMARY KEY, data TEXT NOT NULL, created_at REAL NOT NULL, conversation_id TEXT);
    CREATE TABLE IF NOT EXISTS school_enrollments(course TEXT PRIMARY KEY, status TEXT NOT NULL, enrolled_at REAL NOT NULL, completed_at REAL, grade TEXT);
    CREATE TABLE IF NOT EXISTS school_links(conversation_id TEXT PRIMARY KEY, competency TEXT, course TEXT, updated_at REAL NOT NULL);
    """

    init(db: Database) {
        self.db = db
        try? db.script(Self.schema)
    }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    // MARK: Graph

    /// The built-in curriculum and the competencies proposed in lessons.
    var graph: CompetencyGraph {
        let extra = ((try? db.query("SELECT data FROM school_competencies ORDER BY created_at")) ?? [])
            .compactMap { $0.data("data").flatMap { try? Self.dec.decode(Competency.self, from: $0) } }
        return CompetencyGraph.builtIn.with(extra)
    }

    /// Adds a competency the agent proposed, if the graph stays sound. Returns why not, or nil.
    func propose(_ c: Competency, conversationID: String?) -> String? {
        var c = c
        c.id = c.id.lowercased().trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
        c.proposed = true
        let g = graph
        guard !c.id.isEmpty, !c.title.isEmpty else { return "a competency needs an id and a title" }
        if g[c.id] != nil { return "`\(c.id)` already exists" }
        if let why = g.validates(c) { return why }
        guard let d = try? Self.enc.encode(c) else { return "couldn't store it" }
        db.run("INSERT INTO school_competencies(id, data, created_at, conversation_id) VALUES(?,?,?,?)", c.id, String(decoding: d, as: UTF8.self), Date(), conversationID)
        return nil
    }

    // MARK: Evidence

    @discardableResult
    func record(_ e: Evidence) -> Int64? {
        db.insert("INSERT INTO school_evidence(competency, skill, level, outcome, help, source, note, misconception, conversation_id, at) VALUES(?,?,?,?,?,?,?,?,?,?)",
                  e.competency, e.skill.rawValue, e.level.rawValue, e.outcome.rawValue, e.help.rawValue, e.source.rawValue, e.note, e.misconception, e.conversationID, e.at)
    }

    func evidence(_ competency: String? = nil, limit: Int = 2000) -> [Evidence] {
        let rows = (try? competency.map { try db.query("SELECT * FROM school_evidence WHERE competency = ? ORDER BY at DESC LIMIT ?", $0, limit) }
                    ?? db.query("SELECT * FROM school_evidence ORDER BY at DESC LIMIT ?", limit)) ?? []
        return rows.compactMap { r in
            guard let c = r.string("competency"), let s = r.string("skill").flatMap(Skill.init(rawValue:)), let l = r.int("level").flatMap(Level.init(rawValue:)),
                  let o = r.string("outcome").flatMap(Evidence.Outcome.init(rawValue:)), let src = r.string("source").flatMap(Evidence.Source.init(rawValue:)) else { return nil }
            return Evidence(id: Int64(r.int("id") ?? 0), competency: c, skill: s, level: l, outcome: o, help: Help(rawValue: r.int("help") ?? 0) ?? .none, source: src,
                            note: r.string("note"), misconception: r.string("misconception"), conversationID: r.string("conversation_id"), at: r.date("at") ?? Date())
        }
    }

    /// Evidence from the mastery funnel (quizzes, flashcards, the mastery tool, project reviews): written when the concept
    /// is one of the graph's, at the level the learner is working at there.
    func bridge(subject: String, concept: String, correct: Bool, help: Help, source: Evidence.Source = .mastery, skill: Skill = .recall,
                level: Level? = nil, conversationID: String? = nil, now: Date = Date()) {
        let g = graph
        guard let c = g.resolve(concept) ?? g.resolve(subject + " " + concept) else { return }
        let lv = level ?? target(c.id, graph: g)
        record(Evidence(competency: c.id, skill: skill, level: lv, outcome: correct ? .pass : .fail, help: help, source: source,
                        note: "\(subject) › \(concept)", conversationID: conversationID, at: now))
    }

    // MARK: The learner model

    /// What the evidence says about a competency. A level is held with ≥ 1.5 weight of evidence at it (passes above it
    /// count at it too), a weighted score ≥ 0.7, and passes in two skills, one of them a use (application, debugging,
    /// design or transfer).
    func estimate(_ competency: String, now: Date = Date()) -> Estimate { Self.estimate(competency, evidence(competency), now: now) }

    static func estimate(_ competency: String, _ rows: [Evidence], now: Date = Date()) -> Estimate {
        var held: Level?, developing: Level?, confidence = 0.0
        for l in Level.allCases {
            let at = rows.filter { $0.level == l || ($0.level > l && $0.outcome == .pass) }
            let mass = at.map { $0.weight(now: now, aged: false) }.reduce(0, +)
            guard mass > 0 else { break }
            let w = at.map { $0.weight(now: now) }
            let score = zip(at, w).reduce(0) { $0 + $1.0.outcome.score * $1.1 } / max(w.reduce(0, +), .leastNonzeroMagnitude)
            let passedSkills = Set(at.filter { $0.outcome == .pass && $0.help == .none }.map(\.skill))
            if mass >= 1.5, score >= 0.7, passedSkills.count >= 2, passedSkills.contains(where: \.isUse) {
                held = l; confidence = min(1, mass / 4); developing = nil
            } else {
                developing = l
                break
            }
        }
        var skills: [Skill: Level] = [:]
        for e in rows where e.outcome == .pass && e.help == .none { skills[e.skill] = max(skills[e.skill] ?? e.level, e.level) }
        let passes = rows.filter { $0.outcome != .fail }
        let lastUnaided = rows.filter { $0.outcome == .pass && $0.help == .none }.map(\.at).max()
        let mis = Array(Set(rows.prefix(40).compactMap(\.misconception))).sorted()
        return Estimate(competency: competency, level: held, developing: developing, confidence: confidence, skills: skills,
                        independence: passes.isEmpty ? nil : Double(passes.filter { $0.help == .none }.count) / Double(passes.count),
                        evidenceCount: rows.count, lastUnaided: lastUnaided, misconceptions: mis,
                        recheckDue: held != nil && (lastUnaided.map { now.timeIntervalSince($0) > recheckDays * 86400 } ?? true),
                        shown: rows.filter { $0.outcome == .pass && $0.help == .none && $0.source.reliability >= 0.75 }.map(\.level).max())
    }

    func estimates(now: Date = Date()) -> [String: Estimate] {
        Dictionary(grouping: evidence(limit: 20000), by: \.competency).mapValues { Self.estimate($0.first!.competency, $0, now: now) }
    }

    /// The level to teach a competency at: one above what's held (the zone of proximal development), not above the
    /// level of the course it's studied in or the learner's track, not below school.
    func target(_ competency: String, graph: CompetencyGraph? = nil, course: Course? = nil) -> Level {
        let e = estimate(competency)
        let cap = course?.level ?? profile?.track ?? .college
        let next = e.level.flatMap(\.next) ?? .school
        return min(max(next, .school), max(cap, e.level ?? .school))
    }

    // MARK: Profile, links

    var profile: SchoolProfile? {
        get { kv("profile").flatMap { try? Self.dec.decode(SchoolProfile.self, from: Data($0.utf8)) } }
        set { setKV("profile", newValue.flatMap { try? Self.enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }) }
    }
    private func kv(_ key: String) -> String? { (try? db.query("SELECT value FROM school_kv WHERE key = ?", key))?.first?.string("value") }
    private func setKV(_ key: String, _ value: String?) {
        if let value { db.run("INSERT INTO school_kv(key, value, updated_at) VALUES(?,?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value, updated_at=excluded.updated_at", key, value, Date()) }
        else { db.run("DELETE FROM school_kv WHERE key = ?", key) }
    }

    /// What a lesson is studying: a competency (and the course it's part of).
    func link(_ conversationID: String) -> (competency: String?, course: String?) {
        guard let r = (try? db.query("SELECT competency, course FROM school_links WHERE conversation_id = ?", conversationID))?.first else { return (nil, nil) }
        return (r.string("competency"), r.string("course"))
    }
    func setLink(_ conversationID: String, competency: String?, course: String?) {
        db.run("INSERT INTO school_links(conversation_id, competency, course, updated_at) VALUES(?,?,?,?) ON CONFLICT(conversation_id) DO UPDATE SET competency=COALESCE(excluded.competency, competency), course=COALESCE(excluded.course, course), updated_at=excluded.updated_at",
               conversationID, competency, course, Date())
    }

    // MARK: Placement

    var placement: Placement? {
        get { kv("placement").flatMap { try? Self.dec.decode(Placement.self, from: Data($0.utf8)) } }
        set { setKV("placement", newValue.flatMap { try? Self.enc.encode($0) }.map { String(decoding: $0, as: UTF8.self) }) }
    }

    // MARK: Enrolment and progression

    func enrollments() -> [Enrollment] {
        ((try? db.query("SELECT * FROM school_enrollments ORDER BY enrolled_at")) ?? []).compactMap { r in
            guard let c = r.string("course"), let s = r.string("status") else { return nil }
            return Enrollment(course: c, status: s, enrolledAt: r.date("enrolled_at") ?? Date(), completedAt: r.date("completed_at"), grade: r.string("grade"))
        }
    }

    /// Shown at a level, for readiness: held there, or one unaided pass at it or above on reliable evidence (an unseen
    /// task, tests, a review or defence, a placement probe). Enough to start a course that builds on it; not enough to
    /// certify it (completion needs the level held).
    func shown(_ competency: String, at level: Level, estimate: Estimate? = nil, rows: [Evidence]? = nil) -> Bool {
        if let l = (estimate ?? self.estimate(competency)).level, l >= level { return true }
        return (rows ?? evidence(competency)).contains { $0.level >= level && $0.outcome == .pass && $0.help == .none && $0.source.reliability >= 0.75 }
    }

    /// The prerequisite courses not yet met: completed, or every one of their competencies shown at their level.
    func unmetPrerequisites(_ course: Course, graph g: CompetencyGraph? = nil, estimates est: [String: Estimate]? = nil) -> [String] {
        let g = g ?? graph, est = est ?? estimates()
        let done = Set(enrollments().filter { $0.status == "completed" }.map(\.course))
        return course.prereqs.filter { id in
            guard !done.contains(id), let p = g.course(id) else { return false }
            return !p.competencies.allSatisfy { shown($0, at: p.level, estimate: est[$0] ?? SchoolStore.estimate($0, [])) }
        }
    }

    func enroll(_ courseID: String, override: Bool = false) -> String? {
        let g = graph
        guard let c = g.course(courseID) else { return "no course `\(courseID)` in the catalog" }
        let unmet = unmetPrerequisites(c, graph: g)
        if !unmet.isEmpty, !override {
            let list = unmet.map { "\"\($0)\"" }.joined(separator: ", ")
            return "its prerequisites aren't shown yet: \(unmet.joined(separator: ", ")). Place them on those (`school` place with targets [\(list)]): a probe per outcome at that level, so someone who already holds them clears it in a few tasks; then enroll again"
        }
        db.run("INSERT INTO school_enrollments(course, status, enrolled_at) VALUES(?, 'enrolled', ?) ON CONFLICT(course) DO UPDATE SET status = CASE WHEN status = 'completed' THEN status ELSE 'enrolled' END", c.id, Date())
        return nil
    }
    func drop(_ courseID: String) { db.run("UPDATE school_enrollments SET status = 'dropped' WHERE course = ? AND status = 'enrolled'", courseID) }

    struct CourseProgress: Sendable {
        var course: Course
        var met: [String]
        var remaining: [String]
        var summative: Bool          // some summative evidence at the course's level
        var score: Double            // mean evidence score at the level, for the grade
        var independence: Double
        var completable: Bool { remaining.isEmpty && summative }
        var grade: String { score >= 0.9 && independence >= 0.85 ? "Distinction" : score >= 0.8 ? "Merit" : "Pass" }
        /// The next competency to study: the first not yet held whose prerequisites in this course are.
        func next(_ g: CompetencyGraph) -> String? {
            remaining.first { id in (g[id]?.prereqs ?? []).allSatisfy { !course.competencies.contains($0) || met.contains($0) } } ?? remaining.first
        }
    }

    func progress(_ c: Course, estimates est: [String: Estimate]? = nil) -> CourseProgress {
        let est = est ?? estimates()
        let met = c.competencies.filter { (est[$0]?.level).map { $0 >= c.level } ?? false }
        let rows = c.competencies.flatMap { evidence($0) }.filter { $0.level >= c.level }
        let w = rows.map { $0.weight() }, mass = w.reduce(0, +)
        let passes = rows.filter { $0.outcome != .fail }
        return CourseProgress(course: c, met: met, remaining: c.competencies.filter { !met.contains($0) },
                              summative: rows.contains { $0.source.summative && $0.outcome == .pass && $0.help == .none },
                              score: mass > 0 ? zip(rows, w).reduce(0) { $0 + $1.0.outcome.score * $1.1 } / mass : 0,
                              independence: passes.isEmpty ? 0 : Double(passes.filter { $0.help == .none }.count) / Double(passes.count))
    }

    /// Completes every enrolled course the evidence now completes. The app decides, never the agent. Returns them.
    @discardableResult
    func progressCourses() -> [(Course, String)] {
        let g = graph, est = estimates()
        var done: [(Course, String)] = []
        for e in enrollments() where e.status == "enrolled" {
            guard let c = g.course(e.course) else { continue }
            let p = progress(c, estimates: est)
            if p.completable {
                db.run("UPDATE school_enrollments SET status = 'completed', completed_at = ?, grade = ? WHERE course = ?", Date(), p.grade, c.id)
                done.append((c, p.grade))
            }
        }
        return done
    }

    // MARK: Measures of learning (not engagement)

    struct Measures: Sendable {
        var hintDependence: Double?     // share of the last 30 days' evidence that had help
        var retention: Double?          // unaided pass rate on evidence for competencies first shown ≥ 30 days earlier
        var transfer: Double?           // pass rate on transfer evidence
    }
    func measures(now: Date = Date()) -> Measures {
        let rows = evidence(limit: 20000)
        let recent = rows.filter { now.timeIntervalSince($0.at) < 30 * 86400 }
        let first = Dictionary(grouping: rows, by: \.competency).mapValues { $0.map(\.at).min() ?? now }
        let later = rows.filter { e in first[e.competency].map { e.at.timeIntervalSince($0) >= 30 * 86400 } ?? false }
        let transfer = rows.filter { $0.skill == .transfer }
        func rate(_ r: [Evidence]) -> Double? { r.isEmpty ? nil : Double(r.filter { $0.outcome == .pass && $0.help == .none }.count) / Double(r.count) }
        return Measures(hintDependence: recent.isEmpty ? nil : Double(recent.filter { $0.help != .none }.count) / Double(recent.count),
                        retention: rate(later), transfer: rate(transfer))
    }
}
