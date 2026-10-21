import XCTest
import Combine
@testable import MyAITeacher

/// Deterministic tests for telemetry aggregation, rollups, retention and overhead (UTC day keys, fixed timestamps).
final class TelemetryTests: XCTestCase {
    var dir: URL!
    var db: Database!
    var store: TelemetryStore!
    let utc = TelemetryCalendar(timeZone: TimeZone(identifier: "UTC")!)
    /// 2026-03-10 12:00:00 UTC
    let t0 = 1_773_144_000.0

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("telemetry-\(UUID().uuidString.prefix(8))")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        db = try Database(path: dir.appendingPathComponent("t.sqlite").path)
        try db.script(Schema_.sql)
        store = TelemetryStore(db: db, calendar: utc)
    }
    override func tearDown() { try? FileManager.default.removeItem(at: dir) }

    func step(_ ts: Double, provider: String = "openrouter", model: String = "m1", duration: Double = 2, ttft: Double? = 0.5,
              input: Int = 100, cacheRead: Int = 300, cacheWrite: Int = 0, output: Int = 51, reasoning: Int = 0,
              ok: Bool = true, estimated: Bool = false, ctx: Double = 400, conv: String = "c1") -> TelemetryEvent {
        var a: [String: Double] = ["input": Double(input), "cacheRead": Double(cacheRead), "cacheWrite": Double(cacheWrite),
                                   "output": Double(output), "reasoning": Double(reasoning), "gen": duration - (ttft ?? 0), "ctx": ctx]
        if let ttft { a["ttft"] = ttft }
        if estimated { a["estimated"] = 1 }
        return TelemetryEvent(ts: ts, kind: .step, provider: provider, model: model, conv: conv, value: duration, ok: ok, label: "end_turn", attrs: a)
    }

    // MARK: Histogram

    func testHistogramQuantilesWithinBucketError() {
        var b: [Int: Int] = [:]
        for v in 1...1000 { b[TelemetryHistogram.bucket(Double(v)), default: 0] += 1 }
        let pairs = b.map { ($0.key, $0.value) }
        let p50 = TelemetryHistogram.quantile(0.5, pairs)!, p95 = TelemetryHistogram.quantile(0.95, pairs)!
        XCTAssertEqual(p50, 500, accuracy: 500 * 0.10)
        XCTAssertEqual(p95, 950, accuracy: 950 * 0.10)
        XCTAssertNil(TelemetryHistogram.quantile(0.5, []))
        XCTAssertEqual(TelemetryHistogram.bucket(0), -40)
        XCTAssertEqual(TelemetryHistogram.value(-40), 0)
    }

    // MARK: Rollups

    func testRollupBatchMergesAndComputesDecode() {
        var b = RollupBatch()
        b.add(step(t0), day: "d")
        b.add(step(t0 + 1, ok: false), day: "d")
        b.add(step(t0 + 2, output: 400, estimated: true), day: "d")
        let d = b.llm[.init(day: "d", provider: "openrouter", model: "m1")]!
        XCTAssertEqual(d.calls, 3)
        XCTAssertEqual(d.errors, 1)
        XCTAssertEqual(d.estimated, 1)
        XCTAssertEqual(d.output, 51 + 51 + 400)
        XCTAssertEqual(d.cacheRead, 900)
        XCTAssertEqual(d.ttftN, 3)
        // Estimated usage is excluded from decode speed: only two calls contribute gen time.
        XCTAssertEqual(d.genOutput, 102)
        XCTAssertEqual(d.genSeconds, 3, accuracy: 1e-9)
        let decodeObs = b.hist.filter { $0.key.metric == TelemetryMetric.decode }.values.reduce(0, +)
        XCTAssertEqual(decodeObs, 2)
        XCTAssertEqual(b.counts[.init(day: "d", metric: "finish", key: "end_turn")]?.n, 3)
    }

    func testWriteAndQueryAcrossDaysAndFilters() throws {
        let day = 86400.0
        try store.write([
            step(t0 - day), step(t0 - day + 10, model: "m2", ttft: 2.0),
            step(t0), step(t0 + 5, provider: "minimax", model: "M3", ttft: 1.0, cacheRead: 0),
            TelemetryEvent(ts: t0 + 6, kind: .tool, name: "read", value: 0.2, ok: true),
            TelemetryEvent(ts: t0 + 7, kind: .tool, name: "read", value: 0.4, ok: false),
            TelemetryEvent(ts: t0 + 8, kind: .tool, name: "bash", value: 10, ok: true, attrs: ["waited": 8]),
            TelemetryEvent(ts: t0 + 9, kind: .approval, name: "bash", value: 8, ok: true, label: "allow_once"),
            TelemetryEvent(ts: t0 + 9, kind: .approval, name: "write", value: 0, ok: false, label: "policy"),
            TelemetryEvent(ts: t0 + 10, kind: .error, provider: "minimax", model: "M3", name: "rate_limit", ok: false, label: "429"),
        ])
        let all = TelemetryStore.Filter(since: 0)
        let byDay = store.llmByDay(all)
        XCTAssertEqual(byDay.map(\.day), ["2026-03-09", "2026-03-10"])
        XCTAssertEqual(byDay.map(\.row.calls), [2, 2])

        let byModel = store.llmByModel(all)
        XCTAssertEqual(byModel.count, 3)
        let m1 = byModel.first { $0.model == "m1" }!
        XCTAssertEqual(m1.calls, 2)
        XCTAssertEqual(m1.cacheHitRate!, 0.75, accuracy: 1e-9)

        // Range filter is by day key: since = start of 2026-03-10 UTC.
        let today = TelemetryStore.Filter(since: t0 - 12 * 3600)
        XCTAssertEqual(store.llmByModel(today).reduce(0) { $0 + $1.calls }, 2)
        // Provider and model filters.
        XCTAssertEqual(store.llmByModel(.init(since: 0, provider: "minimax")).map(\.model), ["M3"])
        XCTAssertEqual(store.llmByModel(.init(since: 0, provider: "openrouter", model: "m2")).first?.calls, 1)

        // Quantiles merge across days; per-model split.
        let q = store.quantiles(TelemetryMetric.ttft, all, perModel: true)
        XCTAssertEqual(q.first { $0.model == "m2" }?.p50 ?? 0, 2000, accuracy: 2000 * 0.1)
        XCTAssertEqual(q.first { $0.model == "m1" }?.n, 2)
        let overall = store.quantiles(TelemetryMetric.ttft, all, perModel: false).first!
        XCTAssertEqual(overall.n, 4)

        // Tools: duration excludes learner wait; failure rate.
        let tools = store.tools(since: 0)
        let read = tools.first { $0.tool == "read" }!
        XCTAssertEqual(read.calls, 2); XCTAssertEqual(read.failures, 1)
        XCTAssertEqual(read.failureRate, 0.5)
        let bash = tools.first { $0.tool == "bash" }!
        XCTAssertEqual(bash.meanSeconds, 2, accuracy: 1e-9)
        XCTAssertEqual(bash.p50 ?? 0, 2000, accuracy: 200)

        let approvals = Dictionary(uniqueKeysWithValues: store.counts("approval", since: 0).map { ($0.key, $0.n) })
        XCTAssertEqual(approvals, ["allowed": 1, "blocked": 1])
        XCTAssertEqual(store.counts("error", since: 0).first?.key, "minimax|rate_limit")
        XCTAssertEqual(store.recentEvents(.error, since: 0, limit: 5).first?.label, "429")
        XCTAssertEqual(store.models(since: 0).count, 3)

        // Context series per lesson from raw events.
        XCTAssertEqual(store.contextSeries(conv: "c1").steps.count, 4)
    }

    func testRetentionPrunesRawButKeepsRollups() throws {
        let now = t0
        try store.write([step(now - 40 * 86400), step(now - 31 * 86400), step(now - 86400), step(now)])
        XCTAssertEqual(store.recentEvents(.step, since: 0, limit: 10).count, 4)
        let removed = store.prune(now: now)
        XCTAssertEqual(removed, 2)
        XCTAssertEqual(store.recentEvents(.step, since: 0, limit: 10).count, 2)
        XCTAssertEqual(store.llmByModel(.init(since: 0)).first?.calls, 4, "daily rollups are kept forever")
        XCTAssertEqual(store.quantiles(TelemetryMetric.ttft, .init(since: 0), perModel: false).first?.n, 4)
        XCTAssertEqual(store.rawCount(), 2)
        // The retention delete uses the ts index (no full scan).
        let plan = try db.query("EXPLAIN QUERY PLAN DELETE FROM tm_events WHERE ts < ?", 0.0).compactMap { $0.string("detail") }.joined(separator: " ")
        XCTAssertTrue(plan.contains("tm_events_ts"), plan)
    }

    func testDashboardQueriesUseIndexes() throws {
        func plan(_ sql: String, _ p: SQLBindable...) throws -> String {
            try db.query("EXPLAIN QUERY PLAN " + sql, params: p).compactMap { $0.string("detail") }.joined(separator: " | ")
        }
        XCTAssertTrue(try plan("SELECT * FROM tm_events WHERE kind = ? AND ts >= ? ORDER BY ts DESC LIMIT 5", "error", 0.0).contains("tm_events_kind_ts"))
        XCTAssertTrue(try plan("SELECT ts FROM tm_events WHERE conv = ? AND kind IN ('step','compaction') ORDER BY ts", "c").contains("tm_events_conv_ts"))
        XCTAssertTrue(try plan("SELECT key, SUM(n) FROM tm_count_daily WHERE metric = ? AND day >= ? GROUP BY key", "x", "2026").contains("tm_count_metric"))
        XCTAssertTrue(try plan("SELECT bucket, SUM(n) FROM tm_hist_daily WHERE metric = ? AND day >= ? GROUP BY bucket", "x", "2026").contains("tm_hist_metric"))
        XCTAssertTrue(try plan("SELECT * FROM reviews WHERE reviewed_at >= ?", 0.0).contains("reviews_time"))
        XCTAssertFalse(try plan("SELECT SUM(calls) FROM tm_llm_daily WHERE day >= ?", "2026").contains("SCAN tm_llm_daily "), "rollup reads by PK range")
    }

    func testDayKeysRespectTimeZone() throws {
        // 23:30 UTC on 03-10 is 03-11 in Tokyo.
        let tokyo = TelemetryStore(db: db, calendar: TelemetryCalendar(timeZone: TimeZone(identifier: "Asia/Tokyo")!))
        try tokyo.write([step(t0 + 11.5 * 3600)])
        XCTAssertEqual(tokyo.llmByDay(.init(since: 0)).map(\.day), ["2026-03-11"])
        try store.write([step(t0 + 11.5 * 3600)])
        XCTAssertEqual(store.llmByDay(.init(since: 0)).map(\.day), ["2026-03-10", "2026-03-11"])
    }

    func testLearningOutcomesAndClearAndExport() throws {
        try db.execute("INSERT INTO reviews(card_id, rating, reviewed_at) VALUES(1, 1, ?), (1, 3, ?), (2, 4, ?)", t0, t0 + 1, t0 + 2)
        try db.execute("INSERT INTO quiz_attempts(conversation_id, title, score, total, created_at) VALUES('c','q',4,5,?), ('c','q',2,4,?)", t0, t0 + 1)
        let r = store.reviewsByDay(since: t0 - 10)
        XCTAssertEqual(r.reduce(0) { $0 + $1.n }, 3)
        XCTAssertEqual(r.filter { $0.rating > 1 }.reduce(0) { $0 + $1.n }, 2)
        let q = store.quizzesByDay(since: t0 - 10)
        XCTAssertEqual(q.first?.attempts, 2)
        XCTAssertEqual(q.first?.scorePct ?? 0, 65, accuracy: 1e-6)

        try store.write([step(t0), TelemetryEvent(ts: t0, kind: .memory, name: "recalled", value: 3)])
        let json = try JSONSerialization.jsonObject(with: store.exportJSON()) as! [String: Any]
        XCTAssertEqual((json["llm_daily"] as? [[String: Any]])?.count, 1)
        XCTAssertEqual((json["events"] as? [[String: Any]])?.count, 2)
        XCTAssertNotNil(json["hist_daily"])
        store.clear()
        XCTAssertTrue(store.llmByModel(.init(since: 0)).isEmpty)
        XCTAssertTrue(store.recentEvents(.step, since: 0, limit: 5).isEmpty)
        XCTAssertEqual(store.reviewsByDay(since: 0).count, 3, "clearing telemetry never touches study data")
    }

    // MARK: Mapping

    func testMapperBuildsStepToolTurnAndErrorEvents() {
        var s1 = StepMetrics(provider: "openrouter", model: "m", startedAt: Date(timeIntervalSince1970: t0))
        s1.timeToFirstToken = 0.4; s1.duration = 1.4; s1.usage = Usage(input: 10, output: 21, cacheRead: 90); s1.toolCalls = 1
        var s2 = StepMetrics(provider: "openrouter", model: "m", startedAt: Date(timeIntervalSince1970: t0 + 3))
        s2.duration = 0.3; s2.retries = 2
        var turn = TurnMetrics(startedAt: Date(timeIntervalSince1970: t0))
        turn.duration = 4; turn.steps = 2; turn.tools = [ToolMetric(name: "web_search", duration: 1.2, ok: true, waitedForLearner: nil)]
        turn.memoriesRecalled = ["a", "b"]; turn.error = "HTTP 429: rate limited"
        let ev = TelemetryMapper.events(turn: turn, steps: [(s1, nil), (s2, "HTTP 429: rate limited")], conversationID: "c")
        XCTAssertEqual(ev.map(\.kind), [.step, .step, .error, .tool, .turn])
        XCTAssertEqual(ev[0].attr("ctx"), 100)
        XCTAssertEqual(ev[0].attr("ttft"), 0.4)
        XCTAssertEqual(ev[0].attr("gen")!, 1.0, accuracy: 1e-9)
        XCTAssertFalse(ev[1].ok)
        XCTAssertEqual(ev[2].name, "rate_limit")
        XCTAssertEqual(ev[3].name, "web_search")
        XCTAssertEqual(ev[4].attr("memRecalled"), 2)
        XCTAssertEqual(ev[4].attr("error"), 1)
        // A learner stop is not an error.
        let stopped = TelemetryMapper.events(turn: turn, steps: [(s2, "Stopped.")], conversationID: "c")
        XCTAssertTrue(stopped[0].ok); XCTAssertEqual(stopped[0].label, "cancelled")
        XCTAssertFalse(stopped.contains { $0.kind == .error })
    }

    func testErrorCategories() {
        XCTAssertEqual(TelemetryMapper.errorCategory("HTTP 429 Too Many Requests"), "rate_limit")
        XCTAssertEqual(TelemetryMapper.errorCategory("401 Unauthorized: invalid api key"), "auth")
        XCTAssertEqual(TelemetryMapper.errorCategory("The request timed out."), "timeout")
        XCTAssertEqual(TelemetryMapper.errorCategory("HTTP 503: overloaded"), "server")
        XCTAssertEqual(TelemetryMapper.errorCategory("The Internet connection appears to be offline."), "network")
        XCTAssertEqual(TelemetryMapper.errorCategory("prompt is too long: maximum context length"), "context_length")
        XCTAssertEqual(TelemetryMapper.errorCategory("weird"), "other")
    }

    func testWebFrameEventsRollIntoHistogram() throws {
        let frames: [JSON] = (1...40).map { .number(Double($0) / 4) }   // 0.25 … 10 ms
        let j: JSON = ["type": "telemetry", "frames": .array(frames), "resets": [["ms": 12.5, "n": 30]], "load": ["dcl": 80, "load": 120]]
        let ev = WebTelemetry.events(from: j, now: t0)
        XCTAssertEqual(ev.map(\.name), ["frame", "reset", "load"])
        try store.write(ev)
        let q = store.quantiles(TelemetryMetric.frame, .init(since: 0), perModel: false).first!
        XCTAssertEqual(q.n, 40)
        XCTAssertEqual(q.p50 ?? 0, 5, accuracy: 0.6)
        XCTAssertEqual(store.quantiles(TelemetryMetric.reset, .init(since: 0), perModel: false).first?.n, 1)
        XCTAssertEqual(store.total("web.frame", since: 0).n, 40)
    }

    @MainActor
    func testApprovalObserverPublishesOnceForEachDecision() {
        var got: [(String, Bool)] = []
        let c = EventBus.subject.sink { e in if case .approval(_, _, let choice, let allowed, _) = e { got.append((choice, allowed)) } }
        defer { c.cancel() }
        let req = ApprovalRequest(title: "t", detail: "d", options: [])
        let d = ExtensionHost.observed(.ask(req, resolve: { $0 == "yes" ? .allow : .deny("no") }), tool: "bash", conversationID: "c")
        guard case .ask(_, let resolve) = d else { return XCTFail() }
        if case .allow = resolve("yes") {} else { XCTFail() }
        if case .deny = resolve("no") {} else { XCTFail() }
        _ = ExtensionHost.observed(.deny("blocked"), tool: "write", conversationID: "c")
        _ = ExtensionHost.observed(.allow, tool: "read", conversationID: "c")
        XCTAssertEqual(got.map(\.0), ["yes", "no", "policy"])
        XCTAssertEqual(got.map(\.1), [true, false, false])
    }

    // MARK: Recorder

    func testRecorderBuffersFlushesAndRespectsToggle() {
        let t = Telemetry(store: store, maxBuffer: 3, enabled: true)
        t.record(step(t0)); t.record([step(t0 + 1), step(t0 + 2), step(t0 + 3)])
        XCTAssertEqual(t.buffered, 3)
        XCTAssertEqual(t.overhead.dropped, 1)
        t.flushNow()
        XCTAssertEqual(t.buffered, 0)
        XCTAssertEqual(store.llmByModel(.init(since: 0)).first?.calls, 3)
        t.setEnabled(false)
        t.record(step(t0 + 4))
        XCTAssertEqual(t.buffered, 0)
        XCTAssertEqual(t.overhead.events, 3)
    }

    func testResourceSamplerReadsOwnProcess() {
        let t = Telemetry(store: store, enabled: true)
        t.sampler.registerWebProcess(getpid())   // stand-in for the WebContent pid
        t.sampler.sample(into: t, force: true)
        t.flushNow()
        let e = store.recentEvents(.resource, since: 0, limit: 1).first
        XCTAssertGreaterThan(e?.attr("footprintMB") ?? 0, 1)
        XCTAssertEqual(e?.attr("webProcs"), 1)
        XCTAssertGreaterThan(ProcessClock.startTime, 1_600_000_000)
        XCTAssertLessThanOrEqual(ProcessClock.startTime, Date().timeIntervalSince1970)
    }

    /// Measures the hot path. Prints numbers for the report; bounds are loose so CI noise can't flake.
    func testOverheadIsNegligible() {
        let t = Telemetry(store: store, maxBuffer: 1_000_000, enabled: true)
        let events = (0..<20_000).map { i in step(t0 + Double(i), model: "m\(i % 4)", conv: "c\(i % 10)") }
        let c0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for e in events { t.record(e) }
        let recordNs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c0) / Double(events.count)

        var s1 = StepMetrics(provider: "p", model: "m", startedAt: Date(timeIntervalSince1970: t0)); s1.duration = 1; s1.timeToFirstToken = 0.2
        var turn = TurnMetrics(startedAt: Date(timeIntervalSince1970: t0)); turn.steps = 3
        turn.tools = [ToolMetric(name: "read", duration: 0.1, ok: true), ToolMetric(name: "grep", duration: 0.1, ok: true)]
        let m0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        var n = 0
        for _ in 0..<2_000 { n += TelemetryMapper.events(turn: turn, steps: [(s1, nil), (s1, nil), (s1, nil)], conversationID: "c").count }
        let mapNs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - m0) / Double(n)

        let f0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        t.flushNow()
        let flushUs = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - f0) / 1000 / Double(events.count)
        print(String(format: "TELEMETRY OVERHEAD: record %.0f ns/event, mapping %.0f ns/event (main thread); flush %.1f µs/event (background, 20k batch)", recordNs, mapNs, flushUs))
        XCTAssertLessThan(recordNs, 20_000)
        XCTAssertLessThan(mapNs, 50_000)
        XCTAssertLessThan(flushUs, 500)
        XCTAssertEqual(store.llmByModel(.init(since: 0)).reduce(0) { $0 + $1.calls }, 20_000)
    }

    /// Signposts cost nothing unless the app runs with MYAITEACHER_SIGNPOSTS=1: no interval, and the detail is never built.
    func testSignpostsAreFreeWhenOff() {
        XCTAssertFalse(Signposts.enabled)
        var built = 0
        let detail = { () -> String in built += 1; return "x" }
        let c0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        for _ in 0..<100_000 { Signposts.end("sql", Signposts.begin("sql", detail())); Signposts.event("mark", detail()) }
        let ns = Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - c0) / 100_000
        print(String(format: "SIGNPOSTS OFF: %.1f ns per begin+end+event", ns))
        XCTAssertNil(Signposts.begin("sql", detail()))
        XCTAssertEqual(built, 0)
        XCTAssertLessThan(ns, 2_000)
    }

    /// Live check against a free model (opt-in: TELEMETRY_LIVE=1 and OPENROUTER_API_KEY). Builds StepMetrics the way
    /// ChatSession does, maps and stores them, and reads them back through the dashboard queries.
    func testLiveFreeModelRoundTrip() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["TELEMETRY_LIVE"] == "1", let key = env["OPENROUTER_API_KEY"], !key.isEmpty else { throw XCTSkip("set TELEMETRY_LIVE=1 and OPENROUTER_API_KEY") }
        let provider = ProviderCatalog.presets.first { $0.id == "openrouter" }!
        let model = "minimax/minimax-m3.1-flash:free"
        let client = provider.client(apiKey: key)
        let req = LLMRequest(model: model, system: "Be brief.", messages: [ChatMessage(role: .user, blocks: [.text("What is 2+3? One word.")])],
                             maxTokens: 200, thinking: .off)
        var step = StepMetrics(provider: provider.id, model: model, startedAt: Date())
        var text = "", error: String?
        do {
            for try await ev in client.stream(req) {
                switch ev {
                case .text(let t): text += t; if step.timeToFirstToken == nil { step.timeToFirstToken = Date().timeIntervalSince(step.startedAt) }
                case .thinking, .toolCallStarted, .toolCall: if step.timeToFirstToken == nil { step.timeToFirstToken = Date().timeIntervalSince(step.startedAt) }
                case .usage(let u): step.usage = u
                case .stop(let r): step.finishReason = r
                default: break
                }
            }
        } catch let e { error = e.localizedDescription }
        step.duration = Date().timeIntervalSince(step.startedAt)
        var turn = TurnMetrics(startedAt: step.startedAt); turn.steps = 1; turn.duration = step.duration; turn.usage = step.usage; turn.error = error
        try store.write(TelemetryMapper.events(turn: turn, steps: [(step, error)], conversationID: "live"))
        let row = store.llmByModel(.init(since: 0)).first!
        print("LIVE: \(text.prefix(40)) | ttft \(step.timeToFirstToken ?? -1)s, total \(step.duration)s, usage \(step.usage), error \(error ?? "none")")
        XCTAssertEqual(row.calls, 1)
        if error == nil {
            XCTAssertNotNil(step.timeToFirstToken)
            XCTAssertEqual(store.quantiles(TelemetryMetric.ttft, .init(since: 0), perModel: false).first?.n, 1)
        } else {
            XCTAssertEqual(store.counts("error", since: 0).count, 1)
        }
    }
}
