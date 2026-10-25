import XCTest
@testable import MyAITeacher

final class FeatureTests: XCTestCase {
    func testGraderChoiceAndNumeric() async {
        let mc: JSON = ["type": "single_choice", "prompt": "?", "options": ["a", "b"], "answer": 1]
        let g1 = await Questions.grade(mc, answer: 1)
        XCTAssertEqual(g1.correct, true)
        let multi: JSON = ["type": "multiple_choice", "options": ["a", "b", "c"], "answer": [0, 2]]
        let g2 = await Questions.grade(multi, answer: [0])
        XCTAssertEqual(g2.correct, false)
        XCTAssertEqual(g2.score ?? -1, 0.5, accuracy: 0.001)
        let num: JSON = ["type": "numeric", "answer": 0.75]
        let g3 = await Questions.grade(num, answer: "3/4")
        XCTAssertEqual(g3.correct, true)
    }

    func testGraderBlanksOrderingMatching() async {
        let fb: JSON = ["type": "fill_blanks", "text": "{{}} and {{}}", "answer": [["Paris", "paris"], "Lyon"]]
        let g = await Questions.grade(fb, answer: ["PARIS", "Lyon!"])
        XCTAssertEqual(g.correct, true)
        let ord: JSON = ["type": "ordering", "items": ["a", "b", "c"]]
        let o1 = await Questions.grade(ord, answer: [0, 1, 2])
        XCTAssertEqual(o1.correct, true)
        let o2 = await Questions.grade(ord, answer: [1, 0, 2])
        XCTAssertEqual(o2.correct, false)
        let mt: JSON = ["type": "matching", "pairs": [["x", "1"], ["y", "2"]]]
        let m1 = await Questions.grade(mt, answer: [0, 1])
        XCTAssertEqual(m1.correct, true)
    }

    func testMathEquivalence() async {
        XCTAssertEqual(MathEquivalence.toSympy("\\frac{1}{2}x^{2}"), "((1)/(2))x^(2)")
        let eq = await MathEquivalence.equivalent("5x", "5*x")
        XCTAssertEqual(eq, true)
        let neq = await MathEquivalence.equivalent("\\frac{x}{2}", "2x")
        XCTAssertEqual(neq, false)
        // Equations: same up to swapping sides or scaling; a bare value against "x = value".
        for (g, e, want) in [("2=x", "x=2", true), ("2x-y=0", "y=2x", true), ("4x=8", "x=2", true), ("x=3", "x=2", false),
                             ("2", "x=2", true), ("3", "x=2", false)] {
            let r = await MathEquivalence.equivalent(g, e)
            XCTAssertEqual(r, want, "\(g) vs \(e)")
        }
    }

    func testMultipleChoiceGradedFromOptionText() async {
        let q: JSON = ["type": "multiple_choice", "options": ["2", "4", "5"], "answer": ["2", "5"]]
        let g = await Questions.grade(q, answer: [0, 2])
        XCTAssertEqual(g.correct, true)
        let t = await Questions.grade(q, answer: ["5", "2"])
        XCTAssertEqual(t.correct, true)
    }

    func testSingleChoiceKeyNamesAnOption() async {
        // A string key is the option's text first: "2" among "1","2","3","4" is option 1, not index 2.
        let q: JSON = ["type": "single_choice", "prompt": "1 + 1?", "options": ["1", "2", "3", "4"], "answer": "2"]
        let right = await Questions.grade(q, answer: 1)
        XCTAssertEqual(right.correct, true)
        XCTAssertEqual(right.expected, "2")
        XCTAssertEqual(Questions.reviewKey(q), 1, "the review card highlights the option by index")
        // What the learner typed under "Other…" is text, never an option index.
        let other = await Questions.grade(["type": "single_choice", "options": ["a", "b", "c"], "answer": 2], answer: "2")
        XCTAssertNotEqual(other.correct, true)
        // A key that names no option (1-based, a letter) goes back to the model instead of marking everyone wrong.
        for bad: JSON in [4, -1, "D"] {
            let errs = Questions.validate([["type": "single_choice", "prompt": "?", "options": ["red", "green", "blue", "grey"], "answer": bad]])
            XCTAssertTrue(errs.contains { $0.contains("0-based index") }, "\(bad): \(errs)")
            let g = await Questions.grade(["type": "single_choice", "options": ["red", "green", "blue", "grey"], "answer": bad], answer: 3)
            XCTAssertNil(g.correct, "\(bad) grades nothing (and never traps)")
        }
        XCTAssertTrue(Questions.validate([["type": "multiple_choice", "prompt": "?", "options": ["a", "b"], "answer": [0, "b"]]]).isEmpty)
        XCTAssertFalse(Questions.validate([["type": "multiple_choice", "prompt": "?", "options": ["a", "b"], "answer": [0, 2]]]).isEmpty)
    }

