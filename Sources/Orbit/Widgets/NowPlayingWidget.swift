import ImageIO
import OrbitBridge
import SwiftUI

/// What's playing in Apple Music (from Music's own notification, read-only)
/// or on YouTube in Brave (through Orbit's extension and helper, with
/// play/pause and seek). Off on the Overview by default: turn it on in
/// Settings › Widgets.
@MainActor @Observable
final class NowPlayingWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "nowPlaying", title: "Now Playing", description: "What's playing in Music or on YouTube in Brave",
        symbol: "music.note", category: .general, availability: .live,
        presentations: [.compact, .expanded], isEnabledByDefault: false)
    let coordinator: PlaybackCoordinator

    /// Listens from launch, not only while visible: Music reports changes, not
    /// its current state, so a track started while the dashboard was closed
    /// would otherwise be missed. (Only the progress bar and thumbnails wait
    /// until the widget is on screen.)
    init(coordinator: PlaybackCoordinator) {
        self.coordinator = coordinator
        coordinator.start()
    }

    var state: WidgetState {
        coordinator.current != nil || coordinator.isWaiting ? .ready : .empty("Nothing is playing in Music or on YouTube.")
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        let item = coordinator.current
        return AnyView(NowPlayingView(item: item, isExpanded: presentation == .expanded) { [coordinator] command in
            // The item as displayed: the source refuses it if that's no longer on screen.
            guard let item else { return }
            Task {
                do {
                    try await coordinator.perform(command, on: item)
                } catch {
                    log.error("now playing: \(String(describing: error), privacy: .public)")
                }
            }
        })
    }
}

extension NowPlaying {
    /// How far through the item playback is at `date`, 0…1, when that's known.
    func progress(at date: Date) -> Double? {
        guard let duration, duration > 0, let elapsed = elapsed(at: date) else { return nil }
        return min(max(elapsed / duration, 0), 1)
    }
}

private struct NowPlayingView: View {
    let item: NowPlaying?
    let isExpanded: Bool
    let perform: (PlaybackCommand) -> Void

    var body: some View {
        if let item, item.state != .stopped || item.title != nil {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: isExpanded ? 14 : 10) {
                    Artwork(item: item, height: isExpanded ? 63 : 36, iconSize: isExpanded ? 56 : 34)
                    VStack(alignment: .leading, spacing: 2) {
                        SourceLabel(item: item)
                        Text(item.title ?? "Unknown title")
                            .font(isExpanded ? OrbitType.title : OrbitType.body)
                            .lineLimit(isExpanded ? 2 : 1)
                        if let artist = item.artist {
                            Text(artist).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                        }
                        if isExpanded, let album = item.album {
                            Text(album).font(OrbitType.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
                if item.position != nil, !item.isAd {
                    PlaybackProgress(item: item)
                }
                HStack(spacing: 8) {
                    StatusLabel(item: item)
                    if item.position == nil, isExpanded, let duration = item.duration {
                        Text(Self.format(duration)).font(OrbitType.caption.monospacedDigit()).foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                    PlaybackControls(item: item, isExpanded: isExpanded, perform: perform)
                }
            }
        } else {
            let stopped = item?.state == .stopped
            StatusMessage(text: stopped ? "\(item?.appName ?? "Music") is stopped."
                                        : "Music is open. Play, pause or change a track to show it here.",
                          symbol: stopped ? "stop.circle" : "music.note")
        }
    }

    static func format(_ seconds: TimeInterval) -> String { PlaybackTime.format(seconds) }
}

enum PlaybackTime {
    /// "3:35", or "1:02:07" for long items.
    static func format(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded(.down))
        let (hours, rest) = total.quotientAndRemainder(dividingBy: 3600)
        let (minutes, secs) = rest.quotientAndRemainder(dividingBy: 60)
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs) : String(format: "%d:%02d", minutes, secs)
    }
}

/// "MUSIC", or "YOUTUBE · BRAVE" with Brave's icon when a thumbnail takes the
/// icon's place (`PlaybackSourceIdentity`).
struct SourceLabel: View {
    let item: NowPlaying

