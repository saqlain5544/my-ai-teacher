import Foundation

/// FSRS-5 spaced-repetition scheduler (19 default weights, target retention 0.9).
enum FSRS {
    static let w: [Double] = [0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
                              1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621]
    static let decay = -0.5
    static let factor = 19.0 / 81.0
    static let retention = 0.9
    /// Cap on stability (days): with it the longest interval is ~10 years, as FSRS's own maximum_interval does.
    static let maxStability = 3650.0

    enum Rating: Int, CaseIterable { case again = 1, hard, good, easy
        var title: String { switch self { case .again: "Again"; case .hard: "Hard"; case .good: "Good"; case .easy: "Easy" } }
    }

    struct State: Sendable { var stability: Double; var difficulty: Double; var reps: Int; var lapses: Int; var lastReview: Date? }

    static func retrievability(elapsed t: Double, stability s: Double) -> Double { pow(1 + factor * t / s, decay) }
    static func interval(_ s: Double) -> Double { max(1, (s / factor * (pow(retention, 1 / decay) - 1)).rounded()) }
    static func clampD(_ d: Double) -> Double { min(10, max(1, d)) }
    static func d0(_ g: Int) -> Double { clampD(w[4] - exp(w[5] * Double(g - 1)) + 1) }

    /// Returns the new state and next interval in days (sub-day for Again on new/lapsed cards).
    static func review(_ s: State, rating: Rating, now: Date = Date()) -> (State, intervalDays: Double) {
        let g = rating.rawValue
        var n = s
        n.reps += 1
        if s.reps == 0 || s.stability <= 0 {
            n.stability = w[g - 1]
            n.difficulty = d0(g)
        } else {
            let elapsed = max(0, now.timeIntervalSince(s.lastReview ?? now) / 86400)
            let d = s.difficulty
            // Difficulty update with linear damping + mean reversion toward D0(4).
            let dPrime = d - w[6] * Double(g - 3) * (10 - d) / 9
            n.difficulty = clampD(w[7] * d0(4) + (1 - w[7]) * dPrime)
            if elapsed < 1 {
                n.stability = s.stability * exp(w[17] * (Double(g - 3) + w[18]))
            } else {
                let r = retrievability(elapsed: elapsed, stability: s.stability)
                if rating == .again {
                    n.lapses += 1
                    let sf = w[11] * pow(d, -w[12]) * (pow(s.stability + 1, w[13]) - 1) * exp(w[14] * (1 - r))
                    n.stability = min(sf, s.stability / exp(w[17] * w[18]))
                } else {
                    let hard = rating == .hard ? w[15] : 1, easy = rating == .easy ? w[16] : 1
                    n.stability = s.stability * (1 + exp(w[8]) * (11 - d) * pow(s.stability, -w[9]) * (exp(w[10] * (1 - r)) - 1) * hard * easy)
                }
            }
        }
        n.stability = min(maxStability, max(0.01, n.stability))   // no 30-billion-year intervals
        n.lastReview = now
        let days: Double = rating == .again ? (10.0 / 1440.0) : (rating == .hard && s.reps == 0 ? 1 : interval(n.stability))
        return (n, days)
    }
}

/// Bayesian Knowledge Tracing for concept mastery.
enum BKT {
    static let slip = 0.1, guess = 0.2, learn = 0.15
    /// `guess`: how likely a right answer is without knowing it (higher when the learner says they guessed).
    static func update(_ p: Double, correct: Bool, guess: Double = guess) -> Double {
        let post = correct ? p * (1 - slip) / (p * (1 - slip) + (1 - p) * guess)
                           : p * slip / (p * slip + (1 - p) * (1 - guess))
        return min(0.999, post + (1 - post) * learn)
    }
}

/// How much help an answer had. Only answers without help move mastery up: practice that leans on hints or a shown
/// solution looks like progress but doesn't hold on a test without them.
enum Help: Int, Sendable { case none = 0, hint = 1, solution = 2 }

/// How sure the learner was, picked before the result is shown.
enum Certainty: Int, Sendable, CaseIterable {
    case guess = 1, unsure = 2, sure = 3
    var title: String { switch self { case .guess: "Guessing"; case .unsure: "Unsure"; case .sure: "Sure" } }
}

