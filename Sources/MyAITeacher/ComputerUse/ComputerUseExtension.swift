import Foundation

/// The learner's grants for an agent's browser and Mac control, and the approval cards built on them:
/// - browser: each site once per task, per lesson or always (localhost, the local network, files and data: pages never
///   "always"); a frame of another origin is a site of its own; every download; JavaScript on its own card;
/// - Mac apps: `request_access`, `open_app` and `focus_app` name the apps, approved with their tiers (per lesson or
///   always); pixel actions are then checked against the frontmost app when they run, before every event.
/// The browser and the controller read their grants from here, so what the cards grant is what they enforce.
@MainActor
final class ComputerUseGate {
    /// Where grants live: the app's settings and InteractionCenter in the app, dictionaries in tests.
    struct Store {
        var lessonGranted: (_ key: String, _ conversation: String) -> Bool
        var grantLesson: (_ key: String, _ conversation: String) -> Void
        var alwaysSites: () -> [String]
        var addAlwaysSite: (String) -> Void
        var alwaysApps: () -> [String]
        var addAlwaysApp: (String) -> Void
    }

    var store: Store
    let browser: AgentBrowser
    let computer: ComputerController
    /// "Allow for this task": until the turn ends.
    private var taskGrants: [String: Set<String>] = [:]

    init(store: Store, browser: AgentBrowser, computer: ComputerController) {
        self.store = store
        self.browser = browser
        self.computer = computer
        browser.siteAllowed = { [weak self] site, conv in self?.siteAllowed(site, conv: conv) ?? false }
        computer.isGranted = { [weak self] bundle, conv in self?.appGranted(bundle, conv: conv) ?? false }
    }

    func siteAllowed(_ site: SiteKey, conv: String) -> Bool {
        let key = "site:" + site.id
        return taskGrants[conv]?.contains(key) == true || store.lessonGranted(key, conv) || (!site.isLocal && store.alwaysSites().contains(site.id))
    }

    func appGranted(_ bundle: String, conv: String) -> Bool { store.alwaysApps().contains(bundle) || store.lessonGranted("app:" + bundle, conv) }

    /// The turn is over: task grants lapse.
    func endTurn(_ conv: String) { taskGrants[conv] = nil }

    func decide(tool: String, input: JSON, conv: String, folder: URL) -> ToolDecision {
        switch tool {
        case "browser": browserDecision(input, conv: conv, folder: folder)
        case "mac": appsDecision(input, conv: conv)
        default: .allow
        }
    }

    // MARK: Browser

    private func browserDecision(_ input: JSON, conv: String, folder: URL) -> ToolDecision {
        let action = input["action"]?.string ?? ""
        if ["tabs", "switch_tab", "close_tab", "dialog"].contains(action) || (action == "new_tab" && input["url"] == nil) { return .allow }   // content is gated in the tool
        if action == "download" { return downloadDecision(input, folder: folder) }
        let tab = browser.tab(input["tab"]?.int)
        let target = AgentBrowser.parseRef(input["ref"]?.string)
        // What the call reaches: the address being opened, or the page, and the frame a ref points into.
        var sites: [(SiteKey, URL?)] = []
        if ["navigate", "new_tab"].contains(action) {
            if let u = AgentBrowser.parseURL(input["url"]?.string), let s = SiteKey.of(u) { sites.append((s, u)) }
        } else if let tab {
            if let s = tab.site { sites.append((s, tab.web.url)) }
            if let f = target?.frame, let s = tab.frameSite(f) { sites.append((s, tab.frame(f)?.request.url)) }
        }
        if action == "fill" {
            for f in input["fields"]?.array ?? [] {
                if let fr = AgentBrowser.parseRef(f["ref"]?.string)?.frame, let tab, let s = tab.frameSite(fr) { sites.append((s, tab.frame(fr)?.request.url)) }
            }
        }
        let decision = chain(sites, conv: conv)
        guard action == "evaluate", let site = sites.first?.0 else { return decision }
        // JavaScript runs in the page with the learner's session: its own card, after the site's.
        return then(decision) { [weak self] in self?.jsDecision(site, js: input["js"]?.string ?? input["text"]?.string ?? "", conv: conv) ?? .deny("Closed.") }
    }

    /// Each site in turn: an approval card resolves into the next site's decision, so one call never slips past a frame.
    private func chain(_ sites: [(SiteKey, URL?)], conv: String) -> ToolDecision {
        guard let (site, url) = sites.first else { return .allow }
        let rest = Array(sites.dropFirst())
        return then(siteDecision(site, url: url, conv: conv)) { [weak self] in self?.chain(rest, conv: conv) ?? .deny("Closed.") }
    }

