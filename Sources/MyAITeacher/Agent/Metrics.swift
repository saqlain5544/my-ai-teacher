import Foundation

/// One LLM call (request → streamed response). Names follow the OpenTelemetry GenAI conventions where they exist
/// (time_to_first_token, time_per_output_token, client.operation.duration, finish_reasons).
struct StepMetrics: Codable, Sendable, Hashable {
    var provider: String
    var model: String
    var startedAt: Date
    var timeToFirstToken: Double?     // seconds until the first streamed event (text, thinking or tool call)
    var duration: Double = 0          // seconds, request start → stream end
    var usage = Usage()
    var usageEstimated = false        // provider sent no usage; output estimated from characters
    var finishReason = "end_turn"
    var retries = 0
    var toolCalls = 0

    /// Output tokens per second over the generation phase (excludes time to first token).
    var outputTokensPerSecond: Double? {
        let gen = duration - (timeToFirstToken ?? 0)
        guard usage.output > 0, gen > 0.05 else { return nil }
        return Double(usage.output) / gen
    }
}

struct ToolMetric: Codable, Sendable, Hashable {
    var name: String
    var duration: Double
    var ok: Bool
    var waitedForLearner: Double?     // time spent on approvals/interactive components
}

/// One learner turn: a user message and everything the teacher did in response.
struct TurnMetrics: Codable, Sendable, Hashable {
    var startedAt = Date()
    var duration: Double = 0          // wall time
    var timeToFirstToken: Double?
    var steps = 0                     // LLM calls
    var tools: [ToolMetric] = []
    var usage = Usage()               // summed over steps
    var generationSeconds: Double = 0
    var memoriesRecalled: [String] = []
    var memoryWrites = 0
    var languages: [String] = []
    var cancelled = false
    var error: String?

    var toolCalls: Int { tools.count }
    var outputTokensPerSecond: Double? { generationSeconds > 0.05 && usage.output > 0 ? Double(usage.output) / generationSeconds : nil }
}

/// Running totals for a lesson.
struct ConversationStats: Codable, Sendable, Hashable {
    var turns = 0
    var steps = 0
    var toolCalls = 0
    var usage = Usage()
    var generationSeconds: Double = 0
    var wallSeconds: Double = 0
    var contextTokens = 0             // size of the most recent request (input + cached)

    mutating func add(_ t: TurnMetrics, contextTokens ctx: Int) {
        turns += 1; steps += t.steps; toolCalls += t.toolCalls
        usage = usage + t.usage
        generationSeconds += t.generationSeconds; wallSeconds += t.duration
        if ctx > 0 { contextTokens = ctx }
    }
    var cacheHitRate: Double? {
        let total = usage.input + usage.cacheRead + usage.cacheWrite
        return total > 0 ? Double(usage.cacheRead) / Double(total) : nil
    }
}
