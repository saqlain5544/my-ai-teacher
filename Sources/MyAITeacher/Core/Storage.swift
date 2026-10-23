import Foundation

enum Schema_ {
    static let version = 1
    static let sql = """
    CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, seq INTEGER NOT NULL,
        data TEXT NOT NULL, text TEXT, created_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS messages_conv ON messages(conversation_id, seq);
    CREATE TABLE IF NOT EXISTS blob_refs(ref TEXT NOT NULL, message_id TEXT NOT NULL, conversation_id TEXT NOT NULL, PRIMARY KEY(ref, message_id));
    CREATE INDEX IF NOT EXISTS blob_refs_msg ON blob_refs(message_id);
    CREATE INDEX IF NOT EXISTS blob_refs_conv ON blob_refs(conversation_id);
    CREATE VIRTUAL TABLE IF NOT EXISTS messages_fts USING fts5(text, conversation_id UNINDEXED, content='messages', content_rowid='rowid', tokenize='porter unicode61');
    CREATE TRIGGER IF NOT EXISTS messages_ai AFTER INSERT ON messages BEGIN
        INSERT INTO messages_fts(rowid, text, conversation_id) VALUES (new.rowid, new.text, new.conversation_id); END;
    CREATE TRIGGER IF NOT EXISTS messages_ad AFTER DELETE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, text, conversation_id) VALUES('delete', old.rowid, old.text, old.conversation_id); END;
    CREATE TRIGGER IF NOT EXISTS messages_au AFTER UPDATE ON messages BEGIN
        INSERT INTO messages_fts(messages_fts, rowid, text, conversation_id) VALUES('delete', old.rowid, old.text, old.conversation_id);
        INSERT INTO messages_fts(rowid, text, conversation_id) VALUES (new.rowid, new.text, new.conversation_id); END;

    CREATE TABLE IF NOT EXISTS memories(id INTEGER PRIMARY KEY AUTOINCREMENT, kind TEXT NOT NULL, subject TEXT, content TEXT NOT NULL,
        importance REAL NOT NULL DEFAULT 0.5, confidence REAL NOT NULL DEFAULT 0.8, source TEXT, origin TEXT NOT NULL DEFAULT 'inferred',
        created_at REAL NOT NULL, updated_at REAL NOT NULL, last_used_at REAL, use_count INTEGER NOT NULL DEFAULT 0,
        embedding BLOB, archived INTEGER NOT NULL DEFAULT 0);
    CREATE VIRTUAL TABLE IF NOT EXISTS memories_fts USING fts5(content, subject, kind UNINDEXED, content='memories', content_rowid='id', tokenize='porter unicode61');
    CREATE TRIGGER IF NOT EXISTS memories_ai AFTER INSERT ON memories BEGIN
        INSERT INTO memories_fts(rowid, content, subject, kind) VALUES (new.id, new.content, new.subject, new.kind); END;
    CREATE TRIGGER IF NOT EXISTS memories_ad AFTER DELETE ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, content, subject, kind) VALUES('delete', old.id, old.content, old.subject, old.kind); END;
    CREATE TRIGGER IF NOT EXISTS memories_au AFTER UPDATE OF content, subject, kind ON memories BEGIN
        INSERT INTO memories_fts(memories_fts, rowid, content, subject, kind) VALUES('delete', old.id, old.content, old.subject, old.kind);
        INSERT INTO memories_fts(rowid, content, subject, kind) VALUES (new.id, new.content, new.subject, new.kind); END;

    CREATE TABLE IF NOT EXISTS cards(id INTEGER PRIMARY KEY AUTOINCREMENT, deck TEXT NOT NULL, front TEXT NOT NULL, back TEXT NOT NULL,
        concept TEXT, subject TEXT, source TEXT, created_at REAL NOT NULL, due REAL NOT NULL, stability REAL NOT NULL DEFAULT 0,
        difficulty REAL NOT NULL DEFAULT 0, reps INTEGER NOT NULL DEFAULT 0, lapses INTEGER NOT NULL DEFAULT 0,
        state INTEGER NOT NULL DEFAULT 0, last_review REAL, suspended INTEGER NOT NULL DEFAULT 0);
    CREATE INDEX IF NOT EXISTS cards_due ON cards(suspended, due);
    CREATE TABLE IF NOT EXISTS reviews(id INTEGER PRIMARY KEY AUTOINCREMENT, card_id INTEGER NOT NULL, rating INTEGER NOT NULL,
        reviewed_at REAL NOT NULL, elapsed_days REAL, scheduled_days REAL);
    CREATE TABLE IF NOT EXISTS mastery(subject TEXT NOT NULL, concept TEXT NOT NULL, p_known REAL NOT NULL DEFAULT 0.2,
        attempts INTEGER NOT NULL DEFAULT 0, correct INTEGER NOT NULL DEFAULT 0, streak INTEGER NOT NULL DEFAULT 0,
        notes TEXT, updated_at REAL NOT NULL, PRIMARY KEY(subject, concept));
    CREATE TABLE IF NOT EXISTS plans(id TEXT PRIMARY KEY, title TEXT NOT NULL, subject TEXT, goal TEXT, data TEXT NOT NULL,
        conversation_id TEXT, created_at REAL NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS board_links(conversation_id TEXT PRIMARY KEY, plan_id TEXT NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS quiz_attempts(id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT, title TEXT, topic TEXT,
        score REAL, total INTEGER, data TEXT, created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS usage_log(day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, requests INTEGER NOT NULL DEFAULT 0,
        input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, provider, model));
    CREATE TABLE IF NOT EXISTS study_log(day TEXT PRIMARY KEY, seconds REAL NOT NULL DEFAULT 0, messages INTEGER NOT NULL DEFAULT 0,
        reviews INTEGER NOT NULL DEFAULT 0);
    CREATE TABLE IF NOT EXISTS responses(id INTEGER PRIMARY KEY AUTOINCREMENT, at REAL NOT NULL, subject TEXT, concept TEXT,
        correct INTEGER, certainty INTEGER, help INTEGER NOT NULL DEFAULT 0, source TEXT, conversation_id TEXT);
    CREATE INDEX IF NOT EXISTS responses_at ON responses(at);
    CREATE TABLE IF NOT EXISTS followups(id INTEGER PRIMARY KEY AUTOINCREMENT, subject TEXT NOT NULL, concept TEXT NOT NULL,
        kind TEXT NOT NULL, note TEXT, due REAL NOT NULL, created_at REAL NOT NULL, resolved_at REAL, outcome TEXT, conversation_id TEXT);
    CREATE INDEX IF NOT EXISTS followups_open ON followups(resolved_at, due);
    CREATE TABLE IF NOT EXISTS languages(code TEXT PRIMARY KEY, role TEXT NOT NULL DEFAULT 'target', level TEXT, notes TEXT, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS vocab(id INTEGER PRIMARY KEY AUTOINCREMENT, lang TEXT NOT NULL, term TEXT NOT NULL, reading TEXT, meaning TEXT NOT NULL,
        pos TEXT, example TEXT, example_meaning TEXT, notes TEXT, tags TEXT, card_id INTEGER, source TEXT, created_at REAL NOT NULL, UNIQUE(lang, term));
    CREATE INDEX IF NOT EXISTS vocab_lang ON vocab(lang, created_at);
    CREATE TABLE IF NOT EXISTS reading_log(id INTEGER PRIMARY KEY AUTOINCREMENT, lang TEXT NOT NULL, title TEXT, words INTEGER NOT NULL,
        unit TEXT, at REAL NOT NULL, conversation_id TEXT);
    CREATE INDEX IF NOT EXISTS reading_log_lang ON reading_log(lang, at);
    """
}

