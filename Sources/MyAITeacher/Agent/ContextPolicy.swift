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
        var units = 0.0
        for m in msgs {
            for b in m.blocks {
                if let t = b.text { units += tokens(t) }
                if let i = b.input { units += tokens(i.compact) }
                if b.hasPayload { units += 1_500 }   // ~1.5k tokens per image
            }
        }
        return Int(units)
    }

    /// A cheap, script-aware estimate: Latin text is ~4 characters per token, but CJK, kana and Hangul are ~1 per
    /// character. Counting them as ¼ (as the app used to) under-estimates a Japanese or Chinese lesson 4–6×, so the
    /// budget, microcompaction and last-resort squeeze all fire too late — or the provider rejects the request.
    /// The token estimate of one string, for callers cutting text themselves.
    static func estimate(_ text: String) -> Int { Int(tokens(text)) }

    private static func tokens(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        var cjk = 0, total = 0
        for u in s.unicodeScalars {
            total += 1
            if isCJK(u) { cjk += 1 }
        }
        return Double(cjk) + Double(total - cjk) / 4.0
    }
    private static func isCJK(_ u: Unicode.Scalar) -> Bool {
        switch u.value {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default: return false
        }
    }

    /// Indices of messages that start a learner turn (real user messages, not tool results).
    static func turnStarts(_ msgs: [ChatMessage]) -> [Int] {
        msgs.indices.filter { msgs[$0].role == .user && !msgs[$0].isToolResultOnly }
    }

    /// How many of the oldest loaded messages can leave memory: only display-only ones (before `cut`, the compaction
    /// point) and whole turns, enough to bring the rest within `window` messages and `maxBytes`; 0 when none can go.
    static func windowTrim(_ msgs: [ChatMessage], cut: Int, window: Int, maxBytes: Int) -> Int {
        var bytes = msgs.reduce(0) { $0 + $1.approxBytes }, want = 0
        while want < min(cut, msgs.count), msgs.count - want > window || bytes > maxBytes { bytes -= msgs[want].approxBytes; want += 1 }
        guard want > 0 else { return 0 }
        return turnStarts(msgs).first { $0 >= want && $0 <= cut } ?? 0
    }

    /// Request-ready history.
    static func prepare(_ stored: [ChatMessage], conversation c: Conversation, model: String) -> [ChatMessage] {
        let sp = Signposts.begin("context", "\(stored.count) messages"); defer { Signposts.end("context", sp) }
        // The compaction points name stored messages (the one before a cut may be an empty, failed reply that requests
        // leave out), so both are resolved against the stored list before anything is dropped.
        var msgs = stored
        // Tier 3: summary replaces the compacted prefix.
        if let through = c.compactedThrough, let summary = c.compactSummary, let cut = msgs.firstIndex(where: { $0.id == through }) {
            let head = ChatMessage(role: .user, blocks: [.text("<lesson_summary>\nEarlier part of this lesson, summarised:\n\n\(summary)\n</lesson_summary>")])
            msgs = [head] + msgs[(cut + 1)...]
        }
        let trimThrough = c.trimmedThrough.flatMap { t in msgs.firstIndex { $0.id == t } } ?? -1
        var kept: [ChatMessage] = [], trimEnd = -1
        kept.reserveCapacity(msgs.count)
        for (i, m) in msgs.enumerated() {
            if m.role == .assistant && m.blocks.isEmpty { continue }
            if m.role == .assistant && m.error != nil && m.toolUses.isEmpty && m.plainText.isEmpty { continue }
            kept.append(m)
            if i <= trimThrough { trimEnd = kept.count - 1 }
        }
        msgs = kept
        let keepThinking = AnthropicClient.isAdaptiveClaude(model)
        let lastAssistant = msgs.lastIndex { $0.role == .assistant } ?? -1
        let lastTurnStart = turnStarts(msgs).last ?? 0
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
        if !keepThinking { dropOldCaptures(&msgs) }
        return mergeConsecutiveUserTurns(msgs)
    }

    /// Screenshots of the browser and the Mac go stale at once: requests carry only the latest `capturesKept` (a long
    /// computer-use turn would otherwise resend every image it took). Older ones keep their text, minus the pixels.
    /// Not for Claude with replayed thinking: editing an earlier tool result invalidates every later thinking block (a
    /// 400), so there the API clears old tool results itself (`AnthropicClient.clearsToolUsesServerSide`).
    static let capturesKept = 2
    static let captureTools: Set<String> = ["browser", "computer", "mac"]
    static func dropOldCaptures(_ msgs: inout [ChatMessage]) {
        var seen = 0
        for i in msgs.indices.reversed() where msgs[i].role == .user {
            for j in msgs[i].blocks.indices.reversed() where msgs[i].blocks[j].kind == .toolResult && msgs[i].blocks[j].hasPayload
                && captureTools.contains(msgs[i].blocks[j].name ?? "") {
                seen += 1
                guard seen > capturesKept else { continue }
                msgs[i].blocks[j].data = nil; msgs[i].blocks[j].blob = nil; msgs[i].blocks[j].mime = nil
                msgs[i].blocks[j].text = (msgs[i].blocks[j].text ?? "") + "\n[image dropped: only the latest \(capturesKept) screenshots are sent]"
            }
        }
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
            b.data = nil; b.blob = nil; b.mime = nil
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
    /// Automatic (0): half the model's window, up to 400k: a 1M-token model reasons over the lesson itself, not a summary
    /// of it once a lesson passes a fixed 48k (prompt caching keeps the long prefix cheap). Unknown window: 64k.
    static let automaticCap = 400_000, automaticFallback = 64_000
    static func budget(setting: Int, contextWindow: Int?) -> Int {
        guard setting > 0 else { return contextWindow.map { $0 > 0 ? min($0 / 2, automaticCap) : automaticFallback } ?? automaticFallback }
        guard let w = contextWindow, w > 0 else { return setting }
        return min(setting, w / 2)
    }
}
