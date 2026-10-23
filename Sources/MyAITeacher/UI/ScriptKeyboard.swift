import SwiftUI
import AppKit

/// A key pressed on the composer's on-screen keyboard, applied by the composer's text view at its caret (composition
/// needs the text before the caret, which only the text view has). `remove` characters before the caret are replaced
/// (a kanji candidate replaces the kana that spell it).
struct KeyboardKeyEvent {
    var key: KeyboardLayouts.Key
    var layout: KeyboardLayouts.Layout
    var shift: Bool
    var katakana: Bool
    var mode: String            // tap | kana | romaji | keys
    var sessionID: String
    var remove = 0
    var romaji: Bool { mode == "romaji" }
}

extension Notification.Name {
    static let composerKey = Notification.Name("composerKey")
    /// The composer typed a character from the Mac's keys in "keys" mode: the on-screen key lights up.
    static let composerKeyFlash = Notification.Name("composerKeyFlash")
}

/// The on-screen keyboard above the composer, for the language the lesson is teaching: the same layouts, modes and
/// helpers as the transcript's panel (keyboard-layouts.js, components/keyboard.js), so a learner meets one keyboard.
struct ScriptKeyboardView: View {
    let layout: KeyboardLayouts.Layout
    let sessionID: String
    /// The learner's saved words (kanji and their kana), for kanji candidates while typing kana.
    var words: [(term: String, kana: String)] = []
    /// The text before the composer's caret (its draft), for the candidates.
    var draft: String = ""
    var onClose: () -> Void
    @State private var shift = false
    @State private var katakana = false
    @State private var mode = ""
    @State private var compact = false
    @State private var flashed: String?
    @State private var source: InputSources.Info?

    private var modes: [String] { layout.inputModes }
    private static let modeLabel = ["kana": "かな", "romaji": "ローマ字", "tap": "Tap", "keys": "Mac keys"]

