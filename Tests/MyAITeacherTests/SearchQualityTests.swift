import XCTest
@testable import MyAITeacher

/// Web search ranking, the passages a query picks from a page, and what fetch leaves out to keep its reply short.
final class SearchQualityTests: XCTestCase {
    private func r(_ title: String, _ url: String, _ snippet: String = "") -> SearchResult {
        SearchResult(title: title, url: url, snippet: snippet, source: "test")
    }

    func testRankingPrefersAgreementAndTheWholeQuery() {
        // Bing drops "light reactions"; DuckDuckGo keeps it. The page both list, and pages about the whole query, lead.
        let bing = [r("Photosynthesis basics", "https://a.org/photo"), r("Photosynthesis", "https://wiki.org/Photosynthesis?utm_source=bing"),
                    r("Plants", "https://c.org/plants")]
        let ddg = [r("The light reactions of photosynthesis", "https://d.org/light"), r("Photosynthesis", "https://www.wiki.org/Photosynthesis#top")]
        let ranked = WebSearch.rank([ddg, bing], query: "photosynthesis light reactions")
        XCTAssertEqual(ranked.count, 4, "the same page from two engines (tracking and #fragment aside) is one result")
        XCTAssertEqual(ranked.first?.url, "https://d.org/light", "covers every word of the query")
        XCTAssertEqual(ranked.last?.url, "https://c.org/plants", "matches no query word")
        XCTAssertFalse(ranked.contains { $0.url.contains("utm_source") }, "tracking parameters are stripped")
    }

    func testAtMostTwoPagesPerSiteComeFirst() {
        let list = (1...4).map { r("Swift concurrency \($0)", "https://docs.example.com/p\($0)") } + [r("Swift concurrency guide", "https://other.org/guide")]
        let ranked = WebSearch.rank([list], query: "swift concurrency")
        XCTAssertEqual(ranked.prefix(3).filter { $0.url.contains("example.com") }.count, 2)
        XCTAssertEqual(ranked[2].url, "https://other.org/guide", "a third page from one site waits behind other sites")
        XCTAssertEqual(WebSearch.site("news.bbc.co.uk"), "bbc.co.uk")
        XCTAssertEqual(WebSearch.site("en.wikipedia.org"), "wikipedia.org")
    }

    func testPassagesAnswerTheQueryInReadingOrder() {
        let page = """
        Intro paragraph about plants and how they grow in many different places around the world, every day.

        ## Light reactions

        In the light reactions, photosystem II splits water and releases oxygen; the electrons travel down a chain.

        Read more

        ## Calvin cycle

        The Calvin cycle fixes carbon dioxide into sugar using ATP and NADPH made earlier in the chloroplast.

        ## History

        Jan Ingenhousz showed in 1779 that light is needed; this paragraph mentions plants and growth at length too.
        """
        let picked = Passages.best(page, query: "what splits water in photosystem II", budget: 400)
        XCTAssertEqual(picked.count, 1)
        XCTAssertEqual(picked.first?.heading, "Light reactions")
        XCTAssertTrue(picked.first?.text.hasPrefix("In the light reactions") == true)
        let offset = picked.first!.offset
        XCTAssertTrue(String(Array(page)[offset...]).hasPrefix("In the light reactions"), "the offset is where the passage starts")
        XCTAssertTrue(Passages.best(page, query: "quantum chromodynamics", budget: 1000).isEmpty)
        // "Read more" under a matching heading is not an answer.
        XCTAssertFalse(Passages.best(page, query: "light reactions", budget: 5000).contains { $0.text == "Read more" })
        XCTAssertEqual(Passages.terms("Reactions of the light"), ["reaction", "light"])
        XCTAssertEqual(Passages.terms("光合作用"), ["光合", "合作", "作用"], "scripts without spaces match by character pairs")
    }

    func testLongTablesSplitByRowsWithTheirHeader() {
        let rows = (1...60).map { "| Field \($0) | value number \($0) for the telescope |" }.joined(separator: "\n")
        let table = "| Name | Value |\n| --- | --- |\n" + rows.replacingOccurrences(of: "| Field 42 |", with: "| Launch date |")
        let parts = Passages.split(table)
        XCTAssertGreaterThan(parts.count, 1)
        XCTAssertTrue(parts.allSatisfy { $0.text.hasPrefix("| Name | Value |\n| --- | --- |") }, "each piece keeps the header")
        XCTAssertTrue(Passages.best(table, query: "launch date", budget: 2000).first?.text.contains("Launch date") == true)
    }

    func testFetchDropsSameSiteLinkAddressesAndListsLaterSections() {
        let md = "See [Recursion](https://en.wikipedia.org/wiki/Recursion_%28computer_science%29) and [a source](https://nature.com/x)."
        let (out, dropped) = WebPage.compactLinks(md, site: "wikipedia.org")
        XCTAssertEqual(out, "See Recursion and [a source](https://nature.com/x).")
        XCTAssertEqual(dropped, 1)
        let page = "# T\n\nintro\n\n## One\n\ntext\n\n```\n# not a heading\n```\n\n## Two\n\nmore"
        let later = WebFetchTool.sections(page, after: 10)
        XCTAssertEqual(later.map { $0.components(separatedBy: " (").first! }, ["One", "Two"], "headings inside code don't count")
        let at = Int(later[1].split(separator: "(").last!.dropLast())!
        XCTAssertTrue(String(Array(page)[at...]).hasPrefix("## Two"))
    }

    func testSearchResultsAreCachedAndDatesOnlyForNews() async {
        await SearchCache.shared.put("web|cached question", [r("Cached", "https://x.org")])
        let (hit, errors) = await WebSearch.search("Cached question ", limit: 5)
        XCTAssertEqual(hit.map(\.title), ["Cached"]); XCTAssertTrue(errors.isEmpty)
        XCTAssertEqual(WebSearchTool.day("Sun, 25 Oct 2026 04:26:00 GMT"), "2026-10-25")
    }
}
