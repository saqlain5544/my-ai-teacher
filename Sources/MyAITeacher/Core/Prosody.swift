import Foundation

/// Pronunciation feedback the audio can honestly support, from pitch and loudness alone (no phoneme models):
///   - Mandarin tones per syllable: the learner's voice is cut into as many syllables as the sentence has characters
///     (its voiced stretches, joined or cut at loudness dips), each syllable's pitch shape is classified (high level, rising, dipping/low,
///     falling), and compared with the tone the sentence expects (third-tone, 不 and 一 sandhi applied). The same is done on the
///     synthetic voice saying the sentence; a syllable where the method doesn't recover the expected tone even from
///     that voice is reported as "not measurable" instead of judged.
///   - Japanese pitch accent (a word or short phrase): where the pitch first falls sharply (the accent drop), as a mora
///     position (morae as equal shares of the voiced time), in the learner's voice and
///     in the synthetic voice's.
///   - Stress (single words, alphabetic languages): the most prominent syllable (pitch and loudness), learner vs
///     synthetic voice.
/// Syllable boundaries come from timing and loudness, so this is approximate; the card says what was measured.
enum Prosody {
    struct Syllable { var start: Int; var end: Int }   // 10 ms frames

    /// Pitch for syllable work: 16 kHz (finer than the chart's), a looser voicing threshold (glides and creak at
    /// syllable edges carry the tone), and silence after the end so the last syllable is tracked to its end.
    static func f0(_ s: [Float], rate: Double) -> [Double?] {
        Pitch.track(s + [Float](repeating: 0, count: Int(rate * 0.3)), sampleRate: rate, workRate: 16_000, threshold: 0.25)
    }

    /// Loudness per 10 ms frame (RMS) of 16 kHz-equivalent audio.
    static func energy(_ s: [Float], rate: Double) -> [Float] {
        let hop = max(1, Int(rate * 0.01)), win = max(1, Int(rate * 0.03))
        var out: [Float] = []
        var i = 0
        while i + win <= s.count {
            var sum: Float = 0
            for k in i..<(i + win) { sum += s[k] * s[k] }
            out.append((sum / Float(win)).squareRoot())
            i += hop
        }
        return out
    }

    /// `n` syllables. Voiced stretches first (pitch present, 40 ms gaps or more between them): when there are exactly
    /// `n`, they are the syllables; when there are more, the closest neighbours are joined; when fewer, the longest
    /// stretch is cut at its loudness dip. nil when there isn't enough voice for `n` syllables.
    static func syllables(_ e: [Float], f0: [Double?], count n: Int) -> [Syllable]? {
        guard n > 0, let first = f0.firstIndex(where: { $0 != nil }), let last = f0.lastIndex(where: { $0 != nil }), last - first >= n * 6 else { return nil }
        var runs: [Syllable] = []
        var i = first
        while i <= last {
            guard f0[i] != nil else { i += 1; continue }
            var j = i
            while j + 1 <= last { if f0[j + 1] != nil { j += 1; continue }; var k = j + 1; while k <= last && f0[k] == nil { k += 1 }; if k - j - 1 < 4 && k <= last { j = k } else { break } }
            if j - i >= 3 { runs.append(Syllable(start: i, end: j)) }
            i = j + 1
        }
        while runs.count > n {
            let k = (0..<(runs.count - 1)).min(by: { runs[$0 + 1].start - runs[$0].end < runs[$1 + 1].start - runs[$1].end })!
            runs[k].end = runs[k + 1].end; runs.remove(at: k + 1)
        }
        while !runs.isEmpty && runs.count < n {
            let k = runs.indices.max(by: { runs[$0].end - runs[$0].start < runs[$1].end - runs[$1].start })!
            let r = runs[k]
            guard r.end - r.start >= 10 else { break }
            let lo = r.start + (r.end - r.start) / 4, hi = r.end - (r.end - r.start) / 4
            let cut = (lo...hi).min(by: { (($0 < e.count) ? e[$0] : 0) < (($1 < e.count) ? e[$1] : 0) }) ?? (r.start + r.end) / 2
            runs[k] = Syllable(start: r.start, end: cut - 1); runs.insert(Syllable(start: cut, end: r.end), at: k + 1)
        }
        if runs.count == n { return runs }
        let lo = first, hi = min(last, e.count - 1)
        guard hi > lo else { return nil }
        // Smoothed loudness (50 ms).
        var sm = [Float](repeating: 0, count: e.count)
        for i in lo...hi { var s: Float = 0, c: Float = 0; for k in max(lo, i - 2)...min(hi, i + 2) { s += e[k]; c += 1 }; sm[i] = s / c }
        var peaks: [Int] = []
        for i in (lo + 1)..<hi where sm[i] >= sm[i - 1] && sm[i] >= sm[i + 1] { peaks.append(i) }
        if peaks.count < n {
            // Too few peaks (one long vowel run): equal shares of the voiced span.
            let w = Double(hi - lo + 1) / Double(n)
            return (0..<n).map { k in Syllable(start: lo + Int(Double(k) * w), end: lo + Int(Double(k + 1) * w) - 1) }
        }
        var chosen: [Int] = []
        for p in peaks.sorted(by: { sm[$0] > sm[$1] }) where chosen.allSatisfy({ abs($0 - p) >= 8 }) {
            chosen.append(p); if chosen.count == n { break }
        }
        guard chosen.count == n else {
            let w = Double(hi - lo + 1) / Double(n)
            return (0..<n).map { k in Syllable(start: lo + Int(Double(k) * w), end: lo + Int(Double(k + 1) * w) - 1) }
        }
        chosen.sort()
        var cuts = [lo]
        for k in 0..<(n - 1) {
            let a = chosen[k], b = chosen[k + 1]
            cuts.append((a...b).min(by: { sm[$0] < sm[$1] }) ?? (a + b) / 2)
        }
        cuts.append(hi + 1)
        return (0..<n).map { Syllable(start: cuts[$0], end: max(cuts[$0], cuts[$0 + 1] - 1)) }
    }

