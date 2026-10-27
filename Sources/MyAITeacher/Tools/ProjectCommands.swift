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

    // MARK: Lessons' commands (teaching modes)

    /// The follow-ups under each reply, as commands too (the page's quick chips send the same).
    static let quickPrompts: [(name: String, detail: String, prompt: String)] = [
        ("simpler", "Explain that again more simply", "Can you explain that again more simply, with an everyday analogy?"),
        ("deeper", "Go deeper: the rigorous or advanced version", "Let's go deeper — what's the more rigorous or advanced version of this?"),
        ("example", "Another worked example, then one to try", "Give me another worked example, then a similar one for me to try."),
        ("quiz", "A short graded quiz on what we just covered", "Quiz me on what we just covered with a short graded quiz."),
        ("flashcards", "Turn the last answer's key ideas into flashcards", "Turn the key ideas from your last answer into flashcards for spaced repetition."),
    ]
    /// Teaching modes by command name (`/socratic` switches to Socratic).
    static let modeCommands: [(name: String, mode: TeachingMode)] = [
        ("tutor", .tutor), ("socratic", .socratic), ("explain", .explain), ("exam", .exam), ("eli5", .eli5),
        ("research", .research), ("language", .language), ("code", .code),
    ]

    /// A teaching lesson's command: a follow-up's prompt, or a mode to switch to (with any text after it to send). Nil
    /// when the message isn't one.
    enum LessonCommand: Equatable { case prompt(String), mode(TeachingMode, then: String) }
    static func lessonCommand(_ text: String) -> LessonCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/"), let name = t.dropFirst().split(whereSeparator: \.isWhitespace).first.map({ $0.lowercased() }) else { return nil }
        let rest = t.dropFirst(name.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        if let q = quickPrompts.first(where: { $0.name == name }) { return .prompt(rest.isEmpty ? q.prompt : q.prompt + " " + rest) }
        if let m = modeCommands.first(where: { $0.name == name }) { return .mode(m.mode, then: rest) }
        return nil
    }

    /// The `/` menu of a teaching lesson.
    static func lessonSuggestions(current: TeachingMode) -> [Suggestion] {
        quickPrompts.map { Suggestion(name: $0.name, detail: $0.detail, source: "follow-up") }
            + modeCommands.filter { $0.mode != current }.map { Suggestion(name: $0.name, detail: "Switch to \($0.mode.title) mode", source: "mode") }
    }

    /// A command in the composer's `/` menu.
    struct Suggestion: Equatable, Sendable { var name: String; var detail: String; var source: String }

    /// What the built-ins do, for the menu (`/compact` and `/goal` are the session's own).
    static let builtInDetails: [(String, String)] = [
        ("goal", "Give the session a goal it works toward turn after turn until it's met"),
        ("review", "Review your uncommitted changes (or what you name) without editing"),
        ("compact", "Summarise the session so far, so the next request starts small"),
        ("init", "Write an AGENTS.md describing this codebase for future sessions"),
    ]

    /// Every command for the `/` menu: the built-ins, then the project's and your own (first found wins, as for running
    /// them), each with what it does (a file's `description:` front matter, else its first line).
    static func suggestions(_ folder: URL, home: URL? = URL(fileURLWithPath: NSHomeDirectory())) -> [Suggestion] {
        var out = builtInDetails.map { Suggestion(name: $0.0, detail: $0.1, source: "built in") }
        let projectDirs = Set(dirs(folder, home: nil).map(\.path))
        for name in names(folder, home: home) {
            guard let f = file(name, folder: folder, home: home), let text = try? String(contentsOf: f, encoding: .utf8) else { continue }
            let detail = description(text)
            let source = projectDirs.contains(where: { f.path.hasPrefix($0) }) ? "this project" : "yours"
            if let i = out.firstIndex(where: { $0.name == name }) { out[i] = Suggestion(name: name, detail: detail, source: source) }
            else { out.append(Suggestion(name: name, detail: detail, source: source)) }
        }
        return out
    }

    /// A command file's `description:` (front matter), else its first non-empty line.
    static func description(_ text: String) -> String {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.first == "---", let end = lines.dropFirst().firstIndex(of: "---") {
            if let d = lines[1..<end].first(where: { $0.lowercased().hasPrefix("description:") }) {
                return String(d.dropFirst("description:".count)).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
            }
            return lines[(end + 1)...].first { !$0.isEmpty }.map { String($0.prefix(100)) } ?? ""
        }
        return lines.first { !$0.isEmpty }.map { String($0.prefix(100)) } ?? ""
    }

    /// The menu for what's typed: while the draft is `/` plus a name being typed (no space yet), the commands starting
    /// with it, then those containing it; nil when the draft isn't a command being named.
    static func matches(_ draft: String, in all: [Suggestion]) -> [Suggestion]? {
        guard draft.hasPrefix("/"), !draft.contains(where: { $0.isWhitespace }) else { return nil }
        let typed = draft.dropFirst().lowercased()
        let starts = all.filter { $0.name.lowercased().hasPrefix(typed) }
        let contains = typed.isEmpty ? [] : all.filter { !$0.name.lowercased().hasPrefix(typed) && $0.name.lowercased().contains(typed) }
        return starts + contains
    }

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
    static func compactFocus(_ text: String) -> String? { argument(of: "compact", text) }

    /// `/goal …` in a code session: what follows it ("" alone, `clear`, `resume`, or the objective).
    static func goalArgument(_ text: String) -> String? { argument(of: "goal", text) }

    private static func argument(of command: String, _ text: String) -> String? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines), c = "/" + command
        guard t == c || t.hasPrefix(c + " ") || t.hasPrefix(c + "\n") else { return nil }
        return String(t.dropFirst(c.count)).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