    var body: some View {
        let identity = PlaybackSourceIdentity.of(item.sourceID)
        HStack(spacing: 4) {
            if identity.host != nil, item.artwork != nil { AppIcon(sourceID: item.sourceID, size: 12) }
            Text(identity.label(for: item).uppercased())
                .font(.system(size: 9, weight: .semibold)).tracking(0.6).foregroundStyle(Theme.tertiary).lineLimit(1)
        }
    }
}

/// Elapsed and total time with a bar. Ticks once a second only while playing
/// and on screen; otherwise it's drawn once.
struct PlaybackProgress: View {
    let item: NowPlaying

    var body: some View {
        if item.state == .playing, item.playbackRate > 0 {
            TimelineView(.periodic(from: .now, by: 1)) { context in bar(at: context.date) }
        } else {
            bar(at: .now)
        }
    }

    private func bar(at date: Date) -> some View {
        VStack(spacing: 3) {
            if let fraction = item.progress(at: date) { MeterBar(fraction: fraction) }
            HStack {
                Text(NowPlayingView.format(item.elapsed(at: date) ?? 0))
                Spacer(minLength: 4)
                Text(item.duration.map(NowPlayingView.format) ?? "Live")
            }
            .font(OrbitType.caption.monospacedDigit())
            .foregroundStyle(Theme.tertiary)
        }
    }
}

/// −10 s, play/pause, +10 s, for sources that can be controlled (none for
/// Music). Seeking is disabled, not hidden, during ads, live streams and
/// before the duration is known; the source clamps and targets the command.
struct PlaybackControls: View {
    let item: NowPlaying
    let isExpanded: Bool
    /// The Music Island's motion (press scale, icon swap); nil keeps the widget's plain buttons.
    var islandMotion: IslandMotion?
    let perform: (PlaybackCommand) -> Void

    static let skipSeconds: TimeInterval = 10

    /// (shows the controls, can seek)
    static func availability(_ item: NowPlaying) -> (controls: Bool, seek: Bool) {
        (item.capabilities.contains(.playPause), item.capabilities.contains(.seek) && !item.isAd && item.duration != nil)
    }

    var body: some View {
        let (controls, seek) = Self.availability(item)
        if controls {
            HStack(spacing: isExpanded ? 6 : 4) {
                button("gobackward.10", help: seek ? "Back 10 seconds" : "Can't skip in this video", enabled: seek) {
                    perform(.skip(-Self.skipSeconds))
                }
                let playing = item.state == .playing
                button(playing ? "pause.fill" : "play.fill", help: playing ? "Pause" : "Play", prominent: true) {
                    perform(.togglePlayPause)
                }
                button("goforward.10", help: seek ? "Forward 10 seconds" : "Can't skip in this video", enabled: seek) {
                    perform(.skip(Self.skipSeconds))
                }
            }
        }
    }

    private func button(_ symbol: String, help: String, prominent: Bool = false, enabled: Bool = true,
                        action: @escaping () -> Void) -> some View {
        let size: CGFloat = isExpanded ? 24 : 22
        return Group {
            let label = Image(systemName: symbol)
                .font(.system(size: isExpanded ? 10.5 : 10, weight: .semibold))
                .frame(width: size, height: size)
            if let islandMotion {
                // The icon swaps with the system's replace effect; it always
                // shows the reported state, so rapid clicks can't strand it.
                Button(action: action) { label.contentTransition(islandMotion.symbol) }
                    .buttonStyle(IslandPressStyle(prominent: prominent, motion: islandMotion))
            } else {
                Button(action: action) { label }
                    .buttonStyle(OrbitGlassButtonStyle(prominent: prominent, shape: AnyShape(Circle())))
            }
        }
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.35)
        .help(help)
        .accessibilityLabel(help)
    }
}

struct StatusLabel: View {
    let item: NowPlaying

    var body: some View {
        let (text, symbol, color): (String, String, Color) = if item.isAd {
            ("Ad", "megaphone.fill", OrbitGlass.warning)
        } else {
            switch item.state {
            case .playing: ("Playing", "play.fill", OrbitGlass.goal)
            case .paused: ("Paused", "pause.fill", Theme.secondary)
            case .stopped: ("Stopped", "stop.fill", Theme.tertiary)
            case .unknown: ("Unknown", "questionmark", Theme.tertiary)
            }
        }
        Label(text, systemImage: symbol)
            .font(OrbitType.caption)
            .foregroundStyle(color)
            .lineLimit(1)
    }
}

