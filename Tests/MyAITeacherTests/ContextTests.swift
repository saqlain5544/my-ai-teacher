import XCTest
@testable import MyAITeacher

final class ContextTests: XCTestCase {
    private func turn(_ n: Int, bulk: Int = 5_000) -> [ChatMessage] {
        [ChatMessage(role: .user, blocks: [.text("question \(n)")]),
         ChatMessage(role: .assistant, blocks: [.thinking("reasoning \(n)"), .toolUse(id: "t\(n)", name: "read", input: ["path": "a"])]),
         ChatMessage(role: .user, blocks: [.toolResult(id: "t\(n)", name: "read", content: String(repeating: "x", count: bulk))]),
         ChatMessage(role: .assistant, blocks: [.text("answer \(n)")])]
    }

    func testTrimEpochKeepsRecentTurnsVerbatim() {
        let msgs = (0..<6).flatMap { turn($0) }
        var c = Conversation(providerID: "openrouter", model: "x")
        c.trimmedThrough = ContextPolicy.nextTrimPoint(msgs, current: nil)
        XCTAssertNotNil(c.trimmedThrough)
        let out = ContextPolicy.prepare(msgs, conversation: c, model: "x")
        XCTAssertEqual(out.count, msgs.count)
        // Turns 0–2 trimmed, 3–5 intact.
        XCTAssertLessThan(out[2].blocks[0].text!.count, 1_400)
        XCTAssertEqual(out[14].blocks[0].text!.count, 5_000)
        XCTAssertLessThan(ContextPolicy.estimateTokens(out), ContextPolicy.estimateTokens(msgs) * 7 / 10)
        // Same trim point → stable (cache-friendly) prefix.
        XCTAssertNil(ContextPolicy.nextTrimPoint(msgs, current: c.trimmedThrough))
    }

    func testScriptAwareTokenEstimate() {
        let english = ChatMessage(role: .user, blocks: [.text(String(repeating: "word ", count: 100))])
        let japanese = ChatMessage(role: .user, blocks: [.text(String(repeating: "日本語の文章です。", count: 50))])
        let e = ContextPolicy.estimateTokens([english]), j = ContextPolicy.estimateTokens([japanese])
        XCTAssertGreaterThan(Double(j) / Double(e), 2.0, "CJK characters are not a quarter of a token")
        XCTAssertGreaterThan(j, 300)
    }

    func testEphemeralContextIsStubbedForLaterRequestsButKeptInTheTranscript() {
        let big = String(repeating: "recalled context line\n", count: 300)
        let ephemeral = Block(kind: .text, text: big, meta: ["hidden": true, "ephemeral": true])
        let trimmed = ContextPolicy.trim(ephemeral)
        XCTAssertLessThan(trimmed.text!.count, 2_000, "old per-turn context is dead weight in every later request")
        XCTAssertTrue(trimmed.text!.contains("chars trimmed"))
        XCTAssertEqual(ContextPolicy.trim(Block(kind: .text, text: big)).text!.count, big.count, "ordinary text is never cut here")
    }

    func testWindowTrimAlwaysMakesProgress() {
        let msgs = [ChatMessage(role: .user, blocks: [.text("start")])]
            + (0..<600).map { ChatMessage(role: .assistant, blocks: [.text("answer \($0)")]) }
        let drop = ContextPolicy.windowTrim(msgs, cut: 600, window: 400, maxBytes: 100_000)
        XCTAssertGreaterThan(drop, 0, "one long turn must not make the window unbounded")
        XCTAssertLessThanOrEqual(msgs.count - drop, 600)
    }

    func testOldThinkingDroppedExceptAdaptiveClaude() {
        let msgs = (0..<2).flatMap { turn($0) }
        let c = Conversation(providerID: "x", model: "x")
        let lean = ContextPolicy.prepare(msgs, conversation: c, model: "deepseek-chat")
        XCTAssertFalse(lean[1].blocks.contains { $0.kind == .thinking })
        XCTAssertTrue(lean[5].blocks.contains { $0.kind == .thinking })   // current turn keeps it
        let claude = ContextPolicy.prepare(msgs, conversation: c, model: "claude-opus-5-5")
        XCTAssertTrue(claude[1].blocks.contains { $0.kind == .thinking })
    }

    func testSummaryReplacesPrefix() {
        let msgs = (0..<3).flatMap { turn($0) }
        var c = Conversation(providerID: "x", model: "x")
        c.compactedThrough = msgs[3].id; c.compactSummary = "Covered: X."
        let out = ContextPolicy.prepare(msgs, conversation: c, model: "x")
        // The summary and the next learner message travel as one learner turn (providers want alternating roles).
        XCTAssertEqual(out.count, msgs.count - 4)
        XCTAssertTrue(out[0].plainText.contains("Covered: X."))
        XCTAssertEqual(out[0].blocks.count, 1 + msgs[4].blocks.count)
    }

