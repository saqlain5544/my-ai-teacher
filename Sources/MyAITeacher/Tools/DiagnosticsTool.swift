import Foundation

/// Compiler, type-checker and linter output as the agent needs it: one line per problem (file:line:col severity
/// message), grouped by file, counted, capped — never 400 lines of build log to scroll through.
enum Diagnostics {
    struct Item: Sendable, Equatable {
        var file: String
        var line: Int
        var column: Int?
        var severity: String   // error | warning | note
        var message: String
    }

    // clang / swift / zig / gcc / go vet / ruff: file:line:col: error: message  (go: file:line:col: message)
    private static let colon = try! NSRegularExpression(pattern: #"^\s*(?:\.\/)?([^\s:][^:\n]*?\.[A-Za-z0-9]+):(\d+)(?::(\d+))?:\s*(?:(error|warning|note|fatal error)\s*(?:\[[^\]]*\])?:\s*)?(.+)$"#)
    // tsc / dotnet: file(line,col): error TS2345: message
    private static let paren = try! NSRegularExpression(pattern: #"^\s*([^\s(][^(\n]*?\.[A-Za-z0-9]+)\((\d+),(\d+)\):\s*(error|warning)\s+[A-Z]*\d*:\s*(.+)$"#)
    // rustc / cargo: "error[E0308]: mismatched types" then " --> src/main.rs:4:5"
    private static let rustHead = try! NSRegularExpression(pattern: #"^(error|warning)(?:\[[A-Z0-9]+\])?:\s*(.+)$"#)
    private static let rustArrow = try! NSRegularExpression(pattern: #"^\s*-->\s*([^:\n]+):(\d+):(\d+)"#)
    // python: File "x.py", line 12 … then "SyntaxError: msg" / pytest "x.py:12: AssertionError"
    private static let pyFile = try! NSRegularExpression(pattern: #"^\s*File "([^"]+)", line (\d+)"#)
    private static let pyError = try! NSRegularExpression(pattern: #"^([A-Za-z]+(?:Error|Exception|Warning)):\s*(.+)$"#)
    // eslint stylish: "  12:5  error  message  rule"
    private static let eslint = try! NSRegularExpression(pattern: #"^\s+(\d+):(\d+)\s+(error|warning)\s+(.+?)(?:\s{2,}\S+)?$"#)

    static func parse(_ output: String, folder: URL? = nil) -> [Item] {
        var items: [Item] = []
        var pending: (String, String)?        // rustc: severity + message waiting for its --> line
        var pyPending: (String, Int)?         // python: file + line waiting for the error line
        var eslintFile: String?
        let rel = { (f: String) -> String in
            var s = f.trimmingCharacters(in: .whitespaces)
            if let folder, s.hasPrefix(folder.path + "/") { s = String(s.dropFirst(folder.path.count + 1)) }
            return s
        }
        for raw in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = String(raw)
            let ns = line as NSString, range = NSRange(location: 0, length: ns.length)
            if let m = rustArrow.firstMatch(in: line, range: range), let p = pending {
                items.append(Item(file: rel(ns.substring(with: m.range(at: 1))), line: Int(ns.substring(with: m.range(at: 2))) ?? 0, column: Int(ns.substring(with: m.range(at: 3))), severity: p.0, message: p.1))
                pending = nil; continue
            }
            if let m = rustHead.firstMatch(in: line, range: range), !line.contains(":") || line.hasPrefix("error") || line.hasPrefix("warning") {
                let sev = ns.substring(with: m.range(at: 1)), msg = ns.substring(with: m.range(at: 2))
                if !msg.hasPrefix("aborting") && !msg.contains("could not compile") && !msg.hasPrefix("generated") { pending = (sev, msg) }
                continue
            }
            if let m = paren.firstMatch(in: line, range: range) {
                items.append(Item(file: rel(ns.substring(with: m.range(at: 1))), line: Int(ns.substring(with: m.range(at: 2))) ?? 0, column: Int(ns.substring(with: m.range(at: 3))), severity: ns.substring(with: m.range(at: 4)), message: ns.substring(with: m.range(at: 5)))); continue
            }
            if let m = pyFile.firstMatch(in: line, range: range) { pyPending = (rel(ns.substring(with: m.range(at: 1))), Int(ns.substring(with: m.range(at: 2))) ?? 0); continue }
            if let m = pyError.firstMatch(in: line, range: range), let p = pyPending {
                items.append(Item(file: p.0, line: p.1, column: nil, severity: ns.substring(with: m.range(at: 1)).hasSuffix("Warning") ? "warning" : "error", message: ns.substring(with: m.range(at: 1)) + ": " + ns.substring(with: m.range(at: 2))))
                pyPending = nil; continue
            }
            if let m = colon.firstMatch(in: line, range: range) {
                let sevRaw = m.range(at: 4).location != NSNotFound ? ns.substring(with: m.range(at: 4)) : nil
                let msg = ns.substring(with: m.range(at: 5))
                // Go and pytest print no severity: a located line is an error unless it says otherwise.
                let sev = sevRaw.map { $0 == "fatal error" ? "error" : $0 } ?? (msg.lowercased().hasPrefix("warning") ? "warning" : "error")
                if sev == "note" { continue }
                let file = rel(ns.substring(with: m.range(at: 1)))
                guard !file.contains(" ") || file.hasSuffix(".swift") else { continue }
                items.append(Item(file: file, line: Int(ns.substring(with: m.range(at: 2))) ?? 0, column: m.range(at: 3).location != NSNotFound ? Int(ns.substring(with: m.range(at: 3))) : nil, severity: sev, message: msg))
                continue
            }
            if let m = eslint.firstMatch(in: line, range: range), let f = eslintFile {
                items.append(Item(file: f, line: Int(ns.substring(with: m.range(at: 1))) ?? 0, column: Int(ns.substring(with: m.range(at: 2))), severity: ns.substring(with: m.range(at: 3)), message: ns.substring(with: m.range(at: 4)))); continue
            }
            if !line.hasPrefix(" "), line.contains("/") || line.contains("."), !line.contains(" "), line.count < 300 { eslintFile = rel(line) }
        }
        // The same problem reported twice (a header and its located line) collapses.
        var seen = Set<String>()
        return items.filter { seen.insert("\($0.file):\($0.line):\($0.severity):\($0.message)").inserted }
    }

    /// The agent-facing summary: counts, then problems grouped by file, errors first, at most `cap` lines.
    static func summary(_ items: [Item], cap: Int = 60) -> String {
        let errors = items.filter { $0.severity == "error" }, warnings = items.filter { $0.severity == "warning" }
        guard !items.isEmpty else { return "No problems reported." }
        var s = "\(errors.count) error\(errors.count == 1 ? "" : "s"), \(warnings.count) warning\(warnings.count == 1 ? "" : "s")"
        let ordered = errors + warnings
        let byFile = Dictionary(grouping: ordered, by: \.file)
        var shown = 0
        for file in byFile.keys.sorted(by: { (byFile[$0]!.filter { $0.severity == "error" }.count, $0) > (byFile[$1]!.filter { $0.severity == "error" }.count, $1) }) {
            s += "\n\(file):"
            for it in byFile[file]!.sorted(by: { $0.line < $1.line }) {
                if shown >= cap { s += "\n  … \(ordered.count - shown) more"; return s }
                s += "\n  \(it.line)\(it.column.map { ":\($0)" } ?? "") \(it.severity): \(it.message)"
                shown += 1
            }
        }
        return s
    }

    // MARK: Quick checks after an edit

    /// Appends a quick check's verdict to a write/edit result; problems are flagged in the result's meta for the card.
    static func attach(_ check: String, to text: inout String, meta: inout [String: JSON]) {
        if check == "ok" { text += "\nSyntax check: ok."; return }
        text += "\nSyntax check found problems — fix them before moving on:\n" + check
        meta["syntaxErrors"] = true
    }


    /// A syntax check that finishes in a second or two for one file, when the language has one: what an editor
    /// shows the moment you save. nil = no checker for this file type.
    static func quickCheck(_ file: URL, folder: URL) async -> String? {
        let ext = file.pathExtension.lowercased()
        var cmd: (String, [String])?
        switch ext {
        case "py": cmd = ProcessRunner.which("python3").map { ($0, ["-c", "import ast, sys; ast.parse(open(sys.argv[1], encoding='utf-8').read(), sys.argv[1])", file.path]) }   // not py_compile: it writes __pycache__ into the project
        case "js", "mjs", "cjs": cmd = ProcessRunner.which("node").map { ($0, ["--check", file.path]) }
        case "rb": cmd = ProcessRunner.which("ruby").map { ($0, ["-c", file.path]) }
        case "zig": cmd = ProcessRunner.which("zig").map { ($0, ["ast-check", file.path]) }
        case "swift": cmd = ProcessRunner.which("swiftc").map { ($0, ["-parse", file.path]) }
        case "go": cmd = ProcessRunner.which("gofmt").map { ($0, ["-e", file.path]) }   // syntax errors on stderr with exit 2; formatting is not an error
        case "sh", "bash", "zsh": cmd = ("/bin/zsh", ["-n", file.path])
        case "json":
            guard let data = try? Data(contentsOf: file) else { return nil }
            do { _ = try JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]); return "ok" }
            catch { return "\(file.lastPathComponent): \(error.localizedDescription)" }
        case "lua": cmd = ProcessRunner.which("luac").map { ($0, ["-p", file.path]) }
        case "php": cmd = ProcessRunner.which("php").map { ($0, ["-l", file.path]) }
        case "pl": cmd = ProcessRunner.which("perl").map { ($0, ["-c", file.path]) }
        default: return nil
        }
        guard let (exe, args) = cmd else { return nil }
        let r = await ProcessRunner.run(exe, args, cwd: folder, timeout: 10)
        if r.timedOut { return nil }
        if r.exitCode == 0 { return "ok" }
        let out = (ext == "go" ? r.stderr : r.combined).replacingOccurrences(of: file.path, with: file.lastPathComponent)
        let items = parse(out, folder: folder)
        return items.isEmpty ? String(out.trimmingCharacters(in: .whitespacesAndNewlines).prefix(600)) : summary(items, cap: 10)
    }
}

/// Runs the project's check (build or type-check), tests or lint, and returns the problems, parsed.
struct DiagnosticsTool: Tool {
    let name = "diagnostics"
    let description = """
    Compile-check, type-check, lint or test the project and get the problems parsed: `file:line:col severity message`, \
    grouped by file, counted — instead of a raw build log. `what`: check (default; the project's fast build/type-check \
    from the Project section, e.g. swift build, tsc --noEmit, cargo check, go vet), test, lint, or a `command` of your \
    own. Run it after every batch of edits and before reporting; fix what it finds. Syntax errors in a file you just \
    edited are already appended to that edit's result.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "what": Schema.string("check (default), test, lint, or command.", enum: ["check", "test", "lint", "command"]),
            "command": Schema.string("The command to run (what=command, or to override the detected one)."),
            "timeout": Schema.integer("Seconds (default 300, max 900)."),
        ])
    }
    func summary(_ input: JSON) -> String { input["command"]?.string ?? (input["what"]?.string ?? "check") }
    func timeout(_ input: JSON) -> Double? { Double(min(900, max(10, input["timeout"]?.int ?? 300))) + 15 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let what = input["what"]?.string ?? "check"
        var command = input["command"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)
        if command == nil || command!.isEmpty {
            let profile = await ProjectProfile.detect(ctx.workspace)
            command = switch what {
            case "test": profile.testCommand
            case "lint": profile.commands.lint.first
            default: profile.checkCommand
            }
            guard command != nil else {
                return .error("No \(what) command is known for this project (nothing detected from its manifests). Pass `command`, and save it with `project_memory` once it works.")
            }
        }
        let cmd = command!
        let timeout = TimeInterval(min(900, max(10, input["timeout"]?.int ?? 300)))
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let progress = ctx.progress
        let started = Date()
        let r = await ProcessRunner.run(shell, ["-c", cmd], cwd: ctx.workspace, timeout: timeout, onOutput: { progress($0) })
        let elapsed = String(format: "%.1f s", Date().timeIntervalSince(started))
        if r.timedOut { return .error("`\(cmd)` timed out after \(Int(timeout)) s.\n" + truncateMiddle(r.combined, max: 4000)) }
        let items = Diagnostics.parse(r.combined, folder: ctx.workspace)
        let errors = items.filter { $0.severity == "error" }.count
        var text = "`\(cmd)` → exit \(r.exitCode) in \(elapsed). "
        if items.isEmpty {
            text += r.exitCode == 0 ? "No problems." : "Failed, but nothing parsed as a diagnostic — the tail of its output:\n" + String(r.combined.suffix(3000))
        } else {
            text += Diagnostics.summary(items)
            if r.exitCode != 0 && errors == 0 { text += "\n(The command failed without errors parsed; tail of its output:)\n" + String(r.combined.suffix(1500)) }
        }
        if what == "test", r.exitCode == 0, items.isEmpty {
            // The test runner's own summary line is the evidence worth keeping.
            let tail = r.combined.split(separator: "\n").suffix(4).joined(separator: "\n")
            if !tail.isEmpty { text += "\n" + tail }
        }
        return ToolOutput(text: text, isError: r.exitCode != 0 || errors > 0,
                          meta: ["exit": .number(Double(r.exitCode)), "errors": .number(Double(errors)), "warnings": .number(Double(items.count - errors)), "command": .string(cmd)])
    }
}
