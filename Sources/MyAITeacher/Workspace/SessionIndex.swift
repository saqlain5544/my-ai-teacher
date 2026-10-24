import Foundation

/// Every lesson and code session the learner has, across the folders they work in. Each folder keeps its own lessons
/// (`<folder>/.teacher/state.sqlite`); the index reads them read-only, so listing never creates or changes anything.
enum SessionIndex {
    struct Entry: Identifiable, Hashable, Sendable {
        let conversation: Conversation
        let folder: String
        var id: String { conversation.id }
        var folderName: String { WorkspaceRef(path: folder, lastOpened: .distantPast).name }
    }

    /// The lessons in `folders` (paths), newest first. A folder that is gone or was never opened is skipped, and one
    /// spelled two ways (`/tmp/x` and `/private/tmp/x`, a symlink) is read once; so is a lesson.
    static func scan(_ folders: [String]) -> [Entry] {
        var seen = Set<String>(), out: [Entry] = []
        for folder in folders where seen.insert(URL(fileURLWithPath: folder).canonicalPath).inserted {
            let file = URL(fileURLWithPath: folder).appendingPathComponent(Workspace.stateDirName).appendingPathComponent("state.sqlite")
            guard FileManager.default.fileExists(atPath: file.path), let db = try? Database(path: file.path, readOnly: true) else { continue }
            out += lessons(in: db).map { Entry(conversation: $0, folder: folder) }
        }
        return unique(out)
    }

    /// Newest first, each lesson once.
    static func unique(_ list: [Entry]) -> [Entry] {
        var ids = Set<String>()
        return list.sorted { $0.conversation.updatedAt > $1.conversation.updatedAt }.filter { ids.insert($0.id).inserted }
    }

    private static func lessons(in db: Database) -> [Conversation] {
        let rows = (try? db.query("SELECT data FROM conversations ORDER BY updated_at DESC")) ?? []
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970   // as ConversationStore writes them
        return rows.compactMap { r in r.data("data").flatMap { try? dec.decode(Conversation.self, from: $0) } }
    }
}
