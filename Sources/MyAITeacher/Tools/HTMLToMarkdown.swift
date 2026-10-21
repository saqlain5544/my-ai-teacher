import Foundation

/// Converts HTML to readable Markdown using Foundation's built-in tidy HTML parser (no dependencies).
enum HTMLToMarkdown {
    struct Result { var title: String?; var markdown: String }

    private static let skipTags: Set<String> = ["script", "style", "noscript", "svg", "iframe", "form", "button", "input",
                                                "select", "textarea", "template", "canvas", "object", "embed", "link", "meta"]
    private static let chromeTags: Set<String> = ["nav", "footer", "aside", "header"]
    private static let blockTags: Set<String> = ["p", "div", "section", "article", "main", "figure", "figcaption", "dl", "dt", "dd",
                                                 "address", "center", "details", "summary", "hgroup"]

    /// Foundation's tidy parser drops unknown (HTML5) elements, so map them to divs/spans first,
    /// and lift TeX out of MathML annotations.
    static func preprocess(_ html: String) -> String {
        var s = html.replacingOccurrences(of: "<!--[\\s\\S]*?-->", with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(script|style|noscript|svg|template)\\b[\\s\\S]*?</\\1>", with: "", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<math\\b([^>]*)>[\\s\\S]*?<annotation[^>]*encoding=\"application/x-tex\"[^>]*>([\\s\\S]*?)</annotation>[\\s\\S]*?</math>",
                                   with: "<span data-tex=\"1\"$1>$2</span>", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "<math\\b[\\s\\S]*?</math>", with: "", options: [.regularExpression, .caseInsensitive])
        let blocks = "article|main|nav|footer|aside|header|section|figure|figcaption|details|summary|hgroup|address|search|dialog"
        s = s.replacingOccurrences(of: "<(\\/?)(\(blocks))\\b", with: "<$1div data-h5=\"$2\"", options: [.regularExpression, .caseInsensitive])
        s = s.replacingOccurrences(of: "</div data-h5=\"[a-z]+\"", with: "</div", options: .regularExpression)
        s = s.replacingOccurrences(of: "<(\\/?)(mark|time|picture|data|bdi|output)\\b", with: "<$1span", options: [.regularExpression, .caseInsensitive])
        return s
    }

    static func convert(html: String, baseURL: URL?) -> Result {
        let cleaned = preprocess(html)
        guard let doc = try? XMLDocument(xmlString: cleaned, options: [.documentTidyHTML, .nodeLoadExternalEntitiesNever]) else {
            return Result(title: nil, markdown: stripTags(html))
        }
        let title = (try? doc.nodes(forXPath: "//title").first?.stringValue)?.trimmingCharacters(in: .whitespacesAndNewlines)
        // Prefer the main content region (simple readability heuristic).
        var root: XMLNode? = nil
        for xp in ["//*[@id='mw-content-text']", "//*[@data-h5='article']", "//*[@data-h5='main']", "//*[@role='main']", "//*[@id='content']", "//*[@id='main-content']", "//body"] {
            if let nodes = try? doc.nodes(forXPath: xp), let best = nodes.max(by: { ($0.stringValue?.count ?? 0) < ($1.stringValue?.count ?? 0) }),
               (best.stringValue?.count ?? 0) > 200 || xp == "//body" {
                root = best; break
            }
        }
        guard let root else { return Result(title: title, markdown: "") }
        var ctx = Ctx(base: baseURL, dropChrome: root.name?.lowercased() == "body")
        var out = ""
        render(root, &out, &ctx)
        return Result(title: title, markdown: tidy(out))
    }

    private struct Ctx {
        var base: URL?
        var dropChrome: Bool
        var listStack: [(ordered: Bool, index: Int)] = []
        var inPre = false
        var lastTex = ""
    }

