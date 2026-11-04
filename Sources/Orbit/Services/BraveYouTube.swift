import Darwin
import Foundation
import OrbitBridge

// YouTube in Brave, through Orbit's extension and its native messaging
// helper (OrbitBraveHelper). The helper connects to Orbit's local socket;
// nothing reaches Orbit unless the user installed both. All in memory.

/// Orbit's end of the local socket: accepts the helper (current user only),
/// reads its messages and sends commands back.
@MainActor
final class BrowserBridgeServer {
    let path: String
    var onMessage: ((BridgeMessage, Int) -> Void)?
    var onDisconnect: ((Int) -> Void)?
    private var listener: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextID = 0

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var decoder = FrameDecoder()
        var messages = 0
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    /// Brave runs one helper; a second appears briefly when its extension restarts.
    private static let maxConnections = 4

    init(path: String) { self.path = path }

    var isListening: Bool { listener != nil }
    var connectionCount: Int { connections.count }

    func start() throws(UnixSocket.Failure) {
        guard listener == nil else { return }
        let fd = try UnixSocket.listen(at: path)
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.accept(fd) } }
        source.setCancelHandler { close(fd) }
        source.resume()
        listener = source
    }

    func stop() {
        guard let listener else { return }
        listener.cancel()
        self.listener = nil
        unlink(path)
        for id in connections.keys { drop(id, notify: false) }
    }

    /// False when that helper is gone (it's dropped).
    func send(_ command: BridgeCommand, to id: Int) -> Bool {
        guard let connection = connections[id] else { return false }
        guard UnixSocket.writeAll(connection.fd, BridgeFraming.frame(BridgeMessage.command(command).encoded())) else {
            drop(id)
            return false
        }
        return true
    }

    private func accept(_ listener: Int32) {
        guard let fd = UnixSocket.accept(listener) else { return }
        guard connections.count < Self.maxConnections else {
            close(fd)
            return
        }
        nextID += 1
        let id = nextID
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.read(id) } }
        source.setCancelHandler { close(fd) }
        connections[id] = Connection(fd: fd, source: source)
        source.resume()
        log.notice("brave: helper connected")
    }

    private func read(_ id: Int) {
        guard let connection = connections[id] else { return }
        guard let chunk = UnixSocket.readChunk(connection.fd) else { return drop(id) }
        connection.decoder.append(chunk)
        do {
            while let payload = try connection.decoder.next() {
                let message: BridgeMessage
                do {
                    message = try BridgeMessage.decode(payload)
                } catch {
                    log.error("brave: ignored an invalid message (\(error.description, privacy: .public))")
                    continue
                }
                if case .command = message { continue }  // commands only go to the browser
                connection.messages += 1
                if connection.messages == 1 { log.notice("brave: first message from the helper decoded") }
                onMessage?(message, id)
                guard connections[id] != nil else { return }
            }
        } catch {
            log.error("brave: bad frame (\(String(describing: error), privacy: .public)); disconnecting")
            drop(id)
        }
    }

    private func drop(_ id: Int, notify: Bool = true) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()  // closes the socket
        log.notice("brave: helper disconnected after \(connection.messages, privacy: .public) message(s)")
        if notify { onDisconnect?(id) }
    }
}

/// YouTube playing in Brave: one entry per open YouTube tab, and the tab to
/// show is chosen the way the coordinator chooses between apps, with the tab
/// Brave says is making sound first.
@MainActor
final class BraveYouTubeSource: PlaybackSource {
    nonisolated static let bundleIdentifier = PlaybackSourceIdentity.braveYouTube.bundleIdentifier
    nonisolated static let sourceID = PlaybackSourceIdentity.braveYouTube.sourceID

    let id = BraveYouTubeSource.sourceID
    let displayName = PlaybackSourceIdentity.braveYouTube.displayName
    var capabilities: PlaybackCapabilities { [.playPause, .seek] }

    struct Tab: Equatable {
        var playback: TabPlayback
        var connection: Int
        var updatedAt: Date
    }

    let server: BrowserBridgeServer
    private let clock: () -> Date
    private(set) var tabs: [Int: Tab] = [:]
    private(set) var selectedTab: Int?
    private var onChange: (@MainActor (PlaybackSourceStatus) -> Void)?

    private static let maxTabs = 64

    init(socketPath: String = UnixSocket.defaultPath, clock: @escaping () -> Date = { .now }) {
        server = BrowserBridgeServer(path: socketPath)
        self.clock = clock
        server.onMessage = { [weak self] message, connection in self?.receive(message, from: connection) }
        server.onDisconnect = { [weak self] connection in self?.disconnected(connection) }
    }

    func start(onChange: @escaping @MainActor (PlaybackSourceStatus) -> Void) {
        stop()
        self.onChange = onChange
        onChange(.inactive)
        do {
            try server.start()
            log.notice("brave: listening at \(self.server.path, privacy: .public)")
        } catch {
            log.error("brave: not listening (\(error.description, privacy: .public))")
        }
    }

    func stop() {
        server.stop()
        tabs = [:]
        selectedTab = nil
        onChange = nil
    }

