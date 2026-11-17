import Foundation
import Observation

// Lyrics (Milestone 20), off by default. When turned on, the playing track's
// title and artist go to LRCLIB (lrclib.net, a free, open lyrics database with
// no account or key) and the lyrics come back; they're kept in memory only.
// Synced lyrics follow playback where the source reports a position (YouTube
// in Brave); Apple Music reports none, so its lyrics show as text.

struct LyricLine: Equatable, Sendable {
    let time: TimeInterval
    let text: String
}

struct Lyrics: Equatable, Sendable {
    var synced: [LyricLine] = []
    var plain: String?
    var instrumental = false

    /// `[mm:ss.xx]text` lines; several tags on a line repeat it; metadata tags (`[ar:…]`) and blank lines are skipped.
    static func parseLRC(_ text: String) -> [LyricLine] {
        var lines: [LyricLine] = []
        for raw in text.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [TimeInterval] = []
            while rest.hasPrefix("["), let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                let parts = tag.split(separator: ":", maxSplits: 1)
                guard parts.count == 2, let minutes = Double(parts[0]), let seconds = Double(parts[1]),
                      minutes >= 0, seconds >= 0, seconds < 60 else { continue }
                times.append(minutes * 60 + seconds)
            }
            let words = rest.trimmingCharacters(in: .whitespaces)
            for time in times { lines.append(LyricLine(time: time, text: words)) }
        }
        return lines.sorted { $0.time < $1.time }
    }

    /// The synced line playing at `time`: the last that has started. nil before the first.
    func lineIndex(at time: TimeInterval) -> Int? {
        guard let first = synced.first, time >= first.time else { return nil }
        var low = 0, high = synced.count - 1
        while low < high {
            let mid = (low + high + 1) / 2
            if synced[mid].time <= time { low = mid } else { high = mid - 1 }
        }
        return low
    }
}

enum LyricsQuery {
    /// A track name and artist fit for a lyrics search. YouTube titles are often
    /// "Artist - Song (Official Video)" with the channel as the artist: the title's
    /// own artist wins, and bracketed extras and "| …" tails go.
    /// `videoTitle`: a YouTube title (the channel is only a guess at the artist). Otherwise (Apple Music) the artist
    /// is reliable and " - " starts a version ("Song - Remastered 2011"), which is dropped.
    static func clean(title: String, artist: String?, videoTitle: Bool = true) -> (track: String, artist: String?) {
        var track = title
        if let bar = track.firstIndex(of: "|") { track = String(track[..<bar]) }
        track = stripBrackets(track)
        var artist = artist.map { $0.replacingOccurrences(of: " - Topic", with: "").replacingOccurrences(of: "VEVO", with: "") }
        if let dash = track.range(of: " - ") ?? track.range(of: " – ") {
            let left = track[..<dash.lowerBound].trimmingCharacters(in: .whitespaces)
            let right = track[dash.upperBound...].trimmingCharacters(in: .whitespaces)
            if !videoTitle {
                track = left
            } else if !left.isEmpty, !right.isEmpty {
                artist = left
                track = right
            }
        }
        let trimmed = artist?.trimmingCharacters(in: .whitespaces)
        return (track.trimmingCharacters(in: .whitespaces), trimmed?.isEmpty == false ? trimmed : nil)
    }

    /// Removes (…) and […] groups that are extras: official video, lyrics, audio, HD and the like.
    private static func stripBrackets(_ text: String) -> String {
        let extras = ["official", "video", "lyric", "audio", "visualizer", "hd", "4k", "remaster", "mv", "live"]
        var result = text
        for (open, close) in [("(", ")"), ("[", "]")] {
            var searchFrom = result.startIndex
            while let start = result.range(of: open, range: searchFrom..<result.endIndex),
                  let end = result.range(of: close, range: start.upperBound..<result.endIndex) {
                let inside = result[start.upperBound..<end.lowerBound].lowercased()
                if extras.contains(where: inside.contains) {
                    result.removeSubrange(start.lowerBound..<end.upperBound)
                    searchFrom = result.startIndex
                } else {
                    searchFrom = end.upperBound  // e.g. "(feat. …)" stays
                }
            }
        }
        while result.contains("  ") { result = result.replacingOccurrences(of: "  ", with: " ") }
        return result
    }

