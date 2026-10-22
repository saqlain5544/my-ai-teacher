import Foundation
import SwiftUI
import Combine

enum SidebarItem: Hashable {
    case lesson(String)
    case flashcards
    case progress
    case memory
    case insights
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
    private var modelAttempts: [String: Date] = [:]
    /// Provider metadata per model (context window, max output, reasoning, vision, pricing), from the provider's /models.
    @Published var modelMeta: [String: [String: ModelInfo]] = [:]
    // Right-side inspector (files + in-app page viewer).
    @Published var inspectorShown = false
    @Published var inspectorTab: InspectorTab = .files
    /// The exercise open in the editor (the right panel's Exercise tab, or its own window).
    @Published var exerciseID: String?
    @Published var webURL: URL?
    @Published var revealRequest: URL?
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
        NotificationCenter.default.addObserver(forName: .openExercise, object: nil, queue: .main) { [weak self] n in
            MainActor.assumeIsolated { self?.showExercise(n.object as? String) }
        }
        conversations = services.conversations.all()
        refreshCounts()
        EventBus.subject
            .sink { [weak self] e in self?.handle(e) }
            .store(in: &bag)
        settings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        Experiments.enabled = s.value.experiments
        settings.$value.map(\.experiments).removeDuplicates().sink { Experiments.enabled = $0 }.store(in: &bag)
        if let first = conversations.first { selection = .lesson(first.id) } else { newLesson() }
        // A sub-agent starting in the open lesson shows up in the right-hand panel, as it works.
        SubAgentCenter.shared.onReport = { [weak self] run, out in
            self?.session(for: run.conversationID)?.deliver(SubAgent.reportMessage(run, out))
        }
        SubAgentCenter.shared.onStart = { [weak self] run in
            guard let self, case .lesson(let id) = self.selection, id == run.conversationID else { return }
            self.showSubAgent(run.id)
        }
        touchRecent(ws)
        // Loads the on-device model on a GCD thread (it blocks for a while), not on the main thread or the cooperative pool.
        Task { await Runtime.job("embeddings.warmup", restart: .temporary) { _ in
            await withCheckedContinuation { c in DispatchQueue.global(qos: .utility).async { _ = Embedder.shared.vector("warm up"); c.resume() } }
        } }
        Task { await ShellEnvironment.shared.waitUntilLoaded(); objectWillChange.send() }
    }

    /// Built-in features are extensions; add new ones here without touching the agent loop.
    private func registerExtensions() {
        // First: its refusals (the teacher writing the learner's exercise code) must win over an approval prompt.
        extensions.register(ExerciseExtension())
        extensions.register(PermissionExtension(app: self))
        extensions.register(ComputerUseExtension(app: self))
        extensions.register(MemoryExtension(app: self))
        extensions.register(TeachingContextExtension(app: self))
        extensions.register(CourseBoardExtension())
        extensions.register(LanguageExtension())
        extensions.register(ActivityExtension())
        Telemetry.shared.start(db: global.db)
        extensions.register(TelemetryExtension())
        extensions.register(ExperimentExtension())
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

    func access(for ws: Workspace) -> FolderAccess {
        settings.value.folderAccess[ws.url.path] ?? (isQuick(ws) ? .full : .read)
    }
    func isQuick(_ ws: Workspace) -> Bool { ws.url.standardizedFileURL.path == AppPaths.quickFolder.standardizedFileURL.path }

    /// A quick question outside any folder: switch to the quick-questions space and start a fresh lesson.
    func quickQuestion() {
        if !isQuick(workspace) { openFolder(AppPaths.quickFolder) }
        newLesson()
    }

    func setAccess(_ level: FolderAccess, for ws: Workspace) {
        if level == .read && !isQuick(ws) { settings.value.folderAccess.removeValue(forKey: ws.url.path) }
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
        for s in sessions.values { s.stop(); s.close(); s.detach(deleted: false) }
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
        if settings.value.folderAccess[ws.url.path] == nil && ws.url != settings.defaultFolder && !isQuick(ws) { accessPrompt = ws }
    }

    private func touchRecent(_ ws: Workspace) {
        var r = settings.value.recentFolders.filter { $0.path != ws.url.path }
        r.insert(WorkspaceRef(path: ws.url.path, lastOpened: Date()), at: 0)
        settings.value.recentFolders = Array(r.prefix(12))
    }

    // MARK: Lessons

    /// Opens an exercise in the right panel's editor.
    func showExercise(_ id: String?) {
        exerciseID = id
        inspectorTab = .exercise
        inspectorShown = true
    }

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
        sessions[id]?.detach(deleted: true)
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

    // MARK: In-app navigation (nothing opens another app)

    /// Opens a link in the inspector's page viewer; mailto copies the address instead of launching Mail.
    func openLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            webURL = url; inspectorTab = .page; inspectorShown = true
        case "mailto":
            let addr = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(addr, forType: .string)
            EventBus.publish(.notice(conversationID: nil, text: "Copied \(addr)"))
        default: break
        }
    }

    /// Shows a file or folder in the inspector's file explorer.
    func showSubAgent(_ id: String) {
        SubAgentCenter.shared.selectedID = id
        inspectorTab = .agents
        inspectorShown = true
    }
    func reveal(_ url: URL) { inspectorTab = .files; inspectorShown = true; revealRequest = url }

    // MARK: Providers & models

    func requestKey(for p: ProviderConfig) { keyRequest = p }
    func hasKey(_ p: ProviderConfig) -> Bool { p.keyOptional || KeyStore.shared.key(for: p) != nil }
    var availableProviders: [ProviderConfig] { settings.providers.filter { hasKey($0) } }

    /// Loads a provider's model list: disk cache (24 h) first, network otherwise. One request per provider per day; a
    /// failed one is retried (at most every 30 s) instead of leaving the built-in fallback list in place all session.
    func loadModels(_ p: ProviderConfig, force: Bool = false) {
        let failedLongAgo = modelErrors[p.id] != nil && Date().timeIntervalSince(modelAttempts[p.id] ?? .distantPast) > 30
        if !force, models[p.id] != nil, !failedLongAgo { return }
        if !force, let cached = ModelCache.load(p.id) { apply(p, cached); return }
        guard hasKey(p) else { return }
        let key = KeyStore.shared.key(for: p)
        modelAttempts[p.id] = Date()
        Task {
            do {
                let list = try await ProviderCatalog.fetchModels(p, apiKey: key)
                if !list.isEmpty { ModelCache.save(p.id, list) }
                apply(p, list)
                modelErrors[p.id] = nil
            } catch {
                if let stale = ModelCache.load(p.id, maxAge: .infinity) { apply(p, stale) }
                else { models[p.id] = p.suggestedModels.isEmpty ? [p.defaultModel] : p.suggestedModels }
                modelErrors[p.id] = error.localizedDescription
            }
        }
    }

    func apply(_ p: ProviderConfig, _ list: [ModelInfo]) {
        models[p.id] = list.isEmpty ? p.suggestedModels : list.map(\.id)
        modelMeta[p.id] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Metadata for a model, loading the provider's cached list on first use (no network when cached).
    func modelInfo(_ providerID: String, _ model: String) -> ModelInfo? {
        if modelMeta[providerID] == nil, let cached = ModelCache.load(providerID, maxAge: .infinity) {
            modelMeta[providerID] = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        }
        return modelMeta[providerID]?[model]
    }

    func modelList(_ p: ProviderConfig) -> [String] {
        var list = models[p.id] ?? p.suggestedModels
        if !list.contains(p.defaultModel) { list.insert(p.defaultModel, at: 0) }
        let rec = p.suggestedModels.filter { list.contains($0) }
        return rec + list.filter { !rec.contains($0) }
    }

    // MARK: Welcome screen content

    func welcomePayload(mode: TeachingMode = .tutor) -> JSON {
        let name = settings.value.learnerName
        if mode.isAgent {
            let hasMemory = !ProjectMemory.read(workspace.url).isEmpty
            return ["title": .string("What shall we build in \(workspace.name)?"),
                    "subtitle": .string("A coding agent with the full toolset, working in this folder (\(access(for: workspace).title.lowercased())). It remembers this project in .teacher/code-memory.md."),
                    "suggestions": [
                        ["title": "Explain this codebase", "subtitle": "Structure, entry points, how to build and test", "prompt": "Explore this project and explain its structure, entry points, and how to build and test it. Save the build and test commands to project memory."],
                        ["title": "Fix failing tests", "subtitle": "Run the tests, find the cause, fix it", "prompt": "Run this project's tests, find the cause of any failures, fix them, and run the tests again to confirm."],
                        ["title": "Review my changes", "subtitle": "git diff, bugs and risks", "prompt": "Review the uncommitted changes in this repository (git diff) for bugs, risks and missing tests. Don't change anything yet."],
                        ["title": "Add a feature", "subtitle": "Plan, implement, verify", "prompt": "I want to add a feature. Ask me what it is, then plan it with a todo list, implement it in small steps and verify with the tests."],
                    ],
                    "stats": .array([.string("📁 \(workspace.name) · \(access(for: workspace).title)"), .string(hasMemory ? "🧠 project memory loaded" : "🧠 no project memory yet")])]
        }
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
        if isQuick(workspace) { suggestions.removeAll { $0["title"]?.string == "Study this folder" } }
        if dueCount > 0 {
            suggestions.insert(["title": "Review weak spots", "subtitle": .string("\(dueCount) flashcards due + targeted practice"), "prompt": "Look at my mastery and memory, find my weakest concepts and give me targeted practice with a quiz."], at: 0)
        }
        return ["title": .string(name.isEmpty ? "What would you like to learn today?" : "Hi \(name) — what shall we learn today?"),
                "subtitle": "Ask anything. I can explain, quiz you, draw diagrams, plot functions, run code and search the web.",
                "suggestions": .array(Array(suggestions.prefix(6))), "stats": .array(stats)]
    }
}
