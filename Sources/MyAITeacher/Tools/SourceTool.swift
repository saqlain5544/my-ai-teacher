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
            // `std.ArrayList` lives in array_list.zig, `HashMap` in hash_map.rs: the type name's snake_case is tried too.
            for r in [rel, snake(rel)] {
                let slash = r.replacingOccurrences(of: ".", with: "/")
                for c in [r, slash, slash + ".zig", r + ".zig", slash + ".py", slash + ".rs", slash + "/mod.rs"] {
                    let u = root.appendingPathComponent(c); if FileManager.default.fileExists(atPath: u.path) { return u }
                }
            }
            return nil
        }
        /// The file for `rel` under `root`, or the root itself with a note saying the name is not a file there, so an
        /// installed library never reads as missing because of how a type is spelled.
        func place(_ root: URL, _ rel: String, name: String, note: String) -> Root {
            if let u = sub(root, rel) { return Root(name: name + (rel.isEmpty ? "" : " " + rel), path: u, note: note) }
            return Root(name: name, path: root, note: "`\(rel)` is not a file or folder under \(root.path) — `find` or `grep` for it. " + note)
        }
        switch eco {
        case "zig":
            var std = entries.first { $0.name == "zig" }?.stdlib.map { URL(fileURLWithPath: $0) }
            if std == nil, let zig = tool("zig"), let env = await run(zig, ["env"]) { std = Toolchains.stdlib("zig", output: env).map { URL(fileURLWithPath: $0) } }
            guard let root = std.flatMap(dir) else { return nil }
            let rel = rest.hasPrefix("std.") ? String(rest.dropFirst(4)) : rest == "std" ? "" : rest
            return place(root, rel, name: "zig std", note: "Zig's standard library source (std.zig is the index; std/<name>.zig per namespace)")
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
            return place(dir(base) ?? root, rel, name: "rust \(crate)", note: "Rust's \(crate) source (needs the rust-src component: `rustup component add rust-src`)")
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
            return place(src, rest, name: "go " + (rest.isEmpty ? "standard library" : ""), note: "Go's standard library source under GOROOT/src (one directory per package)")
        case "python", "python3", "pip":
            guard let py = tool("python3") else { return nil }
            if rest.isEmpty {
                guard let std = await run(py, ["-c", "import sysconfig; print(sysconfig.get_paths()['stdlib'])"]) else { return nil }
                return dir(URL(fileURLWithPath: std)).map { Root(name: "python standard library", path: $0, note: "CPython's pure-Python stdlib (C modules such as _json live in the interpreter)") }
            }
            let module = rest.split(separator: " ").first.map(String.init) ?? rest
            // Located without importing it (a package's import-time code never runs from here). Output: the file or
            // <builtin>, the stdlib folder, and the import name (a pip distribution name maps to its top-level module).
            guard module.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "." || $0 == "-" }),
                  let out = await run(py, ["-c", Self.pythonLocator, module]) else { return nil }
            let lines = out.split(separator: "\n").map(String.init)
            guard lines.count == 3, let d = dir(URL(fileURLWithPath: lines[1])) else { return nil }
            let file = lines[0], name = lines[2]
            if file == "<builtin>" || file.hasSuffix(".so") || file.hasSuffix(".pyd") {
                // sys, _json… are compiled into the interpreter and math, _socket… are compiled extensions: no Python
                // source. The stdlib folder stands in, with the note saying why.
                let how = file == "<builtin>" ? "a built-in module compiled into the interpreter" : "a compiled extension module (\(file))"
                return Root(name: "python \(name)", path: d, note: "`\(name)` is \(how), without Python source (its C source is in CPython's Modules/ tree); this is the stdlib folder instead")
            }
            let u = URL(fileURLWithPath: file)
            let path = u.lastPathComponent == "__init__.py" ? u.deletingLastPathComponent() : u
            return Root(name: "python \(name)", path: path, note: "where `import \(name)` loads from")
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

    /// argv[1]: a module or pip distribution name → three lines: its file (or <builtin>), the stdlib folder, the import name.
    static let pythonLocator = """
    import importlib.util, importlib.metadata, os, sys, sysconfig
    n = sys.argv[1]; std = sysconfig.get_paths()['stdlib']
    def spec(m):
        try: return importlib.util.find_spec(m)
        except Exception: return None
    s = spec(n)
    if s is None:
        key = n.lower().replace('_', '-'); names = []
        try: names = [m for m, ds in importlib.metadata.packages_distributions().items() if key in [d.lower().replace('_', '-') for d in ds]]
        except Exception:   # Python 3.9, or a distribution without metadata: each distribution's own top_level.txt
            for d in importlib.metadata.distributions():
                try:
                    if (d.metadata['Name'] or '').lower().replace('_', '-') == key: names += (d.read_text('top_level.txt') or '').split()
                except Exception: pass
        for m in sorted(names):
            s = spec(m)
            if s is not None: n = m; break
    if s is None: sys.exit(3)
    p = s.origin if s.has_location and s.origin else None
    if p is None and s.origin == 'frozen':
        base = os.path.join(std, *n.split('.'))
        p = base + '.py' if os.path.isfile(base + '.py') else os.path.join(base, '__init__.py') if os.path.isdir(base) else None
    print(p or '<builtin>'); print(std); print(n)
    """

    /// `ArrayList` → `array_list`, `HashMap` → `hash_map`, `std.ArrayList` → `std.array_list`.
    static func snake(_ s: String) -> String {
        var out = ""
        for (i, c) in s.enumerated() {
            if c.isUppercase, i > 0, let prev = out.last, prev.isLetter || prev.isNumber, prev.isLowercase || prev.isNumber { out.append("_") }
            out.append(contentsOf: c.lowercased())
        }
        return out
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
    var subAgentVariant: Tool? { self }
    let name = "source"
    let description = """
    Read the real source of a language's standard library or an installed package, by name, wherever it lives on \
    this Mac. `library`: "zig std", "zig std.ArrayList", "rust core", "rust std collections", "go net/http", \
    "go:golang.org/x/net", "python asyncio", "pip:requests", "npm:react", "cargo:serde", "swift:swift-collections", \
    or a folder path — any language's source works by path (find it with the toolchain's own command). action="locate" (where it is and its top-level files), "find" (`query`: a file name or part of \
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
            return .error("Couldn't find the source of “\(spec)” on this Mac. Known forms: zig std, rust core|std|alloc, go <package>, go:<module>, python <module>, pip:<pkg>, npm:<pkg>, cargo:<crate>, swift:<package>, or a folder path. For any other language, ask its own toolchain where its sources live with `bash` (e.g. `gem contents <gem>`, `ghc --print-libdir`, `opam var lib`, `mix deps`, the JDK's lib/src.zip, `julia -e 'println(Sys.STDLIB)'`) and pass that folder as `library`. Never search the whole disk.")
        }
        let root = lib.path
        let fm = FileManager.default
        /// The file for `p`: under the root, absolute, or the root itself when the library resolved to one file.
        enum Found { case file(URL), problem(String) }
        func resolveFile(_ p: String) -> Found {
            var isDir: ObjCBool = false
            let rootIsFile = fm.fileExists(atPath: root.path, isDirectory: &isDir) && !isDir.boolValue
            if rootIsFile, p.isEmpty || root.lastPathComponent == p || root.path.hasSuffix("/" + p) { return .file(root) }
            guard !p.isEmpty else { return .problem("Give `path`, a file under \(root.path) (`locate` lists it).") }
            let u = p.hasPrefix("/") ? URL(fileURLWithPath: p) : root.appendingPathComponent(p)
            guard fm.fileExists(atPath: u.path, isDirectory: &isDir) else { return .problem("No file \(p) under \(root.path): `find` it by name.") }
            return isDir.boolValue ? .problem("\(u.path) is a folder: give a file in it (`locate` or `find` lists them).") : .file(u)
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
            let file: URL
            switch resolveFile(input["path"]?.string ?? "") { case .problem(let m): return .error(m); case .file(let f): file = f }
            guard let text = try? String(contentsOf: file, encoding: .utf8) else { return .error("Cannot read \(file.path).") }
            let syms = SymbolsTool.outline(text, ext: file.pathExtension.lowercased())
            if syms.isEmpty { return ToolOutput(text: "No definitions recognised in \(file.lastPathComponent) (\(text.split(separator: "\n").count) lines): `read` it.", meta: meta) }
            return ToolOutput(text: "\(file.path): \(syms.count) definitions\n" + syms.prefix(500).map { "\(String($0.line).leftPad(5))  \($0.kind == "function" ? "ƒ" : $0.kind == "type" ? "T" : "c")  \($0.text)" }.joined(separator: "\n") + (syms.count > 500 ? "\n… \(syms.count - 500) more" : ""), meta: meta)
        case "read":
            let file: URL
            switch resolveFile(input["path"]?.string ?? "") { case .problem(let m): return .error(m); case .file(let f): file = f }
            let from = max(1, input["from"]?.int ?? 1)
            let to = max(from, min(input["to"]?.int ?? (from + 200), from + 400))
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