/// The item's artwork in its source's shape (`PlaybackSourceIdentity`), or
/// the app's icon when the source has none (Music). On a track change the
/// previous artwork stays until the new one has loaded, then cross-fades; a
/// thumbnail that failed shows the source's icon on a neutral tile. Shared by
/// the widget and the music island.
struct Artwork: View {
    let item: NowPlaying
    let height: CGFloat
    let iconSize: CGFloat
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        if case .url(let url)? = item.artwork {
            let square = PlaybackSourceIdentity.of(item.sourceID).artworkShape(for: item) == .square
            let shape = RoundedRectangle(cornerRadius: height > 50 ? 10 : 7, style: .continuous)
            let shown = ArtworkLoader.shared.artwork(for: url)
            ZStack {
                shape.fill(OrbitGlass.surfaceFill)
                if let shown {
                    Image(decorative: shown.image, scale: 1).resizable().interpolation(.high).aspectRatio(contentMode: .fill)
                        .id(shown.url)  // a different picture is a different view: cross-fades
                        .transition(.opacity)
                } else {
                    AppIcon(sourceID: item.sourceID, size: height * 0.6).opacity(0.5)
                }
            }
            .frame(width: square ? height : height * 16 / 9, height: height)
            .clipShape(shape)
            .overlay(shape.strokeBorder(OrbitGlass.surfaceStroke, lineWidth: 0.5))
            .animation(OrbitMotion.animation(.easeInOut(duration: 0.3), reduced: reduceMotion), value: shown?.url)
            .task(id: url) { await ArtworkLoader.shared.load(url) }
        } else {
            AppIcon(sourceID: item.sourceID, size: iconSize)
        }
    }
}

/// Thumbnails, fetched only while the widget or island is on screen and kept
/// only in memory (an ephemeral session: no disk cache, no cookies), at most
/// six, downscaled to 480 px. Only YouTube's own image hosts, over HTTPS, at
/// most 2 MB. A URL that failed isn't fetched again this session. Each
/// thumbnail's accent colour (`ArtworkAccent`) is worked out once, off the
/// main thread together with the decode, and kept and evicted with it.
@MainActor @Observable
final class ArtworkLoader {
    typealias Fetch = @Sendable (URL) async throws -> (Data, URLResponse)

    static let shared = ArtworkLoader()
    nonisolated static let maxImages = 6
    nonisolated static let maxBytes = 2_000_000
    nonisolated static let maxPixels = 480
    private static let maxFailures = 100

    private var images: [URL: CGImage] = [:]
    private var accents: [URL: ArtworkAccent] = [:]
    private var failed: Set<URL> = []
    /// The artwork on screen for the latest track, kept while the next loads.
    private var shown: (url: URL, image: CGImage)?
    @ObservationIgnored private var order: [URL] = []
    @ObservationIgnored private var loading: Set<URL> = []
    /// The artwork most recently asked for: only it may replace what's shown.
    @ObservationIgnored private var latest: URL?
    @ObservationIgnored private let fetch: Fetch
    /// Downloads started, and accent extractions run, for tests and diagnostics.
    @ObservationIgnored private(set) var requests = 0
    @ObservationIgnored private(set) var extractions = 0

    init(fetch: Fetch? = nil) { self.fetch = fetch ?? Self.network() }

    var cachedCount: Int { images.count }
    var accentCount: Int { accents.count }

    /// The accent for the artwork actually on screen for `item` (while a new
    /// thumbnail loads, that's the previous one's): nil without artwork (Music),
    /// for a failed or greyish thumbnail, or before anything has loaded.
    func accent(for item: NowPlaying) -> ArtworkAccent? {
        guard case .url(let url)? = item.artwork, let shown = artwork(for: url) else { return nil }
        return accents[shown.url]
    }
    var failedCount: Int { failed.count }

    /// What to draw for `url`: its own image once loaded; meanwhile the
    /// artwork already on screen (no placeholder flash between tracks); nil
    /// for a URL that failed, or before anything has loaded (the placeholder).
    func artwork(for url: URL) -> (url: URL, image: CGImage)? {
        if let image = images[url] { return (url, image) }
        return failed.contains(url) ? nil : shown
    }

