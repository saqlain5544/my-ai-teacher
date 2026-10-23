import Foundation

/// Shared question model for `ask_learner` (ungraded) and `quiz` (graded). The web view renders each `type`
/// with a matching component; answers come back in the shapes documented below.
enum Questions {
    static let types = ["single_choice", "multiple_choice", "true_false", "short_text", "long_text", "numeric",
                        "fill_blanks", "ordering", "matching", "scale", "code", "math", "drawing", "speak",
                        "dictation", "translate", "rewrite", "build_sentence", "table"]
    /// Written work in a language the teacher grades and answers with a ```correction (the learner's text, corrected).
    static let writingTypes: Set<String> = ["translate", "rewrite", "build_sentence"]
    static func isWriting(_ q: JSON) -> Bool {
        let t = q["type"]?.string ?? ""
        return writingTypes.contains(t) || ((t == "long_text" || t == "short_text") && q["answer"] == nil && (q["lang"] != nil || q["rubric"] != nil))
    }

    /// Compact schema: per-type fields are documented once in `type` instead of on every property.
    /// The error for a call without questions, with a call that works (models fix a shown example; they repeat a bare error).
    static let missingQuestions = """
    No questions were sent. Call ask_learner again with either a quick question — {"question":"Which topic first?","options":["Cells","Atoms"]} — \
    or a form/quiz with `questions` — {"graded":true,"title":"Atoms","questions":[{"type":"single_choice","prompt":"Charge of a proton?","options":["+1","0","-1"],"answer":0}]}
    """

    static func schema(graded: Bool) -> JSON {
        let str: JSON = ["type": "string"], num: JSON = ["type": "number"]
        let strs: JSON = ["type": "array", "items": str]
        var props: [String: JSON] = [
            "type": ["type": "string", "enum": .array(types.map { .string($0) }), "description": """
                Fields by type — choice types: options[] (+allow_other, multiple_choice: max_select); fill_blanks: text with {{}} per \
                blank (+blank_options[][]); ordering: items[] in CORRECT order; matching: pairs [[left,right],…]; numeric: unit, min, max, \
                integer; short/long_text: min_length, max_length, pattern (regex); scale: min,max,labels[]; code: language,starter; \
                speak: target (the sentence to say aloud), lang, reading (the learner speaks; recognition shows what was heard). \
                Language work (give lang): dictation: listen (the text, played and hidden; graded word by word); translate: text (the \
                source), from, to; rewrite: text + instruction (e.g. "make it formal"); build_sentence: words[] to use in one sentence \
                they write; table: rows[] (labels), columns[], answer [[per row, per column]], cells [[shown, or null to fill]]; \
                long_text/translate/rewrite/build_sentence take rubric [{criterion, points}] and min_words — you grade them. \
                Optional on all: hints[] (a ladder, gentlest first: nudge → targeted hint → one step; shown one at a time), concept, \
                placeholder; language tests: lang (ISO code: picks the on-screen keyboard), listen (text read aloud before the \
                question, hidden: dictation) + listen_lang, accents "strict" (diacritics must match in short_text/fill_blanks). \
                The app enforces these while the learner types.
                """],
            "prompt": ["type": "string", "description": "Markdown/LaTeX question text."],
            "options": strs, "text": str, "blank_options": ["type": "array", "items": strs], "items": strs,
            "pairs": ["type": "array", "items": strs], "min": num, "max": num, "labels": strs, "max_select": ["type": "integer"],
            "language": str, "starter": str, "unit": str, "placeholder": str, "hint": str, "hints": strs, "concept": str,
            "target": str, "lang": str, "reading": str, "listen": str, "listen_lang": str, "accents": str,
            "from": str, "to": str, "instruction": str, "words": strs, "rows": strs, "columns": strs,
            "cells": ["type": "array", "items": ["type": "array"]], "min_words": ["type": "integer"],
            "rubric": ["type": "array", "items": Schema.object(["criterion": str, "points": num])],
            "allow_other": ["type": "boolean"],
            "min_length": ["type": "integer"], "max_length": ["type": "integer"], "pattern": str, "integer": ["type": "boolean"],
        ]
        if graded {
            props["answer"] = ["description": .string("Graded only. single_choice: index; multiple_choice: [indices]; true_false: bool; numeric: number (+tolerance); short_text: string|[accepted]; fill_blanks: [per blank: string|[alts]]; math: expression (checked symbolically). Omit for ordering/matching/long_text/code/drawing.")]
            props["tolerance"] = num
            props["explanation"] = ["type": "string", "description": "Shown after grading."]
            props["misconceptions"] = ["type": "array", "description": .string("Graded only: the wrong answers that reveal a known misconception — [{\"answer\": option index or value, \"misconception\": \"what the learner who picks it believes\"}]. Tag every distractor of a choice question; numeric/short_text: the result of a typical mistake. The app tells you which one the learner hit and remembers it."),
                                       "items": Schema.object(["answer": ["description": "Option index (choice types) or the wrong value."], "misconception": str])]
        }
        return Schema.object(props, required: ["type", "prompt"])
    }

    /// Accepts legacy shapes (mcq/multi/short, `question` field) and returns normalised questions.
    static func normalize(_ qs: [JSON]) -> [JSON] {
        qs.map { q in
            var o = q.object ?? [:]
            if o["prompt"] == nil, let t = o["question"] { o["prompt"] = t }
            let map = ["mcq": "single_choice", "choice": "single_choice", "multi": "multiple_choice", "short": "short_text",
                       "text": "short_text", "essay": "long_text", "tf": "true_false", "boolean": "true_false", "number": "numeric",
                       "cloze": "fill_blanks", "order": "ordering", "match": "matching", "likert": "scale", "rating": "scale"]
            if let t = o["type"]?.string, let m = map[t] { o["type"] = .string(m) }
            if o["type"] == nil { o["type"] = o["options"] != nil ? "single_choice" : "short_text" }
            // Models wrap the key ({"item": "3/x"}, {"value": 2}): the one value inside is the answer.
            if let w = o["answer"]?.object, w.count == 1, let v = w.values.first { o["answer"] = v }
            if let p = o["pattern"]?.string, !Self.isFormatPattern(p, answers: o["answer"]) { o["pattern"] = nil }
            return .object(o)
        }
    }

