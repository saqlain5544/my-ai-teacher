import CoreGraphics

/// "cmd+shift+s", "ctrl+Return", "Page_Down", "ArrowUp": the xdotool names Anthropic's computer-use models send and the DOM
/// names other models guess, as a macOS virtual key code plus modifier flags (ANSI layout).
struct KeyCombo: Equatable {
    var code: CGKeyCode
    var flags: UInt64
    var modifiers: [CGKeyCode]   // pressed before the key, released after it (apps that watch flagsChanged see them)

    static let shift: UInt64 = 0x20000, control: UInt64 = 0x40000, option: UInt64 = 0x80000, command: UInt64 = 0x100000, fn: UInt64 = 0x800000

    private static let mods: [String: (CGKeyCode, UInt64)] = [
        "cmd": (55, command), "command": (55, command), "super": (55, command), "meta": (55, command), "win": (55, command), "⌘": (55, command),
        "ctrl": (59, control), "control": (59, control), "^": (59, control),
        "alt": (58, option), "option": (58, option), "opt": (58, option), "⌥": (58, option),
        "shift": (56, shift), "⇧": (56, shift), "fn": (63, fn),
    ]
    private static let named: [String: CGKeyCode] = [
        "return": 36, "enter": 36, "kp_enter": 76, "tab": 48, "space": 49, "backspace": 51, "escape": 53, "esc": 53,
        "delete": 117, "del": 117, "forwarddelete": 117, "home": 115, "end": 119, "page_up": 116, "pageup": 116, "prior": 116,
        "page_down": 121, "pagedown": 121, "next": 121, "left": 123, "arrowleft": 123, "right": 124, "arrowright": 124,
        "down": 125, "arrowdown": 125, "up": 126, "arrowup": 126, "help": 114, "insert": 114,
        "f1": 122, "f2": 120, "f3": 99, "f4": 118, "f5": 96, "f6": 97, "f7": 98, "f8": 100, "f9": 101, "f10": 109, "f11": 103, "f12": 111,
        "f13": 105, "f14": 107, "f15": 113, "f16": 106, "f17": 64, "f18": 79, "f19": 80, "f20": 90,
        "minus": 27, "equal": 24, "comma": 43, "period": 47, "slash": 44, "backslash": 42, "semicolon": 41, "apostrophe": 39, "quote": 39,
        "grave": 50, "bracketleft": 33, "bracketright": 30,
    ]
    private static let chars: [Character: CGKeyCode] = [
        "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9, "b": 11, "q": 12, "w": 13, "e": 14, "r": 15,
        "y": 16, "t": 17, "1": 18, "2": 19, "3": 20, "4": 21, "6": 22, "5": 23, "=": 24, "9": 25, "7": 26, "-": 27, "8": 28, "0": 29,
        "]": 30, "o": 31, "u": 32, "[": 33, "i": 34, "p": 35, "l": 37, "j": 38, "'": 39, "k": 40, ";": 41, "\\": 42, ",": 43, "/": 44,
        "n": 45, "m": 46, ".": 47, "`": 50, " ": 49,
    ]

    /// Puts a character into the focused field (a letter, digit, punctuation or space, with no command or control key).
    var typesText: Bool { flags & (Self.command | Self.control) == 0 && Self.chars.values.contains(code) }
    /// Pastes: cmd/ctrl+V, or shift+Insert (the Help key on Mac keyboards).
    var isPaste: Bool { (code == 9 && flags & (Self.command | Self.control) != 0) || (code == 114 && flags & Self.shift != 0) }

    static func parse(_ text: String) -> KeyCombo? {
        let t = text.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return nil }
        // "+" alone (or a trailing "++") is the plus key, not a separator.
        var parts = t == "+" ? ["+"] : t.split(separator: "+", omittingEmptySubsequences: true).map(String.init)
        if t.hasSuffix("++") { parts.append("+") }
        guard let last = parts.popLast() else { return nil }
        var flags: UInt64 = 0, codes: [CGKeyCode] = []
        for m in parts {
            guard let (code, flag) = mods[m.lowercased()] else { return nil }
            flags |= flag; codes.append(code)
        }
        if let (code, flag) = mods[last.lowercased()] { return KeyCombo(code: code, flags: flags | flag, modifiers: codes) }   // a lone modifier
        if let code = named[last.lowercased()] { return KeyCombo(code: code, flags: flags, modifiers: codes) }
        guard last.count == 1, let ch = last.first else { return nil }
        if let code = chars[Character(ch.lowercased())] {
            if ch.isUppercase && flags & shift == 0 { flags |= shift; codes.append(56) }
            return KeyCombo(code: code, flags: flags, modifiers: codes)
        }
        let shifted: [Character: Character] = ["!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8", "(": "9", ")": "0",
                                               "_": "-", "+": "=", "{": "[", "}": "]", "|": "\\", ":": ";", "\"": "'", "<": ",", ">": ".", "?": "/", "~": "`"]
        if let base = shifted[ch], let code = chars[base] {
            return KeyCombo(code: code, flags: flags | shift, modifiers: flags & shift == 0 ? codes + [56] : codes)
        }
        return nil
    }
}
