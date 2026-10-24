import Foundation

/// Every agent in the app is a node in one tree. A node declares what it adds; an agent gets everything on its path to
/// the root, never what its children add:
///
///     root ── core for every agent: files, batch edit, web, sub-agents, the core visualisations
///     ├── teacher ── teaching: questions and quizzes, the course board, learner memory, math, code to show things
///     │   ├── tutor · socratic · explain · quiz · exam · eli5 · research   (their instructions differ, not their tools)
///     │   ├── language ── the language mentor: language and vocab tools; listening, gloss, dialogue, conjugation, tones
///     │   └── code-mentor ── projects: tests and reviews, code search, symbols, diagnostics, source; memory-layout and file-tree views
///     └── engineer ── the code agent: shell and jobs, code search, symbols, diagnostics, source, tests, project memory, browser and Mac control
///
/// Per node there are three sets: tools sent with every request (`core`), tools loaded at runtime with `load_tools`
/// (`deferred`, one line each in the prompt, so context stays small), and rendering components (fences the agent may
/// write and the page will draw). A node's `guide` is the part of the app guide that explains what it adds.
struct AgentNode: Sendable {
    let id: String
    let parent: String?
    var core: [String] = []
    var deferred: [String] = []
    var components: [String] = []
    var guide: String = ""
}

enum AgentTree {
    static let nodes: [AgentNode] = [
        AgentNode(id: "root", parent: nil,
                  core: ["read", "write", "edit", "ls", "web_search", "web_fetch", "task", "load_tools"],
                  deferred: ["agents", "visual"],
                  components: ["mermaid", "math", "chart", "plot", "timeline", "steps", "cards", "compare", "kv", "json", "csv", "visual"],
                  guide: Guides.root),
        AgentNode(id: "teacher", parent: "root",
                  core: ["ask_learner", "math", "run_code", "bash", "memory", "lesson_plan"],
                  deferred: ["quiz", "mastery", "flashcards", "todo_write", "bash_jobs", "language", "vocab", "source"],
                  components: ["vocab", "practice", "problem"],
                  guide: Guides.teacher),
        AgentNode(id: "tutor", parent: "teacher"),
        AgentNode(id: "socratic", parent: "teacher"),
        AgentNode(id: "explain", parent: "teacher"),
        AgentNode(id: "quiz", parent: "teacher"),
        AgentNode(id: "exam", parent: "teacher"),
        AgentNode(id: "eli5", parent: "teacher"),
        AgentNode(id: "research", parent: "teacher"),
        AgentNode(id: "language", parent: "teacher",
                  core: ["language", "vocab"],
                  components: ["listen", "gloss", "dialogue", "conjugation", "tones"]),
        AgentNode(id: "code-mentor", parent: "teacher",
                  core: ["run_tests", "project_tests", "project_review", "symbols", "diagnostics", "source"],
                  deferred: ["glob", "grep"],
                  components: ["layout", "tree"],
                  guide: Guides.codeMentor),
        AgentNode(id: "engineer", parent: "root",
                  core: ["bash", "bash_jobs", "run_code", "glob", "grep", "symbols", "source", "diagnostics", "run_tests", "todo_write", "agents", "ask_learner", "project_memory",
                         "browser", "mac", "computer"],
                  components: ["layout", "tree"],
                  guide: Guides.engineer),
    ]

    static let byID: [String: AgentNode] = Dictionary(uniqueKeysWithValues: nodes.map { ($0.id, $0) })

    /// The node an agent runs as.
    static func node(for mode: TeachingMode) -> String {
        switch mode {
        case .agent: "engineer"
        case .code: "code-mentor"
        default: mode.rawValue
        }
    }

    /// Root first, then down to `id`.
    static func path(_ id: String) -> [AgentNode] {
        var out: [AgentNode] = [], cur: String? = id
        while let c = cur, let n = byID[c] { out.insert(n, at: 0); cur = n.parent }
        return out
    }