final class ConversationStore: @unchecked Sendable {
    let db: Database
    /// Image payloads of this database's lessons (messages keep only references).
    let blobs: BlobStore
    init(db: Database) {
        self.db = db
        blobs = BlobStore(databasePath: db.path)
        // Orphans (a crash between writing a blob and saving its message, a truncated turn) go at launch, off the main thread.
        Task.detached(priority: .background) { [self] in blobs.collect(blobs.all(), inUse: inUse) }
    }

    /// A blob a message refers to; when the lookup fails it counts as in use (never delete on doubt).
    private func inUse(_ ref: String) -> Bool {
        guard let rows = try? db.query("SELECT 1 AS x FROM blob_refs WHERE ref=? LIMIT 1", ref) else { return true }
        return !rows.isEmpty
    }

    private let enc: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private let dec: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()

    func all() -> [Conversation] {
        let rows = (try? db.query("SELECT data FROM conversations ORDER BY updated_at DESC")) ?? []
        return rows.compactMap { r in r.data("data").flatMap { try? dec.decode(Conversation.self, from: $0) } }
    }

    func save(_ c: Conversation) {
        guard let data = try? enc.encode(c) else { return }
        try? db.execute("INSERT INTO conversations(id, data, updated_at) VALUES(?,?,?) ON CONFLICT(id) DO UPDATE SET data=excluded.data, updated_at=excluded.updated_at",
                        c.id, String(decoding: data, as: UTF8.self), c.updatedAt)
    }

