import Foundation

/// Another configured provider a sub-agent may use, with the models it accepts.
struct AgentProvider: Sendable {
    let id: String
    let name: String
    /// Accepted model ids: the fetched, tool-capable list (free-only unless paid models are allowed), else its suggestions.
    let models: [String]
    let defaultModel: String
}

/// What sub-agents need from the app beyond the lesson's own client: other providers, limits, and the lesson's grants
/// and folder. The app passes one per lesson (`AppAgentHost`); without one (the CLI, tests) runs use the lesson's
/// client and model with default limits and read-only grants (`LessonOnlyHost`).
protocol AgentHost: Sendable {
    /// The lesson's provider id ("" when unknown).
    var lessonProvider: String { get }
    var folder: URL { get }
    var isCodeMode: Bool { get }
    /// The lesson runs on a free model: its sub-agents may only use models known to be free.
    var lessonFree: Bool { get }
    func limits() async -> SubAgentSettings
    func grants() async -> LessonGrants
    /// Other providers with a key (the lesson's own models come with the tool context).
    func providers() async -> [AgentProvider]
    func client(_ providerID: String) async -> LLMClient?
    func modelInfo(_ providerID: String, _ model: String) async -> ModelInfo?
    func maxOutput(_ providerID: String, _ model: String) async -> Int
    /// A retired model id → the one that now serves it (ProviderConfig.currentModel).
    func currentModel(_ providerID: String, _ model: String) async -> String
}

extension AgentHost {
    func currentModel(_ providerID: String, _ model: String) async -> String { model }
    var lessonFree: Bool { false }
}

struct LessonOnlyHost: AgentHost {
    let folder: URL
    var settings = SubAgentSettings()
    var lessonGrants = LessonGrants()
    var isCodeMode = false
    var lessonProvider: String { "" }
    func limits() async -> SubAgentSettings { settings }
    func grants() async -> LessonGrants { lessonGrants }
    func providers() async -> [AgentProvider] { [] }
    func client(_ providerID: String) async -> LLMClient? { nil }
    func modelInfo(_ providerID: String, _ model: String) async -> ModelInfo? { nil }
    func maxOutput(_ providerID: String, _ model: String) async -> Int { 8192 }
}

/// The app's host for one lesson: settings, keys, fetched model lists and grants, read on the main actor when asked
/// (so a change in Settings applies to the next sub-agent).
struct AppAgentHost: AgentHost {
    let conversationID: String
    let lessonProvider: String
    /// The lesson's model is free: sub-agents then use free models only (delegating never adds cost the learner didn't choose).
    let lessonFree: Bool
    let folder: URL
    let isCodeMode: Bool

    func limits() async -> SubAgentSettings { await MainActor.run { AppModel.shared.settings.value.agents } }

    func grants() async -> LessonGrants {
        await MainActor.run {
            let app = AppModel.shared, s = app.settings.value
            let quick = folder.standardizedFileURL.path == AppPaths.quickFolder.standardizedFileURL.path
            return LessonGrants(access: s.folderAccess[folder.path] ?? (quick ? .full : .read),   // as AppModel.access(for:)
                                granted: Set(["write", "bash", "run_code", "python"].filter { app.interactions.isGranted($0, conversationID: conversationID) }),
                                python: s.python, disabled: Set(s.disabledTools))
        }
    }

    func providers() async -> [AgentProvider] {
        await MainActor.run {
            let app = AppModel.shared, limits = app.settings.value.agents
            guard limits.otherProviders else { return [] }
            let freeOnly = lessonFree || !limits.paidModels
            return app.availableProviders.filter { $0.id != lessonProvider }.compactMap { p -> AgentProvider? in
                app.loadModels(p)                  // fetched once a day; the cached list is used meanwhile
                _ = app.modelInfo(p.id, "")        // loads the cached metadata
                let models = Self.allowed(meta: app.modelMeta[p.id] ?? [:], suggested: app.modelList(p), freeOnly: freeOnly)
                return models.isEmpty ? nil : AgentProvider(id: p.id, name: p.name, models: models, defaultModel: p.defaultModel)
            }
        }
    }

    /// A provider's models a sub-agent may use: the fetched tool-capable ones (the suggestions before a list exists);
    /// free-only keeps those whose metadata says free, or whose id says `:free` — never one whose price is unknown.
    static func allowed(meta: [String: ModelInfo], suggested: [String], freeOnly: Bool) -> [String] {
        let models = meta.isEmpty ? suggested : meta.values.filter { $0.tools != false }.map(\.id).sorted()
        return freeOnly ? models.filter { meta[$0]?.free == true || $0.hasSuffix(":free") } : models
    }

    func client(_ providerID: String) async -> LLMClient? {
        await MainActor.run { AppModel.shared.settings.provider(providerID).map { $0.client(apiKey: KeyStore.shared.key(for: $0)) } }
    }
    func currentModel(_ providerID: String, _ model: String) async -> String {
        await MainActor.run { AppModel.shared.settings.provider(providerID)?.currentModel(model) ?? model }
    }
    func modelInfo(_ providerID: String, _ model: String) async -> ModelInfo? {
        await MainActor.run { AppModel.shared.modelInfo(providerID, model) }
    }
    func maxOutput(_ providerID: String, _ model: String) async -> Int {
        await MainActor.run {
            let app = AppModel.shared
            guard let p = app.settings.provider(providerID) else { return 8192 }
            return ChatSession.maxTokens(provider: p, model: model, info: app.modelInfo(providerID, model))
        }
    }
}

extension ChatSession {
    /// The sub-agent host for this lesson's tool calls.
    var agentHost: AppAgentHost {
        // TaskTool.timeout reads the limits and the types' budgets before the call runs.
        SubAgent.remember(settings.agents, types: AgentCatalog.all(app: settings.agents.definitions, folder: services.workspace.url))
        let info = app.modelInfo(conversation.providerID, conversation.model)
        return AppAgentHost(conversationID: id, lessonProvider: conversation.providerID,
                            lessonFree: info?.free == true || conversation.model.hasSuffix(":free"),
                            folder: services.workspace.url, isCodeMode: conversation.mode.isAgent)
    }

    /// `task` as this lesson sends it: the lesson provider's models, other providers, the agent types (built-in,
    /// Settings, the folder's `.teacher/agents`) and the limits from Settings → Agents.
    func taskSpec() -> ToolSpec {
        let limits = settings.agents
        let others = limits.otherProviders ? app.availableProviders.filter { $0.id != conversation.providerID }.map(\.id) : []
        return TaskTool.spec(models: subAgentModels(), current: conversation.model, provider: conversation.providerID, others: others,
                             types: AgentCatalog.all(app: limits.definitions, folder: services.workspace.url), limits: limits,
                             codeMode: conversation.mode.isAgent)
    }
}
