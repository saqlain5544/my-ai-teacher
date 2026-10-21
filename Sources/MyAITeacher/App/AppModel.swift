import Foundation
import SwiftUI
import Combine

enum SidebarItem: Hashable {
    case lesson(String)
    case flashcards
    case progress
    case memory
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let global: GlobalStore
    let settings: SettingsStore
    let interactions = InteractionCenter()
    let speech = Speech()
    let extensions = ExtensionHost()

    @Published private(set) var workspace: Workspace
    @Published private(set) var services: Services
    @Published var conversations: [Conversation] = []
    @Published var selection: SidebarItem?
    @Published var keyRequest: ProviderConfig?
    @Published var accessPrompt: Workspace?
    @Published var models: [String: [String]] = [:]
    @Published var modelErrors: [String: String] = [:]
    @Published var dueCount = 0
    @Published var memoryCount = 0
    @Published var searchResults: [String]? = nil

    private var sessions: [String: ChatSession] = [:]
    private var bag: Set<AnyCancellable> = []

    private init() {
        ShellEnvironment.shared.load()
        let s = SettingsStore()
        let g = GlobalStore()
        let start = s.value.lastFolder.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? s.defaultFolder
        let ws = (try? Workspace(url: start)) ?? (try! Workspace(url: s.defaultFolder))
        settings = s
        global = g
        workspace = ws
        services = Services(global: g, workspace: ws)
        if ws.url == s.defaultFolder { g.migrateLegacyConversations(into: ws) }
        registerExtensions()
        conversations = services.conversations.all()
        refreshCounts()
        EventBus.subject
            .sink { [weak self] e in self?.handle(e) }
            .store(in: &bag)
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        if let first = conversations.first { selection = .lesson(first.id) } else { newLesson() }
        touchRecent(ws)
        DispatchQueue.global(qos: .utility).async { _ = Embedder.shared.vector("warm up") }
        Task { await ShellEnvironment.shared.waitUntilLoaded(); objectWillChange.send() }
    }

    /// Built-in features are extensions; add new ones here without touching the agent loop.
    private func registerExtensions() {
        extensions.register(PermissionExtension(app: self))
        extensions.register(MemoryExtension(app: self))
        extensions.register(TeachingContextExtension(app: self))
        extensions.register(LanguageExtension())
        extensions.register(ActivityExtension())
    }

    private func handle(_ e: AppEvent) {
        switch e {
        case .memoryChanged(let c) where c.kind != .recalled: refreshCounts()
        case .studyDataChanged, .turnFinished: refreshCounts()
        case .notice(let conv, let text):
            if let conv, let s = sessions[conv] { s.sink?.notice(text) }
            else if conv == nil, case .lesson(let id) = selection { sessions[id]?.sink?.notice(text) }
        default: break
        }
    }

    func refreshCounts() {
        dueCount = services.study.dueCount()
        memoryCount = services.memory.count()
    }

    // MARK: Folders

    func access(for ws: Workspace) -> FolderAccess { settings.value.folderAccess[ws.url.path] ?? .read }

    func setAccess(_ level: FolderAccess, for ws: Workspace) {
        if level == .read { settings.value.folderAccess.removeValue(forKey: ws.url.path) }
        else { settings.value.folderAccess[ws.url.path] = level }
        objectWillChange.send()
    }

