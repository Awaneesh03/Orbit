import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Orbit
@testable import OrbitBridge

// Stage 3.7D: YouTube in Brave. Native message framing and validation, the
// local socket, tab selection, the helper's lifecycle and the widget. Real
// sockets and pipes in a temporary folder; nothing talks to Brave.

private func playback(_ tab: Int, _ title: String = "Video", _ state: VideoState = .playing, audible: Bool = false,
                      position: Double = 10, duration: Double? = 200, at: Double = 1_000_000) -> TabPlayback {
    TabPlayback(tab: tab, state: state, audible: audible, videoID: "vid\(tab)", title: title, channel: "Channel \(tab)",
                artwork: "https://i.ytimg.com/vi/vid\(tab)/hqdefault.jpg", position: position, duration: duration,
                rate: state == .playing ? 1 : 0, at: at)
}

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// A short folder for a socket (paths are limited to 103 bytes).
private func socketPath() -> (path: String, cleanup: () -> Void) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ob-\(UUID().uuidString.prefix(8))")
    return (folder.appending(path: "b.sock").path(percentEncoded: false), { try? FileManager.default.removeItem(at: folder) })
}

/// Lets the main queue deliver socket events until `condition` holds (2 s at most).
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

/// Reads whatever frames have arrived on a non-blocking descriptor.
private struct FrameReader {
    let fd: Int32
    var decoder = FrameDecoder()
    init(_ fd: Int32) {
        self.fd = fd
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }
    mutating func messages() -> [BridgeMessage] {
        var buffer = [UInt8](repeating: 0, count: 65536)
        while case let count = read(fd, &buffer, buffer.count), count > 0 { decoder.append(Data(buffer[..<count])) }
        var result: [BridgeMessage] = []
        while let payload = try? decoder.next(), let message = try? BridgeMessage.decode(payload) { result.append(message) }
        return result
    }
}

// MARK: Framing and validation

