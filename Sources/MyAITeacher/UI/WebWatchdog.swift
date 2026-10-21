import AppKit
import WebKit

/// Restarts a web view whose page stopped answering. A visual's sandboxed frame shares the page's process, so one
/// endless loop in model-written JavaScript would otherwise freeze the lesson for good. It pings only while the window
/// is visible (a throttled background page must never look like a hang).
@MainActor
final class WebWatchdog {
    static let limit: TimeInterval = 8
    private weak var web: WKWebView?
    private var timer: Timer?
    private var outstanding: Date?
    private let onHang: () -> Void
    private let isVisible: @MainActor (WKWebView) -> Bool

    init(web: WKWebView, isVisible: @escaping @MainActor (WKWebView) -> Bool = { $0.window?.occlusionState.contains(.visible) == true },
         onHang: @escaping () -> Void) {
        self.web = web
        self.isVisible = isVisible
        self.onHang = onHang
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func tick() {
        guard let web else { stop(); return }
        guard isVisible(web), !web.isLoading else { outstanding = nil; return }
        if let t = outstanding {
            guard Date().timeIntervalSince(t) > Self.limit else { return }
            outstanding = nil
            AppLog.write("watchdog: page unresponsive for \(Int(Self.limit)) s, restarting it")
            onHang()
            Self.restart(web)
            return
        }
        outstanding = Date()
        web.evaluateJavaScript("0") { [weak self] _, _ in MainActor.assumeIsolated { self?.outstanding = nil } }
    }

    /// Ends the stuck web content process and loads the page again (WebKit doesn't report a termination it was asked
    /// for, so the delegate's own reload can't be relied on). The page posts `ready` and its owner re-renders.
    static func restart(_ web: WKWebView) {
        let url = web.url
        let kill = ["_killWebContentProcessAndResetState", "_killWebContentProcess"].map(NSSelectorFromString).first { web.responds(to: $0) }
        if let kill { web.perform(kill) }
        // The kill is asynchronous: load once the old process is gone, so the page gets a fresh one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak web] in
            guard let web else { return }
            if let url, url.isFileURL { web.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent()) } else { web.reload() }
        }
    }
}
