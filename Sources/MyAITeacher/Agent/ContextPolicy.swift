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
        for m in msgs { units += messageTokens(m) }
        return Int(units)
    }

    /// Per-message estimates, keyed by id and size: a step estimates the whole history two or three times (budget check,
    /// squeeze, compaction), and scanning every scalar of a long lesson each time cost tens of milliseconds on the main
    /// thread. A trimmed, merged or edited copy changes size, so it misses and is counted afresh. Bounded: cleared whole.
    private static let tokenCache = Locked<[String: Double]>([:])
    static let tokenCacheLimit = 20_000

    private static func messageTokens(_ m: ChatMessage) -> Double {
        let key = "\(m.id)#\(m.blocks.count)#\(m.approxBytes)"
        if let hit = tokenCache.mutate({ $0[key] }) { return hit }
        var units = 0.0
        for b in m.blocks {
            if let t = b.text { units += tokens(t) }
            if let i = b.input { units += tokens(i.compact) }
            if b.hasPayload { units += 1_500 }   // ~1.5k tokens per image
        }
        tokenCache.mutate { c in
            if c.count >= tokenCacheLimit { c.removeAll(keepingCapacity: true) }
            c[key] = units
        }
        return units
    }

    /// A cheap, script-aware estimate: Latin text is ~4 characters per token, but CJK, kana and Hangul are ~1 per
    /// character. Counting them as ¼ (as the app used to) under-estimates a Japanese or Chinese lesson 4–6×, so the
    /// budget, microcompaction and last-resort squeeze all fire too late — or the provider rejects the request.
    /// The token estimate of one string, for callers cutting text themselves.
    static func estimate(_ text: String) -> Int { Int(tokens(text)) }

    /// A CJK character is about a token; anything else about a quarter of one.
    private static func tokens(_ s: String) -> Double {
        guard !s.isEmpty else { return 0 }
        let (total, cjk) = FastText.scalarCounts(s)
        return Double(cjk) + Double(total - cjk) / 4.0
    }

    /// Indices of messages that start a learner turn (real user messages, not tool results or the loop's hidden notes).
    static func turnStarts(_ msgs: [ChatMessage]) -> [Int] {
        msgs.indices.filter { msgs[$0].startsTurn }
    }

    /// How many of the oldest loaded messages can leave memory: only display-only ones (before `cut`, the compaction
    /// point) and whole turns, enough to bring the rest within `window` messages and `maxBytes`; 0 when none can go.
    static func windowTrim(_ msgs: [ChatMessage], cut: Int, window: Int, maxBytes: Int) -> Int {
        var bytes = msgs.reduce(0) { $0 + $1.approxBytes }, want = 0
        while want < min(cut, msgs.count), msgs.count - want > window || bytes > maxBytes { bytes -= msgs[want].approxBytes; want += 1 }
        guard want > 0 else { return 0 }
        // A whole turn is nicer to page back to, but never at the cost of an unbounded window: when the post-compaction
        // region alone exceeds it, drop everything that is display-only (it is already summarised for requests).
        return turnStarts(msgs).first { $0 >= want && $0 <= cut } ?? cut
    }

    /// Request-ready history.
    static func prepare(_ stored: [ChatMessage], conversation c: Conversation, model: String) -> [ChatMessage] {
        let sp = Signposts.begin("context", "\(stored.count) messages"); defer { Signposts.end("context", sp) }
        // The compaction points name stored messages (the one before a cut may be an empty, failed reply that requests
        // leave out), so both are resolved against the stored list before anything is dropped.
        var msgs = expandRepeats(stored, conversation: c)
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

    /// A repeat `read` of an unchanged file answers "unchanged" and points at the earlier result (`sameAs`). That only
    /// works while the earlier result reaches the model intact: once microcompaction stubs it or the summary replaces it,
    /// the note would leave the model with neither. So here, before either tier, a note whose earlier result is no longer
    /// intact (or is not loaded) becomes the file itself, from the stored transcript, or an instruction to read it again.
    static func expandRepeats(_ stored: [ChatMessage], conversation c: Conversation) -> [ChatMessage] {
        guard stored.contains(where: { $0.blocks.contains { $0.kind == .toolResult && $0.meta?["sameAs"] != nil } }) else { return stored }
        let cut = c.compactedThrough.flatMap { t in stored.firstIndex { $0.id == t } } ?? -1
        let trim = c.trimmedThrough.flatMap { t in stored.firstIndex { $0.id == t } } ?? -1
        let intactFrom = max(cut, trim) + 1
        var at: [String: (i: Int, j: Int)] = [:]
        for (i, m) in stored.enumerated() where m.role == .user {
            for (j, b) in m.blocks.enumerated() where b.kind == .toolResult { if let id = b.id { at[id] = (i, j) } }
        }
        var out = stored
        for i in out.indices where i > cut {
            for j in out[i].blocks.indices {
                guard out[i].blocks[j].kind == .toolResult, let ref = out[i].blocks[j].meta?["sameAs"]?.string else { continue }
                if let t = at[ref], t.i >= intactFrom, t.i < i { continue }
                var meta = out[i].blocks[j].meta?.object ?? [:]; meta["sameAs"] = nil
                out[i].blocks[j].meta = .object(meta)
                if let t = at[ref], t.i < i, let full = stored[t.i].blocks[t.j].text, stored[t.i].blocks[t.j].meta?["sameAs"] == nil {
                    out[i].blocks[j].text = full
                } else {
                    out[i].blocks[j].text = "The file is unchanged since you read it, but that earlier result is no longer in this conversation: `read` it again if you need it."
                }
            }
        }
        return out
    }

    /// Ids of the tool results a request sends whole (none for Claude with replayed thinking, whose history the API edits itself): after the compaction point and the microcompaction epoch, and only
    /// while the lesson fits `budget` (past it the last-resort squeeze may cut anything). Cut or failed results are not
    /// among them. What a repeat `read` may point back to.
    static func liveResults(_ msgs: [ChatMessage], conversation c: Conversation, model: String, budget: Int) -> Set<String> {
        // The request, not the stored lesson: a compacted lesson's history is long but its request is small. Over budget the
        // squeeze may cut anything.
        guard !AnthropicClient.isAdaptiveClaude(model), estimateTokens(prepare(msgs, conversation: c, model: model)) <= budget else { return [] }
        let from = max(c.compactedThrough.flatMap { t in msgs.firstIndex { $0.id == t } } ?? -1,
                       c.trimmedThrough.flatMap { t in msgs.firstIndex { $0.id == t } } ?? -1) + 1
        var ids = Set<String>()
        for m in msgs[from...] where m.role == .user {
            for b in m.blocks where b.kind == .toolResult && b.isError != true && b.meta?["running"] == nil && b.meta?["sameAs"] == nil
                && b.meta?["stepCapped"] == nil && b.meta?["spilled"] == nil { if let i = b.id { ids.insert(i) } }   // a spilled result keeps only a preview
        }
        return ids
    }

    /// The squeeze cuts the biggest results to head and tail; a note pointing at one of them would leave the model with a
    /// fragment. Such a note says to read the file again instead.
    static func demoteSqueezedNotes(_ msgs: [ChatMessage]) -> [ChatMessage] {
        guard msgs.contains(where: { $0.blocks.contains { $0.meta?["sameAs"] != nil } }) else { return msgs }
        var cut = Set<String>()
        for m in msgs { for b in m.blocks where b.kind == .toolResult && b.text?.contains("characters trimmed to fit the context") == true { if let i = b.id { cut.insert(i) } } }
        guard !cut.isEmpty else { return msgs }
        var out = msgs
        for i in out.indices { for j in out[i].blocks.indices {
            guard let ref = out[i].blocks[j].meta?["sameAs"]?.string, cut.contains(ref) else { continue }
            var meta = out[i].blocks[j].meta?.object ?? [:]; meta["sameAs"] = nil
            out[i].blocks[j].meta = .object(meta)
            out[i].blocks[j].text = "The file is unchanged since you read it, but that earlier result was cut to fit the context: `read` it again if you need it."
        } }
        return out
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
        // Tool inputs too (a `write` carrying a whole file is often the biggest thing in a coding lesson) — except with
        // signed thinking in the history, where an edited earlier tool call invalidates the replayed reasoning.
        let signed = msgs.contains { $0.blocks.contains { $0.kind == .thinking && $0.signature != nil } }
        var big: [(i: Int, j: Int, key: String?, n: Int)] = []
        for (i, m) in msgs.enumerated() where i != lastUser {
            for (j, b) in m.blocks.enumerated() {
                if (b.kind == .toolResult || b.kind == .text), let n = b.text?.count, n > squeezeOver { big.append((i, j, nil, n)) }
                if b.kind == .toolUse, !signed, case .object(let o) = b.input ?? .null {
                    for (k, v) in o { if let n = v.string?.count, n > squeezeOver { big.append((i, j, k, n)) } }
                }
            }
        }
        var out = msgs
        for (i, j, key, n) in big.sorted(by: { $0.n > $1.n }) where total > budget {
            let t = key.map { out[i].blocks[j].input?[$0]?.string ?? "" } ?? out[i].blocks[j].text ?? ""
            let cut = String(t.prefix(3000)) + "\n[… \(n - 4500) characters trimmed to fit the context …]\n" + String(t.suffix(1500))
            if let key, case .object(var o) = out[i].blocks[j].input ?? .null {
                o[key] = .string(cut); out[i].blocks[j].input = .object(o)
            } else {
                out[i].blocks[j].text = cut
            }
            total -= max(0, estimate(t) - estimate(cut))
        }
        return out
    }
    /// Characters past which a block (or tool-input field) is a squeeze candidate.
    static let squeezeOver = 6000

    /// For a model that cannot see images: every picture becomes a short note saying one was attached, so the lesson
    /// goes on (the provider would otherwise refuse the whole request) and the tutor knows to ask about it.
    static let imageNote = "[The learner attached an image. This model can't see images: ask them to describe it or paste its text.]"
    static func describeImages(_ msgs: [ChatMessage]) -> [ChatMessage] {
        var out = msgs
        for i in out.indices {
            out[i].blocks = out[i].blocks.map { b in
                if b.kind == .image { return .text(imageNote) }
                guard b.kind == .toolResult, b.hasPayload else { return b }
                var t = b; t.data = nil; t.blob = nil; t.mime = nil
                t.text = (t.text ?? "") + "\n[image omitted: this model can't see images]"
                return t
            }
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
        case .text:
            // Per-turn context (memory recall, a plan, a revision note) has been read by the model; older copies are dead
            // weight in every later request. The transcript keeps the full text.
            if b.meta?["ephemeral"]?.bool == true, let t = b.text, t.count > stubLimit { b.text = stub(t) }
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
