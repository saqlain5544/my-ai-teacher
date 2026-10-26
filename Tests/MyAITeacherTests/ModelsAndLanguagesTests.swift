import XCTest
@testable import MyAITeacher

/// Model search: any word order, typos, partial words, separators ignored; numbers exact.
final class FuzzyTests: XCTestCase {
    private let catalogue: [(provider: String, id: String, model: String)] = [
        ("NVIDIA NIM", "nvidia", "deepseek-ai/deepseek-v4.1-flash"),
        ("NVIDIA NIM", "nvidia", "nvidia/llama-3.1-nemotron-ultra-253b-v1"),
        ("NVIDIA NIM", "nvidia", "qwen/qwen3-coder-480b-a35b-instruct"),
        ("DeepSeek", "deepseek", "deepseek-flash"),
        ("DeepSeek", "deepseek", "deepseek-v4-pro"),
        ("OpenRouter", "openrouter", "deepseek/deepseek-v4-pro"),
        ("OpenRouter", "openrouter", "anthropic/claude-sonnet-5.5"),
        ("OpenRouter", "openrouter", "openai/gpt-5.4"),
        ("MiniMax", "minimax", "MiniMax-M3"),
        ("MiniMax", "minimax", "MiniMax-M3.1-Flash"),
    ]

    private func search(_ q: String) -> [String] {
        catalogue.compactMap { c in Fuzzy.score(q, [c.provider, c.id, c.model]).map { ("\(c.id):\(c.model)", $0) } }
            .sorted { $0.1 > $1.1 }.map(\.0)
    }

    func testWordsInAnyOrderAndWithTypos() {
        let nim = ["nvidia:deepseek-ai/deepseek-v4.1-flash"]
        for q in ["nvidia deepseek", "deepseek nvidia", "nvdia deepsek", "deepsek nvidai", "NVIDIA  DeepSeek", "deeps nvid", "nvidia-deepseek"] {
            XCTAssertEqual(search(q), nim, q)
        }
    }

    func testPartialWordsSeparatorsAndRanking() {
        XCTAssertEqual(Set(search("deepseek pro")), ["deepseek:deepseek-v4-pro", "openrouter:deepseek/deepseek-v4-pro"])
        XCTAssertEqual(Set(search("v4pro")), ["deepseek:deepseek-v4-pro", "openrouter:deepseek/deepseek-v4-pro"])
        XCTAssertEqual(search("deepseek flash").first, "deepseek:deepseek-flash", "the plainest exact match ranks first")
        XCTAssertEqual(search("sonet 5.5"), ["openrouter:anthropic/claude-sonnet-5.5"])
        XCTAssertEqual(search("gpt5"), ["openrouter:openai/gpt-5.4"])
        XCTAssertEqual(search("minimax m3").first, "minimax:MiniMax-M3")
        XCTAssertEqual(search("nemotorn ultra"), ["nvidia:nvidia/llama-3.1-nemotron-ultra-253b-v1"])
        XCTAssertEqual(search("qwen coder"), ["nvidia:qwen/qwen3-coder-480b-a35b-instruct"])
    }

    func testNumbersMustMatchAndNonsenseMatchesNothing() {
        XCTAssertTrue(search("deepseek v3").isEmpty, "a version is never 'close enough'")
        XCTAssertTrue(search("m4").isEmpty)
        XCTAssertTrue(search("zebra").isEmpty)
        XCTAssertEqual(search("").count, catalogue.count, "an empty query keeps everything")
    }

    func testDistance() {
        XCTAssertEqual(Fuzzy.distance("nvdia", "nvidia", limit: 2), 1)
        XCTAssertEqual(Fuzzy.distance("nvidai", "nvidia", limit: 2), 1, "swapped neighbours are one edit")
        XCTAssertEqual(Fuzzy.distance("deepsek", "deepseek", limit: 2), 1)
        XCTAssertEqual(Fuzzy.distance("abc", "xyz", limit: 1), 2, "cut off above the limit")
    }
}

/// DeepSeek V4: thinking is on unless disabled, retired ids still work, reasoning goes back on every turn.
final class DeepSeekTests: XCTestCase {
    private let ds = ProviderCatalog.presets.first { $0.id == "deepseek" }!

    func testOneOffCallsDoNotWritePromptCaches() {
        let p = ProviderCatalog.presets.first { $0.id == "anthropic" }!
        let c = AnthropicClient(config: p, apiKey: nil)
        var r = LLMRequest(model: "claude-opus-4-8", system: "shared instructions\n\n# Environment\nfolder",
                           messages: [ChatMessage(role: .user, blocks: [.text("hi")])])
        let cached = c.buildBody(r)
        XCTAssertNotNil(cached["system"]?[0]?["cache_control"], "the lesson's own call caches")
        r.cache = false
        let oneOff = c.buildBody(r)
        XCTAssertNil(oneOff["system"]?[0]?["cache_control"], "a plan/review/summary call writes no entry it can never read")
        XCTAssertNil(oneOff["messages"]?[0]?["content"]?[0]?["cache_control"])
    }