    func delete(_ id: String) {
        let refs = ((try? db.query("SELECT DISTINCT ref FROM blob_refs WHERE conversation_id=?", id)) ?? []).compactMap { $0.string("ref") }
        try? db.execute("DELETE FROM messages WHERE conversation_id=?", id)
        try? db.execute("DELETE FROM conversations WHERE id=?", id)
        try? db.execute("DELETE FROM blob_refs WHERE conversation_id=?", id)
        blobs.collect(refs, inUse: inUse)
    }

    func messages(_ conversationID: String) -> [ChatMessage] {
        let sp = Signposts.begin("lesson.load", "all"); defer { Signposts.end("lesson.load", sp) }
        let rows = (try? db.query("SELECT data FROM messages WHERE conversation_id=? ORDER BY seq", conversationID)) ?? []
        return rows.compactMap { r in r.data("data").flatMap { try? dec.decode(ChatMessage.self, from: $0) } }
    }

    /// Messages with seq in [from, to) — a window of a long lesson (seq is the message's position).
    func messages(_ conversationID: String, from: Int, to: Int = Int.max) -> [ChatMessage] {
        let sp = Signposts.begin("lesson.load", "from \(from)"); defer { Signposts.end("lesson.load", sp) }
        let rows = (try? db.query("SELECT data FROM messages WHERE conversation_id=? AND seq>=? AND seq<? ORDER BY seq",
                                  conversationID, from, min(to, Int(Int32.max)))) ?? []
        return rows.compactMap { r in r.data("data").flatMap { try? dec.decode(ChatMessage.self, from: $0) } }
    }

    func messageCount(_ conversationID: String) -> Int {
        (try? db.query("SELECT COUNT(*) AS n FROM messages WHERE conversation_id=?", conversationID))?.first?.int("n") ?? 0
    }

    func seq(ofMessage messageID: String) -> Int? {
        (try? db.query("SELECT seq FROM messages WHERE id=?", messageID))?.first?.int("seq")
    }