/// Something to come back to in a later lesson: a misconception to re-check, a fresh mastery to test in a new
/// context ("transfer"), a flashcard the learner forgot ("missed").
struct FollowUp: Identifiable, Hashable, Sendable {
    enum Kind: String, Sendable { case recheck, transfer, missed }
    var id: Int64
    var subject: String
    var concept: String
    var kind: Kind
    var note: String?
    var due: Date
    var createdAt: Date
}

struct Flashcard: Identifiable, Hashable, Sendable {
    var id: Int64
    var deck: String
    var front: String
    var back: String
    var concept: String?
    var subject: String?
    var due: Date
    var stability: Double
    var difficulty: Double
    var reps: Int
    var lapses: Int
    var lastReview: Date?
}

struct MasteryItem: Identifiable, Hashable, Sendable {
    var id: String { subject + "/" + concept }
    var subject: String
    var concept: String
    var pKnown: Double
    var attempts: Int
    var correct: Int
    var streak: Int
    var notes: String?
    var updatedAt: Date
    var mastered: Bool { pKnown >= 0.95 }
}

struct LessonPlan: Identifiable, Hashable, Sendable {
    var id: String
    var title: String
    var subject: String?
    var goal: String?
    var data: JSON
    var updatedAt: Date
}

final class StudyStore: @unchecked Sendable {
    let db: Database
    /// The school's record (evidence per competency) in the same database: every attempt on a concept the curriculum
    /// knows is evidence there too.
    let school: SchoolStore
    init(db: Database) { self.db = db; school = SchoolStore(db: db) }

    // MARK: Cards
    private func card(_ r: Row) -> Flashcard? {
        guard let id = r.int("id") else { return nil }
        return Flashcard(id: Int64(id), deck: r.string("deck") ?? "General", front: r.string("front") ?? "", back: r.string("back") ?? "",
                         concept: r.string("concept"), subject: r.string("subject"), due: r.date("due") ?? Date(),
                         stability: r.double("stability") ?? 0, difficulty: r.double("difficulty") ?? 0, reps: r.int("reps") ?? 0,
                         lapses: r.int("lapses") ?? 0, lastReview: r.date("last_review"))
    }

    @discardableResult
    func addCard(deck: String, front: String, back: String, concept: String?, subject: String?, source: String?) -> Int64? {
        let exists = (try? db.query("SELECT id FROM cards WHERE deck=? AND front=?", deck, front))?.first?.int("id")
        if let exists { return Int64(exists) }
        return db.insert("INSERT INTO cards(deck, front, back, concept, subject, source, created_at, due) VALUES(?,?,?,?,?,?,?,?)",
                         deck, front, back, concept, subject, source, Date(), Date())
    }

    func dueCards(deck: String? = nil, limit: Int = 100) -> [Flashcard] {
        let now = Date()
        let rows: [Row]
        if let deck { rows = (try? db.query("SELECT * FROM cards WHERE suspended=0 AND due<=? AND deck=? ORDER BY due LIMIT ?", now, deck, limit)) ?? [] }
        else { rows = (try? db.query("SELECT * FROM cards WHERE suspended=0 AND due<=? ORDER BY due LIMIT ?", now, limit)) ?? [] }
        return rows.compactMap(card)
    }

    func allCards(deck: String? = nil) -> [Flashcard] {
        let rows = deck.map { (try? db.query("SELECT * FROM cards WHERE deck=? ORDER BY created_at DESC", $0)) ?? [] }
            ?? ((try? db.query("SELECT * FROM cards ORDER BY created_at DESC")) ?? [])
        return rows.compactMap(card)
    }

    func decks() -> [(name: String, total: Int, due: Int)] {
        let rows = (try? db.query("SELECT deck, COUNT(*) AS total, SUM(CASE WHEN due<=? AND suspended=0 THEN 1 ELSE 0 END) AS due FROM cards GROUP BY deck ORDER BY deck", Date())) ?? []
        return rows.map { ($0.string("deck") ?? "General", $0.int("total") ?? 0, $0.int("due") ?? 0) }
    }

    func dueCount() -> Int { (try? db.query("SELECT COUNT(*) AS n FROM cards WHERE suspended=0 AND due<=?", Date()).first?.int("n")) ?? 0 }

