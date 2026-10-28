import Foundation
import AVFoundation
import Speech

/// What this Mac can do with speech, per language, measured rather than assumed (macOS 27 on the development Mac):
///   - Apple's newer on-device recogniser (SpeechAnalyzer: SpeechTranscriber; DictationTranscriber where it has no
///     model, e.g. Arabic and Russian) — its language models download on request (AssetInventory).
///   - The older SFSpeechRecognizer — on device only for English here; every other language goes to Apple's servers.
///   - Voices: compact ones by default; Enhanced and Premium ones are downloaded in System Settings.
/// The learner sees which engine heard them and which voice spoke, so nothing is claimed that isn't true.
enum SpeechEngines {
    // MARK: Apple's on-device recognisers (macOS 26+)

    enum ModelStatus: String, Sendable { case installed, downloadable, downloading, unsupported }

    /// The SpeechAnalyzer module for a language: SpeechTranscriber where it has the language, else DictationTranscriber.
    @available(macOS 26.0, *)
    static func module(for lang: String) async -> (any LocaleDependentSpeechModule, Locale, String)? {
        let wanted = Speech.recognizerLocale(lang) ?? Locale(identifier: lang)
        if let l = await SpeechTranscriber.supportedLocale(equivalentTo: wanted) {
            return (SpeechTranscriber(locale: l, transcriptionOptions: [], reportingOptions: [.volatileResults], attributeOptions: []), l, "SpeechTranscriber")
        }
        if let l = await DictationTranscriber.supportedLocale(equivalentTo: wanted) {
            return (DictationTranscriber(locale: l, preset: .progressiveShortDictation), l, "DictationTranscriber")
        }
        return nil
    }

    static func appleModelStatus(_ lang: String?) async -> ModelStatus {
        guard let lang else { return .unsupported }
        if #available(macOS 26.0, *) {
            guard let (m, _, _) = await module(for: lang) else { return .unsupported }
            switch await AssetInventory.status(forModules: [m]) {
            case .installed: return .installed
            case .downloading: return .downloading
            case .supported: return .downloadable
            default: return .unsupported
            }
        }
        return .unsupported
    }

    /// Downloads Apple's on-device recognition model for a language (Apple's own asset service), reporting progress.
    static func installAppleModel(_ lang: String, progress: @escaping @Sendable (Double) -> Void) async throws {
        guard #available(macOS 26.0, *), let (m, _, _) = await module(for: lang) else { throw OpenSpeech.Failure(errorDescription: "No on-device recogniser for this language.") }
        guard let req = try await AssetInventory.assetInstallationRequest(supporting: [m]) else { return }   // already installed
        let watcher = Task {
            while !Task.isCancelled { progress(req.progress.fractionCompleted); try? await Task.sleep(nanoseconds: 300_000_000) }
        }
        defer { watcher.cancel() }
        try await req.downloadAndInstall()
        progress(1)
    }

    // MARK: Voices

    struct VoiceInfo: Sendable { var name: String; var quality: String; var language: String }
    /// The best installed voice for a language and its quality ("compact", "enhanced", "premium").
    static func bestVoice(_ lang: String) -> VoiceInfo? {
        guard let v = Speech.bestVoice(lang), v.language.lowercased().hasPrefix(lang.lowercased()) else { return nil }
        return VoiceInfo(name: v.name, quality: v.quality == .premium ? "premium" : v.quality == .enhanced ? "enhanced" : "compact", language: v.language)
    }

    /// The learner's choice of output engine for a language: Apple's voice when it is Enhanced or Premium (or the learner
    /// chose Apple), the open-source voice when installed and better, else Apple's compact voice.
    static func useOpenVoice(_ lang: String?, preference: String) -> Bool { localVoice(lang, preference: preference) == .supertonic }

    enum LocalVoice: Equatable { case supertonic, omni }
    /// The engine on this Mac that speaks `lang` instead of the Mac's own voice; nil: the Mac's voice. "auto" keeps an
    /// Enhanced or Premium Mac voice and otherwise takes Supertonic, then LFM3-Omni (which also speaks Chinese and Hebrew).
    static func localVoice(_ lang: String?, preference: String) -> LocalVoice? {
        guard let lang, preference != "apple" else { return nil }
        let supertonic = OpenSpeech.voice(for: lang), omni = LiquidModels.voice(for: lang)
        switch preference {
        case "open": return supertonic ? .supertonic : nil
        case "omni": return omni ? .omni : nil
        default:
            guard bestVoice(lang).map({ $0.quality == "compact" }) ?? true else { return nil }
            return supertonic ? .supertonic : omni ? .omni : nil
        }
    }
}

