import Foundation
import Darwin

/// Liquid AI's open LFM3 models, downloaded on demand and run on this Mac by llama.cpp's server — nothing leaves the Mac.
/// Like `OpenSpeech`, nothing is bundled: the learner downloads each one in Settings › On this Mac, every file is checked
/// against a pinned hash, and whatever isn't installed (or fails) falls back to what the app did before.
///
///   runtime   llama.cpp b11946 (macOS arm64), MIT: the first release that runs LFM3-Omni and d1.
///   omni      LFM3-Omni-2B (Q4_K_M + Q8_0 projector): a teacher model for lessons (text, pictures, audio in; text out),
///             speech recognition (`Perform ASR in <language>.`) and a voice (llama-tts). LFM Open License v1.0.
///   d1        d1-Omni-2B (Q8_0 + projector): a decision model. It answers fixed questions (yes/no, a choice, a score)
///             with calibrated probabilities in one forward pass, in ~50 ms: how the app routes and grades on this Mac.
@MainActor
final class LiquidModels: ObservableObject {
    static let shared = LiquidModels()

    /// The lesson provider that runs LFM3-Omni (`ProviderCatalog`).
    nonisolated static let providerID = "liquid"
    nonisolated static let omniModel = "LFM3-Omni-2B"
    /// The context each server gives one request (the model was trained on 128k; 64k keeps memory small).
    nonisolated static let contextWindow = 65_536

    private nonisolated static let hf = "https://huggingface.co/LiquidAI"
    nonisolated static let catalog: [OpenSpeech.Component] = [
        OpenSpeech.Component(id: "runtime", title: "llama.cpp runtime b11946",
                  detail: "The engine that runs the models below on this Mac (Metal). Needed by both.",
                  languages: [], license: "MIT",
                  files: [.init(url: "https://github.com/ggml-org/llama.cpp/releases/download/b11946/llama-b11946-bin-macos-arm64.tar.gz",
                                name: "llama-b11946-bin-macos-arm64.tar.gz", bytes: 16_438_371,
                                hash: "sha256:d618da5e7bbb19077f086e6a7e1d77eab55b9bfd481f7531aadada86d13db9ed")]),
        OpenSpeech.Component(id: "omni", title: "LFM3-Omni-2B",
                  detail: "A small teacher that runs on this Mac: pick “LFM3-Omni (on this Mac)” as a lesson's provider. It reads pictures and listens, and can hear you and speak (Settings › Voice).",
                  languages: speechLanguages, license: "LFM Open License v1.0",
                  files: [.init(url: "\(hf)/LFM3-Omni-2B-GGUF/resolve/main/LFM3-Omni-2B-Q4_K_M.gguf", name: "LFM3-Omni-2B-Q4_K_M.gguf",
                                bytes: 1_099_630_080, hash: "sha256:9f8d30e9d4fd7a9349d586e077988229b3ca0a0e4ad730897563d1eccc9893e2"),
                          .init(url: "\(hf)/LFM3-Omni-2B-GGUF/resolve/main/mmproj-LFM3-Omni-2B-Q8_0.gguf", name: "mmproj-LFM3-Omni-2B-Q8_0.gguf",
                                bytes: 540_892_768, hash: "sha256:720ff4fc09df0e026c4ec641d0c698bf27b5bcd50561944c88eda5e3dffe1839")],
                  requires: ["runtime"]),
        OpenSpeech.Component(id: "d1", title: "d1-Omni-2B decisions",
                  detail: "Quick decisions on this Mac: whether a request needs a planned, checked answer, and whether a short answer that doesn't match the key word for word is right.",
                  languages: [], license: "LFM Open License v1.0",
                  files: [.init(url: "\(hf)/d1-Omni-2B-GGUF/resolve/main/d1-Omni-2B-Q8_0.gguf", name: "d1-Omni-2B-Q8_0.gguf",
                                bytes: 1_846_241_184, hash: "sha256:aedf1a7c341b4281979423dbc39e9c3d3ad1da8834156c8e75af5399ca3b0861"),
                          .init(url: "\(hf)/d1-Omni-2B-GGUF/resolve/main/mmproj-d1-Omni-2B-Q8_0.gguf", name: "mmproj-d1-Omni-2B-Q8_0.gguf",
                                bytes: 326_104_096, hash: "sha256:31778160ac0ec70f9b59f296aa1c8e70cbd1eb7e3a3ff873d695aaa4c7b8d674")],
                  requires: ["runtime"]),
    ]
    /// LFM3-Omni's speech languages (its model card): what it can hear and speak.
    nonisolated static let speechLanguages = ["ar", "da", "de", "el", "en", "fi", "fr", "he", "it", "ja", "ko", "nl", "pl", "pt", "es", "sv", "tr", "zh"]