    func review(_ c: Flashcard, rating: FSRS.Rating) -> Flashcard {
        let now = Date()
        let (s, days) = FSRS.review(.init(stability: c.stability, difficulty: c.difficulty, reps: c.reps, lapses: c.lapses, lastReview: c.lastReview), rating: rating, now: now)
        let due = now.addingTimeInterval(days * 86400)
        let elapsed = c.lastReview.map { now.timeIntervalSince($0) / 86400 } ?? 0
        // The schedule and its review log change together (apart, a crash left a rescheduled card with no review, or one).
        db.write("card review") {
            try db.execute("UPDATE cards SET due=?, stability=?, difficulty=?, reps=?, lapses=?, last_review=?, state=? WHERE id=?",
                           due, s.stability, s.difficulty, s.reps, s.lapses, now, rating == .again ? 3 : 2, c.id)
            try db.execute("INSERT INTO reviews(card_id, rating, reviewed_at, elapsed_days, scheduled_days) VALUES(?,?,?,?,?)",
                           c.id, rating.rawValue, now, elapsed, days)
        }
        logActivity(reviews: 1)
        if let concept = c.concept { recordAttempt(subject: c.subject ?? c.deck, concept: concept, correct: rating != .again, note: nil, evidence: (.practice, .recall)) }
        // A forgotten card is the next lesson's business: the tutor sees it and can teach it another way.
        let key = c.concept ?? String(c.front.prefix(80))
        if rating == .again {
            let leech = s.lapses >= 3 ? " (forgotten \(s.lapses) times: teach it another way, e.g. an example or a memory hook)" : ""
            scheduleFollowUp(subject: c.subject ?? c.deck, concept: key, kind: .missed,
                             note: "forgot the card “\(String(c.front.prefix(140)))” → \(String(c.back.prefix(140)))\(leech)", after: 0)
        } else if rating != .hard {
            resolveFollowUps(concept: key, kinds: [.missed], outcome: "remembered")
        }
        var u = c
        u.due = due; u.stability = s.stability; u.difficulty = s.difficulty; u.reps = s.reps; u.lapses = s.lapses; u.lastReview = now
        return u
    }

    /// Preview of the next intervals for each rating (for the review buttons).
    func preview(_ c: Flashcard) -> [FSRS.Rating: Double] {
        var out: [FSRS.Rating: Double] = [:]
        for r in FSRS.Rating.allCases {
            out[r] = FSRS.review(.init(stability: c.stability, difficulty: c.difficulty, reps: c.reps, lapses: c.lapses, lastReview: c.lastReview), rating: r).intervalDays
        }
        return out
    }

    /// Its reviews stay: they are the learner's study history (Insights counts them by day).
    func deleteCard(_ id: Int64) { db.run("DELETE FROM cards WHERE id=?", id) }
    func updateCard(_ id: Int64, front: String, back: String) { db.run("UPDATE cards SET front=?, back=? WHERE id=?", front, back, id) }

    // MARK: Mastery
    /// One answer on a concept. A wrong answer always counts; a right one raises mastery only without help (with help it is
    /// logged as an attempt and nothing more), and less when the learner says they guessed.
    /// Due follow-ups on the concept are settled by answers without help; reaching mastery schedules a transfer check.
    @discardableResult
    func recordAttempt(subject: String, concept: String, correct: Bool, note: String?, help: Help = .none,
                       certainty: Certainty? = nil, now: Date = Date(), evidence: (source: Evidence.Source, skill: Skill)? = (.mastery, .recall),
                       conversationID: String? = nil) -> MasteryItem {
        if let ev = evidence { school.bridge(subject: subject, concept: concept, correct: correct, help: help, source: ev.source, skill: ev.skill, conversationID: conversationID, now: now) }
        let s = subject.trimmingCharacters(in: .whitespaces).lowercased()
        // One row per concept whatever its casing ("Chain rule" = "chain rule"): reuse the stored spelling.
        let cur = mastery(subject: s, concept: concept.trimmingCharacters(in: .whitespaces))
        let c = cur?.concept ?? concept.trimmingCharacters(in: .whitespaces)
        let before = cur?.pKnown ?? 0.2
        let earned = correct && help == .none
        let p = correct && help != .none ? before
            : BKT.update(before, correct: correct, guess: earned && certainty == .guess ? 0.5 : BKT.guess)
        let streak = earned ? (cur?.streak ?? 0) + 1 : (correct ? cur?.streak ?? 0 : 0)
        db.run("""
            INSERT INTO mastery(subject, concept, p_known, attempts, correct, streak, notes, updated_at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(subject, concept) DO UPDATE SET p_known=excluded.p_known, attempts=excluded.attempts, correct=excluded.correct,
            streak=excluded.streak, notes=COALESCE(excluded.notes, mastery.notes), updated_at=excluded.updated_at
            """, s, c, p, (cur?.attempts ?? 0) + 1, (cur?.correct ?? 0) + (earned ? 1 : 0), streak, note, now)
        if help == .none { settleFollowUps(subject: s, concept: c, correct: correct, now: now) }
        // Mastery on the practice it came from isn't proof yet: ask again in a few days, in a new context.
        if earned, before < 0.95, p >= 0.95 {
            scheduleFollowUp(subject: s, concept: c, kind: .transfer,
                             note: "just reached mastery: ask one question that applies it in a new context, not a repeat", after: 3, now: now)
        }
        return mastery(subject: s, concept: c)!
    }

