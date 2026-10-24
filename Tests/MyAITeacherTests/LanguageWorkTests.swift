import XCTest
@testable import MyAITeacher

/// Serious language work: dictation and speech checked word by word (in order, Japanese by reading), written work with
/// its correction, paradigm tables, passages analysed for reading, the reading log, and due words in the state line.
final class LanguageWorkTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var study: StudyStore { services.study }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("langwork-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func testAlignmentIsWordByWordAndInOrder() {
        let d = TextDiff.align(target: "¿Dónde está la estación?", given: "donde esta la estacion")
        XCTAssertEqual(d.score, 1, "accents fold unless strict")
        let s = TextDiff.align(target: "¿Dónde está la estación?", given: "donde esta la estacion", strict: true)
        XCTAssertEqual(s.ops.filter { $0.kind == .wrong }.count, 3, "strict: three accent errors")
        XCTAssertEqual(s.wrong.first?.given, "donde"); XCTAssertEqual(s.wrong.first?.target, "Dónde")
        let order = TextDiff.align(target: "buenos días", given: "días buenos")
        XCTAssertLessThanOrEqual(order.score, 0.5, "order matters, unlike a bag of words")
        XCTAssertEqual(TextDiff.align(target: "أعمل معلمًا", given: "أعمل معلما").score, 1, "harakat are optional unless strict")
        XCTAssertLessThan(TextDiff.align(target: "أعمل معلمًا", given: "اعمل معلما").score, 1, "a missing hamza is a spelling error")
        let miss = TextDiff.align(target: "Ich habe einen Hund", given: "Ich habe Hund gesehen")
        XCTAssertEqual(miss.missing, ["einen"]); XCTAssertEqual(miss.extra, ["gesehen"])
        XCTAssertTrue(miss.summary.contains("missed “einen”"), miss.summary)
        XCTAssertEqual(TextDiff.align(target: "", given: "x").score, 0)
    }

    func testJapaneseIsComparedByReading() {
        XCTAssertEqual(TextAnalysis.japaneseKana("私は食べる。"), "わたしはたべる")
        XCTAssertEqual(TextAnalysis.japaneseKana("七時に起きます"), "しちじにおきます")
        XCTAssertEqual(TextDiff.align(target: "私は食べる", given: "わたしはたべる").score, 1, "kana for kanji is right in dictation")
        XCTAssertEqual(TextDiff.align(target: "私は食べる", given: "わたしわたべる").ops.filter { $0.kind == .wrong }.count, 1, "は written as わ is one error")
        XCTAssertLessThan(TextDiff.align(target: "私は食べる", given: "わたしはたべる", strict: true).score, 1, "strict compares the writing")
        XCTAssertEqual(TextDiff.align(target: "我喜欢喝茶", given: "我喜欢茶").missing, ["喝"], "Chinese by characters")
    }

    func testDictationAndSpeechAreGradedByTheAlignment() async {
        let q: JSON = ["type": "dictation", "prompt": "Write what you hear", "listen": "Hasta luego, Marta", "lang": "es"]
        var g = await Questions.grade(q, answer: "hasta luego marta")
        XCTAssertEqual(g.correct, true); XCTAssertEqual(g.score, 1)
        g = await Questions.grade(q, answer: "hasta lluego marta")
        XCTAssertEqual(g.correct, false); XCTAssertEqual(g.score!, 2.0 / 3, accuracy: 0.001)
        XCTAssertTrue(Questions.describeAnswer(q, "hasta lluego marta").contains("wrote “lluego” for “luego”"))
        XCTAssertNotNil(Questions.diffJSON(Questions.diff(q, answer: "hasta luego")!)["ops"])
        let sp: JSON = ["type": "speak", "prompt": "Say it", "target": "Buenos días", "lang": "es"]
        let s = await Questions.grade(sp, answer: ["heard": "días buenos"])
        XCTAssertEqual(s.correct, false, "spoken out of order is not the sentence")
        XCTAssertTrue(Questions.validate([["type": "dictation", "prompt": "x"]]).first?.contains("listen") ?? false)
    }

    func testTablesAndWrittenWork() async {
        let t: JSON = ["type": "table", "prompt": "hablar, presente", "lang": "es", "rows": ["yo", "tú", "él"], "columns": ["presente"],
                       "answer": [["hablo"], ["hablas"], ["habla"]], "cells": [["hablo"], nil, nil]]
        XCTAssertTrue(Questions.validate([t]).isEmpty, "\(Questions.validate([t]))")
        let g = await Questions.grade(t, answer: [["hablo"], ["hablas"], ["hable"]])
        XCTAssertEqual(g.correct, false); XCTAssertEqual(g.score!, 0.5, accuracy: 0.001, "the shown cell isn't asked: 1 of 2")
        XCTAssertFalse(Questions.validate([["type": "table", "prompt": "x", "rows": ["a"], "columns": ["b"], "answer": [["x", "y"]]]]).isEmpty, "answer shape checked")
        let tr: JSON = ["type": "translate", "prompt": "Into Japanese", "text": "I work in sales.", "from": "en", "to": "ja", "lang": "ja"]
        XCTAssertTrue(Questions.isWriting(tr))
        let trg = await Questions.grade(tr, answer: "営業で働いています"); XCTAssertNil(trg.correct, "the teacher grades translations")
        let note = Questions.writingNote([tr, ["type": "short_text", "prompt": "x", "answer": "y"]], answers: ["営業で働いています", "y"])
        XCTAssertTrue(note.contains("Q1") && note.contains("```correction") && !note.contains("Q2"), note)
        XCTAssertEqual(Questions.writingNote([tr], answers: [""]), "", "nothing written, nothing to correct")
        let b: JSON = ["type": "build_sentence", "prompt": "Use them", "words": ["perro", "parque"], "lang": "es"]
        XCTAssertTrue(Questions.describeAnswer(b, "El perro corre").contains("parque"), "names the given word not used")
        XCTAssertFalse(Questions.validate([["type": "rewrite", "prompt": "x", "text": "Hola"]]).isEmpty, "rewrite needs an instruction")
    }

    func testPassagesAreAnalysedWithOffsetsAndReadings() {
        _ = study.addVocab(lang: "ja", term: "会社", reading: "かいしゃ", meaning: "company")
        let text = "私は会社員です。毎日電車で行きます。"
        let a = LanguageWork.analyze(text, lang: "ja", study: study)
        let toks = a["tokens"]?.array ?? []
        let ns = text as NSString
        XCTAssertFalse(toks.isEmpty)
        for t in toks { let s = t["s"]!.int!, e = t["e"]!.int!; XCTAssertTrue(s < e && e <= ns.length) }
        let words = toks.map { ns.substring(with: NSRange(location: $0["s"]!.int!, length: $0["e"]!.int! - $0["s"]!.int!)) }
        XCTAssertTrue(words.contains("電車"), "\(words)")
        let densha = toks.first { ns.substring(with: NSRange(location: $0["s"]!.int!, length: $0["e"]!.int! - $0["s"]!.int!)) == "電車" }
        XCTAssertEqual(densha?["r"]?.string, "でんしゃ", "kana readings for kanji words")
        XCTAssertTrue(toks.contains { $0["saved"]?.bool == true }, "a saved word is marked")
        XCTAssertEqual(a["sentences"]?.array?.count, 2)
        let t7 = LanguageWork.analyze("七時に起きます。", lang: "ja", study: nil)["tokens"]?.array?.first
        XCTAssertEqual(t7?["r"]?.string, "しちじ", "clock times read as one word"); XCTAssertEqual(t7?["e"]?.int, 2)
        let es = LanguageWork.analyze("Los niños comen manzanas.", lang: "es", study: study)
        XCTAssertEqual(es["tokens"]?.array?.count, 4)
    }

    @MainActor func testReadingLogAndDueWordsReachTheStateLine() {
        study.logReading(lang: "ja", title: "通勤", words: 320, unit: "characters", conversationID: "L")
        study.logReading(lang: "ja", title: "会議", words: 180, unit: "characters", conversationID: "L")
        let r = study.readingStats(lang: "ja")
        XCTAssertEqual(r.words, 500); XCTAssertEqual(r.passages, 2); XCTAssertEqual(r.unit, "characters")
        _ = study.addVocab(lang: "ja", term: "担当", reading: "たんとう", meaning: "in charge")
        let line = LanguageExtension.stateLine(LanguageState(target: "ja", native: "en", level: "A2", profiled: true), study: study)
        XCTAssertTrue(line.contains("due to reuse: 担当"), line)
        XCTAssertTrue(line.contains("read this week: 500 characters in 2 passages"), line)
    }
}

