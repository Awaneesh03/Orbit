import AppKit
import Testing
@testable import Orbit

// Stage 3.7F-1: source identity and the artwork pipeline (failed URLs,
// previous artwork kept while the next loads, stale downloads, cache size).
// Downloads go through a fake fetch: nothing touches the network.

private func thumbnail(_ id: String) -> URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }

/// A fetch that serves a distinct PNG per URL after a per-URL delay, or a
/// status code; counts calls.
private final class FakeServer: @unchecked Sendable {
    var delays: [String: Duration] = [:]
    var status: [String: Int] = [:]
    var bodies: [String: Data] = [:]
    var throwing: [String: any Error] = [:]
    private(set) var calls: [String] = []

    var fetch: ArtworkLoader.Fetch {
        { [self] url in
            let id = url.pathComponents.dropLast().last ?? ""
            calls.append(id)
            if let delay = delays[id] { try await Task.sleep(for: delay) }
            if let error = throwing[id] { throw error }
            let code = status[id] ?? 200
            let data = bodies[id] ?? sampleImage(.png, width: 64, height: 36, seed: UInt8(truncatingIfNeeded: id.hashValue))
            return (data, HTTPURLResponse(url: url, statusCode: code, httpVersion: nil, headerFields: nil)!)
        }
    }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

// MARK: Identity

@MainActor @Test func sourceIdentitiesMapEverySource() {
    let music = PlaybackSourceIdentity.of("apple-music"), brave = PlaybackSourceIdentity.of("brave-youtube")
    #expect(music == .appleMusic && brave == .braveYouTube)
    #expect(AppleMusicSource().id == music.sourceID && AppleMusicSource.bundleIdentifier == "com.apple.Music")
    #expect(BraveYouTubeSource.sourceID == brave.sourceID && BraveYouTubeSource.bundleIdentifier == "com.brave.Browser")
    #expect(AppleMusicSource.parse(["Name": "x", "Player State": "Playing"], now: .now).sourceID == music.sourceID)
    #expect(music.displayName == "Music" && brave.displayName == "YouTube in Brave")

    let song = NowPlaying(sourceID: "apple-music", appName: "Music", state: .playing, updatedAt: .now)
    let video = NowPlaying(sourceID: "brave-youtube", appName: "YouTube", state: .playing, updatedAt: .now)
    let track = NowPlaying(sourceID: "brave-youtube", appName: "YouTube Music", state: .playing, updatedAt: .now)
    #expect(music.label(for: song) == "Music" && brave.label(for: video) == "YouTube · Brave"
        && brave.label(for: track) == "YouTube Music · Brave")
    #expect(music.artworkShape(for: song) == .square && brave.artworkShape(for: video) == .widescreen
        && brave.artworkShape(for: track) == .square)
    #expect(music.fallbackSymbol == "music.note" && brave.fallbackSymbol == "play.rectangle")

    let unknown = PlaybackSourceIdentity.of("spotify")  // not supported yet: neutral, never crashes
    #expect(unknown.bundleIdentifier.isEmpty && unknown.host == nil && unknown.artworkShape == .square)
    #expect(Set(PlaybackSourceIdentity.all.map(\.sourceID)).count == PlaybackSourceIdentity.all.count)
}

// MARK: Artwork

@MainActor @Test func aFailedThumbnailIsNeverFetchedAgain() async {
    let server = FakeServer()
    server.status["gone"] = 404
    server.throwing["offline"] = URLError(.notConnectedToInternet)
    server.bodies["big"] = Data(repeating: 0, count: ArtworkLoader.maxBytes + 1)
    server.bodies["junk"] = Data("not an image".utf8)
    let loader = ArtworkLoader(fetch: server.fetch)
    for id in ["gone", "offline", "big", "junk"] {
        await loader.load(thumbnail(id))
        await loader.load(thumbnail(id))  // the view appears again
        #expect(loader.artwork(for: thumbnail(id)) == nil)  // the source-icon placeholder
    }
    #expect(server.calls == ["gone", "offline", "big", "junk"])  // one request each, never repeated
    #expect(loader.failedCount == 4 && loader.cachedCount == 0)

    await loader.load(URL(string: "https://evil.example/a.jpg")!)  // not YouTube's: never requested
    #expect(server.calls.count == 4 && loader.failedCount == 5)
}