    func setMastery(subject: String, concept: String, level: Double, note: String?) {
        let s = subject.lowercased()
        db.run("""
            INSERT INTO mastery(subject, concept, p_known, notes, updated_at) VALUES(?,?,?,?,?)
            ON CONFLICT(subject, concept) DO UPDATE SET p_known=excluded.p_known, notes=COALESCE(excluded.notes, mastery.notes), updated_at=excluded.updated_at
            """, s, concept, min(0.999, max(0, level)), note, Date())
    }

    func mastery(subject: String, concept: String) -> MasteryItem? {
        (try? db.query("SELECT * FROM mastery WHERE subject=? AND concept=? COLLATE NOCASE", subject.lowercased(), concept))?.first.flatMap(masteryRow)
    }

    func allMastery() -> [MasteryItem] {
        ((try? db.query("SELECT * FROM mastery ORDER BY subject, p_known DESC")) ?? []).compactMap(masteryRow)
    }

    private func masteryRow(_ r: Row) -> MasteryItem? {
        guard let s = r.string("subject"), let c = r.string("concept") else { return nil }
        return MasteryItem(subject: s, concept: c, pKnown: r.double("p_known") ?? 0.2, attempts: r.int("attempts") ?? 0,
                           correct: r.int("correct") ?? 0, streak: r.int("streak") ?? 0, notes: r.string("notes"), updatedAt: r.date("updated_at") ?? Date())
    }

    /// Compact summary for the system prompt.
    func masterySummary(limit: Int = 25) -> String {
        let items = ((try? db.query("SELECT * FROM mastery ORDER BY updated_at DESC LIMIT ?", limit)) ?? []).compactMap(masteryRow)
        guard !items.isEmpty else { return "" }
        return items.map { m in
            let pct = Int(m.pKnown * 100)
            return "- \(m.subject) › \(m.concept): \(pct)% (\(m.correct)/\(m.attempts) correct)\(m.mastered ? " ✓ mastered" : "")"
        }.joined(separator: "\n")
    }

    // MARK: Answers & follow-ups

    /// Logs one graded answer (with or without a concept): how sure the learner was and how much help they had.
    func recordResponse(subject: String?, concept: String?, correct: Bool?, certainty: Certainty?, help: Help,
                        source: String, conversationID: String?, now: Date = Date()) {
        db.run("INSERT INTO responses(at, subject, concept, correct, certainty, help, source, conversation_id) VALUES(?,?,?,?,?,?,?,?)",
                        now, subject?.lowercased(), concept, correct, certainty?.rawValue, help.rawValue, source, conversationID)
    }

    /// Concepts the learner already answered wrong in this lesson, as concept keys (`MemoryText.conceptKey`).
    func missedInLesson(_ conversationID: String) -> Set<String> {
        Set(((try? db.query("SELECT DISTINCT concept FROM responses WHERE conversation_id=? AND correct=0 AND concept IS NOT NULL", conversationID)) ?? [])
            .compactMap { $0.string("concept").map(MemoryText.conceptKey) })
    }

    /// Per certainty level: answers and how many were right (graded answers without help, last `days`).
    func calibration(days: Int = 180, now: Date = Date()) -> [Certainty: (answers: Int, right: Int)] {
        let rows = (try? db.query("""
            SELECT certainty, COUNT(*) AS n, SUM(correct) AS ok FROM responses
            WHERE at>=? AND certainty IS NOT NULL AND correct IS NOT NULL AND help=0 GROUP BY certainty
            """, now.addingTimeInterval(-Double(days) * 86400))) ?? []
        var out: [Certainty: (Int, Int)] = [:]
        for r in rows { if let c = r.int("certainty").flatMap(Certainty.init(rawValue:)) { out[c] = (r.int("n") ?? 0, r.int("ok") ?? 0) } }
        return out
    }

