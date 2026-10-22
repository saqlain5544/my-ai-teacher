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
    case workspaceChanged(path: String)
    case notice(conversationID: String?, text: String)
    /// A tool-approval decision (emitted by `ExtensionHost.shouldRun`; `choice` is the learner's option id, or "policy").
    case approval(conversationID: String, tool: String, choice: String, allowed: Bool, waited: Double)
    /// A/B experiment exposure or outcome. Publish once where a variant is applied / an outcome is known.
    case experiment(ExperimentEvent)
}

struct ExperimentEvent: Sendable {
    enum Kind: String, Sendable { case exposure, outcome }
    var name: String
    var variant: String
    var kind: Kind = .exposure
    var metric: String?
    var value: Double?
    var conversationID: String?
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
    /// Gate a tool call. The first non-`allow` decision wins.
    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision
    /// Observe or rewrite a tool result.
    func didRun(_ call: Block, result: inout Block, session: ChatSession)
    /// Rewrite a finished reply before it is stored and shown in its final form (e.g. withhold solution code).
    func willStoreReply(_ message: inout ChatMessage, session: ChatSession)
    /// Called when a learner turn completes (no more tool calls), with its metrics.
    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession)
    /// Called when a lesson goes idle or is closed.
    func sessionWillClose(_ session: ChatSession)
}

extension AgentExtension {
    func systemPromptSections(_ session: ChatSession) -> [String] { [] }
    func willSend(_ message: inout ChatMessage, session: ChatSession) {}
    func willRequest(_ request: inout LLMRequest, session: ChatSession) {}
    func shouldRun(_ call: Block, tool: Tool, session: ChatSession) -> ToolDecision { .allow }
    func didRun(_ call: Block, result: inout Block, session: ChatSession) {}
    func willStoreReply(_ message: inout ChatMessage, session: ChatSession) {}
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
    func shouldRun(_ c: Block, _ t: Tool, _ s: ChatSession) -> ToolDecision {
        for e in extensions {
            let d = e.shouldRun(c, tool: t, session: s)
            if case .allow = d { continue }
            return Self.observed(d, tool: t.name, conversationID: s.id)
        }
        return .allow
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
                let allowed: Bool = { if case .allow = r { return true }; return false }()
                EventBus.publish(.approval(conversationID: conversationID, tool: tool, choice: choice, allowed: allowed,
                                           waited: Date().timeIntervalSince(askedAt)))
                return observed(r, tool: tool, conversationID: conversationID, resolved: true)
            })
        }
    }
    func didRun(_ c: Block, _ r: inout Block, _ s: ChatSession) { for e in extensions { e.didRun(c, result: &r, session: s) } }
    func willStoreReply(_ m: inout ChatMessage, _ s: ChatSession) { for e in extensions { e.willStoreReply(&m, session: s) } }
    func didFinishTurn(_ m: inout TurnMetrics, _ s: ChatSession) { for e in extensions { e.didFinishTurn(&m, session: s) } }
    func sessionWillClose(_ s: ChatSession) { for e in extensions { e.sessionWillClose(s) } }
}
