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
        /// Tokens and header values of the user's MCP servers (settings.json), matched exactly like the saved keys.
        var mcpSecrets: [String] = []
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

    /// A dotenv-shaped line: `[export] UPPER_NAME_WITH_PASSWORD|SECRET|TOKEN|API_KEY|CREDENTIAL=value` with no space around
    /// `=`, at the start of a line or after the row prefix `read` (`   2\t`) or `grep -n` (`.env:3:`, `3:`) adds. Group 1 is
    /// the prefix and name, group 2 the value: a quoted string or one whole unquoted word.
    private static let dotenv = try! NSRegularExpression(
        pattern: "(?m)^((?:[ \\t]*\\d+\\t|[^\\s:]+:\\d+:|\\d+:)?[ \\t]*(?:export[ \\t]+)?[A-Z0-9_]*(?:PASSWORD|PASSWD|SECRET|TOKEN|API_?KEY|CREDENTIAL)[A-Z0-9_]*=)(\"[^\"\\n$]*\"|'[^'\\n$]*'|[A-Za-z0-9_.:/+@%~,=-]+)(?=[ \\t]*(?:#.*)?$)")

    /// Whether a dotenv value looks like a secret: at least 8 characters, not just digits, not a short plain word
    /// (`MAX_TOKENS=4096`, `PASSWORD_FIELD=password`). A real `.env` is covered only where it has this shape; its other
    /// lines reach the model.
    static func looksLikeSecretValue(_ raw: String) -> Bool {
        let v = raw.count >= 2 && ["\"", "'"].contains(raw.first!) ? String(raw.dropFirst().dropLast()) : raw
        let plainURL = (v.hasPrefix("http://") || v.hasPrefix("https://")) && !v.contains("@")   // an address, not a credential
        return v.count >= 8 && !plainURL && !v.allSatisfy(\.isNumber) && !(v.count < 16 && v.allSatisfy(\.isLetter))
    }

    /// `text` with the values of dotenv-shaped secret lines replaced, or nil when there are none.
    static func redactDotenv(_ text: String) -> String? {
        let ns = text as NSString
        let hits = dotenv.matches(in: text, range: NSRange(location: 0, length: ns.length)).filter { looksLikeSecretValue(ns.substring(with: $0.range(at: 2))) }
        guard !hits.isEmpty else { return nil }
        var out = text
        for m in hits.reversed() { out = (out as NSString).replacingCharacters(in: m.range(at: 2), with: "[redacted: .env value]") }
        return out
    }

    struct Result: Sendable { var text: String; var kinds: [String] }

    /// `text` with every secret in it replaced by `[redacted: kind]`, and the kinds that were found.
    static func redact(_ text: String) -> Result {
        guard text.count >= minLength else { return Result(text: text, kinds: []) }
        var out = text, kinds: [String] = []
        let c = current
        for v in Set(c.savedKeys).union(c.mcpSecrets).union(environmentSecrets(c)) where v.count >= minLength && out.contains(v) {
            let kind = c.savedKeys.contains(v) ? "saved API key" : c.mcpSecrets.contains(v) ? "MCP server secret" : "environment secret"
            out = out.replacingOccurrences(of: v, with: "[redacted: \(kind)]")
            if !kinds.contains(kind) { kinds.append(kind) }
        }
        if let env = redactDotenv(out) {
            out = env
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

    /// A `write`/`edit` of an existing file that puts in a `[redacted: …]` marker the file's current content doesn't hold is
    /// refused, whatever was read before: the model would save the marker over the real value, and a value it saw through
    /// `bash` (`cat`, `head`: not redacted by shape alone) or another agent's read gets the same protection. A file that is
    /// new, or that already holds the marker (documentation about it), is fine.
    static func introducesMarker(tool: String, _ input: JSON, workspace: URL) -> String? {
        guard tool == "write" || tool == "edit", let path = input["path"]?.string else { return nil }
        let url = resolvePath(path, workspace: workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        var news = [input["content"]?.string, input["new_string"]?.string].compactMap { $0 }
        news += (input["edits"]?.array ?? []).compactMap { $0["new_string"]?.string }
        let marker = try! NSRegularExpression(pattern: "\\[redacted: [^\\]\\n]+\\]")
        func markers(_ t: String) -> Set<String> {
            Set(marker.matches(in: t, range: NSRange(t.startIndex..., in: t)).compactMap { Range($0.range, in: t).map { String(t[$0]) } })
        }
        let incoming = news.reduce(into: Set<String>()) { $0.formUnion(markers($1)) }
        guard !incoming.isEmpty else { return nil }
        let existing = (try? String(contentsOf: url, encoding: .utf8)).map(markers) ?? []
        guard !incoming.subtracting(existing).isEmpty else { return nil }
        return "Refused: \(url.path) exists and its text doesn't hold the `[redacted: …]` marker the new text does. A marker stands for a value that was hidden from you; saving it would destroy the real value. Edit around those lines and leave them as they are. (A new file that only mentions the marker is fine.)"
    }

    // MARK: Commands

    /// The credential fence is on for the commands the model starts.
    static var fenceActive: Bool { current.protectCredentials && WriteFence.available }

    /// A shell script for a command the model started: the scrubbed names unset first (a `~/.zshenv` re-exports them, since
    /// `zsh -c` sources it), on the script's first line so line numbers stay. Only names that are plain identifiers are
    /// listed. Nothing the model wrote is changed.
    static func shellScript(_ script: String) -> String {
        guard agentCall else { return script }
        let c = current
        let names = ShellEnvironment.shared.all.keys.filter { isSecretName($0, c) && !c.envAllow.contains($0) && $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }.sorted()
        return names.isEmpty ? script : "unset \(names.joined(separator: " ")) 2>/dev/null; " + script
    }

    /// A hint for the error a nested sandbox gives, appended to the command's output.
    /// The wording follows which fence is on: the credential rules (a Settings switch turns them off), a code-mentor project's
    /// write fence in `folder` (no switch), or both (the switch alone would not help). With neither known, the mentor's.
    static func hint(for output: String, folder: URL? = nil) -> String? {
        guard output.contains("sandbox_apply: Operation not permitted") || output.contains("sandbox-exec: sandbox_apply") else { return nil }
        let credentials = fenceActive, mentor = folder.map(ProjectProfile.mentorFenceOpen) ?? false
        let toggle = credentials && mentor
            ? "the learner can turn off “Commands can't read credential folders” in Settings › Tools › Secrets, but the code mentor's write fence is on for this folder too, so the tool has to run without its own sandbox either way"
            : credentials
            ? "otherwise the learner can turn off “Commands can't read credential folders” in Settings › Tools › Secrets"
            : "the code mentor's write fence is on for this command, so the tool has to run without its own sandbox"
        return "[Hint: this command runs inside a sandbox the app set up, and a tool that sandboxes itself can't nest in it. For SwiftPM pass `--disable-sandbox`; \(toggle).]"
    }

    // MARK: Credential files

    static let home = FileManager.default.homeDirectoryForCurrentUser.path
    /// Directories and files whose contents are credentials: the usual places under the home folder, and the app's own
    /// keys file and settings (MCP tokens live in them).
    /// The one list: the read gate, the deny rules, `ReadOnlyShell`, `namesCredential` and `TreeDigest`'s link check all read
    /// it. Under the home folder, whole trees and single files.
    static let credentialFolders = [".ssh", ".aws", ".gnupg", ".config/gh", ".config/gcloud", ".kube", "Library/Keychains"]
    static let credentialFiles = [".netrc", ".docker/config.json", ".npmrc", ".git-credentials"]
    static var credentialPaths: [String] {
        (credentialFolders + credentialFiles).map { home + "/" + $0 } + [AppPaths.keys.path, AppPaths.settings.path]
    }

    /// Whether `url` is, or is inside, a credential location (case-insensitively: the disk is; and through symlinks).
    static func isCredentialPath(_ url: URL) -> Bool {
        let paths = [url.standardizedFileURL.path, WriteFence.real(url)].map { $0.lowercased() }
        return credentialPaths.contains { c in
            let cs = [c, WriteFence.real(URL(fileURLWithPath: c))].map { $0.lowercased() }
            return paths.contains { p in cs.contains { p == $0 || p.hasPrefix($0 + "/") } }
        }
    }

    /// A folder that holds a credential location (the home folder, `~/.config`): a search from there would walk into it.
    static func containsCredentialPath(_ url: URL) -> Bool {
        let p = url.standardizedFileURL.path.lowercased()
        return credentialPaths.contains { $0.lowercased().hasPrefix(p == "/" ? "/" : p + "/") }
    }

    /// The first credential location a tool call names in its path-like arguments. Every path is resolved the way the tools
    /// resolve it (`..` removed lexically, `~` expanded) and checked in full. `glob` also has its fixed prefix checked, and a
    /// `..` after a wildcard (`*/../../.ssh`) is asked about whatever it reaches. A search that starts above a credential
    /// folder (grep, glob, symbols, code) is asked about too; `ls` of the home folder is not.
    static func credentialPathNamed(by tool: String, _ input: JSON, workspace: URL) -> String? {
        // Every tool that takes a path to read: `lsp` names its file in `file`. (`debug`'s `program` and the test tools' paths
        // are run, not read, under the credential deny rules.)
        guard ["read", "grep", "glob", "ls", "symbols", "code", "source", "lsp"].contains(tool) else { return nil }
        let ws = workspace.standardizedFileURL
        let walks = ["grep", "glob", "symbols", "code"].contains(tool)
        func hit(_ u: URL) -> Bool { isCredentialPath(u) || (walks && containsCredentialPath(u) && u.path != ws.path) }
        var candidates: [(raw: String, base: URL)] = []
        var baseDir = ws
        for k in ["path", "file_path", "file", "dir", "directory", "root"] {
            guard let s = input[k]?.string, !s.isEmpty else { continue }
            candidates.append((s, ws))
            if tool == "glob", k == "path" { baseDir = resolvePath(s, workspace: ws) }
        }
        if tool == "glob", let pat = input["pattern"]?.string, !pat.isEmpty { candidates.append((pat, baseDir)) }
        for (raw, base) in candidates {
            let full = resolvePath(raw, workspace: base)
            if hit(full) { return full.path }
            guard tool == "glob" else { continue }
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            guard let w = parts.firstIndex(where: { $0.contains(where: { "*?[{".contains($0) }) }) else { continue }
            let prefix = resolvePath(parts[..<w].joined(separator: "/").isEmpty ? "." : parts[..<w].joined(separator: "/"), workspace: base)
            if hit(prefix) { return prefix.path }
            if parts[w...].contains("..") { return full.path }
        }
        return nil
    }

    /// A word in a command that names a credential location (for `ReadOnlyShell`, whose commands never ask).
    static func namesCredential(_ command: String) -> Bool {
        let hints = (credentialFolders + credentialFiles).map { "/" + $0 } + credentialFolders.map { $0 + "/" } + credentialFiles
            + ["/.docker/config", "/Keychains", AppPaths.keys.path, AppPaths.settings.path]
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

    /// The rules, built once: paths the kernel sees (`real`).
    static let denyReads: String = {
        let home = Secrets.home
        let dirs = Secrets.credentialFolders.map { real(URL(fileURLWithPath: home + "/" + $0)) }
        let files = Secrets.credentialFiles.map { real(URL(fileURLWithPath: home + "/" + $0)) } + [real(AppPaths.keys), real(AppPaths.settings)]
        let parents = [home, home + "/.config", home + "/.docker", home + "/Library", AppPaths.support.path, AppPaths.support.deletingLastPathComponent().path].map { real(URL(fileURLWithPath: $0)) }
        // Approved plugin files live here and are read by the app as the learner approved them: a command may read them, not change them.
        return denyRules(dirs: dirs, files: files, parents: parents, writeOnly: [real(Plugins.root)])
    }()

    /// Read and write refusals for `dirs` (whole trees) and `files`, and refusal to move or delete the `parents` that hold
    /// them (`mv ~/.config /tmp/c` would carry `gh` away from its rule). Writing includes renaming, unlinking and linking
    /// the credential paths themselves, so `mv ~/.ssh /tmp/s && cat /tmp/s/id_rsa` fails. A write the learner approved goes
    /// through the file tools, which run in the app and are not under this profile.
    /// `writeOnly` trees (the approved plugins) can be read but not written, renamed or deleted.
    static func denyRules(dirs: [String], files: [String], parents: [String], writeOnly: [String] = []) -> String {
        func lit(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let paths = dirs.map { "(subpath \(lit($0)))" } + files.map { "(literal \(lit($0)))" }
        // (An empty filter list would deny everything.)
        return (paths.isEmpty ? "" : "(deny file-read* file-write* " + paths.joined(separator: " ") + ")\n")
            + (writeOnly.isEmpty ? "" : "(deny file-write* " + writeOnly.map { "(subpath \(lit($0)))" }.joined(separator: " ") + ")\n")
            + "(deny file-write-unlink " + parents.map { "(literal \(lit($0)))" }.joined(separator: " ") + ")\n"
    }
}
