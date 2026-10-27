import Foundation

/// Skills, as in Claude Code and OpenCode: a folder with a `SKILL.md` (YAML front matter `name` and `description`, then
/// Markdown instructions, beside any scripts or references it needs). The prompt names each skill in one line; its body
/// reaches the agent only when the agent loads it with `skill`, so an agent can know many skills for the price of a list.
///
/// Where skills come from, later winning on a name clash:
///
///     the app's own, along the agent tree   Resources/skills/<node>/<skill>/   root first, so every agent has the base
///                                           skills and each branch adds its own (the code agent's never reach a tutor)
///     the user's, for every agent           ~/.teacher/skills  ~/.claude/skills  ~/.config/opencode/skills (or skill)
///                                           ~/.agents/skills
///     the open folder's                     .teacher/skills  .claude/skills  .opencode/skills (or skill)  .agents/skills
///
/// A user's or folder's skill can name the agents it is for (`agents: [code-agent, code-mentor]`); without that it is for
/// every agent. `disable-model-invocation: true` keeps a skill out of the list (Claude Code's user-only skills).
struct Skill: Equatable, Sendable {
    enum Source: Equatable, Sendable {
        case app(String)   // the agent tree node it belongs to
        case user, project
        var label: String {
            switch self {
            case .app(let n): n == "root" ? "built in" : "built in (\(Instructions.nodeTitle(n)))"
            case .user: "yours"
            case .project: "this folder's"
            }
        }
    }
    let name: String
    let description: String
    let body: String
    /// The skill's folder: its other files (scripts, references) are read from here.
    let dir: URL
    let source: Source
    /// Agent tree nodes (or their friendly names) the skill is for; nil = every agent.
    let agents: [String]?
    let hidden: Bool
}

enum Skills {
    static let userDirs = [".teacher/skills", ".claude/skills", ".config/opencode/skills", ".config/opencode/skill", ".agents/skills"]
    static let projectDirs = [".teacher/skills", ".claude/skills", ".opencode/skills", ".opencode/skill", ".agents/skills"]
    /// How many skills the prompt lists by name; past it the agent searches (`skill` with `query`).
    static let listed = 40

    /// The user's home for global skills; none under unit tests (they must not read the developer's own skills).
    static var defaultHome: URL? { NSClassFromString("XCTestCase") != nil ? nil : URL(fileURLWithPath: NSHomeDirectory()) }

    /// Friendly names a skill may use for agents, as the app names them.
    static let aliases: [String: String] = [
        "code-agent": "engineer", "agent": "engineer", "engineer": "engineer",
        "code-mentor": "code-mentor", "code": "code-mentor", "mentor": "code-mentor",
        "language-mentor": "language", "language": "language",
        "teacher": "teacher", "tutor": "tutor", "all": "root", "root": "root",
    ]

    /// Every skill the agent at `node` has in `folder`, by name (later sources win), sorted by name.
    static func available(node: String, folder: URL?, home: URL? = defaultHome, builtIn: URL = AppPaths.skillResources) -> [Skill] {
        var byName: [String: Skill] = [:]
        for n in AgentTree.path(node) {
            for s in scan(builtIn.appendingPathComponent(n.id), source: .app(n.id)) { byName[s.name] = s }
        }
        let path = Set(AgentTree.path(node).map(\.id))
        func mine(_ s: Skill) -> Bool {
            guard let agents = s.agents, !agents.isEmpty else { return true }
            return agents.contains { path.contains(aliases[$0.lowercased()] ?? $0.lowercased()) }
        }
        // Within one level the first folder wins (.teacher before .claude), so scan them last to first.
        if let home { for d in userDirs.reversed() { for s in scan(home.appendingPathComponent(d), source: .user) where mine(s) { byName[s.name] = s } } }
        if let folder { for d in projectDirs.reversed() { for s in scan(folder.appendingPathComponent(d), source: .project) where mine(s) { byName[s.name] = s } } }
        return byName.values.sorted { $0.name < $1.name }
    }

