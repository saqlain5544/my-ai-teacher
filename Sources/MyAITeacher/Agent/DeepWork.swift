import Foundation

/// Plan → research → verify for substantial requests. Asking a model to "plan and check" in a prompt leaves it optional,
/// and in one streaming pass it mostly isn't done. Here it is part of the turn:
/// 1. Plan (hidden): what the learner needs, an outline, what to check with tools, what to research, likely pitfalls.
///    The plan reaches the teacher as hidden context, with the instruction to carry it out before writing.
/// 2. The teacher works as usual (tools, sub-agents), then writes its reply.
/// 3. Verify (hidden): a reviewer reads the reply against the plan and the evidence. Substantive problems (errors,
///    unchecked claims, toy filler, missing essentials, a solution handed out) earn one revision: the draft stays in the
///    transcript, collapsed, and the corrected reply follows.
enum DeepWork {
    private static let cue = try! NSRegularExpression(pattern: #"\b(explain|teach|why|how (does|do|did|can|would|is|are)|derive|prove|compare|contrast|design|build|plan|analy[sz]e|understand|walk me|help me|difference|implement|solve|evaluate|what (is|are|causes|happens))\b"#, options: .caseInsensitive)

    /// Worth planning and checking: a request with substance, not a reply inside an exchange (quiz answers, attempts,
    /// submissions, "continue", "thanks").
    static func isSubstantial(_ text: String) -> Bool {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines), lower = t.lowercased()
        if ["my attempt", "i've submitted", "practice:"].contains(where: { lower.hasPrefix($0) }) { return false }
        let words = t.split { $0.isWhitespace }.count
        if words >= 25 { return true }
        return words >= 4 && cue.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
    }

    static let planRequest = """
        Before you reply, plan it. Write the plan only (the learner never sees it, and don't call tools now), in this form:
        Learner needs: what they are really asking, their level, what would make this answer excellent for them.
        Scope: exactly what this reply covers. Only what they asked for now: "start part 1" is part 1, "a few lines" is a \
        few lines; the rest waits for them. Depth, not breadth.
        Outline: the parts of the reply, in order, each with the concrete real-world example, data or problem it uses.
        Check before teaching: each fact, number, derivation or code claim that must be verified, and how (math, run_code, a source).
        Research: questions that need current or precise sources (none if none).
        Pitfalls: misconceptions to address and mistakes to avoid in your answer.
        Keep it under 250 words.
        """

    /// A code mentor designs a lesson before teaching it: the real system it comes from, concepts with analogies, what to
    /// research, working examples to build and run first, and projects that build real subsystems.
    static let lessonDesignRequest = """
        Before you teach, design the lesson. Write the design only (the learner never sees it, and don't call tools now):
        Goal: what the learner will be able to build or reason about afterwards, at their level.
        Real system: the real project or subsystem the lesson is drawn from (name it, e.g. Redis's eviction, Git's object \
        store, SQLite's pager, Nginx's rate limiter, the Go scheduler) and why it is built the way it is.
        Concepts: in order, each with an analogy and where the analogy breaks.
        Research: what to read first (official docs, the real project's source or design docs, papers), as precise questions.
        Working examples: the pieces of the real subsystem you will build and run before teaching, and what each shows.
        Projects: one to three that build a real subsystem, harder each time: the starter files (structure, interfaces, \
        TODOs — no solution), and the tests in `.teacher/tests` that check behaviour: edge cases, failure modes, performance.
        Pitfalls: the misconceptions and bugs learners hit here.
        Keep it under 350 words.
        """

    static func planRequest(_ mode: TeachingMode) -> String { mode == .code ? lessonDesignRequest : planRequest }

    static func planNote(_ plan: String, mode: TeachingMode) -> String {
        guard mode == .code else { return planNote(plan) }
        return """
            <context>
            Your lesson design (hidden from the learner):
            \(plan.trimmingCharacters(in: .whitespacesAndNewlines))

            Carry it out in this order:
            1. Research: read a few primary sources directly with `web_search`/`web_fetch` (the official docs, the real \
            project's source or design notes; three to five pages is plenty) and cite what you use. Don't wait on sub-agents here.
            2. Build two to four working examples with `run_code`, each a complete piece of the real subsystem in one call, and \
            run each until it works; show its real output in the lesson.
            3. Write the lesson: the goal; the real system and why it is built this way; each concept with its analogy and \
            where the analogy breaks; the working examples, explained line by line where it matters; the pitfalls.
            4. Set up the project: starter files in the lesson folder (structure, interfaces, TODOs — no solution) and its \
            tests in `.teacher/tests`; run them with `bash`. The learner edits in their own editor and asks you to check: \
            run the tests, read their changes, and review. Never show solutions.
            </context>
            """
    }

