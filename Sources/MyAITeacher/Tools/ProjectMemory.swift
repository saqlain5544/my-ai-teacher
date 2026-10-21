import Foundation

/// The code agent's memory: one Markdown file per project, `.teacher/code-memory.md`, in sections (Commands, Conventions,
/// Architecture, Gotchas, Decisions). It travels with the folder, is readable and editable by the user, and is loaded
/// into every coding session — with any CLAUDE.md / AGENTS.md the project already has.
enum ProjectMemory {
    static let sections = ["Commands", "Conventions", "Architecture", "Gotchas", "Decisions"]
    static let maxChars = 12_000

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent(".teacher/code-memory.md") }

    static func read(_ folder: URL) -> String { (try? String(contentsOf: file(folder), encoding: .utf8)) ?? "" }

    /// Project memory plus the project's own agent instructions, bounded for the system prompt.
    static func contextBlock(_ folder: URL) -> String {
        var parts: [String] = []
        let mem = read(folder).trimmingCharacters(in: .whitespacesAndNewlines)
        if !mem.isEmpty { parts.append(mem) }
        for name in ["CLAUDE.md", "AGENTS.md", ".github/copilot-instructions.md"] {
            if let t = try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8), !t.isEmpty {
                parts.append("## From the project's \(name)\n" + String(t.prefix(6000)))
            }
        }
        let all = parts.joined(separator: "\n\n")
        return all.count > maxChars ? String(all.prefix(maxChars)) + "\n…" : all
    }

    /// Adds a bullet under `section` (created if missing); a bullet already there is not repeated.
    static func add(_ folder: URL, section: String, text: String) throws -> String {
        let sec = sections.first { $0.caseInsensitiveCompare(section) == .orderedSame } ?? section.capitalized
        let line = "- " + text.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        var doc = read(folder)
        if doc.isEmpty { doc = "# Project memory\n" }
        if doc.components(separatedBy: "\n").contains(line) { return "Already noted." }
        var lines = doc.components(separatedBy: "\n")
        if let h = lines.firstIndex(of: "## \(sec)") {
            var end = h + 1
            while end < lines.count, !lines[end].hasPrefix("## ") { end += 1 }
            while end > h + 1, lines[end - 1].trimmingCharacters(in: .whitespaces).isEmpty { end -= 1 }
            lines.insert(line, at: end)
        } else {
            if lines.last?.isEmpty == false { lines.append("") }
            lines += ["## \(sec)", line]
        }
        try write(folder, lines.joined(separator: "\n"))
        return "Noted under \(sec)."
    }

    /// Removes every line containing `match` (case-insensitive).
    static func remove(_ folder: URL, match: String) throws -> String {
        let lines = read(folder).components(separatedBy: "\n")
        let kept = lines.filter { !($0.hasPrefix("- ") && $0.localizedCaseInsensitiveContains(match)) }
        guard kept.count < lines.count else { return "Nothing matched “\(match)”." }
        try write(folder, kept.joined(separator: "\n"))
        return "Removed \(lines.count - kept.count) line(s)."
    }

    static func write(_ folder: URL, _ text: String) throws {
        let f = file(folder)
        try FileManager.default.createDirectory(at: f.deletingLastPathComponent(), withIntermediateDirectories: true)
        try String(text.prefix(maxChars * 2)).write(to: f, atomically: true, encoding: .utf8)
    }
}

/// The code agent's project memory tool.
struct ProjectMemoryTool: Tool {
    let name = "project_memory"
    let description = "This project's memory (.teacher/code-memory.md): view it, add a durable fact under a section (Commands, Conventions, Architecture, Gotchas, Decisions), or remove an outdated line."
    let risk = ToolRisk.readOnly   // writes only the app's own .teacher folder
    var schema: JSON {
        Schema.object([
            "action": ["type": "string", "enum": ["view", "add", "remove"]],
            "section": ["type": "string", "enum": .array(ProjectMemory.sections.map { .string($0) })],
            "text": Schema.string("add: one short fact (e.g. \"Run tests: swift test --filter X\"); remove: text the line contains."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "") + (input["text"]?.string.map { " " + $0 } ?? "") }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        switch input["action"]?.string ?? "view" {
        case "add":
            let t = try input.req("text")
            return ToolOutput(text: try ProjectMemory.add(ctx.workspace, section: input["section"]?.string ?? "Gotchas", text: t), meta: ["write": true])
        case "remove":
            return ToolOutput(text: try ProjectMemory.remove(ctx.workspace, match: try input.req("text")))
        default:
            let doc = ProjectMemory.read(ctx.workspace)
            return ToolOutput(text: doc.isEmpty ? "No project memory yet. Add build/test commands, conventions and gotchas as you learn them." : doc)
        }
    }
}
