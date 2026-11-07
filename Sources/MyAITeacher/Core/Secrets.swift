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
            ("private key", re("-----BEGIN [A-Z ]*PRIVATE KEY( BLOCK)?-----(?:[\\s\\S]*?-----END [A-Z ]*PRIVATE KEY( BLOCK)?-----|\\s*[A-Za-z0-9+/]{16,}={0,2}(?:\\r?\\n[A-Za-z0-9+/]{16,}={0,2})*)")),
            ("API key", re("\\bsk-(?=[A-Za-z0-9_-]*\\d)[A-Za-z0-9_-]{20,}")),
            ("GitHub token", re("\\b(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{22,})")),
            ("AWS key", re("\\b(?:AKIA|ASIA)[0-9A-Z]{16}\\b")),
            ("Slack token", re("\\bxox[abposr]-[A-Za-z0-9-]{10,}")),
            ("Google API key", re("\\bAIza[0-9A-Za-z_-]{35}\\b")),
            ("NVIDIA API key", re("\\bnvapi-[A-Za-z0-9_-]{30,}")),
        ]
    }()

    /// A dotenv-shaped line: `[export] UPPER_NAME_WITH_PASSWORD|SECRET|TOKEN|API_KEY|CREDENTIAL = value`, at the start of a
    /// line. The value is a quoted string or one whole unquoted word (so `API_KEY = os.environ["API_KEY"]` is left alone).
    private static let dotenv = try! NSRegularExpression(
        pattern: "(?m)^([ \\t]*(?:export[ \\t]+)?[A-Z0-9_]*(?:PASSWORD|SECRET|TOKEN|API_KEY|CREDENTIAL)[A-Z0-9_]*[ \\t]*=[ \\t]*)(?:\"[^\"\\n$]{4,}\"|'[^'\\n$]{4,}'|[A-Za-z0-9_.:/+@%~,=-]{4,}(?=[ \\t]*(?:#.*)?$))")

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
        let envRange = NSRange(out.startIndex..., in: out)
        if dotenv.firstMatch(in: out, range: envRange) != nil {
            out = dotenv.stringByReplacingMatches(in: out, range: envRange, withTemplate: "$1[redacted: .env value]")
            if !kinds.contains(".env value") { kinds.append(".env value") }
        }
        for (kind, re) in shapes {
            let range = NSRange(out.startIndex..., in: out)
            guard re.firstMatch(in: out, range: range) != nil else { continue }
            out = re.stringByReplacingMatches(in: out, range: range, withTemplate: "[redacted: \(kind)]")
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        return Result(text: out, kinds: kinds)
    }

    /// `json` with every string inside redacted (a log line is redacted field by field, before it is serialized).
    static func redact(json: JSON) -> JSON {
        switch json {
        case .string(let s): return .string(redact(s).text)
        case .array(let a): return .array(a.map { redact(json: $0) })
        case .object(let o): return .object(o.mapValues { redact(json: $0) })
        default: return json
        }
    }

    /// Every string inside `json`.
    static func strings(in json: JSON) -> [String] {
        switch json {
        case .string(let s): return [s]
        case .array(let a): return a.flatMap { strings(in: $0) }
        case .object(let o): return o.values.flatMap { strings(in: $0) }
        default: return []
        }
    }

    /// The kind of the first secret in `text`, or nil: for URLs and queries that must not carry one out.
    static func find(_ text: String) -> String? {
        let r = redact(text)
        return r.kinds.first
    }

    /// The tool's output with secrets redacted; `meta.redacted` lists what kind.
    static func redacted(tool: String = "", _ out: ToolOutput) -> ToolOutput {
        let r = redact(out.text)
        guard !r.kinds.isEmpty else { return out }
        var o = out
        o.text = r.text
        if tool == "read" { o.text += "\n[Some values above were redacted. Never write a `[redacted: …]` marker into a file; edit around that line.]" }
        var meta = out.meta?.object ?? [:]
        meta["redacted"] = .array(r.kinds.map { .string($0) })
        o.meta = .object(meta)
        return o
    }

    /// Why a call must not go out: a web address or search that contains a secret would deliver it to a server.
    static func outbound(tool: String, _ input: JSON) -> String? {
        guard ["web_fetch", "web_search", "browser"].contains(tool) else { return nil }
        // Every string of the call: `urls[]`, a browser step's url, the text typed into a page.
        for s in strings(in: input) {
            guard let kind = find(s) else { continue }
            return "Refused: this \(tool) call contains what looks like a secret (\(kind)), and sending it to a website would leak it. Leave it out; the learner's keys are never needed in a request you make."
        }
        return nil
    }

    /// Refuses a `write`/`edit` whose new text holds a `[redacted: …]` marker the file doesn't already have: the model
    /// saw a redacted `read` and would otherwise save the marker over the real value.
    static func introducesMarker(tool: String, _ input: JSON, workspace: URL) -> String? {
        guard tool == "write" || tool == "edit", let path = input["path"]?.string else { return nil }
        var news = [input["content"]?.string, input["new_string"]?.string].compactMap { $0 }
        news += (input["edits"]?.array ?? []).compactMap { $0["new_string"]?.string }
        let marker = try! NSRegularExpression(pattern: "\\[redacted: [^\\]\\n]+\\]")
        func markers(_ t: String) -> Set<String> {
            Set(marker.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range, in: t).map { String(t[$0]) } })
        }
        let incoming = news.reduce(into: Set<String>()) { $0.formUnion(markers($1)) }
        guard !incoming.isEmpty else { return nil }
        let existing = (try? String(contentsOf: resolvePath(path, workspace: workspace), encoding: .utf8)).map(markers) ?? []
        guard !incoming.subtracting(existing).isEmpty else { return nil }
        return "Refused: the new text contains a `[redacted: …]` marker, which replaced a secret in what you read. Writing it would destroy the real value. Edit around that line and leave it as it is."
    }

    // MARK: Commands

    /// A shell script for a command the model started: the scrubbed names unset first (a `~/.zshenv` re-exports them, since
    /// `zsh -c` sources it), on the script's first line so line numbers stay; and, when the fence is on, `--disable-sandbox`
    /// for `swift build|test|run`, whose own sandbox can't nest inside ours.
    static func shellScript(_ script: String) -> String {
        guard agentCall else { return script }
        var out = script
        if WriteFence.profile != nil, WriteFence.available {
            out = out.replacingOccurrences(of: "\\bswift (build|test|run)\\b(?! --disable-sandbox)", with: "swift $1 --disable-sandbox", options: .regularExpression)
        }
        let c = current
        let names = ShellEnvironment.shared.all.keys.filter { isSecretName($0, c) && !c.envAllow.contains($0) && $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }.sorted()
        return names.isEmpty ? out : "unset \(names.joined(separator: " ")) 2>/dev/null; " + out
    }

    /// A hint for the error a nested sandbox gives, appended to the command's output.
    static func hint(for output: String) -> String? {
        guard output.contains("sandbox_apply: Operation not permitted") || output.contains("sandbox-exec: sandbox_apply") else { return nil }
        return "[Hint: this command runs inside the app's credential sandbox, and a tool that sandboxes itself can't nest in it. For SwiftPM pass `--disable-sandbox`; otherwise the learner can turn off “Commands can't read credential folders” in Settings › Tools › Secrets.]"
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
            if isCredentialPath(url) || (["grep", "glob", "symbols", "code"].contains(tool) && containsCredentialPath(url) && url.path != workspace.standardizedFileURL.path) { return url.path }
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
