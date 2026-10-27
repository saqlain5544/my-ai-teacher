import Foundation
import Combine

// MARK: - Events

/// App-wide events. Anything can subscribe (UI, extensions, logging) without the core knowing about it.
enum AppEvent: Sendable {
    case turnStarted(conversationID: String)
    case turnFinished(conversationID: String, metrics: TurnMetrics)
    case toolStarted(conversationID: String, tool: String, callID: String)
    case toolFinished(conversationID: String, tool: String, callID: String, ok: Bool)
    case memoryChanged(MemoryChange)
    case studyDataChanged
    /// A code mentor project's record changed (a test run, a review round, the guard's log).
    case projectChanged(folder: String)
    case workspaceChanged(path: String)
    case notice(conversationID: String?, text: String)
    /// A tool-approval decision (emitted by `ExtensionHost.shouldRun`; `choice` is the learner's option id, or "policy").
    case approval(conversationID: String, tool: String, choice: String, allowed: Bool, waited: Double)
}

struct MemoryChange: Sendable {
    enum Kind: String, Sendable { case added, merged, updated, deleted, recalled, reflected }
    var kind: Kind
    var ids: [String] = []
    var summary: String?
    var conversationID: String?
}

enum EventBus {
    static let subject = PassthroughSubject<AppEvent, Never>()
    static func publish(_ e: AppEvent) {
        if Thread.isMainThread { subject.send(e) } else { DispatchQueue.main.async { subject.send(e) } }
    }
}

// MARK: - Hooks

struct ApprovalOption: Sendable {
    enum Style: String, Sendable { case primary, normal, danger }
    var id: String
    var label: String
    var style: Style = .normal
}

struct ApprovalRequest: Sendable {
    var title: String
    var detail: String
    var options: [ApprovalOption]
}

enum ToolDecision: Sendable {
    case allow
    case deny(String)
    /// Ask the learner; `resolve` maps the chosen option id to a final decision.
    case ask(ApprovalRequest, resolve: @MainActor @Sendable (String) -> ToolDecision)
    /// Decided by work the main actor mustn't wait on (a user's hook command): the loop awaits it, then goes on with its answer.
    case pending(@MainActor @Sendable () async -> ToolDecision)
}

/// A feature that plugs into the agent loop. All methods are optional (default no-ops), so new features
/// are added by registering an extension rather than editing the core loop.
@MainActor
protocol AgentExtension: AnyObject {
    var id: String { get }
    /// Extra system-prompt sections (computed once per lesson, keeps the cached prefix stable).
    func systemPromptSections(_ session: ChatSession) -> [String]
    /// Mutate an outgoing learner message before it is stored (add hidden context, metadata).
    func willSend(_ message: inout ChatMessage, session: ChatSession)
    /// Adjust each request before it is sent to the model.
    func willRequest(_ request: inout LLMRequest, session: ChatSession)
    /// State the summary of a compacted lesson must carry (it is written from the transcript, which may not hold it).
    func summaryContext(_ session: ChatSession) -> [String]
    /// Gate a tool call. A deny wins; an `ask` the learner approves moves on to the next extension's gate.
    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision
    /// The `WriteFence` profile the programs this call starts run under (nil: unfenced). The first extension's wins.
    func writeFence(_ call: Block, tool: Tool, session: ChatSession) -> String?
    /// Observe or rewrite a tool result.
    func didRun(_ call: Block, result: inout Block, session: ChatSession)
    /// After every `didRun`, work the call's result waits for off the main actor (a user's hook command); may add to it.
    func afterRun(_ call: Block, result: inout Block, session: ChatSession) async
    /// Before the first request of a turn the user's message started: may add to that message, or return why it must not
    /// reach the agent (the turn then ends at once, and the reason is shown to the user).
    func willStartTurn(_ message: inout ChatMessage, session: ChatSession) async -> String?
    /// The agent's reply would end the turn: why it must keep going instead (sent to it as a hidden note), or nil.
    /// `continued`: how many times this turn was already sent back.
    func willEndTurn(_ session: ChatSession, continued: Int) async -> String?
    /// Called when a learner turn completes (no more tool calls), with its metrics.
    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession)
    /// Called when a lesson goes idle or is closed.
    func sessionWillClose(_ session: ChatSession)
}

extension AgentExtension {
    func systemPromptSections(_ session: ChatSession) -> [String] { [] }
    func willSend(_ message: inout ChatMessage, session: ChatSession) {}
    func willRequest(_ request: inout LLMRequest, session: ChatSession) {}
    func summaryContext(_ session: ChatSession) -> [String] { [] }
    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision { .allow }
    func writeFence(_ call: Block, tool: Tool, session: ChatSession) -> String? { nil }
    func didRun(_ call: Block, result: inout Block, session: ChatSession) {}
    func afterRun(_ call: Block, result: inout Block, session: ChatSession) async {}
    func willStartTurn(_ message: inout ChatMessage, session: ChatSession) async -> String? { nil }
    func willEndTurn(_ session: ChatSession, continued: Int) async -> String? { nil }
    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {}
    func sessionWillClose(_ session: ChatSession) {}
}