    /// Application Support/MyAITeacher/liquid/<component>/ (a test profile's own support folder).
    nonisolated static var root: URL { AppPaths.support.appendingPathComponent("liquid", isDirectory: true) }
    nonisolated static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    nonisolated static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(id).appendingPathComponent(".installed").path)
    }
    nonisolated static func ready(_ kind: Kind) -> Bool { isInstalled("runtime") && isInstalled(kind.rawValue) }

    @Published private(set) var states: [String: OpenSpeech.State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init() { refresh() }

    func refresh() {
        for c in Self.catalog where tasks[c.id] == nil { states[c.id] = Self.isInstalled(c.id) ? .installed : (states[c.id].flatMap { if case .failed = $0 { return $0 }; return nil } ?? .absent) }
    }

    // MARK: Install / remove

    func install(_ id: String) {
        guard let c = Self.catalog.first(where: { $0.id == id }), tasks[id] == nil else { return }
        for r in c.requires where !Self.isInstalled(r) { install(r) }
        states[id] = .downloading(0, "Starting…")
        tasks[id] = Task { [weak self] in
            do {
                try await OpenSpeech.download(c, into: Self.root) { frac, note in Task { @MainActor in self?.states[id] = .downloading(frac, note) } }
                await MainActor.run { if !Task.isCancelled { self?.states[id] = .installed }; self?.tasks[id] = nil }
                AppLog.write("liquid: installed \(id)")
            } catch {
                let msg = (error as? CancellationError) != nil ? "Cancelled" : error.localizedDescription
                await MainActor.run { self?.states[id] = msg == "Cancelled" ? .absent : .failed(msg); self?.tasks[id] = nil }
                AppLog.write("liquid: \(id) failed: \(msg)")
            }
        }
    }
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func remove(_ id: String) {
        cancel(id)
        tasks[id] = nil
        Task {
            // A running server holds the files: stop it first (the runtime serves both).
            for k in Kind.allCases where id == "runtime" || id == k.rawValue { await Self.server(k).stop() }
            try? FileManager.default.removeItem(at: Self.folder(id))
        }
        states[id] = .absent
    }

    // MARK: Servers

    enum Kind: String, CaseIterable, Sendable { case omni, d1 }

    private nonisolated static let servers = [Kind.omni: LlamaServer(.omni), .d1: LlamaServer(.d1)]
    nonisolated static func server(_ k: Kind) -> LlamaServer { servers[k]! }

    /// A llama.cpp binary in the unpacked runtime (flat: the binaries next to their dylibs).
    nonisolated static func binary(_ name: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: folder("runtime"), includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.lastPathComponent == name { return u }
        return nil
    }
    /// A component's model weights and its projector (pictures and audio).
    nonisolated static func files(_ k: Kind) -> (model: URL, projector: URL)? {
        let c = catalog.first { $0.id == k.rawValue }!
        let paths = c.files.map { folder(k.rawValue).appendingPathComponent($0.name) }
        guard paths.allSatisfy({ FileManager.default.fileExists(atPath: $0.path) }) else { return nil }
        return (paths[0], paths[1])
    }

    /// The servers' process ids, for the quit handler (which can't await an actor).
    nonisolated(unsafe) private static var pids: [Kind: Int32] = [:]
    private nonisolated static let pidLock = NSLock()
    nonisolated static func track(_ k: Kind, pid: Int32?) { pidLock.withLock { pids[k] = pid } }
    /// Stops every server (the app is quitting).
    nonisolated static func stopAll() {
        for pid in pidLock.withLock({ Array(pids.values) }) { kill(pid, SIGTERM) }
    }

    /// Runs a server under a watchdog shell that ends it when the app ends, however it ends (a crash, a kill): a server
    /// left behind holds a gigabyte or two of GPU memory, and a few of them starve the next one. Terminating the shell
    /// stops the server too. Arguments: the app's pid, then the command. The server is killed outright: it keeps nothing,
    /// and llama.cpp b11946 aborts while freeing Metal on SIGTERM (a crash report for every stop).
    nonisolated static let watchdog = #"app=$1; shift; "$@" & c=$!; trap 'kill -9 $c 2>/dev/null; exit 0' TERM INT HUP; "#
        + #"while kill -0 "$app" 2>/dev/null && kill -0 $c 2>/dev/null; do sleep 1; done; kill -9 $c 2>/dev/null; wait $c"#

    // MARK: Speech

    nonisolated static func recognizer(for lang: String?) -> Bool {
        guard let lang, ready(.omni) else { return false }
        return speechLanguages.contains(String(lang.prefix(2)).lowercased())
    }
    nonisolated static func voice(for lang: String?) -> Bool {
        guard let lang, ready(.omni), binary("llama-tts") != nil else { return false }
        return speechLanguages.contains(String(lang.prefix(2)).lowercased())
    }

    /// Transcribes a WAV with LFM3-Omni (its ASR prompt, greedy); nil when it isn't installed or fails.
    nonisolated static func transcribe(_ wav: URL, lang: String?) async -> String? {
        guard recognizer(for: lang), let lang, let data = try? Data(contentsOf: wav) else { return nil }
        let body: JSON = ["model": .string(omniModel), "temperature": 0, "max_tokens": 1024, "messages": [
            ["role": "system", "content": .string("Perform ASR in \(Languages.englishName(String(lang.prefix(2)))).")],
            ["role": "user", "content": [["type": "input_audio", "input_audio": ["data": .string(data.base64EncodedString()), "format": "wav"]]]],
        ]]
        do {
            let reply = try await server(.omni).post("/v1/chat/completions", body, timeout: 120)
            let text = reply["choices"]?[0]?["message"]?["content"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
            return text?.isEmpty == false ? text : nil
        } catch { AppLog.write("liquid asr failed: \(error.localizedDescription)"); return nil }
    }

    /// Speaks `text` in `lang` with LFM3-Omni into a 24 kHz WAV; nil when it isn't installed or fails (the caller falls back).
    /// llama-tts loads the model for each sentence (a few seconds); the server can't speak yet.
    nonisolated static func synthesize(_ text: String, lang: String, voice: String = "female") async -> URL? {
        guard self.voice(for: lang), let bin = binary("llama-tts"), let f = files(.omni) else { return nil }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("myaiteacher-omni-\(UUID().uuidString.prefix(8)).wav")
        let args = ["-m", f.model.path, "-mm", f.projector.path, "--tts-lang", String(lang.prefix(2)).lowercased(), "--tts-voice", voice,
                    "-p", text, "-o", out.path]
        let r = await ProcessRunner.run(bin.path, args, cwd: bin.deletingLastPathComponent(), timeout: 120)
        guard r.exitCode == 0, FileManager.default.fileExists(atPath: out.path) else {
            AppLog.write("llama-tts failed (\(r.exitCode)): \(r.stderr.suffix(300))"); return nil
        }
        return out
    }
}

/// One llama.cpp server for one model: started on first use on a free port of 127.0.0.1, stopped after `idle` seconds
/// unused (the weights hold a gigabyte or two) and when the app quits.
actor LlamaServer {
    let kind: LiquidModels.Kind
    let idle: TimeInterval
    private var process: Process?
    private var base: URL?
    /// A fresh key per launch: the server answers only the app, not a web page posting to localhost.
    private(set) var key = ""
    private var starting: Task<URL, Error>?
    private var lastUse = Date()
    private var watcher: Task<Void, Never>?

    init(_ kind: LiquidModels.Kind, idle: TimeInterval = 600) { self.kind = kind; self.idle = idle }

    struct Failure: LocalizedError { var errorDescription: String? }

    /// The server's address, starting it (and waiting until it answers) when it isn't running.
    func url() async throws -> URL {
        lastUse = Date()
        if let base, process?.isRunning == true { return base }
        if let starting { return try await starting.value }
        let t = Task { try await launch() }
        starting = t
        defer { starting = nil }
        let u = try await t.value
        base = u
        watch()
        return u
    }
    func touch() { lastUse = Date() }
    var isRunning: Bool { process?.isRunning == true }

    func stop() {
        watcher?.cancel(); watcher = nil
        if let p = process, p.isRunning { p.terminate() }
        process = nil; base = nil
        LiquidModels.track(kind, pid: nil)
    }

    /// POSTs JSON to the running (or started) server.
    func post(_ path: String, _ body: JSON, timeout: TimeInterval) async throws -> JSON {
        let u = try await url()
        var req = URLRequest(url: u.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.httpBody = body.data
        req.timeoutInterval = timeout
        let (data, resp) = try await URLSession.shared.data(for: req)
        lastUse = Date()
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 200
        guard status < 400 else { throw HTTPError(status: status, body: String(decoding: data, as: UTF8.self)) }
        guard let j = JSON.parse(data) else { throw Failure(errorDescription: "The local \(kind.rawValue) server sent something that isn't JSON.") }
        return j
    }

    private func launch() async throws -> URL {
        guard let bin = LiquidModels.binary("llama-server") else { throw Failure(errorDescription: "The llama.cpp runtime isn't installed (Settings › On this Mac).") }
        guard let f = LiquidModels.files(kind) else { throw Failure(errorDescription: "\(kind == .omni ? "LFM3-Omni-2B" : "d1-Omni-2B") isn't installed (Settings › On this Mac).") }
        let port = try Self.freePort()
        key = UUID().uuidString
        var args = ["-m", f.model.path, "-mm", f.projector.path, "--host", "127.0.0.1", "--port", String(port), "--no-ui", "--api-key", key]
        switch kind {
        case .omni: args += ["--reasoning", "off", "-c", String(LiquidModels.contextWindow), "-np", "1", "--alias", LiquidModels.omniModel]
        // A question (its state and pictures or audio) is read in one batch.
        case .d1: args += ["-b", "8192", "-ub", "8192"]
        }
        let log = LiquidModels.root.appendingPathComponent("\(kind.rawValue).log")
        FileManager.default.createFile(atPath: log.path, contents: nil)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", LiquidModels.watchdog, "sh", String(ProcessInfo.processInfo.processIdentifier), bin.path] + args
        p.currentDirectoryURL = bin.deletingLastPathComponent()
        if let h = try? FileHandle(forWritingTo: log) { p.standardOutput = h; p.standardError = h }
        p.standardInput = FileHandle.nullDevice
        try p.run()
        process = p
        LiquidModels.track(kind, pid: p.processIdentifier)
        AppLog.write("liquid: \(kind.rawValue) server starting on port \(port)")
        let u = URL(string: "http://127.0.0.1:\(port)")!
        // Loading the weights takes a few seconds (more the first time, from disk).
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            try Task.checkCancellation()
            guard p.isRunning else {
                let tail = (try? String(contentsOf: log, encoding: .utf8)).map { String($0.suffix(400)) } ?? ""
                LiquidModels.track(kind, pid: nil); process = nil
                throw Failure(errorDescription: "The local \(kind.rawValue) server stopped while starting: \(tail)")
            }
            var req = URLRequest(url: u.appendingPathComponent("health")); req.timeoutInterval = 2
            if let (data, resp) = try? await URLSession.shared.data(for: req), (resp as? HTTPURLResponse)?.statusCode == 200,
               String(decoding: data, as: UTF8.self).contains("ok") {
                AppLog.write("liquid: \(kind.rawValue) server ready")
                return u
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        p.terminate(); process = nil; LiquidModels.track(kind, pid: nil)
        throw Failure(errorDescription: "The local \(kind.rawValue) server didn't start within 3 minutes.")
    }

    /// Stops the server once it has gone `idle` seconds unused.
    private func watch() {
        guard watcher == nil else { return }
        watcher = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard let self else { return }
                if await self.idleFor() > self.idle { await self.stop(); AppLog.write("liquid: \(self.kind.rawValue) server stopped (idle)"); return }
            }
        }
    }
    private func idleFor() -> TimeInterval { Date().timeIntervalSince(lastUse) }

    /// A port nothing listens on: bind to 0 and read what the kernel picked.
    static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure(errorDescription: "No socket for a local server.") }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let ok = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0 }
        }
        guard ok else { throw Failure(errorDescription: "No free port for a local server.") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }
}

