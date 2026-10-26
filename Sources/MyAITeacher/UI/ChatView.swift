import SwiftUI
import UniformTypeIdentifiers
import PDFKit

struct Attachment: Identifiable {
    let id = UUID()
    let name: String
    let block: Block
    let thumbnail: NSImage?
}

struct ChatView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var session: ChatSession
    @State private var dropTargeted = false

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(session: session, fontSize: settings.value.fontSize)
            Composer(session: session)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .navigationTitle(session.conversation.title)
        .navigationSubtitle(session.conversation.mode.title)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ModePicker(session: session)
                ModelPickerButton(session: session)
                ThinkingPicker(session: session)
                QuizToggle(session: session)
                LessonInfoButton(session: session)
            }
        }
        .inspector(isPresented: $app.inspectorShown) {
            InspectorPanel(session: session)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 1100)   // wide enough to write code in
                .toolbar {
                    Spacer()
                    Button { app.inspectorShown.toggle() } label: { Label("Files", systemImage: "sidebar.right") }.help("Files and pages")
                }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: $dropTargeted) { providers in
            Composer.handleDrop(providers, session: session)
            return true
        }
        .overlay {
            if dropTargeted {
                RoundedRectangle(cornerRadius: 14).strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [6]))
                    .background(Color.accentColor.opacity(0.06)).padding(8)
                    .overlay(Text("Drop images, PDFs or files to attach").font(.headline).foregroundStyle(Color.accentColor))
                    .allowsHitTesting(false)
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .stopGenerating)) { _ in session.stop() }
        .onReceive(NotificationCenter.default.publisher(for: .togglePlanMode)) { _ in session.setPlanMode(session.conversation.planMode != true) }
    }
}

struct ModePicker: View {
    @ObservedObject var session: ChatSession
    var body: some View {
        Menu {
            ForEach(TeachingMode.allCases) { m in
                Button { session.setMode(m) } label: { Label(m.title, systemImage: m.symbol) }
            }
        } label: {
            Label(session.conversation.mode.title, systemImage: session.conversation.mode.symbol)
                .labelStyle(.titleAndIcon)
        }
        .help("Teaching mode")
        .fixedSize()
    }
}

/// Quizzes on or off. Sticky (off stays off until turned back on) and effective from the learner's next message; Quiz and
/// Exam prep modes always test.
struct QuizToggle: View {
    @EnvironmentObject var settings: SettingsStore
    @ObservedObject var session: ChatSession
    var body: some View {
        let mode = session.conversation.mode
        if !mode.isAgent {
            let forced = mode == .quiz || mode == .exam
            let on = forced || settings.value.quizzes
            Button { settings.value.quizzes.toggle() } label: {
                // Tinted when on: the two checklist glyphs alone were hard to tell apart (the state was only in the tooltip).
                Label("Quizzes: \(on ? "On" : "Off")", systemImage: on ? "checklist.checked" : "checklist.unchecked")
                    .foregroundStyle(on ? Color.accentColor : Color.secondary)
            }
            .disabled(forced)
            .help(forced ? "\(mode.title) mode always tests you."
                  : on ? "Quizzes on: the teacher checks your understanding with questions. Click to turn them off from your next message."
                       : "Quizzes off: the teacher teaches without testing you until you turn them back on.")
            .accessibilityIdentifier("quiz-toggle")
        }
    }
}

struct ThinkingPicker: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ChatSession
    var body: some View {
        // From the provider's metadata: nil = unknown (offer all), false = the model can't reason.
        let reasoning = app.modelInfo(session.conversation.providerID, session.conversation.model)?.reasoning
        Menu {
            Picker("Reasoning effort", selection: $settings.value.thinking) {
                Text("Off").tag(ThinkingLevel.off)
                if reasoning != false {
                    Text("Low").tag(ThinkingLevel.low)
                    Text("Medium").tag(ThinkingLevel.medium)
                    Text("High").tag(ThinkingLevel.high)
                }
            }.pickerStyle(.inline)
            if reasoning == false { Text("This model doesn't support reasoning") }
        } label: {
            let on = reasoning != false && settings.value.thinking != .off
            Label("Thinking: \(on ? settings.value.thinking.rawValue.capitalized : "Off")", systemImage: on ? "lightbulb.max" : "lightbulb")
        }
        .help("Reasoning effort")
        .accessibilityLabel("Thinking: \(reasoning != false && settings.value.thinking != .off ? settings.value.thinking.rawValue.capitalized : "Off")")
        .fixedSize()
    }
}

