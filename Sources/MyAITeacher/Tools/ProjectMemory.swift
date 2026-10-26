import Foundation

/// The code agent's memory: one Markdown file per project, `.teacher/code-memory.md`, in sections (Commands, Conventions,
/// Architecture, Gotchas, Decisions). It travels with the folder, is readable and editable by the user, and is loaded
/// into every coding session — with any CLAUDE.md / AGENTS.md the project already has.
enum ProjectMemory {
    static let sections = ["Commands", "Conventions", "Architecture", "Gotchas", "Decisions"]
    static let maxChars = 12_000

    static func file(_ folder: URL) -> URL { folder.appendingPathComponent(".teacher/code-memory.md") }

    static func read(_ folder: URL) -> String { (try? String(contentsOf: file(folder), encoding: .utf8)) ?? "" }

    /// Project memory plus the agent instructions that apply to the folder, bounded for the system prompt.
    static func contextBlock(_ folder: URL, home: URL? = URL(fileURLWithPath: NSHomeDirectory())) -> String {
        var parts: [String] = []
        let mem = read(folder).trimmingCharacters(in: .whitespacesAndNewlines)
        if !mem.isEmpty { parts.append(String(mem.prefix(maxChars))) }
        var left = instructionsMax
        for f in instructionFiles(folder, home: home) where left > 0 {
            guard let t = try? String(contentsOf: f.url, encoding: .utf8), !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            var seen: Set<String> = [f.url.standardizedFileURL.path]
            let text = String(withImports(t, base: f.url.deletingLastPathComponent(), depth: 0, seen: &seen).prefix(min(perFileMax, left)))
            left -= text.count
            parts.append("## From \(f.label)\n" + text)
        }
        return parts.joined(separator: "\n\n")
    }

    static let instructionsMax = 40_000, perFileMax = 20_000
    /// The project's instruction files, as Claude Code, Codex and Copilot name them.
    static let projectNames = ["CLAUDE.md", ".claude/CLAUDE.md", "AGENTS.md", "CLAUDE.local.md", ".github/copilot-instructions.md"]

    /// The instruction files a coding agent follows here, in order: the user's own (`~/.claude/CLAUDE.md`,
    /// `~/.teacher/AGENTS.md`), each parent folder's up to the home folder, outermost first (a package in a monorepo gets
    /// the repository's), then the project's.
    static func instructionFiles(_ folder: URL, home: URL?) -> [(label: String, url: URL)] {
        let fm = FileManager.default
        var out: [(String, URL)] = []
        if let home {
            for (label, rel) in [("your ~/.claude/CLAUDE.md", ".claude/CLAUDE.md"), ("your ~/.teacher/AGENTS.md", ".teacher/AGENTS.md")] {
                let u = home.appendingPathComponent(rel)
                if fm.fileExists(atPath: u.path) { out.append((label, u)) }
            }
            var parents: [(String, URL)] = []
            let h = home.standardizedFileURL.path
            var dir = folder.standardizedFileURL.deletingLastPathComponent()
            while dir.path.hasPrefix(h), dir.path.count >= h.count, dir.path != "/" {
                for name in ["CLAUDE.md", "AGENTS.md"] {
                    let u = dir.appendingPathComponent(name)
                    if fm.fileExists(atPath: u.path) { parents.insert(((u.path as NSString).abbreviatingWithTildeInPath, u), at: 0) }
                }
                if dir.path == h { break }
                dir = dir.deletingLastPathComponent()
            }
            out += parents
        }
        for name in projectNames {
            let u = folder.appendingPathComponent(name)
            if fm.fileExists(atPath: u.path) { out.append(("the project's \(name)", u)) }
        }
        return out
    }

    /// `text` followed by the files its `@path` mentions import (Claude Code's memory imports: `@docs/style.md`,
    /// `@~/notes.md`), relative to the importing file, three levels deep at most, each file once. Only mentions of files
    /// that exist count, outside code, so `@MainActor` or an email address is left alone.
    static func withImports(_ text: String, base: URL, depth: Int, seen: inout Set<String>) -> String {
        guard depth < 3 else { return text }
        var out = text, inFence = false
        for line in text.components(separatedBy: "\n") {
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            guard !inFence, line.contains("@") else { continue }
            let ns = line as NSString
            for m in importPattern.matches(in: line, range: NSRange(location: 0, length: ns.length)) {
                var p = ns.substring(with: m.range(at: 1))
                while p.hasSuffix(".") || p.hasSuffix(",") || p.hasSuffix(")") { p.removeLast() }
                guard p.contains("/") || p.contains(".") else { continue }
                let u = p.hasPrefix("~") ? URL(fileURLWithPath: (p as NSString).expandingTildeInPath) : p.hasPrefix("/") ? URL(fileURLWithPath: p) : base.appendingPathComponent(p)
                var isDir: ObjCBool = false
                let key = u.standardizedFileURL.path
                guard !seen.contains(key), FileManager.default.fileExists(atPath: key, isDirectory: &isDir), !isDir.boolValue,
                      let body = try? String(contentsOf: u, encoding: .utf8) else { continue }
                seen.insert(key)
                out += "\n\n### Imported from @\(p)\n" + withImports(String(body.prefix(perFileMax)), base: u.deletingLastPathComponent(), depth: depth + 1, seen: &seen)
            }
        }
        return out
    }
    private static let importPattern = try! NSRegularExpression(pattern: #"(?<![\w`@/])@((?:~/|\.{1,2}/|/)?[\w.\-]+(?:/[\w.\-]+)*)"#)

    /// Instruction files in the folders between `file` and the project root (not the root's own, which are in the
    /// prompt): Claude Code reads a subfolder's CLAUDE.md when it first works there.
    static func nested(for file: URL, workspace: URL) -> [URL] {
        let root = workspace.standardizedFileURL.path
        var dir = file.standardizedFileURL.deletingLastPathComponent(), out: [URL] = []
        while dir.path.hasPrefix(root + "/") {
            for name in ["CLAUDE.md", "AGENTS.md"] {
                let u = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) { out.insert(u, at: 0) }
            }
            dir = dir.deletingLastPathComponent()
        }
        return out
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