    // MARK: Mandarin tones

    /// A syllable's pitch (semitones around the speaker's median), its voiced frames only, lightly smoothed.
    static func contour(_ f0: [Double?], _ s: Syllable, median: Double) -> [Double] {
        let v = f0[max(0, s.start)...min(f0.count - 1, s.end)].compactMap { $0 }.map { 12 * log2($0 / median) }
        guard v.count >= 3 else { return v }
        return v.indices.map { i in let w = v[max(0, i - 1)...min(v.count - 1, i + 1)].sorted(); return w[w.count / 2] }
    }

    /// The tone a pitch shape looks like: 1 high level, 2 rising, 3 low or dipping, 4 falling; 0 when too little voice.
    static func tone(_ c: [Double]) -> Int {
        guard c.count >= 4 else { return 0 }
        let n = c.count, third = max(1, n / 3)
        let start = c.prefix(third).reduce(0, +) / Double(third), end = c.suffix(third).reduce(0, +) / Double(third)
        let mean = c.reduce(0, +) / Double(n)
        let minI = c.indices.min(by: { c[$0] < c[$1] })!, minV = c[minI]
        let slope = end - start
        let dip = minI > n / 5 && minI < n * 4 / 5 && start - minV > 1.2 && end - minV > 1.2
        // A fall: steep overall, or a short syllable falling fast (a clipped fourth tone). From low it's a half-third.
        let fast = slope <= -0.6 && slope / Double(max(1, n - third)) <= -0.06
        if slope <= -2.5 || fast { return mean < -1.5 && start < 1 ? 3 : 4 }
        // A dip that climbs back above where it began, without going very low, is a second tone's dip-then-rise;
        // a third tone stays low or comes back only partly.
        if dip { return end > start && minV > -2.5 ? 2 : 3 }
        if slope >= 2.0 { return 2 }
        if mean < -0.8 { return 3 }   // low throughout (below the speaker's middle)
        return 1
    }

    /// The tones a Mandarin sentence expects, one per character: from its pinyin (tone marks), with third-tone sandhi
    /// (3 3 → 2 3) and 不/一 before a fourth tone. Characters that aren't Han are skipped.
    static func expectedTones(_ hanzi: String) -> [(char: String, pinyin: String, tone: Int)] {
        let chars = hanzi.filter { $0.unicodeScalars.contains { (0x4E00...0x9FFF).contains($0.value) } }
        var out: [(String, String, Int)] = chars.map { c in
            let p = String(c).applyingTransform(.mandarinToLatin, reverse: false) ?? ""
            var t = 0
            for ch in p { if let (_, n) = ScriptComposer.toned[ch] { t = n } }
            return (String(c), p, t)
        }
        for i in out.indices.dropLast() {
            if out[i].2 == 3 && out[i + 1].2 == 3 { out[i].2 = 2 }
            if (out[i].0 == "不" || out[i].0 == "一") && out[i + 1].2 == 4 { out[i].2 = 2 }
            else if out[i].0 == "一" && (1...3).contains(out[i + 1].2) { out[i].2 = 4 }   // 一起 yìqǐ, 一天 yìtiān
        }
        return out.map { (char: $0.0, pinyin: $0.1, tone: $0.2) }
    }

