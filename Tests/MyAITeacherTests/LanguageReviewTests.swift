import XCTest
@testable import MyAITeacher

/// Fixes from review: extra words count, vowel signs and kana voicing are letters (never folded), not-pinyin stays as typed.
final class LanguageReviewTests: XCTestCase {
    func testExtraWordsLowerTheScore() async {
        XCTAssertLessThan(TextDiff.align(target: "el gato negro", given: "el gato negro come mucho").score, 1)
        let g = await Questions.grade(["type": "dictation", "prompt": "x", "listen": "el gato negro"], answer: "el gato negro come mucho")
        XCTAssertEqual(g.correct, false, "added words aren't the dictation")
    }
    func testMarksThatAreLettersAreNeverFolded() {
        XCTAssertNotEqual(Questions.norm("कि"), Questions.norm("का"), "Devanagari vowel signs differ")
        XCTAssertNotEqual(Questions.norm("が"), Questions.norm("か"), "kana voicing differs")
        XCTAssertNotEqual(Questions.norm("ที่"), Questions.norm("ท"), "Thai marks stay")
        XCTAssertEqual(Questions.norm("café"), Questions.norm("cafe"), "Latin accents still fold when not strict")
        XCTAssertEqual(Questions.norm("Ёлка"), Questions.norm("елка"), "Cyrillic too")
        XCTAssertEqual(Questions.norm("مُعَلِّمًا"), Questions.norm("معلما"), "harakat optional")
        XCTAssertNotEqual(Questions.norm("مُعَلِّمًا", strict: true), Questions.norm("معلما", strict: true), "unless strict")
    }
    func testWhatIsntPinyinStaysAsTyped() {
        XCTAssertNil(ScriptComposer.setTone("Chapter", 3))
        XCTAssertNil(ScriptComposer.setTone("level", 2))
        XCTAssertEqual(ScriptComposer.setTone("zhongwen", 2)?.text, "wén")
    }
}
