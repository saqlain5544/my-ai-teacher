import Foundation
import SwiftUI
import Combine

enum SidebarItem: Hashable {
    case lesson(String)
    case sessions
    case flashcards
    case progress
    case memory
    case insights
    case tasks
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
    @Published var selection: SidebarItem? {
        didSet { if case .lesson(let id) = selection { finishedUnseen.remove(id) } }
    }
    /// Every lesson in every folder the learner works in (`SessionIndex`), for the All Sessions list.
    @Published private(set) var allSessions: [SessionIndex.Entry] = []
    /// Lessons that finished a turn while the learner was looking elsewhere: marked in the lists until opened.
    @Published private(set) var finishedUnseen: Set<String> = []
    @Published var keyRequest: ProviderConfig?
    @Published var accessPrompt: Workspace?
    @Published var models: [String: [String]] = [:]
    @Published var modelErrors: [String: String] = [:]
    private var modelAttempts: [String: Date] = [:]
    /// Providers with a model-list request in flight (a second `loadModels` meanwhile sent a duplicate request).
    private var modelLoads: Set<String> = []
    /// Providers with no cached model list on disk: `modelInfo` runs several times per step, and re-read the missing
    /// file on every call. Cleared when a list arrives.
    private var modelCacheMisses: Set<String> = []
    /// Provider metadata per model (context window, max output, reasoning, vision, pricing), from the provider's /models.
    @Published var modelMeta: [String: [String: ModelInfo]] = [:]
    // Right-side inspector (files, plan, changes, browser, agents).
    @Published var inspectorShown = false
    @Published var inspectorTab: InspectorTab = .files
    @Published var revealRequest: URL?
    @Published var dueCount = 0
    @Published var memoryCount = 0
    /// Background tasks running now (the sidebar's Tasks badge), checked every 2 s.
    @Published private(set) var runningTasks = 0
    private var tasksTimer: Timer?
    @Published var searchResults: [String]? = nil

    private var sessions: [String: ChatSession] = [:]
    /// Each resident session's running state, forwarded so the lists show a lesson working in the background.
    private var sessionWatch: [String: AnyCancellable] = [:]
    private var bag: Set<AnyCancellable> = []

