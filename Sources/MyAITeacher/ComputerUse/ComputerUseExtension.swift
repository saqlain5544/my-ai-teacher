import Foundation

/// Approvals for the code agent's browser and Mac control, through the same cards as file and command approvals:
/// - browser: each site once (per lesson, or always); localhost, the local network and file:// only per lesson; every
///   download; JavaScript evaluation on its own card;
/// - Mac apps: `request_access` names the apps and the learner approves them with their tiers (per lesson or always);
///   pixel actions are then checked against the frontmost app at run time, before every event.
/// Also: Claude on api.anthropic.com gets Anthropic's native computer-use tool, a failed action skips the rest of its
/// batch, and the "controlling your Mac" indicator goes away when the turn ends.
@MainActor
final class ComputerUseExtension: AgentExtension {
    let id = "computer-use"
    unowned let app: AppModel

    init(app: AppModel) {
        self.app = app
        let c = ComputerController.shared
        c.isGranted = { [unowned app] bundle, conv in
            app.settings.value.computerApps.contains(bundle) || app.interactions.isGranted("app:" + bundle, conversationID: conv)
        }
        c.onStop = { [unowned app] conv in app.session(for: conv)?.stop() }
        c.permissionBuild = ({ [unowned app] in app.settings.value.computerPermissionBuild },
                             { [unowned app] v in if app.settings.value.computerPermissionBuild != v { app.settings.value.computerPermissionBuild = v } })
        AgentBrowser.onShow = { [unowned app] in
            guard app.inspectorTab != .browser || !app.inspectorShown else { return }
            app.inspectorTab = .browser; app.inspectorShown = true
        }
    }

    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision {
        let input = call.input ?? .object([:])
        switch tool.name {
        case "browser": return browser(input, conv: session.id, folder: session.services.workspace)
        case "mac": return apps(input, conv: session.id)
        default: return .allow
        }
    }

    // MARK: Browser

