import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Orbit
@testable import OrbitBridge

// Stage 3.7F-4: the Music Island's motion. Linear Core Animation progress,
// press feedback, the play/pause icon, and Reduce Motion everywhere.

@MainActor
private func trackInWindow(width: CGFloat = 200) -> (ProgressTrackView, NSWindow) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 40), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.alphaValue = 0  // never on screen
    window.isReleasedWhenClosed = false
    let track = ProgressTrackView(frame: NSRect(x: 0, y: 0, width: width, height: 6))
    window.contentView?.addSubview(track)
    track.layout()
    return (track, window)
}

private func song(_ state: PlaybackState, position: Double, duration: Double? = 100, rate: Double = 1,
                  at date: Date = .now, ad: Bool = false) -> NowPlaying {
    NowPlaying(sourceID: "brave-youtube", appName: "YouTube", title: "Song", state: state, duration: duration,
               position: position, positionAt: date, playbackRate: state == .playing ? rate : 0,
               capabilities: [.playPause, .seek], isAd: ad, itemID: "1/v", updatedAt: date)
}

private func run(_ track: ProgressTrackView) -> CABasicAnimation? {
    track.fillLayer.animation(forKey: ProgressTrackView.animationKey) as? CABasicAnimation
}

// MARK: Progress

@MainActor @Test func progressRunsLinearlyToTheEnd() throws {
    let (track, window) = trackInWindow()
    defer { window.close() }
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 25), at: .now), fill: .white, track: .gray)
    let animation = try #require(run(track))
    #expect(animation.timingFunction == CAMediaTimingFunction(name: .linear))
    #expect(abs((animation.fromValue as? CGFloat ?? 0) - 50) < 1 && animation.toValue as? CGFloat == 200)  // 25 % → 100 %
    #expect(abs(animation.duration - 75) < 0.5)  // the 75 s left, at 1×
    #expect(track.starts == 1)

    track.apply(ProgressTrackView.Anchor(song(.playing, position: 25, rate: 2), at: .now), fill: .white, track: .gray)
    #expect(abs((run(track)?.duration ?? 0) - 37.5) < 0.5 && track.starts == 2)  // 2×: half the time
}

@MainActor @Test func pausedProgressStaysWhereItIs() {
    let (track, window) = trackInWindow()
    defer { window.close() }
    track.apply(ProgressTrackView.Anchor(song(.paused, position: 40), at: .now), fill: .white, track: .gray)
    #expect(!track.isRunning && abs(track.shownFraction - 0.4) < 0.001)
    track.apply(ProgressTrackView.Anchor(song(.paused, position: 40), at: .now + 5), fill: .white, track: .gray)
    #expect(!track.isRunning && abs(track.shownFraction - 0.4) < 0.001 && track.starts == 0)  // time passing moves nothing
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 99.9), at: .now), fill: .white, track: .gray)
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 100), at: .now), fill: .white, track: .gray)
    #expect(!track.isRunning && abs(track.shownFraction - 1) < 0.001)  // at the end: full and still
}

@MainActor @Test func liveStreamsAndAdsShowNoBar() {
    #expect(ProgressTrackView.Anchor(song(.playing, position: 30, duration: nil), at: .now) == nil)  // live / unknown
    #expect(ProgressTrackView.Anchor(song(.playing, position: 30, ad: true), at: .now) == nil)
    let (track, window) = trackInWindow()
    defer { window.close() }
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 30), at: .now), fill: .white, track: .gray)
    track.apply(nil, fill: .white, track: .gray)  // the stream went live / an ad began
    #expect(track.isHidden && !track.isRunning)
}

@MainActor @Test func agreeingUpdatesNeverRestartButSeeksJump() throws {
    let (track, window) = trackInWindow()
    defer { window.close() }
    let start = Date.now
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 10, at: start), at: start), fill: .white, track: .gray)
    // Brave re-sends the same position (an audible flag, a late title), or one that agrees with the bar.
    for (seconds, position) in [(0.0, 10.0), (2, 12), (5, 15.3), (8, 17.6)] {
        let now = start + seconds
        track.apply(ProgressTrackView.Anchor(song(.playing, position: position, at: now), at: now), fill: .white, track: .gray)
    }
    for _ in 0 ..< 5 { track.layout() }  // SwiftUI layout passes at the same width
    #expect(track.starts == 1)

    let seek = start + 9
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 60, at: seek), at: seek), fill: .white, track: .gray)
    #expect(track.starts == 2)
    #expect(abs((run(track)?.fromValue as? CGFloat ?? 0) - 120) < 1)  // starts at the new place: a jump, not a slide

    let pause = start + 10
    track.apply(ProgressTrackView.Anchor(song(.paused, position: 61, at: pause), at: pause), fill: .white, track: .gray)
    #expect(!track.isRunning && track.starts == 2)
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 61, at: pause), at: pause), fill: .white, track: .gray)
    #expect(track.isRunning && track.starts == 3)  // resumed
}

