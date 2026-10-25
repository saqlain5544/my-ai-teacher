import Foundation

/// SQLite storage for local telemetry, in the learner-wide `teacher.sqlite`.
///
/// * `tm_events` — raw events, kept `rawRetentionDays` (indexed by ts, kind+ts, conv+ts).
/// * `tm_llm_daily`, `tm_tool_daily`, `tm_count_daily`, `tm_hist_daily` — daily rollups, kept forever.
///   Histograms are log-bucketed so p50/p95 for any range/filter are computed from a handful of rows.
///
/// Every write goes through `write(_:)` from the telemetry queue: one transaction per batch, one INSERT per event plus
/// pre-merged rollup UPSERTs (all by primary key). Dashboard reads only touch index ranges / rollup rows.
final class TelemetryStore: @unchecked Sendable {
    let db: Database
    let calendar: TelemetryCalendar
    static let rawRetentionDays = 30

    static let schema = """
    CREATE TABLE IF NOT EXISTS tm_events(id INTEGER PRIMARY KEY AUTOINCREMENT, ts REAL NOT NULL, kind TEXT NOT NULL,
        provider TEXT NOT NULL DEFAULT '', model TEXT NOT NULL DEFAULT '', conv TEXT, name TEXT NOT NULL DEFAULT '',
        value REAL NOT NULL DEFAULT 0, ok INTEGER NOT NULL DEFAULT 1, label TEXT, attrs TEXT);
    CREATE INDEX IF NOT EXISTS tm_events_ts ON tm_events(ts);
    CREATE INDEX IF NOT EXISTS tm_events_kind_ts ON tm_events(kind, ts);
    CREATE INDEX IF NOT EXISTS tm_events_conv_ts ON tm_events(conv, ts) WHERE conv IS NOT NULL;
    CREATE TABLE IF NOT EXISTS tm_llm_daily(day TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
        calls INTEGER NOT NULL DEFAULT 0, errors INTEGER NOT NULL DEFAULT 0, retries INTEGER NOT NULL DEFAULT 0, estimated INTEGER NOT NULL DEFAULT 0,
        input INTEGER NOT NULL DEFAULT 0, cache_read INTEGER NOT NULL DEFAULT 0, cache_write INTEGER NOT NULL DEFAULT 0,
        output INTEGER NOT NULL DEFAULT 0, reasoning INTEGER NOT NULL DEFAULT 0, duration REAL NOT NULL DEFAULT 0,
        ttft_sum REAL NOT NULL DEFAULT 0, ttft_n INTEGER NOT NULL DEFAULT 0, gen_seconds REAL NOT NULL DEFAULT 0, gen_output INTEGER NOT NULL DEFAULT 0,
        PRIMARY KEY(day, provider, model)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS tm_tool_daily(day TEXT NOT NULL, tool TEXT NOT NULL, calls INTEGER NOT NULL DEFAULT 0,
        failures INTEGER NOT NULL DEFAULT 0, duration REAL NOT NULL DEFAULT 0, waited REAL NOT NULL DEFAULT 0,
        PRIMARY KEY(day, tool)) WITHOUT ROWID;
    CREATE TABLE IF NOT EXISTS tm_count_daily(day TEXT NOT NULL, metric TEXT NOT NULL, key TEXT NOT NULL,
        n INTEGER NOT NULL DEFAULT 0, sum REAL NOT NULL DEFAULT 0, PRIMARY KEY(day, metric, key)) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS tm_count_metric ON tm_count_daily(metric, day);
    CREATE TABLE IF NOT EXISTS tm_hist_daily(day TEXT NOT NULL, metric TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
        bucket INTEGER NOT NULL, n INTEGER NOT NULL DEFAULT 0, PRIMARY KEY(day, metric, provider, model, bucket)) WITHOUT ROWID;
    CREATE INDEX IF NOT EXISTS tm_hist_metric ON tm_hist_daily(metric, day);
    CREATE TABLE IF NOT EXISTS tm_meta(key TEXT PRIMARY KEY, value TEXT);
    """
    /// Time indexes on the study tables so learning-outcome charts read index ranges (tables owned by Schema_).
    static let studyIndexes = [
        "CREATE INDEX IF NOT EXISTS reviews_time ON reviews(reviewed_at)",
        "CREATE INDEX IF NOT EXISTS quiz_attempts_time ON quiz_attempts(created_at)",
    ]

