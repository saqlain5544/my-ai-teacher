import Foundation

/// A language server the app knows how to launch. Nothing here installs anything: a server that isn't on this Mac is
/// reported with the line that would install it, for the learner to run.
struct LSPServerSpec: Sendable {
    let id: String
    /// What the learner knows it as.
    let title: String
    /// Executable names, tried in order.
    let binaries: [String]
    let args: [String]
    /// File extension → LSP language id.
    let languages: [String: String]
    /// Places beyond PATH where it usually lives (`~` expands).
    let extraDirs: [String]
    let install: String
    /// A fixed executable (tests, or a path found elsewhere); skips the search.
    var executable: String? = nil
    /// Files that mark the project's root for this server (shown when none is found: the server needs them).
    var markers: [String] = []
    /// Whether it can run inside `sandbox-exec`. sourcekit-lsp cannot: its sourcekitd service aborts ("Service is invalid")
    /// under any profile, even `(allow default)` (measured), so it runs with the scrubbed environment but without the
    /// project's write fence or the credential deny rules; the approval text and the docs say so.
    var sandboxable = true
}

enum LSPServers {
    static let builtIn: [LSPServerSpec] = [
        LSPServerSpec(id: "rust-analyzer", title: "rust-analyzer", binaries: ["rust-analyzer"], args: [], languages: ["rs": "rust"],
                      extraDirs: ["~/.cargo/bin", "/opt/homebrew/bin"], install: "rustup component add rust-analyzer", markers: ["Cargo.toml"]),
        LSPServerSpec(id: "gopls", title: "gopls", binaries: ["gopls"], args: [], languages: ["go": "go"],
                      extraDirs: ["~/go/bin", "/usr/local/go/bin", "/opt/homebrew/bin"], install: "go install golang.org/x/tools/gopls@latest", markers: ["go.mod"]),
        LSPServerSpec(id: "sourcekit-lsp", title: "sourcekit-lsp", binaries: ["sourcekit-lsp"], args: [], languages: ["swift": "swift"],
                      extraDirs: ["/usr/bin"], install: "install Xcode or the Swift toolchain (swift.org)", markers: ["Package.swift"], sandboxable: false),
        LSPServerSpec(id: "typescript-language-server", title: "typescript-language-server", binaries: ["typescript-language-server"], args: ["--stdio"],
                      languages: ["ts": "typescript", "tsx": "typescriptreact", "js": "javascript", "jsx": "javascriptreact", "mjs": "javascript", "cjs": "javascript"],
                      extraDirs: ["~/.lsp-servers/bin", "/opt/homebrew/bin", "/usr/local/bin"], install: "npm install -g typescript-language-server typescript",
                      markers: ["tsconfig.json", "package.json"]),
        LSPServerSpec(id: "clangd", title: "clangd", binaries: ["clangd"], args: ["--log=error"],
                      languages: ["c": "c", "h": "c", "cpp": "cpp", "cc": "cpp", "cxx": "cpp", "hpp": "cpp", "hh": "cpp", "m": "objective-c", "mm": "objective-cpp"],
                      extraDirs: ["/usr/bin", "/opt/homebrew/opt/llvm/bin", "/opt/homebrew/bin"], install: "xcode-select --install (or brew install llvm)",
                      markers: ["compile_commands.json", "compile_flags.txt", "CMakeLists.txt"]),
        LSPServerSpec(id: "zls", title: "zls", binaries: ["zls"], args: [], languages: ["zig": "zig"],
                      extraDirs: ["/opt/homebrew/bin", "/usr/local/bin"], install: "brew install zls", markers: ["build.zig"]),
        LSPServerSpec(id: "pyright", title: "pyright", binaries: ["pyright-langserver"], args: ["--stdio"], languages: ["py": "python", "pyi": "python"],
                      extraDirs: ["~/.lsp-servers/bin", "/opt/homebrew/bin", "/usr/local/bin", "~/.local/bin"], install: "npm install -g pyright",
                      markers: ["pyproject.toml", "pyrightconfig.json"]),
        LSPServerSpec(id: "pylsp", title: "python-lsp-server", binaries: ["pylsp"], args: [], languages: ["py": "python", "pyi": "python"],
                      extraDirs: ["~/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"], install: "pipx install python-lsp-server"),
    ]