@Test func nativeFramesAreSplitAndBadLengthsRejected() throws {
    let a = Data(#"{"type":"closed","tab":1}"#.utf8), b = Data(#"{"type":"closed","tab":2}"#.utf8)
    let stream = BridgeFraming.frame(a) + BridgeFraming.frame(b)
    var decoder = FrameDecoder()
    var payloads: [Data] = []
    for byte in stream {  // one byte at a time: frames still come out whole
        decoder.append(Data([byte]))
        while let payload = try decoder.next() { payloads.append(payload) }
    }
    #expect(payloads == [a, b])
    #expect(BridgeFraming.frame(a).prefix(4) == Data([UInt8(a.count), 0, 0, 0]))  // little-endian length

    var empty = FrameDecoder()
    empty.append(Data([0, 0, 0, 0]))
    #expect(throws: FrameDecoder.Failure.empty) { try empty.next() }
    var oversized = FrameDecoder()
    var length = UInt32(BridgeFraming.maxMessageBytes + 1).littleEndian
    oversized.append(Data(bytes: &length, count: 4))
    #expect(throws: FrameDecoder.Failure.tooLarge(BridgeFraming.maxMessageBytes + 1)) { try oversized.next() }
    var largest = FrameDecoder()
    largest.append(BridgeFraming.frame(Data(repeating: 0x20, count: BridgeFraming.maxMessageBytes)))
    #expect(try largest.next()?.count == BridgeFraming.maxMessageBytes)
}

@Test func messagesAreValidated() throws {
    let base: [String: Any] = ["type": "update", "tab": 7, "site": "youtube", "state": "playing", "audible": true,
                               "muted": false, "ad": false, "position": 12.5, "rate": 1, "at": 1_700_000_000_000.0]
    func decode(_ changes: [String: Any]) throws -> BridgeMessage { try BridgeMessage.decode(json(base.merging(changes) { $1 })) }

    guard case .update(let ok) = try decode([
        "title": "  A \u{0007}title\n ", "channel": String(repeating: "c", count: 500), "videoID": "dQw4w9WgXcQ",
        "artwork": "https://i.ytimg.com/vi/x/hqdefault.jpg", "duration": 212, "album": "",
    ]) else { Issue.record("not an update"); return }
    #expect(ok.title == "A title" && ok.channel?.count == 200 && ok.album == nil)  // cleaned and capped
    #expect(ok.videoID == "dQw4w9WgXcQ" && ok.duration == 212 && ok.artwork == "https://i.ytimg.com/vi/x/hqdefault.jpg")
    #expect(try BridgeMessage.decode(BridgeMessage.update(ok).encoded()) == .update(ok))  // round trip

    // Kept, but the bad field is dropped.
    for (key, value) in [("artwork", "http://i.ytimg.com/a.jpg"), ("artwork", "https://evil.example/a.jpg"),
                         ("artwork", "https://i.ytimg.com.evil.example/a.jpg"), ("videoID", "../../etc"),
                         ("duration", -3), ("duration", 1e12)] as [(String, Any)] {
        guard case .update(let kept) = try decode([key: value]) else { Issue.record("dropped: \(key)"); continue }
        #expect(kept.artwork == nil && kept.videoID == nil && kept.duration == nil)
    }
    // Rejected outright.
    for bad: [String: Any] in [["tab": -1], ["tab": 1e12], ["position": -1], ["position": 1e9], ["rate": 99],
                               ["at": 0], ["state": "rewinding"], ["site": "vimeo"], ["title": 42], ["type": "eval"]] {
        #expect(throws: BridgeError.self) { try decode(bad) }
    }
    #expect(throws: BridgeError.self) { try BridgeMessage.decode(Data("not json".utf8)) }
    #expect(throws: BridgeError.self) { try BridgeMessage.decode(json(["type": "update", "tab": 1])) }  // fields missing
    #expect(try BridgeMessage.decode(json(["type": "closed", "tab": 3])) == .closed(tab: 3))
    #expect(throws: BridgeError.self) { try BridgeMessage.decode(json(["type": "command", "tab": 3, "action": "seek"])) }
    #expect(try BridgeMessage.decode(json(["type": "command", "tab": 3, "action": "pause", "position": 4]))
        == .command(BridgeCommand(tab: 3, videoID: nil, action: .pause)))  // a stray position is dropped
}

// MARK: Mapping and tab selection

@MainActor @Test func playbackMapsOntoNowPlaying() {
    let date = Date(timeIntervalSince1970: 50)
    let item = BraveYouTubeSource.item(.init(playback: playback(4, "Talk", at: 1_000_000), connection: 1, updatedAt: date))
    #expect(item.sourceID == "brave-youtube" && item.appName == "YouTube" && item.title == "Talk" && item.artist == "Channel 4")
    #expect(item.state == .playing && item.position == 10 && item.duration == 200 && item.playbackRate == 1)
    #expect(item.positionAt == Date(timeIntervalSince1970: 1000) && item.updatedAt == date)
    #expect(item.artwork == .url(URL(string: "https://i.ytimg.com/vi/vid4/hqdefault.jpg")!))
    #expect(item.capabilities == [.playPause, .seek])

    for (state, expected) in [(VideoState.paused, PlaybackState.paused), (.ended, .stopped), (.playing, .playing)] {
        #expect(BraveYouTubeSource.item(.init(playback: playback(1, "Video", state), connection: 1, updatedAt: date)).state == expected)
    }
    var music = playback(2)
    music.site = .music
    music.album = "Album"
    #expect(BraveYouTubeSource.item(.init(playback: music, connection: 1, updatedAt: date)).appName == "YouTube Music")
    var ad = playback(3)
    ad.ad = true
    let adItem = BraveYouTubeSource.item(.init(playback: ad, connection: 1, updatedAt: date))
    #expect(adItem.isAd && adItem.capabilities == [.playPause])  // no seeking through an ad
    #expect(BraveYouTubeSource.item(.init(playback: playback(5, duration: nil), connection: 1, updatedAt: date))
        .capabilities == [.playPause])  // live: nothing to seek in
}