struct ModelPickerButton: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ChatSession
    @State private var show = false

    var body: some View {
        Button { show.toggle() } label: {
            HStack(spacing: 5) {
                Image(systemName: "cpu")
                // One width whatever the model's name: the controls to its right moved when it changed.
                Text(label).lineLimit(1).truncationMode(.middle).frame(width: 196, alignment: .leading)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .help("Provider and model")
        .accessibilityLabel("Model: \(label)")
        .popover(isPresented: $show, arrowEdge: .bottom) {
            ModelPickerPopover(session: session, dismiss: { show = false }).environmentObject(app)
        }
    }

    private var label: String {
        let p = app.settings.provider(session.conversation.providerID)?.name ?? session.conversation.providerID
        return "\(p) · \(session.conversation.model)"
    }
}

struct ModelPickerPopover: View {
    @EnvironmentObject var app: AppModel
    @ObservedObject var session: ChatSession
    var dismiss: () -> Void
    @State private var search = ""
    @State private var expanded: Set<String> = []
    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search models", text: $search).textFieldStyle(.roundedBorder).padding(10)
                .focused($searchFocused)
                .onAppear { DispatchQueue.main.async { searchFocused = true } }   // type to filter right away
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(sections(), id: \.provider.id) { s in
                        providerSection(s.provider, s.models)
                    }
                }.padding(.vertical, 6)
            }
        }
        .frame(width: 380, height: 480)
        .onAppear { for p in app.availableProviders { app.loadModels(p) } }
    }

    /// A catalogue can list a model twice; a repeated row id draws as a blank row.
    static func unique<S: Sequence<String>>(_ models: S) -> [String] {
        var seen = Set<String>()
        return models.filter { seen.insert($0).inserted }
    }

    /// Every provider with its models; while searching, only matches (fuzzy: any word order, typos, partial words),
    /// best first, and the providers with the best match on top.
    private func sections() -> [(provider: ProviderConfig, models: [String])] {
        Self.sections(search, providers: app.settings.providers, models: app.modelList, names: { p, m in app.modelMeta[p]?[m]?.name })
    }

    /// The picker's lists for `query` (the debug hooks run the same function on the live app's catalogues).
    static func sections(_ query: String, providers: [ProviderConfig], models: (ProviderConfig) -> [String],
                         names: (String, String) -> String?) -> [(provider: ProviderConfig, models: [String])] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return providers.map { ($0, models($0)) } }
        let asked = Set(Fuzzy.words(query))
        return providers.enumerated().compactMap { i, p -> (Int, ProviderConfig, [String], Double)? in
            // A query word that names the provider ("minimax m3") puts that provider first among equal matches.
            let named = asked.isDisjoint(with: Fuzzy.words(p.name + " " + p.id)) ? 0 : 0.01
            let hits = models(p).compactMap { m in Fuzzy.score(query, [p.name, p.id, m, names(p.id, m) ?? ""], lengthOf: m).map { (m, $0 + named) } }
                .sorted { $0.1 > $1.1 }
            return hits.first.map { (i, p, hits.map(\.0), $0.1) }
        }.sorted { $0.3 != $1.3 ? $0.3 > $1.3 : $0.0 < $1.0 }.map { ($0.1, $0.2) }
    }

    @ViewBuilder private func providerSection(_ p: ProviderConfig, _ filtered: [String]) -> some View {
        let hasKey = app.hasKey(p)
        if !filtered.isEmpty || (search.isEmpty) {
            Section {
                if !hasKey {
                    Button { dismiss(); app.requestKey(for: p) } label: {
                        Label("Add API key…", systemImage: "key").font(.callout)
                    }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 3)
                } else {
                    let limit = (search.isEmpty && !expanded.contains(p.id)) ? 8 : 400
                    ForEach(Self.unique(filtered.prefix(limit)), id: \.self) { m in
                        Button {
                            session.setModel(providerID: p.id, model: m)
                            app.settings.value.providerID = p.id
                            app.settings.value.model = m
                            dismiss()
                        } label: {
                            HStack {
                                Text(m).font(.callout).lineLimit(1)
                                Spacer()
                                if let i = app.modelMeta[p.id]?[m] { ModelBadges(info: i) }
                                if session.conversation.providerID == p.id && session.conversation.model == m {
                                    Image(systemName: "checkmark").foregroundStyle(Color.accentColor)
                                }
                            }.contentShape(Rectangle())
                        }
                        .buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 3)
                        .id("\(p.id)/\(m)")   // the lazy stack is flat: a model two providers share left a blank row
                    }
                    if filtered.count > limit {
                        Button("Show all \(filtered.count) models") { expanded.insert(p.id) }
                            .buttonStyle(.link).font(.caption).padding(.horizontal, 14).padding(.vertical, 2)
                    }
                }
            } header: {
                HStack {
                    Text(p.name).font(.caption.bold()).foregroundStyle(.secondary)
                    if let n = p.note { Text(n).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                    Spacer()
                    // A failed live list shows the built-in fallback: say so, and offer a retry, rather than look hard-coded.
                    if hasKey, let err = app.modelErrors[p.id] {
                        Image(systemName: "exclamationmark.triangle.fill").font(.caption2).foregroundStyle(.orange)
                            .help("Couldn't load \(p.name)'s live model list (\(err.prefix(120))). Showing the built-in list.")
                    }
                    if hasKey {
                        Button { app.loadModels(p, force: true) } label: { Image(systemName: "arrow.clockwise").font(.caption2) }.accessibilityLabel("Reload \(p.name)'s models")
                            .buttonStyle(.borderless).help("Reload \(p.name)'s models")
                        Circle().fill(.green).frame(width: 6, height: 6)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 4)
                .background(.regularMaterial)
            }
        }
    }
}


