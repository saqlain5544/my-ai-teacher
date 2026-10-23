import Foundation

/// Word-level alignment of what the learner wrote or said against a target text: the shared core of checked dictation,
/// speaking attempts and correction views. Words for spaced scripts, characters for scripts written without spaces
/// (Japanese, Chinese, Thai). Order matters (a longest common subsequence), unlike a bag of words: "días buenos" is not
/// "buenos días". The page's components/langwork.js aligns the same way, so the score the app grades with is the one the
/// learner sees.
enum TextDiff {
    struct Token: Equatable, Sendable {
        var text: String   // as written
        var norm: String   // what is compared
    }
    enum Kind: String, Sendable { case same, wrong, missing, extra }
    /// One step of the alignment: `target` and `given` tokens (a wrong word has both, a missing one only the target).
    struct Op: Equatable, Sendable {
        var kind: Kind
        var target: String?
        var given: String?
    }
    struct Result: Sendable {
        var ops: [Op]
        var targetCount: Int
        /// Target tokens matched in order, over the target's tokens plus any extra ones (0…1): words added that aren't in
        /// the target count against it ("el gato negro come mucho" is not "el gato negro").
        var score: Double { targetCount == 0 ? 0 : Double(ops.filter { $0.kind == .same }.count) / Double(targetCount + ops.filter { $0.kind == .extra }.count) }
        var wrong: [Op] { ops.filter { $0.kind == .wrong } }
        var missing: [String] { ops.filter { $0.kind == .missing }.compactMap(\.target) }
        var extra: [String] { ops.filter { $0.kind == .extra }.compactMap(\.given) }
        /// "missed: x, y · wrote a for b · extra: z" for the teacher.
        var summary: String {
            var parts: [String] = []
            if !wrong.isEmpty { parts.append("wrote " + wrong.map { "“\($0.given ?? "")” for “\($0.target ?? "")”" }.joined(separator: ", ")) }
            if !missing.isEmpty { parts.append("missed " + missing.map { "“\($0)”" }.joined(separator: ", ")) }
            if !extra.isEmpty { parts.append("added " + extra.map { "“\($0)”" }.joined(separator: ", ")) }
            return parts.isEmpty ? "every word right" : parts.joined(separator: "; ")
        }
    }

    /// Scripts written without spaces between words: compared character by character.
    static func unspaced(_ s: String) -> Bool {
        s.unicodeScalars.contains { [.han, .kana, .thai].contains(ScriptRuns.script(of: $0)) }
    }

    /// Japanese is compared by reading (kana), so 食べる written as たべる, or heard as 食べる when said, is right; `strict`
    /// compares the writing itself.
    static func tokens(_ s: String, strict: Bool = false, lang: String? = nil) -> [Token] {
        let ja = lang.flatMap(Languages.code) == "ja" || s.unicodeScalars.contains { ScriptRuns.script(of: $0) == .kana }
        if ja && !strict {
            return TextAnalysis.japaneseKana(s).map { Token(text: String($0), norm: String($0)) }
        }
        if unspaced(s) {
            return s.filter { $0.isLetter || $0.isNumber }.map { c in Token(text: String(c), norm: Questions.norm(String(ScriptComposer.toHiragana(String(c))), strict: strict)) }
        }
        return s.split(whereSeparator: { $0.isWhitespace }).compactMap { w in
            let n = Questions.norm(String(w), strict: strict)
            guard !n.isEmpty else { return nil }   // punctuation on its own
            return Token(text: String(w).trimmingCharacters(in: .punctuationCharacters.union(.symbols)), norm: n)
        }
    }

    /// The alignment of `given` against `target` (case-insensitive; accents count only when `strict`).
    static func align(target: String, given: String, strict: Bool = false, lang: String? = nil) -> Result {
        let ja = lang.flatMap(Languages.code) == "ja" || (target + given).unicodeScalars.contains { ScriptRuns.script(of: $0) == .kana }
        let l = ja ? "ja" : lang
        // Japanese: by reading (kana for kanji is right), or by the writing itself when that matches better (the learner
        // wrote the kanji, and the tokenizer's reading of a word can be the rarer one).
        if l == "ja" && !strict {
            let byReading = alignTokens(tokens(target, lang: "ja"), tokens(given, lang: "ja"))
            let bySurface = alignTokens(tokens(target, strict: true, lang: "ja"), tokens(given, strict: true, lang: "ja"))
            return bySurface.score > byReading.score ? bySurface : byReading
        }
        return alignTokens(tokens(target, strict: strict, lang: l), tokens(given, strict: strict, lang: l))
    }

    static func alignTokens(_ t: [Token], _ g: [Token]) -> Result {
        let n = t.count, m = g.count
        // LCS table over normalised tokens.
        var L = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        if n > 0 && m > 0 {
            for i in stride(from: n - 1, through: 0, by: -1) {
                for j in stride(from: m - 1, through: 0, by: -1) {
                    L[i][j] = t[i].norm == g[j].norm ? L[i + 1][j + 1] + 1 : max(L[i + 1][j], L[i][j + 1])
                }
            }
        }
        var raw: [Op] = []
        var i = 0, j = 0
        while i < n || j < m {
            if i < n, j < m, t[i].norm == g[j].norm { raw.append(Op(kind: .same, target: t[i].text, given: g[j].text)); i += 1; j += 1 }
            else if j < m, i == n || L[i][j + 1] >= L[i + 1][j] { raw.append(Op(kind: .extra, target: nil, given: g[j].text)); j += 1 }
            else { raw.append(Op(kind: .missing, target: t[i].text, given: nil)); i += 1 }
        }
        // A missing target word next to an extra given one is a wrong word ("dias" for "días" in strict mode).
        var ops: [Op] = []
        var k = 0
        while k < raw.count {
            let a = raw[k]
            var run: [Op] = []
            while k < raw.count, raw[k].kind != .same { run.append(raw[k]); k += 1 }
            if run.isEmpty { ops.append(a); k += 1; continue }
            let miss = run.filter { $0.kind == .missing }, extra = run.filter { $0.kind == .extra }
            let pairs = min(miss.count, extra.count)
            for p in 0..<pairs { ops.append(Op(kind: .wrong, target: miss[p].target, given: extra[p].given)) }
            ops += miss.dropFirst(pairs) + extra.dropFirst(pairs)
        }
        return Result(ops: ops, targetCount: n)
    }
}
