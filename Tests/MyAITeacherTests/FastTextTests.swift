import XCTest
@testable import MyAITeacher

/// The byte-level scanners give exactly what the Character / Unicode.Scalar code they replaced gave.
final class FastTextTests: XCTestCase {
    // The replaced implementations, kept here as the reference.
    private func refCounts(_ s: String) -> (Int, Int) {
        var cjk = 0, total = 0
        for u in s.unicodeScalars { total += 1; if FastText.isCJK(u.value) { cjk += 1 } }
        return (total, cjk)
    }
    private func refCollapse(_ s: String) -> String {
        var r = "", space = false
        for u in s.unicodeScalars {
            if u.properties.isWhitespace || u == "\u{00A0}" { if !space { r.unicodeScalars.append(" "); space = true } }
            else { r.unicodeScalars.append(u); space = false }
        }
        return r
    }
    private func refMemoryTokens(_ s: String) -> [String] {
        let separators = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "+#")).inverted
        return s.lowercased().components(separatedBy: separators).filter { !$0.isEmpty }
    }
    private func refPassageWords(_ s: String) -> [String] {
        s.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }
    private func fastPassageWords(_ s: String) -> [String] {
        var out: [String] = []
        FastText.words(s, isWordByte: FastText.isAlnum, ascii: { out.append($0) }) { seg in
            out += seg.lowercased().split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
        }
        return out
    }

    private let samples = [
        "", " ", "plain ASCII prose, with punctuation! And Numbers 1234.",
        "tabs\tand\nnewlines\r\n  and   runs     of spaces long enough to cross sixteen-byte blocks.......",
        "no\u{00A0}break\u{2009}thin\u{3000}ideographic\u{2028}line\u{2029}para\u{205F}math\u{1680}ogham\u{0085}nel\u{202F}narrow",
        "Café naïve résumé — “smart quotes” and ellipsis… em–dash",
        "光合作用は葉緑体で起こる。한국어 텍스트도 있어요。中文，标点。",
        "مرحبا بك في الدرس الأول", "emoji 👩🏽‍🏫 and flags 🇵🇰 mixed with text", "C++ and C# and F#, c++17",
        "e\u{0301}tude combining marks\u{0301} after a space \u{0301}", "İstanbul ΣΊΣΥΦΟΣ straße",
        String(repeating: "abcdefghijklmnop", count: 20) + "é" + String(repeating: " x ", count: 30),
        "control\u{0001}chars\u{0007}and\u{007F}del", "x" + String(repeating: "\u{3000}", count: 40) + "y",
    ]

    func testExactlyTheSameAsBefore() {
        var inputs = samples
        // Random mixes of the pieces above, cut at arbitrary characters (block edges land everywhere).
        var rng = SystemRandomNumberGenerator()
        let pieces = samples.flatMap { Array($0) }
        for _ in 0..<300 {
            let n = Int.random(in: 0..<120, using: &rng)
            inputs.append(String((0..<n).map { _ in pieces.randomElement(using: &rng)! }))
        }
        for s in inputs {
            let fast = FastText.scalarCounts(s), ref = refCounts(s)
            XCTAssertEqual(fast.scalars, ref.0, s); XCTAssertEqual(fast.cjk, ref.1, s)
            XCTAssertEqual(FastText.collapseWhitespace(s), refCollapse(s), s)
            XCTAssertEqual(MemoryText.tokens(s), refMemoryTokens(s), s)
            XCTAssertEqual(fastPassageWords(s), refPassageWords(s), s)
        }
    }

    func testBridgedStringsWork() {
        // Strings from Foundation (XMLNode, NSString) are not always native UTF-8.
        let ns = NSString(string: "Bridged\u{00A0}  text 光合") as String
        XCTAssertEqual(FastText.collapseWhitespace(ns), "Bridged text 光合")
        XCTAssertEqual(FastText.scalarCounts(ns).cjk, 2)
    }
}
