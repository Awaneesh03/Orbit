import Foundation

// Technology news for the Briefing (Milestone 3). Headlines come from the
// publishers' own public RSS/Atom feeds, which exist for exactly this use:
// headline, link, time and the feed's own short description, always
// attributed and always opened at the source. Orbit never fetches article
// pages, never writes its own summaries, and shows nothing a feed didn't say.

enum NewsCategory: String, Codable, CaseIterable, Identifiable, Sendable {
    case ai, software, startups, security, tech
    var id: Self { self }

    var title: String {
        switch self {
        case .ai: "AI"
        case .software: "Software"
        case .startups: "Startups"
        case .security: "Security"
        case .tech: "Tech"
        }
    }
}

struct NewsSource: Identifiable, Sendable, Equatable {
    let id: String
    let name: String
    let feed: URL
    /// What the source mostly covers; keywords refine it for general outlets.
    let category: NewsCategory
    /// Sources that only publish about one subject keep it whatever the title says.
    var isDedicated = false

    /// Chosen for credibility, an official public feed, and coverage of the
    /// five categories. Anthropic publishes no feed (checked 2026-11-14), so
    /// its news arrives through the outlets below.
    static let curated: [NewsSource] = [
        NewsSource(id: "openai", name: "OpenAI", feed: URL(string: "https://openai.com/news/rss.xml")!, category: .ai, isDedicated: true),
        NewsSource(id: "deepmind", name: "Google DeepMind", feed: URL(string: "https://deepmind.google/blog/rss.xml")!, category: .ai, isDedicated: true),
        NewsSource(id: "mittr", name: "MIT Technology Review", feed: URL(string: "https://www.technologyreview.com/feed/")!, category: .tech),
        NewsSource(id: "ars", name: "Ars Technica", feed: URL(string: "https://feeds.arstechnica.com/arstechnica/index")!, category: .tech),
        NewsSource(id: "verge", name: "The Verge", feed: URL(string: "https://www.theverge.com/rss/tech/index.xml")!, category: .tech),
        NewsSource(id: "techcrunch", name: "TechCrunch", feed: URL(string: "https://techcrunch.com/feed/")!, category: .startups),
        // Wired's AI tag feed: its main feed is mostly product reviews.
        NewsSource(id: "wired", name: "Wired", feed: URL(string: "https://www.wired.com/feed/tag/ai/latest/rss")!, category: .ai),
        NewsSource(id: "hn", name: "Hacker News", feed: URL(string: "https://news.ycombinator.com/rss")!, category: .software),
        NewsSource(id: "github", name: "GitHub Blog", feed: URL(string: "https://github.blog/feed/")!, category: .software, isDedicated: true),
        NewsSource(id: "krebs", name: "Krebs on Security", feed: URL(string: "https://krebsonsecurity.com/feed/")!, category: .security, isDedicated: true),
        NewsSource(id: "apple", name: "Apple Newsroom", feed: URL(string: "https://www.apple.com/newsroom/rss-feed.rss")!, category: .tech, isDedicated: true),
        NewsSource(id: "microsoft", name: "Microsoft", feed: URL(string: "https://blogs.microsoft.com/feed/")!, category: .tech, isDedicated: true),
    ]
}

struct NewsStory: Codable, Identifiable, Equatable, Sendable {
    /// The canonical link, so the same article never shows twice.
    let id: String
    let title: String
    let url: URL
    let sourceID: String
    let sourceName: String
    let published: Date?
    /// The feed's own description, plain text, shortened; nil when the feed gave none.
    let summary: String?
    let category: NewsCategory
}

struct NewsDigest: Codable, Equatable, Sendable {
    var stories: [NewsStory]
    /// Names of sources that couldn't be loaded this time.
    var unavailable: [String] = []
}

// MARK: Parsing

/// One item as the feed wrote it.
struct FeedItem: Equatable, Sendable {
    var title = ""
    var link = ""
    var summary = ""
    var date = ""
}

/// RSS 2.0 and Atom, the two formats the curated sources use.
final class FeedParser: NSObject, XMLParserDelegate {
    private var items: [FeedItem] = []
    private var current: FeedItem?
    private var text = ""

