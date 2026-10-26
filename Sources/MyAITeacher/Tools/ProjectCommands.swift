import Foundation

/// The user's own prompts, as Claude Code's slash commands: `<name>.md` in the project's `.teacher/commands` or
/// `.claude/commands`, or the user's `~/.teacher/commands` or `~/.claude/commands` (first found wins; a subfolder makes a
/// namespace, `frontend/test.md` is `/frontend:test`), typed as `/name arguments` in a code session. The file's text, with
/// `$ARGUMENTS` (and `$1`…`$9`) filled in, goes to the agent with the message. `/init` and `/review` are built in, unless
/// a file of that name replaces them; `/compact` is handled by the session itself.
enum ProjectCommands {
    static func dir(_ folder: URL) -> URL { folder.appendingPathComponent(".teacher/commands", isDirectory: true) }

    /// Where commands are looked up, in order (without `home`, the project's only).
    static func dirs(_ folder: URL, home: URL? = URL(fileURLWithPath: NSHomeDirectory())) -> [URL] {
        [dir(folder), folder.appendingPathComponent(".claude/commands", isDirectory: true)]
            + (home.map { [$0.appendingPathComponent(".teacher/commands", isDirectory: true), $0.appendingPathComponent(".claude/commands", isDirectory: true)] } ?? [])
    }

    /// The user's commands (not the built-ins), namespaced ones as `ns:name`.
    static func names(_ folder: URL, home: URL? = URL(fileURLWithPath: NSHomeDirectory())) -> [String] {
        var out = Set<String>()
        for d in dirs(folder, home: home) {
            for rel in (try? FileManager.default.subpathsOfDirectory(atPath: d.path)) ?? [] where rel.hasSuffix(".md") {
                let parts = rel.dropLast(3).split(separator: "/")
                guard parts.count <= 3, !parts.contains(where: { $0.hasPrefix(".") }) else { continue }
                out.insert(parts.joined(separator: ":"))
            }
        }
        return out.sorted()
    }

    static let builtIns: [String: String] = [
        "init": """
        Analyse this codebase and write an AGENTS.md at its root for future coding sessions (if a CLAUDE.md or AGENTS.md \
        exists, improve it instead and keep what is still true). Include: the commands to build, check, lint and test, \
        and how to run a single test; the architecture a newcomer needs (the big picture that takes several files to see, \
        not a file listing); conventions the code follows that aren't obvious. Read the manifests, the README, CI config \
        and the main entry points first. Keep it short and specific to this repository: no generic advice, nothing made \
        up. $ARGUMENTS
        """,
        "review": """
        Review the code changes: $ARGUMENTS (when nothing is named, the working tree's uncommitted changes, `git diff \
        HEAD` with new untracked files; on a clean tree, the last commit). Read the changed code and enough of its callers \
        to judge it. Report, most severe first: correctness bugs (with the input or state that breaks, and the file:line), \
        then security, then missing tests, then simplifications. Verify each finding against the code before reporting it; \
        say plainly when you found nothing serious. Don't change any file.
        """,
    ]

    /// The file for `/name` (`ns:name` → `ns/name.md`), first in lookup order.
    static func file(_ name: String, folder: URL, home: URL? = URL(fileURLWithPath: NSHomeDirectory())) -> URL? {
        let rel = name.replacingOccurrences(of: ":", with: "/") + ".md"
        guard !rel.contains("..") else { return nil }
        return dirs(folder, home: home).map { $0.appendingPathComponent(rel) }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// The expanded prompt for a message that starts with `/name`, or nil when it is not a command.
    static func expand(_ text: String, folder: URL, home: URL? = URL(fileURLWithPath: NSHomeDirectory())) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), let name = t.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init),
              !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }) else { return nil }
        let file = Self.file(name, folder: folder, home: home)
        guard let body = file.flatMap({ try? String(contentsOf: $0, encoding: .utf8) }) ?? builtIns[name] else { return nil }
        let args = t.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        var prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Frontmatter (description: …, argument-hint: …) is for the listing, not the prompt.
        if prompt.hasPrefix("---"), let end = prompt.range(of: "\n---", range: prompt.index(prompt.startIndex, offsetBy: 3)..<prompt.endIndex) {
            prompt = String(prompt[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let positional = args.split(whereSeparator: \.isWhitespace).map(String.init)
        for i in stride(from: 9, through: 1, by: -1) {
            prompt = prompt.replacingOccurrences(of: "$\(i)", with: i <= positional.count ? positional[i - 1] : "")
        }
        prompt = prompt.replacingOccurrences(of: "$ARGUMENTS", with: args).trimmingCharacters(in: .whitespacesAndNewlines)
        let source = file.map { "from " + ($0.path.hasPrefix(folder.path + "/") ? relative($0.path, to: folder.path) : ($0.path as NSString).abbreviatingWithTildeInPath) } ?? "built in"
        return "The user ran the \(file == nil ? "" : "project ")command /\(name)\(args.isEmpty ? "" : " " + args) (\(source)):\n\(prompt)"
    }

    /// `/compact [focus]`: the session summarises itself now. The focus, or nil when the message isn't that command.
    static func compactFocus(_ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t == "/compact" || t.hasPrefix("/compact ") || t.hasPrefix("/compact\n") else { return nil }
        return String(t.dropFirst("/compact".count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
