import Foundation

/// Installing a plugin: from a local folder (copied, so the original can change without touching what was approved) or a
/// git URL (a hardened shallow clone). Nothing is approved by installing; the plugin's standing is "needs approval".
enum PluginInstaller {
    struct Failure: Error, LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    struct Installed { let name: String; let record: PluginRecord }

    /// Only transports that need no helper program: https, ssh, and scp-style `user@host:path`. `ext::` and `fd::` (a
    /// command to run), `file:`, `git:` (unauthenticated), `http:` and anything starting with `-` (an option) are refused.
    static func validateGitURL(_ raw: String) throws -> String {
        let u = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !u.isEmpty, u.count <= 300 else { throw Failure("That isn't a git URL.") }
        if u.hasPrefix("-") || u.contains("::") || u.unicodeScalars.contains(where: { CharacterSet.whitespacesAndNewlines.union(.controlCharacters).union(CharacterSet(charactersIn: "'\"`$\\;|&<>(){}")).contains($0) }) {
            throw Failure("Refused: that URL could run a command (a remote helper, option or shell character). Use https:// or ssh://.")
        }
        let lower = u.lowercased()
        if lower.hasPrefix("https://") || lower.hasPrefix("ssh://") {
            // `ssh://-oProxyCommand=…@host` would reach ssh as an option.
            guard !u.dropFirst(lower.hasPrefix("https://") ? 8 : 6).hasPrefix("-") else { throw Failure("That isn't a valid git URL.") }
            guard let c = URLComponents(string: u), let host = c.host, !host.isEmpty, !host.hasPrefix("-"),
                  host.range(of: #"^[A-Za-z0-9][A-Za-z0-9.-]*$"#, options: .regularExpression) != nil else { throw Failure("That isn't a valid git URL.") }
            return u
        }
        if u.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]*@[A-Za-z0-9][A-Za-z0-9.-]*:[A-Za-z0-9._~/-]+$"#, options: .regularExpression) != nil { return u }
        throw Failure("Only https://, ssh:// and user@host:path git URLs are accepted.")
    }

    /// The arguments of the clone: no hooks, no helper transports, no submodules, no symlinks (checked out as plain files).
    static func cloneArguments(_ url: String, into dir: String) -> [String] {
        ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never", "-c", "protocol.file.allow=never", "-c", "protocol.allow=never",
         "-c", "protocol.https.allow=always", "-c", "protocol.ssh.allow=always", "-c", "core.symlinks=false", "-c", "core.fsmonitor=false",
         "-c", "advice.detachedHead=false", "clone", "--depth", "1", "--single-branch", "--no-tags", "--no-recurse-submodules", "--", url, dir]
    }

    /// The environment of the clone: the user's, minus every `GIT_*` setting, plus ours: no prompts, no global or system
    /// config (so no `filter.*` or `credential.*` helper runs), only https and ssh.
    static func cloneEnvironment() -> [String: String] {
        var env = ShellEnvironment.shared.all.filter { !$0.key.hasPrefix("GIT_") }
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ALLOW_PROTOCOL"] = "https:ssh"
        env["GIT_LFS_SKIP_SMUDGE"] = "1"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["GIT_SSH_COMMAND"] = "ssh -o BatchMode=yes"
        return env
    }

    /// Installs (or, with `replacing`, updates) the plugin at `source` under `root`. Returns its name and record; the
    /// caller stores the record. An update keeps the plugin's `approved`, which then matches only if nothing changed.
    static func install(source: String, replacing: String? = nil, previous: PluginRecord? = nil, root: URL = Plugins.root) async throws -> Installed {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let staging = root.appendingPathComponent(".staging-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? fm.removeItem(at: staging) }
        let text = source.trimmingCharacters(in: .whitespacesAndNewlines)
        let local = localFolder(text)
        var commit: String?
        if let local {
            try copy(local, to: staging)
        } else {
            commit = try await clone(try validateGitURL(text), into: staging)
        }
        let s = TreeDigest.scan(staging, limits: Plugins.limits)
        if let why = Plugins.problem(staging, scan: s) { throw Failure("Not installed: \(why).") }
        guard let name = Plugins.manifest(staging).0?.name else { throw Failure("Not installed: plugin.json has no name.") }
        if let replacing, replacing != name { throw Failure("Not installed: that is “\(name)”, not “\(replacing)”.") }
        let dest = root.appendingPathComponent(name, isDirectory: true)
        if replacing == nil, fm.fileExists(atPath: dest.path) { throw Failure("“\(name)” is already installed: Update it, or Remove it first.") }
        // The new folder takes the old one's place in two renames, so a failure leaves one or the other whole.
        let old = root.appendingPathComponent(".old-\(UUID().uuidString.prefix(8))")
        if fm.fileExists(atPath: dest.path) { try fm.moveItem(at: dest, to: old) }
        do { try fm.moveItem(at: staging, to: dest) } catch {
            if fm.fileExists(atPath: old.path) { try? fm.moveItem(at: old, to: dest) }
            throw error
        }
        try? fm.removeItem(at: old)
        var record = previous ?? PluginRecord()
        record.source = text; record.commit = commit
        return Installed(name: name, record: record)
    }

    /// `text` as an existing local folder (a path, `~/…` or a file: URL), else nil.
    static func localFolder(_ text: String) -> URL? {
        var path = text
        if let u = URL(string: text), u.isFileURL { path = u.path }
        path = (path as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard path.hasPrefix("/"), FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return URL(fileURLWithPath: path).standardizedFileURL
    }

    /// Copies regular files and in-folder relative symlinks only, within the plugin limits; `.git` is left out.
    static func copy(_ src: URL, to dst: URL) throws {
        let fm = FileManager.default
        let s = TreeDigest.scan(src, limits: Plugins.limits, skip: [".git"])
        if let why = Plugins.problem(src, scan: s) { throw Failure("Not installed: \(why).") }
        try fm.createDirectory(at: dst, withIntermediateDirectories: true)
        for rel in s.files {
            let to = dst.appendingPathComponent(rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: src.appendingPathComponent(rel), to: to)
        }
        for (rel, target) in s.links {
            let to = dst.appendingPathComponent(rel)
            try fm.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createSymbolicLink(atPath: to.path, withDestinationPath: target)
        }
    }

    /// A shallow, hardened clone into `dir`; returns the commit it is at. `.git` is removed: the plugin is its files.
    static func clone(_ url: String, into dir: URL) async throws -> String {
        let env = cloneEnvironment()
        let r = await ProcessRunner.run("/usr/bin/git", cloneArguments(url, into: dir.path), env: env, timeout: 180, outputLimit: 200_000)
        guard r.exitCode == 0, !r.timedOut else {
            throw Failure("git couldn't clone it: " + (r.timedOut ? "timed out" : String((r.stderr.isEmpty ? r.stdout : r.stderr).trimmingCharacters(in: .whitespacesAndNewlines).suffix(300))))
        }
        let head = await ProcessRunner.run("/usr/bin/git", ["-C", dir.path, "rev-parse", "HEAD"], env: env, timeout: 20, outputLimit: 1_000)
        let sha = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        try? FileManager.default.removeItem(at: dir.appendingPathComponent(".git"))
        return sha.range(of: #"^[0-9a-f]{7,64}$"#, options: .regularExpression) != nil ? sha : ""
    }

    /// Removes a plugin's folder.
    static func remove(_ name: String, root: URL = Plugins.root) throws {
        guard name.range(of: Plugins.namePattern, options: .regularExpression) != nil else { throw Failure("Not a plugin name.") }
        try FileManager.default.removeItem(at: root.appendingPathComponent(name))
    }
}
