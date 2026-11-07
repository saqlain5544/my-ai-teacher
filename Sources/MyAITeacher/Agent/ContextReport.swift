import Foundation

/// `/compact [focus]` and `/context`: commands on the lesson's context, not messages to the model.
enum ContextCommand: Equatable {
    case compact(focus: String?), context

    var name: String { if case .compact = self { "compact" } else { "context" } }

    static func parse(_ text: String) -> ContextCommand? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard t.hasPrefix("/") else { return nil }
        let word = t.dropFirst().prefix { !$0.isWhitespace }.lowercased()
        let rest = t.dropFirst(word.count + 1).trimmingCharacters(in: .whitespacesAndNewlines)
        switch word {
        case "compact": return .compact(focus: rest.isEmpty ? nil : rest)
        case "context": return rest.isEmpty ? .context : nil
        default: return nil
        }
    }
}

/// Where a lesson's context goes, counted from what the app holds (no model call), with the same script-aware estimate the
/// budget uses. The fixed prefix is what `--cli --measure` prints; the history is what the next request would send.
struct ContextReport: Sendable {
    struct Part: Sendable, Equatable { var name: String; var tokens: Int }
    /// System prompt without its memory and deferred-tool list, the tool definitions, those two, then the history.
    var fixed: [Part] = []
    var history: [Part] = []
    var budget = 0
    var window: Int?
    var trimmedSaved = 0           // tokens microcompaction removed from requests
    var summaryTokens = 0
    var summarisedMessages = 0
    var cacheHitRate: Double?
    var lastCompaction: String?

    var total: Int { (fixed + history).reduce(0) { $0 + $1.tokens } }
    /// The one thing using the most space.
    var biggest: Part? { (fixed + history).filter { $0.tokens > 0 }.max { $0.tokens < $1.tokens } }

    /// Tokens one tool definition adds to every request.
    static func toolTokens(_ t: Tool) -> Int { ContextPolicy.estimate(t.name + t.description + t.schema.compact) }

    /// History by kind: what the model reads as messages, tool results, images and reasoning.
    static func split(_ msgs: [ChatMessage]) -> [Part] {
        var text = 0.0, results = 0.0, images = 0.0, reasoning = 0.0
        for m in msgs {
            for b in m.blocks {
                let t = (b.text.map { Double(ContextPolicy.estimate($0)) } ?? 0) + (b.input.map { Double(ContextPolicy.estimate($0.compact)) } ?? 0)
                if b.hasPayload || b.kind == .image { images += 1_500 }
                switch b.kind {
                case .toolResult: results += t
                case .thinking: reasoning += t
                default: text += t
                }
            }
        }
        return [Part(name: "Messages", tokens: Int(text)), Part(name: "Tool results", tokens: Int(results)),
                Part(name: "Images", tokens: Int(images)), Part(name: "Reasoning", tokens: Int(reasoning))]
    }

    /// `system`: the frozen prompt; `memory` and `deferred` are the parts of it counted apart.
    static func build(system: String, memory: String, deferred: String, tools: [Tool], prepared: [ChatMessage], raw: [ChatMessage],
                      conversation c: Conversation, budget: Int, window: Int?) -> ContextReport {
        var r = ContextReport()
        let sys = ContextPolicy.estimate(system), mem = min(sys, ContextPolicy.estimate(memory)), def = min(sys - mem, ContextPolicy.estimate(deferred))
        r.fixed = [Part(name: "System prompt", tokens: sys - mem - def), Part(name: "Memory", tokens: mem),
                   Part(name: "Deferred-tool list", tokens: def), Part(name: "Tool definitions", tokens: tools.reduce(0) { $0 + toolTokens($1) })]
        r.history = split(prepared)
        r.budget = budget; r.window = window
        r.summaryTokens = c.compactSummary.map { ContextPolicy.estimate($0) } ?? 0
        // `raw` is the lesson after the compaction point as stored; `prepared` the same plus the summary, as sent.
        r.trimmedSaved = max(0, ContextPolicy.estimateTokens(raw) - (ContextPolicy.estimateTokens(prepared) - r.summaryTokens))
        r.cacheHitRate = c.stats?.cacheHitRate
        return r
    }

    /// The card's text: one line each, then the verdict.
    var lines: [String] {
        func k(_ n: Int) -> String { n >= 1000 ? String(format: "%.1fk", Double(n) / 1000) : "\(n)" }
        var out = ["Total ≈ \(k(total)) tokens of a \(k(budget)) budget" + (window.map { " (model window \(k($0)))" } ?? "")]
        if let b = biggest { out.append("Biggest: \(b.name) (\(k(b.tokens)), \(total > 0 ? b.tokens * 100 / total : 0)%)") }
        if trimmedSaved > 0 { out.append("Microcompaction is saving ≈ \(k(trimmedSaved)) tokens of old tool output") }
        if summarisedMessages > 0 || summaryTokens > 0 { out.append("Summary: ≈ \(k(summaryTokens)) tokens stand in for \(summarisedMessages) earlier messages") }
        if let h = cacheHitRate { out.append(String(format: "Cache hit rate: %.0f%%", h * 100)) }
        return out
    }
}
