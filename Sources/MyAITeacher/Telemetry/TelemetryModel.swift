import Foundation

/// One local telemetry record. Only numbers, ids and short labels — never message text, prompts, file contents or keys.
/// Names follow OpenTelemetry GenAI semantic conventions where they exist (see Agent/Metrics.swift).
struct TelemetryEvent: Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable, CaseIterable {
        case step        // one LLM call: provider, model, value = duration (s); attrs: tokens, ttft, gen, retries, ctx
        case turn        // one learner turn: value = wall time (s); attrs: steps, tools, ttft, memory
        case tool        // one tool call: name = tool, value = duration (s), ok; attrs: waited
        case approval    // name = tool, label = choice, ok = allowed, value = time waiting for the learner (s)
        case compaction  // conv, value = context tokens before; attrs: after
        case memory      // name = MemoryChange.Kind, value = ids touched
        case error       // provider, model, name = category, label = short message
        case resource    // attrs: footprintMB, cpuPct, webMB, webCpuPct, webProcs
        case web         // name = frame | reset | load; histogram buckets in attrs ("b<k>")
        case launch      // value = process start → first transcript ready (s); attrs: init
    }

    var ts: Double
    var kind: Kind
    var provider = ""
    var model = ""
    var conv: String?
    var name = ""
    var value: Double = 0
    var ok = true
    var label: String?
    var attrs: [String: Double] = [:]

    func attr(_ k: String) -> Double? { attrs[k] }
}

/// Log-scale histogram buckets (4 per doubling ≈ ±9 % quantile error). Mergeable across days/models, so p50/p95
/// for any range come from the rollup table rather than raw rows.
enum TelemetryHistogram {
    static let perOctave = 4.0
    static func bucket(_ v: Double) -> Int {
        guard v.isFinite, v > 0.001 else { return -40 }
        return Int(floor(log2(v) * perOctave))
    }
    /// Geometric centre of a bucket.
    static func value(_ b: Int) -> Double {
        if b <= -40 { return 0 }
        return pow(2, (Double(b) + 0.5) / perOctave)
    }
    /// Quantile from (bucket, count) pairs.
    static func quantile(_ q: Double, _ buckets: [(Int, Int)]) -> Double? {
        let sorted = buckets.filter { $0.1 > 0 }.sorted { $0.0 < $1.0 }
        let total = sorted.reduce(0) { $0 + $1.1 }
        guard total > 0 else { return nil }
        let target = max(1, Int((q * Double(total)).rounded(.up)))
        var seen = 0
        for (b, n) in sorted {
            seen += n
            if seen >= target { return value(b) }
        }
        return value(sorted.last!.0)
    }
}

/// Histogram metric names (units in the name's suffix in the dashboard).
enum TelemetryMetric {
    static let ttft = "ttft_ms"
    static let stepDuration = "step_ms"
    static let decode = "decode_tps"
    static let turnDuration = "turn_ms"
    static let toolDuration = "tool_ms"
    static let approvalWait = "approval_wait_ms"
    static let footprint = "footprint_mb"
    static let webFootprint = "web_footprint_mb"
    static let cpu = "cpu_pct"
    static let frame = "web_frame_ms"
    static let reset = "web_reset_ms"
    static let launch = "launch_ms"
    static let context = "context_tokens"
}

