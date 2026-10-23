import Foundation

/// The user's own prompts for a project, as Claude Code's slash commands: `.teacher/commands/<name>.md`, typed as
/// `/name arguments` in a code session. The file's text (with `$ARGUMENTS` filled in) goes to the agent with the message.
enum ProjectCommands {
    static func dir(_ folder: URL) -> URL { folder.appendingPathComponent(".teacher/commands", isDirectory: true) }

    static func names(_ folder: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir(folder).path)) ?? []).filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
    }

    /// The expanded prompt for a message that starts with `/name`, or nil when it is not a command.
    static func expand(_ text: String, folder: URL) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), let name = t.dropFirst().split(whereSeparator: \.isWhitespace).first.map(String.init),
              !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":" }) else { return nil }
        let file = dir(folder).appendingPathComponent(name + ".md")
        guard let body = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        let args = t.dropFirst(name.count + 1).trimmingCharacters(in: .whitespaces)
        var prompt = body.trimmingCharacters(in: .whitespacesAndNewlines)
        // Frontmatter (description: …) is for the listing, not the prompt.
        if prompt.hasPrefix("---"), let end = prompt.range(of: "\n---", range: prompt.index(prompt.startIndex, offsetBy: 3)..<prompt.endIndex) {
            prompt = String(prompt[end.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        prompt = prompt.replacingOccurrences(of: "$ARGUMENTS", with: args)
        return "The user ran the project command /\(name)\(args.isEmpty ? "" : " " + args) (from .teacher/commands/\(name).md):\n\(prompt)"
    }
}
