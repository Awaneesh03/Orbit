import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.7F-3: the artwork accent colour: extraction, clamping, cache and
// stale results, fallbacks, and the equalizer's colour change.

/// A PNG of solid colour, or two halves (left, right).
private func png(_ left: (Double, Double, Double), _ right: (Double, Double, Double)? = nil,
                 width: Int = 96, height: Int = 54) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!.retagging(with: .sRGB)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    NSColor(srgbRed: left.0, green: left.1, blue: left.2, alpha: 1).setFill()
    NSRect(x: 0, y: 0, width: width, height: height).fill()
    if let right {
        NSColor(srgbRed: right.0, green: right.1, blue: right.2, alpha: 1).setFill()
        NSRect(x: width / 2, y: 0, width: width / 2, height: height).fill()
    }
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

private func thumbnail(_ id: String) -> URL { URL(string: "https://i.ytimg.com/vi/\(id)/hqdefault.jpg")! }

private func video(_ id: String?) -> NowPlaying {
    NowPlaying(sourceID: "brave-youtube", appName: "YouTube", title: id, state: .playing,
               artwork: id.map { .url(thumbnail($0)) }, itemID: id.map { "1/\($0)" }, updatedAt: .now)
}

private final class ColourServer: @unchecked Sendable {
    var bodies: [String: Data] = [:]
    var delays: [String: Duration] = [:]
    var status: [String: Int] = [:]
    private(set) var calls: [String] = []
    var fetch: ArtworkLoader.Fetch {
        { [self] url in
            let id = url.pathComponents.dropLast().last ?? ""
            calls.append(id)
            if let delay = delays[id] { try await Task.sleep(for: delay) }
            return (bodies[id] ?? png((0.5, 0.5, 0.5)),
                    HTTPURLResponse(url: url, statusCode: status[id] ?? 200, httpVersion: nil, headerFields: nil)!)
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

private func near(_ a: Double, _ b: Double, _ tolerance: Double = 0.03) -> Bool { abs(a - b) <= tolerance }

// MARK: Extraction and clamping

@Test func theAverageColourOfKnownImages() throws {
    let red = try #require(ArtworkLoader.decode(png((0.9, 0.1, 0.1))))
    let average = try #require(ArtworkAccent.averageColor(red))
    #expect(near(average.red, 0.9) && near(average.green, 0.1) && near(average.blue, 0.1))
    let redAccent = try #require(ArtworkAccent.extract(from: red))
    #expect(near(redAccent.hue, 0) || near(redAccent.hue, 1))

    // Half red, half blue: the average, not either half.
    let split = try #require(ArtworkLoader.decode(png((1, 0, 0), (0, 0, 1))))
    let mixed = try #require(ArtworkAccent.averageColor(split))
    // Core Image averages in linear light: an even purple, brighter than 0.5 in sRGB.
    #expect(near(mixed.red, mixed.blue, 0.03) && mixed.red > 0.45 && mixed.green < 0.05)
    let purple = try #require(ArtworkAccent.extract(from: split))
    #expect(near(purple.hue, 5.0 / 6, 0.03))

    let tealImage = try #require(ArtworkLoader.decode(png((0.1, 0.55, 0.6))))
    let teal = try #require(ArtworkAccent.extract(from: tealImage))
    #expect(near(teal.hue, 0.515, 0.03))

    let grey = try #require(ArtworkLoader.decode(png((0.45, 0.45, 0.47))))
    #expect(ArtworkAccent.extract(from: grey) == nil)  // greyish artwork: neutral, no accent

    let big = try #require(ArtworkLoader.decode(png((0.2, 0.4, 0.9), width: 1280, height: 720)))
    #expect(ArtworkAccent.extract(from: big) != nil)  // shrunk before analysis; still works
}

@Test func saturationAndBrightnessStayInABand() throws {
    let neon = try #require(ArtworkAccent.clamped(red: 0, green: 1, blue: 0))
    #expect(neon.saturation == ArtworkAccent.saturationRange.upperBound && neon.brightness == ArtworkAccent.brightnessRange.upperBound)
    let murky = try #require(ArtworkAccent.clamped(red: 0.12, green: 0.02, blue: 0.02))
    #expect(murky.brightness == ArtworkAccent.brightnessRange.lowerBound)  // lifted, never muddy
    let pastel = try #require(ArtworkAccent.clamped(red: 0.95, green: 0.85, blue: 0.8))
    #expect(pastel.saturation == ArtworkAccent.saturationRange.lowerBound && pastel.brightness == ArtworkAccent.brightnessRange.upperBound)
    #expect(ArtworkAccent.clamped(red: 0.5, green: 0.51, blue: 0.5) == nil)
    #expect(ArtworkAccent.tintOpacity == 0.18)
}

// MARK: Cache, staleness, fallbacks

@MainActor @Test func eachThumbnailIsAnalysedOnce() async {
    let server = ColourServer()
    server.bodies["red"] = png((0.9, 0.1, 0.1))
    let loader = ArtworkLoader(fetch: server.fetch)
    for _ in 0 ..< 3 { await loader.load(thumbnail("red")) }  // shown again and again
    #expect(server.calls == ["red"] && loader.extractions == 1)
    let accent = loader.accent(for: video("red"))
    #expect(accent != nil && (near(accent!.hue, 0) || near(accent!.hue, 1)))
    // Progress, play state and title changes are the same artwork: same accent, no work.
    var paused = video("red")
    paused.state = .paused
    paused.title = "Late title"
    #expect(loader.accent(for: paused) == accent && loader.extractions == 1)
}

@MainActor @Test func aSlowOlderThumbnailNeverColoursANewerTrack() async throws {
    let server = ColourServer()
    server.bodies["a"] = png((0.9, 0.1, 0.1))  // red
    server.bodies["b"] = png((0.1, 0.2, 0.9))  // blue, slow
    server.bodies["c"] = png((0.1, 0.8, 0.2))  // green, fast
    server.delays["b"] = .milliseconds(200)
    server.delays["c"] = .milliseconds(20)
    let loader = ArtworkLoader(fetch: server.fetch)
    await loader.load(thumbnail("a"))
    let red = try #require(loader.accent(for: video("a")))
    let b = Task { await loader.load(thumbnail("b")) }
    #expect(await eventually { server.calls.contains("b") })
    #expect(loader.accent(for: video("b")) == red)  // still showing A's artwork, so A's colour
    let c = Task { await loader.load(thumbnail("c")) }
    await c.value
    let green = try #require(loader.accent(for: video("c")))
    #expect(near(green.hue, 0.37, 0.05))
    await b.value  // the older one lands last
    #expect(loader.accent(for: video("c")) == green)
}

@MainActor @Test func evictionAndFailuresLeaveNoStaleColour() async {
    let server = ColourServer()
    for (index, id) in ["v1", "v2", "v3", "v4", "v5", "v6", "v7"].enumerated() {
        server.bodies[id] = png((0.9, Double(index) / 10, 0.1))
    }
    server.status["broken"] = 404
    let loader = ArtworkLoader(fetch: server.fetch)
    for id in ["v1", "v2", "v3", "v4", "v5", "v6", "v7"] { await loader.load(thumbnail(id)) }
    #expect(loader.cachedCount == 6 && loader.accentCount == 6)  // evicted with its image
    #expect(loader.accent(for: video("v7")) != nil)
    #expect(loader.accent(for: video("v1")) == loader.accent(for: video("v7")))  // v1 is gone: what's shown is v7
    await loader.load(thumbnail("broken"))
    #expect(loader.accent(for: video("broken")) == nil)  // failed thumbnail: back to the fallback
    await loader.load(thumbnail("v7"))
    #expect(loader.accent(for: video("v7")) != nil)
}

@MainActor @Test func noArtworkFallsBackToMintAndMusicStaysNeutral() {
    let loader = ArtworkLoader(fetch: { _ in throw URLError(.badURL) })
    #expect(loader.accent(for: video(nil)) == nil)  // a video without a thumbnail
    let song = NowPlaying(sourceID: "apple-music", appName: "Music", title: "Song", state: .playing, updatedAt: .now)
    #expect(loader.accent(for: song) == nil && ArtworkLoader.shared.accent(for: song) == nil)  // Music: no artwork, neutral
    #expect(MusicEqualizer.color(accent: nil) == OrbitGlass.goal)  // the bars stay mint
}

// MARK: Equalizer colour

@MainActor @Test func aColourChangeFadesWithoutRestartingTheBars() {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.alphaValue = 0
    window.isReleasedWhenClosed = false
    defer { window.close() }
    let view = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 12))
    window.contentView?.addSubview(view)
    view.apply(mode: .playing, animated: true, color: NSColor(OrbitGlass.goal))
    let started = view.bars.map { $0.animation(forKey: EqualizerBarsView.animationKey)?.beginTime }

    view.apply(mode: .playing, animated: true, color: .systemBlue)  // the accent arrives
    #expect(view.bars.allSatisfy { $0.animation(forKey: EqualizerBarsView.colorAnimationKey)?.duration == EqualizerBarsView.colorFade })
    #expect(view.bars.map { $0.animation(forKey: EqualizerBarsView.animationKey)?.beginTime } == started)  // bounce untouched
    #expect(view.bars.allSatisfy { $0.backgroundColor == NSColor.systemBlue.cgColor })

    view.bars.forEach { $0.removeAnimation(forKey: EqualizerBarsView.colorAnimationKey) }
    view.apply(mode: .playing, animated: false, color: .systemRed)  // Reduce Motion: instant
    #expect(view.bars.allSatisfy { $0.animation(forKey: EqualizerBarsView.colorAnimationKey) == nil
        && $0.backgroundColor == NSColor.systemRed.cgColor })

    view.apply(mode: .playing, animated: true, color: .systemRed)  // same colour again: nothing
    #expect(view.bars.allSatisfy { $0.animation(forKey: EqualizerBarsView.colorAnimationKey) == nil })
}
