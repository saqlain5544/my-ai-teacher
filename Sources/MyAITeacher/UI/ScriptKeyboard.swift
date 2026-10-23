import SwiftUI
import AppKit

/// A key pressed on the composer's on-screen keyboard, applied by the composer's text view at its caret (composition
/// needs the text before the caret, which only the text view has).
struct KeyboardKeyEvent {
    var key: KeyboardLayouts.Key
    var layout: KeyboardLayouts.Layout
    var shift: Bool
    var katakana: Bool
    var romaji: Bool
}

extension Notification.Name {
    static let composerKey = Notification.Name("composerKey")
}

/// The on-screen keyboard above the composer, for the language the lesson is teaching (same layouts as the transcript's).
struct ScriptKeyboardView: View {
    let layout: KeyboardLayouts.Layout
    var onClose: () -> Void
    @State private var shift = false
    @State private var katakana = false
    @State private var romaji = false

    var body: some View {
        VStack(spacing: 4) {
            HStack(spacing: 8) {
                Text(layout.name).font(.caption.bold())
                Text(layout.english).font(.caption).foregroundStyle(.secondary)
                if romaji { Text("Type romaji: konnichiha → こんにちは").font(.caption).foregroundStyle(.secondary) }
                else if layout.compose == "hangul" { Text("Jamo join into syllables").font(.caption).foregroundStyle(.secondary) }
                else if layout.compose == "pinyin" { Text("Type the syllable, then ā→á for its tone").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button { onClose() } label: { Image(systemName: "xmark") }.buttonStyle(.borderless).help("Hide the keyboard")
            }
            let rows = romaji ? [[.fn("kana"), .text("、"), .text("。"), .text("ー"), .text("？"), .text("！"), .fn("bksp"), .fn("mode")]] : ((shift && layout.shift != nil) ? layout.shift! : layout.rows)
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                HStack(spacing: 4) {
                    ForEach(Array(row.enumerated()), id: \.offset) { _, key in button(key) }
                }
                .environment(\.layoutDirection, layout.rtl ? .rightToLeft : .leftToRight)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.primary.opacity(0.04)))
    }

    private func label(_ key: KeyboardLayouts.Key) -> String {
        switch key {
        case .text(let s):
            var t = s
            if shift && layout.upper && layout.shift == nil { t = t.uppercased() }
            if katakana && layout.compose == "kana" { t = ScriptComposer.toKatakana(t) }
            let combining = t.unicodeScalars.allSatisfy { (0x300...0x36F).contains($0.value) || (0x591...0x5C7).contains($0.value) || (0x64B...0x652).contains($0.value) || $0.value == 0x670 }
            return combining ? "◌" + t : t
        case .fn(let f):
            return ["shift": "⇧", "bksp": "⌫", "space": "␣", "enter": "⏎", "dakuten": "゛", "handakuten": "゜", "small": "小", "kana": "カナ", "tone": "ā→á", "mode": romaji ? "かな" : "ローマ字"][f] ?? f
        }
    }

    private func button(_ key: KeyboardLayouts.Key) -> some View {
        let isFn: Bool = { if case .fn = key { return true }; return false }()
        let on: Bool = { if case .fn(let f) = key { return (f == "shift" && shift) || (f == "kana" && katakana) }; return false }()
        return Button {
            switch key {
            case .fn("shift"): shift.toggle()
            case .fn("kana"): katakana.toggle()
            case .fn("mode"): romaji.toggle()
            default: break
            }
            NotificationCenter.default.post(name: .composerKey, object: KeyboardKeyEvent(key: key, layout: layout, shift: shift, katakana: katakana, romaji: romaji))
            if case .text = key, shift, layout.shift == nil || true { shift = false }
        } label: {
            Text(label(key))
                .font(.system(size: isFn ? 12 : 16))
                .frame(minWidth: key == .fn("space") ? 140 : 30, minHeight: 28)
                .padding(.horizontal, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(on ? Color.accentColor.opacity(0.25) : isFn ? Color.primary.opacity(0.06) : Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.primary.opacity(0.08)))
        }
        .buttonStyle(.plain)
        .foregroundStyle(isFn ? Color.secondary : Color.primary)
    }
}
