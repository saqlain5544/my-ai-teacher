import AppKit

/// What the app keeps about an installed plugin, in its settings (never in the plugin's folder): whether it is on, the
/// exact fingerprint the user approved, and where it came from.
struct PluginRecord: Codable, Sendable, Equatable {
    var enabled = true
    /// The fingerprint (SHA-256 over every file) the user approved; nil = never approved.
    var approved: String?
    /// The local folder or git URL it was installed from (what Update fetches again).
    var source = ""
    var commit: String?

    init(enabled: Bool = true, approved: String? = nil, source: String = "", commit: String? = nil) {
        self.enabled = enabled; self.approved = approved; self.source = source; self.commit = commit
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        approved = try? c.decode(String.self, forKey: .approved)
        source = (try? c.decode(String.self, forKey: .source)) ?? ""
        commit = try? c.decode(String.self, forKey: .commit)
    }
}

/// An installed plugin, in Claude Code's layout: `.claude-plugin/plugin.json` (name, version, description, author) and any of
/// `skills/`, `agents/`, `commands/`, `hooks/hooks.json`, `.mcp.json`.
struct Plugin: Sendable, Identifiable {
    enum Standing: Equatable, Sendable {
        /// Enabled and approved as it is now: its components are in use.
        case active
        case disabled
        /// New, or changed since the user approved it: nothing of it is used.
        case needsApproval
        case broken(String)
    }
    let name: String
    let dir: URL
    var version = "", description = "", author = ""
    var record: PluginRecord
    var fingerprint = ""
    var files: [String] = []
    var standing: Standing
    var id: String { name }

    /// What a plugin brings, read from its files (listing for the user's review; the same parse the seams use).
    struct Contents {
        var skills: [Skill] = []
        var agents: [AgentDefinition] = []
        var commands: [CustomCommand] = []
        var hooks = HookSet()
        var hookProblems: [String] = []
        var servers: [MCPServerConfig] = []
        var isEmpty: Bool { skills.isEmpty && agents.isEmpty && commands.isEmpty && hooks.isEmpty && servers.isEmpty }
    }

    func contents() -> Contents {
        var c = Contents()
        c.skills = Skills.scan(dir.appendingPathComponent("skills"), source: .plugin(name))
        for url in markdown(dir.appendingPathComponent("agents")) {
            if var d = (try? String(contentsOf: url, encoding: .utf8)).flatMap({ AgentCatalog.parse($0, fileName: url.deletingPathExtension().lastPathComponent) }) {
                d.source = .plugin; d.plugin = name
                if !c.agents.contains(where: { $0.name == d.name }) { c.agents.append(d) }
            }
        }
        c.commands = CustomCommands.scan(dir.appendingPathComponent("commands"), origin: "plugin \(name)")
        if let text = try? String(contentsOf: dir.appendingPathComponent("hooks/hooks.json"), encoding: .utf8) {
            let r = HookSet.parse(text: text)
            c.hooks = (r.set ?? HookSet()).tagged(plugin: name, root: dir.path)
            c.hookProblems = r.problems
        }
        c.servers = MCPConfig.project(dir).servers.map { s in
            var s = s
            s.scope = .plugin; s.plugin = name; s.name = "\(name)-\(s.name)"
            return s.replacingRoot(dir.path)
        }
        return c
    }

    private func markdown(_ d: URL) -> [URL] {
        ((try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.pathExtension.lowercased() == "md" }.sorted { $0.path < $1.path }
    }

    /// What the user reviews before approving: where it is from, every component, the hook and MCP commands verbatim,
    /// and the fingerprint the approval binds to.
    func review() -> String {
        let c = contents()
        var s = "\(name)\(version.isEmpty ? "" : " " + version)" + (author.isEmpty ? "" : " by \(author)") + "\n"
        if !description.isEmpty { s += description + "\n" }
        s += "From: \(record.source.isEmpty ? "(unknown)" : record.source)" + (record.commit.map { " @ \($0.prefix(12))" } ?? "") + "\n"
        s += "\(files.count) files · fingerprint \(fingerprint.prefix(16))\n"
        if !c.skills.isEmpty { s += "\nSkills (their instructions go to the model when used): " + c.skills.map(\.name).joined(separator: ", ") }
        if !c.agents.isEmpty { s += "\nAgents (sub-agent types, within the lesson's access): " + c.agents.map(\.name).joined(separator: ", ") }
        if !c.commands.isEmpty { s += "\nCommands (text only): " + c.commands.map { "/" + $0.name }.joined(separator: ", ") }
        if !c.hooks.isEmpty { s += "\n\nHooks (shell commands that run as you at each matching step):\n" + c.hooks.lines.joined(separator: "\n") }
        for p in c.hookProblems { s += "\n  (hooks.json: \(p))" }
        if !c.servers.isEmpty { s += "\n\nMCP servers (programs that run as you when the agent uses them):\n" + c.servers.map { "\($0.name): " + $0.approvalDetail.replacingOccurrences(of: "\n", with: "\n    ") }.joined(separator: "\n") }
        if c.isEmpty { s += "\nNo skills, agents, commands, hooks or MCP servers." }
        return s
    }
}

enum Plugins {
    static var root: URL { AppPaths.support.appendingPathComponent("plugins", isDirectory: true) }
    /// Bounds on one plugin: it is a few text files, not a repository.
    static let limits = TreeDigest.Limits(files: 500, perFile: 2_000_000, total: 20_000_000, depth: 8)
    static let namePattern = #"^[a-z0-9][a-z0-9._-]{0,63}$"#