    func testThinkingOffIsExplicitAndOnCarriesEffort() {
        let c = OpenAIClient(config: ds, apiKey: nil)
        var r = LLMRequest(model: "deepseek-chat", system: "", messages: [ChatMessage(role: .user, blocks: [.text("hi")])])
        var b = c.buildBody(r)
        XCTAssertEqual(b["thinking"]?["type"]?.string, "disabled", "off must be said: DeepSeek thinks by default")
        XCTAssertNil(b["reasoning_effort"])
        XCTAssertEqual(b["model"]?.string, "deepseek-flash", "a retired id goes to what serves it now")
        r.thinking = .low; r.model = "deepseek-v4-pro"
        b = c.buildBody(r)
        XCTAssertEqual(b["thinking"]?["type"]?.string, "enabled"); XCTAssertEqual(b["reasoning_effort"]?.string, "low")
        XCTAssertEqual(b["model"]?.string, "deepseek-v4-pro")
        XCTAssertEqual(ds.defaultModel, "deepseek-flash")
    }

    func testReasoningIsReplayedOnEveryAssistantTurn() {
        let c = OpenAIClient(config: ds, apiKey: nil)
        let msgs = [ChatMessage(role: .user, blocks: [.text("q1")]),
                    ChatMessage(role: .assistant, blocks: [.thinking("plain turn reasoning"), .text("a1")]),
                    ChatMessage(role: .user, blocks: [.text("q2")]),
                    ChatMessage(role: .assistant, blocks: [.thinking("tool turn reasoning"), .toolUse(id: "t1", name: "math", input: ["x": 1])]),
                    ChatMessage(role: .user, blocks: [.toolResult(id: "t1", name: "math", content: "2")])]
        let out = c.convert(LLMRequest(model: "deepseek-v4-pro", system: "", messages: msgs, thinking: .high))
        let assistants = out.filter { $0["role"]?.string == "assistant" }
        XCTAssertEqual(assistants.map { $0["reasoning_content"]?.string }, ["plain turn reasoning", "tool turn reasoning"])
    }

    func testModelListMetadata() {
        let entry = JSON.parse(#"{"id":"deepseek-v4-pro","object":"model","owned_by":"deepseek","name":"DeepSeek-V4-Pro","context_window":1000000,"max_output_tokens":384000,"input_modalities":["text"],"effort":{"supported_levels":["low","high","max"],"default_level":"high"}}"#)!
        let i = ModelInfo.parse(id: "deepseek-v4-pro", entry, provider: ds)
        XCTAssertEqual(i.contextWindow, 1_000_000); XCTAssertEqual(i.maxOutput, 384_000)
        XCTAssertEqual(i.efforts, ["low", "high", "max"]); XCTAssertEqual(i.reasoning, true); XCTAssertEqual(i.vision, false)
    }
}

/// Zig snippets run like the other compiled languages: built in scratch, run in the lesson's folder, nothing left behind.
final class ZigRunTests: XCTestCase {
    func testZigRunsAndLeavesTheFolderClean() async throws {
        try XCTSkipIf(ProcessRunner.which("zig") == nil, "zig not installed")
        let lesson = FileManager.default.temporaryDirectory.appendingPathComponent("zig-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: lesson, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lesson) }
        try "from the lesson".write(to: lesson.appendingPathComponent("note.txt"), atomically: true, encoding: .utf8)
        // Printing only: Zig's file APIs move between releases (0.17 dropped std.fs.cwd()).
        let code = """
        const std = @import("std");
        pub fn main() void {
            const n: u8 = 2 + 3;
            std.debug.print("sum={d}\\n", .{n});
        }
        """
        let r = try await RunCodeTool.execute(language: "zig", code: code, stdin: nil, timeout: 120, workingDirectory: lesson)
        XCTAssertFalse(r.failed, r.text)
        XCTAssertTrue(r.text.contains("sum=5"), r.text)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: lesson.path), ["note.txt"], "no .zig-cache or binary in the lesson's folder")
    }

