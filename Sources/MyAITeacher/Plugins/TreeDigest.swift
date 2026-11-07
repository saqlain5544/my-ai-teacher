import Foundation
import CryptoKit

/// A folder's contents as a fingerprint: every file's relative path and SHA-256, hashed together. Used for a folder's
/// skills, agents and commands, and for a plugin (every file in it). Never opens anything but regular files.
enum TreeDigest {
    struct Limits { var files = 2_000; var perFile = 2_000_000; var total = 50_000_000; var depth = 8 }

    struct Result {
        /// Relative paths of the regular files, sorted.
        var files: [String] = []
        var digest = ""
        var bytes = 0
        /// Symlinks kept as links (relative path → target), when links aren't followed.
        var links: [String: String] = [:]
        /// Of those, the ones that leave the root.
        var escaping: [String] = []
        /// Sockets, devices, pipes: never read, never installed.
        var special: [String] = []
        /// More files or bytes than the limits allow.
        var overLimit = false
    }

    /// `followLinks` false (a plugin): a symlink is recorded by its target and must stay inside `root`. True (a folder's own
    /// skills, which users do link to a shared place): the content it points at is hashed, so changing it asks again.
    /// `skip`: names left out at any depth (`.git`).
    static func scan(_ root: URL, limits: Limits = Limits(), followLinks: Bool = false, skip: Set<String> = []) -> Result {
        var r = Result(), lines: [String] = []
        let fm = FileManager.default
        let rootPath = root.resolvingSymlinksInPath().path
        func walk(_ dir: URL, _ rel: String, _ depth: Int) {
            guard depth <= limits.depth else { r.overLimit = true; return }
            guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
            for n in names.sorted() where !skip.contains(n) {
                if r.overLimit { return }
                let url = dir.appendingPathComponent(n), path = rel.isEmpty ? n : rel + "/" + n
                var type = (try? fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType) ?? nil
                if type == .typeSymbolicLink {
                    if !followLinks {
                        let target = (try? fm.destinationOfSymbolicLink(atPath: url.path)) ?? ""
                        r.links[path] = target
                        if escapes(target, from: dir, root: rootPath) { r.escaping.append(path) }
                        lines.append("L\0\(path)\0\(target)")
                        continue
                    }
                    type = (try? fm.attributesOfItem(atPath: url.resolvingSymlinksInPath().path)[.type] as? FileAttributeType) ?? nil
                }
                switch type {
                case .typeDirectory?: walk(url, path, depth + 1)
                case .typeRegular?:
                    guard r.files.count < limits.files else { r.overLimit = true; return }
                    guard let h = try? FileHandle(forReadingFrom: url) else { continue }
                    defer { try? h.close() }
                    let data = (try? h.read(upToCount: limits.perFile + 1)) ?? Data()
                    if data.count > limits.perFile { r.overLimit = true; return }
                    r.bytes += data.count
                    if r.bytes > limits.total { r.overLimit = true; return }
                    r.files.append(path)
                    lines.append("F\0\(path)\0" + SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
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

    /// Whether a link at `dir` pointing to `target` ends outside `root` (an absolute target always counts as outside:
    /// it would point elsewhere once the folder is copied).
    static func escapes(_ target: String, from dir: URL, root: String) -> Bool {
        if target.hasPrefix("/") || target.isEmpty { return true }
        let resolved = URL(fileURLWithPath: target, relativeTo: dir.resolvingSymlinksInPath()).standardized.path
        return !(resolved == root || resolved.hasPrefix(root + "/"))
    }
}
