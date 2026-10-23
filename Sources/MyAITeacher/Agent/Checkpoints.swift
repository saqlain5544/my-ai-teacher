import Foundation

/// Per-turn undo for the code agent, with or without git: before the agent's first write to a file in a turn, the file
/// as it was is copied to `.teacher/checkpoints/<turn>/`; "Undo this turn's changes" under the reply puts every file
/// back (and removes the ones the turn created). Git checkpoints in the Changes panel are the user's; these are the app's.
enum Checkpoints {
    struct Entry: Codable, Sendable, Equatable {
        var path: String       // absolute path of the file
        var existed: Bool      // false: the turn created it (undo deletes it)
        var backup: String?    // file name under the turn's folder
    }
    struct Manifest: Codable, Sendable { var files: [Entry]; var createdAt: Date }

    static let keep = 40

    static func dir(_ ws: Workspace, turn: String) -> URL { ws.stateDir.appendingPathComponent("checkpoints", isDirectory: true).appendingPathComponent(turn, isDirectory: true) }
    private static func manifestURL(_ ws: Workspace, turn: String) -> URL { dir(ws, turn: turn).appendingPathComponent("manifest.json") }

    static func manifest(_ ws: Workspace, turn: String) -> Manifest? {
        guard let d = try? Data(contentsOf: manifestURL(ws, turn: turn)) else { return nil }
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(Manifest.self, from: d)
    }
    private static func save(_ m: Manifest, _ ws: Workspace, turn: String) {
        let enc = JSONEncoder(); enc.dateEncodingStrategy = .secondsSince1970
        try? FileManager.default.createDirectory(at: dir(ws, turn: turn), withIntermediateDirectories: true)
        if let d = try? enc.encode(m) { try? d.write(to: manifestURL(ws, turn: turn), options: .atomic) }
    }

    /// Records `file` before the agent changes it (once per turn per file). Returns false when the file is the app's own state.
    @discardableResult
    static func backup(_ ws: Workspace, turn: String, file: URL) -> Bool {
        let url = file.standardizedFileURL
        if ws.isStatePath(url) { return false }
        var m = manifest(ws, turn: turn) ?? Manifest(files: [], createdAt: Date())
        if m.files.contains(where: { $0.path == url.path }) { return true }
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        if exists && isDir.boolValue { return false }
        var entry = Entry(path: url.path, existed: exists, backup: nil)
        if exists {
            let name = "\(m.files.count)-" + url.lastPathComponent
            try? fm.createDirectory(at: dir(ws, turn: turn), withIntermediateDirectories: true)
            if (try? fm.copyItem(at: url, to: dir(ws, turn: turn).appendingPathComponent(name))) != nil { entry.backup = name } else { return false }
        }
        m.files.append(entry)
        save(m, ws, turn: turn)
        return true
    }

    /// Turns after `turn` whose checkpoints hold any of the same files: undoing `turn` would discard their changes.
    static func laterTurns(_ ws: Workspace, touching turn: String) -> [String] {
        guard let m = manifest(ws, turn: turn) else { return [] }
        let mine = Set(m.files.map(\.path))
        let root = ws.stateDir.appendingPathComponent("checkpoints", isDirectory: true)
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0 > turn && $0.allSatisfy(\.isNumber) }
        return names.filter { later in (manifest(ws, turn: later)?.files ?? []).contains { mine.contains($0.path) } }.sorted()
    }

    /// Puts every file of the turn back as it was, then forgets the checkpoint (an undo happens once). Returns what
    /// happened, for the notice and for the agent.
    static func restore(_ ws: Workspace, turn: String) -> (restored: [String], removed: [String], failed: [String]) {
        guard let m = manifest(ws, turn: turn) else { return ([], [], []) }
        defer { if m.files.allSatisfy({ !$0.existed || $0.backup != nil }) { try? FileManager.default.removeItem(at: manifestURL(ws, turn: turn)) } }
        let fm = FileManager.default
        var restored: [String] = [], removed: [String] = [], failed: [String] = []
        for e in m.files {
            let url = URL(fileURLWithPath: e.path)
            let rel = url.path.hasPrefix(ws.url.path + "/") ? String(url.path.dropFirst(ws.url.path.count + 1)) : url.path
            if e.existed, let b = e.backup {
                let src = dir(ws, turn: turn).appendingPathComponent(b)
                do {
                    try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
                    try fm.copyItem(at: src, to: url)
                    restored.append(rel)
                } catch { failed.append(rel) }
            } else if !e.existed {
                if fm.fileExists(atPath: url.path) { if (try? fm.removeItem(at: url)) != nil { removed.append(rel) } else { failed.append(rel) } }
            }
        }
        return (restored, removed, failed)
    }

    /// The files a turn actually changed (a backup taken before a call the user then declined is not a change), relative to the folder.
    static func changed(_ ws: Workspace, turn: String) -> [String] {
        let fm = FileManager.default
        return (manifest(ws, turn: turn)?.files ?? []).filter { e in
            let now = fm.fileExists(atPath: e.path)
            if !e.existed { return now }
            guard let b = e.backup, let before = fm.contents(atPath: dir(ws, turn: turn).appendingPathComponent(b).path) else { return true }
            return fm.contents(atPath: e.path) != before
        }.map { $0.path.hasPrefix(ws.url.path + "/") ? String($0.path.dropFirst(ws.url.path.count + 1)) : $0.path }
    }

    /// Old checkpoints go; the newest `keep` turns stay.
    static func prune(_ ws: Workspace) {
        let root = ws.stateDir.appendingPathComponent("checkpoints", isDirectory: true)
        guard let items = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let sorted = items.sorted { ((try? $0.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) > ((try? $1.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast) }
        for u in sorted.dropFirst(keep) { try? FileManager.default.removeItem(at: u) }
    }
}