    private static func render(_ node: XMLNode, _ out: inout String, _ ctx: inout Ctx) {
        if node.kind == .text {
            var t = node.stringValue ?? ""
            if !ctx.inPre {
                t = t.replacingOccurrences(of: "[\\s\\u00A0]+", with: " ", options: .regularExpression)
                if out.hasSuffix(" ") || out.hasSuffix("\n") || out.isEmpty { while t.hasPrefix(" ") { t.removeFirst() } }
                t = escapeMarkdown(t)
            }
            out += t
            return
        }
        guard let el = node as? XMLElement else { node.children?.forEach { render($0, &out, &ctx) }; return }
        var tag = (el.name ?? "").lowercased()
        if let h5 = el.attribute(forName: "data-h5")?.stringValue { tag = h5 == "summary" || h5 == "details" ? "p" : (chromeTags.contains(h5) ? h5 : "div") }
        if skipTags.contains(tag) { return }
        if chromeTags.contains(tag) && (ctx.dropChrome || tag == "nav") { return }
        if el.attribute(forName: "data-tex") != nil {
            let t = Self.unwrapDisplayStyle((el.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            ctx.lastTex = t
            out += (el.attribute(forName: "display")?.stringValue == "block") ? "\n$$\(t)$$\n" : "$\(t)$"
            return
        }
        if let cls = el.attribute(forName: "class")?.stringValue?.lowercased(),
           ["mw-editsection", "navbox", "reflist", "sidebar", "cookie", "advert", "share", "noprint", "mw-jump-link",
             "interlanguage", "vector-", "mw-portlet", "catlinks", "printfooter", "mw-indicator", "navbar", "toc", "breadcrumb", "skip-link", "banner", "newsletter", "related-posts"].contains(where: { cls.contains($0) }) {
            return
        }
        if el.attribute(forName: "hidden") != nil || (el.attribute(forName: "aria-hidden")?.stringValue == "true" && tag != "span") { return }

        func children() { el.children?.forEach { render($0, &out, &ctx) } }
        func block(_ body: () -> Void) { ensureBlank(&out); body(); ensureBlank(&out) }

        switch tag {
        case "h1", "h2", "h3", "h4", "h5", "h6":
            let level = Int(String(tag.last!)) ?? 2
            block {
                out += String(repeating: "#", count: level) + " "
                var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }
                out += inner.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
            }
        case "br": out += "  \n"
        case "hr": block { out += "---" }
        case "p": block { children() }
        case _ where blockTags.contains(tag):
            ensureNewline(&out); children(); ensureNewline(&out)
        case "strong", "b":
            var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }
            let t = inner.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out += "**\(t)** " }
        case "em", "i":
            var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }
            let t = inner.trimmingCharacters(in: .whitespaces)
            if !t.isEmpty { out += "*\(t)* " }
        case "code", "kbd", "samp":
            if ctx.inPre { children() } else {
                let t = (el.stringValue ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                if !t.isEmpty { out += "`\(t)`" }
            }
        case "pre":
            block {
                let lang = (el.elements(forName: "code").first?.attribute(forName: "class")?.stringValue
                            ?? el.attribute(forName: "class")?.stringValue ?? "")
                    .components(separatedBy: .whitespaces).first { $0.hasPrefix("language-") || $0.hasPrefix("lang-") }
                    .map { $0.replacingOccurrences(of: "language-", with: "").replacingOccurrences(of: "lang-", with: "") } ?? ""
                out += "```\(lang)\n" + (el.stringValue ?? "").trimmingCharacters(in: .newlines) + "\n```"
            }
        case "a":
            var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }
            let text = inner.trimmingCharacters(in: .whitespacesAndNewlines)
            if let href = el.attribute(forName: "href")?.stringValue, !href.hasPrefix("javascript:"), !href.hasPrefix("#"), !text.isEmpty,
               let url = URL(string: href, relativeTo: ctx.base)?.absoluteURL {
                out += "[\(text)](\(url.absoluteString))"
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
            var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }
            out += inner.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n\n", with: "\n")
            ensureNewline(&out)
        case "blockquote":
            block {
                var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }
                out += tidy(inner).split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n")
            }
        case "table": block { out += table(el, &ctx) }
        case "math":
            let tex = (try? el.nodes(forXPath: ".//*[local-name()='annotation'][@encoding='application/x-tex']").first?.stringValue)
                ?? el.attribute(forName: "alttext")?.stringValue
            if let tex { let t = tex.trimmingCharacters(in: .whitespacesAndNewlines)
                out += (el.attribute(forName: "display")?.stringValue == "block") ? "\n$$\(t)$$\n" : "$\(t)$" }
            else { out += el.stringValue ?? "" }
        case "sup": var inner = ""; el.children?.forEach { render($0, &inner, &ctx) }; out += "^\(inner)"
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
                var s = ""; var sub = ctx; sub.listStack = []
                c.children?.forEach { render($0, &s, &sub) }
                return tidy(s).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "\\|")
            })
        }
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