    func testSnippetsImportTheLessonsFiles() async throws {
        XCTAssertTrue(RunCodeTool.isCommonJS("const { f } = require('./wf.js');\nconsole.log(f())"))
        XCTAssertFalse(RunCodeTool.isCommonJS("import fs from 'node:fs';\nconst x = require"))
        XCTAssertFalse(RunCodeTool.isCommonJS("console.log(1)"))
        try XCTSkipIf(ProcessRunner.which("node") == nil, "node not installed")
        let lesson = FileManager.default.temporaryDirectory.appendingPathComponent("cjs-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: lesson, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: lesson) }
        try "module.exports = { twice: n => 2 * n };\n".write(to: lesson.appendingPathComponent("wf.js"), atomically: true, encoding: .utf8)
        // A learner's files, imported relative to the lesson's folder, as a review checks them: CommonJS, ES module, Python.
        let cjs = try await RunCodeTool.execute(language: "javascript", code: "const { twice } = require('./wf.js');\nconsole.log('twice=' + twice(21));",
                                                stdin: nil, timeout: 30, workingDirectory: lesson)
        XCTAssertFalse(cjs.failed, cjs.text); XCTAssertTrue(cjs.text.contains("twice=42"), cjs.text)
        let esm = try await RunCodeTool.execute(language: "javascript", code: "import m from './wf.js';\nconsole.log('esm=' + m.twice(2));",
                                                stdin: nil, timeout: 30, workingDirectory: lesson)
        XCTAssertFalse(esm.failed, esm.text); XCTAssertTrue(esm.text.contains("esm=4"), esm.text)
        try XCTSkipIf(ProcessRunner.which("python3") == nil, "python3 not installed")
        try "def total(xs):\n    return sum(xs)\n".write(to: lesson.appendingPathComponent("shop.py"), atomically: true, encoding: .utf8)
        let py = try await RunCodeTool.execute(language: "python", code: "import sys\nfrom shop import total\nprint('total=', total([1, 2]), sys.argv[0].endswith('main.py'))",
                                               stdin: nil, timeout: 30, workingDirectory: lesson)
        XCTAssertFalse(py.failed, py.text); XCTAssertTrue(py.text.contains("total= 3 True"), py.text)
        let err = try await RunCodeTool.execute(language: "python", code: "x = 1\nraise ValueError('boom')\n", stdin: nil, timeout: 30, workingDirectory: lesson)
        XCTAssertTrue(err.failed && err.text.contains("raise ValueError('boom')"), "tracebacks still show the source line: \(err.text)")
    }
}

/// Claude requests: history edits must not turn into 400s, and server-side clearing only removes screenshots.
final class ClaudeHistoryTests: XCTestCase {
    private let first = ProviderCatalog.presets.first { $0.id == "anthropic" }!
    private func tools(_ names: [String]) -> [ToolSpec] { names.map { ToolSpec(name: $0, description: "", schema: ["type": "object"]) } }

    func testMismatchedThinkingIsDroppedNotRejected() {
        let c = AnthropicClient(config: first, apiKey: nil)
        var r = LLMRequest(model: "claude-opus-5-5", system: "", messages: [ChatMessage(role: .user, blocks: [.text("hi")])], thinking: .high)
        XCTAssertEqual(c.buildBody(r)["thinking"]?["block_binding"]?["prefix_mismatch_behavior"]?.string, "drop_block")
        XCTAssertTrue(c.betas(r).contains("thinking-binding-controls-2026-08-01"), "the field needs its beta header (400 without)")
        r.thinking = .off
        XCTAssertNil(c.buildBody(r)["thinking"]?["block_binding"], "thinking on only")
        XCTAssertFalse(c.betas(r).contains("thinking-binding-controls-2026-08-01"))
        r.thinking = .high; r.model = "claude-opus-4-7"
        XCTAssertNil(c.buildBody(r)["thinking"]?["block_binding"], "only models that run the check")
        var compatible = first; compatible.baseURL = "https://api.minimax.io/anthropic/v1"
        r.model = "claude-opus-5-5"
        XCTAssertNil(AnthropicClient(config: compatible, apiKey: nil).buildBody(r)["thinking"]?["block_binding"], "Anthropic's own API only")
    }

