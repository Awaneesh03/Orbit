import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.7B: Now Playing model, coordinator and the Apple Music source, over
// fake payloads and mock sources. Nothing here talks to Music.app.

@MainActor
private final class MockFeed: PlayerInfoFeed {
    private(set) var subscribers: [ObjectIdentifier: @MainActor ([AnyHashable: Any]) -> Void] = [:]
    func subscribe(_ handler: @escaping @MainActor ([AnyHashable: Any]) -> Void) -> AnyObject {
        let token = NSObject()
        subscribers[ObjectIdentifier(token)] = handler
        return token
    }
    func unsubscribe(_ token: AnyObject) { subscribers[ObjectIdentifier(token)] = nil }
    func send(_ userInfo: [AnyHashable: Any]) { subscribers.values.forEach { $0(userInfo) } }
}

@MainActor
private final class MockSource: PlaybackSource {
    let id: String
    let displayName: String
    private(set) var starts = 0
    private(set) var stops = 0
    private var onChange: (@MainActor (PlaybackSourceStatus) -> Void)?

    init(_ id: String) {
        self.id = id
        displayName = id
    }

    func start(onChange: @escaping @MainActor (PlaybackSourceStatus) -> Void) {
        starts += 1
        self.onChange = onChange
    }

    func stop() {
        stops += 1
        onChange = nil
    }

    func emit(_ status: PlaybackSourceStatus) { onChange?(status) }
}

private func track(_ source: String, _ title: String, _ state: PlaybackState, at seconds: TimeInterval) -> NowPlaying {
    NowPlaying(sourceID: source, appName: source, title: title, artist: "Artist", state: state,
               updatedAt: Date(timeIntervalSince1970: seconds))
}

private var playing: [AnyHashable: Any] { [
    "Name": "Blinding Lights", "Artist": "The Weeknd", "Album": "After Hours",
    "Player State": "Playing", "Total Time": NSNumber(value: 200_040), "Persistent ID": NSNumber(value: 1234),
] }

@MainActor
private func musicSource(feed: MockFeed, running: Bool = true, workspace: NotificationCenter = NotificationCenter()) -> AppleMusicSource {
    AppleMusicSource(feed: feed, isMusicRunning: { running }, workspace: workspace,
                     bundleOf: { $0.userInfo?["bundle"] as? String }, clock: { Date(timeIntervalSince1970: 1_000) })
}

// MARK: Payload parsing

@Test func playerInfoPayloadsAreParsedDefensively() {
    let now = Date(timeIntervalSince1970: 1_000)
    let item = AppleMusicSource.parse(playing, now: now)
    #expect(item.title == "Blinding Lights" && item.artist == "The Weeknd" && item.album == "After Hours")
    #expect(item.state == .playing && item.duration == 200.04 && item.updatedAt == now)
    #expect(item.position == nil && item.capabilities.isEmpty && item.artwork == nil)  // nothing invented

    let odd = AppleMusicSource.parse(["Name": 42, "Artist": "  ", "Album": ["x"], "Player State": "Rewinding",
                                      "Total Time": "200", "Extra": Date()], now: now)
    #expect(odd.title == nil && odd.artist == nil && odd.album == nil)  // wrong types and blanks are ignored
    #expect(odd.state == .unknown && odd.duration == nil)

    #expect(AppleMusicSource.parse([:], now: now).state == .unknown)
    for (value, state) in [("Paused", PlaybackState.paused), ("playing", .playing), ("Stopped", .stopped)] {
        #expect(AppleMusicSource.parse(["Player State": value], now: now).state == state)
    }
    let stopped = AppleMusicSource.parse(["Player State": "Stopped", "Name": "Old", "Total Time": NSNumber(value: 1000)], now: now)
    #expect(stopped.title == nil && stopped.duration == nil)  // a stopped player shows no stale track
}

@Test func durationsMustBeSensible() {
    let now = Date.now
    let cases: [(NSNumber, TimeInterval?)] = [
        (NSNumber(value: 0), nil), (NSNumber(value: -5), nil), (NSNumber(value: Double.nan), nil),
        (NSNumber(value: 1e12), nil), (NSNumber(value: 3_725_000), 3725),
    ]
    for (value, expected) in cases {
        #expect(AppleMusicSource.parse(["Player State": "Playing", "Total Time": value], now: now).duration == expected)
    }
}

// MARK: Apple Music source

@MainActor @Test func musicWaitsUntilItsFirstNotification() {
    let feed = MockFeed()
    let coordinator = PlaybackCoordinator()
    coordinator.register(musicSource(feed: feed, running: true))
    coordinator.start()
    #expect(coordinator.isWaiting && coordinator.current == nil)  // not "nothing playing"
    feed.send(playing)
    #expect(!coordinator.isWaiting && coordinator.current?.title == "Blinding Lights")

    let closed = PlaybackCoordinator()
    closed.register(musicSource(feed: MockFeed(), running: false))
    closed.start()
    #expect(!closed.isWaiting && closed.current == nil && closed.statuses["apple-music"] == .inactive)
}

