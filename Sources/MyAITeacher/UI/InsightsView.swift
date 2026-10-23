import SwiftUI
import Charts
import AppKit

/// Everything the Insights screen shows, loaded off the main thread from rollups / indexed ranges.
struct InsightsData: Sendable {
    var models: [(provider: String, model: String)] = []
    var byModel: [TelemetryStore.LLMRow] = []
    var byDay: [(day: String, row: TelemetryStore.LLMRow)] = []
    var ttft: [TelemetryStore.Quantiles] = []
    var decode: [TelemetryStore.Quantiles] = []
    var stepTime: [TelemetryStore.Quantiles] = []
    var ttftAll: TelemetryStore.Quantiles?
    var decodeAll: TelemetryStore.Quantiles?
    var turnAll: TelemetryStore.Quantiles?
    var turns: (n: Int, sum: Double) = (0, 0)
    var turnErrors = 0
    var turnCancelled = 0
    var tools: [TelemetryStore.ToolRow] = []
    var approvals: [TelemetryStore.CountRow] = []
    var approvalWait: TelemetryStore.Quantiles?
    var errors: [TelemetryStore.CountRow] = []
    var recentErrors: [TelemetryEvent] = []
    var memoryByDay: [TelemetryStore.CountRow] = []
    var compactions = 0
    var lessons: [(conv: String, last: Double, steps: Int, maxContext: Double)] = []
    var contextAll: TelemetryStore.Quantiles?
    var reviews: [(day: String, rating: Int, n: Int)] = []
    var quizzes: [(day: String, attempts: Int, scorePct: Double)] = []
    var resources: [(ts: Double, footprintMB: Double, webMB: Double, cpuPct: Double)] = []
    var footprint: TelemetryStore.Quantiles?
    var webFootprint: TelemetryStore.Quantiles?
    var cpu: TelemetryStore.Quantiles?
    var frame: TelemetryStore.Quantiles?
    var reset: TelemetryStore.Quantiles?
    var launch: TelemetryStore.Quantiles?
    var lastLaunch: TelemetryEvent?
    var exposures: [TelemetryStore.CountRow] = []
    var outcomes: [TelemetryStore.CountRow] = []
    var rawEvents = 0

    static func load(_ s: TelemetryStore, _ f: TelemetryStore.Filter) -> InsightsData {
        let since = f.since
        let all = TelemetryStore.Filter(since: since)
        var d = InsightsData()
        d.models = s.models(since: since)
        d.byModel = s.llmByModel(f)
        d.byDay = s.llmByDay(f)
        d.ttft = s.quantiles(TelemetryMetric.ttft, f, perModel: true)
        d.decode = s.quantiles(TelemetryMetric.decode, f, perModel: true)
        d.stepTime = s.quantiles(TelemetryMetric.stepDuration, f, perModel: true)
        d.ttftAll = s.quantiles(TelemetryMetric.ttft, f, perModel: false).first
        d.decodeAll = s.quantiles(TelemetryMetric.decode, f, perModel: false).first
        d.turnAll = s.quantiles(TelemetryMetric.turnDuration, f, perModel: false).first
        d.contextAll = s.quantiles(TelemetryMetric.context, f, perModel: false).first
        d.turns = s.total("turn", since: since)
        d.turnErrors = s.total("turn.error", since: since).n
        d.turnCancelled = s.total("turn.cancelled", since: since).n
        d.tools = s.tools(since: since)
        d.approvals = s.counts("approval", since: since)
        d.approvalWait = s.quantiles(TelemetryMetric.approvalWait, all, perModel: false).first
        d.errors = s.counts("error", since: since).filter { r in
            guard let p = f.provider else { return true }
            return r.key.hasPrefix(p + "|")
        }
        d.recentErrors = s.recentEvents(.error, since: since, limit: 30).filter { e in
            (f.provider == nil || e.provider == f.provider) && (f.model == nil || e.model == f.model)
        }.prefix(8).map { $0 }
        d.memoryByDay = s.countsByDay("memory", since: since)
        d.compactions = s.total("compaction", since: since).n
        d.lessons = s.recentLessons(since: max(since, Date().timeIntervalSince1970 - Double(TelemetryStore.rawRetentionDays) * 86400))
        d.reviews = s.reviewsByDay(since: since)
        d.quizzes = s.quizzesByDay(since: since)
        let rawSince = max(since, Date().timeIntervalSince1970 - Double(TelemetryStore.rawRetentionDays) * 86400)
        d.resources = s.resourceSeries(since: rawSince)
        d.footprint = s.quantiles(TelemetryMetric.footprint, all, perModel: false).first
        d.webFootprint = s.quantiles(TelemetryMetric.webFootprint, all, perModel: false).first
        d.cpu = s.quantiles(TelemetryMetric.cpu, all, perModel: false).first
        d.frame = s.quantiles(TelemetryMetric.frame, all, perModel: false).first
        d.reset = s.quantiles(TelemetryMetric.reset, all, perModel: false).first
        d.launch = s.quantiles(TelemetryMetric.launch, all, perModel: false).first
        d.lastLaunch = s.recentEvents(.launch, since: 0, limit: 1).first
        d.exposures = s.counts("exp.exposure", since: since)
        d.outcomes = s.counts("exp.outcome", since: since)
        d.rawEvents = s.rawCount()
        return d
    }
}

