import Foundation

/// An OS-enforced boundary for the programs a tool call starts: a `sandbox-exec` profile that lets them write anywhere
/// except where the fence says. The code mentor fences its commands off the learner's files and the project's tests and
/// state, so a heredoc or a script can't overwrite their work, rewrite a test or edit the review record. Unlike putting
/// files back afterwards, nothing the learner saves meanwhile is touched.
/// Set for a call with `WriteFence.$profile.withValue(...)`; `ProcessRunner` and `ShellJob` start their programs under it.
enum WriteFence {
    @TaskLocal static var profile: String?

    static let sandboxExec = "/usr/bin/sandbox-exec"
    static let available: Bool = FileManager.default.isExecutableFile(atPath: sandboxExec)

    /// The program to start, under the current fence if there is one.
    static func wrap(_ executable: String, _ args: [String], profile given: String? = WriteFence.profile) -> (String, [String]) {
        guard let profile = given, available else { return (executable, args) }
        return (sandboxExec, ["-p", profile, executable] + args)
    }

    /// The path as the kernel sees it. `resolvingSymlinksInPath` strips a leading /private, which the sandbox never
    /// matches; a path that doesn't exist yet is its parent's real path plus its name.
    static func real(_ u: URL) -> String {
        if let r = realpath(u.path, nil) { defer { free(r) }; return String(cString: r) }
        let parent = u.deletingLastPathComponent()
        return parent.path == u.path ? u.path : real(parent) + "/" + u.lastPathComponent
    }

    /// Whether a program that started under `started` is still protected as much as `current` requires: every path `current` denies
    /// is denied by `started` too, and everything `started` opened up for writing is open in `current` (the tests unlocked at the
    /// start may be locked now, which this refuses; the other way is fine). A path that did not exist when the session began
    /// (a lock file a build wrote, a file the learner saved since) is not counted: a running program could not have been fenced
    /// from it, and ending the session for every such file would end it for every build.
    static func covers(started: String, current: String, since: Date) -> Bool {
        let old = rules(started), now = rules(current)
        for (path, kind) in now.denied where !old.denied.contains(where: { $0.0 == path && $0.1 == kind }) {
            let attrs = try? FileManager.default.attributesOfItem(atPath: path)
            let born = (attrs?[.creationDate] as? Date) ?? Date.distantPast
            if attrs != nil, born > since { continue }
            return false
        }
        // What the start opened up is a hole in a denied area; with nothing denied now, nothing needs it open.
        if !now.denied.isEmpty { for open in old.allowed where !now.allowed.contains(where: { $0.0 == open.0 && $0.1 == open.1 }) { return false } }
        return true
    }

    /// The (path, literal|subpath) pairs under each deny and allow form of a profile.
    private static func rules(_ profile: String) -> (denied: [(String, String)], allowed: [(String, String)]) {
        var denied: [(String, String)] = [], allowed: [(String, String)] = []
        guard let re = try? NSRegularExpression(pattern: #"\((literal|subpath) "((?:[^"\\]|\\.)*)"\)"#) else { return (denied, allowed) }
        for form in profile.components(separatedBy: "\n(") {
            let isDeny = form.hasPrefix("deny") || form.hasPrefix("(deny"), isAllow = form.hasPrefix("allow") || form.hasPrefix("(allow")
            guard isDeny || isAllow else { continue }
            let ns = form as NSString
            for m in re.matches(in: form, range: NSRange(location: 0, length: ns.length)) {
                let path = ns.substring(with: m.range(at: 2)).replacingOccurrences(of: "\\\"", with: "\"").replacingOccurrences(of: "\\\\", with: "\\")
                if isDeny { denied.append((path, ns.substring(with: m.range(at: 1)))) } else { allowed.append((path, ns.substring(with: m.range(at: 1)))) }
            }
        }
        return (denied, allowed)
    }

    /// A profile that denies writing `files` (each one: edit, delete, rename), denies everything under each of `locked`,
    /// and allows writing under each of `open` (more specific, so it wins over `locked`). Everything else is writable, so
    /// any toolchain's build output works. Paths are resolved: the sandbox sees /private/tmp, not /tmp.
    static func profile(files: [URL], locked: [URL], open: [URL]) -> String {
        func lit(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        var p = "(version 1)\n(allow default)\n"
        for u in locked { p += "(deny file-write* file-write-create (subpath \(lit(real(u)))))\n" }
        for u in open { p += "(allow file-write* file-write-create (subpath \(lit(real(u)))))\n" }
        if !files.isEmpty { p += "(deny file-write*\n" + files.map { "  (literal \(lit(real($0))))" }.joined(separator: "\n") + ")\n" }
        return p
    }
}
