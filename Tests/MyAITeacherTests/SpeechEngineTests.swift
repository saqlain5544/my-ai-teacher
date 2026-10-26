import XCTest
import CryptoKit
@testable import MyAITeacher

/// The optional open-source speech engines (downloaded on request, checked against pinned hashes, run as subprocesses)
/// and the pitch comparison of the speaking card — tested with local fixtures: no network, no real models.
final class SpeechEngineTests: XCTestCase {
    var dir: URL!
    override func setUp() async throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("speech-\(UUID().uuidString.prefix(6))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: OpenSpeech.root)
    }
    override func tearDown() {
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.removeItem(at: OpenSpeech.root)
    }

    private func sha256(_ url: URL) throws -> String { SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined() }

    func testHashesAreCheckedBeforeAnythingIsUsed() throws {
        let f = dir.appendingPathComponent("tokens.txt")
        try Data("a 0\nb 1\n".utf8).write(to: f)
        XCTAssertTrue(try OpenSpeech.verify(f, hash: "sha256:" + sha256(f)))
        XCTAssertFalse(try OpenSpeech.verify(f, hash: "sha256:" + String(repeating: "0", count: 64)))
        // A git blob id, as Hugging Face publishes for files outside LFS (git hash-object).
        var h = Insecure.SHA1(); h.update(data: Data("blob 8\0a 0\nb 1\n".utf8))
        XCTAssertTrue(try OpenSpeech.verify(f, hash: "gitsha1:" + h.finalize().map { String(format: "%02x", $0) }.joined()))
        XCTAssertFalse(try OpenSpeech.verify(f, hash: "md5:abc"), "unknown hash kinds are refused")
        // The catalogue pins a hash for every file it would download.
        for c in OpenSpeech.catalog { for file in c.files { XCTAssertTrue(file.hash.hasPrefix("sha256:") || file.hash.hasPrefix("gitsha1:"), file.name); XCTAssertGreaterThan(file.bytes, 0) } }
    }

