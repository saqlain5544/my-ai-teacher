import XCTest
@testable import MyAITeacher

/// The redesigned keyboard: the Mac's keys type each script in its standard layout, tones by key or digit, Devanagari
/// vowel signs, kanji candidates from the learner's own words — the same rules on the page and in the composer.
final class LanguageKeyboardTests: XCTestCase {
    func testMacKeysTypeTheScriptInItsStandardLayout() {
        let ru = KeyboardLayouts.shared["ru"]!, ar = KeyboardLayouts.shared["ar"]!, ko = KeyboardLayouts.shared["ko"]!, hi = KeyboardLayouts.shared["hi"]!
        XCTAssertEqual(ru.inputModes, ["tap", "keys"])
        XCTAssertEqual(KeyboardLayouts.physicalChar(ru, keyCode: 12, shift: false), "й", "Q is й on ЙЦУКЕН")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ru, keyCode: 12, shift: true), "Й")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ru, keyCode: 41, shift: false), "ж", "; is ж")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ar, keyCode: 0, shift: false), "ش", "A is ش on Arabic PC")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ar, keyCode: 11, shift: false), "لا", "B is lam-alef")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ar, keyCode: 12, shift: true), "\u{064E}", "shift-Q is fatha")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ko, keyCode: 15, shift: false), "ㄱ", "R is ㄱ on 2-set Korean")
        XCTAssertEqual(KeyboardLayouts.physicalChar(ko, keyCode: 40, shift: false), "ㅏ", "K is ㅏ")
        XCTAssertEqual(KeyboardLayouts.physicalChar(hi, keyCode: 40, shift: false), "क", "K is क on InScript")
        XCTAssertNil(KeyboardLayouts.physicalChar(ru, keyCode: 49, shift: false), "space is not remapped")
        XCTAssertNil(KeyboardLayouts.physicalChar(KeyboardLayouts.shared["es"]!, keyCode: 12, shift: false), "Latin layouts type as usual")
        XCTAssertEqual(KeyboardLayouts.shared["ja"]!.inputModes, ["kana", "romaji"])
        for (code, l) in KeyboardLayouts.shared { if let p = l.physical { XCTAssertEqual(p.count, 3, code); XCTAssertLessThanOrEqual(p[0].count, 12, code) } }
    }

    func testTheKanaTableIsAGrid() {
        let ja = KeyboardLayouts.shared["ja"]!
        let letters = ja.rows.filter { $0.contains(.text("あ")) || $0.contains(.text("い")) || $0.contains(.text("う")) || $0.contains(.text("え")) || $0.contains(.text("お")) }
        XCTAssertEqual(letters.count, 5, "one row per vowel")
        XCTAssertEqual(Set(letters.map(\.count)).count, 1, "rows of equal length (gaps keep the columns)")
        XCTAssertEqual(ja.rows[1][7], .text(""), "no yi: a gap")
    }

    func testPinyinTonesByKeyOrDigit() {
        XCTAssertEqual(ScriptComposer.setTone("ni", 3)?.text, "nǐ")
        XCTAssertEqual(ScriptComposer.setTone("hǎo", 4)?.text, "hào", "replaces a tone")
        XCTAssertEqual(ScriptComposer.setTone("zhōng", 0)?.text, "zhong", "neutral clears it")
        XCTAssertEqual(ScriptComposer.setTone("xue", 2)?.text, "xué")
        XCTAssertEqual(ScriptComposer.setTone("liu", 2)?.text, "liú", "the last of i/u")
        XCTAssertEqual(ScriptComposer.setTone("wo ai", 4)?.remove, 2, "only the syllable before the caret")
        XCTAssertNil(ScriptComposer.setTone("", 1))
        XCTAssertEqual(ScriptComposer.setTone("nǐhao", 3)?.remove, 3, "the last syllable only (ni3hao3 → nǐhǎo)")
        XCTAssertEqual(ScriptComposer.setTone("nǐhao", 3)?.text, "hǎo")
        XCTAssertEqual(ScriptComposer.lastSyllable("zhongguo"), "guo")
    }

    func testDevanagariVowelSigns() {
        XCTAssertEqual(ScriptComposer.abugida(prev: "क", "आ"), "\u{093E}")
        XCTAssertEqual(ScriptComposer.abugida(prev: "क", "अ"), "", "the inherent vowel adds nothing")
        XCTAssertNil(ScriptComposer.abugida(prev: "आ", "इ"), "after a vowel a vowel letter stays a letter")
        XCTAssertNil(ScriptComposer.abugida(prev: nil, "इ"))
        XCTAssertEqual(ScriptComposer.abugida(prev: "ক", "ি"), nil, "a sign typed directly is inserted as it is")
        XCTAssertEqual(ScriptComposer.abugida(prev: "ক", "ই"), "\u{09BF}", "Bengali too")
    }

    func testKanjiCandidatesComeFromTheLearnersWords() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("kbd-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
        _ = services.study.addVocab(lang: "ja", term: "食べる", reading: "たべる taberu", meaning: "to eat")
        _ = services.study.addVocab(lang: "ja", term: "担当", reading: "tantou", meaning: "in charge")   // romaji only: the tokenizer reads it
        _ = services.study.addVocab(lang: "ja", term: "りんご", reading: "ringo", meaning: "apple")       // no kanji: nothing to offer
        let words = services.study.kanaWords(lang: "ja")
        XCTAssertTrue(words.contains { $0.term == "食べる" && $0.kana == "たべる" }, "\(words)")
        XCTAssertTrue(words.contains { $0.term == "担当" && $0.kana == "たんとう" }, "\(words)")
        XCTAssertFalse(words.contains { $0.term == "りんご" })
        XCTAssertTrue(services.study.kanaWords(lang: "ko").isEmpty)
    }
}
