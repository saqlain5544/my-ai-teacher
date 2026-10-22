import Foundation

/// A coding exercise: a real project the learner builds in their folder (`<folder>/exercises/<slug>/`), checked by tests
/// they never see. The tests and the teacher's reference solution live in the app's own data (`support/exercises/<id>/`),
/// which learner code can't read (`Sandbox`), and nothing of them is ever shown: only the test run's output.
struct Exercise: Codable, Sendable, Identifiable, Hashable {
    var id: String
    var title: String
    var brief: String
    var language: String
    var run: String?
    var test: String
    var concept: String?
    var subject: String?
    var folder: String
    var conversationID: String
    var createdAt: Date
    var attempts = 0
    var passed = false
    var submitted = 0
    var lastOutput: String?

    /// The learner's project; a draft's staged starter until it is published (never the empty path, which is `/`).
    var dir: URL { folder.isEmpty ? ExerciseStore.draftStarter(id) : URL(fileURLWithPath: folder, isDirectory: true) }
}

enum ExerciseStore {
    static var root: URL { AppPaths.support.appendingPathComponent("exercises", isDirectory: true) }
    static func home(_ id: String) -> URL { root.appendingPathComponent(id, isDirectory: true) }
    static func tests(_ id: String) -> URL { home(id).appendingPathComponent("tests", isDirectory: true) }
    static func solution(_ id: String) -> URL { home(id).appendingPathComponent("solution", isDirectory: true) }
    /// A draft's starter project, until it is published to the learner's folder.
    static func draftStarter(_ id: String) -> URL { home(id).appendingPathComponent("starter", isDirectory: true) }

    static func save(_ e: Exercise) {
        try? FileManager.default.createDirectory(at: home(e.id), withIntermediateDirectories: true)
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? enc.encode(e).write(to: home(e.id).appendingPathComponent("exercise.json"), options: .atomic)
    }

    static func load(_ id: String) -> Exercise? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return (try? Data(contentsOf: home(id).appendingPathComponent("exercise.json"))).flatMap { try? dec.decode(Exercise.self, from: $0) }
    }

    /// A lesson's exercises, newest first.
    static func list(conversationID: String? = nil) -> [Exercise] {
        let ids = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
        return ids.compactMap(load).filter { !$0.folder.isEmpty && (conversationID == nil || $0.conversationID == conversationID) }
            .sorted { $0.createdAt > $1.createdAt }
    }

    // MARK: Files

    /// A relative path that stays inside its folder ("src/app.py"), or nil.
    static func safePath(_ p: String) -> String? {
        let parts = p.split(separator: "/").map(String.init)
        guard !p.hasPrefix("/"), !parts.isEmpty, !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty || $0.hasPrefix("~") }), p.count <= 200 else { return nil }
        return parts.joined(separator: "/")
    }

    static func write(_ files: [String: String], to dir: URL) throws {
        for (p, content) in files {
            guard let rel = safePath(p) else { throw ExerciseError("unsafe path \(p)") }
            let url = dir.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(content.utf8).write(to: url, options: .atomic)
        }
    }

    /// The project's text files (relative path → content), skipping build output, caches and hidden folders.
    static func read(_ dir: URL, maxFiles: Int = 200, maxBytes: Int = 400_000) -> [String: String] {
        var out: [String: String] = [:], total = 0
        let skip: Set<String> = [".git", "node_modules", "target", "build", ".build", "__pycache__", ".zig-cache", "zig-out", "dist", ".venv", "venv"]
        let dir = URL(fileURLWithPath: Sandbox.realPath(dir.path), isDirectory: true)   // enumerated paths are real ones
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { return [:] }
        for case let url as URL in e {
            let v = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey])
            if v?.isDirectory == true { if skip.contains(url.lastPathComponent) { e.skipDescendants() }; continue }
            guard out.count < maxFiles, let size = v?.fileSize, size <= 200_000, total + size <= maxBytes,
                  let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else { continue }
            out[relative(url, to: dir)] = text
            total += size
        }
        return out
    }

    /// A fresh copy of `dir` in a temporary run folder (removed by the caller).
    static func scratchCopy(of dir: URL) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("teacher-run-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: dir, to: tmp)
        return tmp
    }

    /// Runs the hidden tests against `project` (the learner's folder, or any other) in a scratch copy: the tests never
    /// land in the learner's folder, and only what the test command prints comes back.
    static func runTests(_ e: Exercise, project: URL, timeout: TimeInterval = 120) async -> Sandbox.Result {
        guard let run = try? scratchCopy(of: project) else { return .init(output: "Couldn't prepare the test run.", exitCode: 1, timedOut: false) }
        defer { try? FileManager.default.removeItem(at: run) }
        if FileManager.default.fileExists(atPath: tests(e.id).path) { try? merge(tests(e.id), into: run) }
        return await Sandbox.run(e.test, in: run, writable: [], timeout: timeout)
    }

    /// `url`'s path inside `dir`, both taken as the paths the kernel sees.
    static func relative(_ url: URL, to dir: URL) -> String {
        let base = Sandbox.realPath(dir.path), path = Sandbox.realPath(url.path)
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : url.lastPathComponent
    }

    static func merge(_ src: URL, into dst: URL) throws {
        let src = URL(fileURLWithPath: Sandbox.realPath(src.path), isDirectory: true)
        guard let e = FileManager.default.enumerator(at: src, includingPropertiesForKeys: [.isDirectoryKey]) else { return }
        for case let url as URL in e where (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) != true {
            let rel = relative(url, to: src)
            let target = dst.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
            try FileManager.default.copyItem(at: url, to: target)
        }
    }

    // MARK: Solution leaks

    /// Lines of a reference solution worth matching: long enough to mean something, not braces, imports or comments.
    static func signatureLines(_ code: String) -> Set<String> {
        Set(code.split(whereSeparator: \.isNewline).compactMap { l -> String? in
            let t = l.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            guard t.count >= 14, !t.hasPrefix("//"), !t.hasPrefix("#"), !t.hasPrefix("import "), !t.hasPrefix("from "), !t.hasPrefix("use "),
                  !t.hasPrefix("*"), !t.hasPrefix("/*") else { return nil }
            return t
        })
    }

    /// The solution's lines that the learner was not given: what a reply must not show. (The starter shares the solution's
    /// signatures, docstrings and constants; quoting those back to the learner is fine.) Saved when the exercise is published.
    static func secretLines(_ id: String) -> Set<String> {
        let file = home(id).appendingPathComponent("secret.json")
        if let d = try? Data(contentsOf: file), let lines = try? JSONDecoder().decode([String].self, from: d) { return Set(lines) }
        return signatureLines(read(solution(id)).values.joined(separator: "\n"))
    }

    static func saveSecretLines(_ id: String, starter: [String: String], solution: [String: String]) {
        let secret = signatureLines(solution.values.joined(separator: "\n")).subtracting(signatureLines(starter.values.joined(separator: "\n")))
        try? JSONEncoder().encode(secret.sorted()).write(to: home(id).appendingPathComponent("secret.json"), options: .atomic)
    }

    /// True when a code block repeats the hidden solution: four of its lines, or most of a short block.
    static func leaks(_ block: String, solution: Set<String>) -> Bool {
        let lines = signatureLines(block)
        guard !lines.isEmpty else { return false }
        let hits = lines.intersection(solution).count
        return hits >= 4 || (hits >= 2 && Double(hits) / Double(lines.count) >= 0.5)
    }
}

struct ExerciseError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}