/// Lesson-level metadata: tokens, cache efficiency, speed, tool use, memory and context size.
struct LessonInfoButton: View {
    @ObservedObject var session: ChatSession
    @State private var show = false
    var body: some View {
        Button { show.toggle() } label: { Label("Lesson info", systemImage: "info.circle") }
            .help("Lesson stats")
            .popover(isPresented: $show, arrowEdge: .bottom) { LessonInfoView(session: session).frame(width: 340) }
    }
}

struct LessonInfoView: View {
    @ObservedObject var session: ChatSession
    var body: some View {
        let st = session.conversation.stats ?? ConversationStats()
        let u = st.usage
        VStack(alignment: .leading, spacing: 12) {
            Text(session.conversation.title).font(.headline).lineLimit(2)
            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                row("Model", session.conversation.model)
                row("Turns · model calls", "\(st.turns) · \(st.steps)")
                row("Tool calls", "\(st.toolCalls)")
                row("Context now", Composer.short(st.contextTokens) + " tokens")
                Divider().gridCellColumns(2)
                row("Input (uncached)", Composer.short(u.input))
                row("Cache read", Composer.short(u.cacheRead) + (st.cacheHitRate.map { String(format: "  (%.0f%% hit)", $0 * 100) } ?? ""))
                row("Cache write", Composer.short(u.cacheWrite))
                row("Output", Composer.short(u.output) + (u.reasoningTokens.map { "  (\(Composer.short($0)) reasoning)" } ?? ""))
                Divider().gridCellColumns(2)
                row("Avg decode speed", st.generationSeconds > 0 ? String(format: "%.0f tok/s", Double(u.output) / st.generationSeconds) : "—")
                row("Time with teacher", StudyProgressView.hours(st.wallSeconds))
                if let s = session.conversation.compactSummary { row("Summarised", "\(s.count) chars of earlier lesson") }
                row("Memory", session.conversation.reflectedAt.map { "reflected \($0.formatted(.relative(presentation: .named)))" } ?? "not reflected yet")
                row("Folder", session.services.workspace.name)
            }
            .font(.callout)
        }
        .padding(16)
    }
    private func row(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).foregroundStyle(.secondary)
            Text(v).monospacedDigit().textSelection(.enabled)
        }
    }
}

/// Compact facts from the provider's metadata: context size, reasoning, vision, free.
struct ModelBadges: View {
    let info: ModelInfo
    var body: some View {
        HStack(spacing: 4) {
            if info.free == true { Text("free").font(.caption2.bold()).foregroundStyle(.green) }
            if info.reasoning == true { Image(systemName: "lightbulb.max").font(.caption2) }
            if info.vision == true { Image(systemName: "eye").font(.caption2) }
            if let c = info.contextWindow { Text(c >= 1_000_000 ? "\(c / 1_000_000)M" : "\(c / 1000)k").font(.caption2.monospacedDigit()) }
        }.foregroundStyle(.secondary)
    }
}
