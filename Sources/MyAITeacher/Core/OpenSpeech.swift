import Foundation
import AVFoundation
import CryptoKit

/// Optional open-source speech engines, downloaded on demand and run fully on this Mac (sherpa-onnx's command-line tools
/// in a subprocess, so a crash in native inference can't take the app down). Nothing is bundled: the learner turns them
/// on in Settings › Voice, sees the size, languages and folder, and every file is checked against a pinned hash before
/// it is used. Whatever isn't installed — or fails — falls back to the Mac's own engines.
///
///   runtime   sherpa-onnx 1.13.8 (macOS arm64, shared build: bin/ + lib/ with onnxruntime), Apache-2.0 (bundles espeak-ng, GPL-3)
///   voices    Supertonic 3 (int8): ja, ko, ar, de, es, fr, hi, ru, en and 20 more; no Chinese. OpenRAIL licence.
///   whisper   Whisper large-v3-turbo (int8 ONNX export): recognition in ~100 languages, incl. ar, ru, hi. MIT.
@MainActor
final class OpenSpeech: ObservableObject {
    static let shared = OpenSpeech()

    struct File: Sendable {
        var url: String
        var name: String          // file name on disk (an archive is unpacked and removed)
        var bytes: Int64
        var hash: String          // "sha256:…" (GitHub release digest, Hugging Face LFS oid) or "gitsha1:…" (a git blob)
        var archive: Bool { name.hasSuffix(".tar.bz2") || name.hasSuffix(".tar.gz") }
    }
    struct Component: Identifiable, Sendable {
        var id: String
        var title: String
        var detail: String
        var languages: [String]   // ISO codes it covers
        var license: String
        var files: [File]
        var requires: [String] = []
        var bytes: Int64 { files.reduce(0) { $0 + $1.bytes } }
    }

    nonisolated static let catalog: [Component] = [
        Component(id: "runtime", title: "sherpa-onnx runtime 1.13.8",
                  detail: "The command-line engine that runs the models below (ONNX Runtime, CPU). Needed by both.",
                  languages: [], license: "Apache-2.0 (includes espeak-ng, GPL-3.0)",
                  files: [File(url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/v1.13.8/sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2",
                               name: "sherpa-onnx-v1.13.8-osx-arm64-shared.tar.bz2", bytes: 20_310_000,
                               hash: "sha256:b10e5c7e2c30ea03de9c442655d14860d9edc475c6251d58a8f5f06e913a1d56")]),
        Component(id: "supertonic", title: "Supertonic 3 voices",
                  detail: "Natural neural voices, much clearer than the Mac's compact voices. Spoken by the app when the Mac has no Enhanced or Premium voice for the language.",
                  languages: ["ja", "ko", "ar", "de", "es", "fr", "hi", "ru", "en", "it", "pt", "nl", "pl", "tr", "uk", "vi", "sv", "cs", "el", "id", "ro", "hu", "fi", "da", "bg", "hr", "sk", "sl", "et", "lt", "lv"],
                  license: "OpenRAIL (Supertone)",
                  files: [File(url: "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2",
                               name: "sherpa-onnx-supertonic-3-tts-int8-2026-05-11.tar.bz2", bytes: 128_800_000,
                               hash: "sha256:82fa96f91c4ef8abaae3a14a3f4153facf88bed821d1f7331cec2700f432c427")],
                  requires: ["runtime"]),
        Component(id: "whisper", title: "Whisper large-v3-turbo",
                  detail: "On-device recognition of what the learner says, for languages the Mac can only recognise online (Arabic, Russian, Hindi…). Transcribes when they stop speaking.",
                  languages: ["ja", "zh", "ko", "ar", "es", "fr", "de", "ru", "hi", "en", "it", "pt", "nl", "pl", "tr", "uk", "vi", "he", "fa", "ur", "el", "th", "id", "sv"],
                  license: "MIT (OpenAI Whisper)",
                  files: [
                    File(url: "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/resolve/main/turbo-encoder.int8.onnx", name: "turbo-encoder.int8.onnx",
                         bytes: 674_716_297, hash: "sha256:b02dcdf54f348741e93fe732b67d933c8dcb6735655f710640143081db38878b"),
                    File(url: "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/resolve/main/turbo-decoder.int8.onnx", name: "turbo-decoder.int8.onnx",
                         bytes: 361_080_764, hash: "sha256:20accd02388482eb3a46bd615631adfdc85e1eb2c7db9ea3f02a40ffe6b81547"),
                    File(url: "https://huggingface.co/csukuangfj/sherpa-onnx-whisper-turbo/resolve/main/turbo-tokens.txt", name: "turbo-tokens.txt",
                         bytes: 816_730, hash: "gitsha1:a4edf0b719c10d28cd83f8c294449f99ff5d5dc0"),
                  ],
                  requires: ["runtime"]),
    ]