    /// `pattern` checks an answer's shape ("[A-Z]{2}\\d{4}"). Models also put the answer itself there ("Largest"): that shows
    /// it to the page and refuses every other answer, so a learner who is wrong can't even submit. A pattern stays only if it
    /// is regex syntax, compiles, and every expected answer passes it.
    static func isFormatPattern(_ p: String, answers: JSON?) -> Bool {
        guard p.range(of: #"[\\^$.|?*+()\[\]{}]"#, options: .regularExpression) != nil,
              let re = try? NSRegularExpression(pattern: "^(?:\(p))$") else { return false }
        // Answers come as a string, a list, or wrapped ({"item": [...]}): every string in them is an accepted answer.
        func strings(_ j: JSON?) -> [String] {
            guard let j else { return [] }
            if let s = j.string { return [s] }
            if let a = j.array { return a.flatMap { strings($0) } }
            if let o = j.object { return o.values.flatMap { strings($0) } }
            return []
        }
        let expected = strings(answers)
        return expected.allSatisfy { a in
            let t = a.trimmingCharacters(in: .whitespaces)
            return re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) != nil
        }
    }

    /// Structural problems the model must fix before the learner sees the form. A graded question the app could check needs its
    /// key: without one nothing is auto-graded, so mastery, calibration and follow-ups learn nothing from the answer.
    static func validate(_ qs: [JSON], graded: Bool = false) -> [String] {
        var errs: [String] = []
        for (i, q) in qs.enumerated() {
            let n = i + 1
            let type = q["type"]?.string ?? ""
            if graded, ["single_choice", "multiple_choice", "true_false", "numeric", "math"].contains(type), q["answer"]?.isNull ?? true {
                errs.append("Q\(n): a graded \(type) question needs `answer` (the key the app checks the learner against)\(type == "math" ? "; for an open question use long_text" : "").")
            }
            switch type {
            case "single_choice", "multiple_choice":
                if (q["options"]?.array?.count ?? 0) < 2 { errs.append("Q\(n): \(q["type"]!.string!) needs at least 2 options.") }
            case "matching":
                let pairs = q["pairs"]?.array ?? []
                if pairs.count < 2 || pairs.contains(where: { ($0.array?.count ?? 0) != 2 }) {
                    errs.append("Q\(n): matching needs `pairs` as [[left, right], …] with at least 2 pairs (each pair has exactly 2 strings).")
                }
            case "ordering":
                if (q["items"]?.array?.count ?? 0) < 2 { errs.append("Q\(n): ordering needs at least 2 `items` in the correct order.") }
            case "fill_blanks":
                let text = q["text"]?.string ?? q["prompt"]?.string ?? ""
                if !text.contains("{{}}") { errs.append("Q\(n): fill_blanks needs `text` containing {{}} for each blank.") }
            case "speak":
                if (q["target"]?.string ?? q["text"]?.string ?? "").isEmpty { errs.append("Q\(n): speak needs `target`, the sentence to say.") }
            case "dictation":
                if (q["listen"]?.string ?? q["text"]?.string ?? "").isEmpty { errs.append("Q\(n): dictation needs `listen`, the text they hear and write.") }
            case "translate", "rewrite":
                if (q["text"]?.string ?? "").isEmpty { errs.append("Q\(n): \(type) needs `text`, the passage to \(type == "translate" ? "translate" : "rewrite").") }
                if type == "rewrite", (q["instruction"]?.string ?? "").isEmpty { errs.append("Q\(n): rewrite needs `instruction` (how to rewrite it, e.g. \"in the polite register\").") }
            case "build_sentence":
                if (q["words"]?.array?.count ?? 0) < 2 { errs.append("Q\(n): build_sentence needs `words`, at least 2 to use.") }
            case "table":
                let rows = q["rows"]?.array?.count ?? 0, cols = q["columns"]?.array?.count ?? 0
                if rows < 1 || cols < 1 { errs.append("Q\(n): table needs `rows` (labels) and `columns` (headers).") }
                if let a = q["answer"]?.array, a.count != rows || a.contains(where: { ($0.array?.count ?? 0) != cols }) {
                    errs.append("Q\(n): table `answer` must be one list per row with one entry per column (\(rows)×\(cols)).")
                }
            case "": errs.append("Q\(n): missing `type`.")
            default: break
            }
            if (q["prompt"]?.string ?? q["text"]?.string ?? "").isEmpty { errs.append("Q\(n): missing `prompt`.") }
            // Garbled text (a Chinese word inside Japanese, a stray script) shown to a learner would teach the error.
            if let lang = q["lang"]?.string.flatMap(Languages.code) {
                let fields = ["prompt", "text", "target", "listen", "instruction"].compactMap { q[$0]?.string } + (q["options"]?.array?.compactMap(\.string) ?? []) + (q["words"]?.array?.compactMap(\.string) ?? [])
                if let slip = fields.lazy.compactMap({ ScriptCheck.slip($0, lang: lang) }).first { errs.append("Q\(n): \(slip) — rewrite that text.") }
            }
        }
        return errs
    }

    /// The view never sees answers or explanations.
    static func publicView(_ q: JSON) -> JSON {
        var o = q.object ?? [:]
        for k in ["answer", "explanation", "tolerance", "misconceptions"] { o.removeValue(forKey: k) }
        return .object(o)
    }

    struct Grade: Sendable {
        var correct: Bool?        // nil = needs the teacher's judgement
        var score: Double?        // 0…1 partial credit
        var expected: String?
    }

    /// The misconception a wrong answer reveals, when the question tagged that answer in `misconceptions`
    /// ([{"answer": option index or value, "misconception": "…"}]).
    static func misconception(_ q: JSON, answer a: JSON) -> String? {
        guard !a.isNull, let tags = q["misconceptions"]?.array else { return nil }
        let opts = q["options"]?.array?.compactMap(\.string) ?? []
        // Options may be named by index or by their text.
        let index = { (j: JSON) -> Int? in
            if let s = j.string, let i = opts.firstIndex(where: { norm($0) == norm(s) }) { return i }
            return j.int
        }
        for t in tags {
            guard let text = t["misconception"]?.string ?? t["why"]?.string, !text.isEmpty, let tagged = t["answer"] else { continue }
            switch q["type"]?.string ?? "" {
            case "single_choice":
                if let g = index(a), g == index(tagged) { return text }
            case "multiple_choice":
                if let ti = index(tagged), (a.array ?? []).compactMap(index).contains(ti) { return text }
            case "true_false":
                if let g = a.bool, g == tagged.bool { return text }
            case "numeric":
                if let g = number(a), let e = number(tagged), abs(g - e) <= (q["tolerance"]?.double ?? max(1e-9, abs(e) * 1e-3)) { return text }
            default:
                if let g = a.string, let e = tagged.string ?? tagged.double.map({ String($0) }), norm(g) == norm(e) { return text }
            }
        }
        return nil
    }