// MARK: - SpeechAnalyzer stream

/// One dictation through SpeechAnalyzer: microphone buffers in (converted to the analyzer's format), text out — the
/// finished part plus the volatile tail, as the learner speaks.
@available(macOS 26.0, *)
final class AnalyzerStream: @unchecked Sendable {
    private let analyzer: SpeechAnalyzer
    private let builder: AsyncStream<AnalyzerInput>.Continuation
    private let input: AsyncStream<AnalyzerInput>
    private let format: AVAudioFormat
    private var converter: AVAudioConverter?
    private var results: Task<Void, Never>?
    private var finalText = ""
    private let lock = NSLock()

    init?(module: any LocaleDependentSpeechModule) async {
        guard let f = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [module]) else { return nil }
        format = f
        analyzer = SpeechAnalyzer(modules: [module])
        (input, builder) = AsyncStream<AnalyzerInput>.makeStream()
    }

    /// Starts analysing; `onText(text, final)` gets the transcript so far.
    func start(module: any LocaleDependentSpeechModule, onText: @escaping @Sendable (String, Bool) -> Void) async throws {
        try await analyzer.start(inputSequence: input)
        results = Task { [weak self] in
            do {
                if let t = module as? SpeechTranscriber {
                    for try await r in t.results { self?.take(String(r.text.characters), final: r.isFinal, onText) }
                } else if let d = module as? DictationTranscriber {
                    for try await r in d.results { self?.take(String(r.text.characters), final: r.isFinal, onText) }
                }
            } catch { AppLog.write("speech analyzer: \(error.localizedDescription)") }
        }
    }
    private func take(_ text: String, final: Bool, _ onText: @Sendable (String, Bool) -> Void) {
        lock.lock()
        let shown: String
        if final { finalText += text; shown = finalText } else { shown = finalText + text }
        lock.unlock()
        onText(shown.trimmingCharacters(in: .whitespaces), false)
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return finalText.trimmingCharacters(in: .whitespaces) }

    func append(_ buffer: AVAudioPCMBuffer) {
        if buffer.format == format { builder.yield(AnalyzerInput(buffer: buffer)); return }
        if converter == nil || converter?.inputFormat != buffer.format { converter = AVAudioConverter(from: buffer.format, to: format) }
        guard let converter else { return }
        let ratio = format.sampleRate / buffer.format.sampleRate
        guard let out = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(Double(buffer.frameLength) * ratio + 32)) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true; status.pointee = .haveData; return buffer
        }
        if err == nil, out.frameLength > 0 { builder.yield(AnalyzerInput(buffer: out)) }
    }

    /// Ends the input and waits for the final transcript.
    func finish() async -> String {
        builder.finish()
        try? await analyzer.finalizeAndFinishThroughEndOfInput()
        _ = await results?.value
        return text
    }
    func cancel() async { builder.finish(); await analyzer.cancelAndFinishNow(); results?.cancel() }
}

// MARK: - Pitch