    func openFolderPanel() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Open Folder"
        panel.message = "Choose a folder to learn in. Teacher starts with read-only access; you can grant more."
        if panel.runModal() == .OK, let url = panel.url { openFolder(url) }
    }

    func openFolder(_ url: URL) {
        guard url.standardizedFileURL.path != workspace.url.path else { return }
        let ws: Workspace
        do { ws = try Workspace(url: url) }
        catch {
            let alert = NSAlert()
            alert.messageText = "Can't use this folder"
            alert.informativeText = "Teacher needs to create a hidden “.teacher” folder inside it to keep lessons. \(error.localizedDescription)"
            alert.runModal()
            return
        }
        for s in sessions.values { s.stop(); s.close() }
        sessions.removeAll()
        workspace = ws
        services = Services(global: global, workspace: ws)
        settings.value.lastFolder = ws.url.path
        touchRecent(ws)
        conversations = services.conversations.all()
        searchResults = nil
        refreshCounts()
        if let first = conversations.first { selection = .lesson(first.id) } else { newLesson() }
        EventBus.publish(.workspaceChanged(path: ws.url.path))
        if settings.value.folderAccess[ws.url.path] == nil && ws.url != settings.defaultFolder { accessPrompt = ws }
    }

    private func touchRecent(_ ws: Workspace) {
        var r = settings.value.recentFolders.filter { $0.path != ws.url.path }
        r.insert(WorkspaceRef(path: ws.url.path, lastOpened: Date()), at: 0)
        settings.value.recentFolders = Array(r.prefix(12))
    }

    // MARK: Lessons

    func session(for id: String) -> ChatSession? {
        if let s = sessions[id] { return s }
        guard let c = conversations.first(where: { $0.id == id }) else { return nil }
        let s = ChatSession(conversation: c, app: self, services: services)
        sessions[id] = s
        evictSessions(keeping: id)
        return s
    }

    /// Keep memory low: only the selected and running sessions stay resident.
    private func evictSessions(keeping id: String) {
        guard sessions.count > 3 else { return }
        for (sid, s) in sessions where sid != id && !s.isRunning {
            s.close()
            sessions.removeValue(forKey: sid)
            if sessions.count <= 3 { break }
        }
    }

    @discardableResult
    func newLesson(mode: TeachingMode = .tutor, prompt: String? = nil) -> String {
        if let empty = conversations.first(where: { c in c.title == "New lesson" && services.conversations.messages(c.id).isEmpty }) {
            selection = .lesson(empty.id)
            if let s = session(for: empty.id) {
                s.setMode(mode)
                s.setModel(providerID: settings.value.providerID, model: settings.value.model)
                if let prompt { s.send(prompt) }
            }
            return empty.id
        }
        let c = Conversation(providerID: settings.value.providerID, model: settings.value.model, mode: mode)
        services.conversations.save(c)
        conversations.insert(c, at: 0)
        selection = .lesson(c.id)
        if let prompt { session(for: c.id)?.send(prompt) }
        return c.id
    }

    func delete(_ id: String) {
        sessions[id]?.stop()
        sessions.removeValue(forKey: id)
        services.conversations.delete(id)
        conversations.removeAll { $0.id == id }
        if case .lesson(let sel) = selection, sel == id {
            if let first = conversations.first { selection = .lesson(first.id) } else { newLesson() }
        }
    }

    func togglePin(_ id: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }) else { return }
        conversations[i].pinned.toggle()
        sessions[id]?.conversation.pinned = conversations[i].pinned
        services.conversations.save(conversations[i])
    }

    func rename(_ id: String, to title: String) {
        guard let i = conversations.firstIndex(where: { $0.id == id }), !title.isEmpty else { return }
        conversations[i].title = title
        sessions[id]?.conversation.title = title
        services.conversations.save(conversations[i])
    }

    func conversationDidChange(_ c: Conversation) {
        if let i = conversations.firstIndex(where: { $0.id == c.id }) {
            if conversations[i] != c { conversations[i] = c }
        } else {
            conversations.insert(c, at: 0)
        }
    }

    func sessionDidFinishTurn(_ s: ChatSession) {
        if let i = conversations.firstIndex(where: { $0.id == s.id }), i != 0, !conversations[i].pinned {
            let c = conversations.remove(at: i)
            conversations.insert(c, at: 0)
        }
        if NSApp.isActive == false { NSApp.requestUserAttention(.informationalRequest) }
    }

    func search(_ q: String) {
        let t = q.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { searchResults = nil; return }
        let titleHits = conversations.filter { $0.title.localizedCaseInsensitiveContains(t) }.map(\.id)
        let ftsHits = services.conversations.search(t).map(\.id)
        var seen = Set<String>()
        searchResults = (titleHits + ftsHits).filter { seen.insert($0).inserted }
    }

    func flushAll() { for s in sessions.values { s.close() } }
    func isRunning(_ id: String) -> Bool { sessions[id]?.isRunning ?? false }
    var anyRunning: Bool { sessions.values.contains { $0.isRunning } || !interactions.pending.isEmpty }

    // MARK: Providers & models

    func requestKey(for p: ProviderConfig) { keyRequest = p }
    func hasKey(_ p: ProviderConfig) -> Bool { p.keyOptional || KeyStore.shared.key(for: p) != nil }
    var availableProviders: [ProviderConfig] { settings.providers.filter { hasKey($0) } }

    func loadModels(_ p: ProviderConfig, force: Bool = false) {
        if !force, models[p.id] != nil { return }
        guard hasKey(p) else { return }
        let key = KeyStore.shared.key(for: p)
        Task {
            do {
                var list = try await ProviderCatalog.fetchModels(p, apiKey: key)
                if list.isEmpty { list = p.suggestedModels }
                models[p.id] = list
                modelErrors[p.id] = nil
            } catch {
                models[p.id] = p.suggestedModels.isEmpty ? [p.defaultModel] : p.suggestedModels
                modelErrors[p.id] = error.localizedDescription
            }
        }
    }

    func modelList(_ p: ProviderConfig) -> [String] {
        var list = models[p.id] ?? p.suggestedModels
        if !list.contains(p.defaultModel) { list.insert(p.defaultModel, at: 0) }
        let rec = p.suggestedModels.filter { list.contains($0) }
        return rec + list.filter { !rec.contains($0) }
    }

    // MARK: Welcome screen content

    func welcomePayload() -> JSON {
        let name = settings.value.learnerName
        var stats: [JSON] = []
        let streak = services.study.streakDays()
        if streak > 0 { stats.append(.string("🔥 \(streak)-day streak")) }
        if dueCount > 0 { stats.append(.string("🗂 \(dueCount) cards due")) }
        if memoryCount > 0 { stats.append(.string("🧠 \(memoryCount) \(memoryCount == 1 ? "memory" : "memories")")) }
        let mastered = services.study.allMastery().filter(\.mastered).count
        if mastered > 0 { stats.append(.string("✅ \(mastered) concepts mastered")) }
        stats.append(.string("📁 \(workspace.name) · \(access(for: workspace).title)"))
        var suggestions: [JSON] = [
            ["title": "Learn something new", "subtitle": "Start from what I know and build up", "prompt": "I'd like to learn something new. Ask me a couple of quick questions to find the right starting point, then teach me step by step."],
            ["title": "Explain with a diagram", "subtitle": "How does the internet route a packet?", "prompt": "Explain how a packet travels across the internet from my laptop to a web server. Use a mermaid diagram."],
            ["title": "Practise calculus", "subtitle": "Derivatives with plots and a quiz", "prompt": "Teach me the intuition behind derivatives with a plot, then give me a short quiz."],
            ["title": "Learn a language", "subtitle": "Arabic basics with pronunciation", "prompt": "Teach me five everyday Arabic greetings with pronunciation, then check me with a few questions."],
            ["title": "Study this folder", "subtitle": "Read my files and teach from them", "prompt": "Look through the files in this folder and suggest how you could help me learn from them."],
            ["title": "Today's news, explained", "subtitle": "Live web search with sources", "prompt": "Search the web for one important science or technology story from this week and explain it to me with sources."],
        ]
        if dueCount > 0 {
            suggestions.insert(["title": "Review weak spots", "subtitle": .string("\(dueCount) flashcards due + targeted practice"), "prompt": "Look at my mastery and memory, find my weakest concepts and give me targeted practice with a quiz."], at: 0)
        }
        return ["title": .string(name.isEmpty ? "What would you like to learn today?" : "Hi \(name) — what shall we learn today?"),
                "subtitle": "Ask anything. I can explain, quiz you, draw diagrams, plot functions, run code and search the web.",
                "suggestions": .array(Array(suggestions.prefix(6))), "stats": .array(stats)]
    }
}