    /// The first spec that handles `ext` (lower case, no dot) and is installed; else the specs that handle it, for the
    /// message. `specs` is the registry (tests pass their own).
    static func resolve(ext: String, specs: [LSPServerSpec] = builtIn) -> Result<(LSPServerSpec, String), LSPUnavailable> {
        let candidates = specs.filter { $0.languages[ext] != nil }
        guard !candidates.isEmpty else { return .failure(LSPUnavailable(ext: ext, candidates: [])) }
        for s in candidates { if let path = executable(s) { return .success((s, path)) } }
        return .failure(LSPUnavailable(ext: ext, candidates: candidates))
    }

    static func spec(id: String, specs: [LSPServerSpec] = builtIn) -> LSPServerSpec? { specs.first { $0.id == id } }

    /// The server's executable: its fixed path, else the user's PATH (the shell's, as the shell tools see it) and its
    /// usual places.
    static func executable(_ s: LSPServerSpec) -> String? {
        if let e = s.executable { return FileManager.default.isExecutableFile(atPath: e) ? e : nil }
        for b in s.binaries {
            for d in s.extraDirs.map({ ($0 as NSString).expandingTildeInPath }) {
                let p = (d as NSString).appendingPathComponent(b)
                if FileManager.default.isExecutableFile(atPath: p), works(p) { return p }
            }
            if let p = ProcessRunner.which(b), works(p) { return p }
        }
        return nil
    }

    /// `/usr/bin/sourcekit-lsp` and friends are `xcrun` shims that exist even where no toolchain is installed; they say so
    /// when run, so a shim is only trusted once `xcrun` can find the real tool.
    private static func works(_ path: String) -> Bool {
        let rustup = path.hasPrefix(NSHomeDirectory() + "/.cargo/bin/")
        guard path.hasPrefix("/usr/bin/") || rustup else { return true }
        if let cache = shimCache.mutate({ c -> Bool? in c[path] }) { return cache }
        // `~/.cargo/bin/rust-analyzer` is a rustup proxy that exists whether or not the component is installed (and then
        // exits 1); `--version` tells. The Xcode shims in /usr/bin say it through `xcrun --find`.
        let p = Process()
        p.executableURL = URL(fileURLWithPath: rustup ? path : "/usr/bin/xcrun")
        p.arguments = rustup ? ["--version"] : ["--find", (path as NSString).lastPathComponent]
        p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        var ok = false
        if (try? p.run()) != nil {
            let end = Date().addingTimeInterval(5)
            while p.isRunning && Date() < end { usleep(20_000) }
            if p.isRunning { p.terminate() } else { ok = p.terminationStatus == 0 }
        }
        shimCache.mutate { $0[path] = ok }
        return ok
    }
    private static let shimCache = Locked<[String: Bool]>([:])

    /// The language id for a file under `spec`.
    static func languageID(_ spec: LSPServerSpec, ext: String) -> String { spec.languages[ext] ?? ext }
}

/// No usable server for a file type.
struct LSPUnavailable: Error, Sendable {
    let ext: String
    let candidates: [LSPServerSpec]
    var message: String {
        if candidates.isEmpty {
            return "No language server is set up for .\(ext) files. `code` and `symbols` still work for this language."
        }
        let names = candidates.map(\.title).joined(separator: " or ")
        let how = candidates.map { "\($0.title): \($0.install)" }.joined(separator: "; ")
        return "No language server for .\(ext) files is installed on this Mac (\(names)); the learner can install one (\(how)). The app never installs anything. `code` and `symbols` still work."
    }
}
