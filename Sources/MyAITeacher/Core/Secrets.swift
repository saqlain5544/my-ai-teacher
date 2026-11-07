import Foundation

/// Keeps the learner's secrets on the Mac. Three jobs, each narrow on purpose so a false alarm is rare:
/// * **Environment** — the commands an agent starts get the login shell's variables without the provider keys and
///   anything named like a secret (`scrub`); Settings › Tools can allow a name. Hooks and MCP servers the user set up
///   keep the full environment.
/// * **Detection** — `redact` replaces a secret in text with `[redacted: kind]`: an exact match on a saved or environment
///   key, or a shape that is hardly ever anything else (`sk-…` with a digit, `ghp_…`, `AKIA…`, `xoxb-…`, a PEM private key).
///   It runs on every tool result before the model sees it, on the activity log, and (`find`) on URLs and queries that
///   would carry a secret out.
/// * **Credential files** — the places a person keeps credentials (`isCredentialPath`): read tools ask once per lesson,
///   and commands run with the OS refusing to read them (`WriteFence.guarded`).
enum Secrets {
    /// What the app knows about, kept where any thread can read it (`SettingsStore` and `KeyStore` update it).
    struct Config: Sendable {
        var envAllow: Set<String> = []
        var protectCredentials = true
        var providerEnvNames: Set<String> = Set(ProviderCatalog.presets.flatMap(\.envKeys))
        var savedKeys: [String] = []
    }
    nonisolated(unsafe) private static let config = Locked(Config())
    static func update(_ f: (inout Config) -> Void) { config.mutate(f) }
    static var current: Config { config.get() }

    /// True inside a tool call the model started (`Tool.runBounded`). Task-local, so a command's helper tasks inherit it.
    @TaskLocal static var agentCall = false

    // MARK: Environment

    static let secretNameWords = ["API_KEY", "APIKEY", "SECRET", "TOKEN", "PASSWORD", "PASSWD", "CREDENTIAL"]
    static func isSecretName(_ name: String, _ c: Config = current) -> Bool {
        if c.providerEnvNames.contains(name) { return true }
        let up = name.uppercased()
        return secretNameWords.contains { up.contains($0) }
    }

    /// The environment without secrets, except the names the learner allowed.
    static func scrub(_ env: [String: String], _ c: Config = current) -> [String: String] {
        env.filter { !isSecretName($0.key, c) || c.envAllow.contains($0.key) }
    }

    /// The values of the environment's secrets (a key exported in ~/.zshrc), for exact matching.
    private static func environmentSecrets(_ c: Config) -> [String] {
        ShellEnvironment.shared.all.compactMap { k, v in
            isSecretName(k, c) && (minLength...4096).contains(v.count) && !v.hasPrefix("/") && !v.contains(where: \.isWhitespace) ? v : nil
        }
    }

    // MARK: Detection

    static let minLength = 10
    private static let shapes: [(kind: String, regex: NSRegularExpression)] = {
        func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
        return [
            ("private key", re("-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----[\\s\\S]*?(-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----|$)")),
            ("API key", re("\\bsk-(?=[A-Za-z0-9_-]*\\d)[A-Za-z0-9_-]{20,}")),
            ("GitHub token", re("\\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})")),
            ("AWS key", re("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b")),
            ("Slack token", re("\\bxox[abposr]-[A-Za-z0-9-]{10,}")),
            ("Google API key", re("\\bAIza[0-9A-Za-z_-]{35}\\b")),
            ("NVIDIA API key", re("\\bnvapi-[A-Za-z0-9_-]{30,}")),
        ]
    }()

    struct Result: Sendable { var text: String; var kinds: [String] }

