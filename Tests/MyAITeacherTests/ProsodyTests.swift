import XCTest
@testable import MyAITeacher

/// Pronunciation from pitch: Mandarin tones per syllable, the Japanese accent drop, stress in a word — on synthetic
/// contours, and on Apple's voices rendered with `say` (where the method must recover what the text expects).
final class ProsodyTests: XCTestCase {
    /// Syllables of 220 ms with the given pitch paths (Hz from → to, via a midpoint), 120 ms of near-silence between.
    private func syllables(_ paths: [(Double, Double, Double)], rate: Double = 16_000) -> [Float] {
        var out: [Float] = [], phase = 0.0
        for (a, mid, b) in paths {
            let n = Int(0.22 * rate)
            for i in 0..<n {
                let t = Double(i) / Double(n)
                let f = t < 0.5 ? a + (mid - a) * t * 2 : mid + (b - mid) * (t - 0.5) * 2
                phase += 2 * .pi * f / rate
                let env = Float(sin(Double.pi * t))
                out.append(0.4 * env * Float(sin(phase)))
            }
            out += [Float](repeating: 0.0003, count: Int(0.12 * rate))
        }
        return out
    }

    func testToneShapesAreClassified() {
        XCTAssertEqual(Prosody.tone([3, 3.1, 3, 2.9, 3, 3.1]), 1)
        XCTAssertEqual(Prosody.tone([-1, -0.5, 0.5, 1.5, 2.5, 3.2]), 2)
        XCTAssertEqual(Prosody.tone([-1, -2.5, -3.5, -3.2, -2, -0.5]), 3)
        XCTAssertEqual(Prosody.tone([3, 2, 0.5, -1, -2.5, -3.5]), 4)
        XCTAssertEqual(Prosody.tone([1, 2]), 0, "too little voice")
    }

    func testSyllablesAreFoundAndToned() {
        let s = syllables([(240, 240, 240), (170, 200, 240), (170, 140, 170), (260, 210, 150)])   // 1 2 3 4
        let f0 = Pitch.track(s, sampleRate: 16_000), e = Prosody.energy(s, rate: 16_000)
        let syl = Prosody.syllables(e, f0: f0, count: 4)
        XCTAssertEqual(syl?.count, 4)
        let median = f0.compactMap { $0 }.sorted()[f0.compactMap { $0 }.count / 2]
        XCTAssertEqual(syl?.map { Prosody.tone(Prosody.contour(f0, $0, median: median)) }, [1, 2, 3, 4])
    }

    func testExpectedTonesWithSandhi() {
        XCTAssertEqual(Prosody.expectedTones("你好").map(\.tone), [2, 3], "3 3 → 2 3")
        XCTAssertEqual(Prosody.expectedTones("不是").map(\.tone), [2, 4], "不 before a fourth tone")
        XCTAssertEqual(Prosody.expectedTones("妈麻马骂").map(\.tone), [1, 2, 3, 4])
        XCTAssertEqual(Prosody.morae("きょうと"), ["きょ", "う", "と"])
        XCTAssertEqual(Prosody.morae("にっぽん"), ["に", "っ", "ぽ", "ん"])
        XCTAssertEqual(Prosody.writtenSyllables("trabajamos"), ["tra", "ba", "ja", "mos"])
    }

    /// Apple's Mandarin voice saying the four tones: the method should recover most of them from a real voice.
    func testTonesAreRecoveredFromARealVoice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("tones-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("t.aiff")
        let r = await ProcessRunner.run("/usr/bin/say", ["-v", "Tingting", "-o", file.path, "妈 [[slnc 300]] 麻 [[slnc 300]] 马 [[slnc 300]] 骂"])
        guard r.exitCode == 0 else { throw XCTSkip("No Mandarin voice: \(r.stderr)") }
        let s = try await MediaTranscript.samples(file)
        let j = Prosody.mandarin(target: "妈麻马骂", learner: s, learnerRate: 16_000, reference: s, refRate: 16_000)
        let rows = j?["syllables"]?.array ?? []
        let heard = rows.compactMap { $0["heard"]?.int }
        print("Tingting tones heard:", heard)
        XCTAssertEqual(rows.count, 4)
        XCTAssertGreaterThanOrEqual(zip(heard, [1, 2, 3, 4]).filter { $0 == $1 }.count, 3, "at least three of four tones recovered: \(heard)")
    }

    func testStressInAWord() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("stress-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("w.aiff")
        let r = await ProcessRunner.run("/usr/bin/say", ["-v", "Mónica", "-o", file.path, "teléfono"])
        guard r.exitCode == 0 else { throw XCTSkip("No Spanish voice") }
        let s = try await MediaTranscript.samples(file)
        let j = Prosody.stress(target: "teléfono", learner: s, learnerRate: 16_000, reference: s, refRate: 16_000)
        print("teléfono stressed syllable:", j?["learner"]?.int as Any)
        XCTAssertEqual(j?["syllables"]?.array?.count, 4)
        XCTAssertNotNil(j?["learner"]?.int)
    }

    /// 雨 (あ'め, falls after the first mora) against 飴 (あめ, no fall), as Apple's Japanese voice says them.
    func testAccentDropFromARealVoice() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("accent-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        var heard: [Int?] = []
        for word in ["雨", "飴"] {
            let file = dir.appendingPathComponent("\(word).aiff")
            let r = await ProcessRunner.run("/usr/bin/say", ["-v", "Kyoko", "-o", file.path, word])
            guard r.exitCode == 0 else { throw XCTSkip("No Japanese voice") }
            let s = try await MediaTranscript.samples(file)
            let j = Prosody.japanese(target: word, learner: s, learnerRate: 16_000, reference: s, refRate: 16_000)
            XCTAssertEqual(j?["morae"]?.array?.count, 2)
            heard.append(j?["learner"]?.int)
        }
        XCTAssertEqual(heard, [1, 0])
    }

    /// What the lesson reads: what was measured, and the misses by name.
    func testSummaryForTheLesson() {
        let tones: JSON = ["kind": "tones", "syllables": [
            ["char": "你", "pinyin": "nǐ", "expected": 2, "heard": 2, "ok": true, "measurable": true],
            ["char": "好", "pinyin": "hǎo", "expected": 3, "heard": 4, "ok": false, "measurable": true],
            ["char": "吗", "pinyin": "ma", "expected": 0, "heard": 1, "ok": false, "measurable": false]]]
        let t = Prosody.summary(tones) ?? ""
        XCTAssertTrue(t.contains("1/2 judged") && t.contains("好 hǎo expected 3rd (low), pitch looked 4th (falling)") && t.contains("1 not judged"), t)
        let a = Prosody.summary(["kind": "accent", "morae": ["あ", "め"], "learner": 0, "reference": 1]) ?? ""
        XCTAssertTrue(a.contains("learner no fall within the word") && a.contains("synthetic voice falls after mora 1 (あ)"), a)
        XCTAssertEqual(Prosody.expectedTones("一起").map(\.tone), [4, 3], "一 before a third tone")
    }
}
