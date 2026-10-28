import Foundation

/// A project's own instruction files (CLAUDE.md, AGENTS.md) in its subfolders.
enum InstructionFiles {
    /// Instruction files in the folders between `file` and the project root (not the root's own): Claude Code reads a
    /// subfolder's CLAUDE.md when it first works there.
    static func nested(for file: URL, workspace: URL) -> [URL] {
        let root = workspace.standardizedFileURL.path
        var dir = file.standardizedFileURL.deletingLastPathComponent(), out: [URL] = []
        while dir.path.hasPrefix(root + "/") {
            for name in ["CLAUDE.md", "AGENTS.md"] {
                let u = dir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: u.path) { out.insert(u, at: 0) }
            }
            dir = dir.deletingLastPathComponent()
        }
        return out
    }
}
