import Foundation

/// The on-screen keyboard layouts, read from `Resources/web/keyboard-layouts.js` (one file for the transcript page and the
/// composer). The file is `window.TeacherKeyboardLayouts = {…};` with a JSON object after the `=`.
enum KeyboardLayouts {
    enum Key: Equatable, Sendable {
        case text(String)
        case fn(String)   // shift, bksp, space, enter, dakuten, handakuten, small, kana, tone, mode
    }
    struct Layout: Sendable {
        var code: String
        var name: String
        var english: String
        var rows: [[Key]]
        var shift: [[Key]]?
        var upper = false
        var rtl = false
        var compose: String?   // hangul | kana | pinyin | marks
        var modes: [String] = []
        /// Letters only: the learner types as usual (no panel worth showing).
        var isEmpty: Bool { rows.isEmpty }
    }

    nonisolated(unsafe) static var shared: [String: Layout] = load()

    static func load(from url: URL = AppPaths.webResources.appendingPathComponent("keyboard-layouts.js")) -> [String: Layout] {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }

    static func parse(_ text: String) -> [String: Layout] {
        guard let eq = text.range(of: "window.TeacherKeyboardLayouts ="), let open = text[eq.upperBound...].firstIndex(of: "{"),
              let close = text.lastIndex(of: "}"), open < close, let j = JSON.parse(String(text[open...close])), let o = j.object else { return [:] }
        var out: [String: Layout] = [:]
        for (code, v) in o {
            let keys = { (rows: JSON?) -> [[Key]] in
                (rows?.array ?? []).map { row in (row.array ?? []).compactMap { k -> Key? in
                    if let s = k.string { return .text(s) }
                    if let f = k["k"]?.string { return .fn(f) }
                    return nil
                } }
            }
            out[code] = Layout(code: code, name: v["name"]?.string ?? code, english: v["english"]?.string ?? code, rows: keys(v["rows"]),
                               shift: v["shift"].map(keys), upper: v["upper"]?.bool ?? false, rtl: v["rtl"]?.bool ?? false,
                               compose: v["compose"]?.string, modes: v["modes"]?.array?.compactMap(\.string) ?? [])
        }
        return out
    }

    /// The layout for a language code ("ja-JP" → ja), or nil when the language needs no panel.
    static func layout(for code: String?) -> Layout? {
        guard let c = code?.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map({ String($0).lowercased() }), let l = shared[c], !l.isEmpty else { return nil }
        return l
    }
}

