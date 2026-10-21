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
                LessonInfoButton(session: session)
            }
        }
        .inspector(isPresented: $app.inspectorShown) {
            InspectorPanel(session: session)
                .inspectorColumnWidth(min: 260, ideal: 340, max: 640)
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
                Text(label).lineLimit(1)
                Image(systemName: "chevron.down").font(.caption2)
            }
        }
        .help("Provider and model")
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

    var body: some View {
        VStack(spacing: 0) {
            TextField("Search models", text: $search).textFieldStyle(.roundedBorder).padding(10)
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2, pinnedViews: [.sectionHeaders]) {
                    ForEach(app.settings.providers) { p in
                        providerSection(p)
                    }
                }.padding(.vertical, 6)
            }
        }
        .frame(width: 380, height: 480)
        .onAppear { for p in app.availableProviders { app.loadModels(p) } }
    }

    @ViewBuilder private func providerSection(_ p: ProviderConfig) -> some View {
        let hasKey = app.hasKey(p)
        let all = app.modelList(p)
        let filtered = search.isEmpty ? all : all.filter { $0.localizedCaseInsensitiveContains(search) || p.name.localizedCaseInsensitiveContains(search) }
        if !filtered.isEmpty || (search.isEmpty) {
            Section {
                if !hasKey {
                    Button { dismiss(); app.requestKey(for: p) } label: {
                        Label("Add API key…", systemImage: "key").font(.callout)
                    }.buttonStyle(.plain).padding(.horizontal, 14).padding(.vertical, 3)
                } else {
                    let limit = (search.isEmpty && !expanded.contains(p.id)) ? 8 : 400
                    ForEach(filtered.prefix(limit), id: \.self) { m in
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
                    if hasKey { Circle().fill(.green).frame(width: 6, height: 6) }
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
