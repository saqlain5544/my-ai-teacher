import Foundation

/// Getting a debuggable program: the learner's build command (or the project's, or a single file built with debug flags),
/// run through the same path as `bash` (the call's `WriteFence` applies to it), and a plain answer when the binary has no
/// symbols. Go goes through `dlv` when it's installed; lldb doesn't understand goroutines.
/// A step that failed with something to tell the model.
struct DebugFailure: Error {
    let output: ToolOutput
    static func error(_ s: String) -> DebugFailure { DebugFailure(output: .error(s)) }
}

extension DebugTool {
    struct Target {
        var path: String
        var display: String
        var notes: [String] = []
        var go = false
        var language = ""
        /// The scratch folder of a single-file build.
        var scratch: URL?
    }

    static let sourceExtensions: Set<String> = ["c", "cc", "cpp", "cxx", "m", "rs", "swift", "zig"]

    static func prepare(_ input: JSON, _ ctx: ToolContext) async -> Result<Target, DebugFailure> {
        let ws = ctx.workspace
        var notes: [String] = []
        var scratch: URL?
        var program = input["program"]?.string?.trimmingCharacters(in: .whitespaces) ?? ""
        let build = input["build"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let fm = FileManager.default
        let isGo = program.hasSuffix(".go") || (program.isEmpty && build.isEmpty && fm.fileExists(atPath: ws.appendingPathComponent("go.mod").path) && inferProgram(ws) == nil)
        if isGo { return .success(Target(path: program, display: program.isEmpty ? "the Go module" : program, go: true, language: "go")) }

        if !build.isEmpty {
            let r = await ProcessRunner.run("/bin/zsh", ["-c", build], cwd: ws, timeout: 180, outputLimit: 400_000)
            if r.timedOut { return .failure(.error("The build timed out after 180 s: `\(build)`.")) }
            if r.exitCode != 0 { return .failure(.error("The build failed (exit \(r.exitCode)): `\(build)`\n" + truncateMiddle(r.combined, max: 3000))) }
            notes.append("Built with `\(build)`.")
        }
        if program.isEmpty, let p = inferProgram(ws) { program = p; notes.append("Program: \(p).") }
        guard !program.isEmpty else {
            return .failure(.error("Say which program to debug: `program` (the built executable, or one source file to build with debug flags) and, for a project, the `build` command that produces it with symbols."))
        }
        var url = resolvePath(program, workspace: ws)
        let ext = url.pathExtension.lowercased()
        if sourceExtensions.contains(ext), fm.fileExists(atPath: url.path) {
            switch await compile(url, ext) {
            case .success(let out): notes.append("Built \(url.lastPathComponent) with debug symbols and no optimisation."); url = out; scratch = out.deletingLastPathComponent()
            case .failure(let e): return .failure(e)
            }
        } else if !fm.fileExists(atPath: url.path) {
            // Not built yet: the project's own build command, once.
            if build.isEmpty {
                let profile = await ProjectProfile.detect(ws)
                if let b = profile.commands.build.first(where: { !$0.contains("<") }) {
                    let r = await ProcessRunner.run("/bin/zsh", ["-c", b], cwd: ws, timeout: 180, outputLimit: 400_000)
                    if r.exitCode != 0 { return .failure(.error("\(program) doesn't exist, and the project's build (`\(b)`) failed:\n" + truncateMiddle(r.combined, max: 3000))) }
                    notes.append("\(program) didn't exist; built with the project's `\(b)`.")
                }
            }
            guard fm.fileExists(atPath: url.path) else {
                return .failure(.error("\(program) doesn't exist. Build it with debug symbols first (`build`: e.g. `cargo build`, `swift build`, `clang -g -O0 -o prog main.c`) or give the source file as `program`."))
            }
        }
        var isDir: ObjCBool = false
        if fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue { return .failure(.error("\(program) is a folder, not an executable.")) }
        guard fm.isExecutableFile(atPath: url.path) else { return .failure(.error("\(program) isn't an executable file.")) }
        return .success(Target(path: url.path, display: url.lastPathComponent, notes: notes, language: ext, scratch: scratch))
    }

    /// Where the project's debug build puts its program, when a manifest says (Cargo's package, SwiftPM's executable, zig-out).
    static func inferProgram(_ ws: URL) -> String? {
        let fm = FileManager.default
        func read(_ n: String) -> String? { try? String(contentsOf: ws.appendingPathComponent(n), encoding: .utf8) }
        if let cargo = read("Cargo.toml") {
            if let m = cargo.range(of: #"(?m)^\s*name\s*=\s*"([^"]+)""#, options: .regularExpression) {
                let name = String(cargo[m]).components(separatedBy: "\"").dropFirst().first ?? ""
                if !name.isEmpty { return "target/debug/\(name)" }
            }
        }
        if let pkg = read("Package.swift") {
            let re = try? NSRegularExpression(pattern: #"\.(?:executableTarget|executable)\(\s*name:\s*"([^"]+)""#)
            let ns = pkg as NSString
            if let m = re?.firstMatch(in: pkg, range: NSRange(location: 0, length: ns.length)) { return ".build/debug/" + ns.substring(with: m.range(at: 1)) }
        }
        if let bin = try? fm.contentsOfDirectory(atPath: ws.appendingPathComponent("zig-out/bin").path), bin.count == 1 { return "zig-out/bin/" + bin[0] }
        return nil
    }

    /// One source file → an executable in a scratch folder, with symbols and no optimisation.
    static func compile(_ source: URL, _ ext: String) async -> Result<URL, DebugFailure> {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-debugbuild-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let out = dir.appendingPathComponent("prog")
        let (tool, args): (String, [String])
        switch ext {
        case "c": (tool, args) = ("clang", ["-g", "-O0", source.path, "-o", out.path])
        case "cc", "cpp", "cxx": (tool, args) = ("clang++", ["-g", "-O0", source.path, "-o", out.path])
        case "m": (tool, args) = ("clang", ["-g", "-O0", "-framework", "Foundation", source.path, "-o", out.path])
        case "rs": (tool, args) = ("rustc", ["-g", "-C", "opt-level=0", "-C", "split-debuginfo=packed", source.path, "-o", out.path])
        case "swift": (tool, args) = ("swiftc", ["-Onone", "-g", "-c", source.path, "-o", dir.appendingPathComponent("prog.o").path])
        default: (tool, args) = ("zig", ["build-exe", "-O", "Debug", source.path, "-femit-bin=" + out.path])
        }
        guard let exe = ProcessRunner.which(tool) else { return .failure(.error("`\(tool)` isn't installed on this Mac, so \(source.lastPathComponent) can't be built.")) }
        let r = await ProcessRunner.run(exe, args, cwd: dir, timeout: 180, outputLimit: 400_000)
        if r.exitCode != 0 || !FileManager.default.fileExists(atPath: ext == "swift" ? dir.appendingPathComponent("prog.o").path : out.path) {
            try? FileManager.default.removeItem(at: dir)
            return .failure(.error("\(source.lastPathComponent) didn't compile (`\(tool) \(args.dropLast(2).joined(separator: " "))`):\n" + truncateMiddle(r.combined, max: 3000)))
        }
        if ext == "swift" {
            // One step would leave the debug info in an object file swiftc deletes; linking the kept one lets lldb find it.
            let link = await ProcessRunner.run(exe, [dir.appendingPathComponent("prog.o").path, "-o", out.path], cwd: dir, timeout: 120, outputLimit: 400_000)
            if link.exitCode != 0 { try? FileManager.default.removeItem(at: dir); return .failure(.error("Linking \(source.lastPathComponent) failed:\n" + truncateMiddle(link.combined, max: 3000))) }
        }
        if ext == "zig", let d = ProcessRunner.which("dsymutil") { _ = await ProcessRunner.run(d, [out.path], cwd: dir, timeout: 60) }
        return .success(out)
    }

    // MARK: Plain answers

    /// The binary has no debug info: say which command gives it some.
    static func noDebugInfo(_ t: Target) -> String {
        let name = t.display
        var fix: String
        switch t.language {
        case "c", "": fix = "C or C++: `clang -g -O0 -o \(name) main.c` (CMake: `-DCMAKE_BUILD_TYPE=Debug`; Make: add `-g -O0` to CFLAGS)"
        case "rs": fix = "Rust: `cargo build` (the dev profile has symbols; `--release` has none unless `[profile.release] debug = true`)"
        default: fix = "C or C++: `clang -g -O0`"
        }
        let all = """
        \(name) has no debug information, so a debugger can show addresses only. Build it with symbols and no optimisation, then call `debug` again:
        - \(fix)
        - Rust: `cargo build` (not `--release`)
        - Swift: `swift build` (debug is the default; `-c release` drops most of it) or `swiftc -Onone -g`
        - Zig: `zig build-exe -O Debug main.zig` or `zig build` (not ReleaseFast/ReleaseSmall)
        Or pass the source file as `program` and it is built that way. A binary that was stripped (`strip`) or built `-O2` also lacks the lines and variables.
        """
        return all
    }

    /// A launch failure, with the likely reason when it is the OS refusing to let a debugger attach.
    static func launchError(_ e: String) -> String {
        let l = e.lowercased()
        if l.contains("not permitted") || l.contains("unable to attach") || l.contains("developer") || l.contains("authoriz") || l.contains("debugserver") {
            return "The debugger couldn't take control of the program: \(e)\nmacOS may need Developer Mode (`sudo DevToolsSecurity -enable` in Terminal, once), or the program is hardened or signed in a way that forbids debugging."
        }
        return e
    }

    // MARK: Go

    /// Go through `dlv` when installed: one scripted run, breakpoints and the stops' locals and stacks as text (no stepper:
    /// delve's output is not structured, and goroutines are not something lldb understands).
    static func delve(_ action: String, _ t: Target, _ input: JSON, _ ctx: ToolContext) async -> ToolOutput {
        guard let dlv = ProcessRunner.which("dlv") else {
            return .error("Go programs need Delve (`dlv`), which isn't installed (`go install github.com/go-delve/delve/cmd/dlv@latest`, which the learner runs; lldb doesn't understand goroutines, so this tool doesn't pretend to). Without it: `go test -race`, `GOTRACEBACK=all` for a crash's goroutine dump, `fmt.Printf` of the state, or a hand-made ```trace.")
        }
        guard action == "run" || action == "crash" else {
            return .error("Go debugging is one scripted run (`run` with breakpoints, or `crash`), not a stepping session.")
        }
        let pkg = t.path.isEmpty || t.path == "." ? "." : (t.path.hasSuffix(".go") ? t.path : "./" + t.path)
        let stops = min(20, max(1, input["max_stops"]?.int ?? 6))
        var script = ""
        let bps = (input["breakpoints"]?.array ?? []).compactMap(\.string).map(breakpoint)
        for (i, b) in bps.enumerated() {
            script += "break bp\(i + 1) \(b["at"]?.string ?? "main.main")\n"
            if let c = b["condition"]?.string { script += "condition bp\(i + 1) \(c)\n" }
        }
        if bps.isEmpty && action == "run" { script += "break main.main\n" }
        for _ in 0..<(action == "crash" ? 1 : stops) { script += "continue\nlocals\nstack 8\n" }
        script += "exit\n"
        // Built first, with the optimiser and inlining off, so `seconds` bounds the run and not the compile.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-dlv-\(UUID().uuidString.prefix(8))")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        guard let go = ProcessRunner.which("go") else { return .error("`go` isn't installed, so the program can't be built for Delve.") }
        let bin = dir.appendingPathComponent("prog").path
        let built = await ProcessRunner.run(go, ["build", "-gcflags=all=-N -l", "-o", bin, pkg], cwd: ctx.workspace, timeout: 120, outputLimit: 400_000)
        if built.exitCode != 0 { return .error("The Go build failed:\n" + truncateMiddle(built.combined, max: 3000)) }
        let file = dir.appendingPathComponent("script.init")
        try? Data(script.utf8).write(to: file)
        var args = ["exec", bin, "--allow-non-terminal-interactive=true", "--init", file.path]
        if let a = input["args"]?.array?.compactMap(\.string), !a.isEmpty { args += ["--"] + a }
        let seconds = seconds(input)
        let r = await ProcessRunner.run(dlv, args, cwd: ctx.workspace, stdin: input["stdin"]?.string ?? "", timeout: TimeInterval(seconds), outputLimit: 400_000)
        let note = r.timedOut ? "\n[Stopped after \(seconds) s: the program was still running. What it printed so far is above.]" : ""
        return ToolOutput(text: "Delve (Go) output:\n" + truncateMiddle(r.combined, max: 9000) + note, isError: r.exitCode != 0 && r.combined.isEmpty && !r.timedOut)
    }
}
