import SwiftUI
import WebKit

// MARK: - Card face renderer (reuses the transcript renderer in "card" mode)

struct CardFaceView: NSViewRepresentable {
    let front: String
    let back: String
    let showBack: Bool
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), name: "bridge")
        let web = ClickThroughWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        let dir = AppPaths.webResources
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.show(front: front, back: back, showBack: showBack, fontSize: fontSize)
    }

    final class Coordinator: NSObject, WKScriptMessageHandler {
        weak var web: WKWebView?
        var ready = false
        var pending: String?
        func show(front: String, back: String, showBack: Bool, fontSize: Double) {
            let js = "T.setFontSize(\(fontSize));T.card(\(JSON.string(front).compact),\(JSON.string(back).compact),\(showBack))"
            if ready { web?.evaluateJavaScript(js) } else { pending = js }
        }
        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            guard let body = m.body as? [String: Any], let type = body["type"] as? String else { return }
            if type == "ready" { ready = true; if let p = pending { web?.evaluateJavaScript(p); pending = nil } }
            if type == "open", let s = body["url"] as? String, let u = URL(string: s) { AppModel.shared.openLink(u) }
        }
    }
}

// MARK: - Flashcards

struct FlashcardsView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @State private var deck: String? = nil
    @State private var queue: [Flashcard] = []
    @State private var revealed = false
    @State private var reviewing = false
    @State private var reviewedCount = 0
    @State private var decks: [(name: String, total: Int, due: Int)] = []
    @State private var browse: [Flashcard] = []

    var body: some View {
        Group {
            if reviewing { reviewView } else { overview }
        }
        .navigationTitle("Flashcards")
        .onAppear(perform: reload)
        .onReceive(EventBus.subject.filter { if case .studyDataChanged = $0 { return true }; if case .turnFinished = $0 { return true }; return false }) { _ in if !reviewing { reload() } }
    }

    private func reload() {
        decks = app.services.study.decks()
        browse = app.services.study.allCards(deck: deck)
    }

    private var overview: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Spaced repetition").font(.largeTitle.bold())
                        Text("Cards are scheduled with FSRS so you review right before you'd forget.").foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        startReview()
                    } label: {
                        Label(dueTotal > 0 ? "Review \(dueTotal) due" : "Nothing due", systemImage: "play.fill").padding(.horizontal, 6)
                    }
                    .buttonStyle(.borderedProminent).controlSize(.large).disabled(dueTotal == 0)
                }
                if decks.isEmpty {
                    ContentUnavailableView("No flashcards yet", systemImage: "rectangle.on.rectangle.angled",
                                           description: Text("Ask your teacher to “make flashcards” from any lesson."))
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12)], spacing: 12) {
                        deckTile(name: nil, total: decks.reduce(0) { $0 + $1.total }, due: dueTotal)
                        ForEach(decks, id: \.name) { d in deckTile(name: d.name, total: d.total, due: d.due) }
                    }
                    Text(deck ?? "All cards").font(.title3.bold()).padding(.top, 6)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(browse) { c in
                            HStack(alignment: .top) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.front).font(.callout.weight(.medium)).lineLimit(2)
                                    Text(c.back).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 3) {
                                    Text(c.due <= Date() ? "Due" : c.due.formatted(.relative(presentation: .named)))
                                        .font(.caption).foregroundStyle(c.due <= Date() ? .orange : .secondary)
                                    Text("\(c.reps) reviews").font(.caption2).foregroundStyle(.tertiary)
                                }
                                Button { app.services.study.deleteCard(c.id); reload(); app.refreshCounts() } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).foregroundStyle(.secondary).accessibilityLabel("Delete card").help("Delete card")
                            }
                            .padding(.vertical, 8)
                            Divider()
                        }
                    }
                }
            }
            .padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
        }
    }

    private var dueTotal: Int { deck.map { d in decks.first { $0.name == d }?.due ?? 0 } ?? decks.reduce(0) { $0 + $1.due } }

    private func deckTile(name: String?, total: Int, due: Int) -> some View {
        Button {
            deck = name; reload()
        } label: {
            VStack(alignment: .leading, spacing: 6) {
                Text(name ?? "All decks").font(.headline).lineLimit(1)
                HStack {
                    Text("\(total) cards").foregroundStyle(.secondary)
                    Spacer()
                    if due > 0 { Text("\(due) due").foregroundStyle(.orange).bold() }
                }.font(.callout)
            }
            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 12).fill(deck == name ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.04)))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(deck == name ? Color.accentColor : Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
    }

    private func startReview() {
        queue = app.services.study.dueCards(deck: deck)
        revealed = false; reviewedCount = 0
        reviewing = !queue.isEmpty
    }

    private var reviewView: some View {
        VStack(spacing: 18) {
            HStack {
                Button { reviewing = false; reload(); app.refreshCounts() } label: { Label("Done", systemImage: "chevron.left") }
                Spacer()
                Text("\(reviewedCount) reviewed · \(queue.count) left").foregroundStyle(.secondary)
            }
            if let card = queue.first {
                VStack(spacing: 0) {
                    Text(card.deck).font(.caption).foregroundStyle(.secondary).padding(.top, 12)
                    CardFaceView(front: card.front, back: card.back, showBack: revealed, fontSize: settings.value.fontSize + 3)
                        .frame(minHeight: 260)
                }
                .background(RoundedRectangle(cornerRadius: 18).fill(Color(nsColor: .textBackgroundColor)).shadow(color: .black.opacity(0.08), radius: 12, y: 4))
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.primary.opacity(0.08)))
                .frame(maxWidth: 720)
                if revealed {
                    let prev = app.services.study.preview(card)
                    HStack(spacing: 10) {
                        ForEach(FSRS.Rating.allCases, id: \.rawValue) { r in
                            Button { rate(card, r) } label: {
                                VStack(spacing: 2) {
                                    Text(r.title).bold()
                                    Text(Self.interval(prev[r] ?? 0)).font(.caption).foregroundStyle(.secondary)
                                }.frame(width: 96).padding(.vertical, 4)
                            }
                            .keyboardShortcut(KeyEquivalent(Character(String(r.rawValue))), modifiers: [])
                            .tint(r == .again ? .red : (r == .hard ? .orange : (r == .good ? .green : .blue)))
                            .buttonStyle(.bordered).controlSize(.large)
                        }
                    }
                    Text("Keys 1–4 to rate").font(.caption2).foregroundStyle(.tertiary)
                } else {
                    Button { revealed = true } label: { Text("Show answer").frame(width: 200) }
                        .buttonStyle(.borderedProminent).controlSize(.large).keyboardShortcut(.space, modifiers: [])
                    Text("Space to reveal · try to recall first").font(.caption2).foregroundStyle(.tertiary)
                }
            } else {
                ContentUnavailableView("All done! 🎉", systemImage: "checkmark.seal", description: Text("You reviewed \(reviewedCount) cards. See you next time."))
                Button("Back to decks") { reviewing = false; reload(); app.refreshCounts() }
            }
            Spacer()
        }
        .padding(28)
    }

    private func rate(_ c: Flashcard, _ r: FSRS.Rating) {
        let updated = app.services.study.review(c, rating: r)
        queue.removeFirst()
        // Cards forgotten come back in this session.
        if r == .again { queue.append(updated) }
        reviewedCount += 1
        revealed = false
    }

    static func interval(_ days: Double) -> String {
        if days < 1.0 / 24 { return "\(max(1, Int(days * 1440))) min" }
        if days < 1 { return "\(Int(days * 24)) h" }
        if days < 30 { return "\(Int(days.rounded())) d" }
        if days < 365 { return String(format: "%.1f mo", days / 30) }
        return String(format: "%.1f y", days / 365)
    }
}

