import Foundation
import PDFKit
import UniformTypeIdentifiers

private let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]

struct ReadTool: Tool {
    let name = "read"
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
            return .error("File does not exist: \(url.path)")
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
        out.reserveCapacity(min(data.count, 200_000))
        for i in (offset - 1)..<end {
            var line = lines[i]
            if line.count > 2000 { line = line.prefix(2000) + "… [line truncated]" }
            out += "\(String(i + 1).leftPad(6))\t\(line)\n"
        }
        if end < lines.count { out += "\n(\(lines.count - end) more lines — use offset=\(end + 1) to continue)" }
        return ToolOutput(text: out)
    }
}

struct WriteTool: Tool {
    let name = "write"
    let description = "Write a file (creates parent directories, overwrites existing files). Prefer `edit` for changing existing files. Relative paths resolve against the workspace."
    let risk = ToolRisk.write
    var schema: JSON {
        Schema.object(["path": Schema.string("File path."), "content": Schema.string("Full file content.")], required: ["path", "content"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let url = resolvePath(try input.req("path"), workspace: ctx.workspace)
        let (content, strayEOF) = HeredocSlip.strip(input["content"]?.string ?? "")
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existed = FileManager.default.fileExists(atPath: url.path)
        try Data(content.utf8).write(to: url, options: .atomic)
        let lines = content.split(separator: "\n", omittingEmptySubsequences: false).count
        return ToolOutput(text: "\(existed ? "Overwrote" : "Created") \(url.path) (\(lines) lines)." + (strayEOF ? " " + HeredocSlip.note : ""),
                          meta: ["path": .string(url.path)])
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
        if count == 0 { return (nil, tag + "old_string not found in \(file). Re-read the file and copy the text exactly.") }
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
        var updated = content
        for (k, c) in changes.enumerated() {
            let (next, why) = Self.apply(updated, old: c.old, new: c.new, all: c.all, n: changes.count > 1 ? k + 1 : nil, file: url.lastPathComponent)
            guard let next else { return .error(why + (changes.count > 1 ? " Nothing was changed." : "")) }
            updated = next
        }
        try Data(updated.utf8).write(to: url, options: .atomic)
        // Small diff preview for the UI (the first change).
        let first = changes[0]
        let line = content.range(of: first.old).map { content[..<$0.lowerBound].split(separator: "\n", omittingEmptySubsequences: false).count } ?? 1
        let summary = changes.count == 1 ? "replaced \(first.all ? max(1, content.components(separatedBy: first.old).count - 1) : 1) occurrence(s) near line \(line)"
                                         : "applied \(changes.count) edits"
        return ToolOutput(text: "Edited \(url.path): \(summary).",
                          meta: ["path": .string(url.path), "old": .string(String(first.old.prefix(2000))), "new": .string(String(first.new.prefix(2000))),
                                 "edits": .number(Double(changes.count))])
    }
}

struct LsTool: Tool {
    let name = "ls"
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
    let description = "Find files by glob pattern (e.g. \"**/*.py\", \"src/**/*.swift\"). Returns paths sorted by modification time, newest first."
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object(["pattern": Schema.string("Glob pattern."), "path": Schema.string("Directory to search (default workspace).")], required: ["pattern"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let pattern = try input.req("pattern")
        let root = resolvePath(input["path"]?.string ?? ".", workspace: ctx.workspace)
        let regex = try NSRegularExpression(pattern: Self.globToRegex(pattern), options: [])
        guard var matches = Self.scan(root: root, regex: regex) else { return .error("Cannot search \(root.path)") }
        matches.sort { $0.1 > $1.1 }
        if matches.isEmpty { return ToolOutput(text: "No files match \(pattern) in \(root.path)") }
        let shown = matches.prefix(200).map(\.0).joined(separator: "\n")
        return ToolOutput(text: shown + (matches.count > 200 ? "\n… \(matches.count - 200) more" : ""))
    }

    /// Synchronous directory walk (FileManager enumerators can't be iterated from async contexts).
    static func scan(root: URL, regex: NSRegularExpression) -> [(String, Date)]? {
        let skip: Set<String> = [".git", "node_modules", ".build", "__pycache__", ".venv", "DerivedData", "Pods"]
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
                                                     options: [.skipsPackageDescendants]) else { return nil }
        var matches: [(String, Date)] = []
        var scanned = 0
        // Stops on cancellation (the tool's deadline), and drains Foundation temporaries as it goes.
        var done = false
        while !done {
            autoreleasepool {
                for _ in 0..<512 {
                    guard let url = e.nextObject() as? URL else { done = true; return }
                    if skip.contains(url.lastPathComponent) { e.skipDescendants(); continue }
                    scanned += 1
                    if scanned > 200_000 { done = true; return }
                    let rel = String(url.path.dropFirst(root.path.count + 1))
                    if regex.firstMatch(in: rel, range: NSRange(rel.startIndex..., in: rel)) != nil {
                        let d = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                        matches.append((url.path, d))
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
    let description = """
    Search file contents with a regular expression (ripgrep syntax when available). \
    output_mode: "files_with_matches" (default), "content" (matching lines with line numbers), or "count". \
    Filter files with `glob` (e.g. "*.py"). Use -i for case-insensitive, `context` for surrounding lines.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "pattern": Schema.string("Regular expression."),
            "path": Schema.string("File or directory (default workspace)."),
            "glob": Schema.string("Only search files matching this glob."),
            "output_mode": Schema.string("Output mode.", enum: ["files_with_matches", "content", "count"]),
            "-i": Schema.boolean("Case-insensitive."),
            "context": Schema.integer("Lines of context around matches (content mode)."),
            "head_limit": Schema.integer("Max result lines (default 200)."),
        ], required: ["pattern"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let pattern = try input.req("pattern")
        let path = resolvePath(input["path"]?.string ?? ".", workspace: ctx.workspace).path
        let mode = input["output_mode"]?.string ?? "files_with_matches"
        let limit = max(1, input["head_limit"]?.int ?? 200)
        var result: ProcessResult
        if let rg = ProcessRunner.which("rg") {
            var args = ["--no-heading", "--color=never", "--max-columns=500"]
            switch mode {
            case "content": args += ["-n"]; if let c = input["context"]?.int { args += ["-C", String(c)] }
            case "count": args += ["-c"]
            default: args += ["-l"]
            }
            if input["-i"]?.bool == true { args.append("-i") }
            if let g = input["glob"]?.string { args += ["--glob", g] }
            args += ["-e", pattern, path]
            result = await ProcessRunner.run(rg, args, timeout: 60)
        } else {
            var args = ["-r", "-E", "-I", "--exclude-dir=.git", "--exclude-dir=node_modules"]
            switch mode {
            case "content": args += ["-n"]; if let c = input["context"]?.int { args += ["-C", String(c)] }
            case "count": args += ["-c"]
            default: args += ["-l"]
            }
            if input["-i"]?.bool == true { args.append("-i") }
            if let g = input["glob"]?.string { args.append("--include=\(g)") }
            args += ["-e", pattern, path]
            result = await ProcessRunner.run("/usr/bin/grep", args, timeout: 60)
        }
        if result.exitCode == 1 && result.stdout.isEmpty { return ToolOutput(text: "No matches.") }
        if result.exitCode > 1 { return .error(result.stderr.isEmpty ? "grep failed" : result.stderr) }
        var lines = result.stdout.split(separator: "\n", omittingEmptySubsequences: true)
        if mode == "count" { lines = lines.filter { !$0.hasSuffix(":0") } }
        let shown = lines.prefix(limit).joined(separator: "\n")
        return ToolOutput(text: shown + (lines.count > limit ? "\n… \(lines.count - limit) more lines" : ""))
    }
}

extension String {
    func leftPad(_ n: Int) -> String { count >= n ? self : String(repeating: " ", count: n - count) + self }
}