/// Checks against the model's garbles: Chinese inside Japanese, another script, a reading that isn't the dictionary's.
final class LanguageSlipTests: XCTestCase {
    func testSlipsAreCaught() {
        XCTAssertNotNil(ScriptCheck.slip("田中さんに何Outlook said as 什么?", lang: "ja"), "什么 is Chinese")
        XCTAssertNil(ScriptCheck.slip("本社に着いて、田中さんに声をかけます。机の上に置きます。", lang: "ja"), "Japanese passes (机 and 迎 are Japanese too)")
        XCTAssertNotNil(ScriptCheck.slip("안녕 は Korean", lang: "ja"))
        let errs = Questions.validate([["type": "short_text", "prompt": "公司について説明してください。说明", "lang": "ja"]])
        XCTAssertTrue(errs.contains { $0.contains("Chinese") }, "\(errs)")
        XCTAssertTrue(Questions.validate([["type": "short_text", "prompt": "What do you do?", "lang": "ja"]]).isEmpty, "an English prompt for a Japanese answer is fine")
    }
    func testReadingsAreCheckedAgainstTheDictionary() {
        func item(_ term: String, _ reading: String) -> VocabItem { VocabItem(id: 1, lang: "ja", term: term, reading: reading, meaning: "x", tags: [], createdAt: Date()) }
        XCTAssertNotNil(VocabTool.readingMismatch(item("出社", "しゅくしゃ"), lang: "ja"))
        XCTAssertNil(VocabTool.readingMismatch(item("出社", "しゅっしゃ"), lang: "ja"))
        XCTAssertNil(VocabTool.readingMismatch(item("乗り換える", "のりかえる"), lang: "ja"))
        XCTAssertNil(VocabTool.readingMismatch(item("着く", "つく / ついた / 着いて"), lang: "ja"))
        XCTAssertNil(VocabTool.readingMismatch(item("おはよう", "ohayou"), lang: "ja"), "no kanji, nothing to check")
        var zh = item("学习", "xuéxí"); zh.lang = "zh"
        XCTAssertNil(VocabTool.readingMismatch(zh, lang: "zh"))
        zh.reading = "xuéxì"
        XCTAssertNotNil(VocabTool.readingMismatch(zh, lang: "zh"))
        zh.reading = "xuexi"
        XCTAssertNil(VocabTool.readingMismatch(zh, lang: "zh"), "toneless pinyin is not contradicted")
    }
}
