import Foundation
import PDFKit
import UniformTypeIdentifiers

private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

/// What each agent has seen of the files it works on: a file's modification date and size when the agent last read or
/// wrote it. As in Claude Code, `write` won't replace a file the agent hasn't read, or one that changed since it looked
/// (the user saved it in their editor, a formatter or a command rewrote it): the overwrite would erase work the agent
/// never saw. `edit` matches exact text, so it still applies to a changed file, with a note. Keyed by the agent's shell
/// session (each sub-agent has its own); bounded per agent.
final class FileViews: @unchecked Sendable {
    static let shared = FileViews()
    struct Stamp: Equatable { var modified: Date; var size: Int }
    enum State: Equatable { case missing, unread, changed, current }
    private let lock = NSLock()
    private var seen: [String: [String: Stamp]] = [:]
    private var order: [String: [String]] = [:]
    static let perAgent = 4000

    static func stamp(_ url: URL) -> Stamp? {
        guard let a = try? FileManager.default.attributesOfItem(atPath: url.path), let d = a[.modificationDate] as? Date else { return nil }
        return Stamp(modified: d, size: (a[.size] as? NSNumber)?.intValue ?? 0)
    }

    /// The agent has the file's current content (it read or wrote it).
    func saw(_ url: URL, agent: String) {
        guard let s = Self.stamp(url) else { return }
        let path = url.standardizedFileURL.path
        lock.lock(); defer { lock.unlock() }
        if seen[agent]?[path] == nil {
            order[agent, default: []].append(path)
            if let o = order[agent], o.count > Self.perAgent {
                let drop = o.prefix(o.count - Self.perAgent)
                for p in drop { seen[agent]?[p] = nil }
                order[agent] = Array(o.dropFirst(drop.count))
            }
        }
        seen[agent, default: [:]][path] = s
    }

    func state(_ url: URL, agent: String) -> State {
        guard let now = Self.stamp(url) else { return .missing }
        lock.lock(); let was = seen[agent]?[url.standardizedFileURL.path]; lock.unlock()
        guard let was else { return .unread }
        return was == now ? .current : .changed
    }

    /// True the first time `url` is mentioned to this agent (a subfolder's instructions ride on one read only).
    private var mentioned: [String: Set<String>] = [:]
    func firstMention(_ url: URL, agent: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return mentioned[agent, default: []].insert(url.standardizedFileURL.path).inserted
    }

    /// A lesson closed: its views go, and its sub-agents' (`<lesson>/A1`…).
    func forget(agent: String) {
        lock.lock(); defer { lock.unlock() }
        for k in Array(seen.keys) where k == agent || k.hasPrefix(agent + "/") { seen[k] = nil; order[k] = nil }
        for k in Array(mentioned.keys) where k == agent || k.hasPrefix(agent + "/") { mentioned[k] = nil }
    }

    static func agent(_ ctx: ToolContext) -> String { ctx.shellID ?? ctx.conversationID }
}

