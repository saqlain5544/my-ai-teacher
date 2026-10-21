import SwiftUI

struct ContentView: View {
    @EnvironmentObject var app: AppModel
    @EnvironmentObject var settings: SettingsStore

    var body: some View {
        NavigationSplitView {
            Sidebar()
                .navigationSplitViewColumnWidth(min: 210, ideal: 250, max: 340)
        } detail: {
            detail
        }
        .sheet(item: $app.keyRequest) { p in KeyEntrySheet(provider: p).environmentObject(app) }
        .sheet(item: $app.accessPrompt) { ws in FolderAccessSheet(workspace: ws).environmentObject(app) }
        .task {
            await ShellEnvironment.shared.waitUntilLoaded()
            for p in app.availableProviders { app.loadModels(p) }
        }
    }

    @ViewBuilder private var detail: some View {
        switch app.selection {
        case .lesson(let id):
            if let s = app.session(for: id) { ChatView(session: s) }
            else { Text("Select a lesson").foregroundStyle(.secondary) }
        case .flashcards: FlashcardsView()
        case .progress: StudyProgressView()
        case .memory: MemoryView()
        case .insights: InsightsView()
        case nil: Text("Select a lesson").foregroundStyle(.secondary)
        }
    }
}

struct Sidebar: View {
    @EnvironmentObject var app: AppModel
    @State private var query = ""
    @State private var renaming: Conversation?
    @State private var newTitle = ""

    var body: some View {
        List(selection: $app.selection) {
            Section {
                Label("Flashcards", systemImage: "rectangle.on.rectangle.angled")
                    .badge(app.dueCount)
                    .tag(SidebarItem.flashcards)
                Label("Progress", systemImage: "chart.line.uptrend.xyaxis")
                    .tag(SidebarItem.progress)
                Label("Memory", systemImage: "brain.head.profile")
                    .badge(app.memoryCount)
                    .tag(SidebarItem.memory)
                Label("Insights", systemImage: "gauge.with.dots.needle.33percent").tag(SidebarItem.insights)
            }
            ForEach(groups, id: \.0) { title, items in
                Section(title) {
                    ForEach(items) { c in
                        row(c).tag(SidebarItem.lesson(c.id))
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .top, spacing: 0) { FolderSwitcher().padding(.horizontal, 10).padding(.bottom, 6) }
        .searchable(text: $query, placement: .sidebar, prompt: "Search lessons")
        .onChange(of: query) { _, q in app.search(q) }
        .toolbar {
            ToolbarItem {
                Button { app.newLesson() } label: { Label("New Lesson", systemImage: "square.and.pencil") }
                    .help("New lesson (⌘N)")
            }
        }
        .alert("Rename lesson", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
            TextField("Title", text: $newTitle)
            Button("Rename") { if let r = renaming { app.rename(r.id, to: newTitle) }; renaming = nil }
            Button("Cancel", role: .cancel) { renaming = nil }
        }
    }

    private func row(_ c: Conversation) -> some View {
        HStack(spacing: 8) {
            Image(systemName: c.mode.symbol).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 1) {
                Text(c.title).lineLimit(1)
                Text(c.updatedAt, format: .relative(presentation: .named)).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
            if c.pinned { Image(systemName: "pin.fill").font(.caption2).foregroundStyle(.secondary) }
        }
        .contextMenu {
            Button(c.pinned ? "Unpin" : "Pin") { app.togglePin(c.id) }
            Button("Rename…") { newTitle = c.title; renaming = c }
            Divider()
            Button("Delete", role: .destructive) { app.delete(c.id) }
        }
    }

    private var groups: [(String, [Conversation])] {
        var list = app.conversations
        if let hits = app.searchResults {
            let set = Set(hits)
            list = list.filter { set.contains($0.id) }
            return list.isEmpty ? [] : [("Results", list)]
        }
        let cal = Calendar.current
        var pinned: [Conversation] = [], today: [Conversation] = [], yesterday: [Conversation] = [], week: [Conversation] = [], older: [Conversation] = []
        for c in list {
            if c.pinned { pinned.append(c) }
            else if cal.isDateInToday(c.updatedAt) { today.append(c) }
            else if cal.isDateInYesterday(c.updatedAt) { yesterday.append(c) }
            else if c.updatedAt > Date().addingTimeInterval(-7 * 86400) { week.append(c) }
            else { older.append(c) }
        }
        return [("Pinned", pinned), ("Today", today), ("Yesterday", yesterday), ("Previous 7 days", week), ("Older", older)].filter { !$0.1.isEmpty }
    }
}

struct KeyEntrySheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    let provider: ProviderConfig
    @State private var key = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("API key for \(provider.name)").font(.title3.bold())
            Text("Keys are read from your shell environment (\(provider.envKeys.joined(separator: ", "))) or can be added here at runtime. Keys added here are stored locally with owner-only permissions.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            SecureField("Paste API key", text: $key).textFieldStyle(.roundedBorder).onSubmit(save)
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Save") { save() }.keyboardShortcut(.defaultAction).disabled(key.isEmpty)
            }
        }
        .padding(22).frame(width: 440)
    }

