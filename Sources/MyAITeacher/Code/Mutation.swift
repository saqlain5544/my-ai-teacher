import Foundation

/// Source with its comments and strings blanked, byte for byte (newlines kept), so a scan for operators never lands in
/// text: `"a < b"` and `# x == y` are not code. Unlike `CodeImpact.code` it reads across lines (docstrings, block
/// comments, template literals), which a mutant that changes a string's meaning would otherwise corrupt.
enum CodeMask {
    struct Syntax {
        var line: [String] = ["//"], block = true
        var quotes: [UInt8] = [34], triple = false, backtick = false, charLiteral = false, regex = false
    }

    static func syntax(_ ext: String) -> Syntax? {
        switch ext {
        case "py": return Syntax(line: ["#"], block: false, quotes: [34, 39], triple: true)
        case "rb": return Syntax(line: ["#"], block: false, quotes: [34, 39], backtick: true)
        case "js", "jsx", "ts", "tsx", "mjs", "cjs": return Syntax(quotes: [34, 39], backtick: true, regex: true)
        case "go": return Syntax(quotes: [34, 39], backtick: true)
        case "rs": return Syntax(quotes: [34], charLiteral: true)
        case "swift": return Syntax(quotes: [34], triple: true)
        case "java", "kt", "cs", "scala": return Syntax(quotes: [34, 39], triple: true)
        case "c", "h", "cpp", "cc", "cxx", "hpp": return Syntax(quotes: [34, 39])
        case "php": return Syntax(line: ["//", "#"], quotes: [34, 39])
        case "zig": return Syntax(block: false, quotes: [34, 39])
        default: return nil
        }
    }

    static func mask(_ src: [UInt8], ext: String) -> [UInt8] {
        guard let s = syntax(ext) else { return src }
        var out = src
        let n = src.count
        func blank(_ a: Int, _ b: Int) { var k = a; while k < min(b, n) { if out[k] != 10 { out[k] = 32 }; k += 1 } }
        func starts(_ at: Int, _ t: String) -> Bool { let u = Array(t.utf8); return at + u.count <= n && Array(src[at..<at + u.count]) == u }
        var i = 0, lastSignificant: UInt8 = 10
        while i < n {
            let c = src[i]
            if let lc = s.line.first(where: { starts(i, $0) }), !(lc == "#" && ext == "php" && starts(i, "#[")) {
                var j = i; while j < n, src[j] != 10 { j += 1 }
                blank(i, j); i = j; continue
            }
            if s.block, starts(i, "/*") {
                var j = i + 2; while j < n, !starts(j, "*/") { j += 1 }
                blank(i, j + 2); i = j + 2; continue
            }
            if s.triple, (c == 34 || c == 39), starts(i, String(UnicodeScalar(c)) + String(UnicodeScalar(c)) + String(UnicodeScalar(c))) {
                let close = String(repeating: String(UnicodeScalar(c)), count: 3)
                var j = i + 3; while j < n, !starts(j, close) { if src[j] == 92 { j += 1 }; j += 1 }
                blank(i, j + 3); i = j + 3; lastSignificant = 34; continue
            }
            if s.quotes.contains(c) || (s.backtick && c == 96) {
                if c == 39, s.charLiteral {
                    // Rust: 'a' and '\n' are chars, 'a is a lifetime.
                    if i + 2 < n, src[i + 1] != 92, src[i + 2] == 39 { blank(i, i + 3); i += 3; continue }
                    if i + 1 < n, src[i + 1] == 92 { var j = i + 2; while j < n, src[j] != 39, src[j] != 10 { j += 1 }; blank(i, j + 1); i = j + 1; continue }
                    i += 1; continue
                }
                let multiline = c == 96
                var j = i + 1
                while j < n, src[j] != c, multiline || src[j] != 10 { if src[j] == 92, j + 1 < n, src[j + 1] != 10 { j += 1 }; j += 1 }
                blank(i, j + 1); i = j + 1; lastSignificant = 34; continue
            }
            if s.regex, c == 47, i + 1 < n, src[i + 1] != 47, src[i + 1] != 42, i + 1 < n, src[i + 1] != 32 || lastSignificant == 10,
               "(,=:[!&|?{};\n".utf8.contains(lastSignificant) {
                var j = i + 1, inClass = false
                while j < n, src[j] != 10 {
                    if src[j] == 92 { j += 2; continue }
                    if src[j] == 91 { inClass = true } else if src[j] == 93 { inClass = false } else if src[j] == 47, !inClass { break }
                    j += 1
                }
                if j < n, src[j] == 47 { blank(i, j + 1); i = j + 1; lastSignificant = 34; continue }
            }
            if c != 32 && c != 9 && c != 13 { lastSignificant = c }
            i += 1
        }
        return out
    }
}

/// One textual change to one line of source.
struct Mutant: Sendable, Equatable {
    var file: String
    var line: Int
    var kind: String          // the operator pair, e.g. "< → <="
    var original: String      // the line as written, trimmed
    var mutated: String       // the same line mutated, trimmed
    var function: String?
    var changed = false       // the line is one the learner changed since the last review
    /// The whole mutated line (untrimmed) and the original, to patch the file.
    var newLine: String
}

