import Foundation

/// Where the real source of a language's standard library or an installed package lives on this Mac, resolved on
/// demand: Zig's std, Rust's std/core/alloc, Go's GOROOT and module cache, Python's stdlib and site-packages, npm
/// packages in the folder, Cargo registry crates, Swift package checkouts. The mentor teaches from it instead of
/// from memory.
enum LibrarySources {
    struct Root: Sendable, Equatable { var name: String; var path: URL; var note: String }

    private static let cache = Locked<[String: Root]>([:])

    /// "zig", "zig std", "rust core", "go net/http", "go:golang.org/x/net", "python asyncio", "pip:requests",
    /// "npm:react", "cargo:serde", "swift:swift-collections", or a directory path.
    static func resolve(_ spec: String, folder: URL) async -> Root? {
        let s = spec.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if let hit = cache.get()[s + "|" + folder.path] { return hit }
        let r = await locate(s, folder: folder)
        if let r { cache.mutate { $0[s + "|" + folder.path] = r } }
        return r
    }
    static func forget() { cache.mutate { $0 = [:] } }

    private static func locate(_ s: String, folder: URL) async -> Root? {
        var isDir: ObjCBool = false
        if s.hasPrefix("/") || s.hasPrefix("~"), FileManager.default.fileExists(atPath: (s as NSString).expandingTildeInPath, isDirectory: &isDir), isDir.boolValue {
            return Root(name: s, path: URL(fileURLWithPath: (s as NSString).expandingTildeInPath), note: "a folder")
        }
        var parts = s.split(whereSeparator: { $0 == ":" || $0 == " " }).map(String.init)
        let eco = parts.removeFirst().lowercased()
        let rest = parts.joined(separator: " ")
        let entries = Toolchains.shared.entries ?? []
        func tool(_ name: String) -> String? { entries.first { $0.name == name }?.path ?? ProcessRunner.which(name) }
        func run(_ exe: String, _ args: [String]) async -> String? {
            let r = await ProcessRunner.run(exe, args, timeout: 20)
            let out = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            return r.exitCode == 0 && !out.isEmpty ? out : nil
        }
        func dir(_ u: URL) -> URL? { var d: ObjCBool = false; return FileManager.default.fileExists(atPath: u.path, isDirectory: &d) && d.boolValue ? u : nil }
        func sub(_ root: URL, _ rel: String) -> URL? {
            guard !rel.isEmpty else { return root }
            let candidates = [rel, rel.replacingOccurrences(of: ".", with: "/"), rel.replacingOccurrences(of: ".", with: "/") + ".zig", rel + ".zig", rel + ".py", rel + ".rs"]
            for c in candidates { let u = root.appendingPathComponent(c); if FileManager.default.fileExists(atPath: u.path) { return u } }
            return nil
        }
        switch eco {
        case "zig":
            var std = entries.first { $0.name == "zig" }?.stdlib.map { URL(fileURLWithPath: $0) }
            if std == nil, let zig = tool("zig"), let env = await run(zig, ["env"]) { std = Toolchains.stdlib("zig", output: env).map { URL(fileURLWithPath: $0) } }
            guard let root = std.flatMap(dir) else { return nil }
            let rel = rest.hasPrefix("std.") ? String(rest.dropFirst(4)) : rest == "std" ? "" : rest
            return sub(root, rel).map { Root(name: "zig std" + (rel.isEmpty ? "" : " " + rel), path: $0, note: "Zig's standard library source (std.zig is the index; std/<name>.zig per namespace)") }
        case "rust", "rustc", "cargo":
            if eco == "cargo", !rest.isEmpty {
                // ~/.cargo/registry/src/<index>/<crate>-<version>: the newest version present.
                let reg = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".cargo/registry/src")
                let crate = rest.split(separator: " ").first.map(String.init) ?? rest
                let hits = ((try? FileManager.default.contentsOfDirectory(at: reg, includingPropertiesForKeys: nil)) ?? []).flatMap { idx in
                    ((try? FileManager.default.contentsOfDirectory(at: idx, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent.hasPrefix(crate + "-") && $0.lastPathComponent.dropFirst(crate.count + 1).first?.isNumber == true }
                }.sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                return hits.first.map { Root(name: "cargo crate \(crate)", path: $0, note: "the crate's source as Cargo downloaded it (src/lib.rs is the entry)") }
            }
            var lib = entries.first { $0.name == "rustc" }?.stdlib.map { URL(fileURLWithPath: $0) }
            if lib == nil, let rustc = tool("rustc"), let sysroot = await run(rustc, ["--print", "sysroot"]) { lib = URL(fileURLWithPath: sysroot).appendingPathComponent("lib/rustlib/src/rust/library") }
            guard let root = lib.flatMap(dir) else { return nil }
            let crate = rest.split(separator: " ").first.map(String.init) ?? "std"
            let base = root.appendingPathComponent(["std", "core", "alloc", "test", "proc_macro"].contains(crate) ? crate + "/src" : crate)
            let rel = rest.split(separator: " ").dropFirst().joined(separator: "/")
            return sub(dir(base) ?? root, rel).map { Root(name: "rust \(crate)", path: $0, note: "Rust's \(crate) source (needs the rust-src component: `rustup component add rust-src`)") }
        case "go":
            guard let go = tool("go") else { return nil }
            if rest.contains(".") && rest.contains("/") {   // a module path: golang.org/x/net
                guard let modcache = await run(go, ["env", "GOMODCACHE"]) else { return nil }
                let parts = rest.split(separator: "/").map(String.init)
                var base = URL(fileURLWithPath: modcache)
                for (i, p) in parts.enumerated() {
                    let hits = ((try? FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)) ?? []).filter { $0.lastPathComponent == p || $0.lastPathComponent.hasPrefix(p + "@") }
                        .sorted { $0.lastPathComponent.compare($1.lastPathComponent, options: .numeric) == .orderedDescending }
                    guard let h = hits.first else { return i == 0 ? nil : Root(name: "go module \(rest)", path: base, note: "the nearest module folder in the Go module cache") }
                    base = h
                }
                return Root(name: "go module \(rest)", path: base, note: "from the Go module cache (`go env GOMODCACHE`)")
            }
            guard let goroot = await run(go, ["env", "GOROOT"]) else { return nil }
            let src = URL(fileURLWithPath: goroot).appendingPathComponent("src")
            return sub(src, rest).map { Root(name: "go " + (rest.isEmpty ? "standard library" : rest), path: $0, note: "Go's standard library source under GOROOT/src (one directory per package)") }
        case "python", "python3", "pip":
            guard let py = tool("python3") else { return nil }
            if rest.isEmpty {
                guard let std = await run(py, ["-c", "import sysconfig; print(sysconfig.get_paths()['stdlib'])"]) else { return nil }
                return dir(URL(fileURLWithPath: std)).map { Root(name: "python standard library", path: $0, note: "CPython's pure-Python stdlib (C modules such as _json live in the interpreter)") }
            }
            let module = rest.split(separator: " ").first.map(String.init) ?? rest
            guard module.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." }),
                  let file = await run(py, ["-c", "import importlib, sys; m = importlib.import_module(sys.argv[1]); print(getattr(m, '__file__', '') or '<builtin>')", module]) else { return nil }
            if file == "<builtin>" {
                // sys, math, _json…: compiled into the interpreter. The stdlib folder stands in, with the note saying why.
                guard let std = await run(py, ["-c", "import sysconfig; print(sysconfig.get_paths()['stdlib'])"]), let d = dir(URL(fileURLWithPath: std)) else { return nil }
                return Root(name: "python \(module)", path: d, note: "`\(module)` is a built-in module without Python source (its C source is in CPython's Modules/ or Python/ tree); this is the stdlib folder instead")
            }
            let u = URL(fileURLWithPath: file)
            let path = u.lastPathComponent == "__init__.py" ? u.deletingLastPathComponent() : u
            return Root(name: "python \(module)", path: path, note: "where `import \(module)` loads from")
        case "npm", "node":
            guard !rest.isEmpty else { return nil }
            let pkg = rest.split(separator: " ").first.map(String.init) ?? rest
            var d: URL? = folder
            while let cur = d {
                let p = cur.appendingPathComponent("node_modules").appendingPathComponent(pkg)
                if let u = dir(p) { return Root(name: "npm \(pkg)", path: u, note: "the package as installed under node_modules (package.json's main/exports says where it starts)") }
                if cur.path == "/" || cur.pathComponents.count <= 2 { break }
                d = cur.deletingLastPathComponent()
            }
            return nil
        case "swift", "swiftpm":
            guard !rest.isEmpty else { return nil }
            let pkg = rest.split(separator: " ").first.map(String.init) ?? rest
            return dir(folder.appendingPathComponent(".build/checkouts").appendingPathComponent(pkg)).map { Root(name: "swift package \(pkg)", path: $0, note: "the package checkout SwiftPM made for this project") }
        default:
            // "react", "serde", "asyncio" without an ecosystem: try the folder's node_modules, then Python, then Cargo.
            if let r = await locate("npm " + s, folder: folder) { return r }
            if let r = await locate("python " + s, folder: folder), r.note.hasPrefix("where") { return r }
            if let r = await locate("cargo " + s, folder: folder) { return r }
            return nil
        }
    }