    func receive(_ message: BridgeMessage, from connection: Int) {
        switch message {
        case .update(let playback):
            log.debug("brave: tab \(playback.tab, privacy: .public) \(playback.state.rawValue, privacy: .public) at \(playback.position, format: .fixed(precision: 1), privacy: .public) s")
            guard tabs[playback.tab] != nil || tabs.count < Self.maxTabs else { return }
            tabs[playback.tab] = Tab(playback: playback, connection: connection, updatedAt: clock())
        case .closed(let tab):
            guard tabs[tab]?.connection == connection else { return }
            tabs[tab] = nil
        case .command:
            return
        }
        publish()
    }

    /// The helper went away (Brave quit, or the extension let go): its tabs are gone.
    func disconnected(_ connection: Int) {
        tabs = tabs.filter { $0.value.connection != connection }
        publish()
    }

    /// The tab making sound first; then silent tabs (muted or paused) by most
    /// recent update, so pausing your video doesn't hand the widget to a muted
    /// autoplay elsewhere; ended last.
    static func select(_ tabs: some Collection<Tab>) -> Tab? {
        func rank(_ tab: Tab) -> Int {
            switch tab.playback.state {
            case .playing: tab.playback.audible && !tab.playback.muted ? 2 : 1
            case .paused: 1
            case .ended: 0
            }
        }
        return tabs.max { a, b in
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.updatedAt != b.updatedAt { return a.updatedAt < b.updatedAt }
            return a.playback.tab < b.playback.tab
        }
    }

    static func item(_ tab: Tab) -> NowPlaying {
        let playback = tab.playback
        let state: PlaybackState = switch playback.state {
        case .playing: .playing
        case .paused: .paused
        case .ended: .stopped
        }
        var capabilities: PlaybackCapabilities = [.playPause]
        if playback.duration != nil, !playback.ad { capabilities.insert(.seek) }
        return NowPlaying(sourceID: sourceID, appName: playback.site == .music ? "YouTube Music" : "YouTube",
                          title: playback.title, artist: playback.channel, album: playback.album, state: state,
                          duration: playback.duration, position: playback.position,
                          positionAt: Date(timeIntervalSince1970: playback.at / 1000), playbackRate: playback.rate,
                          capabilities: capabilities,
                          artwork: BridgeMessage.artworkURL(playback.artwork).map(ArtworkReference.url),
                          isAd: playback.ad, itemID: itemID(playback), updatedAt: tab.updatedAt)
    }

    /// The tab and the video in it.
    static func itemID(_ playback: TabPlayback) -> String { "\(playback.tab)/\(playback.videoID ?? "-")" }

    /// Sent only to the tab and video the user saw (`item`): if the widget has
    /// moved on, the command is refused here, and a tab that has moved to
    /// another video ignores it too (it carries the video id). Seeks are
    /// clamped to 0…duration and shown at once, before Brave confirms them.
    func perform(_ command: PlaybackCommand, on item: NowPlaying) async throws {
        guard let selectedTab, let tab = tabs[selectedTab] else {
            throw PlaybackSourceError(message: "Nothing is playing on YouTube.")
        }
        guard item.sourceID == id, item.itemID == Self.itemID(tab.playback) else {
            throw PlaybackSourceError(message: "That video is no longer on screen.")
        }
        let playback = tab.playback
        let bridgeCommand: BridgeCommand
        switch command {
        case .togglePlayPause:
            bridgeCommand = BridgeCommand(tab: playback.tab, videoID: playback.videoID,
                                          action: playback.state == .playing ? .pause : .play)
        case .seek, .skip:
            guard let duration = playback.duration, !playback.ad else {
                throw PlaybackSourceError(message: "This video can't be skipped through.")
            }
            let requested = switch command {
            case .skip(let delta): (Self.item(tab).elapsed(at: clock()) ?? playback.position) + delta
            case .seek(let position): position
            default: playback.position
            }
            bridgeCommand = BridgeCommand(tab: playback.tab, videoID: playback.videoID, action: .seek,
                                          position: min(max(requested, 0), duration))
        case .next, .previous:
            throw PlaybackSourceError(message: "YouTube can't skip tracks from Orbit.")
        }
        guard server.send(bridgeCommand, to: tab.connection) else {
            throw PlaybackSourceError(message: "Brave isn't connected.")
        }
        if bridgeCommand.action == .seek, let position = bridgeCommand.position {
            tabs[selectedTab]?.playback.position = position
            tabs[selectedTab]?.playback.at = clock().timeIntervalSince1970 * 1000
            publish()
        }
    }

    private func publish() {
        guard let onChange else { return }
        if let tab = Self.select(tabs.values) {
            if selectedTab != tab.playback.tab {
                log.notice("brave: showing tab \(tab.playback.tab, privacy: .public) of \(self.tabs.count, privacy: .public)")
            }
            selectedTab = tab.playback.tab
            onChange(.playing(Self.item(tab)))
        } else {
            selectedTab = nil
            onChange(.inactive)
        }
    }
}
