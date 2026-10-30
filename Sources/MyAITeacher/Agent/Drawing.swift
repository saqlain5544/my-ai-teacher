import Foundation

/// The drawing set: every kind of figure an agent can put in a reply (the fences the transcript draws: ```mermaid,
/// ```plot, ```chart, ```svg, ```visual…, and the libraries a ```visual loads: three.js, d3, Chart.js, Matter.js, KaTeX),
/// each with a reference: its exact format, a working example, its limits. The prompt names the kinds in one line (the
/// root guide); a reference reaches the agent only when it asks (`draw`), so a lesson pays only for the formats it uses.
///
/// References are `Resources/drawing/<agent tree node>/<kind>.md` (front matter `name`, `summary`, and optionally `title`,
/// `aliases`, `needs`, `order`; then Markdown) and follow the tree like skills: an agent has the kinds of the nodes on its
/// path, so the code mentor's code views never reach a tutor. A kind is the component of the same name (`needs` names
/// another, or `none`), offered only where the page draws it. `guide.md` says how to choose. Every example fence in a
/// reference is drawn by the renderer suite (`window.__drawingExamples`), so a format that drifts fails a test.
struct DrawingKind: Equatable, Sendable {
    let name: String
    let title: String
    let summary: String
    let aliases: [String]
    /// The component the page must draw for this kind (nil: none, as for ```svg); a library names its host, `visual`.
    let needs: String?
    let node: String
    let order: Int
    let body: String

    /// A library for another kind's fence (three.js for ```visual), rather than a fence of its own.
    var isLibrary: Bool { needs.map { $0 != name } ?? false }
    var label: String { isLibrary ? "`\(name)` (in a ```\(needs ?? ""))" : "```\(name)" }

    /// The reference's example fences, as written (each must render as it stands).
    var examples: [(lang: String, fence: String)] {
        var out: [(String, String)] = [], open: (lang: String, lines: [String])?
        for line in body.components(separatedBy: "\n") {
            if let o = open {
                if line.trimmingCharacters(in: .whitespaces) == "```" { out.append((o.lang, (["```" + o.lang] + o.lines + ["```"]).joined(separator: "\n"))); open = nil }
                else { open?.lines.append(line) }
            } else if line.hasPrefix("```") {
                let lang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                if lang.range(of: #"^[a-z0-9-]+$"#, options: .regularExpression) != nil { open = (lang, []) }
            }
        }
        return out
    }
}

enum Drawing {
    struct Library: Sendable {
        let guide: String
        let kinds: [DrawingKind]
    }

    static let shipped = load(AppPaths.drawingResources)

    /// What every reference starts with.
    static let rules = "Drawings are fenced blocks in your reply, never tool calls. JSON must be valid (double quotes; no comments or trailing commas). A drawing that fails shows the learner its error, and the error reaches you with their next message."