    init(db: Database, calendar: TelemetryCalendar = TelemetryCalendar()) {
        self.db = db
        self.calendar = calendar
        try? db.script(Self.schema)
        for sql in Self.studyIndexes { try? db.script(sql) }
    }

    private static let enc: JSONEncoder = { let e = JSONEncoder(); e.outputFormatting = .sortedKeys; return e }()

    // MARK: Writes

    /// Appends a batch: raw rows + merged rollups, one transaction.
    func write(_ events: [TelemetryEvent]) throws {
        guard !events.isEmpty else { return }
        var batch = RollupBatch()
        let fmt = calendar.dayFormatter()
        // Local day keys cached per 15-minute slot (every UTC offset is a multiple of 15 min, so a slot never spans midnight).
        var cache: (slot: Int, day: String) = (Int.min, "")
        for e in events {
            let slot = Int((e.ts / 900).rounded(.down))
            if slot != cache.slot { cache = (slot, fmt.string(from: Date(timeIntervalSince1970: e.ts))) }
            batch.add(e, day: cache.day)
        }
        try db.transaction {
            for e in events {
                let attrs = e.attrs.isEmpty ? nil : (try? Self.enc.encode(e.attrs)).map { String(decoding: $0, as: UTF8.self) }
                try db.execute("INSERT INTO tm_events(ts, kind, provider, model, conv, name, value, ok, label, attrs) VALUES(?,?,?,?,?,?,?,?,?,?)",
                               e.ts, e.kind.rawValue, e.provider, e.model, e.conv, e.name, e.value, e.ok, e.label, attrs)
            }
            try apply(batch)
        }
    }

    private func apply(_ b: RollupBatch) throws {
        for (k, d) in b.llm {
            try db.execute("""
                INSERT INTO tm_llm_daily(day, provider, model, calls, errors, retries, estimated, input, cache_read, cache_write, output, reasoning,
                    duration, ttft_sum, ttft_n, gen_seconds, gen_output) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                ON CONFLICT(day, provider, model) DO UPDATE SET calls=calls+excluded.calls, errors=errors+excluded.errors,
                    retries=retries+excluded.retries, estimated=estimated+excluded.estimated, input=input+excluded.input,
                    cache_read=cache_read+excluded.cache_read, cache_write=cache_write+excluded.cache_write, output=output+excluded.output,
                    reasoning=reasoning+excluded.reasoning, duration=duration+excluded.duration, ttft_sum=ttft_sum+excluded.ttft_sum,
                    ttft_n=ttft_n+excluded.ttft_n, gen_seconds=gen_seconds+excluded.gen_seconds, gen_output=gen_output+excluded.gen_output
                """, params: [k.day, k.provider, k.model, d.calls, d.errors, d.retries, d.estimated, d.input, d.cacheRead, d.cacheWrite, d.output,
                              d.reasoning, d.duration, d.ttftSum, d.ttftN, d.genSeconds, d.genOutput])
        }
        for (k, d) in b.tools {
            try db.execute("""
                INSERT INTO tm_tool_daily(day, tool, calls, failures, duration, waited) VALUES(?,?,?,?,?,?)
                ON CONFLICT(day, tool) DO UPDATE SET calls=calls+excluded.calls, failures=failures+excluded.failures,
                    duration=duration+excluded.duration, waited=waited+excluded.waited
                """, k.day, k.tool, d.calls, d.failures, d.duration, d.waited)
        }
        for (k, c) in b.counts {
            try db.execute("""
                INSERT INTO tm_count_daily(day, metric, key, n, sum) VALUES(?,?,?,?,?)
                ON CONFLICT(day, metric, key) DO UPDATE SET n=n+excluded.n, sum=sum+excluded.sum
                """, k.day, k.metric, k.key, c.n, c.sum)
        }
        for (k, n) in b.hist {
            try db.execute("""
                INSERT INTO tm_hist_daily(day, metric, provider, model, bucket, n) VALUES(?,?,?,?,?,?)
                ON CONFLICT(day, metric, provider, model, bucket) DO UPDATE SET n=n+excluded.n
                """, k.day, k.metric, k.provider, k.model, k.bucket, n)
        }
    }

