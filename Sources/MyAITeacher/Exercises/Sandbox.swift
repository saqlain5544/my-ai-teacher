import Foundation

/// Runs learner code on this Mac under a Seatbelt profile (`sandbox-exec`): no network, writes only inside the run folder,
/// the temporary folder and build caches, and no reads of the app's own data (keys, hidden tests and solutions live there)
/// or the usual credential stores. Reads elsewhere stay open: compilers and interpreters need the system and toolchains.
enum Sandbox {
    struct Result: Sendable {
        var output: String
        var exitCode: Int32
        var timedOut: Bool
        var passed: Bool { exitCode == 0 && !timedOut }
    }

    /// The path the kernel sees (`/var/folders/…` is `/private/var/folders/…`). Foundation's symlink resolution drops
    /// `/private`, which a Seatbelt rule would then never match.
    static func realPath(_ path: String) -> String {
        guard let r = realpath(path, nil) else { return path }
        defer { free(r) }
        return String(cString: r)
    }

    /// `readOnly`: folders never written, even inside an otherwise writable place (a code mentor's runs: the lesson folder
    /// and the learner's exercise projects, wherever they live). Later rules win in a Seatbelt profile, so these come last.
    static func profile(writable: [URL], readOnly: [URL] = []) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let writes = writable.map { "(subpath \(q(realPath($0.path))))" }
            + ["(subpath \"/private/var/folders\")", "(subpath \"/private/tmp\")", "(subpath \(q(home + "/Library/Caches")))", "(subpath \(q(home + "/.cache")))",
               "(literal \"/dev/null\")", "(literal \"/dev/zero\")", "(regex #\"^/dev/tty\")", "(regex #\"^/dev/fd/\")"]
        let secret = [realPath(AppPaths.support.path), home + "/Library/Application Support/MyAITeacher", home + "/.ssh", home + "/.aws",
                      home + "/.gnupg", home + "/.config/gh", home + "/.netrc", home + "/Library/Keychains", home + "/.local/share/opencode"]
        return """
        (version 1)
        (allow default)
        (deny network*)
        (allow network* (remote unix-socket))
        (deny file-write*)
        (allow file-write* \(writes.joined(separator: " ")))
        (deny file-read* \(Set(secret).sorted().map { "(subpath \(q($0)))" }.joined(separator: " ")))
        \(readOnly.isEmpty ? "" : "(deny file-write* " + readOnly.map { "(subpath \(q(realPath($0.path))))" }.joined(separator: " ") + ")")
        """
    }

    /// `command` through zsh in `cwd`, sandboxed. Output is capped; a run past `timeout` is stopped.
    static func run(_ command: String, in cwd: URL, writable: [URL], timeout: TimeInterval = 60, outputLimit: Int = 200_000) async -> Result {
        var env = ShellEnvironment.shared.all
        // No credentials reach learner code, whatever the profile allows.
        for k in env.keys where k.hasSuffix("_API_KEY") || k.hasSuffix("_TOKEN") || k.hasSuffix("_SECRET") || k == "MYAITEACHER_HOME" { env[k] = nil }
        env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path
        let r = await ProcessRunner.run("/usr/bin/sandbox-exec", ["-p", profile(writable: [cwd] + writable), "/bin/zsh", "-c", command],
                                        cwd: cwd, env: env, timeout: timeout, outputLimit: outputLimit)
        var out = r.combined
        if r.timedOut { out += "\n[stopped after \(Int(timeout)) s]" }
        return Result(output: out, exitCode: r.exitCode, timedOut: r.timedOut)
    }
}