    static func load(_ dir: URL) -> Library {
        let fm = FileManager.default
        var kinds: [DrawingKind] = []
        for node in ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted() where AgentTree.byID[node] != nil {
            let folder = dir.appendingPathComponent(node)
            for file in ((try? fm.contentsOfDirectory(atPath: folder.path)) ?? []).sorted() where file.hasSuffix(".md") {
                guard let text = try? String(contentsOf: folder.appendingPathComponent(file), encoding: .utf8) else { continue }
                let (meta, body) = Skills.frontMatter(text)
                let name = (meta["name"] ?? String(file.dropLast(3))).lowercased()
                guard let summary = meta["summary"], !summary.isEmpty else { continue }
                let needs = meta["needs"].map { $0.lowercased() } ?? name
                kinds.append(DrawingKind(name: name, title: meta["title"] ?? "```\(name)", summary: summary,
                                         aliases: (meta["aliases"] ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }.filter { !$0.isEmpty },
                                         needs: needs == "none" ? nil : needs, node: node, order: Int(meta["order"] ?? "") ?? 100,
                                         body: body.trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
        let guide = (try? String(contentsOf: dir.appendingPathComponent("guide.md"), encoding: .utf8)) ?? ""
        return Library(guide: guide.trimmingCharacters(in: .whitespacesAndNewlines), kinds: kinds)
    }

    /// The kinds an agent has: its path's, where its page draws what they need; root first, then in reference order.
    static func kinds(_ node: String, in lib: Library = shipped) -> [DrawingKind] {
        let path = AgentTree.path(node).map(\.id), drawn = Set(AgentTree.components(node))
        let depth = { (k: DrawingKind) in path.firstIndex(of: k.node) ?? 0 }
        return lib.kinds.filter { path.contains($0.node) && ($0.needs.map(drawn.contains) ?? true) }
            .sorted { (depth($0), $0.order, $0.name) < (depth($1), $1.order, $1.name) }
    }

    /// The kind a word names, as models write it ("```mermaid", "Three.js", "chart.js"): by name, then by alias.
    static func find(_ word: String, in kinds: [DrawingKind]) -> DrawingKind? {
        let w = word.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "`'\"").union(.whitespacesAndNewlines))
        return kinds.first { $0.name == w } ?? kinds.first { $0.aliases.contains(w) }
    }

    /// How to choose, then each kind this agent has in one line (the answer to `draw` with no kinds).
    static func catalog(_ node: String, in lib: Library = shipped) -> String {
        let mine = kinds(node, in: lib)
        var s = lib.guide + "\n\n**The kinds here** (`draw` with their names gives each one's format, an example and its limits):"
        var group = ""
        for k in mine {
            if k.node != group, k.node != "root" { s += "\n\n\(Instructions.nodeTitle(k.node)):" }
            group = k.node
            s += "\n- \(k.label): \(k.summary)"
        }
        return s
    }

    /// The references for the kinds the agent named (after the rules they share), or what went wrong.
    static func reference(_ words: [String], node: String, in lib: Library = shipped) -> ToolOutput {
        let mine = kinds(node, in: lib)
        var found: [DrawingKind] = [], notes: [String] = []
        for w in words {
            if let k = find(w, in: mine) { if !found.contains(k) { found.append(k) }; continue }
            if let other = find(w, in: lib.kinds) {
                notes.append("`\(other.name)` isn't drawn in this lesson (it belongs to the \(Instructions.nodeTitle(other.node).lowercased())).")
            } else {
                notes.append("No drawing kind “\(w)”.")
            }
        }
        if found.isEmpty {
            return .error((notes + ["Kinds here: " + mine.map(\.name).joined(separator: ", ") + ". (`draw` with no kinds explains how to choose.)"]).joined(separator: " "))
        }
        let refs = found.map { "## \($0.title)\n\($0.summary)\n\n\($0.body)" }
        let text = ([rules] + refs + (notes.isEmpty ? [] : [notes.joined(separator: " ")])).joined(separator: "\n\n")
        return ToolOutput(text: text, meta: ["kinds": .array(found.map { .string($0.name) })])
    }
}

/// The drawing set's references on demand (Claude Code's progressive disclosure: the prompt lists, this tool details).
struct DrawTool: Tool {
    var subAgentVariant: Tool? { self }
    let name = "draw"
    let description = "Drawing formats on demand: each kind you name comes back with its exact fence format, a working example and its limits; none gives the catalog and how to choose."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object(["kinds": Schema.array(["type": "string"], "e.g. [\"mermaid\", \"chart\"] or [\"visual\", \"three\"]")])
    }
    func summary(_ input: JSON) -> String { Self.words(input).joined(separator: ", ") }
    func timeout(_ input: JSON) -> Double? { 10 }

    /// The kinds asked for, however the model put them: an array, a comma list, or under another name.
    static func words(_ input: JSON) -> [String] {
        for key in ["kinds", "kind", "names", "name", "topics", "topic"] {
            if let a = input[key]?.array { return a.compactMap(\.string).flatMap(split) }
            if let s = input[key]?.string { return split(s) }
        }
        return []
    }
    private static func split(_ s: String) -> [String] {
        s.split { $0 == "," || $0 == ";" || $0.isWhitespace }.map(String.init).filter { !$0.isEmpty }
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let words = Self.words(input).filter { !["all", "catalog", "list", "help"].contains($0.lowercased()) }
        if words.isEmpty { return ToolOutput(text: Drawing.catalog(ctx.agentNode), meta: ["kinds": .array([])]) }
        return Drawing.reference(words, node: ctx.agentNode)
    }
}