    func upsert(_ m: ChatMessage, conversationID: String, seq: Int) {
        let sp = Signposts.begin("lesson.save"); defer { Signposts.end("lesson.save", sp) }
        guard let data = try? enc.encode(m) else { return }
        let text = m.blocks.compactMap { b -> String? in
            switch b.kind { case .text, .file: return b.text; default: return nil }
        }.joined(separator: "\n")
        try? db.execute("""
            INSERT INTO messages(id, conversation_id, seq, data, text, created_at) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET data=excluded.data, text=excluded.text, seq=excluded.seq
            """, m.id, conversationID, seq, String(decoding: data, as: UTF8.self), text, m.createdAt)
        try? db.execute("DELETE FROM blob_refs WHERE message_id=?", m.id)
        for ref in Set(m.blobRefs) { try? db.execute("INSERT OR IGNORE INTO blob_refs(ref, message_id, conversation_id) VALUES(?,?,?)", ref, m.id, conversationID) }
    }

    func deleteMessages(_ conversationID: String, fromSeq: Int) {
        let gone = "SELECT id FROM messages WHERE conversation_id=? AND seq>=?"
        let refs = ((try? db.query("SELECT DISTINCT ref FROM blob_refs WHERE message_id IN (\(gone))", conversationID, fromSeq)) ?? []).compactMap { $0.string("ref") }
        try? db.execute("DELETE FROM blob_refs WHERE message_id IN (\(gone))", conversationID, fromSeq)
        try? db.execute("DELETE FROM messages WHERE conversation_id=? AND seq>=?", conversationID, fromSeq)
        blobs.collect(refs, inUse: inUse)   // a regenerated turn's screenshots; the grace period covers ones about to be re-saved
    }

    /// Full-text search across all lessons. Returns conversation ids with a snippet.
    func search(_ q: String) -> [(id: String, snippet: String)] {
        let query = FTS.query(q)
        guard !query.isEmpty else { return [] }
        // Rank only the 2,000 newest matches, so a common word over millions of rows stays fast. FTS5 yields matches in
        // rowid order: find the 2,000th newest, then rank the range from it (a seek). `rowid IN (subquery)` instead ran one
        // full-text lookup per rowid — 64 s on 200k messages.
        let floor = (try? db.query("SELECT rowid AS r FROM messages_fts WHERE messages_fts MATCH ? ORDER BY rowid DESC LIMIT 1 OFFSET 1999", query))?.first?.int("r") ?? 0
        let rows = (try? db.query("""
            SELECT conversation_id, snippet(messages_fts, 0, '', '', '…', 12) AS snip FROM messages_fts
            WHERE messages_fts MATCH ? AND rowid >= ? ORDER BY rank LIMIT 50
            """, query, floor)) ?? []
        var seen = Set<String>()
        return rows.compactMap { r in
            guard let id = r.string("conversation_id"), seen.insert(id).inserted else { return nil }
            return (id, r.string("snip") ?? "")
        }
    }
}

enum FTS {
    /// Builds a forgiving FTS5 query: each word as a prefix term, OR-ed.
    static let stopwords: Set<String> = ["the", "and", "for", "with", "that", "this", "what", "how", "are", "was", "you", "can", "does", "about",
        "from", "into", "have", "has", "its", "is", "of", "to", "in", "on", "a", "an", "me", "my", "i", "it", "be", "do", "or", "so", "if",
        "then", "than", "use", "using", "like", "please", "quick", "just", "also", "answer", "explain", "tell", "show", "give", "make",
        "want", "need", "let", "lets", "let's", "now", "one", "two", "some", "any", "all", "more", "very", "can't", "would", "could",
        "should", "will", "there", "here", "when", "why", "which", "who", "your", "our", "we", "they", "them", "sentence", "sentences", "tool"]

    /// Significant query terms (lowercased, stopwords removed).
    static func terms(_ s: String) -> [String] {
        let words = s.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted).filter { $0.count > 2 }
        var seen = Set<String>()
        return words.filter { !stopwords.contains($0) && seen.insert($0).inserted }.prefix(16).map { $0 }
    }

    /// Builds a forgiving FTS5 query: each significant word as a prefix term, OR-ed.
    static func query(_ s: String, joiner: String = " OR ") -> String {
        terms(s).map { "\"\($0)\"*" }.joined(separator: joiner)
    }
}
