import Foundation
import PDFKit

struct SearchResult: Sendable, Hashable {
    var title: String
    var url: String
    var snippet: String
    var source: String
    var date: String?
}

/// Free, keyless live web search: DuckDuckGo HTML + Bing RSS in parallel (Brave HTML as a fallback), merged and deduplicated.
enum WebSearch {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"

    static func search(_ query: String, kind: String = "web", limit: Int = 10) async -> (results: [SearchResult], errors: [String]) {
        if kind == "news" {
            let r = await bingRSS(query, news: true)
            return (Array((r.0).prefix(limit)), r.1.map { [$0] } ?? [])
        }
        async let ddg = duckDuckGo(query)
        async let bing = bingRSS(query, news: false)
        let (d, b) = await (ddg, bing)
        var errors = [d.1, b.1].compactMap { $0 }
        var lists = [d.0, b.0]
        if d.0.isEmpty && b.0.isEmpty {
            let br = await brave(query)
            lists.append(br.0)
            if let e = br.1 { errors.append(e) }
        }
        // Interleave engines, dedupe by normalised URL.
        var seen = Set<String>()
        var merged: [SearchResult] = []
        let maxLen = lists.map(\.count).max() ?? 0
        for i in 0..<maxLen {
            for list in lists where i < list.count {
                let key = normalize(list[i].url)
                if seen.insert(key).inserted { merged.append(list[i]) }
            }
        }
        return (Array(merged.prefix(limit)), errors)
    }