    func load(_ url: URL) async {
        latest = url
        if let image = images[url] { return show(image, for: url) }
        guard !failed.contains(url), !loading.contains(url) else { return }
        guard BridgeMessage.artworkURL(url.absoluteString) != nil else { return fail(url) }
        loading.insert(url)
        defer { loading.remove(url) }
        requests += 1
        let result: (Data, URLResponse)
        do {
            result = try await fetch(url)
        } catch {
            // The view went away mid-download: not a failure, try again next time.
            if Task.isCancelled || (error as? URLError)?.code == .cancelled || error is CancellationError { return }
            return fail(url)
        }
        let (data, response) = result
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              BridgeMessage.artworkURL(http.url?.absoluteString) != nil,  // not redirected elsewhere
              data.count <= Self.maxBytes else { return fail(url) }
        // Decoding and colour analysis off the main thread; only the 480 px
        // thumbnail and its colour come back.
        let prepared = await Task.detached(priority: .utility) { Self.prepare(data) }.value
        guard let prepared else { return fail(url) }
        extractions += 1
        store(prepared.image, accent: prepared.accent, for: url)
    }

    struct Prepared: @unchecked Sendable {  // CGImage is immutable
        let image: CGImage
        let accent: ArtworkAccent?
    }

    nonisolated static func prepare(_ data: Data) -> Prepared? {
        guard let image = decode(data) else { return nil }
        return Prepared(image: image, accent: ArtworkAccent.extract(from: image))
    }

    func store(_ image: CGImage, accent: ArtworkAccent? = nil, for url: URL) {
        if images[url] == nil { order.append(url) }
        images[url] = image
        accents[url] = accent
        while order.count > Self.maxImages {
            let evicted = order.removeFirst()
            images[evicted] = nil
            accents[evicted] = nil
        }
        if url == latest || shown == nil { show(image, for: url) }  // a stale track's image never takes over
    }

    private func show(_ image: CGImage, for url: URL) {
        if shown?.url != url { shown = (url, image) }
    }

    private func fail(_ url: URL) {
        if failed.count >= Self.maxFailures { failed.removeAll() }
        failed.insert(url)
        // The track on screen has no picture: the next track starts from the
        // placeholder, never from an older track's artwork.
        if url == latest { shown = nil }
    }

    private static func network() -> Fetch {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 10
        let session = URLSession(configuration: configuration)
        return { url in try await session.data(from: url) }
    }

    /// Downscaled to at most `maxPixels`.
    nonisolated static func decode(_ data: Data) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceThumbnailMaxPixelSize: maxPixels,
                                        kCGImageSourceCreateThumbnailWithTransform: true]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }
}

/// The source app's icon, read from disk (this never launches the app).
struct AppIcon: View {
    let sourceID: String
    let size: CGFloat

    @MainActor private static var cache: [String: CGImage] = [:]

    var body: some View {
        Group {
            if let image = Self.icon(for: sourceID) {
                // Standard range: the app icon is HDR-capable and would otherwise outshine
                // the card (and turn a rendered snapshot into an HDR image).
                Image(decorative: image, scale: 2).resizable().interpolation(.high).allowedDynamicRange(.standard)
            } else {
                Image(systemName: PlaybackSourceIdentity.of(sourceID).fallbackSymbol)
                    .font(.system(size: size * 0.5)).foregroundStyle(Theme.accent)
                    .frame(maxWidth: .infinity, maxHeight: .infinity).orbitSurface(radius: size * 0.22)
            }
        }
        .frame(width: size, height: size)
    }

    /// Flattened once to a single 128 px bitmap: the multi-representation
    /// NSImage icon dims everything drawn with it in some contexts.
    @MainActor static func icon(for sourceID: String) -> CGImage? {
        if let cached = cache[sourceID] { return cached }
        let bundle = PlaybackSourceIdentity.of(sourceID).bundleIdentifier
        guard !bundle.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) else { return nil }
        // Drawn into a plain 8-bit sRGB bitmap: the icon itself is HDR-capable.
        let icon = NSWorkspace.shared.icon(forFile: url.path(percentEncoded: false))
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 128, height: 128, bitsPerComponent: 8, bytesPerRow: 0, space: space,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
        icon.draw(in: NSRect(x: 0, y: 0, width: 128, height: 128))
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { return nil }
        cache[sourceID] = image
        return image
    }
}
