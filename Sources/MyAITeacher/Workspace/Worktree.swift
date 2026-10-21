import Foundation

/// A git worktree a coder sub-agent works on, so its edits never touch the learner's checkout until they choose to
/// merge. It lives in the app's support folder (not the project); git records it in the repository's `.git/worktrees`.
/// It starts from HEAD: uncommitted changes in the folder aren't in it.
struct Worktree: Sendable {
    let repo: URL      // the repository's top level
    let path: URL      // the worktree's top level
    let branch: String
    let base: String   // the commit it started from
    let root: URL      // where the agent works: the lesson folder's place inside the worktree

    static var git: String { ProcessRunner.which("git") ?? "/usr/bin/git" }

    static func create(folder: URL, label: String) async throws -> Worktree {
        let top = await ProcessRunner.run(git, ["-C", folder.path, "rev-parse", "--show-toplevel"], timeout: 20)
        let repoPath = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.exitCode == 0, !repoPath.isEmpty else { throw ToolError("“\(folder.lastPathComponent)” isn't a git repository, so there is nothing to make a worktree of.") }
        let repo = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath()
        let head = await ProcessRunner.run(git, ["-C", repo.path, "rev-parse", "HEAD"], timeout: 20)
        let base = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.exitCode == 0, !base.isEmpty else { throw ToolError("The repository has no commits yet; commit once before using a worktree.") }
        let tag = label.lowercased().filter { $0.isLetter || $0.isNumber } + "-" + UUID().uuidString.prefix(6).lowercased()
        var h: UInt64 = 0xcbf29ce484222325   // FNV-1a: the same folder per repository across launches
        for b in repo.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let dir = AppPaths.support.appendingPathComponent("worktrees", isDirectory: true)
            .appendingPathComponent(repo.lastPathComponent + "-" + String(h % 1_000_000), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(tag, isDirectory: true)
        let branch = "teacher/" + tag
        let add = await ProcessRunner.run(git, ["-C", repo.path, "worktree", "add", "-q", "-b", branch, path.path, base], timeout: 120)
        guard add.exitCode == 0 else { throw ToolError("git worktree add failed: \(add.combined.prefix(400))") }
        let folderReal = folder.resolvingSymlinksInPath().path
        let rel = folderReal == repo.path ? "" : String(folderReal.dropFirst(repo.path.count + 1))
        return Worktree(repo: repo, path: path, branch: branch, base: base, root: rel.isEmpty ? path : path.appendingPathComponent(rel, isDirectory: true))
    }

    /// Removes the worktree if the agent changed nothing; otherwise keeps it and says where the changes are.
    func finish() async -> String {
        let status = await ProcessRunner.run(Self.git, ["-C", path.path, "status", "--porcelain"], timeout: 30)
        let head = await ProcessRunner.run(Self.git, ["-C", path.path, "rev-parse", "HEAD"], timeout: 20)
        let changed = !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != base
        guard changed else {
            _ = await ProcessRunner.run(Self.git, ["-C", repo.path, "worktree", "remove", "--force", path.path], timeout: 60)
            _ = await ProcessRunner.run(Self.git, ["-C", repo.path, "branch", "-D", branch], timeout: 20)
            return "It worked on a git worktree and changed nothing (the worktree was removed)."
        }
        let stat = await ProcessRunner.run(Self.git, ["-C", path.path, "diff", "--stat", base], timeout: 30)
        return """
        Its changes are on a git worktree, not in the folder: \(path.path) (branch `\(branch)`, from \(base.prefix(8))). \
        Review them with `git -C \(path.path.shellQuoted) diff \(base.prefix(8))` and copy or merge what you want; untracked files show in \
        `git -C \(path.path.shellQuoted) status`.
        \(stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }
}