struct InsightsView: View {
    @EnvironmentObject var app: AppModel
    @AppStorage(Telemetry.enabledKey) private var enabled = true
    @State private var range: TelemetryRange = .week
    @State private var filter = ""          // "" = all, "p" = provider, "p\u{1}m" = model
    @State private var data = InsightsData()
    @State private var loaded = false
    @State private var lesson: String?
    @State private var context: (steps: [(ts: Double, tokens: Double)], compactions: [Double]) = ([], [])
    @State private var confirmClear = false
    @State private var overhead = Telemetry.Overhead()

    private static let dayParser: DateFormatter = TelemetryCalendar().dayFormatter()
    private func date(_ day: String) -> Date { Self.dayParser.date(from: day) ?? .distantPast }

    private var storeFilter: TelemetryStore.Filter {
        let parts = filter.split(separator: "\u{1}", omittingEmptySubsequences: false).map(String.init)
        return TelemetryStore.Filter(since: range.start(), provider: parts.first.flatMap { $0.isEmpty ? nil : $0 },
                                     model: parts.count > 1 ? parts[1] : nil)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                if !enabled {
                    Label("Telemetry is off. Turn it on in Settings → General → Privacy to collect new data.", systemImage: "pause.circle")
                        .foregroundStyle(.secondary)
                }
                kpis
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                    card("Tokens by kind", "Per day. Reasoning is counted inside output by most providers.") { tokensChart }
                    card("Prompt cache hit rate", "Cached input ÷ all input tokens, per day.") { cacheChart }
                }
                card("Latency by model", "From log-bucketed histograms (±9 %). TTFT = time to first streamed token; decode = (output − 1) ÷ generation time.") { latency }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                    card("Errors by provider", "Failed model calls, by category. Retries are automatic for busy/5xx.") { errorsView }
                    card("Approvals", "Tool calls that needed your OK.") { approvalsView }
                }
                card("Tools", "Duration excludes time spent waiting for you.") { toolsView }
                card("Context size per lesson", "Prompt tokens per model call (last 30 days). Dashed lines mark compaction (summarising older turns).") { contextView }
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], alignment: .leading, spacing: 16) {
                    card("Learning outcomes", "Flashcard reviews by rating, and average quiz score.") { learningView }
                    card("Memory activity", "Long-term memory reads (recalled) and writes, per day.") { memoryView }
                }
                card("App performance", "Resource samples every minute; transcript render timings from the web view.") { performanceView }
                if !data.exposures.isEmpty || !data.outcomes.isEmpty {
                    card("Experiments", "A/B exposures and outcome means per variant.") { experimentsView }
                }
                privacy
            }
            .padding(28)
            .frame(maxWidth: 1100, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle("Insights")
        .task(id: "\(range.rawValue)|\(filter)") { await reload() }
        .onReceive(EventBus.subject.filter { if case .turnFinished = $0 { return true }; return false }
            .debounce(for: .seconds(2), scheduler: RunLoop.main)) { _ in Task { await reload() } }
        .confirmationDialog("Delete all telemetry?", isPresented: $confirmClear) {
            Button("Delete telemetry", role: .destructive) {
                Telemetry.shared.clear()
                Task { try? await Task.sleep(nanoseconds: 200_000_000); await reload() }
            }
        } message: { Text("Removes raw events and daily rollups from this Mac. Lessons, flashcards and quizzes are not affected.") }
    }

    // MARK: Loading

    private func reload() async {
        let f = storeFilter
        if let d = await Telemetry.shared.read({ InsightsData.load($0, f) }) {
            data = d
            if lesson == nil || !d.lessons.contains(where: { $0.conv == lesson }) { lesson = d.lessons.first?.conv }
            await loadContext()
        }
        overhead = Telemetry.shared.overhead
        loaded = true
    }

    private func loadContext() async {
        guard let id = lesson else { context = ([], []); return }
        if let c = await Telemetry.shared.read({ $0.contextSeries(conv: id) }) { context = c } else { context = ([], []) }
    }

    // MARK: Header & KPIs

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Insights").font(.largeTitle.bold())
            Spacer()
            Picker("Range", selection: $range) { ForEach(TelemetryRange.allCases) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented).frame(width: 360).labelsHidden()
            Picker("Model", selection: $filter) {
                Text("All models").tag("")
                let providers = Array(Set(data.models.map(\.provider))).sorted()
                ForEach(providers, id: \.self) { p in
                    Divider()
                    Text("All \(providerName(p))").tag(p)
                    ForEach(data.models.filter { $0.provider == p }.map(\.model), id: \.self) { m in Text("  \(m)").tag(p + "\u{1}" + m) }
                }
            }
            .frame(width: 230).labelsHidden()
            Button { Task { await reload() } } label: { Image(systemName: "arrow.clockwise") }.accessibilityLabel("Refresh insights").help("Refresh")
        }
    }

    private var kpis: some View {
        let tot = data.byModel.reduce(TelemetryStore.LLMRow(provider: "", model: "")) { a, r in
            var a = a; a.calls += r.calls; a.errors += r.errors; a.input += r.input; a.cacheRead += r.cacheRead
            a.cacheWrite += r.cacheWrite; a.output += r.output; a.retries += r.retries; return a
        }
        let toolCalls = data.tools.reduce(0) { $0 + $1.calls }, toolFails = data.tools.reduce(0) { $0 + $1.failures }
        return HStack(spacing: 10) {
            tile("Replies", "\(data.turns.n)", data.turnAll?.p50.map { "median " + Self.secs($0 / 1000) } ?? " ")
            tile("First token", data.ttftAll?.p50.map { Self.secs($0 / 1000) } ?? "—", data.ttftAll?.p95.map { "p95 " + Self.secs($0 / 1000) } ?? " ")
            tile("Decode speed", data.decodeAll?.p50.map { "\(Int($0)) tok/s" } ?? "—", data.decodeAll?.p95.map { "p95 \(Int($0)) tok/s" } ?? " ")
            tile("Cache hit", tot.cacheHitRate.map { Self.pct($0) } ?? "—", "\(Composer.short(tot.cacheRead)) cached")
            tile("Tokens", Composer.short(tot.promptTotal + tot.output), "\(Composer.short(tot.output)) out · \(tot.calls) calls")
            tile("Model errors", tot.errorRate.map { Self.pct($0) } ?? "—", "\(tot.errors) failed · \(tot.retries) retries")
            tile("Tool success", toolCalls > 0 ? Self.pct(1 - Double(toolFails) / Double(toolCalls)) : "—", "\(toolCalls) calls")
        }
    }

    // MARK: Charts

    private struct TokenPoint: Identifiable { let id = UUID(); let day: Date; let kind: String; let n: Int }

    @ViewBuilder private var tokensChart: some View {
        let pts = data.byDay.flatMap { d -> [TokenPoint] in
            let day = date(d.day), r = d.row
            return [TokenPoint(day: day, kind: "Input", n: r.input), TokenPoint(day: day, kind: "Cached", n: r.cacheRead),
                    TokenPoint(day: day, kind: "Cache write", n: r.cacheWrite),
                    TokenPoint(day: day, kind: "Output", n: max(0, r.output - r.reasoning)), TokenPoint(day: day, kind: "Reasoning", n: r.reasoning)]
        }.filter { $0.n > 0 }
        if pts.isEmpty { empty("No model calls in this range.") } else {
            Chart(pts) { p in
                BarMark(x: .value("Day", p.day, unit: .day), y: .value("Tokens", p.n))
                    .foregroundStyle(by: .value("Kind", p.kind))
            }
            .chartForegroundStyleScale(["Input": Color.blue, "Cached": Color.teal, "Cache write": Color.indigo, "Output": Color.orange, "Reasoning": Color.pink])
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Int.self) { Text(Composer.short(n)) } } } }
            .frame(height: 190)
        }
    }

    /// Short model name for chart axes (the table below has the full provider · model).
    private func shortModel(_ m: String) -> String {
        let last = m.split(separator: "/").last.map(String.init) ?? m
        return last.count > 26 ? String(last.prefix(25)) + "…" : last
    }

    @ViewBuilder private var cacheChart: some View {
        let pts = data.byDay.compactMap { d in d.row.cacheHitRate.map { (date(d.day), $0) } }
        if pts.isEmpty { empty("No prompt tokens yet.") } else {
            Chart(pts, id: \.0) { p in
                LineMark(x: .value("Day", p.0, unit: .day), y: .value("Hit rate", p.1 * 100)).interpolationMethod(.monotone)
                PointMark(x: .value("Day", p.0, unit: .day), y: .value("Hit rate", p.1 * 100)).symbolSize(24)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Double.self) { Text("\(Int(n))%") } } } }
            .frame(height: 190)
        }
    }

    @ViewBuilder private var latency: some View {
        if data.byModel.isEmpty { empty("No model calls in this range.") } else {
            let ttft = Dictionary(uniqueKeysWithValues: data.ttft.map { ($0.id, $0) })
            let dec = Dictionary(uniqueKeysWithValues: data.decode.map { ($0.id, $0) })
            let step = Dictionary(uniqueKeysWithValues: data.stepTime.map { ($0.id, $0) })
            VStack(alignment: .leading, spacing: 12) {
                Chart {
                    ForEach(data.ttft.prefix(8)) { q in
                        if let p50 = q.p50 { BarMark(x: .value("ms", p50 / 1000), y: .value("Model", shortModel(q.model))).foregroundStyle(by: .value("Stat", "TTFT p50")).position(by: .value("Stat", "p50")) }
                        if let p95 = q.p95 { BarMark(x: .value("ms", p95 / 1000), y: .value("Model", shortModel(q.model))).foregroundStyle(by: .value("Stat", "TTFT p95")).position(by: .value("Stat", "p95")) }
                    }
                }
                .chartForegroundStyleScale(["TTFT p50": Color.blue, "TTFT p95": Color.blue.opacity(0.45)])
                .chartXAxisLabel("seconds to first token")
                .chartYAxis { AxisMarks(position: .leading) { _ in AxisValueLabel().font(.caption) } }
                .frame(height: CGFloat(max(1, min(8, data.ttft.count))) * 56 + 44)
                Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 5) {
                    GridRow {
                        ForEach(["Model", "Calls", "TTFT p50", "TTFT p95", "Decode p50", "Decode p95", "Call p50", "Call p95", "Cache hit", "Errors"], id: \.self) { Text($0).bold() }
                    }.font(.caption).foregroundStyle(.secondary)
                    ForEach(data.byModel) { r in
                        GridRow {
                            Text(label(r.provider, r.model)).lineLimit(1).frame(maxWidth: 260, alignment: .leading)
                            Text("\(r.calls)").monospacedDigit()
                            Text(ttft[r.id]?.p50.map { Self.secs($0 / 1000) } ?? "—").monospacedDigit()
                            Text(ttft[r.id]?.p95.map { Self.secs($0 / 1000) } ?? "—").monospacedDigit()
                            Text(dec[r.id]?.p50.map { "\(Int($0))/s" } ?? "—").monospacedDigit()
                            Text(dec[r.id]?.p95.map { "\(Int($0))/s" } ?? "—").monospacedDigit()
                            Text(step[r.id]?.p50.map { Self.secs($0 / 1000) } ?? "—").monospacedDigit()
                            Text(step[r.id]?.p95.map { Self.secs($0 / 1000) } ?? "—").monospacedDigit()
                            Text(r.cacheHitRate.map { Self.pct($0) } ?? "—").monospacedDigit()
                            Text(r.errors > 0 ? "\(r.errors) (\(Self.pct(r.errorRate ?? 0)))" : "0").monospacedDigit()
                                .foregroundStyle(r.errors > 0 ? Color.red : Color.primary)
                        }
                    }
                }
                .font(.callout)
                if data.byModel.contains(where: { $0.estimated > 0 }) {
                    Text("Some providers sent no usage; their output tokens are estimated and excluded from decode speed.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    @ViewBuilder private var errorsView: some View {
        if data.errors.isEmpty { empty("No errors. 🎉") } else {
            let rows = data.errors.map { r -> (String, String, Int) in
                let p = r.key.split(separator: "|", maxSplits: 1).map(String.init)
                return (providerName(p.first ?? ""), p.count > 1 ? p[1] : "other", r.n)
            }
            Chart(Array(rows.enumerated()), id: \.offset) { _, r in
                BarMark(x: .value("Errors", r.2), y: .value("Category", r.1)).foregroundStyle(by: .value("Provider", r.0))
            }
            .frame(height: CGFloat(Set(rows.map(\.1)).count) * 30 + 40)
            ForEach(Array(data.recentErrors.enumerated()), id: \.offset) { _, e in
                HStack(alignment: .firstTextBaseline) {
                    Text(Date(timeIntervalSince1970: e.ts), format: .relative(presentation: .named)).frame(width: 90, alignment: .leading)
                    Text(e.model).lineLimit(1).frame(width: 130, alignment: .leading)
                    Text(e.label ?? e.name).lineLimit(1).truncationMode(.tail).foregroundStyle(.secondary)
                }.font(.caption)
            }
        }
    }

    @ViewBuilder private var approvalsView: some View {
        if data.approvals.isEmpty { empty("No approval prompts in this range.") } else {
            HStack(spacing: 18) {
                Chart(data.approvals, id: \.key) { r in
                    SectorMark(angle: .value("Count", r.n), innerRadius: .ratio(0.6), angularInset: 1.5)
                        .foregroundStyle(by: .value("Outcome", r.key.capitalized))
                }
                .chartForegroundStyleScale(["Allowed": Color.green, "Denied": Color.orange, "Blocked": Color.red])
                .frame(width: 150, height: 150)
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(data.approvals, id: \.key) { r in Text("\(r.key.capitalized): \(r.n)").monospacedDigit() }
                    if let w = data.approvalWait, let p50 = w.p50 {
                        Text("You took \(Self.secs(p50 / 1000)) to decide (median)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    @ViewBuilder private var toolsView: some View {
        if data.tools.isEmpty { empty("No tool calls in this range.") } else {
            HStack(alignment: .top, spacing: 18) {
                Chart(data.tools.prefix(12)) { t in
                    BarMark(x: .value("Calls", t.calls - t.failures), y: .value("Tool", t.tool)).foregroundStyle(by: .value("Result", "OK"))
                    BarMark(x: .value("Calls", t.failures), y: .value("Tool", t.tool)).foregroundStyle(by: .value("Result", "Failed"))
                }
                .chartForegroundStyleScale(["OK": Color.green.opacity(0.75), "Failed": Color.red])
                .frame(height: CGFloat(min(12, data.tools.count)) * 24 + 40)
                .frame(maxWidth: 360)
                Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 4) {
                    GridRow { ForEach(["Tool", "Calls", "Fail", "Mean", "p50", "p95", "Waited"], id: \.self) { Text($0).bold() } }
                        .font(.caption).foregroundStyle(.secondary)
                    ForEach(data.tools.prefix(14)) { t in
                        GridRow {
                            Text(t.tool).lineLimit(1)
                            Text("\(t.calls)").monospacedDigit()
                            Text(t.failures > 0 ? Self.pct(t.failureRate) : "0").monospacedDigit().foregroundStyle(t.failures > 0 ? Color.red : Color.primary)
                            Text(Self.secs(t.meanSeconds)).monospacedDigit()
                            Text(t.p50.map { Self.secs($0 / 1000) } ?? "—").monospacedDigit()
                            Text(t.p95.map { Self.secs($0 / 1000) } ?? "—").monospacedDigit()
                            Text(t.waited > 0.5 ? Self.secs(t.waited) : "—").monospacedDigit()
                        }
                    }
                }.font(.callout)
            }
        }
    }

    @ViewBuilder private var contextView: some View {
        if data.lessons.isEmpty { empty("No lessons with model calls in the last 30 days.") } else {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Picker("Lesson", selection: Binding(get: { lesson ?? "" }, set: { lesson = $0; Task { await loadContext() } })) {
                        ForEach(data.lessons, id: \.conv) { l in Text("\(lessonTitle(l.conv)) · \(l.steps) calls").tag(l.conv) }
                    }.frame(maxWidth: 420)
                    Spacer()
                    Text("\(data.compactions) compaction\(data.compactions == 1 ? "" : "s") in range").font(.caption).foregroundStyle(.secondary)
                    if let p = data.contextAll?.p95 { Text("· p95 context \(Composer.short(Int(p)))").font(.caption).foregroundStyle(.secondary) }
                }
                if context.steps.isEmpty { empty("No context data for this lesson.") } else {
                    Chart {
                        ForEach(Array(context.steps.enumerated()), id: \.offset) { i, s in
                            LineMark(x: .value("Call", i + 1), y: .value("Tokens", s.tokens)).interpolationMethod(.stepEnd)
                            AreaMark(x: .value("Call", i + 1), y: .value("Tokens", s.tokens)).interpolationMethod(.stepEnd).foregroundStyle(.blue.opacity(0.12))
                        }
                        ForEach(compactionIndices, id: \.self) { i in
                            RuleMark(x: .value("Call", i)).lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 3])).foregroundStyle(.orange)
                                .annotation(position: .top, alignment: .leading) { Text("compacted").font(.caption2).foregroundStyle(.orange) }
                        }
                    }
                    .chartXAxisLabel("model call #")
                    .chartYAxis { AxisMarks { v in AxisGridLine(); AxisValueLabel { if let n = v.as(Double.self) { Text(Composer.short(Int(n))) } } } }
                    .frame(height: 190)
                }
            }
        }
    }

    /// Model-call index (1-based x) just after each compaction.
    private var compactionIndices: [Int] {
        context.compactions.map { c in (context.steps.firstIndex { $0.ts >= c } ?? context.steps.count) + 1 }
    }

    private struct RatingPoint: Identifiable { let id = UUID(); let day: Date; let rating: String; let n: Int }

    @ViewBuilder private var learningView: some View {
        if data.reviews.isEmpty && data.quizzes.isEmpty { empty("Review flashcards or take a quiz to see outcomes here.") } else {
            let names = [1: "Again", 2: "Hard", 3: "Good", 4: "Easy"]
            let total = data.reviews.reduce(0) { $0 + $1.n }, recalled = data.reviews.filter { $0.rating > 1 }.reduce(0) { $0 + $1.n }
            VStack(alignment: .leading, spacing: 8) {
                if !data.reviews.isEmpty {
                    Text("\(total) reviews · \(Self.pct(total > 0 ? Double(recalled) / Double(total) : 0)) recalled").font(.callout)
                    Chart(data.reviews.map { RatingPoint(day: date($0.day), rating: names[$0.rating] ?? "?", n: $0.n) }) { p in
                        BarMark(x: .value("Day", p.day, unit: .day), y: .value("Reviews", p.n)).foregroundStyle(by: .value("Rating", p.rating))
                    }
                    .chartForegroundStyleScale(["Again": Color.red, "Hard": Color.orange, "Good": Color.green, "Easy": Color.teal])
                    .frame(height: 130)
                }
                if !data.quizzes.isEmpty {
                    let attempts = data.quizzes.reduce(0) { $0 + $1.attempts }
                    Text("\(attempts) quiz\(attempts == 1 ? "" : "zes") · avg \(Int(data.quizzes.map(\.scorePct).reduce(0, +) / Double(data.quizzes.count)))%").font(.callout)
                    Chart(data.quizzes, id: \.day) { q in
                        LineMark(x: .value("Day", date(q.day), unit: .day), y: .value("Score", q.scorePct))
                        PointMark(x: .value("Day", date(q.day), unit: .day), y: .value("Score", q.scorePct))
                    }
                    .chartYScale(domain: 0...100)
                    .frame(height: 100)
                }
            }
        }
    }

    @ViewBuilder private var memoryView: some View {
        if data.memoryByDay.isEmpty { empty("No memory activity in this range.") } else {
            Chart(Array(data.memoryByDay.enumerated()), id: \.offset) { _, r in
                BarMark(x: .value("Day", date(r.day), unit: .day), y: .value("Events", r.n)).foregroundStyle(by: .value("Kind", r.key))
            }
            .frame(height: 190)
        }
    }

    @ViewBuilder private var performanceView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                tile("Launch → transcript", data.lastLaunch.map { Self.secs($0.value) } ?? "—", data.launch?.p50.map { "median " + Self.secs($0 / 1000) } ?? " ")
                tile("App memory", data.footprint?.p50.map { "\(Int($0)) MB" } ?? "—", data.footprint?.p95.map { "p95 \(Int($0)) MB" } ?? " ")
                tile("Web view memory", data.webFootprint?.p50.map { "\(Int($0)) MB" } ?? "—", data.webFootprint?.p95.map { "p95 \(Int($0)) MB" } ?? " ")
                tile("CPU (idle+busy)", data.cpu?.p50.map { String(format: "%.1f%%", $0) } ?? "—", data.cpu?.p95.map { String(format: "p95 %.1f%%", $0) } ?? " ")
                tile("Render frame", data.frame?.p50.map { String(format: "%.1f ms", $0) } ?? "—", data.frame?.p95.map { String(format: "p95 %.1f ms", $0) } ?? " ")
                tile("Transcript load", data.reset?.p50.map { String(format: "%.0f ms", $0) } ?? "—", data.reset?.p95.map { String(format: "p95 %.0f ms", $0) } ?? " ")
            }
            if data.resources.count > 1 {
                Chart {
                    ForEach(Array(data.resources.enumerated()), id: \.offset) { _, r in
                        LineMark(x: .value("Time", Date(timeIntervalSince1970: r.ts)), y: .value("MB", r.footprintMB)).foregroundStyle(by: .value("Process", "App"))
                        if r.webMB > 0 {
                            LineMark(x: .value("Time", Date(timeIntervalSince1970: r.ts)), y: .value("MB", r.webMB)).foregroundStyle(by: .value("Process", "Web view"))
                        }
                    }
                }
                .chartYAxisLabel("memory footprint (MB, hourly max)")
                .frame(height: 160)
            }
            Text(overheadText).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var overheadText: String {
        let o = overhead
        return String(format: "Telemetry cost this session: %d events · %.2f µs/event on the main thread (enqueue %.2f + mapping %.2f) · %.1f µs/event background write · %d flushes (last %.1f ms) · %d raw rows stored",
                      o.events, o.recordMicrosPerEvent + o.mapMicrosPerEvent, o.recordMicrosPerEvent, o.mapMicrosPerEvent,
                      o.flushMicrosPerEvent, o.flushes, o.lastFlushMillis, data.rawEvents)
    }

    @ViewBuilder private var experimentsView: some View {
        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 4) {
            GridRow { ForEach(["Experiment", "Variant", "Exposures", "Outcome", "Mean"], id: \.self) { Text($0).bold() } }.font(.caption).foregroundStyle(.secondary)
            ForEach(data.exposures, id: \.key) { r in
                let p = r.key.split(separator: "|", omittingEmptySubsequences: false).map(String.init)
                let outs = data.outcomes.filter { $0.key.hasPrefix(r.key + "|") }
                GridRow {
                    Text(p.first ?? ""); Text(p.count > 1 ? p[1] : ""); Text("\(r.n)").monospacedDigit()
                    Text(outs.map { String($0.key.split(separator: "|", omittingEmptySubsequences: false).last ?? "") }.joined(separator: ", "))
                    Text(outs.map { String(format: "%.3g (n=%d)", $0.n > 0 ? $0.sum / Double($0.n) : 0, $0.n) }.joined(separator: ", ")).monospacedDigit()
                }
            }
        }
    }

    private var privacy: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Private by design", systemImage: "lock.shield").font(.headline)
            Text("Telemetry stays on this Mac in teacher.sqlite and is never sent anywhere. It records timings, token counts, model and tool names, error categories and resource usage — never your messages, prompts, files or keys. Raw events are kept for \(TelemetryStore.rawRetentionDays) days; daily summaries are kept until you clear them.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button { export() } label: { Label("Export JSON…", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) { confirmClear = true } label: { Label("Clear telemetry…", systemImage: "trash") }
                Spacer()
                Toggle("Collect telemetry", isOn: $enabled).toggleStyle(.switch)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.07)))
    }

    private func export() {
        let since = range.start()
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "teacher-telemetry-\(TelemetryCalendar().day(Date().timeIntervalSince1970)).json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            if let data = await Telemetry.shared.read({ $0.exportJSON(since: since) }) { try? data.write(to: url) }
        }
    }

    // MARK: Pieces

    private func card<C: View>(_ title: String, _ subtitle: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            Text(subtitle).font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            content()
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.secondary.opacity(0.15)))
    }

    private func tile(_ title: String, _ value: String, _ sub: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            Text(value).font(.title3.bold()).monospacedDigit().lineLimit(1).minimumScaleFactor(0.7)
            Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1).minimumScaleFactor(0.8)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.08)))
    }

    private func empty(_ text: String) -> some View {
        Text(loaded ? text : "Loading…").foregroundStyle(.secondary).frame(maxWidth: .infinity, minHeight: 60, alignment: .center)
    }

    private func providerName(_ id: String) -> String { app.settings.provider(id)?.name ?? id }
    private func label(_ provider: String, _ model: String) -> String { storeFilter.provider == nil ? "\(providerName(provider)) · \(model)" : model }
    private func lessonTitle(_ id: String) -> String {
        app.conversations.first { $0.id == id }?.title ?? "Lesson \(id.prefix(6)) (other folder)"
    }

    static func secs(_ s: Double) -> String {
        s < 1 ? "\(Int((s * 1000).rounded())) ms" : s < 60 ? String(format: "%.1f s", s) : "\(Int(s) / 60)m \(Int(s) % 60)s"
    }
    static func pct(_ v: Double) -> String { v >= 0.995 || v == 0 ? "\(Int((v * 100).rounded()))%" : String(format: "%.1f%%", v * 100) }
}