@MainActor @Test func musicLaunchAndQuitAreFollowedAndOtherAppsIgnored() {
    let feed = MockFeed()
    let workspace = NotificationCenter()
    let coordinator = PlaybackCoordinator()
    coordinator.register(musicSource(feed: feed, running: false, workspace: workspace))
    coordinator.start()
    workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: ["bundle": "com.apple.Music"])
    #expect(coordinator.isWaiting)
    feed.send(playing)
    workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: ["bundle": "com.apple.Safari"])
    #expect(coordinator.current?.title == "Blinding Lights")  // another app quitting changes nothing
    workspace.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil, userInfo: ["bundle": "com.apple.Music"])
    #expect(coordinator.current == nil && coordinator.statuses["apple-music"] == .inactive)  // Music quit: track cleared
}

@MainActor @Test func stoppingRemovesEveryObserverAndRestartingDoesNotDuplicate() {
    let feed = MockFeed()
    let workspace = NotificationCenter()
    let source = musicSource(feed: feed, workspace: workspace)
    var received: [PlaybackSourceStatus] = []
    source.start { received.append($0) }
    source.start { received.append($0) }  // a second start replaces, never doubles
    #expect(feed.subscribers.count == 1)
    received = []
    feed.send(playing)
    #expect(received.count == 1)
    source.stop()
    #expect(feed.subscribers.isEmpty)
    feed.send(playing)
    workspace.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil, userInfo: ["bundle": "com.apple.Music"])
    #expect(received.count == 1)  // nothing after stop
}

// MARK: Coordinator

@MainActor @Test func duplicateUpdatesAreIgnored() {
    let source = MockSource("music")
    let coordinator = PlaybackCoordinator()
    coordinator.register(source)
    coordinator.start()
    source.emit(.playing(track("music", "A", .playing, at: 1)))
    source.emit(.playing(track("music", "A", .playing, at: 2)))  // same track and state, later
    #expect(coordinator.updateCount == 1)
    #expect(coordinator.current?.updatedAt == Date(timeIntervalSince1970: 1))
    source.emit(.playing(track("music", "A", .paused, at: 3)))
    source.emit(.playing(track("music", "B", .paused, at: 4)))
    #expect(coordinator.updateCount == 3 && coordinator.current?.title == "B")
}

@MainActor @Test func playingBeatsPausedAndTiesGoToTheMostRecent() {
    let a = MockSource("a"), b = MockSource("b")
    let coordinator = PlaybackCoordinator()
    coordinator.register(a)
    coordinator.register(b)
    coordinator.start()
    a.emit(.playing(track("a", "Paused song", .paused, at: 10)))
    b.emit(.playing(track("b", "Playing song", .playing, at: 5)))
    #expect(coordinator.current?.sourceID == "b")  // playing wins even though older
    b.emit(.playing(track("b", "Playing song", .paused, at: 20)))
    #expect(coordinator.current?.sourceID == "b")  // both paused: the more recent
    a.emit(.playing(track("a", "Paused song 2", .paused, at: 30)))
    #expect(coordinator.current?.sourceID == "a")
    b.emit(.playing(track("b", "x", .stopped, at: 40)))
    #expect(coordinator.current?.sourceID == "a")  // stopped ranks last even when newest
    #expect(PlaybackCoordinator.select([]) == nil)
}

@MainActor @Test func coordinatorLifecycleStartsAndStopsSources() {
    let a = MockSource("a")
    let coordinator = PlaybackCoordinator()
    coordinator.register(a)
    coordinator.register(a)  // the same source once
    #expect(coordinator.registeredSourceIDs == ["a"] && a.starts == 0)
    coordinator.start()
    coordinator.start()
    #expect(a.starts == 1)
    let late = MockSource("late")
    coordinator.register(late)  // registered while running: started at once
    #expect(late.starts == 1)
    a.emit(.waiting)
    coordinator.stop()
    #expect(a.stops == 1 && late.stops == 1 && coordinator.statuses.isEmpty)  // nothing kept in memory
    a.emit(.playing(track("a", "After stop", .playing, at: 1)))
    #expect(coordinator.current == nil)
}

// MARK: Widget

@MainActor @Test func widgetStatesAndRendering() throws {
    let feed = MockFeed()
    let coordinator = PlaybackCoordinator()
    coordinator.register(musicSource(feed: feed, running: true))
    let widget = NowPlayingWidget(coordinator: coordinator)
    #expect(coordinator.isRunning && widget.state == .ready && coordinator.isWaiting)  // waiting, not empty
    #expect(widget.metadata.isEnabledByDefault == false)  // the Overview isn't changed for existing users
    let waiting = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
    feed.send(playing)
    let compact = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
    let expanded = try #require(render(WidgetHost(widget: widget, presentation: .expanded), size: CGSize(width: 468, height: 160)))
    #expect(compact.pixels != waiting.pixels && expanded.width == 468)

    let closed = PlaybackCoordinator()
    closed.register(musicSource(feed: MockFeed(), running: false))
    #expect(NowPlayingWidget(coordinator: closed).state == .empty("Nothing is playing in Music or on YouTube."))

    if let folder = ProcessInfo.processInfo.environment["ORBIT_RENDER_DIR"] {
        for (name, presentation, width) in [("nowplaying-compact", WidgetPresentation.compact, 229.0),
                                            ("nowplaying-expanded", .expanded, 468.0)] {
            let renderer = ImageRenderer(content: WidgetHost(widget: widget, presentation: presentation)
                .frame(width: width, height: 160).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
            }
        }
    }
}