    static func normalize(_ url: String) -> String {
        var u = url.lowercased()
        for p in ["https://", "http://", "www."] where u.hasPrefix(p) { u.removeFirst(p.count) }
        if let q = u.firstIndex(of: "#") { u = String(u[..<q]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    private static func fetch(_ req: URLRequest) async throws -> String {
        var r = req
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.timeoutInterval = 12
        let (data, resp) = try await URLSession.shared.data(for: r)
        let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
        guard code == 200 else { throw ToolError("HTTP \(code)") }
        return String(decoding: data, as: UTF8.self)
    }

    static func duckDuckGo(_ q: String) async -> ([SearchResult], String?) {
        var req = URLRequest(url: URL(string: "https://html.duckduckgo.com/html/")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Data("q=\(q.formEncoded)&kl=us-en".utf8)
        do {
            let html = try await fetch(req)
            var out: [SearchResult] = []
            for block in html.components(separatedBy: "class=\"result results_links").dropFirst() {
                if block.contains("result--ad") { continue }
                guard let a = block.firstMatch(#"class="result__a"[^>]*href="([^"]+)"[^>]*>([\s\S]*?)</a>"#)
                        ?? block.firstMatch(#"href="([^"]+)"[^>]*class="result__a"[^>]*>([\s\S]*?)</a>"#) else { continue }
                var href = HTMLToMarkdown.decodeEntities(a[0])
                if href.contains("uddg="), let comps = URLComponents(string: href.hasPrefix("//") ? "https:" + href : href),
                   let target = comps.queryItems?.first(where: { $0.name == "uddg" })?.value { href = target }
                if href.contains("duckduckgo.com/y.js") { continue }
                let snippet = block.firstMatch(#"class="result__snippet"[^>]*>([\s\S]*?)</a>"#)?[0] ?? ""
                out.append(SearchResult(title: HTMLToMarkdown.stripTags(a[1]), url: href, snippet: HTMLToMarkdown.stripTags(snippet), source: "DuckDuckGo"))
            }
            return (out, out.isEmpty ? "DuckDuckGo returned no results" : nil)
        } catch { return ([], "DuckDuckGo: \(error.localizedDescription)") }
    }

    static func bingRSS(_ q: String, news: Bool) async -> ([SearchResult], String?) {
        let base = news ? "https://www.bing.com/news/search" : "https://www.bing.com/search"
        guard let url = URL(string: "\(base)?q=\(q.formEncoded)&format=rss&count=15&setlang=en-US") else { return ([], "bad query") }
        do {
            let xml = try await fetch(URLRequest(url: url))
            let doc = try XMLDocument(xmlString: xml, options: [])
            var out: [SearchResult] = []
            for item in (try doc.nodes(forXPath: "//item")) {
                guard let el = item as? XMLElement else { continue }
                func text(_ n: String) -> String { el.elements(forName: n).first?.stringValue ?? "" }
                var link = text("link")
                if news, let comps = URLComponents(string: link), let u = comps.queryItems?.first(where: { $0.name == "url" })?.value { link = u }
                out.append(SearchResult(title: text("title"), url: link, snippet: HTMLToMarkdown.stripTags(text("description")),
                                        source: news ? "Bing News" : "Bing", date: text("pubDate").isEmpty ? nil : text("pubDate")))
            }
            return (out, out.isEmpty ? "Bing returned no results" : nil)
        } catch { return ([], "Bing: \(error.localizedDescription)") }
    }

    static func brave(_ q: String) async -> ([SearchResult], String?) {
        guard let url = URL(string: "https://search.brave.com/search?q=\(q.formEncoded)&source=web") else { return ([], nil) }
        do {
            let html = try await fetch(URLRequest(url: url))
            var out: [SearchResult] = []
            for block in html.components(separatedBy: "data-type=\"web\"").dropFirst().prefix(15) {
                guard let href = block.firstMatch(#"<a[^>]*href="(https?://[^"]+)""#)?[0] else { continue }
                let title = block.firstMatch(#"class="[^"]*title[^"]*"[^>]*>([\s\S]*?)</div>"#)?[0] ?? href
                let snip = block.firstMatch(#"class="[^"]*(?:snippet-description|content)[^"]*"[^>]*>([\s\S]*?)</div>"#)?[0] ?? ""
                out.append(SearchResult(title: HTMLToMarkdown.stripTags(title), url: HTMLToMarkdown.decodeEntities(href),
                                        snippet: HTMLToMarkdown.stripTags(snip), source: "Brave"))
            }
            return (out, out.isEmpty ? "Brave returned no results" : nil)
        } catch { return ([], "Brave: \(error.localizedDescription)") }
    }
}

struct WebSearchTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { 30 }
    let name = "web_search"
    let description = """
    Search the live web (free; DuckDuckGo + Bing, merged). Returns titles, URLs and snippets. Use for current events, \
    facts you are unsure about, documentation, and finding sources to cite. Follow up with `web_fetch` to read a page. \
    Set kind="news" for recent news. Cite sources as markdown links.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "query": Schema.string("Search query."),
            "kind": Schema.string("web (default) or news.", enum: ["web", "news"]),
            "max_results": Schema.integer("1-20 (default 8)."),
        ], required: ["query"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let q = try input.req("query")
        let n = min(20, max(1, input["max_results"]?.int ?? 8))
        let (results, errors) = await WebSearch.search(q, kind: input["kind"]?.string ?? "web", limit: n)
        if results.isEmpty { return .error("No results for \"\(q)\". \(errors.joined(separator: "; "))") }
        var text = "Search results for \"\(q)\":\n"
        for (i, r) in results.enumerated() {
            text += "\n\(i + 1). \(r.title)\n   \(r.url)\n"
            if let d = r.date { text += "   (\(d))\n" }
            if !r.snippet.isEmpty { text += "   \(r.snippet)\n" }
        }
        let meta: JSON = .object(["results": .array(results.map { ["title": .string($0.title), "url": .string($0.url), "snippet": .string($0.snippet), "source": .string($0.source)] })])
        return ToolOutput(text: text, meta: meta)
    }
}

/// Converted pages for 15 minutes (paging through a long one re-reads it), bounded by size, oldest out first.
actor FetchCache {
    static let shared = FetchCache()
    static let maxChars = 4_000_000
    private var store: [String: (Date, String, String?)] = [:]
    private var chars = 0
    func get(_ k: String) -> (String, String?)? {
        guard let v = store[k], Date().timeIntervalSince(v.0) < 900 else { return nil }
        return (v.1, v.2)
    }
    func put(_ k: String, _ md: String, _ title: String?) {
        if let old = store.removeValue(forKey: k) { chars -= old.1.utf8.count }
        while chars + md.utf8.count > Self.maxChars, let oldest = store.min(by: { $0.value.0 < $1.value.0 }) {
            chars -= oldest.value.1.utf8.count; store[oldest.key] = nil
        }
        store[k] = (Date(), md, title); chars += md.utf8.count
    }
    func clear() { store = [:]; chars = 0 }
}

struct WebFetchTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { 40 }
    let name = "web_fetch"
    let description = """
    Fetch a URL and return its main content as Markdown (HTML is cleaned; PDFs are converted to text; images are shown). \
    Long pages are paginated: pass `start_index` to continue. Use after web_search, or when the learner shares a link.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "url": Schema.string("http(s) URL."),
            "start_index": Schema.integer("Character offset to start from (default 0)."),
            "max_length": Schema.integer("Max characters to return (default 40000)."),
        ], required: ["url"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        var raw = try input.req("url")
        if !raw.hasPrefix("http") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme) else { return .error("Invalid URL.") }
        let start = max(0, input["start_index"]?.int ?? 0)
        let maxLen = min(100_000, max(1000, input["max_length"]?.int ?? 40_000))
        let md: String, title: String?
        if let cached = await FetchCache.shared.get(url.absoluteString) {
            (md, title) = cached
        } else {
            var req = URLRequest(url: url)
            req.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
            req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
            req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
            req.timeoutInterval = 25
            let (data, resp) = try await URLSession.shared.data(for: req)
            let http = resp as? HTTPURLResponse
            let code = http?.statusCode ?? 0
            if code >= 400 { return .error("HTTP \(code) fetching \(url.absoluteString)") }
            let ct = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            let finalURL = resp.url ?? url
            if ct.contains("image/") {
                guard let img = ImageUtil.loadForModel(data: data, name: finalURL.lastPathComponent) else { return .error("Could not decode image.") }
                return ToolOutput(text: "Image from \(finalURL.absoluteString) (\(img.width)×\(img.height))", images: [img.block])
            }
            if ct.contains("pdf") || finalURL.pathExtension.lowercased() == "pdf" {
                guard let doc = PDFDocument(data: data) else { return .error("Could not read PDF.") }
                var t = ""
                for i in 0..<min(doc.pageCount, 80) { t += "\n--- Page \(i + 1) ---\n" + (doc.page(at: i)?.string ?? "") }
                (md, title) = (t, doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
            } else if ct.contains("html") || ct.isEmpty || ct.contains("xml") {
                let html = String(decoding: data.prefix(6_000_000), as: UTF8.self)
                let r = HTMLToMarkdown.convert(html: html, baseURL: finalURL)
                try Task.checkCancellation()  // a conversion cut short by the deadline is partial: don't cache it
                (md, title) = (r.markdown, r.title)
            } else {
                (md, title) = (String(decoding: data.prefix(3_000_000), as: UTF8.self), nil)
            }
            await FetchCache.shared.put(url.absoluteString, md, title)
        }
        guard !md.isEmpty else { return .error("The page had no readable content (it may require JavaScript).") }
        let chars = Array(md)
        guard start < chars.count else { return .error("start_index beyond content length (\(chars.count)).") }
        let end = min(chars.count, start + maxLen)
        var text = (title.map { "# \($0)\n" } ?? "") + "Source: \(url.absoluteString)\n\n" + String(chars[start..<end])
        if end < chars.count { text += "\n\n[Content truncated: \(chars.count - end) more characters. Call again with start_index=\(end).]" }
        return ToolOutput(text: text, meta: ["url": .string(url.absoluteString), "title": .string(title ?? "")])
    }
}

extension String {
    var formEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._*")
        return (addingPercentEncoding(withAllowedCharacters: allowed) ?? self).replacingOccurrences(of: "%20", with: "+")
    }

    /// Returns capture groups of the first regex match.
    func firstMatch(_ pattern: String) -> [String]? {
        guard let re = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let ns = self as NSString
        guard let m = re.firstMatch(in: self, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return (1..<m.numberOfRanges).map { m.range(at: $0).location == NSNotFound ? "" : ns.substring(with: m.range(at: $0)) }
    }
}
