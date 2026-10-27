import Foundation

enum AppPaths {
    /// Test profile: MYAITEACHER_HOME=/dir keeps the database, settings, default folder, quick questions and log under
    /// that directory, so end-to-end runs never touch the learner's own data.
    /// Unit tests get a throwaway profile even without it: they must never open the learner's database or settings.
    static let testHome: URL? = ProcessInfo.processInfo.environment["MYAITEACHER_HOME"].flatMap {
        $0.isEmpty ? nil : URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath, isDirectory: true)
    } ?? (NSClassFromString("XCTestCase") != nil
        ? FileManager.default.temporaryDirectory.appendingPathComponent("myaiteacher-tests-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        : nil)
    static let support: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let url = testHome?.appendingPathComponent("support", isDirectory: true) ?? base.appendingPathComponent("MyAITeacher", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var database: URL { support.appendingPathComponent("teacher.sqlite") }
    static var keys: URL { support.appendingPathComponent("keys.json") }
    static var settings: URL { support.appendingPathComponent("settings.json") }
    /// Default workspace where the tutor's file/bash tools operate.
    static let workspace: URL = {
        let url = (testHome ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent("AI Teacher Workspace", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    /// Lessons that don't belong to a folder ("Quick questions"). Full access by default.
    static let quickFolder: URL = {
        let url = (testHome ?? FileManager.default.homeDirectoryForCurrentUser).appendingPathComponent(".teacher/no-dir-conversations", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()
    static var webResources: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("web"),
           FileManager.default.fileExists(atPath: r.appendingPathComponent("index.html").path) { return r }
        // Development fallback: running via `swift run` from the repo.
        let src = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/web")
        return src
    }
    /// The app's own skills (`Resources/skills/<agent tree node>/<skill>/SKILL.md`).
    static var skillResources: URL {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("skills"), FileManager.default.fileExists(atPath: r.path) { return r }
        return URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/skills")
    }
}

/// GUI apps launched from Finder/Dock don't inherit the user's shell environment, so API keys
/// exported in ~/.zshrc would be invisible. We resolve the login‑shell environment once at launch.
final class ShellEnvironment: @unchecked Sendable {
    static let shared = ShellEnvironment()
    private let lock = NSLock()
    private var env: [String: String] = ProcessInfo.processInfo.environment
    private var loaded = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func get(_ key: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        if let v = env[key], !v.isEmpty { return v }
        return nil
    }

    var all: [String: String] { lock.lock(); defer { lock.unlock() }; return env }

    /// Kick off background resolution. Safe to call multiple times.
    func load() {
        DispatchQueue.global(qos: .userInitiated).async { [self] in
            let shellEnv = Self.readLoginShellEnv()
            lock.lock()
            for (k, v) in shellEnv where env[k] == nil || env[k]!.isEmpty { env[k] = v }
            loaded = true
            let w = waiters; waiters = []
            lock.unlock()
            w.forEach { $0.resume() }
        }
    }

    func waitUntilLoaded() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if loaded { lock.unlock(); c.resume(); return }
            waiters.append(c)
            lock.unlock()
        }
    }

    private static func readLoginShellEnv() -> [String: String] {
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let marker = "__AITEACHER_ENV__"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        p.arguments = ["-ilc", "printf '\(marker)'; env -0"]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        var result: [String: String] = [:]
        do { try p.run() } catch { return result }
        let deadline = DispatchTime.now() + 5
        let group = DispatchGroup()
        group.enter()
        var data = Data()
        DispatchQueue.global().async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            group.leave()
        }
        if group.wait(timeout: deadline) == .timedOut { p.terminate(); return result }
        guard let r = data.range(of: Data(marker.utf8)) else { return result }
        let body = data[r.upperBound...]
        for entry in body.split(separator: 0) {
            guard let s = String(data: entry, encoding: .utf8), let eq = s.firstIndex(of: "=") else { continue }
            result[String(s[..<eq])] = String(s[s.index(after: eq)...])
        }
        return result
    }
}

/// API keys: runtime keys (stored 0600 in Application Support, like opencode's auth.json) override env vars.
@MainActor
final class KeyStore: ObservableObject {
    static let shared = KeyStore()
    @Published private(set) var runtimeKeys: [String: String] = [:]

    private init() {
        if let data = try? Data(contentsOf: AppPaths.keys),
           let dict = try? JSONDecoder().decode([String: String].self, from: data) {
            runtimeKeys = dict
        }
    }

    enum Source: String { case runtime = "Saved in app", env = "Environment", none = "Not set" }

    func key(for provider: ProviderConfig) -> String? {
        if let k = runtimeKeys[provider.id], !k.isEmpty { return k }
        for name in provider.envKeys { if let v = ShellEnvironment.shared.get(name) { return v } }
        return nil
    }

    func source(for provider: ProviderConfig) -> (Source, String?) {
        if let k = runtimeKeys[provider.id], !k.isEmpty { return (.runtime, nil) }
        for name in provider.envKeys where ShellEnvironment.shared.get(name) != nil { return (.env, name) }
        return (.none, nil)
    }

    func set(_ key: String?, for providerID: String) {
        if let key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            runtimeKeys[providerID] = key.trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
            runtimeKeys.removeValue(forKey: providerID)
        }
        persist()
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(runtimeKeys) else { return }
        try? data.write(to: AppPaths.keys, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: AppPaths.keys.path)
    }
}


/// Tiny append-only log at ~/Library/Logs/MyAITeacher.log (rotated at 2 MB).
enum AppLog {
    private static let queue = DispatchQueue(label: "applog", qos: .utility)
    static let url: URL = AppPaths.testHome?.appendingPathComponent("MyAITeacher.log")
        ?? FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0].appendingPathComponent("Logs/MyAITeacher.log")

    /// Used on `queue` only. A formatter per line cost the caller (often the main thread) an ICU time-zone load: one
    /// took 373 ms under load in a perf run.
    nonisolated(unsafe) private static let stamps = ISO8601DateFormatter()

    static func write(_ line: String) {
        let now = Date()
        queue.async {
            let stamp = stamps.string(from: now)
            let fm = FileManager.default
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int, size > 2_000_000 {
                try? fm.removeItem(at: url.appendingPathExtension("1"))
                try? fm.moveItem(at: url, to: url.appendingPathExtension("1"))
            }
            let data = Data("\(stamp) \(line)\n".utf8)
            if let h = try? FileHandle(forWritingTo: url) { h.seekToEndOfFile(); h.write(data); try? h.close() }
            else { try? data.write(to: url) }
        }
    }
}