@MainActor @Test func theAudibleTabWinsAndTabsNeverMix() {
    var now = Date(timeIntervalSince1970: 0)
    let source = BraveYouTubeSource(socketPath: "/nonexistent/x.sock", clock: { now })
    var statuses: [PlaybackSourceStatus] = []
    source.start { statuses.append($0) }
    func current() -> NowPlaying? { if case .playing(let item)? = statuses.last { item } else { nil } }

    source.receive(.update(playback(1, "Muted autoplay", audible: false)), from: 1)
    now += 1
    source.receive(.update(playback(2, "Paused lecture", .paused)), from: 1)
    #expect(current()?.title == "Paused lecture")  // neither makes sound: the most recent
    now += 1
    source.receive(.update(playback(3, "Song", audible: true)), from: 1)
    now += 1
    source.receive(.update(playback(1, "Muted autoplay", audible: false, position: 30)), from: 1)
    #expect(current()?.title == "Song" && source.selectedTab == 3)  // making sound beats newer but silent

    now += 1
    source.receive(.update(playback(3, "Next song", audible: true)), from: 1)  // metadata change in the same tab
    #expect(current()?.title == "Next song" && current()?.artist == "Channel 3")
    #expect(source.tabs[1]?.playback.title == "Muted autoplay")  // other tabs untouched

    source.receive(.closed(tab: 3), from: 2)  // another helper can't close this one's tab
    #expect(source.selectedTab == 3)
    source.receive(.closed(tab: 3), from: 1)
    #expect(current()?.title == "Muted autoplay")
    source.receive(.update(playback(1, "Muted autoplay", .paused)), from: 1)
    now += 1
    source.receive(.update(playback(2, "Paused lecture", .paused)), from: 1)
    #expect(current()?.title == "Paused lecture")  // both paused: the most recent

    source.receive(.update(playback(9, "Other window")), from: 2)
    source.disconnected(1)  // that helper is gone: only its tabs go
    #expect(current()?.title == "Other window" && source.tabs.keys.sorted() == [9])
    source.disconnected(2)
    #expect(statuses.last == .inactive && source.selectedTab == nil)
    source.stop()
}

@MainActor @Test func coordinatorKeepsItsRulesAcrossMusicAndYouTube() {
    let feed = MockMusicFeed()
    let brave = BraveYouTubeSource(socketPath: "/nonexistent/x.sock", clock: { Date(timeIntervalSince1970: 100) })
    let coordinator = PlaybackCoordinator()
    coordinator.register(AppleMusicSource(feed: feed, isMusicRunning: { true }, workspace: NotificationCenter(),
                                          bundleOf: { _ in nil }, clock: { Date(timeIntervalSince1970: 50) }))
    coordinator.register(brave)
    coordinator.start()
    feed.send(["Name": "Song", "Artist": "Band", "Player State": "Paused"])
    #expect(coordinator.current?.sourceID == "apple-music")
    brave.receive(.update(playback(1, "Video")), from: 1)
    #expect(coordinator.current?.sourceID == "brave-youtube")  // playing beats paused
    brave.receive(.update(playback(1, "Video", .paused)), from: 1)
    #expect(coordinator.current?.sourceID == "brave-youtube")  // both paused: YouTube is more recent
    feed.send(["Name": "Song", "Artist": "Band", "Player State": "Playing"])
    #expect(coordinator.current?.sourceID == "apple-music")
    let updates = coordinator.updateCount
    brave.receive(.update(playback(1, "Video", .paused)), from: 1)  // the same again
    #expect(coordinator.updateCount == updates)
    coordinator.stop()
}

// MARK: Socket