/// A rollup row change. Each event maps to a small, constant number of these (O(1) writes per event).
enum RollupOp: Hashable, Sendable {
    struct LLMKey: Hashable, Sendable { var day: String; var provider: String; var model: String }
    struct LLMDelta: Sendable, Equatable {
        var calls = 0, errors = 0, retries = 0, estimated = 0
        var input = 0, cacheRead = 0, cacheWrite = 0, output = 0, reasoning = 0
        var duration = 0.0, ttftSum = 0.0, ttftN = 0, genSeconds = 0.0, genOutput = 0
        static func + (a: LLMDelta, b: LLMDelta) -> LLMDelta {
            LLMDelta(calls: a.calls + b.calls, errors: a.errors + b.errors, retries: a.retries + b.retries, estimated: a.estimated + b.estimated,
                     input: a.input + b.input, cacheRead: a.cacheRead + b.cacheRead, cacheWrite: a.cacheWrite + b.cacheWrite,
                     output: a.output + b.output, reasoning: a.reasoning + b.reasoning, duration: a.duration + b.duration,
                     ttftSum: a.ttftSum + b.ttftSum, ttftN: a.ttftN + b.ttftN, genSeconds: a.genSeconds + b.genSeconds, genOutput: a.genOutput + b.genOutput)
        }
    }
    struct ToolKey: Hashable, Sendable { var day: String; var tool: String }
    struct ToolDelta: Sendable, Equatable {
        var calls = 0, failures = 0
        var duration = 0.0, waited = 0.0
        static func + (a: ToolDelta, b: ToolDelta) -> ToolDelta {
            ToolDelta(calls: a.calls + b.calls, failures: a.failures + b.failures, duration: a.duration + b.duration, waited: a.waited + b.waited)
        }
    }
    struct CountKey: Hashable, Sendable { var day: String; var metric: String; var key: String }
    struct HistKey: Hashable, Sendable { var day: String; var metric: String; var provider: String; var model: String; var bucket: Int }
}

/// Pre-aggregated rollup changes for one flush (same keys merged before touching SQLite).
struct RollupBatch: Sendable {
    var llm: [RollupOp.LLMKey: RollupOp.LLMDelta] = [:]
    var tools: [RollupOp.ToolKey: RollupOp.ToolDelta] = [:]
    var counts: [RollupOp.CountKey: (n: Int, sum: Double)] = [:]
    var hist: [RollupOp.HistKey: Int] = [:]

    var isEmpty: Bool { llm.isEmpty && tools.isEmpty && counts.isEmpty && hist.isEmpty }

    mutating func count(_ day: String, _ metric: String, _ key: String = "", n: Int = 1, sum: Double = 0) {
        let k = RollupOp.CountKey(day: day, metric: metric, key: key)
        let c = counts[k] ?? (0, 0)
        counts[k] = (c.n + n, c.sum + sum)
    }
    mutating func observe(_ day: String, _ metric: String, _ v: Double, provider: String = "", model: String = "", n: Int = 1) {
        hist[RollupOp.HistKey(day: day, metric: metric, provider: provider, model: model, bucket: TelemetryHistogram.bucket(v)), default: 0] += n
    }
    mutating func observeBucket(_ day: String, _ metric: String, bucket: Int, n: Int) {
        hist[RollupOp.HistKey(day: day, metric: metric, provider: "", model: "", bucket: bucket), default: 0] += n
    }

