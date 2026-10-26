import Foundation
import PDFKit

struct SearchResult: Sendable, Hashable {
    var title: String
    var url: String
    var snippet: String
    var source: String
    var date: String?
}

/// Free, keyless live web search: DuckDuckGo HTML + Bing RSS in parallel (Brave HTML as a fallback), ranked together.
enum WebSearch {
    static let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15"
    /// Once one engine has answered, how long the other gets: a slow engine (DuckDuckGo sometimes takes seconds) must not
    /// hold up results that are already in hand.
    static let grace: Double = 1.5

    static func search(_ query: String, kind: String = "web", limit: Int = 10) async -> (results: [SearchResult], errors: [String]) {
        let key = kind + "|" + query.lowercased().trimmingCharacters(in: .whitespaces)
        if let hit = await SearchCache.shared.get(key) { return (Array(hit.prefix(limit)), []) }
        if kind == "news" {
            let r = await bingRSS(query, news: true)
            let ranked = rank([r.0], query: query)
            if !ranked.isEmpty { await SearchCache.shared.put(key, ranked); return (Array(ranked.prefix(limit)), []) }
            // Bing News has nothing for many specific queries (quoted names, a year): the web usually does.
        }
        var answers = await firstAnswers(query)
        if answers.allSatisfy({ $0.0.isEmpty }) { answers.append(await brave(query)) }
        let ranked = rank(answers.map(\.0), query: query)
        if !ranked.isEmpty { await SearchCache.shared.put(key, ranked) }
        return (Array(ranked.prefix(limit)), ranked.isEmpty ? answers.compactMap(\.1) : [])
    }

    /// DuckDuckGo and Bing together; when one has results, the other has `grace` seconds to join them.
    private static func firstAnswers(_ q: String) async -> [([SearchResult], String?)] {
        await withTaskGroup(of: ([SearchResult], String?)?.self) { g in
            g.addTask { await duckDuckGo(q) }
            g.addTask { await bingRSS(q, news: false) }
            var out: [([SearchResult], String?)] = [], timer = false
            for await r in g {
                guard let r else { break }   // the grace period ran out
                out.append(r)
                if out.count == 2 { break }
                if !r.0.isEmpty && !timer {
                    timer = true
                    g.addTask { try? await Task.sleep(nanoseconds: UInt64(grace * 1e9)); return nil }
                }
            }
            g.cancelAll()
            return out
        }
    }

