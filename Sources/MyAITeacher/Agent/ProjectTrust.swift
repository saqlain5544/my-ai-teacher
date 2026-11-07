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
        /// Can't be offered for approval at all (too big, or a link into credentials): the reason, for the user.
        case blocked(String)
    }

    struct Listing {
        /// Files whose content is in the fingerprint, and the others (path and size only), relative to the folder.
        var files: [String] = [], other: [String] = []
        /// Each symlink and where it really points, for the card.
        var links: [String] = []
        var fingerprint = ""
        var blocked: String?
    }

    /// What reaches a prompt is hashed: each `SKILL.md`, agent file and command file. The rest of a skill's folder (scripts,
    /// assets) is listed by path and size, so ordinary bundled files can't trip the limit; the agent reads or runs them
    /// through its own tools, each under the usual approvals. `node_modules` and `.git` are left out altogether.
    static let limits = TreeDigest.Limits(files: 400, perFile: 1_000_000, total: 10_000_000, depth: 8, listed: 20_000)

    /// The folder's skills, agents and commands, and their fingerprint; nil when it has none.
    static func listing(_ folder: URL) -> Listing? {
        var l = Listing(), lines: [String] = []
        for d in allDirs {
            let dir = folder.appendingPathComponent(d)
            guard FileManager.default.fileExists(atPath: dir.path) else { continue }
            let isSkills = skillDirs.contains(d)
            let r = TreeDigest.scan(dir, limits: limits, followLinks: true, skip: TreeDigest.vendored,
                                    // Case-insensitively, as the loader's open finds `skill.md` for `SKILL.md` on APFS.
                                    hashes: { isSkills ? ($0 as NSString).lastPathComponent.lowercased() == "skill.md" : $0.lowercased().hasSuffix(".md") })
            // A folder holding nothing that counts (only litter and caches) is as if it weren't there.
            guard !(r.files + r.listed).isEmpty || !r.links.isEmpty || r.overLimit || !r.forbidden.isEmpty else { continue }
            if r.overLimit {
                l.blocked = "“\(d)” is larger than a skills, agents or commands folder can be (\(limits.files) hashed files, \(limits.perFile / 1_000_000) MB each, \(limits.listed) files in all)."
            }
            if let bad = r.forbidden.first { l.blocked = l.blocked ?? "“\(d)/\(bad)” is a link into a credential location (\(r.links[bad] ?? ""))." }
            l.files += r.files.map { d + "/" + $0 }
            l.other += r.listed.map { d + "/" + $0 }
            l.links += r.links.keys.sorted().map { "\(d)/\($0) → \(r.links[$0]!)" }
            lines.append(d + "\0" + r.digest)
        }
        guard !(l.files + l.other).isEmpty || l.blocked != nil else { return nil }
        l.fingerprint = SHA256.hash(data: Data(lines.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
        return l
    }

    /// The fingerprint approval is for; nil when there is nothing, or it can't be approved.
    static func fingerprint(_ folder: URL) -> String? { listing(folder).flatMap { $0.blocked == nil ? $0.fingerprint : nil } }

    /// Reads the folder's files off the calling actor, so the next `state` on the main actor finds their hashes known.
    static func warm(_ folder: URL) async { _ = listing(folder) }

    /// Declines for this lesson (lesson id + fingerprint) and the questions being asked.
    private static let declined = Locked<Set<String>>([])
    private static let asking = Locked<[String: Task<Bool, Never>]>([:])

    static func state(_ folder: URL?, _ settings: AppSettings, lesson: String? = nil) -> State {
        guard let folder, let l = listing(folder) else { return .none }
        if let why = l.blocked { return .blocked(why) }
        let fp = l.fingerprint
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
            .filter { $0.hasSuffix(".md") && !TreeDigest.neverLoaded($0) }.map { String($0.dropLast(3)).lowercased() } }
    }

    /// The one neutral line the prompt carries until the user decides.
    static let awaitingLine = "This folder has its own skills, agents or commands, which wait for the user's approval; `skill` asks them if you need one."

    /// What the approval card shows: the files that are read into the model's instructions, where every symlink really leads,
    /// and the other files only by name.
    static func detail(_ folder: URL, listing l: Listing) -> String {
        var s = "“\(folder.lastPathComponent)” supplies instructions for the agent: skills, sub-agent definitions or commands. They go into what the model "
            + "reads and may tell it to run things (each call is still asked).\n\n" + l.files.prefix(40).map { Plugin.visible($0, max: 160) }.joined(separator: "\n")
        if l.files.count > 40 { s += "\n… and \(l.files.count - 40) more files" }
        if !l.links.isEmpty { s += "\n\nSymlinks (their content is part of this approval):\n" + l.links.prefix(20).map { Plugin.visible($0, max: 300) }.joined(separator: "\n") }
        if !l.other.isEmpty { s += "\n\n\(l.other.count) other files alongside (scripts, assets), not part of the fingerprint: " + l.other.prefix(8).map { Plugin.visible($0, max: 100) }.joined(separator: ", ") + (l.other.count > 8 ? "…" : "") }
        return s + "\n\nAllowed, they apply in every lesson in this folder until one of those files changes. Approve only a folder you trust."
    }

    /// Whether the folder's content is approved now, asking the user once per fingerprint (a card under the calling tool).
    /// A sub-agent can't ask; it just finds the content unavailable.
    static func resolve(_ ctx: ToolContext) async -> Bool {
        let folder = ctx.workspace
        let settings = await MainActor.run { AppModel.shared.settings.value }
        guard let listing = listing(folder), listing.blocked == nil else { return false }
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

    private static func ask(_ ctx: ToolContext, listing: Listing, key: String) async -> Bool {
        let folder = ctx.workspace
        let reply = await ctx.interactions.request(id: ctx.toolCallID, kind: "permission", conversationID: ctx.conversationID, payload: [
            "tool": "skill",
            "title": .string("Use the skills, agents and commands in this folder?"),
            "detail": .string(detail(folder, listing: listing)),
            "options": .array([["id": "allow", "label": .string("Use this folder's"), "style": "primary"],
                               ["id": "deny", "label": "Don't use them", "style": "danger"]]),
        ])
        let allowed = reply["cancelled"]?.bool != true && reply["decision"]?.string == "allow"
        if allowed { await MainActor.run { AppModel.shared.settings.value.approvedProjectContent[folder.path] = listing.fingerprint } }
        else if reply["cancelled"]?.bool != true { declined.mutate { _ = $0.insert(key) } }
        return allowed
    }
}

/// What a folder and the user's plugins supply that a lesson can use, by name: skills, agent types and commands. Read off the
/// main actor (it walks and parses files).
enum ContentScan {
    nonisolated static func usable(node: String, folder: URL, settings: AppSettings) async -> [String] {
        var out = Set(Skills.available(node: node, folder: ProjectTrust.approved(folder, settings), plugins: Plugins.active(settings))
            .filter { s in if case .app = s.source { return false }; return !s.hidden }.map { "skill " + $0.name })
        out.formUnion(AgentCatalog.all(settings: settings, folder: folder).filter { $0.source == .project || $0.source == .plugin }.map { "agent " + $0.name })
        out.formUnion(CustomCommands.available(folder: folder, settings: settings).map { "command /" + $0.name })
        return out.sorted()
    }
}