    /// `text` with every secret in it replaced by `[redacted: kind]`, and the kinds that were found.
    static func redact(_ text: String) -> Result {
        guard text.count >= minLength else { return Result(text: text, kinds: []) }
        var out = text, kinds: [String] = []
        let c = current
        for v in Set(c.savedKeys).union(environmentSecrets(c)) where v.count >= minLength && out.contains(v) {
            let kind = c.savedKeys.contains(v) ? "saved API key" : "environment secret"
            out = out.replacingOccurrences(of: v, with: "[redacted: \(kind)]")
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        for (kind, re) in shapes {
            let range = NSRange(out.startIndex..., in: out)
            guard re.firstMatch(in: out, range: range) != nil else { continue }
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[redacted: \(kind)]")
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return Result(text: out, kinds: kinds)
    }

    /// The kind of the first secret in `text`, or nil: for URLs and queries that must not carry one out.
    static func find(_ text: String) -> String? {
        let r = redact(text)
        return r.kinds.first
    }

    /// The tool's output with secrets redacted; `meta.redacted` lists what kind.
    static func redacted(_ out: ToolOutput) -> ToolOutput {
        let r = redact(out.text)
        guard !r.kinds.isEmpty else { return out }
        var o = out
        o.text = r.text
        var meta = out.meta?.object ?? [:]
        meta["redacted"] = .array(r.kinds.map { .string($0) })
        o.meta = .object(meta)
        return o
    }

    /// Why a call must not go out: a web address or search that contains a secret would deliver it to a server.
    static func outbound(tool: String, _ input: JSON) -> String? {
        let fields: [String]
        switch tool {
        case "web_fetch", "browser": fields = ["url"]
        case "web_search": fields = ["query"]
        default: return nil
        }
        for f in fields {
            guard let s = input[f]?.string, let kind = find(s) else { continue }
            return "Refused: the \(f) contains what looks like a secret (\(kind)), and sending it to a website would leak it. Leave it out; the learner's keys are never needed in a request you make."
        }
        return nil
    }

    // MARK: Credential files

    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Directories and files whose contents are credentials. Relative to the home folder, except the app's own keys file.
    static var credentialPaths: [String] {
        let rel = [".ssh", ".aws", ".gnupg", ".netrc", ".config/gh", ".docker/config.json", "Library/Keychains"]
        return rel.map { home + "/" + $0 } + [AppPaths.keys.path]
    }

    /// Whether `url` is, or is inside, a credential location.
    static func isCredentialPath(_ url: URL) -> Bool {
        let paths = [url.standardizedFileURL.path, WriteFence.real(url)]
        return credentialPaths.contains { c in
            let rc = WriteFence.real(URL(fileURLWithPath: c))
            return paths.contains { $0 == c || $0.hasPrefix(c + "/") || $0 == rc || $0.hasPrefix(rc + "/") }
        }
    }

    /// A folder that holds a credential location (the home folder, `~/.config`): a search from there would walk into it.
    static func containsCredentialPath(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path
        return credentialPaths.contains { $0.hasPrefix(p == "/" ? "/" : p + "/") }
    }

    /// The first credential location a tool call names in its path-like arguments, as the model wrote it.
    static func credentialPathNamed(by tool: String, _ input: JSON, workspace: URL) -> String? {
        guard ["read", "grep", "glob", "ls", "symbols", "code", "source"].contains(tool) else { return nil }
        var raws: [String] = []
        for k in ["path", "file_path", "dir", "directory", "root"] { if let s = input[k]?.string, !s.isEmpty { raws.append(s) } }
        if tool == "glob", let pat = input["pattern"]?.string, pat.hasPrefix("/") || pat.hasPrefix("~") { raws.append(pat) }
        for raw in raws {
            // A glob or a path with a wildcard: its fixed part is what is checked.
            let fixed = raw.split(separator: "/", omittingEmptySubsequences: false).prefix { !$0.contains(where: { "*?[{".contains($0) }) }.joined(separator: "/")
            let url = resolvePath(fixed.isEmpty ? "." : fixed, workspace: workspace)
            if isCredentialPath(url) || (tool != "read" && containsCredentialPath(url) && url.path != workspace.standardizedFileURL.path) { return url.path }
        }
        return nil
    }

    /// A word in a command that names a credential location (for `ReadOnlyShell`, whose commands never ask).
    static func namesCredential(_ command: String) -> Bool {
        let hints = ["/.ssh", "/.aws", "/.gnupg", "/.netrc", "/.config/gh", "/.docker/config", "/Keychains", "keys.json", ".ssh/", ".aws/", ".gnupg/", ".netrc"]
        return hints.contains { command.contains($0) }
    }
}

extension WriteFence {
    /// `profile` plus refusals to read the credential locations (every command an agent starts runs under it).
    /// Mentor fences compose: both sets of rules are in one profile. Nil when protection is off or `sandbox-exec` is missing.
    static func guarded(_ profile: String?) -> String? {
        guard Secrets.current.protectCredentials, available else { return profile }
        return (profile ?? "(version 1)\n(allow default)\n") + denyReads
    }

    /// The rules, built once: paths the kernel sees (`real`), quoted.
    static let denyReads: String = {
        func lit(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let dirs = [".ssh", ".aws", ".gnupg", ".config/gh", "Library/Keychains"].map { real(URL(fileURLWithPath: Secrets.home + "/" + $0)) }
        let files = [".netrc", ".docker/config.json"].map { real(URL(fileURLWithPath: Secrets.home + "/" + $0)) } + [real(AppPaths.keys)]
        return "(deny file-read* " + dirs.map { "(subpath \(lit($0)))" }.joined(separator: " ") + " " + files.map { "(literal \(lit($0)))" }.joined(separator: " ") + ")\n"
    }()
}
