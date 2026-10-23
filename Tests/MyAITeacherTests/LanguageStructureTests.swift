import XCTest
@testable import MyAITeacher

/// Levels per skill, the grammar syllabus with mastery from production, and vocabulary in and out of Anki/spreadsheets.
final class LanguageStructureTests: XCTestCase {
    var dir: URL!
    var services: Services!
    var study: StudyStore { services.study }

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("lstruct-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() async throws { try? FileManager.default.removeItem(at: dir) }

    @MainActor private func ctx() -> ToolContext {
        ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "t1",
                    client: ScriptedLLM([]), model: "m", progress: { _ in })
    }

    @MainActor func testSkillsSyllabusAndGrammarEvidence() async throws {
        let c = ctx()
        _ = try await LanguageTool().run(["action": "profile", "target": "Spanish", "level": "A2"], c)
        let sk = try await LanguageTool().run(["action": "skills", "skills": [
            ["skill": "reading", "level": "B1", "evidence": "read a 400-word news text, answered 5/6 detail questions"],
            ["skill": "speaking", "level": "A2", "provisional": true], ["skill": "dancing", "level": "C2"]]], c)
        XCTAssertTrue(sk.text.contains("reading B1") && sk.text.contains("Not set") && sk.text.contains("Not placed yet: listening, writing, vocabulary, grammar"), sk.text)
        XCTAssertEqual(study.skills(lang: "es").map(\.level), ["B1", "A2?"], "a level without a sample is marked provisional")

        let sy = try await LanguageTool().run(["action": "syllabus", "points": [
            ["name": "ser vs estar", "level": "A1", "description": "identity vs state and place"],
            ["name": "pretérito indefinido: regular verbs", "level": "A2"],
            ["name": "subjuntivo after querer que", "level": "B1"], ["name": "nonsense", "level": "Z9"]]], c)
        XCTAssertTrue(sy.text.contains("Added or updated 3"), sy.text)
        XCTAssertTrue(sy.text.contains("A1 — 0/1 mastered") && sy.text.contains("not seen yet"), sy.text)

        // Production moves mastery; the evidence is the learner's sentence.
        for _ in 0..<4 { _ = try await LanguageTool().run(["action": "grammar", "point": "Ser vs Estar", "correct": true, "sentence": "Mi casa está en Madrid."], c) }
        let wrong = try await LanguageTool().run(["action": "grammar", "point": "pretérito indefinido: regular verbs", "correct": false, "sentence": "Ayer hablé... hablaba con él"], c)
        XCTAssertTrue(wrong.text.contains("used wrongly"), wrong.text)
        let g = study.grammarSyllabus(lang: "es")
        XCTAssertEqual(g.map(\.name), ["ser vs estar", "pretérito indefinido: regular verbs", "subjuntivo after querer que"])
        XCTAssertTrue(g[0].pKnown > 0.9 && g[0].mastery?.notes?.contains("está en Madrid") == true)
        XCTAssertEqual(study.nextGrammar(lang: "es").first?.name, "pretérito indefinido: regular verbs", "the shaky point first")
        let added = try await LanguageTool().run(["action": "grammar", "point": "por vs para", "correct": true, "sentence": "Gracias por todo"], c)
        XCTAssertTrue(added.text.contains("added at A2"), "a new point lands at the learner's level: \(added.text)")

        let line = LanguageExtension.stateLine(LanguageState(target: "es", level: "A2", profiled: true), study: study)
        XCTAssertTrue(line.contains("by skill: reading B1, speaking A2?") && line.contains("next: pretérito indefinido: regular verbs (shaky)"), line)
        let prof = try await LanguageTool().run(["action": "profile"], c)
        XCTAssertTrue(prof.text.contains("grammar syllabus") && prof.text.contains("by skill"), prof.text)
    }