/// Composition for the composer's keyboard (the page has the same rules in components/keyboard.js): Hangul jamo join
/// into syllables, kana take voicing marks and small forms, romaji become kana, a tone key cycles pinyin tone marks.
enum ScriptComposer {
    // MARK: Hangul
    static let cho = Array("ㄱㄲㄴㄷㄸㄹㅁㅂㅃㅅㅆㅇㅈㅉㅊㅋㅌㅍㅎ")
    static let jung = Array("ㅏㅐㅑㅒㅓㅔㅕㅖㅗㅘㅙㅚㅛㅜㅝㅞㅟㅠㅡㅢㅣ")
    static let jong: [Character] = ["\0"] + Array("ㄱㄲㄳㄴㄵㄶㄷㄹㄺㄻㄼㄽㄾㄿㅀㅁㅂㅄㅅㅆㅇㅈㅊㅋㅌㅍㅎ")
    static let vowelPairs: [String: Character] = ["ㅗㅏ": "ㅘ", "ㅗㅐ": "ㅙ", "ㅗㅣ": "ㅚ", "ㅜㅓ": "ㅝ", "ㅜㅔ": "ㅞ", "ㅜㅣ": "ㅟ", "ㅡㅣ": "ㅢ"]
    static let finalPairs: [String: Character] = ["ㄱㅅ": "ㄳ", "ㄴㅈ": "ㄵ", "ㄴㅎ": "ㄶ", "ㄹㄱ": "ㄺ", "ㄹㅁ": "ㄻ", "ㄹㅂ": "ㄼ", "ㄹㅅ": "ㄽ", "ㄹㅌ": "ㄾ", "ㄹㅍ": "ㄿ", "ㄹㅎ": "ㅀ", "ㅂㅅ": "ㅄ"]
    static let split: [Character: (Character, Character)] = {
        var m: [Character: (Character, Character)] = [:]
        for (k, v) in vowelPairs.merging(finalPairs, uniquingKeysWith: { a, _ in a }) { let c = Array(k); m[v] = (c[0], c[1]) }
        return m
    }()
    static func isJamo(_ c: Character) -> Bool { cho.contains(c) || jung.contains(c) || jong.contains(c) }
    static func syllable(_ c: Int, _ j: Int, _ f: Int) -> Character { Character(UnicodeScalar(0xAC00 + (c * 21 + j) * 28 + f)!) }
    static func decompose(_ ch: Character) -> (cho: Int, jung: Int, jong: Int)? {
        guard let v = ch.unicodeScalars.first?.value, (0xAC00...0xD7A3).contains(v) else { return nil }
        let c = Int(v) - 0xAC00
        return (c / 588, (c % 588) / 28, c % 28)
    }
    /// What the character before the caret becomes when jamo `j` is typed: (characters to remove, replacement).
    static func hangul(prev: Character?, _ j: Character) -> (remove: Int, text: String) {
        let s = prev.flatMap(decompose)
        if jung.contains(j) {
            if let s, s.jong == 0 {
                if let pair = vowelPairs[String(jung[s.jung]) + String(j)], let pi = jung.firstIndex(of: pair) { return (1, String(syllable(s.cho, pi, 0))) }
                return (0, String(j))
            }
            if let s, s.jong > 0 {
                let f = jong[s.jong]
                if let (a, b) = split[f], let ai = jong.firstIndex(of: a), let bi = cho.firstIndex(of: b), let ji = jung.firstIndex(of: j) {
                    return (1, String(syllable(s.cho, s.jung, ai)) + String(syllable(bi, ji, 0)))
                }
                if let ci = cho.firstIndex(of: f), let ji = jung.firstIndex(of: j) { return (1, String(syllable(s.cho, s.jung, 0)) + String(syllable(ci, ji, 0))) }
                return (0, String(j))
            }
            if let p = prev, let ci = cho.firstIndex(of: p), let ji = jung.firstIndex(of: j) { return (1, String(syllable(ci, ji, 0))) }
            if let p = prev, jung.contains(p), let pair = vowelPairs[String(p) + String(j)] { return (1, String(pair)) }
            return (0, String(j))
        }
        if let s, s.jong == 0, let fi = jong.firstIndex(of: j) { return (1, String(syllable(s.cho, s.jung, fi))) }
        if let s, s.jong > 0, let pair = finalPairs[String(jong[s.jong]) + String(j)], let fi = jong.firstIndex(of: pair) { return (1, String(syllable(s.cho, s.jung, fi))) }
        return (0, String(j))
    }
    /// Backspace that removes one jamo.
    static func hangulBackspace(prev: Character) -> (remove: Int, text: String) {
        guard let s = decompose(prev) else { return split[prev].map { (1, String($0.0)) } ?? (1, "") }
        if s.jong > 0 { let parts = split[jong[s.jong]]; return (1, String(syllable(s.cho, s.jung, parts.flatMap { jong.firstIndex(of: $0.0) } ?? 0))) }
        if let (a, _) = split[jung[s.jung]], let ai = jung.firstIndex(of: a) { return (1, String(syllable(s.cho, ai, 0))) }
        return (1, String(cho[s.cho]))
    }