    /// Folds one event into the batch. Constant work per event (web frame batches: one op per distinct bucket).
    mutating func add(_ e: TelemetryEvent, day: String) {
        switch e.kind {
        case .step:
            var d = RollupOp.LLMDelta()
            d.calls = 1
            d.errors = e.ok ? 0 : 1
            d.retries = Int(e.attr("retries") ?? 0)
            d.estimated = (e.attr("estimated") ?? 0) > 0 ? 1 : 0
            d.input = Int(e.attr("input") ?? 0); d.cacheRead = Int(e.attr("cacheRead") ?? 0)
            d.cacheWrite = Int(e.attr("cacheWrite") ?? 0); d.output = Int(e.attr("output") ?? 0)
            d.reasoning = Int(e.attr("reasoning") ?? 0)
            d.duration = e.value
            let gen = e.attr("gen") ?? 0
            if let t = e.attr("ttft") { d.ttftSum = t; d.ttftN = 1; observe(day, TelemetryMetric.ttft, t * 1000, provider: e.provider, model: e.model) }
            observe(day, TelemetryMetric.stepDuration, e.value * 1000, provider: e.provider, model: e.model)
            if d.output > 1, gen > 0.05, d.estimated == 0 {
                d.genSeconds = gen; d.genOutput = d.output
                observe(day, TelemetryMetric.decode, Double(d.output - 1) / gen, provider: e.provider, model: e.model)
            }
            if let ctx = e.attr("ctx"), ctx > 0 { observe(day, TelemetryMetric.context, ctx, provider: e.provider, model: e.model) }
            let k = RollupOp.LLMKey(day: day, provider: e.provider, model: e.model)
            llm[k] = (llm[k] ?? .init()) + d
            if let f = e.label { count(day, "finish", f) }
        case .turn:
            count(day, "turn", "", sum: e.value)
            if (e.attr("cancelled") ?? 0) > 0 { count(day, "turn.cancelled") }
            if (e.attr("error") ?? 0) > 0 { count(day, "turn.error") }
            count(day, "turn.steps", "", n: 1, sum: e.attr("steps") ?? 0)
            count(day, "turn.tools", "", n: 1, sum: e.attr("tools") ?? 0)
            observe(day, TelemetryMetric.turnDuration, e.value * 1000, provider: e.provider, model: e.model)
        case .tool:
            let k = RollupOp.ToolKey(day: day, tool: e.name)
            let waited = e.attr("waited") ?? 0
            tools[k] = (tools[k] ?? .init()) + .init(calls: 1, failures: e.ok ? 0 : 1, duration: e.value, waited: waited)
            observe(day, TelemetryMetric.toolDuration, max(0, e.value - waited) * 1000, model: e.name)
        case .approval:
            let outcome = e.ok ? "allowed" : (e.label == "policy" ? "blocked" : "denied")
            count(day, "approval", outcome)
            count(day, "approval.tool", e.name + "|" + outcome)
            if e.label != "policy" { observe(day, TelemetryMetric.approvalWait, e.value * 1000) }
        case .compaction:
            count(day, "compaction", "", sum: e.value)
        case .memory:
            count(day, "memory", e.name, sum: max(1, e.value))
        case .error:
            count(day, "error", e.provider + "|" + e.name)
        case .resource:
            if let v = e.attr("footprintMB") { observe(day, TelemetryMetric.footprint, v) }
            if let v = e.attr("webMB"), v > 0 { observe(day, TelemetryMetric.webFootprint, v) }
            if let v = e.attr("cpuPct") { observe(day, TelemetryMetric.cpu, v) }
            count(day, "resource.samples")
        case .web:
            let metric = e.name == "reset" ? TelemetryMetric.reset : e.name == "frame" ? TelemetryMetric.frame : "web_" + e.name + "_ms"
            var sawBuckets = false
            for (k, n) in e.attrs where k.hasPrefix("b") {
                if let b = Int(k.dropFirst()) { observeBucket(day, metric, bucket: b, n: Int(n)); sawBuckets = true }
            }
            if !sawBuckets { observe(day, metric, e.value) }
            count(day, "web." + e.name, "", n: Int(e.attr("n") ?? 1), sum: e.attr("sum") ?? e.value)
        case .launch:
            observe(day, TelemetryMetric.launch, e.value * 1000)
            count(day, "launch", "", sum: e.value)
        }
    }
}

/// Day keys in local time (injectable for tests).
struct TelemetryCalendar: Sendable {
    var timeZone: TimeZone = .current
    private var formatter: DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f
    }
    func day(_ ts: Double) -> String { formatter.string(from: Date(timeIntervalSince1970: ts)) }
    func dayFormatter() -> DateFormatter { formatter }
}

/// Time ranges offered by the dashboard.
enum TelemetryRange: String, CaseIterable, Identifiable, Sendable {
    case today = "Today", week = "7 days", month = "30 days", quarter = "90 days", all = "All time"
    var id: String { rawValue }
    var days: Int? { switch self { case .today: 1; case .week: 7; case .month: 30; case .quarter: 90; case .all: nil } }
    /// Start timestamp (local midnight `days-1` days ago) or 0 for all time.
    func start(now: Date = Date(), calendar: Calendar = .current) -> Double {
        guard let d = days else { return 0 }
        let today = calendar.startOfDay(for: now)
        return (calendar.date(byAdding: .day, value: -(d - 1), to: today) ?? today).timeIntervalSince1970
    }
}
