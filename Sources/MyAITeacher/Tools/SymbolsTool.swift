import Foundation

/// Where things are defined: an outline of one file (functions, types, methods with their lines), or every definition
/// of a name across the project. Regular expressions per language family, through ripgrep when it is installed; it
/// finds definitions, not every mention, which is what `grep` returns for a common name.
struct SymbolsTool: Tool {
    var subAgentVariant: Tool? { self }
    let name = "symbols"
    let description = """
    Definitions, not mentions. `path`: an outline of that file — every function, method, type, class, struct, enum, \
    protocol/interface/trait and top-level constant with its line, in order (read the parts you need with `read` \
    offset/limit instead of the whole file). `query`: where a name is defined anywhere in the project (`file:line kind name`). \
    Use it before editing something whose definition you haven't seen, and to find a function's siblings.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "path": Schema.string("A file to outline."),
            "query": Schema.string("A symbol name to find the definition(s) of (whole word, case-sensitive)."),
            "kind": Schema.string("Only definitions of this kind.", enum: ["function", "type", "constant", "any"]),
        ])
    }
    func summary(_ input: JSON) -> String { input["path"]?.string ?? input["query"]?.string ?? "" }

    struct Symbol: Sendable, Equatable { var line: Int; var kind: String; var name: String; var text: String }

    /// Definition patterns by extension: (kind, regex with the name as group 1).
    static func patterns(for ext: String) -> [(String, NSRegularExpression)] {
        let p = { (k: String, s: String) -> (String, NSRegularExpression) in (k, try! NSRegularExpression(pattern: s)) }
        switch ext {
        case "swift":
            return [p("function", #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|static|class|final|override|mutating|nonisolated|convenience|required|indirect|unowned|weak|lazy|dynamic)\s+)*(?:func|init)\s*([A-Za-z_][\w]*|init)"#),
                    p("type", #"^\s*(?:@\w+(?:\([^)]*\))?\s+)*(?:(?:public|private|fileprivate|internal|open|final|indirect)\s+)*(?:struct|class|enum|protocol|actor|extension|typealias)\s+([A-Za-z_][\w.]*)"#),
                    p("constant", #"^(?:(?:public|private|fileprivate|internal|open|static|nonisolated\(unsafe\))\s+)*(?:let|var)\s+([A-Za-z_]\w*)\b"#)]
        case "py":
            return [p("function", #"^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)"#), p("type", #"^\s*class\s+([A-Za-z_]\w*)"#), p("constant", #"^([A-Z][A-Z0-9_]+)\s*(?::[^=]+)?=\s"#)]
        case "js", "jsx", "mjs", "cjs", "ts", "tsx":
            return [p("function", #"^\s*(?:export\s+)?(?:default\s+)?(?:async\s+)?function\s*\*?\s*([A-Za-z_$][\w$]*)"#),
                    p("function", #"^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s*)?(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*=>"#),
                    p("function", #"^\s+(?:public\s+|private\s+|protected\s+|static\s+|async\s+|readonly\s+|override\s+)*([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*\([^)]*\)\s*(?::\s*[^{]+)?\{\s*$"#),
                    p("type", #"^\s*(?:export\s+)?(?:default\s+)?(?:abstract\s+)?(?:class|interface|enum|namespace)\s+([A-Za-z_$][\w$]*)"#),
                    p("type", #"^\s*(?:export\s+)?type\s+([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*="#),
                    p("constant", #"^(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?!.*=>)"#)]
        case "rs":
            return [p("function", #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:async\s+)?(?:unsafe\s+)?(?:extern\s+"[^"]*"\s+)?fn\s+([A-Za-z_]\w*)"#),
                    p("type", #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:struct|enum|trait|type|union|mod)\s+([A-Za-z_]\w*)"#),
                    p("type", #"^\s*impl(?:<[^>]*>)?\s+(?:[\w:]+\s+for\s+)?([A-Za-z_][\w:]*)"#),
                    p("constant", #"^\s*(?:pub(?:\([^)]*\))?\s+)?(?:const|static)\s+(?:mut\s+)?([A-Za-z_]\w*)"#)]
        case "go":
            return [p("function", #"^func\s+(?:\([^)]*\)\s+)?([A-Za-z_]\w*)"#), p("type", #"^type\s+([A-Za-z_]\w*)"#), p("constant", #"^(?:const|var)\s+([A-Za-z_]\w*)"#)]
        case "zig":
            return [p("function", #"^\s*(?:pub\s+)?(?:export\s+)?(?:inline\s+)?fn\s+([A-Za-z_]\w*)"#),
                    p("type", #"^\s*(?:pub\s+)?const\s+([A-Z]\w*)\s*=\s*(?:struct|enum|union|opaque|extern|packed)"#),
                    p("constant", #"^\s*(?:pub\s+)?(?:const|var)\s+([a-z_]\w*)\s*(?::[^=]+)?=\s"#)]
        case "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm":
            return [p("function", #"^(?:[A-Za-z_][\w:<>*&\s]*?\s+\*?)([A-Za-z_]\w*)\s*\([^;]*\)\s*(?:const\s*)?(?:\{|$)"#),
                    p("type", #"^\s*(?:typedef\s+)?(?:struct|class|enum|union|namespace)\s+([A-Za-z_]\w*)"#),
                    p("constant", #"^#define\s+([A-Za-z_]\w*)"#)]
        case "java", "kt", "scala", "cs":
            return [p("function", #"^\s+(?:(?:public|private|protected|static|final|abstract|override|suspend|open|async|virtual|fun|def)\s+)*[\w<>\[\],\s?]+?\s+([A-Za-z_]\w*)\s*\([^)]*\)\s*(?:throws[^{]*)?\{"#),
                    p("function", #"^\s*(?:(?:public|private|protected|internal|override|open|suspend)\s+)*(?:fun|def)\s+([A-Za-z_]\w*)"#),
                    p("type", #"^\s*(?:(?:public|private|protected|internal|static|final|abstract|sealed|data|open|partial)\s+)*(?:class|interface|enum|object|record|trait|struct)\s+([A-Za-z_]\w*)"#)]
        case "rb":
            return [p("function", #"^\s*def\s+(?:self\.)?([A-Za-z_]\w*[?!=]?)"#), p("type", #"^\s*(?:class|module)\s+([A-Z][\w:]*)"#)]
        case "ex", "exs":
            return [p("function", #"^\s*defp?\s+([a-z_]\w*[?!]?)"#), p("type", #"^\s*defmodule\s+([A-Z][\w.]*)"#)]
        case "php":
            return [p("function", #"^\s*(?:(?:public|private|protected|static|abstract|final)\s+)*function\s+([A-Za-z_]\w*)"#), p("type", #"^\s*(?:abstract\s+|final\s+)?(?:class|interface|trait|enum)\s+([A-Za-z_]\w*)"#)]
        case "lua":
            return [p("function", #"^\s*(?:local\s+)?function\s+([A-Za-z_][\w.:]*)"#)]
        case "sh", "bash", "zsh":
            return [p("function", #"^\s*(?:function\s+)?([A-Za-z_]\w*)\s*\(\)\s*\{?"#)]
        case "gleam", "odin", "hs", "ml", "nim":
            return [p("function", #"^\s*(?:pub\s+)?(?:fn|proc|func|let)\s+([A-Za-z_]\w*)"#), p("type", #"^\s*(?:pub\s+)?(?:type|data|newtype)\s+([A-Za-z_]\w*)"#)]
        default:
            return [p("function", #"^\s*(?:export\s+)?(?:async\s+)?(?:function|func|fn|def|sub|proc)\s+([A-Za-z_]\w*)"#),
                    p("type", #"^\s*(?:export\s+)?(?:class|struct|enum|interface|trait|type|module)\s+([A-Za-z_]\w*)"#)]
        }
    }

    static func outline(_ text: String, ext: String) -> [Symbol] {
        let pats = patterns(for: ext)
        var out: [Symbol] = []
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = String(raw)
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty, line.count < 400 else { continue }
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("//") || t.hasPrefix("#") && ext != "c" && ext != "h" && ext != "cpp" && ext != "m" && ext != "mm" && ext != "sh" && ext != "py" && ext != "rb" { if !t.hasPrefix("#define") { continue } }
            for (kind, re) in pats {
                let ns = line as NSString
                guard let m = re.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)), m.range(at: 1).location != NSNotFound else { continue }
                let name = ns.substring(with: m.range(at: 1))
                if ["if", "for", "while", "switch", "return", "else", "catch", "guard", "defer", "new", "super", "this", "self", "import", "export", "require"].contains(name) { continue }
                out.append(Symbol(line: i + 1, kind: kind, name: name, text: String(t.prefix(140))))
                break
            }
        }
        return out
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let wanted = input["kind"]?.string ?? "any"
        if let p = input["path"]?.string, !p.isEmpty {
            let url = resolvePath(p, workspace: ctx.workspace)
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { return .error("Cannot read \(url.path).") }
            let syms = Self.outline(text, ext: url.pathExtension.lowercased()).filter { wanted == "any" || $0.kind == wanted }
            if syms.isEmpty { return ToolOutput(text: "No definitions recognised in \(url.lastPathComponent) (\(text.split(separator: "\n").count) lines). `read` it, or `grep` for a name.") }
            let lines = syms.prefix(400).map { s in "\(String(s.line).leftPad(5))  \(s.kind == "function" ? "ƒ" : s.kind == "type" ? "T" : "c")  \(s.text)" }
            return ToolOutput(text: "\(url.lastPathComponent): \(syms.count) definitions\n" + lines.joined(separator: "\n") + (syms.count > 400 ? "\n… \(syms.count - 400) more" : ""),
                              meta: ["count": .number(Double(syms.count))])
        }
        guard let q = input["query"]?.string?.trimmingCharacters(in: .whitespaces), !q.isEmpty else { return .error("Give `path` (an outline) or `query` (a name to find).") }
        let esc = NSRegularExpression.escapedPattern(for: q)
        // One pattern that most languages' definitions match: a keyword, then the name.
        // The name right after a definition keyword (one modifier, or a Go receiver, allowed between): `func (r *T) Cart`
        // and `struct Cart` yes; `func checkout(c: Cart)` no.
        let pattern = #"(?:^|\s)(?:func|fn|def|defp|function|class|struct|enum|protocol|interface|trait|type|typealias|actor|module|object|record|const|let|var|static|val|impl|extension|namespace|macro|sub|proc)\s+(?:(?:mut|unsafe|async|pub|self\.|\*?\([^)]{0,40}\))\s+)?"# + esc + #"\b"#
        var hits: [String] = []
        if let rg = ProcessRunner.which("rg") {
            let r = await ProcessRunner.run(rg, ["-n", "--no-heading", "--color=never", "--max-columns=200", "-g", "!node_modules", "-g", "!.build", "-g", "!dist", "-g", "!target", "-e", pattern, ctx.workspace.path], timeout: 30)
            hits = r.stdout.split(separator: "\n").map(String.init)
        } else {
            let r = await ProcessRunner.run("/usr/bin/grep", ["-rnE", "--exclude-dir=.git", "--exclude-dir=node_modules", "--exclude-dir=.build", "-e", pattern, ctx.workspace.path], timeout: 30)
            hits = r.stdout.split(separator: "\n").map(String.init)
        }
        hits = hits.map { $0.hasPrefix(ctx.workspace.path + "/") ? String($0.dropFirst(ctx.workspace.path.count + 1)) : $0 }
            .filter { line in
                // Keep definitions whose kind matches, judged by the line's own text.
                guard wanted != "any" else { return true }
                let l = line.lowercased()
                switch wanted {
                case "function": return l.contains("func") || l.contains("fn ") || l.contains("def ") || l.contains("function") || l.contains("proc ") || l.contains("sub ")
                case "type": return ["class ", "struct ", "enum ", "protocol ", "interface ", "trait ", "type ", "typealias ", "actor ", "module ", "record "].contains { l.contains($0) }
                default: return ["const ", "let ", "var ", "static ", "val "].contains { l.contains($0) }
                }
            }
        if hits.isEmpty { return ToolOutput(text: "No definition of `\(q)` found. `grep` finds its uses; the name may be defined dynamically or under another spelling.") }
        return ToolOutput(text: "\(hits.count) definition\(hits.count == 1 ? "" : "s") of `\(q)`:\n" + hits.prefix(60).joined(separator: "\n") + (hits.count > 60 ? "\n… \(hits.count - 60) more" : ""),
                          meta: ["count": .number(Double(hits.count))])
    }
}