    // MARK: Kana
    static let small: [Character: Character] = ["あ": "ぁ", "い": "ぃ", "う": "ぅ", "え": "ぇ", "お": "ぉ", "つ": "っ", "や": "ゃ", "ゆ": "ゅ", "よ": "ょ", "わ": "ゎ", "か": "ゕ", "け": "ゖ",
                                                "ア": "ァ", "イ": "ィ", "ウ": "ゥ", "エ": "ェ", "オ": "ォ", "ツ": "ッ", "ヤ": "ャ", "ユ": "ュ", "ヨ": "ョ", "ワ": "ヮ", "カ": "ヵ", "ケ": "ヶ"]
    static let big: [Character: Character] = Dictionary(uniqueKeysWithValues: small.map { ($1, $0) })
    static func toKatakana(_ s: String) -> String { s.applyingTransform(.hiraganaToKatakana, reverse: false) ?? s }
    static func toHiragana(_ s: String) -> String { s.applyingTransform(.hiraganaToKatakana, reverse: true) ?? s }
    /// Toggles ゛ (U+3099) or ゜ (U+309A) on the kana before the caret.
    static func voicing(prev: Character?, mark: Unicode.Scalar) -> (remove: Int, text: String)? {
        guard let p = prev else { return nil }
        let d = String(p).decomposedStringWithCanonicalMapping
        let base = String(d.unicodeScalars.filter { $0.value != 0x3099 && $0.value != 0x309A })
        if d.unicodeScalars.contains(mark) { return (1, base) }
        let v = (base + String(mark)).precomposedStringWithCanonicalMapping
        return v.unicodeScalars.count == 1 ? (1, v) : nil   // あ゙ has no precomposed form: not a kana that takes it
    }
    static func toggleSmall(prev: Character?) -> (remove: Int, text: String)? {
        guard let p = prev, let t = small[p] ?? big[p] else { return nil }
        return (1, String(t))
    }
    /// Romaji → kana, syllable by syllable (the same table and rules as the page's keyboard.js): "konnichiha" → こんにちは,
    /// "kitte" → きって, "kyou" → きょう. What cannot be decided yet (a lone "k", an "n" that may start "na") stays Latin.
    static let romajiTable: [String: String] = [
        "a": "あ", "i": "い", "u": "う", "e": "え", "o": "お", "ka": "か", "ki": "き", "ku": "く", "ke": "け", "ko": "こ", "sa": "さ", "shi": "し", "si": "し", "su": "す", "se": "せ", "so": "そ",
        "ta": "た", "chi": "ち", "ti": "ち", "tsu": "つ", "tu": "つ", "te": "て", "to": "と", "na": "な", "ni": "に", "nu": "ぬ", "ne": "ね", "no": "の", "ha": "は", "hi": "ひ", "fu": "ふ", "hu": "ふ", "he": "へ", "ho": "ほ",
        "ma": "ま", "mi": "み", "mu": "む", "me": "め", "mo": "も", "ya": "や", "yu": "ゆ", "yo": "よ", "ra": "ら", "ri": "り", "ru": "る", "re": "れ", "ro": "ろ", "wa": "わ", "wo": "を",
        "ga": "が", "gi": "ぎ", "gu": "ぐ", "ge": "げ", "go": "ご", "za": "ざ", "ji": "じ", "zi": "じ", "zu": "ず", "ze": "ぜ", "zo": "ぞ", "da": "だ", "di": "ぢ", "du": "づ", "de": "で", "do": "ど",
        "ba": "ば", "bi": "び", "bu": "ぶ", "be": "べ", "bo": "ぼ", "pa": "ぱ", "pi": "ぴ", "pu": "ぷ", "pe": "ぺ", "po": "ぽ",
        "kya": "きゃ", "kyu": "きゅ", "kyo": "きょ", "sha": "しゃ", "shu": "しゅ", "sho": "しょ", "sya": "しゃ", "syu": "しゅ", "syo": "しょ", "cha": "ちゃ", "chu": "ちゅ", "cho": "ちょ", "tya": "ちゃ", "tyu": "ちゅ", "tyo": "ちょ",
        "nya": "にゃ", "nyu": "にゅ", "nyo": "にょ", "hya": "ひゃ", "hyu": "ひゅ", "hyo": "ひょ", "mya": "みゃ", "myu": "みゅ", "myo": "みょ", "rya": "りゃ", "ryu": "りゅ", "ryo": "りょ",
        "gya": "ぎゃ", "gyu": "ぎゅ", "gyo": "ぎょ", "ja": "じゃ", "ju": "じゅ", "jo": "じょ", "jya": "じゃ", "jyu": "じゅ", "jyo": "じょ", "zya": "じゃ", "zyu": "じゅ", "zyo": "じょ", "bya": "びゃ", "byu": "びゅ", "byo": "びょ", "pya": "ぴゃ", "pyu": "ぴゅ", "pyo": "ぴょ",
        "dya": "ぢゃ", "dyu": "ぢゅ", "dyo": "ぢょ", "fa": "ふぁ", "fi": "ふぃ", "fe": "ふぇ", "fo": "ふぉ", "va": "ゔぁ", "vi": "ゔぃ", "vu": "ゔ", "ve": "ゔぇ", "vo": "ゔぉ",
        "she": "しぇ", "che": "ちぇ", "je": "じぇ", "tsa": "つぁ", "tsi": "つぃ", "tse": "つぇ", "tso": "つぉ", "thi": "てぃ", "dhi": "でぃ", "twu": "とぅ", "dwu": "どぅ", "wi": "うぃ", "we": "うぇ",
        "xa": "ぁ", "xi": "ぃ", "xu": "ぅ", "xe": "ぇ", "xo": "ぉ", "la": "ぁ", "li": "ぃ", "lu": "ぅ", "le": "ぇ", "lo": "ぉ", "xtu": "っ", "ltu": "っ", "xtsu": "っ", "ltsu": "っ",
        "xya": "ゃ", "xyu": "ゅ", "xyo": "ょ", "lya": "ゃ", "lyu": "ゅ", "lyo": "ょ", "xwa": "ゎ", "-": "ー", ",": "、", ".": "。", "?": "？", "!": "！",
    ]
    static let romajiPrefixes: Set<String> = {
        var p = Set<String>()
        for k in romajiTable.keys { var s = ""; for c in k.dropLast() { s.append(c); p.insert(s) } }
        return p
    }()
    static func romaji(_ run: String, katakana: Bool) -> String {
        let s = Array(run.lowercased()), raw = Array(run)
        let vowel: (Character) -> Bool = { "aiueo".contains($0) }
        let consonant: (Character) -> Bool = { "bcdfghjklmpqrstvwxz".contains($0) }
        var out = "", i = 0
        while i < s.count {
            let c = s[i]
            let next: Character? = i + 1 < s.count ? s[i + 1] : nil, after: Character? = i + 2 < s.count ? s[i + 2] : nil
            if c == "n", next == "n" {
                // "nn" before a vowel or y: ん and the n that starts the next syllable (konnichiha); otherwise just ん.
                if let a = after, vowel(a) || a == "y" { out += "ん"; i += 1 } else { out += "ん"; i += 2 }
                continue
            }
            if c == "n", next == "'" { out += "ん"; i += 2; continue }
            if c == "n", let n = next, !vowel(n), n != "y", n != "'" { out += "ん"; i += 1; continue }
            if consonant(c), next == c, let a = after, vowel(a) || a == "y" || a == "h" { out += "っ"; i += 1; continue }
            var hit: String?
            for n in [4, 3, 2, 1] where i + n <= s.count {
                let k = String(s[i..<(i + n)])
                if romajiTable[k] != nil { hit = k; break }
            }
            if let h = hit { out += romajiTable[h]!; i += h.count; continue }
            if romajiPrefixes.contains(String(s[i...])) { break }   // an unfinished syllable at the end
            out.append(raw[i]); i += 1
        }
        let kana = katakana ? toKatakana(out) : out
        return kana + String(raw[i...])
    }