    struct Record: Decodable, Sendable {
        let trackName: String?
        let artistName: String?
        let duration: Double?
        let instrumental: Bool?
        let plainLyrics: String?
        let syncedLyrics: String?

        var lyrics: Lyrics {
            Lyrics(synced: syncedLyrics.map(Lyrics.parseLRC) ?? [], plain: plainLyrics, instrumental: instrumental ?? false)
        }
    }

    /// The best search result: synced lyrics first, then any, among those within 3 s of the length when it's known.
    static func best(_ records: [Record], duration: TimeInterval?) -> Record? {
        let usable = records.filter { $0.instrumental == true || $0.syncedLyrics != nil || $0.plainLyrics != nil }
        let fitting = duration.map { length in usable.filter { abs(($0.duration ?? length) - length) <= 3 } } ?? usable
        return fitting.first { $0.syncedLyrics != nil } ?? fitting.first
    }

    static let base = URL(string: "https://lrclib.net/api")!

    static func searchURL(track: String, artist: String?) -> URL {
        var items = [URLQueryItem(name: "track_name", value: track)]
        if let artist { items.append(URLQueryItem(name: "artist_name", value: artist)) }
        return base.appending(path: "search").appending(queryItems: items)
    }
}

/// Lyrics for what's playing: one lookup per track, remembered for the session.
@MainActor @Observable
final class LyricsModel {
    enum Status: Equatable { case off, idle, loading, found, notFound, failed }

    private(set) var status = Status.off
    private(set) var lyrics: Lyrics?
    /// Settings › General › Lyrics. Turning it off forgets everything fetched.
    var isEnabled = false {
        didSet {
            guard isEnabled != oldValue else { return }
            if isEnabled { status = .idle; key = nil } else { reset() }
        }
    }

    @ObservationIgnored private let http: any WeatherHTTP
    @ObservationIgnored private var key: String?
    @ObservationIgnored private var cache: [String: Lyrics?] = [:]
    @ObservationIgnored private var order: [String] = []
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private(set) var requests = 0
    static let cacheLimit = 40

    init(http: any WeatherHTTP = URLSessionWeatherHTTP()) { self.http = http }

    /// Called whenever the playing item changes; only a new track starts a lookup.
    func follow(_ item: NowPlaying?) {
        guard isEnabled else { return }
        guard let item, let title = item.title, !title.isEmpty, !item.isAd else {
            // An ad, nothing, or an untitled stream: the last song's lyrics don't stay on screen.
            if key != nil || lyrics != nil { task?.cancel(); key = nil; lyrics = nil; status = .idle }
            return
        }
        let query = LyricsQuery.clean(title: title, artist: item.artist, videoTitle: item.sourceID == "brave-youtube")
        guard !query.track.isEmpty else { return }
        let newKey = "\(query.track.lowercased())|\(query.artist?.lowercased() ?? "")"
        guard newKey != key else { return }
        key = newKey
        task?.cancel()
        if let cached = cache[newKey] {
            lyrics = cached
            status = cached == nil ? .notFound : .found
            return
        }
        lyrics = nil
        status = .loading
        requests += 1
        let http = self.http
        let duration = item.duration
        task = Task { [weak self] in
            let result: Result<Lyrics?, any Error>
            do {
                let (data, code) = try await http.get(LyricsQuery.searchURL(track: query.track, artist: query.artist))
                guard code == 200 else { throw URLError(.badServerResponse) }
                let records = try JSONDecoder().decode([LyricsQuery.Record].self, from: data)
                result = .success(LyricsQuery.best(records, duration: duration)?.lyrics)
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled else { return }
            self?.finish(newKey, result)
        }
    }

    /// Waits for the lookup in flight (tests).
    func settle() async { await task?.value }

    private func finish(_ forKey: String, _ result: Result<Lyrics?, any Error>) {
        guard forKey == key, isEnabled else { return }
        switch result {
        case .success(let found):
            remember(forKey, found)
            lyrics = found
            status = found == nil ? .notFound : .found
        case .failure:
            key = nil  // a failure isn't remembered: the next change tries again
            status = .failed
        }
    }

    private func remember(_ key: String, _ value: Lyrics?) {
        cache[key] = .some(value)
        order.append(key)
        if order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
    }

    private func reset() {
        task?.cancel()
        task = nil
        key = nil
        cache = [:]
        order = []
        lyrics = nil
        status = .off
    }
}
