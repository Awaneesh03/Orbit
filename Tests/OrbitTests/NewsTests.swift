import Foundation
import Testing
@testable import Orbit

// Milestone 3: Tech News in the Briefing. Everything a story shows comes
// from its feed: these tests pin the parsing, cleaning, de-duplication and
// classification, and that nothing is invented.

private let rss = Data("""
<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0"><channel><title>Example</title>
<item><title>Apple &amp; Google ship a new API for developers</title>
<link>https://www.example.com/story-one/?utm_source=rss&amp;id=7#comments</link>
<description><![CDATA[<p>The two companies announced a shared <b>framework</b> today, with support arriving in the next update for everyone.</p>]]></description>
<pubDate>Fri, 13 Nov 2026 18:30:00 +0000</pubDate></item>
<item><title>Ask HN: What are you working on?</title><link>https://news.ycombinator.com/item?id=1</link>
<description><![CDATA[<a href="https://news.ycombinator.com/item?id=1">Comments</a>]]></description>
<pubDate>Sat, 14 Nov 2026 08:00:00 GMT</pubDate></item>
<item><title></title><link>https://example.com/empty</link></item>
<item><title>Script link</title><link>javascript:alert(1)</link></item>
</channel></rss>
""".utf8)

private let atom = Data("""
<?xml version="1.0" encoding="utf-8"?>
<feed xmlns="http://www.w3.org/2005/Atom"><title>Atom</title>
<entry><title>Researchers find a ransomware gang&#8217;s new exploit</title>
<link rel="replies" href="https://atom.example/replies"/><link href="https://atom.example/post"/>
<summary type="html">&lt;p&gt;A short, plain description of what was found and who is affected by it.&lt;/p&gt;</summary>
<published>2026-11-14T06:15:00Z</published><updated>2026-11-14T07:00:00Z</updated></entry>
<entry><title>Only updated</title><link href="https://atom.example/second"/><updated>2026-11-12T10:00:00.250Z</updated></entry>
</feed>
""".utf8)

private let now = Date(timeIntervalSince1970: 1_794_650_000)  // 2026-11-14 ~13:13 UTC
private let general = NewsSource(id: "ex", name: "Example", feed: URL(string: "https://example.com/feed")!, category: .tech)

@Test func parsesRSSAndAtomItems() throws {
    let items = try #require(FeedParser.parse(rss))
    #expect(items.count == 4)
    #expect(items[0].title == "Apple & Google ship a new API for developers")
    #expect(items[0].link.hasPrefix("https://www.example.com/story-one/"))
    #expect(items[0].date == "Fri, 13 Nov 2026 18:30:00 +0000")
    let entries = try #require(FeedParser.parse(atom))
    #expect(entries.count == 2)
    #expect(entries[0].link == "https://atom.example/post")  // the alternate link, not "replies"
    #expect(entries[0].date == "2026-11-14T06:15:00Z")  // published wins over updated
    #expect(entries[1].date == "2026-11-12T10:00:00.250Z")
    #expect(FeedParser.parse(Data("not xml at all".utf8)) == nil)
}

@Test func summariesArePlainShortAndNeverInvented() {
    #expect(NewsText.summary(fromHTML: "<p>Hello <b>world</b> &amp; friends, this is a real description.</p>")
        == "Hello world & friends, this is a real description.")
    #expect(NewsText.summary(fromHTML: #"<a href="x">Comments</a>"#) == nil)  // nothing meaningful: no summary
    #expect(NewsText.summary(fromHTML: "") == nil)
    let long = String(repeating: "word ", count: 100)
    let cut = try! #require(NewsText.summary(fromHTML: long, limit: 40))
    #expect(cut.count <= 41 && cut.hasSuffix("…") && !cut.contains("  "))
    #expect(NewsText.decodeEntities("It&#8217;s &#x2014; &lt;b&gt; &amp;amp;") == "It’s — <b> &amp;")
}

@Test func datesInEveryFeedFormat() throws {
    #expect(NewsText.date("Fri, 13 Nov 2026 18:30:00 +0000") != nil)
    #expect(NewsText.date("Sat, 14 Nov 2026 08:00:00 GMT") != nil)
    #expect(NewsText.date("2026-11-14T06:15:00Z") != nil)
    #expect(NewsText.date("2026-11-12T10:00:00.250Z") != nil)
    #expect(NewsText.date("2026-11-14T06:15:00+05:30") != nil)
    #expect(NewsText.date("yesterday") == nil)
    #expect(NewsText.date("") == nil)
}

