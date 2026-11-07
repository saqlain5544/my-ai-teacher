import Foundation

/// What a lesson message contributes to `messages.text`, the column `messages_fts` indexes (the sidebar's search and
/// `past_lessons`). Visible text and attached files, plus what makes "that command you showed me" and "how I fixed that
/// error" findable: the commands and code the teacher ran, and the first lines of a failed run. Never hidden context
/// (recalled memory, plans, loop notes: they are the app's, not the lesson), thinking, images or successful tool output
/// (bulky, and web pages and files the lesson read are not what was said).
enum MessageIndex {
    /// Tools whose input is worth finding later, and the field that holds it.
    static let ranTools: [String: String] = ["bash": "command", "run_code": "code", "diagnostics": "command", "run_tests": "command"]
    static let ranLimit = 1_500, failureLimit = 400

    static func text(of m: ChatMessage) -> String {
        var parts: [String] = []
        var extra = 0
        for b in m.blocks {
            switch b.kind {
            case .text where b.meta?["hidden"]?.bool != true && b.meta?["ephemeral"]?.bool != true: if let t = b.text { parts.append(t) }
            case .file: if let t = b.text { parts.append(t) }
            case .toolUse:
                guard let field = ranTools[b.name ?? ""], let t = b.input?[field]?.string, extra < 3_000 else { continue }
                let s = String(t.prefix(ranLimit)); extra += s.count; parts.append(s)
            case .toolResult where b.isError == true:
                guard let t = b.text, extra < 3_000 else { continue }
                let s = String(t.prefix(failureLimit)); extra += s.count; parts.append(s)
            default: break
            }
        }
        return parts.joined(separator: "\n")
    }

    /// Only what the learner and teacher said (for showing a message): visible text and file names.
    static func visibleText(of m: ChatMessage) -> String {
        m.blocks.compactMap { b -> String? in
            guard b.kind == .text, b.meta?["hidden"]?.bool != true, b.meta?["ephemeral"]?.bool != true else { return nil }
            return b.text
        }.joined(separator: "\n")
    }

    // MARK: One-time re-index of older lessons

    static let marker = "text_v2", cursor = "text_v2_cursor"

    static func meta(_ db: Database, _ key: String) -> String? {
        (try? db.query("SELECT value FROM store_meta WHERE key=?", key))?.first?.string("value")
    }
    /// Whether this database's index is current: no hidden context in it. Older ones (and ones this build never opened)
    /// are read with the safety net in `PastLessons`.
    static func isCurrent(_ db: Database) -> Bool { meta(db, marker) == "done" }

    /// Older lessons indexed hidden context and no commands. The rows' `text` is rewritten in batches (the update
    /// trigger moves the FTS entry with it): a crash or a busy database stops it where it is and the next launch carries
    /// on from the cursor. Nothing but `text` changes, so there is nothing to back up. True when done.
    @discardableResult
    static func upgrade(_ db: Database, batch: Int = 200, beat: () -> Void = {}, afterRead: () -> Void = {}) -> Bool {
        if isCurrent(db) { return true }
        var last = Int(meta(db, cursor) ?? "") ?? 0
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        while true {
            if Task.isCancelled { return false }
            guard let rows = try? db.query("SELECT rowid AS r, id, data, text FROM messages WHERE rowid>? ORDER BY rowid LIMIT ?", last, batch) else { return false }
            if rows.isEmpty { break }
            var changes: [(id: String, text: String, data: String)] = []
            for r in rows {
                last = max(last, r.int("r") ?? last)
                guard let id = r.string("id"), let d = r.data("data"), let m = try? dec.decode(ChatMessage.self, from: d) else { continue }
                let new = text(of: m)
                if new != (r.string("text") ?? ""), let raw = r.string("data") { changes.append((id, new, raw)) }
            }
            afterRead()
            do {
                try db.transaction {
                    // Only if the row is still what was read: the lesson may have saved a newer version meanwhile, whose own
                    // text (written by `upsert`) is already right.
                    for c in changes { try db.execute("UPDATE messages SET text=? WHERE id=? AND data=?", c.text, c.id, c.data) }
                    try db.execute("INSERT INTO store_meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", cursor, String(last))
                }
            } catch { return false }
            beat()
            Thread.sleep(forTimeInterval: 0.005)   // a 200k-message store is minutes of background work: leave the disk to the lesson
        }
        db.run("INSERT INTO store_meta(key, value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", marker, "done")
        return true
    }

    /// After launch, off the main actor, one job per database.
    static func upgradeInBackground(_ db: Database) {
        guard !db.path.isEmpty, db.path != ":memory:" else { return }
        Task { await Runtime.job("lessons.reindex:" + db.path, restart: .temporary, watchdog: 120) { job in _ = upgrade(db, beat: job.beat) } }
    }
}
