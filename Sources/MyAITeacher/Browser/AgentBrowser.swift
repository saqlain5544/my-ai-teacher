import AppKit
import WebKit

/// The in-app browser (right panel → Browser): tabs of WKWebViews over one persistent website data store of its own,
/// separate from the transcript; links from lessons open here too. The learner watches it live, can browse in it and can take over;
/// the agent acts through the helper in an isolated content world, so page scripts can't see or tamper with it.
/// Tabs not on screen live in an offscreen panel, so they keep a real size, keep rendering and can be screenshotted.
///
/// Sites are the lesson's: while the agent acts, the page may only take it to sites its lesson approved (redirects, links,
/// scripts and forms included), and what the agent reads always comes from an approved site. Between actions the learner
/// (or the page) may go anywhere public; this Mac and the local network stay closed unless approved, and public pages
/// can't load anything from them.
@MainActor
final class AgentBrowser: ObservableObject {
    static let shared = AgentBrowser(store: AppPaths.testHome == nil ? WKWebsiteDataStore(forIdentifier: storeID) : .nonPersistent(),
                                     rules: WKContentRuleListStore(url: AppPaths.support.appendingPathComponent("BrowserRules", isDirectory: true)))
    /// The learner's own copy keeps its sign-ins across launches; test profiles never write a store.
    static let storeID = UUID(uuidString: "5C0FFEE0-7EAC-4E12-A9E7-0B5E55100001")!
    /// Shows the panel when the agent opens a page (set by the app; nil in tests).
    static var onShow: (() -> Void)?
    static let tabLimit = 12

    let store: WKWebsiteDataStore
    let world = WKContentWorld.world(name: "teacher-agent")
    let contentController = WKUserContentController()
    @Published private(set) var tabs: [BrowserTab] = []
    @Published var activeID: Int?
    /// The learner has taken over: agent actions are refused until they hand it back.
    @Published var learnerControl = false
    /// What the agent is doing right now (shown in the panel).
    @Published var activity: String?
    /// Whether a lesson may use a site (its grants; set by the app, tests set their own).
    var siteAllowed: (SiteKey, String) -> Bool = { _, _ in false }
    /// The lesson whose agent drives the browser now, or did last.
    private(set) var driver: String?
    /// An agent action is running: navigations now are the agent's, so only to sites its lesson approved.
    private(set) var acting = false
    /// Popups the running action may open (one per click or key press; none from page timers).
    var popupBudget = 0
    private var lastIdlePopup = Date.distantPast
    /// Local addresses the learner opened from the address bar themselves.
    var learnerSites = Set<String>()
    var viewport = CGSize(width: 1280, height: 800)
    private var nextID = 1
    private var router: MessageRouter?
    private lazy var parking: NSPanel = {
        let p = NSPanel(contentRect: NSRect(x: -30000, y: -30000, width: 1600, height: 1200), styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: false)
        p.isExcludedFromWindowsMenu = true
        p.collectionBehavior = [.transient, .ignoresCycle]
        p.orderFrontRegardless()
        return p
    }()