    /// One list from several engines' lists: reciprocal-rank fusion (a page both engines rank high comes first), scaled
    /// by how many of the query's words its title, address and snippet contain (Bing's feed drops words from the query),
    /// tracking parameters stripped before duplicates are merged, and at most two pages per site ahead of everything else.
    static func rank(_ lists: [[SearchResult]], query: String) -> [SearchResult] {
        let q = Set(Passages.terms(query))
        var best: [String: (r: SearchResult, score: Double, order: Int)] = [:]
        var order = 0
        for list in lists {
            for (i, raw) in list.enumerated() {
                var r = raw
                r.url = clean(r.url)
                r.snippet = clip(r.snippet.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression), 240)
                let key = normalize(r.url)
                let fused = 1.0 / Double(12 + i)
                if var cur = best[key] {
                    cur.score += fused
                    if r.snippet.count > cur.r.snippet.count { cur.r.snippet = r.snippet }
                    best[key] = cur
                } else {
                    best[key] = (r, fused, order); order += 1
                }
            }
        }
        let scored = best.values.map { e -> (SearchResult, Double, Int) in
            guard !q.isEmpty else { return (e.r, e.score, e.order) }
            let title = Set(Passages.terms(e.r.title)), rest = Set(Passages.terms(e.r.snippet + " " + (URL(string: e.r.url)?.path ?? "")))
            let covered = q.filter { title.contains($0) || rest.contains($0) }.count, inTitle = q.filter { title.contains($0) }.count
            let coverage = (Double(covered) + 0.5 * Double(inTitle)) / (1.5 * Double(q.count))
            return (e.r, e.score * (0.25 + 0.75 * coverage), e.order)
        }.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.2 < $1.2 }
        var perSite: [String: Int] = [:], first: [SearchResult] = [], later: [SearchResult] = []
        for (r, _, _) in scored {
            let s = site(URL(string: r.url)?.host ?? r.url)
            perSite[s, default: 0] += 1
            if perSite[s]! <= 2 { first.append(r) } else { later.append(r) }
        }
        return first + later
    }

    static func normalize(_ url: String) -> String {
        var u = url.lowercased()
        for p in ["https://", "http://", "www."] where u.hasPrefix(p) { u.removeFirst(p.count) }
        if let q = u.firstIndex(of: "#") { u = String(u[..<q]) }
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }

    /// The address without its fragment and tracking parameters (utm_*, click ids): shorter to send, and the same page
    /// from two engines merges.
    static func clean(_ raw: String) -> String {
        guard var c = URLComponents(string: raw) else { return raw }
        c.fragment = nil
        if let items = c.queryItems {
            let kept = items.filter { i in let n = i.name.lowercased(); return !(n.hasPrefix("utm_") || ["fbclid", "gclid", "msclkid", "mc_cid", "mc_eid", "ref_src", "srsltid"].contains(n)) }
            c.queryItems = kept.isEmpty ? nil : kept
        }
        return c.string ?? raw
    }

    /// The site a host belongs to, near enough: its last two labels, or three under a country's second level (bbc.co.uk).
    static func site(_ host: String) -> String {
        let labels = host.lowercased().split(separator: ".")
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let n = labels.count, secondLevel = labels[n - 2].count <= 3 && labels[n - 1].count == 2
        return labels.suffix(secondLevel ? 3 : 2).joined(separator: ".")
    }

    /// At most `n` characters, cut at a word.
    static func clip(_ s: String, _ n: Int) -> String {
        guard s.count > n else { return s }
        let cut = s.prefix(n)
        return String(cut.range(of: " ", options: .backwards).map { cut[..<$0.lowerBound] } ?? cut) + "…"
    }

    private static func fetch(_ req: URLRequest) async throws -> String {
        var r = req
        r.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        r.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        r.timeoutInterval = 10
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

/// Recent searches (10 minutes, 200 at most): the same question asked again in a lesson, or by a sub-agent, is answered
/// at once and identically.
actor SearchCache {
    static let shared = SearchCache()
    private var store: [String: (Date, [SearchResult])] = [:]
    func get(_ k: String) -> [SearchResult]? {
        guard let v = store[k], Date().timeIntervalSince(v.0) < 600 else { return nil }
        return v.1
    }
    func put(_ k: String, _ r: [SearchResult]) {
        if store.count >= 200, let oldest = store.min(by: { $0.value.0 < $1.value.0 }) { store[oldest.key] = nil }
        store[k] = (Date(), r)
    }
    func clear() { store = [:] }
}

struct WebSearchTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { 30 }
    let name = "web_search"
    let description = """
    Search the live web. Returns titles, URLs and snippets: for current events, facts you're unsure of, docs, and sources \
    to cite as markdown links.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "query": Schema.string("Search query."),
            "kind": Schema.string("web (default) or news.", enum: ["web", "news"]),
            "max_results": Schema.integer("1-8 (default 6)."),
            "read": Schema.integer("1-3: also the best-matching passages of that many top pages (saves a web_fetch)."),
        ], required: ["query"])
    }
    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        let q = try input.req("query")
        let news = input["kind"]?.string == "news"
        let n = min(8, max(1, input["max_results"]?.int ?? 6))
        let (results, errors) = await WebSearch.search(q, kind: news ? "news" : "web", limit: n)
        if results.isEmpty { return .error("No results for \"\(q)\". \(errors.joined(separator: "; "))") }
        // A page read for its passages skips its snippet in the list (the passages say more).
        let reads = min(3, max(0, input["read"]?.int ?? 0))
        let pages = reads > 0 ? await WebPage.passages(for: Array(results.prefix(reads + 2)).map(\.url), query: q, pages: reads, budget: 1_400) : []
        let read = Set(pages.map(\.url))
        var text = ""
        for (i, r) in results.enumerated() {
            text += "\(i + 1). \(r.title)\n   \(r.url)\n"
            // Bing's dates on ordinary results are crawl dates, not publication dates: only news shows them.
            if news, let d = r.date.flatMap(Self.day) { text += "   \(d)\n" }
            if !r.snippet.isEmpty && !read.contains(r.url) { text += "   \(r.snippet)\n" }
        }
        for p in pages { text += "\n--- \(p.url)\n\(p.text)\n" }
        if reads > 0 && pages.isEmpty { text += "\n(The top results couldn't be read; use web_fetch on one.)\n" }
        let meta: JSON = .object(["results": .array(results.map { ["title": .string($0.title), "url": .string($0.url), "snippet": .string($0.snippet), "source": .string($0.source)] })])
        return ToolOutput(text: text.trimmingCharacters(in: .newlines), meta: meta)
    }

    /// "Sun, 25 Oct 2026 04:26:00 GMT" → "2026-10-25".
    static func day(_ rfc822: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let d = f.date(from: rfc822) else { return nil }
        let out = DateFormatter()
        out.locale = Locale(identifier: "en_US_POSIX"); out.dateFormat = "yyyy-MM-dd"
        return out.string(from: d)
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
        // A page bigger than the whole cache (a large PDF) used to evict every other page and then be kept anyway, over
        // the cap; it isn't cached (a second fetch converts it again).
        guard md.utf8.count <= Self.maxChars else { return }
        while chars + md.utf8.count > Self.maxChars, let oldest = store.min(by: { $0.value.0 < $1.value.0 }) {
            chars -= oldest.value.1.utf8.count; store[oldest.key] = nil
        }
        store[k] = (Date(), md, title); chars += md.utf8.count
    }
    func clear() { store = [:]; chars = 0 }
    var cachedChars: Int { chars }
}

/// A web page as Markdown (HTML cleaned, PDFs as text) or as an image: what `web_fetch`, `web_search`'s `read` and the
/// reading component load, through one cache.
enum WebPage {
    enum Loaded { case text(markdown: String, title: String?), image(ModelImage, URL) }
    struct Read: Sendable { var url: String; var text: String }

    /// The cache key: the address without its fragment (#section is the same page).
    static func key(_ url: URL) -> String {
        guard var c = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        c.fragment = nil
        return c.string ?? url.absoluteString
    }

    static func load(_ url: URL, timeout: Double = 25) async throws -> Loaded {
        if let cached = await FetchCache.shared.get(key(url)) { return .text(markdown: cached.0, title: cached.1) }
        var req = URLRequest(url: url)
        req.setValue(WebSearch.userAgent, forHTTPHeaderField: "User-Agent")
        req.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,text/plain;q=0.8,*/*;q=0.5", forHTTPHeaderField: "Accept")
        req.setValue("en-US,en;q=0.9", forHTTPHeaderField: "Accept-Language")
        req.timeoutInterval = timeout
        let redirects = LocalRedirectGuard(fromLocal: LocalNetwork.isLocal(url.host ?? ""))
        let (data, resp) = try await URLSession.shared.data(for: req, delegate: redirects)
        if let host = redirects.blocked.get() {
            throw ToolError("\(url.absoluteString) redirects to \(host), on this Mac or the local network: not followed. Fetch that address directly if it's wanted (the learner will be asked).")
        }
        let http = resp as? HTTPURLResponse
        let code = http?.statusCode ?? 0
        if code >= 400 { throw ToolError("HTTP \(code) fetching \(url.absoluteString)") }
        let ct = (http?.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let finalURL = resp.url ?? url
        let md: String, title: String?
        if ct.contains("image/") {
            guard let img = ImageUtil.loadForModel(data: data, name: finalURL.lastPathComponent) else { throw ToolError("Could not decode image.") }
            return .image(img, finalURL)
        }
        if ct.contains("pdf") || finalURL.pathExtension.lowercased() == "pdf" {
            guard let doc = PDFDocument(data: data) else { throw ToolError("Could not read PDF.") }
            var t = ""
            for i in 0..<min(doc.pageCount, 80) { t += "\n## Page \(i + 1)\n\n" + (doc.page(at: i)?.string ?? "") }
            (md, title) = (t, doc.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String)
        } else if ct.contains("html") || ct.isEmpty || ct.contains("xml") {
            let r = HTMLToMarkdown.convert(html: String(decoding: data.prefix(6_000_000), as: UTF8.self), baseURL: finalURL)
            try Task.checkCancellation()  // a conversion cut short by the deadline is partial: don't cache it
            (md, title) = (r.markdown, r.title)
        } else {
            (md, title) = (String(decoding: data.prefix(3_000_000), as: UTF8.self), nil)
        }
        await FetchCache.shared.put(key(url), md, title)
        return .text(markdown: md, title: title)
    }

    /// Link targets on the page's own site dropped, text kept: on a Wikipedia article they were 40% of the characters,
    /// and the model follows few of them. Links to other sites (sources, references) keep their address.
    static func compactLinks(_ md: String, site: String) -> (String, Int) {
        let re = try! NSRegularExpression(pattern: #"\[((?:[^\[\]\n]|\[[^\[\]\n]*\])*)\]\((https?://[^\s)]+)\)"#)
        let ns = md as NSString
        var out = "", last = 0, dropped = 0
        for m in re.matches(in: md, range: NSRange(location: 0, length: ns.length)) {
            let target = ns.substring(with: m.range(at: 2))
            guard let host = URL(string: target)?.host, WebSearch.site(host) == site else { continue }
            out += ns.substring(with: NSRange(location: last, length: m.range.location - last)) + ns.substring(with: m.range(at: 1))
            last = m.range.location + m.range.length; dropped += 1
        }
        return (out + ns.substring(from: last), dropped)
    }

    /// The best passages for `query` from the first `pages` of `urls` that load (in parallel, a few seconds each; local
    /// addresses skipped, since reading those needs the learner's approval), in the order given.
    static func passages(for urls: [String], query: String, pages: Int, budget: Int) async -> [Read] {
        let found = await withTaskGroup(of: (Int, Read?).self) { g -> [(Int, Read)] in
            for (i, raw) in urls.enumerated() {
                guard let url = URL(string: raw), let host = url.host, !LocalNetwork.isLocal(host) else { continue }
                g.addTask {
                    guard !(await LocalNetwork.resolvesLocal(host)),
                          case .text(let md, _)? = try? await withDeadline(seconds: 6, { try await load(url, timeout: 6) }) else { return (i, nil) }
                    let picked = Passages.best(compactLinks(md, site: WebSearch.site(host)).0, query: query, budget: budget)
                    return (i, picked.isEmpty ? nil : Read(url: raw, text: Passages.render(picked)))
                }
            }
            var out: [(Int, Read)] = []
            for await (i, r) in g { if let r { out.append((i, r)) } }
            return out
        }
        return found.sorted { $0.0 < $1.0 }.prefix(pages).map(\.1)
    }
}

struct WebFetchTool: Tool {
    var subAgentVariant: Tool? { self }
    func timeout(_ input: JSON) -> Double? { 40 }
    let name = "web_fetch"
    let description = """
    Fetch a URL as Markdown (PDFs as text, images shown). Long pages are paged; the reply lists later sections' start_index.
    """
    let risk = ToolRisk.network
    var schema: JSON {
        Schema.object([
            "url": Schema.string("http(s) URL."),
            "query": Schema.string("Return only the passages matching this (prefer for a specific question)."),
            "start_index": Schema.integer("Character offset (default 0)."),
            "max_length": Schema.integer("Max characters (default 12000; 6000 with query)."),
            "links": Schema.boolean("Keep same-site link URLs (default: text only)."),
        ], required: ["url"])
    }
    /// The URL to fetch ("example.com/x" is https).
    static func url(_ input: JSON) -> URL? {
        guard var raw = input["url"]?.string?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if !raw.hasPrefix("http") { raw = "https://" + raw }
        guard let url = URL(string: raw), let scheme = url.scheme, ["http", "https"].contains(scheme) else { return nil }
        return url
    }
    /// The host when it is this Mac or the local network (the learner's own servers and devices): fetching from there
    /// needs their approval, as the browser's local sites do. A page that tells the agent to fetch from localhost and pass
    /// on what came back is what this stops.
    static func localHost(_ input: JSON) -> String? {
        guard let host = url(input)?.host, LocalNetwork.isLocal(host) else { return nil }
        return host
    }

    func run(_ input: JSON, _ ctx: ToolContext) async throws -> ToolOutput {
        _ = try input.req("url")
        guard let url = Self.url(input) else { return .error("Invalid URL.") }
        // A public name that resolves to a local address is a local fetch: refused here, then asked for like one (the name
        // is remembered as local, so the approval gate sees it next time).
        if let host = url.host, !LocalNetwork.isLocal(host), await LocalNetwork.resolvesLocal(host) {
            return .error("\(host) resolves to an address on this Mac or the local network, so fetching it needs the learner's approval: call web_fetch again and they will be asked.")
        }
        let query = (input["query"]?.string?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
        let start = max(0, input["start_index"]?.int ?? 0)
        let maxLen = min(100_000, max(1000, input["max_length"]?.int ?? (query == nil ? 12_000 : 6_000)))
        let loaded: WebPage.Loaded
        do { loaded = try await WebPage.load(url) } catch let e as ToolError { return .error(e.localizedDescription) }
        guard case .text(var md, let title) = loaded else {
            guard case .image(let img, let finalURL) = loaded else { return .error("Nothing readable at \(url.absoluteString).") }
            return ToolOutput(text: "Image from \(finalURL.absoluteString) (\(img.width)×\(img.height))", images: [img.block])
        }
        guard !md.isEmpty else { return .error("The page had no readable content (it may require JavaScript).") }
        var dropped = 0
        if input["links"]?.bool != true, let host = url.host { (md, dropped) = WebPage.compactLinks(md, site: WebSearch.site(host)) }
        let head = (title.map { "# \($0)\n" } ?? "") + "Source: \(url.absoluteString)\n"
        let meta: JSON = ["url": .string(url.absoluteString), "title": .string(title ?? "")]
        let total = md.count

        if let query, start == 0 {
            let picked = Passages.best(md, query: query, budget: maxLen)
            if !picked.isEmpty {
                return ToolOutput(text: head + "Passages matching \"\(query)\" (\(picked.count) of a \(total)-character page; start_index reads on from one):\n\n"
                                  + Passages.render(picked), meta: meta)
            }
        }
        let chars = Array(md)
        guard start < chars.count else { return .error("start_index beyond content length (\(chars.count)).") }
        let end = min(chars.count, start + maxLen)
        var text = head + (query != nil && start == 0 ? "(Nothing on the page matched \"\(query!)\"; here is its start.)\n" : "") + "\n" + String(chars[start..<end])
        if end < chars.count {
            text += "\n\n[\(chars.count - end) more characters: start_index=\(end) continues."
            let later = Self.sections(md, after: end)
            if !later.isEmpty { text += " Later sections: " + later.joined(separator: " · ") }
            text += "]"
        }
        if dropped > 0 && start == 0 { text += "\n[Addresses of \(dropped) links within the site left out; links=true keeps them.]" }
        return ToolOutput(text: text, meta: meta)
    }

    /// The page's headings after `offset`, with the `start_index` of each (at most 24, top levels first when there are
    /// more), so the model can jump to the part it needs instead of paging through.
    static func sections(_ md: String, after offset: Int) -> [String] {
        var found: [(level: Int, title: String, at: Int)] = []
        var pos = 0, inFence = false
        for line in md.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("```") { inFence.toggle() }
            if !inFence, pos >= offset, line.hasPrefix("#") {
                let level = line.prefix { $0 == "#" }.count
                let title = line.dropFirst(level).trimmingCharacters(in: .whitespaces)
                if (1...4).contains(level), !title.isEmpty { found.append((level, String(title.prefix(80)), pos)) }
            }
            pos += line.count + 1
        }
        var levels = found.map(\.level).sorted()
        while found.filter({ $0.level <= (levels.last ?? 6) }).count > 24, let top = levels.last, top > (levels.first ?? 1) { levels.removeAll { $0 == top } }
        let maxLevel = levels.last ?? 6
        return found.filter { $0.level <= maxLevel }.prefix(24).map { "\($0.title) (\($0.at))" }
    }
}

/// Follows a fetch's redirects, except from a public address into this Mac or the local network: the approval for a local
/// fetch is asked for the URL the agent named, and a redirect would skip it.
private final class LocalRedirectGuard: NSObject, URLSessionTaskDelegate {
    let fromLocal: Bool
    let blocked = Locked<String?>(nil)
    init(fromLocal: Bool) { self.fromLocal = fromLocal }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        if !fromLocal, let host = request.url?.host, LocalNetwork.isLocal(host) { blocked.mutate { $0 = host }; completionHandler(nil) }
        else { completionHandler(request) }
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