// MARK: - Progress

struct StudyProgressView: View {
    @EnvironmentObject var app: AppModel
    @State private var mastery: [MasteryItem] = []
    @State private var plans: [LessonPlan] = []
    @State private var quizzes: [(title: String, topic: String?, score: Double, total: Int, date: Date)] = []
    @State private var activity: [String: (seconds: Double, messages: Int, reviews: Int)] = [:]
    @State private var streak = 0
    @State private var usage: [(provider: String, model: String, requests: Int, input: Int, output: Int, cacheRead: Int)] = []
    @State private var calibration: [Certainty: (answers: Int, right: Int)] = [:]
    @State private var help = (hints: 0, solutions: 0)
    @State private var followUps: [FollowUp] = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                Text("Your progress").font(.largeTitle.bold())
                HStack(spacing: 12) {
                    stat("🔥", "\(streak)", "day streak")
                    stat("⏱", Self.hours(activity.values.reduce(0) { $0 + $1.seconds }), "studied (12 wks)")
                    stat("✅", "\(mastery.filter(\.mastered).count)", "concepts mastered")
                    stat("🗂", "\(app.dueCount)", "cards due")
                    stat("🧠", "\(app.memoryCount)", "memories")
                }
                section("Activity") { heatmap }
                section("Concept mastery") {
                    if mastery.isEmpty { Text("Mastery appears as you answer quizzes and practice questions.").foregroundStyle(.secondary) }
                    ForEach(Dictionary(grouping: mastery, by: \.subject).sorted(by: { $0.key < $1.key }), id: \.key) { subject, items in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(subject.capitalized).font(.headline)
                            ForEach(items) { m in
                                HStack {
                                    Text(m.concept).frame(width: 260, alignment: .leading).lineLimit(1)
                                    ProgressView(value: m.pKnown).tint(m.mastered ? .green : (m.pKnown > 0.6 ? .blue : .orange))
                                    Text("\(Int(m.pKnown * 100))%").monospacedDigit().frame(width: 44, alignment: .trailing)
                                    Text("\(m.correct)/\(m.attempts)").font(.caption).foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                                }
                            }
                        }.padding(.bottom, 8)
                    }
                }
                section("Confidence check") {
                    if calibration.isEmpty {
                        Text("Mark how sure you are on quiz questions: this shows how often you're right at each level.").foregroundStyle(.secondary)
                    } else {
                        ForEach(Certainty.allCases, id: \.rawValue) { c in
                            if let v = calibration[c], v.answers > 0 {
                                let rate = Double(v.right) / Double(v.answers)
                                HStack {
                                    Text(c.title).frame(width: 90, alignment: .leading)
                                    ProgressView(value: rate).tint(rate >= 0.8 ? .green : (rate >= 0.5 ? .blue : .orange))
                                    Text("\(Int((rate * 100).rounded()))% right").monospacedDigit().frame(width: 80, alignment: .trailing)
                                    Text("\(v.answers) answer\(v.answers == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary).frame(width: 80, alignment: .trailing)
                                }
                            }
                        }
                        Text(Self.calibrationReading(calibration)).font(.callout).foregroundStyle(.secondary)
                    }
                    if help.hints + help.solutions > 0 {
                        Text("Last 30 days: \(help.hints) hint\(help.hints == 1 ? "" : "s") opened, \(help.solutions) solution\(help.solutions == 1 ? "" : "s") seen before trying. Answers after help are logged but don't raise mastery.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
                if !followUps.isEmpty {
                    section("Coming back to") {
                        ForEach(followUps) { f in
                            HStack(alignment: .firstTextBaseline) {
                                Image(systemName: f.kind == .transfer ? "arrow.triangle.branch" : (f.kind == .missed ? "rectangle.on.rectangle.angled" : "arrow.clockwise"))
                                    .foregroundStyle(.secondary).frame(width: 18)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(Self.plainMath(f.concept)).lineLimit(1)
                                    if let n = f.note { Text(Self.plainMath(n)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                                }
                                Spacer()
                                Text(f.due <= Date() ? "Next lesson" : f.due.formatted(.relative(presentation: .named)))
                                    .font(.caption).foregroundStyle(f.due <= Date() ? .orange : .secondary)
                            }
                        }
                    }
                }
                section("Course boards") {
                    if plans.isEmpty { Text("Ask your teacher to “make a course board” for a bigger goal, like an exam or a project.").foregroundStyle(.secondary) }
                    ForEach(plans) { p in planCard(p) }
                }
                section("Model usage (30 days)") {
                    if usage.isEmpty { Text("No usage yet.").foregroundStyle(.secondary) }
                    else {
                        Grid(alignment: .leading, horizontalSpacing: 18, verticalSpacing: 5) {
                            GridRow { Text("Model").bold(); Text("Requests").bold(); Text("Input").bold(); Text("Cached").bold(); Text("Output").bold() }
                                .font(.caption).foregroundStyle(.secondary)
                            ForEach(Array(usage.enumerated()), id: \.offset) { _, u in
                                GridRow {
                                    Text("\(app.settings.provider(u.provider)?.name ?? u.provider) · \(u.model)").lineLimit(1)
                                    Text("\(u.requests)").monospacedDigit()
                                    Text(Composer.short(u.input)).monospacedDigit()
                                    Text(Composer.short(u.cacheRead)).monospacedDigit()
                                    Text(Composer.short(u.output)).monospacedDigit()
                                }
                            }
                        }
                    }
                }
                section("Recent quizzes") {
                    if quizzes.isEmpty { Text("No quizzes yet.").foregroundStyle(.secondary) }
                    ForEach(Array(quizzes.enumerated()), id: \.offset) { _, q in
                        HStack {
                            Text(q.title).lineLimit(1)
                            if let t = q.topic { Text(t).font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Text(q.total > 0 ? "\(String(format: "%g", q.score))/\(q.total)" : "teacher-graded").bold()
                                .foregroundStyle(q.total > 0 && q.score / Double(q.total) >= 0.8 ? .green : q.total > 0 ? .primary : .secondary)
                            Text(q.date, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.secondary).frame(width: 110, alignment: .trailing)
                        }
                        Divider()
                    }
                }
            }
            .padding(28).frame(maxWidth: 960, alignment: .leading).frame(maxWidth: .infinity)
        }
        .navigationTitle("Progress")
        .onAppear(perform: reload)
        .onReceive(EventBus.subject.filter { if case .studyDataChanged = $0 { return true }; if case .turnFinished = $0 { return true }; return false }) { _ in reload() }
    }

    private func reload() {
        let s = app.services.study
        mastery = s.allMastery(); plans = s.plans(); quizzes = s.recentQuizzes(); activity = s.activity(); streak = s.streakDays()
        usage = app.services.usageSummary(days: 30)
        calibration = s.calibration(); help = s.helpUsed(); followUps = s.openFollowUps(limit: 8)
    }

    /// Inline LaTeX as plain text for a label (notes quote the teacher's math): "$\frac{1+3}{6+4}$" → "(1+3)/(6+4)".
    static func plainMath(_ s: String) -> String {
        guard s.contains("$") || s.contains("\\") else { return s }
        var t = s
        for _ in 0..<4 { t = t.replacingOccurrences(of: #"\\[dt]?frac\{([^{}]*)\}\{([^{}]*)\}"#, with: "($1)/($2)", options: .regularExpression) }
        t = t.replacingOccurrences(of: #"\(([\w.]+)\)/\(([\w.]+)\)"#, with: "$1/$2", options: .regularExpression)
        for (a, b) in [("\\left", ""), ("\\right", ""), ("\\neq", "≠"), ("\\cdot", "·"), ("\\times", "×"), ("\\div", "÷"), ("\\sqrt", "√"),
                       ("\\pi", "π"), ("\\leq", "≤"), ("\\geq", "≥"), ("\\le", "≤"), ("\\ge", "≥"), ("\\to", "→")] {
            t = t.replacingOccurrences(of: a, with: b)
        }
        return t.replacingOccurrences(of: #"\\([a-zA-Z]+)"#, with: "$1", options: .regularExpression)
            .replacingOccurrences(of: "[${}]", with: "", options: .regularExpression)
    }

    /// One sentence on how well certainty matches being right (needs a handful of answers at a level before saying much).
    static func calibrationReading(_ c: [Certainty: (answers: Int, right: Int)]) -> String {
        let rate = { (k: Certainty) -> Double? in c[k].flatMap { $0.answers >= 5 ? Double($0.right) / Double($0.answers) : nil } }
        if let s = rate(.sure), s < 0.75 { return "When you're sure, you're right \(Int((s * 100).rounded()))% of the time: double-check answers that feel obvious." }
        if let g = rate(.guess), g >= 0.7 { return "Your guesses are usually right: you know more than you think." }
        if let s = rate(.sure), s >= 0.9 { return "When you're sure, you're almost always right." }
        return "The picture gets clearer after a few more quizzes."
    }

    private func stat(_ icon: String, _ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(icon).font(.title2)
            Text(value).font(.title.bold()).monospacedDigit()
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.title3.bold())
            content()
        }
    }

    private var heatmap: some View {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let weeks = 12
        let start = cal.date(byAdding: .day, value: -(weeks * 7 - 1) - (cal.component(.weekday, from: today) - 1), to: today)!
        return HStack(alignment: .top, spacing: 3) {
            ForEach(0..<(weeks + 1), id: \.self) { w in
                VStack(spacing: 3) {
                    ForEach(0..<7, id: \.self) { d in
                        let day = cal.date(byAdding: .day, value: w * 7 + d, to: start)!
                        let a = activity[StudyStore.dayFormatter.string(from: day)]
                        let level = min(4, ((a?.messages ?? 0) + (a?.reviews ?? 0) + 4) / 5)
                        RoundedRectangle(cornerRadius: 2.5)
                            .fill(day > today ? Color.clear : (level == 0 ? Color.primary.opacity(0.06) : Color.green.opacity(0.25 + Double(level) * 0.18)))
                            .frame(width: 13, height: 13)
                            .help("\(day.formatted(date: .abbreviated, time: .omitted)): \(a?.messages ?? 0) messages, \(a?.reviews ?? 0) reviews")
                    }
                }
            }
        }
    }

    private func planCard(_ p: LessonPlan) -> some View {
        let b = CourseBoard(plan: p)
        let parked = b.lane(.parked)
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(p.title).font(.headline)
                Spacer()
                Text("\(b.doneCount)/\(b.courseCount)").foregroundStyle(.secondary)
                Button { app.services.study.deletePlan(p.id); reload() } label: { Image(systemName: "trash") }.buttonStyle(.borderless).accessibilityLabel("Delete plan").help("Delete plan")
            }
            if let g = p.goal { Text(g).font(.callout).foregroundStyle(.secondary) }
            ProgressView(value: b.courseCount == 0 ? 0 : Double(b.doneCount) / Double(b.courseCount))
            if let f = b.focus {
                Text("Focus: \(f.title)").font(.callout.weight(.semibold))
                if let n = f.next { Text("Next: \(n)").font(.callout).foregroundStyle(.secondary) }
            }
            ForEach(b.cards.filter { $0.lane != .parked }) { c in
                HStack(spacing: 6) {
                    Image(systemName: c.lane == .done ? "checkmark.circle.fill" : (c.lane == .doing ? "play.circle.fill" : c.lane == .review ? "arrow.triangle.2.circlepath.circle" : "circle"))
                        .foregroundStyle(c.lane == .done ? .green : (c.lane == .doing ? .blue : c.lane == .review ? .orange : .secondary))
                    Text("\(c.id.uppercased()) \(c.title)").font(.callout)
                }
            }
            HStack(spacing: 10) {
                if !parked.isEmpty { Text("\(parked.count) parked").font(.caption).foregroundStyle(.secondary) }
                if let d = b.daysLeft() { Text(d < 0 ? "deadline passed" : "\(d) day\(d == 1 ? "" : "s") left").font(.caption).foregroundStyle(.secondary) }
            }
            Button("Continue this course") { resume(b) }.buttonStyle(.link)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    /// A new lesson on this board: linked before the first message, so the mentor's first request carries the state card.
    private func resume(_ b: CourseBoard) {
        let id = app.newLesson()
        app.services.study.link(board: b.id, lesson: id)
        app.session(for: id)?.send("Let's continue my course \"\(b.title)\". Pick up from the board: " +
                                   (b.focus.map { f in "the focus is \(f.title)" + (f.next.map { ", next: \($0)" } ?? "") } ?? "start the next card") + ".")
    }

    static func hours(_ s: Double) -> String { s < 3600 ? "\(Int(s / 60))m" : String(format: "%.1fh", s / 3600) }
}
