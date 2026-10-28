import XCTest
@testable import MyAITeacher

/// Liquid AI's LFM3 models on this Mac: what is downloaded, what each feature does without them, and how the app finds
/// them once installed. The live servers are exercised end to end in the app, not here (gigabytes of weights).
@MainActor
final class LiquidModelsTests: XCTestCase {
    override func tearDown() {
        try? FileManager.default.removeItem(at: LiquidModels.root)
        LiquidModels.shared.refresh()
    }

    /// Marks components as installed (an empty `.installed` folder, like a finished download), with stand-in files.
    private func fakeInstall(_ ids: [String], files: [String: [String]] = [:]) throws {
        for id in ids {
            let dir = LiquidModels.folder(id)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try Data().write(to: dir.appendingPathComponent(".installed"))
            for f in files[id] ?? [] { try Data().write(to: dir.appendingPathComponent(f)) }
        }
    }

    func testEveryDownloadIsPinnedAndNeedsTheRuntime() {
        let ids = LiquidModels.catalog.map(\.id)
        XCTAssertEqual(ids, ["runtime", "omni", "d1"])
        for c in LiquidModels.catalog {
            for f in c.files {
                XCTAssertTrue(f.url.hasPrefix("https://"), f.url)
                XCTAssertTrue(f.hash.hasPrefix("sha256:") && f.hash.count == 71, "\(f.name) has a pinned sha256")
                XCTAssertTrue(f.url.hasSuffix("/" + f.name), "the file keeps its published name")
            }
            if c.id != "runtime" {
                XCTAssertEqual(c.requires, ["runtime"])
                XCTAssertEqual(c.files.count, 2, "weights and the projector (pictures and audio)")
                XCTAssertTrue(c.files[1].name.hasPrefix("mmproj-"))
            }
        }
        XCTAssertTrue(LiquidModels.catalog[0].files[0].archive, "the runtime is a .tar.gz, unpacked on install")
        XCTAssertGreaterThan(LiquidModels.catalog.reduce(0) { $0 + $1.bytes }, 3_000_000_000)
    }

    func testNothingChangesUntilTheModelsAreDownloaded() async {
        XCTAssertFalse(LiquidModels.ready(.omni)); XCTAssertFalse(LiquidModels.ready(.d1))
        let p = ProviderCatalog.presets.first { $0.id == LiquidModels.providerID }!
        XCTAssertFalse(AppModel.shared.hasKey(p), "the provider is listed only once LFM3-Omni is installed")
        XCTAssertFalse(AppModel.shared.availableProviders.contains { $0.id == LiquidModels.providerID })
        XCTAssertFalse(LiquidModels.recognizer(for: "fr")); XCTAssertFalse(LiquidModels.voice(for: "fr"))
        XCTAssertNil(SpeechEngines.localVoice("zh", preference: "omni"))
        XCTAssertNil(SpeechEngines.localVoice("zh", preference: "auto"))
        // d1 missing: every decision is the app's own rule.
        let none = await LocalDecision.ask(state: "x", questions: ["q": ["type": "noul", "instructions": "?"]], timeout: 1)
        XCTAssertNil(none)
        let deep = await DeepWork.needsDeepWork("Explain how TCP congestion control works")
        XCTAssertTrue(deep)
        let thanks = await DeepWork.needsDeepWork("thanks!")
        XCTAssertFalse(thanks)
        let g = await Questions.grade(["type": "short_text", "prompt": "What gas do plants absorb?", "answer": "carbon dioxide"], answer: "CO2")
        XCTAssertNil(g.correct, "no d1: the teacher judges an answer in other words")
        XCTAssertNil(g.judgedBy)
    }

    func testInstalledOmniHearsAndSpeaksItsLanguages() throws {
        try fakeInstall(["runtime", "omni"], files: ["runtime": ["llama-server", "llama-tts"],
                                                     "omni": ["LFM3-Omni-2B-Q4_K_M.gguf", "mmproj-LFM3-Omni-2B-Q8_0.gguf"]])
        XCTAssertTrue(LiquidModels.ready(.omni)); XCTAssertFalse(LiquidModels.ready(.d1))
        XCTAssertNotNil(LiquidModels.binary("llama-server"))
        XCTAssertNotNil(LiquidModels.files(.omni))
        XCTAssertNil(LiquidModels.files(.d1))
        XCTAssertTrue(LiquidModels.recognizer(for: "zh-Hans"), "Chinese, which Supertonic doesn't speak")
        XCTAssertTrue(LiquidModels.voice(for: "he"))
        XCTAssertFalse(LiquidModels.recognizer(for: "ru"), "not one of its speech languages")
        XCTAssertEqual(SpeechEngines.localVoice("zh", preference: "omni"), .omni)
        XCTAssertNil(SpeechEngines.localVoice("zh", preference: "apple"))
        XCTAssertNil(SpeechEngines.localVoice("zh", preference: "open"), "the learner asked for Supertonic")
        XCTAssertFalse(SpeechEngines.useOpenVoice("zh", preference: "omni"))
        let p = ProviderCatalog.presets.first { $0.id == LiquidModels.providerID }!
        XCTAssertTrue(AppModel.shared.hasKey(p))
    }