    static func parse(_ data: Data) -> [FeedItem]? {
        let delegate = FeedParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldResolveExternalEntities = false  // never fetch anything a feed points at
        guard parser.parse() || !delegate.items.isEmpty else { return nil }
        return delegate.items
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        text = ""
        switch name {
        case "item", "entry": current = FeedItem()
        case "link" where current != nil:
            // Atom: <link rel="alternate" href="…"/> (no rel means alternate).
            if let href = attributes["href"], (attributes["rel"] ?? "alternate") == "alternate", current?.link.isEmpty == true {
                current?.link = href
            }
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }

    func parser(_ parser: XMLParser, foundCDATA block: Data) { text += String(decoding: block, as: UTF8.self) }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        guard current != nil else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch name {
        case "title": current?.title = value
        case "link" where !value.isEmpty && current?.link.isEmpty == true: current?.link = value
        case "description", "summary": if current?.summary.isEmpty == true { current?.summary = value }
        case "content" where current?.summary.isEmpty == true: current?.summary = value
        case "pubDate", "published", "dc:date": current?.date = value
        case "updated" where current?.date.isEmpty == true: current?.date = value
        case "item", "entry":
            if let item = current { items.append(item) }
            current = nil
        default: break
        }
        text = ""
    }
}

enum NewsText {
    /// Plain text from a feed's HTML description: tags removed, entities
    /// decoded, whitespace collapsed, cut at a word near `limit`. nil when
    /// nothing meaningful is left (Hacker News descriptions are just "Comments").
    static func summary(fromHTML html: String, limit: Int = 220) -> String? {
        var text = html.replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        text = decodeEntities(text)
        text = text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        guard text.count >= 30 else { return nil }
        guard text.count > limit else { return text }
        let cut = text.prefix(limit)
        let end = cut.lastIndex(of: " ") ?? cut.endIndex
        return String(cut[..<end]).trimmingCharacters(in: CharacterSet(charactersIn: " ,;:-–—")) + "…"
    }

    static func decodeEntities(_ text: String) -> String {
        guard text.contains("&") else { return text }
        let named = ["&lt;": "<", "&gt;": ">", "&quot;": "\"", "&apos;": "'", "&#39;": "'", "&nbsp;": " ",
                     "&hellip;": "…", "&mdash;": "—", "&ndash;": "–", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        var result = text
        for (entity, character) in named { result = result.replacingOccurrences(of: entity, with: character) }
        // Numeric: &#8217; and &#x2019;
        let pattern = try! NSRegularExpression(pattern: "&#(x?)([0-9a-fA-F]+);")
        for match in pattern.matches(in: result, range: NSRange(result.startIndex..., in: result)).reversed() {
            guard let whole = Range(match.range, in: result), let digits = Range(match.range(at: 2), in: result),
                  let hex = Range(match.range(at: 1), in: result) else { continue }
            let radix = result[hex].isEmpty ? 10 : 16
            if let code = UInt32(result[digits], radix: radix), let scalar = Unicode.Scalar(code) {
                result.replaceSubrange(whole, with: String(Character(scalar)))
            }
        }
        return result.replacingOccurrences(of: "&amp;", with: "&")  // last, so "&amp;lt;" stays "&lt;"
    }

    static func date(_ text: String) -> Date? {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        if let iso = try? Date(trimmed, strategy: .iso8601) { return iso }
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: trimmed) { return date }
        let rfc822 = DateFormatter()
        rfc822.locale = Locale(identifier: "en_US_POSIX")
        for format in ["EEE, dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm:ss zzz", "dd MMM yyyy HH:mm:ss Z", "EEE, dd MMM yyyy HH:mm Z"] {
            rfc822.dateFormat = format
            if let date = rfc822.date(from: trimmed) { return date }
        }
        return nil
    }

    /// The link that identifies an article: https, lower-case host without
    /// "www.", no tracking parameters, fragment or trailing slash.
    static func canonical(_ url: URL) -> String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        parts.scheme = "https"
        parts.host = parts.host?.lowercased().replacingOccurrences(of: "^www\\.", with: "", options: .regularExpression)
        parts.fragment = nil
        parts.queryItems = parts.queryItems?.filter { !$0.name.lowercased().hasPrefix("utm_") && $0.name != "ref" && $0.name != "source" }
        if parts.queryItems?.isEmpty == true { parts.queryItems = nil }
        if parts.path.count > 1, parts.path.hasSuffix("/") { parts.path.removeLast() }
        return parts.string ?? url.absoluteString
    }

    /// Lower-case words of three or more letters, for comparing headlines.
    static func words(_ title: String) -> Set<String> {
        Set(title.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init).filter { $0.count >= 3 })
    }

    /// Two headlines about the same thing: most of their words shared.
    static func isSameStory(_ a: String, _ b: String) -> Bool {
        let x = words(a), y = words(b)
        guard x.count >= 4, y.count >= 4 else { return a.caseInsensitiveCompare(b) == .orderedSame }
        return Double(x.intersection(y).count) / Double(x.union(y).count) >= 0.6
    }
}

