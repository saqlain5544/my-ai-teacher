import Foundation

/// How much the teacher may do inside a loaded folder. Reading is always allowed everywhere;
/// every folder starts read-only and the learner escalates explicitly.
enum FolderAccess: String, Codable, CaseIterable, Identifiable, Sendable, Comparable {
    case read, write, full
    var id: String { rawValue }
    var title: String {
        switch self {
        case .read: "Read only"
        case .write: "Read & write"
        case .full: "Full access"
        }
    }
    var detail: String {
        switch self {
        case .read: "Can read files anywhere. Asks before changing anything."
        case .write: "Can create and edit files in this folder. Asks before running commands or code."
        case .full: "Can edit files and run commands and code in this folder without asking."
        }
    }
    var symbol: String {
        switch self {
        case .read: "eye"
        case .write: "pencil"
        case .full: "bolt.shield"
        }
    }
    private var rank: Int { switch self { case .read: 0; case .write: 1; case .full: 2 } }
    static func < (a: FolderAccess, b: FolderAccess) -> Bool { a.rank < b.rank }
}

struct WorkspaceRef: Codable, Hashable, Identifiable, Sendable {
    var path: String
    var lastOpened: Date
    var id: String { path }
    var name: String { path == AppPaths.quickFolder.path ? "Quick questions" : (path as NSString).lastPathComponent }
}

/// A folder the teacher works in. Its state (lessons, folder memory, outputs) lives in `<folder>/.teacher/`.
/// Access grants are NOT stored there — a folder must never be able to grant itself permissions.
final class Workspace: @unchecked Sendable, Identifiable {
    static let stateDirName = ".teacher"

    let url: URL
    let stateDir: URL
    let db: Database
    let conversations: ConversationStore
    let memory: MemoryStore

    var id: String { url.path }
    var name: String { url.path == AppPaths.quickFolder.path ? "Quick questions" : url.lastPathComponent }
    var outputsDir: URL { stateDir.appendingPathComponent("outputs", isDirectory: true) }
    var attachmentsDir: URL { stateDir.appendingPathComponent("attachments", isDirectory: true) }
    /// Tests the agent writes for the learner's work; the only `.teacher/` folder it may write to.
    var testsDir: URL { stateDir.appendingPathComponent("tests", isDirectory: true) }

    init(url: URL) throws {
        self.url = url.standardizedFileURL
        stateDir = self.url.appendingPathComponent(Self.stateDirName, isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: stateDir, withIntermediateDirectories: true)
        try? fm.createDirectory(at: stateDir.appendingPathComponent("outputs"), withIntermediateDirectories: true)
        try? fm.createDirectory(at: stateDir.appendingPathComponent("attachments"), withIntermediateDirectories: true)
        // The app's lesson database and caches must never end up in the project's git history (a checkpoint, or the
        // learner's own `git add -A`); the code agent's project memory and the learner's own sub-agent types
        // (`agents/*.md`) are worth versioning, so they stay visible.
        let ignore = stateDir.appendingPathComponent(".gitignore")
        let rules = "# My AI Teacher's own state (lessons, caches) — not part of the project.\n*\n!.gitignore\n!code-memory.md\n!agents/\n!agents/*.md\n!tests/\n!tests/**\n"
        if !fm.fileExists(atPath: ignore.path) { try? rules.write(to: ignore, atomically: true, encoding: .utf8) }
        else if let text = try? String(contentsOf: ignore, encoding: .utf8), !text.contains("!tests/") {
            try? (text.hasSuffix("\n") ? text : text + "\n").appending("!tests/\n!tests/**\n").write(to: ignore, atomically: true, encoding: .utf8)
        }
        let readme = stateDir.appendingPathComponent("README.md")
        if !fm.fileExists(atPath: readme.path) {
            try? Data("""
            # .teacher

            State for **My AI Teacher** in this folder: lessons (`state.sqlite`), memories about this folder,
            tool outputs, and the tests the teacher writes for your work (`tests/`, versioned with the project).
            Safe to delete the rest — the teacher will start fresh here. Permissions are stored in the app, not here.
            """.utf8).write(to: readme)
        }
        db = try Database(path: stateDir.appendingPathComponent("state.sqlite").path)
        try db.script(Schema_.sql)
        conversations = ConversationStore(db: db)
        memory = MemoryStore(db: db, scope: .folder)
    }

    func contains(_ u: URL) -> Bool { u.isInside(url) }
    func isStatePath(_ u: URL) -> Bool { u.isInside(stateDir) }
    func isTestsPath(_ u: URL) -> Bool { u.isInside(testsDir) }
}