@MainActor
final class ExtensionHost {
    private(set) var extensions: [AgentExtension] = []

    func register(_ e: AgentExtension) {
        extensions.removeAll { $0.id == e.id }
        extensions.append(e)
    }
    func get<T: AgentExtension>(_ type: T.Type) -> T? { extensions.first { $0 is T } as? T }

    func systemPromptSections(_ s: ChatSession) -> [String] { extensions.flatMap { $0.systemPromptSections(s) } }
    func willSend(_ m: inout ChatMessage, _ s: ChatSession) { for e in extensions { e.willSend(&m, session: s) } }
    func willRequest(_ r: inout LLMRequest, _ s: ChatSession) { for e in extensions { e.willRequest(&r, session: s) } }
    func summaryContext(_ s: ChatSession) -> [String] { extensions.flatMap { $0.summaryContext(s) } }
    func shouldRun(_ c: Block, _ t: Tool, _ s: ChatSession) -> ToolDecision {
        let gates: [@MainActor () -> ToolDecision] = extensions.map { e in { e.shouldRun(c, tool: t, session: s) } }
        return Self.observed(Self.chain(gates[...]), tool: t.name, conversationID: s.id)
    }

    /// Runs gates in registration order: a deny ends it; an approval the learner gives, or a pending gate's answer that
    /// allows, goes on to the remaining gates. (Returning the first `.ask` as final let an approval for one gate skip every
    /// gate after it.)
    static func chain(_ gates: ArraySlice<@MainActor () -> ToolDecision>) -> ToolDecision {
        guard let first = gates.first else { return .allow }
        return then(first(), gates.dropFirst())
    }

    /// `d`, and once it allows, the remaining gates.
    private static func then(_ d: ToolDecision, _ rest: ArraySlice<@MainActor () -> ToolDecision>) -> ToolDecision {
        switch d {
        case .allow: return chain(rest)
        case .deny: return d
        case .ask(let req, let resolve): return .ask(req, resolve: { choice in then(resolve(choice), rest) })
        case .pending(let decide): return .pending { then(await decide(), rest) }
        }
    }

    /// Publishes `.approval` events for gated calls without the loop knowing (one emit point).
    static func observed(_ d: ToolDecision, tool: String, conversationID: String, askedAt: Date = Date(), resolved: Bool = false) -> ToolDecision {
        switch d {
        case .allow: return d
        case .deny:
            if !resolved { EventBus.publish(.approval(conversationID: conversationID, tool: tool, choice: "policy", allowed: false, waited: 0)) }
            return d
        case .ask(let req, let resolve):
            return .ask(req, resolve: { choice in
                let r = resolve(choice)
                // The learner's answer allowed it unless it ended in a deny (a later gate may still ask).
                let allowed: Bool = { if case .deny = r { return false }; return true }()
                EventBus.publish(.approval(conversationID: conversationID, tool: tool, choice: choice, allowed: allowed,
                                           waited: Date().timeIntervalSince(askedAt)))
                return observed(r, tool: tool, conversationID: conversationID, resolved: true)
            })
        case .pending(let decide):
            return .pending { observed(await decide(), tool: tool, conversationID: conversationID, resolved: resolved) }
        }
    }
    func writeFence(_ c: Block, _ t: Tool, _ s: ChatSession) -> String? { extensions.lazy.compactMap { $0.writeFence(c, tool: t, session: s) }.first }
    func didRun(_ c: Block, _ r: inout Block, _ s: ChatSession) { for e in extensions { e.didRun(c, result: &r, session: s) } }
    func afterRun(_ c: Block, _ r: inout Block, _ s: ChatSession) async { for e in extensions { await e.afterRun(c, result: &r, session: s) } }
    func willStartTurn(_ m: inout ChatMessage, _ s: ChatSession) async -> String? {
        for e in extensions { if let why = await e.willStartTurn(&m, session: s) { return why } }
        return nil
    }
    func willEndTurn(_ s: ChatSession, continued: Int) async -> String? {
        var reasons: [String] = []
        for e in extensions { if let why = await e.willEndTurn(s, continued: continued) { reasons.append(why) } }
        return reasons.isEmpty ? nil : reasons.joined(separator: "\n\n")
    }
    func didFinishTurn(_ m: inout TurnMetrics, _ s: ChatSession) { for e in extensions { e.didFinishTurn(&m, session: s) } }
    func sessionWillClose(_ s: ChatSession) { for e in extensions { e.sessionWillClose(s) } }
}