    func testTheProviderNeedsNoServerToListItsModel() async throws {
        let p = ProviderCatalog.presets.first { $0.id == LiquidModels.providerID }!
        XCTAssertTrue(p.keyOptional); XCTAssertEqual(p.api, .openai)
        let models = try await ProviderCatalog.fetchModels(p, apiKey: nil)
        XCTAssertEqual(models.map(\.id), [LiquidModels.omniModel])
        XCTAssertEqual(models[0].contextWindow, LiquidModels.contextWindow, "the context the app's server gives it, not 128k")
        XCTAssertEqual(models[0].vision, true); XCTAssertEqual(models[0].tools, true); XCTAssertEqual(models[0].reasoning, false)
        let running = await LiquidModels.server(.omni).isRunning
        XCTAssertFalse(running, "listing started nothing")
    }

    func testAServerWithoutItsFilesFailsClearly() async {
        do { _ = try await LiquidModels.server(.d1).url(); XCTFail("nothing installed") }
        catch { XCTAssertTrue(error.localizedDescription.contains("isn't installed"), error.localizedDescription) }
    }

    /// A server outlives nothing: the app ending (here a stand-in process, killed) or the watchdog being stopped ends it.
    func testAServerEndsWithTheApp() async throws {
        func run(_ exe: String, _ args: [String]) throws -> Process {
            let p = Process(); p.executableURL = URL(fileURLWithPath: exe); p.arguments = args; try p.run(); return p
        }
        // The stand-in server writes its pid, then becomes `sleep`.
        let pidFile = FileManager.default.temporaryDirectory.appendingPathComponent("watchdog-\(UUID().uuidString.prefix(6)).pid")
        let serverCommand = ["/bin/sh", "-c", "echo $$ > '\(pidFile.path)'; exec /bin/sleep 60"]
        func childOf(_ sh: Process) async -> Int32? {
            for _ in 0..<40 {
                if let s = try? String(contentsOf: pidFile, encoding: .utf8), let pid = Int32(s.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    try? FileManager.default.removeItem(at: pidFile); return pid
                }
                try? await Task.sleep(nanoseconds: 50_000_000)
            }
            return nil
        }
        func gone(_ pid: Int32) async -> Bool {
            for _ in 0..<60 { if kill(pid, 0) != 0 { return true }; try? await Task.sleep(nanoseconds: 100_000_000) }
            return false
        }
        // The app dies.
        let app = try run("/bin/sleep", ["60"])
        let sh = try run("/bin/sh", ["-c", LiquidModels.watchdog, "sh", String(app.processIdentifier)] + serverCommand)
        let child = await childOf(sh)
        let server = try XCTUnwrap(child)
        app.terminate()
        let ended = await gone(server)
        XCTAssertTrue(ended, "the server ends within seconds of the app")
        // The app stops the server (terminating the watchdog).
        let sh2 = try run("/bin/sh", ["-c", LiquidModels.watchdog, "sh", String(ProcessInfo.processInfo.processIdentifier)] + serverCommand)
        let child2 = await childOf(sh2)
        let server2 = try XCTUnwrap(child2)
        sh2.terminate()
        let ended2 = await gone(server2)
        XCTAssertTrue(ended2, "stopping the watchdog stops the server")
    }