@MainActor @Test func socketIsPrivateAndFollowsConnections() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let source = BraveYouTubeSource(socketPath: path)
    var statuses: [PlaybackSourceStatus] = []
    source.start { statuses.append($0) }
    defer { source.stop() }
    #expect(source.server.isListening)

    var info = stat()
    #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600 && info.st_mode & S_IFMT == S_IFSOCK)
    #expect(lstat((path as NSString).deletingLastPathComponent, &info) == 0 && info.st_mode & 0o777 == 0o700)
    #expect(throws: UnixSocket.Failure.self) { try UnixSocket.listen(at: path) }  // a live socket isn't taken over

    let client = try UnixSocket.connect(to: path)
    #expect(await eventually { source.server.connectionCount == 1 })
    #expect(UnixSocket.writeAll(client, BridgeFraming.frame(Data("{\"type\":\"nonsense\"}".utf8))))  // ignored
    #expect(UnixSocket.writeAll(client, BridgeFraming.frame(BridgeMessage.update(playback(5, "Hello")).encoded())))
    #expect(await eventually { source.tabs[5] != nil })
    #expect(source.server.connectionCount == 1)  // an invalid message doesn't cost the connection
    close(client)
    #expect(await eventually { statuses.last == .inactive && source.server.connectionCount == 0 })  // disconnect clears

    let rude = try UnixSocket.connect(to: path)
    var length = UInt32(1 << 30).littleEndian
    #expect(UnixSocket.writeAll(rude, Data(bytes: &length, count: 4)))  // a 1 GiB claim: dropped
    #expect(await eventually { source.server.connectionCount == 0 })
    close(rude)

    source.stop()
    #expect(lstat(path, &info) != 0)  // the socket file is removed
    #expect(throws: UnixSocket.Failure.self) { try UnixSocket.connect(to: path) }

    // Never anything that isn't a socket, and never a folder that isn't ours.
    FileManager.default.createFile(atPath: path, contents: Data("keep me".utf8))
    #expect(throws: UnixSocket.Failure.self) { try UnixSocket.listen(at: path) }
    #expect(FileManager.default.contents(atPath: path) == Data("keep me".utf8))
    #expect(throws: UnixSocket.Failure.self) { try UnixSocket.listen(at: "/private/var/x.sock") }
    #expect(throws: UnixSocket.Failure.self) { try UnixSocket.listen(at: "/tmp/" + String(repeating: "x", count: 120)) }
}

@MainActor @Test func commandsGoOnlyToTheTabOnScreen() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let source = BraveYouTubeSource(socketPath: path)
    var statuses: [PlaybackSourceStatus] = []
    source.start { statuses.append($0) }
    defer { source.stop() }
    func shown() -> NowPlaying? { if case .playing(let item)? = statuses.last { item } else { nil } }
    let nothing = BraveYouTubeSource.item(.init(playback: playback(1), connection: 1, updatedAt: .now))
    await #expect(throws: PlaybackSourceError.self) { try await source.perform(.togglePlayPause, on: nothing) }  // nothing yet

    let client = try UnixSocket.connect(to: path)
    defer { close(client) }
    var reader = FrameReader(client)
    for message in [BridgeMessage.update(playback(1, "Quiet", .paused)), .update(playback(2, "Loud", audible: true))] {
        #expect(UnixSocket.writeAll(client, BridgeFraming.frame(message.encoded())))
    }
    #expect(await eventually { source.selectedTab == 2 })
    let loud = try #require(shown())
    try await source.perform(.togglePlayPause, on: loud)
    try await source.perform(.seek(500), on: loud)
    var received: [BridgeMessage] = []
    #expect(await eventually { received += reader.messages(); return received.count == 2 })
    #expect(received == [.command(BridgeCommand(tab: 2, videoID: "vid2", action: .pause)),
                         .command(BridgeCommand(tab: 2, videoID: "vid2", action: .seek, position: 200))])  // clamped
    await #expect(throws: PlaybackSourceError.self) { try await source.perform(.next, on: loud) }
    // The quiet tab, though connected, was never sent anything.
    #expect(!received.contains { if case .command(let command) = $0 { command.tab == 1 } else { false } })
}