    private func browser(_ input: JSON, conv: String, folder: Workspace) -> ToolDecision {
        let action = input["action"]?.string ?? ""
        if ["tabs", "switch_tab", "close_tab", "dialog"].contains(action) || (action == "new_tab" && input["url"] == nil) { return .allow }
        let b = AgentBrowser.shared
        if action == "download" {
            guard let url = AgentBrowser.parseURL(input["url"]?.string) ?? b.tab(input["tab"]?.int)?.blockedDownload?.url else { return .allow }
            let known = b.tabs.compactMap(\.blockedDownload).first { $0.url == url }
            let name = known?.name ?? (url.lastPathComponent.isEmpty ? "a file" : url.lastPathComponent)
            return .ask(ApprovalRequest(
                title: "Allow Teacher to download \(name)?",
                detail: "From: \(url.absoluteString)\nSize: \(BrowserTab.sizeText(known?.size))\(known?.mime.map { "\nType: \($0)" } ?? "")\nSaved to: \(folder.url.appendingPathComponent("Downloads").path)",
                options: [ApprovalOption(id: "once", label: "Download", style: .primary), ApprovalOption(id: "deny", label: "Don't download", style: .danger)])) { choice in
                choice == "once" ? .allow : .deny("The learner declined the download.")
            }
        }
        let url: URL? = ["navigate", "new_tab"].contains(action) ? AgentBrowser.parseURL(input["url"]?.string) : b.tab(input["tab"]?.int)?.web.url
        guard let url, let site = SiteKey.of(url) else { return .allow }
        let site_ = siteDecision(site, url: url, conv: conv)
        guard action == "evaluate" else { return site_ }
        if app.interactions.isGranted("js:" + site.id, conversationID: conv), case .allow = site_ { return .allow }
        return .ask(ApprovalRequest(
            title: "Allow Teacher to run JavaScript on \(site.label)?",
            detail: String((input["js"]?.string ?? "").prefix(4000)),
            options: [ApprovalOption(id: "once", label: "Run once", style: .primary), ApprovalOption(id: "lesson", label: "Allow on \(site.label) for this lesson"),
                      ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
            guard let self, choice != "deny" else { return .deny("The learner declined running JavaScript.") }
            if choice == "lesson" { self.app.interactions.grant("js:" + site.id, conversationID: conv) }
            self.grantSite(site, conv: conv, lesson: choice == "lesson")
            return .allow
        }
    }

    private func siteDecision(_ site: SiteKey, url: URL, conv: String) -> ToolDecision {
        if app.interactions.isGranted("site:" + site.id, conversationID: conv) || (!site.isLocal && app.settings.value.browserSites.contains(site.id)) {
            if site.isLocal { AgentBrowser.shared.allowedLocal.insert(site.id) }
            return .allow
        }
        let what = site.id.hasPrefix("file:") ? "open files in \(site.id.dropFirst(5))" : site.isLocal ? "use \(site.id) (this Mac or your local network)" : "use \(site.id)"
        var options = [ApprovalOption(id: "lesson", label: "Allow for this lesson", style: .primary)]
        if !site.isLocal { options.append(ApprovalOption(id: "always", label: "Always allow \(site.id)")) }
        options += [ApprovalOption(id: "once", label: "Allow once"), ApprovalOption(id: "deny", label: "Deny", style: .danger)]
        return .ask(ApprovalRequest(
            title: "Allow Teacher to \(what) in its browser?",
            detail: url.absoluteString + "\nTeacher can read the page and click, type and submit forms there. It never types passwords, payment details or ID numbers, never uploads files, and asks before downloading.",
            options: options)) { [weak self] choice in
            guard let self else { return .deny("Closed.") }
            switch choice {
            case "lesson", "once": self.grantSite(site, conv: conv, lesson: choice == "lesson"); return .allow
            case "always": self.app.settings.value.browserSites.append(site.id); return .allow
            default: return .deny("The learner declined \(site.label).")
            }
        }
    }

    private func grantSite(_ site: SiteKey, conv: String, lesson: Bool) {
        if lesson { app.interactions.grant("site:" + site.id, conversationID: conv) }
        if site.isLocal { AgentBrowser.shared.allowedLocal.insert(site.id) }
    }

    // MARK: Mac apps

    private func apps(_ input: JSON, conv: String) -> ToolDecision {
        let action = input["action"]?.string ?? ""
        let names: [String]
        switch action {
        case "request_access": names = input["apps"]?.array?.compactMap(\.string) ?? input["app"]?.string.map { [$0] } ?? []
        case "open_app", "focus_app": names = input["app"]?.string.map { [$0] } ?? []
        default: return .allow   // everything else is checked against the grants when it runs
        }
        let c = ComputerController.shared
        let wanted = names.compactMap(AppResolver.resolve).filter { AppTier.of($0.bundleID) != .never && !c.isGranted($0.bundleID, conv) }
        guard !wanted.isEmpty else { return .allow }
        let lines = wanted.map { "• \($0.name) — \(AppTier.of($0.bundleID).title)" }
        let reason = input["reason"]?.string.map { "\n\nWhy: " + $0 } ?? ""
        return .ask(ApprovalRequest(
            title: "Allow Teacher to use \(wanted.count == 1 ? wanted[0].name : "\(wanted.count) apps") on your Mac?",
            detail: lines.joined(separator: "\n") + reason + "\n\nTeacher sees only these apps in screenshots. A banner shows while it is in control; press Esc twice or Stop to take over.",
            options: [ApprovalOption(id: "lesson", label: "Allow for this lesson", style: .primary), ApprovalOption(id: "always", label: "Always allow"),
                      ApprovalOption(id: "deny", label: "Deny", style: .danger)])) { [weak self] choice in
            guard let self, choice != "deny" else { return .deny("The learner declined access to \(wanted.map(\.name).joined(separator: ", ")).") }
            for f in wanted {
                if choice == "always" { if !self.app.settings.value.computerApps.contains(f.bundleID) { self.app.settings.value.computerApps.append(f.bundleID) } }
                else { self.app.interactions.grant("app:" + f.bundleID, conversationID: conv) }
            }
            return .allow
        }
    }

    // MARK: Requests and turns

    /// Claude on Anthropic's own API: the native computer-use tool replaces the generic schema (same actions, so the
    /// same `computer` tool runs it). Other providers keep the generic one.
    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        guard let i = request.tools.firstIndex(where: { $0.name == "computer" }),
              let p = app.settings.provider(session.conversation.providerID), p.api == .anthropic, p.baseURL.contains("api.anthropic.com"),
              let native = NativeComputerTool.spec(model: request.model, display: NativeComputerTool.displaySize) else { return }
        request.tools[i].native = native.json
        request.tools[i].nativeBeta = native.beta
    }

    /// One failed computer action ends its batch: the rest of that step's computer calls are answered without running.
    func didRun(_ call: Block, result: inout Block, session: ChatSession) {
        guard call.name == "computer", result.isError == true,
              let step = session.messages.last(where: { $0.role == .assistant && $0.toolUses.contains { $0.id == call.id } }) else { return }
        let later = step.toolUses.drop { $0.id != call.id }.dropFirst().filter { $0.name == "computer" }.compactMap(\.id)
        ComputerController.shared.skipped.formUnion(later)
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) { ComputerController.shared.end(session.id) }
    func sessionWillClose(_ session: ChatSession) { ComputerController.shared.end(session.id) }
}