    // MARK: Pinyin
    static let tones: [Character: String] = ["a": "āáǎà", "e": "ēéěè", "i": "īíǐì", "o": "ōóǒò", "u": "ūúǔù", "ü": "ǖǘǚǜ", "A": "ĀÁǍÀ", "E": "ĒÉĚÈ", "I": "ĪÍǏÌ", "O": "ŌÓǑÒ", "U": "ŪÚǓÙ", "Ü": "ǕǗǙǛ"]
    static let toned: [Character: (Character, Int)] = {
        var m: [Character: (Character, Int)] = [:]
        for (v, marks) in tones { for (i, c) in marks.enumerated() { m[c] = (v, i + 1) } }
        return m
    }()
    /// The syllable before the caret with its tone advanced (none → 1 → 2 → 3 → 4 → none).
    static func cycleTone(_ text: String) -> (remove: Int, text: String)? {
        let letters = Set("abcdefghijklmnopqrstuvwxyzüABCDEFGHIJKLMNOPQRSTUVWXYZÜ").union(toned.keys)
        let run = String(text.reversed().prefix { letters.contains($0) }.reversed())
        guard !run.isEmpty else { return nil }
        var tone = 0, plain = ""
        for c in run { if let (v, t) = toned[c] { plain.append(v); tone = t } else { plain.append(c) } }
        let next = (tone + 1) % 5
        let low = plain.lowercased()
        var pos: String.Index?
        if let i = low.firstIndex(of: "a") { pos = i } else if let i = low.firstIndex(of: "e") { pos = i }
        else if let r = low.range(of: "ou") { pos = r.lowerBound }
        else { pos = low.lastIndex { "iouü".contains($0) } }
        guard let p = pos else { return nil }
        let v = plain[p]
        let marked = next == 0 ? v : tones[v].map { Array($0)[next - 1] } ?? v
        var out = plain; out.replaceSubrange(p...p, with: String(marked))
        return (run.count, out)
    }
}
