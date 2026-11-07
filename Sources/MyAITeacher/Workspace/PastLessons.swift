import Foundation

/// Search and reading across the learner's earlier lessons, for the `past_lessons` tool and the Sessions page. Every
/// folder keeps its lessons in its own `.teacher/state.sqlite`; each search opens that file read-only (like
/// `SessionIndex`, so nothing is created or changed), on its own connection and a background thread, runs one query,
/// and is stopped by its time budget or by the task's cancellation.
enum PastLessons {
    struct Hit: Sendable, Hashable {
        let folder: String
        let conversationID: String
        let messageID: String
        let seq: Int
        let title: String
        let mode: String
        let role: String      // learner | teacher | tool
        let date: Date
        let snippet: String
        let score: Double
        var folderName: String { WorkspaceRef(path: folder, lastOpened: .distantPast).name }
        /// What `read` accepts.
        var ref: String { "\(conversationID):\(seq)" }
    }

    struct Filter: Sendable {
        var mode: String? = nil
        var since: Date? = nil
        var until: Date? = nil
    }

    enum Status: Sendable, Equatable { case ok, missing, unreadable, timedOut }
    struct FolderResult: Sendable { let folder: String; var hits: [Hit]; var status: Status; var capped = false }

    /// How many of a query's best matches are scored (a common word over millions of rows stays fast), how many rows come
    /// back to rank with recency, and how many a single lesson may fill.
    static let scored = 2_000, candidates = 200, perLesson = 3
    /// Folders one `all` search opens, and the time each may take.
    static let maxFolders = 16, folderBudget: TimeInterval = 2.5
    /// A match from this many days ago counts for 0.6 of a fresh one; older ones tend to 0.6 (never to zero: the lesson
    /// that has the answer may be old).
    static let halfLifeDays = 60.0

    static func stateFile(_ folder: String) -> String {
        URL(fileURLWithPath: folder).appendingPathComponent(Workspace.stateDirName).appendingPathComponent("state.sqlite").path
    }

    // MARK: Stopping

    /// A search's way to be stopped from outside: cancellation or the time budget interrupts the statement in flight.
    final class Stop: @unchecked Sendable {
        private let lock = NSLock()
        private var db: Database?
        private var cancelled = false, expired = false
        var isStopped: Bool { lock.withLock { cancelled || expired } }
        var timedOut: Bool { lock.withLock { expired && !cancelled } }
        func attach(_ d: Database) { lock.withLock { db = d }; if isStopped { d.interrupt() } }
        func cancel() { let d = lock.withLock { () -> Database? in cancelled = true; return db }; d?.interrupt() }
        func expire() { let d = lock.withLock { () -> Database? in expired = true; return db }; d?.interrupt() }
    }

