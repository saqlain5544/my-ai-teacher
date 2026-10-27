import Foundation
import Combine

struct AppSettings: Codable, Sendable, Equatable {
    var providerID = "minimax"
    var model = "MiniMax-M3"
    /// High by default: lessons get the model's best work (Settings › General lowers it).
    var thinking: ThinkingLevel = .medium
    /// Access granted per folder path. Folders not listed are read-only. Stored in the app, never in the folder.
    var folderAccess: [String: FolderAccess] = [:]
    var recentFolders: [WorkspaceRef] = []
    var lastFolder: String?
    var autoMemory = true
    /// Plan → research → verify for substantial requests (`DeepWork`).
    var deepWork = true
    var memoryProviderID: String?
    var memoryModel: String?
    var workspacePath: String = AppPaths.workspace.path   // default folder
    var fontSize: Double = 15
    var customProviders: [ProviderConfig] = []
    var disabledTools: [String] = []
    /// Tool steps one reply may take; 0 = no limit (the default). The learner can set one in Settings.
    var maxToolTurns = 0
    /// Quizzes and tests. Off: the teacher teaches without testing until the learner turns them back on (toolbar).
    /// Quiz and Exam prep modes always test.
    var quizzes = true
    /// How the teacher keeps long-term state for goals that span many replies: `BoardSystem` arms
    /// ("nested": cards with book-style outlines, "shallow": cards only, "off": no board).
    var courseBoard = "nested"
    /// The learner's edits to the agents' instructions (`Instructions.Key.raw` → text); absent = the default.
    var instructions: [String: String] = [:]
    var learnerName: String = ""
    var learnerLevel: String = ""
    var voiceIdentifier: String?
    var speechRate: Double = 0.5
    /// Who speaks the target language: "auto" (the Mac's Enhanced/Premium voice, else the open-source voice when
    /// installed, else the Mac's compact voice), "apple", or "open" (the open-source voice whenever it has the language).
    var speechOutput = "auto"
    /// Who hears the learner: "auto" (Apple on device, else Whisper when installed, else Apple online), "whisper", "online".
    var speechInput = "auto"
    /// Context budget in tokens; 0 = automatic (half the model's window, up to 400k: `ContextPolicy.budget`).
    var compactAtTokens = 0
    var showThinking = true
    var python: PythonPolicy = .allow   // run_code (python) and math (SymPy)
    var agents = SubAgentSettings()     // sub-agent limits, defaults and app-level agent types
    /// Sites the agent's browser may always use, and Mac apps (bundle ids) it may always control. Per-lesson grants live in
    /// InteractionCenter; localhost and file:// are never stored here (they're approved per lesson).
    var browserSites: [String] = []
    var computerApps: [String] = []
    /// Commands approved with "Always allow in this folder" (folder path → command prefixes like `npm test`), as Claude
    /// Code's `Bash(npm test:*)` rules. Stored in the app, never in the folder (a cloned repo can't pre-approve itself).
    var commandRules: [String: [String]] = [:]
    /// The user's own MCP servers (Settings → MCP), for the code agent in every folder.
    var mcpServers: [MCPServerConfig] = []
    /// A folder's `.mcp.json` servers the user approved or declined (folder path → server name → the config they saw).
    /// Stored in the app, never in the folder: a cloned repo can't approve its own servers.
    var mcpProjectDecisions: [String: [String: MCPDecision]] = [:]
    /// MCP servers whose tools run without asking, per folder (folder path → server names).
    var mcpAlwaysAllow: [String: [String]] = [:]
    /// The user's own hooks for the code agent: Claude Code's `hooks` JSON (event → matchers → shell commands), as typed
    /// in Settings › Hooks (`HooksExtension`).
    var hooks = ""
    /// Folders whose own hooks (`.claude/settings.json`) the user approved: folder path → the approved configuration's
    /// fingerprint. Stored in the app, never in the folder, so a cloned repo can't approve itself, and a change asks again.
    var approvedHooks: [String: String] = [:]
    /// The build that last had Screen Recording + Accessibility: macOS resets both when an ad-hoc signed app is rebuilt.
    var computerPermissionBuild: String?