    init(store: WKWebsiteDataStore, rules: WKContentRuleListStore? = nil) {
        self.store = store
        let r = MessageRouter(browser: self)
        router = r
        contentController.addUserScript(WKUserScript(source: BrowserScripts.helper, injectionTime: .atDocumentStart, forMainFrameOnly: false, in: world))
        contentController.addUserScript(WKUserScript(source: BrowserScripts.logger, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        contentController.add(r, contentWorld: world, name: "taFrame")
        contentController.add(r, name: "taLog")
        NotificationCenter.default.addObserver(forName: MemoryGovernor.shedNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.tabs.forEach { $0.shed() } }
        }
        if let rules { Task { if let list = try? await Self.localNetworkRules(rules) { contentController.add(list) } } }
    }

    var active: BrowserTab? { tabs.first { $0.id == activeID } ?? tabs.last }
    func tab(_ id: Int?) -> BrowserTab? { id.map { i in tabs.first { $0.id == i } } ?? active }

    @discardableResult
    func newTab(_ url: URL? = nil, configuration: WKWebViewConfiguration? = nil) -> BrowserTab {
        let cfg = configuration ?? {
            let c = WKWebViewConfiguration()
            c.websiteDataStore = store
            c.userContentController = contentController
            c.preferences.javaScriptCanOpenWindowsAutomatically = true   // popups are filtered in createWebViewWith instead
            c.preferences.isElementFullscreenEnabled = false
            return c
        }()
        let tab = BrowserTab(id: nextID, configuration: cfg, browser: self)
        nextID += 1
        tabs.append(tab)
        activeID = tab.id
        park(tab)
        if let url { tab.load(url) }
        return tab
    }

    /// A page the learner opened (a link in a lesson, the address bar): a new tab, or the active one when the tabs are
    /// full. A local address they chose is allowed for this run, as typed into the address bar.
    @discardableResult
    func openForLearner(_ url: URL) -> BrowserTab {
        if let key = SiteKey.of(url), key.isLocal { learnerSites.insert(key.id) }
        if tabs.count >= Self.tabLimit, let t = active { activeID = t.id; t.load(url); return t }
        return newTab(url)
    }

    func close(_ tab: BrowserTab) {
        tab.cancelDownload()
        tab.web.stopLoading()
        tab.web.removeFromSuperview()
        tabs.removeAll { $0 === tab }
        if activeID == tab.id { activeID = tabs.last?.id }
    }

    /// Puts a tab's view into `container` (the panel), or back into the offscreen panel at its current size.
    func show(_ tab: BrowserTab, in container: NSView) {
        guard tab.web.superview !== container else { return }
        tab.web.removeFromSuperview()
        tab.web.frame = container.bounds
        tab.web.autoresizingMask = [.width, .height]
        container.addSubview(tab.web)
    }

    func park(_ tab: BrowserTab) {
        guard tab.web.superview !== parking.contentView else { return }
        let size = tab.web.frame.width > 100 ? tab.web.frame.size : viewport
        tab.web.removeFromSuperview()
        tab.web.autoresizingMask = []
        tab.web.frame = NSRect(origin: .zero, size: size)
        parking.contentView?.addSubview(tab.web)
    }

    /// Signs the agent's browser out of everything (cookies, storage, caches).
    func clearData() { store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast) {} }

    // MARK: Who may go where

    /// Marks the start and end of one agent action of `conv`.
    func beginAction(_ conv: String, popups: Int) { driver = conv; acting = true; popupBudget = popups }
    func endAction() { acting = false; popupBudget = 0 }

    /// Whether the lesson driving the browser may see this site (nil: a blank page with nothing of anyone's).
    func approved(_ site: SiteKey?) -> Bool {
        guard let site else { return true }
        guard let d = driver else { return false }
        return siteAllowed(site, d)
    }

    /// A navigation (main frame or a frame inside it). While the agent acts: only to sites its lesson approved. Otherwise
    /// public sites are fine (nothing reaches the agent unapproved), but this Mac and the local network need an approval
    /// or the learner's own typing.
    func mayNavigate(to site: SiteKey, mainFrame: Bool) -> Bool {
        if site.isLocal && !acting && learnerSites.contains(site.id) { return true }
        if acting && mainFrame { return approved(site) }
        return !site.isLocal || approved(site)
    }

    /// target=_blank and window.open: one per agent click or key press; while idle (the learner browsing), one every 2 s.
    func mayOpenPopup() -> Bool {
        guard tabs.count < Self.tabLimit else { return false }
        if acting { guard popupBudget > 0 else { return false }; popupBudget -= 1; return true }
        guard Date().timeIntervalSince(lastIdlePopup) > 2 else { return false }
        lastIdlePopup = Date()
        return true
    }

    /// Requests from a public page to this Mac or the local network (images, scripts, fetches) are blocked by WebKit
    /// itself. Content-rule regexes have no alternation, so each local prefix is its own rule.
    static let localPrefixes = ["localhost[:/]", "[^/]*\\.localhost[:/]", "[^/]*\\.local[:/]", "127\\.", "10\\.", "192\\.168\\.", "169\\.254\\.",
                                "172\\.1[6-9]\\.", "172\\.2[0-9]\\.", "172\\.3[01]\\.", "0\\.", "\\[::1\\]", "\\[::\\]", "\\[::ffff:", "\\[f[cd]", "\\[fe[89ab]"]
    static func localNetworkRules(_ store: WKContentRuleListStore) async throws -> WKContentRuleList? {
        let local = localPrefixes.map { "^https?://" + $0 }
        let rules: [JSON] = local.map { p in
            ["trigger": ["url-filter": .string(p), "unless-top-url": .array((local + ["^file:"]).map { .string($0) })], "action": ["type": "block"]]
        }
        return try await store.compileContentRuleList(forIdentifier: "teacher-agent-local-network", encodedContentRuleList: JSON.array(rules).compact)
    }
}