    /// Per syllable: the expected tone, the tone the learner's pitch shows, and whether the method recovers the
    /// expected tone from the synthetic voice (when it doesn't, that syllable isn't judged).
    static func mandarin(target: String, learner: [Float], learnerRate: Double, reference: [Float], refRate: Double) -> JSON? {
        let exp = expectedTones(target)
        guard !exp.isEmpty, exp.count <= 30 else { return nil }
        func classify(_ s: [Float], _ rate: Double) -> [Int]? {
            let f0 = Prosody.f0(s, rate: rate), e = energy(s, rate: rate)
            guard let syl = syllables(e, f0: f0, count: exp.count) else { return nil }
            let voiced = f0.compactMap { $0 }.sorted()
            guard !voiced.isEmpty else { return nil }
            let median = voiced[voiced.count / 2]
            return syl.map { tone(contour(f0, $0, median: median)) }
        }
        guard let mine = classify(learner, learnerRate) else { return nil }
        let ref = classify(reference, refRate)
        let rows: [JSON] = exp.enumerated().map { i, x in
            let measurable = ref.map { $0[i] == x.tone } ?? false
            return ["char": .string(x.char), "pinyin": .string(x.pinyin), "expected": .number(Double(x.tone)), "heard": .number(Double(mine[i])),
                    "ok": .bool(measurable && mine[i] == x.tone), "measurable": .bool(measurable && x.tone != 0)]
        }
        let judged = rows.filter { $0["measurable"]?.bool == true }
        return ["kind": "tones", "syllables": .array(rows), "judged": .number(Double(judged.count)),
                "right": .number(Double(judged.filter { $0["ok"]?.bool == true }.count))]
    }

    // MARK: Japanese pitch accent

    /// Morae of a kana reading: small ゃゅょぁぃぅぇぉ join the mora before them; っ, ん and ー are morae.
    static func morae(_ kana: String) -> [String] {
        var out: [String] = []
        for c in kana where c.isLetter || c == "ー" {
            if "ゃゅょぁぃぅぇぉゎャュョァィゥェォヮ".contains(c), !out.isEmpty { out[out.count - 1].append(c) } else { out.append(String(c)) }
        }
        return out
    }
    /// The mora after which the pitch falls (the accent drop); 0 when it doesn't fall within the word (heiban);
    /// nil when there isn't enough voice to tell.
    static func drop(_ s: [Float], rate: Double, morae n: Int) -> Int? {
        let f0 = Prosody.f0(s, rate: rate)
        let voiced = f0.compactMap { $0 }.sorted()
        guard !voiced.isEmpty, let first = f0.firstIndex(where: { $0 != nil }), let last = f0.lastIndex(where: { $0 != nil }) else { return nil }
        let median = voiced[voiced.count / 2]
        guard last - first >= n * 4 else { return nil }
        // Morae are close to equal in time (that is what a mora is), and unlike syllables they have no voicing gap
        // between them (ん, long vowels): equal shares of the voiced span.
        let span = Double(last - first + 1) / Double(n)
        let syl = (0..<n).map { i in Syllable(start: first + Int(Double(i) * span), end: first + Int(Double(i + 1) * span) - 1) }
        // The accent is where the pitch starts its fall: the first point that is as high as anything before it
        // and drops 2.5 semitones or more within 150 ms. A fall that starts in the last mora is the ordinary
        // lowering at the end of a word, so no drop there (heiban, or odaka, which only shows on a particle after).
        var c: [Double?] = Array(repeating: nil, count: f0.count)
        // (more than 8 semitones above the middle is the tracker jumping an octave: brought back down)
        for sy in syl { for t in max(0, sy.start)...min(f0.count - 1, sy.end) { if let v = f0[t] { var x = 12 * log2(v / median); if x > 8 { x -= 12 }; c[t] = x } } }
        var peak = -Double.infinity
        for t in first...last {
            guard let v = c[t] else { continue }
            defer { peak = max(peak, v) }
            guard v >= peak - 1.0 else { continue }
            let ahead = c[t...min(last, t + 15)].compactMap { $0 }
            guard let low = ahead.min(), v - low >= 2.5 else { continue }
            guard let m = syl.firstIndex(where: { t <= $0.end }), m < n - 1 else { return 0 }
            return m + 1
        }
        return 0
    }
    static func japanese(target: String, learner: [Float], learnerRate: Double, reference: [Float], refRate: Double) -> JSON? {
        let m = morae(TextAnalysis.japaneseKana(target))
        guard m.count >= 2, m.count <= 8 else { return nil }   // a word or short phrase: one accent
        let mine = drop(learner, rate: learnerRate, morae: m.count), ref = drop(reference, rate: refRate, morae: m.count)
        return ["kind": "accent", "morae": .array(m.map { .string($0) }), "learner": mine.map { .number(Double($0)) } ?? .null,
                "reference": ref.map { .number(Double($0)) } ?? .null]
    }

    // MARK: Stress

