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
            .filter { $0.pathExtension.lowercased() == "md" && !TreeDigest.neverLoaded($0.lastPathComponent) }.sorted { $0.path < $1.path }
    }

    /// Text for a review, made harmless to read: a line break shows as ↵ (a command can't fake a row or push the rest off
    /// screen), other control characters and bidirectional marks as <U+XXXX> (a right-to-left override can't reorder what
    /// follows), and a long text is cut with a note of how much.
    static func visible(_ text: String, max: Int = 2_000) -> String {
        var out = ""
        for u in text.unicodeScalars {
            let v = u.value
            if v == 0x09 { out += " "; continue }
            if v == 0x0A || v == 0x0D { out += "↵"; continue }
            switch u.properties.generalCategory {
            case .lineSeparator, .paragraphSeparator: out += "↵"
            // Controls, formatting characters (bidi marks, zero-width, tags), unassigned and private ones can hide or reorder
            // text; variation selectors change how a character looks. All shown as their code points.
            case .control, .format, .unassigned, .privateUse, .surrogate:
                out += String(format: "<U+%04X>", v)
            default:
                if (0xFE00...0xFE0F).contains(v) || (0xE0100...0xE01EF).contains(v) || (0xE0000...0xE007F).contains(v) { out += String(format: "<U+%04X>", v) }
                else { out.unicodeScalars.append(u) }
            }
        }
        return out.count > max ? String(out.prefix(max)) + "… (\(out.count - max) more characters not shown)" : out
    }

    /// What the user reviews before approving. What would run comes first, word for word (hook and MCP commands, with line
    /// breaks and invisible characters made visible); then the components; the plugin's own description, which it
    /// writes itself, comes last and short. `taken`: names of servers the user or the folder already has.
    func review(taken: Set<String> = []) -> String {
        let c = contents()
        var s = ""
        if !c.hooks.isEmpty { s += "HOOKS: shell commands that run as you at each matching step\n" + c.hooks.lines.map { "  " + Self.visible($0) }.joined(separator: "\n") + "\n\n" }
        for p in c.hookProblems { s += "  (hooks.json: \(Self.visible(p, max: 200)))\n" }
        if !c.servers.isEmpty {
            s += "MCP SERVERS: programs that run as you when the agent uses them\n"
            s += c.servers.map { sv in
                (taken.contains(sv.name) ? "  \(Self.visible(sv.name, max: 100)) (not used: you or this folder already have a server by that name)\n" : "  \(Self.visible(sv.name, max: 100))\n")
                    + sv.approvalLines.map { "    " + Self.visible($0) }.joined(separator: "\n")
            }.joined(separator: "\n") + "\n\n"
        }
        if !c.skills.isEmpty { s += "Skills (their instructions go to the model when used): " + c.skills.map(\.name).joined(separator: ", ") + "\n" }
        if !c.agents.isEmpty { s += "Agents (sub-agent types, within the lesson's access): " + c.agents.map(\.name).joined(separator: ", ") + "\n" }
        if !c.commands.isEmpty { s += "Commands (text only): " + c.commands.map { "/" + $0.name }.joined(separator: ", ") + "\n" }
        if c.isEmpty { s += "No skills, agents, commands, hooks or MCP servers.\n" }
        s += "\n\(Self.visible(name, max: 64))\(version.isEmpty ? "" : " " + Self.visible(version, max: 32))" + (author.isEmpty ? "" : " by \(Self.visible(author, max: 80))") + "\n"
        if !description.isEmpty { s += Self.visible(description, max: 300) + "\n" }
        s += "From: \(record.source.isEmpty ? "(unknown)" : Self.visible(record.source, max: 300))" + (record.commit.map { " @ \(Self.visible(String($0.prefix(12)), max: 12))" } ?? "") + "\n"
        s += "\(files.count) files · fingerprint \(fingerprint.prefix(16))"
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