    func testInstallUnpacksVerifiedFilesAndTheRecogniserRunsAsASubprocess() async throws {
        // A stand-in runtime: bin/sherpa-onnx-offline prints what the real one prints for a transcribed file.
        let pkg = dir.appendingPathComponent("pkg/sherpa-onnx-v0-osx-arm64-shared", isDirectory: true)
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("bin"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: pkg.appendingPathComponent("lib"), withIntermediateDirectories: true)
        let tool = pkg.appendingPathComponent("bin/sherpa-onnx-offline")
        try "#!/bin/sh\necho 'progress…' >&2\necho '{\"lang\": \"\", \"text\": \" hola mundo\", \"timestamps\": []}'\n".write(to: tool, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        let archive = dir.appendingPathComponent("runtime.tar.bz2")
        let r = await ProcessRunner.run("/usr/bin/tar", ["-cjf", archive.path, "-C", dir.appendingPathComponent("pkg").path, "sherpa-onnx-v0-osx-arm64-shared"])
        XCTAssertEqual(r.exitCode, 0, r.stderr)
        let size = (try FileManager.default.attributesOfItem(atPath: archive.path)[.size] as! NSNumber).int64Value
        let runtime = OpenSpeech.Component(id: "runtime", title: "r", detail: "", languages: [], license: "",
                                           files: [.init(url: archive.absoluteString, name: "runtime.tar.bz2", bytes: size, hash: "sha256:" + (try sha256(archive)))])
        try await OpenSpeech.download(runtime) { _, _ in }
        XCTAssertTrue(OpenSpeech.isInstalled("runtime"))
        XCTAssertNotNil(OpenSpeech.binary("sherpa-onnx-offline"), "bin/ unpacked next to lib/")
        // Whisper's files, plain (not archives).
        var files: [OpenSpeech.File] = []
        for n in ["turbo-encoder.int8.onnx", "turbo-decoder.int8.onnx", "turbo-tokens.txt"] {
            let u = dir.appendingPathComponent(n); try Data(n.utf8).write(to: u)
            files.append(.init(url: u.absoluteString, name: n, bytes: Int64(n.utf8.count), hash: "sha256:" + (try sha256(u))))
        }
        let whisper = OpenSpeech.Component(id: "whisper", title: "w", detail: "", languages: ["es"], license: "", files: files)
        try await OpenSpeech.download(whisper) { _, _ in }
        XCTAssertTrue(OpenSpeech.recognizer(for: "es"))
        XCTAssertFalse(OpenSpeech.recognizer(for: "xx"), "only the languages it covers")
        let wav = dir.appendingPathComponent("a.wav"); try Data().write(to: wav)
        let text = await OpenSpeech.transcribe(wav, lang: "es")
        XCTAssertEqual(text, "hola mundo")
        // A file that doesn't match its hash is never installed.
        let bad = OpenSpeech.Component(id: "supertonic", title: "s", detail: "", languages: ["ja"], license: "",
                                       files: [.init(url: wav.absoluteString, name: "x.bin", bytes: 0, hash: "sha256:" + String(repeating: "1", count: 64))])
        do { try await OpenSpeech.download(bad) { _, _ in }; XCTFail("a wrong checksum must fail") } catch {}
        XCTAssertFalse(OpenSpeech.isInstalled("supertonic"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: OpenSpeech.folder("supertonic").path))
    }

    func testTheRecognisedTextIsReadFromLenientJSON() {
        XCTAssertEqual(OpenSpeech.parseText("log line\n{\"lang\": \"\", \"text\": \"こんにちは\", \"tokens\": []}\n"), "こんにちは")
        XCTAssertEqual(OpenSpeech.parseText("{\"text\": \"line one\nline two\", \"x\": 1}"), "line one line two", "raw control characters (1.13's JSON)")
        XCTAssertNil(OpenSpeech.parseText("nothing here"))
    }

    /// Whisper's byte-piece tokens: a character split across tokens must survive (sherpa-onnx 1.13.8 decoded each token
    /// alone and dropped them: 萨姆 → nothing, 営業部 → 業部).
    func testWhisperTokensKeepCharactersSplitAcrossTokens() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sa = Array("萨".utf8)   // three bytes: as three tokens, each alone invalid UTF-8
        let tokens: [[UInt8]] = [Array("我".utf8), [sa[0]], [sa[1]], [sa[2]], Array(" 50%".utf8)]
        let file = dir.appendingPathComponent("turbo-tokens.txt")
        try tokens.enumerated().map { Data($1).base64EncodedString() + " \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        let safe = try XCTUnwrap(OpenSpeech.byteSafeTokens(file))
        let decoded = try String(contentsOf: safe, encoding: .utf8).split(separator: "\n").map { line -> String in
            String(decoding: Data(base64Encoded: String(line.split(separator: " ")[0]))!, as: UTF8.self)
        }
        XCTAssertTrue(decoded.allSatisfy { $0.unicodeScalars.allSatisfy(\.isASCII) }, "every token is plain ASCII now: \(decoded)")
        XCTAssertEqual(OpenSpeech.unescapeBytes(decoded.joined()), "我萨 50%", "the runtime's output, joined, decodes back exactly")
        XCTAssertEqual(OpenSpeech.unescapeBytes("plain text"), "plain text")
    }

    /// A take with no voice in it never reaches Whisper (it writes a stock phrase over silence).
    func testSilentTakesAreNotTranscribed() {
        let rate = 16_000.0
        let hiss = (0..<16_000).map { _ in Float.random(in: -0.002...0.002) }
        XCTAssertLessThan(Speech.levels(hiss, rate: rate).voiced, 0.1, "room noise isn't a voice")
        let voice = (0..<16_000).map { i in Float(0.2 * sin(Double(i) * 2 * .pi * 220 / rate)) }
        XCTAssertGreaterThan(Speech.levels(hiss + voice, rate: rate).voiced, 0.9, "a second of speech-level sound")
        let farVoice = (0..<16_000).map { i in Float(0.006 * sin(Double(i) * 2 * .pi * 220 / rate)) }   // about -47 dBFS
        XCTAssertGreaterThan(Speech.levels(hiss + farVoice, rate: rate).voiced, 0.9, "a voice across the room, still clear above the hiss")
        XCTAssertEqual(Speech.levels([Float](repeating: 0, count: 16_000), rate: rate).voiced, 0, "a denied microphone records zeros")
        let pausesAround = hiss + (hiss.prefix(8_000).enumerated().map { i, n in n + Float(0.006 * sin(Double(i) * 2 * .pi * 220 / rate)) }) + hiss
        XCTAssertEqual(Speech.levels(pausesAround, rate: rate).voiced, 0.5, accuracy: 0.05, "half a second of voice between pauses")
    }

    func testPitchContoursCompareTheMelody() {
        func sweep(_ from: Double, _ to: Double, seconds: Double = 1.2, rate: Double = 16_000) -> [Float] {
            let n = Int(seconds * rate)
            var phase = 0.0
            return (0..<n).map { i in
                let f = from + (to - from) * Double(i) / Double(n)
                phase += 2 * .pi * f / rate
                return Float(0.5 * sin(phase))
            }
        }
        let rise = Pitch.contour(Pitch.track(sweep(140, 260), sampleRate: 16_000))
        let rise2 = Pitch.contour(Pitch.track(sweep(200, 380, rate: 22_050), sampleRate: 22_050))   // a higher voice, another rate
        let fall = Pitch.contour(Pitch.track(sweep(260, 140), sampleRate: 16_000))
        XCTAssertEqual(rise.count, 80)
        let voiced = rise.compactMap { $0 }
        XCTAssertGreaterThan(voiced.count, 60, "a steady tone is voiced throughout")
        XCTAssertGreaterThan(voiced.last! - voiced.first!, 8, "140 → 260 Hz is about +10.7 semitones")
        XCTAssertGreaterThan(Pitch.similarity(rise, rise2) ?? 0, 0.9, "the same shape in a higher voice matches")
        XCTAssertLessThan(Pitch.similarity(rise, fall) ?? 1, 0.1, "a fall is not a rise")
        let j = Pitch.json(learner: rise, target: rise2)
        XCTAssertNotNil(j?["similarity"]); XCTAssertEqual(j?["learner"]?.array?.count, 80)
        XCTAssertTrue(Pitch.track([Float](repeating: 0, count: 16_000), sampleRate: 16_000).allSatisfy { $0 == nil }, "silence is unvoiced")
    }

    func testTheOpenVoiceIsUsedOnlyWhenItIsTheBetterOne() {
        XCTAssertFalse(SpeechEngines.useOpenVoice("ja", preference: "auto"), "not installed: the Mac's voice")
        XCTAssertFalse(SpeechEngines.useOpenVoice("ja", preference: "open"))
        XCTAssertFalse(SpeechEngines.useOpenVoice(nil, preference: "open"))
    }
}