    /// `strict` keeps diacritics (é ≠ e, ü ≠ u, harakat and tone marks count): language tests ask for them; everything
    /// else folds them, so "cafe" passes for "café". Pinyin tone marks and tone numbers are the same answer either way.
    static func norm(_ s: String, strict: Bool = false, pinyin: Bool = false) -> String {
        // Pinyin: tone marks become numbers (nǐ → ni3), and without `strict` the numbers go too (ni3, nǐ and ni all agree).
        var s = pinyin ? (strict ? pinyinNumbers(s) : pinyinNumbers(s).replacingOccurrences(of: "(?<=[A-Za-zü])[1-5]", with: "", options: .regularExpression)) : s
        // Arabic harakat and tatweel, Hebrew niqqud: optional in ordinary writing, so they count only when strict (the
        // system's diacritic folding leaves them in).
        if !strict { s.unicodeScalars.removeAll { (0x064B...0x065F).contains($0.value) || $0.value == 0x0670 || $0.value == 0x0640 || (0x0591...0x05C7).contains($0.value) } }
        // Punctuation that changes meaning survives: a leading minus (-5 ≠ 5), # and + (C# ≠ C), a decimal point (3.14).
        return s.folding(options: strict ? [.caseInsensitive, .widthInsensitive] : [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: #"(?<![\w])-(?=\d)"#, with: "\u{1}", options: .regularExpression)
            .replacingOccurrences(of: #"(?<=\d)\.(?=\d)"#, with: "\u{2}", options: .regularExpression)
            .replacingOccurrences(of: #"[^\p{L}\p{N}#+\x{01}\x{02}]+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "\u{1}", with: "-").replacingOccurrences(of: "\u{2}", with: ".")
            .trimmingCharacters(in: .whitespaces)
    }

    private static let pinyinTones: [Character: (Character, Int)] = {
        var m: [Character: (Character, Int)] = [:]
        for (v, marks) in ["a": "āáǎà", "e": "ēéěè", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ", "A": "ĀÁǍÀ", "E": "ĒÉĚÈ", "I": "ĪÍǏÌ", "O": "ŌÓǑÒ", "U": "ŪÚǓÙ", "Ü": "ǕǗǙǛ"] {
            for (i, c) in marks.enumerated() { m[c] = (Character(v), i + 1) }
        }
        return m
    }()
    /// Tone marks become tone numbers after each syllable ("nǐ hǎo" → "ni3 hao3"), so marked and numbered pinyin agree.
    static func pinyinNumbers(_ s: String) -> String {
        guard s.contains(where: { pinyinTones[$0] != nil }) else { return s }
        var out = "", tone = 0
        func flush() { if tone > 0 { out.append(String(tone)); tone = 0 } }
        for c in s {
            if let (base, t) = pinyinTones[c] { out.append(base); tone = t }
            else if c.isLetter || c == "ü" { out.append(c) }
            else { flush(); out.append(c) }
        }
        flush()
        return out
    }

    /// How much of `target` the learner's speech contained: words (characters for scripts without spaces) matched as a multiset.
    static func speechMatch(target: String, heard: String) -> Double {
        func tokens(_ s: String) -> [String] {
            let noSpaces = s.trimmingCharacters(in: .whitespaces).contains(" ") == false
            let cjk = s.unicodeScalars.contains { [.han, .kana, .hangul, .thai].contains(ScriptRuns.script(of: $0)) }
            if cjk && noSpaces { return s.filter { $0.isLetter || $0.isNumber }.map(String.init) }
            return norm(s).split(separator: " ").map(String.init)
        }
        let t = tokens(target), h = tokens(heard)
        guard !t.isEmpty else { return 0 }
        var pool: [String: Int] = [:]
        for w in h { pool[w, default: 0] += 1 }
        var hit = 0
        for w in t where (pool[w] ?? 0) > 0 { pool[w]! -= 1; hit += 1 }
        return Double(hit) / Double(t.count)
    }

    /// The number in an answer: "12 seconds", "12 m/s" → 12; "1 1/2" → 1.5; "3/4"; "3,5" → 3.5; "1,234" → 1234;
    /// "5%" → 5; "10^3" → 1000; "2.5e3". Units and words around it are ignored.
    static func number(_ a: JSON) -> Double? {
        if let d = a.double { return d }
        guard var s = a.string?.trimmingCharacters(in: .whitespaces), !s.isEmpty else { return nil }
        s = s.replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: "×", with: "*")
        if let m = s.firstMatch(of: #/^([+-]?\d+)\s+(\d+)\s*/\s*(\d+)/#), let w = Double(m.1), let n = Double(m.2), let d = Double(m.3), d != 0 {
            return w < 0 ? w - n / d : w + n / d   // mixed number
        }
        if let m = s.firstMatch(of: #/^([+-]?\d+(?:\.\d+)?)\s*/\s*([+-]?\d+(?:\.\d+)?)(?![\d.])/#), let a = Double(m.1), let b = Double(m.2), b != 0 { return a / b }
        if let m = s.firstMatch(of: #/^([+-]?\d+(?:\.\d+)?)\s*(?:\^|\*\*)\s*([+-]?\d+)/#), let b = Double(m.1), let e = Double(m.2) { return pow(b, e) }
        if s.wholeMatch(of: #/[+-]?\d{1,3}(,\d{3})+(\.\d+)?.*/#) != nil { s = s.replacingOccurrences(of: ",", with: "") }
        else if let m = s.firstMatch(of: #/^([+-]?\d+),(\d+)\b/#) { s = m.1 + "." + m.2 + s[m.range.upperBound...] }   // decimal comma
        guard let m = s.firstMatch(of: #/[+-]?(\d+\.?\d*|\.\d+)([eE][+-]?\d+)?/#) else { return nil }
        return Double(m.0)
    }

    static func grade(_ q: JSON, answer a: JSON) async -> Grade {
        let type = q["type"]?.string ?? "single_choice"
        let ans = q["answer"]
        let strict = q["accents"]?.string?.lowercased() == "strict"
        let pinyin = (q["lang"]?.string ?? "").lowercased().hasPrefix("zh")
        let lang = q["lang"]?.string ?? q["listen_lang"]?.string
        if type == "speak" {
            let target = q["target"]?.string ?? q["text"]?.string ?? ""
            guard let heard = a["heard"]?.string ?? a.string, !heard.isEmpty else { return Grade(correct: false, score: 0, expected: target) }
            let s = TextDiff.align(target: target, given: heard, lang: lang).score
            return Grade(correct: s >= 0.8, score: s, expected: target)
        }
        if type == "dictation" {
            let target = q["listen"]?.string ?? q["text"]?.string ?? ""
            guard let g = a.string, !g.trimmingCharacters(in: .whitespaces).isEmpty else { return Grade(correct: false, score: 0, expected: target) }
            let s = TextDiff.align(target: target, given: g, strict: strict, lang: lang).score
            return Grade(correct: s >= 0.999, score: s, expected: target)
        }
        if type == "table" {
            guard let key = ans?.array, !key.isEmpty else { return Grade() }
            let given = a.array ?? []
            var ok = 0, total = 0
            for (r, row) in key.enumerated() {
                for (c, cell) in (row.array ?? []).enumerated() {
                    // A cell shown to the learner (in `cells`) isn't asked.
                    if let shown = q["cells"]?[r]?[c], !shown.isNull, shown.string != "" { continue }
                    let alts = (cell.array?.compactMap(\.string) ?? cell.string.map { [$0] } ?? []).map { norm($0, strict: strict, pinyin: pinyin) }
                    guard !alts.isEmpty else { continue }
                    total += 1
                    if let g = given[safe: r]?[c]?.string, alts.contains(norm(g, strict: strict, pinyin: pinyin)) { ok += 1 }
                }
            }
            guard total > 0 else { return Grade() }
            return Grade(correct: ok == total, score: Double(ok) / Double(total), expected: key.map { ($0.array ?? []).map { $0.array?.first?.string ?? $0.string ?? "" }.joined(separator: " / ") }.joined(separator: " | "))
        }
        if a.isNull { return Grade(correct: type == "scale" ? nil : false, score: 0, expected: ans.map(describe)) }
        switch type {
        case "single_choice":
            let opts = q["options"]?.array?.compactMap(\.string) ?? []
            guard let e = ans?.int ?? opts.firstIndex(of: ans?.string ?? "") else { return Grade() }
            if let g = a.int { return Grade(correct: g == e, score: g == e ? 1 : 0, expected: e < opts.count ? opts[e] : "\(e)") }
            if let t = a.string, e < opts.count { return Grade(correct: norm(t) == norm(opts[e]) ? true : nil, expected: opts[e]) }
            return Grade()
        case "multiple_choice":
            // Answers may be indices or the options' text (models write either).
            let opts = q["options"]?.array?.compactMap(\.string) ?? []
            // A string answer is the option's text first ("2" among options "2","4","5" is option 0), then an index.
            let index = { (j: JSON) -> Int? in
                if let s = j.string, let i = opts.firstIndex(where: { norm($0) == norm(s) }) { return i }
                return j.int
            }
            let e = Set(ans?.array?.compactMap(index) ?? [])
            guard !e.isEmpty else { return Grade() }
            let g = Set(a.array?.compactMap(index) ?? [])
            let hits = Double(g.intersection(e).count), wrong = Double(g.subtracting(e).count)
            return Grade(correct: g == e, score: max(0, (hits - wrong) / Double(e.count)), expected: e.sorted().map(String.init).joined(separator: ", "))
        case "true_false":
            guard let e = ans?.bool, let g = a.bool else { return Grade() }
            return Grade(correct: e == g, score: e == g ? 1 : 0, expected: e ? "True" : "False")
        case "numeric":
            guard let e = ans?.double else { return Grade() }
            guard let g = number(a) else { return Grade(correct: false, score: 0, expected: describe(ans!)) }
            let tol = q["tolerance"]?.double ?? max(1e-9, abs(e) * 1e-3)
            return Grade(correct: abs(e - g) <= tol, score: abs(e - g) <= tol ? 1 : 0, expected: describe(ans!))
        case "short_text":
            let alts = (ans?.array?.compactMap(\.string) ?? ans?.string.map { [$0] } ?? []).map { norm($0, strict: strict, pinyin: pinyin) }
            guard !alts.isEmpty, let g = a.string else { return Grade(expected: ans.map(describe)) }
            if alts.contains(norm(g, strict: strict, pinyin: pinyin)) { return Grade(correct: true, score: 1, expected: describe(ans!)) }
            // Right but for the accents: a mistake in a language test, not a judgement call.
            if strict, alts.map({ norm($0, pinyin: pinyin) }).contains(norm(g, pinyin: pinyin)) { return Grade(correct: false, score: 0, expected: describe(ans!)) }
            return Grade(correct: nil, expected: describe(ans!))
        case "fill_blanks":
            let blanks = ans?.array ?? []
            let given = a.array ?? []
            guard !blanks.isEmpty else { return Grade() }
            var ok = 0
            for (i, b) in blanks.enumerated() {
                let alts = (b.array?.compactMap(\.string) ?? b.string.map { [$0] } ?? []).map { norm($0, strict: strict, pinyin: pinyin) }
                if i < given.count, let g = given[i].string, alts.contains(norm(g, strict: strict, pinyin: pinyin)) { ok += 1 }
            }
            return Grade(correct: ok == blanks.count, score: Double(ok) / Double(blanks.count),
                         expected: blanks.map { $0.array?.first?.string ?? $0.string ?? "" }.joined(separator: " | "))
        case "ordering":
            let items = q["items"]?.array?.compactMap(\.string) ?? []
            let g = a.array?.compactMap(\.int) ?? []
            guard !items.isEmpty, g.count == items.count else { return Grade(correct: false, score: 0, expected: items.joined(separator: " → ")) }
            let inPlace = g.enumerated().filter { $0.offset == $0.element }.count
            return Grade(correct: g == Array(0..<items.count), score: Double(inPlace) / Double(items.count), expected: items.joined(separator: " → "))
        case "matching":
            let pairs = q["pairs"]?.array ?? []
            let g = a.array?.compactMap(\.int) ?? []
            guard !pairs.isEmpty else { return Grade() }
            let ok = g.enumerated().filter { $0.offset == $0.element }.count
            return Grade(correct: ok == pairs.count && g.count == pairs.count, score: Double(ok) / Double(pairs.count),
                         expected: pairs.map { "\($0[0]?.string ?? "") ↔ \($0[1]?.string ?? "")" }.joined(separator: "; "))
        case "math":
            // One expression, or several accepted forms: right when it equals any of them.
            let keys = (ans?.array ?? ans.map { [$0] } ?? []).compactMap { $0.string ?? $0.double.map { String($0) } }
            guard let e = keys.first, let g = a.string else { return Grade(expected: ans.map(describe)) }
            var verdict: Bool? = false
            for k in keys {
                let eq = await MathEquivalence.equivalent(g, k)
                if eq == true { verdict = true; break }
                if eq == nil { verdict = nil }
            }
            return Grade(correct: verdict, score: verdict == true ? 1 : (verdict == false ? 0 : nil), expected: e)
        default:
            return Grade(expected: ans.map(describe))     // long_text, code, drawing, scale: teacher judges
        }
    }

    static func describe(_ j: JSON) -> String { j.string ?? j.compact }

    /// Human-readable rendering of a learner's answer for the model.
    static func describeAnswer(_ q: JSON, _ a: JSON) -> String {
        if a.isNull { return "(no answer)" }
        switch q["type"]?.string ?? "" {
        case "single_choice":
            let opts = q["options"]?.array?.compactMap(\.string) ?? []
            if let i = a.int { return i < opts.count ? "“\(opts[i])”" : "option \(i)" }
            return "“\(a.string ?? a.compact)” (typed)"
        case "multiple_choice":
            let opts = q["options"]?.array?.compactMap(\.string) ?? []
            let picked = (a.array ?? []).compactMap { $0.int.flatMap { $0 < opts.count ? "“\(opts[$0])”" : nil } ?? $0.string.map { "“\($0)” (typed)" } }
            return picked.isEmpty ? "(none)" : picked.joined(separator: ", ")
        case "ordering":
            let items = q["items"]?.array?.compactMap(\.string) ?? []
            return (a.array ?? []).compactMap { $0.int.flatMap { $0 < items.count ? items[$0] : nil } }.joined(separator: " → ")
        case "matching":
            let pairs = q["pairs"]?.array ?? []
            return (a.array ?? []).enumerated().map { i, r in
                "\(pairs[safe: i]?[0]?.string ?? "?") ↔ \(r.int.flatMap { pairs[safe: $0]?[1]?.string } ?? "?")"
            }.joined(separator: "; ")
        case "fill_blanks": return (a.array ?? []).map { "“\($0.string ?? "")”" }.joined(separator: ", ") + (q["text"]?.string.map { "  (in: \($0))" } ?? "")
        case "drawing": return "(drawing attached as an image)"
        case "speak":
            guard let heard = a["heard"]?.string else { return "(nothing was recognised)" }
            let target = q["target"]?.string ?? q["text"]?.string ?? ""
            let engine = a["engine"]?.string.map { ", \($0)" } ?? ""
            return "said “\(heard)” (speech recognition\(engine); target “\(target)”: \(TextDiff.align(target: target, given: heard, lang: q["lang"]?.string).summary))"
        case "dictation":
            guard let g = a.string else { return "(no answer)" }
            let target = q["listen"]?.string ?? q["text"]?.string ?? ""
            return "“\(g)” — \(TextDiff.align(target: target, given: g, strict: q["accents"]?.string == "strict", lang: q["lang"]?.string ?? q["listen_lang"]?.string).summary)"
        case "table":
            let rows = q["rows"]?.array?.compactMap(\.string) ?? [], cols = q["columns"]?.array?.compactMap(\.string) ?? []
            return (a.array ?? []).enumerated().map { r, row in
                "\(rows[safe: r] ?? "row \(r + 1)"): " + (row.array ?? []).enumerated().map { c, v in "\(cols[safe: c] ?? "") “\(v.string ?? "")”" }.joined(separator: ", ")
            }.joined(separator: "; ")
        case "build_sentence":
            guard let g = a.string else { return "(no answer)" }
            let words = q["words"]?.array?.compactMap(\.string) ?? []
            let low = norm(g)
            let missing = words.filter { !low.contains(norm($0)) }
            return "“\(g)”" + (missing.isEmpty ? " (uses every given word)" : " (doesn't contain: \(missing.joined(separator: ", ")) — maybe inflected; judge it)")
        case "translate", "rewrite":
            return a.string.map { "“\($0)”" + " (source: “\(q["text"]?.string ?? "")”)" } ?? "(no answer)"
        case "code": return "\n```\(q["language"]?.string ?? "")\n\(a.string ?? "")\n```"
        default: return a.string.map { "“\($0)”" } ?? a.compact
        }
    }

    /// The word-by-word alignment behind a dictation or speaking grade (the card shows it; Japanese is compared by reading).
    static func diff(_ q: JSON, answer a: JSON) -> TextDiff.Result? {
        switch q["type"]?.string {
        case "speak":
            guard let heard = a["heard"]?.string ?? a.string, !heard.isEmpty else { return nil }
            return TextDiff.align(target: q["target"]?.string ?? q["text"]?.string ?? "", given: heard, lang: q["lang"]?.string)
        case "dictation":
            guard let g = a.string, !g.isEmpty else { return nil }
            return TextDiff.align(target: q["listen"]?.string ?? q["text"]?.string ?? "", given: g, strict: q["accents"]?.string == "strict", lang: q["lang"]?.string ?? q["listen_lang"]?.string)
        default: return nil
        }
    }
    static func diffJSON(_ r: TextDiff.Result) -> JSON {
        ["score": .number((r.score * 1000).rounded() / 1000),
         "ops": .array(r.ops.map { ["k": .string($0.kind.rawValue), "t": $0.target.map { .string($0) } ?? .null, "g": $0.given.map { .string($0) } ?? .null] })]
    }

    /// Written work in the target language comes back with the way to answer it: a correction view per answer.
    static func writingNote(_ qs: [JSON], answers: [JSON], ungraded: Set<Int>? = nil) -> String {
        // Written in the target language and left to the teacher: the writing types, an essay, and in a language lesson any
        // text answer the app couldn't check (a short answer whose key was a description, not the words).
        let written = qs.enumerated().filter { i, q in
            let typed = !(answers[safe: i]?.string ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            let open = isWriting(q) || (q["lang"] != nil && ["short_text", "long_text"].contains(q["type"]?.string ?? "") && (ungraded?.contains(i) ?? true))
            return typed && open
        }.map { "Q\($0.offset + 1)" }
        guard !written.isEmpty else { return "" }
        return "\n\nWritten answers \(written.joined(separator: ", ")): grade each against its rubric (or meaning, grammar, vocabulary, register) and answer it with a ```correction block — {\"lang\", \"original\": their text exactly as written, \"corrected\": the minimal correction (keep what was right), \"errors\": [{\"wrong\", \"right\", \"type\": grammar|particle|conjugation|vocabulary|spelling|word order|register|meaning, \"why\": one line}], \"rubric\": [{\"criterion\", \"score\", \"max\", \"note\"}], \"better\": a more natural version if theirs is correct but stiff, \"recast\": a cue (in their language) to produce the corrected sentence again}. The app draws the differences and asks them to produce it again; record `mastery` per concept, and save recurring errors to `memory`."
    }

    /// Extracts drawings (data URLs) from answers so they can be passed to the model as images.
    static func images(from answers: [JSON]) -> [Block] {
        answers.compactMap { a in
            guard let s = a["image"]?.string ?? a.string, s.hasPrefix("data:image/"),
                  let comma = s.firstIndex(of: ","), let data = Data(base64Encoded: String(s[s.index(after: comma)...])),
                  let img = ImageUtil.loadForModel(data: data, name: "drawing") else { return nil }
            return img.block
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { i >= 0 && i < count ? self[i] : nil }
}

/// Symbolic equivalence via SymPy, with a light LaTeX → SymPy translation.
enum MathEquivalence {
    static func toSympy(_ s: String) -> String {
        var t = s
        for (a, b) in [("\\left", ""), ("\\right", ""), ("\\cdot", "*"), ("\\times", "*"), ("\\div", "/"), ("\\pi", "pi"),
                       ("\\infty", "oo"), ("\\ln", "log"), ("\\,", ""), ("\\!", ""), ("$", ""), ("−", "-")] { t = t.replacingOccurrences(of: a, with: b) }
        // \frac{a}{b} → ((a)/(b)), \sqrt{x} → sqrt(x) (repeat for nesting)
        for _ in 0..<6 {
            t = t.replacingOccurrences(of: "\\\\[dt]?frac\\{([^{}]*)\\}\\{([^{}]*)\\}", with: "(($1)/($2))", options: .regularExpression)
            t = t.replacingOccurrences(of: "\\\\sqrt\\{([^{}]*)\\}", with: "sqrt($1)", options: .regularExpression)
        }
        t = t.replacingOccurrences(of: "\\\\(sin|cos|tan|exp|log|arcsin|arccos|arctan|sinh|cosh|tanh)", with: "$1", options: .regularExpression)
        t = t.replacingOccurrences(of: "{", with: "(").replacingOccurrences(of: "}", with: ")")
        return t
    }

    static func equivalent(_ a: String, _ b: String) async -> Bool? {
        let x = toSympy(a), y = toSympy(b)
        guard MathTool.safe(x), MathTool.safe(y), let py = ProcessRunner.which("python3") else { return nil }
        let script = """
        import sys, json
        try:
            from sympy import simplify, nsimplify, Symbol
            from sympy.parsing.sympy_parser import parse_expr, standard_transformations, implicit_multiplication_application, convert_xor
        except ImportError:
            print("null"); sys.exit(0)
        T = standard_transformations + (implicit_multiplication_application, convert_xor)
        a, b = json.loads(sys.stdin.read())
        try:
            E = lambda s: parse_expr(s, transformations=T)
            is_eq = lambda s: "=" in s and "==" not in s
            def sides(s):
                l, r = s.split("=", 1); return E(l), E(r)
            if is_eq(a) and is_eq(b):
                # Same equation up to swapping sides or scaling by a constant: 2=x ~ x=2, 2x-y=0 ~ y=2x.
                la, ra = sides(a); lb, rb = sides(b)
                da, db = simplify(la - ra), simplify(lb - rb)
                if db == 0 or da == 0:
                    ok = simplify(da - db) == 0
                else:
                    q = simplify(da / db)
                    ok = q.is_number and q != 0 and q.is_finite
                print("true" if ok else "false")
            elif is_eq(a) or is_eq(b):
                # "x = 2" against a bare "2": compare with the side opposite the variable.
                eq, other = (a, b) if is_eq(a) else (b, a)
                l, r = sides(eq); o = E(other)
                val = r if l.is_Symbol else (l if r.is_Symbol else None)
                print("null" if val is None else ("true" if simplify(val - o) == 0 else "false"))
            else:
                print("true" if simplify(E(a) - E(b)) == 0 else "false")
        except Exception:
            print("null")
        """
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("aiteacher-math", isDirectory: true)
        try? FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let r = await ProcessRunner.run(py, ["-c", script], cwd: scratch, stdin: JSON.array([.string(x), .string(y)]).compact, timeout: 15)
        switch r.stdout.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "true": return true
        case "false": return false
        default: return nil
        }
    }
}

// MARK: - Tools

struct AskLearnerTool: Tool {
    let name = "ask_learner"
    let description = """
    Show interactive questions in the chat and WAIT for the learner. Quick choice: `question` + `options`. \
    Form: `questions` (any type). Set `graded: true` for a quiz: include `answer`s; the app auto-grades \
    (choice, true/false, numeric, short text, blanks, ordering, matching, symbolic math), updates mastery, and returns \
    long text/code/drawings for you to grade. Use for diagnostics, choices, practice and reflection. A test reads like a \
    real exam: a `case` (a realistic scenario, code, data or a passage) that the questions refer to, needing reading and \
    reasoning rather than recall; a few questions, each worth answering. Refused while the learner has quizzes off.
    """
    let risk = ToolRisk.interactive
    var schema: JSON {
        Schema.object([
            "question": Schema.string("Quick form: the question (shown as clickable options)."),
            "options": Schema.array(Schema.string("Option"), "Quick form: 2-6 short options."),
            "multi_select": Schema.boolean("Quick form: allow several options."),
            "allow_free_text": Schema.boolean("Quick form: allow a typed answer (default true)."),
            "title": Schema.string("Form title."),
            "graded": Schema.boolean("Quiz mode: auto-grade with `answer`s."),
            "subject": Schema.string("Subject (graded)."),
            "case": Schema.string("Markdown shown above the questions: the scenario, code, data or passage they all refer to (exam style)."),
            "questions": ["type": "array", "items": Questions.schema(graded: true)],
        ])
    }
    func summary(_ input: JSON) -> String { input["question"]?.string ?? input["title"]?.string ?? input["questions"]?[0]?["prompt"]?.string ?? "" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let hasForm = !(input["questions"]?.array ?? []).isEmpty, hasQuick = !(input["question"]?.string ?? "").isEmpty
        if input["graded"]?.bool == true, hasForm { return try await QuizTool().run(input, ctx) }
        if input["graded"]?.bool == true, !ctx.quizzes { return .error(Testing.refusal) }
        // Some models send `graded` with no questions, or nothing at all: say exactly what to send (they repeat a bare error).
        guard hasForm || hasQuick else { return .error(Questions.missingQuestions) }
        var payload = input.object ?? [:]
        if let qs = input["questions"]?.array {
            let errs = Questions.validate(Questions.normalize(qs))
            if !errs.isEmpty { return .error("Fix the form and call ask_learner again:\n" + errs.joined(separator: "\n")) }
            payload["questions"] = .array(Questions.normalize(qs).map(Questions.publicView))
        }
        let reply = await ctx.interactions.request(id: ctx.toolCallID, kind: "ask", conversationID: ctx.conversationID, payload: .object(payload))
        if reply["cancelled"]?.bool == true { return .error(Testing.skipped("question", reason: reply["reason"]?.string)) }
        if let qs = input["questions"]?.array {
            let norm = Questions.normalize(qs)
            let answers = reply["answers"]?.array ?? []
            var lines: [String] = []
            for (i, q) in norm.enumerated() {
                lines.append("Q\(i + 1) [\(q["type"]?.string ?? "")]: \(q["prompt"]?.string ?? "")\n   Answer: \(Questions.describeAnswer(q, answers[safe: i] ?? .null))")
            }
            return ToolOutput(text: "Learner's answers:\n" + lines.joined(separator: "\n") + Questions.writingNote(norm, answers: answers), images: Questions.images(from: answers),
                              meta: ["answers": .array(answers)])
        }
        let sel = reply["selected"]?.array?.compactMap(\.string) ?? []
        let text = reply["text"]?.string ?? ""
        var out = "Learner's answer: " + sel.joined(separator: ", ")
        if !text.isEmpty { out += (sel.isEmpty ? "" : " — ") + "\"\(text)\"" }
        return ToolOutput(text: out, meta: ["selected": .array(sel.map { .string($0) }), "text": .string(text)])
    }
}

struct QuizTool: Tool {
    let name = "quiz"
    let description = """
    Show a graded interactive quiz in the chat and WAIT for the answers. Auto-grades single/multiple choice, true/false, \
    numeric, short text (accepted answers), fill-in-the-blanks, ordering, matching and math (symbolic equivalence via SymPy); \
    returns long text, code and drawings for you to grade. Results update concept mastery. Like a real exam: a `case` \
    (a realistic scenario, code, data or a passage) the questions refer to, needing reading and reasoning rather than \
    recall; 2-6 questions on what was just taught, each worth answering. Refused while the learner has quizzes off.
    """
    let risk = ToolRisk.interactive
    var schema: JSON {
        Schema.object([
            "title": Schema.string("Quiz title."),
            "subject": Schema.string("Subject, e.g. algebra."),
            "case": Schema.string("Markdown shown above the questions: the scenario, code, data or passage they all refer to."),
            "questions": Schema.array(Questions.schema(graded: true), "Questions."),
        ], required: ["title", "questions"])
    }
    func summary(_ input: JSON) -> String { input["title"]?.string ?? "Quiz" }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        guard ctx.quizzes else { return .error(Testing.refusal) }
        let questions = Questions.normalize(input["questions"]?.array ?? [])
        guard !questions.isEmpty else { return .error(Questions.missingQuestions) }
        let errs = Questions.validate(questions, graded: true)
        if !errs.isEmpty { return .error("Fix the quiz and call it again:\n" + errs.joined(separator: "\n")) }
        let payload: JSON = ["title": input["title"] ?? "Quiz", "subject": input["subject"] ?? .null, "case": input["case"] ?? .null,
                             "questions": .array(questions.map(Questions.publicView)), "graded": true]
        let reply = await ctx.interactions.request(id: ctx.toolCallID, kind: "quiz", conversationID: ctx.conversationID, payload: payload)
        if reply["cancelled"]?.bool == true { return .error(Testing.skipped("quiz", reason: reply["reason"]?.string)) }
        let answers = reply["answers"]?.array ?? []
        // Per question: hints the learner opened (the app also opens one when they're stuck) and how sure they were.
        let hintsOpened = reply["hints"]?.array ?? [], certainties = reply["certainty"]?.array ?? []
        let subject = input["subject"]?.string ?? "general"
        let study = ctx.services.study
        var graded: [JSON] = []
        var score = 0.0
        var autoTotal = 0
        var lines: [String] = []
        var wrong = 0, hinted = 0
        var sureButWrong: [String] = [], luckyGuesses: [String] = [], missedAgain: [String] = [], unknown: [String] = []
        let missedBefore = study.missedInLesson(ctx.conversationID)
        for (i, q) in questions.enumerated() {
            let a = answers[safe: i] ?? .null
            // "Don't know yet" (certainty 0): a gap to teach, not a mistake. Nothing is graded or recorded.
            if certainties[safe: i]?.int == 0 {
                unknown.append("Q\(i + 1)" + (q["concept"]?.string.map { " (\($0))" } ?? ""))
                lines.append("Q\(i + 1) [\(q["type"]?.string ?? "")\(q["concept"]?.string.map { ", concept: \($0)" } ?? "")]: \(q["prompt"]?.string ?? "")\n   → 🤷 the learner doesn't know this yet")
                graded.append(["correct": .null, "unknown": true, "explanation": q["explanation"] ?? .null, "answer": q["answer"] ?? .null, "given": a])
                continue
            }
            var g = await Questions.grade(q, answer: a)
            let mis = g.correct == true ? nil : Questions.misconception(q, answer: a)
            if mis != nil, g.correct == nil { g.correct = false; g.score = 0 }   // a tagged wrong answer needs no judgement
            let hints = hintsOpened[safe: i]?.int ?? 0
            let help: Help = hints > 0 ? .hint : .none
            let certainty = certainties[safe: i]?.int.flatMap(Certainty.init(rawValue:))
            let concept = q["concept"]?.string
            if g.correct != nil { autoTotal += 1; score += g.score ?? (g.correct == true ? 1 : 0) }
            if let c = g.correct {
                study.recordResponse(subject: subject, concept: concept, correct: c, certainty: certainty, help: help, source: "quiz", conversationID: ctx.conversationID)
                if let concept { study.recordAttempt(subject: subject, concept: concept, correct: c, note: nil, help: help, certainty: certainty) }
                if !c, let concept, missedBefore.contains(MemoryText.conceptKey(concept)) { missedAgain.append("Q\(i + 1) (\(concept))") }
                else if !c { wrong += 1 }
                if !c, certainty == .sure { sureButWrong.append("Q\(i + 1)") }
                if c, certainty == .guess, help == .none { luckyGuesses.append("Q\(i + 1)") }
            }
            if hints > 0 { hinted += 1 }
            // A wrong answer comes back in a later lesson; a confident one sooner, with its flashcards brought forward.
            if g.correct == false, let concept {
                let sure = certainty == .sure
                if sure { study.reviewSoon(concept: concept) }
                study.scheduleFollowUp(subject: subject, concept: concept, kind: .recheck,
                                       note: mis.map { "misconception: \($0)" } ?? "answered wrong\(sure ? " while sure" : ""): \(MemoryText.clip(q["prompt"]?.string ?? "", 120))",
                                       after: sure ? 1 : 2, conversationID: ctx.conversationID)
            }
            if let mis {
                ctx.services.memory.add(kind: .misconception, content: mis, subject: subject, importance: 0.6, origin: "quiz",
                                        source: ctx.conversationID, concept: concept)
            }
            let verdict = g.correct.map { $0 ? "✅ correct" : "❌ incorrect" } ?? "📝 needs your grading"
            var notes: [String] = []
            if let mis { notes.append("misconception: \(mis)") }
            if let certainty { notes.append(certainty.title.lowercased()) }
            if hints > 0 { notes.append("after \(hints) hint\(hints == 1 ? "" : "s")") }
            lines.append("Q\(i + 1) [\(q["type"]?.string ?? "")\(concept.map { ", concept: \($0)" } ?? "")]: \(q["prompt"]?.string ?? "")\n   Learner: \(Questions.describeAnswer(q, a))\n   Expected: \(g.expected ?? "—")\n   → \(verdict)\(g.score.map { $0 > 0 && $0 < 1 ? String(format: " (partial %.0f%%)", $0 * 100) : "" } ?? "")\(notes.isEmpty ? "" : " · " + notes.joined(separator: " · "))")
            graded.append(["correct": g.correct.map { .bool($0) } ?? .null, "score": g.score.map { .number($0) } ?? .null,
                           "explanation": q["explanation"] ?? .null, "expected": g.expected.map { .string($0) } ?? .null,
                           "answer": q["answer"] ?? .null, "given": a, "misconception": mis.map { .string($0) } ?? .null,
                           "certainty": certainty.map { .number(Double($0.rawValue)) } ?? .null, "hints": .number(Double(hints)),
                           "diff": Questions.diff(q, answer: a).map(Questions.diffJSON) ?? .null])
        }
        study.recordQuiz(conversationID: ctx.conversationID, title: input["title"]?.string ?? "Quiz", topic: subject, score: score, total: autoTotal,
                         data: ["questions": .array(questions), "answers": .array(answers), "hints": .array(hintsOpened), "certainty": .array(certainties)])
        EventBus.publish(.studyDataChanged)
        var text = "Quiz \"\(input["title"]?.string ?? "")\" submitted. " + (autoTotal == 0
            ? "Nothing could be auto-graded (no answer key), so grade every answer below.\n"
            : "Auto-graded score: \(String(format: "%g", (score * 10).rounded() / 10))/\(autoTotal).\n")
        if let c = reply["confidence"]?.int { text += "Self-rated confidence before answering: \(c)/5.\n" }
        if let s = reply["seconds"]?.double { text += "Time taken: \(Int(s)) s.\n" }
        text += "\n" + lines.joined(separator: "\n")
        text += "\n\n" + Self.feedbackSteps(wrong: wrong, missedAgain: missedAgain, sureButWrong: sureButWrong, luckyGuesses: luckyGuesses, hinted: hinted,
                                            ungraded: questions.count - autoTotal - unknown.count, unknown: unknown)
        text += Questions.writingNote(questions, answers: answers, ungraded: Set(graded.enumerated().filter { $0.element["correct"]?.isNull ?? true }.map(\.offset)))
        return ToolOutput(text: text, images: Questions.images(from: answers),
                          meta: ["graded": .array(graded), "score": .number((score * 10).rounded() / 10), "total": .number(Double(autoTotal))])
    }

    /// What to do with the result: a first mistake is corrected now with a retry; a concept missed again in the same lesson
    /// gets a worked example instead of yet another quiz (more questions alone don't help a learner who lacks the method).
    static func feedbackSteps(wrong: Int, missedAgain: [String] = [], sureButWrong: [String], luckyGuesses: [String], hinted: Int, ungraded: Int = 0,
                              unknown: [String] = []) -> String {
        var s: [String] = []
        if !unknown.isEmpty {
            s.append("\(unknown.joined(separator: ", ")): the learner doesn't know this yet — a gap to teach, not a mistake. Teach it properly (the mechanism, a worked example, a visual) before testing it again, later and in a new context.")
        }
        if ungraded > 0 {
            s.append("Grade the 📝 answers yourself and record each with `mastery` (concept, correct). A wrong one is a mistake like any other: name the misconception and teach the gap behind it; if the learner's answers make no sense, ask what they meant.")
        }
        if wrong > 0 {
            s.append("For each ❌: say what the learner most likely believed (the misconception named above, if any), why it's tempting, and the fix. A slip needs only that. A mistake that shows a gap in understanding needs teaching first (a new angle, a worked example), not another question. Then move on: check the point again later in the lesson, in a new context — never quiz the same point twice in a row.")
        }
        if !missedAgain.isEmpty {
            s.append("\(missedAgain.joined(separator: ", ")): missed again in this lesson. Don't quiz it again in this turn: teach it with one worked example, step by step, then ask the learner to explain the key step back in their own words, and end your turn. Try a fresh question later.")
        }
        if !sureButWrong.isEmpty {
            s.append("\(sureButWrong.joined(separator: ", ")): wrong although the learner was sure. Corrections stick best right now: contrast their reasoning with the right one explicitly.")
        }
        if !luckyGuesses.isEmpty {
            s.append("\(luckyGuesses.joined(separator: ", ")): right but guessed. Treat as not known yet and check it again later in this lesson.")
        }
        if hinted > 0 { s.append("Answers given after a hint don't raise mastery: say briefly what the hint unlocked.") }
        if ungraded == 0 {
            s.append(wrong == 0 && missedAgain.isEmpty ? "Praise specifically and briefly, then move on (harder questions or the next step)." : "Praise what's right briefly.")
        }
        return s.joined(separator: "\n")
    }
}
