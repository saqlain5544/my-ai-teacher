import Foundation

/// What a folder is, read from its manifests: the build systems in it, how to build, check, test and lint it, which
/// languages it is written in, and its git state. The code agent gets it in its prompt, so it never has to discover
/// how a project builds, and `diagnostics` uses its check command. Detection reads a handful of files and counts
/// extensions under a cap; it never runs a build.
struct ProjectProfile: Sendable, Equatable {
    struct Commands: Sendable, Equatable {
        var build: [String] = []
        var check: [String] = []    // fast: compile/type-check without running
        var test: [String] = []
        var lint: [String] = []
        var format: [String] = []
    }
    var kinds: [String] = []                 // "Swift package", "npm (pnpm)", "Cargo", …
    var commands = Commands()
    var scripts: [String: String] = [:]      // package.json scripts
    var makeTargets: [String] = []
    var languages: [(String, Int)] = []      // by file count, most first
    var files = 0
    var git: (branch: String, dirty: Int)?
    var notes: [String] = []                 // CI, Dockerfile, monorepo hints
    var commandsDir: [String] = []           // .teacher/commands/*.md

    static func == (a: ProjectProfile, b: ProjectProfile) -> Bool { a.section() == b.section() }

    /// The project's first check command (fast), else its build.
    var checkCommand: String? { commands.check.first ?? commands.build.first }
    var testCommand: String? { commands.test.first }

    static let skip: Set<String> = [".git", "node_modules", ".build", "build", "dist", "target", "DerivedData", ".venv", "venv", "__pycache__", "Pods",
                                    ".next", ".nuxt", "out", "coverage", ".cache", "zig-cache", ".zig-cache", "zig-out", "vendor", ".teacher", ".claude"]
    static let languageByExtension: [String: String] = [
        "swift": "Swift", "m": "Objective-C", "mm": "Objective-C++", "ts": "TypeScript", "tsx": "TypeScript", "js": "JavaScript", "jsx": "JavaScript", "mjs": "JavaScript", "cjs": "JavaScript",
        "py": "Python", "rs": "Rust", "go": "Go", "zig": "Zig", "c": "C", "h": "C/C++ header", "cpp": "C++", "cc": "C++", "cxx": "C++", "hpp": "C++", "java": "Java", "kt": "Kotlin",
        "rb": "Ruby", "ex": "Elixir", "exs": "Elixir", "erl": "Erlang", "hs": "Haskell", "ml": "OCaml", "cs": "C#", "fs": "F#", "php": "PHP", "scala": "Scala", "lua": "Lua", "dart": "Dart",
        "sh": "Shell", "zsh": "Shell", "bash": "Shell", "sql": "SQL", "html": "HTML", "css": "CSS", "scss": "SCSS", "vue": "Vue", "svelte": "Svelte",
        "proto": "Protobuf", "gleam": "Gleam", "odin": "Odin", "nim": "Nim", "jl": "Julia", "r": "R", "tf": "Terraform", "sol": "Solidity",
    ]   // data and docs (json, yaml, toml, md) are not counted: a project is written in its code