    /// Deletes raw events older than the retention window (rollups are kept). Uses the ts index.
    @discardableResult
    func prune(now: Double = Date().timeIntervalSince1970, retentionDays: Int = TelemetryStore.rawRetentionDays) -> Int {
        let cutoff = now - Double(retentionDays) * 86400
        let n = (db.run("DELETE FROM tm_events WHERE ts < ?", cutoff)) ?? 0
        db.run("INSERT INTO tm_meta(key, value) VALUES('last_prune', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", String(now))
        return n
    }

    func clear() {
        try? db.transaction {
            for t in ["tm_events", "tm_llm_daily", "tm_tool_daily", "tm_count_daily", "tm_hist_daily", "tm_meta"] { try db.execute("DELETE FROM \(t)") }
        }
    }

    // MARK: Reads

    struct Filter: Sendable, Equatable {
        var since: Double = 0
        var provider: String?
        var model: String?
    }

    private func dayBound(_ f: Filter) -> String { f.since <= 0 ? "0000-00-00" : calendar.day(f.since) }
    private func llmWhere(_ f: Filter, prefix: String = "") -> (String, [SQLBindable?]) {
        var sql = "\(prefix)day >= ?"
        var p: [SQLBindable?] = [dayBound(f)]
        if let pr = f.provider { sql += " AND \(prefix)provider = ?"; p.append(pr) }
        if let m = f.model { sql += " AND \(prefix)model = ?"; p.append(m) }
        return (sql, p)
    }

    struct LLMRow: Sendable, Identifiable, Hashable {
        var provider: String, model: String
        var calls = 0, errors = 0, retries = 0, estimated = 0
        var input = 0, cacheRead = 0, cacheWrite = 0, output = 0, reasoning = 0
        var duration = 0.0, ttftSum = 0.0, ttftN = 0, genSeconds = 0.0, genOutput = 0
        var id: String { provider + "/" + model }
        var promptTotal: Int { input + cacheRead + cacheWrite }
        var cacheHitRate: Double? { promptTotal > 0 ? Double(cacheRead) / Double(promptTotal) : nil }
        var errorRate: Double? { calls > 0 ? Double(errors) / Double(calls) : nil }
    }

    private func llmRow(_ r: Row, provider: String, model: String) -> LLMRow {
        LLMRow(provider: provider, model: model, calls: r.int("calls") ?? 0, errors: r.int("errors") ?? 0, retries: r.int("retries") ?? 0,
               estimated: r.int("estimated") ?? 0, input: r.int("input") ?? 0, cacheRead: r.int("cache_read") ?? 0,
               cacheWrite: r.int("cache_write") ?? 0, output: r.int("output") ?? 0, reasoning: r.int("reasoning") ?? 0,
               duration: r.double("duration") ?? 0, ttftSum: r.double("ttft_sum") ?? 0, ttftN: r.int("ttft_n") ?? 0,
               genSeconds: r.double("gen_seconds") ?? 0, genOutput: r.int("gen_output") ?? 0)
    }
    private static let llmSums = """
        SUM(calls) calls, SUM(errors) errors, SUM(retries) retries, SUM(estimated) estimated, SUM(input) input, SUM(cache_read) cache_read,
        SUM(cache_write) cache_write, SUM(output) output, SUM(reasoning) reasoning, SUM(duration) duration, SUM(ttft_sum) ttft_sum,
        SUM(ttft_n) ttft_n, SUM(gen_seconds) gen_seconds, SUM(gen_output) gen_output
        """

    /// Totals per provider/model over the range.
    func llmByModel(_ f: Filter) -> [LLMRow] {
        let (w, p) = llmWhere(f)
        let rows = (try? db.query("SELECT provider, model, \(Self.llmSums) FROM tm_llm_daily WHERE \(w) GROUP BY provider, model ORDER BY calls DESC", params: p)) ?? []
        return rows.map { llmRow($0, provider: $0.string("provider") ?? "", model: $0.string("model") ?? "") }
    }

