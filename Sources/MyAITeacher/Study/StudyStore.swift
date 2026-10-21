import Foundation

/// FSRS-5 spaced-repetition scheduler (19 default weights, target retention 0.9).
enum FSRS {
    static let w: [Double] = [0.40255, 1.18385, 3.173, 15.69105, 7.1949, 0.5345, 1.4604, 0.0046, 1.54575, 0.1192,
                              1.01925, 1.9395, 0.11, 0.29605, 2.2698, 0.2315, 2.9898, 0.51655, 0.6621]
    static let decay = -0.5
    static let factor = 19.0 / 81.0
    static let retention = 0.9

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
        n.stability = max(0.01, n.stability)
        n.lastReview = now
        let days: Double = rating == .again ? (10.0 / 1440.0) : (rating == .hard && s.reps == 0 ? 1 : interval(n.stability))
        return (n, days)
    }
}

/// Bayesian Knowledge Tracing for concept mastery.
enum BKT {
    static let slip = 0.1, guess = 0.2, learn = 0.15
    static func update(_ p: Double, correct: Bool) -> Double {
        let post = correct ? p * (1 - slip) / (p * (1 - slip) + (1 - p) * guess)
                           : p * slip / (p * slip + (1 - p) * (1 - guess))
        return min(0.999, post + (1 - post) * learn)
    }
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
    init(db: Database) { self.db = db }

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
        try? db.execute("INSERT INTO cards(deck, front, back, concept, subject, source, created_at, due) VALUES(?,?,?,?,?,?,?,?)",
                        deck, front, back, concept, subject, source, Date(), Date())
        return db.lastInsertRowID
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
        try? db.execute("UPDATE cards SET due=?, stability=?, difficulty=?, reps=?, lapses=?, last_review=?, state=? WHERE id=?",
                        due, s.stability, s.difficulty, s.reps, s.lapses, now, rating == .again ? 3 : 2, c.id)
        try? db.execute("INSERT INTO reviews(card_id, rating, reviewed_at, elapsed_days, scheduled_days) VALUES(?,?,?,?,?)",
                        c.id, rating.rawValue, now, elapsed, days)
        logActivity(reviews: 1)
        if let concept = c.concept { recordAttempt(subject: c.subject ?? c.deck, concept: concept, correct: rating != .again, note: nil) }
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

    func deleteCard(_ id: Int64) { try? db.execute("DELETE FROM cards WHERE id=?", id) }
    func updateCard(_ id: Int64, front: String, back: String) { try? db.execute("UPDATE cards SET front=?, back=? WHERE id=?", front, back, id) }

    // MARK: Mastery
    @discardableResult
    func recordAttempt(subject: String, concept: String, correct: Bool, note: String?) -> MasteryItem {
        let s = subject.trimmingCharacters(in: .whitespaces).lowercased()
        // One row per concept whatever its casing ("Chain rule" = "chain rule"): reuse the stored spelling.
        let cur = mastery(subject: s, concept: concept.trimmingCharacters(in: .whitespaces))
        let c = cur?.concept ?? concept.trimmingCharacters(in: .whitespaces)
        let p = BKT.update(cur?.pKnown ?? 0.2, correct: correct)
        let streak = correct ? (cur?.streak ?? 0) + 1 : 0
        try? db.execute("""
            INSERT INTO mastery(subject, concept, p_known, attempts, correct, streak, notes, updated_at) VALUES(?,?,?,?,?,?,?,?)
            ON CONFLICT(subject, concept) DO UPDATE SET p_known=excluded.p_known, attempts=excluded.attempts, correct=excluded.correct,
            streak=excluded.streak, notes=COALESCE(excluded.notes, mastery.notes), updated_at=excluded.updated_at
            """, s, c, p, (cur?.attempts ?? 0) + 1, (cur?.correct ?? 0) + (correct ? 1 : 0), streak, note, Date())
        return mastery(subject: s, concept: c)!
    }

    func setMastery(subject: String, concept: String, level: Double, note: String?) {
        let s = subject.lowercased()
        try? db.execute("""
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

    // MARK: Plans
    func savePlan(_ p: LessonPlan, conversationID: String?) {
        try? db.execute("""
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
    func deletePlan(_ id: String) { try? db.execute("DELETE FROM plans WHERE id=?", id) }

    // MARK: Quizzes & activity
    func recordQuiz(conversationID: String, title: String, topic: String?, score: Double, total: Int, data: JSON) {
        try? db.execute("INSERT INTO quiz_attempts(conversation_id, title, topic, score, total, data, created_at) VALUES(?,?,?,?,?,?,?)",
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
        try? db.execute("""
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
