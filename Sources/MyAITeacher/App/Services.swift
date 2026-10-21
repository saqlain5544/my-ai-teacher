import Foundation
import Combine

struct AppSettings: Codable, Sendable, Equatable {
    var providerID = "minimax"
    var model = "MiniMax-M3"
    var thinking: ThinkingLevel = .medium
    /// Access granted per folder path. Folders not listed are read-only. Stored in the app, never in the folder.
    var folderAccess: [String: FolderAccess] = [:]
    var recentFolders: [WorkspaceRef] = []
    var lastFolder: String?
    var autoMemory = true
    var memoryProviderID: String?
    var memoryModel: String?
    var workspacePath: String = AppPaths.workspace.path   // default folder
    var fontSize: Double = 15
    var customProviders: [ProviderConfig] = []
    var disabledTools: [String] = []
    var maxToolTurns = 40
    var learnerName: String = ""
    var learnerLevel: String = ""
    var voiceIdentifier: String?
    var speechRate: Double = 0.5
    var compactAtTokens = 48_000   // context budget (tokens)
    var showThinking = true
    var python: PythonPolicy = .allow   // run_code (python) and math (SymPy)
    var experiments = true              // local A/B experiments (see Experiments)
    var agents = SubAgentSettings()     // sub-agent limits, defaults and app-level agent types
    /// Sites the agent's browser may always use, and Mac apps (bundle ids) it may always control. Per-lesson grants live in
    /// InteractionCenter; localhost and file:// are never stored here (they're approved per lesson).
    var browserSites: [String] = []
    var computerApps: [String] = []
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
        memoryProviderID = try? c.decode(String.self, forKey: .memoryProviderID)
        memoryModel = try? c.decode(String.self, forKey: .memoryModel)
        workspacePath = (try? c.decode(String.self, forKey: .workspacePath)) ?? d.workspacePath
        fontSize = (try? c.decode(Double.self, forKey: .fontSize)) ?? d.fontSize
        customProviders = (try? c.decode([ProviderConfig].self, forKey: .customProviders)) ?? []
        disabledTools = (try? c.decode([String].self, forKey: .disabledTools)) ?? []
        maxToolTurns = (try? c.decode(Int.self, forKey: .maxToolTurns)) ?? d.maxToolTurns
        learnerName = (try? c.decode(String.self, forKey: .learnerName)) ?? ""
        learnerLevel = (try? c.decode(String.self, forKey: .learnerLevel)) ?? ""
        voiceIdentifier = try? c.decode(String.self, forKey: .voiceIdentifier)
        speechRate = (try? c.decode(Double.self, forKey: .speechRate)) ?? d.speechRate
        let savedBudget = (try? c.decode(Int.self, forKey: .compactAtTokens)) ?? d.compactAtTokens
        compactAtTokens = savedBudget == 120_000 ? d.compactAtTokens : min(savedBudget, 400_000)   // migrate the old default
        showThinking = (try? c.decode(Bool.self, forKey: .showThinking)) ?? true
        python = (try? c.decode(PythonPolicy.self, forKey: .python)) ?? d.python
        experiments = (try? c.decode(Bool.self, forKey: .experiments)) ?? d.experiments
        agents = (try? c.decode(SubAgentSettings.self, forKey: .agents)) ?? d.agents
        browserSites = (try? c.decode([String].self, forKey: .browserSites)) ?? []
        computerApps = (try? c.decode([String].self, forKey: .computerApps)) ?? []
        computerPermissionBuild = try? c.decode(String.self, forKey: .computerPermissionBuild)
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

    func request(id: String, kind: String, conversationID: String, payload: JSON) async -> JSON {
        await withCheckedContinuation { c in
            continuations[id] = c
            let p = Pending(id: id, kind: kind, conversationID: conversationID, payload: payload)
            pending[id] = p
            onChange?(p, true)
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