    init() {}
    init(from decoder: Decoder) throws {
        // Tolerant decoding so new fields never break old settings files.
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = AppSettings()
        providerID = (try? c.decode(String.self, forKey: .providerID)) ?? d.providerID
        model = (try? c.decode(String.self, forKey: .model)) ?? d.model
        thinking = (try? c.decode(ThinkingLevel.self, forKey: .thinking)) ?? d.thinking
        folderAccess = (try? c.decode([String: FolderAccess].self, forKey: .folderAccess)) ?? [:]
        recentFolders = (try? c.decode([WorkspaceRef].self, forKey: .recentFolders)) ?? []
        lastFolder = try? c.decode(String.self, forKey: .lastFolder)
        autoMemory = (try? c.decode(Bool.self, forKey: .autoMemory)) ?? d.autoMemory
        deepWork = (try? c.decode(Bool.self, forKey: .deepWork)) ?? d.deepWork
        memoryProviderID = try? c.decode(String.self, forKey: .memoryProviderID)
        memoryModel = try? c.decode(String.self, forKey: .memoryModel)
        workspacePath = (try? c.decode(String.self, forKey: .workspacePath)) ?? d.workspacePath
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
        customProviders = (try? c.decode([ProviderConfig].self, forKey: .customProviders)) ?? []
        disabledTools = (try? c.decode([String].self, forKey: .disabledTools)) ?? []
        // 40 was the old default, saved into every settings file: it means "never chosen", so it becomes no limit.
        let savedSteps = (try? c.decode(Int.self, forKey: .maxToolTurns)) ?? d.maxToolTurns
        maxToolTurns = savedSteps == 40 ? 0 : max(0, savedSteps)
        quizzes = (try? c.decode(Bool.self, forKey: .quizzes)) ?? d.quizzes
        courseBoard = (try? c.decode(String.self, forKey: .courseBoard)).flatMap { BoardSystem.arms.contains($0) ? $0 : nil } ?? d.courseBoard
        learnerName = (try? c.decode(String.self, forKey: .learnerName)) ?? ""
        learnerLevel = (try? c.decode(String.self, forKey: .learnerLevel)) ?? ""
        voiceIdentifier = try? c.decode(String.self, forKey: .voiceIdentifier)
        speechRate = (try? c.decode(Double.self, forKey: .speechRate)) ?? d.speechRate
        speechOutput = (try? c.decode(String.self, forKey: .speechOutput)) ?? d.speechOutput
        speechInput = (try? c.decode(String.self, forKey: .speechInput)) ?? d.speechInput
        let savedBudget = (try? c.decode(Int.self, forKey: .compactAtTokens)) ?? d.compactAtTokens
        // The old fixed defaults (120k, then 48k) become automatic; anything else the learner chose stays, within the stepper's range.
        compactAtTokens = [0, 48_000, 120_000].contains(savedBudget) ? 0 : min(max(savedBudget, 20_000), 900_000)
        showThinking = (try? c.decode(Bool.self, forKey: .showThinking)) ?? true
        python = (try? c.decode(PythonPolicy.self, forKey: .python)) ?? d.python
        agents = (try? c.decode(SubAgentSettings.self, forKey: .agents)) ?? d.agents
        browserSites = (try? c.decode([String].self, forKey: .browserSites)) ?? []
        computerApps = (try? c.decode([String].self, forKey: .computerApps)) ?? []
        commandRules = (try? c.decode([String: [String]].self, forKey: .commandRules)) ?? [:]
        mcpServers = (try? c.decode([MCPServerConfig].self, forKey: .mcpServers)) ?? []
        mcpProjectDecisions = (try? c.decode([String: [String: MCPDecision]].self, forKey: .mcpProjectDecisions)) ?? [:]
        mcpAlwaysAllow = (try? c.decode([String: [String]].self, forKey: .mcpAlwaysAllow)) ?? [:]
        hooks = (try? c.decode(String.self, forKey: .hooks)) ?? ""
        approvedHooks = (try? c.decode([String: String].self, forKey: .approvedHooks)) ?? [:]
        computerPermissionBuild = try? c.decode(String.self, forKey: .computerPermissionBuild)
        instructions = (try? c.decode([String: String].self, forKey: .instructions)) ?? [:]
    }
}

