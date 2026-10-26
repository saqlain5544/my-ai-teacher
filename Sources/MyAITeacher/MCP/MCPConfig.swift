import Foundation
import CryptoKit

/// One MCP server, in Claude Code's `.mcp.json` shape: a program the app starts and talks to over its stdin and stdout
/// (`command`, `args`, `env`), or a streamable-HTTP endpoint (`"type": "http"`, `url`, `headers`). App-level servers are
/// the user's own (Settings → MCP); project servers come from the folder's `.mcp.json` and never start before the user
/// approves them once (a cloned repository can't run programs by itself).
struct MCPServerConfig: Codable, Sendable, Equatable, Identifiable {
    enum Scope: String, Codable, Sendable { case app, project }
    var name: String
    /// "stdio" (the default), "http" (streamable HTTP) or "sse" (the old HTTP+SSE transport, not supported).
    var type = "stdio"
    var command = ""
    var args: [String] = []
    var env: [String: String] = [:]
    var url = ""
    var headers: [String: String] = [:]
    /// App-level servers only: off keeps it configured but unused.
    var enabled = true
    var scope: Scope = .app

    var id: String { "\(scope.rawValue):\(name)" }
    var isHTTP: Bool { type == "http" || type == "streamable-http" || (command.isEmpty && !url.isEmpty && type != "sse") }

    init(name: String, type: String = "stdio", command: String = "", args: [String] = [], env: [String: String] = [:],
         url: String = "", headers: [String: String] = [:], enabled: Bool = true, scope: Scope = .app) {
        self.name = name; self.type = type; self.command = command; self.args = args; self.env = env
        self.url = url; self.headers = headers; self.enabled = enabled; self.scope = scope
    }

    init(from decoder: Decoder) throws {
        // Tolerant, like AppSettings: a field added later never breaks a saved list.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = (try? c.decode(String.self, forKey: .name)) ?? ""
        type = (try? c.decode(String.self, forKey: .type)) ?? "stdio"
        command = (try? c.decode(String.self, forKey: .command)) ?? ""
        args = (try? c.decode([String].self, forKey: .args)) ?? []
        env = (try? c.decode([String: String].self, forKey: .env)) ?? [:]
        url = (try? c.decode(String.self, forKey: .url)) ?? ""
        headers = (try? c.decode([String: String].self, forKey: .headers)) ?? [:]
        enabled = (try? c.decode(Bool.self, forKey: .enabled)) ?? true
        scope = (try? c.decode(Scope.self, forKey: .scope)) ?? .app
    }

    /// One `mcpServers` entry of a `.mcp.json` file.
    init?(name: String, json: JSON, scope: Scope) {
        guard json.object != nil else { return nil }
        let strings = { (k: String) in json[k]?.object?.compactMapValues { $0.string ?? $0.double.map { String($0) } } ?? [:] }
        self.init(name: name, type: json["type"]?.string?.lowercased() ?? (json["url"]?.string != nil && json["command"] == nil ? "http" : "stdio"),
                  command: json["command"]?.string ?? "", args: json["args"]?.array?.compactMap(\.string) ?? [],
                  env: strings("env"), url: json["url"]?.string ?? "", headers: strings("headers"), scope: scope)
    }

    /// What the server runs or reaches, as the user sees it in an approval (variables unexpanded: no secrets shown).
    var summary: String {
        if isHTTP || type == "sse" { return url }
        return ([command] + args).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
    }

    /// Everything an approval is for: the command line, and the environment it sets (`NODE_OPTIONS` or
    /// `DYLD_INSERT_LIBRARIES` would run other code under an innocent command), or the URL and which headers it sends.
    var approvalDetail: String {
        var lines = [summary]
        if isHTTP || type == "sse" {
            if !headers.isEmpty { lines.append("Headers: " + headers.keys.sorted().joined(separator: ", ")) }
        } else {
            lines += env.keys.sorted().map { "\($0)=\(env[$0]!)" }
        }
        return lines.joined(separator: "\n")
    }

