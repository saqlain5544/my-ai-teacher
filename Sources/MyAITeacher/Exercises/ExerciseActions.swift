import Foundation

/// What a learner does with an exercise, from the editor or the debug hooks.
@MainActor
enum ExerciseActions {
    /// Runs the hidden tests on the learner's current work, records it, and sends it to their teacher.
    @discardableResult
    static func submit(_ id: String) async -> Sandbox.Result? {
        guard var e = ExerciseStore.load(id) else { return nil }
        let r = await ExerciseStore.runTests(e, project: e.dir)
        e.attempts += 1; e.submitted += 1
        e.passed = e.passed || r.passed
        e.lastOutput = String(r.output.suffix(20_000))
        ExerciseStore.save(e)
        send(e, result: r)
        return r
    }

    /// The learner's submission reaches their teacher: a short message, with their files and the test output as
    /// hidden context. A pass on the hidden tests also counts as unaided practice on the exercise's concept.
    static func send(_ e: Exercise, result r: Sandbox.Result) {
        let app = AppModel.shared
        guard let s = app.session(for: e.conversationID) else { return }
        if let concept = e.concept {
            s.services.study.recordAttempt(subject: e.subject ?? e.language, concept: concept, correct: r.passed, note: nil)
            EventBus.publish(.studyDataChanged)
        }
        let context = "<context>\nThe learner submitted their exercise. Review what they wrote (judge it as a senior engineer would: correctness, " +
            "design, edge cases, clarity, performance where it matters). Never write their code or show the solution.\n\n" +
            ExerciseTool.describe(e, files: ExerciseStore.read(e.dir)) + "\n\n--- hidden tests on this submission: \(r.passed ? "PASS" : "FAIL (exit \(r.exitCode))")\n" +
            String(r.output.suffix(10_000)) + "\n</context>"
        s.send("I've submitted “\(e.title)”: " + (r.passed ? "the tests pass." : "some tests still fail."),
               attachments: [Block(kind: .text, text: context, meta: ["hidden": true])])
        if case .lesson(let current) = app.selection, current == e.conversationID {} else { app.selection = .lesson(e.conversationID) }
    }
}