/// LFM3-Omni as a lesson's model: starts its server when a request needs it, then speaks Chat Completions to it.
struct LocalModelClient: LLMClient {
    let config: ProviderConfig

    func stream(_ request: LLMRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        AsyncThrowingStream { cont in
            let task = Task {
                let server = LiquidModels.server(.omni)
                do {
                    var c = config
                    c.baseURL = try await server.url().appendingPathComponent("v1").absoluteString
                    for try await e in OpenAIClient(config: c, apiKey: await server.key).stream(request) { cont.yield(e) }
                    await server.touch()
                    cont.finish()
                } catch { await server.touch(); cont.finish(throwing: error) }
            }
            cont.onTermination = { _ in task.cancel() }
        }
    }
}

/// Fixed questions answered on this Mac by d1 (`LiquidModels`): calibrated probabilities instead of a model's prose. Every
/// caller has its own answer when d1 is off, missing, slow or failing — d1 only ever improves a decision.
enum LocalDecision {
    /// d1 is installed and the learner lets it decide (Settings › On this Mac).
    @MainActor static var available: Bool { LiquidModels.ready(.d1) && AppModel.shared.settings.value.localDecisions }

    /// Starts d1 (a few seconds to load) when a lesson opens, so it is ready by the first message: a decision that waits
    /// for a cold start would be over its time limit and fall back to the rule.
    @MainActor static func warm() {
        guard available else { return }
        Task.detached(priority: .utility) { _ = try? await LiquidModels.server(.d1).url() }
    }

