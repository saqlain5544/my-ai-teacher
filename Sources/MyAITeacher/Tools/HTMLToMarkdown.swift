import Foundation

/// Converts HTML to readable Markdown using Foundation's built-in tidy HTML parser (no dependencies).
enum HTMLToMarkdown {
    struct Result { var title: String?; var markdown: String }
    /// Text kept from one page (the tool returns at most 100k characters per call).
    static let maxOutput = 400_000
    /// Deeper than this the tree is pathological (tidy nesting unclosed tags): the rest is taken as plain text, without recursion.
    static let maxDepth = 40

    private static let skipTags: Set<String> = ["script", "style", "noscript", "svg", "iframe", "form", "button", "input",
                                                "select", "textarea", "template", "canvas", "object", "embed", "link", "meta"]
    private static let chromeTags: Set<String> = ["nav", "footer", "aside", "header"]
    private static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "figure", "figcaption", "dl", "dt", "dd",
                                                 "address", "center", "details", "summary", "hgroup"]

    /// Foundation's tidy parser drops unknown (HTML5) elements, so map them to divs/spans first, lift TeX out of MathML
    /// annotations, and drop comments, scripts, styles, SVG, templates and other MathML. One pass over the bytes: the eight
    /// regex passes this replaces held several UTF-16 copies of the page at once (+65 MB for a 3 MB page, which the
    /// allocator then keeps).
    static func preprocess(_ html: String) -> String {
        let src = Array(html.utf8), n = src.count
        var out = [UInt8]()
        out.reserveCapacity(n)
        var missing: [String: Int] = [:]   // a closing pattern absent after position p is absent after any later one
        func lower(_ c: UInt8) -> UInt8 { c >= 65 && c <= 90 ? c + 32 : c }
        func at(_ i: Int, _ pat: String) -> Bool {
            var j = i
            for c in pat.utf8 { guard j < n, lower(src[j]) == c else { return false }; j += 1 }
            return true
        }
        func find(_ pat: String, from: Int, before limit: Int? = nil) -> Int? {
            if let m = missing[pat], from >= m, limit == nil { return nil }
            let first = pat.utf8.first!, end = min(limit ?? n, n)
            var j = from
            while j < end { if lower(src[j]) == first, at(j, pat) { return j }; j += 1 }
            if limit == nil { missing[pat] = from }
            return nil
        }
        func boundary(_ i: Int) -> Bool {   // the regex \b after a tag name
            guard i < n else { return true }
            let c = src[i]
            return !(c == 95 || (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c >= 128)
        }
        func name(at i: Int, _ names: [String]) -> String? { names.first { at(i, $0) && boundary(i + $0.utf8.count) } }
        let dropped = ["script", "style", "noscript", "svg", "template"]
        let blocks = ["article", "main", "nav", "footer", "aside", "header", "section", "figure", "figcaption", "details", "summary",
                      "hgroup", "address", "search", "dialog"]
        let inline = ["mark", "time", "picture", "data", "bdi", "output"]
        var i = 0
        while i < n {
            guard src[i] == 60 else { out.append(src[i]); i += 1; continue }   // "<"
            if at(i, "<!--"), let e = find("-->", from: i + 4) { i = e + 3; continue }
            if let t = name(at: i + 1, dropped), let e = find("</\(t)>", from: i + 1 + t.utf8.count) { i = e + t.utf8.count + 3; continue }
            if at(i, "<math"), boundary(i + 5), let e = find("</math>", from: i + 5) {
                // <math attrs>…<annotation encoding="application/x-tex">TeX</annotation>…</math> → <span data-tex="1" attrs>TeX</span>
                if let gt = src[(i + 5)..<e].firstIndex(of: 62) {
                    var a = gt
                    while let s = find("<annotation", from: a, before: e), let close = src[s..<e].firstIndex(of: 62) {
                        a = close + 1
                        guard String(decoding: src[s..<close], as: UTF8.self).lowercased().contains("encoding=\"application/x-tex\"") else { continue }
                        if let ae = find("</annotation>", from: a, before: e) {
                            out += Array("<span data-tex=\"1\"".utf8); out += src[(i + 5)..<gt]; out.append(62)
                            out += src[a..<ae]; out += Array("</span>".utf8)
                        }
                        break
                    }
                }
                i = e + 7; continue
            }
            let closing = i + 1 < n && src[i + 1] == 47, j = closing ? i + 2 : i + 1
            if let b = name(at: j, blocks) { out += Array((closing ? "</div" : "<div data-h5=\"\(b)\"").utf8); i = j + b.utf8.count; continue }
            if let t = name(at: j, inline) { out += Array((closing ? "</span" : "<span").utf8); i = j + t.utf8.count; continue }
            out.append(src[i]); i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }

    static func convert(html: String, baseURL: URL?) -> Result {
        let sp = Signposts.begin("html", "\(html.utf8.count) bytes"); defer { Signposts.end("html", sp) }
        if Task.isCancelled { return Result(title: nil, markdown: "") }
        let cleaned = preprocess(html)
        guard let doc = try? XMLDocument(xmlString: cleaned, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            return Result(title: nil, markdown: stripTags(html))
        }
        let title = (try? doc.nodes(forXPath: "//title").first).flatMap { $0 }.map { plainText($0, cap: 1000) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer the main content region (simple readability heuristic).
        var root: XMLNode? = nil
        for xp in ["//*[@id='mw-content-text']", "//*[@data-h5='article']", "//*[@data-h5='main']", "//*[@role='main']", "//*[@id='content']", "//*[@id='main-content']", "//body"] {
            if let nodes = try? doc.nodes(forXPath: xp),
               let best = nodes.map({ ($0, textLength($0, cap: 2_000_000)) }).max(by: { $0.1 < $1.1 }),
               best.1 > 200 || xp == "//body" {
                root = best.0; break
            }
        }
        guard let root else { return Result(title: title, markdown: "") }
        var ctx = Ctx(base: baseURL, dropChrome: root.name?.lowercased() == "body")
        var out = ""
        autoreleasepool { render(root, &out, &ctx) }
        return Result(title: title, markdown: tidy(out))
    }

    private struct Ctx {
        var base: URL?
        var dropChrome: Bool
        var listStack: [(ordered: Bool, index: Int)] = []
        var inPre = false
        var lastTex = ""
        var depth = 0, visited = 0, emitted = 0
        /// Set when the output budget is spent or the task was cancelled (the tool's deadline passed).
        var stop = false
    }

    /// Children in order, each in its own autorelease pool so Foundation temporaries don't pile up on a big page.
    private static func renderChildren(_ node: XMLNode, _ out: inout String, _ ctx: inout Ctx) {
        for c in node.children ?? [] where !ctx.stop { autoreleasepool { render(c, &out, &ctx) } }
    }

    /// Appends text within the page budget.
    private static func emit(_ t: String, _ out: inout String, _ ctx: inout Ctx) {
        let room = maxOutput - ctx.emitted
        if t.utf8.count <= room { out += t; ctx.emitted += t.utf8.count; return }
        out += t.prefix(max(0, room)); ctx.emitted = maxOutput; ctx.stop = true
    }

    /// A subtree's raw text, iteratively and capped. `XMLNode.stringValue` builds a string per level: O(text × depth), 1.5 GB on a deep page.
    static func plainText(_ node: XMLNode, cap: Int = maxOutput) -> String {
        var r = "", stack = [node]
        while r.utf8.count < cap, let n = stack.popLast() {
            if n.kind == .text { r += n.stringValue ?? "" } else if let kids = n.children { stack.append(contentsOf: kids.reversed()) }
        }
        return r.utf8.count > cap ? String(r.prefix(cap)) : r
    }

    private static func textLength(_ node: XMLNode, cap: Int) -> Int {
        var total = 0, stack = [node]
        while total < cap, let n = stack.popLast() {
            if n.kind == .text { total += n.stringValue?.utf8.count ?? 0 } else if let kids = n.children { stack.append(contentsOf: kids) }
        }
        return total
    }

    /// A subtree's text, depth-first with an explicit stack.
    private static func flatText(_ node: XMLNode, _ out: inout String, _ ctx: inout Ctx) {
        var stack = [node]
        while !ctx.stop, let n = stack.popLast() {
            ctx.visited += 1
            if ctx.visited % 256 == 0 && Task.isCancelled { ctx.stop = true }
            if n.kind == .text {
                var t = collapseWhitespace(n.stringValue ?? "")
                if out.hasSuffix(" ") || out.hasSuffix("\n") || out.isEmpty { while t.hasPrefix(" ") { t.removeFirst() } }
                emit(t, &out, &ctx)
            } else if let el = n as? XMLElement, skipTags.contains((el.name ?? "").lowercased()) {
                continue
            } else if let kids = n.children {
                stack.append(contentsOf: kids.reversed())
            }
        }
    }

    /// Runs of whitespace (and no-break spaces) become one space. A plain scan: a regex per text node was the converter's main cost.
    static func collapseWhitespace(_ s: String) -> String {
        var r = ""; r.reserveCapacity(s.utf8.count)
        var space = false
        for u in s.unicodeScalars {
            if u.properties.isWhitespace || u == "\u{00A0}" {
                if !space { r.unicodeScalars.append(" "); space = true }
            } else { r.unicodeScalars.append(u); space = false }
        }
        return r
    }

    private static func render(_ node: XMLNode, _ out: inout String, _ ctx: inout Ctx) {
        if ctx.stop { return }
        ctx.visited += 1
        if ctx.visited % 256 == 0 && Task.isCancelled { ctx.stop = true; return }
        if node.kind == .text {
            var t = node.stringValue ?? ""
            if !ctx.inPre {
                t = collapseWhitespace(t)
                if out.hasSuffix(" ") || out.hasSuffix("\n") || out.isEmpty { while t.hasPrefix(" ") { t.removeFirst() } }
                t = escapeMarkdown(t)
            }
            emit(t, &out, &ctx)
            return
        }
        guard let el = node as? XMLElement else { renderChildren(node, &out, &ctx); return }
        var tag = (el.name ?? "").lowercased()
        if let h5 = el.attribute(forName: "data-h5")?.stringValue { tag = h5 == "summary" || h5 == "details" ? "p" : (chromeTags.contains(h5) ? h5 : "div") }
        if skipTags.contains(tag) { return }
        if chromeTags.contains(tag) && (ctx.dropChrome || tag == "nav") { return }
        if el.attribute(forName: "data-tex") != nil {
            let t = Self.unwrapDisplayStyle(plainText(el).trimmingCharacters(in: .whitespacesAndNewlines))
            ctx.lastTex = t
            out += (el.attribute(forName: "display")?.stringValue == "block") ? "\n$$\(t)$$\n" : "$\(t)$"
            return
        }
        if let cls = el.attribute(forName: "class")?.stringValue?.lowercased(),
           ["mw-editsection", "navbox", "reflist", "sidebar", "cookie", "advert", "share", "noprint", "mw-jump-link",
             "interlanguage", "vector-", "mw-portlet", "catlinks", "printfooter", "mw-indicator", "navbar", "toc", "breadcrumb", "skip-link", "banner", "newsletter", "related-posts",
             "hatnote", "ambox", "mw-empty-elt"].contains(where: { cls.contains($0) }) {
            return
        }
        if el.attribute(forName: "hidden") != nil || (el.attribute(forName: "aria-hidden")?.stringValue == "true" && tag != "span") { return }
        if ctx.depth >= maxDepth { flatText(el, &out, &ctx); out += " "; return }
        ctx.depth += 1
        defer { ctx.depth -= 1 }

        func children() { renderChildren(el, &out, &ctx) }
        func block(_ body: () -> Void) { ensureBlank(&out); body(); ensureBlank(&out) }

        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!)) ?? 2
            block {
                out += String(repeating: "#", count: level) + " "
                var inner = ""; renderChildren(el, &inner, &ctx)
                out += inner.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }
        case "br": out += "  \n"
        case "hr": block { out += "---" }
        case "p": block { children() }
        case _ where blockTags.contains(tag):
            ensureNewline(&out); children(); ensureNewline(&out)
        case "strong", "b":
            var inner = ""; renderChildren(el, &inner, &ctx)
            let t = inner.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out += "**\(t)** " }
        case "em", "i":
            var inner = ""; renderChildren(el, &inner, &ctx)
            let t = inner.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out += "*\(t)* " }
        case "code", "kbd", "samp":
            if ctx.inPre { children() } else {
                let t = plainText(el).trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { emit("`\(t)`", &out, &ctx) }
            }
        case "pre":
            block {
                let lang = (el.elements(forName: "code").first?.attribute(forName: "class")?.stringValue
                            ?? el.attribute(forName: "class")?.stringValue ?? "")
                    .components(separatedBy: .whitespaces).first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
                    .map { $0.replacingOccurrences(of: "language-", with: "").replacingOccurrences(of: "lang-", with: "") } ?? ""
                emit("```\(lang)\n" + plainText(el).trimmingCharacters(in: .newlines) + "\n```", &out, &ctx)
            }
        case "a":
            var inner = ""; renderChildren(el, &inner, &ctx)
            let text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = el.attribute(forName: "href")?.stringValue, !href.hasPrefix("javascript:"), !href.hasPrefix("#"), !text.isEmpty,
               let url = URL(string: href, relativeTo: ctx.base)?.absoluteURL {
                // Parentheses in an address (Wikipedia's "Recursion_(computer_science)") would end a Markdown link early.
                out += "[\(text)](\(url.absoluteString.replacingOccurrences(of: "(", with: "%28").replacingOccurrences(of: ")", with: "%29")))"
            } else { out += text }
        case "img":
            let cls = el.attribute(forName: "class")?.stringValue ?? ""
            if let alt = el.attribute(forName: "alt")?.stringValue, !alt.isEmpty {
                if cls.contains("mwe-math") {
                    let tex = Self.unwrapDisplayStyle(alt)
                    if tex != ctx.lastTex { out += "$\(tex)$" }
                    ctx.lastTex = ""
                } else if alt.count < 200 { out += "[image: \(alt)]" }
            }
        case "ul", "ol":
            block {
                ctx.listStack.append((tag == "ol", 0))
                children()
                ctx.listStack.removeLast()
            }
        case "li":
            ensureNewline(&out)
            let depth = max(0, ctx.listStack.count - 1)
            var marker = "- "
            if var top = ctx.listStack.last, top.ordered {
                top.index += 1; ctx.listStack[ctx.listStack.count - 1] = top; marker = "\(top.index). "
            }
            out += String(repeating: "  ", count: depth) + marker
            var inner = ""; renderChildren(el, &inner, &ctx)
            out += inner.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n\n", with: "\n")
            ensureNewline(&out)
        case "blockquote":
            block {
                var inner = ""; renderChildren(el, &inner, &ctx)
                out += tidy(inner).split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            }
        case "table": block { out += table(el, &ctx) }
        case "math":
            let tex = (try? el.nodes(forXPath: ".//*[local-name()='annotation'][@encoding='application/x-tex']").first?.stringValue)
                ?? el.attribute(forName: "alttext")?.stringValue
            if let tex { let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
                out += (el.attribute(forName: "display")?.stringValue == "block") ? "\n$$\(t)$$\n" : "$\(t)$" }
            else { emit(plainText(el), &out, &ctx) }
        case "sup": var inner = ""; renderChildren(el, &inner, &ctx); out += "^\(inner)"
        default: children()
        }
    }

    static func unwrapDisplayStyle(_ s: String) -> String {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.hasPrefix("{\\displaystyle"), t.hasSuffix("}") {
            t = String(t.dropFirst("{\\displaystyle".count).dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return t
    }

    private static func table(_ el: XMLElement, _ ctx: inout Ctx) -> String {
        guard let rows = try? el.nodes(forXPath: ".//tr") as? [XMLElement], !rows.isEmpty else { return "" }
        var grid: [[String]] = []
        for r in rows.prefix(200) {
            let cells = (r.children ?? []).compactMap { $0 as? XMLElement }.filter { ["td", "th"].contains($0.name?.lowercased() ?? "") }
            grid.append(cells.map { c in
                var s = ""; let lists = ctx.listStack; ctx.listStack = []
                renderChildren(c, &s, &ctx)
                ctx.listStack = lists
                return tidy(s).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
            })
        }
        // Rows with no text (an infobox's spacers) say nothing.
        grid = grid.enumerated().filter { $0.offset == 0 || $0.element.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty } }.map(\.element)
        let cols = grid.map(\.count).max() ?? 0
        guard cols > 0 else { return "" }
        var md = ""
        for (i, row) in grid.enumerated() {
            md += "| " + (row + Array(repeating: "", count: cols - row.count)).joined(separator: " | ") + " |\n"
            if i == 0 { md += "|" + String(repeating: " --- |", count: cols) + "\n" }
        }
        return md
    }

    private static func ensureNewline(_ s: inout String) { if !s.isEmpty && !s.hasSuffix("\n") { trimTrailingSpaces(&s); s += "\n" } }
    private static func ensureBlank(_ s: inout String) {
        guard !s.isEmpty else { return }
        trimTrailingSpaces(&s)
        if s.hasSuffix("\n\n") { return }
        s += s.hasSuffix("\n") ? "\n" : "\n\n"
    }
    private static func trimTrailingSpaces(_ s: inout String) { while s.hasSuffix(" ") { s.removeLast() } }

    private static func escapeMarkdown(_ s: String) -> String { s }

    static func tidy(_ s: String) -> String {
        s.replacingOccurrences(of: "[ \\t]+\\n", with: "\n", options: .regularExpression)
            .replacingOccurrences(of: "\\n{3,}", with: "\n\n", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func stripTags(_ s: String) -> String {
        decodeEntities(s.replacingOccurrences(of: "<[^>]+>", with: "", options: .regularExpression))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        var r = s
        let named = ["&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'", "&nbsp;": " ",
                     "&ndash;": "–", "&mdash;": "—", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&ldquo;": "“", "&rdquo;": "”"]
        for (k, v) in named { r = r.replacingOccurrences(of: k, with: v) }
        let re = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        let ns = r as NSString
        var result = ""
        var last = 0
        for m in re.matches(in: r, range: NSRange(location: 0, length: ns.length)) {
            result += ns.substring(with: NSRange(location: last, length: m.range.location - last))
            let hex = ns.substring(with: m.range(at: 1)) == "x"
            let num = ns.substring(with: m.range(at: 2))
            if let code = UInt32(num, radix: hex ? 16 : 10), let u = Unicode.Scalar(code) { result.unicodeScalars.append(u) }
            last = m.range.location + m.range.length
        }
        result += ns.substring(from: last)
        return result
    }
}