    /// Resumes a continuation once, from whoever gets there first (the work, the budget's timer, cancellation).
    private final class Once<V: Sendable>: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false, cont: CheckedContinuation<V, Never>?, stored: V?
        func finish(_ v: V) {
            lock.lock()
            guard !done else { lock.unlock(); return }
            done = true
            if let c = cont { cont = nil; lock.unlock(); c.resume(returning: v) } else { stored = v; lock.unlock() }
        }
        func wait(_ c: CheckedContinuation<V, Never>) {
            lock.lock()
            if done, let v = stored { stored = nil; lock.unlock(); c.resume(returning: v) } else { cont = c; lock.unlock() }
        }
    }

    /// Runs blocking `work` off the cooperative pool with a budget. Past the budget, or when the calling task is
    /// cancelled, the call returns `fallback` at once and the statement in flight is interrupted. `sqlite3_interrupt` does
    /// nothing while a kernel call is blocked (opening a file on a network volume that went away), so the caller
    /// must not wait for `work` to come back: the thread is left to finish on its own, its answer dropped.
    static func off<T: Sendable>(budget: TimeInterval, fallback: T, _ work: @escaping @Sendable (Stop) -> T) async -> (T, Stop) {
        let stop = Stop(), once = Once<T>()
        let value: T = await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                once.wait(c)
                DispatchQueue.global(qos: .userInitiated).async {
                    let timer = DispatchWorkItem { stop.expire(); once.finish(fallback) }
                    DispatchQueue.global().asyncAfter(deadline: .now() + budget, execute: timer)
                    let r = work(stop)
                    timer.cancel()
                    once.finish(r)
                }
            }
        } onCancel: { stop.cancel(); once.finish(fallback) }
        return (value, stop)
    }

    // MARK: Search

    /// One folder's matches, best first. `stop` ends it early with whatever was ranked.
    static func search(_ db: Database, folder: String, query: String, filter: Filter = Filter(), limit: Int = 10,
                       now: Date = Date(), stop: Stop? = nil) -> [Hit] {
        searchCapped(db, folder: folder, query: query, filter: filter, limit: limit, now: now, stop: stop).hits
    }

    /// `search`, and whether more matches than were ranked exist (only the newest `scored` are).
    static func searchCapped(_ db: Database, folder: String, query: String, filter: Filter = Filter(), limit: Int = 10,
                             now: Date = Date(), stop: Stop? = nil) -> (hits: [Hit], capped: Bool) {
        let fts = FTS.query(query)
        guard !fts.isEmpty, stop?.isStopped != true else { return ([], false) }
        // Rank only the newest `scored` matches: FTS5 yields matches in rowid order, so find the last of them and rank the
        // range from it (a seek). `rowid IN (subquery)` ran one full-text lookup per rowid — 64 s on 200k messages.
        // The filters (dates, mode) go into that seek too: the cap is on matches that qualify, so an older date range is
        // searched in its own newest 2,000 rather than found empty behind newer matches.
        var cond = "", filterParams: [SQLBindable?] = []
        if let s = filter.since { cond += " AND m0.created_at >= ?"; filterParams.append(s.timeIntervalSince1970) }
        if let u = filter.until { cond += " AND m0.created_at <= ?"; filterParams.append(u.timeIntervalSince1970) }
        if let mode = filter.mode {   // the lessons of that mode, found once; the conversation rows are parsed here only
            cond += " AND m0.conversation_id IN (SELECT id FROM conversations WHERE json_extract(data,'$.mode') = ?)"; filterParams.append(mode)
        }
        let floorRow = (try? db.query("SELECT messages_fts.rowid AS r FROM messages_fts JOIN messages m0 ON m0.rowid = messages_fts.rowid WHERE messages_fts MATCH ?\(cond) ORDER BY messages_fts.rowid DESC LIMIT 1 OFFSET \(scored - 1)", params: [fts] + filterParams))?.first
        let floor = floorRow?.int("r") ?? 0, capped = floorRow != nil
        guard stop?.isStopped != true else { return ([], false) }
        let inner = "messages_fts.rowid >= ?" + cond
        var params: [SQLBindable?] = [fts, floor] + filterParams
        params.append(candidates)
        let current = MessageIndex.isCurrent(db)
        // The inner query ranks cheap columns only; the JSON columns (role, title, mode) are read for the few survivors.
        let rows = (try? db.query("""
            SELECT t.snip AS snip, t.score AS score, m.id AS mid, m.conversation_id AS cid, m.seq AS seq, m.created_at AS at,
                   json_extract(m.data,'$.role') AS role, instr(m.data, '"hidden"') > 0 AS hid,
                   CASE WHEN \(current ? 0 : 1) AND instr(m.data, '"hidden"') > 0 THEN m.data END AS raw,
                   json_extract(c.data,'$.title') AS title, json_extract(c.data,'$.mode') AS mode,
                   json_extract(m.data,'$.blocks[0].kind') AS k0
            FROM (SELECT messages_fts.rowid AS rid, snippet(messages_fts, 0, '«', '»', '…', 24) AS snip, bm25(messages_fts) AS score
                  FROM messages_fts JOIN messages m0 ON m0.rowid = messages_fts.rowid
                  WHERE messages_fts MATCH ? AND \(inner) ORDER BY score LIMIT ?) t
            JOIN messages m ON m.rowid = t.rid
            LEFT JOIN conversations c ON c.id = m.conversation_id
            """, params: params)) ?? []
        let terms = FTS.terms(query)
        var hits: [(Hit, Double)] = []
        for r in rows {
            guard let mid = r.string("mid"), let cid = r.string("cid") else { continue }
            var snippet = r.string("snip") ?? ""
            // Older indexes hold hidden context: a message that has any is re-read and its snippet taken from what was said.
            if !current, r.int("hid") == 1 {
                guard let d = r.data("raw"), let m = decode(d), let s = visibleSnippet(MessageIndex.visibleText(of: m), terms: terms) else { continue }
                snippet = s
            }
            let at = r.date("at") ?? .distantPast
            let age = max(0, now.timeIntervalSince(at)) / 86_400
            let weight = 0.6 + 0.4 * pow(0.5, age / halfLifeDays)
            let role = r.string("role") == "user" ? (r.string("k0") == "toolResult" ? "tool" : "learner") : "teacher"
            hits.append((Hit(folder: folder, conversationID: cid, messageID: mid, seq: r.int("seq") ?? 0, title: r.string("title") ?? "Lesson",
                             mode: r.string("mode") ?? "tutor", role: role, date: at, snippet: scrub(snippet), score: -(r.double("score") ?? 0) * weight), -(r.double("score") ?? 0) * weight))
        }
        var perConv: [String: Int] = [:]
        var out: [Hit] = []
        for (h, _) in hits.sorted(by: { $0.1 > $1.1 }) where perConv[h.conversationID, default: 0] < perLesson {
            perConv[h.conversationID, default: 0] += 1
            out.append(h)
            if out.count >= limit { break }
        }
        return (out, capped)
    }

    private static func decode(_ d: Data) -> ChatMessage? {
        let dec = JSONDecoder(); dec.dateDecodingStrategy = .secondsSince1970
        return try? dec.decode(ChatMessage.self, from: d)
    }

    /// A window of `text` around the first query term (prefix match, as the index's), with the term marked.
    static func visibleSnippet(_ text: String, terms: [String]) -> String? {
        for t in terms {
            guard let r = text.range(of: t, options: [.caseInsensitive, .diacriticInsensitive]) else { continue }
            let start = text.index(r.lowerBound, offsetBy: -80, limitedBy: text.startIndex) ?? text.startIndex
            let end = text.index(r.upperBound, offsetBy: 120, limitedBy: text.endIndex) ?? text.endIndex
            return (start > text.startIndex ? "…" : "") + String(text[start..<end]).replacingOccurrences(of: "\n", with: " ") + (end < text.endIndex ? "…" : "")
        }
        return nil
    }

    // MARK: Folders

    /// The databases one search opens: `folders` once each (spelled two ways, a symlink, counts once), the current folder
    /// first, those without a lesson database dropped, at most `maxFolders`.
    static func databases(current: String, others: [String]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for f in [current] + others where isMounted(f) && seen.insert(URL(fileURLWithPath: f).canonicalPath).inserted {
            if FileManager.default.fileExists(atPath: stateFile(f)) { out.append(f) }
            if out.count >= maxFolders { break }
        }
        return out
    }

    /// A folder on an external or network volume that is not mounted is not looked at (a stale mount point can block).
    static func isMounted(_ folder: String) -> Bool {
        let parts = URL(fileURLWithPath: folder).standardizedFileURL.pathComponents
        guard parts.count > 2, parts[1] == "Volumes" else { return true }
        return FileManager.default.fileExists(atPath: "/Volumes/" + parts[2])
    }

    /// `databases`, off the calling thread and within a budget: the path checks hit the disk (a network volume that went
    /// away blocks in the kernel), so the Sessions page and the tool never wait on them. Past the budget only the current folder is used.
    static func databases(current: String, others: [String], budget: TimeInterval) async -> [String] {
        await off(budget: budget, fallback: [current]) { _ in databases(current: current, others: others) }.0
    }

    /// One folder, read-only. A database that is gone, locked or not a lesson database is `.missing` / `.unreadable`.
    static func searchFolder(_ folder: String, query: String, filter: Filter, limit: Int, budget: TimeInterval = folderBudget) async -> FolderResult {
        let (r, stop) = await off(budget: budget, fallback: FolderResult(folder: folder, hits: [], status: .timedOut)) { stop -> FolderResult in
            let file = stateFile(folder)
            guard isMounted(folder), FileManager.default.fileExists(atPath: file) else { return FolderResult(folder: folder, hits: [], status: .missing) }
            guard let db = try? Database(path: file, readOnly: true) else { return FolderResult(folder: folder, hits: [], status: .unreadable) }
            stop.attach(db)
            // A corrupt file or a different kind of SQLite file fails the first read: skipped, not an error for the others.
            guard (try? db.query("SELECT 1 AS x FROM messages_fts LIMIT 1")) != nil else { return FolderResult(folder: folder, hits: [], status: .unreadable) }
            let found = searchCapped(db, folder: folder, query: query, filter: filter, limit: limit, stop: stop)
            return FolderResult(folder: folder, hits: found.hits, status: .ok, capped: found.capped)
        }
        var out = r
        if stop.timedOut, out.status == .ok { out.status = .timedOut }
        return out
    }

    /// Several folders, a few at a time. Results come back in the order of `folders`; cancelling stops them all.
    static func searchFolders(_ folders: [String], query: String, filter: Filter, limit: Int, budget: TimeInterval = folderBudget) async -> [FolderResult] {
        await withTaskGroup(of: (Int, FolderResult).self) { group in
            var results: [FolderResult?] = Array(repeating: nil, count: folders.count)
            var next = 0
            func launch() {
                guard next < folders.count else { return }
                let i = next, f = folders[i]; next += 1
                group.addTask { (i, await searchFolder(f, query: query, filter: filter, limit: limit, budget: budget)) }
            }
            for _ in 0..<min(4, folders.count) { launch() }
            while let (i, r) = await group.next() { results[i] = r; if !Task.isCancelled { launch() } }
            return results.compactMap { $0 }
        }
    }

    /// Hits of several folders in one ranking.
    static func merge(_ results: [FolderResult], limit: Int) -> [Hit] {
        var perConv: [String: Int] = [:], out: [Hit] = []
        for h in results.flatMap(\.hits).sorted(by: { $0.score > $1.score }) where perConv[h.conversationID, default: 0] < perLesson {
            perConv[h.conversationID, default: 0] += 1
            out.append(h)
            if out.count >= limit { break }
        }
        return out
    }

    // MARK: Reading

    /// Runs `work` on one folder's lesson database, read-only, off the cooperative pool and within the folder budget; nil when
    /// the database is missing, unreadable or the budget ran out.
    static func inFolder<T: Sendable>(_ folder: String, budget: TimeInterval = folderBudget, _ work: @escaping @Sendable (Database) -> T?) async -> T? {
        let (r, stop) = await off(budget: budget, fallback: nil) { stop -> T? in
            let file = stateFile(folder)
            guard isMounted(folder), FileManager.default.fileExists(atPath: file), let db = try? Database(path: file, readOnly: true) else { return nil }
            stop.attach(db)
            return work(db)
        }
        return stop.isStopped ? nil : r
    }

    struct Window: Sendable {
        let title: String, mode: String, folder: String
        let first: Int, total: Int
        let messages: [(seq: Int, message: ChatMessage)]
    }

    /// `count` messages from `from` of a lesson (nil when the lesson isn't in this database).
    static func window(_ db: Database, folder: String, conversationID: String, from: Int, count: Int) -> Window? {
        guard let c = (try? db.query("SELECT json_extract(data,'$.title') AS title, json_extract(data,'$.mode') AS mode, (SELECT COUNT(*) FROM messages WHERE conversation_id=?1) AS n FROM conversations WHERE id=?1", conversationID))?.first
        else { return nil }
        let start = max(0, from)
        let rows = (try? db.query("SELECT seq, data FROM messages WHERE conversation_id=? AND seq>=? ORDER BY seq LIMIT ?", conversationID, start, count)) ?? []
        let msgs = rows.compactMap { r -> (Int, ChatMessage)? in r.data("data").flatMap(decode).map { (r.int("seq") ?? 0, $0) } }
        return Window(title: c.string("title") ?? "Lesson", mode: c.string("mode") ?? "tutor", folder: folder, first: start, total: c.int("n") ?? msgs.count, messages: msgs)
    }

    struct Recent: Sendable { let id: String, title: String, mode: String, updated: Date, messages: Int, episode: String? }

    /// The newest lessons with the memory system's episode summary where there is one, in one query.
    static func recent(_ db: Database, limit: Int, since: Date? = nil, mode: String? = nil) -> [Recent] {
        var cond = "1=1", params: [SQLBindable?] = []
        if let since { cond += " AND c.updated_at >= ?"; params.append(since.timeIntervalSince1970) }
        if let mode { cond += " AND json_extract(c.data,'$.mode') = ?"; params.append(mode) }
        params.append(limit)
        func map(_ rows: [Row]) -> [Recent] {
            var seen = Set<String>()
            return rows.compactMap { r in
                guard let id = r.string("id"), seen.insert(id).inserted else { return nil }
                return Recent(id: id, title: r.string("title") ?? "Lesson", mode: r.string("mode") ?? "tutor", updated: r.date("up") ?? .distantPast,
                              messages: r.int("n") ?? 0, episode: r.string("episode"))
            }
        }
        let head = "SELECT c.id AS id, json_extract(c.data,'$.title') AS title, json_extract(c.data,'$.mode') AS mode, c.updated_at AS up, "
            + "(SELECT COUNT(*) FROM messages WHERE conversation_id = c.id) AS n"
        if let rows = try? db.query(head + ", e.content AS episode FROM conversations c LEFT JOIN (SELECT source, content FROM memories WHERE kind='episode' AND archived=0) e ON e.source = c.id WHERE \(cond) ORDER BY c.updated_at DESC LIMIT ?", params: params) {
            return map(rows)
        }
        return map((try? db.query(head + ", NULL AS episode FROM conversations c WHERE \(cond) ORDER BY c.updated_at DESC LIMIT ?", params: params)) ?? [])
    }

    // MARK: Text going to a model or the screen

    /// Long runs of base64-like characters and data URLs never leave the database.
    static func scrub(_ s: String) -> String {
        var t = s
        if t.contains("base64,") { t = t.replacingOccurrences(of: #"data:[\w/+.-]+;base64,[A-Za-z0-9+/=]*"#, with: "[data omitted]", options: .regularExpression) }
        if t.count > 160 { t = t.replacingOccurrences(of: #"[A-Za-z0-9+/=_-]{160,}"#, with: "[long data omitted]", options: .regularExpression) }
        return t
    }
}