    /// d1's answers (question name → answer), or nil when unavailable, failing or later than `timeout` (a server still
    /// starting keeps starting, for the next question).
    static func ask(state: String?, questions: JSON, files: [String] = [], timeout: TimeInterval) async -> JSON? {
        guard await MainActor.run(body: { available }) else { return nil }
        var fields: [String: JSON] = ["state": state.map(JSON.string) ?? .null, "questions": questions]
        if !files.isEmpty { fields["files"] = .array(files.map(JSON.string)) }
        let body = JSON.object(fields)
        return await withTaskGroup(of: JSON?.self) { g in
            g.addTask {
                do { return try await LiquidModels.server(.d1).post("/v1/systemone", body, timeout: timeout + 5)["answers"] }
                catch { AppLog.write("d1 failed: \(error.localizedDescription)"); return nil }
            }
            g.addTask { try? await Task.sleep(nanoseconds: UInt64(timeout * 1e9)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
    }

    /// What a learner's message asks for: "chat" (thanks, yes, go on), "quick" (a fact, a definition) or "teach"
    /// (an explanation, derivation, analysis, code, research), with d1's probability; nil when d1 can't say.
    static func requestKind(_ text: String, timeout: TimeInterval = 1.5) async -> (kind: String, p: Double)? {
        let q: JSON = ["kind": ["type": "choice", "instructions": "What does the learner's message ask the teacher for?", "criteria": [
            "chat": "A greeting, thanks, an acknowledgement, a yes or no, or a request to go on",
            "quick": "A quick fact, a definition or a one-line answer",
            "teach": "Teaching or explaining a topic, a derivation, proof or worked problem, an analysis, code, a plan or research",
        ]]]
        guard let a = await ask(state: String(text.prefix(4000)), questions: q, timeout: timeout)?["kind"],
              let kind = a["choice"]?.string else { return nil }
        return (kind, a["probabilities"]?[kind]?.double ?? a["confidence"]?.double ?? 0)
    }

    /// The probability that a learner's short answer is right (a content question, not a language one), or nil.
    static func answerIsRight(question: String, accepted: [String], given: String, timeout: TimeInterval = 8) async -> Double? {
        let state = "Question: \(question.prefix(1500))\nAccepted answers: \(accepted.joined(separator: " | ").prefix(1500))\nLearner's answer: \(given.prefix(1500))"
        let q: JSON = ["ok": ["type": "noul", "instructions": .string(judge)]]
        return await ask(state: state, questions: q, timeout: timeout)?["ok"]?["noul"]?.double
    }
    static let judge = "Is the learner's answer correct? Accept synonyms, equivalent wording, a different but equally right form, and small spelling mistakes; reject answers that are wrong, incomplete or mean something else."
}
