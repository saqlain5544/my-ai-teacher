import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Read-aloud (AVSpeechSynthesizer) and dictation (on-device Speech framework).
@MainActor
final class Speech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate, AVAudioPlayerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isListening = false
    /// The language being dictated (nil: the Mac's).
    @Published private(set) var listeningLanguage: String?
    @Published var transcript = ""
    private let synth = AVSpeechSynthesizer()
    private var engine: AVAudioEngine?
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?

    override init() {
        super.init()
        synth.delegate = self
    }

    /// Speaks mixed-language text: one utterance per language run, each with the best installed voice for it.
    /// `language` forces a single language (click-to-hear on a foreign word).
    func speak(_ markdown: String, language: String? = nil, voice: String?, rate: Double, onFinish: (@MainActor () -> Void)? = nil) {
        stop()
        finish = nil
        let text = Self.speakable(markdown)
        // One language (a word, a sentence, a passage in the target language): the open-source voice when it is the
        // better one for it (the Mac has only a compact voice), rendered on device and played; the Mac's voice otherwise.
        if let lang = language.map({ String($0.prefix(2)).lowercased() }), SpeechEngines.useOpenVoice(lang, preference: AppModel.shared.settings.value.speechOutput) {
            let ticket = UUID(); openTicket = ticket
            isSpeaking = true
            Task {
                let wav = await OpenSpeech.synthesize(text, lang: lang, speed: rate / 0.5)
                await MainActor.run {
                    guard self.openTicket == ticket else { return }
                    if let wav, let p = try? AVAudioPlayer(contentsOf: wav) {
                        self.player = p; self.playerFinish = onFinish; self.playerFile = wav
                        p.delegate = self; p.play()
                    } else { self.openTicket = nil; self.speakApple(text, language: language, voice: voice, rate: rate, onFinish: onFinish) }
                }
            }
            return
        }
        speakApple(text, language: language, voice: voice, rate: rate, onFinish: onFinish)
    }
    private var openTicket: UUID?
    private var player: AVAudioPlayer?
    private var playerFile: URL?
    private var playerFinish: (@MainActor () -> Void)?
    nonisolated func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully: Bool) {
        Task { @MainActor in
            guard p === self.player else { return }
            self.endPlayer(); self.isSpeaking = self.synth.isSpeaking
            let f = self.playerFinish; self.playerFinish = nil; f?()
        }
    }
    private func endPlayer() {
        player?.stop(); player = nil; openTicket = nil
        if let f = playerFile { try? FileManager.default.removeItem(at: f); playerFile = nil }
    }

    private func speakApple(_ text: String, language: String?, voice: String?, rate: Double, onFinish: (@MainActor () -> Void)?) {
        let baseVoice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        let baseLang = baseVoice?.language ?? Locale.preferredLanguages.first ?? "en-US"
        let segments: [(String, String)] = language.map { [(text, $0)] } ?? Self.segments(text, base: String(baseLang.prefix(2)))
        for (chunk, lang) in segments {
            let u = AVSpeechUtterance(string: chunk)
            if lang == String(baseLang.prefix(2)), let baseVoice { u.voice = baseVoice } else { u.voice = Self.bestVoice(lang) }
            u.rate = Float(rate) * AVSpeechUtteranceMaximumSpeechRate * 0.9
            u.postUtteranceDelay = 0.05
            synth.speak(u)
            last = u
        }
        isSpeaking = !segments.isEmpty
        if segments.isEmpty { onFinish?() } else { finish = onFinish }
    }
    /// The last utterance queued and what to do once it has been spoken (a reading's next sentence).
    private var last: AVSpeechUtterance?
    private var finish: (@MainActor () -> Void)?

    nonisolated static func bestVoice(_ lang: String) -> AVSpeechSynthesisVoice? {
        let all = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.lowercased().hasPrefix(lang.lowercased()) }
        let preferredRegion = Locale.current.region?.identifier ?? ""
        return all.sorted { a, b in
            if a.quality != b.quality { return a.quality.rawValue > b.quality.rawValue }
            return a.language.hasSuffix(preferredRegion) && !b.language.hasSuffix(preferredRegion)
        }.first ?? AVSpeechSynthesisVoice(language: lang)
    }

    /// Splits text into (chunk, language) runs: by script first, then by sentence language for Latin text.
    nonisolated static func segments(_ text: String, base: String) -> [(String, String)] {
        var out: [(String, String)] = []
        func push(_ s: String, _ l: String) {
            let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard t.rangeOfCharacter(from: .letters) != nil || t.rangeOfCharacter(from: .decimalDigits) != nil else { return }
            if let last = out.last, last.1 == l { out[out.count - 1].0 += " " + t } else { out.append((t, l)) }
        }
        let rec = NLLanguageRecognizer()
        for run in ScriptRuns.runs(text) {
            if let l = run.script.defaultLanguage {
                var lang = l
                if run.script == .arabic {
                    if run.text.range(of: "[پچژگ]", options: .regularExpression) != nil { lang = "fa" }
                    if run.text.range(of: "[ٹڈڑںے]", options: .regularExpression) != nil { lang = "ur" }
                }
                push(run.text, lang); continue
            }
            // Latin/other: detect per sentence; fall back to the base language for short text.
            let tok = NLTokenizer(unit: .sentence)
            tok.string = run.text
            tok.enumerateTokens(in: run.text.startIndex..<run.text.endIndex) { r, _ in
                let s = String(run.text[r])
                var lang = base
                if s.count >= 15 {
                    rec.reset(); rec.processString(s)
                    if let (l, p) = rec.languageHypotheses(withMaximum: 1).first, p >= 0.8 { lang = l.rawValue }
                }
                push(s, lang)
                return true
            }
        }
        return out
    }

    func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
        if player != nil || openTicket != nil { endPlayer(); playerFinish = nil }
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        nonisolated(unsafe) let done = u   // the utterance itself, not its address (a freed one's can be reused)
        Task { @MainActor in
            self.isSpeaking = self.synth.isSpeaking
            if let l = self.last, l === done { self.last = nil; let f = self.finish; self.finish = nil; f?() }
        }
    }

    /// Strips Markdown/LaTeX/code so speech sounds natural.
    nonisolated static func speakable(_ s: String) -> String {
        var t = s.replacingOccurrences(of: "<rt>[\\s\\S]*?</rt>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression)
        t = t.replacingOccurrences(of: "```[\\s\\S]*?```", with: " (code example) ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\$\\$[\\s\\S]*?\\$\\$", with: " (equation) ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\$([^$\\n]{1,40})\\$", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\\\[a-zA-Z]+", with: " ", options: .regularExpression)
        t = t.replacingOccurrences(of: "\\[([^\\]]+)\\]\\([^)]+\\)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "[#*_`>|{}]", with: "", options: .regularExpression)
        return t
    }

    // MARK: Dictation

    func toggleDictation(language: String? = nil, onText: @escaping (String) -> Void) {
        if isListening { stopListening(); return }
        dictate(language: language) { text, _, _ in onText(text) }
    }

    /// Which recogniser heard the learner, said as it is: on this Mac or on Apple's servers, and which model.
    @Published private(set) var engineName = ""

    /// Listens in `language` (an ISO code; nil for the Mac's language) and reports partial results, then the final one
    /// with `info`: the engine that heard it and, with a `target` sentence, the pitch of the learner's voice against
    /// the synthetic voice saying it. The engine is the best this Mac has for the language: Apple's on-device
    /// SpeechAnalyzer when its model is installed, else Whisper when the learner installed it (and the Mac would
    /// otherwise send the audio to Apple), else SFSpeechRecognizer (on device for English, Apple's servers otherwise).
    func dictate(language: String?, target: String? = nil, onText: @escaping (String, Bool, JSON?) -> Void) {
        if isListening { stopListening() }
        generation += 1
        let gen = generation
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { onText("", true, ["engine": "Speech recognition isn't allowed: System Settings › Privacy & Security › Speech Recognition"]); return }
                await self.startListening(language: language, target: target, gen: gen, onText: onText)
            }
        }
    }

    /// The best recogniser locale for a language code ("ja" → ja-JP), or nil when the Mac has none for it.
    nonisolated static func recognizerLocale(_ language: String?) -> Locale? {
        guard let l = language?.lowercased(), !l.isEmpty else { return nil }
        let all = supportedLocales
        if let exact = all.first(where: { $0.identifier.lowercased().replacingOccurrences(of: "_", with: "-") == l }) { return exact }
        let base = String(l.split(whereSeparator: { $0 == "-" || $0 == "_" }).first ?? Substring(l))
        let region = Locale.current.region?.identifier ?? ""
        let candidates = all.filter { ($0.language.languageCode?.identifier ?? "") == base }
        return candidates.first { $0.region?.identifier == region } ?? candidates.sorted { $0.identifier < $1.identifier }.first
    }

    /// The Mac's recogniser locales never change while the app runs (the composer asks on every render).
    nonisolated static let supportedLocales = SFSpeechRecognizer.supportedLocales()

    private enum Engine { case analyzer, whisper, sf(onDevice: Bool) }
    private var analyzerStream: AnyObject?
    /// The microphone's samples (mono) of the current take, for Whisper and the pitch comparison: at most a minute. Owned
    /// by the take (the tap writes it on the audio thread), so a late buffer never lands in the next take.
    final class Samples: @unchecked Sendable {
        private let lock = NSLock()
        private var data: [Float] = []
        let rate: Double
        init(rate: Double) { self.rate = rate }
        func append(_ p: UnsafeBufferPointer<Float>) { lock.lock(); if data.count < Int(rate * 60) { data.append(contentsOf: p) }; lock.unlock() }
        var all: [Float] { lock.lock(); defer { lock.unlock() }; return data }
    }
    private var samples = Samples(rate: 16_000)
    private var target: String?
    private var currentEngine: Engine = .sf(onDevice: false)
    private var lastText = ""
    private var onFinal: ((String) -> Void)?
    /// Each take's number: a Stop, or a new take, makes everything still on its way from an older one (an await that
    /// returns late, a recogniser callback) a no-op.
    private var generation = 0

    private func chooseEngine(_ language: String?) async -> Engine {
        let pref = AppModel.shared.settings.value.speechInput
        let sfLocale = Self.recognizerLocale(language)
        let sfOnDevice = sfLocale.flatMap(SFSpeechRecognizer.init(locale:))?.supportsOnDeviceRecognition ?? false
        if pref == "whisper", OpenSpeech.recognizer(for: language) { return .whisper }
        if pref != "online", let language, await SpeechEngines.appleModelStatus(language) == .installed { return .analyzer }
        if pref != "online", !sfOnDevice, OpenSpeech.recognizer(for: language) { return .whisper }
        return .sf(onDevice: sfOnDevice)
    }

    private func startListening(language: String?, target: String?, gen: Int, onText: @escaping (String, Bool, JSON?) -> Void) async {
        guard gen == generation else { return }
        lastText = ""; self.target = target
        listeningLanguage = language
        isListening = true   // before the awaits: a Stop pressed while the engine is chosen is heard
        let lang = language ?? String(Locale.preferredLanguages.first?.prefix(2) ?? "en")
        whisperLanguage = lang
        let chosen = await chooseEngine(language)
        guard gen == generation else { return }
        currentEngine = chosen

        var append: ((AVAudioPCMBuffer) -> Void)?
        switch currentEngine {
        case .analyzer:
            if #available(macOS 26.0, *), let (module, _, kind) = await SpeechEngines.module(for: lang), let s = await AnalyzerStream(module: module) {
                guard gen == generation else { await s.cancel(); return }
                do {
                    try await s.start(module: module) { text, _ in Task { @MainActor in guard gen == self.generation else { return }; self.lastText = text; onText(text, false, nil) } }
                    guard gen == generation else { await s.cancel(); return }
                    analyzerStream = s
                    append = { s.append($0) }
                    engineName = "On this Mac (Apple \(kind))"
                } catch { currentEngine = .sf(onDevice: false) }
            } else { currentEngine = .sf(onDevice: false) }
            guard gen == generation else { return }
        case .whisper:
            engineName = "On this Mac (Whisper large-v3-turbo)"
            onText("", false, ["engine": .string(engineName + " — transcribes when you stop")])
        case .sf: break
        }
        if case .sf = currentEngine {
            guard let recognizer = Self.recognizerLocale(language).flatMap(SFSpeechRecognizer.init(locale:)) ?? SFSpeechRecognizer(locale: Locale.current),
                  recognizer.isAvailable else {
                isListening = false; listeningLanguage = nil; onText("", true, ["engine": "No speech recogniser for this language on this Mac"]); return
            }
            let req = SFSpeechAudioBufferRecognitionRequest()
            req.shouldReportPartialResults = true
            if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
            engineName = recognizer.supportsOnDeviceRecognition ? "On this Mac (Apple speech recognition)" : "Apple speech recognition — online (the audio goes to Apple)"
            request = req
            append = { req.append($0) }
            task = recognizer.recognitionTask(with: req) { result, error in
                Task { @MainActor in
                    guard gen == self.generation else { return }   // an older take's last callback (its cancel error)
                    if let r = result { self.lastText = r.bestTranscription.formattedString; onText(self.lastText, false, nil) }
                    if error != nil || (result?.isFinal ?? false) { self.stopListening() }
                }
            }
        }
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        let take = Samples(rate: format.sampleRate)
        samples = take
        onFinal = { [weak self] text in
            guard let self else { return }
            let target = self.target, name = self.engineName
            // The transcript first; the pitch (a second or two of work, and a synthetic voice that may not answer)
            // follows as an update of the same final result.
            onText(text, true, ["engine": .string(name)])
            guard let target, !target.isEmpty else { return }
            let all = take.all
            guard all.count > Int(take.rate * 0.3) else { return }
            Task {
                guard let p = await Self.pitchInfo(samples: all, rate: take.rate, target: target, lang: lang) else { return }
                await MainActor.run { onText(text, true, ["engine": .string(name), "pitch": p]) }
            }
        }
        let feed = append
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in
            feed?(buf)
            if let ch = buf.floatChannelData?[0] { take.append(UnsafeBufferPointer(start: ch, count: Int(buf.frameLength))) }
        }
        // No microphone, or one held by another app: the caller hears a final empty result instead of waiting forever.
        do { engine.prepare(); try engine.start() } catch {
            input.removeTap(onBus: 0)
            isListening = false; listeningLanguage = nil; onFinal = nil; task?.cancel(); task = nil; request = nil
            if #available(macOS 26.0, *), let s = analyzerStream as? AnalyzerStream { analyzerStream = nil; Task { await s.cancel() } }
            onText("", true, ["engine": .string("The microphone couldn't start (\(error.localizedDescription))")]); return
        }
        self.engine = engine
    }

    func stopListening() {
        guard isListening || engine != nil else { return }
        generation += 1   // whatever the current take still has on its way is dropped
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        engine = nil
        let wasListening = isListening
        isListening = false
        listeningLanguage = nil
        let done = onFinal; onFinal = nil
        let lang = whisperLanguage
        switch currentEngine {
        case .analyzer:
            if #available(macOS 26.0, *), let s = analyzerStream as? AnalyzerStream {
                analyzerStream = nil
                let partial = lastText
                Task { let text = await s.finish(); await MainActor.run { if wasListening { done?(text.isEmpty ? partial : text) } } }
                return
            }
        case .whisper:
            let all = samples.all, rate = samples.rate
            Task {
                var heard = ""
                if let wav = Self.writeWAV(all, rate: rate) { heard = await OpenSpeech.transcribe(wav, lang: lang) ?? ""; try? FileManager.default.removeItem(at: wav) }
                await MainActor.run { if wasListening { done?(heard) } }
            }
            return
        case .sf:
            request?.endAudio()
            task?.cancel()
        }
        request = nil; task = nil
        if wasListening { done?(lastText) }
    }
    private var whisperLanguage: String?

    /// The learner's recording as a 16 kHz mono 16-bit WAV (what Whisper reads).
    nonisolated static func writeWAV(_ samples: [Float], rate: Double) -> URL? {
        guard !samples.isEmpty, let src = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false),
              let dst = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 16_000, channels: 1, interleaved: true),
              let inBuf = AVAudioPCMBuffer(pcmFormat: src, frameCapacity: AVAudioFrameCount(samples.count)),
              let conv = AVAudioConverter(from: src, to: dst),
              let outBuf = AVAudioPCMBuffer(pcmFormat: dst, frameCapacity: AVAudioFrameCount(Double(samples.count) * 16_000 / rate + 64)) else { return nil }
        inBuf.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { p in inBuf.floatChannelData![0].update(from: p.baseAddress!, count: samples.count) }
        var fed = false
        var err: NSError?
        conv.convert(to: outBuf, error: &err) { _, st in if fed { st.pointee = .endOfStream; return nil }; fed = true; st.pointee = .haveData; return inBuf }
        guard err == nil else { return nil }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("myaiteacher-rec-\(UUID().uuidString.prefix(8)).wav")
        guard let f = try? AVAudioFile(forWriting: url, settings: dst.settings, commonFormat: .pcmFormatInt16, interleaved: true) else { return nil }
        do { try f.write(from: outBuf) } catch { return nil }
        return url
    }

    // MARK: Pitch against the synthetic voice

    /// The learner's pitch contour and the synthetic voice's for the same sentence (rendered offline, not played).
    nonisolated static func pitchInfo(samples: [Float], rate: Double, target: String, lang: String) async -> JSON? {
        let learner = Pitch.contour(Pitch.track(samples, sampleRate: rate))
        // The synthetic voice is rendered offline; a voice that never answers must not hold the result back.
        guard !learner.isEmpty else { return nil }
        let rendered: ([Float], Double)? = try? await withDeadline(seconds: 8, { await synthesize(target, lang: lang) })
        guard let (ref, refRate) = rendered else { return nil }
        let reference = Pitch.contour(Pitch.track(ref, sampleRate: refRate))
        return Pitch.json(learner: learner, target: reference)
    }

    /// The target sentence spoken by the best installed voice into memory (AVSpeechSynthesizer.write), as mono samples.
    nonisolated static func synthesize(_ text: String, lang: String) async -> ([Float], Double)? {
        await withCheckedContinuation { (c: CheckedContinuation<([Float], Double)?, Never>) in
            DispatchQueue.main.async {
                let synth = AVSpeechSynthesizer()
                let u = AVSpeechUtterance(string: text)
                u.voice = bestVoice(lang)
                u.rate = AVSpeechUtteranceDefaultSpeechRate
                var samples: [Float] = [], rate = 22_050.0, done = false
                Self.keepAlive.insert(synth)
                synth.write(u) { buffer in
                    guard !done else { return }
                    guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                        done = true; DispatchQueue.main.async { Self.keepAlive.remove(synth) }
                        c.resume(returning: samples.isEmpty ? nil : (samples, rate)); return
                    }
                    rate = pcm.format.sampleRate
                    if let f = pcm.floatChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: f, count: Int(pcm.frameLength))) }
                    else if let i = pcm.int16ChannelData?[0] { samples.append(contentsOf: UnsafeBufferPointer(start: i, count: Int(pcm.frameLength)).map { Float($0) / 32768 }) }
                }
            }
        }
    }
    @MainActor static var keepAlive = Set<AVSpeechSynthesizer>()
}