    func testShortTextNeedsTeacherWhenUnmatched() async {
        let q: JSON = ["type": "short_text", "answer": ["photosynthesis"]]
        let ok = await Questions.grade(q, answer: "Photosynthesis.")
        XCTAssertEqual(ok.correct, true)
        let unsure = await Questions.grade(q, answer: "plants making food from light")
        XCTAssertNil(unsure.correct)
    }

    func testScriptRunsAndLanguages() {
        let runs = ScriptRuns.runs("The word مرحبا means hello, and 漢字かな is Japanese.")
        XCTAssertTrue(runs.contains { $0.script == .arabic && $0.text.contains("مرحبا") })
        XCTAssertTrue(runs.contains { $0.script == .kana })
        let segs = Speech.segments("Hello there, how are you today? مرحبا يا صديقي", base: "en")
        XCTAssertEqual(segs.first?.1, "en")
        XCTAssertEqual(segs.last?.1, "ar")
    }

    func testWorkspacePaths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("ws-test-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ws = try Workspace(url: dir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent(".teacher/state.sqlite").path))
        XCTAssertTrue(ws.contains(dir.appendingPathComponent("notes/a.md")))
        XCTAssertFalse(ws.contains(URL(fileURLWithPath: "/tmp/x")))
        XCTAssertTrue(ws.isStatePath(dir.appendingPathComponent(".teacher/state.sqlite")))
        XCTAssertFalse(ws.contains(dir.deletingLastPathComponent().appendingPathComponent(dir.lastPathComponent + "-evil/x")))
        try? FileManager.default.removeItem(at: dir)
    }

