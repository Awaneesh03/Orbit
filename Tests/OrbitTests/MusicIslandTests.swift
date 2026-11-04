import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.7E: the music island, a compact player below the notch with its own
// panel and state, separate from the Control Center dashboard.

private func item(_ state: PlaybackState, _ title: String = "Song", video: String = "vid", position: Double = 50,
                  source: String = "brave-youtube") -> NowPlaying {
    NowPlaying(sourceID: source, appName: "YouTube", title: title, artist: "Channel", state: state, duration: 200,
               position: position, positionAt: .now, capabilities: source == "brave-youtube" ? [.playPause, .seek] : [],
               itemID: source == "brave-youtube" ? "1/\(video)" : nil, updatedAt: .now)
}

/// An island with a short auto-dismiss, for tests that wait for it.
@MainActor
private func quickIsland(_ dismiss: Duration = .milliseconds(60)) -> MusicIsland {
    let island = MusicIsland()
    island.autoDismiss = dismiss
    island.lingerAfterHover = .milliseconds(40)
    return island
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 150 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

// MARK: State

@MainActor @Test func playbackStartingShowsTheIslandAndItHidesItself() async {
    let island = quickIsland()
    island.refresh(item: nil, enabled: true, dashboardOpen: false)
    #expect(island.phase == .hidden)  // nothing playing (or Music only waiting)
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    #expect(island.phase == .compact && island.isVisible)
    #expect(await eventually { island.phase == .dismissed })  // gone after the timeout
    #expect(!island.isVisible && island.item?.title == "Song")

    let slow = quickIsland(.seconds(60))
    slow.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    try? await Task.sleep(for: .milliseconds(80))
    #expect(slow.phase == .compact)  // the configured duration, not a fixed one
    slow.shutdown()
}

@MainActor @Test func progressPauseAndResumeNeverBringItBack() async {
    let island = quickIsland(.milliseconds(100))
    island.refresh(item: item(.playing, position: 1), enabled: true, dashboardOpen: false)
    // Position updates every 10 ms (far more often than real ones) don't extend
    // it: it's gone while they're still arriving.
    var dismissedDuringUpdates = false
    for tick in 1 ... 100 where !dismissedDuringUpdates {
        island.refresh(item: item(.playing, position: 1 + Double(tick) / 100), enabled: true, dashboardOpen: false)
        try? await Task.sleep(for: .milliseconds(10))
        dismissedDuringUpdates = island.phase == .dismissed
    }
    #expect(dismissedDuringUpdates)
    // …and once it's gone, more progress, pausing and resuming don't reopen it.
    for (state, position) in [(PlaybackState.playing, 30.0), (.paused, 31), (.playing, 31), (.paused, 40), (.playing, 41)] {
        island.refresh(item: item(state, position: position), enabled: true, dashboardOpen: false)
        #expect(island.phase == .dismissed)
    }
    // Found already paused (e.g. Orbit launched mid-video): no pop-up at all.
    let paused = quickIsland()
    paused.refresh(item: item(.paused), enabled: true, dashboardOpen: false)
    #expect(paused.phase == .dismissed)
}

@MainActor @Test func aNewTrackOrARestartAnnouncesAgain() async {
    let island = quickIsland()
    island.refresh(item: item(.playing, "One", video: "a"), enabled: true, dashboardOpen: false)
    #expect(await eventually { island.phase == .dismissed })
    island.refresh(item: item(.playing, "One (late title)", video: "a"), enabled: true, dashboardOpen: false)
    #expect(island.phase == .dismissed)  // the same video, its title filled in late: not new
    island.refresh(item: item(.playing, "Two", video: "b"), enabled: true, dashboardOpen: false)
    #expect(island.phase == .compact && island.item?.title == "Two")  // a new video
    #expect(await eventually { island.phase == .dismissed })

    island.refresh(item: item(.stopped, video: "b"), enabled: true, dashboardOpen: false)
    #expect(island.phase == .hidden)  // stopped / ended
    island.refresh(item: item(.playing, "Two", video: "b"), enabled: true, dashboardOpen: false)
    #expect(island.phase == .compact)  // playback starting again is announced

    // Back and forth between two tabs: each video is announced once.
    let tabs = quickIsland()
    tabs.refresh(item: item(.playing, "Tab A", video: "a"), enabled: true, dashboardOpen: false)
    tabs.refresh(item: item(.playing, "Tab B", video: "b"), enabled: true, dashboardOpen: false)
    #expect(await eventually { tabs.phase == .dismissed })
    tabs.refresh(item: item(.playing, "Tab A", video: "a"), enabled: true, dashboardOpen: false)
    #expect(tabs.phase == .dismissed)

    let music = quickIsland()  // Music: tracks by name
    music.refresh(item: item(.playing, "Song A", source: "apple-music"), enabled: true, dashboardOpen: false)
    music.refresh(item: item(.paused, "Song A", source: "apple-music"), enabled: true, dashboardOpen: false)
    #expect(await eventually { music.phase == .dismissed })
    music.refresh(item: item(.playing, "Song B", source: "apple-music"), enabled: true, dashboardOpen: false)
    #expect(music.phase == .compact)
    music.shutdown()
    island.shutdown()
}

@MainActor @Test func theExpandedPlayerStaysUntilDismissedAndNeverReopens() async {
    let island = quickIsland()
    var changes: [MusicIsland.Phase] = []
    island.onPhaseChange = { changes.append($1) }
    island.tap()
    #expect(island.phase == .hidden)  // nothing to open
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    island.tap()  // clicked within its 4 s
    #expect(island.phase == .expanded)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(island.phase == .expanded)  // no timer while expanded
    island.refresh(item: item(.paused, position: 60), enabled: true, dashboardOpen: false)
    island.refresh(item: item(.playing, "Next", video: "next"), enabled: true, dashboardOpen: false)
    #expect(island.phase == .expanded && island.item?.title == "Next")  // follows playback, stays open
    island.collapse()  // outside click, Escape or the close button
    #expect(island.phase == .dismissed)
    for position in [61.0, 62, 63] {
        island.refresh(item: item(.playing, "Next", video: "next", position: position), enabled: true, dashboardOpen: false)
    }
    #expect(island.phase == .dismissed)  // not reopened for the same track
    #expect(changes == [.compact, .expanded, .dismissed])
}

@MainActor @Test func hoveringHoldsOffTheDismissal() async {
    let island = quickIsland()
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    island.hover(true)
    try? await Task.sleep(for: .milliseconds(150))
    #expect(island.phase == .compact)  // the pointer may be about to click
    island.hover(false)
    #expect(await eventually { island.phase == .dismissed })
}

@MainActor @Test func dismissingNeverTouchesPlayback() async throws {
    let coordinator = PlaybackCoordinator()
    let brave = BraveYouTubeSource(socketPath: "/nonexistent/x.sock")
    coordinator.register(brave)
    let widget = NowPlayingWidget(coordinator: coordinator)
    brave.receive(.update(.init(tab: 1, state: .playing, videoID: "v", title: "Video", at: 1)), from: 1)
    var commands = 0
    let island = quickIsland()
    let panel = MusicIslandPanel(island: island) { _, _ in commands += 1 }
    panel.alphaValue = 0
    defer { panel.orderOut(nil) }
    island.refresh(item: coordinator.current, enabled: true, dashboardOpen: false)
    #expect(await eventually { island.phase == .dismissed })
    island.refresh(item: coordinator.current, enabled: true, dashboardOpen: false)
    #expect(commands == 0 && coordinator.current?.state == .playing && widget.state == .ready)  // still playing, still in the widget
    coordinator.stop()
}

@MainActor @Test func disablingHidesOnlyTheIsland() {
    let coordinator = PlaybackCoordinator()
    let brave = BraveYouTubeSource(socketPath: "/nonexistent/x.sock")
    coordinator.register(brave)
    let widget = NowPlayingWidget(coordinator: coordinator)
    brave.receive(.update(.init(tab: 1, state: .playing, videoID: "v", title: "Video", at: 1)), from: 1)
    let island = MusicIsland()
    island.refresh(item: coordinator.current, enabled: false, dashboardOpen: false)
    #expect(!island.isVisible)
    #expect(coordinator.current?.title == "Video" && widget.state == .ready)  // detection and the widget carry on
    island.refresh(item: coordinator.current, enabled: true, dashboardOpen: false)
    #expect(!island.isVisible)  // turned on mid-track: no late pop-up
    coordinator.stop()

    #expect(OrbitPreferences().musicIsland && OrbitPreferences().musicIslandSeconds == 4)  // on, 4 s by default
    let old = try? JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"hideDelay": 2}"#.utf8))
    #expect(old?.musicIsland == true && old?.musicIslandSeconds == 4 && old?.hideDelay == 2)  // older files
    let bad = try? JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"musicIsland": "yes", "musicIslandSeconds": 99}"#.utf8))
    #expect(bad?.musicIsland == true && bad?.musicIslandSeconds == OrbitPreferences.musicIslandSecondsRange.upperBound)
    let preferences = PreferencesModel(file: nil)
    preferences.update { $0.musicIsland = false; $0.musicIslandSeconds = 0 }
    #expect(!preferences.value.musicIsland && preferences.value.musicIslandSeconds == 2)  // clamped
    preferences.resetGeneral()
    #expect(preferences.value.musicIsland && preferences.value.musicIslandSeconds == 4)
}