    /// `d`, and once it allows, `next`.
    private func then(_ d: ToolDecision, _ next: @escaping @MainActor @Sendable () -> ToolDecision) -> ToolDecision {
        switch d {
        case .allow: return next()
        case .deny: return d
        case .ask(let req, let resolve): return .ask(req) { choice in self.then(resolve(choice), next) }
        case .pending(let decide): return .pending { self.then(await decide(), next) }
        }
    }

    private func siteDecision(_ site: SiteKey, url: URL?, conv: String) -> ToolDecision {
        if siteAllowed(site, conv: conv) { return .allow }
        let what = site.id == "data:" ? "use a page made from a data: URL" : site.id.hasPrefix("file:") ? "open files in \(site.id.dropFirst(5))"
            : site.isLocal ? "use \(site.id) (this Mac or your local network)" : "use \(site.id)"
        var options = [ApprovalOption(id: "lesson", label: "Allow for this lesson", style: .primary)]
        if !site.isLocal { options.append(ApprovalOption(id: "always", label: "Always allow \(site.id)")) }
        options += [ApprovalOption(id: "task", label: "Allow for this task"), ApprovalOption(id: "deny", label: "Deny", style: .danger)]
        return .ask(ApprovalRequest(
            title: "Allow Teacher to \(what) in its browser?",
            detail: (url?.absoluteString ?? site.label) + "\nTeacher can read the page and click, type and submit forms there. It never types passwords, payment details or ID numbers, never uploads files, and asks before downloading.",
            options: options)) { [weak self] choice in
            guard let self else { return .deny("Closed.") }
            switch choice {
            case "lesson": self.store.grantLesson("site:" + site.id, conv); return .allow
            case "always" where !site.isLocal: self.store.addAlwaysSite(site.id); return .allow
            case "task", "once": self.taskGrants[conv, default: []].insert("site:" + site.id); return .allow
            default: return .deny("The learner declined \(site.label).")
            }
        }
    }