/// Script messages for every tab, routed by the web view they came from (popups share their opener's controller).
private final class MessageRouter: NSObject, WKScriptMessageHandler {
    weak var browser: AgentBrowser?
    init(browser: AgentBrowser) { self.browser = browser }
    func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        MainActor.assumeIsolated {
            guard let tab = browser?.tabs.first(where: { $0.web === message.webView }) else { return }
            tab.received(message)
        }
    }
}

extension WKSecurityOrigin {
    /// scheme://host[:port]; nil for opaque origins (data: frames, sandboxes).
    var url: URL? { `protocol`.isEmpty || host.isEmpty ? nil : URL(string: "\(`protocol`)://\(host)\(port > 0 ? ":\(port)" : "")") }
}

extension WKNavigationAction {
    /// The origin of the frame that started it; nil for loads the app started (WebKit hands back nil there, despite the
    /// non-optional type, so it is read without trusting that).
    var sourceOrigin: URL? { (value(forKey: "sourceFrame") as? WKFrameInfo)?.securityOrigin.url }
}

/// One tab: its web view, what it logged, and the navigation, dialog, download and upload policy.
@MainActor
final class BrowserTab: NSObject, ObservableObject, Identifiable, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    struct LogEntry { let time: Date; let level: String; let text: String }
    struct NetEntry { let time: Date; let kind: String; let method: String; let url: String; let status: Int; let ms: Int; let type: String; let error: String? }
    struct Download { let url: URL; let name: String; let size: Int64?; let mime: String? }

    let id: Int
    let web: WKWebView
    unowned let browser: AgentBrowser
    @Published var title = ""
    @Published var url: URL?
    @Published var loading = false
    @Published var canGoBack = false
    @Published var canGoForward = false
    private(set) var console: [LogEntry] = []
    private(set) var network: [NetEntry] = []
    /// Cross-origin frames that introduced themselves (index → frame), read separately for snapshots and actions.
    private(set) var frames: [Int: WKFrameInfo] = [:]
    private var nextFrame = 1
    /// Each ref handed out ("frame:ref", main frame 0) with the token of the document it came from: a ref from an earlier
    /// document is refused even when the new one numbers an element the same.
    var issued: [String: String] = [:]
    /// The origin an about: page (or a popup) belongs to: the page that made it.
    var inheritedOrigin: URL?
    var inflight = 0
    var lastNetwork = Date.distantPast
    /// When the latest main-frame navigation started (an action that navigates shows here within a frame or two).
    var navStartedAt = Date.distantPast
    var lastStatus: Int?
    var lastError: String?
    /// Screenshot pixels → CSS pixels, from the latest screenshot.
    var shotScale: Double = 1
    /// What happened that the agent should hear about in its next result: blocked navigations, dialogs, refused uploads.
    private(set) var notices: [String] = []
    var blockedDownload: Download?
    /// The next JavaScript confirm/prompt: accepted (with text) or dismissed (the default).
    var dialogAnswer: (accept: Bool, text: String?)?
    private var downloadDone: CheckedContinuation<Result<URL, Error>, Never>?
    private var activeDownload: WKDownload?
    private var downloadDir: URL?
    private var downloadDest: URL?
    private var observers: [NSKeyValueObservation] = []
    static let logLimit = 300

    init(id: Int, configuration: WKWebViewConfiguration, browser: AgentBrowser) {
        self.id = id
        self.browser = browser
        web = WKWebView(frame: NSRect(origin: .zero, size: browser.viewport), configuration: configuration)
        super.init()
        web.navigationDelegate = self
        web.uiDelegate = self
        web.allowsBackForwardNavigationGestures = true
        web.isInspectable = AppPaths.testHome != nil
        // Offscreen counts as occluded, which would pause timers and rendering of background tabs.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) { web.perform(occlusion, with: nil) }
        observers = [
            web.observe(\.title) { [weak self] w, _ in MainActor.assumeIsolated { self?.title = w.title ?? "" } },
            web.observe(\.url) { [weak self] w, _ in MainActor.assumeIsolated { self?.url = w.url } },
            web.observe(\.isLoading) { [weak self] w, _ in MainActor.assumeIsolated { self?.loading = w.isLoading } },
            web.observe(\.canGoBack) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoBack = w.canGoBack } },
            web.observe(\.canGoForward) { [weak self] w, _ in MainActor.assumeIsolated { self?.canGoForward = w.canGoForward } },
        ]
    }

    func load(_ u: URL) {
        lastError = nil; lastStatus = nil
        if u.isFileURL { web.loadFileURL(u, allowingReadAccessTo: u.deletingLastPathComponent()) }
        else { web.load(URLRequest(url: u)) }
    }

    /// The site whose content this tab shows: its URL's, or for an about: page the origin that made it.
    var site: SiteKey? {
        guard let u = web.url else { return inheritedOrigin.flatMap(SiteKey.of) }
        return SiteKey.of(u) ?? inheritedOrigin.flatMap(SiteKey.of)
    }

    /// A cross-origin frame's site (file frames by their URL; opaque data: frames as the data: "site").
    func frameSite(_ index: Int) -> SiteKey? {
        guard let f = frames[index] else { return nil }
        if let u = f.request.url, u.isFileURL || u.scheme == "data" || u.scheme == "blob" { return SiteKey.of(u) }
        return f.securityOrigin.url.flatMap(SiteKey.of) ?? SiteKey(id: "data:", isLocal: true)
    }

    func note(_ s: String) {
        notices.append(AXFormat.clip(s, 400))
        if notices.count > 20 { notices.removeFirst(notices.count - 20) }
    }
    func drainNotices() -> [String] { defer { notices.removeAll() }; return notices }

    /// Drops what can be rebuilt (logs) when memory runs short.
    func shed() { console.removeAll(); network.removeAll() }

    // MARK: Script messages

    func received(_ m: WKScriptMessage) {
        guard let body = m.body as? [String: Any] else { return }
        if m.name == "taFrame" {
            guard !m.frameInfo.isMainFrame else { return }
            frames[nextFrame] = m.frameInfo; nextFrame += 1
            if frames.count > 12, let oldest = frames.keys.min() { frames.removeValue(forKey: oldest) }
            return
        }
        switch body["t"] as? String {
        case "console":
            append(&console, LogEntry(time: Date(), level: body["level"] as? String ?? "log", text: AXFormat.clip(body["text"] as? String ?? "", 2000)))
        case "net":
            lastNetwork = Date()
            if body["phase"] as? String == "start" { inflight += 1; return }
            inflight = max(0, inflight - 1)
            append(&network, NetEntry(time: Date(), kind: body["kind"] as? String ?? "fetch", method: body["method"] as? String ?? "GET",
                                      url: AXFormat.clip(body["url"] as? String ?? "", 500), status: body["status"] as? Int ?? 0,
                                      ms: body["ms"] as? Int ?? 0, type: body["type"] as? String ?? "", error: body["error"] as? String))
        default: break
        }
    }

    private func append<T>(_ list: inout [T], _ e: T) {
        list.append(e)
        if list.count > Self.logLimit { list.removeFirst(list.count - Self.logLimit) }
    }

    func clearLogs(console c: Bool, network n: Bool) { if c { console.removeAll() }; if n { network.removeAll() } }

    func frame(_ index: Int) -> WKFrameInfo? { frames[index] }
    func dropFrame(_ index: Int) { frames.removeValue(forKey: index); issued = issued.filter { !$0.key.hasPrefix("\(index):") } }
    var frameIndices: [Int] { frames.keys.sorted() }

    // MARK: Navigation policy

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping @MainActor (WKNavigationActionPolicy) -> Void) {
        guard let u = action.request.url else { return decisionHandler(.cancel) }
        if action.shouldPerformDownload {
            blockedDownload = Download(url: u, name: u.lastPathComponent.isEmpty ? "download" : u.lastPathComponent, size: nil, mime: nil)
            note("The page tried to download a file from \(u.absoluteString). Downloads need the learner's approval: call download with this url.")
            return decisionHandler(.cancel)
        }
        let main = action.targetFrame?.isMainFrame ?? true
        switch u.scheme?.lowercased() ?? "" {
        case "about", "blob":
            if main { inheritedOrigin = action.sourceOrigin ?? inheritedOrigin }
            decisionHandler(.allow)
        case "data", "javascript": decisionHandler(.allow)   // WebKit itself refuses top-level data: navigations from pages
        case "http", "https", "file":
            guard let site = SiteKey.of(u) else { return decisionHandler(.cancel) }
            let decide = { [weak self] (local: Bool) in
                guard let self else { return decisionHandler(.cancel) }
                let key = local && !site.isLocal ? SiteKey(id: site.id + ":\(u.port ?? (u.scheme == "https" ? 443 : 80))", isLocal: true) : site
                if self.browser.mayNavigate(to: key, mainFrame: main) {
                    if main { self.inheritedOrigin = nil }
                    return decisionHandler(.allow)
                }
                self.note(key.isLocal
                    ? "Blocked a navigation to \(u.absoluteString): this Mac, the local network and files need the learner's approval — call navigate with that URL to ask."
                    : "Blocked a navigation to \(u.absoluteString): the learner hasn't approved \(key.label) for this lesson. Call navigate with it to ask.")
                decisionHandler(.cancel)
            }
            // A name that resolves to this Mac or the LAN (localtest.me, nip.io…) is treated as local.
            guard !site.isLocal, let host = u.host(), LocalNetwork.addressIsLocal(host) == nil else { return decide(false) }
            Task { @MainActor in decide(await LocalNetwork.resolvesLocal(host)) }
        default:
            note("Blocked a link that would open another app (\(u.scheme ?? "?"):). Nothing leaves the app.")
            decisionHandler(.cancel)
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse, decisionHandler: @escaping @MainActor (WKNavigationResponsePolicy) -> Void) {
        let http = response.response as? HTTPURLResponse
        if response.isForMainFrame { lastStatus = http?.statusCode }
        if let u = response.response.url {
            // Where a redirect really ended: the same rule as for the request.
            // (data: and blob: documents aren't places to go: what they show is gated when it is read.)
            if ["http", "https", "file"].contains(u.scheme?.lowercased() ?? ""), let site = SiteKey.of(u), !browser.mayNavigate(to: site, mainFrame: response.isForMainFrame) {
                note("Blocked \(u.absoluteString) (reached by a redirect): the learner hasn't approved \(site.label) for this lesson.")
                return decisionHandler(.cancel)
            }
            network.append(NetEntry(time: Date(), kind: response.isForMainFrame ? "document" : "frame", method: "GET", url: AXFormat.clip(u.absoluteString, 500),
                                    status: http?.statusCode ?? 200, ms: 0, type: response.response.mimeType ?? "", error: nil))
            if network.count > Self.logLimit { network.removeFirst() }
        }
        let attachment = (http?.value(forHTTPHeaderField: "Content-Disposition") ?? "").lowercased().hasPrefix("attachment")
        if response.canShowMIMEType && !attachment { return decisionHandler(.allow) }
        if let u = response.response.url {   // a file, not a page: never saved without the learner's approval
            let size = response.response.expectedContentLength
            let d = Download(url: u, name: response.response.suggestedFilename ?? u.lastPathComponent, size: size > 0 ? size : nil, mime: response.response.mimeType)
            blockedDownload = d
            note("The page offered a file to download: \(d.name) (\(Self.sizeText(d.size)), \(d.mime ?? "unknown type")) from \(u.absoluteString). Downloads need the learner's approval: call download with this url.")
        }
        decisionHandler(.cancel)
    }

    /// Frames are forgotten when a main-frame navigation starts: the new document's frames can introduce themselves
    /// before WebKit reports the commit.
    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) { frames.removeAll(); navStartedAt = Date() }

    /// A new document: the refs and logs belong to the old one.
    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) {
        issued.removeAll()
        console.removeAll(); network.removeAll()
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { failed(error) }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { failed(error) }
    private func failed(_ error: Error) {
        let e = error as NSError
        if e.code == NSURLErrorCancelled || (e.domain == "WebKitErrorDomain" && e.code == 102) { return }   // our own cancels, downloads
        lastError = e.localizedDescription
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        note("The page crashed and was reloaded.")
        webView.reload()
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        guard browser.mayOpenPopup() else {
            note("Blocked a popup (\(action.request.url?.absoluteString ?? "")): one per click, at most \(AgentBrowser.tabLimit) tabs.")
            return nil
        }
        let tab = browser.newTab(nil, configuration: configuration)
        tab.inheritedOrigin = action.sourceOrigin
        note("The page opened a new tab (t\(tab.id)); it is now the active tab.")
        return tab.web
    }

    func webViewDidClose(_ webView: WKWebView) { browser.close(self) }

    // MARK: Dialogs and uploads

    func webView(_ webView: WKWebView, runJavaScriptAlertPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor () -> Void) {
        note("Page alert (dismissed): \(message)")
        completionHandler()
    }

    func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (Bool) -> Void) {
        let a = dialogAnswer?.accept ?? false
        dialogAnswer = nil
        note("Page asked to confirm: \(message) — \(a ? "accepted" : "dismissed (use dialog with accept: true before the action to accept)").")
        completionHandler(a)
    }

    func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor (String?) -> Void) {
        let a = dialogAnswer
        dialogAnswer = nil
        note("Page prompt: \(prompt) — \(a?.accept == true ? "answered" : "dismissed").")
        completionHandler(a?.accept == true ? (a?.text ?? defaultText ?? "") : nil)
    }

    func webView(_ webView: WKWebView, runOpenPanelWith parameters: WKOpenPanelParameters, initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping @MainActor ([URL]?) -> Void) {
        note("The page asked for a file to upload: refused. File uploads are never done by the agent; the learner can attach files themselves.")
        completionHandler(nil)
    }

    // MARK: Downloads (only after the learner approved this one)

    /// One at a time per tab; cancelled with its tool call (the deadline), and a cancelled download leaves no partial file.
    func download(_ url: URL, into dir: URL) async -> Result<URL, Error> {
        guard downloadDone == nil else { return .failure(ToolError("Another download is still running in this tab.")) }
        downloadDir = dir; downloadDest = nil
        return await withTaskCancellationHandler {
            await withCheckedContinuation { c in
                downloadDone = c
                web.startDownload(using: URLRequest(url: url)) { [weak self] d in
                    guard let self, self.downloadDone != nil else { d.cancel { _ in }; return }
                    d.delegate = self
                    self.activeDownload = d
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelDownload() }
        }
    }

    func cancelDownload() {
        guard downloadDone != nil else { return }
        activeDownload?.cancel { _ in }
        if let d = downloadDest { try? FileManager.default.removeItem(at: d) }
        finishDownload(.failure(ToolError("The download was cancelled.")))
    }

    private func finishDownload(_ r: Result<URL, Error>) {
        let c = downloadDone
        downloadDone = nil; activeDownload = nil
        c?.resume(returning: r)
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String, completionHandler: @escaping @MainActor (URL?) -> Void) {
        guard let dir = downloadDir, downloadDone != nil else { return completionHandler(nil) }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let safe = String(suggestedFilename.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: ":", with: "_").prefix(120))
        var dest = dir.appendingPathComponent(safe.isEmpty || safe.hasPrefix(".") ? "download" + safe : safe), n = 2
        while FileManager.default.fileExists(atPath: dest.path) {
            dest = dir.appendingPathComponent("\((safe as NSString).deletingPathExtension) \(n)").appendingPathExtension((safe as NSString).pathExtension); n += 1
        }
        downloadDest = dest
        completionHandler(dest)
    }

    func downloadDidFinish(_ download: WKDownload) {
        if let d = downloadDest { finishDownload(.success(d)) } else { finishDownload(.failure(ToolError("The download finished without a file."))) }
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) { finishDownload(.failure(error)) }

    static func sizeText(_ n: Int64?) -> String { n.map { ByteCountFormatter.string(fromByteCount: $0, countStyle: .file) } ?? "size unknown" }
}