    /// Identifies what would run: an approval is for this exact command (or URL), its arguments and environment, so a
    /// `.mcp.json` changed after the approval asks again.
    var fingerprint: String {
        let canonical: JSON = ["type": .string(isHTTP ? "http" : type), "command": .string(command), "args": .array(args.map { .string($0) }),
                               "env": .object(env.mapValues { .string($0) }), "url": .string(url), "headers": .object(headers.mapValues { .string($0) })]
        return SHA256.hash(data: Data(canonical.sortedCompact.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// With `${VAR}` and `${VAR:-default}` filled in from the user's environment (Claude Code's expansion), and a
    /// leading `~` in the command expanded.
    func expanded(_ env: [String: String] = ShellEnvironment.shared.all) -> MCPServerConfig {
        var c = self
        let x = { (s: String) in MCPConfig.expand(s, env) }
        c.command = (x(command) as NSString).expandingTildeInPath
        c.args = args.map(x)
        c.env = self.env.mapValues(x)
        c.url = x(url)
        c.headers = headers.mapValues(x)
        return c
    }
}

/// A folder's project server the user approved or declined, for the exact config they saw (its fingerprint).
struct MCPDecision: Codable, Sendable, Equatable {
    var fingerprint: String
    var allowed: Bool
}

enum MCPConfig {
    /// A server's place for this folder: usable, waiting for the user's approval, declined, or switched off.
    enum Standing: String, Sendable { case usable, needsApproval, declined, disabled, unsupported }

    struct Entry: Sendable, Identifiable {
        let config: MCPServerConfig
        let standing: Standing
        var id: String { config.id }
    }

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent(".mcp.json") }

    /// The folder's `.mcp.json` servers, in name order; an unreadable file is an error, a missing one is no servers.
    static func project(_ folder: URL) -> (servers: [MCPServerConfig], error: String?) {
        let url = file(folder)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: url.path)[.modificationDate] as? Date) ?? nil
        guard let mtime else { return ([], nil) }
        if let hit = cache.get()[url.path], hit.mtime == mtime { return hit.parsed }
        let parsed: (servers: [MCPServerConfig], error: String?)
        if let data = try? Data(contentsOf: url), let json = JSON.parse(data) {
            let entries = (json["mcpServers"] ?? json["servers"])?.object ?? [:]
            parsed = (entries.keys.sorted().compactMap { MCPServerConfig(name: $0, json: entries[$0]!, scope: .project) }, nil)
        } else {
            parsed = ([], ".mcp.json isn't valid JSON.")
        }
        cache.mutate { $0[url.path] = (mtime, parsed) }
        return parsed
    }
    private static let cache = Locked<[String: (mtime: Date, parsed: (servers: [MCPServerConfig], error: String?))]>([:])

    /// The servers the code agent has in `folder`: the user's app-level ones, then the folder's, which win a name clash
    /// (as in Claude Code, project scope over user scope).
    static func entries(_ folder: URL?, _ settings: AppSettings) -> [Entry] {
        var out: [String: Entry] = [:]
        for c in settings.mcpServers where !c.name.isEmpty {
            out[c.name] = Entry(config: c, standing: c.type == "sse" ? .unsupported : c.enabled ? .usable : .disabled)
        }
        if let folder {
            let decided = settings.mcpProjectDecisions[folder.path] ?? [:]
            for c in project(folder).servers {
                let d = decided[c.name]
                let standing: Standing = c.type == "sse" ? .unsupported
                    : d?.fingerprint == c.fingerprint ? (d!.allowed ? .usable : .declined) : .needsApproval
                out[c.name] = Entry(config: c, standing: standing)
            }
        }
        return out.values.sorted { $0.config.name < $1.config.name }
    }

    /// `${VAR}` and `${VAR:-default}`; an unset variable without a default becomes empty.
    static func expand(_ s: String, _ env: [String: String]) -> String {
        guard s.contains("${") else { return s }
        let re = try! NSRegularExpression(pattern: #"\$\{([A-Za-z_][A-Za-z0-9_]*)(:-([^}]*))?\}"#)
        let ns = s as NSString
        var out = "", last = 0
        for m in re.matches(in: s, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let name = ns.substring(with: m.range(at: 1))
            let fallback = m.range(at: 3).location == NSNotFound ? "" : ns.substring(with: m.range(at: 3))
            out += env[name].flatMap { $0.isEmpty ? nil : $0 } ?? fallback
            last = m.range.location + m.range.length
        }
        return out + ns.substring(from: last)
    }

    /// A tool's name for the model: `mcp__<server>__<tool>` (Claude Code's), with anything but letters, digits, `_` and
    /// `-` made `_`, and at most 64 characters (providers' limit; a cut name keeps a hash of the full one).
    static func toolName(server: String, tool: String) -> String {
        let full = prefix(server) + safe(tool)
        guard full.count > 64 else { return full }
        let tag = SHA256.hash(data: Data(full.utf8)).prefix(3).map { String(format: "%02x", $0) }.joined()
        return String(full.prefix(57)) + "_" + tag
    }

    /// The prefix of every tool of a server (`mcp__github__`).
    static func prefix(_ server: String) -> String { "mcp__\(safe(server))__" }
    static func safe(_ s: String) -> String { String(s.map { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") ? $0 : "_" }) }
}

extension JSON {
    /// Compact JSON with object keys sorted, so equal values always print alike (hashing).
    var sortedCompact: String {
        switch self {
        case .object(let o): return "{" + o.keys.sorted().map { JSON.string($0).compact + ":" + o[$0]!.sortedCompact }.joined(separator: ",") + "}"
        case .array(let a): return "[" + a.map(\.sortedCompact).joined(separator: ",") + "]"
        default: return compact
        }
    }
}