    private init() {
        ShellEnvironment.shared.load()
        Toolchains.shared.warmUp()
        let s = SettingsStore()
        let g = GlobalStore()
        let start = s.value.lastFolder.map { URL(fileURLWithPath: $0) }.flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil } ?? s.defaultFolder
        let ws = (try? Workspace(url: start)) ?? (try? Workspace(url: s.defaultFolder)) ?? Self.fallbackWorkspace(s.defaultFolder)
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
        interactions.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &bag)
        BoardSystem.loadForced()
        settings.$value.map(\.courseBoard).removeDuplicates().sink { BoardSystem.chosen = $0 }.store(in: &bag)
        settings.$value.map(\.activityLog).removeDuplicates().sink { ActivityLog.level = $0 }.store(in: &bag)
        tasksTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let n = BackgroundTasks.runningCount
                if n != self.runningTasks { self.runningTasks = n }
            }
        }
        let info = Bundle.main.infoDictionary
        ActivityLog.record("app.launch", ["version": .string(info?["CFBundleShortVersionString"] as? String ?? "dev"),
                                          "build": .string(info?["CFBundleVersion"] as? String ?? "dev"),
                                          "pid": .number(Double(ProcessInfo.processInfo.processIdentifier)), "folder": .string(ws.url.path)])
        if let first = conversations.first { selection = .lesson(first.id) } else { newLesson() }
        // A sub-agent starting in the open lesson shows up in the right-hand panel, as it works.
        SubAgentCenter.shared.onReport = { [weak self] run, out in
            ActivityLog.record("subagent.end", conv: run.conversationID, ["handle": .string(run.handle), "state": .string(run.state.rawValue),
                                                                         "steps": .number(Double(run.steps)), "usage": ActivityLog.usage(run.totalUsage),
                                                                         "report": ActivityLog.text(out.text)])
            self?.deliver(SubAgent.reportMessage(run, out), to: run.conversationID)
        }
        SubAgentCenter.shared.onStart = { [weak self] run in
            ActivityLog.record("subagent.start", conv: run.conversationID, ["handle": .string(run.handle), "title": .string(run.title),
                                                                           "type": run.config.map { .string($0.type.name) } ?? .null,
                                                                           "model": run.config.map { .string($0.model) } ?? .null,
                                                                           "background": .bool(run.background), "parent": run.parent.map { .string($0) } ?? .null])
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

    /// Neither the last folder nor the default one can hold `.teacher/` (a full disk, a read-only or unmounted volume):
    /// the app starts in a temporary folder instead of crashing at launch, and the learner can open another folder.
    private static func fallbackWorkspace(_ wanted: URL) -> Workspace {
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("MyAITeacher-fallback", isDirectory: true)
        AppLog.write("workspace: \(wanted.path) is unusable; starting in \(tmp.path)")
        guard let ws = try? Workspace(url: tmp) else { fatalError("No usable folder: \(wanted.path) and \(tmp.path) both failed") }
        return ws
    }

    /// Built-in features are extensions; add new ones here without touching the agent loop. A feature with its own
    /// tools is a `Features.Module` instead: its hooks are registered here, right after the permission gate.
    private func registerExtensions() {
        extensions.register(CodeAgentExtension(app: self))   // before permissions: a file is checkpointed before any gate can pause the call
        extensions.register(HooksExtension(app: self))   // before permissions: a blocked call is never asked about
        extensions.register(PermissionExtension(app: self))
        for module in Features.all { module.extensions(self).forEach(extensions.register) }
        extensions.register(MemoryExtension(app: self))
        extensions.register(TeachingContextExtension(app: self))
        extensions.register(TestingExtension())
        extensions.register(LanguageExtension())
        extensions.register(CodeMentorExtension())
        extensions.register(MentorGuard())
        extensions.register(AnswerFirstExtension())
        extensions.register(ActivityExtension())
        Telemetry.shared.start(db: global.db)
        extensions.register(TelemetryExtension())
    }

    private func handle(_ e: AppEvent) {
        Self.log(e)
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
        // An empty lesson's welcome names the folder's access: redrawn, or it kept saying "Read only".
        if case .lesson(let id) = selection, let s = sessions[id] { s.refreshWelcome() }
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

    /// Switches to another folder. Lessons still working (a turn running, or waiting for the learner's answer) keep
    /// going in the background with their own folder's services; the rest are saved and let go. `select` opens one of
    /// the folder's lessons instead of the newest; `askAccess` is false when the folder is one the learner already uses.
    func openFolder(_ url: URL, select: String? = nil, askAccess: Bool = true) {
        let path = url.standardizedFileURL.path
        guard path != workspace.url.path else {
            if let select, conversations.contains(where: { $0.id == select }) { selection = .lesson(select) }
            return
        }
        let keep = sessions.filter { isActive($0.key) }
        let ws: Workspace, next: Services
        // A lesson of that folder still working there: its services (and database connection) are the folder's.
        if let live = keep.values.first(where: { $0.services.workspace.url.path == path })?.services {
            ws = live.workspace; next = live
        } else {
            do { ws = try Workspace(url: url) }
            catch {
                let alert = NSAlert()
                alert.messageText = "Can't use this folder"
                alert.informativeText = "Teacher needs to create a hidden “.teacher” folder inside it to keep lessons. \(error.localizedDescription)"
                alert.runModal()
                return
            }
            next = Services(global: global, workspace: ws)
        }
        for (id, s) in sessions where keep[id] == nil { s.close(); s.detach(deleted: false); sessionWatch[id] = nil }
        sessions = keep
        workspace = ws
        services = next
        settings.value.lastFolder = ws.url.path
        touchRecent(ws)
        conversations = services.conversations.all()
        searchResults = nil
        refreshCounts()
        if let select, conversations.contains(where: { $0.id == select }) { selection = .lesson(select) }
        else if let first = conversations.first { selection = .lesson(first.id) } else { newLesson() }
        EventBus.publish(.workspaceChanged(path: ws.url.path))
        if askAccess, settings.value.folderAccess[ws.url.path] == nil && ws.url != settings.defaultFolder && !isQuick(ws) { accessPrompt = ws }
    }

    private func touchRecent(_ ws: Workspace) {
        var r = settings.value.recentFolders.filter { $0.path != ws.url.path }
        r.insert(WorkspaceRef(path: ws.url.path, lastOpened: Date()), at: 0)
        settings.value.recentFolders = Array(r.prefix(12))
    }

    // MARK: Lessons

    /// App events into the activity log (turns and tools are logged where they happen, with their numbers).
    private static func log(_ e: AppEvent) {
        switch e {
        case .approval(let conv, let tool, let choice, let allowed, let waited):
            ActivityLog.record("approval", conv: conv, ["tool": .string(tool), "choice": .string(choice), "allowed": .bool(allowed), "waited_ms": ActivityLog.ms(waited)])
        case .memoryChanged(let c):
            ActivityLog.record("memory", conv: c.conversationID, ["kind": .string(c.kind.rawValue), "ids": .array(c.ids.map { .string($0) }), "summary": ActivityLog.text(c.summary)])
        case .notice(let conv, let text): ActivityLog.record("notice", conv: conv, ["text": ActivityLog.text(text)])
        case .workspaceChanged(let path): ActivityLog.record("folder", ["path": .string(path)])
        case .projectChanged(let folder): ActivityLog.record("project", ["folder": .string(folder)])
        case .turnStarted, .turnFinished, .toolStarted, .toolFinished, .studyDataChanged: break
        }
    }

    func session(for id: String) -> ChatSession? {
        if let s = sessions[id] { return s }
        guard let c = conversations.first(where: { $0.id == id }) else { return nil }
        let s = ChatSession(conversation: c, app: self, services: services)
        sessions[id] = s
        sessionWatch[id] = s.$isRunning.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }
        evictSessions(keeping: id)
        // Reports that finished while the lesson couldn't be loaded (its folder wasn't open) wake it now.
        for r in undelivered.removeValue(forKey: id) ?? [] { s.deliver(r) }
        LocalDecision.warm()
        return s
    }

    /// Background work's report to its lesson: read at the agent's next step, or a new turn when the lesson is idle. A
    /// lesson of a folder that isn't open gets it when it is next opened, rather than losing it.
    func deliver(_ report: ChatMessage, to conversationID: String) {
        if let s = session(for: conversationID) { s.deliver(report) } else { undelivered[conversationID, default: []].append(report) }
    }
    private var undelivered: [String: [ChatMessage]] = [:]

    /// Keep memory low: only the selected and running sessions stay resident.
    private func evictSessions(keeping id: String) {
        guard sessions.count > 3 else { return }
        for (sid, s) in sessions where sid != id && !isActive(sid) {
            s.close()
            if s.services.workspace !== services.workspace { s.detach(deleted: false) }
            sessions.removeValue(forKey: sid)
            sessionWatch[sid] = nil
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
        ShellJobs.shared.stopAll(id)   // its servers and watchers
        sessions.removeValue(forKey: id)
        sessionWatch[id] = nil
        finishedUnseen.remove(id)
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

    /// A lesson saved itself. One of another folder's, working in the background, only updates the All Sessions list:
    /// the sidebar shows the open folder's lessons.
    func conversationDidChange(_ c: Conversation, folder: URL) {
        if let i = allSessions.firstIndex(where: { $0.id == c.id }) { allSessions[i] = .init(conversation: c, folder: folder.path) }
        guard folder.path == workspace.url.path else { return }
        if let i = conversations.firstIndex(where: { $0.id == c.id }) {
            if conversations[i] != c { conversations[i] = c }
        } else {
            conversations.insert(c, at: 0)
        }
    }

    func sessionDidFinishTurn(_ s: ChatSession) {
        if selection != .lesson(s.id) { finishedUnseen.insert(s.id) }
        guard s.services.workspace === services.workspace else { return }
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

    // MARK: All sessions

    /// Re-reads every folder's lessons, off the main thread (each folder is its own database). The open folder's come
    /// from memory, and a lesson working in the background shows its live title.
    func refreshSessions() {
        var folders = settings.value.recentFolders.map(\.path) + [settings.defaultFolder.path, AppPaths.quickFolder.path]
        folders += sessions.values.map(\.services.workspace.url.path)
        let current = workspace.url.path, here = workspace.url.canonicalPath
        folders = folders.filter { URL(fileURLWithPath: $0).canonicalPath != here }
        Task {
            let others = await Task.detached(priority: .userInitiated) { SessionIndex.scan(folders) }.value
            var list = conversations.map { SessionIndex.Entry(conversation: $0, folder: current) } + others
            for i in list.indices { if let live = sessions[list[i].id]?.conversation { list[i] = .init(conversation: live, folder: list[i].folder) } }
            allSessions = SessionIndex.unique(list)
        }
    }

    /// Goes into a lesson of any folder: the folder (its files, memory and access), the lesson, and with it its mode
    /// and model. Lessons working elsewhere keep working.
    func openSession(_ id: String, folder: String) {
        openFolder(URL(fileURLWithPath: folder), select: id, askAccess: false)
    }

    enum Activity { case running, waiting, finished, idle }
    /// What a lesson is doing: a turn running, a question or approval waiting for the learner, a turn finished unseen.
    func activity(_ id: String) -> Activity {
        if interactions.pending.values.contains(where: { $0.conversationID == id }) { return .waiting }
        if sessions[id]?.isRunning == true { return .running }
        return finishedUnseen.contains(id) ? .finished : .idle
    }
    /// Running or waiting: such a lesson stays resident (and keeps going) when the learner switches folders.
    private func isActive(_ id: String) -> Bool { [.running, .waiting].contains(activity(id)) }
    /// Lessons working right now, in any folder.
    var activeCount: Int { sessions.keys.filter(isActive).count }

    func flushAll() { for s in sessions.values { s.close() } }
    func isRunning(_ id: String) -> Bool { sessions[id]?.isRunning ?? false }
    // MARK: In-app navigation (nothing opens another app)

    /// Opens a link in the in-app browser (a tab of the learner's); mailto copies the address instead of launching Mail.
    func openLink(_ url: URL) {
        switch url.scheme?.lowercased() {
        case "http", "https":
            AgentBrowser.shared.openForLearner(url)
            inspectorTab = .browser; inspectorShown = true
        case "mailto":
            let addr = url.absoluteString.dropFirst("mailto:".count).split(separator: "?").first.map(String.init) ?? ""
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString(addr, forType: .string)
            EventBus.publish(.notice(conversationID: nil, text: "Copied \(addr)"))
        default: break
        }
    }

    /// Shows a sub-agent's run in the inspector's Agents tab.
    func showSubAgent(_ id: String) {
        SubAgentCenter.shared.selectedID = id
        inspectorTab = .agents
        inspectorShown = true
    }
    /// Shows a file or folder in the inspector's file explorer.
    func reveal(_ url: URL) { inspectorTab = .files; inspectorShown = true; revealRequest = url }

    // MARK: Providers & models

    func requestKey(for p: ProviderConfig) { keyRequest = p }
    /// Usable: a key, or none needed (the app's own LFM3-Omni once it is downloaded).
    func hasKey(_ p: ProviderConfig) -> Bool {
        if p.id == LiquidModels.providerID { return LiquidModels.ready(.omni) }
        return p.keyOptional || KeyStore.shared.key(for: p) != nil
    }
    var availableProviders: [ProviderConfig] { settings.providers.filter { hasKey($0) } }

    /// Loads a provider's model list: disk cache (24 h) first, network otherwise. One request per provider per day; a
    /// failed one is retried (at most every 30 s) instead of leaving the built-in fallback list in place all session.
    func loadModels(_ p: ProviderConfig, force: Bool = false) {
        let failedLongAgo = modelErrors[p.id] != nil && Date().timeIntervalSince(modelAttempts[p.id] ?? .distantPast) > 30
        if !force, models[p.id] != nil, !failedLongAgo { return }
        if !force, let cached = ModelCache.load(p.id) { apply(p, cached); return }
        guard hasKey(p), !modelLoads.contains(p.id) else { return }
        let key = KeyStore.shared.key(for: p)
        modelAttempts[p.id] = Date()
        modelLoads.insert(p.id)
        Task {
            defer { modelLoads.remove(p.id) }
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
        modelCacheMisses.remove(p.id)
        modelMeta[p.id] = Dictionary(list.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// Metadata for a model, loading the provider's cached list on first use (no network when cached).
    func modelInfo(_ providerID: String, _ model: String) -> ModelInfo? {
        if modelMeta[providerID] == nil, !modelCacheMisses.contains(providerID) {
            if let cached = ModelCache.load(providerID, maxAge: .infinity) {
                modelMeta[providerID] = Dictionary(cached.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            } else {
                modelCacheMisses.insert(providerID)
            }
        }
        return modelMeta[providerID]?[model]
    }

    func modelList(_ p: ProviderConfig) -> [String] {
        // A catalogue entry without an id drew a blank row in the picker.
        var list = (models[p.id] ?? p.suggestedModels).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        if !list.contains(p.defaultModel) { list.insert(p.defaultModel, at: 0) }
        let rec = p.suggestedModels.filter { list.contains($0) }
        return rec + list.filter { !rec.contains($0) }
    }

    // MARK: Welcome screen content

    /// One fact under the welcome's suggestions: an icon from the page's set (icons.js) and its text.
    private static func stat(_ icon: String, _ text: String) -> JSON { ["icon": .string(icon), "text": .string(text)] }

    func welcomePayload(mode: TeachingMode = .tutor) -> JSON {
        let name = settings.value.learnerName
        if mode == .language {
            let profiles = services.study.languageProfiles().filter { $0.role == "target" }
            let learning = profiles.map { p in "\(Languages.englishName(p.code))\(p.level.map { " (\($0))" } ?? "")" }.joined(separator: ", ")
            var sug: [JSON] = [
                ["title": "Place my level", "subtitle": "A few quick questions, then a plan", "prompt": .string("I want to learn \(profiles.first.map { Languages.englishName($0.code) } ?? "a new language"). Place my level with a short graded test that gets harder, then set my profile and propose where we start.")],
                ["title": "Conversation practice", "subtitle": "A role-play with my lines hidden", "prompt": "Let's do a role-play dialogue at my level (ordering food, asking the way). Use a dialogue block where I play one role, then quiz me on what we used."],
                ["title": "Dictation", "subtitle": "Listen, type what you hear", "prompt": "Give me a dictation exercise at my level: a few short sentences I listen to and type, graded strictly, then explain my mistakes."],
                ["title": "Review my words", "subtitle": "Due vocabulary, used in new sentences", "prompt": "Review the vocabulary that's due, used in new sentences and short questions rather than as a list."],
            ]
            if profiles.isEmpty { sug.insert(["title": "Start from zero", "subtitle": "Sounds, script and first phrases", "prompt": "I'm a complete beginner. Ask me which language and why, then start with the sounds, the script (with the on-screen keyboard) and the first useful phrases."], at: 0) }
            return ["title": .string(profiles.isEmpty ? "Which language are we learning?" : "Back to \(learning)?"),
                    "subtitle": "Say the language and how far along you are. The mentor places you, shows the keyboard for its script, and keeps the words you learn for review.",
                    "suggestions": .array(sug), "stats": .array(profiles.map { p in let v = services.study.vocabStats(lang: p.code); return Self.stat("languages", "\(Languages.englishName(p.code)): \(v.total) words, \(v.due) due") })]
        }
        if mode == .code {
            var stats = [Self.stat("folder", "\(workspace.name) · \(access(for: workspace).title)")]
            if let p = ProjectStore.load(workspace), let title = p.title {
                let state = p.isOpen ? (p.lastRun.map { "\($0.passed)/\($0.passed + $0.failed) passing" } ?? "open") : p.parkedAt != nil ? "put aside" : "passed"
                stats.insert(Self.stat("flask", "\(title) · \(state)"), at: 0)
            }
            return ["title": "What shall we build or learn?",
                    "subtitle": "Projects with tests sized to you, reviews like a demanding senior engineer, and the real source when you ask how something works. Your code stays yours.",
                    "suggestions": [
                        ["title": "Practise with a project", "subtitle": "Starter files and tests, sized to you", "prompt": "Give me a small coding project to practise, sized to my level, with tests I can run. Ask me one question about what I know first if you need to."],
                        ["title": "Review my code", "subtitle": "Line-level feedback, no rewrite", "prompt": "Review the code in this folder like a demanding senior engineer: point at lines and ask questions, but don't rewrite it for me."],
                        ["title": "Debug with me", "subtitle": "Find the cause, not just the fix", "prompt": "I have a bug. Help me find its cause step by step, without fixing it for me."],
                        ["title": "How does it work inside?", "subtitle": "Read a library's real source", "prompt": "Explain how Python's dict works inside, using the real CPython source and small experiments I can run."],
                        ["title": "Learn a new language", "subtitle": "From one you already know", "prompt": "Teach me Rust starting from what I already know in Python, with small runnable examples."],
                        ["title": "Build a data structure", "subtitle": "From scratch, with tests", "prompt": "Teach me a data structure by having me build it from scratch with tests, one method at a time."],
                    ],
                    "stats": .array(stats)]
        }
        var stats: [JSON] = []
        let streak = services.study.streakDays()
        if streak > 0 { stats.append(Self.stat("flame", "\(streak)-day streak")) }
        if dueCount > 0 { stats.append(Self.stat("cards", "\(dueCount) cards due")) }
        if memoryCount > 0 { stats.append(Self.stat("brain", "\(memoryCount) \(memoryCount == 1 ? "memory" : "memories")")) }
        let mastered = services.study.allMastery().filter(\.mastered).count
        if mastered > 0 { stats.append(Self.stat("check-circle", "\(mastered) concepts mastered")) }
        stats.append(Self.stat("folder", "\(workspace.name) · \(access(for: workspace).title)"))
        var suggestions: [JSON] = [
            ["title": "Learn something new", "subtitle": "Start from what I know and build up", "prompt": "I'd like to learn something new. Ask me a couple of quick questions to find the right starting point, then teach me step by step."],
            ["title": "Explain with a diagram", "subtitle": "How does the internet route a packet?", "prompt": "Explain how a packet travels across the internet from my laptop to a web server. Use a mermaid diagram."],
            ["title": "Practise calculus", "subtitle": "Derivatives with plots and a quiz", "prompt": "Teach me the intuition behind derivatives with a plot, then give me a short quiz."],
            ["title": "Learn a language", "subtitle": "Arabic basics with pronunciation", "prompt": "Teach me five everyday Arabic greetings with pronunciation, then check me with a few questions."],
            ["title": "Study this folder", "subtitle": "Read my files and teach from them", "prompt": "Look through the files in this folder and suggest how you could help me learn from them."],
            ["title": "Today's news, explained", "subtitle": "Live web search with sources", "prompt": "Search the web for one important science or technology story from this week and explain it to me with sources."],
        ]
        if isQuick(workspace) { suggestions.removeAll { $0["title"]?.string == "Study this folder" } }
        // The course in progress comes first: one click picks it up where the board says (linked before the first message).
        if let b = services.study.plans().lazy.map(CourseBoard.init(plan:)).first(where: { b in
            b.doneCount < b.courseCount && BoardSystem.applies(to: b.mode.flatMap(TeachingMode.init(rawValue:)) ?? .tutor)
        }) {
            let where_ = b.focus.map { "\($0.id.uppercased()) \($0.title)" } ?? "the next card"
            suggestions.insert(["title": .string("Continue: \(b.title)"), "subtitle": .string("\(b.doneCount) of \(b.courseCount) done · next: \(where_)"),
                                "prompt": .string("Let's continue my course \"\(b.title)\". Pick up from the board: " + (b.focus.map { f in "the focus is \(f.title)" + (f.next.map { ", next: \($0)" } ?? "") } ?? "start the next card") + "."),
                                "board": .string(b.id)], at: 0)
        }
        if dueCount > 0 {
            suggestions.insert(["title": "Review weak spots", "subtitle": .string("\(dueCount) flashcards due + targeted practice"), "prompt": "Look at my mastery and memory, find my weakest concepts and give me targeted practice with a quiz."], at: 0)
        }
        return ["title": .string(name.isEmpty ? "What would you like to learn today?" : "Hi \(name) — what shall we learn today?"),
                "subtitle": "Ask anything. I can explain, quiz you, draw diagrams, plot functions, run code and search the web.",
                "suggestions": .array(Array(suggestions.prefix(6))), "stats": .array(stats)]
    }
}
