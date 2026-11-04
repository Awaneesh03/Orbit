import AppKit
import Observation

// What's playing, from per-app sources (Apple Music, YouTube in Brave;
// Spotify later). Public APIs only, no permissions, nothing written to disk:
// Now Playing information lives in memory for as long as Orbit runs.

enum PlaybackState: String, Sendable, Equatable {
    case playing, paused, stopped, unknown

    /// Higher wins when choosing which source to show.
    var priority: Int {
        switch self {
        case .playing: 3
        case .paused: 2
        case .unknown: 1
        case .stopped: 0
        }
    }
}

/// What a source can be asked to do (YouTube in Brave: play/pause and seek).
enum PlaybackCommand: Sendable, Hashable {
    case togglePlayPause, next, previous
    /// To a position, in seconds.
    case seek(TimeInterval)
    /// Forward (positive) or back (negative) from where playback is now.
    case skip(TimeInterval)
}

struct PlaybackCapabilities: OptionSet, Sendable, Hashable {
    let rawValue: Int
    static let playPause = PlaybackCapabilities(rawValue: 1 << 0)
    static let next = PlaybackCapabilities(rawValue: 1 << 1)
    static let previous = PlaybackCapabilities(rawValue: 1 << 2)
    static let seek = PlaybackCapabilities(rawValue: 1 << 3)
}

/// For future sources that provide artwork; nothing fetches it yet.
enum ArtworkReference: Equatable, Sendable {
    case url(URL)
}

struct NowPlaying: Equatable, Sendable {
    let sourceID: String
    let appName: String
    var title: String?
    var artist: String?
    var album: String?
    var state: PlaybackState
    var duration: TimeInterval?
    /// Position as of `positionAt` (sources that know it; Music's notification doesn't).
    var position: TimeInterval?
    var positionAt: Date?
    /// How fast `position` moves while playing (0 while buffering).
    var playbackRate: Double = 1
    var capabilities: PlaybackCapabilities = []
    var artwork: ArtworkReference?
    /// An ad is playing in place of the item (YouTube).
    var isAd = false
    /// What exactly is on screen, for sources that take commands (YouTube:
    /// tab and video), so a command never reaches something else.
    var itemID: String?
    var updatedAt: Date

    /// Where playback is at `date`: the reported position, moved on at the
    /// reported rate while playing, never past the end.
    func elapsed(at date: Date) -> TimeInterval? {
        guard let position else { return nil }
        var value = position
        if state == .playing, let positionAt { value += max(0, date.timeIntervalSince(positionAt)) * playbackRate }
        if let duration { value = min(value, duration) }
        return value
    }

    /// The same track in the same state: a repeat, ignoring when it arrived.
    func isSameUpdate(as other: NowPlaying) -> Bool {
        var a = self, b = other
        a.updatedAt = .distantPast
        b.updatedAt = .distantPast
        a.positionAt = nil
        b.positionAt = nil
        return a == b
    }
}

/// What one source currently knows.
enum PlaybackSourceStatus: Equatable, Sendable {
    /// The app isn't running.
    case inactive
    /// The app is running but hasn't said what's playing yet (Music only
    /// reports changes, so this lasts until the next play, pause or track change).
    case waiting
    case playing(NowPlaying)
}

struct PlaybackSourceError: Error, Equatable {
    let message: String
}

/// One app Orbit can follow. Called on the main actor; `start` may be called
/// again after `stop`.
@MainActor
protocol PlaybackSource: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var capabilities: PlaybackCapabilities { get }
    func start(onChange: @escaping @MainActor (PlaybackSourceStatus) -> Void)
    func stop()
    /// `item` is what the user saw when they asked: a source refuses the
    /// command if that's no longer what it's showing.
    func perform(_ command: PlaybackCommand, on item: NowPlaying) async throws
}

