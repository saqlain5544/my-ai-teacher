import AppKit
import WebKit

/// Test automation, enabled only when launched with MYAITEACHER_DEBUG=1:
///   open --env MYAITEACHER_DEBUG=1 "My AI Teacher.app"
/// then post a distributed notification "com.saqlain.myaiteacher.debug" with a JSON string object:
///   {"action":"snapshot","path":"/tmp/x.png"} | {"action":"eval","js":"…"} | {"action":"send","text":"…"}
///   {"action":"answer","value":{…}}  (resolves the first pending interaction) | {"action":"select","item":"memory"}
///   {"action":"newLesson"} | {"action":"setModel","provider":"minimax","model":"MiniMax-M3"} | {"action":"openFolder","path":"…"} | {"action":"allSessions"} | {"action":"openSession","id":"<prefix>"}
///   perf: {"action":"seedLesson","messages":4000} | {"action":"seedMemories","count":10000} | {"action":"recall"} | {"action":"runTool",…} | {"action":"mark",…}
/// Results are appended to ~/Library/Logs/MyAITeacher.log.
@MainActor
enum DebugHooks {
    static var enabled: Bool { ProcessInfo.processInfo.environment["MYAITEACHER_DEBUG"] == "1" }
    weak static var transcript: WKWebView?

