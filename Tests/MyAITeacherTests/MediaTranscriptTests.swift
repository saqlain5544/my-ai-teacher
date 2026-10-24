import XCTest
@testable import MyAITeacher

/// Real audio for listening: speech cut at its pauses, sentences timed, and (when Whisper is installed in
/// /tmp/sp-e2e/app/support/speech) a recording made with `say` transcribed end to end.
final class MediaTranscriptTests: XCTestCase {
    private func tone(_ seconds: Double, _ amp: Float = 0.3) -> [Float] {
        (0..<Int(seconds * 16_000)).map { i in amp * sinf(Float(i) * 2 * .pi * 220 / 16_000) }
    }
    private func silence(_ seconds: Double) -> [Float] { [Float](repeating: 0.0005, count: Int(seconds * 16_000)) }

    func testSpeechIsCutAtItsPauses() {
        let s = silence(0.5) + tone(3) + silence(2) + tone(4) + silence(0.2) + tone(1) + silence(1)
        let c = MediaTranscript.chunks(s)
        XCTAssertEqual(c.count, 2, "\(c)")
        XCTAssertEqual(c[0].0, 0.35, accuracy: 0.1); XCTAssertEqual(c[0].1, 3.65, accuracy: 0.15)
        XCTAssertEqual(c[1].0, 5.35, accuracy: 0.15, "a short pause (0.2 s) doesn't split"); XCTAssertEqual(c[1].1, 10.85, accuracy: 0.2)
        let long = MediaTranscript.chunks(tone(60))
        XCTAssertTrue(long.allSatisfy { $0.1 - $0.0 <= 26.5 }, "Whisper reads 30 s at most: \(long)")
        XCTAssertTrue(MediaTranscript.chunks(silence(5)).isEmpty, "silence has no speech")
    }

    func testSentencesShareTheirStretchesTime() {
        let s = MediaTranscript.sentences("Hola. ¿Qué tal estás hoy?", start: 10, end: 14, lang: "es")
        XCTAssertEqual(s.count, 2)
        XCTAssertEqual(s[0].start, 10); XCTAssertEqual(s[1].end, 14, accuracy: 0.001)
        XCTAssertLessThan(s[0].end - s[0].start, s[1].end - s[1].start, "by length")
        let t = MediaTranscript.Transcript(segments: s, duration: 75, engine: "Whisper", language: "es")
        XCTAssertTrue(MediaTranscript.text(t, name: "clip.mp3").contains("[0:10] Hola."))
        XCTAssertEqual(MediaTranscript.json(t, file: "a.mp3")["segments"]?.array?.count, 2)
    }

    func testARecordingIsTranscribedWithTimesByWhisper() async throws {
        let installed = URL(fileURLWithPath: "/tmp/sp-e2e/app/support/speech")
        guard FileManager.default.fileExists(atPath: installed.appendingPathComponent("whisper/.installed").path) else { throw XCTSkip("Whisper isn't installed in the shared test profile") }
        try? FileManager.default.removeItem(at: OpenSpeech.root)
        try FileManager.default.createDirectory(at: OpenSpeech.root.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: OpenSpeech.root, withDestinationURL: installed)
        defer { try? FileManager.default.removeItem(at: OpenSpeech.root) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("media-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("clip.aiff")
        let r = await ProcessRunner.run("/usr/bin/say", ["-v", "Mónica", "-o", file.path, "Hola, me llamo Marta. [[slnc 1500]] Trabajo en una oficina en Madrid. [[slnc 1500]] Los viernes trabajo desde casa."])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let t = try await MediaTranscript.transcribe(file, lang: "es") { _, _ in }
        let all = t.segments.map(\.text).joined(separator: " ").lowercased()
        XCTAssertTrue(all.contains("marta") && all.contains("madrid") && all.contains("viernes"), all)
        XCTAssertGreaterThanOrEqual(t.segments.count, 3)
        XCTAssertTrue(zip(t.segments, t.segments.dropFirst()).allSatisfy { $0.0.start < $0.1.start }, "in order")
        XCTAssertGreaterThan(t.segments.last!.start, 3, "later sentences start later in the recording")
        XCTAssertTrue(t.engine.contains("Whisper"))
    }
}
