import Foundation

/// A user-defined slash command: a Markdown file whose body becomes the message sent (Claude Code's custom commands).
/// Front matter `description` and `argument-hint`; `$ARGUMENTS` is everything typed after the command, `$1`…`$9` its words.
///
/// Deliberately not Claude Code's `!` (run a shell command and paste its output) or `@` (include a file): a command file
/// is text and nothing else, so approving or installing one can never run anything. The agent can run or read whatever the
/// message asks for through its own tools, each under the usual approvals.
struct CustomCommand: Equatable, Sendable {
    var name: String
    var description: String
    var argumentHint: String
    var body: String
    /// Where it came from, as the `/` menu shows it.
    var origin: String

    /// The message to send for `/name <arguments>`.
    func expand(_ arguments: String) -> String {
        let args = arguments.trimmingCharacters(in: .whitespacesAndNewlines)
        let words = CustomCommands.words(args)
        // One pass over the template: what is substituted is never expanded again.
        let re = try! NSRegularExpression(pattern: #"\$(ARGUMENTS|[1-9])"#)
        let ns = body as NSString
        var out = "", last = 0, used = false
        for m in re.matches(in: body, range: NSRange(location: 0, length: ns.length)) {
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let key = ns.substring(with: m.range(at: 1))
            out += key == "ARGUMENTS" ? args : (Int(key).flatMap { $0 <= words.count ? words[$0 - 1] : nil } ?? "")
            last = m.range.location + m.range.length
            used = true
        }
        out += ns.substring(from: last)
        // As in Claude Code, arguments a command never mentions still reach the model.
        if !used && !args.isEmpty { out += "\n\nARGUMENTS: " + args }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

enum CustomCommands {
    static let userDirs = [".teacher/commands", ".claude/commands"]
    static let projectDirs = ProjectTrust.commandDirs

    /// Names a command file can't take: the built-in `/` commands.
    static var reserved: Set<String> {
        Set(ProjectCommands.quickPrompts.map(\.name) + ProjectCommands.modeCommands.map(\.name) + ["review", "plugin", "plugins"])
    }

    /// A command file: front matter, then the body. The name is the file's.
    static func parse(_ text: String, fileName: String, origin: String) -> CustomCommand? {
        let (meta, body) = Skills.frontMatter(text.replacingOccurrences(of: "\r\n", with: "\n"))
        let name = fileName.lowercased()
        guard name.range(of: #"^[a-z0-9][a-z0-9._-]{0,63}$"#, options: .regularExpression) != nil else { return nil }
        let text = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let first = text.split(separator: "\n").first.map(String.init) ?? ""
        return CustomCommand(name: name, description: meta["description"].flatMap { $0.isEmpty ? nil : $0 } ?? String(first.prefix(80)),
                             argumentHint: meta["argument-hint"] ?? "", body: text, origin: origin)
    }

    /// The `*.md` files of one directory.
    static func scan(_ dir: URL, origin: String) -> [CustomCommand] {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasSuffix(".md") }.sorted()
        return names.compactMap { n in
            guard let text = try? String(contentsOf: dir.appendingPathComponent(n), encoding: .utf8) else { return nil }
            return parse(text, fileName: String(n.dropLast(3)), origin: origin)
        }
    }

    /// Every command this lesson has. `folder` is the folder whose commands may be used (callers pass it once the user approved
    /// them, as for skills); a built-in's name is never taken; the folder's wins over the user's; a plugin's keeps its name
    /// unless it is taken, then it is `plugin:name`.
    static func available(folder: URL?, home: URL? = Skills.defaultHome, plugins: [Plugin] = []) -> [CustomCommand] {
        var byName: [String: CustomCommand] = [:]
        let taken = reserved
        // Within one level the first directory wins (.teacher before .claude): scan last to first.
        if let home { for d in userDirs.reversed() { for c in scan(home.appendingPathComponent(d), origin: "yours") where !taken.contains(c.name) { byName[c.name] = c } } }
        if let folder { for d in projectDirs.reversed() { for c in scan(folder.appendingPathComponent(d), origin: "this folder") where !taken.contains(c.name) { byName[c.name] = c } } }
        for p in plugins {
            for var c in scan(p.dir.appendingPathComponent("commands"), origin: "plugin \(p.name)") {
                if taken.contains(c.name) || byName[c.name] != nil { c.name = "\(p.name):\(c.name)" }
                if byName[c.name] == nil { byName[c.name] = c }
            }
        }
        return byName.values.sorted { $0.name < $1.name }
    }

    static func available(folder: URL?, settings: AppSettings) -> [CustomCommand] {
        available(folder: ProjectTrust.approved(folder, settings), plugins: Plugins.active(settings))
    }

    /// Words the way a shell splits them: spaces separate, quotes group (`$1` of `"two words" x` is `two words`).
    static func words(_ s: String) -> [String] {
        var out: [String] = [], cur = "", quote: Character?, any = false
        for ch in s {
            if let q = quote { if ch == q { quote = nil } else { cur.append(ch) } }
            else if ch == "\"" || ch == "'" { quote = ch; any = true }
            else if ch.isWhitespace { if !cur.isEmpty || any { out.append(cur) }; cur = ""; any = false }
            else { cur.append(ch) }
        }
        if !cur.isEmpty || any { out.append(cur) }
        return out
    }

    static func suggestions(_ commands: [CustomCommand]) -> [ProjectCommands.Suggestion] {
        commands.map { c in
            ProjectCommands.Suggestion(name: c.name, detail: (c.argumentHint.isEmpty ? "" : c.argumentHint + " — ") + c.description, source: c.origin)
        }
    }
}