    /// One channel per profile (MYAITEACHER_HOME), so test instances running side by side never act on each other's commands.
    nonisolated static var channel: Notification.Name {
        let home = ProcessInfo.processInfo.environment["MYAITEACHER_HOME"].map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path } ?? ""
        return Notification.Name("com.saqlain.myaiteacher.debug" + (home.isEmpty ? "" : ":" + home))
    }

    static func install() {
        guard enabled else { return }
        AppLog.write("debug hooks enabled on \(channel.rawValue)")
        DistributedNotificationCenter.default().addObserver(forName: channel, object: nil, queue: .main) { n in
            let raw = (n.object as? String) ?? ""
            MainActor.assumeIsolated { handle(JSON.parse(raw) ?? .null) }
        }
    }

    static func handle(_ cmd: JSON) {
        let app = AppModel.shared
        // A command may name its lesson ({"lesson": id}); otherwise it acts on the selected one. Scripts name it: a click in
        // the window (or a notice) that changes the selection must not send their next message nowhere.
        let session: ChatSession? = {
            if let id = cmd["lesson"]?.string, !id.isEmpty { return app.session(for: id) }
            if case .lesson(let id) = app.selection { return app.session(for: id) }
            return nil
        }()
        switch cmd["action"]?.string {
        case "snapshot": snapshot(to: cmd["path"]?.string ?? "/tmp/myaiteacher.png")
        case "eval":
            transcript?.evaluateJavaScript(cmd["js"]?.string ?? "") { r, e in
                AppLog.write("eval → \(e.map { "error: \($0.localizedDescription)" } ?? String(describing: r ?? "nil").prefix(4000))")
            }
        case "models":   // reload every keyed provider's live list, then log what each returned (listing models is free)
            for p in app.availableProviders { app.loadModels(p, force: true) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
                for p in app.availableProviders {
                    let list = app.modelList(p)
                    AppLog.write("models \(p.id): \(list.count) [\(list.prefix(8).joined(separator: ", "))]\(app.modelErrors[p.id].map { " error: \($0.prefix(160))" } ?? "")")
                }
            }
        case "pickerSearch":   // what the model picker lists for a query, from this app's live catalogues
            let q = cmd["query"]?.string ?? ""
            let out = ModelPickerPopover.sections(q, providers: app.availableProviders, models: app.modelList, names: { p, m in app.modelMeta[p]?[m]?.name })
            AppLog.write("picker \"\(q)\": " + out.prefix(4).map { "\($0.provider.id)[\($0.models.prefix(3).joined(separator: ", "))]" }.joined(separator: " · "))
        case "shed":   // what memory pressure does: every rebuildable cache goes (the log says how much was freed)
            MemoryGovernor.shared.shed(critical: cmd["critical"]?.bool == true, reason: "debug")
        case "send":
            if let t = cmd["text"]?.string {
                // An image path attaches it, as a learner's drop would.
                let img = cmd["image"]?.string.flatMap { ImageUtil.loadForModel(URL(fileURLWithPath: $0)) }
                guard let s = session else { AppLog.write("send: no lesson"); return }
                if s.isRunning { AppLog.write("send refused: a reply is still running"); return }
                s.send(t, attachments: img.map { [$0.block] } ?? [])
                AppLog.write("sent: \(t.prefix(80))\(img == nil ? "" : " + image")")
            }
        case "attach":   // {"action":"attach","path":"/tmp/clip.mp3"}: into the composer, as a learner's drop (audio is transcribed)
            guard let s = session, let p = cmd["path"]?.string else { return }
            Composer.attach([URL(fileURLWithPath: p)], to: s)
            AppLog.write("attach: \(p)")
        case "talk":   // {"action":"talk","op":"start"|"heard"|"end","text":"…"}: the spoken conversation, a turn as if heard
            guard let s = session else { return }
            switch cmd["op"]?.string {
            case "start": s.talk.quiet = cmd["quiet"]?.bool == true; s.talk.start(s, listenNow: !s.talk.quiet)
            case "heard": s.talk.simulateHeard(cmd["text"]?.string ?? "")
            case "end": s.talk.end()
            default: AppLog.write("talk: phase \(s.talk.phase) turns \(s.talk.turns) heard \(s.talk.heard)")
            }
        case "speakFile":   // {"action":"speakFile","key":"toolId:qi","path":"/tmp/take.aiff","target":"…","lang":"zh"}: a speak take from a file
            guard let key = cmd["key"]?.string, let p = cmd["path"]?.string, let target = cmd["target"]?.string, let lang = cmd["lang"]?.string else { return }
            let web = transcript
            Task { @MainActor in
                guard let s = try? await MediaTranscript.samples(URL(fileURLWithPath: p)) else { AppLog.write("speakFile: unreadable"); return }
                let info = await Speech.pitchInfo(samples: s, rate: 16_000, target: target, lang: lang)
                let x: JSON = ["engine": "audio file (debug)", "pitch": info ?? .null]
                _ = try? await web?.evaluateJavaScript("T.dictation(\(JSON.string(key).compact),\(JSON.string(cmd["heard"]?.string ?? target).compact),true,\(x.compact))")
                AppLog.write("speakFile: \(info?["prosody"]?.compact.prefix(300) ?? "no prosody")")
            }
        case "importVocab":   // {"action":"importVocab","path":"/tmp/words.txt","lang":"es"}: what the Progress screen's Import does
            guard let p = cmd["path"]?.string, let lang = cmd["lang"]?.string.flatMap(Languages.code) else { return }
            let study = app.services.study
            Task { @MainActor in
                do { AppLog.write("importVocab: " + (try await VocabTransfer.importFile(URL(fileURLWithPath: p), lang: lang, into: study))) }
                catch { AppLog.write("importVocab: \(error.localizedDescription)") }
            }
        case "sendDraft":   // sends what the composer holds (text and attachments), once nothing is still being transcribed
            guard let s = session, s.pendingMedia.isEmpty, !s.isRunning else { AppLog.write("sendDraft: not ready"); return }
            let blocks = s.attachments.map(\.block); let text = cmd["text"]?.string ?? s.draft
            s.attachments = []; s.draft = ""
            s.send(text, attachments: blocks)
            AppLog.write("sent draft with \(blocks.count) attachment(s)")
        case "answer":
            // Only answers an interaction named explicitly (by tool-call id or title), never the learner's own.
            let match = app.interactions.pending.values.first { p in
                if let id = cmd["id"]?.string { return p.id == id }
                if let t = cmd["title"]?.string { return p.payload["title"]?.string == t }
                return false
            }
            if let p = match { app.interactions.resolve(p.id, cmd["value"] ?? .null); AppLog.write("answered \(p.kind) \(p.id)") }
            else { AppLog.write("answer: no pending interaction matches id/title") }
        case "pending":
            AppLog.write("pending: " + app.interactions.pending.values.map { "\($0.kind) id=\($0.id) conv=\($0.conversationID.prefix(8)) \($0.payload.compact.prefix(400))" }.joined(separator: " | "))
        case "sessions":
            AppLog.write("sessions: " + app.conversations.prefix(10).map { c in
                "\(c.id.prefix(8)) \(c.title.prefix(30)) running=\(app.isRunning(c.id))"
            }.joined(separator: " | "))
        case "allSessions":
            app.refreshSessions()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(600))
                AppLog.write("allSessions: folder=\(app.workspace.url.path) active=\(app.activeCount) " + app.allSessions.prefix(20).map { e in
                    "\(e.id.prefix(8)) [\(e.folderName)] \(e.conversation.mode.rawValue) \(e.conversation.title.prefix(30)) \(app.activity(e.id))"
                }.joined(separator: " | "))
            }
        case "openSession":
            if let id = cmd["id"]?.string, let e = app.allSessions.first(where: { $0.id.hasPrefix(id) }) { app.openSession(e.id, folder: e.folder) }
            else { AppLog.write("openSession: no session \(cmd["id"]?.string ?? "") in the list (run allSessions first)") }
        case "select":
            switch cmd["item"]?.string {
            case "sessions": app.selection = .sessions
            case "memory": app.selection = .memory
            case "progress": app.selection = .progress
            case "flashcards": app.selection = .flashcards
            case "insights": app.selection = .insights
            case "tasks": app.selection = .tasks
            default: if let id = cmd["id"]?.string ?? app.conversations.first?.id { app.selection = .lesson(id) }
            }
        case "draft":   // {"action":"draft","text":"/re"}: what's typed in the composer (its `/` menu follows)
            session?.draft = cmd["text"]?.string ?? ""
        case "quick": app.quickQuestion()
        case "stop": session?.stop(); AppLog.write("stopped")
        case "quit": NSApp.terminate(nil)   // a real quit (willTerminate runs), for this test instance only
        case "newLesson": app.newLesson(mode: cmd["mode"]?.string.flatMap(TeachingMode.init(rawValue:)) ?? .tutor)
        case "setModel":
            if let p = cmd["provider"]?.string, let m = cmd["model"]?.string { session?.setModel(providerID: p, model: m) }
        case "setAccess":
            if let l = cmd["level"]?.string.flatMap(FolderAccess.init(rawValue:)) { app.setAccess(l, for: app.workspace) }
            app.accessPrompt = nil
        case "consolidate": app.extensions.get(MemoryExtension.self)?.consolidateNow()
        case "steer":   // {"action":"steer","id":"A1","text":"…"}: a learner's note to a running sub-agent (the Agents panel's box)
            let ok = cmd["id"]?.string.flatMap { SubAgentCenter.shared.run($0) }?.steer(cmd["text"]?.string ?? "", from: "learner") ?? false
            AppLog.write("steer \(cmd["id"]?.string ?? "?"): \(ok ? "sent" : "not running")")
        case "runtime": AppLog.write("runtime: " + Runtime.metrics.json.compact)
        case "dismissSheet": app.accessPrompt = nil
        case "openFolder":
            if let p = cmd["path"]?.string { app.openFolder(URL(fileURLWithPath: p)) }
        case "inspector":   // {"action":"inspector","url":"https://…"} | {"action":"inspector","reveal":"/path"} | {"action":"inspector","show":false}
            let app = AppModel.shared
            if let u = cmd["url"]?.string.flatMap(URL.init(string:)) { app.openLink(u) }
            else if let p = cmd["reveal"]?.string { app.reveal(URL(fileURLWithPath: p)) }
            else if let t = cmd["tab"]?.string.flatMap(InspectorTab.init(rawValue:)) { app.inspectorTab = t; app.inspectorShown = true }
            else { app.inspectorShown = cmd["show"]?.bool ?? !app.inspectorShown }
            AppLog.write("inspector shown=\(app.inspectorShown) tab=\(app.inspectorTab.rawValue)")
        case "report":   // {"action":"report","path":"/tmp/r.json"}: lesson state + rendered-page health, for scripts/e2e-live.py
            report(session, to: cmd["path"]?.string ?? "/tmp/myaiteacher-report.json")
        case "browser":   // {"action":"browser","js":"document.title"}: evaluated in the agent browser's active tab (page world)
            guard let tab = AgentBrowser.shared.active else { AppLog.write("browser → no tab"); return }
            tab.web.evaluateJavaScript(cmd["js"]?.string ?? "location.href") { r, e in
                AppLog.write("browser → \(e.map { "error: \($0.localizedDescription)" } ?? String(describing: r ?? "nil").prefix(4000))")
            }
        case "status":
            AppLog.write("status running=\(session?.isRunning ?? false) msgs=\(session?.messages.count ?? -1) status=\(session?.status ?? "-") error=\(session?.errorMessage ?? "-")")
        case "resize":
            if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                // Optional x/y (top-left, in screen points from the top of the main screen): side-by-side test windows.
                let h = cmd["h"]?.double ?? 840, screen = w.screen ?? NSScreen.main
                let x = cmd["x"]?.double ?? w.frame.minX
                let y = cmd["y"].flatMap(\.double).map { Double(screen?.frame.maxY ?? CGFloat(h)) - $0 - h } ?? w.frame.minY
                if w.styleMask.contains(.fullScreen) { w.toggleFullScreen(nil) }
                w.setFrame(NSRect(x: x, y: y, width: cmd["w"]?.double ?? 1240, height: h), display: true)
            }
        case "front":   // bring this instance's window forward (several test instances share one screen)
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) })?.makeKeyAndOrderFront(nil)
        // Perf workloads (scripts/perf): synthetic data at scale, and the hot paths run on their own.
        case "mark":   // {"action":"mark","name":"…"}: brackets a workload in the signpost timeline
            Signposts.event("mark", cmd["name"]?.string ?? "")
            AppLog.write("mark \(cmd["name"]?.string ?? "")")
        case "seedLesson": PerfSeed.lesson(cmd["messages"]?.int ?? 3000, title: cmd["title"]?.string ?? "Perf lesson")
        case "seedMemories": PerfSeed.memories(cmd["count"]?.int ?? 10_000)
        case "recall":   // on the main thread, as the per-message recall in MemoryExtension.willSend runs
            let hub = app.services.memory, text = cmd["text"]?.string ?? "How does the chain rule work for derivatives?"
            let ms = (0..<(cmd["times"]?.int ?? 5)).map { _ in
                let t0 = DispatchTime.now().uptimeNanoseconds
                _ = hub.recall(text, core: "")
                return Int((DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000)
            }
            AppLog.write("recall ms=\(ms) items=\(hub.count())")
        case "runTool":   // {"action":"runTool","name":"web_fetch","input":{…}}: one tool call outside any lesson
            guard let name = cmd["name"]?.string, let tool = ToolRegistry.byName[name], let p = app.settings.provider(app.settings.value.providerID) else {
                AppLog.write("runTool: unknown tool"); return
            }
            let ctx = ToolContext(conversationID: "perf", workspace: app.workspace.url, services: app.services, interactions: app.interactions,
                                  toolCallID: UUID().uuidString, client: p.client(apiKey: KeyStore.shared.key(for: p)), model: app.settings.value.model, progress: { _ in })
            let input = cmd["input"] ?? .object([:])
            Task {
                let t0 = Date()
                let r: String
                do { let out = try await tool.runBounded(input, ctx); r = "ok=\(!out.isError) chars=\(out.text.count)" } catch { r = "error: \(error.localizedDescription)" }
                AppLog.write("runTool \(name) \(r) ms=\(Int(Date().timeIntervalSince(t0) * 1000))")
            }
        default: AppLog.write("unknown debug command: \(cmd.compact)")
        }
    }

    /// Rendered-page health: visible error boxes, spinners still turning, diagrams never drawn, and the latest reply's text.
    static let healthJS = """
    (() => { const all = s => Array.from(document.querySelectorAll(s));
      const last = document.querySelector('.msg.assistant.last');
      return JSON.stringify({ messages: all('.msg').length,
        errors: all('.comp-error, .diagram-error, .math-error, .katex-error, .katex [style*="#cc0000"], .msg-error, .visual-error:not([hidden])').map(e => e.textContent.trim().slice(0, 300)),
        spinners: all('.tool .spinner').length, pendingDiagrams: all('.mermaid-block[data-pending]').length,
        visuals: all('.visual iframe').length, katex: all('.katex').length, diagrams: all('.mermaid-block svg').length,
        tables: all('.md table').length, practice: all('.practice').length, tools: all('[data-tool-id]').map(e => e.getAttribute('data-tool-id')),
        lastText: last ? last.innerText.slice(-2000) : '' }); })()
    """

    static func report(_ session: ChatSession?, to path: String) {
        let app = AppModel.shared
        let clip = { (s: String?, n: Int) in s.map { JSON.string(String($0.prefix(n))) } ?? .null }
        let msgs: [JSON] = (session?.messages ?? []).map { m in
            .object(["role": .string(m.role.rawValue), "error": clip(m.error, 400), "model": clip(m.model, 80),
                     "usage": m.usage.map { .object(["input": .number(Double($0.input)), "output": .number(Double($0.output)), "cacheRead": .number(Double($0.cacheRead))]) } ?? .null,
                     "turn": m.turn.map { t in .object(["duration": .number(t.duration), "steps": .number(Double(t.steps))]) } ?? .null,
                     "blocks": .array(m.blocks.map { b in
                         .object(["kind": .string(b.kind.rawValue), "name": clip(b.name, 60), "id": clip(b.id, 60), "isError": .bool(b.isError ?? false),
                                  "text": clip(b.text, 1200), "input": b.input.map { JSON.string(String($0.compact.prefix(600))) } ?? .null])
                     })])
        }
        var out: [String: JSON] = [
            "running": .bool(session?.isRunning ?? false), "status": clip(session?.status, 200), "error": clip(session?.errorMessage, 400),
            "lesson": clip(session?.id, 60), "folder": .string(app.workspace.url.path), "messages": .array(msgs),
            "base": .number(Double(session?.base ?? 0)),   // messages before the in-memory window (long lessons trim it)
            "pending": .array(app.interactions.pending.values.map { .object(["id": .string($0.id), "kind": .string($0.kind), "payload": $0.payload,
                                                                                 "lesson": .string($0.conversationID)]) }),
            "agents": .array(SubAgentCenter.shared.runs(in: session?.id).map(\.debugJSON)), "runtime": Runtime.metrics.json,
            "browser": .array(AgentBrowser.shared.tabs.map { .object(["id": .number(Double($0.id)), "url": .string($0.url?.absoluteString ?? ""), "title": .string($0.title)]) }),
        ]
        let write = {
            if let d = try? JSONEncoder().encode(JSON.object(out)) { try? d.write(to: URL(fileURLWithPath: path), options: .atomic) }
        }
        guard let web = transcript else { write(); return }
        web.evaluateJavaScript(healthJS) { r, _ in
            out["page"] = (r as? String).flatMap { JSON.parse($0) } ?? .null
            write()
        }
    }

    /// Renders the main window offscreen (works even when the window is on another Space), web view included.
    static func snapshot(to path: String) {
        guard let window = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) && $0.contentView != nil }),
              let view = window.contentView?.superview ?? window.contentView else { AppLog.write("snapshot: no window"); return }
        let bounds = view.bounds
        guard let rep = view.bitmapImageRepForCachingDisplay(in: bounds) else { return }
        view.cacheDisplay(in: bounds, to: rep)
        // Attached sheets (e.g. the folder-access sheet) are separate windows: render them on top.
        var sheetRep: NSBitmapImageRep?
        var sheetSize = NSSize.zero
        if let sheet = window.attachedSheet, let sv = sheet.contentView?.superview ?? sheet.contentView,
           let r = sv.bitmapImageRepForCachingDisplay(in: sv.bounds) {
            sv.cacheDisplay(in: sv.bounds, to: r)
            sheetRep = r; sheetSize = sv.bounds.size
        }
        // Composited straight into one bitmap and encoded, all inside a pool: going through NSImage + TIFF left ~140 MB of
        // image caches behind after a test run's snapshots.
        let finish: (NSImage?, NSRect) -> Void = { webImage, webFrame in
            autoreleasepool {
                guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh, bitsPerSample: 8,
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
                else { return }
                // The point size before the context: a context made first draws at 1x, into a quarter of a Retina bitmap.
                out.size = bounds.size
                guard let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
                NSGraphicsContext.saveGraphicsState()
                NSGraphicsContext.current = ctx
                rep.draw(in: bounds)
                if let webImage { webImage.draw(in: webFrame) }
                if let sheetRep {
                    NSColor.black.withAlphaComponent(0.25).setFill()
                    bounds.fill(using: .sourceOver)
                    sheetRep.draw(in: NSRect(x: (bounds.width - sheetSize.width) / 2, y: bounds.height - sheetSize.height - 52, width: sheetSize.width, height: sheetSize.height))
                }
                NSGraphicsContext.restoreGraphicsState()
                if let png = out.representation(using: .png, properties: [:]) {
                    try? png.write(to: URL(fileURLWithPath: path))
                    AppLog.write("snapshot saved \(path)")
                }
            }
        }
        if let web = transcript, web.window === window {
            let frame = web.convert(web.bounds, to: view)
            web.takeSnapshot(with: nil) { image, _ in finish(image, frame) }
        } else {
            finish(nil, .zero)
        }
    }
}

