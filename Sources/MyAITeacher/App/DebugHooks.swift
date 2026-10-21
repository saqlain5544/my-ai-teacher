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

    static func install() {
        guard enabled else { return }
        AppLog.write("debug hooks enabled")
        DistributedNotificationCenter.default().addObserver(forName: Notification.Name("com.saqlain.myaiteacher.debug"), object: nil, queue: .main) { n in
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
        case "send":
            if let t = cmd["text"]?.string { session?.send(t); AppLog.write("sent: \(t.prefix(80))") }
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
            default: if let id = app.conversations.first?.id { app.selection = .lesson(id) }
            }
        case "newLesson": app.newLesson(mode: cmd["mode"]?.string.flatMap(TeachingMode.init(rawValue:)) ?? .tutor)
        case "setModel":
            if let p = cmd["provider"]?.string, let m = cmd["model"]?.string { session?.setModel(providerID: p, model: m) }
        case "setAccess":
            if let l = cmd["level"]?.string.flatMap(FolderAccess.init(rawValue:)) { app.setAccess(l, for: app.workspace) }
            app.accessPrompt = nil
        case "consolidate": app.extensions.get(MemoryExtension.self)?.consolidateNow()
        case "dismissSheet": app.accessPrompt = nil
        case "openFolder":
            if let p = cmd["path"]?.string { app.openFolder(URL(fileURLWithPath: p)) }
        case "inspector":   // {"action":"inspector","url":"https://…"} | {"action":"inspector","reveal":"/path"} | {"action":"inspector","show":false}
            let app = AppModel.shared
            if let u = cmd["url"]?.string.flatMap(URL.init(string:)) { app.openLink(u) }
            else if let p = cmd["reveal"]?.string { app.reveal(URL(fileURLWithPath: p)) }
            else { app.inspectorShown = cmd["show"]?.bool ?? !app.inspectorShown }
            AppLog.write("inspector shown=\(app.inspectorShown) tab=\(app.inspectorTab.rawValue)")
        case "status":
            AppLog.write("status running=\(session?.isRunning ?? false) msgs=\(session?.messages.count ?? -1) status=\(session?.status ?? "-") error=\(session?.errorMessage ?? "-")")
        case "resize":
            if let w = NSApp.windows.first(where: { $0.isVisible && !($0 is NSPanel) }) {
                w.setFrame(NSRect(x: w.frame.minX, y: w.frame.minY, width: cmd["w"]?.double ?? 1240, height: cmd["h"]?.double ?? 840), display: true)
            }
        default: AppLog.write("unknown debug command: \(cmd.compact)")
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
        let finish: (NSImage?, NSRect) -> Void = { webImage, webFrame in
            let img = NSImage(size: bounds.size)
            img.lockFocus()
            rep.draw(in: bounds)
            if let webImage { webImage.draw(in: webFrame) }
            if let sheetRep {
                NSColor.black.withAlphaComponent(0.25).setFill()
                bounds.fill(using: .sourceOver)
                sheetRep.draw(in: NSRect(x: (bounds.width - sheetSize.width) / 2, y: bounds.height - sheetSize.height - 52, width: sheetSize.width, height: sheetSize.height))
            }
            img.unlockFocus()
            if let tiff = img.tiffRepresentation, let r = NSBitmapImageRep(data: tiff), let png = r.representation(using: .png, properties: [:]) {
                try? png.write(to: URL(fileURLWithPath: path))
                AppLog.write("snapshot saved \(path)")
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
