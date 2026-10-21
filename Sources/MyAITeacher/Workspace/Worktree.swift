import Foundation

/// A git worktree a coder sub-agent works on, so its edits never touch the learner's checkout until they choose to
/// merge. It lives in the app's support folder (not the project); git records it in the repository's `.git/worktrees`.
/// It starts from HEAD: uncommitted changes in the folder aren't in it. One the agent changed is kept for
/// `keepDays`, then removed (with its `teacher/…` branch) at a later launch.
struct Worktree: Sendable {
    let repo: URL      // the repository's top level
    let path: URL      // the worktree's top level
    let branch: String
    let base: String   // the commit it started from
    let root: URL      // where the agent works: the lesson folder's place inside the worktree

    static var git: String { ProcessRunner.which("git") ?? "/usr/bin/git" }
    static let keepDays = 14
    static var dir: URL { AppPaths.support.appendingPathComponent("worktrees", isDirectory: true) }
    /// Config the repository can't override for these commands: no hooks (a checkout would run post-checkout) and no
    /// fsmonitor (status would run it).
    static let safe = ["-c", "core.hooksPath=/dev/null", "-c", "core.fsmonitor=false"]

    static func run(_ args: [String], timeout: TimeInterval = 60) async -> ProcessResult {
        await ProcessRunner.run(git, safe + args, timeout: timeout)
    }

    static func create(folder: URL, label: String) async throws -> Worktree {
        let top = await run(["-C", folder.path, "rev-parse", "--show-toplevel"], timeout: 20)
        let repoPath = top.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard top.exitCode == 0, !repoPath.isEmpty else { throw ToolError("“\(folder.lastPathComponent)” isn't a git repository, so there is nothing to make a worktree of.") }
        let repo = URL(fileURLWithPath: repoPath).resolvingSymlinksInPath()
        let head = await run(["-C", repo.path, "rev-parse", "HEAD"], timeout: 20)
        let base = head.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard head.exitCode == 0, !base.isEmpty else { throw ToolError("The repository has no commits yet; commit once before using a worktree.") }
        let tag = label.lowercased().filter { $0.isLetter || $0.isNumber } + "-" + UUID().uuidString.prefix(6).lowercased()
        var h: UInt64 = 0xcbf29ce484222325   // FNV-1a: the same folder per repository across launches
        for b in repo.path.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        let parent = dir.appendingPathComponent(repo.lastPathComponent + "-" + String(h % 1_000_000), isDirectory: true)
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let path = parent.appendingPathComponent(tag, isDirectory: true)
        let branch = "teacher/" + tag
        let add = await run(["-C", repo.path, "worktree", "add", "-q", "-b", branch, path.path, base], timeout: 120)
        guard add.exitCode == 0 else { throw ToolError("git worktree add failed: \(add.combined.prefix(400))") }
        let folderReal = folder.resolvingSymlinksInPath().path
        let rel = folderReal == repo.path ? "" : String(folderReal.dropFirst(repo.path.count + 1))
        return Worktree(repo: repo, path: path, branch: branch, base: base, root: rel.isEmpty ? path : path.appendingPathComponent(rel, isDirectory: true))
    }

    private static let finishing = Locked<[String: Task<String, Never>]>([:])

    /// Removes the worktree if the agent changed nothing; otherwise keeps it and says where the changes are. Callers
    /// that race (the run's own end, and its settling from outside) share one pass and one answer.
    func finish() async -> String {
        let me = self
        let task = Self.finishing.mutate { f -> Task<String, Never> in
            if let t = f[path.path] { return t }
            let t = Task { await me.finishOnce() }
            f[path.path] = t
            return t
        }
        return await task.value
    }

    private func finishOnce() async -> String {
        guard FileManager.default.fileExists(atPath: path.path) else { return "Its git worktree is gone." }
        let status = await Self.run(["-C", path.path, "status", "--porcelain"], timeout: 30)
        let head = await Self.run(["-C", path.path, "rev-parse", "HEAD"], timeout: 20)
        let changed = !status.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            || head.stdout.trimmingCharacters(in: .whitespacesAndNewlines) != base
        guard changed else {
            _ = await Self.run(["-C", repo.path, "worktree", "remove", "--force", path.path])
            _ = await Self.run(["-C", repo.path, "branch", "-D", branch], timeout: 20)
            return "It worked on a git worktree and changed nothing (the worktree was removed)."
        }
        let stat = await Self.run(["-C", path.path, "diff", "--stat", base], timeout: 30)
        return """
        Its changes are on a git worktree, not in the folder: \(path.path) (branch `\(branch)`, from \(base.prefix(8))). \
        Review them with `git -C \(path.path.shellQuoted) diff \(base.prefix(8))` and copy or merge what you want; untracked files show in \
        `git -C \(path.path.shellQuoted) status`. It is removed with its branch after \(Self.keepDays) days.
        \(stat.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    /// At launch: worktrees kept longer than `keepDays` (unless something is still writing in them) are removed with
    /// their `teacher/…` branch, and each repository forgets worktrees whose folders are gone.
    static func pruneStale(now: Date = Date()) async {
        let fm = FileManager.default
        for group in (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? [] {
            var repos = Set<String>()
            for wt in (try? fm.contentsOfDirectory(at: group, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [] {
                // `.git` in a worktree is a file: "gitdir: <repo>/.git/worktrees/<name>".
                guard let link = try? String(contentsOf: wt.appendingPathComponent(".git"), encoding: .utf8),
                      let r = link.range(of: "gitdir: ") else { continue }
                let gitdir = link[r.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
                guard let dotGit = gitdir.range(of: "/.git/worktrees/") else { continue }
                let repo = String(gitdir[..<dotGit.lowerBound])
                repos.insert(repo)
                let age = now.timeIntervalSince(newest(in: wt))
                guard age > Double(keepDays) * 86_400 else { continue }
                _ = await run(["-C", repo, "worktree", "remove", "--force", wt.path])
                _ = await run(["-C", repo, "branch", "-D", "teacher/" + wt.lastPathComponent], timeout: 20)
            }
            for repo in repos { _ = await run(["-C", repo, "worktree", "prune"], timeout: 30) }
            if ((try? fm.contentsOfDirectory(atPath: group.path)) ?? []).isEmpty { try? fm.removeItem(at: group) }
        }
    }

    /// The latest change anywhere in a worktree (its top level and first-level entries: enough to see recent work).
    private static func newest(in wt: URL) -> Date {
        let fm = FileManager.default
        let entries = [wt] + ((try? fm.contentsOfDirectory(at: wt, includingPropertiesForKeys: [.contentModificationDateKey])) ?? [])
        return entries.compactMap { try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate }.max() ?? .distantPast
    }
}