    /// Totals per day (all matching models summed). `provider` holds the day.
    func llmByDay(_ f: Filter) -> [(day: String, row: LLMRow)] {
        let (w, p) = llmWhere(f)
        let rows = (try? db.query("SELECT day, \(Self.llmSums) FROM tm_llm_daily WHERE \(w) GROUP BY day ORDER BY day", params: p)) ?? []
        return rows.map { ($0.string("day") ?? "", llmRow($0, provider: "", model: "")) }
    }

    /// Distinct provider/model pairs seen in the range (for the filter menu).
    func models(since: Double) -> [(provider: String, model: String)] {
        let rows = (try? db.query("SELECT DISTINCT provider, model FROM tm_llm_daily WHERE day >= ? ORDER BY provider, model", dayBound(Filter(since: since)))) ?? []
        return rows.map { ($0.string("provider") ?? "", $0.string("model") ?? "") }
    }

    struct Quantiles: Sendable, Hashable, Identifiable {
        var provider: String, model: String
        var n: Int
        var p50: Double?, p95: Double?
        var id: String { provider + "/" + model }
    }

    /// p50/p95 of a histogram metric over the range, optionally per provider/model.
    func quantiles(_ metric: String, _ f: Filter, perModel: Bool) -> [Quantiles] {
        let (w, p) = llmWhere(f)
        let rows = (try? db.query("""
            SELECT \(perModel ? "provider, model," : "") bucket, SUM(n) n FROM tm_hist_daily WHERE metric = ? AND \(w)
            GROUP BY \(perModel ? "provider, model," : "") bucket
            """, params: [metric] + p)) ?? []
        var groups: [String: (String, String, [(Int, Int)])] = [:]
        for r in rows {
            let pr = perModel ? (r.string("provider") ?? "") : "", m = perModel ? (r.string("model") ?? "") : ""
            groups[pr + "\u{1}" + m, default: (pr, m, [])].2.append((r.int("bucket") ?? 0, r.int("n") ?? 0))
        }
        return groups.values.map { pr, m, b in
            Quantiles(provider: pr, model: m, n: b.reduce(0) { $0 + $1.1 },
                      p50: TelemetryHistogram.quantile(0.5, b), p95: TelemetryHistogram.quantile(0.95, b))
        }.sorted { $0.n > $1.n }
    }

    /// Quantiles of a histogram metric, keyed on the `model` column (used for per-tool durations).
    func quantilesByKey(_ metric: String, since: Double) -> [String: Quantiles] {
        Dictionary(quantiles(metric, Filter(since: since), perModel: true).map { ($0.model, $0) }, uniquingKeysWith: { a, _ in a })
    }

    struct ToolRow: Sendable, Hashable, Identifiable {
        var tool: String
        var calls: Int, failures: Int, duration: Double, waited: Double
        var p50: Double?, p95: Double?
        var id: String { tool }
        var failureRate: Double { calls > 0 ? Double(failures) / Double(calls) : 0 }
        var meanSeconds: Double { calls > 0 ? max(0, duration - waited) / Double(calls) : 0 }
    }

    func tools(since: Double) -> [ToolRow] {
        let rows = (try? db.query("""
            SELECT tool, SUM(calls) calls, SUM(failures) failures, SUM(duration) duration, SUM(waited) waited FROM tm_tool_daily
            WHERE day >= ? GROUP BY tool ORDER BY calls DESC
            """, dayBound(Filter(since: since)))) ?? []
        let q = quantilesByKey(TelemetryMetric.toolDuration, since: since)
        return rows.map { r in
            let t = r.string("tool") ?? ""
            return ToolRow(tool: t, calls: r.int("calls") ?? 0, failures: r.int("failures") ?? 0, duration: r.double("duration") ?? 0,
                           waited: r.double("waited") ?? 0, p50: q[t]?.p50, p95: q[t]?.p95)
        }
    }

    struct CountRow: Sendable, Hashable { var day: String; var key: String; var n: Int; var sum: Double }

