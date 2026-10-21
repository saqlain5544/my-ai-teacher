import SwiftUI
import WebKit

/// Right-hand panel tab: the lesson's sub-agents, each rendered live with the lesson renderer: who it is (type,
/// provider, model, effort), its budget use as it works, a note box to steer it, and Stop.
struct SubAgentPanel: View {
    @ObservedObject var center = SubAgentCenter.shared
    var conversationID: String?

    var body: some View {
        let runs = center.runs(in: conversationID)
        if let run = runs.first(where: { $0.id == center.selectedID }) ?? runs.last {
            VStack(spacing: 0) {
                if runs.count > 1 {
                    Picker("Sub-agent", selection: Binding(get: { run.id }, set: { center.selectedID = $0 })) {
                        ForEach(runs.reversed()) { r in Text("\(r.handle) · \(r.title)\(r.isRunning ? " ●" : "")").tag(r.id) }
                    }
                    .labelsHidden().padding(.horizontal, 8).padding(.top, 6)
                }
                SubAgentHeader(run: run)
                Divider()
                SubAgentWebView(run: run)
                RuntimeFooter()
            }
        } else {
            ContentUnavailableView("No sub-agents yet", systemImage: "person.2",
                                   description: Text("When the teacher hands research to a sub-agent, its work appears here as it happens."))
        }
    }
}

private struct SubAgentHeader: View {
    @ObservedObject var run: SubAgentRun
    @State private var note = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: icon).foregroundStyle(color)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(run.title).font(.headline).lineLimit(1)
                        Text(run.typeName).font(.caption2.weight(.semibold)).padding(.horizontal, 5).padding(.vertical, 1)
                            .background(.quaternary, in: Capsule())
                    }
                    Text(identity).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
                Spacer()
                if run.isRunning {
                    Button(role: .destructive) { run.stop() } label: { Label("Stop", systemImage: "stop.fill") }
                        .help("Stop this sub-agent; the lesson gets what it found so far")
                }
            }
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                VStack(alignment: .leading, spacing: 3) {
                    Text(caption).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                    HStack(spacing: 10) {
                        Gauge(label: "steps", used: Double(run.steps), limit: run.budget?.steps.map(Double.init), text: "\(run.steps)")
                        Gauge(label: "s", used: run.elapsed, limit: run.budget?.seconds.map(Double.init), text: "\(Int(run.elapsed))")
                        Gauge(label: "tokens", used: Double(run.usage.total), limit: run.budget?.tokens.map(Double.init), text: AgentBudget.short(run.usage.total))
                        Text(run.cost.map { $0 == 0 ? "free" : String(format: "$%.4f", $0) } ?? "cost —").font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }
            if run.isRunning {
                HStack(spacing: 6) {
                    TextField("Note to steer it (read before its next step)…", text: $note).textFieldStyle(.roundedBorder).font(.caption)
                        .onSubmit(send)
                    Button("Send", action: send).disabled(note.trimmingCharacters(in: .whitespaces).isEmpty).controlSize(.small)
                }
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }

    private func send() {
        let t = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, run.steer(t, from: "learner") else { return }
        note = ""
    }

    private var identity: String {
        [run.handle, run.providerID.isEmpty ? nil : run.providerID, run.model.isEmpty ? nil : run.model, "effort \(run.effort)",
         run.budget.map { "budget " + $0.label }, run.parent.map { "from \($0)" }].compactMap { $0 }.joined(separator: " · ")
    }
    private var icon: String {
        switch run.state { case .running: "circle.dotted"; case .done: "checkmark.circle.fill"; case .stopped: "stop.circle.fill"; case .failed: "exclamationmark.triangle.fill" }
    }
    private var color: Color {
        switch run.state { case .running: .accentColor; case .done: .green; case .stopped: .secondary; case .failed: .orange }
    }
    private var caption: String {
        let secs = Int(run.elapsed)
        let time = secs < 60 ? "\(secs) s" : "\(secs / 60)m \(secs % 60)s"
        let tools = run.toolCalls
        let extra = run.restarts > 0 ? " · \(run.restarts) restart\(run.restarts == 1 ? "" : "s")" : ""
        switch run.state {
        case .running: return (run.status ?? "Working…") + " · \(time)" + extra
        case .done: return "Finished in \(time) · \(tools) tool call\(tools == 1 ? "" : "s")" + extra
        case .stopped: return "Stopped after \(time)" + extra
        case .failed: return "Failed after \(time)" + extra
        }
    }
}

/// One budget dimension: a bar against its limit (none for an unbounded dimension), and the number used.
private struct Gauge: View {
    let label: String
    let used: Double
    let limit: Double?
    let text: String
    var body: some View {
        HStack(spacing: 4) {
            if let limit, limit > 0 {
                ProgressView(value: min(used, limit), total: limit).frame(width: 44).tint(used >= limit ? .orange : .accentColor)
            }
            Text(text + (limit.map { "/" + ($0 >= 1000 ? AgentBudget.short(Int($0)) : "\(Int($0))") } ?? "") + " " + label)
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
        }
    }
}

/// The supervised runtime at a glance: live processes, queued mail, restarts (Runtime.metrics).
private struct RuntimeFooter: View {
    var body: some View {
        TimelineView(.periodic(from: .now, by: 2)) { _ in
            let m = Runtime.metrics
            HStack {
                Text("Runtime · \(m.count) processes · \(m.mailboxDepth) queued · \(m.totalRestarts) restart\(m.totalRestarts == 1 ? "" : "s")")
                Spacer()
            }
            .font(.caption2).foregroundStyle(.tertiary).monospacedDigit().padding(.horizontal, 10).padding(.vertical, 4)
            .help(m.processes.map { "\($0.name) \($0.pid)\($0.mailbox > 0 ? " · \($0.mailbox) queued" : "")\($0.restarts > 0 ? " · \($0.restarts) restarts" : "")" }.joined(separator: "\n"))
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
        config.setURLSchemeHandler(BlobSchemeHandler(), forURLScheme: BlobSchemeHandler.scheme)
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
            // A parked transcript comes back from disk while it is on screen (after this view update, which can't publish).
            if r.parked != nil {
                DispatchQueue.main.async { [weak self] in
                    r.unpark()
                    if let self, self.run === r, self.ready { self.resetAll() }
                }
            }
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
