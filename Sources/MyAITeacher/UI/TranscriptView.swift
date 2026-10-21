import SwiftUI
import WebKit

/// Hosts the single WKWebView that renders a lesson's transcript.
struct TranscriptView: NSViewRepresentable {
    @ObservedObject var session: ChatSession
    let fontSize: Double

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(c), name: "bridge")
        config.setURLSchemeHandler(TeacherLibSchemeHandler(), forURLScheme: TeacherLibSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: Self.logBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if Telemetry.isEnabled { config.userContentController.addUserScript(WKUserScript(source: WebTelemetry.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)) }
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")
        config.suppressesIncrementalRendering = false
        let web = ClickThroughWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        web.uiDelegate = c
        web.setValue(false, forKey: "drawsBackground")
        web.allowsMagnification = true
        c.web = web
        c.watchdog = WebWatchdog(web: web) { [weak c] in c?.pageHung() }
        DebugHooks.transcript = web
        let dir = AppPaths.webResources
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        c.attach(session, fontSize: fontSize)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {
        context.coordinator.attach(session, fontSize: fontSize)
    }

    /// Forwards JS errors and console output to ~/Library/Logs/MyAITeacher.log.
    static let logBridge = """
    (function(){
      const send = (level, text) => { try { window.webkit.messageHandlers.bridge.postMessage({type:'log', level, text: String(text).slice(0, 2000)}); } catch (_) {} };
      window.addEventListener('error', e => send('error', e.message + ' @ ' + (e.filename || '').split('/').pop() + ':' + e.lineno));
      window.addEventListener('unhandledrejection', e => send('error', 'Unhandled: ' + (e.reason && (e.reason.stack || e.reason))));
      const ce = console.error, cw = console.warn, cl = console.log;
      console.error = (...a) => { send('error', a.join(' ')); ce.apply(console, a); };
      console.warn = (...a) => { send('warn', a.join(' ')); cw.apply(console, a); };
      console.log = (...a) => { send('info', a.join(' ')); cl.apply(console, a); };
    })();
    """

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        coordinator.watchdog?.stop()
        web.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler, TranscriptSink {
        weak var web: WKWebView?
        var watchdog: WebWatchdog?
        /// After paging in earlier messages, keep the view on the message the learner was looking at.
        private var pendingAnchor: String?
        /// Lessons whose page froze (a looping visual): their visuals wait for a click from then on.
        private var pausedVisuals: Set<String> = []
        private var hungNotice = false

        func pageHung() {
            if let id = session?.id { pausedVisuals.insert(id) }
            hungNotice = true
            ready = false   // calls queue until the restarted page says ready
        }
        weak var session: ChatSession?
        private var ready = false
        private var queue: [String] = []
        private var fontSize: Double = 15
        // Coalesced streaming deltas, flushed once per frame.
        private var pendingDeltas: [(id: String, index: Int, kind: Block.Kind, text: String)] = []
        private var flushScheduled = false

        func attach(_ s: ChatSession, fontSize: Double) {
            if self.fontSize != fontSize { self.fontSize = fontSize; run("T.setFontSize(\(fontSize))") }
            guard session !== s else { return }
            session?.sink = nil
            session = s
            s.sink = self
            AppModel.shared.interactions.onChange = { [weak self] p, active in self?.interaction(p, active: active) }
        }

        // MARK: TranscriptSink
        func reset(_ messages: [ChatMessage], conversation: Conversation) {
            pendingDeltas.removeAll()
            let payload = JSON.array(messages.map(Self.encode))
            var opts: [String: JSON] = ["showThinking": .bool(AppModel.shared.settings.value.showThinking)]
            if messages.isEmpty { opts["welcome"] = AppModel.shared.welcomePayload(mode: conversation.mode) }
            if pausedVisuals.contains(conversation.id) { opts["pauseVisuals"] = true }
            if conversation.mode.isAgent { opts["agent"] = true }
            if let s = session, s.base > 0 { opts["earlier"] = .number(Double(s.base)) }
            if let anchor = pendingAnchor { opts["anchor"] = .string(anchor); pendingAnchor = nil }
            run("T.reset(\(payload.compact), \(JSON.object(opts).compact))", replaceQueue: true)
            if ready {
                web?.evaluateJavaScript("document.querySelectorAll('.msg').length + ' rendered / ' + document.body.scrollHeight + 'px'") { r, _ in
                    AppLog.write("reset \(conversation.title.prefix(40)): \(messages.count) messages → \(r ?? "?")")
                }
            }
            for p in AppModel.shared.interactions.pending.values where p.conversationID == conversation.id { interaction(p, active: true) }
            setStatus(session?.status)
        }

        func upsert(_ message: ChatMessage) {
            flushDeltas()
            run("T.upsert(\(Self.encode(message).compact))")
        }

        func delta(_ messageID: String, index: Int, kind: Block.Kind, text: String) {
            if let last = pendingDeltas.last, last.id == messageID, last.index == index, last.kind == kind {
                pendingDeltas[pendingDeltas.count - 1].text += text
            } else {
                pendingDeltas.append((messageID, index, kind, text))
            }
            guard !flushScheduled else { return }
            flushScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.016) { [weak self] in
                MainActor.assumeIsolated { self?.flushDeltas() }
            }
        }

        private func flushDeltas() {
            flushScheduled = false
            guard !pendingDeltas.isEmpty else { return }
            let js = pendingDeltas.map { d in
                "T.delta(\(JSON.string(d.id).compact),\(d.index),\(JSON.string(d.kind.rawValue).compact),\(JSON.string(d.text).compact));"
            }.joined()
            pendingDeltas.removeAll(keepingCapacity: true)
            run(js)
        }

        func notice(_ text: String) {
            run("T.notice(\(JSON.string(text).compact))")
        }

        func toolProgress(_ toolID: String, text: String) {
            run("T.toolProgress(\(JSON.string(toolID).compact),\(JSON.string(text).compact))")
        }

        func interaction(_ p: InteractionCenter.Pending, active: Bool) {
            guard p.conversationID == session?.id else { return }
            let j: JSON = ["id": .string(p.id), "kind": .string(p.kind), "payload": p.payload]
            run("T.interaction(\(j.compact), \(active))")
        }

        func setStatus(_ status: String?) {
            let running = session?.isRunning ?? false
            run("T.status(\(status.map { JSON.string($0).compact } ?? "null"), \(running))")
        }

        static func encode(_ m: ChatMessage) -> JSON {
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .secondsSince1970
            guard let d = try? enc.encode(m), let j = JSON.parse(d) else { return .null }
            return j
        }

        // MARK: JS plumbing
        private func run(_ js: String, replaceQueue: Bool = false) {
            guard ready, let web else {
                if replaceQueue { queue.removeAll() }
                queue.append(js); return
            }
            web.evaluateJavaScript(js) { _, err in
                if let err { AppLog.write("JS error: \(err.localizedDescription) in \(js.prefix(160))") }
            }
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {}

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            // Sandboxed visual iframes: their srcdoc document loads; any other sub-frame navigation is dropped silently.
            if action.targetFrame?.isMainFrame == false {
                decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel); return
            }
            if [.other, .reload].contains(action.navigationType), action.request.url?.isFileURL == true { decisionHandler(.allow); return }
            if let url = action.request.url, ["http", "https", "mailto"].contains(url.scheme ?? "") { AppModel.shared.openLink(url) }
            decisionHandler(.cancel)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            let dir = AppPaths.webResources
            webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let j = JSON(any: body)
            MainActor.assumeIsolated { self.handle(j) }
        }

        private func handle(_ j: JSON) {
            let app = AppModel.shared
            switch j["type"]?.string {
            case "log":
                AppLog.write("[web \(j["level"]?.string ?? "info")] \(j["text"]?.string ?? "")")
            case "ready":
                AppLog.write("transcript ready")
                ready = true
                run("T.setFontSize(\(fontSize))")
                if let s = session { reset(s.messages, conversation: s.conversation) }
                let q = queue; queue.removeAll()
                q.forEach { run($0) }
                if hungNotice {
                    hungNotice = false
                    run("T.notice('A visual stopped responding, so the lesson was reloaded with visuals paused. Use ▶ Run to try one again.')")
                }
            case "telemetry":
                WebTelemetry.handle(j, webView: web)
            case "open":
                if let u = j["url"]?.string.flatMap(URL.init(string:)) { app.openLink(u) }
            case "copy":
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(j["text"]?.string ?? "", forType: .string)
            case "speak":
                if app.speech.isSpeaking && j["lang"] == nil { app.speech.stop() }
                else { app.speech.speak(j["text"]?.string ?? "", language: j["lang"]?.string, voice: app.settings.value.voiceIdentifier, rate: app.settings.value.speechRate) }
            case "memory":
                app.selection = .memory
            case "older":
                pendingAnchor = session?.messages.first?.id
                session?.loadEarlier()
            case "agent":   // a sub-agent card: open it in the right-hand panel, or stop it
                guard let id = j["id"]?.string, let s = session else { return }
                let center = SubAgentCenter.shared
                if j["op"]?.string == "stop" { center.run(id)?.stop(); return }
                if center.run(id) == nil {
                    // Not in memory (the app restarted): rebuild it from the transcript kept in the lesson.
                    let blocks = s.messages.flatMap(\.blocks)
                    let use = blocks.first { $0.kind == .toolUse && $0.id == id }
                    let saved = blocks.first { $0.kind == .toolResult && $0.id == id }?.meta?["subagent"]
                        ?? blocks.first { $0.meta?["agentReport"]?.string == id }?.meta?["subagent"]
                    guard let saved else { return }
                    let title = use?.input?["description"]?.string ?? blocks.first { $0.meta?["agentReport"]?.string == id }?.meta?["title"]?.string ?? "Sub-agent"
                    _ = center.restore(id: id, conversationID: s.id, title: title, saved: saved)
                }
                app.showSubAgent(center.run(id)?.id ?? id)
            case "answer":
                if let id = j["id"]?.string { app.interactions.resolve(id, j["value"] ?? .null) }
            case "regenerate": session?.regenerate()
            case "retry": session?.retry()
            case "edit":
                if let id = j["id"]?.string, let t = j["text"]?.string { session?.edit(messageID: id, newText: t) }
            case "suggest":
                if let t = j["text"]?.string { session?.send(t) }
            case "quick":
                let prompts = [
                    "simpler": "Can you explain that again more simply, with an everyday analogy?",
                    "deeper": "Let's go deeper — what's the more rigorous or advanced version of this?",
                    "example": "Give me another worked example, then a similar one for me to try.",
                    "quiz": "Quiz me on what we just covered with a short graded quiz.",
                    "flashcards": "Turn the key ideas from your last answer into flashcards for spaced repetition.",
                ]
                if let q = j["q"]?.string, let p = prompts[q] { session?.send(p) }
            case "run":
                guard let key = j["key"]?.string, let code = j["code"]?.string else { return }
                let lang = j["lang"]?.string ?? "python"
                Task {
                    let out: String, failed: Bool
                    do {
                        let r = try await RunCodeTool.execute(language: lang, code: code, stdin: nil, timeout: 60, workingDirectory: app.workspace.url)
                        (out, failed) = (r.text, r.failed)
                    } catch { (out, failed) = (error.localizedDescription, true) }
                    self.run("T.codeOutput(\(JSON.string(key).compact),\(JSON.string(out).compact),\(failed))")
                }
            default: break
            }
        }

        // Disable the default context menu items that navigate.
        func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
            if let u = navigationAction.request.url { AppModel.shared.openLink(u) }
            return nil
        }
    }
}

/// Accepts the first click even when the window isn't key (buttons in the transcript respond immediately).
final class ClickThroughWebView: WKWebView {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Avoids the WKUserContentController → handler retain cycle.
final class WeakHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?
    init(_ t: WKScriptMessageHandler) { target = t }
    func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) { target?.userContentController(c, didReceive: m) }
}
