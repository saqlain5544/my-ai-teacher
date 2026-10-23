import Foundation

/// Tier 3 of the context policy, apart from the lesson loop: which messages a summary replaces, and the summary itself.
/// `ChatSession` decides when to run it and applies the result; anything else with a long history (a sub-agent, a
/// future agent) can use the same two steps.
enum Compaction {
    /// Share of the budget kept verbatim after the summary.
    static let keepShare = 0.3
    /// Characters of transcript per summary call; a longer range is folded in chunk by chunk.
    static let chunkChars = 60_000

    /// The messages a summary should replace: from just after the previous compaction point to the start of the learner
    /// turn where the verbatim tail (`keepShare` of the budget, in script-aware tokens) begins. Nil when there is nothing
    /// worth summarising.
    static func summaryRange(_ msgs: [ChatMessage], compactedThrough: String?, budget: Int) -> Range<Int>? {
        // Counted in tokens: counting characters (÷4) kept 4× too much of a CJK lesson, so the summary could never bring
        // it back under the budget.
        var keepTokens = 0, cut = msgs.count
        for i in msgs.indices.reversed() {
            keepTokens += ContextPolicy.estimateTokens([msgs[i]])
            if Double(keepTokens) > Double(budget) * keepShare { cut = i; break }
        }
        // The verbatim part starts with a learner message, so no tool result is separated from its call.
        while cut < msgs.count && (msgs[cut].role != .user || msgs[cut].isToolResultOnly) { cut += 1 }
        guard cut > 1, cut < msgs.count else { return nil }
        let start = compactedThrough.flatMap { t in msgs.firstIndex { $0.id == t } }.map { $0 + 1 } ?? 0
        return start < cut ? start..<cut : nil
    }

    struct Summary: Sendable {
        var text: String
        /// One entry per model call (each is billed and counted as a step, cancelled or not).
        var usage: [Usage] = []
        /// The task was cancelled mid-summary: record the usage, but keep the lesson as it was (a learner's stop must
        /// not replace the lesson's history with a rough digest for good).
        var cancelled = false
    }

    /// A rolling summary of `msgs` merged into `previous`, chunk by chunk, so nothing is silently dropped however long the
    /// range is. `state` is app-held context the summary must carry verbatim (the course board is not in the transcript).
    /// A failed call falls back to a deterministic digest, so the request still shrinks.
    static func summarise(_ msgs: [ChatMessage], previous: String?, state: String, client: LLMClient, model: String,
                          sessionID: String) async -> Summary {
        var summary = previous
        var usage: [Usage] = []
        for chunk in ContextPolicy.chunks(msgs, maxChars: chunkChars) {
            let req = LLMRequest(model: model, system: "You write precise, dense summaries of tutoring sessions.",
                                 messages: [ChatMessage(role: .user, blocks: [.text(prompt(chunk, previous: summary, state: state))])],
                                 maxTokens: 4096, sessionID: sessionID, cache: false)
            // A supervised job (Runtime › jobs): a failed call, or one silent for 120 s (every streamed event is a heartbeat),
            // is retried with backoff, then the digest below.
            let part = (try? await Runtime.call("lesson.compact", limit: Intensity(maxRestarts: 1, period: 300), watchdog: 120) { beat -> Summary in
                var out = Summary(text: "")
                for try await ev in BeatingClient(inner: client, beat: beat).stream(req) {
                    switch ev {
                    case .text(let s): out.text += s
                    case .usage(let u): out.usage.append(u)
                    default: break
                    }
                }
                return out
            }) ?? Summary(text: "")
            usage.append(part.usage.reduce(Usage(), +))
            if Task.isCancelled { return Summary(text: "", usage: usage, cancelled: true) }
            var text = part.text
            if let r = text.range(of: "</think>") { text = String(text[r.upperBound...]) }
            summary = text.count > 100 ? text.trimmingCharacters(in: .whitespacesAndNewlines)
                : ContextPolicy.digest(chunk, previous: summary) + (state.isEmpty ? "" : "\n\nCourse state:\n" + state)
        }
        return Summary(text: (summary ?? "").trimmingCharacters(in: .whitespacesAndNewlines), usage: usage)
    }

    static func prompt(_ chunk: [ChatMessage], previous: String?, state: String) -> String {
        """
        Summarise this part of a tutoring session so the lesson can continue seamlessly. \
        \(previous.map { "Merge with the previous summary:\n\($0)\n\n" } ?? "")
        Use these headings: Goal / What was covered / Learner's understanding & misconceptions / Tests & results / \
        Decisions & preferences / Files & artifacts / Course state / Next steps. Be specific (formulas, examples, scores).\
        \(state.isEmpty ? "" : "\n\nActive course state from the app (copy it under \"Course state\" verbatim; \"Next steps\" must agree with its Focus and Next):\n" + state)

        <transcript>
        \(Reflection.transcriptExcerpt(chunk, maxChars: chunkChars))
        </transcript>
        """
    }
}
