import SwiftUI
import WebKit
import QuartzCore

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
        config.setURLSchemeHandler(BlobSchemeHandler(), forURLScheme: BlobSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: Self.logBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        if Telemetry.isEnabled { config.userContentController.addUserScript(WKUserScript(source: WebTelemetry.script, injectionTime: .atDocumentEnd, forMainFrameOnly: true)) }
        #if DEBUG
        config.preferences.setValue(true, forKey: "developerExtrasEnabled")   // private key: debug builds (Web Inspector) only
        #endif
        config.suppressesIncrementalRendering = false
        let web = ClickThroughWebView(frame: .zero, configuration: config)
        web.navigationDelegate = c
        web.uiDelegate = c
        // Public equivalents of the old private `drawsBackground` key: let the SwiftUI chrome show through.
        web.underPageBackgroundColor = .clear
        (web.subviews.compactMap { $0 as? NSScrollView }).forEach { $0.drawsBackground = false }
        web.allowsMagnification = true
        c.web = web
        c.watchdog = WebWatchdog(web: web) { [weak c] in c?.pageHung() }
        NotificationCenter.default.addObserver(c, selector: #selector(Coordinator.shedCaches), name: MemoryGovernor.shedNotification, object: nil)
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
        coordinator.stopFrameLoop()
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

        /// The app is short of memory (MemoryGovernor): the page drops its render caches, which rebuild on demand.
        @objc func shedCaches() { if ready { web?.evaluateJavaScript("T.dropCaches(); 0") } }
        private var fontSize: Double = 15
        // Coalesced streaming deltas, flushed once per frame.
        private var pendingDeltas: [(id: String, index: Int, kind: Block.Kind, text: String)] = []
        private var frameLink: CADisplayLink?

        /// The page renders the newest `shown` messages of the lesson's window; the rest stay in memory (requests need them)
        /// behind "Show earlier", revealed a step at a time before older ones load from disk. Rendering the whole window of a
        /// 4,000-message lesson took ~0.8–1.4 GB in the page.
        static let pageWindow = 300, pageStep = 200
        private var shown = Coordinator.pageWindow
        /// The page's first message: where "Show earlier" continues from.
        private var pageFirst: String?
        /// Reading back beyond what fits: the page shows `browse` (positions [from, to) in the whole lesson), read straight
        /// from disk, at most `pageMax` messages, with "Show newer" under it. The session's own window is untouched. Without
        /// it, every "Show earlier" grew both the page and the session's window with no ceiling: ten steps back in a
        /// 20,000-message lesson held 1,875 messages and 1.2 GB in the page. Anything new in the lesson (a send, a reply,
        /// an agent's report) brings the page back to the live window.
        static let pageMax = 600
        private var browse: (from: Int, to: Int)?

        static func learner(_ m: ChatMessage) -> Bool { m.role == .user && !m.isToolResultOnly }
        /// Where the newest `keep` messages start, moved to a learner's message so no tool result arrives without its card
        /// (forward, or back when one turn is longer than `keep`).
        static func pageStart(_ m: [ChatMessage], keep: Int) -> Int {
            guard m.count > keep else { return 0 }
            let cut = m.count - keep
            return m[cut...].firstIndex(where: learner) ?? m[..<cut].lastIndex(where: learner) ?? 0
        }
        /// Where "Show earlier" moves the page's start from `first`: a step back, on a learner's message (the nearest after
        /// the step, else before it: an agent turn can be longer than a step), else the very start. nil: nothing earlier
        /// in memory, so it comes from disk.
        static func revealStart(_ m: [ChatMessage], first: Int, step: Int) -> Int? {
            guard first > 0 else { return nil }
            let from = max(0, first - step)
            let k = m[from..<first].firstIndex(where: learner) ?? m[..<from].lastIndex(where: learner) ?? 0
            return k < first ? k : nil
        }

        private func pageIndex(_ s: ChatSession) -> Int? { pageFirst.flatMap { id in s.messages.firstIndex { $0.id == id } } }

        /// Messages [from, to) of the whole lesson, from disk, starting on a learner's message (so no tool result arrives
        /// without its card), with the view kept on the message at `anchorAt`.
        private func showBrowse(from: Int, to: Int, anchorAt: Int, session s: ChatSession) {
            var page = s.services.conversations.messages(s.id, from: from, to: to)
            var start = from
            if start > 0, let k = page.firstIndex(where: Self.learner), k > 0, k < page.count { page.removeFirst(k); start += k }
            guard !page.isEmpty else { return }
            browse = (start, start + page.count)
            let a = anchorAt - start
            pendingAnchor = a >= 0 && a < page.count ? (page[a...].first(where: Self.learner) ?? page[a]).id : nil
            render(page[...], earlier: start, newer: s.totalCount - (start + page.count), windowCount: page.count, conversation: s.conversation)
        }

        func attach(_ s: ChatSession, fontSize: Double) {
            if self.fontSize != fontSize { self.fontSize = fontSize; run("T.setFontSize(\(fontSize))") }
            guard session !== s else { return }
            session?.sink = nil
            shown = Self.pageWindow
            session = s
            s.sink = self
            AppModel.shared.interactions.onChange = { [weak self] p, active in self?.interaction(p, active: active) }
        }

        // MARK: TranscriptSink
        func reset(_ messages: [ChatMessage], conversation: Conversation) {
            browse = nil
            let start = Self.pageStart(messages, keep: shown), earlier = (session?.base ?? 0) + start
            pageFirst = start < messages.count ? messages[start].id : nil
            render(messages[start...], earlier: earlier, newer: 0, windowCount: messages.count, conversation: conversation)
        }

        /// Puts `page` on the page, with how many messages come before and after it.
        private func render(_ page: ArraySlice<ChatMessage>, earlier: Int, newer: Int, windowCount: Int, conversation: Conversation) {
            pendingDeltas.removeAll()
            // Thinking is shown in every mode (the learner can hide it in Settings, and each finished block can be collapsed).
            var opts: [String: JSON] = ["showThinking": .bool(AppModel.shared.settings.value.showThinking)]
            if page.isEmpty && earlier == 0 && newer == 0 { opts["welcome"] = AppModel.shared.welcomePayload(mode: conversation.mode) }
            if pausedVisuals.contains(conversation.id) { opts["pauseVisuals"] = true }
            if conversation.mode.isAgent { opts["agent"] = true }
            if earlier > 0 { opts["earlier"] = .number(Double(earlier)) }
            if newer > 0 { opts["newer"] = .number(Double(newer)) }
            if let anchor = pendingAnchor { opts["anchor"] = .string(anchor); pendingAnchor = nil }
            // Built in one buffer of the exact size: every intermediate copy of a long lesson's payload (8 MB for 4,000
            // messages) would stay in the footprint, as freed large blocks do.
            let parts = page.map(Self.script), tail = "], " + JSON.object(opts).compact + ")"
            var js = "T.reset(["
            js.reserveCapacity(parts.reduce(js.utf8.count + tail.utf8.count) { $0 + $1.utf8.count + 1 })
            for (i, p) in parts.enumerated() { if i > 0 { js += "," }; js += p }
            js += tail
            run(js, replaceQueue: true)
            if let s = session { language(AppModel.shared.extensions.get(LanguageExtension.self)?.state(for: s)) }
            if ready {
                web?.evaluateJavaScript("document.querySelectorAll('.msg').length + ' rendered / ' + document.body.scrollHeight + 'px'") { r, _ in
                    AppLog.write("reset \(conversation.title.prefix(40)): \(windowCount) messages → \(r ?? "?")")
                }
            }
            for p in AppModel.shared.interactions.pending.values where p.conversationID == conversation.id { interaction(p, active: true) }
            setStatus(session?.status)
        }

        func upsert(_ message: ChatMessage) {
            flushDeltas()
            // Something new while reading back: the page returns to the live window (which has the new message).
            if browse != nil, let s = session {
                shown = Self.pageWindow
                reset(s.messages, conversation: s.conversation)
                return
            }
            run("T.upsert(\(Self.script(message)))")
            guard let s = session else { return }
            if pageFirst == nil { pageFirst = s.messages.first?.id }   // a lesson that started empty: its page starts here
            // A long session keeps adding to the page: when a turn starts with more than a step past the window rendered,
            // the oldest leave the page (still in memory, behind "Show earlier").
            guard message.role == .user, !message.isToolResultOnly, let first = pageIndex(s),
                  s.messages.count - first > Self.pageWindow + Self.pageStep else { return }
            shown = Self.pageWindow
            let start = Self.pageStart(s.messages, keep: shown)
            pageFirst = s.messages[start].id
            run("T.trimBefore(\(JSON.string(s.messages[start].id).compact), \(s.base + start))")
        }

        func delta(_ messageID: String, index: Int, kind: Block.Kind, text: String) {
            if let last = pendingDeltas.last, last.id == messageID, last.index == index, last.kind == kind {
                pendingDeltas[pendingDeltas.count - 1].text += text
            } else {
                pendingDeltas.append((messageID, index, kind, text))
            }
            startFrameLoop()
        }

        /// Flush text on the display's own cadence — 120 Hz on ProMotion, 60 Hz elsewhere — so streamed replies move at
        /// the same rate as everything else on screen. A timer here would cap them at a fixed rate the display doesn't share.
        private func startFrameLoop() {
            guard frameLink == nil else { return }
            if let link = web?.displayLink(target: self, selector: #selector(onDisplayFrame(_:))) {
                // ProMotion stays at 120 Hz for the length of the stream (and degrades to the display's own rate otherwise).
                link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
                link.add(to: .main, forMode: .common)
                frameLink = link
            } else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.008) { [weak self] in
                    MainActor.assumeIsolated { self?.flushFrame() }
                }
            }
        }

        @objc private func onDisplayFrame(_ link: CADisplayLink) { flushFrame() }

        private func flushFrame() {
            if pendingDeltas.isEmpty { stopFrameLoop(); return }
            flushDeltas()
        }

        /// Called when the view goes away (and once the stream goes idle): the link holds its target.
        func stopFrameLoop() {
            frameLink?.invalidate()
            frameLink = nil
        }

        private func flushDeltas() {
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

        func language(_ state: LanguageState?) {
            run("T.setLanguage(\(state.map { $0.json.compact } ?? "null"))")
        }

        func trimBefore(_ messageID: String, earlier: Int) {
            if let s = session, pageIndex(s) == nil { pageFirst = messageID }   // the page started before the cut
            if browse != nil { return }   // the page shows something else; it comes back live on the next message
            run("T.trimBefore(\(JSON.string(messageID).compact), \(earlier))")
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

        /// A message as JSON text for the page, in one pass: through a JSON tree it took three, ~200 ms of the main thread
        /// to open a 4,000-message lesson.
        static func script(_ m: ChatMessage) -> String {
            (try? scriptEncoder.encode(m)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
        }
        private static let scriptEncoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()

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
            let sp = Signposts.begin("render", "\(js.prefix(9)) \(js.utf8.count) bytes")
            web.evaluateJavaScript(js) { _, err in
                Signposts.end("render", sp)
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
                // The fresh reset below supersedes a reset queued before the page was ready (it rendered the lesson twice).
                var q = queue; queue.removeAll()
                if let i = q.lastIndex(where: { $0.hasPrefix("T.reset(") }) { q.removeSubrange(...i) }
                if let s = session { reset(s.messages, conversation: s.conversation) }
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
                else { app.speech.speak(j["text"]?.string ?? "", language: j["lang"]?.string, voice: app.settings.value.voiceIdentifier,
                                        rate: app.settings.value.speechRate * min(1.5, max(0.3, j["rate"]?.double ?? 1))) }
            case "dictate":
                // A `speak` question: the Mac listens in the target language and the card shows what it heard.
                guard let key = j["id"]?.string else { return }
                if j["op"]?.string == "stop" { app.speech.stopListening(); return }
                app.speech.dictate(language: j["lang"]?.string) { [weak self] text, final in
                    self?.run("T.dictation(\(JSON.string(key).compact),\(JSON.string(text).compact),\(final))")
                }
            case "vocab":
                // The Save button on a ```vocab card: into the learner's vocabulary and its flashcard deck.
                guard let s = session, let w = j["word"], let term = w["term"]?.string, let meaning = w["meaning"]?.string else { return }
                guard let lang = w["lang"]?.string.flatMap(Languages.code) ?? s.language?.target ?? s.services.study.languageProfiles().first(where: { $0.role == "target" })?.code else {
                    run("T.notice('Which language is this word in? Ask the teacher to set your language profile, then save it again.')"); return
                }
                if s.services.study.addVocab(lang: lang, term: term, reading: w["reading"]?.string, meaning: meaning, pos: w["pos"]?.string, example: w["example"]?.string,
                                             exampleMeaning: w["example_meaning"]?.string, notes: w["notes"]?.string, source: s.id) != nil {
                    EventBus.publish(.studyDataChanged)
                    run("T.notice(\(JSON.string("Saved “\(term)” to your \(Languages.englishName(lang)) vocabulary (reviewed as a flashcard).").compact))")
                }
            case "memory":
                app.selection = .memory
            case "older":
                guard let s = session else { return }
                let first = pageIndex(s) ?? 0
                // A reset mid-reply would wipe the text streamed so far (it lives in the loop until the step ends).
                if s.isRunning {
                    run("T.earlier(\(s.base + first)); T.notice('Earlier messages can be shown once this reply finishes.')")
                    return
                }
                // In memory and still within the page's bound: reveal a step of the live window.
                if browse == nil, let k = Self.revealStart(s.messages, first: first, step: Self.pageStep), s.messages.count - k <= Self.pageMax {
                    // Keep the view on the first message the learner was looking at (a tool result renders no element).
                    pendingAnchor = s.messages[first...].first(where: Self.learner)?.id ?? pageFirst
                    shown = s.messages.count - k
                    reset(s.messages, conversation: s.conversation)
                    return
                }
                // Otherwise read back from disk, a step at a time, keeping at most `pageMax` on the page.
                let current = browse ?? (from: s.base + first, to: s.totalCount)
                guard current.from > 0 else { run("T.earlier(0)"); return }
                let from = max(0, current.from - Self.pageStep)
                showBrowse(from: from, to: min(current.to, from + Self.pageMax), anchorAt: current.from, session: s)
            case "newer":
                guard let s = session, let b = browse else { return }
                let total = s.totalCount, to = min(total, b.to + Self.pageStep), from = max(b.from, to - Self.pageMax)
                let anchorAt = b.to - 1
                if to >= total, from >= s.base {   // back to the live window
                    shown = max(Self.pageWindow, total - from)
                    pendingAnchor = (anchorAt - s.base) >= 0 && (anchorAt - s.base) < s.messages.count ? s.messages[anchorAt - s.base].id : nil
                    reset(s.messages, conversation: s.conversation)
                } else {
                    showBrowse(from: from, to: to, anchorAt: anchorAt, session: s)
                }
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
                // "Continue: <course>" on the welcome screen links the board before the first message, like Progress does.
                if let b = j["board"]?.string, let s = session, s.services.study.board(b) != nil { s.services.study.link(board: b, lesson: s.id) }
                if let t = j["text"]?.string { session?.send(t) }
            case "study":
                // A hint or solution opened on a ```problem: logged as help; a solution seen without an attempt also goes to
                // the tutor with the learner's next message.
                guard let s = session else { return }
                s.services.study.recordResponse(subject: j["subject"]?.string, concept: j["concept"]?.string, correct: nil, certainty: nil,
                                                help: j["event"]?.string == "solution" ? .solution : .hint, source: "problem", conversationID: s.id)
                if let note = j["note"]?.string, !note.isEmpty, !s.studyNotes.contains(note) { s.studyNotes.append(String(note.prefix(400))) }
                EventBus.publish(.studyDataChanged)
            case "visualError":
                // A ```visual in the latest reply failed in the learner's view: the teacher hears it with the next message.
                guard let s = session, let msg = j["msg"]?.string else { return }
                let kind = j["kind"]?.string ?? "visual"
                let note = "A ```\(kind) block in your last reply (“\(j["title"]?.string ?? kind)”) failed to render for the learner: \(msg). Include a corrected, working version in your next reply."
                if !s.studyNotes.contains(note) { s.studyNotes.append(String(note.prefix(500))) }
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
