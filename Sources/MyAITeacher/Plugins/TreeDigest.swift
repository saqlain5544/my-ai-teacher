import Foundation
import CryptoKit

/// A folder's contents as a fingerprint: every file's relative path and SHA-256, hashed together. Used for a folder's
/// skills, agents and commands, and for a plugin (every file in it). Never opens anything but regular files.
enum TreeDigest {
    struct Limits { var files = 2_000; var perFile = 2_000_000; var total = 50_000_000; var depth = 8; var listed = 20_000 }

    struct Result {
        /// Relative paths of the regular files that were hashed, sorted.
        var files: [String] = []
        /// Files only listed (path and size are in the digest, not their content), when a `hashes` filter is given.
        var listed: [String] = []
        var digest = ""
        var bytes = 0
        /// Symlinks (relative path → where they point: the text of the link for a plugin, the real path for followed ones).
        var links: [String: String] = [:]
        /// Of those, the ones that leave the root or can't be shown to stay inside (plugins: links are never followed).
        var escaping: [String] = []
        /// Followed links that resolve into a credential location.
        var forbidden: [String] = []
        /// Sockets, devices, pipes: never read, never installed.
        var special: [String] = []
        /// Caches (`__pycache__`, `.cache`, `*.pyc`): left out of the digest. A plugin may make them as it runs, but
        /// can't ship them, since nobody approved them.
        var caches: [String] = []
        /// More files or bytes than the limits allow.
        var overLimit = false
    }

    /// Finder's and other tools' litter never counts: it changes by itself and means nothing.
    static func isLitter(_ name: String) -> Bool { name == ".DS_Store" || name.hasPrefix("._") }
    static func isCache(_ name: String) -> Bool { name == "__pycache__" || name == ".cache" || name.hasSuffix(".pyc") }

    /// Where a link may never lead in a folder's own content: credentials, which a command file linked to would send to the model.
    nonisolated(unsafe) static var credentialRoots: [String] = defaultCredentialRoots()
    static func defaultCredentialRoots() -> [String] {
        let home = NSHomeDirectory()
        let rel = [".ssh", ".aws", ".gnupg", ".netrc", ".config/gh", ".docker/config.json", "Library/Keychains"]
        return (rel.map { home + "/" + $0 } + [AppPaths.keys.path]).map(resolved)
    }

    /// The path with every symlink resolved (a part that doesn't exist yet is kept as is).
    static func resolved(_ path: String) -> String {
        if let r = realpath(path, nil) { defer { free(r) }; return String(cString: r) }
        let u = URL(fileURLWithPath: path)
        return u.deletingLastPathComponent().path == path ? path : resolved(u.deletingLastPathComponent().path) + "/" + u.lastPathComponent
    }
    static func inside(_ path: String, _ root: String) -> Bool { path == root || path.hasPrefix(root + "/") }

    /// Hashes of files already read, by path, size and time: a tool call asks again, and a file that didn't change isn't read.
    private static let hashed = Locked<[String: String]>([:])

    /// `followLinks` false (a plugin): a symlink is kept as a link and must resolve, on the real filesystem, to a place inside
    /// `root`; anything that can't be shown to is `escaping`. True (a folder's own skills, which users do link to a shared
    /// place): the content it points at is hashed, so changing it asks again, but a link into a credential location is `forbidden`.
    /// `skip`: names left out at any depth. `hashes`: which files (by relative path) are hashed; the others are only listed.
    static func scan(_ root: URL, limits: Limits = Limits(), followLinks: Bool = false, skip: Set<String> = [], hashes: ((String) -> Bool)? = nil) -> Result {
        var r = Result(), lines: [String] = []
        let fm = FileManager.default
        let realRoot = resolved(root.path)
        let creds = credentialRoots
        func walk(_ dir: URL, _ rel: String, _ depth: Int) {
            guard depth <= limits.depth else { r.overLimit = true; return }
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names.sorted() where !skip.contains(n) && !isLitter(n) {
                if r.overLimit { return }
                let url = dir.appendingPathComponent(n), path = rel.isEmpty ? n : rel + "/" + n
                if isCache(n) { r.caches.append(path); continue }
                var type = (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) ?? nil
                var real = url.path
                if type == .typeSymbolicLink {
                    real = resolved(url.path)
                    let exists = realpath(url.path, nil).map { free($0); return true } ?? false
                    if !followLinks {
                        let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                        r.links[path] = target
                        if !exists || !inside(real, realRoot) { r.escaping.append(path) }
                        lines.append("L\0\(path)\0\(target)")
                        continue
                    }
                    guard exists else { continue }
                    r.links[path] = real
                    if creds.contains(where: { inside(real, $0) }) { r.forbidden.append(path); continue }
                    type = (try? fm.attributesOfItem(atPath: real)[.type] as? FileAttributeType) ?? nil
                }
                switch type {
                case .typeDirectory?: walk(url, path, depth + 1)
                case .typeRegular?:
                    let attrs = try? fm.attributesOfItem(atPath: real)
                    let size = (attrs?[.size] as? Int) ?? 0
                    if let hashes, !hashes(path) {
                        guard r.listed.count < limits.listed else { r.overLimit = true; return }
                        r.listed.append(path)
                        lines.append("S\0\(path)\0\(size)")
                        continue
                    }
                    guard r.files.count < limits.files, size <= limits.perFile else { r.overLimit = true; return }
                    r.bytes += size
                    if r.bytes > limits.total { r.overLimit = true; return }
                    let stamp = "\(real)\0\(size)\0\(((attrs?[.modificationDate] as? Date)?.timeIntervalSince1970) ?? 0)"
                    var h = hashed.get()[stamp]
                    if h == nil {
                        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: real)) else { continue }
                        defer { try? fh.close() }
                        let data = (try? fh.read(upToCount: limits.perFile + 1)) ?? Data()
                        if data.count > limits.perFile { r.overLimit = true; return }
                        h = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                        hashed.mutate { if $0.count > 20_000 { $0.removeAll() }; $0[stamp] = h }
                    }
                    r.files.append(path)
                    lines.append("F\0\(path)\0\(h!)")
                case nil: continue
                default: r.special.append(path)
                }
            }
        }
        walk(root, "", 0)
        r.files.sort()
        r.digest = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return r
    }
}
