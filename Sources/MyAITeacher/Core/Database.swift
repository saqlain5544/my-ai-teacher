import Foundation
import SQLite3

enum SQLValue: Sendable {
    case null, int(Int64), double(Double), text(String), blob(Data)
}

protocol SQLBindable { var sqlValue: SQLValue { get } }
extension String: SQLBindable { var sqlValue: SQLValue { .text(self) } }
extension Int: SQLBindable { var sqlValue: SQLValue { .int(Int64(self)) } }
extension Int64: SQLBindable { var sqlValue: SQLValue { .int(self) } }
extension Double: SQLBindable { var sqlValue: SQLValue { .double(self) } }
extension Bool: SQLBindable { var sqlValue: SQLValue { .int(self ? 1 : 0) } }
extension Data: SQLBindable { var sqlValue: SQLValue { .blob(self) } }
extension Date: SQLBindable { var sqlValue: SQLValue { .double(timeIntervalSince1970) } }
extension Optional: SQLBindable where Wrapped: SQLBindable {
    var sqlValue: SQLValue { self?.sqlValue ?? .null }
}

struct Row {
    fileprivate let columns: [String: Int]
    fileprivate let values: [SQLValue]
    subscript(_ name: String) -> SQLValue { columns[name].map { values[$0] } ?? .null }
    func string(_ n: String) -> String? {
        switch self[n] { case .text(let s): return s; case .int(let i): return String(i); case .double(let d): return String(d); default: return nil }
    }
    func int(_ n: String) -> Int? {
        switch self[n] { case .int(let i): return Int(i); case .double(let d): return Int(d); case .text(let s): return Int(s); default: return nil }
    }
    func double(_ n: String) -> Double? {
        switch self[n] { case .int(let i): return Double(i); case .double(let d): return d; case .text(let s): return Double(s); default: return nil }
    }
    func date(_ n: String) -> Date? { double(n).map { Date(timeIntervalSince1970: $0) } }
    func data(_ n: String) -> Data? {
        switch self[n] { case .blob(let d): return d; case .text(let s): return Data(s.utf8); default: return nil }
    }
}

struct SQLiteError: LocalizedError { let message: String; var errorDescription: String? { message } }

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Minimal, fast SQLite wrapper: one connection, WAL, cached prepared statements, serialised by a lock.
final class Database: @unchecked Sendable {
    private var db: OpaquePointer?
    private var cache: [String: OpaquePointer] = [:]
    private let lock = NSRecursiveLock()
    let path: String

