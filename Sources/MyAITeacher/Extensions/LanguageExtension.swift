import Foundation
import NaturalLanguage

/// Which language a lesson is teaching, and in which language the learner is taught: the mentor's profile when it set
/// one, otherwise read from the lesson itself (what the learner asked for, the languages the replies are tagged with).
struct LanguageState: Equatable, Sendable {
    var target: String?        // the language being learned (ISO 639-1)
    var native: String?        // the learner's own language
    var level: String?         // CEFR estimate from the profile
    var profiled = false       // the mentor set the target with `language` action=profile
    var source = "none"        // profile | asked | content | none

    var hasKeyboard: Bool { KeyboardLayouts.layout(for: target) != nil }
    /// What the page needs (T.setLanguage): codes, display names, direction.
    var json: JSON {
        ["target": target.map { .string($0) } ?? .null, "native": native.map { .string($0) } ?? .null,
         "name": target.map { .string(Languages.nativeName($0)) } ?? .null, "english": target.map { .string(Languages.englishName($0)) } ?? .null,
         "level": level.map { .string($0) } ?? .null, "rtl": .bool(target.map { Languages.rightToLeft.contains($0) } ?? false)]
    }
}

/// Multilingual teaching: prompt guidance for mixed-language output, per-turn language detection, and the language
/// mentor's runtime state — the target language is detected as the lesson goes (or set by the mentor), the page gets
/// the matching on-screen keyboard, and every request carries a `<language_state>` line.
@MainActor
final class LanguageExtension: AgentExtension {
    let id = "language"
    private var states: [String: LanguageState] = [:]      // lesson id → last computed state
    private var perMessage: [String: [String]] = [:]       // message id → languages in that reply (computed once)

    func systemPromptSections(_ session: ChatSession) -> [String] {
        let full = session.conversation.mode == .language || state(for: session).target != nil
        var s = """
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
        """
        if full { s += "\n" + Self.componentGuide }
        return [s]
    }

    /// The language-learning components and question fields, sent to lessons that teach a language.
    static let componentGuide = """
    - Language-learning components (JSON fences): ```gloss {"lang":"ja","words":[{"w":"私は","r":"わたしは","m":"I (topic)","role":"topic"},{"w":"りんごを","r":"ringo o","m":"apple (object)","role":"object"},{"w":"食べる","r":"taberu","m":"eat","role":"verb"}],"translation":"I eat an apple.","align":[[0,0],[1,3],[2,1]]} — an interlinear sentence with word roles and word-order lines to the translation; ```listen {"lang":"es","text":"…","translation":"…","hide":true} — play / play slowly, text hidden for dictation; ```dialogue {"lang":"fr","title":"…","lines":[{"who":"Serveur","text":"…","translation":"…"},{"who":"Vous","text":"…"}],"you":"Vous"} — role-play: the learner's lines stay hidden until they say them; ```conjugation {"lang":"es","verb":"hablar","meaning":"to speak","tense":"presente","stem":"habl","forms":[{"person":"yo","form":"hablo"},{"person":"él","form":"es","irregular":true}]} — stem and endings told apart; ```tones {"text":"nǐ hǎo"} — Mandarin pitch contours. ```vocab cards carry a Save button (the learner's vocabulary, reviewed as flashcards).
    - Questions for language tests: type "speak" {"target":"こんにちは","lang":"ja","reading":"konnichiwa"} — they say it, on-device recognition in that language shows what was heard, graded by words matched; any question may carry "listen":"…" (+ "listen_lang") to play audio first with the text hidden (dictation); "accents":"strict" makes diacritics count in short_text and fill_blanks (default: lenient); "lang" on a question picks the on-screen keyboard. The learner has an on-screen keyboard for the target language's script on every text field, so ask for the script, not romanisation, from A2 on.
    - `language` (profile, transliterate, analyze, dictionary) and `vocab` (the learner's words: add, due, list, search, stats).
    """

    func willRequest(_ request: inout LLMRequest, session: ChatSession) {
        guard !session.conversation.mode.isAgent else { return }
        let st = state(for: session, push: true)
        if st.target == nil && session.conversation.mode != .language { return }
        Self.inject(Self.stateLine(st, study: session.services.study), into: &request)
    }

    /// Appends the line to the last learner message of the request (request copy only, like the course board's card).
    nonisolated static func inject(_ line: String, into request: inout LLMRequest) {
        guard let i = request.messages.indices.last, request.messages[i].role == .user else { return }
        request.messages[i].blocks.removeAll { $0.meta?["languageState"]?.bool == true }
        request.messages[i].blocks.append(Block(kind: .text, text: line, meta: ["languageState": true]))
    }

    nonisolated static func stateLine(_ st: LanguageState, study: StudyStore) -> String {
        guard let t = st.target else {
            return "<language_state>No target language yet: find out which language they want to learn and their level, then set it with `language` action=profile.</language_state>"
        }
        var parts = ["Target language: \(Languages.englishName(t)) (\(t))" + (st.level.map { ", level \($0)" } ?? ", level unknown") + (st.profiled ? "" : " — detected from the lesson, not set: confirm with `language` action=profile")]
        if let n = st.native { parts.append("learner's language: \(Languages.englishName(n))") }
        if let kb = KeyboardLayouts.layout(for: t) {
            parts.append("keyboard: on-screen \(kb.english) keyboard on every answer field" + (kb.modes.contains("romaji") ? " (kana or romaji)" : kb.compose == "pinyin" ? " (pinyin with tone marks; 汉字 via the Mac's input source)" : ""))
        }
        let v = study.vocabStats(lang: t)
        if v.total > 0 { parts.append("vocabulary: \(v.total) words saved, \(v.due) due, \(v.known) known") }
        else { parts.append("vocabulary: none saved yet (`vocab` add)") }
        return "<language_state>" + parts.joined(separator: " · ") + "</language_state>"
    }