    /// Counter totals by key over the range (uses the metric/day index).
    func counts(_ metric: String, since: Double) -> [CountRow] {
        let rows = (try? db.query("SELECT key, SUM(n) n, SUM(sum) s FROM tm_count_daily WHERE metric = ? AND day >= ? GROUP BY key ORDER BY n DESC",
                                  metric, dayBound(Filter(since: since)))) ?? []
        return rows.map { CountRow(day: "", key: $0.string("key") ?? "", n: $0.int("n") ?? 0, sum: $0.double("s") ?? 0) }
    }

    /// Counter rows per day and key.
    func countsByDay(_ metric: String, since: Double) -> [CountRow] {
        let rows = (try? db.query("SELECT day, key, n, sum FROM tm_count_daily WHERE metric = ? AND day >= ? ORDER BY day",
                                  metric, dayBound(Filter(since: since)))) ?? []
        return rows.map { CountRow(day: $0.string("day") ?? "", key: $0.string("key") ?? "", n: $0.int("n") ?? 0, sum: $0.double("sum") ?? 0) }
    }

    func total(_ metric: String, since: Double) -> (n: Int, sum: Double) {
        counts(metric, since: since).reduce((0, 0.0)) { ($0.0 + $1.n, $0.1 + $1.sum) }
    }

    // Raw-event reads (bounded by the 30-day retention and served by indexes).

    func recentEvents(_ kind: TelemetryEvent.Kind, since: Double, limit: Int) -> [TelemetryEvent] {
        let rows = (try? db.query("SELECT * FROM tm_events WHERE kind = ? AND ts >= ? ORDER BY ts DESC LIMIT ?", kind.rawValue, since, limit)) ?? []
        return rows.map(Self.event)
    }

    /// Lessons with model calls in the range, most recent first.
    func recentLessons(since: Double, limit: Int = 12) -> [(conv: String, last: Double, steps: Int, maxContext: Double)] {
        let rows = (try? db.query("""
            SELECT conv, MAX(ts) last, COUNT(*) steps FROM tm_events WHERE kind = 'step' AND ts >= ? AND conv IS NOT NULL
            GROUP BY conv ORDER BY last DESC LIMIT ?
            """, since, limit)) ?? []
        return rows.map { ($0.string("conv") ?? "", $0.double("last") ?? 0, $0.int("steps") ?? 0, 0) }
    }

    /// Context size per model call for one lesson, plus compaction times.
    func contextSeries(conv: String) -> (steps: [(ts: Double, tokens: Double)], compactions: [Double]) {
        let rows = (try? db.query("SELECT ts, kind, attrs FROM tm_events WHERE conv = ? AND kind IN ('step','compaction') ORDER BY ts LIMIT 5000", conv)) ?? []
        var steps: [(Double, Double)] = [], comps: [Double] = []
        for r in rows {
            let ts = r.double("ts") ?? 0
            if r.string("kind") == "compaction" { comps.append(ts); continue }
            let a = r.data("attrs").flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
            if let c = a["ctx"], c > 0 { steps.append((ts, c)) }
        }
        return (steps, comps)
    }