    /// The message before a compaction cut can be a failed, empty reply that requests leave out: the summary must still
    /// replace the prefix (the cut is found among the stored messages), and the trim point still lands where it should.
    func testCompactionPointsSurviveFilteredMessages() {
        var msgs = (0..<3).flatMap { turn($0) }
        var failed = ChatMessage(role: .assistant, blocks: [])
        failed.error = "HTTP 529: overloaded"
        msgs.insert(failed, at: 4)   // after turn 0, before the learner's next question
        var c = Conversation(providerID: "x", model: "x")
        c.compactedThrough = failed.id; c.compactSummary = "Covered: X."
        let out = ContextPolicy.prepare(msgs, conversation: c, model: "x")
        XCTAssertTrue(out[0].plainText.contains("Covered: X."), "the summary replaces everything up to the failed reply")
        XCTAssertEqual(out.count, msgs.count - 5)
        // The trim epoch may end on the failed reply too: everything before it is trimmed, nothing after.
        var t = Conversation(providerID: "x", model: "x")
        t.trimmedThrough = failed.id
        let trimmed = ContextPolicy.prepare(msgs, conversation: t, model: "x")
        XCTAssertEqual(trimmed.count, msgs.count - 1)
        XCTAssertLessThan(trimmed[2].blocks[0].text!.count, 1_400)
        XCTAssertEqual(trimmed[6].blocks[0].text!.count, 5_000)
    }

    func testBudgetCapsAtHalfWindow() {
        XCTAssertEqual(ContextPolicy.budget(setting: 48_000, contextWindow: 32_768), 16_384)
        XCTAssertEqual(ContextPolicy.budget(setting: 48_000, contextWindow: 1_000_000), 48_000)
        XCTAssertEqual(ContextPolicy.budget(setting: 48_000, contextWindow: nil), 48_000)
    }

    func testModelInfoParsesProviderShapes() {
        let p = ProviderCatalog.presets[0]
        let or: JSON = ["id": "minimax/minimax-m3.1-flash:free", "context_length": 196_608,
                        "top_provider": ["max_completion_tokens": 32_000], "supported_parameters": ["tools", "reasoning"],
                        "architecture": ["input_modalities": ["text", "image"]], "pricing": ["prompt": "0", "completion": "0"]]
        let a = ModelInfo.parse(id: "minimax/minimax-m3.1-flash:free", or, provider: p)
        XCTAssertEqual(a.contextWindow, 196_608); XCTAssertEqual(a.maxOutput, 32_000)
        XCTAssertEqual(a.reasoning, true); XCTAssertEqual(a.tools, true); XCTAssertEqual(a.vision, true); XCTAssertEqual(a.free, true)
        let gem: JSON = ["name": "models/gemini-3-flash", "inputTokenLimit": 1_048_576, "outputTokenLimit": 65_536, "thinking": true]
        let g = ModelInfo.parse(id: "gemini-3-flash", gem, provider: p)
        XCTAssertEqual(g.contextWindow, 1_048_576); XCTAssertEqual(g.maxOutput, 65_536); XCTAssertEqual(g.reasoning, true)
        let groq: JSON = ["id": "llama", "context_window": 131_072, "max_completion_tokens": 8192, "supported_features": ["tools"]]
        let q = ModelInfo.parse(id: "llama", groq, provider: p)
        XCTAssertEqual(q.contextWindow, 131_072); XCTAssertEqual(q.reasoning, false)
        XCTAssertEqual(ChatSession.maxTokens(provider: p, model: "llama", info: q), 8192)
    }

    func testDeferredToolsLoadOnDemand() async throws {
        let s = AppSettings()
        let base = ToolRegistry.active(s, loaded: []).map(\.name)
        XCTAssertFalse(base.contains("mastery")); XCTAssertTrue(base.contains("load_tools"))
        XCTAssertEqual(ToolRegistry.active(s, loaded: ["mastery", "nope", "browser", "quiz"]).map(\.name), base + ["mastery"], "only this agent's loadable tools load (and the retired `quiz` none)")
        // The course board never waits on another tool being loaded (it used to come in with `mastery`, so a lesson
        // with quizzes off had no board).
        XCTAssertTrue(base.contains("lesson_plan")); XCTAssertFalse(ToolRegistry.deferredIndex("tutor").contains("lesson_plan"))
    }
}