    func didFinishTurn(_ metrics: inout TurnMetrics, session: ChatSession) {
        let text = session.messages.reversed().prefix { !($0.role == .user && !$0.isToolResultOnly) }
            .filter { $0.role == .assistant }.map(\.plainText).joined(separator: "\n")
        metrics.languages = Self.languages(in: text)
        for m in session.messages.suffix(8) where m.role == .assistant && perMessage[m.id] == nil { perMessage[m.id] = metrics.languages }
        _ = state(for: session, push: true)
    }

    func sessionWillClose(_ session: ChatSession) {
        states[session.id] = nil; pushed[session.id] = nil
        for m in session.messages { perMessage[m.id] = nil }
    }

    /// The lesson's language state, recomputed from its messages and the profile. With `push`, the page gets it as soon
    /// as it differs from what the page was last given (the keyboard appears mid-turn, before the first quiz).
    @discardableResult
    func state(for session: ChatSession, push: Bool = false) -> LanguageState {
        let st = compute(session)
        if states[session.id] != st {
            states[session.id] = st
            DispatchQueue.main.async { if session.language != st { session.language = st } }
        }
        if push, pushed[session.id] != st { pushed[session.id] = st; session.sink?.language(st) }
        return st
    }
    private var pushed: [String: LanguageState] = [:]      // lesson id → what the page was last told

    private func compute(_ session: ChatSession) -> LanguageState {
        let study = session.services.study
        let profiles = study.languageProfiles()
        let targets = profiles.filter { $0.role == "target" }
        let inferred = Self.infer(session.messages, cache: &perMessage)
        var st = LanguageState()
        st.native = profiles.first { $0.role == "native" }?.code ?? inferred.native
        // What this lesson is about wins; the profile adds the level. A lesson that says nothing yet falls back to the
        // one language the learner is known to be learning.
        if let asked = inferred.asked, asked != st.native { st.target = asked; st.source = "asked" }
        else if let c = inferred.content, c != st.native { st.target = c; st.source = "content" }
        else if targets.count == 1 || (session.conversation.mode == .language && !targets.isEmpty) { st.target = targets[0].code; st.source = "profile" }
        if let t = st.target, let p = targets.first(where: { $0.code == t }) { st.level = p.level; st.profiled = true; if st.source != "profile" { st.source = "profile" } }
        if st.target == st.native { st.target = nil; st.source = "none" }
        return st
    }

    /// What the lesson says about its languages: the language the learner asked to learn, the most frequent language
    /// of the replies other than the learner's, and the learner's own language.
    nonisolated static func infer(_ messages: [ChatMessage], cache: inout [String: [String]]) -> (asked: String?, content: String?, native: String?) {
        let learner = messages.filter { $0.role == .user && !$0.isToolResultOnly }
            .map { $0.blocks.filter { $0.kind == .text && $0.meta?["hidden"]?.bool != true }.compactMap(\.text).joined(separator: "\n") }
        let native = nativeLanguage(learner.joined(separator: "\n"))
        var counts: [String: Int] = [:]
        for m in messages where m.role == .assistant {
            let langs: [String]
            if let saved = m.meta?["languages"]?.array?.compactMap(\.string) { langs = saved }
            else if let c = cache[m.id] { langs = c }
            else { langs = languages(in: m.plainText); cache[m.id] = langs }
            for (i, l) in langs.enumerated() { counts[l, default: 0] += i == 0 ? 1 : 2 }   // a second language in a reply is the one being taught
        }
        let content = counts.filter { $0.key != native }.max { a, b in a.value != b.value ? a.value < b.value : a.key > b.key }?.key
        return (asked(learner), content, native)
    }

    /// The learner's own language: the dominant language of their messages (the Mac's language until they've written enough).
    nonisolated static func nativeLanguage(_ text: String) -> String? {
        let fallback = Locale.preferredLanguages.first.map { String($0.prefix(2)) }
        let clean = text.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        guard clean.count >= 20 else { return fallback }
        let rec = NLLanguageRecognizer()
        rec.processString(String(clean.suffix(3000)))
        guard let (l, p) = rec.languageHypotheses(withMaximum: 1).first, p >= 0.5 else { return fallback }
        return l.rawValue
    }

    private static let askPattern = try! NSRegularExpression(pattern: #"(?i)\b(learn(?:ing)?|teach(?:\s+me)?|practi[cs](?:e|ing)|stud(?:y|ying)|speak(?:ing)?|improve(?:\s+my)?|lessons?\s+(?:in|on|of)|tutor(?:\s+me)?\s+in|help\s+me\s+with|my)\b([^.!?\n]{0,50})"#)
    /// "I want to learn Japanese", "teach me some Spanish", "practise my Arabic" → the language named last.
    nonisolated static func asked(_ texts: [String]) -> String? {
        let names = Languages.names.keys.sorted { $0.count > $1.count }
        var found: String?
        for t in texts {
            let ns = t as NSString
            for m in askPattern.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                let window = ns.substring(with: m.range(at: 2)).lowercased()
                for n in names where window.contains(n) {
                    // A whole word for Latin names ("thai" must not match "thailand"… nor "lao" in "laos" is tolerated).
                    if n.first!.isASCII, let r = window.range(of: n) {
                        let after = r.upperBound < window.endIndex ? window[r.upperBound] : " "
                        let before = r.lowerBound > window.startIndex ? window[window.index(before: r.lowerBound)] : " "
                        if after.isLetter || before.isLetter { continue }
                    }
                    found = Languages.names[n]; break
                }
            }
        }
        return found
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