extension URL {
    /// The real path, also for a file that doesn't exist yet: the deepest existing ancestor through realpath (so a
    /// symlinked directory is followed), then the rest. Lower-cased, because APFS is case-insensitive by default and
    /// `.TEACHER/x` is `.teacher/x` there (on a case-sensitive volume this errs towards "inside").
    var canonicalPath: String {
        var head = standardizedFileURL, rest: [String] = []
        var st = stat()
        while lstat(head.path, &st) != 0, head.path != "/" {   // lstat: a dangling symlink exists (and doesn't resolve)
            rest.insert(head.lastPathComponent, at: 0)
            head.deleteLastPathComponent()
        }
        // A link that leads nowhere could be written through to anywhere: it is inside nothing.
        guard var base = realpath(head.path, nil).map({ p in defer { free(p) }; return String(cString: p) }) else { return "\u{0}unresolved" }
        for c in rest { base = (base as NSString).appendingPathComponent(c) }
        return base.lowercased()
    }

    /// Whether this path is `base` or lies under it, after symlinks and case.
    func isInside(_ base: URL) -> Bool {
        let p = canonicalPath, b = base.canonicalPath
        return p == b || p.hasPrefix(b.hasSuffix("/") ? b : b + "/")
    }
}

/// Learner-wide state that follows you across folders (profile memory, flashcards, mastery, plans, usage).
final class GlobalStore: @unchecked Sendable {
    let db: Database
    let memory: MemoryStore
    let study: StudyStore

    init() {
        do { db = try Database(path: AppPaths.database.path) }
        catch { fatalError("Database unavailable: \(error)") }
        try? db.script(Schema_.sql)
        memory = MemoryStore(db: db, scope: .learner)
        study = StudyStore(db: db)
    }

    /// Over an explicit database (tests, tools) — never touches the app's real learner DB.
    init(db: Database) {
        self.db = db
        try? db.script(Schema_.sql)
        memory = MemoryStore(db: db, scope: .learner)
        study = StudyStore(db: db)
    }

    /// Lessons created before folder workspaces existed lived in the global DB; move them to the default folder.
    func migrateLegacyConversations(into ws: Workspace) {
        guard let rows = try? db.query("SELECT id, data, updated_at FROM conversations"), !rows.isEmpty else { return }
        let msgs = (try? db.query("SELECT * FROM messages")) ?? []
        try? ws.db.transaction {
            for r in rows {
                try ws.db.execute("INSERT OR IGNORE INTO conversations(id, data, updated_at) VALUES(?,?,?)", r.string("id"), r.string("data"), r.double("updated_at"))
            }
            for m in msgs {
                try ws.db.execute("INSERT OR IGNORE INTO messages(id, conversation_id, seq, data, text, created_at) VALUES(?,?,?,?,?,?)",
                                  m.string("id"), m.string("conversation_id"), m.int("seq"), m.string("data"), m.string("text"), m.double("created_at"))
            }
        }
        db.run("DELETE FROM messages")
        db.run("DELETE FROM conversations")
    }
}

/// Everything tools and sessions need, for the current folder.
final class Services: @unchecked Sendable {
    let global: GlobalStore
    let workspace: Workspace
    let memory: MemoryHub

    init(global: GlobalStore, workspace: Workspace) {
        self.global = global
        self.workspace = workspace
        memory = MemoryHub(learner: global.memory, folder: workspace.memory)
    }

    var conversations: ConversationStore { workspace.conversations }
    var study: StudyStore { global.study }

    func logUsage(provider: String, model: String, usage: Usage) {
        let day = StudyStore.dayFormatter.string(from: Date())
        global.db.run("""
            INSERT INTO usage_log(day, provider, model, requests, input, output, cache_read, cache_write, reasoning) VALUES(?,?,?,1,?,?,?,?,?)
            ON CONFLICT(day, provider, model) DO UPDATE SET requests=requests+1, input=input+excluded.input, output=output+excluded.output,
            cache_read=cache_read+excluded.cache_read, cache_write=cache_write+excluded.cache_write, reasoning=reasoning+excluded.reasoning
            """, day, provider, model, usage.input, usage.output, usage.cacheRead, usage.cacheWrite, usage.reasoning)
    }

    func usageSummary(days: Int = 30) -> [(provider: String, model: String, requests: Int, input: Int, output: Int, cacheRead: Int)] {
        let since = StudyStore.dayFormatter.string(from: Date().addingTimeInterval(-Double(days) * 86400))
        let rows = (try? global.db.query("""
            SELECT provider, model, SUM(requests) r, SUM(input) i, SUM(output) o, SUM(cache_read) c FROM usage_log WHERE day>=?
            GROUP BY provider, model ORDER BY o DESC
            """, since)) ?? []
        return rows.map { ($0.string("provider") ?? "", $0.string("model") ?? "", $0.int("r") ?? 0, $0.int("i") ?? 0, $0.int("o") ?? 0, $0.int("c") ?? 0) }
    }
}