    func testMemoryHubScopedIDs() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mem-test-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let learnerDB = try Database(path: dir.appendingPathComponent("l.sqlite").path)
        try learnerDB.script(Schema_.sql)
        let ws = try Workspace(url: dir)
        let hub = MemoryHub(learner: MemoryStore(db: learnerDB, scope: .learner), folder: ws.memory)
        let a = hub.add(kind: .goal, content: "Wants to pass the AP Calculus exam", scope: .learner)
        let b = hub.add(kind: .fact, content: "This folder holds the thesis drafts", scope: .folder)
        XCTAssertFalse(a.id.hasPrefix("f"))
        XCTAssertTrue(b.id.hasPrefix("f"))
        XCTAssertEqual(hub.get(b.id)?.scope, .folder)
        XCTAssertTrue(hub.coreBlock().contains("About this folder"))
        hub.delete(b.id)
        XCTAssertNil(hub.get(b.id))
        try? FileManager.default.removeItem(at: dir)
    }

    func testLanguageDetectionIsConservative() {
        let physics = """
        **Given:** $v_0 = 20$ m/s, $\\theta = 30^\\circ$. Time of flight $T = 2 v_0 \\sin\\theta / g \\approx 2.04$ s.
        Max height $H = v_0^2 \\sin^2\\theta / (2g) \\approx 5.10$ m. Range $R \\approx 35.3$ m. Both formulas match.
        """
        XCTAssertEqual(LanguageExtension.languages(in: physics), ["en"])
        let mixed = "In Arabic, hello is <span lang=\"ar\">مرحبا</span> and thank you is شكرا. Practise them every morning with a friend."
        let langs = LanguageExtension.languages(in: mixed)
        XCTAssertTrue(langs.contains("en") && langs.contains("ar"), "\(langs)")
    }

    /// Long text is embedded in ≤400-character pieces cut at spaces (bounded model memory) and averaged into one vector.
    func testEmbedderPiecesLongText() throws {
        let text = String(repeating: "The chain rule differentiates composite functions such as sin(x^2). ", count: 30) + String(repeating: "x", count: 900)
        let pieces = Embedder.pieces(String(text.prefix(2000)), max: Embedder.pieceLength)
        XCTAssertTrue(pieces.allSatisfy { !$0.isEmpty && $0.count <= Embedder.pieceLength })
        XCTAssertEqual(pieces.joined(separator: " "), String(text.prefix(2000)), "nothing lost or reordered")
        XCTAssertEqual(Embedder.pieces("short question", max: 400), ["short question"])
        let long = try XCTUnwrap(Embedder.shared.vector(text)), short = try XCTUnwrap(Embedder.shared.vector("The chain rule differentiates composite functions."))
        XCTAssertEqual(long.count, short.count)
        XCTAssertGreaterThan(Embedder.cosine(long, short), 0.5, "the averaged vector still means the same thing")
    }

    /// The reflection excerpt is built newest-first and stops when full; it must equal rendering the whole lesson and
    /// keeping the tail.
    func testTranscriptExcerptMatchesTheWholeLessonTail() {
        func reference(_ messages: [ChatMessage], maxChars: Int) -> String {
            var parts: [String] = []
            for m in messages {
                for b in m.blocks {
                    switch b.kind {
                    case .text where b.meta?["hidden"]?.bool != true: parts.append("[\(m.role == .user ? "Learner" : "Teacher")]: \(b.text ?? "")")
                    case .toolUse where !(b.name ?? "").hasPrefix("memory"): parts.append("[Teacher used \(b.name ?? "tool")]: \((b.input ?? .null).compact.prefix(300))")
                    case .toolResult where ["quiz", "ask_learner"].contains(b.name ?? ""): parts.append("[Result of \(b.name ?? "")]: \((b.text ?? "").prefix(1200))")
                    case .image: parts.append("[Learner attached an image]")
                    case .file: parts.append("[Learner attached file \(b.name ?? "")]")
                    default: break
                    }
                }
            }
            var s = parts.joined(separator: "\n\n")
            if s.count > maxChars { s = "…" + String(s.suffix(maxChars)) }
            return s
        }
        let lesson = (0..<1200).map { PerfSeed.message($0) } + [ChatMessage(role: .user, blocks: [Block(kind: .text, text: "<context>x</context>", meta: ["hidden": true]), .text("Last question")])]
        for n in [0, 3, 9, 40, 1201] {
            for maxChars in [100, 999, 14_000, 60_000] {
                XCTAssertEqual(Reflection.transcriptExcerpt(Array(lesson.suffix(n)), maxChars: maxChars), reference(Array(lesson.suffix(n)), maxChars: maxChars), "\(n) messages, \(maxChars)")
            }
        }
    }

    func testEmbedderIsSafeUnderConcurrency() async {
        await withTaskGroup(of: Int.self) { g in
            for i in 0..<64 { g.addTask { Embedder.shared.vector("concurrent memory search number \(i) about derivatives")?.count ?? 0 } }
            var n = 0
            for await c in g { n += c > 0 ? 1 : 0 }
            XCTAssertEqual(n, 64)
        }
    }

    func testSpeechSegmentsJapaneseInEnglish() {
        let text = Speech.speakable("Exactly right! <span lang=\"ja\">ありがとうございます</span> is the polite form, and to a barista that's the natural choice. One way to feel the difference: ありがとう on its own is roughly thanks.")
        let segs = Speech.segments(text, base: "en")
        XCTAssertEqual(segs.map(\.1), ["en", "ja", "en", "ja", "en"])
        XCTAssertNotNil(Speech.bestVoice("ja"), "a Japanese voice should be available")
        XCTAssertNotNil(Speech.bestVoice("ar"))
    }
}