struct ReadTool: Tool {
    /// Characters one read returns at most (about 16k tokens); `offset` reads on.
    static let budget = 64_000
    let name = "read"
    var subAgentVariant: Tool? { self }
    let description = """
    Read a file from the local filesystem. Returns lines prefixed with line numbers (cat -n style). \
    Relative paths resolve against the workspace. Use `offset`/`limit` for large files (default: first 2000 lines). \
    Images are returned visually; PDFs return their text (use `pages` like "1-5"). Read a file before editing it.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "path": Schema.string("Absolute path, or path relative to the workspace."),
            "offset": Schema.integer("1-based line number to start from."),
            "limit": Schema.integer("Number of lines to read."),
            "pages": Schema.string("For PDFs: page range, e.g. \"1-5\" or \"3\"."),
        ], required: ["path"])
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = resolvePath(try input.req("path"), workspace: ctx.workspace)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else {
            let near = await Self.similar(url, workspace: ctx.workspace)
            return .error("File does not exist: \(url.path)" + (near.isEmpty ? "" : ". Did you mean: " + near.joined(separator: ", ") + "?"))
        }
        if isDir.boolValue { return .error("\(url.path) is a directory. Use the `ls` tool instead.") }
        let ext = url.pathExtension.lowercased()
        if imageExtensions.contains(ext) {
            guard let img = ImageUtil.loadForModel(url) else { return .error("Could not decode image.") }
            return ToolOutput(text: "Image \(url.lastPathComponent) (\(img.width)×\(img.height))", images: [img.block])
        }
        if ext == "pdf" {
            guard let doc = PDFDocument(url: url) else { return .error("Could not open PDF.") }
            var range = 1...max(1, doc.pageCount)
            if let p = input["pages"]?.string {
                // Clamped: a model may send "5-3" or "0", and a reversed or empty range would trap.
                let parts = p.split(separator: "-").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }.map { max(1, $0) }
                if parts.count == 1 { range = parts[0]...parts[0] } else if parts.count == 2 { range = parts[0]...max(parts[0], parts[1]) }
            }
            let upper = min(range.upperBound, doc.pageCount, range.lowerBound + 49)
            var text = "PDF \(url.lastPathComponent): \(doc.pageCount) pages\n"
            if range.lowerBound <= upper {
                for i in range.lowerBound...upper {
                    text += "\n--- Page \(i) ---\n" + (doc.page(at: i - 1)?.string ?? "")
                }
            }
            return ToolOutput(text: truncateMiddle(text, max: 100_000))
        }
        let data = try Data(contentsOf: url)
        if data.prefix(8000).contains(0) { return .error("\(url.lastPathComponent) appears to be a binary file (\(data.count) bytes).") }
        let content = String(decoding: data, as: UTF8.self)
        if content.isEmpty { return ToolOutput(text: "(file is empty)") }
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false)
        let offset = max(1, input["offset"]?.int ?? 1)
        let limit = max(1, input["limit"]?.int ?? 2000)
        guard offset <= lines.count else { return .error("offset \(offset) is beyond end of file (\(lines.count) lines).") }
        let end = min(lines.count, offset - 1 + limit)
        var out = ""
        out.reserveCapacity(min(data.count, Self.budget + 4096))
        // Line numbers padded only as wide as the last one ("  9", " 10"), not to six columns: on a 2000-line read the
        // padding alone was 8k characters.
        let width = String(end).count
        var shown = end
        for i in (offset - 1)..<end {
            var line = lines[i]
            if line.count > 2000 { line = line.prefix(2000) + "… [line truncated]" }
            let row = "\(String(i + 1).leftPad(width))\t\(line)\n"
            // A file of long lines stops at the budget rather than at 2000 lines (which could be 4M characters).
            if out.utf8.count + row.utf8.count > Self.budget && i > offset - 1 { shown = i; break }
            out += row
        }
        if shown < lines.count { out += "\n(\(lines.count - shown) more lines — use offset=\(shown + 1) to continue)" }
        FileViews.shared.saw(url, agent: FileViews.agent(ctx))
        // A subfolder's own CLAUDE.md / AGENTS.md, the first time the agent works there.
        if ctx.codeAgent {
            for f in ProjectMemory.nested(for: url, workspace: ctx.workspace) where f != url && FileViews.shared.firstMention(f, agent: FileViews.agent(ctx)) {
                guard let t = try? String(contentsOf: f, encoding: .utf8), !t.isEmpty else { continue }
                let dir = relative(f.deletingLastPathComponent().path, to: ctx.workspace.path)
                out += "\n\n[Project instructions from \(relative(f.path, to: ctx.workspace.path)), for work under \(dir)/:]\n" + String(t.prefix(8000))
            }
        }
        return ToolOutput(text: out)
    }

    /// Files in the workspace with the missing file's name (a wrong directory is the usual slip), nearest first.
    static func similar(_ url: URL, workspace: URL) async -> [String] {
        let name = url.lastPathComponent
        guard !name.isEmpty, let rg = ProcessRunner.which("rg"), !name.contains("*") else { return [] }
        let r = await ProcessRunner.run(rg, ["--files", "--hidden", "-g", "!.git", "-g", "**/" + name, workspace.path], timeout: 3, outputLimit: 20_000)
        return r.stdout.split(separator: "\n").map { relative(String($0), to: workspace.path) }
            .sorted { $0.count < $1.count }.prefix(3).map { $0 }
    }
}

struct WriteTool: Tool {
    let name = "write"
    var subAgentVariant: Tool? { self }
    let description = "Write a file (creates parent directories, overwrites existing files: `read` one first). Prefer `edit` for changing existing files. Relative paths resolve against the workspace."
    let risk = ToolRisk.write
    var schema: JSON {
        Schema.object(["path": Schema.string("File path."), "content": Schema.string("Full file content.")], required: ["path", "content"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = resolvePath(try input.req("path"), workspace: ctx.workspace)
        let (content, strayEOF) = HeredocSlip.strip(input["content"]?.string ?? "")
        if ctx.codeAgent, let refusal = Self.staleOverwrite(url, ctx) { return .error(refusal) }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try Data(content.utf8).write(to: url, options: .atomic)
        FileViews.shared.saw(url, agent: FileViews.agent(ctx))
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        var text = "\(existed ? "Overwrote" : "Created") \(url.path) (\(lines) lines)." + (strayEOF ? " " + HeredocSlip.note : "")
        var meta: [String: JSON] = ["path": .string(url.path)]
        if ctx.codeAgent, let check = await Diagnostics.quickCheck(url, folder: ctx.workspace) { Diagnostics.attach(check, to: &text, meta: &meta) }
        return ToolOutput(text: text, meta: .object(meta))
    }

    /// Why replacing `url` would lose work the agent hasn't seen, or nil when it may (a new file, or one it has current).
    static func staleOverwrite(_ url: URL, _ ctx: ToolContext) -> String? {
        switch FileViews.shared.state(url, agent: FileViews.agent(ctx)) {
        case .missing, .current: return nil
        case .unread: return "\(url.path) already exists and you haven't read it. `read` it first; for a change to part of it use `edit`. Nothing was written."
        case .changed: return "\(url.path) changed since you last read or wrote it (the user may have saved it, or a command rewrote it). `read` it again and make your change on the current content. Nothing was written."
        }
    }
}

/// Models that usually write files with `cat > f <<'EOF'` sometimes end `write` or `run_code` content with the heredoc's
/// terminator. A lone `EOF` last line in content with no heredoc of its own is never meant: it broke every file of a Zig
/// project in a live lesson (`build.zig:50:1: error: file cannot be a tuple`) and two `run_code` compiles. Dropped, and
/// the model is told, so it stops adding it.
enum HeredocSlip {
    static let note = "(A trailing `EOF` line was removed: `write` and `run_code` take the content itself, no heredoc terminator.)"
    static func strip(_ content: String) -> (String, Bool) {
        var lines = content.components(separatedBy: "\n")
        while let l = lines.last, l.trimmingCharacters(in: .whitespaces).isEmpty, lines.count > 1 { lines.removeLast() }
        guard let last = lines.last?.trimmingCharacters(in: .whitespaces), ["EOF", "'EOF'", "\"EOF\""].contains(last),
              !content.contains("<<") else { return (content, false) }
        lines.removeLast()
        return (lines.joined(separator: "\n") + "\n", true)
    }
}

struct EditTool: Tool {
    let name = "edit"
    var subAgentVariant: Tool? { self }
    let description = """
    Exact string replacement in a file. `old_string` must match the file exactly (including whitespace) and be unique \
    unless `replace_all` is true. Several changes to one file: `edits` (applied in order, all or nothing). Read the file \
    first. To create a new file use `write`.
    """
    let risk = ToolRisk.write
    var schema: JSON {
        Schema.object([
            "path": Schema.string("File path."),
            "old_string": Schema.string("Exact text to replace (one change)."),
            "new_string": Schema.string("Replacement text (one change)."),
            "replace_all": Schema.boolean("Replace every occurrence (default false)."),
            "edits": Schema.array(Schema.object(["old_string": Schema.string("Exact text to replace."), "new_string": Schema.string("Replacement."),
                                                 "replace_all": Schema.boolean("Every occurrence.")], required: ["old_string", "new_string"]),
                                  "Several changes, applied in order; nothing is written unless every one applies."),
        ], required: ["path"])
    }

    /// One replacement applied to `content`, or why it can't be.
    static func apply(_ content: String, old: String, new: String, all: Bool, n: Int?, file: String) -> (String?, String) {
        let tag = n.map { "Edit \($0): " } ?? ""
        guard !old.isEmpty else { return (nil, tag + "old_string must not be empty. Use `write` to create files.") }
        guard old != new else { return (nil, tag + "old_string and new_string are identical.") }
        let count = content.components(separatedBy: old).count - 1
        if count == 0 {
            // Not found exactly: the same lines with different indentation or trailing spaces is almost always what was meant.
            guard let (r, replacement) = fuzzyMatch(content, old: old, new: new) else {
                return (nil, tag + "old_string not found in \(file). Re-read the file and copy the text exactly (whitespace included).")
            }
            return (content.replacingCharacters(in: r, with: replacement), "matched with different indentation/whitespace; the replacement was re-indented to the file's")
        }
        if count > 1 && !all { return (nil, tag + "old_string occurs \(count) times. Add surrounding context to make it unique, or set replace_all.") }
        if all { return (content.replacingOccurrences(of: old, with: new), "") }
        let r = content.range(of: old)!
        return (content.replacingCharacters(in: r, with: new), "")
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = resolvePath(try input.req("path"), workspace: ctx.workspace)
        guard let content = try? String(contentsOf: url, encoding: .utf8) else { return .error("Cannot read \(url.path).") }
        var changes: [(old: String, new: String, all: Bool)] = (input["edits"]?.array ?? []).map {
            ($0["old_string"]?.string ?? "", $0["new_string"]?.string ?? "", $0["replace_all"]?.bool ?? false)
        }
        if changes.isEmpty || input["old_string"]?.string != nil {
            changes.insert((input["old_string"]?.string ?? "", input["new_string"]?.string ?? "", input["replace_all"]?.bool ?? false), at: 0)
        }
        var updated = content, notes: [String] = []
        // Exact matching keeps the change safe on a file that moved on; the agent should know its picture is old.
        if ctx.codeAgent, FileViews.shared.state(url, agent: FileViews.agent(ctx)) == .changed {
            notes.append("the file had changed since you last read it, so the rest of it may not be what you remember")
        }
        for (k, c) in changes.enumerated() {
            let (next, why) = Self.apply(updated, old: c.old, new: c.new, all: c.all, n: changes.count > 1 ? k + 1 : nil, file: url.lastPathComponent)
            guard let next else { return .error(why + (changes.count > 1 ? " Nothing was changed." : "")) }
            if !why.isEmpty { notes.append(changes.count > 1 ? "edit \(k + 1) \(why)" : why) }
            updated = next
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
        FileViews.shared.saw(url, agent: FileViews.agent(ctx))
        // Small diff preview for the UI (the first change).
        let first = changes[0]
        let line = content.range(of: first.old).map { content[..<$0.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count } ?? 1
        let summary = changes.count == 1 ? "replaced \(first.all ? max(1, content.components(separatedBy: first.old).count - 1) : 1) occurrence(s) near line \(line)"
                                         : "applied \(changes.count) edits"
        var text = "Edited \(url.path): \(summary)" + (notes.isEmpty ? "" : " (\(notes.joined(separator: "; ")))") + "."
        var meta: [String: JSON] = ["path": .string(url.path), "old": .string(String(first.old.prefix(2000))), "new": .string(String(first.new.prefix(2000))),
                                    "edits": .number(Double(changes.count))]
        if ctx.codeAgent, let check = await Diagnostics.quickCheck(url, folder: ctx.workspace) { Diagnostics.attach(check, to: &text, meta: &meta) }
        return ToolOutput(text: text, meta: .object(meta))
    }

    /// `old` as a run of lines matched with leading and trailing whitespace ignored, when that run is unique in the
    /// file; `new` re-indented by the difference between the file's and `old`'s first-line indentation.
    static func fuzzyMatch(_ content: String, old: String, new: String) -> (Range<String.Index>, String)? {
        let fileLines = content.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let oldLines = old.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let trim = { (s: String) in s.trimmingCharacters(in: .whitespaces) }
        let wanted = oldLines.map(trim)
        guard !wanted.isEmpty, wanted.contains(where: { !$0.isEmpty }), fileLines.count >= wanted.count else { return nil }
        var starts: [Int] = []
        for i in 0...(fileLines.count - wanted.count) where (0..<wanted.count).allSatisfy({ trim(fileLines[i + $0]) == wanted[$0] }) { starts.append(i) }
        guard starts.count == 1 else { return nil }
        let start = starts[0], end = start + wanted.count - 1
        let indent = { (s: String) in s.prefix { $0 == " " || $0 == "\t" } }
        let fileIndent = String(indent(fileLines[start])), oldIndent = String(indent(oldLines[0]))
        let newLines = new.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let reindented = newLines.map { l -> String in
            if l.trimmingCharacters(in: .whitespaces).isEmpty { return l }
            if l.hasPrefix(oldIndent) { return fileIndent + l.dropFirst(oldIndent.count) }
            if oldIndent.hasPrefix(String(indent(l))) { return String(fileIndent.prefix(max(0, fileIndent.count - (oldIndent.count - indent(l).count)))) + l.drop { $0 == " " || $0 == "\t" } }
            return l
        }.joined(separator: "\n")
        // Character offsets of the matched lines in the file.
        var offset = 0
        for i in 0..<start { offset += fileLines[i].count + 1 }
        let from = content.index(content.startIndex, offsetBy: offset)
        var length = 0
        for i in start...end { length += fileLines[i].count + (i < end ? 1 : 0) }
        return (from..<content.index(from, offsetBy: length), reindented)
    }
}

struct LsTool: Tool {
    let name = "ls"
    var subAgentVariant: Tool? { self }
    let description = "List a directory (default: workspace). Shows entries with type and size; hides .git, node_modules and similar."
    let risk = ToolRisk.readOnly
    var schema: JSON { Schema.object(["path": Schema.string("Directory path (default workspace).")]) }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = resolvePath(input["path"]?.string ?? ".", workspace: ctx.workspace)
        let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        guard let items = try? FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: keys) else {
            return .error("Cannot list \(url.path).")
        }
        let hidden: Set<String> = [".git", "node_modules", ".build", ".DS_Store", "__pycache__", ".venv", "DerivedData"]
        var lines: [String] = []
        for item in items.sorted(by: { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }) {
            if hidden.contains(item.lastPathComponent) { continue }
            let v = try? item.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true { lines.append("\(item.lastPathComponent)/") }
            else { lines.append("\(item.lastPathComponent)  (\(ByteCountFormatter.string(fromByteCount: Int64(v?.fileSize ?? 0), countStyle: .file)))") }
            if lines.count >= 500 { lines.append("… (truncated)"); break }
        }
        return ToolOutput(text: "\(url.path)\n" + (lines.isEmpty ? "(empty)" : lines.joined(separator: "\n")))
    }
}

struct GlobTool: Tool {
    let name = "glob"
    var subAgentVariant: Tool? { self }
    let description = "Find files by glob pattern (e.g. \"**/*.py\", \"src/**/*.swift\"). Returns paths sorted by modification time, newest first."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object(["pattern": Schema.string("Glob pattern."), "path": Schema.string("Directory to search (default workspace).")], required: ["pattern"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let pattern = try input.req("pattern")
        let root = resolvePath(input["path"]?.string ?? ".", workspace: ctx.workspace)
        let regex = try NSRegularExpression(pattern: Self.globToRegex(pattern), options: [])
        // ripgrep's file list first: it honours .gitignore (no build output, vendored or generated trees) and is fast on
        // large repositories. Nothing there (the pattern names an ignored path) or no rg: the folder walk.
        var matches = await Self.listed(root: root, regex: regex) ?? []
        if matches.isEmpty {
            guard let walked = Self.scan(root: root, regex: regex) else { return .error("Cannot search \(root.path)") }
            matches = walked
        }
        matches.sort { $0.1 > $1.1 }
        if matches.isEmpty { return ToolOutput(text: "No files match \(pattern) in \(root.path)") }
        // Relative to the folder searched (named once on top): absolute paths repeated the same prefix on every line.
        let shown = matches.prefix(100).map { relative($0.0, to: root.path) }.joined(separator: "\n")
        return ToolOutput(text: "In \(root.path):\n" + shown + (matches.count > 100 ? "\n… \(matches.count - 100) more (narrow the pattern)" : ""))
    }

    /// Files under `root` that ripgrep lists (hidden ones too, .gitignore honoured) whose relative path matches, with their
    /// modification dates; nil when rg isn't installed or fails.
    static func listed(root: URL, regex: NSRegularExpression) async -> [(String, Date)]? {
        guard let rg = ProcessRunner.which("rg") else { return nil }
        let r = await ProcessRunner.run(rg, ["--files", "--hidden", "-g", "!.git", "--color=never"], cwd: root, timeout: 30, outputLimit: 40_000_000)
        guard r.exitCode == 0 || (r.exitCode == 1 && r.stdout.isEmpty) else { return nil }
        var out: [(String, Date)] = []
        for line in r.stdout.split(separator: "\n") {
            let rel = String(line.hasPrefix("./") ? line.dropFirst(2) : line[...])
            guard regex.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil else { continue }
            let path = root.appendingPathComponent(rel).path
            let d = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date) ?? .distantPast
            out.append((path, d))
        }
        return out
    }

    /// Synchronous directory walk (FileManager enumerators can't be iterated from async contexts).
    static func scan(root: URL, regex: NSRegularExpression) -> [(String, Date)]? {
        let skip: Set<String> = [".git", "node_modules", ".build", "__pycache__", ".venv", "DerivedData", "Pods"]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                     options: [.skipsPackageDescendants]) else { return nil }
        var matches: [(String, Date)] = []
        var scanned = 0
        // The enumerator names files by the folder's real path (/private/var/… for /var/…): relative paths are taken
        // against that, and the matches given under the folder as it was asked for.
        let real = realpath(root.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? root.path
        let rel = { (u: URL) -> String in
            for base in [real, root.path] where u.path.hasPrefix(base + "/") { return String(u.path.dropFirst(base.count + 1)) }
            return u.lastPathComponent
        }
        // Stops on cancellation (the tool's deadline), and drains Foundation temporaries as it goes.
        var done = false
        while !done {
            autoreleasepool {
                for _ in 0..<512 {
                    guard let url = e.nextObject() as? URL else { done = true; return }
                    if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                    scanned += 1
                    if scanned > 200_000 { done = true; return }
                    let r = rel(url)
                    if regex.firstMatch(in: r, range: NSRange(r.startIndex..., in: r)) != nil {
                        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        matches.append((root.appendingPathComponent(r).path, d))
                    }
                }
                if Task.isCancelled { done = true }
            }
        }
        return matches
    }

    static func globToRegex(_ glob: String) -> String {
        var r = "^"
        var i = glob.startIndex
        while i < glob.endIndex {
            let c = glob[i]
            switch c {
            case "*":
                let next = glob.index(after: i)
                if next < glob.endIndex, glob[next] == "*" {
                    let after = glob.index(after: next)
                    if after < glob.endIndex, glob[after] == "/" { r += "(?:.*/)?"; i = glob.index(after: after); continue }
                    r += ".*"; i = after; continue
                }
                r += "[^/]*"
            case "?": r += "[^/]"
            case "{": r += "(?:"
            case "}": r += ")"
            case ",": r += "|"
            case ".", "(", ")", "+", "|", "^", "$", "\\", "[", "]": r += "\\\(c)"
            default: r.append(c)
            }
            i = glob.index(after: i)
        }
        if !glob.contains("/") { r = "^(?:.*/)?" + r.dropFirst() }
        return r + "$"
    }
}

struct GrepTool: Tool {
    let name = "grep"
    var subAgentVariant: Tool? { self }
    let description = """
    Search file contents with a regular expression (ripgrep syntax when available; .gitignore honoured). \
    output_mode: "files_with_matches" (default; file:count, most first), "content" (numbered lines by file) or "count". \
    Filter files with `glob` (e.g. "*.py") or `type` (e.g. "py", "rust"). -i case-insensitive; -A/-B/-C lines after, \
    before or around matches (content mode); `multiline` lets a pattern span lines; `offset` skips result lines \
    (page with `head_limit`).
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "pattern": Schema.string("Regular expression."),
            "path": Schema.string("File or directory (default workspace)."),
            "glob": Schema.string("Only search files matching this glob."),
            "type": Schema.string("Only files of this type (rg --type: py, js, ts, rust, go, swift, java…)."),
            "output_mode": Schema.string("Output mode.", enum: ["files_with_matches", "content", "count"]),
            "-i": Schema.boolean("Case-insensitive."),
            "-A": Schema.integer("Lines after each match (content mode)."),
            "-B": Schema.integer("Lines before each match (content mode)."),
            "-C": Schema.integer("Lines around each match (content mode)."),
            "context": Schema.integer("Same as -C."),
            "multiline": Schema.boolean("Patterns may span lines (`.` matches newlines)."),
            "head_limit": Schema.integer("Max result lines (default 100)."),
            "offset": Schema.integer("Skip this many result lines first (default 0)."),
        ], required: ["pattern"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let pattern = try input.req("pattern")
        let path = resolvePath(input["path"]?.string ?? ".", workspace: ctx.workspace).path
        let mode = input["output_mode"]?.string ?? "files_with_matches"
        let limit = max(1, input["head_limit"]?.int ?? 100), skip = max(0, input["offset"]?.int ?? 0)
        // Context lines: -C (or `context`) around, -A/-B on one side; only content mode shows lines.
        var around: [String] = []
        if let c = input["-C"]?.int ?? input["context"]?.int { around += ["-C", String(c)] }
        if let a = input["-A"]?.int { around += ["-A", String(a)] }
        if let b = input["-B"]?.int { around += ["-B", String(b)] }
        var result: ProcessResult
        // Files with matches are listed by match count (the file that mentions it most is usually the one wanted), so
        // both modes count.
        if let rg = ProcessRunner.which("rg") {
            var args = ["--color=never", "--max-columns=400", "--max-columns-preview"]
            switch mode {
            case "content": args += ["-n", "--heading"] + around
            default: args += ["-c", "--no-heading", "--with-filename"]
            }
            if input["-i"]?.bool == true { args.append("-i") }
            if input["multiline"]?.bool == true { args += ["-U", "--multiline-dotall"] }
            if let g = input["glob"]?.string { args += ["--glob", g] }
            if let t = input["type"]?.string, !t.isEmpty { args += ["--type", t] }
            args += ["-e", pattern, path]
            result = await ProcessRunner.run(rg, args, timeout: 60)
            if result.exitCode == 2, result.stderr.contains("unrecognized file type") {
                return .error("Unknown file type “\(input["type"]?.string ?? "")”. Use a glob instead (e.g. \"*.py\"), or a type like py, js, ts, rust, go, swift.")
            }
        } else {
            var args = ["-r", "-E", "-I", "--exclude-dir=.git", "--exclude-dir=node_modules"]
            switch mode {
            case "content": args += ["-n"] + around
            default: args += ["-c", "-H"]
            }
            if input["-i"]?.bool == true { args.append("-i") }
            if let g = input["glob"]?.string { args.append("--include=\(g)") }
            args += ["-e", pattern, path]
            result = await ProcessRunner.run("/usr/bin/grep", args, timeout: 60)
        }
        if result.exitCode == 1 && result.stdout.isEmpty { return ToolOutput(text: "No matches.") }
        if result.exitCode > 1 { return .error(result.stderr.isEmpty ? "grep failed" : result.stderr) }
        let base = (path.hasSuffix("/") ? path : path + "/")
        var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: mode != "content")
            .map { $0.hasPrefix(base) ? String($0.dropFirst(base.count)) : String($0) }
        if mode != "content" {
            // "path:count", most matches first.
            let counted = lines.compactMap { l -> (String, Int)? in
                guard let c = l.lastIndex(of: ":"), let n = Int(l[l.index(after: c)...]), n > 0 else { return nil }
                return (String(l[..<c]), n)
            }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0 < $1.0 }
            lines = counted.map { "\($0.0):\($0.1)" }
        }
        while lines.last?.isEmpty == true { lines.removeLast() }
        if lines.isEmpty { return ToolOutput(text: "No matches.") }
        if skip >= lines.count { return ToolOutput(text: "No results past offset \(skip) (there are \(lines.count) lines).") }
        let rest = lines.count - skip - min(limit, lines.count - skip)
        let shown = lines.dropFirst(skip).prefix(limit).joined(separator: "\n")
        var isDir: ObjCBool = false
        let header = FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue ? "In \(path):\n" : ""
        return ToolOutput(text: header + shown + (rest > 0 ? "\n… \(rest) more lines (offset=\(skip + limit) for the next ones)" : ""))
    }
}

/// `path` relative to `root` when it is inside it.
func relative(_ path: String, to root: String) -> String {
    let base = root.hasSuffix("/") ? root : root + "/"
    return path.hasPrefix(base) ? String(path.dropFirst(base.count)) : path
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
