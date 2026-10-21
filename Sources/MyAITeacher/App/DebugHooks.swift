import AppKit
import WebKit

/// Test automation, enabled only when launched with MYAITEACHER_DEBUG=1:
///   open --env MYAITEACHER_DEBUG=1 "My AI Teacher.app"
/// then post a distributed notification "com.saqlain.myaiteacher.debug" with a JSON string object:
///   {"action":"snapshot","path":"/tmp/x.png"} | {"action":"eval","js":"…"} | {"action":"send","text":"…"}
///   {"action":"answer","value":{…}}  (resolves the first pending interaction) | {"action":"select","item":"memory"}
///   {"action":"newLesson"} | {"action":"setModel","provider":"minimax","model":"MiniMax-M3"} | {"action":"openFolder","path":"…"}
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
        let session: ChatSession? = { if case .lesson(let id) = app.selection { return app.session(for: id) }; return nil }()
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
        case "shed":   // what memory pressure does: every rebuildable cache goes (the log says how much was freed)
            MemoryGovernor.shared.shed(critical: cmd["critical"]?.bool == true, reason: "debug")
        case "send":
            if let t = cmd["text"]?.string {
                // An image path attaches it, as a learner's drop would.
                let img = cmd["image"]?.string.flatMap { ImageUtil.loadForModel(URL(fileURLWithPath: $0)) }
                session?.send(t, attachments: img.map { [$0.block] } ?? [])
                AppLog.write("sent: \(t.prefix(80))\(img == nil ? "" : " + image")")
            }
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
        case "select":
            switch cmd["item"]?.string {
            case "memory": app.selection = .memory
            case "progress": app.selection = .progress
            case "flashcards": app.selection = .flashcards
            case "insights": app.selection = .insights
            default: if let id = app.conversations.first?.id { app.selection = .lesson(id) }
            }
        case "quick": app.quickQuestion()
        case "stop": session?.stop(); AppLog.write("stopped")
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
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: cmd["w"]?.double ?? 1240, height: cmd["h"]?.double ?? 840), display: true)
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
            "pending": .array(app.interactions.pending.values.map { .object(["id": .string($0.id), "kind": .string($0.kind), "payload": $0.payload]) }),
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
                                                 samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
                      let ctx = NSGraphicsContext(bitmapImageRep: out) else { return }
                out.size = bounds.size
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