    var body: some View {
        VStack(spacing: 5) {
            header
            if !candidates.isEmpty {
                HStack(spacing: 6) {
                    ForEach(candidates, id: \.term) { w in
                        Button { post(.text(w.term), remove: w.kana.count) } label: {
                            Text(w.term).font(.system(size: 16)).padding(.horizontal, 8).padding(.vertical, 2)
                                .background(RoundedRectangle(cornerRadius: 7).fill(Color.accentColor.opacity(0.14)))
                        }.buttonStyle(.plain).help(w.kana)
                    }
                }
            }
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 5) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in button(key) }
                }
                .environment(\.layoutDirection, layout.rtl ? .rightToLeft : .leftToRight)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
        .onAppear {
            if mode.isEmpty { mode = modes.first ?? "tap" }
            compact = UserDefaults.standard.bool(forKey: "kbd.compact.\(layout.code)")
            source = InputSources.best(for: layout.code)
            post(.fn("mode"))
        }
        .onReceive(NotificationCenter.default.publisher(for: .composerKeyFlash)) { n in
            guard let s = n.object as? String else { return }
            flashed = s
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { if flashed == s { flashed = nil } }
        }
        // Closing the keyboard ends romaji and katakana in the composer too: they used to stay on, and English typed after
        // closing it came out as kana ("My ろぇ: い いんsたll…").
        .onDisappear { post(.fn("reset")) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(layout.name).font(.caption.bold())
            Text(layout.english).font(.caption).foregroundStyle(.secondary)
            if modes.count > 1 {
                Picker("Input mode", selection: Binding(get: { mode }, set: { mode = $0; post(.fn("mode")) })) {
                    ForEach(modes, id: \.self) { Text(Self.modeLabel[$0] ?? $0).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize().controlSize(.small)
            }
            Text(hint).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let s = source {
                if s.selected {
                    Label(s.name, systemImage: "checkmark").font(.caption).foregroundStyle(.green).help("The Mac is typing with \(s.name)")
                } else if s.enabled {
                    Button("Use Mac input: \(s.name)") { InputSources.select(for: layout.code); source = InputSources.best(for: layout.code) }
                        .controlSize(.small).help("Switch the Mac to its own \(s.name) input: full layout\(layout.compose == "kana" || layout.compose == "pinyin" ? ", conversion to kanji/hanzi" : "")")
                } else {
                    Button("Add Mac input…") { InputSources.openSettings() }.controlSize(.small)
                        .help("Add the Mac's \(s.name) input source in Keyboard settings (it converts to kanji/hanzi and types the full layout)")
                }
            }
            Button(compact ? "Full" : "Compact") {
                compact.toggle(); UserDefaults.standard.set(compact, forKey: "kbd.compact.\(layout.code)")
            }.controlSize(.small).help(compact ? "Show every key" : "Only the helper keys")
            Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide the keyboard")
        }
    }

    private var hint: String {
        switch mode {
        case "romaji": return "Type romaji: konnichiha → こんにちは"
        case "keys": return "Your Mac keys type \(layout.english) in its standard layout"
        default:
            switch layout.compose {
            case "hangul": return "Jamo join into syllables"
            case "pinyin": return "Type the syllable, then its tone (key or digit: ni3 → nǐ)"
            case "abugida": return "A vowel after a consonant becomes its sign: क + आ → का"
            case "marks" where layout.rtl: return "Harakat attach to the letter before them"
            default: return ""
            }
        }
    }

    private static func isCombining(_ s: String) -> Bool {
        s.unicodeScalars.allSatisfy { (0x300...0x36F).contains($0.value) || (0x591...0x5C7).contains($0.value) || (0x64B...0x652).contains($0.value) || $0.value == 0x670
            || (0x901...0x903).contains($0.value) || (0x93C...0x94D).contains($0.value) || (0x981...0x983).contains($0.value) || (0x9BC...0x9CD).contains($0.value)
            || $0.value == 0xE31 || (0xE34...0xE3A).contains($0.value) || (0xE47...0xE4E).contains($0.value) }
    }

    private var rows: [[KeyboardLayouts.Key]] {
        if mode == "romaji" { return [[.fn("kana"), .text("、"), .text("。"), .text("ー"), .text("？"), .text("！"), .text("「"), .text("」"), .fn("bksp"), .fn("mode")]] }
        let all = (shift && layout.shift != nil) ? layout.shift! : layout.rows
        guard compact else { return all }
        // Compact: only the helpers (marks, tones, function keys); the letters come from the Mac's keys.
        let keep = all.filter { $0.contains { k in if case .text(let s) = k { return Self.isCombining(s) }; return true } }
        return keep.isEmpty ? Array(all.suffix(1)) : keep
    }

    /// Saved words whose kana end the draft (たべる → 食べる).
    private var candidates: [(term: String, kana: String)] {
        guard layout.compose == "kana", !words.isEmpty else { return [] }
        let run = String(draft.reversed().prefix { ("\u{3041}"..."\u{30FC}").contains(String($0)) }.reversed())
        guard !run.isEmpty else { return [] }
        let hira = ScriptComposer.toHiragana(run)
        var seen = Set<String>(), out: [(term: String, kana: String)] = []
        for w in words.sorted(by: { $0.kana.count > $1.kana.count }) where !w.kana.isEmpty && w.kana != w.term && !seen.contains(w.term) {
            if hira.hasSuffix(ScriptComposer.toHiragana(w.kana)) { seen.insert(w.term); out.append(w) }
            if out.count >= 6 { break }
        }
        return out
    }

    private func label(_ key: KeyboardLayouts.Key) -> String {
        switch key {
        case .text(let s):
            var t = s
            if shift && layout.upper && layout.shift == nil { t = t.uppercased() }
            if katakana && layout.compose == "kana" { t = ScriptComposer.toKatakana(t) }
            return Self.isCombining(t) ? "◌" + t : t
        case .fn(let f):
            return ["shift": "⇧", "bksp": "⌫", "space": "space", "enter": "⏎", "dakuten": "゛", "handakuten": "゜", "small": "小", "kana": "カナ", "tone": "ā→á",
                    "tone1": "ˉ 1", "tone2": "ˊ 2", "tone3": "ˇ 3", "tone4": "ˋ 4", "mode": mode == "romaji" ? "かな" : "ローマ字"][f] ?? f
        }
    }

    private func post(_ key: KeyboardLayouts.Key, remove: Int = 0) {
        NotificationCenter.default.post(name: .composerKey, object: KeyboardKeyEvent(key: key, layout: layout, shift: shift, katakana: katakana, mode: mode,
                                                                                     sessionID: sessionID, remove: remove))
    }

    @ViewBuilder private func button(_ key: KeyboardLayouts.Key) -> some View {
        if key == .text("") {
            Color.clear.frame(width: 34, height: 32)   // a gap in the kana table
        } else {
            let isFn: Bool = { if case .fn = key { return true }; return false }()
            let on: Bool = { if case .fn(let f) = key { return (f == "shift" && shift) || (f == "kana" && katakana) }; return false }()
            let hit: Bool = { if case .text(let s) = key { return s == flashed }; return false }()
            Button {
                switch key {
                case .fn("shift"): shift.toggle()
                case .fn("kana"): katakana.toggle()
                case .fn("mode"):
                    if let i = modes.firstIndex(of: mode) { mode = modes[(i + 1) % modes.count] }
                default: break
                }
                post(key)
                if case .text = key, shift { shift = false }   // one shifted key at a time, as on the page
            } label: {
                Text(label(key))
                    .font(.system(size: isFn ? 12 : 17))
                    .frame(minWidth: key == .fn("space") ? 150 : 34, minHeight: 32)
                    .padding(.horizontal, 4)
                    .background(RoundedRectangle(cornerRadius: 7).fill(on || hit ? Color.accentColor.opacity(0.28) : isFn ? Color.primary.opacity(0.07) : Color(nsColor: .controlBackgroundColor)))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(hit ? Color.accentColor : Color.primary.opacity(0.1)))
                    .shadow(color: .black.opacity(0.06), radius: 0, y: 1)
                    .contentShape(Rectangle())
            }
            .buttonStyle(KeyPressStyle())
            .foregroundStyle(isFn ? Color.secondary : Color.primary)
            .help(isFn ? helpText(key) : "")
        }
    }
    private func helpText(_ key: KeyboardLayouts.Key) -> String {
        guard case .fn(let f) = key else { return "" }
        return ["dakuten": "Voiced mark (か → が)", "handakuten": "Semi-voiced mark (は → ぱ)", "small": "Small kana (つ → っ)", "kana": "Katakana", "tone": "Cycle the tone",
                "tone1": "First tone (high level)", "tone2": "Second tone (rising)", "tone3": "Third tone (dipping)", "tone4": "Fourth tone (falling)", "mode": "Input mode"][f] ?? ""
    }
}

/// Keys sink a little while pressed.
private struct KeyPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.scaleEffect(configuration.isPressed ? 0.94 : 1).opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.easeOut(duration: 0.06), value: configuration.isPressed)
    }
}

// MARK: - First click

/// SwiftUI content whose first click works while its window is not the key window: a plain SwiftUI button there only
/// activated the window and swallowed the click (the keyboard button needed two). The content is hosted in its own
/// `NSHostingView` that accepts the first mouse down, as the transcript's web view does.
struct FirstMouse<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder _ content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> FirstMouseHostingView<Content> {
        let v = FirstMouseHostingView(rootView: content)
        v.sizingOptions = [.intrinsicContentSize]
        v.setContentHuggingPriority(.required, for: .vertical)
        return v
    }
    func updateNSView(_ v: FirstMouseHostingView<Content>, context: Context) { v.rootView = content }
}

final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
