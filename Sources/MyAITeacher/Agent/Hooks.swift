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
            return d
        }
        return .allow
    }
    func didRun(_ c: Block, _ r: inout Block, _ s: ChatSession) { for e in extensions { e.didRun(c, result: &r, session: s) } }
    func didFinishTurn(_ m: inout TurnMetrics, _ s: ChatSession) { for e in extensions { e.didFinishTurn(&m, session: s) } }
    func sessionWillClose(_ s: ChatSession) { for e in extensions { e.sessionWillClose(s) } }
}
