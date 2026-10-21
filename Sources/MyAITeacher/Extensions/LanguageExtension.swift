import Foundation
import NaturalLanguage

/// Multilingual teaching: prompt guidance for mixed-language output and per-turn language detection.
@MainActor
final class LanguageExtension: AgentExtension {
    let id = "language"

    func systemPromptSections(_ session: ChatSession) -> [String] {
        ["""
        # Languages
        - Reply in the learner's language unless they ask otherwise. When teaching a language, mix languages naturally: \
        explanations in the learner's language, examples in the target language.
        - Mark every target-language word, phrase or sentence with raw HTML language tags, written directly in the text and \
        never inside backticks or code formatting. For example, write: The word <span lang="ar">مرحبا</span> means hello, \
        and <span lang="es">¿Qué tal?</span> means how are you. Use <div lang="ja">…</div> for whole blocks. The app uses \
        this for right-to-left layout, fonts, and click-to-hear pronunciation (the tags themselves are invisible).
        - Give pronunciation for non-Latin scripts: transliteration in parentheses, or ruby annotations \
        (`<ruby>漢字<rt>かんじ</rt></ruby>`, `<ruby>你好<rt>nǐ hǎo</rt></ruby>`).
        - For vocabulary use a ```vocab block (see Rich output). For conjugations/declensions use tables.
        """]
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        let text = session.messages.reversed().prefix { !($0.role == .user && !$0.isToolResultOnly) }
            .filter { $0.role == .assistant }.map(\.plainText).joined(separator: "\n")
        metrics.languages = Self.languages(in: text)
    }

    /// Languages present in a text (most frequent first). Conservative: explicit `lang` markup and non-Latin scripts
    /// always count; Latin-script languages other than the dominant one need long, confidently-detected sentences.
    nonisolated static func languages(in text: String, max: Int = 4) -> [String] {
        guard !text.isEmpty else { return [] }
        var counts: [String: Int] = [:]
        // Explicit markup from the model.
        if let re = try? NSRegularExpression(pattern: #"lang=["']([a-zA-Z-]{2,10})["']"#) {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                if let r = Range(m.range(at: 1), in: text) { counts[String(text[r].prefix(2)).lowercased(), default: 0] += 40 }
            }
        }
        var clean = text
        for p in ["```[\\s\\S]*?```", "\\$\\$[\\s\\S]*?\\$\\$", "\\\\\\[[\\s\\S]*?\\\\\\]", "\\\\\\([\\s\\S]*?\\\\\\)",
                  "\\$[^$\\n]*\\$", "`[^`]*`", "<[^>]+>", "https?://\\S+", "[#*_|>\\[\\]()\\d=+\\-/^{}\\\\]"] {
            clean = clean.replacingOccurrences(of: p, with: " ", options: .regularExpression)
        }
        let whole = NLLanguageRecognizer()
        whole.processString(clean)
        let dominant = whole.dominantLanguage?.rawValue
        if let d = dominant { counts[d, default: 0] += clean.count }
        let tok = NLTokenizer(unit: .sentence)
        tok.string = clean
        let rec = NLLanguageRecognizer()
        tok.enumerateTokens(in: clean.startIndex..<clean.endIndex) { r, _ in
            let s = String(clean[r])
            // Foreign-script runs (Arabic, CJK, …) are reliable at any length.
            for run in ScriptRuns.runs(s) where run.script != .latin && run.script != .neutral && run.script != .other {
                let letters = run.text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
                if letters >= 2, let l = run.script.defaultLanguage { counts[l, default: 0] += letters * 3 }
            }
            let latin = s.unicodeScalars.filter { ScriptRuns.script(of: $0) == .latin }.count
            guard latin >= 40 else { return true }
            rec.reset()
            if let d = dominant { rec.languageHints = [NLLanguage(d): 0.6] }
            rec.processString(s)
            if let (l, p) = rec.languageHypotheses(withMaximum: 1).first, p >= 0.9, l.rawValue != dominant {
                counts[l.rawValue, default: 0] += latin
            }
            return true
        }
        let total = Swift.max(1, counts.values.reduce(0, +))
        return counts.filter { $0.key == dominant || Double($0.value) / Double(total) >= 0.08 }
            .sorted { $0.value > $1.value }.prefix(max).map(\.key)
    }
}

/// Splits text into runs by Unicode script (used for TTS voice switching and language hints).
enum ScriptRuns {
    enum Script: Equatable {
        case latin, arabic, hebrew, cyrillic, greek, devanagari, thai, han, kana, hangul, other, neutral
        var defaultLanguage: String? {
            switch self {
            case .arabic: "ar"; case .hebrew: "he"; case .cyrillic: "ru"; case .greek: "el"; case .devanagari: "hi"
            case .thai: "th"; case .han: "zh"; case .kana: "ja"; case .hangul: "ko"; default: nil
            }
        }
    }
    struct Run { var script: Script; var text: String }

    static func script(of s: Unicode.Scalar) -> Script {
        switch s.value {
        case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: return .latin
        case 0x0600...0x06FF, 0x0750...0x077F, 0x08A0...0x08FF, 0xFB50...0xFDFF, 0xFE70...0xFEFF: return .arabic
        case 0x0590...0x05FF: return .hebrew
        case 0x0400...0x04FF: return .cyrillic
        case 0x0370...0x03FF: return .greek
        case 0x0900...0x097F: return .devanagari
        case 0x0E00...0x0E7F: return .thai
        case 0x3040...0x30FF: return .kana
        case 0x3400...0x9FFF, 0xF900...0xFAFF: return .han
        case 0xAC00...0xD7AF, 0x1100...0x11FF: return .hangul
        default:
            return CharacterSet.letters.contains(s) ? .other : .neutral
        }
    }

    static func runs(_ text: String) -> [Run] {
        var out: [Run] = []
        var cur = Script.neutral
        var buf = ""
        for ch in text.unicodeScalars {
            let sc = script(of: ch)
            if sc == .neutral || sc == cur || cur == .neutral {
                if cur == .neutral && sc != .neutral { cur = sc }
                buf.unicodeScalars.append(ch)
            } else {
                // Japanese mixes kana and kanji: keep them in one run.
                if (cur == .kana && sc == .han) || (cur == .han && sc == .kana) { cur = .kana; buf.unicodeScalars.append(ch); continue }
                out.append(Run(script: cur, text: buf))
                buf = String(ch); cur = sc
            }
        }
        if !buf.isEmpty { out.append(Run(script: cur, text: buf)) }
        return out
    }
}
