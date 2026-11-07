import Foundation
import CryptoKit

/// Trust for what a folder supplies to the agent as instructions: its skills, sub-agent definitions and commands. Like a
/// folder's hooks and `.mcp.json`, they reach the prompt only after the user approves their exact fingerprint (kept in
/// the app's settings, never in the folder), so a cloned repository can't put its own instructions in front of the model.
/// A change asks again; a decline holds for the lesson.
enum ProjectTrust {
    static let skillDirs = Skills.projectDirs
    static let agentDirs = [".teacher/agents", ".claude/agents"]
    static let commandDirs = [".teacher/commands", ".claude/commands"]
    static var allDirs: [String] { skillDirs + agentDirs + commandDirs }

    enum State: Equatable {
        /// Nothing there to approve.
        case none
        case approved, declined, unasked
    }

    /// Every file of the folder's skills, agents and commands (relative to the folder), and their fingerprint; nil when
    /// the folder has none (or more than the limits, which is never trusted).
    static func listing(_ folder: URL) -> (files: [String], fingerprint: String)? {
        var files: [String] = [], lines: [String] = []
        for d in allDirs {
            let dir = folder.appendingPathComponent(d)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let r = TreeDigest.scan(dir, limits: .init(files: 400, perFile: 1_000_000, total: 10_000_000, depth: 6), followLinks: true)
            if r.overLimit { return nil }
            files += r.files.map { d + "/" + $0 }
            lines.append(d + "\0" + r.digest)
        }
        guard !files.isEmpty else { return nil }
        return (files, SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined())
    }

    static func fingerprint(_ folder: URL) -> String? { listing(folder)?.fingerprint }

    /// Declines for this lesson (lesson id + fingerprint) and the questions being asked.
    private static let declined = Locked<Set<String>>([])
    private static let asking = Locked<[String: Task<Bool, Never>]>([:])

    static func state(_ folder: URL?, _ settings: AppSettings, lesson: String? = nil) -> State {
        guard let folder, let fp = fingerprint(folder) else { return .none }
        if settings.approvedProjectContent[folder.path] == fp { return .approved }
        return lesson.map { declined.get().contains($0 + fp) } == true ? .declined : .unasked
    }

    /// `folder` when its skills, agents and commands are approved as they are now; nil otherwise (or no folder).
    static func approved(_ folder: URL?, _ settings: AppSettings) -> URL? {
        guard let folder, state(folder, settings) == .approved else { return nil }
        return folder
    }

    /// Names of the folder's commands (files in its commands folders), for telling the user one awaits approval.
    static func commandNames(_ folder: URL) -> [String] {
        commandDirs.flatMap { d in ((try? FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent(d).path)) ?? [])
            .filter { $0.hasSuffix(".md") }.map { String($0.dropLast(3)).lowercased() } }
    }

    /// The one neutral line the prompt carries until the user decides.
    static let awaitingLine = "This folder has its own skills, agents or commands, which wait for the user's approval; `skill` asks them if you need one."

    /// What the approval card shows.
    static func detail(_ folder: URL, files: [String]) -> String {
        let shown = files.prefix(40).joined(separator: "\n")
        return "“\(folder.lastPathComponent)” supplies instructions for the agent: skills, sub-agent definitions or commands. They go into what the model "
            + "reads and may tell it to run things (each call is still asked).\n\n\(shown)" + (files.count > 40 ? "\n… and \(files.count - 40) more files" : "")
            + "\n\nAllowed, they apply in every lesson in this folder until a file changes. Approve only a folder you trust."
    }

    /// Whether the folder's content is approved now, asking the user once per fingerprint (a card under the calling tool).
    /// A sub-agent can't ask; it just finds the content unavailable.
    static func resolve(_ ctx: ToolContext) async -> Bool {
        let folder = ctx.workspace
        let settings = await MainActor.run { AppModel.shared.settings.value }
        guard let listing = listing(folder) else { return false }
        if settings.approvedProjectContent[folder.path] == listing.fingerprint { return true }
        let key = ctx.conversationID + listing.fingerprint
        if declined.get().contains(key) || ctx.agentDepth > 0 { return false }
        let task = asking.mutate { all -> Task<Bool, Never> in
            if let t = all[key] { return t }
            let t = Task { await ask(ctx, listing: listing, key: key) }
            all[key] = t
            return t
        }
        let ok = await task.value
        asking.mutate { $0[key] = nil }
        return ok
    }

    private static func ask(_ ctx: ToolContext, listing: (files: [String], fingerprint: String), key: String) async -> Bool {
        let folder = ctx.workspace
        let reply = await ctx.interactions.request(id: ctx.toolCallID, kind: "permission", conversationID: ctx.conversationID, payload: [
            "tool": "skill",
            "title": .string("Use the skills, agents and commands in this folder?"),
            "detail": .string(detail(folder, files: listing.files)),
            "options": .array([["id": "allow", "label": .string("Use this folder's"), "style": "primary"],
                               ["id": "deny", "label": "Don't use them", "style": "danger"]]),
        ])
        let allowed = reply["cancelled"]?.bool != true && reply["decision"]?.string == "allow"
        if allowed { await MainActor.run { AppModel.shared.settings.value.approvedProjectContent[folder.path] = listing.fingerprint } }
        else if reply["cancelled"]?.bool != true { declined.mutate { _ = $0.insert(key) } }
        return allowed
    }
}