@MainActor @Test func hidingStopsTheBarAndShowingResumesFromNow() throws {
    let (track, window) = trackInWindow()
    defer { window.close() }
    track.apply(ProgressTrackView.Anchor(song(.playing, position: 20), at: .now), fill: .white, track: .gray)
    track.removeFromSuperview()  // the island hid
    #expect(!track.isRunning)
    window.contentView?.addSubview(track)
    let animation = try #require(run(track))
    #expect((animation.fromValue as? CGFloat ?? 0) >= 40 && track.starts == 2)  // from where playback is now
    #expect(track.fillLayer.animationKeys() == [ProgressTrackView.animationKey])  // one animation, never stacked

    let detached = ProgressTrackView(frame: NSRect(x: 0, y: 0, width: 200, height: 6))
    detached.layout()
    detached.apply(ProgressTrackView.Anchor(song(.playing, position: 20), at: .now), fill: .white, track: .gray)
    #expect(!detached.isRunning)  // never runs outside a window
}

// MARK: Controls and Reduce Motion

@Test func reduceMotionTurnsOffEveryNonessentialAnimation() {
    let full = IslandMotion(reduced: false), reduced = IslandMotion(reduced: true)
    #expect(full.morph != nil && full.hover != nil && full.tint != nil && full.press != nil)
    #expect(reduced.morph == nil && reduced.hover == nil && reduced.tint == nil && reduced.press == nil)
    #expect(full.scale(pressed: true) == 0.94 && full.scale(pressed: false) == 1)  // press, then release
    #expect(reduced.scale(pressed: true) == 1)  // no press scale
    #expect(reduced.symbol == .identity && full.symbol != .identity)  // the play/pause swap
    #expect(OrbitMotion.animation(.easeInOut(duration: 0.3), reduced: true) == nil)  // artwork: instant
}

@MainActor @Test func rapidPlayPauseClicksFollowTheReportedState() async throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ob-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let path = folder.appending(path: "b.sock").path(percentEncoded: false)
    let source = BraveYouTubeSource(socketPath: path)
    var statuses: [PlaybackSourceStatus] = []
    source.start { statuses.append($0) }
    defer { source.stop() }
    let client = try UnixSocket.connect(to: path)
    defer { close(client) }
    func report(_ state: VideoState) async {
        let update = TabPlayback(tab: 3, state: state, audible: state == .playing, videoID: "v", title: "Song", position: 5,
                                 duration: 100, rate: state == .playing ? 1 : 0, at: Date.now.timeIntervalSince1970 * 1000)
        _ = UnixSocket.writeAll(client, BridgeFraming.frame(BridgeMessage.update(update).encoded()))
        for _ in 0 ..< 100 where source.tabs[3]?.playback.state != state { try? await Task.sleep(for: .milliseconds(10)) }
    }
    func shown() -> NowPlaying? { if case .playing(let item)? = statuses.last { item } else { nil } }
    _ = fcntl(client, F_SETFL, fcntl(client, F_GETFL) | O_NONBLOCK)
    func commands() async -> [BridgeCommand.Action] {
        try? await Task.sleep(for: .milliseconds(50))
        var decoder = FrameDecoder(), buffer = [UInt8](repeating: 0, count: 4096), actions: [BridgeCommand.Action] = []
        while case let count = read(client, &buffer, buffer.count), count > 0 { decoder.append(Data(buffer[..<count])) }
        while let payload = try? decoder.next() {
            if case .command(let command)? = try? BridgeMessage.decode(payload) { actions.append(command.action) }
        }
        return actions
    }

    await report(.playing)
    let playing = try #require(shown())
    for _ in 0 ..< 3 { try await source.perform(.togglePlayPause, on: playing) }  // three clicks before Brave answers
    #expect(await commands() == [.pause, .pause, .pause])  // each asks for what the reported state needs: never a flip-flop
    await report(.paused)
    #expect(shown()?.state == .paused)  // the icon shows play: the state Brave reported
    try await source.perform(.togglePlayPause, on: try #require(shown()))
    #expect(await commands() == [.play])
}