    /// What an agent inherits, in path order without repeats. A tool core somewhere on the path is never also deferred.
    static func core(_ id: String) -> [String] { unique(path(id).flatMap(\.core)) }
    static func deferred(_ id: String) -> [String] { let c = Set(core(id)); return unique(path(id).flatMap(\.deferred)).filter { !c.contains($0) } }
    static func components(_ id: String) -> [String] { unique(path(id).flatMap(\.components)) }
    static func guides(_ id: String) -> [String] { path(id).map(\.guide).filter { !$0.isEmpty } }

    private static func unique(_ xs: [String]) -> [String] { var seen = Set<String>(); return xs.filter { seen.insert($0).inserted } }
}

/// Each node's part of the app guide. Short: the tools' own descriptions carry the details.
enum Guides {
    static let root = """
    # The app
    - Replies render Markdown with LaTeX (`$…$`, `$$…$$`, `\\ce{}`) and callouts (`> [!NOTE|TIP|WARNING|EXAMPLE|DEFINITION|THEOREM] title`). Fences: ```mermaid (quote any label with brackets, parentheses, quotes or `<br/>`: `A["cwnd × β (0.7)"]`, `A -->|"loss"| B`); ```plot {"functions":["sin(x)"],"x":[-6,6]}; ```chart {"type":"bar|line|area|pie|scatter","labels":[…],"series":[{"name":"…","data":[…]}]}; ```timeline [{"date","title","text"}]; ```steps [{"title","text"}] (`{"reveal":true,"steps":[…]}` reveals a worked example step by step); ```compare {"columns":[…],"rows":[[label,…]]}; ```visual — self-contained HTML/JS, offline, first line `<!-- title: …; libs: three, d3, chart, matter; height: 360 -->`, no reasoning inside it; it must run as written (declare before use, no name clashes with element ids) and read on light and dark backgrounds. JSON must be valid. Use them freely wherever they make an idea clearer — several in one reply is fine.
    - Tools: files `read`, `write`, `edit` (several changes at once with `edits`), `ls` (relative paths are this folder); `web_search`, `web_fetch`; `task` for sub-agents. More, after `load_tools` with their names:
    {more_tools}
    - Call independent tools in parallel; don't narrate tool mechanics. A `<background-agent>` message is a sub-agent's report, not the person you're working with.
    """

    static let teacher = """
    # Teaching tools
    - Fences: ```vocab [{"term","lang","reading","meaning","example"}]; ```practice [{"q","a","hint"}] (self-check cards); ```problem {"q","hints":[…],"solution","answer","concept","subject"} (attempt first: hints and solution stay hidden until they try; their attempt is their next message).
    - `ask_learner` (questions that wait for the learner; `graded: true` is a quiz — give each question `answer`, `concept`, `hints`, and `misconceptions` for wrong options; no giveaways: the right option is no longer or more precise than the others); `math`, `run_code`, `bash`; `memory` for durable facts about the learner (goals, level, preferences, recurring misconceptions), never one-off details; `lesson_plan` for the course board.
    """

    static let codeMentor = """
    # Code mentor tools
    - `run_tests` runs the project's tests (`.teacher/tests`, or a command) and shows the learner a pass/fail card they can re-run themselves; use it to check their work, not `bash`.
    - Fences for code: ```layout {"name","size","align","fields":[{"name","type","offset","size"}]} draws a type's memory layout (fields, padding, alignment) — check the numbers with the real compiler first; ```tree ["src/", "  main.zig  # entry point", …] draws a project's file tree with notes.
    """

    static let engineer = """
    # Engineering tools
    - `run_tests` runs the project's tests and reports each pass and failure; `glob`/`grep` search code; `bash` runs commands. Fences for code: ```layout (a type's memory layout) and ```tree (a file tree with notes). Draw what has structure (call flows, state machines, architectures) instead of describing it.
    """
}
