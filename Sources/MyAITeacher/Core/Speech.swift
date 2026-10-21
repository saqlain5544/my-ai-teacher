import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Read-aloud (AVSpeechSynthesizer) and dictation (on-device Speech framework).
@MainActor
final class Speech: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var isSpeaking = false
    @Published private(set) var isListening = false
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
    func speak(_ markdown: String, language: String? = nil, voice: String?, rate: Double) {
        stop()
        let text = Self.speakable(markdown)
        let baseVoice = voice.flatMap(AVSpeechSynthesisVoice.init(identifier:))
        let baseLang = baseVoice?.language ?? Locale.preferredLanguages.first ?? "en-US"
        let segments: [(String, String)] = language.map { [(text, $0)] } ?? Self.segments(text, base: String(baseLang.prefix(2)))
        for (chunk, lang) in segments {
            let u = AVSpeechUtterance(string: chunk)
            if lang == String(baseLang.prefix(2)), let baseVoice { u.voice = baseVoice } else { u.voice = Self.bestVoice(lang) }
            u.rate = Float(rate) * AVSpeechUtteranceMaximumSpeechRate * 0.9
            u.postUtteranceDelay = 0.05
            synth.speak(u)
        }
        isSpeaking = !segments.isEmpty
    }

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
        isSpeaking = false
    }

    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) {
        Task { @MainActor in self.isSpeaking = self.synth.isSpeaking }
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

    func toggleDictation(onText: @escaping (String) -> Void) {
        if isListening { stopListening(); return }
        SFSpeechRecognizer.requestAuthorization { status in
            Task { @MainActor in
                guard status == .authorized else { return }
                self.startListening(onText: onText)
            }
        }
    }

    private func startListening(onText: @escaping (String) -> Void) {
        guard let recognizer = SFSpeechRecognizer(locale: Locale.current) ?? SFSpeechRecognizer(locale: Locale(identifier: "en-US")),
              recognizer.isAvailable else { return }
        let engine = AVAudioEngine()
        let req = SFSpeechAudioBufferRecognitionRequest()
        req.shouldReportPartialResults = true
        if recognizer.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { buf, _ in req.append(buf) }
        do { engine.prepare(); try engine.start() } catch { return }
        self.engine = engine
        self.request = req
        isListening = true
        task = recognizer.recognitionTask(with: req) { result, error in
            Task { @MainActor in
                if let r = result { onText(r.bestTranscription.formattedString) }
                if error != nil || (result?.isFinal ?? false) { self.stopListening() }
            }
        }
    }

    func stopListening() {
        engine?.stop()
        engine?.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.cancel()
        engine = nil; request = nil; task = nil
        isListening = false
    }
}