    static func detect(_ folder: URL) async -> ProjectProfile {
        var p = ProjectProfile()
        let fm = FileManager.default
        let has = { (name: String) in fm.fileExists(atPath: folder.appendingPathComponent(name).path) }
        let read = { (name: String) -> String? in try? String(contentsOf: folder.appendingPathComponent(name), encoding: .utf8) }
        let top = (try? fm.contentsOfDirectory(atPath: folder.path)) ?? []

        if has("Package.swift") {
            p.kinds.append("Swift package")
            p.commands.build.append("swift build"); p.commands.check.append("swift build"); p.commands.test.append("swift test")
            p.notes.append("`swift test --filter <TestClass>` runs one class")
        }
        if let proj = top.first(where: { $0.hasSuffix(".xcworkspace") }) ?? top.first(where: { $0.hasSuffix(".xcodeproj") }) {
            p.kinds.append("Xcode (\(proj))")
            p.commands.build.append("xcodebuild -\(proj.hasSuffix(".xcworkspace") ? "workspace" : "project") \(proj) -scheme <scheme> build")
            p.notes.append("`xcodebuild -list` shows the schemes")
        }
        if let pkg = read("package.json"), let j = JSON.parse(pkg) {
            let pm = has("pnpm-lock.yaml") ? "pnpm" : has("yarn.lock") ? "yarn" : (has("bun.lockb") || has("bun.lock")) ? "bun" : "npm"
            p.kinds.append("npm package (\(pm))")
            let scripts = j["scripts"]?.object ?? [:]
            for (k, v) in scripts { if let s = v.string { p.scripts[k] = s } }
            let runCmd = { (s: String) in pm == "npm" ? (s == "test" ? "npm test" : "npm run \(s)") : "\(pm) run \(s)" }
            for (k, _) in scripts.sorted(by: { $0.key < $1.key }) {
                switch k {
                case "build": p.commands.build.append(runCmd(k))
                case "test", "test:unit": p.commands.test.append(runCmd(k))
                case "lint": p.commands.lint.append(runCmd(k))
                case "typecheck", "type-check", "check", "tsc": p.commands.check.append(runCmd(k))
                case "format", "fmt": p.commands.format.append(runCmd(k))
                default: break
                }
            }
            if has("tsconfig.json") {
                p.kinds.append("TypeScript")
                if p.commands.check.isEmpty { p.commands.check.append((pm == "npm" ? "npx" : pm == "bun" ? "bunx" : "\(pm) exec") + " tsc --noEmit -p .") }
            }
            if top.contains(where: { $0.hasPrefix("vitest.config") }) && p.commands.test.isEmpty { p.commands.test.append((pm == "npm" ? "npx" : pm) + " vitest run") }
            if top.contains(where: { $0.hasPrefix("jest.config") }) && p.commands.test.isEmpty { p.commands.test.append((pm == "npm" ? "npx" : pm) + " jest") }
            if j["workspaces"] != nil { p.notes.append("a monorepo: `workspaces` in package.json") }
        }
        if has("Cargo.toml") {
            p.kinds.append("Cargo" + (has("Cargo.lock") ? "" : " (no lockfile yet)"))
            p.commands.build.append("cargo build"); p.commands.check.append("cargo check"); p.commands.test.append("cargo test")
            p.commands.lint.append("cargo clippy"); p.commands.format.append("cargo fmt")
        }
        if has("go.mod") {
            p.kinds.append("Go module")
            p.commands.build.append("go build ./..."); p.commands.check.append("go vet ./..."); p.commands.test.append("go test ./...")
            p.commands.format.append("gofmt -l .")
        }
        if has("pyproject.toml") || has("setup.py") || has("setup.cfg") || has("requirements.txt") {
            p.kinds.append("Python project")
            let py = read("pyproject.toml") ?? ""
            if py.contains("[tool.pytest") || has("pytest.ini") || has("conftest.py") || has("tests") || has("test") { p.commands.test.append("python3 -m pytest -q") }
            else if has("manage.py") { p.commands.test.append("python3 manage.py test") }
            if ProcessRunner.which("ruff") != nil || py.contains("[tool.ruff") { p.commands.lint.append("ruff check ."); p.commands.format.append("ruff format .") }
            if py.contains("[tool.mypy") || has("mypy.ini") { p.commands.check.append("python3 -m mypy .") }
            if py.contains("[tool.pyright") || has("pyrightconfig.json") { p.commands.check.append("pyright") }
            if p.commands.check.isEmpty { p.commands.check.append("python3 -m compileall -q .") }
            if py.contains("[tool.poetry") { p.notes.append("Poetry: run tools with `poetry run …`") }
            if has("uv.lock") { p.notes.append("uv: run tools with `uv run …`") }
        }
        if has("build.zig") {
            p.kinds.append("Zig")
            p.commands.build.append("zig build"); p.commands.check.append("zig build"); p.commands.test.append("zig build test")
            p.commands.format.append("zig fmt --check .")
        }
        if has("CMakeLists.txt") {
            p.kinds.append("CMake")
            p.commands.build.append(has("build") ? "cmake --build build" : "cmake -S . -B build && cmake --build build")
            p.commands.test.append("ctest --test-dir build")
        }
        if has("build.gradle") || has("build.gradle.kts") {
            p.kinds.append("Gradle")
            let g = has("gradlew") ? "./gradlew" : "gradle"
            p.commands.build.append("\(g) build"); p.commands.test.append("\(g) test")
        }
        if has("pom.xml") { p.kinds.append("Maven"); p.commands.build.append("mvn -q compile"); p.commands.test.append("mvn -q test") }
        if has("Gemfile") {
            p.kinds.append("Ruby (Bundler)")
            if has("spec") { p.commands.test.append("bundle exec rspec") } else if has("test") { p.commands.test.append("bundle exec rake test") }
            if has("Rakefile") { p.notes.append("`rake -T` lists the tasks") }
        }
        if has("mix.exs") { p.kinds.append("Mix (Elixir)"); p.commands.build.append("mix compile"); p.commands.test.append("mix test") }
        if has("gleam.toml") { p.kinds.append("Gleam"); p.commands.build.append("gleam build"); p.commands.test.append("gleam test") }
        if has("deno.json") || has("deno.jsonc") { p.kinds.append("Deno"); p.commands.check.append("deno check ."); p.commands.test.append("deno test") }
        if let mk = read("Makefile") ?? read("makefile") {
            p.kinds.append("Makefile")
            let targets = mk.split(separator: "\n").compactMap { line -> String? in
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(".") else { return nil }
                let name = line[..<colon].trimmingCharacters(in: .whitespaces)
                guard !name.isEmpty, name.allSatisfy({ $0.isLetter || $0.isNumber || "-_".contains($0) }), !line.contains(":=") else { return nil }
                return name
            }
            p.makeTargets = Array(Array(Set(targets)).sorted().prefix(20))
            for t in ["build", "all"] where targets.contains(t) && p.commands.build.isEmpty { p.commands.build.append("make \(t)") }
            for t in ["test", "check"] where targets.contains(t) && p.commands.test.isEmpty { p.commands.test.append("make \(t)") }
            if targets.contains("lint"), p.commands.lint.isEmpty { p.commands.lint.append("make lint") }
        }
        if has("Dockerfile") || has("docker-compose.yml") || has("compose.yaml") { p.notes.append("Docker files present") }
        if has(".github/workflows") { p.notes.append("GitHub Actions workflows in .github/workflows (what CI runs)") }
        if has(".pre-commit-config.yaml") { p.notes.append("pre-commit hooks configured") }
        if has(".editorconfig") { p.notes.append(".editorconfig sets indentation") }
        if has(".teacher/commands"), let cmds = try? fm.contentsOfDirectory(atPath: folder.appendingPathComponent(".teacher/commands").path) {
            p.commandsDir = cmds.filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)) }.sorted()
        }

        // Languages by file count, bounded.
        var counts: [String: Int] = [:]
        if let e = fm.enumerator(at: folder, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsPackageDescendants, .skipsHiddenFiles]) {
            var n = 0
            while let u = e.nextObject() as? URL {
                if Self.skip.contains(u.lastPathComponent) { e.skipDescendants(); continue }
                if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
                n += 1
                if n > 20_000 { break }
                if let l = Self.languageByExtension[u.pathExtension.lowercased()] { counts[l, default: 0] += 1 }
            }
            p.files = n
        }
        p.languages = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.prefix(6).map { ($0.key, $0.value) }

        // Git, briefly.
        if fm.fileExists(atPath: folder.appendingPathComponent(".git").path) || ProcessRunner.which("git") != nil {
            let git = Worktree.git
            let branch = await ProcessRunner.run(git, Worktree.safe + ["-C", folder.path, "rev-parse", "--abbrev-ref", "HEAD"], timeout: 5)
            if branch.exitCode == 0 {
                let status = await ProcessRunner.run(git, Worktree.safe + ["-C", folder.path, "status", "--porcelain"], timeout: 10)
                let dirty = status.exitCode == 0 ? status.stdout.split(separator: "\n").count : 0
                p.git = (branch.stdout.trimmingCharacters(in: .whitespacesAndNewlines), dirty)
            }
        }
        return p
    }

    /// The prompt section. nil for a folder with nothing to say (no manifests, no code).
    func section() -> String? {
        guard !kinds.isEmpty || !languages.isEmpty || git != nil else { return nil }
        var s = "# Project\n"
        if !kinds.isEmpty { s += "- Build system: " + kinds.joined(separator: ", ") + "\n" }
        if !languages.isEmpty { s += "- Languages (files): " + languages.map { "\($0.0) \($0.1)" }.joined(separator: ", ") + " (\(files) files)\n" }
        let cmd = { (label: String, list: [String]) in list.isEmpty ? "" : "- \(label): " + list.map { "`\($0)`" }.joined(separator: ", ") + "\n" }
        s += cmd("Build", commands.build) + cmd("Check (fast, no run)", commands.check) + cmd("Test", commands.test) + cmd("Lint", commands.lint) + cmd("Format", commands.format)
        if !scripts.isEmpty && commands.build.isEmpty && commands.test.isEmpty {
            s += "- package.json scripts: " + scripts.keys.sorted().prefix(12).joined(separator: ", ") + "\n"
        }
        if !makeTargets.isEmpty { s += "- make targets: " + makeTargets.joined(separator: ", ") + "\n" }
        if let g = git { s += "- Git: branch `\(g.branch)`, \(g.dirty == 0 ? "clean" : "\(g.dirty) changed file\(g.dirty == 1 ? "" : "s") uncommitted")\n" }
        for n in notes { s += "- \(n)\n" }
        if !commandsDir.isEmpty { s += "- Project commands the user can run as /name (from .teacher/commands): " + commandsDir.joined(separator: ", ") + "\n" }
        return s.trimmingCharacters(in: .newlines)
    }
}
