import Foundation

/// Builds the system prompts from the agents' instructions (`Instructions`: lean defaults the learner can edit in
/// Settings) plus what only the app knows: today's date, the model, the folder, the learner and their memory.
enum SystemPrompt {
    /// The mode's instructions (the default text; a lesson uses `Instructions.text` with its settings).
    /// Where the lesson-specific part starts (everything before it is identical across lessons).
    static let dynamicMarker = "\n\n# Environment\n"

    /// Splits a built prompt into [shared instructions, lesson context] for providers with explicit cache breakpoints.
    static func split(_ system: String) -> [String] {
        guard let r = system.range(of: dynamicMarker) else { return [system] }
        // A prompt with nothing before the marker has one part: an empty (cached) text block is refused by Anthropic.
        return [String(system[..<r.lowerBound]), String(system[r.lowerBound...]).trimmingCharacters(in: .newlines)].filter { !$0.isEmpty }
    }

    private static func today() -> String {
        let df = DateFormatter(); df.dateFormat = "EEEE, d MMMM yyyy"
        return df.string(from: Date())
    }

    /// The guides on an agent's path through `AgentTree`, root first (each the learner's edited text, else the default).
    static func guides(_ node: String, _ settings: AppSettings) -> String {
        AgentTree.path(node).filter { !$0.guide.isEmpty }.map { n in
            let text = Instructions.text(n.id == "root" ? .app : .guide(n.id), settings)
            return text.replacingOccurrences(of: "{more_tools}", with: ToolRegistry.deferredIndex(node, settings))
        }.joined(separator: "\n\n")
    }

    static func build(settings: AppSettings, mode: TeachingMode, coreMemory: String, model: String, lessonID: String? = nil, folder: URL? = nil) -> String {
        let name = settings.learnerName.isEmpty ? "the learner" : settings.learnerName
        var s = Instructions.text(.teacher, settings).replacingOccurrences(of: "{learner}", with: name)
        s += "\n\n# Current teaching mode\n" + Instructions.text(.mode(mode), settings)
            + "\n(If the learner switches modes later you'll see a note in their message.)"
        if BoardSystem.applies(to: mode) {
            s += "\n\n" + (BoardSystem.current == "shallow" ? Instructions.boardShallow : Instructions.text(.board, settings))
        }
        s += "\n\n" + guides(AgentTree.node(for: mode), settings)
        s += """


        # Environment
        - Today is \(today()). Model: \(model).
        - The learner can attach images, PDFs and files; they review flashcards and see progress\(BoardSystem.applies(to: mode) ? ", boards" : "") and memory in the app.
        """
        if let skills = Skills.promptSection(node: AgentTree.node(for: mode), folder: folder) { s += "\n\n" + skills }
        if !settings.learnerName.isEmpty || !settings.learnerLevel.isEmpty {
            s += "\n\n# Learner\n"
            if !settings.learnerName.isEmpty { s += "- Name: \(settings.learnerName)\n" }
            if !settings.learnerLevel.isEmpty { s += "- Level / background: \(settings.learnerLevel)\n" }
        }
        if !coreMemory.isEmpty {
            s += "\n\n# Learner model (what you remember)\n(ids: #12 learner, #f3 this folder, #c7 concept — use with the `memory` tool. Relevant extra memories may appear in <context> blocks.)\n\(coreMemory)"
        } else {
            s += "\n\n# Memory\nYou have no memories of this learner yet. Learn about them naturally (goals, level, interests, preferences) and save what matters."
        }
        return s
    }
}
