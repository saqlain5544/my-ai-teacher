import Foundation
import Combine

/// Turns agent-loop metrics and app events into telemetry. Plugs in as an `AgentExtension` + `EventBus` subscriber,
/// so the agent loop itself has no telemetry calls.
@MainActor
final class TelemetryExtension: AgentExtension {
    let id = "telemetry"
    nonisolated(unsafe) static var startedAt: Double = ProcessClock.startTime
    private let telemetry: Telemetry
    private var bag: Set<AnyCancellable> = []
    /// Last seen compaction points per lesson (detection without a loop hook): summary and trim epochs.
    private var compactedThrough: [String: String?] = [:]
    private var trimmedThrough: [String: String?] = [:]
    private var lastContext: [String: Int] = [:]

    init(telemetry: Telemetry = .shared) {
        self.telemetry = telemetry
        Self.startedAt = Date().timeIntervalSince1970
        EventBus.subject
            .sink { [weak self] e in self?.handle(e) }
            .store(in: &bag)
    }

    private func timed(_ body: () -> [TelemetryEvent]) {
        guard telemetry.enabled else { return }
        let t0 = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let events = body()
        telemetry.addMappingTime(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - t0)
        telemetry.record(events)
    }

    // MARK: Hooks

    func willSend(_ message: inout ChatMessage, session: ChatSession) {
        compactedThrough[session.id] = .some(session.conversation.compactedThrough)
        trimmedThrough[session.id] = .some(session.conversation.trimmedThrough)
    }

    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        let summary = session.conversation.compactedThrough, trim = session.conversation.trimmedThrough
        defer { compactedThrough[session.id] = .some(summary); trimmedThrough[session.id] = .some(trim) }
        var kinds: [String] = []
        if let seen = compactedThrough[session.id], let summary, summary != seen { kinds.append("summary") }
        if let seen = trimmedThrough[session.id], let trim, trim != seen { kinds.append("trim") }
        guard !kinds.isEmpty else { return }
        let before = lastContext[session.id] ?? 0
        timed { kinds.map { TelemetryEvent(ts: Date().timeIntervalSince1970, kind: .compaction, provider: session.conversation.providerID,
                                           model: session.conversation.model, conv: session.id, value: Double(before), label: $0) } }
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        let turn = metrics
        timed {
            // Steps of this turn: trailing assistant messages whose metrics started after the turn did.
            var steps: [(StepMetrics, String?)] = []
            for m in session.messages.reversed() {
                guard m.role == .assistant else { continue }
                guard let s = m.metrics else { continue }
                if s.startedAt < turn.startedAt { break }
                steps.append((s, m.error))
            }
            steps.reverse()
            if let ctx = steps.last?.0.usage.promptTotal, ctx > 0 { lastContext[session.id] = ctx }
            compactedThrough[session.id] = .some(session.conversation.compactedThrough)
            trimmedThrough[session.id] = .some(session.conversation.trimmedThrough)
            return TelemetryMapper.events(turn: turn, steps: steps, conversationID: session.id)
        }
    }

    // MARK: Events

    private func handle(_ e: AppEvent) {
        switch e {
        case .approval(let conv, let tool, let choice, let allowed, let waited):
            timed { [TelemetryEvent(ts: Date().timeIntervalSince1970, kind: .approval, conv: conv, name: tool, value: waited, ok: allowed, label: choice)] }
        case .memoryChanged(let c):
            timed { [TelemetryEvent(ts: Date().timeIntervalSince1970, kind: .memory, conv: c.conversationID, name: c.kind.rawValue, value: Double(max(1, c.ids.count)))] }
        default: break
        }
    }
}

/// Pure mapping from agent metrics to telemetry events (unit-tested).
enum TelemetryMapper {
    static func events(turn: TurnMetrics, steps: [(StepMetrics, String?)], conversationID: String) -> [TelemetryEvent] {
        var out: [TelemetryEvent] = []
        out.reserveCapacity(steps.count * 2 + turn.tools.count + 1)
        for (s, error) in steps {
            let stopped = error == "Stopped."
            let failed = error != nil && !stopped
            var a: [String: Double] = [
                "input": Double(s.usage.input), "cacheRead": Double(s.usage.cacheRead), "cacheWrite": Double(s.usage.cacheWrite),
                "output": Double(s.usage.output), "reasoning": Double(s.usage.reasoning), "ctx": Double(s.usage.promptTotal),
                "gen": max(0, s.duration - (s.timeToFirstToken ?? 0)), "toolCalls": Double(s.toolCalls),
            ]
            if s.retries > 0 { a["retries"] = Double(s.retries) }
            if s.usageEstimated { a["estimated"] = 1 }
            if let t = s.timeToFirstToken { a["ttft"] = t }
            let ts = s.startedAt.timeIntervalSince1970
            out.append(TelemetryEvent(ts: ts, kind: .step, provider: s.provider, model: s.model, conv: conversationID,
                                      value: s.duration, ok: !failed, label: stopped ? "cancelled" : s.finishReason, attrs: a))
            if let error, failed {
                out.append(TelemetryEvent(ts: ts + s.duration, kind: .error, provider: s.provider, model: s.model, conv: conversationID,
                                          name: errorCategory(error), ok: false, label: String(error.prefix(160)), attrs: ["retries": Double(s.retries)]))
            }
        }
        var t = turn.startedAt.timeIntervalSince1970
        for tool in turn.tools {
            var a: [String: Double] = [:]
            if let w = tool.waitedForLearner { a["waited"] = w }
            t += 0.000_001   // keep insertion order stable for identical timestamps
            out.append(TelemetryEvent(ts: t, kind: .tool, conv: conversationID, name: tool.name, value: tool.duration, ok: tool.ok, attrs: a))
        }
        let last = steps.last?.0
        var a: [String: Double] = ["steps": Double(turn.steps), "tools": Double(turn.toolCalls),
                                   "memRecalled": Double(turn.memoriesRecalled.count), "memWrites": Double(turn.memoryWrites),
                                   "output": Double(turn.usage.output)]
        if let ttft = turn.timeToFirstToken { a["ttft"] = ttft }
        if turn.cancelled { a["cancelled"] = 1 }
        if turn.error != nil { a["error"] = 1 }
        out.append(TelemetryEvent(ts: turn.startedAt.timeIntervalSince1970 + turn.duration, kind: .turn, provider: last?.provider ?? "",
                                  model: last?.model ?? "", conv: conversationID, value: turn.duration, ok: turn.error == nil, attrs: a))
        return out
    }

    /// Buckets provider error messages into a few actionable categories.
    static func errorCategory(_ message: String) -> String {
        let m = message.lowercased()
        func has(_ s: String...) -> Bool { s.contains { m.contains($0) } }
        if has("429", "rate limit", "rate_limit", "too many requests", "quota") { return "rate_limit" }
        if has("401", "403", "unauthorized", "forbidden", "api key", "invalid_api_key", "authentication") { return "auth" }
        if has("context length", "context_length", "too long", "maximum context", "too many tokens", "prompt is too long") { return "context_length" }
        if has("timed out", "timeout") { return "timeout" }
        if has("500", "502", "503", "504", "529", "overloaded", "server error", "internal error", "bad gateway", "unavailable", "busy") { return "server" }
        if has("offline", "network", "connection", "could not connect", "hostname", "internet", "ssl") { return "network" }
        if has("400", "invalid", "bad request") { return "bad_request" }
        return "other"
    }
}