@Test func canonicalLinksIgnoreTrackingAndCosmetics() {
    let a = NewsText.canonical(URL(string: "http://WWW.Example.com/story/?utm_source=rss&utm_medium=feed#top")!)
    let b = NewsText.canonical(URL(string: "https://example.com/story")!)
    #expect(a == b)
    // Meaningful parameters stay (Hacker News items are identified by one).
    #expect(NewsText.canonical(URL(string: "https://news.ycombinator.com/item?id=1")!)
        != NewsText.canonical(URL(string: "https://news.ycombinator.com/item?id=2")!))
}

@Test func storiesAreCleanDeduplicatedAndNewestFirst() throws {
    let other = NewsSource(id: "other", name: "Other", feed: URL(string: "https://other.example/feed")!, category: .tech)
    let syndicated = [FeedItem(title: "Apple and Google ship new API for developers", link: "https://other.example/copy",
                               summary: "", date: "Fri, 13 Nov 2026 19:00:00 +0000"),
                      FeedItem(title: "Same link, different words entirely here", link: "https://example.com/story-one?id=7",
                               summary: "", date: "Fri, 13 Nov 2026 19:00:00 +0000")]
    let stories = NewsAssembler.stories(from: [(general, try #require(FeedParser.parse(rss))), (other, syndicated)], now: now)
    // Empty title and the javascript: link are dropped; the reworded copy and
    // the same link from the second source are duplicates.
    #expect(stories.map(\.sourceID) == ["ex", "ex"])
    #expect(stories.map(\.title) == ["Ask HN: What are you working on?", "Apple & Google ship a new API for developers"])
    #expect(stories[0].summary == nil)  // HN gives no description: none is made up
    #expect(stories[1].summary?.hasPrefix("The two companies announced") == true)
    #expect(stories[1].category == .software)  // "API", "developers"
}

@Test func oldStoriesAreLeftOutAndUndatedOnesGoLast() {
    let items = [FeedItem(title: "Ancient history from the archive", link: "https://e.x/1", summary: "", date: "Mon, 02 Nov 2026 10:00:00 +0000"),
                 FeedItem(title: "Undated item from a sloppy feed", link: "https://e.x/2", summary: "", date: ""),
                 FeedItem(title: "Fresh news published this morning", link: "https://e.x/3", summary: "", date: "Sat, 14 Nov 2026 09:00:00 +0000")]
    let stories = NewsAssembler.stories(from: [(general, items)], now: now)
    #expect(stories.map(\.url.absoluteString) == ["https://e.x/3", "https://e.x/2"])
}

@Test func headlinesAreClassifiedByKeywordUnlessTheSourceIsDedicated() {
    #expect(NewsClassifier.category(title: "OpenAI releases a new GPT model", source: general) == .ai)
    #expect(NewsClassifier.category(title: "Startup raises $40M Series B", source: general) == .startups)
    #expect(NewsClassifier.category(title: "Critical vulnerability found in routers", source: general) == .security)
    #expect(NewsClassifier.category(title: "Rust 2.0 compiler lands", source: general) == .software)
    #expect(NewsClassifier.category(title: "The best headphones of the year", source: general) == .tech)
    // Whole words only: "said" and "maintain" contain "ai" but aren't about AI.
    #expect(NewsClassifier.category(title: "Officials said they maintain the bridge", source: general) == .tech)
    let deepmind = NewsSource.curated.first { $0.id == "deepmind" }!
    #expect(NewsClassifier.category(title: "Our new weather forecasting work", source: deepmind) == .ai)
}

@Test func curatedSourcesAreHTTPSAndUnique() {
    let sources = NewsSource.curated
    #expect(Set(sources.map(\.id)).count == sources.count)
    #expect(sources.allSatisfy { $0.feed.scheme == "https" })
    #expect(Set(sources.map(\.category)) == Set(NewsCategory.allCases))  // every category has a source
}

private final class FeedHTTP: WeatherHTTP, @unchecked Sendable {
    let responses: [URL: (Data, Int)]
    init(_ responses: [URL: (Data, Int)]) { self.responses = responses }
    func get(_ url: URL) async throws -> (Data, Int) {
        guard let response = responses[url] else { throw URLError(.cannotConnectToHost) }
        return response
    }
}

@Test func aFailingFeedIsNamedNotFatal() async throws {
    let atomSource = NewsSource(id: "atom", name: "Atom Site", feed: URL(string: "https://atom.example/feed")!, category: .tech)
    let down = NewsSource(id: "down", name: "Down Site", feed: URL(string: "https://down.example/feed")!, category: .tech)
    let broken = NewsSource(id: "broken", name: "Broken", feed: URL(string: "https://broken.example/feed")!, category: .tech)
    let http = FeedHTTP([atomSource.feed: (atom, 200), broken.feed: (Data(), 503)])
    let digest = try await NewsFeedSource(sources: [atomSource, down, broken], http: http, clock: { now }).fetch()
    #expect(digest.unavailable == ["Down Site", "Broken"])
    #expect(digest.stories.first?.title == "Researchers find a ransomware gang’s new exploit")
    #expect(digest.stories.first?.category == .security)

    // Everything down: an offline error, so the widget keeps its cached stories.
    await #expect(throws: URLError.self) {
        try await NewsFeedSource(sources: [down], http: http).fetch()
    }
    #expect(DataSourceError.from(URLError(.notConnectedToInternet)) == .offline)
}

@MainActor @Test func widgetFiltersAndOpensOnlyWebLinks() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var opened: [URL] = []
    let atomSource = NewsSource(id: "atom", name: "Atom Site", feed: URL(string: "https://atom.example/feed")!, category: .tech)
    let cache: DataCache<NewsDigest> = DataCache(file: temp.file("news-cache.json"))
    let widget = NewsWidget(source: NewsFeedSource(sources: [atomSource], http: FeedHTTP([atomSource.feed: (atom, 200)]), clock: { now }),
                            cache: cache, clock: { now }, open: { opened.append($0) })
    #expect(widget.state == .loading)
    widget.start()
    await widget.refresher.refresh().value
    widget.stop()
    #expect(widget.state == .ready)
    #expect(widget.categories == [.security, .tech])
    widget.filter = .security
    #expect(widget.stories.count == 1)
    widget.read(widget.stories[0])
    #expect(opened == [URL(string: "https://atom.example/post")!])
    let sneaky = NewsStory(id: "x", title: "x", url: URL(string: "file:///etc/hosts")!, sourceID: "x", sourceName: "x",
                           published: nil, summary: nil, category: .tech)
    widget.read(sneaky)
    #expect(opened.count == 1)  // file: (and anything else not on the web) never opens

    // The digest is cached on disk: a new widget shows it at once, offline.
    let reopened = NewsWidget(source: NewsFeedSource(sources: [atomSource], http: FeedHTTP([:])),
                              cache: DataCache(file: temp.file("news-cache.json")), clock: { now })
    #expect(reopened.state == .ready && reopened.stories.count == 2)
}

@Test func noOutletFloodsTheTop() {
    func story(_ id: String, _ source: String, hoursAgo: Double) -> NewsStory {
        NewsStory(id: id, title: id, url: URL(string: "https://e.x/\(id)")!, sourceID: source, sourceName: source,
                  published: now.addingTimeInterval(-hoursAgo * 3600), summary: nil, category: .tech)
    }
    // Four fresh stories from one outlet, one slightly older from another.
    let stories = [story("a1", "a", hoursAgo: 0.1), story("a2", "a", hoursAgo: 0.2), story("a3", "a", hoursAgo: 0.3),
                   story("a4", "a", hoursAgo: 0.4), story("b1", "b", hoursAgo: 1)]
    #expect(NewsAssembler.diversified(stories, now: now).map(\.id) == ["a1", "b1", "a2", "a3", "a4"])
    // A much newer story still wins over an old one from another source.
    let fresh = [story("a1", "a", hoursAgo: 0), story("a2", "a", hoursAgo: 0.5), story("b1", "b", hoursAgo: 20)]
    #expect(NewsAssembler.diversified(fresh, now: now).map(\.id) == ["a1", "a2", "b1"])
}