    func testExportAndImportRoundTrip() throws {
        study.addVocab(lang: "ja", term: "電話", reading: "でんわ", meaning: "telephone", pos: "noun", example: "電話をかける", exampleMeaning: "to make a call",
                       notes: "Goes with: かける\nRegister: neutral", tags: ["daily", "n5"])
        study.addVocab(lang: "ja", term: "猫", meaning: "cat, \"neko\"")
        let items = study.vocab(lang: "ja")
        let tsv = VocabTransfer.tsv(items, lang: "ja")
        XCTAssertTrue(tsv.hasPrefix("#separator:tab\n#html:true\n#notetype:Basic\n#deck:Japanese vocabulary\n#tags column:8\n#columns:term\treading"), tsv)
        let back = VocabTransfer.parse(tsv)
        XCTAssertEqual(back.count, 2)
        let tel = back.first { $0.term == "電話" }
        XCTAssertEqual(tel?.reading, "でんわ"); XCTAssertEqual(tel?.exampleMeaning, "to make a call"); XCTAssertEqual(tel?.tags, ["daily", "n5"])
        XCTAssertEqual(tel?.notes, "Goes with: かける\nRegister: neutral", "newlines survive as <br>")
        let csvBack = VocabTransfer.parse(VocabTransfer.csv(items))
        XCTAssertEqual(csvBack.first { $0.term == "猫" }?.meaning, "cat, \"neko\"", "quoted commas and quotes")

        // Into another profile's store: new words added, known ones updated, each with a flashcard.
        let r = VocabTransfer.importEntries(back + [VocabTransfer.Entry(term: "犬", meaning: "dog")], lang: "ja", into: study, source: "import")
        XCTAssertEqual(r.added, 1); XCTAssertEqual(r.updated, 2)
        XCTAssertNotNil(study.vocab(lang: "ja").first { $0.term == "犬" }?.cardID)
    }

    func testAnkiAndSpreadsheetTextIsRead() {
        // Anki's own "Notes in Plain Text" export: HTML on, tags in the last column, no header row.
        let anki = "#separator:tab\n#html:true\n#tags column:3\nhola<br>\t<b>hello</b>&nbsp;[sound:hola.mp3]\tgreetings basics\nadiós\tgoodbye\t\n"
        let a = VocabTransfer.parse(anki)
        XCTAssertEqual(a.map(\.term), ["hola", "adiós"]); XCTAssertEqual(a.first?.meaning, "hello"); XCTAssertEqual(a.first?.tags, ["greetings", "basics"])
        // A spreadsheet with its own header names, semicolon-separated.
        let sheet = "Word;Pinyin;English\n你好;nǐ hǎo;hello\n谢谢;xièxie;thank you\n"
        let s = VocabTransfer.parse(sheet)
        XCTAssertEqual(s.map(\.reading), ["nǐ hǎo", "xièxie"]); XCTAssertEqual(s.last?.meaning, "thank you")
        // No header: term and meaning first.
        XCTAssertEqual(VocabTransfer.parse("Haus,house\nBaum,tree").map(\.meaning), ["house", "tree"])
    }

    /// An Anki package in the format Anki writes with "Support older Anki versions": a zip with the SQLite collection.
    func testAnkiPackageIsRead() async throws {
        let pkg = dir.appendingPathComponent("pkg"); try FileManager.default.createDirectory(at: pkg, withIntermediateDirectories: true)
        let db = try Database(path: pkg.appendingPathComponent("collection.anki2").path)
        try db.script("CREATE TABLE notes(id INTEGER PRIMARY KEY, flds TEXT, tags TEXT);")
        _ = try db.execute("INSERT INTO notes(flds, tags) VALUES(?,?)", "Brot\u{1f}bread<br>(n.)\u{1f}das Brot", " food ")
        _ = try db.execute("INSERT INTO notes(flds, tags) VALUES(?,?)", "laufen\u{1f}to run", "")
        let file = dir.appendingPathComponent("deck.apkg")
        let z = await ProcessRunner.run("/usr/bin/ditto", ["-c", "-k", pkg.path, file.path])
        XCTAssertEqual(z.exitCode, 0)
        let e = try await VocabTransfer.apkg(file)
        XCTAssertEqual(e.map(\.term), ["Brot", "laufen"])
        XCTAssertEqual(e.first?.meaning, "bread\n(n.)"); XCTAssertEqual(e.first?.notes, "das Brot"); XCTAssertEqual(e.first?.tags, ["food"])
    }
}