@MainActor @Test func skippingMovesFromWherePlaybackIsNowAndStaysInTheVideo() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    var now = Date(timeIntervalSince1970: 1000)
    let source = BraveYouTubeSource(socketPath: path, clock: { now })
    let coordinator = PlaybackCoordinator()
    coordinator.register(source)
    coordinator.start()
    defer { coordinator.stop() }
    let client = try UnixSocket.connect(to: path)
    defer { close(client) }
    var reader = FrameReader(client)
    // Playing from 30 s at 1000 s, 1.5×, in a 100 s video.
    var video = playback(3, "Video", position: 30, duration: 100, at: 1_000_000)
    video.rate = 1.5
    #expect(UnixSocket.writeAll(client, BridgeFraming.frame(BridgeMessage.update(video).encoded())))
    #expect(await eventually { coordinator.current?.title == "Video" })
    func seeks() async -> [Double] {
        var positions: [Double] = []
        _ = await eventually {
            for case .command(let command) in reader.messages() { positions.append(command.position ?? -1) }
            return !positions.isEmpty
        }
        return positions
    }

    now += 4  // 30 + 4 × 1.5 = 36 s now
    try await coordinator.perform(.skip(10), on: try #require(coordinator.current))
    #expect(await seeks() == [46])
    #expect(coordinator.current?.position == 46)  // shown at once, before Brave confirms
    #expect(coordinator.current?.elapsed(at: now) == 46)
    try await coordinator.perform(.skip(-10), on: try #require(coordinator.current))
    #expect(await seeks() == [36])
    #expect(coordinator.current?.position == 36)

    try await coordinator.perform(.skip(-60), on: try #require(coordinator.current))
    #expect(await seeks() == [0])  // never before the start
    try await coordinator.perform(.skip(500), on: try #require(coordinator.current))
    #expect(await seeks() == [100])  // never past the end
    #expect(coordinator.current?.progress(at: now) == 1)
}

@MainActor @Test func seekingIsRefusedWhenItCantBeDoneOrTheVideoMovedOn() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let source = BraveYouTubeSource(socketPath: path)
    let coordinator = PlaybackCoordinator()
    coordinator.register(source)
    coordinator.start()
    defer { coordinator.stop() }
    let client = try UnixSocket.connect(to: path)
    defer { close(client) }
    var reader = FrameReader(client)
    func send(_ value: TabPlayback) async {
        _ = UnixSocket.writeAll(client, BridgeFraming.frame(BridgeMessage.update(value).encoded()))
        _ = await eventually { coordinator.current?.itemID == BraveYouTubeSource.itemID(value) && coordinator.current?.isAd == value.ad
            && coordinator.current?.duration == value.duration }
    }

    var ad = playback(1, "Video")
    ad.ad = true
    await send(ad)
    var item = try #require(coordinator.current)
    #expect(!PlaybackControls.availability(item).seek && PlaybackControls.availability(item).controls)
    await #expect(throws: PlaybackSourceError.self) { try await coordinator.perform(.skip(10), on: item) }  // an ad

    await send(playback(1, "Live", duration: nil))
    item = try #require(coordinator.current)
    #expect(!PlaybackControls.availability(item).seek)
    await #expect(throws: PlaybackSourceError.self) { try await coordinator.perform(.skip(-10), on: item) }  // live

    await send(playback(1, "Video A"))
    let stale = try #require(coordinator.current)
    #expect(PlaybackControls.availability(stale).seek)
    var next = playback(1, "Video B")
    next.videoID = "vidB"
    await send(next)  // the tab moved to another video before the click arrived
    await #expect(throws: PlaybackSourceError.self) { try await coordinator.perform(.skip(10), on: stale) }
    await #expect(throws: PlaybackSourceError.self) { try await coordinator.perform(.togglePlayPause, on: stale) }

    await send(playback(2, "Other tab", audible: true))  // another tab took over the widget
    let otherItemFromTab1 = BraveYouTubeSource.item(.init(playback: next, connection: 1, updatedAt: .now))
    await #expect(throws: PlaybackSourceError.self) { try await coordinator.perform(.skip(10), on: otherItemFromTab1) }

    try? await Task.sleep(for: .milliseconds(50))
    #expect(reader.messages().isEmpty)  // nothing at all reached the browser

    let music = NowPlaying(sourceID: "apple-music", appName: "Music", title: "Song", state: .playing, duration: 200,
                           updatedAt: .now)
    #expect(!PlaybackControls.availability(music).controls && !PlaybackControls.availability(music).seek)  // Music: no buttons
}

// MARK: Helper lifecycle

@MainActor @Test func helperRelaysBothWaysReconnectsAndExitsWithBrave() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    var stdin: [Int32] = [0, 0], stdout: [Int32] = [0, 0]
    #expect(pipe(&stdin) == 0 && pipe(&stdout) == 0)
    defer { close(stdin[1]); close(stdout[0]); close(stdout[1]) }
    var exitCode: Int32?
    let host = NativeHost(input: stdin[0], output: stdout[1], socketPath: path, retryInterval: .milliseconds(50)) { exitCode = $0 }
    var browser = FrameReader(stdout[0])
    host.start()  // Orbit isn't running yet: the helper keeps trying
    #expect(!host.isConnected)
    func fromBrave(_ message: BridgeMessage) { _ = UnixSocket.writeAll(stdin[1], BridgeFraming.frame(message.encoded())) }
    fromBrave(.update(playback(4, "Before Orbit")))
    #expect(await eventually { host.tabs[4] != nil })

    let source = BraveYouTubeSource(socketPath: path)
    var statuses: [PlaybackSourceStatus] = []
    source.start { statuses.append($0) }
    #expect(await eventually { source.tabs[4]?.playback.title == "Before Orbit" })  // replayed on connect

    fromBrave(.update(playback(4, "Changed")))
    fromBrave(.command(BridgeCommand(tab: 4, videoID: nil, action: .pause)))  // Brave can't send commands
    _ = UnixSocket.writeAll(stdin[1], BridgeFraming.frame(Data("{\"type\":\"update\",\"tab\":-4}".utf8)))  // invalid: dropped
    #expect(await eventually { source.tabs[4]?.playback.title == "Changed" })
    let shown = try #require(source.tabs[4].map(BraveYouTubeSource.item))
    try await source.perform(.togglePlayPause, on: shown)
    var commands: [BridgeMessage] = []
    #expect(await eventually { commands += browser.messages(); return !commands.isEmpty })
    #expect(commands == [.command(BridgeCommand(tab: 4, videoID: "vid4", action: .pause))])

    source.stop()  // Orbit quits
    #expect(await eventually { !host.isConnected })
    source.start { statuses.append($0) }  // and comes back
    #expect(await eventually { source.tabs[4]?.playback.title == "Changed" })

    fromBrave(.closed(tab: 4))
    #expect(await eventually { source.tabs.isEmpty && host.tabs.isEmpty })
    fromBrave(.update(playback(6, "Last")))
    #expect(await eventually { source.tabs[6] != nil })
    close(stdin[1])  // Brave lets go
    stdin[1] = -1
    #expect(await eventually { exitCode == 0 })
    #expect(await eventually { source.tabs.isEmpty && statuses.last == .inactive })  // its tabs are cleared
    source.stop()
    close(stdin[0])
}

@MainActor @Test func helperExitsOnAnOversizedFrame() async {
    var stdin: [Int32] = [0, 0], stdout: [Int32] = [0, 0]
    #expect(pipe(&stdin) == 0 && pipe(&stdout) == 0)
    defer { [stdin[0], stdin[1], stdout[0], stdout[1]].forEach { close($0) } }
    var exitCode: Int32?
    let host = NativeHost(input: stdin[0], output: stdout[1], socketPath: "/nonexistent/x.sock",
                          retryInterval: .seconds(60)) { exitCode = $0 }
    host.start()
    var length = UInt32(BridgeFraming.maxMessageBytes + 1).littleEndian
    _ = UnixSocket.writeAll(stdin[1], Data(bytes: &length, count: 4))
    #expect(await eventually { exitCode == 1 })
}

// MARK: Widget

@Test func progressFollowsThePlaybackRate() {
    let start = Date(timeIntervalSince1970: 1000)
    var item = NowPlaying(sourceID: "brave-youtube", appName: "YouTube", state: .playing, duration: 100, position: 20,
                          positionAt: start, playbackRate: 1.5, updatedAt: start)
    #expect(item.elapsed(at: start + 10) == 35 && item.progress(at: start + 10) == 0.35)
    #expect(item.elapsed(at: start + 1000) == 100 && item.progress(at: start + 1000) == 1)  // never past the end
    #expect(item.elapsed(at: start - 5) == 20)  // a clock that's behind doesn't rewind
    item.playbackRate = 0  // buffering
    #expect(item.elapsed(at: start + 10) == 20)
    item.state = .paused
    item.playbackRate = 1
    #expect(item.elapsed(at: start + 10) == 20)
    item.duration = nil
    #expect(item.elapsed(at: start) == 20 && item.progress(at: start) == nil)  // live
    item.position = nil
    #expect(item.elapsed(at: start) == nil)  // Music: no position
}

@MainActor @Test func youTubeWidgetRendering() throws {
    let source = BraveYouTubeSource(socketPath: "/nonexistent/x.sock")
    let coordinator = PlaybackCoordinator()
    coordinator.register(source)
    let widget = NowPlayingWidget(coordinator: coordinator)
    #expect(widget.state == .empty("Nothing is playing in Music or on YouTube."))
    let thumbnail = URL(string: "https://i.ytimg.com/vi/vid1/hqdefault.jpg")!
    let image = try #require(NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in
        NSColor(red: 0.85, green: 0.25, blue: 0.3, alpha: 1).setFill()
        rect.fill()
        return true
    }.cgImage(forProposedRect: nil, context: nil, hints: nil))
    ArtworkLoader.shared.store(image, for: thumbnail)
    var paused = playback(1, "A long video title about Swift concurrency", .paused, position: 75, duration: 300,
                          at: Date.now.timeIntervalSince1970 * 1000)
    source.receive(.update(paused), from: 1)
    #expect(widget.state == .ready)
    let compact = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
    let expanded = try #require(render(WidgetHost(widget: widget, presentation: .expanded), size: CGSize(width: 468, height: 160)))
    paused.artwork = nil  // no thumbnail: Brave's icon instead
    paused.title = nil
    source.receive(.update(paused), from: 1)
    let bare = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
    #expect(compact.pixels != bare.pixels && expanded.width == 468)

    if let folder = ProcessInfo.processInfo.environment["ORBIT_RENDER_DIR"] {
        source.receive(.update(playback(1, "A long video title about Swift concurrency", .paused, position: 75, duration: 300,
                                        at: Date.now.timeIntervalSince1970 * 1000)), from: 1)
        for (name, presentation, width) in [("youtube-compact", WidgetPresentation.compact, 229.0),
                                            ("youtube-expanded", .expanded, 468.0)] {
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

@MainActor
private final class MockMusicFeed: PlayerInfoFeed {
    private var handler: (@MainActor ([AnyHashable: Any]) -> Void)?
    func subscribe(_ handler: @escaping @MainActor ([AnyHashable: Any]) -> Void) -> AnyObject {
        self.handler = handler
        return NSObject()
    }
    func unsubscribe(_ token: AnyObject) { handler = nil }
    func send(_ userInfo: [AnyHashable: Any]) { handler?(userInfo) }
}

@MainActor @Test func youTubeReplacesMusicsWaitingMessage() {
    let brave = BraveYouTubeSource(socketPath: "/nonexistent/x.sock")
    let coordinator = PlaybackCoordinator()
    coordinator.register(AppleMusicSource(feed: MockMusicFeed(), isMusicRunning: { true }, workspace: NotificationCenter(),
                                          bundleOf: { _ in nil }))
    coordinator.register(brave)
    let widget = NowPlayingWidget(coordinator: coordinator)  // starts listening, as at launch
    #expect(coordinator.isWaiting && coordinator.current == nil)  // "Music is open…"
    brave.receive(.update(playback(1, "Real video")), from: 1)
    #expect(!coordinator.isWaiting && coordinator.current?.sourceID == "brave-youtube" && widget.state == .ready)
    brave.disconnected(1)
    #expect(coordinator.isWaiting)  // back to Music's message
    coordinator.stop()
}
