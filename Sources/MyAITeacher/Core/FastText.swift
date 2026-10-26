import Foundation

/// Text scans on UTF-8 bytes, 16 at a time where the text is plain ASCII (most prose, code and HTML), with the
/// Unicode-aware path kept for the rest. Each matches what it replaced exactly; it only does it without a Character or
/// Unicode.Scalar per position (page conversion, passage ranking and memory indexing scan whole pages).
enum FastText {
    /// Unicode scalars in `s` and how many of them are CJK (Han, kana, Hangul and their punctuation): the token estimate.
    /// A scalar is a byte that isn't a continuation byte; every CJK range is a 3-byte sequence.
    static func scalarCounts(_ s: String) -> (scalars: Int, cjk: Int) {
        var str = s
        str.makeContiguousUTF8()
        return str.utf8.withContiguousStorageIfAvailable { p -> (Int, Int) in
            guard let base = p.baseAddress else { return (0, 0) }
            let n = p.count
            var scalars = 0, cjk = 0, i = 0
            func lead(_ k: Int) {
                let b = p[k]
                guard b >= 0xE1, b <= 0xEF, k + 2 < n else { return }
                let cp = UInt32(b & 0x0F) << 12 | UInt32(p[k + 1] & 0x3F) << 6 | UInt32(p[k + 2] & 0x3F)
                if isCJK(cp) { cjk += 1 }
            }
            while i + 16 <= n {
                let v = UnsafeRawPointer(base + i).loadUnaligned(as: SIMD16<UInt8>.self)
                if (v & 0x80) == .zero { scalars += 16; i += 16; continue }   // all ASCII
                let continuation = (v & 0xC0) .== SIMD16<UInt8>(repeating: 0x80)
                scalars += 16 - Int(SIMD16<UInt8>(repeating: 0).replacing(with: 1, where: continuation).wrappedSum())
                for k in i..<(i + 16) { lead(k) }
                i += 16
            }
            while i < n {
                if p[i] & 0xC0 != 0x80 { scalars += 1 }
                lead(i); i += 1
            }
            return (scalars, cjk)
        } ?? (s.unicodeScalars.count, 0)
    }

    static func isCJK(_ v: UInt32) -> Bool {
        switch v {
        case 0x1100...0x11FF, 0x2E80...0x2FDF, 0x3000...0x30FF, 0x3130...0x318F, 0x3400...0x4DBF,
             0x4E00...0x9FFF, 0xA960...0xA97F, 0xAC00...0xD7AF, 0xF900...0xFAFF, 0xFF00...0xFFEF:
            return true
        default: return false
        }
    }

    /// Every run of Unicode whitespace (the White_Space property: tabs, newlines, spaces, no-break and ideographic spaces,
    /// line and paragraph separators) as one space.
    static func collapseWhitespace(_ s: String) -> String {
        var str = s
        str.makeContiguousUTF8()
        guard let out = str.utf8.withContiguousStorageIfAvailable({ p -> String in
            guard let base = p.baseAddress else { return "" }
            let n = p.count
            var out = [UInt8]()
            out.reserveCapacity(n)
            var space = false, i = 0
            while i < n {
                // Sixteen printable ASCII bytes (no whitespace, no multi-byte sequence): copied as they are.
                if i + 16 <= n {
                    let v = UnsafeRawPointer(base + i).loadUnaligned(as: SIMD16<UInt8>.self)
                    if !any((v .<= SIMD16<UInt8>(repeating: 0x20)) .| (v .>= SIMD16<UInt8>(repeating: 0x80))) {
                        out.append(contentsOf: UnsafeBufferPointer(start: base + i, count: 16))
                        space = false; i += 16; continue
                    }
                }
                let w = whitespaceLength(p, i)
                if w > 0 {
                    if !space { out.append(0x20); space = true }
                    i += w
                } else {
                    out.append(p[i]); space = false; i += 1
                }
            }
            return String(decoding: out, as: UTF8.self)
        }) else { return s }
        return out
    }

    /// Bytes of the whitespace character at `i` in UTF-8, or 0.
    private static func whitespaceLength(_ p: UnsafeBufferPointer<UInt8>, _ i: Int) -> Int {
        let b = p[i], n = p.count
        if b == 0x20 || (b >= 0x09 && b <= 0x0D) { return 1 }
        guard b >= 0xC2, i + 1 < n else { return 0 }
        let b1 = p[i + 1]
        if b == 0xC2 { return b1 == 0x85 || b1 == 0xA0 ? 2 : 0 }                    // U+0085, U+00A0
        guard i + 2 < n else { return 0 }
        let b2 = p[i + 2]
        switch (b, b1) {
        case (0xE1, 0x9A): return b2 == 0x80 ? 3 : 0                                 // U+1680
        case (0xE2, 0x80): return (0x80...0x8A).contains(b2) || b2 == 0xA8 || b2 == 0xA9 || b2 == 0xAF ? 3 : 0   // U+2000–200A, 2028, 2029, 202F
        case (0xE2, 0x81): return b2 == 0x9F ? 3 : 0                                 // U+205F
        case (0xE3, 0x80): return b2 == 0x80 ? 3 : 0                                 // U+3000
        default: return 0
        }
    }

    static func isAlnum(_ b: UInt8) -> Bool { (b >= 0x30 && b <= 0x39) || (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }

    /// The words of `s`: runs of bytes `isWordByte` accepts, split at every other ASCII byte. An all-ASCII run goes to
    /// `ascii` lower-cased; a run with non-ASCII bytes in it goes to `mixed` as it is, for the caller's Unicode-aware
    /// splitting (an ASCII separator separates there too, so the results are the same as splitting the whole text).
    static func words(_ s: String, isWordByte: (UInt8) -> Bool, ascii: (String) -> Void, mixed: (String) -> Void) {
        var str = s
        str.makeContiguousUTF8()
        _ = str.utf8.withContiguousStorageIfAvailable { p in
            let n = p.count
            var i = 0, lower = [UInt8]()
            while i < n {
                let b = p[i]
                if b < 0x80 && !isWordByte(b) { i += 1; continue }
                var j = i, plain = true
                while j < n { let c = p[j]; if c < 0x80 { if !isWordByte(c) { break } } else { plain = false }; j += 1 }
                if plain {
                    lower.removeAll(keepingCapacity: true)
                    for k in i..<j { let c = p[k]; lower.append(c >= 0x41 && c <= 0x5A ? c | 0x20 : c) }
                    ascii(String(decoding: lower, as: UTF8.self))
                } else {
                    mixed(String(decoding: UnsafeBufferPointer(rebasing: p[i..<j]), as: UTF8.self))
                }
                i = j
            }
        }
    }
}