/// Synthetic data at scale for perf runs, written straight to the stores in the background.
enum PerfSeed {
    /// A lesson of `n` messages in turns of four: a question, a step with a tool call, its result (4 KB; 30 KB every tenth
    /// turn) and a reply with Markdown, maths, code and a table (a Mermaid diagram every 25th turn). Opened when written.
    @MainActor static func lesson(_ n: Int, title: String) {
        let app = AppModel.shared, store = app.services.conversations
        var c = Conversation(providerID: app.settings.value.providerID, model: app.settings.value.model)
        c.title = title
        let conv = c
        Task.detached(priority: .userInitiated) {
            let t0 = Date(), start = Date().addingTimeInterval(-Double(n) * 30)
            try? store.db.transaction {
                for i in 0..<n {
                    var m = message(i)
                    m.createdAt = start.addingTimeInterval(Double(i) * 30)
                    store.upsert(m, conversationID: conv.id, seq: i)
                }
            }
            store.save(conv)
            await MainActor.run {
                app.conversations.insert(conv, at: 0)
                app.selection = .lesson(conv.id)
                AppLog.write("seeded lesson \(conv.id) \(n) messages in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
            }
        }
    }

    static func message(_ i: Int) -> ChatMessage {
        let turn = i / 4, call = "perf_\(turn)"
        switch i % 4 {
        case 0: return ChatMessage(role: .user, blocks: [.text("Question \(turn): how does the chain rule apply to sin(x^\(turn % 7 + 2))? Show a worked example.")])
        case 1: return ChatMessage(role: .assistant, blocks: [.text("Let me check a reference first."),
                                                            .toolUse(id: call, name: "web_fetch", input: ["url": .string("https://example.org/calculus/\(turn)")])])
        case 2:
            let para = "The chain rule says that the derivative of f(g(x)) is f'(g(x)) · g'(x). Reference section \(turn) works through composite functions. "
            return ChatMessage(role: .user, blocks: [.toolResult(id: call, name: "web_fetch", content: String(repeating: para, count: turn % 10 == 0 ? 220 : 30))])
        default:
            var text = """
            ## Step \(turn): the chain rule

            For $f(x) = \\sin(x^{\(turn % 7 + 2)})$ the outer function is $\\sin u$ and the inner one is $u = x^{\(turn % 7 + 2)}$, so

            $$f'(x) = \\cos(x^{\(turn % 7 + 2)}) \\cdot \(turn % 7 + 2)x^{\(turn % 7 + 1)}$$

            1. **Differentiate the outer function** and keep the inner one as it is.
            2. **Multiply** by the derivative of the inner function.
            3. Simplify, and check the result numerically at $x = 1$.

            ```python
            import math
            h = 1e-6
            f = lambda x: math.sin(x ** \(turn % 7 + 2))
            print((f(1 + h) - f(1 - h)) / (2 * h), math.cos(1) * \(turn % 7 + 2))
            ```

            | x | f(x) | f'(x) |
            |---|------|-------|
            | 0 | 0 | 0 |
            | 1 | 0.841 | \(String(format: "%.3f", cos(1.0) * Double(turn % 7 + 2))) |

            Try it yourself: what is the derivative of $\\cos(3x^2)$?
            """
            if turn % 25 == 0 { text += "\n\n```mermaid\nflowchart LR\n  A[outer f] --> B[inner g]\n  B --> C[f'(g) · g']\n```" }
            var m = ChatMessage(role: .assistant, blocks: [.text(text)], model: "perf-synthetic")
            m.turn = TurnMetrics(duration: 6.5, timeToFirstToken: 0.8, steps: 2, usage: Usage(input: 4200, output: 520))
            return m
        }
    }

    /// `n` learner memories with real embeddings (as recall sees them), across kinds and subjects. At utility priority:
    /// embedding 10k texts fills every core, and above that the main thread waited for a core (stalls that weren't the app's).
    @MainActor static func memories(_ n: Int) {
        let store = AppModel.shared.services.memory.learner
        Task.detached(priority: .utility) {
            let t0 = Date()
            let subjects = ["calculus", "algebra", "physics", "chemistry", "biology", "history", "spanish", "programming", "statistics", "music"]
            let topics = ["derivatives", "integrals", "limits", "vectors", "forces", "reactions", "cells", "verbs", "recursion", "probability",
                          "matrices", "waves", "genetics", "loops", "scales", "energy", "proofs", "series", "graphs", "sorting"]
            let kinds: [MemoryKind] = [.knowledge, .fact, .misconception, .preference, .episode, .goal]
            let rows = (0..<n).map { i -> (kind: MemoryKind, content: String, subject: String?, vector: [Float]?) in
                let s = subjects[i % subjects.count], t = topics[(i / 3) % topics.count], k = kinds[i % kinds.count]
                let text = "Learner \(["understands", "confuses", "practised", "asked about", "wants to master", "struggled with"][i % 6]) \(t) in \(s) " +
                    "(case \(i)): \(["worked example with numbers", "visual explanation", "step-by-step proof", "real-world analogy"][i % 4])."
                return (k, text, s, Embedder.shared.vector(text))
            }
            store.bulkInsert(rows)
            AppLog.write("seeded \(n) memories in \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        }
    }
}
