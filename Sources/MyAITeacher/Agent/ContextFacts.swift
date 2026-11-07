import Foundation

/// What a summary must not lose, assembled from what the app holds rather than from what a model remembered: files this
/// lesson changed, the todo list, the course goal, the mentor project's tests, work still running, and the files the
/// agent read last (what to re-read). Appended to the summary after the model's text, so a bad summary cannot drop it.
/// Built once per compaction and stored with the summary, so the request prefix stays byte-stable until the next one.
struct ContextFacts: Sendable {
    /// Newest first (the lists that are cut keep their newest entries).
    var changedFiles: [String] = []
    var todos: [(status: String, content: String)] = []
    var goal = ""
    var project: (title: String, command: String?, last: String?)?
    var running: [String] = []
    /// Newest first.
    var recentReads: [String] = []

    /// Starts the section; a rolling summary strips everything from here before it merges the previous text.
    static let marker = "## Kept by the app (exact; not from the model)"

    /// Share of the budget the section may take, and its ceiling. A summary is ~1–2k tokens; this is a small tail of it.
    static let budgetShare = 0.04, ceiling = 1_200, floor = 200

    /// The summary text without a previous facts section (the app writes a fresh one each time).
    static func strip(_ summary: String) -> String {
        guard let r = summary.range(of: marker) else { return summary }
        return String(summary[..<r.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var isEmpty: Bool {
        changedFiles.isEmpty && todos.isEmpty && goal.isEmpty && project == nil && running.isEmpty && recentReads.isEmpty
    }

    /// The section, within `tokens`. Each list is cut by whole lines with "+N more"; every part is listed in a fixed order
    /// with no clocks or counters, so the same facts render the same bytes.
    func render(tokens: Int) -> String {
        guard !isEmpty else { return "" }
        var parts: [(String, [String])] = []
        if !goal.isEmpty { parts.append(("Goal and course state", [goal])) }
        if !todos.isEmpty { parts.append(("Todo list", todos.map { "[\($0.status)] \(MemoryText.clip($0.content, 120))" })) }
        if let p = project {
            var l = [p.title]
            if let c = p.command { l.append("test command: \(MemoryText.clip(c, 160))") }
            l.append("last test run: " + (p.last ?? "none yet"))
            parts.append(("Mentor project", l))
        }
        if !changedFiles.isEmpty { parts.append(("Files changed in this lesson (newest first)", changedFiles)) }
        if !running.isEmpty { parts.append(("Still running in the background", running)) }
        if !recentReads.isEmpty { parts.append(("Files read most recently, newest first (re-read before relying on them)", recentReads)) }
        var out = [Self.marker]
        var left = tokens - ContextPolicy.estimate(Self.marker)
        for (title, lines) in parts {
            let head = "### " + title
            left -= ContextPolicy.estimate(head) + 1
            guard left > 0 else { break }
            out.append(head)
            for (i, l) in lines.enumerated() {
                let line = "- " + l
                let cost = ContextPolicy.estimate(line) + 1
                if cost > left || i >= 40 { out.append("- … +\(lines.count - i) more"); left -= 6; break }
                out.append(line); left -= cost
            }
        }
        return out.joined(separator: "\n")
    }

    /// `summary` plus the facts section within the budget's share.
    func appended(to summary: String, budget: Int) -> String {
        let section = render(tokens: min(Self.ceiling, max(Self.floor, Int(Double(budget) * Self.budgetShare))))
        let base = Self.strip(summary)
        return section.isEmpty ? base : base + "\n\n" + section
    }
}
