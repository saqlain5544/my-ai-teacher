import Foundation
import AVFoundation
import Speech
import NaturalLanguage

/// Real audio for listening: a podcast, a news clip, a film scene the learner brings. The audio (or a video's sound
/// track) is decoded on this Mac, cut into stretches of speech at its pauses, and each stretch transcribed — by Whisper
/// when it is installed (on this Mac), else by Apple's recogniser (on device for English, online otherwise, said as
/// such). Each stretch keeps its start and end time; its sentences share the stretch's time by length (said as
/// approximate on the player). The transcript is stored with the lesson (in the learner's message) and the file in
/// the lesson's .teacher/attachments/media folder; the player plays it sentence by sentence.
enum MediaTranscript {
    static let audioExtensions: Set<String> = ["mp3", "m4a", "aac", "wav", "aiff", "aif", "caf", "flac", "mp4", "m4v", "mov", "ogg", "opus"]

    struct Segment: Equatable, Sendable { var start: Double; var end: Double; var text: String }
    struct Transcript: Sendable {
        var segments: [Segment]
        var duration: Double
        var engine: String
        var language: String?
    }

    struct Failure: LocalizedError { var errorDescription: String? }

    /// The file's sound as 16 kHz mono samples (a video's audio track too), at most `maxSeconds`.
    static func samples(_ url: URL, maxSeconds: Double = 3600) async throws -> [Float] {
        let asset = AVURLAsset(url: url)
        guard let track = try await asset.loadTracks(withMediaType: .audio).first else { throw Failure(errorDescription: "The file has no sound track.") }
        let reader = try AVAssetReader(asset: asset)
        let out = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVSampleRateKey: 16_000, AVNumberOfChannelsKey: 1,
            AVLinearPCMBitDepthKey: 32, AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false, AVLinearPCMIsBigEndianKey: false,
        ])
        reader.add(out)
        guard reader.startReading() else { throw Failure(errorDescription: reader.error?.localizedDescription ?? "The file couldn't be read.") }
        var all: [Float] = []
        let cap = Int(16_000 * maxSeconds)
        while let buf = out.copyNextSampleBuffer(), let block = CMSampleBufferGetDataBuffer(buf) {
            let n = CMBlockBufferGetDataLength(block) / MemoryLayout<Float>.size
            var chunk = [Float](repeating: 0, count: n)
            _ = chunk.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: n * MemoryLayout<Float>.size, destination: $0.baseAddress!) }
            all.append(contentsOf: chunk)
            if all.count >= cap { reader.cancelReading(); break }
        }
        return all
    }

    /// Stretches of speech (seconds), cut at pauses: 30 ms frames against the recording's own noise floor; pauses of at
    /// least 0.3 s split, stretches are joined up to `target` seconds and cut hard past `maxLen` (Whisper reads 30 s).
    static func chunks(_ s: [Float], rate: Double = 16_000, target: Double = 18, maxLen: Double = 26) -> [(Double, Double)] {
        let frame = max(1, Int(rate * 0.03))
        let rms = Loudness.frames(s, window: frame, hop: frame)
        guard !rms.isEmpty else { return [] }
        let sorted = rms.sorted()
        let floor = sorted[sorted.count / 10], peak = sorted[sorted.count * 98 / 100]
        let threshold = max(0.002, min(floor * 3, peak * 0.25))
        let fs = Double(frame) / rate
        // Voiced regions with short pauses (< 0.3 s) bridged.
        var regions: [(Int, Int)] = []
        var start: Int? = nil, quiet = 0
        let bridge = Int(0.3 / fs)
        for (k, v) in rms.enumerated() {
            if v > threshold { if start == nil { start = k }; quiet = 0 }
            else if let st = start { quiet += 1; if quiet > bridge { regions.append((st, k - quiet)); start = nil; quiet = 0 } }
        }
        if let st = start { regions.append((st, rms.count - 1 - quiet)) }
        regions = regions.filter { Double($0.1 - $0.0) * fs >= 0.2 }
        // Joined into chunks of up to `target` seconds; a long region is cut every `target` seconds.
        var out: [(Double, Double)] = []
        for (a, b) in regions {
            var s0 = Double(a) * fs, e0 = Double(b + 1) * fs
            while e0 - s0 > maxLen { out.append((s0, s0 + target)); s0 += target }
            if let last = out.last, e0 - last.0 <= target, s0 - last.1 < 1.5 { out[out.count - 1].1 = e0 } else { out.append((s0, e0)) }
        }
        let duration = Double(s.count) / rate
        return out.map { (max(0, $0.0 - 0.15), min(duration, $0.1 + 0.15)) }
    }

    /// A stretch's text cut into sentences, each given a share of the stretch's time by its length.
    static func sentences(_ text: String, start: Double, end: Double, lang: String?) -> [Segment] {
        let tok = NLTokenizer(unit: .sentence)
        tok.string = text
        if let lang { tok.setLanguage(NLLanguage(lang)) }
        let parts = tok.tokens(for: text.startIndex..<text.endIndex).map { String(text[$0]).trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard parts.count > 1 else { return text.isEmpty ? [] : [Segment(start: start, end: end, text: text)] }
        let total = Double(parts.reduce(0) { $0 + $1.count })
        var t = start, out: [Segment] = []
        for p in parts {
            let d = (end - start) * Double(p.count) / max(total, 1)
            out.append(Segment(start: t, end: t + d, text: p)); t += d
        }
        return out
    }

    /// The whole file transcribed, stretch by stretch, with `progress(done, total)`.
    static func transcribe(_ url: URL, lang: String?, progress: @escaping @Sendable (Int, Int) -> Void) async throws -> Transcript {
        let s = try await samples(url)
        let duration = Double(s.count) / 16_000
        guard duration >= 0.5 else { throw Failure(errorDescription: "The recording is too short.") }
        let parts = chunks(s)
        guard !parts.isEmpty else { throw Failure(errorDescription: "No speech found in the recording.") }
        let whisper = OpenSpeech.recognizer(for: lang)
        var segs: [Segment] = []
        var engine = whisper ? "Whisper large-v3-turbo, on this Mac" : ""
        for (n, (a, b)) in parts.enumerated() {
            try Task.checkCancellation()
            progress(n, parts.count)
            let piece = Array(s[Int(a * 16_000)..<min(s.count, Int(b * 16_000))])
            var text: String?
            if whisper, let wav = Speech.writeWAV(piece, rate: 16_000) {
                text = await OpenSpeech.transcribe(wav, lang: lang)
                try? FileManager.default.removeItem(at: wav)
            } else {
                let r = await appleTranscribe(piece, lang: lang)
                text = r.text; if engine.isEmpty { engine = r.engine }
            }
            if let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { segs += sentences(t, start: a, end: b, lang: lang) }
        }
        progress(parts.count, parts.count)
        guard !segs.isEmpty else { throw Failure(errorDescription: "Nothing could be transcribed\(whisper ? "" : " (install Whisper in Settings › Voice to transcribe on this Mac)").") }
        return Transcript(segments: segs, duration: duration, engine: engine.isEmpty ? "Apple speech recognition" : engine, language: lang)
    }

    /// One stretch through Apple's recogniser (a file request): on device where the Mac has the language, else online.
    static func appleTranscribe(_ piece: [Float], lang: String?) async -> (text: String?, engine: String) {
        guard let wav = Speech.writeWAV(piece, rate: 16_000),
              let rec = Speech.recognizerLocale(lang).flatMap(SFSpeechRecognizer.init(locale:)) ?? SFSpeechRecognizer(locale: Locale.current), rec.isAvailable
        else { return (nil, "") }
        defer { try? FileManager.default.removeItem(at: wav) }
        let req = SFSpeechURLRecognitionRequest(url: wav)
        req.shouldReportPartialResults = false
        if rec.supportsOnDeviceRecognition { req.requiresOnDeviceRecognition = true }
        let engine = rec.supportsOnDeviceRecognition ? "Apple speech recognition, on this Mac" : "Apple speech recognition — online (the audio went to Apple)"
        let text: String? = await withCheckedContinuation { c in
            let once = OnceFlag()
            rec.recognitionTask(with: req) { r, e in
                if let r, r.isFinal { if once.claim() { c.resume(returning: r.bestTranscription.formattedString) } }
                else if e != nil { if once.claim() { c.resume(returning: nil) } }
            }
        }
        return (text, engine)
    }

    /// The transcript as the teacher reads it: each sentence with its time.
    static func text(_ t: Transcript, name: String, limit: Int = 24_000) -> String {
        let fmt = { (s: Double) in String(format: "%d:%02d", Int(s) / 60, Int(s) % 60) }
        var out = "Audio “\(name)” (\(fmt(t.duration))), transcribed by \(t.engine); times are approximate within each stretch:\n"
        for s in t.segments {
            let line = "[\(fmt(s.start))] \(s.text)\n"
            if out.count + line.count > limit { out += "[… the rest of the transcript is with the player]\n"; break }
            out += line
        }
        return out
    }
    static func json(_ t: Transcript, file: String) -> JSON {
        ["media": .string(file), "duration": .number(t.duration), "engine": .string(t.engine), "lang": t.language.map { .string($0) } ?? .null,
         "segments": .array(t.segments.map { [.number(($0.start * 100).rounded() / 100), .number(($0.end * 100).rounded() / 100), .string($0.text)] })]
    }
}

