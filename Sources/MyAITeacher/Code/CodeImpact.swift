import Foundation

/// What a change reaches beyond its own lines (`code` action=impact): the context a reviewer reads a diff with, as
/// Greptile-style reviewers do. From the uncommitted changes (or everything since `base`): the definitions they edit or
/// add, and for each the places outside the change that use it (callers that may need updating), the tests that name
/// it, and which nothing tests; plus definitions the change removed that are still named somewhere (a broken caller).
enum CodeImpact {
    struct Changed: Sendable {
        var path: String
        var sym: CodeIndex.Sym
        var isNew: Bool
        /// Uses outside the changed lines, and how many sit inside them (updated with it).
        var outside: [CodeTool.Use]
        var inside: Int
        /// Too common a name to trace (`init`, defined in many places).
        var untraced: Bool
        /// Other definitions of the same name: some uses may be theirs.
        var namesakes: Int = 0
    }
    struct Removed: Sendable { var name: String; var path: String; var uses: [CodeTool.Use] }
    struct Report: Sendable {
        var files: [String]
        var changed: [Changed]
        var removed: [Removed]
        var unindexed: [String]
        /// Definitions the change took out of a file, whether or not anything still names them.
        var gone: [String: [String]] = [:]
    }

    /// The new-side lines each file's diff (`git diff -U0`) touches, and the text of the lines it removed. A pure
    /// deletion marks the line it sits after. A deleted file is keyed by its old path, with no ranges.
    static func parse(_ diff: String) -> (ranges: [String: [ClosedRange<Int>]], removed: [String: [String]]) {
        var ranges: [String: [ClosedRange<Int>]] = [:], removed: [String: [String]] = [:]
        var old: String?, new: String?
        func strip(_ s: Substring, _ prefix: String) -> String? {
            let p = s.trimmingCharacters(in: .whitespaces)
            return p == "/dev/null" ? nil : String(p.hasPrefix(prefix) ? p.dropFirst(prefix.count) : Substring(p))
        }
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("--- ") { old = strip(line.dropFirst(4), "a/"); new = nil }
            else if line.hasPrefix("+++ ") { new = strip(line.dropFirst(4), "b/") }
            else if line.hasPrefix("@@"), let f = new,
                    let m = line.range(of: #"\+(\d+)(?:,(\d+))?"#, options: .regularExpression) {
                let spec = line[m].dropFirst().split(separator: ",")
                guard let start = Int(spec[0]) else { continue }
                let count = spec.count > 1 ? Int(spec[1]) ?? 1 : 1
                ranges[f, default: []].append(count == 0 ? max(1, start)...max(1, start) : start...(start + count - 1))
            } else if line.hasPrefix("-"), !line.hasPrefix("--- "), let f = new ?? old {
                removed[f, default: []].append(String(line.dropFirst()))
            }
        }
        return (ranges, removed)
    }

    /// The definitions `ranges` touch in a file: the innermost one around each changed line, and any that starts on one.
    static func touched(_ symbols: [CodeIndex.Sym], _ ranges: [ClosedRange<Int>]) -> [CodeIndex.Sym] {
        var out: [CodeIndex.Sym] = [], seen = Set<Int>()
        func add(_ s: CodeIndex.Sym) { if seen.insert(s.line).inserted { out.append(s) } }
        for r in ranges {
            for s in symbols where r.contains(s.line) { add(s) }
            for l in r.prefix(2000) {
                if let s = symbols.filter({ $0.line <= l && l <= $0.end }).max(by: { $0.line < $1.line }) { add(s) }
            }
        }
        return out.sorted { $0.line < $1.line }
    }

    /// Languages that can name each other's definitions: a JavaScript function isn't called from Swift, so a Swift line
    /// with the same word isn't a use of it.
    static func family(_ path: String) -> String {
        let ext = (path as NSString).pathExtension.lowercased()
        switch ext {
        case "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte": return "js"
        case "c", "h", "cpp", "cc", "cxx", "hpp", "m", "mm": return "c"
        case "java", "kt", "scala": return "jvm"
        case "ex", "exs": return "ex"
        case "sh", "bash": return "sh"
        default: return ext
        }
    }

    /// A definition only its own file can name: `private`/`fileprivate`, or a C `static` function.
    static func isFileLocal(_ s: CodeIndex.Sym, path: String) -> Bool {
        s.text.range(of: #"\b(private|fileprivate)\b"#, options: .regularExpression) != nil
            || family(path) == "c" && s.text.hasPrefix("static ")
    }

    /// The uses that can be this definition's: in its language, in code (not a comment or a string: `"edit"` and a CSS
    /// class `lw-legend` aren't calls), in its own file when it's local.
    static func plausible(_ uses: [CodeTool.Use], name: String, from path: String, local: Bool) -> [CodeTool.Use] {
        let fam = family(path)
        return uses.filter { u in
            (!local || u.path == path) && family(u.path) == fam && !u.path.contains(".min.") && !u.path.contains("vendor/")
                && !CodeIndex.isCommentOrAttribute(Substring(u.text)) && !u.text.hasPrefix("[Omitted long")
                && names(code(u.text, family: fam), name)
        }
    }

    /// A line with its string literals and trailing comment taken out. Single quotes are strings only where the
    /// language says so (Rust's are lifetimes, Swift has none).
    static func code(_ line: String, family: String) -> String {
        let quoted = ["js", "py", "rb", "php", "sh", "lua", "c"].contains(family)
            ? #""(?:[^"\\]|\\.)*"|'(?:[^'\\]|\\.)*'|`(?:[^`\\]|\\.)*`"# : #""(?:[^"\\]|\\.)*""#
        var s = line.replacingOccurrences(of: quoted, with: "\"\"", options: .regularExpression)
        let comment = ["py", "rb", "sh"].contains(family) ? "#" : "//"
        if let r = s.range(of: comment) { s = String(s[..<r.lowerBound]) }
        return s
    }

    /// Whether `name` appears in `text` as a whole identifier (`blank` isn't in `q-blank` or `blank_fix`).
    static func names(_ text: String, _ name: String) -> Bool {
        text.range(of: #"(?<![\w$-])"# + NSRegularExpression.escapedPattern(for: name) + #"(?![\w$-])"#, options: .regularExpression) != nil
    }

    static func isTest(_ path: String) -> Bool {
        let w = Set(CodeIndex.words(path))
        return w.contains("test") || w.contains("spec")
    }

    /// The change's reach. `base`: a git revision to compare the working tree with (default HEAD: uncommitted work).
    static func report(root: URL, index: CodeIndex, base: String?) async throws -> Report {
        let given = base?.trimmingCharacters(in: .whitespaces) ?? ""
        let rev = given.isEmpty ? "HEAD" : given
        // A revision, never an option: `--output=…` would write a file.
        guard !rev.hasPrefix("-"), rev.range(of: #"^[\w./~^@{}:-]+$"#, options: .regularExpression) != nil else { throw ToolError("`\(rev)` isn't a git revision.") }
        let g = ["-C", root.path]
        let inside = await Worktree.run(g + ["rev-parse", "--is-inside-work-tree"], timeout: 20)
        guard inside.exitCode == 0 else { throw ToolError("This folder isn't a git repository, so there is no change to trace. Use `code` action=refs or callers on a name instead.") }
        let diff = await Worktree.run(g + ["diff", "-U0", "--no-color", "--no-ext-diff", "--no-renames", "--relative", rev, "--"], timeout: 60)
        guard diff.exitCode == 0 else {
            throw ToolError("git couldn't diff against `\(rev)`: " + diff.stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(300))
        }
        func source(_ p: String) -> Bool { CodeIndex.sourceExtensions.contains((p as NSString).pathExtension.lowercased()) }
        var (ranges, removedText) = parse(diff.stdout)
        ranges = ranges.filter { source($0.key) }
        removedText = removedText.filter { source($0.key) }
        // New files git doesn't track yet are part of the change too, all of them.
        let untracked = await Worktree.run(g + ["ls-files", "--others", "--exclude-standard"], timeout: 30)
        var fresh = Set<String>()
        for p in untracked.stdout.split(separator: "\n").map(String.init) where ranges[p] == nil && source(p) {
            ranges[p] = [1...1_000_000]; fresh.insert(p)
        }

        var changed: [Changed] = [], unindexed: [String] = []
        var syms: [(String, CodeIndex.Sym, Bool)] = []
        for p in ranges.keys.sorted() {
            guard let f = await index.entry(p) else { unindexed.append(p); continue }
            // A definition is new when its first line is an added one and the lines the change removed didn't define it.
            let before = Set(removedText[p].map { SymbolsTool.outline($0.joined(separator: "\n"), ext: (p as NSString).pathExtension.lowercased()).map(\.name) } ?? [])
            for s in touched(f.symbols, ranges[p] ?? []) {
                let added = fresh.contains(p) || (ranges[p] ?? []).contains { $0.contains(s.line) } && !before.contains(s.name)
                syms.append((p, s, added))
            }
        }
        func inChange(_ u: CodeTool.Use) -> Bool { ranges[u.path]?.contains { $0.contains(u.line) } ?? false }
        for (p, s, added) in syms.prefix(40) {
            let defined = await index.definitions(s.name).count
            let common = s.name.count < 3 || CodeIndex.keywords.contains(s.name) || defined > 6
            if common { changed.append(Changed(path: p, sym: s, isNew: added, outside: [], inside: 0, untraced: true)); continue }
            let uses = plausible(await CodeTool.uses(s.name, index: index, root: root), name: s.name, from: p, local: isFileLocal(s, path: p))
            let out = uses.filter { !inChange($0) }
            changed.append(Changed(path: p, sym: s, isNew: added, outside: out, inside: uses.count - out.count, untraced: false, namesakes: defined - 1))
        }

        // Removed definitions whose name nothing defines any more, but something still names.
        var removed: [Removed] = []
        for (p, lines) in removedText.sorted(by: { $0.key < $1.key }) {
            let ext = (p as NSString).pathExtension.lowercased()
            for name in Set(SymbolsTool.outline(lines.joined(separator: "\n"), ext: ext).map(\.name)).sorted()
            where name.count >= 3 && !CodeIndex.keywords.contains(name) {
                guard await index.definitions(name).isEmpty else { continue }
                let uses = plausible(await CodeTool.uses(name, index: index, root: root), name: name, from: p, local: false)
                if !uses.isEmpty { removed.append(Removed(name: name, path: p, uses: uses)) }
            }
        }
        var gone: [String: [String]] = [:]
        for (p, lines) in removedText {
            let ext = (p as NSString).pathExtension.lowercased()
            let now = Set(await index.entry(p)?.symbols.map(\.name) ?? [])
            let names = Set(SymbolsTool.outline(lines.joined(separator: "\n"), ext: ext).map(\.name)).subtracting(now).sorted()
            if !names.isEmpty { gone[p] = names }
        }
        return Report(files: Set(ranges.keys).union(removedText.keys).sorted(), changed: changed, removed: removed, unindexed: unindexed, gone: gone)
    }

    /// The report as the agent reads it: what is at risk first.
    static func render(_ r: Report, base: String?) -> String {
        let since = base.map { "since `\($0)`" } ?? "uncommitted"
        guard !r.files.isEmpty else { return "No \(since) changes to source files in this folder." }
        func kind(_ s: CodeIndex.Sym) -> String { s.kind == "function" ? "ƒ" : s.kind == "type" ? "T" : "c" }
        var s = "\(r.files.count) source file\(r.files.count == 1 ? "" : "s") changed (\(since)), \(r.changed.count) definition\(r.changed.count == 1 ? "" : "s") touched.\n"
        if !r.removed.isEmpty {
            s += "\nREMOVED BUT STILL NAMED (likely broken):\n"
            for x in r.removed {
                s += "  \(x.name) (was in \(x.path)) — \(x.uses.count) place\(x.uses.count == 1 ? "" : "s"):\n"
                s += x.uses.prefix(6).map { "    \($0.path):\($0.line)  \($0.text)" }.joined(separator: "\n") + "\n"
            }
        }
        let traced = r.changed.filter { !$0.untraced }
        let reach = traced.filter { !$0.outside.isEmpty }.sorted { $0.outside.count > $1.outside.count }
        if !reach.isEmpty {
            s += "\nUSED OUTSIDE THE CHANGE (check these callers still hold):\n"
            for c in reach {
                let files = Set(c.outside.map(\.path))
                s += "  \(c.path):\(c.sym.line) \(kind(c.sym)) \(c.sym.text)\(c.isNew ? "  [new]" : "") — \(c.outside.count) use\(c.outside.count == 1 ? "" : "s") in \(files.count) file\(files.count == 1 ? "" : "s")\(c.inside > 0 ? " (\(c.inside) more updated in this change)" : "")\(c.namesakes > 0 ? " — the name has \(c.namesakes) other definition\(c.namesakes == 1 ? "" : "s"), some uses may be theirs" : "")\n"
                var seen = Set<String>()
                for u in c.outside.filter({ !isTest($0.path) }) where seen.insert(u.path + ":" + (u.within?.name ?? "\(u.line)")).inserted && seen.count <= 8 {
                    s += "    \(u.path):\(u.line)  \(u.within.map { "in \($0.name): " } ?? "")\(u.text)\n"
                }
            }
        }
        let tested = traced.filter { $0.outside.contains { isTest($0.path) } }
        if !tested.isEmpty {
            s += "\nTESTS THAT NAME THEM (run these):\n"
            var byFile: [String: Set<String>] = [:]
            for c in tested { for u in c.outside where isTest(u.path) { byFile[u.path, default: []].insert(c.sym.name) } }
            s += byFile.keys.sorted().map { "  \($0) — \(byFile[$0]!.sorted().joined(separator: ", "))" }.joined(separator: "\n") + "\n"
        }
        let untested = traced.filter { c in !isTest(c.path) && c.sym.kind == "function" && !c.outside.contains { isTest($0.path) } }
        if !untested.isEmpty {
            s += "\nNO TEST NAMES THESE:\n  " + untested.prefix(20).map { "\($0.sym.name) (\($0.path):\($0.sym.line))" }.joined(separator: ", ") + "\n"
        }
        let quiet = traced.filter { $0.outside.isEmpty && !isTest($0.path) }
        if !quiet.isEmpty {
            s += "\nUsed nowhere else: " + quiet.prefix(20).map { "\($0.sym.name)\($0.isNew ? " [new]" : "")" }.joined(separator: ", ") + "\n"
        }
        let common = r.changed.filter(\.untraced)
        if !common.isEmpty { s += "Too common a name to trace: " + common.map { "\($0.sym.name) (\($0.path):\($0.sym.line))" }.joined(separator: ", ") + "\n" }
        if r.changed.count >= 40 { s += "(the first 40 touched definitions; pass `base` or narrow the change for the rest)\n" }
        if !r.unindexed.isEmpty { s += "Not indexed: " + r.unindexed.prefix(10).joined(separator: ", ") + "\n" }
        return s
    }

    /// The report cut to what a review needs in front of it (`maxLines`), or nil when there is nothing to say or the
    /// folder isn't a git repository: the review goes on without it.
    static func brief(root: URL, maxLines: Int = 40) async -> String? {
        let index = CodeIndex.of(root)
        _ = await index.refresh()
        guard let r = try? await report(root: root, index: index, base: nil), !r.changed.isEmpty || !r.removed.isEmpty else { return nil }
        let lines = render(r, base: nil).split(separator: "\n", omittingEmptySubsequences: true)
        let cut = lines.count > maxLines ? lines.prefix(maxLines) + ["… (`code` action=impact for the rest)"] : lines.map { $0 }
        return cut.joined(separator: "\n")
    }

    /// The repository's own review rules (`REVIEW.md`, else `.github/REVIEW.md`): what its maintainers want checked in
    /// a change, which no index can know. Bounded; nil when there is none.
    static func rules(root: URL, limit: Int = 3000) -> String? {
        for rel in ["REVIEW.md", ".github/REVIEW.md"] {
            guard let text = try? String(contentsOf: root.appendingPathComponent(rel), encoding: .utf8) else { continue }
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            return t.count > limit ? String(t.prefix(limit)) + "\n… (\(rel) goes on; read it)" : t
        }
        return nil
    }

    struct Flag: Sendable, Equatable { var path: String; var line: Int; var what: String; var text: String }

    /// Patterns worth a reviewer's eye on a line the change added: not verdicts, leads. `tests`: whether they apply in test files.
    static let patterns: [(what: String, regex: String, tests: Bool)] = [
        ("hardcoded secret", #"(?i)(api[_-]?key|secret|passw(or)?d|token)\w*\s*[:=]\s*["'][A-Za-z0-9_\-/+=]{12,}["']"#, false),
        ("private key", #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#, true),
        ("runs a string as code", #"(?<![.\w])(eval|exec)\s*\(|new Function\(|shell\s*=\s*True|os\.system\(|Runtime\.getRuntime\(\)\.exec"#, false),
        ("TLS or certificate checks off", #"(?i)verify\s*=\s*False|rejectUnauthorized\s*:\s*false|InsecureSkipVerify|NSAllowsArbitraryLoads|CURLOPT_SSL_VERIFYPEER,\s*(0|false)"#, true),
        ("force unwrap or forced cast", #"\btry!|\bas!|\w\)?!\.\w|\w!\s*$"#, false),
        ("unfinished", #"\b(TODO|FIXME|XXX|HACK)\b"#, true),
        ("debug leftover", #"console\.(log|debug)\(|\bdebugger\b|\bbreakpoint\(\)|\bpdb\.set_trace"#, false),
        ("SQL built from a string", #"(?i)\b(select|insert|update|delete)\b[^\n]*(?:(["']\s*\+|\+\s*["']|\$\{|\\\(|%s|\{\w+\})[^\n]*\b(from|into|set|where)\b|\b(from|into|set|where)\b[^\n]*(["']\s*\+|\+\s*["']|\$\{|\\\(|%s|\{\w+\}))"#, false),
    ]

    /// The patterns' hits on the lines a unified diff adds (`diff -U<n>`), with the new-file line numbers.
    static func flags(_ diff: String) -> [Flag] {
        var out: [Flag] = []
        var path: String?, line = 0
        for raw in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if raw.hasPrefix("+++ ") { let t = raw.dropFirst(4); path = t == "/dev/null" ? nil : String(t.hasPrefix("b/") ? t.dropFirst(2) : t); continue }
            if raw.hasPrefix("--- ") { continue }
            if raw.hasPrefix("@@"), let m = raw.range(of: #"\+(\d+)"#, options: .regularExpression) { line = (Int(raw[m].dropFirst()) ?? 1) - 1; continue }
            guard let p = path else { continue }
            if raw.hasPrefix("+") {
                line += 1
                let text = String(raw.dropFirst())
                let test = isTest(p), fam = family(p)
                for (what, rx, inTests) in patterns where inTests || !test {
                    if what == "force unwrap or forced cast", fam != "swift" { continue }
                    if what == "debug leftover", test { continue }
                    if text.range(of: rx, options: .regularExpression) != nil {
                        out.append(Flag(path: p, line: line, what: what, text: text.trimmingCharacters(in: .whitespaces).prefix(140).description))
                    }
                }
            } else if !raw.hasPrefix("-") && !raw.hasPrefix("\\") { line += 1 }
        }
        return out
    }

    /// What changed, file by file: definitions added, modified and removed. Deterministic, so it also serves a commit message.
    static func summary(_ r: Report) -> String {
        var lines: [String] = []
        for p in r.files {
            let mine = r.changed.filter { $0.path == p }
            var parts: [String] = []
            let added = mine.filter(\.isNew).map(\.sym.name), edited = mine.filter { !$0.isNew }.map(\.sym.name)
            if !added.isEmpty { parts.append("added " + added.prefix(8).joined(separator: ", ")) }
            if !edited.isEmpty { parts.append("changed " + edited.prefix(8).joined(separator: ", ")) }
            if let g = r.gone[p] { parts.append("removed " + g.prefix(8).joined(separator: ", ")) }
            lines.append("- \(p)" + (parts.isEmpty ? "" : ": " + parts.joined(separator: "; ")))
        }
        return lines.joined(separator: "\n")
    }

    /// A commit or pull-request description drafted from the change itself: a title from what it touches, what changed
    /// per file, what to check (removed names still used, callers outside it, pattern flags) and the test picture.
    /// Facts only: the author adds the why.
    static func describe(root: URL, index: CodeIndex, base: String?) async throws -> String {
        let r = try await report(root: root, index: index, base: base)
        guard !r.files.isEmpty else { return render(r, base: base) }
        let given = base?.trimmingCharacters(in: .whitespaces) ?? ""
        let diff = await Worktree.run(["-C", root.path, "diff", "-U0", "--no-color", "--no-ext-diff", "--relative", given.isEmpty ? "HEAD" : given, "--"], timeout: 60).stdout
        let flagged = flags(diff)
        // The title: the definitions that matter most (added first, then the most used), else the files.
        var ordered: [Changed] = []
        for c in r.changed where c.isNew { ordered.append(c) }
        let edited: [Changed] = r.changed.filter { !$0.isNew && !$0.untraced }
        ordered += edited.sorted { (x: Changed, y: Changed) -> Bool in x.outside.count > y.outside.count }
        var seen = Set<String>(), names: [String] = []
        for c in ordered where seen.insert(c.sym.name).inserted { names.append(c.sym.name) }
        var what = ""
        if names.isEmpty {
            what = r.files.prefix(2).map { ($0 as NSString).lastPathComponent }.joined(separator: ", ")
        } else {
            what = names.prefix(3).joined(separator: ", ")
            if names.count > 3 { what += " and \(names.count - 3) more" }
        }
        let verb = r.changed.allSatisfy(\.isNew) && !r.changed.isEmpty ? "Add" : "Change"
        var s = "\(verb) \(what)\n\n## What changed\n" + summary(r) + "\n"
        var check: [String] = []
        for x in r.removed { check.append("`\(x.name)` was removed from \(x.path) but is still named in \(x.uses.prefix(3).map { "\($0.path):\($0.line)" }.joined(separator: ", "))") }
        for c in r.changed where !c.untraced && !c.outside.isEmpty && !c.isNew {
            let files = Set(c.outside.filter { !isTest($0.path) }.map(\.path))
            if !files.isEmpty { check.append("`\(c.sym.name)` is used outside this change in \(files.sorted().prefix(3).joined(separator: ", "))\(files.count > 3 ? " and \(files.count - 3) more" : "")") }
        }
        for f in flagged.prefix(8) { check.append("\(f.path):\(f.line) \(f.what)") }
        if !check.isEmpty { s += "\n## To check\n" + check.map { "- " + $0 }.joined(separator: "\n") + "\n" }
        let traced = r.changed.filter { !$0.untraced && $0.sym.kind == "function" && !isTest($0.path) }
        let covered = traced.filter { $0.outside.contains { isTest($0.path) } }, bare = traced.filter { c in !c.outside.contains { isTest($0.path) } }
        if !covered.isEmpty || !bare.isEmpty {
            s += "\n## Tests\n"
            if !covered.isEmpty { s += "- Named by tests: " + covered.prefix(8).map { "`\($0.sym.name)`" }.joined(separator: ", ") + "\n" }
            if !bare.isEmpty { s += "- No test names: " + bare.prefix(8).map { "`\($0.sym.name)`" }.joined(separator: ", ") + "\n" }
        }
        return s
    }

    /// A review's whole brief for a change: the diff (bounded), what it reaches, the repository's rules, and how to
    /// report. The caller reads the files around each hunk and answers; nothing here runs a model.
    static func reviewBrief(root: URL, index: CodeIndex, base: String?, diffLimit: Int = 24_000) async throws -> String {
        let r = try await report(root: root, index: index, base: base)
        guard !r.files.isEmpty else { return render(r, base: base) }
        let given = base?.trimmingCharacters(in: .whitespaces) ?? ""
        let rev = given.isEmpty ? "HEAD" : given
        let diff = await Worktree.run(["-C", root.path, "diff", "-U3", "--no-color", "--no-ext-diff", "--relative", rev, "--"], timeout: 60).stdout
        var s = "REVIEW BRIEF\n\n## What changed\n" + summary(r) + "\n\n## Diff\n"
        s += diff.count > diffLimit ? "```diff\n" + diff.prefix(diffLimit) + "\n```\n(diff cut at \(diffLimit) characters; `git diff` the rest, file by file)\n" : "```diff\n" + diff + "```\n"
        let flagged = flags(diff)
        if !flagged.isEmpty {
            s += "\n## Pattern flags (leads from a scan of the added lines, not verdicts: confirm in context)\n"
            s += flagged.prefix(30).map { "- \($0.path):\($0.line)  \($0.what): \($0.text)" }.joined(separator: "\n") + "\n"
            if flagged.count > 30 { s += "(and \(flagged.count - 30) more)\n" }
        }
        s += "\n## Reach\n" + render(r, base: base)
        if let rules = rules(root: root) { s += "\n## Repository review rules (REVIEW.md)\n" + rules + "\n" }
        if let learned = ReviewMemory.render(ReviewMemory.load(root)) { s += "\n## Learned from earlier reviews here (the user's corrections; follow them)\n" + learned + "\n" }
        s += """

        ## How to review
        Read the code around each hunk (`read` offset/limit), not only the diff. For each finding give file:line, what is \
        wrong, and why it matters; rank must-fix over nits, and say nothing about style the repository's formatter owns. \
        Check, in order: a removed or renamed name still used (above); callers listed under "used outside the change" \
        that the new behaviour breaks; the error and empty cases; missing tests for the touched functions; anything the \
        repository rules forbid. If nothing is wrong, say so plainly rather than inventing findings.
        """
        return s
    }
}