@MainActor @Test func aCancelledDownloadIsNotAFailure() async {
    let server = FakeServer()
    server.delays["slow"] = .seconds(5)
    let loader = ArtworkLoader(fetch: server.fetch)
    let task = Task { await loader.load(thumbnail("slow")) }
    #expect(await eventually { server.calls.count == 1 })
    task.cancel()  // the island dismissed itself mid-download
    await task.value
    #expect(loader.failedCount == 0)
    server.delays["slow"] = nil
    await loader.load(thumbnail("slow"))  // tried again next time it's shown
    #expect(server.calls.count == 2 && loader.artwork(for: thumbnail("slow"))?.url == thumbnail("slow"))
}

@MainActor @Test func thePreviousArtworkStaysUntilTheNextHasLoaded() async {
    let server = FakeServer()
    let loader = ArtworkLoader(fetch: server.fetch)
    #expect(loader.artwork(for: thumbnail("a")) == nil)  // nothing yet: placeholder
    await loader.load(thumbnail("a"))
    #expect(loader.artwork(for: thumbnail("a"))?.url == thumbnail("a"))

    server.delays["b"] = .milliseconds(150)
    let next = Task { await loader.load(thumbnail("b")) }
    #expect(await eventually { server.calls.contains("b") })
    #expect(loader.artwork(for: thumbnail("b"))?.url == thumbnail("a"))  // the old picture, no placeholder flash
    await next.value
    #expect(loader.artwork(for: thumbnail("b"))?.url == thumbnail("b"))  // then the new one (the view cross-fades)

    server.status["c"] = 404
    await loader.load(thumbnail("c"))
    #expect(loader.artwork(for: thumbnail("c")) == nil)  // a failed one shows the placeholder, not the old picture

    server.delays["d"] = .milliseconds(150)
    let after = Task { await loader.load(thumbnail("d")) }
    #expect(await eventually { server.calls.contains("d") })
    #expect(loader.artwork(for: thumbnail("d")) == nil)  // after a failed track: placeholder, never B from two tracks back
    await after.value
    #expect(loader.artwork(for: thumbnail("d"))?.url == thumbnail("d"))
}

@MainActor @Test func rapidTrackChangesNeverShowAStalePicture() async {
    let server = FakeServer()
    let loader = ArtworkLoader(fetch: server.fetch)
    await loader.load(thumbnail("a"))
    server.delays["b"] = .milliseconds(200)
    server.delays["c"] = .milliseconds(20)
    let b = Task { await loader.load(thumbnail("b")) }  // skipped past quickly…
    #expect(await eventually { server.calls.contains("b") })
    let c = Task { await loader.load(thumbnail("c")) }  // …to this one
    await c.value
    #expect(loader.artwork(for: thumbnail("c"))?.url == thumbnail("c"))
    await b.value  // the earlier download finishes last
    #expect(loader.artwork(for: thumbnail("c"))?.url == thumbnail("c"))
    #expect(loader.artwork(for: thumbnail("d"))?.url == thumbnail("c"))  // what's kept on screen is C, never B
    #expect(loader.artwork(for: thumbnail("b"))?.url == thumbnail("b"))  // B is cached for if it comes back
}

@MainActor @Test func atMostSixThumbnailsAt480Pixels() async throws {
    let server = FakeServer()
    let loader = ArtworkLoader(fetch: server.fetch)
    for index in 1 ... 8 { await loader.load(thumbnail("v\(index)")) }
    #expect(loader.cachedCount == ArtworkLoader.maxImages && ArtworkLoader.maxImages == 6)
    #expect(loader.artwork(for: thumbnail("v8"))?.url == thumbnail("v8"))
    await loader.load(thumbnail("v1"))  // evicted: fetched again (not a failure)
    #expect(server.calls.filter { $0 == "v1" }.count == 2 && loader.failedCount == 0)

    let large = try #require(ArtworkLoader.decode(sampleImage(.png, width: 1280, height: 720)))
    #expect(max(large.width, large.height) == ArtworkLoader.maxPixels && ArtworkLoader.maxPixels == 480)
    let small = try #require(ArtworkLoader.decode(sampleImage(.png, width: 120, height: 90)))
    #expect(small.width == 120)  // never enlarged
}
