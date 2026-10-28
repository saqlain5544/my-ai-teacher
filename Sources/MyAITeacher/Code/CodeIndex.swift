import Foundation
import CryptoKit

/// A folder's code, indexed and graphed for an agent's research (`CodeTool`): what grep can't tell it.
///
/// Per file: its definitions (with the lines they span), what it imports, and the identifiers it uses. From those, for
/// the whole folder: where each name is defined, which files use which (a file uses another when it names something
/// only that file defines, or imports it), and how central each file is (PageRank over that graph, Aider's repo-map
/// idea). Search ranks symbol-sized chunks by BM25 over their words (identifiers split: `parseHTTPHeader` → parse, http,
/// header), boosted where the name or path matches and by the file's centrality: a question in words finds the
/// definitions that answer it. No embeddings: the on-device sentence model is slow per chunk and blind to code.
///
/// Built on first use, then incremental: each query re-lists the folder (gitignore-aware) and re-reads only files whose
/// size or date changed. Saved between launches in the app's support folder (never in the project).
actor CodeIndex {
    struct Sym: Codable, Sendable, Hashable {
        var name: String
        var kind: String
        var line: Int
        var end: Int
        var text: String
        /// The chunk's words (split identifiers, comments), distinct and lowercased, for search.
        var terms: [String]
        /// A long definition's later stretches (40 lines each, overlapping), searchable on their own: what a big function
        /// does near its end is found at that line, not lost past the first chunk.
        var windows: [Window] = []
    }
    struct Window: Codable, Sendable, Hashable { var line: Int; var terms: [String] }
    struct FileEntry: Codable, Sendable {
        var path: String
        var mtime: Double
        var size: Int
        var symbols: [Sym]
        var imports: [String]
        /// Identifiers it uses, with counts (bounded).
        var idents: [String: Int]
        /// Words of its first lines and path (module docs, the file's purpose).
        var head: [String]
    }
    private struct Saved: Codable { var version: Int; var files: [String: FileEntry] }
    static let version = 6

    let root: URL
    private(set) var files: [String: FileEntry] = [:]
    // Derived, recomputed when files change.
    private(set) var defs: [String: [(path: String, sym: Sym)]] = [:]
    private(set) var rank: [String: Double] = [:]
    private(set) var edges: [String: [String: Double]] = [:]      // file → files it uses, weighted
    private var df: [String: Int] = [:]
    private var chunkCount = 0
    private var loaded = false
    private var dirty = true

    static let maxFiles = 20_000
    static let maxBytes = 600_000
    static let sourceExtensions: Set<String> = ["swift", "py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "rs", "go", "zig", "c", "h", "cpp", "cc", "cxx",
                                                "hpp", "m", "mm", "java", "kt", "scala", "cs", "rb", "ex", "exs", "php", "lua", "sh", "bash", "gleam",
                                                "odin", "hs", "ml", "nim", "dart", "vue", "svelte", "sql", "proto"]

    private static let shared = Lock<[String: CodeIndex]>([:])
    /// The index of `folder` (one per folder for the app's life).
    static func of(_ folder: URL) -> CodeIndex {
        let key = folder.standardizedFileURL.resolvingSymlinksInPath().path
        return shared.with { all in
            if let i = all[key] { return i }
            let i = CodeIndex(root: URL(fileURLWithPath: key)); all[key] = i; return i
        }
    }

    init(root: URL) { self.root = root }

    private var cacheURL: URL {
        let h = SHA256.hash(data: Data(root.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return AppPaths.support.appendingPathComponent("code-index/\(h).json")
    }

    // MARK: Building

    /// Brings the index up to date with the folder: new and changed files read, deleted ones dropped.
    @discardableResult
    func refresh() async -> (files: Int, changed: Int) {
        if !loaded {
            loaded = true
            if let d = try? Data(contentsOf: cacheURL), let s = try? JSONDecoder().decode(Saved.self, from: d), s.version == Self.version { files = s.files }
        }
        let listed = await Self.list(root)
        var changed = 0
        let present = Set(listed.map(\.path))
        for gone in files.keys where !present.contains(gone) { files[gone] = nil; changed += 1 }
        for f in listed {
            if let e = files[f.path], e.mtime == f.mtime, e.size == f.size { continue }
            guard let text = try? String(contentsOf: root.appendingPathComponent(f.path), encoding: .utf8) else { files[f.path] = nil; continue }
            files[f.path] = Self.index(text, path: f.path, mtime: f.mtime, size: f.size)
            changed += 1
        }
        if changed > 0 || dirty {
            derive()
            dirty = false
            if changed > 0 { save() }
        }
        return (files.count, changed)
    }

    private func save() {
        let url = cacheURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? JSONEncoder().encode(Saved(version: Self.version, files: files)) { try? d.write(to: url, options: .atomic) }
    }

    /// Source files under `root`, relative, with their date and size: ripgrep's listing (it honours .gitignore), else a walk
    /// that skips the usual build and dependency folders.
    static func list(_ root: URL) async -> [(path: String, mtime: Double, size: Int)] {
        var paths: [String] = []
        if let rg = ProcessRunner.which("rg") {
            let r = await ProcessRunner.run(rg, ["--files", "--hidden", "-g", "!.git", "-g", "!.teacher", "."], cwd: root, timeout: 30)
            paths = r.stdout.split(separator: "\n").map { $0.hasPrefix("./") ? String($0.dropFirst(2)) : String($0) }
        }
        if paths.isEmpty { paths = walk(root) }
        var out: [(String, Double, Int)] = []
        // Vendored and minified code is someone else's: it would answer every question with noise.
        let foreign = ["/vendor/", "vendor/", "/third_party/", "/node_modules/", "/Pods/", "/.build/", "/dist/"]
        for p in paths where sourceExtensions.contains((p as NSString).pathExtension.lowercased())
            && !p.contains(".min.") && !foreign.contains(where: { p.hasPrefix($0) || p.contains($0) }) {
            guard let a = try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(p).path),
                  let size = a[.size] as? Int, size <= maxBytes else { continue }
            out.append((p, (a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0, size))
            if out.count >= maxFiles { break }
        }
        return out
    }

    /// A doc comment, comment or attribute line (what sits above a definition and says what it is).
    static func isCommentOrAttribute(_ line: Substring) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        return t.hasPrefix("//") || t.hasPrefix("#") && !t.hasPrefix("#include") || t.hasPrefix("/*") || t.hasPrefix("*") || t.hasPrefix("--")
            || t.hasPrefix("@") || t.hasPrefix("\"\"\"") || t.hasPrefix("///") || t.hasPrefix(";;")
    }

    /// Without ripgrep: a walk that skips the usual build and dependency folders.
    private static func walk(_ root: URL) -> [String] {
        let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", "target", "DerivedData", "__pycache__", ".venv", "venv", ".teacher", "zig-out", ".zig-cache"]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants]) else { return [] }
        let base = root.path.count + 1
        var paths: [String] = []
        while let u = e.nextObject() as? URL {
            if skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { continue }
            let p = u.resolvingSymlinksInPath().path
            if p.count > base { paths.append(String(p.dropFirst(base))) }
            if paths.count > maxFiles * 2 { break }
        }
        return paths
    }

    /// One file's entry: definitions with their spans and words, imports, identifiers.
    static func index(_ text: String, path: String, mtime: Double, size: Int) -> FileEntry {
        let ext = (path as NSString).pathExtension.lowercased()
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        let outline = SymbolsTool.outline(text, ext: ext)
        var syms: [Sym] = []
        for (i, s) in outline.enumerated() {
            // A definition runs to the next one at its indentation or shallower (methods end at the next method).
            let indent = lines[s.line - 1].prefix { $0 == " " || $0 == "\t" }.count
            var end = lines.count
            for t in outline[(i + 1)...] {
                let ti = lines[t.line - 1].prefix { $0 == " " || $0 == "\t" }.count
                if ti <= indent { end = t.line - 1; break }
            }
            end = min(end, s.line + 400)
            // Its chunk: the doc comment above it, then its own lines. A type's own lines stop at its first member (each
            // member is a chunk of its own): with every member's code, a big class matched every question.
            var top = s.line - 1
            while top > 0, top > s.line - 14, Self.isCommentOrAttribute(lines[top - 1]) { top -= 1 }
            var stop = min(lines.count, end)
            if s.kind == "type", let member = outline[(i + 1)...].first(where: { $0.line <= end }) { stop = min(stop, member.line - 1) }
            let span = max(top + 1, stop)
            let first = min(span, top + 50)
            let terms = Array(Set(words(lines[top..<first].joined(separator: "\n")) + words(s.name)))
            var windows: [Window] = []
            var w = max(top, first - 10)
            while first < span, w < span - 5 && windows.count < 20 {
                let e = min(span, w + 40)
                windows.append(Window(line: w + 1, terms: Array(Set(words(lines[w..<e].joined(separator: "\n")) + words(s.name))).sorted()))
                w += 30
            }
            syms.append(Sym(name: s.name, kind: s.kind, line: s.line, end: end, text: s.text, terms: terms.sorted(), windows: windows))
        }
        var idents: [String: Int] = [:]
        for m in identRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            let w = String(text[r])
            if w.count >= 3, !keywords.contains(w) { idents[w, default: 0] += 1 }
        }
        if idents.count > 3000 { idents = Dictionary(uniqueKeysWithValues: idents.sorted { $0.value > $1.value }.prefix(3000).map { ($0.key, $0.value) }) }
        // The file as a whole: its path and its header comment (what the file is for), not its code: that's in its chunks.
        let header = lines.prefix(40).drop { $0.trimmingCharacters(in: .whitespaces).isEmpty }.prefix { isCommentOrAttribute($0) || $0.trimmingCharacters(in: .whitespaces).isEmpty }
        let head = Array(Set(words(header.joined(separator: "\n")) + words(path))).sorted()
        return FileEntry(path: path, mtime: mtime, size: size, symbols: syms, imports: imports(text, ext: ext), idents: idents, head: head)
    }

    static let identRegex = try! NSRegularExpression(pattern: #"[A-Za-z_][A-Za-z0-9_]*"#)
    static let keywords: Set<String> = ["the", "and", "for", "return", "func", "function", "def", "let", "var", "const", "class", "struct", "enum", "import",
        "from", "self", "this", "true", "false", "nil", "null", "None", "True", "False", "else", "while", "case", "break", "continue", "static", "public",
        "private", "fileprivate", "internal", "void", "int", "string", "String", "Int", "Bool", "bool", "new", "try", "catch", "throw", "throws", "async",
        "await", "guard", "where", "with", "not", "pub", "mut", "impl", "use", "mod", "export", "default", "type", "interface", "extends", "implements",
        "package", "fun", "val", "end", "then", "elif", "lambda", "yield", "pass", "assert", "defer", "switch", "inline", "comptime", "undefined", "usize",
        "u8", "i32", "i64", "u32", "u64", "f64", "f32", "char", "auto", "unsigned", "signed", "long", "short", "double", "float", "override", "final"]

    /// Words for search: identifiers split at case changes and underscores, lowercased, stemmed lightly; stopwords out.
    static func words(_ text: String) -> [String] {
        var out: [String] = []
        for m in identRegex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let r = Range(m.range, in: text) else { continue }
            for part in split(String(text[r])) where part.count >= 2 && !stop.contains(part) { out.append(stem(part)) }
        }
        return out
    }
    static let stop: Set<String> = ["the", "and", "for", "to", "of", "in", "is", "it", "if", "on", "or", "an", "as", "at", "be", "by", "do", "we",
        "return", "let", "var", "self", "this", "func", "def", "fn", "const", "new", "nil", "null", "none", "true", "false", "end", "with", "from", "that",
        "when", "too", "how", "what", "where", "why", "which", "does", "into", "than", "then", "there", "their", "about", "gets", "way", "after", "before"]
    /// `parseHTTPHeader` → parse, http, header; `max_retries` → max, retries.
    static func split(_ ident: String) -> [String] {
        var parts: [String] = [], cur = ""
        let chars = Array(ident)
        for (i, c) in chars.enumerated() {
            if c == "_" || c.isNumber { if !cur.isEmpty { parts.append(cur) }; cur = ""; continue }
            let prevLower = i > 0 && chars[i - 1].isLowercase
            let nextLower = i + 1 < chars.count && chars[i + 1].isLowercase
            if c.isUppercase && !cur.isEmpty && (prevLower || (nextLower && cur.last?.isUppercase == true)) { parts.append(cur); cur = "" }
            cur.append(c)
        }
        if !cur.isEmpty { parts.append(cur) }
        return parts.map { $0.lowercased() }
    }
    static func stem(_ w: String) -> String {
        guard w.count > 4 else { return w }
        for s in ["ing", "ies", "es", "ed", "s"] where w.hasSuffix(s) && w.count - s.count >= 3 {
            if s == "ies" { return String(w.dropLast(3)) + "y" }
            if s == "es", !["ses", "xes", "zes", "ches", "shes"].contains(where: { w.hasSuffix($0) }) { continue }   // "names" → name, via "s"
            var base = String(w.dropLast(s.count))
            // running → run, stopped → stop: a doubled consonant before the ending is one in the stem.
            if (s == "ing" || s == "ed"), base.count >= 3, let last = base.last, base.dropLast().last == last, !"aeiouls".contains(last) { base.removeLast() }
            return base
        }
        return w
    }

    /// Words a question uses for what code calls something else, both ways (approve ↔ allow, permission; run ↔ execute):
    /// matched at a lower weight than the question's own words.
    static let synonyms: [String: [String]] = {
        let groups: [[String]] = [
            ["approve", "allow", "permission", "permit", "grant", "consent", "authorize", "approval"],
            ["run", "execute", "exec", "spawn", "launch", "invoke"], ["command", "shell", "bash", "process"],
            ["delete", "remove", "erase", "drop", "unlink"], ["fetch", "download", "request", "get", "load"],
            ["error", "fail", "failure", "exception", "throw", "crash"], ["config", "setting", "option", "preference", "configuration"],
            ["user", "learner", "person"], ["stop", "cancel", "terminate", "kill", "abort", "interrupt"],
            ["start", "begin", "init", "boot"], ["save", "persist", "store", "write"], ["find", "search", "lookup", "query"],
            ["retry", "backoff", "attempt"], ["auth", "login", "token", "credential"], ["parse", "decode", "deserialize"],
            ["render", "draw", "display", "show"], ["notify", "report", "alert", "deliver", "wake"], ["summary", "compact", "summarise", "summarize"],
            ["test", "spec", "check", "assert"], ["cache", "memo", "store"], ["background", "job", "task", "async"],
        ]
        var m: [String: [String]] = [:]
        for g in groups { let s = g.map(stem); for w in s { m[w, default: []] += s.filter { $0 != w } } }
        return m
    }()

    /// What a file imports, by language family (module names or paths, as written).
    static func imports(_ text: String, ext: String) -> [String] {
        let pattern: String
        switch ext {
        case "py": pattern = #"(?m)^\s*(?:from\s+([\w.]+)\s+import|import\s+([\w.]+))"#
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte": pattern = #"(?:from\s+|require\(\s*|import\(\s*|^import\s+)['"]([^'"]+)['"]"#
        case "swift": pattern = #"(?m)^\s*(?:@testable\s+)?import\s+(\w+)"#
        case "go": pattern = #"(?m)^\s*(?:import\s+)?(?:\w+\s+)?"([\w./-]+)"$"#
        case "rs": pattern = #"(?m)^\s*(?:pub\s+)?(?:use|mod)\s+([\w:]+)"#
        case "zig": pattern = #"@import\("([^"]+)"\)"#
        case "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm": pattern = #"(?m)^\s*#\s*(?:include|import)\s+["<]([^">]+)[">]"#
        case "java", "kt", "scala", "cs": pattern = #"(?m)^\s*(?:import|using)\s+(?:static\s+)?([\w.]+)"#
        case "rb": pattern = #"require(?:_relative)?\s*\(?\s*['"]([^'"]+)['"]"#
        case "ex", "exs": pattern = #"(?m)^\s*(?:alias|import|use)\s+([\w.]+)"#
        case "php": pattern = #"(?m)^\s*(?:use|require|include)(?:_once)?\s*\(?\s*['"]?([\w\\/.]+)"#
        default: return []
        }
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        var out: [String] = []
        for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            for g in 1..<m.numberOfRanges where m.range(at: g).location != NSNotFound {
                if let r = Range(m.range(at: g), in: text) { out.append(String(text[r])); break }
            }
        }
        return Array(Set(out)).sorted()
    }

    // MARK: Graph

    private func derive() {
        var d: [String: [(path: String, sym: Sym)]] = [:]
        for (p, f) in files { for s in f.symbols { d[s.name, default: []].append((p, s)) } }
        defs = d
        // Who uses whom: naming something only a few files define (a common name like `init` links nothing), or importing it.
        var e: [String: [String: Double]] = [:]
        for (p, f) in files {
            let own = Set(f.symbols.map(\.name))
            for (name, count) in f.idents where !own.contains(name) && name.count >= 4 {
                guard let ds = d[name], ds.count <= 6 else { continue }
                let targets = Set(ds.map(\.path)).subtracting([p])
                for t in targets { e[p, default: [:]][t, default: 0] += (1 + log(Double(count))) / Double(targets.count) }
            }
            for imp in f.imports { for t in resolve(imp, from: p) where t != p { e[p, default: [:]][t, default: 0] += 2 } }
        }
        edges = e
        rank = Self.pageRank(nodes: Array(files.keys), edges: e)
        var freq: [String: Int] = [:], n = 0
        for f in files.values {
            for s in f.symbols { n += 1; for t in s.terms { freq[t, default: 0] += 1 } }
            n += 1; for t in f.head { freq[t, default: 0] += 1 }
        }
        df = freq; chunkCount = max(1, n)
        let lengths = files.values.flatMap { $0.symbols.map { Double($0.terms.count) } }
        avgTerms = max(1, lengths.reduce(0, +) / Double(max(1, lengths.count)))
    }
    private var avgTerms = 1.0

    /// Files an import names: a relative path from the importing file, else a module path's last parts matched against
    /// file paths (`app.models.user` → …/app/models/user.py; `./util` → util.ts; `std` → nothing).
    func resolve(_ imp: String, from path: String) -> [String] {
        let dir = (path as NSString).deletingLastPathComponent
        var key = imp
        if imp.hasPrefix(".") || imp.contains("/") {
            key = imp.hasPrefix(".") ? ((dir as NSString).appendingPathComponent(imp) as NSString).standardizingPath : imp
            if key.hasPrefix("/") { key.removeFirst() }
        } else {
            key = imp.replacingOccurrences(of: ".", with: "/").replacingOccurrences(of: "::", with: "/")
        }
        key = (key as NSString).deletingPathExtension
        guard key.count >= 2 else { return [] }
        return files.keys.filter { p in
            let stem = (p as NSString).deletingPathExtension
            return stem == key || stem.hasSuffix("/" + key) || stem == key + "/index" || stem.hasSuffix("/" + key + "/index") || stem.hasSuffix("/" + key + "/__init__")
        }
    }

    static func pageRank(nodes: [String], edges: [String: [String: Double]], damping: Double = 0.85, iterations: Int = 25) -> [String: Double] {
        guard !nodes.isEmpty else { return [:] }
        let n = Double(nodes.count)
        var r = Dictionary(uniqueKeysWithValues: nodes.map { ($0, 1 / n) })
        let out = edges.mapValues { $0.values.reduce(0, +) }
        for _ in 0..<iterations {
            var next = Dictionary(uniqueKeysWithValues: nodes.map { ($0, (1 - damping) / n) })
            var dangling = 0.0
            for v in nodes {
                guard let es = edges[v], let total = out[v], total > 0 else { dangling += r[v] ?? 0; continue }
                for (t, w) in es { next[t, default: 0] += damping * (r[v] ?? 0) * w / total }
            }
            for v in nodes { next[v, default: 0] += damping * dangling / n }
            r = next
        }
        return r
    }

    // MARK: Queries

    /// `line`: where in the definition the best match is (its start, or a later window of a long one).
    struct Hit: Sendable { var path: String; var sym: Sym?; var score: Double; var matched: [String]; var line: Int? = nil }

    /// The definitions (and files) that best answer a question in words or names.
    func search(_ query: String, limit: Int = 12) -> [Hit] {
        let q = Array(Set(Self.words(query)))
        guard !q.isEmpty else { return [] }
        let maxRank = rank.values.max() ?? 1
        func idf(_ t: String) -> Double { log(1 + (Double(chunkCount) - Double(df[t] ?? 0) + 0.5) / (Double(df[t] ?? 0) + 0.5)) }
        // Tests answer a question about tests; otherwise the code under test is what's wanted.
        let aboutTests = q.contains { ["test", "spec", "check"].contains($0) }
        var hits: [Hit] = []
        for (p, f) in files {
            let pathWords = Set(Self.words(p))
            let isTest = pathWords.contains("test") || pathWords.contains("spec")
            let central = (1 + 0.35 * ((rank[p] ?? 0) / maxRank)) * (isTest && !aboutTests ? 0.5 : 1)
            for s in f.symbols {
                let nameWords = Set(Self.words(s.name))
                // Its first chunk and each later window, scored apart; the best one stands for the definition.
                var best: (score: Double, matched: [String], line: Int)?
                for (line, list) in [(s.line, s.terms)] + s.windows.map({ ($0.line, $0.terms) }) {
                    let terms = Set(list)
                    var score = 0.0, matched: [String] = []
                    for t in q {
                        // The question's own word, else one of its synonyms (at a lower weight).
                        let hit: (word: String, weight: Double)? = terms.contains(t) ? (t, 1)
                            : Self.synonyms[t]?.first(where: terms.contains).map { ($0, 0.6) }
                        guard let h = hit else { continue }
                        var w = idf(h.word) * h.weight
                        if nameWords.contains(h.word) { w *= 2 }
                        if pathWords.contains(h.word) { w *= 1.3 }
                        score += w; matched.append(t)
                    }
                    guard score > 0 else { continue }
                    let cover = Double(matched.count) / Double(q.count)
                    score *= cover * cover + 0.15   // covering more of the question beats a name that shares one word with it
                    score /= 0.6 + 0.4 * (Double(terms.count) / avgTerms)    // BM25's length term: a long chunk matches more by chance
                    if score > (best?.score ?? 0) { best = (score, matched, line) }
                }
                guard let b = best else { continue }
                hits.append(Hit(path: p, sym: s, score: b.score * central * (s.kind == "constant" ? 0.7 : 1), matched: b.matched, line: b.line))
            }
            let head = Set(f.head)
            let hm = q.filter { head.contains($0) }
            if !hm.isEmpty {
                let cover = Double(hm.count) / Double(q.count)
                let score = hm.reduce(0) { $0 + idf($1) } * (pathWords.isSuperset(of: hm) ? 1.3 : 0.8) * (cover * cover + 0.15) * central
                hits.append(Hit(path: p, sym: nil, score: score, matched: hm))
            }
        }
        return Array(hits.sorted { $0.score > $1.score }.prefix(limit))
    }

    /// Every definition of `name`.
    func definitions(_ name: String) -> [(path: String, sym: Sym)] {
        (defs[name] ?? []).sorted { ($0.path, $0.sym.line) < ($1.path, $1.sym.line) }
    }

    /// The definition in `path` that contains `line` (innermost).
    func enclosing(_ path: String, line: Int) -> Sym? {
        files[path]?.symbols.filter { $0.line <= line && line <= $0.end }.max { $0.line < $1.line }
    }

    func entry(_ path: String) -> FileEntry? { files[path] }

    /// Files `path` uses and files that use it, most connected first.
    func neighbours(_ path: String) -> (uses: [(String, Double)], usedBy: [(String, Double)]) {
        let uses = (edges[path] ?? [:]).sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
        let usedBy = edges.compactMap { (src, es) in es[path].map { (src, $0) } }.sorted { $0.1 > $1.1 }
        return (uses, usedBy)
    }

    /// Defined names `sym` (in `path`) uses: what it calls or builds on, with where they're defined.
    func callees(_ path: String, _ sym: Sym) -> [(name: String, at: [(path: String, sym: Sym)])] {
        guard let text = try? String(contentsOf: root.appendingPathComponent(path), encoding: .utf8) else { return [] }
        let body = text.split(separator: "\n", omittingEmptySubsequences: false).dropFirst(sym.line).prefix(max(0, sym.end - sym.line)).joined(separator: "\n")
        var seen = Set<String>(), out: [(String, [(path: String, sym: Sym)])] = []
        for m in Self.identRegex.matches(in: body, range: NSRange(body.startIndex..., in: body)) {
            guard let r = Range(m.range, in: body) else { continue }
            let w = String(body[r])
            guard w != sym.name, w.count >= 3, !seen.contains(w), let d = defs[w], d.count <= 6 else { continue }
            seen.insert(w); out.append((w, d))
        }
        return out
    }

    /// The most central files with their main definitions, for orientation in a repository the agent doesn't know.
    func map(files limit: Int = 15, symbols perFile: Int = 6) -> [(path: String, rank: Double, symbols: [Sym])] {
        let top = rank.sorted { $0.value > $1.value }.prefix(limit)
        return top.map { p, r in
            let f = files[p]
            // A file's main definitions: the ones other files name most.
            let used = (f?.symbols ?? []).filter { $0.kind != "constant" }.sorted { a, b in
                let ua = edgesUsing(a.name), ub = edgesUsing(b.name)
                return ua != ub ? ua > ub : a.line < b.line
            }
            return (p, r, Array(used.prefix(perFile)))
        }
    }
    private func edgesUsing(_ name: String) -> Int { files.values.reduce(0) { $0 + ($1.idents[name] != nil ? 1 : 0) } }

    var stats: (files: Int, symbols: Int, edges: Int) { (files.count, files.values.reduce(0) { $0 + $1.symbols.count }, edges.values.reduce(0) { $0 + $1.count }) }
}

/// A value guarded by a lock (the index registry).
final class Lock<T>: @unchecked Sendable {
    private var value: T
    private let lock = NSLock()
    init(_ v: T) { value = v }
    func with<R>(_ f: (inout T) -> R) -> R { lock.lock(); defer { lock.unlock() }; return f(&value) }
}
