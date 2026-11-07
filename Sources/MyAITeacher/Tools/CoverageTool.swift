import Foundation

/// Which lines the learner's tests never run, from what the toolchain already has (Go's cover profile, SwiftPM's and
/// cargo-llvm-cov's llvm-cov JSON, node's and jest's coverage tables, coverage.py or Python's stdlib `trace`). It runs
/// the registered tests in a scratch copy, so the learner's folder gets no `.coverage` or `cover.out`. Nothing is installed:
/// a missing tool is named. A line that ran is not a line that was checked; that is what `mutate` measures.
enum Coverage {
    struct File: Sendable, Equatable {
        var path: String
        var covered: Int, total: Int
        var missing: [ClosedRange<Int>]
        /// `covered`/`total` are real line (or statement) counts; false when a runner printed only a percentage.
        var counts = true
        var percent: Double { total == 0 ? 100 : Double(covered) / Double(total) * 100 }
    }
    struct Report: Sendable {
        var tool = ""
        var files: [File] = []
        var note: String? = nil
        var output = ""
        var left: String? = nil
        var covered: Int { files.reduce(0) { $0 + $1.covered } }
        var total: Int { files.reduce(0) { $0 + $1.total } }
        /// Real counts only when every file has them; otherwise the mean of the files' percentages.
        var exact: Bool { files.allSatisfy(\.counts) }
        var percent: Double { files.isEmpty ? 0 : exact ? (total == 0 ? 0 : Double(covered) / Double(total) * 100) : files.map(\.percent).reduce(0, +) / Double(files.count) }
    }

    /// Consecutive line numbers as ranges.
    static func ranges(_ lines: [Int]) -> [ClosedRange<Int>] {
        var out: [ClosedRange<Int>] = []
        for l in Set(lines).sorted() {
            if let last = out.last, last.upperBound + 1 == l { out[out.count - 1] = last.lowerBound...l } else { out.append(l...l) }
        }
        return out
    }
    static func text(_ r: ClosedRange<Int>) -> String { r.lowerBound == r.upperBound ? "\(r.lowerBound)" : "\(r.lowerBound)-\(r.upperBound)" }

    /// The files of a report a learner wrote: not their tests, the app's state, or other people's code.
    static func isMine(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        if parts.contains(where: { Scratch.excluded.contains($0) || $0 == "site-packages" || $0 == "usr" }) { return false }
        return !CodeImpact.isTest(path) && !path.hasPrefix("/")
    }

    // MARK: Parsers

    /// `go test -coverprofile`: "mode: set" then `pkg/file.go:10.2,12.3 1 0` (statements, then hit count).
    static func goProfile(_ text: String, module: String?) -> [File] {
        var covered: [String: Set<Int>] = [:], missing: [String: Set<Int>] = [:], stmts: [String: (Int, Int)] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("mode:") {
            let f = line.split(separator: " ")
            guard f.count == 3, let colon = f[0].lastIndex(of: ":"), let n = Int(f[1]), let hits = Int(f[2]) else { continue }
            var path = String(f[0][..<colon])
            if let m = module, path.hasPrefix(m + "/") { path = String(path.dropFirst(m.count + 1)) }
            let span = f[0][f[0].index(after: colon)...].split(separator: ",")
            guard span.count == 2, let a = Int(span[0].split(separator: ".")[0]), let b = Int(span[1].split(separator: ".")[0]), a <= b else { continue }
            let cur = stmts[path] ?? (0, 0)
            stmts[path] = (cur.0 + n, cur.1 + (hits > 0 ? n : 0))
            if hits > 0 { covered[path, default: []].formUnion(a...b) } else { missing[path, default: []].formUnion(a...b) }
        }
        return stmts.keys.sorted().map { p in
            File(path: p, covered: stmts[p]!.1, total: stmts[p]!.0, missing: ranges(Array((missing[p] ?? []).subtracting(covered[p] ?? []))))
        }
    }