enum NewsClassifier {
    private static let rules: [(NewsCategory, [String])] = [
        (.security, ["security", "vulnerability", "vulnerabilities", "breach", "ransomware", "malware", "cve", "exploit",
                     "zero-day", "phishing", "hacker", "hackers", "hacked", "spyware", "botnet"]),
        (.ai, ["ai", "a.i.", "llm", "llms", "gpt", "chatgpt", "openai", "anthropic", "claude", "gemini", "deepmind", "copilot",
               "machine learning", "neural", "artificial intelligence", "agentic", "chatbot", "chatbots", "mistral", "llama"]),
        (.startups, ["startup", "startups", "raises", "funding", "series a", "series b", "series c", "seed round", "valuation",
                     "acquires", "acquisition", "ipo", "venture", "unicorn", "layoffs"]),
        (.software, ["developer", "developers", "programming", "open source", "open-source", "rust", "swift", "python",
                     "javascript", "typescript", "github", "compiler", "linux", "kernel", "api", "framework", "database", "xcode"]),
    ]

    /// The source's own subject for dedicated sources; otherwise the first
    /// keyword rule the headline matches, else the source's default.
    static func category(title: String, source: NewsSource) -> NewsCategory {
        if source.isDedicated { return source.category }
        let lower = " " + String(title.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." ? $0 : " " }) + " "
        for (category, keywords) in rules where keywords.contains(where: { lower.contains(" \($0) ") }) {
            return category
        }
        return source.category
    }
}

// MARK: Assembling

enum NewsAssembler {
    /// Stories from feeds: parsed, cleaned, classified, deduplicated (same
    /// link, or the same headline from two outlets: the earlier source in
    /// `curated` order wins), newest first, older than `maxAge` dropped.
    static func stories(from feeds: [(NewsSource, [FeedItem])], now: Date, maxAge: TimeInterval = 4 * 86_400,
                        perSource: Int = 12, limit: Int = 80) -> [NewsStory] {
        var kept: [NewsStory] = []
        var links = Set<String>()
        for (source, items) in feeds {
            var taken = 0
            for item in items where taken < perSource {
                let title = NewsText.decodeEntities(item.title).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !title.isEmpty, let url = URL(string: item.link.trimmingCharacters(in: .whitespacesAndNewlines)),
                      url.scheme == "https" || url.scheme == "http" else { continue }
                let published = NewsText.date(item.date)
                if let published, now.timeIntervalSince(published) > maxAge { continue }
                let key = NewsText.canonical(url)
                guard !links.contains(key), !kept.contains(where: { NewsText.isSameStory($0.title, title) }) else { continue }
                links.insert(key)
                kept.append(NewsStory(id: key, title: title, url: url, sourceID: source.id, sourceName: source.name,
                                      published: published, summary: NewsText.summary(fromHTML: item.summary),
                                      category: NewsClassifier.category(title: title, source: source)))
                taken += 1
            }
        }
        return Array(diversified(kept, now: now).prefix(limit))
    }

    /// Newest first, but no outlet floods the top: each earlier story from the
    /// same source counts as three hours older. Undated stories go last.
    static func diversified(_ stories: [NewsStory], now: Date) -> [NewsStory] {
        let byDate = stories.sorted { ($0.published ?? .distantPast) > ($1.published ?? .distantPast) }
        var seen: [String: Int] = [:]
        let scored = byDate.map { story -> (NewsStory, Double) in
            let hours = story.published.map { max(0, now.timeIntervalSince($0) / 3600) } ?? 1_000_000
            let earlier = seen[story.sourceID, default: 0]
            seen[story.sourceID] = earlier + 1
            return (story, hours + 3 * Double(earlier))
        }
        return scored.enumerated().sorted { a, b in
            a.element.1 != b.element.1 ? a.element.1 < b.element.1 : a.offset < b.offset
        }.map(\.element.0)
    }
}

/// Every curated feed, fetched at once; a feed that fails is named, not fatal.
struct NewsFeedSource: DataSource {
    let sources: [NewsSource]
    let http: any WeatherHTTP
    var clock: @Sendable () -> Date = { .now }

    func fetch() async throws -> NewsDigest {
        let results = await withTaskGroup(of: (Int, [FeedItem]?).self) { group in
            for (index, source) in sources.enumerated() {
                group.addTask {
                    guard let (data, status) = try? await http.get(source.feed), (200..<300).contains(status) else { return (index, nil) }
                    return (index, FeedParser.parse(data))
                }
            }
            var all = [[FeedItem]?](repeating: nil, count: sources.count)
            for await (index, items) in group { all[index] = items }
            return all
        }
        try Task.checkCancellation()
        let loaded = zip(sources, results).compactMap { source, items in items.map { (source, $0) } }
        guard !loaded.isEmpty else { throw URLError(.notConnectedToInternet) }
        return NewsDigest(stories: NewsAssembler.stories(from: loaded, now: clock()),
                          unavailable: zip(sources, results).filter { $0.1 == nil }.map(\.0.name))
    }
}
