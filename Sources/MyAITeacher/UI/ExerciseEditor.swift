import SwiftUI
import WebKit

/// The right panel's Exercise tab: the lesson's current project in a code editor.
struct ExercisePanel: View {
    @EnvironmentObject var app: AppModel
    @Environment(\.openWindow) private var openWindow
    var lessonID: String?

    var body: some View {
        if let e = current {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Image(systemName: e.passed ? "checkmark.seal.fill" : "chevron.left.forwardslash.chevron.right")
                        .foregroundStyle(e.passed ? .green : .secondary)
                    Text(e.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button { Task { await ExternalEditor.openHelix(e.dir) } } label: { Image(systemName: "terminal") }
                        .buttonStyle(.borderless).help("Open the project in Helix")
                    Button { openWindow(id: "exercise") } label: { Image(systemName: "macwindow.on.rectangle") }
                        .buttonStyle(.borderless).help("Open the editor in its own window")
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                Divider()
                ExerciseEditorView(exerciseID: e.id).id(e.id)
            }
        } else {
            ContentUnavailableView("No exercise yet", systemImage: "chevron.left.forwardslash.chevron.right",
                                   description: Text("In Code mentor mode, ask for a project. Your mentor sets it up here, with tests you don't see."))
        }
    }

    var current: Exercise? {
        if let id = app.exerciseID, let e = ExerciseStore.load(id), lessonID == nil || e.conversationID == lessonID { return e }
        return lessonID.flatMap { ExerciseStore.list(conversationID: $0).first }
    }
}

/// The editor in a window of its own (Window › Exercise, or the panel's pop-out button).
struct ExerciseWindow: View {
    @EnvironmentObject var app: AppModel
    var body: some View {
        if let id = app.exerciseID, ExerciseStore.load(id) != nil {
            ExerciseEditorView(exerciseID: id).id(id)
        } else {
            ContentUnavailableView("No exercise open", systemImage: "chevron.left.forwardslash.chevron.right",
                                   description: Text("Open one from a Code mentor lesson."))
        }
    }
}

/// CodeMirror in a web view (Resources/web/editor.html). Files are the learner's own, on disk: every edit is saved;
/// Run, Test and Submit run sandboxed (`Sandbox`), and Test/Submit only ever show what the hidden tests print.
struct ExerciseEditorView: NSViewRepresentable {
    let exerciseID: String

    func makeCoordinator() -> Coordinator { Coordinator(id: exerciseID) }

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(WeakHandler(context.coordinator), name: "exercise")
        let web = WKWebView(frame: .zero, configuration: config)
        web.setValue(false, forKey: "drawsBackground")
        context.coordinator.web = web
        web.uiDelegate = context.coordinator
        let dir = AppPaths.webResources
        web.loadFileURL(dir.appendingPathComponent("editor.html"), allowingReadAccessTo: dir)
        return web
    }

    func updateNSView(_ web: WKWebView, context: Context) {}

    @MainActor
    final class Coordinator: NSObject, WKScriptMessageHandler, WKUIDelegate {
        let id: String
        weak var web: WKWebView?
        private var busy = false
        init(id: String) { self.id = id }

        private func call(_ fn: String, _ arg: JSON) {
            web?.evaluateJavaScript("EX.\(fn)(\(arg.compact))")
        }

        private func url(_ e: Exercise, _ path: String?) -> URL? {
            path.flatMap(ExerciseStore.safePath).map { e.dir.appendingPathComponent($0) }
        }

        // The page's prompt() and confirm() (new file, rename, delete) as native sheets: a web view shows nothing without these.
        func webView(_ webView: WKWebView, runJavaScriptTextInputPanelWithPrompt prompt: String, defaultText: String?,
                     initiatedByFrame frame: WKFrameInfo, completionHandler: @escaping (String?) -> Void) {
            let a = NSAlert()
            a.messageText = prompt
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
            field.stringValue = defaultText ?? ""
            a.accessoryView = field
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
            a.window.initialFirstResponder = field
            completionHandler(a.runModal() == .alertFirstButtonReturn ? field.stringValue : nil)
        }

        func webView(_ webView: WKWebView, runJavaScriptConfirmPanelWithMessage message: String, initiatedByFrame frame: WKFrameInfo,
                     completionHandler: @escaping (Bool) -> Void) {
            let a = NSAlert()
            a.messageText = message
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Cancel")
            completionHandler(a.runModal() == .alertFirstButtonReturn)
        }

        func load() {
            guard let e = ExerciseStore.load(id) else { return }
            let files = ExerciseStore.read(e.dir)
            call("load", ["id": .string(e.id), "title": .string(e.title), "brief": .string(e.brief), "language": .string(e.language),
                          "folder": .string(e.folder), "canRun": .bool(e.run != nil), "passed": .bool(e.passed), "attempts": .number(Double(e.attempts)),
                          "files": .object(files.mapValues { .string($0) }), "lastOutput": e.lastOutput.map { .string($0) } ?? .null])
        }

        func userContentController(_ c: WKUserContentController, didReceive m: WKScriptMessage) {
            let j = JSON(any: m.body)
            guard let type = j["type"]?.string, var e = ExerciseStore.load(id) else { return }
            let fm = FileManager.default
            switch type {
            case "ready": load()
            case "save":
                guard let u = url(e, j["path"]?.string), let text = j["content"]?.string else { return }
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data(text.utf8).write(to: u, options: .atomic)
            case "create":
                guard let u = url(e, j["path"]?.string), !fm.fileExists(atPath: u.path) else { call("notice", "That file exists or the name isn't allowed."); return }
                try? fm.createDirectory(at: u.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? Data().write(to: u)
                load()
            case "rename":
                guard let a = url(e, j["from"]?.string), let b = url(e, j["to"]?.string), !fm.fileExists(atPath: b.path) else { return }
                try? fm.createDirectory(at: b.deletingLastPathComponent(), withIntermediateDirectories: true)
                try? fm.moveItem(at: a, to: b)
                load()
            case "delete":
                guard let u = url(e, j["path"]?.string) else { return }
                try? fm.removeItem(at: u)
                load()
            case "run", "test", "submit":
                guard !busy else { return }
                if type == "run", e.run == nil { call("output", ["kind": "run", "text": "This project has no run command: use Test.", "ok": false]); return }
                if type == "submit", let s = AppModel.shared.session(for: e.conversationID), s.isRunning {
                    call("output", ["kind": "submit", "text": "Your teacher is still replying. Submit again when it's done.", "ok": false]); return
                }
                busy = true
                call("busy", .string(type))
                Task { @MainActor in
                    let r = type == "run" ? await Sandbox.run(e.run!, in: e.dir, writable: [], timeout: 60)
                                          : await ExerciseStore.runTests(e, project: e.dir)
                    busy = false
                    if type != "run" {
                        e.attempts += 1
                        e.lastOutput = String(r.output.suffix(20_000))
                        e.passed = e.passed || r.passed
                        if type == "submit" { e.submitted += 1 }
                        ExerciseStore.save(e)
                    }
                    call("output", ["kind": .string(type), "text": .string(String(r.output.suffix(60_000))), "ok": .bool(r.passed),
                                    "passed": .bool(e.passed), "attempts": .number(Double(e.attempts))])
                    if type == "submit" { ExerciseActions.send(e, result: r) }
                }
            default: break
            }
        }

    }
}