    /// `readOnly` opens a scanner: its reads come through a memory map (the OS file cache — clean pages that are not
    /// the app's footprint) instead of its own page cache, and it never holds up the writer's connection. Our lock already
    /// serialises a connection, so it skips SQLite's own mutex (taken on every column read).
    init(path: String, readOnly: Bool = false) throws {
        self.path = path
        let flags = readOnly ? SQLITE_OPEN_READONLY | SQLITE_OPEN_NOMUTEX : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &db, flags, nil) == SQLITE_OK else {
            throw SQLiteError(message: "Cannot open database at \(path)")
        }
        if readOnly {
            try execute("PRAGMA mmap_size=1073741824")
            try execute("PRAGMA cache_size=-1000")
        } else {
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=NORMAL")
            try execute("PRAGMA foreign_keys=ON")
            try execute("PRAGMA temp_store=MEMORY")
            try execute("PRAGMA cache_size=-8000")
        }
        Self.live.add(self)
    }

    private static let live = WeakRegistry<Database>()
    /// Returns every open database's page cache to the system (memory pressure: see MemoryGovernor).
    static func releaseAllMemory() { for d in live.all { _ = try? d.execute("PRAGMA shrink_memory") } }

    deinit {
        for (_, s) in cache { sqlite3_finalize(s) }
        sqlite3_close_v2(db)
    }

    private var errorMessage: String { String(cString: sqlite3_errmsg(db)) }

    /// Runs one or more statements without parameters.
    func script(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) != SQLITE_OK {
            let m = err.map { String(cString: $0) } ?? errorMessage
            sqlite3_free(err)
            throw SQLiteError(message: m)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        if let s = cache[sql] { sqlite3_reset(s); sqlite3_clear_bindings(s); return s }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v3(db, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &stmt, nil) == SQLITE_OK, let stmt else {
            throw SQLiteError(message: "\(errorMessage) — in: \(sql.prefix(200))")
        }
        cache[sql] = stmt
        return stmt
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLBindable?]) {
        for (i, p) in params.enumerated() {
            let idx = Int32(i + 1)
            switch p?.sqlValue ?? .null {
            case .null: sqlite3_bind_null(stmt, idx)
            case .int(let v): sqlite3_bind_int64(stmt, idx, v)
            case .double(let v): sqlite3_bind_double(stmt, idx, v)
            case .text(let v): sqlite3_bind_text(stmt, idx, v, -1, SQLITE_TRANSIENT)
            case .blob(let v):
                v.withUnsafeBytes { buf in
                    _ = sqlite3_bind_blob(stmt, idx, buf.baseAddress, Int32(buf.count), SQLITE_TRANSIENT)
                }
            }
        }
    }

    @discardableResult
    func execute(_ sql: String, _ params: SQLBindable?...) throws -> Int {
        try execute(sql, params: params)
    }

    @discardableResult
    func execute(_ sql: String, params: [SQLBindable?]) throws -> Int {
        let sp = Signposts.begin("sql", String(sql.prefix(60))); defer { Signposts.end("sql", sp) }
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        bind(stmt, params)
        var rc = sqlite3_step(stmt)
        while rc == SQLITE_ROW { rc = sqlite3_step(stmt) }
        defer { sqlite3_reset(stmt) }
        guard rc == SQLITE_DONE else { throw SQLiteError(message: errorMessage) }
        return Int(sqlite3_changes(db))
    }

    func query(_ sql: String, _ params: SQLBindable?...) throws -> [Row] {
        try query(sql, params: params)
    }

    func query(_ sql: String, params: [SQLBindable?]) throws -> [Row] {
        let sp = Signposts.begin("sql", String(sql.prefix(60))); defer { Signposts.end("sql", sp) }
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        bind(stmt, params)
        let count = sqlite3_column_count(stmt)
        var cols: [String: Int] = [:]
        for i in 0..<count { cols[String(cString: sqlite3_column_name(stmt, i))] = Int(i) }
        var rows: [Row] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: errorMessage) }
            var vals: [SQLValue] = []
            vals.reserveCapacity(Int(count))
            for i in 0..<count {
                switch sqlite3_column_type(stmt, i) {
                case SQLITE_INTEGER: vals.append(.int(sqlite3_column_int64(stmt, i)))
                case SQLITE_FLOAT: vals.append(.double(sqlite3_column_double(stmt, i)))
                case SQLITE_TEXT: vals.append(.text(String(cString: sqlite3_column_text(stmt, i))))
                case SQLITE_BLOB:
                    let n = Int(sqlite3_column_bytes(stmt, i))
                    if let p = sqlite3_column_blob(stmt, i), n > 0 { vals.append(.blob(Data(bytes: p, count: n))) }
                    else { vals.append(.blob(Data())) }
                default: vals.append(.null)
                }
            }
            rows.append(Row(columns: cols, values: vals))
        }
        return rows
    }

    /// A row being read by `each`, by column index; valid only inside the callback (blobs are not copied).
    struct Cursor {
        fileprivate let stmt: OpaquePointer
        func int64(_ i: Int32) -> Int64 { sqlite3_column_int64(stmt, i) }
        func double(_ i: Int32) -> Double { sqlite3_column_double(stmt, i) }
        func text(_ i: Int32) -> String? { sqlite3_column_text(stmt, i).map { String(cString: $0) } }
        func blob(_ i: Int32) -> UnsafeRawBufferPointer {
            UnsafeRawBufferPointer(start: sqlite3_column_blob(stmt, i), count: Int(sqlite3_column_bytes(stmt, i)))
        }
    }

    /// Streams rows to `body` without materialising them, so a scan of any size runs in constant memory.
    /// `body` returns false to stop early.
    func each(_ sql: String, _ params: SQLBindable?..., body: (Cursor) throws -> Bool) throws {
        lock.lock(); defer { lock.unlock() }
        let stmt = try prepare(sql)
        defer { sqlite3_reset(stmt) }
        bind(stmt, params)
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { return }
            guard rc == SQLITE_ROW else { throw SQLiteError(message: errorMessage) }
            if try !body(Cursor(stmt: stmt)) { return }
        }
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }
        try script("BEGIN IMMEDIATE")
        do { let r = try body(); try script("COMMIT"); return r }
        catch { try? script("ROLLBACK"); throw error }
    }

    var lastInsertRowID: Int64 { sqlite3_last_insert_rowid(db) }
}