    private func save() {
        KeyStore.shared.set(key, for: provider.id)
        app.loadModels(provider, force: true)
        app.objectWillChange.send()
        dismiss()
    }
}


/// Shows the current folder and its access level; switches folders.
struct FolderSwitcher: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        let ws = app.workspace
        let access = app.access(for: ws)
        Menu {
            Section("Teacher's access to “\(ws.name)”") {
                ForEach(FolderAccess.allCases) { level in
                    Button { app.setAccess(level, for: ws) } label: {
                        if level == access { Label(level.title, systemImage: "checkmark") } else { Text(level.title) }
                    }
                }
            }
            Divider()
            Button("Open Folder…") { app.openFolderPanel() }
            if app.settings.value.recentFolders.count > 1 {
                Menu("Recent Folders") {
                    ForEach(app.settings.value.recentFolders.filter { $0.path != ws.url.path }) { r in
                        Button(r.name) { app.openFolder(URL(fileURLWithPath: r.path)) }
                    }
                }
            }
            if ws.url != app.settings.defaultFolder {
                Button("Default Folder") { app.openFolder(app.settings.defaultFolder) }
            }
            Divider()
            Button("Show Files") { app.reveal(ws.url) }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder.fill").foregroundStyle(Color.accentColor)
                VStack(alignment: .leading, spacing: 0) {
                    Text(ws.name).font(.callout.weight(.semibold)).lineLimit(1)
                    Label(access.title, systemImage: access.symbol).font(.caption2).foregroundStyle(access == .read ? Color.secondary : (access == .full ? Color.orange : Color.green))
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.caption2).foregroundStyle(.tertiary)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.primary.opacity(0.05)))
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .help(ws.url.path)
    }
}

struct FolderAccessSheet: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.dismiss) var dismiss
    let workspace: Workspace
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(systemName: "folder.badge.gearshape").font(.largeTitle).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Opened “\(workspace.name)”").font(.title3.bold())
                    Text(workspace.url.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            Text("Teacher can read this folder (and files anywhere on your Mac). It keeps lessons in a hidden “.teacher” folder here. How much more should it be able to do?")
                .fixedSize(horizontal: false, vertical: true)
            ForEach(FolderAccess.allCases) { level in
                Button {
                    app.setAccess(level, for: workspace); dismiss()
                } label: {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: level.symbol).frame(width: 22).foregroundStyle(Color.accentColor)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(level.title).font(.headline)
                            Text(level.detail).font(.callout).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(10)
                    .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.05)))
                }
                .buttonStyle(.plain)
            }
            Text("You can change this any time from the folder menu at the top of the sidebar.").font(.caption).foregroundStyle(.secondary)
        }
        .padding(22).frame(width: 470)
    }
}