@MainActor @Test func theDashboardAndTheIslandKeepSeparateState() {
    let interaction = NotchInteraction()
    let island = MusicIsland()
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: interaction.isOpen)
    island.tap()
    #expect(island.phase == .expanded && interaction.phase == .hidden)  // the player never opens the dashboard

    interaction.pointerEntered()  // the user hovers the notch while the player is open
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: interaction.isOpen)
    #expect(interaction.phase == .open && island.phase == .dismissed)  // the player gets out of the way first

    island.refresh(item: item(.playing, "New", video: "new"), enabled: true, dashboardOpen: interaction.isOpen)
    #expect(!island.isVisible)  // a track starting under the open dashboard shows in its widget instead
    island.tap()
    #expect(interaction.phase == .open && !island.isVisible)

    interaction.close()
    island.refresh(item: item(.playing, "New", video: "new"), enabled: true, dashboardOpen: interaction.isOpen)
    #expect(!island.isVisible)  // nothing pops up afterwards
    #expect(interaction.phase == .hidden && NotchGeometry.dashboardSize == CGSize(width: 740, height: 420))
}

@MainActor @Test func spaceChangesAndQuittingLeaveNothingBehind() async {
    let island = quickIsland()
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    island.spaceChanged()
    #expect(island.phase == .dismissed)
    island.refresh(item: item(.playing, "B", video: "b"), enabled: true, dashboardOpen: false)
    island.tap()
    island.spaceChanged()
    #expect(island.phase == .dismissed)  // the player doesn't follow to another Space

    var changes: [MusicIsland.Phase] = []
    let quitting = quickIsland(.milliseconds(40))
    quitting.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    quitting.onPhaseChange = { changes.append($1) }
    quitting.shutdown()
    try? await Task.sleep(for: .milliseconds(120))
    #expect(quitting.phase == .hidden && changes == [.hidden])  // the pending dismissal was cancelled
}