    /// Hints used and solutions shown in the last `days`.
    func helpUsed(days: Int = 30, now: Date = Date()) -> (hints: Int, solutions: Int) {
        let r = (try? db.query("SELECT SUM(help=1) AS h, SUM(help=2) AS s FROM responses WHERE at>=?", now.addingTimeInterval(-Double(days) * 86400)))?.first
        return (r?.int("h") ?? 0, r?.int("s") ?? 0)
    }

    /// Open follow-ups of these kinds on the concept, matched by concept key ("the chain rule" = "Chain rule").
    private func open(_ kinds: [FollowUp.Kind], concept: String) -> [FollowUp] {
        let key = MemoryText.conceptKey(concept)
        let rows = (try? db.query("SELECT * FROM followups WHERE resolved_at IS NULL AND kind IN (\(kinds.map { "'\($0.rawValue)'" }.joined(separator: ",")))")) ?? []
        return rows.compactMap(followUp).filter { $0.concept.caseInsensitiveCompare(concept) == .orderedSame || MemoryText.conceptKey($0.concept) == key }
    }

    /// Adds a follow-up, or refreshes the open one of the same kind for the concept (the earlier due date wins).
    func scheduleFollowUp(subject: String, concept: String, kind: FollowUp.Kind, note: String?, after days: Double,
                          conversationID: String? = nil, now: Date = Date()) {
        let due = now.addingTimeInterval(days * 86400)
        if let id = open([kind], concept: concept).first?.id {
            db.run("UPDATE followups SET due=MIN(due, ?), note=COALESCE(?, note) WHERE id=?", due, note, id)
        } else {
            db.run("INSERT INTO followups(subject, concept, kind, note, due, created_at, conversation_id) VALUES(?,?,?,?,?,?,?)",
                            subject.lowercased(), concept, kind.rawValue, note, due, now, conversationID)
        }
    }

    /// Open follow-ups that are due, oldest first. Forgotten-card notes that nobody took up expire after a week.
    func dueFollowUps(limit: Int = 6, now: Date = Date()) -> [FollowUp] {
        db.run("UPDATE followups SET resolved_at=?, outcome='expired' WHERE resolved_at IS NULL AND kind='missed' AND created_at<?",
                        now, now.addingTimeInterval(-7 * 86400))
        return ((try? db.query("SELECT * FROM followups WHERE resolved_at IS NULL AND due<=? ORDER BY due LIMIT ?", now, limit)) ?? []).compactMap(followUp)
    }

    /// Every open follow-up, soonest first (the Progress screen).
    func openFollowUps(limit: Int = 20) -> [FollowUp] {
        ((try? db.query("SELECT * FROM followups WHERE resolved_at IS NULL ORDER BY due LIMIT ?", limit)) ?? []).compactMap(followUp)
    }

    func resolveFollowUps(concept: String, kinds: [FollowUp.Kind], outcome: String, now: Date = Date()) {
        for f in open(kinds, concept: concept) { db.run("UPDATE followups SET resolved_at=?, outcome=? WHERE id=?", now, outcome, f.id) }
    }

    /// An answer without help settles the concept's due re-check and transfer checks: right closes them; a missed transfer
    /// check becomes a re-check tomorrow; a missed re-check comes back tomorrow. Follow-ups not due yet wait: an answer
    /// in the same lesson isn't the delayed check.
    private func settleFollowUps(subject: String, concept: String, correct: Bool, now: Date) {
        for f in open([.recheck, .transfer], concept: concept) where f.due <= now {
            let id = f.id
            if correct {
                db.run("UPDATE followups SET resolved_at=?, outcome='passed' WHERE id=?", now, id)
            } else if f.kind == .transfer {
                db.run("UPDATE followups SET resolved_at=?, outcome='failed' WHERE id=?", now, id)
                scheduleFollowUp(subject: subject, concept: concept, kind: .recheck, note: "missed the transfer check: it didn't carry over to a new context", after: 1, now: now)
            } else {
                db.run("UPDATE followups SET due=? WHERE id=?", now.addingTimeInterval(86400), id)
            }
        }
    }