    static func planNote(_ plan: String) -> String {
        """
        <context>
        Your plan for this reply (hidden from the learner):
        \(plan.trimmingCharacters(in: .whitespacesAndNewlines))

        Carry it out before you write: check every item under "Check before teaching" with `math`, `run_code` or a source; \
        answer the Research questions with `web_search`/`web_fetch` (several independent ones in parallel with `task` \
        sub-agents) and cite them. Then write the reply the plan describes.
        </context>
        """
    }

    static let reviewerSystem = """
        You review a tutor's reply before the learner reads it. Be demanding and fair. Ask for a revision only for \
        substantive problems: a factual, numerical or logical error; an important claim stated without checking when it \
        could have been checked; toy or textbook-filler examples where a real one was needed; an essential part of the \
        plan missing; far more than they asked for now (the next part, an unrequested project) at the cost of focus; a full solution handed to a learner who should attempt it first; structure so confused it blocks \
        understanding. Never for style, length or tone preferences.
        Answer in exactly this form:
        VERDICT: OK
        or
        VERDICT: REVISE
        - one specific issue per line, saying what is wrong and what the fix is
        """

    static func reviewInput(request: String, plan: String?, reply: String, evidence: String) -> String {
        var s = "The learner asked:\n\(request.prefix(4_000))\n\n"
        if let plan { s += "The tutor's plan:\n\(plan.prefix(3_000))\n\n" }
        if !evidence.isEmpty { s += "What the tutor checked with tools this turn:\n\(evidence.prefix(8_000))\n\n" }
        return s + "The reply:\n\(reply.prefix(24_000))"
    }

    struct Verdict: Equatable { var revise: Bool; var issues: [String] }

    static func verdict(_ text: String) -> Verdict {
        let revise = text.range(of: #"VERDICT:\s*REVISE"#, options: [.regularExpression, .caseInsensitive]) != nil
        let issues = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("- ") || $0.hasPrefix("* ") }.map { String($0.dropFirst(2)) }
        return Verdict(revise: revise && !issues.isEmpty, issues: Array(issues.prefix(8)))
    }

    static func revisionNote(_ issues: [String]) -> String {
        """
        <context>
        A reviewer read your reply before the learner did and found:
        \(issues.map { "- " + $0 }.joined(separator: "\n"))
        Write the complete, corrected reply now. It replaces your previous one (the learner sees that one collapsed as a \
        draft), so it must stand on its own. Fix every issue, checking with tools where needed; don't mention the review.
        </context>
        """
    }

    struct Collected { var text: String?; var usage = Usage() }

    /// The output and token usage of one model call (no streaming to the learner). Usage matters: plan, review and
    /// summary calls are billed like any other, and leaving them out under-reports a lesson by a third or more.
    static func collect(_ client: LLMClient, _ request: LLMRequest) async -> Collected {
        var text = "", usage = Usage()
        do {
            for try await ev in client.stream(request) {
                if Task.isCancelled { break }
                switch ev {
                case .text(let t): text += t
                case .usage(let u): usage = usage + u
                default: break
                }
            }
        } catch { return Collected(text: nil, usage: usage) }
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Collected(text: t.isEmpty ? nil : t, usage: usage)
    }

    /// What the turn's tools returned, briefly (the reviewer's evidence).
    static func evidence(_ messages: [ChatMessage]) -> String {
        messages.flatMap(\.blocks).compactMap { b -> String? in
            switch b.kind {
            case .toolUse: return "→ \(b.name ?? "tool") \(b.input.map { String($0.compact.prefix(300)) } ?? "")"
            case .toolResult: return "  \(b.isError == true ? "error: " : "")\(String((b.text ?? "").prefix(600)))"
            default: return nil
            }
        }.joined(separator: "\n")
    }
}
