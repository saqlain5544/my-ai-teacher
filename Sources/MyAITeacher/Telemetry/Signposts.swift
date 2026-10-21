import Foundation
import Combine
import os

/// os_signpost intervals around the work worth profiling, for Instruments (Points of Interest) and scripts/perf: lesson
/// turns, model streams, tool runs, transcript render batches, SQL, lesson loads, memory recall, context preparation,
/// compaction and HTML conversion, plus main-thread stalls as "hang" events.
/// Off unless the app runs with MYAITEACHER_SIGNPOSTS=1: then every call site is one check of a constant and formats nothing.
enum Signposts {
    static let enabled = ProcessInfo.processInfo.environment["MYAITEACHER_SIGNPOSTS"] == "1"
    static let poster = enabled ? OSSignposter(subsystem: "com.saqlain.myaiteacher", category: .pointsOfInterest) : .disabled

    /// Starts an interval; pair it with `end` (a `defer`, or the callback where the work finishes).
    static func begin(_ name: StaticString, _ detail: @autoclosure () -> String = "") -> OSSignpostIntervalState? {
        guard enabled else { return nil }
        let d = detail()
        return poster.beginInterval(name, id: poster.makeSignpostID(), "\(d, privacy: .public)")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        if let state { poster.endInterval(name, state) }
    }

    static func event(_ name: StaticString, _ detail: @autoclosure () -> String = "") {
        guard enabled else { return }
        let d = detail()
        poster.emitEvent(name, "\(d, privacy: .public)")
    }

    /// Lesson turns (from the event bus, so the agent loop carries no extra code) and the main-thread watch.
    @MainActor static func install() {
        guard enabled else { return }
        var turns: [String: OSSignpostIntervalState] = [:]
        bag = EventBus.subject.sink { e in
            switch e {
            case .turnStarted(let id): turns[id] = begin("turn", String(id.prefix(8)))
            case .turnFinished(let id, let m): end("turn", turns.removeValue(forKey: id)); event("turn.done", "\(m.steps) steps \(m.tools.count) tools")
            default: break
            }
        }
        HangWatch.shared.start()
        AppLog.write("signposts on (subsystem com.saqlain.myaiteacher, Points of Interest)")
    }
    @MainActor private static var bag: AnyCancellable?
}

/// Main-thread stalls without Instruments: a timer off the main thread pings the main queue every 50 ms (one ping in
/// flight); an answer 100 ms or more late is a stall, reported when the main thread comes back with its length, so a
/// recorder can line it up with sampled stacks.
final class HangWatch: @unchecked Sendable {
    static let shared = HangWatch()
    private let queue = DispatchQueue(label: "perf.hangwatch", qos: .userInteractive)
    private var timer: DispatchSourceTimer?
    private var inFlight = false   // touched on `queue` only

    func start(threshold ms: Double = 100) {
        queue.async { [self] in
            guard timer == nil else { return }
            let t = DispatchSource.makeTimerSource(queue: queue)
            t.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(5))
            t.setEventHandler { [self] in
                guard !inFlight else { return }
                inFlight = true
                let sent = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async { [self] in
                    let late = Double(DispatchTime.now().uptimeNanoseconds - sent) / 1e6
                    if late >= ms {
                        Signposts.event("hang", String(format: "%.0f ms", late))
                        AppLog.write(String(format: "perf: main thread stalled %.0f ms", late))
                    }
                    queue.async { self.inFlight = false }
                }
            }
            t.resume()
            timer = t
        }
    }
}