enum Mutator {
    static let sourceExtensions: Set<String> = ["py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "go", "rs", "swift", "java", "kt", "cs", "scala", "c", "h", "cpp", "cc", "cxx", "hpp", "rb", "php", "zig"]
    static let dynamic: Set<String> = ["py", "js", "jsx", "ts", "tsx", "mjs", "cjs", "rb", "php"]

    private static func re(_ p: String) -> NSRegularExpression { try! NSRegularExpression(pattern: p) }
    private static let integer = re(#"(?<![\w.$])\d+(?![\w.$])"#)
    private static let boolean = re(#"(?<![\w.$])(true|false|True|False)(?![\w$:(])"#)
    private static let ifLine = re(#"^(\s*)((?:\} )?(?:else )?(?:el)?if|while)\s*\((.*)\)\s*(\{?)\s*$"#)
    private static let ifBare = re(#"^(\s*)((?:\} )?else if|if|while)\s+([^;:=]*?(?:==|!=|<|>|\w)[^;]*?)\s*\{\s*$"#)
    private static let pyIf = re(#"^(\s*)(if|elif|while)\s+(.+):\s*$"#)
    private static let ret = re(#"^(\s*)return\s+(\S.*?);?\s*$"#)
    private static let call = re(#"^(\s*)[A-Za-z_][\w.]*\((.*)\);?\s*$"#)
    private static let skipLine = re(#"^\s*(import|from|use|using|package|#include|#define|#if|#endif|@|assert|debug_assert|precondition)\b"#)
    private static let noisy = re(#"^\s*(?:[\w.]*\.)?(print|println|printf|puts|log|debug|info|warn|error|assert\w*|expect|require|check|panic|fatalError|exit|sleep)\("#)

    /// Every mutant of one file: one per candidate operator on a line of code. `changed` marks lines the learner changed.
    static func mutants(file: String, text: String, changed: [ClosedRange<Int>] = []) -> [Mutant] {
        let ext = (file as NSString).pathExtension.lowercased()
        guard sourceExtensions.contains(ext), text.utf8.count < 400_000 else { return [] }
        let masked = CodeMask.mask(Array(text.utf8), ext: ext)
        let origLines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let maskLines = String(decoding: masked, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard origLines.count == maskLines.count else { return [] }
        let funcs = SymbolsTool.outline(text, ext: ext)
        var out: [Mutant] = []
        for (idx, orig) in origLines.enumerated() {
            let m = maskLines[idx]
            guard !m.trimmingCharacters(in: .whitespaces).isEmpty, orig.count < 300 else { continue }
            let n = idx + 1
            func has(_ r: NSRegularExpression, _ s: String) -> Bool { r.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil }
            if has(skipLine, m) { continue }
            let fn = funcs.last { $0.line <= n && $0.kind == "function" }?.name
            let isChanged = changed.contains { $0.contains(n) }
            func add(_ kind: String, _ newLine: String) {
                guard newLine != orig else { return }
                out.append(Mutant(file: file, line: n, kind: kind, original: orig.trimmingCharacters(in: .whitespaces), mutated: newLine.trimmingCharacters(in: .whitespaces),
                                  function: fn, changed: isChanged, newLine: newLine))
            }
            // Same offsets in both: blanking keeps every byte's place, so a token found in `m` is in `orig`.
            let mb = Array(m.utf8), ob = Array(orig.utf8)
            guard mb.count == ob.count else { continue }
            func replace(_ at: Int, _ len: Int, _ with: String) -> String { String(decoding: Array(ob[..<at]) + Array(with.utf8) + Array(ob[(at + len)...]), as: UTF8.self) }
            func find(_ pat: String) -> [Int] {
                let p = Array(pat.utf8); var r: [Int] = []
                guard mb.count >= p.count else { return r }
                for k in 0...(mb.count - p.count) where Array(mb[k..<k + p.count]) == p { r.append(k) }
                return r
            }
            for (a, b) in [("<=", "<"), ("<", "<="), (">=", ">"), (">", ">="), ("==", "!="), ("!=", "=="), ("&&", "||"), ("||", "&&"), ("+", "-"), ("-", "+")] {
                for k in find(" \(a) ") { add("\(a) → \(b)", replace(k + 1, a.utf8.count, b)) }
            }
            if ext == "py" || ext == "rb" {
                for k in find(" and ") { add("and → or", replace(k + 1, 3, "or")) }
                for k in find(" or ") { add("or → and", replace(k + 1, 2, "and")) }
            }
            for match in boolean.matches(in: m, range: NSRange(m.startIndex..., in: m)) {
                let word = (m as NSString).substring(with: match.range(at: 1))
                if ext == "py" ? !(word == "True" || word == "False") : !(word == "true" || word == "false") { continue }
                let flipped = word == "true" ? "false" : word == "false" ? "true" : word == "True" ? "False" : "True"
                let prefix = (m as NSString).substring(to: match.range.location).utf8.count
                add("\(word) → \(flipped)", replace(prefix, word.utf8.count, flipped))
            }
            for match in integer.matches(in: m, range: NSRange(m.startIndex..., in: m)) {
                let s = (m as NSString).substring(with: match.range)
                guard let v = Int(s), v < 1_000_000 else { continue }
                if has(re(#"^\s*(case|default)\b"#), m) { continue }
                let nv = v == 0 ? 1 : (n % 2 == 0 ? v + 1 : v - 1)
                let prefix = (m as NSString).substring(to: match.range.location).utf8.count
                add("\(v) → \(nv)", replace(prefix, s.utf8.count, String(nv)))
            }
            // A negated condition.
            func g(_ r: NSRegularExpression, _ k: Int) -> String? {
                guard let x = r.firstMatch(in: orig, range: NSRange(orig.startIndex..., in: orig)), x.range(at: k).location != NSNotFound else { return nil }
                return (orig as NSString).substring(with: x.range(at: k))
            }
            if ext == "py" || ext == "rb" {
                if ext == "py", has(pyIf, m), let ind = g(pyIf, 1), let kw = g(pyIf, 2), let cond = g(pyIf, 3) { add("negated condition", "\(ind)\(kw) not (\(cond)):") }
            } else if has(ifLine, m), let ind = g(ifLine, 1), let kw = g(ifLine, 2), let cond = g(ifLine, 3), let brace = g(ifLine, 4) {
                add("negated condition", "\(ind)\(kw) (!(\(cond)))" + (brace.isEmpty ? "" : " {"))
            } else if ["swift", "go", "rs"].contains(ext), has(ifBare, m), let ind = g(ifBare, 1), let kw = g(ifBare, 2), let cond = g(ifBare, 3),
                      !cond.contains(" let ") && !cond.contains(":=") && !cond.hasPrefix("let ") && !cond.contains("case ") {
                add("negated condition", "\(ind)\(kw) !(\(cond)) {")
            }
            // An early return (dynamic languages only: a typed function can't return nothing).
            if dynamic.contains(ext), has(ret, m), let ind = g(ret, 1), let value = g(ret, 2), value != "None", value != "null", value != "undefined", value != "nil" {
                let nothing = ext == "py" ? "None" : ext == "rb" ? "nil" : ext == "php" ? "null" : "undefined"
                add("return dropped", "\(ind)return \(nothing)" + (ext == "py" || ext == "rb" ? "" : ";"))
            }
            // A dropped call statement.
            if has(call, m), !has(noisy, m), !m.contains("="), let ind = g(call, 1), parens(mb) {
                add("call dropped", ext == "py" ? "\(ind)pass" : ind)
            }
        }
        return out
    }

    private static func parens(_ b: [UInt8]) -> Bool {
        var d = 0
        for c in b { if c == 40 || c == 91 || c == 123 { d += 1 } else if c == 41 || c == 93 || c == 125 { d -= 1 }; if d < 0 { return false } }
        return d == 0
    }

    /// At most `limit` mutants, spread: changed code first, then round-robin across functions (one from each before a
    /// second from any), and within a function across operator kinds, so twenty mutants are not twenty `+`s of one loop.
    static func select(_ all: [Mutant], limit: Int) -> [Mutant] {
        var buckets: [String: [Mutant]] = [:], order: [String] = []
        for m in all {
            let key = "\(m.file)#\(m.function ?? "")"
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(m)
        }
        // Within a bucket: changed lines first, then kinds taken in turn.
        for k in order {
            let ms = buckets[k]!
            var byKind: [String: [Mutant]] = [:], kinds: [String] = []
            for m in ms.sorted(by: { ($0.changed ? 0 : 1, $0.line) < ($1.changed ? 0 : 1, $1.line) }) {
                let kk = m.kind.contains(" → ") ? String(m.kind.split(separator: " ")[0]) : m.kind
                if byKind[kk] == nil { kinds.append(kk) }
                byKind[kk, default: []].append(m)
            }
            var mixed: [Mutant] = []
            var r = 0
            while mixed.count < ms.count {
                for kd in kinds { if let x = byKind[kd], r < x.count { mixed.append(x[r]) } }
                r += 1
            }
            buckets[k] = mixed
        }
        let first = Dictionary(uniqueKeysWithValues: order.enumerated().map { ($1, $0) })
        let touched = Dictionary(uniqueKeysWithValues: order.map { ($0, buckets[$0]!.contains { $0.changed } ? 0 : 1) })
        order.sort { (touched[$0]!, first[$0]!) < (touched[$1]!, first[$1]!) }
        var picked: [Mutant] = [], round = 0
        while picked.count < limit {
            var any = false
            for k in order where picked.count < limit { if round < buckets[k]!.count { picked.append(buckets[k]![round]); any = true } }
            if !any { break }
            round += 1
        }
        return picked.sorted { ($0.file, $0.line) < ($1.file, $1.line) }
    }
}