    /// The skills in one directory (`<dir>/<name>/SKILL.md`).
    static func scan(_ dir: URL, source: Skill.Source) -> [Skill] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return [] }
        return names.sorted().compactMap { n in
            let folder = dir.appendingPathComponent(n)
            guard let text = try? String(contentsOf: folder.appendingPathComponent("SKILL.md"), encoding: .utf8) else { return nil }
            return parse(text, dir: folder, source: source)
        }
    }

    /// A `SKILL.md`: front matter between `---` lines, then the body. The name defaults to the folder's.
    static func parse(_ text: String, dir: URL, source: Skill.Source) -> Skill? {
        var meta: [String: String] = [:], body = text
        let lines = text.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---", let end = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }) {
            for line in lines[1..<end] {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix(" ") else { continue }
                let key = line[..<colon].trimmingCharacters(in: .whitespaces).lowercased()
                meta[key] = unquote(line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces))
            }
            body = lines[(end + 1)...].joined(separator: "\n")
        }
        let name = (meta["name"].flatMap { $0.isEmpty ? nil : $0 } ?? dir.lastPathComponent).lowercased()
        guard name.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        let description = (meta["description"] ?? "").replacingOccurrences(of: "\n", with: " ")
        guard !description.isEmpty else { return nil }   // nothing to choose it by
        let agents = meta["agents"].map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).split(separator: ",").map { unquote($0.trimmingCharacters(in: .whitespaces)) }.filter { !$0.isEmpty } }
        return Skill(name: name, description: description, body: body.trimmingCharacters(in: .whitespacesAndNewlines), dir: dir,
                     source: source, agents: agents, hidden: meta["disable-model-invocation"]?.lowercased() == "true")
    }

    private static func unquote(_ s: String) -> String {
        guard s.count >= 2, let f = s.first, f == s.last, f == "\"" || f == "'" else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// The prompt's list: one line per skill, the agent's own first.
    static func promptSection(node: String, folder: URL?, home: URL? = defaultHome, builtIn: URL = AppPaths.skillResources) -> String? {
        let all = available(node: node, folder: folder, home: home, builtIn: builtIn).filter { !$0.hidden }
        guard !all.isEmpty else { return nil }
        let shown = all.prefix(listed)
        var s = "# Skills\nKnow-how you load when a task matches: `skill` with its name returns the instructions (follow them). Don't load one for a task it doesn't fit.\n"
        s += shown.map { "- \($0.name): \(String($0.description.prefix(160)))" }.joined(separator: "\n")
        if all.count > shown.count { s += "\n- …and \(all.count - shown.count) more: `skill` with `query` searches them." }
        return s
    }

    /// Skills whose name or description has every word of `query`, best first.
    static func search(_ query: String, in skills: [Skill]) -> [Skill] {
        let words = query.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        guard !words.isEmpty else { return skills }
        return skills.map { s -> (Skill, Int) in
            let hay = (s.name + " " + s.description).lowercased()
            return (s, words.filter { hay.contains($0) }.count + (words.contains { s.name.contains($0) } ? 1 : 0))
        }.filter { $0.1 > 0 }.sorted { $0.1 > $1.1 }.map(\.0)
    }
}

/// Loads a skill's instructions (Claude Code's Skill tool), or searches the agent's skills.
struct SkillTool: Tool {
    var subAgentVariant: Tool? { self }
    let name = "skill"
    let description = "Load a skill listed under Skills in your instructions: returns its instructions, to follow for this task. `query` searches the skills instead."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object(["name": Schema.string("The skill's name."), "query": Schema.string("Words to search the skills by, when none listed fits.")])
    }
    func summary(_ input: JSON) -> String { input["name"]?.string ?? input["query"]?.string ?? "" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let skills = Skills.available(node: ctx.agentNode, folder: ctx.workspace)
        if let q = input["query"]?.string, input["name"]?.string == nil {
            let hits = Skills.search(q, in: skills.filter { !$0.hidden }).prefix(10)
            return ToolOutput(text: hits.isEmpty ? "No skill matches “\(q)”." : hits.map { "- \($0.name): \($0.description)" }.joined(separator: "\n"))
        }
        let wanted = (input["name"]?.string ?? "").lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        guard let s = skills.first(where: { $0.name == wanted }) else {
            let near = Skills.search(wanted, in: skills).prefix(5).map(\.name)
            return .error("No skill “\(wanted)”." + (near.isEmpty ? " Skills: \(skills.map(\.name).joined(separator: ", "))." : " Did you mean: \(near.joined(separator: ", "))?"))
        }
        let files = ((try? FileManager.default.contentsOfDirectory(atPath: s.dir.path)) ?? []).filter { $0 != "SKILL.md" && !$0.hasPrefix(".") }.sorted()
        var text = "<skill name=\"\(s.name)\" source=\"\(s.source.label)\">\n\(s.body)\n</skill>"
        if !files.isEmpty { text += "\nIts files (read them as needed, from \(s.dir.path)): \(files.joined(separator: ", "))" }
        return ToolOutput(text: text, meta: ["skill": .string(s.name)])
    }
}