/// Resumes a continuation once, whichever callback comes first.
final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock(); private var done = false
    func claim() -> Bool { lock.lock(); defer { lock.unlock() }; if done { return false }; done = true; return true }
}

/// Plays the learner's audio for the listening player: a stretch from `start` to `end`, slowed without changing pitch.
@MainActor
final class MediaPlayer {
    static let shared = MediaPlayer()
    private var player: AVPlayer?
    private var file: URL?
    private var boundary: Any?
    private var onEnd: (() -> Void)?

    func play(_ url: URL, from start: Double, to end: Double, rate: Double, onEnd: @escaping () -> Void) {
        stop()
        if file != url || player == nil {
            let item = AVPlayerItem(url: url)
            item.audioTimePitchAlgorithm = .timeDomain   // slowed speech keeps its pitch
            player = AVPlayer(playerItem: item); file = url
        }
        guard let p = player else { return }
        self.onEnd = onEnd
        let endTime = CMTime(seconds: end, preferredTimescale: 600)
        boundary = p.addBoundaryTimeObserver(forTimes: [NSValue(time: endTime)], queue: .main) { [weak self] in
            MainActor.assumeIsolated { self?.finish() }
        }
        p.seek(to: CMTime(seconds: start, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            Task { @MainActor in p.rate = Float(min(1.5, max(0.5, rate))) }
        }
    }
    private func finish() {
        player?.pause()
        if let b = boundary { player?.removeTimeObserver(b); boundary = nil }
        let f = onEnd; onEnd = nil; f?()
    }
    func stop() {
        player?.pause()
        if let b = boundary { player?.removeTimeObserver(b); boundary = nil }
        onEnd = nil
    }
}
