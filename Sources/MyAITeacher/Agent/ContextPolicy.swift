import Foundation

/// Builds the request history from the stored transcript while keeping it lean. All steps are O(n) in history size.
///
/// Tiers (cheapest first):
/// 1. Old reasoning is not resent (except for Claude adaptive models, whose thinking replay is validated).
/// 2. Microcompaction: bulky tool results/inputs and images before `trimmedThrough` are cut to a head+tail stub.
///    The cut point moves in jumps (epochs) so the cached prefix stays stable between jumps.
/// 3. Summary compaction: messages up to `compactedThrough` are replaced by a structured summary.
enum ContextPolicy {
    static let stubLimit = 1_200          // chars kept from an old bulky block
    static let recentTurnsKept = 3        // turns never trimmed

    static func estimateTokens(_ msgs: [ChatMessage]) -> Int {
        var chars = 0
        for m in msgs {
            for b in m.blocks {
                chars += (b.text?.count ?? 0) + (b.input.map { $0.compact.count } ?? 0)
                if b.data != nil { chars += 6_000 }   // ~1.5k tokens per image
            }
        }
        return chars / 4
    }

    /// Indices of messages that start a learner turn (real user messages, not tool results).
    static func turnStarts(_ msgs: [ChatMessage]) -> [Int] {
        msgs.indices.filter { msgs[$0].role == .user && !msgs[$0].isToolResultOnly }
    }

    /// Request-ready history.
    static func prepare(_ stored: [ChatMessage], conversation c: Conversation, model: String) -> [ChatMessage] {
        var msgs = stored.filter { m in
            if m.role == .assistant && m.blocks.isEmpty { return false }
            if m.role == .assistant && m.error != nil && m.toolUses.isEmpty && m.plainText.isEmpty { return false }
            return true
        }
        // Tier 3: summary replaces the compacted prefix.
        if let through = c.compactedThrough, let summary = c.compactSummary, let cut = msgs.firstIndex(where: { $0.id == through }) {
            let head = ChatMessage(role: .user, blocks: [.text("<lesson_summary>\nEarlier part of this lesson, summarised:\n\n\(summary)\n</lesson_summary>")])
            msgs = [head] + msgs[(cut + 1)...]
        }
        let keepThinking = AnthropicClient.isAdaptiveClaude(model)
        let lastAssistant = msgs.lastIndex { $0.role == .assistant } ?? -1
        let lastTurnStart = turnStarts(msgs).last ?? 0
        let trimEnd = c.trimmedThrough.flatMap { t in msgs.firstIndex { $0.id == t } } ?? -1
        for i in msgs.indices {
            // Tier 1: drop reasoning from earlier turns (the current tool loop keeps it — some providers require it).
            if !keepThinking && i < lastTurnStart && i != lastAssistant {
                msgs[i].blocks.removeAll { $0.kind == .thinking }
            }
            // Tier 2: microcompaction of the old prefix.
            if i <= trimEnd {
                msgs[i].blocks = msgs[i].blocks.map(trim)
            }
        }
        return mergeConsecutiveUserTurns(msgs)
    }

    /// Messages split into runs of at most `maxChars` (a message is never split).
    static func chunks(_ msgs: [ChatMessage], maxChars: Int) -> [[ChatMessage]] {
        var out: [[ChatMessage]] = [], cur: [ChatMessage] = [], size = 0
        for m in msgs {
            let n = m.blocks.reduce(0) { $0 + ($1.text?.count ?? 0) + ($1.input?.compact.count ?? 0) }
            if size + n > maxChars, !cur.isEmpty { out.append(cur); cur = []; size = 0 }
            cur.append(m); size += n
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    /// A summary made without a model (when the summary call fails): the learner's requests and the teacher's openings.
    static func digest(_ msgs: [ChatMessage], previous: String?) -> String {
        var lines: [String] = previous.map { [$0, ""] } ?? []
        lines.append("Later in the lesson (condensed):")
        for m in msgs where !m.isToolResultOnly {
            let t = m.plainText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            let first = t.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? t
            lines.append((m.role == .user ? "- Learner: " : "- Teacher: ") + MemoryText.clip(first, 160))
        }
        let s = lines.joined(separator: "\n")
        return s.count > 8000 ? String(s.suffix(8000)) : s
    }

    /// Last resort when a request is still over budget (one huge turn, or a summary that couldn't help): the largest
    /// tool outputs and long texts — never the newest learner message — are cut to head + tail in the request copy.
    static func squeeze(_ msgs: [ChatMessage], budget: Int) -> [ChatMessage] {
        var total = estimateTokens(msgs)
        guard total > budget, budget > 0 else { return msgs }
        let lastUser = msgs.lastIndex { $0.role == .user && !$0.isToolResultOnly } ?? -1
        var big: [(Int, Int, Int)] = []
        for (i, m) in msgs.enumerated() where i != lastUser {
            for (j, b) in m.blocks.enumerated() where (b.kind == .toolResult || b.kind == .text) && (b.text?.count ?? 0) > 6000 { big.append((i, j, b.text!.count)) }
        }
        var out = msgs
        for (i, j, n) in big.sorted(by: { $0.2 > $1.2 }) where total > budget {
            let t = out[i].blocks[j].text!
            let head = String(t.prefix(3000)), tail = String(t.suffix(1500))
            out[i].blocks[j].text = head + "\n[… \(n - 4500) characters trimmed to fit the context …]\n" + tail
            total -= (n - 4600) / 4
        }
        return out
    }

    /// Two learner-side messages in a row (a background agent's report after tool results, the summary before the next
    /// prompt) become one — tool results first, then the rest: the shape every provider accepts.
    static func mergeConsecutiveUserTurns(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out: [ChatMessage] = []
        out.reserveCapacity(msgs.count)
        for m in msgs {
            if m.role == .user, let last = out.last, last.role == .user {
                let all = last.blocks + m.blocks
                out[out.count - 1].blocks = all.filter { $0.kind == .toolResult } + all.filter { $0.kind != .toolResult }
            } else { out.append(m) }
        }
        return out
    }

    static func trim(_ b: Block) -> Block {
        var b = b
        switch b.kind {
        case .toolResult:
            if let t = b.text, t.count > stubLimit { b.text = stub(t) }
            b.data = nil; b.mime = nil
        case .toolUse:
            if case .object(var o) = b.input ?? .null {
                for (k, v) in o { if let s = v.string, s.count > stubLimit { o[k] = .string(stub(s)) } }
                b.input = .object(o)
            }
        case .image:
            b = .text("[image the learner shared earlier]")
        case .file:
            if let t = b.text, t.count > stubLimit * 2 { b.text = stub(t) }
        default: break
        }
        return b
    }

    static func stub(_ s: String) -> String {
        "\(s.prefix(stubLimit * 2 / 3))\n…[\(s.count - stubLimit) chars trimmed from an earlier step; re-run the tool if you need them]…\n\(s.suffix(stubLimit / 3))"
    }

    /// Where the next microcompaction epoch should end (message id), or nil if not worth it yet.
    static func nextTrimPoint(_ stored: [ChatMessage], current: String?) -> String? {
        let starts = turnStarts(stored)
        guard starts.count > recentTurnsKept else { return nil }
        let boundary = starts[starts.count - recentTurnsKept] - 1
        guard boundary >= 0 else { return nil }
        let id = stored[boundary].id
        return id == current ? nil : id
    }

    /// Effective budget: the setting, capped at half the model's context window when known.
    static func budget(setting: Int, contextWindow: Int?) -> Int {
        guard let w = contextWindow, w > 0 else { return setting }
        return min(setting, w / 2)
    }
}
