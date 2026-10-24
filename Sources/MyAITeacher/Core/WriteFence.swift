import Foundation

/// An OS-enforced boundary for the programs a tool call starts: a `sandbox-exec` profile that lets them write anywhere
/// except where the fence says. The code mentor fences its commands off the learner's files and the project's tests and
/// state, so a heredoc or a script can't write a solution, rewrite a test or edit the review record. Unlike putting
/// files back afterwards, nothing the learner saves meanwhile is touched.
/// Set for a call with `WriteFence.$profile.withValue(...)`; `ProcessRunner` and `ShellJob` start their programs under it.
enum WriteFence {
    @TaskLocal static var profile: String?

    static let sandboxExec = "/usr/bin/sandbox-exec"
    static let available: Bool = FileManager.default.isExecutableFile(atPath: sandboxExec)

    /// The program to start, under the current fence if there is one.
    static func wrap(_ executable: String, _ args: [String]) -> (String, [String]) {
        guard let profile, available else { return (executable, args) }
        return (sandboxExec, ["-p", profile, executable] + args)
    }

    /// The path as the kernel sees it. `resolvingSymlinksInPath` strips a leading /private, which the sandbox never
    /// matches; a path that doesn't exist yet is its parent's real path plus its name.
    static func real(_ u: URL) -> String {
        if let r = realpath(u.path, nil) { defer { free(r) }; return String(cString: r) }
        let parent = u.deletingLastPathComponent()
        return parent.path == u.path ? u.path : real(parent) + "/" + u.lastPathComponent
    }

    /// A profile that denies writing `files` (each one: edit, delete, rename) and creating any file under `root` outside
    /// build and cache folders (dot folders and `buildDirs`), denies everything under each of `locked`, and allows
    /// writing under each of `open` (more specific, so it wins over `locked`). Paths are resolved: the sandbox sees
    /// /private/tmp, not /tmp.
    static func profile(root: URL, files: [URL], locked: [URL], open: [URL], buildDirs: Set<String>) -> String {
        func lit(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        let r = NSRegularExpression.escapedPattern(for: real(root))
        let build = buildDirs.filter { !$0.hasPrefix(".") }.sorted().map(NSRegularExpression.escapedPattern(for:)).joined(separator: "|")
        var p = "(version 1)\n(allow default)\n"
        p += "(deny file-write-create (regex #\"^\(r)/\"))\n"
        p += "(allow file-write* file-write-create (regex #\"^\(r)/(.*/)?(\\.[^/]+\(build.isEmpty ? "" : "|" + build))(/|$)\"))\n"
        for u in locked { p += "(deny file-write* file-write-create (subpath \(lit(real(u)))))\n" }
        for u in open { p += "(allow file-write* file-write-create (subpath \(lit(real(u)))))\n" }
        if !files.isEmpty { p += "(deny file-write*\n" + files.map { "  (literal \(lit(real($0))))" }.joined(separator: "\n") + ")\n" }
        return p
    }
}