final class PolicyTests: XCTestCase {
    func testPackageInstallsAreBlocked() {
        let bash = BashTool(), code = RunCodeTool()
        for c in ["pip install numpy", "python3 -m pip install x", "uv pip install y", "conda install z", "brew install wget", "npm i -g serve"] {
            XCTAssertNotNil(PermissionExtension.packageInstall(tool: bash, input: ["command": .string(c)]), c)
        }
        XCTAssertNotNil(PermissionExtension.packageInstall(tool: code, input: ["language": "python", "code": "import subprocess; subprocess.run('pip install x', shell=True)"]))
        for c in ["ls -la", "python3 script.py", "pip list", "echo 'install guide'"] {
            XCTAssertNil(PermissionExtension.packageInstall(tool: bash, input: ["command": .string(c)]), c)
        }
    }

    func testPythonDetection() {
        XCTAssertTrue(PermissionExtension.isPython(MathTool(), ["expression": "x"]))
        XCTAssertTrue(PermissionExtension.isPython(RunCodeTool(), ["language": "Python", "code": "1"]))
        XCTAssertFalse(PermissionExtension.isPython(RunCodeTool(), ["language": "javascript", "code": "1"]))
    }

    func testConsecutiveLearnerMessagesMergeForProviders() {
        let msgs = [ChatMessage(role: .user, blocks: [.text("q")]),
                    ChatMessage(role: .assistant, blocks: [.toolUse(id: "t", name: "task", input: [:])]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "t", name: "task", content: "started")]),
                    ChatMessage(role: .user, blocks: [.text("<background-agent id=\"A1\">report</background-agent>")])]
        let out = ContextPolicy.mergeConsecutiveUserTurns(msgs)
        XCTAssertEqual(out.count, 3)
        XCTAssertEqual(out[2].blocks.map(\.kind), [.toolResult, .text], "tool results stay first")
    }

    func testSqueezeKeepsHugeTurnsUnderBudgetAndTheNewestMessageIntact() {
        let huge = String(repeating: "log line\n", count: 40_000)   // ~360k chars ≈ 90k tokens
        let msgs = [ChatMessage(role: .user, blocks: [.text("run it")]),
                    ChatMessage(role: .assistant, blocks: [.toolUse(id: "b", name: "bash", input: ["command": "make"])]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "b", name: "bash", content: huge)]),
                    ChatMessage(role: .user, blocks: [.text("what failed?")])]
        let out = ContextPolicy.squeeze(msgs, budget: 8_000)
        XCTAssertLessThanOrEqual(ContextPolicy.estimateTokens(out), 8_000)
        XCTAssertTrue(out[2].blocks[0].text!.contains("trimmed to fit"))
        XCTAssertEqual(out[3].plainText, "what failed?")
        XCTAssertEqual(ContextPolicy.squeeze(msgs, budget: 1_000_000).map(\.plainText), msgs.map(\.plainText), "under budget: untouched")
    }

    func testNoToolStepLimitByDefault() throws {
        let dec = { (json: String) in try JSONDecoder().decode(AppSettings.self, from: Data(json.utf8)).maxToolTurns }
        XCTAssertEqual(AppSettings().maxToolTurns, 0, "no limit unless the learner sets one")
        XCTAssertEqual(try dec("{}"), 0)
        XCTAssertEqual(try dec(#"{"maxToolTurns": 40}"#), 0, "the old default, saved in every settings file, means never chosen")
        XCTAssertEqual(try dec(#"{"maxToolTurns": 25}"#), 25, "a limit the learner chose is kept")
        XCTAssertEqual(try dec(#"{"maxToolTurns": -3}"#), 0)
    }

    func testStrayHeredocTerminatorIsDropped() {
        XCTAssertEqual(HeredocSlip.strip("const x = 1;\nEOF").0, "const x = 1;\n")
        XCTAssertTrue(HeredocSlip.strip("}\nEOF\n\n").1)
        XCTAssertEqual(HeredocSlip.strip("}\n'EOF'").0, "}\n")
        XCTAssertFalse(HeredocSlip.strip("cat <<EOF\nhi\nEOF\n").1, "a real heredoc in a shell script keeps its terminator")
        XCTAssertFalse(HeredocSlip.strip("const EOF = 0;\n").1)
        XCTAssertFalse(HeredocSlip.strip("hello\n").1)
        XCTAssertEqual(HeredocSlip.strip("hello").0, "hello", "untouched content is byte-identical")
    }

    func testToolchainsAnchorCodeLessonsToInstalledVersions() {
        let zon = ".{\n    .zig_exe = \"/u/zig/zig\",\n    .lib_dir = \"/u/zig/lib\",\n    .std_dir = \"/u/zig/lib/std\",\n    .version = \"0.17.0\",\n}"
        XCTAssertEqual(Toolchains.stdlib("zig", output: zon), "/u/zig/lib/std")
        XCTAssertEqual(Toolchains.stdlib("zig", output: ".{ .lib_dir = \"/old/lib\" }"), "/old/lib/std", "older zig: lib_dir + std")
        XCTAssertNil(Toolchains.stdlib("zig", output: "garbage"))
        XCTAssertEqual(Toolchains.stdlib("go", output: "/usr/local/go\n"), "/usr/local/go/src")
        XCTAssertEqual(Toolchains.firstLine("\nPython 3.12.1\nmore"), "Python 3.12.1")
        XCTAssertNil(Toolchains.section([]))
        let s = Toolchains.section([.init(name: "zig", path: "/u/zig/zig", version: "0.17.0", stdlib: "/u/zig/lib/std")]) ?? ""
        XCTAssertTrue(s.contains("- zig: 0.17.0 — /u/zig/zig; standard library source: /u/zig/lib/std") && s.contains("find /"), s)
    }

    @MainActor func testStudyTimeCountsActiveTimeNotJustReplies() {
        let t0 = Date()
        XCTAssertEqual(ActivityExtension.credit(since: nil, now: t0), 0, "the first action starts the clock")
        XCTAssertEqual(ActivityExtension.credit(since: t0, now: t0.addingTimeInterval(240)), 240, "reading and working between actions counts")
        XCTAssertEqual(ActivityExtension.credit(since: t0, now: t0.addingTimeInterval(ActivityExtension.idleGap + 1)), 0, "a long gap is time away")
        XCTAssertEqual(ActivityExtension.credit(since: t0, now: t0.addingTimeInterval(-5)), 0, "clock skew never subtracts")
    }

    func testTextOnlyModelsGetImagesAsNotes() {
        let msgs = [ChatMessage(role: .user, blocks: [.image(mime: "image/png", base64: "AAAA"), .text("What colour is it?")]),
                    ChatMessage(role: .assistant, blocks: [.toolUse(id: "t", name: "browser", input: [:])]),
                    ChatMessage(role: .user, blocks: [Block.toolResult(id: "t", name: "browser", content: "shot", meta: nil)])]
        var shot = msgs[2]; shot.blocks[0].data = "QUJD"; shot.blocks[0].mime = "image/png"
        let out = ContextPolicy.describeImages([msgs[0], msgs[1], shot])
        XCTAssertEqual(out[0].blocks.map(\.kind), [.text, .text]); XCTAssertEqual(out[0].blocks[0].text, ContextPolicy.imageNote)
        XCTAssertFalse(out[2].blocks[0].hasPayload); XCTAssertTrue(out[2].blocks[0].text?.contains("image omitted") == true)
        XCTAssertEqual(out[1].blocks.map(\.kind), [.toolUse], "everything else is untouched")
        XCTAssertTrue(ChatSession.rejectsImages(HTTPError(status: 400, body: "Upstream request failed: [invalid_value] Beam supports text input only. This conversation contains an image.")))
        XCTAssertTrue(ChatSession.rejectsImages(HTTPError(status: 400, body: #"{"error":{"message":"This model does not support vision inputs"}}"#)))
        XCTAssertFalse(ChatSession.rejectsImages(HTTPError(status: 400, body: "max_tokens too large")))
        XCTAssertFalse(ChatSession.rejectsImages(HTTPError(status: 429, body: "image rate limit")))
        XCTAssertFalse(ChatSession.rejectsImages(URLError(.timedOut)))
    }

    func testRollingSummaryInputsCoverEverything() {
        let msgs = (0..<300).map { ChatMessage(role: $0 % 2 == 0 ? .user : .assistant, blocks: [.text("message \($0) " + String(repeating: "x", count: 900))]) }
        let parts = ContextPolicy.chunks(msgs, maxChars: 60_000)
        XCTAssertEqual(parts.flatMap { $0 }.map(\.id), msgs.map(\.id), "every message in exactly one chunk, in order")
        XCTAssertTrue(parts.allSatisfy { $0.reduce(0) { $0 + ($1.plainText.count) } <= 61_000 })
        let d = ContextPolicy.digest(Array(msgs.prefix(6)), previous: "Earlier: fractions.")
        XCTAssertTrue(d.hasPrefix("Earlier: fractions.") && d.contains("- Learner: message 0"))
    }
}