/// Pitch tracks for the speaking card: the learner's voice against the synthetic voice saying the target, as semitones
/// around each speaker's own median (so a low and a high voice compare), time-normalised over the voiced part. This
/// compares the melody — rises, falls, Mandarin tones, a Japanese accent drop — and nothing else.
enum Pitch {
    /// F0 per 10 ms frame (Hz) by the YIN method between 70 and 450 Hz; nil for unvoiced or quiet frames.
    static func track(_ samples: [Float], sampleRate: Double, workRate: Double = 8_000, threshold: Float = 0.15) -> [Double?] {
        // Work at ~8 kHz: enough for voices up to 450 Hz, and four times less work than 16 kHz (tones use 16 kHz).
        let factor = max(1, Int((sampleRate / workRate).rounded()))
        let sr = sampleRate / Double(factor)
        var x = [Float](); x.reserveCapacity(samples.count / factor + 1)
        var i = 0
        while i + factor <= samples.count { var s: Float = 0; for k in 0..<factor { s += samples[i + k] }; x.append(s / Float(factor)); i += factor }
        let hop = Int(sr * 0.01), win = Int(sr * 0.04)
        let minLag = Int(sr / 450), maxLag = Int(sr / 70)
        guard x.count > win + maxLag, hop > 0 else { return [] }
        var energies: [Float] = []
        var frames: [Int] = []
        var p = 0
        while p + win + maxLag < x.count { frames.append(p); var e: Float = 0; for k in p..<(p + win) { e += x[k] * x[k] }; energies.append(sqrtf(e / Float(win))); p += hop }
        let loud = (energies.max() ?? 0) * 0.08
        var out: [Double?] = []
        var d = [Float](repeating: 0, count: maxLag + 1)
        for (fi, start) in frames.enumerated() {
            guard energies[fi] > loud else { out.append(nil); continue }
            for tau in 1...maxLag {
                var s: Float = 0
                for k in start..<(start + win) { let diff = x[k] - x[k + tau]; s += diff * diff }
                d[tau] = s
            }
            // Cumulative mean normalised difference; first dip under the threshold.
            var running: Float = 0, best: Int?
            var cmnd = [Float](repeating: 1, count: maxLag + 1)
            for tau in 1...maxLag { running += d[tau]; cmnd[tau] = running > 0 ? d[tau] * Float(tau) / running : 1 }
            var tau = minLag
            while tau < maxLag {
                if cmnd[tau] < threshold { while tau + 1 < maxLag && cmnd[tau + 1] < cmnd[tau] { tau += 1 }; best = tau; break }
                tau += 1
            }
            // The dip between samples (parabolic interpolation): whole-sample lags step pitch in ~0.4-semitone jumps.
            out.append(best.map { t in
                guard t > 1, t < maxLag else { return sr / Double(t) }
                let a = Double(cmnd[t - 1]), b = Double(cmnd[t]), c = Double(cmnd[t + 1]), den = a - 2 * b + c
                let shift = den != 0 ? max(-0.5, min(0.5, (a - c) / (2 * den))) : 0
                return sr / (Double(t) + shift)
            })
        }
        return out
    }

    /// Semitones around the median, voiced span only, median-smoothed, resampled to `points` (nil where unvoiced).
    static func contour(_ f0: [Double?], points: Int = 80) -> [Double?] {
        guard let first = f0.firstIndex(where: { $0 != nil }), let last = f0.lastIndex(where: { $0 != nil }), last > first + 3 else { return [] }
        let span = Array(f0[first...last])
        let voiced = span.compactMap { $0 }.sorted()
        let median = voiced[voiced.count / 2]
        var st: [Double?] = span.map { $0.map { 12 * log2($0 / median) } }
        // Octave jumps and stray frames: a 5-frame median.
        st = st.indices.map { i in
            guard st[i] != nil else { return nil }
            let w = st[max(0, i - 2)...min(st.count - 1, i + 2)].compactMap { $0 }.sorted()
            return w[w.count / 2]
        }
        return (0..<points).map { k in
            let idx = Int((Double(k) / Double(points - 1) * Double(st.count - 1)).rounded())
            return st[idx]
        }
    }

    /// How alike two contours are in shape: the correlation where both are voiced, as 0…1 (nil: too little to compare).
    static func similarity(_ a: [Double?], _ b: [Double?]) -> Double? {
        let pairs = zip(a, b).compactMap { x, y -> (Double, Double)? in guard let x, let y else { return nil }; return (x, y) }
        guard pairs.count >= 12 else { return nil }
        let mx = pairs.map(\.0).reduce(0, +) / Double(pairs.count), my = pairs.map(\.1).reduce(0, +) / Double(pairs.count)
        var sxy = 0.0, sxx = 0.0, syy = 0.0
        for (x, y) in pairs { sxy += (x - mx) * (y - my); sxx += (x - mx) * (x - mx); syy += (y - my) * (y - my) }
        guard sxx > 1e-9, syy > 1e-9 else { return nil }
        return max(0, sxy / sqrt(sxx * syy))
    }

    static func json(learner: [Double?], target: [Double?]) -> JSON? {
        guard !learner.isEmpty, !target.isEmpty else { return nil }
        let r = { (v: [Double?]) -> JSON in .array(v.map { $0.map { .number(($0 * 10).rounded() / 10) } ?? .null }) }
        var j: [String: JSON] = ["learner": r(learner), "target": r(target)]
        if let s = similarity(learner, target) { j["similarity"] = .number((s * 100).rounded() / 100) }
        return .object(j)
    }
}
