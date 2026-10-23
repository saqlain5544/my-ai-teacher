import Foundation

/// A/B experiments. Each lesson gets a deterministic arm per experiment (hash of experiment + lesson id), so a lesson's
/// prompt prefix never changes mid-lesson (cache-safe) and no assignment state is stored. Exposures and per-turn
/// outcomes go through the EventBus; telemetry stores them and the Insights dashboard compares arms.
enum Experiments {
    struct Experiment: Sendable {
        let name: String
        let arms: [String]   // arms[0] is the default when experiments are off
    }

    /// `visual` tool sent with every request ("core") or loaded on demand ("deferred", the ```visual fence is the default).
    static let visualTool = Experiment(name: "visual_tool", arms: ["deferred", "core"])
    static let all = [visualTool]

    /// The course board system: book-style outlines, cards only, or no board. The learner picks one in Settings
    /// (`AppSettings.courseBoard`, mirrored into `chosen`); an evaluation run forces one with
    /// `MYAITEACHER_EXP=course_board=off` (or the CLI's `--exp`). Never randomised.
    static let courseBoard = Experiment(name: "course_board", arms: ["nested", "shallow", "off"])
    static func evaluationArm(_ e: Experiment) -> String {
        if let f = forced[e.name], e.arms.contains(f) { return f }
        if let c = choice(e.name), e.arms.contains(c) { return c }
        return e.arms[0]
    }
    /// The learner's choices from Settings (forced arms win over them). Written on the main thread when Settings change,
    /// read from tool calls on any thread: behind a lock.
    private static let choices = NSLock()
    nonisolated(unsafe) private static var _chosen: [String: String] = [:]
    static var chosen: [String: String] {
        get { choices.withLock { _chosen } }
        set { choices.withLock { _chosen = newValue } }
    }
    static func choose(_ arm: String, for name: String) { choices.withLock { _chosen[name] = arm } }
    private static func choice(_ name: String) -> String? { choices.withLock { _chosen[name] } }
    static var boardOff: Bool { evaluationArm(courseBoard) == "off" }

    /// `MYAITEACHER_EXP="name=arm,name=arm"` from the environment (evaluation runs launch the app with it).
    static func loadForced(_ env: [String: String] = ProcessInfo.processInfo.environment) {
        for pair in (env["MYAITEACHER_EXP"] ?? "").split(separator: ",") {
            let kv = pair.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { forced[kv[0]] = kv[1] }
        }
    }

    /// Forced arms (CLI `--exp name=arm`, tests). Read-mostly; set before any lesson runs.
    nonisolated(unsafe) static var forced: [String: String] = [:]
    nonisolated(unsafe) static var enabled = true

    static func arm(_ e: Experiment, unit: String) -> String {
        if let f = forced[e.name], e.arms.contains(f) { return f }
        guard enabled else { return e.arms[0] }
        var h: UInt64 = 0xcbf29ce484222325   // FNV-1a: stable across launches (unlike Hasher)
        for b in (e.name + ":" + unit).utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return e.arms[Int(h % UInt64(e.arms.count))]
    }
}

/// Publishes exposures (once per lesson) and per-turn outcomes for every experiment.
@MainActor
final class ExperimentExtension: AgentExtension {
    let id = "experiments"
    private var exposed = Set<String>()

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        guard Experiments.enabled, exposed.insert(session.id).inserted else { return }
        for e in Experiments.all {
            EventBus.publish(.experiment(ExperimentEvent(name: e.name, variant: Experiments.arm(e, unit: session.id), conversationID: session.id)))
        }
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        guard Experiments.enabled else { return }
        let outcomes: [(String, Double)] = [
            ("steps", Double(metrics.steps)),
            ("tokens", Double(metrics.usage.promptTotal + metrics.usage.output)),
            ("seconds", metrics.duration),
        ]
        for e in Experiments.all {
            let arm = Experiments.arm(e, unit: session.id)
            for (k, v) in outcomes {
                EventBus.publish(.experiment(ExperimentEvent(name: e.name, variant: arm, kind: .outcome, metric: k, value: v, conversationID: session.id)))
            }
        }
    }
}