// MARK: Geometry and panel

@Test func islandSitsBelowTheNotchAndNeverCoversIt() {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let trigger = NotchGeometry.triggerRect(screen: screen, visible: CGRect(x: 0, y: 0, width: 1470, height: 919),
                                            left: CGRect(x: 0, y: 919, width: 640, height: 37),
                                            right: CGRect(x: 830, y: 919, width: 640, height: 37))
    let compact = MusicIslandGeometry.compactRect(trigger: trigger, screen: screen)
    let expanded = MusicIslandGeometry.expandedRect(trigger: trigger, screen: screen)
    for rect in [compact, expanded] {
        #expect(rect.maxY == trigger.minY - MusicIslandGeometry.gap)  // below the menu bar and the notch
        #expect(!rect.intersects(trigger) && screen.contains(rect))
        #expect(abs(rect.midX - trigger.midX) < 0.5)  // centred on the notch
    }
    #expect(compact.maxY == expanded.maxY && compact.size == MusicIslandGeometry.compactSize)  // grows downwards
    let dashboard = NotchGeometry.dashboardRect(trigger: trigger, screen: screen)
    #expect(dashboard.contains(expanded))  // the open dashboard covers it: hence hidden while open
    let corner = MusicIslandGeometry.compactRect(trigger: CGRect(x: 1400, y: 919, width: 70, height: 37), screen: screen)
    #expect(screen.contains(corner))  // kept on screen
}