    func testServerSideClearingTakesOnlyScreenshotsAndOnlyOnceThereAreSome() {
        let c = AnthropicClient(config: first, apiKey: nil)
        let use = ChatMessage(role: .assistant, blocks: [.toolUse(id: "t1", name: "browser", input: ["action": "screenshot"])])
        var shot = Block.toolResult(id: "t1", name: "browser", content: "screenshot")
        shot.mime = "image/png"; shot.data = "iVBORw0KGgo="
        var r = LLMRequest(model: "claude-sonnet-5-5", system: "", messages: [ChatMessage(role: .user, blocks: [.text("go")])],
                           tools: tools(["read", "bash", "browser", "computer"]), thinking: .low)
        XCTAssertNil(c.buildBody(r)["context_management"], "declared tools alone clear nothing")
        r.messages += [use, ChatMessage(role: .user, blocks: [shot])]
        let edit = c.buildBody(r)["context_management"]?["edits"]?[0]
        XCTAssertEqual(edit?["type"]?.string, "clear_tool_uses_20250919")
        XCTAssertEqual(edit?["exclude_tools"]?.array?.compactMap(\.string), ["read", "bash"], "file reads and shell output are never cleared")
        XCTAssertTrue(c.betas(r).contains("context-management-2025-06-27"))
    }
}

/// A quiz's `pattern` checks the answer's shape; it must never be the answer (the live quiz-mode run got stuck on it).
final class QuizPatternTests: XCTestCase {
    private func pattern(_ p: String, _ answer: JSON?) -> String? {
        var q: [String: JSON] = ["type": "short_text", "prompt": "x", "pattern": .string(p)]
        if let answer { q["answer"] = answer }
        return Questions.normalize([.object(q)])[0]["pattern"]?.string
    }
    func testAnAnswerIsNotAFormat() {
        XCTAssertNil(pattern("Largest", "Largest"), "MiniMax-M3 put the answer there: wrong answers couldn't be submitted")
        XCTAssertNil(pattern("Paris", nil), "a plain word is no format either")
        XCTAssertEqual(pattern("[A-Z]{2}\\d{4}", "AB1234"), "[A-Z]{2}\\d{4}", "a real format stays")
        XCTAssertEqual(pattern("\\d+(\\.\\d+)?", nil), "\\d+(\\.\\d+)?")
        XCTAssertNil(pattern("[0-9]+", "twelve"), "a format the expected answer fails is wrong")
        XCTAssertNil(pattern("(unclosed", nil), "doesn't compile")
        XCTAssertEqual(pattern("[a-z]+", .array(["cat", "dog"])), "[a-z]+", "every accepted answer passes")
        XCTAssertNil(pattern("[0-9]+", .object(["item": .array(["twelve"])])), "answers wrapped in an object are read too")
    }
}

/// The model picker's own lists: the wiring around Fuzzy (provider order, model order, what's left out).
final class ModelPickerTests: XCTestCase {
    @MainActor func testPickerListsMatchTheQueryInAnyOrderWithTypos() {
        let byID = Dictionary(uniqueKeysWithValues: ProviderCatalog.presets.map { ($0.id, $0) })
        let providers = ["nvidia", "deepseek", "openrouter", "minimax"].compactMap { byID[$0] }
        let lists = ["nvidia": ["meta/llama-3.3-70b-instruct", "deepseek-ai/deepseek-v4.1-flash", "qwen/qwen3-coder-480b-a35b-instruct", "deepseek-ai/deepseek-r1"],
                     "deepseek": ["deepseek-flash", "deepseek-v4-pro"],
                     "openrouter": ["deepseek/deepseek-v4-pro", "anthropic/claude-sonnet-5.5", "openai/gpt-5.4"],
                     "minimax": ["MiniMax-M3", "MiniMax-M3.1-Flash"]]
        let pick = { (q: String) in ModelPickerPopover.sections(q, providers: providers, models: { lists[$0.id] ?? [] }, names: { _, _ in nil }) }
        for q in ["nvidia deepseek", "deepseek nvidia", "nvdia deepsek", "deepsek nvidai"] {
            let s = pick(q)
            XCTAssertEqual(s.map(\.provider.id), ["nvidia"], q)
            XCTAssertEqual(Set(s[0].models), ["deepseek-ai/deepseek-v4.1-flash", "deepseek-ai/deepseek-r1"], q)
        }
        let ds = pick("deepseek")
        XCTAssertEqual(ds.first?.provider.id, "deepseek", "the provider named exactly comes first")
        XCTAssertFalse(ds.contains { $0.provider.id == "minimax" }, "providers without a match are left out")
        XCTAssertEqual(pick("deepseek pro").map(\.provider.id).sorted(), ["deepseek", "openrouter"])
        XCTAssertEqual(pick("").count, providers.count, "no query: every provider")
        // Found on the live catalogues: the exact version before its neighbours, and the provider the query names first.
        let sonnet = ModelPickerPopover.sections("sonet 5.5", providers: providers,
            models: { $0.id == "openrouter" ? ["anthropic/claude-sonnet-5", "anthropic/claude-sonnet-4.5", "anthropic/claude-sonnet-5.5"] : [] }, names: { _, _ in nil })
        XCTAssertEqual(sonnet.first?.models.first, "anthropic/claude-sonnet-5.5")
        let mm = ModelPickerPopover.sections("minimax m3", providers: providers + [byID["ollama-cloud"]!],
            models: { $0.id == "ollama-cloud" ? ["minimax-m3"] : lists[$0.id] ?? [] }, names: { p, m in p == "minimax" ? m : nil })
        XCTAssertEqual(mm.first?.provider.id, "minimax", "MiniMax itself, not a host of its model")
    }
}