    /// The real models, when LIQUID_MODELS names a folder with the llama.cpp runtime and the .gguf files (skipped
    /// otherwise): d1 grades and routes, LFM3-Omni teaches and hears.
    func testLiveModels() async throws {
        guard let src = ProcessInfo.processInfo.environment["LIQUID_MODELS"].map({ URL(fileURLWithPath: $0) }) else {
            throw XCTSkip("set LIQUID_MODELS to run the real models")
        }
        let fm = FileManager.default
        func find(_ name: String) throws -> URL {
            let e = fm.enumerator(at: src, includingPropertiesForKeys: nil)!
            for case let u as URL in e where u.lastPathComponent == name { return u }
            throw XCTSkip("\(name) isn't in \(src.path)")
        }
        let rt = try find("llama-server").deletingLastPathComponent()
        try fm.createDirectory(at: LiquidModels.folder("runtime"), withIntermediateDirectories: true)
        for f in try fm.contentsOfDirectory(at: rt, includingPropertiesForKeys: nil) {
            try fm.createSymbolicLink(at: LiquidModels.folder("runtime").appendingPathComponent(f.lastPathComponent), withDestinationURL: f)
        }
        for c in LiquidModels.catalog where c.id != "runtime" {
            try fm.createDirectory(at: LiquidModels.folder(c.id), withIntermediateDirectories: true)
            for f in c.files { try fm.createSymbolicLink(at: LiquidModels.folder(c.id).appendingPathComponent(f.name), withDestinationURL: try find(f.name)) }
        }
        try fakeInstall(["runtime", "omni", "d1"])
        defer { Task { for k in LiquidModels.Kind.allCases { await LiquidModels.server(k).stop() } } }
        _ = try await LiquidModels.server(.d1).url()   // loaded once, before the timed questions

        func grade(_ prompt: String, _ key: String, _ given: String, lang: String? = nil) async -> Questions.Grade {
            var q: JSON = ["type": "short_text", "prompt": .string(prompt), "answer": .string(key)]
            if let lang { q = ["type": "short_text", "prompt": .string(prompt), "answer": .string(key), "lang": .string(lang)] }
            return await Questions.grade(q, answer: .string(given))
        }
        let co2 = await grade("What gas do plants absorb for photosynthesis?", "carbon dioxide", "CO2")
        XCTAssertEqual(co2.correct, true); XCTAssertNotNil(co2.judgedBy)
        let oxygen = await grade("What gas do plants absorb for photosynthesis?", "carbon dioxide", "oxygen")
        XCTAssertEqual(oxygen.correct, false)
        let french = await grade("Translate 'the cat' into French", "le chat", "la chat", lang: "fr")
        XCTAssertNil(french.correct, "a language answer stays with the teacher")
        let thanks = await DeepWork.needsDeepWork("got it, thanks!")
        XCTAssertFalse(thanks)
        let derive = await DeepWork.needsDeepWork("derive the quadratic formula")
        XCTAssertTrue(derive)
        let fact = await DeepWork.needsDeepWork("what is the capital of France?")
        XCTAssertFalse(fact, "a quick fact, though the rule's cue words match it")

        // LFM3-Omni: a lesson reply through the provider, and speech heard.
        let p = ProviderCatalog.presets.first { $0.id == LiquidModels.providerID }!
        var text = ""
        let req = LLMRequest(model: LiquidModels.omniModel, system: "Answer in one short sentence.",
                             messages: [ChatMessage(role: .user, blocks: [.text("What is 6 times 7?")])], maxTokens: 100)
        for try await e in p.client(apiKey: nil).stream(req) { if case .text(let t) = e { text += t } }
        XCTAssertTrue(text.contains("42"), text)
        let wav = fm.temporaryDirectory.appendingPathComponent("omni-asr.wav")
        let say = await ProcessRunner.run("/usr/bin/say", ["-v", "Thomas", "-o", wav.path, "--data-format=LEI16@16000", "Bonjour, je voudrais un café."], timeout: 30)
        XCTAssertEqual(say.exitCode, 0)
        let heard = await LiquidModels.transcribe(wav, lang: "en")
        XCTAssertNotNil(heard)
        let heardFr = await LiquidModels.transcribe(wav, lang: "fr")
        XCTAssertTrue(heardFr?.lowercased().contains("café") == true, heardFr ?? "nil")
    }

    func testAFreePortIsALocalPort() throws {
        let a = try LlamaServer.freePort(), b = try LlamaServer.freePort()
        XCTAssertTrue((1024...65535).contains(a)); XCTAssertTrue((1024...65535).contains(b))
    }

    func testDecisionsAreOnByDefaultAndOldSettingsKeepThem() throws {
        XCTAssertTrue(AppSettings().localDecisions)
        let old = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"providerID":"minimax"}"#.utf8))
        XCTAssertTrue(old.localDecisions)
        let off = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"localDecisions":false}"#.utf8))
        XCTAssertFalse(off.localDecisions)
    }
}
