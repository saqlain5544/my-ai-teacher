import Foundation

/// A lesson's `/` commands: the follow-ups under each reply (`/simpler`, `/quiz`…) and the teaching modes (`/socratic`).
enum ProjectCommands {
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

    /// The menu for what's typed: while the draft is `/` plus a name being typed (no space yet), the commands starting
    /// with it, then those containing it; nil when the draft isn't a command being named.
    static func matches(_ draft: String, in all: [Suggestion]) -> [Suggestion]? {
        guard draft.hasPrefix("/"), !draft.contains(where: { $0.isWhitespace }) else { return nil }
        let typed = draft.dropFirst().lowercased()
        let starts = all.filter { $0.name.lowercased().hasPrefix(typed) }
        let contains = typed.isEmpty ? [] : all.filter { !$0.name.lowercased().hasPrefix(typed) && $0.name.lowercased().contains(typed) }
        return starts + contains
    }
}