extension PlaybackSource {
    var capabilities: PlaybackCapabilities { [] }
    func perform(_ command: PlaybackCommand, on item: NowPlaying) async throws {
        throw PlaybackSourceError(message: "\(displayName) can't be controlled from Orbit yet.")
    }
}

// MARK: Coordinator

/// Follows every registered source and picks the one to show: playing beats
/// paused beats unknown beats stopped; ties go to the most recent update.
/// Repeats of the same track and state are ignored.
@MainActor @Observable
final class PlaybackCoordinator {
    private(set) var statuses: [String: PlaybackSourceStatus] = [:]
    /// Accepted (non-duplicate) updates, for tests and diagnostics.
    private(set) var updateCount = 0
    @ObservationIgnored private var sources: [any PlaybackSource] = []
    @ObservationIgnored private(set) var isRunning = false

    var registeredSourceIDs: [String] { sources.map(\.id) }

    func register(_ source: any PlaybackSource) {
        guard !sources.contains(where: { $0.id == source.id }) else { return }
        sources.append(source)
        if isRunning { start(source) }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        sources.forEach(start)
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        sources.forEach { $0.stop() }
        statuses = [:]
    }

    /// The source to show, if any has something.
    var current: NowPlaying? {
        Self.select(statuses.values.compactMap { if case .playing(let item) = $0 { item } else { nil } })
    }

    /// No track yet, but at least one app is running and may report one.
    var isWaiting: Bool { current == nil && statuses.values.contains(.waiting) }

    /// Sent to the source of the item on screen (`item`, as displayed).
    func perform(_ command: PlaybackCommand, on item: NowPlaying) async throws {
        guard let source = sources.first(where: { $0.id == item.sourceID }) else {
            throw PlaybackSourceError(message: "Nothing is playing.")
        }
        try await source.perform(command, on: item)
    }

    static func select(_ candidates: [NowPlaying]) -> NowPlaying? {
        candidates.max { a, b in
            a.state.priority != b.state.priority ? a.state.priority < b.state.priority : a.updatedAt < b.updatedAt
        }
    }

    private func start(_ source: any PlaybackSource) {
        let id = source.id
        source.start { [weak self] status in self?.receive(status, from: id) }
    }

    private func receive(_ status: PlaybackSourceStatus, from id: String) {
        if case .playing(let new) = status, case .playing(let old)? = statuses[id], new.isSameUpdate(as: old) { return }
        guard statuses[id] != status else { return }
        statuses[id] = status
        updateCount += 1
    }
}

// MARK: Apple Music

/// Apple Music through its public `com.apple.Music.playerInfo` distributed
/// notification: no permission, no Apple Events, never launches Music.
/// The payload is undocumented, so every field is optional and type-checked.
@MainActor
final class AppleMusicSource: PlaybackSource {
    nonisolated static let bundleIdentifier = PlaybackSourceIdentity.appleMusic.bundleIdentifier
    nonisolated static let playerInfo = Notification.Name("com.apple.Music.playerInfo")

    let id = PlaybackSourceIdentity.appleMusic.sourceID
    let displayName = PlaybackSourceIdentity.appleMusic.displayName

    private let feed: any PlayerInfoFeed
    private let isMusicRunning: () -> Bool
    private let workspace: NotificationCenter
    private let bundleOf: @Sendable (Notification) -> String?
    private let clock: () -> Date
    private var tokens: [any NSObjectProtocol] = []
    private var feedToken: AnyObject?