    /// Syllables of a written word, roughly: a vowel group with the consonants before it (por-que, ha-bla-mos).
    static func writtenSyllables(_ word: String) -> [String] {
        let vowels = Set("aeiouáéíóúàèìòùâêîôûäëïöüyаеёиоуыэюяαεηιουω")
        var out: [String] = [], cur = "", inVowel = false
        for c in word.lowercased() where c.isLetter {
            let v = vowels.contains(c)
            if v { inVowel = true; cur.append(c) }
            else if inVowel { out.append(cur); cur = String(c); inVowel = false }
            else { cur.append(c) }
        }
        if !cur.isEmpty { if inVowel || out.isEmpty { out.append(cur) } else { out[out.count - 1] += cur } }
        return out
    }
    /// The most prominent syllable (pitch above the median plus loudness).
    static func stressed(_ s: [Float], rate: Double, syllables n: Int) -> Int? {
        let f0 = Prosody.f0(s, rate: rate), e = energy(s, rate: rate)
        guard let syl = syllables(e, f0: f0, count: n) else { return nil }
        let voiced = f0.compactMap { $0 }.sorted()
        guard !voiced.isEmpty else { return nil }
        let median = voiced[voiced.count / 2], maxE = max(e.max() ?? 1, 1e-6)
        let score = syl.map { s -> Double in
            let c = contour(f0, s, median: median)
            let pitch = c.max() ?? -12
            let loud = Double(e[s.start...min(e.count - 1, s.end)].max() ?? 0) / Double(maxE)
            return pitch / 6 + loud * 2 + Double(s.end - s.start) / 30
        }
        return score.indices.max(by: { score[$0] < score[$1] })
    }
    static func stress(target: String, learner: [Float], learnerRate: Double, reference: [Float], refRate: Double) -> JSON? {
        let words = target.split(whereSeparator: { !$0.isLetter })
        guard words.count == 1 else { return nil }   // single words only: in a sentence, stress and intonation mix
        let syl = writtenSyllables(String(words[0]))
        guard syl.count >= 2, syl.count <= 7 else { return nil }
        return ["kind": "stress", "syllables": .array(syl.map { .string($0) }),
                "learner": stressed(learner, rate: learnerRate, syllables: syl.count).map { .number(Double($0)) } ?? .null,
                "reference": stressed(reference, rate: refRate, syllables: syl.count).map { .number(Double($0)) } ?? .null]
    }

    /// One line for the lesson: what was measured and what it showed (from `mandarin`, `japanese` or `stress`).
    static func summary(_ p: JSON) -> String? {
        let ord = ["neutral", "1st (high level)", "2nd (rising)", "3rd (low)", "4th (falling)"]
        switch p["kind"]?.string {
        case "tones":
            let rows = p["syllables"]?.array ?? []
            let judged = rows.filter { $0["measurable"]?.bool == true }
            guard !judged.isEmpty else { return "tones: not judged (the method couldn't recover the expected tones from the synthetic voice)" }
            let misses = judged.filter { $0["ok"]?.bool != true }.map { r in
                "\(r["char"]?.string ?? "") \(r["pinyin"]?.string ?? "") expected \(ord[safe: r["expected"]?.int ?? 0] ?? "?"), pitch looked \(ord[safe: r["heard"]?.int ?? 0] ?? "unclear")"
            }
            return "tones (pitch shape per syllable, measured): \(judged.count - misses.count)/\(judged.count) judged syllables right" + (misses.isEmpty ? "" : "; " + misses.joined(separator: "; "))
                + (rows.count > judged.count ? "; \(rows.count - judged.count) not judged" : "")
        case "accent":
            let m = p["morae"]?.array?.compactMap(\.string) ?? []
            func say(_ v: Int?) -> String { guard let v else { return "unclear" }; return v == 0 ? "no fall within the word" : "falls after mora \(v) (\(m.prefix(v).joined()))" }
            return "pitch accent (where the pitch falls, measured): learner \(say(p["learner"]?.int)); synthetic voice \(say(p["reference"]?.int))"
        case "stress":
            let syl = p["syllables"]?.array?.compactMap(\.string) ?? []
            func say(_ v: Int?) -> String { v.flatMap { syl[safe: $0] } ?? "unclear" }
            return "stress (most prominent syllable by pitch, loudness, length; rough): learner “\(say(p["learner"]?.int))”, synthetic voice “\(say(p["reference"]?.int))”"
        default: return nil
        }
    }

    /// What can be measured for this language and target.
    static func analyse(target: String, lang: String, learner: [Float], learnerRate: Double, reference: [Float], refRate: Double) -> JSON? {
        switch Languages.code(lang) {
        case "zh": return mandarin(target: target, learner: learner, learnerRate: learnerRate, reference: reference, refRate: refRate)
        case "ja": return japanese(target: target, learner: learner, learnerRate: learnerRate, reference: reference, refRate: refRate)
        default: return stress(target: target, learner: learner, learnerRate: learnerRate, reference: reference, refRate: refRate)
        }
    }
}
