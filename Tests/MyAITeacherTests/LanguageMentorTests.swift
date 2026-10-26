import XCTest
@testable import MyAITeacher

/// The language mentor: which language a lesson teaches is read from the lesson at run time, the keyboard layouts are one
/// file for the page and the composer, composition rules match the page's, grading knows accents and speech, and the
/// learner's vocabulary is a flashcard deck.
final class LanguageMentorTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var study: StudyStore { services.study }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("langmentor-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    // MARK: Runtime language detection

    private func user(_ t: String) -> ChatMessage { ChatMessage(role: .user, blocks: [.text(t)]) }
    private func reply(_ t: String) -> ChatMessage { ChatMessage(role: .assistant, blocks: [.text(t)]) }

    func testTheLanguageTheLearnerAsksForIsTheTarget() {
        var cache: [String: [String]] = [:]
        let r = LanguageExtension.infer([user("Hi! I want to learn Japanese, I'm a complete beginner.")], cache: &cache)
        XCTAssertEqual(r.asked, "ja")
        XCTAssertEqual(LanguageExtension.asked(["teach me some spanish please"]), "es")
        XCTAssertEqual(LanguageExtension.asked(["Can you help me with my Arabic homework"]), "ar")
        XCTAssertEqual(LanguageExtension.asked(["I'm studying 日本語 at university"]), "ja")
        XCTAssertNil(LanguageExtension.asked(["I'm learning about Thailand's economy"]), "a country is not a language")
        XCTAssertNil(LanguageExtension.asked(["teach me the chain rule"]))
    }

    func testTaggedRepliesRevealTheTargetLanguage() {
        var cache: [String: [String]] = [:]
        let msgs = [user("Teach me greetings"),
                    reply("Good morning is <span lang=\"es\">buenos días</span>, and good night is <span lang=\"es\">buenas noches</span>. Practise both."),
                    user("more"), reply("Hello: <span lang=\"es\">hola</span>. How are you: <span lang=\"es\">¿cómo estás?</span>")]
        let r = LanguageExtension.infer(msgs, cache: &cache)
        XCTAssertEqual(r.content, "es")
        XCTAssertNil(r.asked)
        XCTAssertEqual(cache.count, 2, "each reply is analysed once")
    }

    @MainActor func testTheStateLineAndTheProfile() {
        XCTAssertTrue(LanguageExtension.stateLine(LanguageState(), study: study).contains("No target language yet"))
        _ = study.setLanguageProfile(code: "Japanese", role: "target", level: "A2")
        _ = study.setLanguageProfile(code: "en", role: "native")
        let p = study.languageProfile("ja")
        XCTAssertEqual(p?.level, "A2"); XCTAssertEqual(p?.role, "target")
        let line = LanguageExtension.stateLine(LanguageState(target: "ja", native: "en", level: "A2", profiled: true), study: study)
        XCTAssertTrue(line.contains("Japanese (ja), level A2"), line)
        XCTAssertTrue(line.contains("Japanese keyboard"), "the state names the keyboard: \(line)")
        XCTAssertTrue(line.contains("kana or romaji"), line)
        XCTAssertFalse(line.contains("confirm with"), "a profiled language needs no confirmation")
        let detected = LanguageExtension.stateLine(LanguageState(target: "ko", native: "en"), study: study)
        XCTAssertTrue(detected.contains("confirm with `language`"), detected)
        var r = LLMRequest(model: "m", system: "", messages: [ChatMessage(role: .user, blocks: [.text("hi")])])
        LanguageExtension.inject(line, into: &r)
        LanguageExtension.inject(line, into: &r)
        XCTAssertEqual(r.messages[0].blocks.filter { $0.meta?["languageState"]?.bool == true }.count, 1, "one state block, never stacked")
    }

    func testLanguageCodesAndNames() {
        XCTAssertEqual(Languages.code("Japanese"), "ja"); XCTAssertEqual(Languages.code("ja-JP"), "ja"); XCTAssertEqual(Languages.code("jpn"), "ja")
        XCTAssertEqual(Languages.code("Mandarin"), "zh"); XCTAssertEqual(Languages.code("español"), "es")
        XCTAssertNil(Languages.code("klingon")); XCTAssertNil(Languages.code(""))
        XCTAssertEqual(Languages.englishName("ja"), "Japanese"); XCTAssertEqual(Languages.nativeName("ja"), "日本語")
    }

    // MARK: Keyboard layouts and composition

    func testLayoutsFileIsOneSourceForThePageAndTheComposer() {
        let layouts = KeyboardLayouts.shared
        XCTAssertGreaterThanOrEqual(layouts.count, 30)
        for code in ["ja", "ko", "zh", "ar", "he", "ru", "el", "hi", "th", "es", "fr", "de", "vi"] { XCTAssertNotNil(layouts[code], code) }
        let ja = layouts["ja"]!
        XCTAssertEqual(ja.compose, "kana"); XCTAssertEqual(ja.modes, ["kana", "romaji"]); XCTAssertFalse(ja.rows.isEmpty)
        XCTAssertTrue(layouts["ar"]!.rtl); XCTAssertNotNil(layouts["ko"]!.shift); XCTAssertTrue(layouts["es"]!.upper)
        XCTAssertNil(KeyboardLayouts.layout(for: "sw"), "a plain-Latin language shows no panel")
        XCTAssertNil(KeyboardLayouts.layout(for: "xx")); XCTAssertNotNil(KeyboardLayouts.layout(for: "ja-JP"))
        for (code, l) in layouts {
            for row in l.rows + (l.shift ?? []) { for k in row { if case .fn(let f) = k { XCTAssertTrue(["shift", "bksp", "space", "enter", "dakuten", "handakuten", "small", "kana", "tone", "tone1", "tone2", "tone3", "tone4", "mode"].contains(f), "\(code): unknown key \(f)") } } }
        }
        XCTAssertTrue(KeyboardLayouts.parse("// x = y\nwindow.TeacherKeyboardLayouts = {\"xx\": {\"name\": \"X\", \"english\": \"X\", \"rows\": [[\"a\", {\"k\": \"bksp\"}]]}};")["xx"]!.rows[0] == [.text("a"), .fn("bksp")])
    }

    func testHangulComposition() {
        var text = ""
        func type(_ j: Character) { let r = ScriptComposer.hangul(prev: text.last, j); text = String(text.dropLast(r.remove)) + r.text }
        for j in "ㅎㅏㄴㄱㅡㄹ" { type(j) }
        XCTAssertEqual(text, "한글")
        text = ""; for j in "ㄱㅗㅏㄴ" { type(j) }; XCTAssertEqual(text, "관", "compound vowel")
        text = ""; for j in "ㄷㅏㄹㄱ" { type(j) }; XCTAssertEqual(text, "닭", "compound final")
        text = ""; for j in "ㄷㅏㄹㄱㅣ" { type(j) }; XCTAssertEqual(text, "달기", "a compound final splits when a vowel follows")
        text = ""; for j in "ㅇㅏㄴㄴㅕㅇ" { type(j) }; XCTAssertEqual(text, "안녕")
        XCTAssertEqual(ScriptComposer.hangulBackspace(prev: "한").text, "하")
        XCTAssertEqual(ScriptComposer.hangulBackspace(prev: "하").text, "ㅎ")
        XCTAssertEqual(ScriptComposer.hangulBackspace(prev: "닭").text, "달")
    }

    func testKanaAndPinyinComposition() {
        XCTAssertEqual(ScriptComposer.voicing(prev: "か", mark: "\u{3099}")?.text, "が")
        XCTAssertEqual(ScriptComposer.voicing(prev: "が", mark: "\u{3099}")?.text, "か", "toggles off")
        XCTAssertEqual(ScriptComposer.voicing(prev: "は", mark: "\u{309A}")?.text, "ぱ")
        XCTAssertNil(ScriptComposer.voicing(prev: "あ", mark: "\u{3099}"), "あ takes no dakuten")
        XCTAssertEqual(ScriptComposer.toggleSmall(prev: "つ")?.text, "っ"); XCTAssertEqual(ScriptComposer.toggleSmall(prev: "っ")?.text, "つ")
        XCTAssertEqual(ScriptComposer.toKatakana("こんにちは"), "コンニチハ")
        XCTAssertEqual(ScriptComposer.romaji("konnichiha", katakana: false), "こんにちは")
        XCTAssertEqual(ScriptComposer.romaji("kyou", katakana: false), "きょう")
        XCTAssertEqual(ScriptComposer.romaji("kitte", katakana: false), "きって")
        XCTAssertEqual(ScriptComposer.romaji("desu.", katakana: false), "です。", "punctuation converts like an input method's")
        XCTAssertEqual(ScriptComposer.romaji(",", katakana: false), "、")
        XCTAssertEqual(ScriptComposer.romaji("k", katakana: false), "k", "an unfinished syllable stays Latin")
        XCTAssertEqual(ScriptComposer.romaji("kon", katakana: false), "こn", "a lone n waits for the next letter")
        XCTAssertEqual(ScriptComposer.romaji("koohii", katakana: true), "コオヒイ")
        XCTAssertEqual(ScriptComposer.romaji("kan'i", katakana: false), "かんい"); XCTAssertEqual(ScriptComposer.romaji("sinbunn", katakana: false), "しんぶん")
        XCTAssertEqual(ScriptComposer.cycleTone("ma")?.text, "mā"); XCTAssertEqual(ScriptComposer.cycleTone("mā")?.text, "má")
        XCTAssertEqual(ScriptComposer.cycleTone("mà")?.text, "ma", "after the fourth tone, none")
        XCTAssertEqual(ScriptComposer.cycleTone("hao")?.text, "hāo", "a goes first"); XCTAssertEqual(ScriptComposer.cycleTone("xie")?.text, "xiē")
        XCTAssertEqual(ScriptComposer.cycleTone("gou")?.text, "gōu", "ou takes it on o"); XCTAssertEqual(ScriptComposer.cycleTone("liu")?.text, "liū", "else the last vowel")
        XCTAssertEqual(ScriptComposer.cycleTone("nǐ hǎo")?.remove, 3, "only the last syllable")
    }

    // MARK: Transliteration and analysis (on device)

    func testTransliterationAndAnalysis() {
        XCTAssertEqual(Transliteration.apply("konnichiha", to: "hiragana"), "こんにちは")
        XCTAssertEqual(Transliteration.apply("こんにちは", to: "katakana"), "コンニチハ")
        XCTAssertEqual(Transliteration.apply("コンニチハ", to: "hiragana"), "こんにちは")
        XCTAssertEqual(Transliteration.apply("你好", to: "pinyin")?.lowercased().replacingOccurrences(of: " ", with: ""), "nǐhǎo")
        XCTAssertEqual(Transliteration.apply("Привет", to: "latin"), "Privet")
        XCTAssertEqual(Transliteration.apply("café", to: "ascii"), "cafe")
        XCTAssertNil(Transliteration.apply("x", to: "klingon"))
        let toks = TextAnalysis.tokens("私はりんごを食べる", language: "ja")
        XCTAssertGreaterThanOrEqual(toks.count, 4, "Japanese is segmented into words: \(toks.map(\.text))")
        XCTAssertTrue(toks.contains { $0.text == "食べる" || $0.text == "食べ" }, toks.map(\.text).joined(separator: "|"))
        let es = TextAnalysis.tokens("Los niños comieron manzanas", language: "es")
        XCTAssertEqual(es.map(\.text), ["Los", "niños", "comieron", "manzanas"])
        // The system tagger tags English; for languages it has no model for it says "OtherWord" for every word, which
        // is noise, not a part of speech: dropped.
        XCTAssertFalse(es.contains { $0.pos == "otherword" }, "no empty tags: \(es.map { $0.pos ?? "-" })")
        let en = TextAnalysis.tokens("The children ate apples", language: "en")
        XCTAssertEqual(en.map { $0.pos ?? "-" }, ["determiner", "noun", "verb", "noun"])
        XCTAssertEqual(TextAnalysis.sentences("Hola. ¿Qué tal? Bien.").count, 3)
        XCTAssertEqual(TextAnalysis.languages("Bonjour, je voudrais un café s'il vous plaît.").first?.0, "fr")
    }

    // MARK: Grading language tests

    func testAccentsStrictAndPinyin() async {
        let lenient: JSON = ["type": "short_text", "prompt": "coffee?", "answer": "café"]
        var strict = lenient; strict = .object(strict.object!.merging(["accents": "strict"]) { $1 })
        let g1 = await Questions.grade(lenient, answer: "cafe")
        XCTAssertEqual(g1.correct, true, "accents fold by default")
        let g2 = await Questions.grade(strict, answer: "cafe")
        XCTAssertEqual(g2.correct, false, "strict: the accent is the point")
        let g3 = await Questions.grade(strict, answer: "Café")
        XCTAssertEqual(g3.correct, true, "case still folds")
        let blanks: JSON = ["type": "fill_blanks", "text": "Yo {{}} español.", "answer": ["hablo"], "accents": "strict"]
        let g4 = await Questions.grade(blanks, answer: ["hablo"])
        XCTAssertEqual(g4.correct, true)
        XCTAssertEqual(Questions.pinyinNumbers("nǐ hǎo"), "ni3 hao3")
        let py: JSON = ["type": "short_text", "prompt": "pinyin for 你好", "answer": "nǐ hǎo", "lang": "zh"]
        let g5 = await Questions.grade(py, answer: "ni3 hao3")
        XCTAssertEqual(g5.correct, true, "tone numbers and marks are the same answer")
        let g6 = await Questions.grade(py, answer: "ni hao")
        XCTAssertEqual(g6.correct, true, "lenient by default")
        var pys = py; pys = .object(pys.object!.merging(["accents": "strict"]) { $1 })
        let g7 = await Questions.grade(pys, answer: "ni hao")
        XCTAssertEqual(g7.correct, false, "strict: tones count")
    }

    func testSpeakQuestionsAreGradedByWordsHeard() async {
        let q: JSON = ["type": "speak", "prompt": "Say it", "target": "Buenos días", "lang": "es"]
        XCTAssertEqual(Questions.validate([q]), [])
        XCTAssertEqual(Questions.validate([["type": "speak", "prompt": "Say it"]]).count, 1, "needs a target")
        let g = await Questions.grade(q, answer: ["heard": "buenos dias", "target": "Buenos días"])
        XCTAssertEqual(g.correct, true); XCTAssertEqual(g.expected, "Buenos días")
        let g8 = await Questions.grade(q, answer: .null)
        XCTAssertEqual(g8.correct, false)
        XCTAssertTrue(Questions.describeAnswer(q, ["heard": "buenos dias"]).contains("said “buenos dias”"))
        XCTAssertTrue(Questions.types.contains("speak"))
    }

    // MARK: Vocabulary

    func testVocabularyIsAFlashcardDeck() {
        let v = study.addVocab(lang: "Japanese", term: "りんご", reading: "ringo", meaning: "apple", pos: "noun", example: "りんごを食べる", exampleMeaning: "I eat an apple", tags: ["food"], source: "L1")
        XCTAssertEqual(v?.lang, "ja"); XCTAssertEqual(v?.status, "new"); XCTAssertNotNil(v?.cardID)
        let cards = study.allCards(deck: StudyStore.vocabDeck("ja"))
        XCTAssertEqual(cards.count, 1); XCTAssertTrue(cards[0].front.contains("りんご") && cards[0].front.contains("ringo")); XCTAssertTrue(cards[0].back.contains("apple"))
        _ = study.addVocab(lang: "ja", term: "りんご", meaning: "apple (fruit)")
        XCTAssertEqual(study.vocab(lang: "ja").count, 1, "the same word updates, never duplicates")
        XCTAssertEqual(study.vocab(lang: "ja")[0].meaning, "apple (fruit)")
        XCTAssertEqual(study.allCards(deck: StudyStore.vocabDeck("ja")).count, 1)
        _ = study.addVocab(lang: "ja", term: "水", reading: "mizu", meaning: "water")
        XCTAssertEqual(study.vocab(lang: "ja", tag: "food").map(\.term), ["りんご"])
        XCTAssertEqual(study.searchVocab("water").map(\.term), ["水"])
        let st = study.vocabStats(lang: "ja")
        XCTAssertEqual(st.total, 2); XCTAssertEqual(st.due, 2, "new cards are due"); XCTAssertEqual(st.new, 2)
        XCTAssertEqual(study.dueVocab(lang: "ja").count, 2)
        XCTAssertEqual(study.vocabLanguages(), ["ja"])
        XCTAssertTrue(study.removeVocab(lang: "ja", term: "水"))
        XCTAssertEqual(study.vocabStats(lang: "ja").total, 1); XCTAssertEqual(study.allCards(deck: StudyStore.vocabDeck("ja")).count, 1, "its card goes too")
        XCTAssertNil(study.addVocab(lang: "ja", term: " ", meaning: "x"))
    }

    func testTheToolsAreCoreInLanguageModeAndLoadableElsewhere() {
        XCTAssertEqual(AgentTree.node(for: .language), "language")
        let lang = AgentTree.core("language")
        XCTAssertTrue(lang.contains("vocab") && lang.contains("language"))
        XCTAssertFalse(AgentTree.deferred("language").contains("vocab"))
        XCTAssertTrue(AgentTree.components("language").contains("gloss"))
        XCTAssertFalse(AgentTree.core("tutor").contains("vocab"))
        XCTAssertTrue(AgentTree.deferred("tutor").contains("vocab") && AgentTree.deferred("tutor").contains("language"))
        XCTAssertTrue(ToolRegistry.deferredIndex("tutor").contains("`vocab`"))
        XCTAssertFalse(ToolRegistry.deferredIndex("language").contains("`vocab`"))
        XCTAssertEqual(TeachingMode.language.title, "Language mentor")
        XCTAssertTrue(Instructions.mode(.language).contains("```gloss"))
    }

    @MainActor func testLanguageToolProfileAndTransliterate() async throws {
        let ctx = ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "t1",
                              client: ScriptedLLM([]), model: "m", progress: { _ in })
        let out = try await LanguageTool().run(["action": "profile", "target": "Korean", "native": "English", "level": "A1"], ctx)
        XCTAssertFalse(out.isError); XCTAssertTrue(out.text.contains("Korean (ko)"), out.text); XCTAssertTrue(out.text.contains("Korean keyboard"), out.text)
        XCTAssertEqual(study.languageProfiles().map(\.code).sorted(), ["en", "ko"])
        let t = try await LanguageTool().run(["action": "transliterate", "text": "annyeong", "to": "hangul"], ctx)
        XCTAssertFalse(t.isError); XCTAssertTrue(t.text.contains("안"), t.text)
        let bad = try await LanguageTool().run(["action": "profile", "target": "klingon"], ctx)
        XCTAssertTrue(bad.isError)
        let v = try await VocabTool().run(["action": "add", "words": [["term": "안녕", "reading": "annyeong", "meaning": "hi"]]], ctx)
        XCTAssertFalse(v.isError); XCTAssertTrue(v.text.contains("Korean"), v.text)
        XCTAssertEqual(study.vocab(lang: "ko").count, 1, "the profile's target is the default language")
        let due = try await VocabTool().run(["action": "due"], ctx)
        XCTAssertTrue(due.text.contains("안녕"))
        // Adding again updates the word (live runs removed every word before re-adding it).
        let again = try await VocabTool().run(["action": "add", "words": [["term": "안녕", "meaning": "hi (casual)", "example": "안녕, 민수야!"]]], ctx)
        XCTAssertFalse(again.isError); XCTAssertEqual(study.vocab(lang: "ko").count, 1); XCTAssertEqual(study.vocab(lang: "ko").first?.meaning, "hi (casual)")
        // A slip into another script is named, so it gets fixed in one go.
        let slip = try await VocabTool().run(["action": "add", "words": [["term": "학교", "meaning": "school", "example": "学校に行きます"]]], ctx)
        XCTAssertTrue(slip.text.contains("“학교”: its example contains Hiragana"), slip.text)
    }

    func testJapaneseAnalysisReadsJapaneseNotMandarin() {
        let toks = TextAnalysis.tokens("設備の設置を担当しております。", language: "ja")
        let tantou = toks.first { $0.text == "担当" }
        XCTAssertNotNil(tantou, toks.map(\.text).joined(separator: "|"))
        XCTAssertTrue(tantou?.reading?.contains("たんとう") == true && tantou?.reading?.contains("tantou") == true, tantou?.reading ?? "nil")
        XCTAssertFalse(toks.contains { ($0.reading ?? "").contains("dān") || $0.pos == "otherword" }, "no pinyin, no empty tags")
        XCTAssertFalse(toks.contains { $0.text == "。" }, "punctuation isn't a word")
        XCTAssertEqual(toks.first { $0.text == "を" }?.reading, "o", "particles read as spoken")
        XCTAssertEqual(TextAnalysis.tokens("私は学生です", language: "ja").first { $0.text == "は" }?.reading, "wa")
    }

    @MainActor func testTransliterationRefusesWhatIsntRomanisation() async throws {
        let ctx = ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "t1",
                              client: ScriptedLLM([]), model: "m", progress: { _ in })
        let name = try await LanguageTool().run(["action": "transliterate", "text": "Sam Carter", "to": "katakana"], ctx)
        XCTAssertTrue(name.isError && name.text.contains("サム・カーター"), name.text)
        let ok = try await LanguageTool().run(["action": "transliterate", "text": "konnichiha", "to": "hiragana"], ctx)
        XCTAssertFalse(ok.isError); XCTAssertEqual(ok.text, "こんにちは")
    }

    func testScriptCheckFindsWordsFromAnotherScript() {
        XCTAssertNil(ScriptCheck.foreign("担当しています。Sam です", lang: "ja"), "kanji, kana and Latin names are Japanese text")
        XCTAssertEqual(ScriptCheck.foreign("担当は 새로", lang: "ja"), "Hangul")
        XCTAssertEqual(ScriptCheck.foreign("Hola, мир", lang: "es"), "Cyrillic")
        XCTAssertNil(ScriptCheck.foreign("مرحبا Sam", lang: "ar"))
    }
}