@MainActor @Test func panelFollowsTheIslandAndEscapeCollapses() async throws {
    let island = quickIsland(.seconds(60))
    let panel = MusicIslandPanel(island: island) { _, _ in }
    panel.alphaValue = 0  // a real window: never flash it on the screen during tests
    defer { panel.orderOut(nil) }
    #expect(!panel.isVisible && !panel.canBecomeKey)

    island.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    #expect(panel.isVisible && !panel.canBecomeKey)  // compact never takes focus
    #expect(panel.frame.size == MusicIslandGeometry.compactSize)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && !panel.collectionBehavior.contains(.fullScreenAuxiliary))

    island.tap()
    #expect(panel.frame.size == MusicIslandGeometry.expandedSize && panel.canBecomeKey && panel.watchesOutsideClicks)
    let escape = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                                               windowNumber: panel.windowNumber, context: nil, characters: "\u{1b}",
                                               charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53))
    panel.sendEvent(escape)
    #expect(island.phase == .dismissed && !panel.watchesOutsideClicks && !panel.canBecomeKey)
    #expect(await eventually { !panel.isVisible })  // off the screen: the tab bar is clear

    island.refresh(item: item(.playing, "B", video: "b"), enabled: true, dashboardOpen: false)
    #expect(await eventually { panel.isVisible })
    island.tap()
    panel.outsideClick()  // what the global mouse monitor calls
    #expect(island.phase == .dismissed && !panel.watchesOutsideClicks)
    #expect(await eventually { !panel.isVisible })
}

@MainActor @Test func islandRendering() throws {
    let island = quickIsland(.seconds(60))
    let view = MusicIslandView(island: island) { _, _ in }
    let empty = try #require(render(view, size: CGSize(width: 384, height: 172)))
    island.refresh(item: item(.playing, "A long video title about Swift"), enabled: true, dashboardOpen: false)
    let compact = try #require(render(view, size: CGSize(width: 384, height: 172)))
    island.tap()
    let expanded = try #require(render(view, size: CGSize(width: 384, height: 172)))
    #expect(compact.pixels != empty.pixels && expanded.pixels != compact.pixels)

    if let folder = ProcessInfo.processInfo.environment["ORBIT_RENDER_DIR"] {
        for (name, phase) in [("island-compact", MusicIsland.Phase.compact), ("island-expanded", .expanded)] {
            if phase == .compact {
                island.collapse()
                island.refresh(item: item(.playing, "A long video title about Swift", video: "other"), enabled: true, dashboardOpen: false)
            } else {
                island.tap()
            }
            let renderer = ImageRenderer(content: view.frame(width: 384, height: 172).background(Color.gray.opacity(0.3)))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
            }
        }
    }
}