    private func jsDecision(_ site: SiteKey, js: String, conv: String) -> ToolDecision {
        if store.lessonGranted("js:" + site.id, conv) { return .allow }
        return .ask(ApprovalRequest(
            title: "Allow Teacher to run JavaScript on \(site.label)?",
            detail: String(js.prefix(4000)),
            options: [ApprovalOption(id: "once", label: "Run once", style: .primary), ApprovalOption(id: "lesson", label: "Allow on \(site.label) for this lesson"),
                      ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
            guard let self, choice != "deny" else { return .deny("The learner declined running JavaScript.") }
            if choice == "lesson" { self.store.grantLesson("js:" + site.id, conv) }
            return .allow
        }
    }

    /// Every download asks. The page names the file, so the name stays in the card's details, never its title.
    private func downloadDecision(_ input: JSON, folder: URL) -> ToolDecision {
        guard let url = AgentBrowser.parseURL(input["url"]?.string) ?? browser.tab(input["tab"]?.int)?.blockedDownload?.url else { return .allow }
        let known = browser.tabs.compactMap(\.blockedDownload).first { $0.url == url }
        let name = AXFormat.clip((known?.name ?? url.lastPathComponent).components(separatedBy: .controlCharacters).joined(), 80)
        return .ask(ApprovalRequest(
            title: "Allow Teacher to download a file?",
            detail: "File (named by the page): \(name.isEmpty ? "unnamed" : name)\nFrom: \(url.absoluteString)\nSize: \(BrowserTab.sizeText(known?.size))\(known?.mime.map { "\nType: \($0)" } ?? "")\nSaved to: \(folder.appendingPathComponent("Downloads").path)",
            options: [ApprovalOption(id: "once", label: "Download", style: .primary), ApprovalOption(id: "deny", label: "Don't download", style: .danger)])) { choice in
            choice == "once" ? .allow : .deny("The learner declined the download.")
        }
    }

    // MARK: Mac apps

    private func appsDecision(_ input: JSON, conv: String) -> ToolDecision {
        let names: [String]
        switch input["action"]?.string ?? "" {
        case "request_access": names = input["apps"]?.array?.compactMap(\.string) ?? input["app"]?.string.map { [$0] } ?? []
        case "open_app", "focus_app": names = input["app"]?.string.map { [$0] } ?? []
        default: return .allow   // everything else is checked against the grants when it runs
        }
        let wanted = names.compactMap(AppResolver.resolve).filter { AppTier.of($0.bundleID) != .never && !appGranted($0.bundleID, conv: conv) }
        return appsCard(wanted, reason: input["reason"]?.string, conv: conv)
    }

    func appsCard(_ wanted: [AppResolver.Found], reason: String?, conv: String) -> ToolDecision {
        guard !wanted.isEmpty else { return .allow }
        let lines = wanted.map { "• \($0.name) — \(AppTier.of($0.bundleID).title)" }
        return .ask(ApprovalRequest(
            title: "Allow Teacher to use \(wanted.count == 1 ? wanted[0].name : "\(wanted.count) apps") on your Mac?",
            detail: lines.joined(separator: "\n") + (reason.map { "\n\nWhy: " + $0 } ?? "")
                + "\n\nTeacher sees only these apps in screenshots. A banner shows while it is in control; press Esc twice or Stop to take over.",
            options: [ApprovalOption(id: "lesson", label: "Allow for this lesson", style: .primary), ApprovalOption(id: "always", label: "Always allow"),
                      ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
            guard let self, choice != "deny" else { return .deny("The learner declined access to \(wanted.map(\.name).joined(separator: ", ")).") }
            for f in wanted {
                if choice == "always" { if !self.store.alwaysApps().contains(f.bundleID) { self.store.addAlwaysApp(f.bundleID) } }
                else { self.store.grantLesson("app:" + f.bundleID, conv) }
            }
            return .allow
        }
    }

    /// One failed computer action ends its batch: the rest of that step's computer calls are answered without running.
    func skipRest(after callID: String, in step: ChatMessage) {
        let later = step.toolUses.drop { $0.id != callID }.dropFirst().filter { $0.name == "computer" }.compactMap(\.id)
        computer.skipped.formUnion(later)
    }
}

/// Plugs the gate into the agent loop, through the same cards as file and command approvals. Also: Claude on
/// api.anthropic.com gets Anthropic's native computer-use tool, and control (and task grants) end with the turn.
@MainActor
final class ComputerUseExtension: AgentExtension {
    let id = "computer-use"
    unowned let app: AppModel
    let gate: ComputerUseGate

    init(app: AppModel) {
        self.app = app
        gate = ComputerUseGate(store: ComputerUseGate.Store(
            lessonGranted: { [unowned app] key, conv in app.interactions.isGranted(key, conversationID: conv) },
            grantLesson: { [unowned app] key, conv in app.interactions.grant(key, conversationID: conv) },
            alwaysSites: { [unowned app] in app.settings.value.browserSites },
            addAlwaysSite: { [unowned app] s in if !app.settings.value.browserSites.contains(s) { app.settings.value.browserSites.append(s) } },
            alwaysApps: { [unowned app] in app.settings.value.computerApps },
            addAlwaysApp: { [unowned app] b in app.settings.value.computerApps.append(b) }), browser: AgentBrowser.shared, computer: ComputerController.shared)
        let c = ComputerController.shared
        c.onStop = { [unowned app] conv in app.session(for: conv)?.stop() }
        c.permissionBuild = ({ [unowned app] in app.settings.value.computerPermissionBuild },
                             { [unowned app] v in if app.settings.value.computerPermissionBuild != v { app.settings.value.computerPermissionBuild = v } })
        AgentBrowser.onShow = { [unowned app] in
            guard app.inspectorTab != .browser || !app.inspectorShown else { return }
            app.inspectorTab = .browser; app.inspectorShown = true
        }
    }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        gate.decide(tool: tool.name, input: call.input ?? .object([:]), conv: session.id, folder: session.services.workspace.url)
    }

    /// Claude on Anthropic's own API: the native computer-use tool replaces the generic schema (same actions, so the
    /// same `computer` tool runs it). Other providers keep the generic one.
    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        guard let i = request.tools.firstIndex(where: { $0.name == "computer" }),
              let p = app.settings.provider(session.conversation.providerID), p.api == .anthropic, p.baseURL.contains("api.anthropic.com"),
              let native = NativeComputerTool.spec(model: request.model, display: NativeComputerTool.displaySize) else { return }
        request.tools[i].native = native.json
        request.tools[i].nativeBeta = native.beta
    }

    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard call.name == "computer", result.isError == true, let id = call.id,
              let step = session.messages.last(where: { $0.role == .assistant && $0.toolUses.contains { $0.id == id } }) else { return }
        gate.skipRest(after: id, in: step)
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        ComputerController.shared.end(session.id)
        gate.endTurn(session.id)
    }
    func sessionWillClose(_ session: ChatSession) {
        ComputerController.shared.end(session.id)
        gate.endTurn(session.id)
    }
}
