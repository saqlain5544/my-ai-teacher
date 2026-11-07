import SwiftUI

/// Every lesson and code session, in every folder. Opening one switches the whole app to it (folder, files, memory,
/// access, and the lesson with its mode and model); lessons working elsewhere keep working in the background.
struct SessionsView: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var scope: Scope = .all
    /// Matches inside lessons' text for the query (all folders), and whether a search is in flight.
    @State private var hits: [PastLessons.Hit] = []
    @State private var searching = false

    enum Scope: String, CaseIterable, Identifiable {
        case all = "All", active = "Working", here = "This folder"
        var id: String { rawValue }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Picker("", selection: $scope) { ForEach(Scope.allCases) { Text($0.rawValue).tag($0) } }
                    .pickerStyle(.segmented).labelsHidden().frame(maxWidth: 300)
                TextField("Search sessions and what was said", text: $query).textFieldStyle(.roundedBorder).frame(maxWidth: 300)
                if searching { ProgressView().controlSize(.small) }
                Spacer()
                Button { app.refreshSessions() } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless).help("Reload the list")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            Divider()
            if groups.isEmpty && hits.isEmpty {
                ContentUnavailableView(scope == .active ? "Nothing is working right now" : "No sessions",
                                       systemImage: "rectangle.stack",
                                       description: Text(scope == .active ? "A lesson that is replying or waiting for you shows up here, in any folder." : "Lessons you start in any folder show up here."))
            } else {
                List {
                    ForEach(groups, id: \.0) { folder, items in
                        Section {
                            ForEach(items) { e in row(e) }
                        } header: {
                            HStack(spacing: 6) {
                                Image(systemName: "folder")
                                Text(items[0].folderName)
                                if folder == app.workspace.url.path { Text("open").font(.caption2).foregroundStyle(.secondary) }
                            }
                            .help(folder)
                        }
                    }
                    if !hits.isEmpty {
                        Section {
                            ForEach(hits, id: \.messageID) { h in hitRow(h) }
                        } header: {
                            HStack(spacing: 6) { Image(systemName: "text.magnifyingglass"); Text("In the conversations") }
                        }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("All Sessions")
        .onAppear { app.refreshSessions() }
        // Typing waits a moment, then searches every folder's lessons off the main actor; a newer query (or leaving)
        // cancels the one in flight, which interrupts its SQLite statements.
        .task(id: "\(scope.rawValue)|\(query)") { await search() }
    }

    private func search() async {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard q.count >= 3, !FTS.terms(q).isEmpty else { hits = []; searching = false; return }
        searching = true
        defer { if !Task.isCancelled { searching = false } }
        do { try await Task.sleep(nanoseconds: 300_000_000) } catch { return }
        // The picker applies to what was said too: this folder only, or only the lessons working right now.
        let here = app.workspace.url.path
        let others = scope == .here ? [] : app.allSessions.map(\.folder) + SessionIndex.known.get()
        let folders = await PastLessons.databases(current: here, others: others, budget: PastLessons.folderBudget)
        let results = await PastLessons.searchFolders(scope == .here ? [here] : folders, query: q, filter: .init(), limit: scope == .active ? 200 : 30)
        guard !Task.isCancelled else { return }
        hits = PastLessons.merge(results, limit: scope == .active ? 200 : 30).filter { h in
            scope != .active || [.running, .waiting].contains(app.activity(h.conversationID))
        }.prefix(30).map { $0 }
    }

    private func hitRow(_ h: PastLessons.Hit) -> some View {
        Button { app.openSession(h.conversationID, folder: h.folder) } label: {
            VStack(alignment: .leading, spacing: 3) {
                Text(h.title).lineLimit(1)
                Text(Self.highlighted(h.snippet)).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                Text("\(h.folderName) · \(h.role) · \(h.date.formatted(date: .abbreviated, time: .omitted))").font(.caption).foregroundStyle(.tertiary)
            }
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(h.title), in \(h.folderName): \(h.snippet.replacingOccurrences(of: "«", with: "").replacingOccurrences(of: "»", with: ""))")
    }

    /// The matched words (marked « » by the search) in bold.
    static func highlighted(_ s: String) -> AttributedString {
        var out = AttributedString()
        for (i, part) in s.components(separatedBy: "«").enumerated() {
            let pieces = part.components(separatedBy: "»")
            if i == 0 { out += AttributedString(pieces.joined()); continue }
            var hit = AttributedString(pieces[0]); hit.font = .callout.bold(); hit.foregroundColor = .primary
            out += hit
            out += AttributedString(pieces.dropFirst().joined())
        }
        return out
    }

    private func row(_ e: SessionIndex.Entry) -> some View {
        let c = e.conversation
        return Button { app.openSession(c.id, folder: e.folder) } label: {
            HStack(spacing: 10) {
                Image(systemName: c.mode.symbol).foregroundStyle(.secondary).frame(width: 18)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.title).lineLimit(1)
                    Text("\(c.mode.title) · \(c.model)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 8)
                SessionActivityBadge(activity: app.activity(c.id))
                Text(c.updatedAt, format: .relative(presentation: .named)).font(.caption).foregroundStyle(.tertiary)
                    .frame(minWidth: 70, alignment: .trailing)
            }
            .padding(.vertical, 3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(c.title), \(c.mode.title), in \(e.folderName)")
    }

    /// Working sessions first, then by folder: the open folder's, then the rest by their newest lesson.
    private var groups: [(String, [SessionIndex.Entry])] {
        let q = query.trimmingCharacters(in: .whitespaces)
        let list = app.allSessions.filter { e in
            switch scope {
            case .all: true
            case .active: [.running, .waiting].contains(app.activity(e.id))
            case .here: e.folder == app.workspace.url.path
            }
        }.filter { q.isEmpty || $0.conversation.title.localizedCaseInsensitiveContains(q) || $0.folderName.localizedCaseInsensitiveContains(q) }
        var order: [String] = [], byFolder: [String: [SessionIndex.Entry]] = [:]
        for e in list {
            if byFolder[e.folder] == nil { order.append(e.folder) }
            byFolder[e.folder, default: []].append(e)
        }
        let current = app.workspace.url.path
        order.sort { a, b in (a == current ? 0 : 1) < (b == current ? 0 : 1) }
        return order.map { f in
            let items = byFolder[f]!
            return (f, items.filter { app.activity($0.id) != .idle } + items.filter { app.activity($0.id) == .idle })
        }
    }
}

/// Running, waiting for the learner, or finished while they were elsewhere.
struct SessionActivityBadge: View {
    let activity: AppModel.Activity
    /// The sidebar's rows: the marks without their words.
    var compact = false
    var body: some View {
        switch activity {
        case .running:
            HStack(spacing: 4) { ProgressView().controlSize(.mini); if !compact { Text("Working") } }
                .font(.caption).foregroundStyle(.secondary).help("Replying in the background")
        case .waiting:
            Label("Needs you", systemImage: "hand.raised.fill").font(.caption).foregroundStyle(.orange)
                .labelStyle(compact ? AnyLabelStyle(.iconOnly) : AnyLabelStyle(.titleAndIcon))
                .help("Waiting for your answer or approval")
        case .finished:
            Circle().fill(Color.accentColor).frame(width: 7, height: 7).help("Finished while you were elsewhere")
        case .idle:
            EmptyView()
        }
    }
}

private struct AnyLabelStyle: LabelStyle {
    private let make: (Configuration) -> AnyView
    init<S: LabelStyle>(_ style: S) { make = { AnyView(Label($0).labelStyle(style)) } }
    func makeBody(configuration: Configuration) -> some View { make(configuration) }
}
