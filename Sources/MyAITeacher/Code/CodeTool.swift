import Foundation

/// Code research over the folder's index (`CodeIndex`): search by meaning, definitions, uses and callers, what a function
/// calls, a file's imports and neighbours, and a map of the repository. `grep` stays for exact text.
struct CodeTool: Tool {
    var subAgentVariant: Tool? { self }
    let name = "code"
    let description = """
    Research the project's code through its index (definitions, references, imports, a usage graph; incremental, so it \
    is always current). action: find — the definitions that best answer `query` in words or names ("where are retries \
    backed off", "parse config"), ranked; def — where `name` is defined; refs — every use of `name`, grouped by the \
    function it's in; callers — the functions that use `name`; callees — what function `name` calls or builds on; \
    outline — `path`'s definitions with their lines; related — the files `path` uses and that use it; map — the \
    repository's most central files and their main definitions (start here in an unfamiliar codebase). Use `grep` only \
    for exact text (strings, error messages, config keys).
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "action": Schema.string("What to look up.", enum: ["find", "def", "refs", "callers", "callees", "outline", "related", "map"]),
            "query": Schema.string("find: what you're looking for, in words or names."),
            "name": Schema.string("def, refs, callers, callees: the symbol."),
            "path": Schema.string("outline, related: a file (relative to the folder)."),
        ], required: ["action"])
    }
    func summary(_ input: JSON) -> String {
        let a = input["action"]?.string ?? ""
        return [a, input["query"]?.string ?? input["name"]?.string ?? input["path"]?.string ?? ""].filter { !$0.isEmpty }.joined(separator: " ")
    }
    func timeout(_ input: JSON) -> Double? { 120 }   // the first query of a large repository builds its index

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let action = try input.req("action")
        let index = CodeIndex.of(ctx.workspace)
        let t0 = Date()
        let built = await index.refresh()
        let note = built.changed > 200 ? "(indexed \(built.files) files in \(String(format: "%.1f", Date().timeIntervalSince(t0))) s)\n" : ""
        func rel(_ p: String) -> String { p }
        switch action {
        case "find":
            let q = try input.req("query")
            let hits = await index.search(q)
            guard !hits.isEmpty else { return ToolOutput(text: note + "Nothing in the index matches “\(q)”. Try other words, `grep` for exact text, or `code` action=map.") }
            let lines = hits.map { h -> String in
                if let s = h.sym {
                    let at = h.line.flatMap { $0 > s.line ? " — best match around line \($0)" : nil } ?? ""
                    return "\(h.path):\(s.line)  \(s.kind == "function" ? "ƒ" : s.kind == "type" ? "T" : "c") \(s.text)\(at)"
                }
                return "\(h.path)  (file: \(h.matched.joined(separator: ", ")))"
            }
            return ToolOutput(text: note + "Best matches for “\(q)” (read them with `read` offset/limit):\n" + lines.joined(separator: "\n"), meta: ["count": .number(Double(hits.count))])
        case "def":
            let n = try input.req("name")
            let d = await index.definitions(n)
            guard !d.isEmpty else { return ToolOutput(text: note + "No definition of `\(n)` in the index. `code` action=find with words for it, or `grep`.") }
            return ToolOutput(text: note + d.prefix(40).map { "\($0.path):\($0.sym.line)-\($0.sym.end)  \($0.sym.text)" }.joined(separator: "\n"))
        case "refs", "callers":
            let n = try input.req("name")
            let uses = await Self.uses(n, index: index, root: ctx.workspace)
            guard !uses.isEmpty else { return ToolOutput(text: note + "No uses of `\(n)` found outside its definition.") }
            if action == "callers" {
                var seen = Set<String>(), out: [String] = []
                for u in uses { let k = u.path + ":" + (u.within?.name ?? "(top level)"); if seen.insert(k).inserted { out.append("\(u.path):\(u.within?.line ?? u.line)  \(u.within?.text ?? "(top level)")") } }
                return ToolOutput(text: note + "\(out.count) place\(out.count == 1 ? "" : "s") use `\(n)`:\n" + out.prefix(60).joined(separator: "\n"))
            }
            var byFile: [String: [String]] = [:], order: [String] = []
            for u in uses.prefix(150) {
                if byFile[u.path] == nil { order.append(u.path) }
                byFile[u.path, default: []].append("  \(u.line)  \(u.within.map { "in \($0.name): " } ?? "")\(u.text)")
            }
            return ToolOutput(text: note + "\(uses.count) use\(uses.count == 1 ? "" : "s") of `\(n)` in \(order.count) file\(order.count == 1 ? "" : "s"):\n"
                              + order.map { $0 + "\n" + byFile[$0]!.joined(separator: "\n") }.joined(separator: "\n"))
        case "callees":
            let n = try input.req("name")
            guard let d = await index.definitions(n).first else { return .error("No definition of `\(n)` in the index.") }
            let c = await index.callees(d.path, d.sym)
            guard !c.isEmpty else { return ToolOutput(text: note + "`\(n)` (\(d.path):\(d.sym.line)) uses nothing else defined in this project.") }
            return ToolOutput(text: note + "`\(n)` (\(d.path):\(d.sym.line)) uses:\n" + c.prefix(50).map { e in
                "  \(e.name) — " + e.at.prefix(2).map { "\($0.path):\($0.sym.line)" }.joined(separator: ", ")
            }.joined(separator: "\n"))
        case "outline":
            let p = try input.req("path")
            guard let f = await index.entry(Self.relative(p, root: ctx.workspace)) else { return .error("\(p) isn't an indexed source file.") }
            let uses = await index.neighbours(f.path)
            var s = "\(f.path): \(f.symbols.count) definitions\n" + f.symbols.prefix(300).map { "\(String($0.line).leftPad(5))-\($0.end)  \($0.kind == "function" ? "ƒ" : $0.kind == "type" ? "T" : "c")  \($0.text)" }.joined(separator: "\n")
            if !f.imports.isEmpty { s += "\nImports: " + f.imports.prefix(20).joined(separator: ", ") }
            if !uses.usedBy.isEmpty { s += "\nUsed by: " + uses.usedBy.prefix(8).map(\.0).joined(separator: ", ") }
            return ToolOutput(text: s)
        case "related":
            let p = Self.relative(try input.req("path"), root: ctx.workspace)
            guard await index.entry(p) != nil else { return .error("\(p) isn't an indexed source file.") }
            let n = await index.neighbours(p)
            return ToolOutput(text: "\(p)\nUses: " + (n.uses.isEmpty ? "nothing else here" : n.uses.prefix(12).map(\.0).joined(separator: ", "))
                              + "\nUsed by: " + (n.usedBy.isEmpty ? "nothing here" : n.usedBy.prefix(12).map(\.0).joined(separator: ", ")))
        case "map":
            let m = await index.map()
            let st = await index.stats
            guard !m.isEmpty else { return ToolOutput(text: "No source files indexed in this folder.") }
            return ToolOutput(text: note + "\(st.files) files, \(st.symbols) definitions. Most central (used by the most others):\n" + m.map { e in
                "\(e.path)\n" + e.symbols.map { "    \($0.line)  \($0.text)" }.joined(separator: "\n")
            }.joined(separator: "\n"))
        default:
            return .error("action is one of find, def, refs, callers, callees, outline, related, map.")
        }
    }

    static func relative(_ p: String, root: URL) -> String {
        let full = resolvePath(p, workspace: root).standardizedFileURL.resolvingSymlinksInPath().path
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path + "/"
        return full.hasPrefix(base) ? String(full.dropFirst(base.count)) : p
    }

    struct Use: Sendable { var path: String; var line: Int; var text: String; var within: CodeIndex.Sym? }

    /// Every whole-word use of `name` (ripgrep, so it is exact and current), each with the definition it sits in;
    /// definitions of the name itself left out.
    static func uses(_ name: String, index: CodeIndex, root: URL) async -> [Use] {
        guard name.range(of: #"^[A-Za-z_][\w]*$"#, options: .regularExpression) != nil else { return [] }
        var lines: [String] = []
        if let rg = ProcessRunner.which("rg") {
            // An explicit "." — without a path, ripgrep with a piped stdin searches stdin instead of the folder.
            lines = await ProcessRunner.run(rg, ["-n", "-w", "-F", "--no-heading", "--color=never", "--max-columns=240", "-g", "!.teacher", name, "."], cwd: root, timeout: 30)
                .stdout.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
        } else {
            lines = await ProcessRunner.run("/usr/bin/grep", ["-rnwF", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.teacher", name, "."], cwd: root, timeout: 30)
                .stdout.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
        }
        let defs = await Set(index.definitions(name).map { "\($0.path):\($0.sym.line)" })
        var out: [Use] = []
        for l in lines {
            let parts = l.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let n = Int(parts[1]) else { continue }
            let path = String(parts[0])
            if defs.contains("\(path):\(n)") { continue }
            out.append(Use(path: path, line: n, text: parts[2].trimmingCharacters(in: .whitespaces), within: await index.enclosing(path, line: n)))
        }
        return out
    }
}
