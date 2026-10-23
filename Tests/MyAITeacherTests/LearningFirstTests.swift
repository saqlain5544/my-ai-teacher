import XCTest
@testable import MyAITeacher

/// Learning-first defaults: help-aware mastery, misconception-tagged answers, certainty, follow-ups and the prompt rules.
final class LearningFirstTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var study: StudyStore { services.study }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("learnfirst-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testOnlyUnaidedRightAnswersRaiseMastery() {
        let plain = study.recordAttempt(subject: "algebra", concept: "plain", correct: true, note: nil)
        let hinted = study.recordAttempt(subject: "algebra", concept: "hinted", correct: true, note: nil, help: .hint)
        let shown = study.recordAttempt(subject: "algebra", concept: "shown", correct: true, note: nil, help: .solution)
        let guessed = study.recordAttempt(subject: "algebra", concept: "guessed", correct: true, note: nil, certainty: .guess)
        XCTAssertGreaterThan(plain.pKnown, 0.5)
        XCTAssertEqual(hinted.pKnown, 0.2, accuracy: 1e-9, "a right answer after a hint is logged, not credited")
        XCTAssertEqual(shown.pKnown, 0.2, accuracy: 1e-9)
        XCTAssertEqual(hinted.attempts, 1); XCTAssertEqual(hinted.correct, 0); XCTAssertEqual(hinted.streak, 0)
        XCTAssertGreaterThan(guessed.pKnown, 0.2); XCTAssertLessThan(guessed.pKnown, plain.pKnown, "a lucky guess says less")
        let wrongWithHint = study.recordAttempt(subject: "algebra", concept: "plain", correct: false, note: nil, help: .hint)
        XCTAssertLessThan(wrongWithHint.pKnown, plain.pKnown, "a wrong answer counts whatever the help")
    }

    func testMasteryAsksForATransferCheckDaysLater() {
        let t0 = Date()
        var m = study.recordAttempt(subject: "physics", concept: "Newton's second law", correct: true, note: nil, now: t0)
        while m.pKnown < 0.95 { m = study.recordAttempt(subject: "physics", concept: "Newton's second law", correct: true, note: nil, now: t0) }
        XCTAssertTrue(study.dueFollowUps(now: t0).isEmpty, "not due the same day")
        let later = t0.addingTimeInterval(3.1 * 86400)
        let due = study.dueFollowUps(now: later)
        XCTAssertEqual(due.map(\.kind), [.transfer]); XCTAssertEqual(due.first?.concept, "Newton's second law")
        // A miss on the transfer check: it didn't carry over, so it becomes a re-check the next day.
        _ = study.recordAttempt(subject: "physics", concept: "newton's second law", correct: false, note: nil, now: later)
        XCTAssertTrue(study.dueFollowUps(now: later).isEmpty, "\(study.dueFollowUps(now: later)) \(study.openFollowUps())")
        let next = study.dueFollowUps(now: later.addingTimeInterval(1.1 * 86400))
        XCTAssertEqual(next.map(\.kind), [.recheck]); XCTAssertTrue(next[0].note?.contains("transfer") ?? false)
        // A right answer without help settles it; a helped one would not.
        _ = study.recordAttempt(subject: "physics", concept: "Newton's second law", correct: true, note: nil, help: .hint, now: later.addingTimeInterval(1.2 * 86400))
        XCTAssertEqual(study.openFollowUps().count, 1)
        let back = study.recordAttempt(subject: "physics", concept: "Newton's second law", correct: true, note: nil, now: later.addingTimeInterval(1.3 * 86400))
        XCTAssertGreaterThanOrEqual(back.pKnown, 0.95)
        XCTAssertEqual(study.openFollowUps().map(\.kind), [.transfer], "re-check passed; mastery regained asks for a new transfer check")
    }

    func testRecheckWaitsUntilItIsDue() {
        let t0 = Date()
        study.scheduleFollowUp(subject: "chem", concept: "moles", kind: .recheck, note: "misconception: moles are grams", after: 2, now: t0)
        study.scheduleFollowUp(subject: "chem", concept: "Moles", kind: .recheck, note: nil, after: 5, now: t0)   // same one, kept earlier date and note
        XCTAssertEqual(study.openFollowUps().count, 1)
        XCTAssertEqual(study.openFollowUps()[0].note, "misconception: moles are grams")
        _ = study.recordAttempt(subject: "chem", concept: "moles", correct: true, note: nil, now: t0.addingTimeInterval(3600))
        XCTAssertEqual(study.openFollowUps().count, 1, "the same lesson isn't the delayed check")
        _ = study.recordAttempt(subject: "chem", concept: "moles", correct: false, note: nil, now: t0.addingTimeInterval(2.1 * 86400))
        XCTAssertEqual(study.openFollowUps().count, 1, "missed again: comes back tomorrow")
        XCTAssertGreaterThan(study.openFollowUps()[0].due, t0.addingTimeInterval(2.9 * 86400))
    }

    func testForgottenFlashcardBecomesAFollowUp() {
        let id = study.addCard(deck: "Spanish", front: "el perro", back: "the dog", concept: nil, subject: "spanish", source: nil)!
        var card = study.allCards().first { $0.id == id }!
        card = study.review(card, rating: .again)
        let due = study.dueFollowUps()
        XCTAssertEqual(due.map(\.kind), [.missed]); XCTAssertTrue(due[0].note?.contains("el perro") ?? false)
        _ = study.review(card, rating: .good)
        XCTAssertTrue(study.dueFollowUps().isEmpty, "remembered later: settled")
    }

    func testWrongAnswersNameTheirMisconception() {
        let single: JSON = ["type": "single_choice", "options": ["x^5", "x^6", "x^9"], "answer": 1,
                            "misconceptions": [["answer": 0, "misconception": "adds the exponents"], ["answer": "x^9", "misconception": "squares the base"]]]
        XCTAssertEqual(Questions.misconception(single, answer: 0), "adds the exponents")
        XCTAssertEqual(Questions.misconception(single, answer: 2), "squares the base", "a tag may name the option by its text")
        XCTAssertNil(Questions.misconception(single, answer: .null))
        let multi: JSON = ["type": "multiple_choice", "options": ["a", "b", "c"], "answer": [0], "misconceptions": [["answer": 2, "misconception": "c looks like a"]]]
        XCTAssertEqual(Questions.misconception(multi, answer: [0, 2]), "c looks like a")
        let num: JSON = ["type": "numeric", "answer": 9.8, "misconceptions": [["answer": -9.8, "misconception": "sign of g"]]]
        XCTAssertEqual(Questions.misconception(num, answer: "-9.8 m/s^2"), "sign of g")
        XCTAssertNil(Questions.misconception(num, answer: 9.8))
        let text: JSON = ["type": "short_text", "answer": "mitochondria", "misconceptions": [["answer": "Nucleus", "misconception": "thinks the nucleus makes energy"]]]
        XCTAssertEqual(Questions.misconception(text, answer: "nucleus."), "thinks the nucleus makes energy")
        let tf: JSON = ["type": "true_false", "answer": false, "misconceptions": [["answer": true, "misconception": "heavier falls faster"]]]
        XCTAssertEqual(Questions.misconception(tf, answer: true), "heavier falls faster")
        XCTAssertNil(Questions.publicView(single)["misconceptions"], "the page never sees which options are traps")
        XCTAssertNotNil(Questions.schema(graded: true)["properties"]?["misconceptions"])
        XCTAssertNotNil(Questions.schema(graded: false)["properties"]?["hints"])
    }

    func testQuizzesOffDontKnowAndReasonedSkips() async throws {
        let interactions = await MainActor.run { InteractionCenter() }
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        func ctx(_ id: String, quizzes: Bool = true) -> ToolContext {
            var c = ToolContext(conversationID: "lesson-2", workspace: dir, services: services, interactions: interactions, toolCallID: id,
                                client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
            c.quizzes = quizzes
            return c
        }
        let input: JSON = ["title": "Latency", "case": "p99 jumps from 40 ms to 900 ms after a deploy.", "questions": [
            ["type": "single_choice", "prompt": "First suspect?", "options": ["GC", "Locks"], "answer": 1, "concept": "lock contention"],
            ["type": "true_false", "prompt": "p99 hides the tail", "answer": false, "concept": "percentiles"]]]
        // Off: the quiz is refused, graded or through ask_learner, before anything reaches the learner.
        let off = try await QuizTool().run(input, ctx("q0", quizzes: false))
        XCTAssertTrue(off.isError == true && off.text.contains("Quizzes are off"), off.text)
        var viaAsk = input.object ?? [:]; viaAsk["graded"] = true
        let refused = try await AskLearnerTool().run(.object(viaAsk), ctx("q0b", quizzes: false)).text
        XCTAssertTrue(refused.contains("Quizzes are off"), refused)
        // "Don't know yet": a gap to teach, not graded, not a mistake.
        let run = Task { try await QuizTool().run(input, ctx("q1")) }
        for _ in 0..<200 where await MainActor.run(body: { interactions.pending["q1"] == nil }) { try await Task.sleep(nanoseconds: 5_000_000) }
        let payload = await MainActor.run { interactions.pending["q1"]?.payload }
        XCTAssertEqual(payload?["case"]?.string, "p99 jumps from 40 ms to 900 ms after a deploy.", "the case reaches the page")
        await MainActor.run { interactions.resolve("q1", ["answers": [.null, false], "certainty": [0, 3]]) }
        let out = try await run.value
        XCTAssertTrue(out.text.contains("Auto-graded score: 1/1"), out.text)
        XCTAssertTrue(out.text.contains("doesn't know this yet") && out.text.contains("a gap to teach, not a mistake"), out.text)
        XCTAssertEqual(out.meta?["graded"]?[0]?["unknown"]?.bool, true)
        XCTAssertNil(study.mastery(subject: "general", concept: "lock contention"), "nothing recorded for an unknown")
        // A skip says why, and the teacher is told what to do about it.
        let skip = Task { try await QuizTool().run(input, ctx("q2")) }
        for _ in 0..<200 where await MainActor.run(body: { interactions.pending["q2"] == nil }) { try await Task.sleep(nanoseconds: 5_000_000) }
        await MainActor.run { interactions.resolve("q2", ["cancelled": true, "reason": "need_more"]) }
        let skipped = try await skip.value.text
        XCTAssertTrue(skipped.contains("needs more explanation first") && skipped.contains("Teach the idea more deeply"), skipped)
        XCTAssertTrue(Testing.skipped("quiz", reason: nil).contains("Don't ask it again right away"))
        XCTAssertTrue(Testing.on(AppSettings(), .tutor))
        var s = AppSettings(); s.quizzes = false
        XCTAssertFalse(Testing.on(s, .tutor)); XCTAssertTrue(Testing.on(s, .quiz), "Quiz mode always tests")
    }

    func testQuizUsesHintsCertaintyAndMisconceptions() async throws {
        let interactions = await MainActor.run { InteractionCenter() }
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        let ctx = ToolContext(conversationID: "lesson-1", workspace: dir, services: services, interactions: interactions, toolCallID: "quiz-1",
                              client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
        let cardID = study.addCard(deck: "Powers", front: "x^2 · x^3?", back: "x^5", concept: "product of powers", subject: "algebra", source: nil)!
        try services.global.db.execute("UPDATE cards SET due=? WHERE id=?", Date().addingTimeInterval(10 * 86400), cardID)
        let input: JSON = ["title": "Powers", "subject": "algebra", "questions": [
            ["type": "single_choice", "prompt": "x^2 · x^3 = ?", "options": ["x^6", "x^5"], "answer": 1, "concept": "product of powers",
             "misconceptions": [["answer": 0, "misconception": "multiplies the exponents instead of adding them"]]],
            ["type": "numeric", "prompt": "2^3 = ?", "answer": 8, "concept": "integer powers", "hints": ["Multiply 2 by itself", "2·2·2"]],
            ["type": "true_false", "prompt": "x^0 = 1 for x ≠ 0", "answer": true, "concept": "zero exponent"],
            ["type": "short_text", "prompt": "Name the base in 5^2", "answer": "5", "misconceptions": [["answer": "2", "misconception": "confuses base and exponent"]]],
        ]]
        let run = Task { try await QuizTool().run(input, ctx) }
        for _ in 0..<200 where await MainActor.run(body: { interactions.pending["quiz-1"] == nil }) { try await Task.sleep(nanoseconds: 5_000_000) }
        await MainActor.run {
            interactions.resolve("quiz-1", ["answers": [0, "8", true, "2"], "hints": [0, 1, 0, 0], "certainty": [3, 2, 1, .null]])
        }
        let out = try await run.value
        XCTAssertTrue(out.text.contains("misconception: multiplies the exponents"), out.text)
        XCTAssertTrue(out.text.contains("Q1: wrong although the learner was sure"), out.text)
        XCTAssertTrue(out.text.contains("Q3: right but guessed"), out.text)
        XCTAssertTrue(out.text.contains("after 1 hint") && out.text.contains("never quiz the same point twice in a row"), out.text)
        XCTAssertTrue(out.text.contains("Auto-graded score: 2/4"), "a tagged wrong short answer is graded, not left to the teacher: \(out.text)")
        XCTAssertEqual(out.meta?["graded"]?[0]?["misconception"]?.string, "multiplies the exponents instead of adding them")
        XCTAssertEqual(out.meta?["graded"]?[0]?["certainty"]?.int, 3)
        // Mastery: the hinted right answer earned nothing; the guess a little.
        XCTAssertEqual(study.mastery(subject: "algebra", concept: "integer powers")?.pKnown ?? 0, 0.2, accuracy: 1e-9)
        XCTAssertGreaterThan(study.mastery(subject: "algebra", concept: "zero exponent")?.pKnown ?? 0, 0.2)
        // The confident mistake: re-check tomorrow, its flashcard brought forward, the misconception remembered.
        let follow = study.openFollowUps()
        XCTAssertEqual(follow.map(\.concept), ["product of powers"])
        XCTAssertLessThan(follow[0].due, Date().addingTimeInterval(1.01 * 86400))
        XCTAssertLessThan(study.allCards().first { $0.id == cardID }!.due, Date().addingTimeInterval(1.01 * 86400))
        let mis = services.memory.learner.top(kinds: [.misconception], limit: 10).map(\.content)
        XCTAssertTrue(mis.contains { $0.contains("multiplies the exponents") }, "\(mis)")
        XCTAssertTrue(mis.contains { $0.contains("confuses base and exponent") }, "\(mis)")
        // Calibration counts unaided graded answers by certainty.
        let cal = study.calibration()
        XCTAssertEqual(cal[.sure]?.answers, 1); XCTAssertEqual(cal[.sure]?.right, 0)
        XCTAssertEqual(cal[.guess]?.right, 1)
        XCTAssertNil(cal[.unsure], "the hinted answer is left out of calibration")
        XCTAssertEqual(study.helpUsed().hints, 1)
    }

    /// A concept missed again in the same lesson gets a worked example, not another quiz (a live run chained four retries).
    func testASecondMissInTheLessonAsksForAWorkedExample() async throws {
        let interactions = await MainActor.run { InteractionCenter() }
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        func quiz(_ id: String, lesson: String) async throws -> String {
            let ctx = ToolContext(conversationID: lesson, workspace: dir, services: services, interactions: interactions, toolCallID: id,
                                  client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
            let input: JSON = ["title": "Fractions", "questions": [["type": "single_choice", "prompt": "1/3 + 1/4?", "options": ["2/7", "7/12"], "answer": 1, "concept": "adding fractions"]]]
            let run = Task { try await QuizTool().run(input, ctx) }
            for _ in 0..<200 where await MainActor.run(body: { interactions.pending[id] == nil }) { try await Task.sleep(nanoseconds: 5_000_000) }
            await MainActor.run { interactions.resolve(id, ["answers": [0]]) }
            return try await run.value.text
        }
        let first = try await quiz("q1", lesson: "lesson-a")
        XCTAssertTrue(first.contains("never quiz the same point twice in a row") && !first.contains("missed again"), first)
        let second = try await quiz("q2", lesson: "lesson-a")
        XCTAssertTrue(second.contains("Q1 (adding fractions): missed again in this lesson") && second.contains("worked example"), second)
        XCTAssertFalse(second.contains("never quiz the same point twice"), "only the worked-example step for a repeat miss")
        let other = try await quiz("q3", lesson: "lesson-b")
        XCTAssertFalse(other.contains("missed again"), "another lesson starts fresh")
    }

    /// A live re-check never settled: the model wrapped every math key ({"item": …}, ["…"]) and nothing was auto-graded.
    func testWrappedAnswerKeysStillGrade() async throws {
        let q = Questions.normalize([["type": "math", "prompt": "d/dx 2√(3x+1)?", "answer": ["item": "3/sqrt(3*x+1)"]]])[0]
        XCTAssertEqual(q["answer"]?.string, "3/sqrt(3*x+1)")
        let n = Questions.normalize([["type": "numeric", "prompt": "2^3", "answer": ["value": 8]]])[0]
        let g = await Questions.grade(n, answer: "8")
        XCTAssertEqual(g.correct, true)
        let forms: JSON = ["type": "math", "answer": ["3*x*sqrt(x**2+1)", "3x\\sqrt{x^2+1}"]]
        let right = await Questions.grade(forms, answer: "3*x*(x^2+1)^(1/2)")
        let wrong = await Questions.grade(forms, answer: "3*(x^2+1)^(3/2)")
        if right.correct == nil { throw XCTSkip("SymPy isn't installed") }
        XCTAssertEqual(right.correct, true, "any accepted form counts")
        XCTAssertEqual(wrong.correct, false)
        XCTAssertTrue(QuizTool.feedbackSteps(wrong: 0, sureButWrong: [], luckyGuesses: [], hinted: 0, ungraded: 1).contains("record each with `mastery`"))
        XCTAssertFalse(QuizTool.feedbackSteps(wrong: 0, sureButWrong: [], luckyGuesses: [], hinted: 0, ungraded: 1).contains("Praise specifically"))
    }

    /// A live re-check on "the chain rule" stayed open: the tutor's question said "chain rule".
    func testFollowUpsMatchConceptNamesLoosely() {
        let t0 = Date()
        study.scheduleFollowUp(subject: "calculus", concept: "the chain rule", kind: .recheck, note: nil, after: -0.1, now: t0)
        study.scheduleFollowUp(subject: "calculus", concept: "Chain rule", kind: .recheck, note: "dup", after: 1, now: t0)
        XCTAssertEqual(study.openFollowUps().count, 1, "one re-check per concept, whatever the wording")
        _ = study.recordAttempt(subject: "calculus", concept: "Chain Rule", correct: true, note: nil, now: t0)
        XCTAssertTrue(study.openFollowUps().isEmpty)
    }

    func testGradedQuestionsNeedAKey() {
        let open: JSON = ["type": "math", "prompt": "d/dx (3x^2+1)^5?", "concept": "chain rule"]
        XCTAssertTrue(Questions.validate([open], graded: true).first?.contains("needs `answer`") ?? false)
        XCTAssertTrue(Questions.validate([open], graded: false).isEmpty, "an ungraded form needs no key")
        XCTAssertTrue(Questions.validate([["type": "long_text", "prompt": "Explain why."]], graded: true).isEmpty, "the teacher grades open answers")
        XCTAssertTrue(Questions.validate([["type": "true_false", "prompt": "x^0 = 1", "answer": false]], graded: true).isEmpty, "false is a key")
    }

    func testFollowUpNotesShowMathAsText() {
        XCTAssertEqual(StudyProgressView.plainMath("misconception: adds straight across: $\\frac{1+3}{6+4}$"), "misconception: adds straight across: (1+3)/(6+4)")
        XCTAssertEqual(StudyProgressView.plainMath("$\\frac{3}{4} \\cdot x \\leq \\pi$"), "3/4 · x ≤ π")
        XCTAssertEqual(StudyProgressView.plainMath("no math here"), "no math here")
    }

    func testCalibrationReading() {
        XCTAssertTrue(StudyProgressView.calibrationReading([.sure: (10, 6)]).contains("60%"))
        XCTAssertTrue(StudyProgressView.calibrationReading([.sure: (10, 10)]).contains("almost always"))
        XCTAssertTrue(StudyProgressView.calibrationReading([.guess: (6, 5), .sure: (10, 9)]).contains("guesses"))
        XCTAssertTrue(StudyProgressView.calibrationReading([.sure: (3, 0)]).contains("few more"), "too few answers to say")
    }

    func testFollowUpSectionTellsTheTutorWhatToBringUp() {
        let now = Date()
        let s = TeachingContextExtension.followUpSection([
            FollowUp(id: 1, subject: "algebra", concept: "product of powers", kind: .recheck, note: "misconception: multiplies exponents", due: now, createdAt: now.addingTimeInterval(-2 * 86400)),
            FollowUp(id: 2, subject: "physics", concept: "momentum", kind: .transfer, note: nil, due: now, createdAt: now),
        ], now: now)
        XCTAssertTrue(s.contains("re-check: product of powers (algebra, 2 days ago) — misconception: multiplies exponents"), s)
        XCTAssertTrue(s.contains("transfer check: momentum (physics, today)"), s)
        XCTAssertTrue(s.contains("never the old question again"))
    }

    func testEveryTeachingModeIsAttemptFirst() {
        for mode in TeachingMode.allCases where !mode.isAgent {
            let p = SystemPrompt.build(settings: AppSettings(), mode: mode, coreMemory: "", model: "m")
            XCTAssertTrue(p.contains("Attempt first, in every mode") && p.contains("```problem {"), "\(mode)")
            XCTAssertTrue(p.contains("Only unaided success counts"), "\(mode)")
        }
        XCTAssertFalse(SystemPrompt.buildAgent(settings: AppSettings(), folder: dir, model: "m", projectMemory: "").contains("```problem"))
    }
}
