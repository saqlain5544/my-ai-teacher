import XCTest
@testable import MyAITeacher

/// The spoken conversation: a turn ends after voice then quiet; the mentor is told to talk, not correct, until the end.
final class ConversationTests: XCTestCase {
    private func feed(_ w: Speech.SilenceWatch, _ amp: Float, seconds: Double) -> Bool {
        var fired = false
        let n = 1600   // 0.1 s buffers at 16 kHz
        for k in 0..<Int(seconds * 10) {
            let buf = (0..<n).map { i in amp * sinf(Float(i + k * n) * 2 * .pi * 200 / 16_000) }
            buf.withUnsafeBufferPointer { if w.feed($0) { fired = true } }
        }
        return fired
    }
    func testATurnEndsAfterVoiceThenAPause() {
        let w = Speech.SilenceWatch(after: 1.4, rate: 16_000)
        XCTAssertFalse(feed(w, 0.0005, seconds: 3), "silence before speaking never ends a turn")
        XCTAssertFalse(feed(w, 0.2, seconds: 2), "speaking")
        XCTAssertFalse(feed(w, 0.0005, seconds: 1.0), "a short pause mid-sentence")
        XCTAssertFalse(feed(w, 0.2, seconds: 1), "more speech")
        XCTAssertTrue(feed(w, 0.0005, seconds: 1.6), "then a real pause ends it")
        XCTAssertFalse(feed(w, 0.0005, seconds: 2), "once")
        let quiet = Speech.SilenceWatch(after: 1.4, rate: 16_000)
        XCTAssertFalse(feed(quiet, 0.2, seconds: 0.2) || feed(quiet, 0.0005, seconds: 3), "a cough (0.2 s) isn't a turn")
    }
    @MainActor func testTheMentorTalksNowAndCorrectsAtTheEnd() {
        let turn = ConversationController.turnNote("es"), end = ConversationController.endNote("es")
        XCTAssertTrue(turn.contains("Spanish only") && turn.contains("Don't correct") && turn.contains("read aloud"), turn)
        XCTAssertTrue(end.contains("```correction") && end.contains("mishearing"), end)
    }
}
