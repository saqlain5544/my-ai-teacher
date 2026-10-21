import AppKit
import WebKit

/// Headless renderer suite: `MyAITeacher --webtest [suite.js] [--dark] [--only name]` loads the real transcript page
/// (same scheme handler, navigation policy and libraries as the app) in an offscreen window, runs the suite and exits
/// non-zero when a test fails or the page logs an error a test didn't expect. The suite talks back with
/// {type:'webtest', event:'result'|'done'|'log'} messages; anything else the page posts is ignored here.
@MainActor
final class WebTest: NSObject, WKNavigationDelegate, WKScriptMessageHandler {
    private let suite: String
    private let only: String?
    private var web: WKWebView!
    private var window: NSWindow!
    private var pageErrors: [String] = []
    private var injected = false
    private var watchdogMode = false
    private var watchdog: WebWatchdog?
    private var restarted = false
    private static let loopingLesson = #"[{"id":"u","role":"user","blocks":[{"kind":"text","text":"q"}]},{"id":"a","role":"assistant","blocks":[{"kind":"text","text":"```visual\n<!-- title: Loop -->\n<script>setTimeout(() => { while (true) {} }, 200)</script>\n```"}]}]"#
    private var running = "loading the page"
    private static var current: WebTest?

    private init(suite: String, only: String?) { self.suite = suite; self.only = only }

    nonisolated static func main(_ args: [String]) -> Never {
        let path = args.first { $0.hasSuffix(".js") } ?? "Tests/web/renderer.test.js"
        guard let suite = args.contains("--watchdog") ? "" : try? String(contentsOfFile: path, encoding: .utf8) else { print("cannot read \(path)"); exit(2) }
        let only = args.firstIndex(of: "--only").flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil }
        MainActor.assumeIsolated {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            if args.contains("--dark") { app.appearance = NSAppearance(named: .darkAqua) }
            let t = WebTest(suite: suite, only: only)
            t.watchdogMode = args.contains("--watchdog")
            t.start()
            current = t
            DispatchQueue.main.asyncAfter(deadline: .now() + 180) { print("TIMEOUT after 180 s in: \(t.running)"); exit(3) }
            app.run()
        }
        exit(0)
    }

    private func start() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.userContentController.add(self, name: "bridge")
        config.setURLSchemeHandler(TeacherLibSchemeHandler(), forURLScheme: TeacherLibSchemeHandler.scheme)
        config.userContentController.addUserScript(WKUserScript(source: TranscriptView.logBridge, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        web = WKWebView(frame: NSRect(x: 0, y: 0, width: 900, height: 1400), configuration: config)
        web.navigationDelegate = self
        web.setValue(false, forKey: "drawsBackground")
        // A real (offscreen) window keeps requestAnimationFrame, layout and iframe loading running as in the app.
        window = NSWindow(contentRect: NSRect(x: -30000, y: -30000, width: 900, height: 1400), styleMask: .borderless, backing: .buffered, defer: false)
        window.contentView = web
        window.orderFrontRegardless()
        // An offscreen window counts as occluded, which would pause rAF; the app's own window is visible.
        let occlusion = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        if web.responds(to: occlusion) { web.perform(occlusion, with: nil) }
        let dir = AppPaths.webResources
        web.loadFileURL(dir.appendingPathComponent("index.html"), allowingReadAccessTo: dir)
    }

    nonisolated func userContentController(_ ucc: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any] else { return }
        let j = JSON(any: body)
        MainActor.assumeIsolated { self.handle(j) }
    }

    private func handle(_ j: JSON) {
        switch j["type"]?.string {
        case "ready" where watchdogMode:
            // Recovery check: a looping visual freezes the page; the watchdog must restart it, and the reload (visuals
            // paused) must answer again.
            if !restarted {
                print("  · rendering a visual that loops forever")
                web.evaluateJavaScript("T.reset(\(Self.loopingLesson), {}); 0") { _, _ in }
                watchdog = WebWatchdog(web: web, isVisible: { _ in true }) { [weak self] in
                    print("  · watchdog: page unresponsive, restarting it"); self?.restarted = true
                }
            } else {
                watchdog?.stop()
                web.evaluateJavaScript("T.reset(\(Self.loopingLesson), {pauseVisuals: true}); 0") { _, _ in }
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                    self?.web.evaluateJavaScript("!!document.querySelector('.visual-paused [data-act=\"visual-run\"]')") { r, _ in
                        let ok = (r as? Bool) == true
                        print(ok ? "  ✓ page restarted and answers again, visual paused behind ▶ Run" : "  ✗ page did not recover")
                        exit(ok ? 0 : 1)
                    }
                }
            }
        case "ready":
            guard !injected else { return }
            injected = true
            let filter = only.flatMap { try? JSONEncoder().encode($0) }.flatMap { String(data: $0, encoding: .utf8) }.map { "window.__only = \($0);" } ?? ""
            web.evaluateJavaScript(filter + suite + "\n;0") { _, err in
                if let err { print("SUITE FAILED TO LOAD: \(err)"); exit(2) }
            }
        case "log" where j["level"]?.string == "error":
            pageErrors.append(j["text"]?.string ?? "")
        case "webtest":
            switch j["event"]?.string {
            case "result":
                let ok = j["ok"]?.bool == true
                let ms = j["ms"]?.double.map { String(format: " (%.0f ms)", $0) } ?? ""
                print((ok ? "  ✓ " : "  ✗ ") + (j["name"]?.string ?? "?") + ms)
                if !ok { print("      " + (j["error"]?.string ?? "").replacingOccurrences(of: "\n", with: "\n      ")) }
            case "start": running = j["name"]?.string ?? ""
            case "log": print("    · " + (j["text"]?.string ?? ""))
            case "done":
                let passed = j["passed"]?.int ?? 0, failed = j["failed"]?.int ?? 0
                let expected = Set((j["expectedErrors"]?.array ?? []).compactMap(\.string))
                let unexpected = pageErrors.filter { e in !expected.contains { e.contains($0) } }
                for e in unexpected { print("  ✗ page error: \(e.prefix(400))") }
                print("\n\(passed) passed, \(failed) failed, \(unexpected.count) unexpected page errors")
                exit(failed == 0 && unexpected.isEmpty ? 0 : 1)
            default: break
            }
        default: break
        }
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        // Same rule as the transcript: visual iframes load their srcdoc, nothing else navigates.
        if action.targetFrame?.isMainFrame == false { decisionHandler(action.request.url?.scheme == "about" ? .allow : .cancel); return }
        decisionHandler(action.request.url?.isFileURL == true ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard watchdogMode, restarted else { print("WEB CONTENT PROCESS CRASHED"); exit(4) }   // the watchdog reloads it
    }
}
