import AppKit
import Darwin
import SwiftUI
import Testing
@testable import Orbit
@testable import OrbitBridge

// Pause/resume from Brave reaching the island's equalizer, end to end: the
// real socket, BraveYouTubeSource, PlaybackCoordinator, MusicIsland.follow
// (as the app wires it) and the hosted SwiftUI view with its bar layers.

@MainActor private func findBars(_ view: NSView) -> EqualizerBarsView? {
    (view as? EqualizerBarsView) ?? view.subviews.lazy.compactMap(findBars).first
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

@MainActor
private final class Rig {
    let folder = FileManager.default.temporaryDirectory.appending(path: "ob-\(UUID().uuidString.prefix(8))")
    let source: BraveYouTubeSource
    let coordinator = PlaybackCoordinator()
    let island = MusicIsland()
    let host: NSHostingView<MusicIslandView>
    let window: NSWindow
    var client: Int32 = -1

    init() throws {
        source = BraveYouTubeSource(socketPath: folder.appending(path: "b.sock").path(percentEncoded: false))
        coordinator.register(source)
        coordinator.start()
        island.autoDismiss = .seconds(60)  // keep it on screen for the test
        host = NSHostingView(rootView: MusicIslandView(island: island) { _, _ in })
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 384, height: 172), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.alphaValue = 0  // a real window, never visible
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        let coordinator = coordinator
        island.follow { (coordinator.current, true, false) }
        client = try UnixSocket.connect(to: folder.appending(path: "b.sock").path(percentEncoded: false))
    }

    func close() {
        Darwin.close(client)
        window.orderOut(nil)
        coordinator.stop()
        try? FileManager.default.removeItem(at: folder)
    }

    /// What Brave's content script sends for a pause, play, seek or title change.
    func brave(_ state: VideoState, title: String = "Song", position: Double = 10) {
        let update = TabPlayback(tab: 7, state: state, audible: state == .playing, videoID: "same-video", title: title,
                                 channel: "Channel", position: position, duration: 200, rate: state == .playing ? 1 : 0,
                                 at: Date.now.timeIntervalSince1970 * 1000)
        _ = UnixSocket.writeAll(client, BridgeFraming.frame(BridgeMessage.update(update).encoded()))
    }

    var bars: EqualizerBarsView? {
        host.layoutSubtreeIfNeeded()
        return findBars(host)
    }
}

@MainActor @Test func pauseAndResumeFromBraveReachTheBarsWithTheSameVideo() async throws {
    let rig = try Rig()
    defer { rig.close() }
    rig.brave(.playing)
    #expect(await eventually { rig.bars?.mode == .playing && rig.bars?.animatingBars == 4 })
    #expect(rig.island.phase == .compact)
    for cycle in 1 ... 5 {  // never reopening Brave, never changing video
        rig.brave(.paused, position: Double(10 + cycle))
        #expect(await eventually { rig.bars?.mode == .paused }, "cycle \(cycle): pause")
        #expect(rig.bars?.animatingBars == 0)
        #expect(rig.bars?.bars.allSatisfy { $0.opacity == EqualizerBarsView.pausedOpacity } == true)
        rig.brave(.playing, position: Double(10 + cycle))
        #expect(await eventually { rig.bars?.animatingBars == 4 }, "cycle \(cycle): resume")
        #expect(rig.bars?.bars.allSatisfy { ($0.animationKeys() ?? []) == [EqualizerBarsView.animationKey] } == true)
    }
    #expect(rig.island.phase == .compact)  // the island's lifecycle is untouched
}

@MainActor @Test func progressAndMetadataUpdatesDontRestartTheBars() async throws {
    let rig = try Rig()
    defer { rig.close() }
    rig.brave(.playing, position: 10)
    #expect(await eventually { rig.bars?.animatingBars == 4 })
    let started = rig.bars?.bars.map { $0.animation(forKey: EqualizerBarsView.animationKey)?.beginTime }
    for second in 11 ... 15 { rig.brave(.playing, position: Double(second)) }  // seeks / progress
    rig.brave(.playing, title: "Song (title filled in late)", position: 16)  // metadata
    #expect(await eventually { rig.island.item?.title == "Song (title filled in late)" })
    #expect(rig.bars?.bars.map { $0.animation(forKey: EqualizerBarsView.animationKey)?.beginTime } == started)
}

@MainActor @Test func rapidPauseResumeSettlesOnTheLastState() async throws {
    let rig = try Rig()
    defer { rig.close() }
    rig.brave(.playing)
    #expect(await eventually { rig.bars?.animatingBars == 4 })
    for index in 0 ..< 9 { rig.brave(index.isMultiple(of: 2) ? .paused : .playing, position: 10 + Double(index) / 10) }
    rig.brave(.paused, position: 11)  // the final state
    #expect(await eventually { rig.bars?.mode == .paused && rig.island.item?.state == .paused })
    #expect(rig.bars?.animatingBars == 0)
    rig.brave(.playing, position: 11)
    #expect(await eventually { rig.bars?.animatingBars == 4 })
    #expect(rig.bars?.bars.allSatisfy { ($0.animationKeys() ?? []) == [EqualizerBarsView.animationKey] } == true)
}

@MainActor @Test func hidingShowingAndReduceMotionStillHold() async throws {
    let rig = try Rig()
    defer { rig.close() }
    rig.brave(.playing)
    #expect(await eventually { rig.bars?.animatingBars == 4 })
    rig.island.reduceMotion = true
    #expect(await eventually { rig.bars?.animatingBars == 0 && rig.bars?.mode == .playing })  // still bars
    rig.brave(.paused, position: 12)
    #expect(await eventually { rig.bars?.mode == .paused && rig.bars?.animatingBars == 0 })
    rig.island.reduceMotion = false
    rig.brave(.playing, position: 12)
    #expect(await eventually { rig.bars?.animatingBars == 4 })
    rig.island.spaceChanged()  // dismissed: the bars leave the view
    #expect(await eventually { rig.bars == nil })
}
