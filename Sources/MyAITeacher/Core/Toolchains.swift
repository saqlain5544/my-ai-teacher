import Foundation

/// The language toolchains installed on this Mac, with their exact versions and (where the toolchain says) the path of
/// its standard library source. Code lessons get this in their prompt, so a mentor teaches the version the learner
/// actually has — not the one in its training data — reads the real standard library instead of searching the disk
/// (`find / -name std.zig` ran into the two-minute timeout twice in one Zig lesson), and never guesses where a compiler is.
/// Detected once per launch in the background; a lesson that starts before it finishes simply goes without.
final class Toolchains: @unchecked Sendable {
    static let shared = Toolchains()
    struct Entry: Sendable, Equatable { var name: String; var path: String; var version: String; var stdlib: String? }

    private let lock = NSLock()
    private var detected: [Entry]?
    private var started = false

    /// (command, version arguments, how to find the standard library source)
    static let probes: [(String, [String], [String]?)] = [
        ("zig", ["version"], ["env"]), ("rustc", ["--version"], ["--print", "sysroot"]), ("go", ["version"], ["env", "GOROOT"]),
        ("python3", ["--version"], nil), ("node", ["--version"], nil), ("swift", ["--version"], nil),
        ("clang", ["--version"], nil), ("gcc", ["--version"], nil), ("java", ["-version"], nil), ("ruby", ["--version"], nil),
        ("odin", ["version"], nil), ("gleam", ["--version"], nil), ("ghc", ["--version"], nil), ("ocaml", ["-version"], nil),
    ]

    var entries: [Entry]? { lock.lock(); defer { lock.unlock() }; return detected }

    func warmUp() {
        lock.lock(); if started { lock.unlock(); return }; started = true; lock.unlock()
        Task.detached(priority: .utility) {
            await ShellEnvironment.shared.waitUntilLoaded()
            var found: [Entry] = []
            for (name, args, stdArgs) in Self.probes {
                guard let path = ProcessRunner.which(name) else { continue }
                let r = await ProcessRunner.run(path, args, timeout: 5)
                guard !r.timedOut, r.exitCode == 0 else { continue }
                guard let version = Self.firstLine(r.stdout.isEmpty ? r.stderr : r.stdout) else { continue }
                var std: String?
                if let stdArgs {
                    let s = await ProcessRunner.run(path, stdArgs, timeout: 5)
                    if !s.timedOut, s.exitCode == 0 { std = Self.stdlib(name, output: s.stdout) }
                }
                found.append(Entry(name: name, path: path, version: version, stdlib: std))
            }
            self.store(found)
        }
    }
    private func store(_ found: [Entry]) { lock.withLock { detected = found } }

    static func firstLine(_ s: String) -> String? {
        let l = s.split(separator: "\n").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return l.isEmpty ? nil : String(l.prefix(120))
    }

    /// Where the toolchain keeps its standard library source, from its own report.
    static func stdlib(_ name: String, output: String) -> String? {
        let o = output.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "zig":   // `zig env` is a ZON object: .std_dir (newer), else .lib_dir + /std
            if let v = capture(#"\.std_dir\s*=\s*"([^"]+)""#, in: o) { return v }
            return capture(#"\.lib_dir\s*=\s*"([^"]+)""#, in: o).map { ($0 as NSString).appendingPathComponent("std") }
        case "rustc": return o.isEmpty ? nil : (o as NSString).appendingPathComponent("lib/rustlib/src/rust/library")
        case "go": return o.isEmpty ? nil : (o as NSString).appendingPathComponent("src")
        default: return nil
        }
    }

    private static func capture(_ pattern: String, in s: String) -> String? {
        guard let re = try? NSRegularExpression(pattern: pattern),
              let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), m.numberOfRanges > 1,
              let r = Range(m.range(at: 1), in: s) else { return nil }
        return String(s[r])
    }

    /// The prompt section (empty when nothing was detected yet).
    static func section(_ entries: [Entry]?) -> String? {
        guard let entries, !entries.isEmpty else { return nil }
        let lines = entries.map { e in
            "- \(e.name): \(e.version) — \(e.path)" + (e.stdlib.map { "; standard library source: \($0)" } ?? "")
        }
        return """
        # Toolchains on this Mac
        Teach and build for these exact versions: APIs change between releases, so when your memory and the installed \
        version disagree, the installed standard library source and compiler win (read and grep the source; compile to check). \
        Don't search the whole disk for a toolchain or its library (`find /` times out): the paths are here.
        \(lines.joined(separator: "\n"))
        """
    }
}
