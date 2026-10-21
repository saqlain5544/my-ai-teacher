import SwiftUI
import WebKit

/// Right-hand panel tab: the lesson's sub-agents, each rendered live with the lesson renderer, with a Stop button.
struct SubAgentPanel: View {
    @ObservedObject var center = SubAgentCenter.shared
    var conversationID: String?

    var body: some View {
        let runs = center.runs(in: conversationID)
        if let run = runs.first(where: { $0.id == center.selectedID }) ?? runs.last {
            VStack(spacing: 0) {
                if runs.count > 1 {
                    Picker("Sub-agent", selection: Binding(get: { run.id }, set: { center.selectedID = $0 })) {
                        ForEach(runs.reversed()) { Text($0.title).tag($0.id) }
                    }
                    .labelsHidden().padding(.horizontal, 8).padding(.top, 6)
                }
                SubAgentHeader(run: run)
                Divider()
                SubAgentWebView(run: run)
            }
        } else {
            ContentUnavailableView("No sub-agents yet", systemImage: "person.2",
                                   description: Text("When the teacher hands research to a sub-agent, its work appears here as it happens."))
        }
    }
}

private struct SubAgentHeader: View {
    @ObservedObject var run: SubAgentRun

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: icon).foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(run.title).font(.headline).lineLimit(1)
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
            Spacer()
            if run.isRunning {
                Button(role: .destructive) { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                    .help("Stop this sub-agent; the lesson gets what it found so far")
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private var icon: String {
        switch run.state { case .running: "circle.dotted"; case .done: "checkmark.circle.fill"; case .stopped: "stop.circle.fill"; case .failed: "exclamationmark.triangle.fill" }
    }
    private var color: Color {
        switch run.state { case .running: .accentColor; case .done: .green; case .stopped: .secondary; case .failed: .orange }
    }
    private var caption: String {
        let secs = Int((run.endedAt ?? Date()).timeIntervalSince(run.startedAt))
        let time = secs < 60 ? "\(secs) s" : "\(secs / 60)m \(secs % 60)s"
        let tools = run.messages.reduce(0) { $0 + $1.toolUses.count }
        let model = run.model.isEmpty ? "" : " · " + run.model
        switch run.state {
        case .running: return (run.status ?? "Working…") + " · \(time)" + model
        case .done: return "Finished in \(time) · \(tools) tool call\(tools == 1 ? "" : "s")" + model
        case .stopped: return "Stopped after \(time)" + model
        case .failed: return "Failed after \(time)" + model
        }
    }
}

/// The lesson renderer (same page, same components) fed from a sub-agent run.
struct SubAgentWebView: NSViewRepresentable {
    @ObservedObject var run: SubAgentRun

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let c = context.coordinator
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(c), name: "bridge")
        config.setURLSchemeHandler(TeacherLibSchemeHandler(), forURLScheme: TeacherLibSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: TranscriptView.logBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        let web = ClickThroughWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        web.setValue(false, forKey: "drawsBackground")
        c.web = web
        c.watchdog = WebWatchdog(web: web) { [weak c] in c?.pageHung() }
        let dir = AppPaths.webResources
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        c.attach(run)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) { context.coordinator.attach(run) }

    static func dismantleNSView(_ web: WKWebView, coordinator: Coordinator) {
        web.configuration.userContentController.removeScriptMessageHandler(forName: "bridge")
        coordinator.watchdog?.stop()
        coordinator.detach()
    }

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate, WKScriptMessageHandler, SubAgentSink {
        weak var web: WKWebView?
        var watchdog: WebWatchdog?
        private var paused = false   // a visual froze this page once: visuals wait for a click
        func pageHung() { paused = true; ready = false }
        private var run: SubAgentRun?
        private var ready = false

        func attach(_ r: SubAgentRun) {
            guard run !== r else { return }
            run?.sink = nil
            run = r
            r.sink = self
            if ready { resetAll() }
        }
        func detach() { run?.sink = nil; run = nil }

        private func resetAll() {
            guard let run else { return }
            let payload = JSON.array(run.messages.map(TranscriptView.Coordinator.encode))
            exec("document.body.classList.add('read-only'); T.setFontSize(\(max(12, AppModel.shared.settings.value.fontSize - 1))); T.reset(\(payload.compact), {showThinking: \(AppModel.shared.settings.value.showThinking), pauseVisuals: \(paused)})")
            setStatus(run.status, running: run.isRunning)
        }
        private func exec(_ js: String) {
            guard ready, let web else { return }
            web.evaluateJavaScript(js) { _, err in if let err { AppLog.write("sub-agent JS error: \(err.localizedDescription)") } }
        }

        func upsert(_ message: ChatMessage) { exec("T.upsert(\(TranscriptView.Coordinator.encode(message).compact))") }
        func delta(_ messageID: String, index: Int, kind: Block.Kind, text: String) {
            exec("T.delta(\(JSON.string(messageID).compact), \(index), \(JSON.string(kind.rawValue).compact), \(JSON.string(text).compact))")
        }
        func toolProgress(_ toolID: String, text: String) { exec("T.toolProgress(\(JSON.string(toolID).compact), \(JSON.string(text).compact))") }
        func setStatus(_ status: String?, running: Bool) {
            exec("T.status(\(JSON.string(status ?? "").compact), \(running))")
        }

        func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any] else { return }
            let j = JSON(any: body)
            MainActor.assumeIsolated {
                switch j["type"]?.string {
                case "ready": ready = true; resetAll()
                case "log": AppLog.write("[sub-agent web \(j["level"]?.string ?? "info")] \(j["text"]?.string ?? "")")
                case "open": if let u = j["url"]?.string.flatMap(URL.init(string:)) { AppModel.shared.openLink(u) }
                case "copy":
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(j["text"]?.string ?? "", forType: .string)
                default: break   // a sub-agent transcript is read-only
                }
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
            if action.targetFrame?.isMainFrame == false { decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel); return }
            decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
        }
        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            ready = false
            let dir = AppPaths.webResources
            webView.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
        }
    }
}