    /// `llvm-cov export` JSON (swift test --enable-code-coverage, cargo llvm-cov --json): per file a lines summary and
    /// segments `[line, col, count, hasCount, isRegionEntry, isGap]`, a count holding until the next segment.
    static func llvmJSON(_ data: Data, root: String) -> [File] {
        guard let j = JSON.parse(String(decoding: data, as: UTF8.self)), let files = j["data"]?[0]?["files"]?.array else { return [] }
        var out: [File] = []
        for f in files {
            guard var name = f["filename"]?.string else { continue }
            if name.hasPrefix(root + "/") { name = String(name.dropFirst(root.count + 1)) }
            let segs = (f["segments"]?.array ?? []).compactMap { s -> (line: Int, count: Int, has: Bool)? in
                guard let a = s.array, a.count >= 4, let l = a[0].int, let c = a[2].int else { return nil }
                return (l, c, a[3].bool ?? (a[3].int == 1))
            }
            var perLine: [Int: Int] = [:]      // the best count seen on each line
            var carry = 0, hasCarry = false
            for (i, s) in segs.enumerated() {
                let next = i + 1 < segs.count ? segs[i + 1].line : s.line
                if s.has { carry = s.count; hasCarry = true } else { hasCarry = false; continue }   // a region's end holds no count
                perLine[s.line] = max(perLine[s.line] ?? 0, s.has ? s.count : carry)
                if next > s.line + 1 { for l in (s.line + 1)..<next { perLine[l] = max(perLine[l] ?? 0, carry) } }
            }
            let total = f["summary"]?["lines"]?["count"]?.int ?? perLine.count, cov = f["summary"]?["lines"]?["covered"]?.int ?? perLine.values.filter { $0 > 0 }.count
            out.append(File(path: name, covered: cov, total: total, missing: ranges(perLine.filter { $0.value == 0 }.map(\.key))))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// A coverage table with pipe-separated columns: node's ("file | line % | branch % | funcs % | uncovered lines") and
    /// jest's, vitest's and c8's ("File | % Stmts | … | % Lines | Uncovered Line #s"). Percent only: line counts aren't printed,
    /// so `covered`/`total` stand for the percent of 100.
    static func table(_ text: String) -> [File] {
        var out: [File] = [], pctCol: Int?, missCol: Int?
        var dirs: [(indent: Int, name: String)] = []
        for raw in text.split(separator: "\n") {
            var line = String(raw)
            if line.hasPrefix("ℹ ") || line.hasPrefix("# ") { line = String(line.dropFirst(2)) }
            let cells = line.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard cells.count >= 3 else { continue }
            let low = cells.map { $0.lowercased() }
            if low[0] == "file" || low[0] == "files" {
                pctCol = low.firstIndex { $0.contains("line") && $0.contains("%") } ?? low.firstIndex { $0.contains("stmts") }
                missCol = low.firstIndex { $0.contains("uncovered") }
                dirs = []
                continue
            }
            guard let pc = pctCol, let mc = missCol, pc < cells.count, mc < cells.count else { continue }
            let name = cells[0], indent = line.prefix { $0 == " " }.count
            if name.isEmpty || name.lowercased() == "all files" || name.hasPrefix("---") || name.hasPrefix("===") { continue }
            while let top = dirs.last, top.indent >= indent { dirs.removeLast() }
            // A row with a file extension is a file; any other row is a folder that the indented rows below it belong to.
            guard name.range(of: #"\.\w{1,5}$"#, options: .regularExpression) != nil else { dirs.append((indent, name)); continue }
            guard let pct = Double(cells[pc]) else { continue }
            var miss: [Int] = []
            for part in cells[mc].split(whereSeparator: { $0 == "," || $0 == " " }) {
                let ends = part.split(separator: "-").compactMap { Int($0) }
                if ends.count == 2, ends[0] <= ends[1] { miss += Array(ends[0]...ends[1]) } else if ends.count == 1 { miss.append(ends[0]) }
            }
            // Node prints a file's whole relative path; jest and c8 print the folder row above and the bare name.
            var path = name.contains("/") ? name : (dirs.map(\.name).filter { $0 != "." } + [name]).joined(separator: "/")
            if path.hasPrefix("./") { path = String(path.dropFirst(2)) }
            out.append(File(path: path, covered: Int(pct.rounded()), total: 100, missing: ranges(miss), counts: false))
        }
        return out
    }

    /// coverage.py's `json` report.
    static func coveragePy(_ data: Data) -> [File] {
        guard let j = JSON.parse(String(decoding: data, as: UTF8.self)), let files = j["files"]?.object else { return [] }
        return files.keys.sorted().map { k in
            let f = files[k]!
            let ex = f["executed_lines"]?.array?.compactMap(\.int).count ?? 0, miss = f["missing_lines"]?.array?.compactMap(\.int) ?? []
            return File(path: k, covered: ex, total: ex + miss.count, missing: ranges(miss))
        }
    }

    /// stdlib `trace --count --missing`: `m.cover` beside `m.py`, an executed line prefixed with its count, a missed
    /// executable line with `>>>>>>`.
    static func traceCover(in dir: URL, sources: [String]) -> [File] {
        sources.filter { $0.hasSuffix(".py") }.compactMap { rel in
            let cover = dir.appendingPathComponent(String(rel.dropLast(3)) + ".cover")
            guard let text = try? String(contentsOf: cover, encoding: .utf8) else { return nil }
            var missing: [Int] = [], ran = 0
            for (i, l) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                if l.hasPrefix(">>>>>>") { missing.append(i + 1) }
                else if let c = l.prefix(7).trimmingCharacters(in: .whitespaces).first, c.isNumber, l.prefix(7).contains(":") { ran += 1 }
            }
            return File(path: rel, covered: ran, total: ran + missing.count, missing: ranges(missing))
        }
    }

    // MARK: Running

    static func run(ws: Workspace, command: String?, seconds: TimeInterval, progress: @escaping @Sendable (String) -> Void) async -> Report {
        var r = Report()
        guard let command = command ?? ProjectStore.load(ws)?.testCommand, !command.isEmpty else {
            r.note = "No test command: `project_tests` set registers one (or pass `command`)."
            return r
        }
        let c = command
        enum Kind { case go, swift, rust, node, jest, python }
        let kind: Kind? = c.contains("cargo") ? .rust : c.range(of: #"\bgo test"#, options: .regularExpression) != nil ? .go : c.contains("swift test") ? .swift
            : c.range(of: #"\bnode\b.*--test|\bnode\s"#, options: .regularExpression) != nil && !c.contains("jest") ? .node
            : c.contains("jest") || c.contains("vitest") || c.range(of: #"\b(npm|pnpm|yarn)\b.*\btest\b"#, options: .regularExpression) != nil ? .jest
            : c.range(of: #"\b(pytest|python3?|py)\b|unittest"#, options: .regularExpression) != nil ? .python : nil
        guard let kind else {
            r.note = "Coverage is read from go, swift, cargo (with cargo-llvm-cov), node/jest/vitest and python (coverage.py, else the stdlib trace). `\(command)` is none of those; run it with its own coverage flag."
            return r
        }
        func need(_ exe: String, _ what: String) -> Bool { if ProcessRunner.which(exe) == nil { r.note = "`\(what)` is not installed on this Mac; nothing was installed."; return false }; return true }
        let root: URL
        do { root = try Scratch.make() } catch { r.note = "Could not make a scratch folder: \(error.localizedDescription)"; return r }
        defer { try? FileManager.default.removeItem(at: root) }
        do { let list = await Scratch.listing(ws); r.left = list.leftOut; try Scratch.populate(root, from: ws, files: list.files) } catch { r.note = "Could not copy the project: \(error.localizedDescription)"; return r }
        let shell = ShellEnvironment.shared.get("SHELL").flatMap { $0.hasSuffix("zsh") || $0.hasSuffix("bash") ? $0 : nil } ?? "/bin/zsh"
        let cmd = Scratch.command(c, from: ws, to: root)
        func sh(_ s: String) async -> ProcessResult { await ProcessRunner.run(shell, ["-c", s], cwd: root, timeout: seconds) }
        let rootPath = WriteFence.real(root)
        progress("Running the tests with coverage…")
        switch kind {
        case .go:
            guard need("go", "go") else { return r }
            r.tool = "go test -coverprofile"
            let out = await sh(cmd.replacingOccurrences(of: "go test", with: "go test -coverprofile=cover.out\(cmd.contains("-coverpkg") ? "" : " -coverpkg=./...")", options: [], range: cmd.range(of: "go test")))
            r.output = String(out.combined.suffix(1500))
            guard let prof = try? String(contentsOf: root.appendingPathComponent("cover.out"), encoding: .utf8) else { r.note = "No cover profile came out (the tests may not build)."; return r }
            let mod = (try? String(contentsOf: root.appendingPathComponent("go.mod"), encoding: .utf8))?.split(separator: "\n").first { $0.hasPrefix("module ") }.map { $0.dropFirst(7).trimmingCharacters(in: .whitespaces) }
            r.files = goProfile(prof, module: mod)
        case .swift:
            guard need("swift", "swift") else { return r }
            r.tool = "swift test --enable-code-coverage"
            let out = await sh(cmd.replacingOccurrences(of: "swift test", with: "swift test --enable-code-coverage", options: [], range: cmd.range(of: "swift test")))
            r.output = String(out.combined.suffix(1500))
            let path = (await sh("swift test --show-codecov-path")).stdout.split(separator: "\n").last.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
            guard !path.isEmpty, let data = FileManager.default.contents(atPath: path) else { r.note = "swift test produced no coverage JSON (the tests may not build)."; return r }
            r.files = llvmJSON(data, root: rootPath)
        case .rust:
            guard need("cargo", "cargo"), (await sh("cargo llvm-cov --version")).exitCode == 0 else { r.note = "`cargo-llvm-cov` is not installed on this Mac; nothing was installed."; return r }
            r.tool = "cargo llvm-cov"
            let out = await sh("cargo llvm-cov --json --output-path cov.json")
            r.output = String(out.combined.suffix(1500))
            guard let data = FileManager.default.contents(atPath: root.appendingPathComponent("cov.json").path) else { r.note = "cargo llvm-cov produced no report (the tests may not build)."; return r }
            r.files = llvmJSON(data, root: rootPath)
        case .node, .jest:
            guard need("node", "node") else { return r }
            let injected = kind == .node ? (cmd.contains("--test") ? cmd.replacingOccurrences(of: "--test", with: "--experimental-test-coverage --test") : cmd.replacingOccurrences(of: "node ", with: "node --experimental-test-coverage ", options: [], range: cmd.range(of: "node ")))
                : cmd.contains("jest") || cmd.contains("vitest") ? cmd + " --coverage --coverageReporters=text" : cmd + " -- --coverage"
            r.tool = kind == .node ? "node --experimental-test-coverage" : "--coverage"
            let out = await sh(injected)
            r.output = String(out.combined.suffix(1500))
            r.files = table(out.combined)
            if r.files.isEmpty { r.note = "No coverage table in the output (the runner may not support a coverage flag, or the tests failed to start)." }
        case .python:
            guard need("python3", "python3") else { return r }
            let hasCov = (await sh("python3 -c 'import coverage'")).exitCode == 0
            let mod = try? NSRegularExpression(pattern: #"^(?:python3?|py)\s+-m\s+(\S+)(.*)$"#), file = try? NSRegularExpression(pattern: #"^(?:python3?|py)\s+(\S+\.py)(.*)$"#), bare = try? NSRegularExpression(pattern: #"^(pytest|py\.test)(.*)$"#)
            func group(_ re: NSRegularExpression?) -> (String, String)? {
                guard let m = re?.firstMatch(in: cmd, range: NSRange(cmd.startIndex..., in: cmd)) else { return nil }
                return ((cmd as NSString).substring(with: m.range(at: 1)), (cmd as NSString).substring(with: m.range(at: 2)))
            }
            let target: (module: Bool, name: String, rest: String)? = group(mod).map { (true, $0.0, $0.1) } ?? group(file).map { (false, $0.0, $0.1) } ?? group(bare).map { (true, $0.0 == "py.test" ? "pytest" : $0.0, $0.1) }
            guard let t = target else { r.note = "Could not read `\(command)` as a Python command (python3 -m …, python3 file.py or pytest)."; return r }
            if hasCov {
                r.tool = "coverage.py"
                let run = await sh("python3 -m coverage run --source=. \(t.module ? "-m " : "")\(t.name)\(t.rest)")
                r.output = String(run.combined.suffix(1500))
                _ = await sh("python3 -m coverage json -o cov.json")
                guard let data = FileManager.default.contents(atPath: root.appendingPathComponent("cov.json").path) else { r.note = "coverage.py produced no report."; return r }
                r.files = coveragePy(data)
            } else {
                r.tool = "python3 -m trace (stdlib)"
                let libs = #"$(python3 -c "import sysconfig;print(':'.join({sysconfig.get_paths()[k] for k in ('stdlib','platstdlib','purelib','platlib')}))")"#
                let run = await sh("python3 -m trace --count --missing --ignore-dir=\"\(libs)\" \(t.module ? "--module " : "")\(t.name)\(t.rest)")
                r.output = String(run.combined.suffix(1500))
                let all = (FileManager.default.enumerator(atPath: root.path)?.allObjects as? [String] ?? []).filter { $0.hasSuffix(".py") && !$0.hasPrefix("node_modules") }
                r.files = traceCover(in: root, sources: all)
            }
        }
        r.files = r.files.filter { isMine($0.path) && $0.total > 0 }
        if r.files.isEmpty, r.note == nil { r.note = "The run reported no coverage for the learner's source files.\n" + r.output }
        return r
    }

    static func render(_ r: Report, ws: Workspace? = nil) -> String {
        if let n = r.note, r.files.isEmpty { return n }
        let n = "\(r.files.count) source file\(r.files.count == 1 ? "" : "s")"
        var s = r.exact ? "Coverage by \(r.tool): \(String(format: "%.0f", r.percent))% of the lines in \(n) ran (tests excluded).\n"
            : "Coverage by \(r.tool): the \(n) average \(String(format: "%.0f", r.percent))% each (the runner prints percentages per file, not line counts; tests excluded).\n"
        if let l = r.left { s += "Left out of the scratch copy: \(l).\n" }
        for f in r.files {
            s += "\(f.path)  \(String(format: "%.0f", f.percent))%" + (f.counts ? " (\(f.covered)/\(f.total))" : "")
            if !f.missing.isEmpty {
                let names = ws.flatMap { w in (try? String(contentsOf: w.url.appendingPathComponent(f.path), encoding: .utf8)).map { SymbolsTool.outline($0, ext: (f.path as NSString).pathExtension.lowercased()).filter { $0.kind == "function" } } } ?? []
                func inFn(_ r: ClosedRange<Int>) -> String { names.last { $0.line <= r.lowerBound }.map { " (in \($0.name))" } ?? "" }
                s += "\n    never run: " + f.missing.prefix(14).map { text($0) + inFn($0) }.joined(separator: ", ") + (f.missing.count > 14 ? ", … \(f.missing.count - 14) more" : "")
            }
            s += "\n"
        }
        s += "\nA line that ran is not a line that was checked (`mutate` measures that). For each never-run range, ask the learner what behaviour lives there and what input would reach it; do not write the test. Information only."
        return s
    }

    static func meta(_ r: Report) -> JSON {
        ["tool": .string(r.tool), "exact": .bool(r.exact), "percent": .number((r.percent * 10).rounded() / 10), "note": r.note.map { .string($0) } ?? .null,
         "files": .array(r.files.map { f in ["path": .string(f.path), "percent": .number((f.percent * 10).rounded() / 10), "counts": .bool(f.counts), "covered": .number(Double(f.covered)), "total": .number(Double(f.total)),
                                              "missing": .array(f.missing.prefix(40).map { .array([.number(Double($0.lowerBound)), .number(Double($0.upperBound))]) })] })]
    }
}

struct CoverageTool: Tool {
    let name = "coverage"
    let description = """
    Which lines do the learner's tests never run? Runs the registered test command in a scratch copy (their folder is \
    untouched) with the toolchain's own coverage: Go, SwiftPM, cargo-llvm-cov, node/jest/vitest, Python (coverage.py, else \
    the stdlib trace). You get per-file percentages and the never-run line ranges; the learner gets a card. A tool \
    that isn't installed is named, never installed. Ranges are questions for them ("what is this branch for, what input \
    reaches it?"), not tests you write. Ran is not checked: `mutate` measures whether tests would notice a bug.
    """
    let risk = ToolRisk.execute
    var schema: JSON {
        Schema.object([
            "command": Schema.string("Test command (default: the project's registered one)."),
            "seconds": Schema.integer("Time limit (default 300, max 900)."),
        ])
    }
    func summary(_ input: JSON) -> String { "test coverage" }
    func timeout(_ input: JSON) -> Double? { Double(min(900, max(30, input["seconds"]?.int ?? 300))) + 60 }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let ws = ctx.services.workspace
        let r = await Coverage.run(ws: ws, command: input["command"]?.string, seconds: TimeInterval(min(900, max(30, input["seconds"]?.int ?? 300))), progress: ctx.progress)
        return ToolOutput(text: Coverage.render(r, ws: ws), isError: r.files.isEmpty, meta: Coverage.meta(r))
    }
}