    static let skipDirs: Set<String> = ["node_modules", ".git", "__pycache__", "testdata", "target", ".build", "zig-cache", ".zig-cache"]

    /// Files under the root whose name contains `query` (case-insensitive), bounded.
    static func find(_ query: String, in root: URL, limit: Int = 100) -> [String] {
        let q = query.lowercased()
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = [], n = 0
        while let u = e.nextObject() as? URL {
            if skipDirs.contains(u.lastPathComponent) { e.skipDescendants(); continue }
            n += 1; if n > 60_000 { break }
            if (try? u.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true { continue }
            if u.lastPathComponent.lowercased().contains(q) || q.contains("/") && u.path.lowercased().contains(q) {
                out.append(String(u.path.dropFirst(root.path.count + 1)))
                if out.count >= limit { break }
            }
        }
        return out.sorted { $0.count != $1.count ? $0.count < $1.count : $0 < $1 }
    }
}

/// The mentor's window into real source: the standard library of a language or an installed package, by name.
struct SourceTool: Tool {
    let name = "source"
    let description = """
    Read the real source of a language's standard library or an installed package, by name, wherever it lives on \
    this Mac. `library`: "zig std", "zig std.ArrayList", "rust core", "rust std collections", "go net/http", \
    "go:golang.org/x/net", "python asyncio", "pip:requests", "npm:react", "cargo:serde", "swift:swift-collections", \
    or a folder path. action="locate" (where it is and its top-level files), "find" (`query`: a file name or part of \
    a path), "outline" (`path`: a file's definitions with lines), "read" (`path`, `from`, `to`: numbered lines, up to \
    400), "grep" (`query`: a regex over the library). Teach from this — the installed version — not from memory; cite \
    file and line when you explain how something is implemented.
    """
    let risk = ToolRisk.readOnly
    var schema: JSON {
        Schema.object([
            "library": Schema.string("The library (see description)."),
            "action": Schema.string("Action.", enum: ["locate", "find", "outline", "read", "grep"]),
            "path": Schema.string("outline/read: a file, relative to the library root (or absolute)."),
            "query": Schema.string("find: part of a file name or path; grep: a regular expression."),
            "from": Schema.integer("read: first line (1-based)."),
            "to": Schema.integer("read: last line (default from+200, at most from+400)."),
        ], required: ["library"])
    }
    func summary(_ input: JSON) -> String { (input["action"]?.string ?? "locate") + " " + (input["library"]?.string ?? "") + (input["path"]?.string.map { " " + $0 } ?? input["query"]?.string.map { " " + $0 } ?? "") }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let spec = try input.req("library")
        guard let lib = await LibrarySources.resolve(spec, folder: ctx.workspace) else {
            return .error("Couldn't find the source of “\(spec)” on this Mac. Known forms: zig std, rust core|std|alloc, go <package>, go:<module>, python <module>, pip:<pkg>, npm:<pkg>, cargo:<crate>, swift:<package>, or a folder path. Is the toolchain or package installed? (`bash` can check; never search the whole disk.)")
        }
        let root = lib.path
        let fm = FileManager.default
        func resolveFile(_ p: String) -> URL? {
            let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.path.hasSuffix("/" + p) ? root : root.appendingPathComponent(p)
            if fm.fileExists(atPath: u.path) { return u }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: root.path, isDirectory: &isDir), !isDir.boolValue, p.isEmpty || root.lastPathComponent == p { return root }
            return nil
        }
        let meta: JSON = ["root": .string(root.path), "name": .string(lib.name)]
        switch input["action"]?.string ?? "locate" {
        case "locate":
            var isDir: ObjCBool = false
            fm.fileExists(atPath: root.path, isDirectory: &isDir)
            var s = "\(lib.name): \(root.path)\n\(lib.note)\n"
            if isDir.boolValue {
                let items = ((try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []).filter { !$0.lastPathComponent.hasPrefix(".") }
                    .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                // Public names first (a stdlib has dozens of _private modules), 160 at most.
                let ordered = items.filter { !$0.lastPathComponent.hasPrefix("_") } + items.filter { $0.lastPathComponent.hasPrefix("_") }
                s += "\(items.count) entries" + (items.count > 160 ? " (first 160)" : "") + ":\n" + ordered.prefix(160).map { ((try? $0.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true ? $0.lastPathComponent + "/" : $0.lastPathComponent) }.joined(separator: "  ")
            } else {
                s += "A single file (\((try? fm.attributesOfItem(atPath: root.path))?[.size] as? Int ?? 0) bytes): `read` it, or `outline` it first."
            }
            return ToolOutput(text: s, meta: meta)
        case "find":
            let q = try input.req("query")
            let hits = LibrarySources.find(q, in: root)
            return ToolOutput(text: hits.isEmpty ? "No file under \(root.path) has “\(q)” in its name. Try `grep`, or `locate` to see the layout." : "\(hits.count) file(s):\n" + hits.joined(separator: "\n"), meta: meta)
        case "outline":
            guard let file = resolveFile(input["path"]?.string ?? "") else { return .error("Give `path`, a file under \(root.path).") }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .error("Cannot read \(file.path).") }
            let syms = SymbolsTool.outline(text, ext: file.pathExtension.lowercased())
            if syms.isEmpty { return ToolOutput(text: "No definitions recognised in \(file.lastPathComponent) (\(text.split(separator: "\n").count) lines): `read` it.", meta: meta) }
            return ToolOutput(text: "\(file.path): \(syms.count) definitions\n" + syms.prefix(500).map { "\(String($0.line).leftPad(5))  \($0.kind == "function" ? "ƒ" : $0.kind == "type" ? "T" : "c")  \($0.text)" }.joined(separator: "\n") + (syms.count > 500 ? "\n… \(syms.count - 500) more" : ""), meta: meta)
        case "read":
            guard let file = resolveFile(input["path"]?.string ?? "") else { return .error("Give `path`, a file under \(root.path).") }
            let from = max(1, input["from"]?.int ?? 1)
            let to = min(input["to"]?.int ?? (from + 200), from + 400)
            var r = try await ReadTool().run(["path": .string(file.path), "offset": .number(Double(from)), "limit": .number(Double(to - from + 1))], ctx)
            r.text = "\(file.path) lines \(from)–\(to):\n" + r.text
            r.meta = meta
            return r
        case "grep":
            let q = try input.req("query")
            var r = try await GrepTool().run(["pattern": .string(q), "path": .string(root.path), "output_mode": "content", "head_limit": 120], ctx)
            r.text = r.text.replacingOccurrences(of: root.path + "/", with: "")
            r.meta = meta
            return r
        default:
            return .error("Unknown action.")
        }
    }
}
