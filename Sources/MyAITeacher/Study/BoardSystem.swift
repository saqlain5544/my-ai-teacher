import Foundation

/// The course board system: book-style outlines ("nested"), cards only ("shallow") or no board ("off"). The learner picks
/// one in Settings (`AppSettings.courseBoard`, mirrored into `chosen`); an evaluation run forces one with
/// `MYAITEACHER_EXP=course_board=off` in the environment or the CLI's `--exp course_board=off` (scripts/ab-board.py).
enum BoardSystem {
    static let arms = ["nested", "shallow", "off"]

    /// The learner's choice from Settings. Written on the main thread when Settings change, read from tool calls on any
    /// thread: behind a lock.
    private static let lock = NSLock()
    nonisolated(unsafe) private static var _chosen: String?
    static var chosen: String? {
        get { lock.withLock { _chosen } }
        set { lock.withLock { _chosen = newValue } }
    }
    /// An evaluation run's arm (wins over the learner's choice). Set before any lesson runs.
    nonisolated(unsafe) static var forced: String?

    static var current: String {
        if let f = forced, arms.contains(f) { return f }
        if let c = chosen, arms.contains(c) { return c }
        return arms[0]
    }
    static var off: Bool { current == "off" }

    /// Reads `course_board=<arm>` from "name=value" pairs separated by commas (`MYAITEACHER_EXP`, `--exp`).
    static func force(_ pairs: String) {
        for pair in pairs.split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2, kv[0] == "course_board" { forced = kv[1] }
        }
    }
    static func loadForced(_ env: [String: String] = ProcessInfo.processInfo.environment) { force(env["MYAITEACHER_EXP"] ?? "") }
}