    init(feed: any PlayerInfoFeed = DistributedPlayerInfoFeed(),
         isMusicRunning: @escaping () -> Bool = {
             !NSRunningApplication.runningApplications(withBundleIdentifier: AppleMusicSource.bundleIdentifier).isEmpty
         },
         workspace: NotificationCenter = NSWorkspace.shared.notificationCenter,
         bundleOf: @escaping @Sendable (Notification) -> String? = {
             ($0.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
         },
         clock: @escaping () -> Date = { .now }) {
        self.feed = feed
        self.isMusicRunning = isMusicRunning
        self.workspace = workspace
        self.bundleOf = bundleOf
        self.clock = clock
    }

    func start(onChange: @escaping @MainActor (PlaybackSourceStatus) -> Void) {
        stop()  // never two sets of observers
        onChange(isMusicRunning() ? .waiting : .inactive)
        feedToken = feed.subscribe { [weak self, clock] userInfo in
            guard self != nil else { return }
            onChange(.playing(Self.parse(userInfo, now: clock())))
        }
        for (name, status) in [(NSWorkspace.didLaunchApplicationNotification, PlaybackSourceStatus.waiting),
                               (NSWorkspace.didTerminateApplicationNotification, .inactive)] {
            tokens.append(workspace.addObserver(forName: name, object: nil, queue: .main) { [bundleOf] note in
                guard bundleOf(note) == Self.bundleIdentifier else { return }  // other apps don't matter
                MainActor.assumeIsolated { onChange(status) }
            })
        }
    }

    func stop() {
        tokens.forEach(workspace.removeObserver)
        tokens = []
        if let feedToken { feed.unsubscribe(feedToken) }
        feedToken = nil
    }

    /// Reads what the payload offers: "Name", "Artist", "Album", "Player State"
    /// and "Total Time" (milliseconds). Anything missing or of the wrong type
    /// is left out rather than guessed.
    nonisolated static func parse(_ userInfo: [AnyHashable: Any], now: Date) -> NowPlaying {
        func text(_ key: String) -> String? {
            guard let value = userInfo[key] as? String else { return nil }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        }
        let state: PlaybackState = switch text("Player State")?.lowercased() {
        case "playing": .playing
        case "paused": .paused
        case "stopped": .stopped
        default: .unknown
        }
        var duration: TimeInterval?
        if let milliseconds = (userInfo["Total Time"] as? NSNumber)?.doubleValue,
           milliseconds.isFinite, milliseconds > 0, milliseconds < 48 * 3600 * 1000 {
            duration = milliseconds / 1000
        }
        let stopped = state == .stopped
        return NowPlaying(sourceID: PlaybackSourceIdentity.appleMusic.sourceID, appName: "Music",
                          title: stopped ? nil : text("Name"), artist: stopped ? nil : text("Artist"),
                          album: stopped ? nil : text("Album"), state: state, duration: stopped ? nil : duration,
                          updatedAt: now)
    }
}

/// Delivers Music's player-info payloads on the main actor.
@MainActor
protocol PlayerInfoFeed: AnyObject {
    func subscribe(_ handler: @escaping @MainActor ([AnyHashable: Any]) -> Void) -> AnyObject
    func unsubscribe(_ token: AnyObject)
}

/// The real feed. `.deliverImmediately`: AppKit otherwise holds distributed
/// notifications while the app is inactive, which Orbit (an accessory app)
/// almost always is.
@MainActor
final class DistributedPlayerInfoFeed: PlayerInfoFeed {
    /// Registered from the main thread, so AppKit delivers on the main thread.
    @MainActor private final class Relay: NSObject {
        let handler: @MainActor ([AnyHashable: Any]) -> Void
        init(_ handler: @escaping @MainActor ([AnyHashable: Any]) -> Void) { self.handler = handler }
        @objc func received(_ note: Notification) { handler(note.userInfo ?? [:]) }
    }

    func subscribe(_ handler: @escaping @MainActor ([AnyHashable: Any]) -> Void) -> AnyObject {
        let relay = Relay(handler)
        DistributedNotificationCenter.default().addObserver(relay, selector: #selector(Relay.received(_:)),
                                                            name: AppleMusicSource.playerInfo, object: nil,
                                                            suspensionBehavior: .deliverImmediately)
        return relay
    }

    func unsubscribe(_ token: AnyObject) {
        DistributedNotificationCenter.default().removeObserver(token)
    }
}
