import Foundation
import WebKit

/// Render/streaming timings from the transcript web view, posted over the existing `bridge` as `{type:'telemetry'}`.
/// The script is injected by TranscriptView (only when telemetry is on). It times every animation-frame callback
/// (the renderer's flush runs there), full transcript resets, and page load, and posts a compact summary every 10 s.
enum WebTelemetry {
    static let script = """
    (function(){
      if (window.__teacherTelemetry) return; window.__teacherTelemetry = true;
      const post = m => { try { window.webkit.messageHandlers.bridge.postMessage(m); } catch (_) {} };
      const now = () => performance.now();
      let frames = [], resets = [], longTasks = 0, longMs = 0;
      const raf = window.requestAnimationFrame.bind(window);
      window.requestAnimationFrame = function (cb) {
        return raf(function (t) { const s = now(); try { cb(t); } finally { const d = now() - s; if (d >= 0.05 && frames.length < 2000) frames.push(+d.toFixed(2)); } });
      };
      const wrapT = () => {
        if (!window.T || window.T.__timed) return !!window.T;
        const orig = window.T.reset;
        window.T.reset = function (messages, opts) {
          const s = now(); try { return orig.apply(this, arguments); }
          finally { resets.push({ ms: +(now() - s).toFixed(2), n: (messages || []).length }); }
        };
        window.T.__timed = true; return true;
      };
      if (!wrapT()) document.addEventListener('DOMContentLoaded', wrapT);
      try { new PerformanceObserver(l => { for (const e of l.getEntries()) { longTasks++; longMs += e.duration; } }).observe({ entryTypes: ['longtask'] }); } catch (_) {}
      const flush = () => {
        if (!frames.length && !resets.length && !longTasks) return;
        post({ type: 'telemetry', frames, resets, longTasks, longMs: Math.round(longMs) });
        frames = []; resets = []; longTasks = 0; longMs = 0;
      };
      setInterval(flush, 10000);
      document.addEventListener('visibilitychange', () => { if (document.hidden) flush(); });
      window.addEventListener('load', () => setTimeout(() => {
        const n = (performance.getEntriesByType && performance.getEntriesByType('navigation')[0]) || {};
        post({ type: 'telemetry', load: { dcl: Math.round(n.domContentLoadedEventEnd || 0), load: Math.round(n.loadEventEnd || now()) } });
      }, 0));
    })();
    """

    /// Converts one bridge message into events (one per message kind; frame samples pre-bucketed).
    static func events(from j: JSON, now: Double = Date().timeIntervalSince1970) -> [TelemetryEvent] {
        var out: [TelemetryEvent] = []
        if let frames = j["frames"]?.array, !frames.isEmpty {
            let v = frames.compactMap(\.double)
            var attrs: [String: Double] = ["n": Double(v.count), "sum": v.reduce(0, +), "max": v.max() ?? 0]
            for x in v { attrs["b\(TelemetryHistogram.bucket(x))", default: 0] += 1 }
            out.append(TelemetryEvent(ts: now, kind: .web, name: "frame", value: v.max() ?? 0, attrs: attrs))
        }
        for r in j["resets"]?.array ?? [] {
            out.append(TelemetryEvent(ts: now, kind: .web, name: "reset", value: r["ms"]?.double ?? 0, attrs: ["messages": r["n"]?.double ?? 0]))
        }
        if let n = j["longTasks"]?.double, n > 0 {
            out.append(TelemetryEvent(ts: now, kind: .web, name: "longtask", value: j["longMs"]?.double ?? 0, attrs: ["n": n, "sum": j["longMs"]?.double ?? 0]))
        }
        if let load = j["load"] {
            out.append(TelemetryEvent(ts: now, kind: .web, name: "load", value: load["load"]?.double ?? 0, attrs: ["dcl": load["dcl"]?.double ?? 0]))
        }
        return out
    }

    nonisolated(unsafe) private static var launchRecorded = false

    /// Bridge entry point (TranscriptView → `case "telemetry"`). Main thread.
    @MainActor
    static func handle(_ j: JSON, webView: WKWebView?, telemetry: Telemetry = .shared) {
        guard telemetry.enabled else { return }
        let now = Date().timeIntervalSince1970
        var events = events(from: j, now: now)
        if j["load"] != nil {
            if let web = webView, web.responds(to: NSSelectorFromString("_webProcessIdentifier")),
               let pid = (web.value(forKey: "_webProcessIdentifier") as? NSNumber)?.int32Value {
                telemetry.sampler.registerWebProcess(pid)
            }
            if !launchRecorded {
                launchRecorded = true
                events.append(TelemetryEvent(ts: now, kind: .launch, value: now - ProcessClock.startTime,
                                             attrs: ["init": TelemetryExtension.startedAt - ProcessClock.startTime]))
            }
        }
        telemetry.record(events)
    }
}