/// Whether the teacher may run Python (code and SymPy math). Package installs are never allowed.
enum PythonPolicy: String, Codable, CaseIterable, Identifiable, Sendable {
    case allow, ask, off
    var id: String { rawValue }
    var title: String {
        switch self {
        case .allow: "Run without asking"
        case .ask: "Ask before each run"
        case .off: "Off"
        }
    }
}

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet { if value != oldValue { scheduleSave() } }
    }
    private var saveWork: DispatchWorkItem?

    init() {
        if let data = try? Data(contentsOf: AppPaths.settings), let s = try? JSONDecoder().decode(AppSettings.self, from: data) {
            value = s
        } else {
            value = AppSettings()
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let snapshot = value
        let w = DispatchWorkItem {
            let enc = JSONEncoder(); enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            if let d = try? enc.encode(snapshot) { try? d.write(to: AppPaths.settings, options: .atomic) }
        }
        saveWork = w
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.4, execute: w)
    }

    var providers: [ProviderConfig] { ProviderCatalog.presets + value.customProviders }
    func provider(_ id: String) -> ProviderConfig? { providers.first { $0.id == id } }
    var defaultFolder: URL {
        let u = URL(fileURLWithPath: (value.workspacePath as NSString).expandingTildeInPath, isDirectory: true)
        try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
        return u
    }
}

/// Bridges tools that must wait for the learner (approvals, quizzes, questions) with the transcript UI.
@MainActor
final class InteractionCenter: ObservableObject {
    struct Pending: Identifiable {
        let id: String          // tool call id
        let kind: String        // permission | quiz | ask
        let conversationID: String
        let payload: JSON
    }
    @Published private(set) var pending: [String: Pending] = [:]
    private var continuations: [String: CheckedContinuation<JSON, Never>] = [:]
    /// Per-conversation "always allow" grants for risky tools.
    private var grants: [String: Set<String>] = [:]

    var onChange: ((Pending, Bool) -> Void)?

    /// Waits for the learner's answer. A cancelled task gets `{"cancelled": true}` at once, and its card goes: only an
    /// explicit `cancelAll` used to end a wait, so a task cancelled any other way (a stopped sub-agent, a closed lesson)
    /// waited forever with its card still open.
    func request(id: String, kind: String, conversationID: String, payload: JSON) async -> JSON {
        if Task.isCancelled { return ["cancelled": true] }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                // A second request under the same id would orphan the first waiter (never resumed): it is cancelled instead.
                if continuations[id] != nil { resolve(id, ["cancelled": true]) }
                continuations[id] = c
                let p = Pending(id: id, kind: kind, conversationID: conversationID, payload: payload)
                pending[id] = p
                onChange?(p, true)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.resolve(id, ["cancelled": true]) }
        }
    }

    func resolve(_ id: String, _ value: JSON) {
        guard let c = continuations.removeValue(forKey: id) else { return }
        if let p = pending.removeValue(forKey: id) { onChange?(p, false) }
        c.resume(returning: value)
    }

    func cancelAll(conversationID: String) {
        for (id, p) in pending where p.conversationID == conversationID {
            resolve(id, ["cancelled": true])
        }
    }

    func isGranted(_ tool: String, conversationID: String) -> Bool { grants[conversationID]?.contains(tool) ?? false }
    func grant(_ tool: String, conversationID: String) { grants[conversationID, default: []].insert(tool) }
}