    private func followUp(_ r: Row) -> FollowUp? {
        guard let id = r.int("id"), let c = r.string("concept"), let k = r.string("kind").flatMap(FollowUp.Kind.init(rawValue:)) else { return nil }
        return FollowUp(id: Int64(id), subject: r.string("subject") ?? "general", concept: c, kind: k, note: r.string("note"),
                        due: r.date("due") ?? Date(), createdAt: r.date("created_at") ?? Date())
    }

    /// Brings the concept's flashcards forward to tomorrow at the latest (after a confident mistake).
    func reviewSoon(concept: String, now: Date = Date()) {
        db.run("UPDATE cards SET due=MIN(due, ?) WHERE suspended=0 AND concept=? COLLATE NOCASE", now.addingTimeInterval(86400), concept)
    }

    // MARK: Plans
    func savePlan(_ p: LessonPlan, conversationID: String?) {
        db.run("""
            INSERT INTO plans(id, title, subject, goal, data, conversation_id, created_at, updated_at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET title=excluded.title, subject=excluded.subject, goal=excluded.goal, data=excluded.data, updated_at=excluded.updated_at
            """, p.id, p.title, p.subject, p.goal, p.data.compact, conversationID, Date(), Date())
    }
    func plans() -> [LessonPlan] {
        ((try? db.query("SELECT * FROM plans ORDER BY updated_at DESC")) ?? []).compactMap { r in
            guard let id = r.string("id") else { return nil }
            return LessonPlan(id: id, title: r.string("title") ?? "Plan", subject: r.string("subject"), goal: r.string("goal"),
                              data: r.string("data").flatMap { JSON.parse($0) } ?? .object([:]), updatedAt: r.date("updated_at") ?? Date())
        }
    }
    func plan(_ id: String) -> LessonPlan? { plans().first { $0.id == id || $0.title.lowercased() == id.lowercased() } }
    func deletePlan(_ id: String) { db.run("DELETE FROM plans WHERE id=?", id) }

    // MARK: Quizzes & activity
    func recordQuiz(conversationID: String, title: String, topic: String?, score: Double, total: Int, data: JSON) {
        db.run("INSERT INTO quiz_attempts(conversation_id, title, topic, score, total, data, created_at) VALUES(?,?,?,?,?,?,?)",
                        conversationID, title, topic, score, total, data.compact, Date())
    }
    func recentQuizzes(limit: Int = 20) -> [(title: String, topic: String?, score: Double, total: Int, date: Date)] {
        ((try? db.query("SELECT * FROM quiz_attempts ORDER BY created_at DESC LIMIT ?", limit)) ?? []).map {
            ($0.string("title") ?? "Quiz", $0.string("topic"), $0.double("score") ?? 0, $0.int("total") ?? 0, $0.date("created_at") ?? Date())
        }
    }

    static let dayFormatter: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

    func logActivity(seconds: Double = 0, messages: Int = 0, reviews: Int = 0) {
        let day = Self.dayFormatter.string(from: Date())
        db.run("""
            INSERT INTO study_log(day, seconds, messages, reviews) VALUES(?,?,?,?)
            ON CONFLICT(day) DO UPDATE SET seconds=seconds+excluded.seconds, messages=messages+excluded.messages, reviews=reviews+excluded.reviews
            """, day, seconds, messages, reviews)
    }

    func activity(days: Int = 84) -> [String: (seconds: Double, messages: Int, reviews: Int)] {
        let since = Self.dayFormatter.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        var out: [String: (Double, Int, Int)] = [:]
        for r in (try? db.query("SELECT * FROM study_log WHERE day>=?", since)) ?? [] {
            if let d = r.string("day") { out[d] = (r.double("seconds") ?? 0, r.int("messages") ?? 0, r.int("reviews") ?? 0) }
        }
        return out
    }

    func streakDays() -> Int {
        let log = activity(days: 400)
        var streak = 0
        var day = Date()
        if log[Self.dayFormatter.string(from: day)] == nil { day = day.addingTimeInterval(-86400) }
        while let a = log[Self.dayFormatter.string(from: day)], a.messages + a.reviews > 0 {
            streak += 1; day = day.addingTimeInterval(-86400)
        }
        return streak
    }
}
