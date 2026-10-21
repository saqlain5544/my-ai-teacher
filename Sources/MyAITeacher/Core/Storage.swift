import Foundation

enum Schema_ {
    static let version = 1
    static let sql = """
    CREATE TABLE IF NOT EXISTS conversations(id TEXT PRIMARY KEY, data TEXT NOT NULL, updated_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS messages(id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL, seq INTEGER NOT NULL,
        data TEXT NOT NULL, text TEXT, created_at REAL NOT NULL);
    CREATE INDEX IF NOT EXISTS messages_conv ON messages(conversation_id, seq);
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
    CREATE TABLE IF NOT EXISTS quiz_attempts(id INTEGER PRIMARY KEY AUTOINCREMENT, conversation_id TEXT, title TEXT, topic TEXT,
        score REAL, total INTEGER, data TEXT, created_at REAL NOT NULL);
    CREATE TABLE IF NOT EXISTS usage_log(day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL, requests INTEGER NOT NULL DEFAULT 0,
        input INTEGER NOT NULL DEFAULT 0, output INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0,
        cache_write INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, provider, model));
    CREATE TABLE IF NOT EXISTS study_log(day TEXT PRIMARY KEY, seconds REAL NOT NULL DEFAULT 0, messages INTEGER NOT NULL DEFAULT 0,
        reviews INTEGER NOT NULL DEFAULT 0);
    """
}

final class ConversationStore: @unchecked Sendable {
    let db: Database
    init(db: Database) { self.db = db }

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
        try? db.execute("DELETE FROM messages WHERE conversation_id=?", id)
        try? db.execute("DELETE FROM conversations WHERE id=?", id)
    }

    func messages(_ conversationID: String) -> [ChatMessage] {
        let rows = (try? db.query("SELECT data FROM messages WHERE conversation_id=? ORDER BY seq", conversationID)) ?? []
        return rows.compactMap { r in r.data("data").flatMap { try? dec.decode(ChatMessage.self, from: $0) } }
    }

    func upsert(_ m: ChatMessage, conversationID: String, seq: Int) {
        guard let data = try? enc.encode(m) else { return }
        let text = m.blocks.compactMap { b -> String? in
            switch b.kind { case .text, .file: return b.text; default: return nil }
        }.joined(separator: "\n")
        try? db.execute("""
            INSERT INTO messages(id, conversation_id, seq, data, text, created_at) VALUES(?,?,?,?,?,?)
            ON CONFLICT(id) DO UPDATE SET data=excluded.data, text=excluded.text, seq=excluded.seq
            """, m.id, conversationID, seq, String(decoding: data, as: UTF8.self), text, m.createdAt)
    }

    func deleteMessages(_ conversationID: String, fromSeq: Int) {
        try? db.execute("DELETE FROM messages WHERE conversation_id=? AND seq>=?", conversationID, fromSeq)
    }

    /// Full-text search across all lessons. Returns conversation ids with a snippet.
    func search(_ q: String) -> [(id: String, snippet: String)] {
        let query = FTS.query(q)
        guard !query.isEmpty else { return [] }
        let rows = (try? db.query("""
            SELECT conversation_id, snippet(messages_fts, 0, '', '', '…', 12) AS snip FROM messages_fts
            WHERE messages_fts MATCH ? ORDER BY rank LIMIT 50
            """, query)) ?? []
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