    /// Every plugin folder under `root`, with its standing for these settings.
    static func installed(_ settings: AppSettings, root: URL = Plugins.root) -> [Plugin] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        return names.compactMap { load($0, dir: root.appendingPathComponent($0), record: settings.plugins[$0] ?? PluginRecord()) }
    }

    /// The plugins whose components are in use: enabled, and approved exactly as they are on disk.
    static func active(_ settings: AppSettings, root: URL = Plugins.root) -> [Plugin] {
        guard !settings.plugins.isEmpty else { return [] }
        return installed(settings, root: root).filter { $0.standing == .active }
    }

    private static let cache = Locked<[String: (signature: String, scan: TreeDigest.Result)]>([:])

    /// The folder's digest, recomputed only when a file's size or time changed (it is asked for at every tool call).
    static func scan(_ dir: URL) -> TreeDigest.Result {
        let fm = FileManager.default
        let sig = (fm.subpaths(atPath: dir.path) ?? []).prefix(5_000).sorted().map { p -> String in
            let a = try? fm.attributesOfItem(atPath: dir.appendingPathComponent(p).path)
            return "\(p):\(a?[.size] as? Int ?? 0):\(((a?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
        }.joined(separator: "|")
        if let hit = cache.get()[dir.path], hit.signature == sig { return hit.scan }
        let r = TreeDigest.scan(dir, limits: limits)
        cache.mutate { $0[dir.path] = (sig, r) }
        return r
    }

    struct Manifest { var name = "", version = "", description = "", author = "" }

    /// `.claude-plugin/plugin.json`; the error says what is wrong with it.
    static func manifest(_ dir: URL) -> (Manifest?, String?) {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent(".claude-plugin/plugin.json")) else { return (nil, "no .claude-plugin/plugin.json") }
        guard let j = JSON.parse(data), j.object != nil else { return (nil, "plugin.json isn't valid JSON") }
        guard let name = j["name"]?.string, name.range(of: namePattern, options: .regularExpression) != nil else {
            return (nil, "plugin.json needs a `name` of lower-case letters, digits, `.`, `_` or `-`")
        }
        let author = j["author"]?.string ?? j["author"]?["name"]?.string ?? ""
        return (Manifest(name: name, version: j["version"]?.string ?? "", description: j["description"]?.string ?? "", author: author), nil)
    }

    /// The problem that makes a folder unfit as a plugin, if any (also the install check).
    static func problem(_ dir: URL, scan s: TreeDigest.Result, name: String? = nil) -> String? {
        if s.overLimit { return "it is larger than a plugin may be (\(limits.files) files, \(limits.total / 1_000_000) MB, \(limits.perFile / 1_000_000) MB a file)" }
        if let l = s.escaping.first { return "“\(l)” is a symlink that leaves the plugin folder" }
        if let p = s.special.first { return "“\(p)” isn't a regular file" }
        if let bad = s.files.first(where: { $0.split(separator: "/").contains("..") }) { return "“\(bad)” has a path that climbs out of the folder" }
        let m = manifest(dir)
        if let e = m.1 { return e }
        if let name, m.0?.name != name { return "plugin.json's name “\(m.0?.name ?? "")” isn't the folder's “\(name)”" }
        return nil
    }

    private static func load(_ name: String, dir: URL, record: PluginRecord) -> Plugin? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let s = scan(dir)
        var p = Plugin(name: name, dir: dir, record: record, fingerprint: s.digest, files: s.files, standing: .active)
        if let why = problem(dir, scan: s, name: name) { p.standing = .broken(why); return p }
        let m = manifest(dir).0
        p.version = m?.version ?? ""; p.description = m?.description ?? ""; p.author = m?.author ?? ""
        p.standing = !record.enabled ? .disabled : record.approved == s.digest ? .active : .needsApproval
        return p
    }

    /// `/plugin`: the app's Settings window, where the Plugins page is.
    @MainActor static func openSettings() {
        NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
    }

    // MARK: Components for the seams

    static func hooks(_ plugins: [Plugin]) -> HookSet {
        plugins.reduce(HookSet()) { $0.merged($1.contents().hooks) }
    }
    static func servers(_ plugins: [Plugin]) -> [MCPServerConfig] {
        plugins.flatMap { $0.contents().servers }
    }
    static func agents(_ plugins: [Plugin]) -> [AgentDefinition] {
        plugins.flatMap { $0.contents().agents }
    }
}