    /// Resource samples bucketed per hour (≤ 30 days × 24 rows).
    func resourceSeries(since: Double) -> [(ts: Double, footprintMB: Double, webMB: Double, cpuPct: Double)] {
        let rows = (try? db.query("SELECT ts, attrs FROM tm_events WHERE kind = 'resource' AND ts >= ? ORDER BY ts", since)) ?? []
        var hours: [Int: (n: Double, f: Double, w: Double, c: Double)] = [:]
        for r in rows {
            let ts = r.double("ts") ?? 0
            let a = r.data("attrs").flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:]
            let h = Int(ts / 3600)
            let cur = hours[h] ?? (0, 0, 0, 0)
            hours[h] = (cur.n + 1, max(cur.f, a["footprintMB"] ?? 0), max(cur.w, a["webMB"] ?? 0), cur.c + (a["cpuPct"] ?? 0))
        }
        return hours.keys.sorted().map { h in let v = hours[h]!; return (Double(h) * 3600, v.f, v.w, v.n > 0 ? v.c / v.n : 0) }
    }

    // Learning outcomes from the study tables (indexed by time in `schema`).

    func reviewsByDay(since: Double) -> [(day: String, rating: Int, n: Int)] {
        let rows = (try? db.query("""
            SELECT date(reviewed_at, 'unixepoch', 'localtime') day, rating, COUNT(*) n FROM reviews WHERE reviewed_at >= ? GROUP BY day, rating ORDER BY day
            """, since)) ?? []
        return rows.map { ($0.string("day") ?? "", $0.int("rating") ?? 0, $0.int("n") ?? 0) }
    }

    func quizzesByDay(since: Double) -> [(day: String, attempts: Int, scorePct: Double)] {
        let rows = (try? db.query("""
            SELECT date(created_at, 'unixepoch', 'localtime') day, COUNT(*) n, AVG(CASE WHEN total > 0 THEN score * 1.0 / total END) pct
            FROM quiz_attempts WHERE created_at >= ? GROUP BY day ORDER BY day
            """, since)) ?? []
        return rows.map { ($0.string("day") ?? "", $0.int("n") ?? 0, ($0.double("pct") ?? 0) * 100) }
    }

    // MARK: Export

    /// Everything we store, as JSON (rollups for the range + raw events kept by retention).
    func exportJSON(since: Double = 0) -> Data {
        func dump(_ table: String, _ cols: [String], where w: String, _ param: SQLBindable) -> [[String: Any]] {
            let rows = (try? db.query("SELECT \(cols.joined(separator: ", ")) FROM \(table) WHERE \(w) ORDER BY 1", param)) ?? []
            return rows.map { r in
                var d: [String: Any] = [:]
                for c in cols { d[c] = Self.any(r[c]) }
                return d
            }
        }
        let day = dayBound(Filter(since: since))
        let obj: [String: Any] = [
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "schema": ["raw_retention_days": Self.rawRetentionDays, "histogram_buckets_per_octave": TelemetryHistogram.perOctave],
            "llm_daily": dump("tm_llm_daily", ["day", "provider", "model", "calls", "errors", "retries", "estimated", "input", "cache_read",
                                               "cache_write", "output", "reasoning", "duration", "ttft_sum", "ttft_n", "gen_seconds", "gen_output"],
                              where: "day >= ?", day),
            "tool_daily": dump("tm_tool_daily", ["day", "tool", "calls", "failures", "duration", "waited"], where: "day >= ?", day),
            "count_daily": dump("tm_count_daily", ["day", "metric", "key", "n", "sum"], where: "day >= ?", day),
            "hist_daily": dump("tm_hist_daily", ["day", "metric", "provider", "model", "bucket", "n"], where: "day >= ?", day),
            "events": dump("tm_events", ["ts", "kind", "provider", "model", "conv", "name", "value", "ok", "label", "attrs"], where: "ts >= ?", since),
        ]
        return (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data("{}".utf8)
    }

    private static func any(_ v: SQLValue) -> Any {
        switch v {
        case .null: return NSNull()
        case .int(let i): return i
        case .double(let d): return d
        case .text(let s): return s
        case .blob(let b): return String(decoding: b, as: UTF8.self)
        }
    }

    static func event(_ r: Row) -> TelemetryEvent {
        TelemetryEvent(ts: r.double("ts") ?? 0, kind: TelemetryEvent.Kind(rawValue: r.string("kind") ?? "") ?? .step,
                       provider: r.string("provider") ?? "", model: r.string("model") ?? "", conv: r.string("conv"),
                       name: r.string("name") ?? "", value: r.double("value") ?? 0, ok: (r.int("ok") ?? 1) != 0, label: r.string("label"),
                       attrs: r.data("attrs").flatMap { try? JSONDecoder().decode([String: Double].self, from: $0) } ?? [:])
    }

    /// Row count of the raw table (for the dashboard footer).
    /// Approximate (rowid span, O(log n)) — exact unless rows were deleted from the middle.
    func rawCount() -> Int { (try? db.query("SELECT IFNULL(MAX(id) - MIN(id) + 1, 0) n FROM tm_events"))?.first?.int("n") ?? 0 }
}
