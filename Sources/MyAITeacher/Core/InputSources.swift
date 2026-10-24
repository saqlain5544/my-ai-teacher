import Foundation
import Carbon
import AppKit

/// The Mac's own input sources (Text Input Sources): for a script the Mac types better than an on-screen grid — kana to
/// kanji conversion, pinyin to characters, the full Arabic or Korean layout — the keyboard panels offer the installed
/// input source for the language and switch to it at the learner's click (and back when they leave the language).
/// Enabling a new input source is a system setting: the app only opens Keyboard settings for that.
@MainActor
enum InputSources {
    struct Info: Equatable, Sendable {
        var id: String
        var name: String
        var enabled: Bool
        var selected: Bool
        var json: JSON { ["id": .string(id), "name": .string(name), "enabled": .bool(enabled), "selected": .bool(selected)] }
    }

    /// Preferred sources per language, best first (input methods that convert, then the standard layout).
    static let preferred: [String: [String]] = [
        "ja": ["com.apple.inputmethod.Kotoeri.RomajiTyping.Japanese", "com.apple.inputmethod.Kotoeri.KanaTyping.Japanese"],
        "zh": ["com.apple.inputmethod.SCIM.ITABC", "com.apple.inputmethod.TCIM.Pinyin", "com.apple.inputmethod.SCIM.Shuangpin"],
        "ko": ["com.apple.inputmethod.Korean.2SetKorean", "com.apple.inputmethod.Korean.3SetKorean"],
        "ar": ["com.apple.keylayout.ArabicPC", "com.apple.keylayout.Arabic", "com.apple.keylayout.Arabic-QWERTY"],
        "fa": ["com.apple.keylayout.Persian-ISIRI2901", "com.apple.keylayout.Persian-QWERTY"],
        "he": ["com.apple.keylayout.Hebrew", "com.apple.keylayout.Hebrew-QWERTY"],
        "ru": ["com.apple.keylayout.RussianWin", "com.apple.keylayout.Russian", "com.apple.keylayout.Russian-Phonetic"],
        "uk": ["com.apple.keylayout.Ukrainian-PC", "com.apple.keylayout.Ukrainian"],
        "el": ["com.apple.keylayout.Greek", "com.apple.keylayout.GreekPolytonic"],
        "hi": ["com.apple.keylayout.Devanagari-QWERTY", "com.apple.inputmethod.TransliterationIM.hi", "com.apple.keylayout.Devanagari"],
        "th": ["com.apple.keylayout.Thai", "com.apple.keylayout.Thai-PattaChote"],
    ]

    private static func string(_ s: TISInputSource, _ k: CFString) -> String? {
        guard let p = TISGetInputSourceProperty(s, k) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }
    private static func flag(_ s: TISInputSource, _ k: CFString) -> Bool {
        guard let p = TISGetInputSourceProperty(s, k) else { return false }
        return CFBooleanGetValue(Unmanaged<CFBoolean>.fromOpaque(p).takeUnretainedValue())
    }
    private static func all() -> [TISInputSource] {
        (TISCreateInputSourceList(nil, true)?.takeRetainedValue() as? [TISInputSource]) ?? []
    }
    private static func current() -> TISInputSource? { TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() }

    /// The Mac's input source for a language: an enabled one first, else the best installed one (to enable in Settings).
    /// nil for languages the Latin keyboard already types (the accent row covers them).
    static func best(for lang: String?) -> Info? {
        guard let lang, let ids = preferred[lang] else { return nil }
        let sources = all()
        let cur = current().flatMap { string($0, kTISPropertyInputSourceID) }
        func info(_ id: String) -> Info? {
            guard let s = sources.first(where: { string($0, kTISPropertyInputSourceID) == id }) else { return nil }
            return Info(id: id, name: string(s, kTISPropertyLocalizedName) ?? id, enabled: flag(s, kTISPropertyInputSourceIsEnabled) && flag(s, kTISPropertyInputSourceIsSelectCapable),
                        selected: cur == id)
        }
        let found = ids.compactMap(info)
        return found.first(where: \.enabled) ?? found.first
    }

    /// The source the learner was typing with before the app switched: restored when they leave the language.
    private static var previous: String?

    /// Switches the Mac to the language's enabled input source. False when it isn't enabled (Settings is the way).
    @discardableResult
    static func select(for lang: String) -> Bool {
        guard let b = best(for: lang), b.enabled, !b.selected,
              let s = all().first(where: { string($0, kTISPropertyInputSourceID) == b.id }) else { return false }
        if previous == nil { previous = current().flatMap { string($0, kTISPropertyInputSourceID) } }
        return TISSelectInputSource(s) == noErr
    }

    /// Back to what the learner typed with before (the app switched it, and the lesson's language is no longer on screen).
    static func restore() {
        guard let id = previous else { return }
        previous = nil
        if let s = all().first(where: { string($0, kTISPropertyInputSourceID) == id }) { TISSelectInputSource(s) }
    }

    /// Keyboard settings, where input sources are added (System Settings › Keyboard › Text Input).
    static func openSettings() {
        if let u = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") { NSWorkspace.shared.open(u) }
    }
}