    /// Where the engines live: Application Support/MyAITeacher/speech/<component>/ (a test profile's own support folder).
    nonisolated static var root: URL { AppPaths.support.appendingPathComponent("speech", isDirectory: true) }
    nonisolated static func folder(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }

    enum State: Equatable { case absent, downloading(Double, String), installed, failed(String) }
    @Published private(set) var states: [String: State] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]

    init() { refresh() }

    func refresh() {
        for c in Self.catalog where tasks[c.id] == nil { states[c.id] = Self.isInstalled(c.id) ? .installed : (states[c.id].flatMap { if case .failed = $0 { return $0 }; return nil } ?? .absent) }
    }
    nonisolated static func isInstalled(_ id: String) -> Bool {
        FileManager.default.fileExists(atPath: folder(id).appendingPathComponent(".installed").path)
    }
    /// The engines usable for a language: a voice, a recogniser (with the runtime installed).
    nonisolated static func voice(for lang: String?) -> Bool {
        guard let lang, isInstalled("runtime"), isInstalled("supertonic") else { return false }
        return catalog.first { $0.id == "supertonic" }!.languages.contains(lang)
    }
    nonisolated static func recognizer(for lang: String?) -> Bool {
        guard let lang, isInstalled("runtime"), isInstalled("whisper") else { return false }
        return catalog.first { $0.id == "whisper" }!.languages.contains(lang)
    }

    // MARK: Install / remove

    func install(_ id: String) {
        guard let c = Self.catalog.first(where: { $0.id == id }), tasks[id] == nil else { return }
        for r in c.requires where !Self.isInstalled(r) { install(r) }
        states[id] = .downloading(0, "Starting…")
        tasks[id] = Task { [weak self] in
            do {
                try await Self.download(c) { frac, note in Task { @MainActor in self?.states[id] = .downloading(frac, note) } }
                await MainActor.run { if !Task.isCancelled { self?.states[id] = .installed }; self?.tasks[id] = nil }
                AppLog.write("open speech: installed \(id)")
            } catch {
                // Only the staging folder goes (download's own cleanup): a working install stays if a re-download fails.
                let msg = (error as? CancellationError) != nil ? "Cancelled" : error.localizedDescription
                await MainActor.run { self?.states[id] = msg == "Cancelled" ? .absent : .failed(msg); self?.tasks[id] = nil }
                AppLog.write("open speech: \(id) failed: \(msg)")
            }
        }
    }
    func cancel(_ id: String) { tasks[id]?.cancel() }
    func remove(_ id: String) {
        cancel(id)
        tasks[id] = nil
        try? FileManager.default.removeItem(at: Self.folder(id))
        states[id] = .absent
    }

    struct Failure: LocalizedError { var errorDescription: String? }

    /// Downloads every file of a component into a staging folder, checks each against its pinned hash, unpacks archives
    /// (with /usr/bin/tar, which keeps the runtime's dylib links), and only then moves the folder into place under `root`
    /// (the speech engines' folder, or another store's: `LiquidModels`).
    nonisolated static func download(_ c: Component, into root: URL = OpenSpeech.root, progress: @escaping @Sendable (Double, String) -> Void) async throws {
        let fm = FileManager.default
        let staging = root.appendingPathComponent(".staging-\(c.id)", isDirectory: true)
        try? fm.removeItem(at: staging)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }
        var done: Int64 = 0
        let total = max(1, c.bytes)
        for f in c.files {
            try Task.checkCancellation()
            guard let url = URL(string: f.url) else { throw Failure(errorDescription: "Bad URL \(f.url)") }
            let dest = staging.appendingPathComponent(f.name)
            let base = done
            try await Downloader.fetch(url, to: dest) { got in
                progress(Double(base + got) / Double(total), "Downloading \(f.name) — \(ByteCountFormatter.string(fromByteCount: base + got, countStyle: .file)) of \(ByteCountFormatter.string(fromByteCount: total, countStyle: .file))")
            }
            progress(Double(base + f.bytes) / Double(total), "Checking \(f.name)…")
            guard try verify(dest, hash: f.hash) else { throw Failure(errorDescription: "\(f.name) doesn't match its published checksum — not installed.") }
            done += f.bytes
            if f.archive {
                progress(Double(done) / Double(total), "Unpacking \(f.name)…")
                let r = await ProcessRunner.run("/usr/bin/tar", ["-xf", dest.path, "-C", staging.path], timeout: 600)
                guard r.exitCode == 0 else { throw Failure(errorDescription: "Couldn't unpack \(f.name): \(r.stderr.prefix(200))") }
                try fm.removeItem(at: dest)
            }
        }
        try Data("\(c.id) \(Date())\n".utf8).write(to: staging.appendingPathComponent(".installed"))
        try Task.checkCancellation()   // removed or cancelled while unpacking: nothing moves into place
        let target = root.appendingPathComponent(c.id, isDirectory: true)
        try? fm.removeItem(at: target)
        try fm.moveItem(at: staging, to: target)
    }

    /// `sha256:<hex>` over the file, or `gitsha1:<hex>`, the git blob id (sha1 of "blob <size>\0" + content) that Hugging
    /// Face publishes for files outside LFS.
    nonisolated static func verify(_ url: URL, hash: String) throws -> Bool {
        let parts = hash.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2, let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        func stream(_ update: (Data) -> Void) throws {
            while true {
                try Task.checkCancellation()
                let chunk = try h.read(upToCount: 4 << 20) ?? Data()
                if chunk.isEmpty { break }
                update(chunk)
            }
        }
        switch parts[0] {
        case "sha256":
            var d = SHA256()
            try stream { d.update(data: $0) }
            return d.finalize().map { String(format: "%02x", $0) }.joined() == parts[1].lowercased()
        case "gitsha1":
            var d = Insecure.SHA1()
            d.update(data: Data("blob \(size)\0".utf8))
            try stream { d.update(data: $0) }
            return d.finalize().map { String(format: "%02x", $0) }.joined() == parts[1].lowercased()
        default: return false
        }
    }

    // MARK: Running

    /// The sherpa-onnx binary `name`, inside the unpacked runtime (bin/ next to lib/, as its rpath expects).
    nonisolated static func binary(_ name: String) -> URL? {
        let fm = FileManager.default
        guard let e = fm.enumerator(at: folder("runtime"), includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.lastPathComponent == name && u.deletingLastPathComponent().lastPathComponent == "bin" { return u }
        return nil
    }
    /// The first file named `name` (or ending in it) under a component's folder.
    nonisolated static func find(_ id: String, _ name: String) -> URL? {
        guard let e = FileManager.default.enumerator(at: folder(id), includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.lastPathComponent == name || u.lastPathComponent.hasSuffix(name) { return u }
        return nil
    }

    /// Speaks `text` in `lang` with Supertonic into a WAV file; nil when it isn't installed or fails (the caller falls back).
    nonisolated static func synthesize(_ text: String, lang: String, speed: Double) async -> URL? {
        guard voice(for: lang), let bin = binary("sherpa-onnx-offline-tts"),
              let dur = find("supertonic", "duration_predictor.int8.onnx"), let enc = find("supertonic", "text_encoder.int8.onnx"),
              let vec = find("supertonic", "vector_estimator.int8.onnx"), let voc = find("supertonic", "vocoder.int8.onnx"),
              let json = find("supertonic", "tts.json"), let idx = find("supertonic", "unicode_indexer.bin") else { return nil }
        let style = find("supertonic", "voice.bin") ?? find("supertonic", ".bin").flatMap { $0.lastPathComponent == "unicode_indexer.bin" ? nil : $0 }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("myaiteacher-tts-\(UUID().uuidString.prefix(8)).wav")
        var args = ["--supertonic-duration-predictor=\(dur.path)", "--supertonic-text-encoder=\(enc.path)", "--supertonic-vector-estimator=\(vec.path)",
                    "--supertonic-vocoder=\(voc.path)", "--supertonic-tts-json=\(json.path)", "--supertonic-unicode-indexer=\(idx.path)",
                    "--lang=\(lang)", "--num-steps=8", "--sid=0", "--speed=\(String(format: "%.2f", speed))", "--num-threads=4", "--output-filename=\(out.path)"]
        if let style { args.insert("--supertonic-voice-style=\(style.path)", at: 6) }
        args.append(text)
        let r = await ProcessRunner.run(bin.path, args, cwd: bin.deletingLastPathComponent(), timeout: 60)
        guard r.exitCode == 0, FileManager.default.fileExists(atPath: out.path) else {
            AppLog.write("supertonic failed (\(r.exitCode)): \(r.stderr.suffix(300))"); return nil
        }
        return out
    }

    /// Transcribes a 16 kHz mono WAV with Whisper; nil when it isn't installed or fails.
    nonisolated static func transcribe(_ wav: URL, lang: String?) async -> String? {
        guard recognizer(for: lang), let bin = binary("sherpa-onnx-offline"),
              let enc = find("whisper", "turbo-encoder.int8.onnx"), let dec = find("whisper", "turbo-decoder.int8.onnx"), let raw = find("whisper", "turbo-tokens.txt"),
              let tok = byteSafeTokens(raw) else { return nil }
        var args = ["--whisper-encoder=\(enc.path)", "--whisper-decoder=\(dec.path)", "--tokens=\(tok.path)", "--whisper-task=transcribe", "--num-threads=4"]
        if let lang { args.append("--whisper-language=\(lang)") }
        args.append(wav.path)
        let r = await ProcessRunner.run(bin.path, args, cwd: bin.deletingLastPathComponent(), timeout: 120)
        guard r.exitCode == 0 else { AppLog.write("whisper failed (\(r.exitCode)): \(r.stderr.suffix(300))"); return nil }
        return parseText(r.stdout).map(unescapeBytes)
    }

    /// Whisper's tokens are byte pieces: a Chinese or Japanese character is often split across two or three of them.
    /// sherpa-onnx 1.13.8 turns each token into text on its own, so those characters came out empty and were lost
    /// ("我叫萨姆" → "我叫", 営業部 → 業部). A copy of the tokens file spells every byte above 0x7F (and "%") as an ASCII
    /// percent-escape, so nothing is lost on the way out; `unescapeBytes` turns the whole text back into UTF-8. Made once,
    /// next to the verified original.
    nonisolated static func byteSafeTokens(_ original: URL) -> URL? {
        let out = original.deletingLastPathComponent().appendingPathComponent("turbo-tokens-bytesafe.txt")
        if FileManager.default.fileExists(atPath: out.path) { return out }
        guard let text = try? String(contentsOf: original, encoding: .utf8) else { return original }
        var lines: [String] = []
        lines.reserveCapacity(52_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // Not the format we know: use the original as it is (characters may be lost, but recognition still runs).
            guard let space = line.lastIndex(of: " "), let raw = Data(base64Encoded: String(line[..<space])) else { return original }
            var esc = ""
            for b in raw { if b >= 0x80 || b == 0x25 { esc += String(format: "%%%02X", b) } else { esc.unicodeScalars.append(UnicodeScalar(b)) } }
            lines.append(Data(esc.utf8).base64EncodedString() + String(line[space...]))
        }
        do { try (lines.joined(separator: "\n") + "\n").write(to: out, atomically: true, encoding: .utf8) } catch { return original }
        return out
    }
    /// The text from byte-safe tokens back to UTF-8 (invalid sequences become U+FFFD rather than dropping the rest).
    nonisolated static func unescapeBytes(_ s: String) -> String {
        guard s.contains("%") else { return s }
        var bytes: [UInt8] = [], u = Array(s.utf8), i = 0
        while i < u.count {
            if u[i] == 0x25, i + 2 < u.count, let v = UInt8(String(decoding: u[(i + 1)...(i + 2)], as: UTF8.self), radix: 16) { bytes.append(v); i += 3 }
            else { bytes.append(u[i]); i += 1 }
        }
        return String(decoding: bytes, as: UTF8.self)
    }
    /// The recognised text from sherpa-onnx-offline's output: a JSON line per file ({"text": …}); parsed leniently (1.13's
    /// JSON can carry raw control characters).
    nonisolated static func parseText(_ out: String) -> String? {
        // Control characters (a newline inside the text) replaced first; the last "text" value wins.
        let clean = out.replacingOccurrences(of: "[\\u0000-\\u001F]", with: " ", options: .regularExpression)
        guard let re = try? NSRegularExpression(pattern: #""text"\s*:\s*("(?:[^"\\]|\\.)*")"#) else { return nil }
        let ns = clean as NSString
        guard let m = re.matches(in: clean, range: NSRange(location: 0, length: ns.length)).last else { return nil }
        let literal = ns.substring(with: m.range(at: 1))
        let value = JSON.parse(Data("[\(literal)]".utf8))?[0]?.string ?? String(literal.dropFirst().dropLast())
        return value.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
    }
}

/// A download with progress that ends on cancellation, into a file (URLSession's own temporary file is moved there).
enum Downloader {
    final class Delegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
        let progress: @Sendable (Int64) -> Void
        let dest: URL
        var cont: CheckedContinuation<Void, Error>?
        init(dest: URL, progress: @escaping @Sendable (Int64) -> Void) { self.dest = dest; self.progress = progress }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite _: Int64) {
            progress(totalBytesWritten)
        }
        func urlSession(_ s: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
            if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
                cont?.resume(throwing: OpenSpeech.Failure(errorDescription: "The server answered \(http.statusCode) for \(downloadTask.originalRequest?.url?.lastPathComponent ?? "a file").")); cont = nil; return
            }
            do { try? FileManager.default.removeItem(at: dest); try FileManager.default.moveItem(at: location, to: dest); cont?.resume() }
            catch { cont?.resume(throwing: error) }
            cont = nil
        }
        func urlSession(_ s: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
            if let error { cont?.resume(throwing: error); cont = nil }
        }
    }
    static func fetch(_ url: URL, to dest: URL, progress: @escaping @Sendable (Int64) -> Void) async throws {
        let d = Delegate(dest: dest, progress: progress)
        let session = URLSession(configuration: .ephemeral, delegate: d, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let task = session.downloadTask(with: url)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                d.cont = c
                task.resume()
            }
        } onCancel: { task.cancel() }
    }
}
