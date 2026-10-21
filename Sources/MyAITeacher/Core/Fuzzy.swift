import Foundation

/// Forgiving search for short catalogues (models, providers): every word of the query must match somewhere, in any order
/// ("nvidia deepseek" = "deepseek nvidia"), with typos allowed on words ("nvdia deepsek"), partial words ("deeps"),
/// and separators ignored ("v4pro" finds "deepseek-v4-pro"). Numbers must match exactly: "v4" never finds "v3".
enum Fuzzy {
    /// Lowercased words: split at spaces and the punctuation ids use (`/ - _ . :`), diacritics folded.
    static func words(_ s: String) -> [String] {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// 0…1 relevance of `fields` (e.g. provider name, model id) to `query`; nil when some query word matches nothing.
    /// `lengthOf`: what the shorter-is-better nudge measures (the model id, not the provider's name repeated).
    static func score(_ query: String, _ fields: [String], lengthOf: String? = nil) -> Double? {
        let q = words(query)
        guard !q.isEmpty else { return 1 }
        let cw = fields.flatMap(words), compact = cw.joined()
        var total = 0.0
        for t in q {
            guard let s = best(t, cw, compact) else { return nil }
            total += s
        }
        // Query words that sit side by side in the name, too: "sonnet 5.5" is claude-sonnet-5.5 before sonnet-5 or 4.5.
        var together = 0
        for (a, b) in zip(q, q.dropFirst()) where cw.indices.dropLast().contains(where: { cw[$0].hasPrefix(a) && cw[$0 + 1].hasPrefix(b) }) { together += 1 }
        let adjacency = q.count > 1 ? 0.05 * Double(together) / Double(q.count - 1) : 0
        // Mean word quality, nudged toward shorter names (the plain model before its variants).
        let length = lengthOf.map { words($0).joined().count } ?? compact.count
        return total / Double(q.count) + adjacency - Double(length) / 10_000
    }

    private static func best(_ t: String, _ cw: [String], _ compact: String) -> Double? {
        if cw.contains(t) { return 1 }
        if cw.contains(where: { $0.hasPrefix(t) }) { return 0.9 }
        if compact.contains(t) { return 0.8 }
        // Typos only on words of letters: digits carry versions and sizes, where "close" is wrong.
        guard t.count >= 3, !t.contains(where: \.isNumber) else { return nil }
        let k = t.count >= 7 ? 2 : 1
        var bestD = Int.max
        for w in cw {
            // The whole word (if it has no digits: "nvdia" → "nvidia"), or the start of a longer word being typed ("deepsk").
            if !w.contains(where: \.isNumber) { bestD = min(bestD, distance(t, w, limit: k)) }
            if w.count > t.count { bestD = min(bestD, distance(t, String(w.prefix(t.count)), limit: k)) }
            if bestD == 1 { break }
        }
        return bestD <= k ? 0.7 - 0.15 * Double(bestD - 1) : nil
    }

    /// Optimal-string-alignment distance (insert, delete, substitute, swap neighbours), cut off above `limit`.
    static func distance(_ a: String, _ b: String, limit: Int) -> Int {
        let a = Array(a), b = Array(b)
        if abs(a.count - b.count) > limit { return limit + 1 }
        if a.isEmpty || b.isEmpty { return max(a.count, b.count) }
        var prev2 = [Int](repeating: 0, count: b.count + 1), prev = Array(0...b.count), cur = prev
        for i in 1...a.count {
            cur[0] = i
            var rowMin = cur[0]
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
                if i > 1, j > 1, a[i - 1] == b[j - 2], a[i - 2] == b[j - 1] { cur[j] = min(cur[j], prev2[j - 2] + 1) }
                rowMin = min(rowMin, cur[j])
            }
            if rowMin > limit { return limit + 1 }
            (prev2, prev, cur) = (prev, cur, prev2)
        }
        return prev[b.count]
    }
}
