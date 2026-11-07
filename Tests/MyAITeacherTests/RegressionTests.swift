import XCTest
@testable import MyAITeacher

/// Cases that used to go wrong: each test names what happened before its fix.
final class RegressionTests: XCTestCase {
    var dir: URL!
    var services: Services!

    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("regress-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        services = Services(global: GlobalStore(db: try Database(path: dir.appendingPathComponent("g.sqlite").path)), workspace: try Workspace(url: dir))
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    @MainActor func ctx() -> ToolContext {
        let cfg = ProviderConfig(id: "x", name: "x", api: .openai, baseURL: "http://127.0.0.1:1", envKeys: [], defaultModel: "m")
        return ToolContext(conversationID: "L", workspace: dir, services: services, interactions: InteractionCenter(), toolCallID: "c",
                           client: cfg.client(apiKey: nil), model: "m", progress: { _ in })
    }

    // MARK: Windows line endings ("\r\n" is one Character in Swift)

    @MainActor func testReadShowsEveryLineOfACRLFFile() async throws {
        try "one\r\ntwo\r\nthree\r\n".write(to: dir.appendingPathComponent("w.txt"), atomically: true, encoding: .utf8)
        let out = try await ReadTool().run(["path": "w.txt", "offset": 2], ctx())
        XCTAssertFalse(out.isError, out.text)   // was: "offset 2 is beyond end of file (1 lines)"
        XCTAssertTrue(out.text.contains("2\ttwo") && out.text.contains("3\tthree") && !out.text.contains("\r"), out.text)
    }

    func testEditMatchesMultiLineTextInACRLFFileAndKeepsItsLineEndings() {
        let file = "def f():\r\n    return 1\r\n\r\ndef g():\r\n    return 2\r\n"
        let (out, why) = EditTool.apply(file, old: "def f():\n    return 1", new: "def f():\n    return 10", all: false, n: nil, file: "a.py")
        XCTAssertEqual(out, "def f():\r\n    return 10\r\n\r\ndef g():\r\n    return 2\r\n", why)
        let (fuzzy, _) = EditTool.apply("x = 1  \r\ny = 2\r\n", old: "x = 1\ny = 2", new: "x = 1\ny = 3", all: false, n: nil, file: "a.py")
        XCTAssertEqual(fuzzy, "x = 1\r\ny = 3\r\n")
        // A lone "\n" against a file with one "\r\n": counted once, then a nil range was force-unwrapped.
        XCTAssertEqual(EditTool.apply("a\r\nb", old: "\n", new: "\n\n", all: false, n: nil, file: "a.txt").0, "a\r\n\r\nb")
    }

    func testCodeIndexOutlinesACRLFFile() {
        let syms = SymbolsTool.outline("func a() {\r\n}\r\n\r\nfunc b() {\r\n}\r\n", ext: "swift")
        XCTAssertEqual(syms.count, 2)
    }

    // MARK: Grading

    func testScientificNotationAnswersReadAsTheirValue() {
        XCTAssertEqual(Questions.number("3×10^8"), 3e8)   // was 3
        XCTAssertEqual(Questions.number("6.02 x 10^23") ?? 0, 6.02e23, accuracy: 1e12)
        XCTAssertEqual(Questions.number("2.5e3"), 2500)
        XCTAssertEqual(Questions.number("10^3"), 1000)
    }

    // MARK: Shell safety

    func testInstallsFromInsideCodeAreRefusedInTheirListForm() {
        let code = { (s: String) -> JSON in ["language": "python", "code": .string(s)] }
        XCTAssertNotNil(PermissionExtension.packageInstall(tool: RunCodeTool(), input: code(#"subprocess.check_call([sys.executable, "-m", "pip", "install", "requests"])"#)))
        XCTAssertNotNil(PermissionExtension.packageInstall(tool: RunCodeTool(), input: code("subprocess.run(['pip', 'install', 'numpy'])")))
        XCTAssertNil(PermissionExtension.packageInstall(tool: RunCodeTool(), input: code(#"print("install the package with care")"#)))
    }

    func testATestNameCannotEndTheGoFilterQuote() async throws {
        let name = "a'; touch \(dir.appendingPathComponent("RAN").path); echo '"
        let c = try XCTUnwrap(ProjectTestRunner.filtered("go test ./...", test: name))
        // The shell reads the added words as exactly `-run <pattern>`: nothing after a `;` runs.
        let words = String(c.dropFirst("go test ./...".count))
        let r = await ProcessRunner.run("/bin/sh", ["-c", "set --\(words); for a; do printf '[%s]' \"$a\"; done"], timeout: 10)
        XCTAssertEqual(r.stdout, "[-run][^" + NSRegularExpression.escapedPattern(for: name) + "$]")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("RAN").path))
    }

    func testReadOnlyGitStatusRunsNoFilterProgramFromTheRepositorysConfig() async throws {
        let git = try XCTUnwrap(ProcessRunner.which("git"))
        let repo = dir.appendingPathComponent("repo"), marker = dir.appendingPathComponent("RAN")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        func g(_ a: String...) async { _ = await ProcessRunner.run(git, a, cwd: repo, timeout: 20) }
        await g("init", "-q", "."); await g("config", "user.email", "t@example.com"); await g("config", "user.name", "t")
        try "hi\n".write(to: repo.appendingPathComponent("a.txt"), atomically: true, encoding: .utf8)
        try "* filter=x\n".write(to: repo.appendingPathComponent(".gitattributes"), atomically: true, encoding: .utf8)
        await g("add", "."); await g("commit", "-qm", "init")
        await g("config", "filter.x.process", "sh -c 'touch \(marker.path)'")
        await g("config", "filter.x.clean", "sh -c 'touch \(marker.path); cat'")
        // A stale index (an unpacked archive's usual state) makes `git status` read the file again, through the filter.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_600_000_000)], ofItemAtPath: repo.appendingPathComponent("a.txt").path)
        XCTAssertTrue(ReadOnlyShell.allows("git status"), "asked of no one")
        let index = repo.appendingPathComponent(".git/index"), before = try Data(contentsOf: index)
        _ = await ReadOnlyShell.run("git status", cwd: repo, timeout: 30)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path), "the repository's filter program ran without an approval")
        // The refresh a status does on a stale index would leave the control below with nothing to re-read.
        XCTAssertEqual(try Data(contentsOf: index), before, "a read-only status wrote the repository's index")
        XCTAssertTrue(ReadOnlyShell.hardened(["log"]).contains("log.showSignature=false"))
        await g("status")   // the same call without the hardening does run it: the test's repository is set up right
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
    }

    func testWebFetchAddsTheSchemeToHostsThatStartWithHttp() {
        XCTAssertEqual(WebFetchTool.url(["url": "httpbin.org/get"])?.absoluteString, "https://httpbin.org/get")   // was "Invalid URL."
        XCTAssertEqual(WebFetchTool.url(["url": "http://example.com"])?.absoluteString, "http://example.com")
    }

    // MARK: The agent loop

    func testHiddenLoopNotesDontStartATurn() {
        let asked = ChatMessage(role: .user, blocks: [Block(kind: .text, text: "plan", meta: ["hidden": true]), .text("Teach me X")])
        let results = ChatMessage(role: .user, blocks: [.toolResult(id: "t", name: "read", content: "x")])
        let note = ChatMessage(role: .user, blocks: [Block(kind: .text, text: "carry on", meta: ["hidden": true, "ephemeral": true])])
        XCTAssertEqual(ContextPolicy.turnStarts([asked, results, note]), [0])
    }

    func testACallCutOffAtTheOutputLimitIsMarkedNotToRun() {
        var m = ChatMessage(role: .assistant, blocks: [.toolUse(id: "a", name: "read", input: ["path": "x"]),
                                                       .toolUse(id: "b", name: "write", input: ["path": "y", "content": "half a fi"])])
        ToolArgs.markCutOff(&m, finish: "end_turn")
        XCTAssertNil(m.blocks[1].input?["_cutOff"])
        ToolArgs.markCutOff(&m, finish: "max_tokens")
        XCTAssertNil(m.blocks[0].input?["_cutOff"], "the earlier call was complete")
        XCTAssertEqual(m.blocks[1].input?["_cutOff"]?.bool, true)
        XCTAssertEqual(m.blocks[1].input?["path"]?.string, "y")
    }

    // MARK: Study records

    func testAStudyDayWithOnlyTimeLoggedDoesntBreakTheStreak() throws {
        let db = services.global.db, cal = Calendar.current, today = cal.startOfDay(for: Date())
        for back in 1...3 {
            db.run("INSERT INTO study_log(day, seconds, messages, reviews) VALUES(?,?,?,?)",
                   StudyStore.dayFormatter.string(from: cal.date(byAdding: .day, value: -back, to: today)!), 60.0, 2, 0)
        }
        db.run("INSERT INTO study_log(day, seconds, messages, reviews) VALUES(?,?,?,?)", StudyStore.dayFormatter.string(from: today), 30.0, 0, 0)
        XCTAssertEqual(services.global.study.streakDays(), 3)   // was 0: a turn that finished after midnight logged only seconds
    }

    func testAVocabularyWordWhoseCardWasDeletedGetsANewOne() throws {
        let study = services.global.study
        let card = try XCTUnwrap(study.addVocab(lang: "ja", term: "猫", meaning: "cat")?.cardID)
        study.deleteCard(card)
        let again = try XCTUnwrap(study.addVocab(lang: "ja", term: "猫", meaning: "cat"))
        XCTAssertNotNil(again.cardID); XCTAssertNotEqual(again.cardID, card)   // was the deleted card's id, so never due again
        XCTAssertEqual(study.dueVocab(lang: "ja").map(\.term), ["猫"])
    }

    func testVocabularySearchReadsPercentAsText() {
        let study = services.global.study
        _ = study.addVocab(lang: "fr", term: "pour cent", meaning: "per cent")
        _ = study.addVocab(lang: "fr", term: "50%", meaning: "half")
        XCTAssertEqual(study.searchVocab("%").map(\.term), ["50%"])   // was both: % matched anything
    }

    func testSetMasteryKeepsOneRowWhateverTheCasing() {
        let study = services.global.study
        study.recordAttempt(subject: "calculus", concept: "chain rule", correct: true, note: nil)
        study.setMastery(subject: "Calculus", concept: "Chain Rule", level: 0.9, note: nil)
        let rows = (try? services.global.db.query("SELECT concept FROM mastery WHERE subject='calculus'")) ?? []
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(study.mastery(subject: "calculus", concept: "chain rule")?.pKnown ?? 0, 0.9, accuracy: 1e-9)
    }
}

extension ProviderStreamTests {
    func testAnthropicStreamThatClosesWithoutAStopIsALostConnection() async throws {
        let sse = """
        event: message_start
        data: {"type":"message_start","message":{"usage":{"input_tokens":10,"output_tokens":0}}}

        event: content_block_start
        data: {"type":"content_block_start","index":0,"content_block":{"type":"text","text":""}}

        event: content_block_delta
        data: {"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"The answer is"}}


        """
        let server = try MockSSEServer(body: sse)
        let p = ProviderConfig(id: "anthropic", name: "A", api: .anthropic, baseURL: "http://127.0.0.1:\(server.port)/v1", envKeys: [], defaultModel: "claude-opus-5-5")
        let req = LLMRequest(model: "claude-opus-5-5", system: "s", messages: [ChatMessage(role: .user, blocks: [.text("hi")])], thinking: .medium)
        do {
            for try await _ in p.client(apiKey: "k").stream(req) {}
            XCTFail("a reply cut off mid-stream was taken as finished")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .networkConnectionLost, "\(error)")   // retried by the loop
        }
    }

    func testOpenAICallsThatReuseIndexZeroKeepTheirOwnArguments() async throws {
        let sse = """
        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"A","type":"function","function":{"name":"math","arguments":""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"expression\\":\\"1+1\\"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"id":"B","type":"function","function":{"name":"math","arguments":""}}]}}]}

        data: {"choices":[{"index":0,"delta":{"tool_calls":[{"index":0,"function":{"arguments":"{\\"expression\\":\\"2+2\\"}"}}]}}]}

        data: {"choices":[{"index":0,"delta":{},"finish_reason":"tool_calls"}]}

        data: [DONE]


        """
        let server = try MockSSEServer(body: sse)
        let p = ProviderConfig(id: "openai", name: "OpenAI", api: .openai, baseURL: "http://127.0.0.1:\(server.port)/v1", envKeys: [], defaultModel: "m")
        let r = try await collect(p.client(apiKey: "k"))
        XCTAssertEqual(r.calls.map(\.id), ["A", "B"])
        // Was: A ran with B's arguments and B with none.
        XCTAssertEqual(r.calls.map { $0.input?["expression"]?.string }, ["1+1", "2+2"])
    }
}
