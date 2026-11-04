import AppKit
import CoreAudio
import Observation
import Testing
@testable import Orbit

// Stage 4.1-3: Sonic Pulse, the volume HUD's window and view. Fake volume
// readings only: the real system volume is never read or changed here.
// Real windows are kept at alpha 0 so nothing flashes on the screen.

private func device(_ id: AudioObjectID = 10, volume: Float? = 0.5, muted: Bool? = false, name: String = "Speakers") -> SystemVolumeStatus {
    .device(VolumeState(device: id, name: name, volume: volume, isMuted: muted, canSetVolume: volume != nil))
}

private func state(volume: Float?, muted: Bool?, name: String? = "Speakers") -> VolumeState {
    VolumeState(device: 10, name: name, volume: volume, isMuted: muted, canSetVolume: volume != nil)
}

@MainActor @Observable
private final class FakeInputs {
    var volume = device()
    var island = MusicIsland.Phase.hidden
    var dashboardOpen = false
    var snapshot: NotchOverlayCoordinator.Inputs { .init(volume: volume, island: island, dashboardOpen: dashboardOpen) }
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 200 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

/// A HUD with short real timers, its coordinator following fake inputs, and
/// the real panel (invisible) following the coordinator.
@MainActor
private final class Rig {
    let inputs = FakeInputs()
    let coordinator: NotchOverlayCoordinator
    let panel: SystemHUDPanel
    private(set) var covers: [Bool] = []

    init(dismiss: Duration = .milliseconds(120), fade: Duration = .milliseconds(320)) {
        coordinator = NotchOverlayCoordinator(hud: VolumeHUD(settleDelay: .milliseconds(40), dismissDelay: dismiss))
        panel = SystemHUDPanel(coordinator: coordinator)
        panel.alphaValue = 0
        panel.dismissal = fade
        panel.onCoverIsland = { [unowned self] in covers.append($0) }
        coordinator.start { [inputs] in inputs.snapshot }
    }

    func close() {
        coordinator.shutdown()
        panel.stop()
    }
}

// MARK: Pure design

@Test func meterSegmentsFollowTheLevel() {
    #expect(SonicPulse.litSegments(nil) == 0)  // no software volume: no meter at all
    #expect(SonicPulse.litSegments(0) == 0)
    #expect(SonicPulse.litSegments(0.01) == 1)  // anything audible lights one
    #expect(SonicPulse.litSegments(0.5) == 6)
    #expect(SonicPulse.litSegments(0.0625) == 1)  // one key press on macOS (1/16)
    #expect(SonicPulse.litSegments(0.96) == 12 && SonicPulse.litSegments(1) == 12)
    let steps = (0 ... 16).map { SonicPulse.litSegments(Float($0) / 16) }
    #expect(steps == steps.sorted())  // never goes down as the level goes up
}

@Test func theSpeakerSymbolFollowsLevelAndMute() {
    #expect(SonicPulse.symbol(volume: 0.8, isMuted: true) == "speaker.slash.fill")
    #expect(SonicPulse.symbol(volume: 0, isMuted: false) == "speaker.fill")
    #expect(SonicPulse.symbol(volume: 0.2, isMuted: false) == "speaker.wave.1.fill")
    #expect(SonicPulse.symbol(volume: 0.5, isMuted: nil) == "speaker.wave.2.fill")
    #expect(SonicPulse.symbol(volume: 0.9, isMuted: false) == "speaker.wave.3.fill")
    #expect(SonicPulse.symbol(volume: nil, isMuted: nil) == "hifispeaker.fill")  // the device sets its own volume
    #expect(SonicPulse.symbol(volume: nil, isMuted: true) == "speaker.slash.fill")
}

@Test func textAndAccessibilityNeverInventALevel() {
    #expect(SonicPulse.percentage(0.6) == "60%" && SonicPulse.percentage(0.004) == "0%" && SonicPulse.percentage(nil) == nil)
    #expect(SonicPulse.accessibilityLabel(state(volume: 0.6, muted: false)) == "Speakers: Volume 60 percent")
    #expect(SonicPulse.accessibilityLabel(state(volume: 0.6, muted: true)) == "Speakers: Volume muted")
    #expect(SonicPulse.accessibilityLabel(state(volume: nil, muted: nil, name: "LG HDR 4K")) == "LG HDR 4K: Volume is set on the device")
    #expect(SonicPulse.accessibilityLabel(state(volume: 1, muted: nil, name: nil)) == "Volume 100 percent")
}

// MARK: Pulse

@MainActor @Test func onePulsePerShownChangeAndTheDeviceNamedOnASwitch() {
    let hud = VolumeHUD(settleDelay: .seconds(60), dismissDelay: .seconds(60))
    defer { hud.shutdown() }
    hud.receive(device(), suppressed: false)  // the baseline
    hud.receive(device(), suppressed: false)  // a repeat
    #expect(hud.pulse == 0)
    hud.receive(device(volume: 0.6), suppressed: false)
    hud.receive(device(volume: 0.65), suppressed: false)
    #expect(hud.pulse == 2 && !hud.showsDevice)
    hud.expectOrbitChange(volume: 0.7, isMuted: false)
    hud.receive(device(volume: 0.7), suppressed: false)  // Orbit's own echo
    hud.receive(device(volume: 0.8), suppressed: true)  // suppressed
    #expect(hud.pulse == 2)
    hud.receive(device(20, volume: 0.4, name: "CX80U"), suppressed: false)  // a new output device
    #expect(hud.pulse == 3 && hud.showsDevice && hud.shown?.name == "CX80U")
    hud.receive(device(20, volume: 0.5, name: "CX80U"), suppressed: false)
    #expect(!hud.showsDevice)  // the next change on it is just a level
}

@MainActor
private func ringInWindow() -> (PulseRingView, NSWindow) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.alphaValue = 0
    window.isReleasedWhenClosed = false
    let ring = PulseRingView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    window.contentView?.addSubview(ring)
    ring.layout()
    return (ring, window)
}

@MainActor @Test func theRingPlaysOncePerValueAndNeverWithReduceMotion() {
    let (view, window) = ringInWindow()
    defer { window.close() }
    view.play(1, animated: true, color: .systemBlue)
    #expect(view.played == 1 && view.ring.animation(forKey: PulseRingView.animationKey) != nil)
    view.play(1, animated: true, color: .systemBlue)  // SwiftUI updating for something else
    view.play(1, animated: true, color: .systemBlue)
    #expect(view.played == 1)
    for value in 2 ... 6 { view.play(value, animated: true, color: .systemBlue) }  // rapid changes
    #expect(view.played == 6 && view.ring.animationKeys() == [PulseRingView.animationKey])  // one ring at a time
    let group = view.ring.animation(forKey: PulseRingView.animationKey) as? CAAnimationGroup
    #expect(group?.duration == 0.6 && group?.repeatCount == 0 && group?.isRemovedOnCompletion == true)  // one-shot
    #expect(view.ring.opacity == 0)  // nothing left showing when it ends

    let (still, stillWindow) = ringInWindow()
    defer { stillWindow.close() }
    for value in 1 ... 4 { still.play(value, animated: false, color: .systemBlue) }  // Reduce Motion
    #expect(still.played == 0 && still.ring.animationKeys() == nil)
}

@MainActor @Test func aNewRingWaitsForItsWindowAndStopsWhenRemoved() {
    let view = PulseRingView(frame: NSRect(x: 0, y: 0, width: 34, height: 34))
    view.play(3, animated: true, color: .systemBlue)  // just made by SwiftUI, not in a window yet
    #expect(view.played == 0)
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 40), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.alphaValue = 0
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView?.addSubview(view)
    #expect(view.played == 1)  // the change that brought the HUD on screen gets its pulse
    view.removeFromSuperview()
    #expect(view.ring.animationKeys() == nil)  // hidden: nothing left running
    window.contentView?.addSubview(view)
    #expect(view.played == 1)  // re-adding doesn't replay it
}

@MainActor @Test func reduceMotionTurnsOffTheExpansion() async {
    let rig = Rig(dismiss: .seconds(60))
    defer { rig.close() }
    rig.coordinator.hud.reduceMotion = true
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.coordinator.hud.phase == .visible })
    rig.inputs.volume = device(volume: 0.62)
    #expect(await eventually { rig.coordinator.hud.phase == .updating })
    #expect(!rig.coordinator.hud.isExpanded && rig.panel.isVisible)  // still shown, just not growing
    rig.coordinator.hud.reduceMotion = false
    #expect(rig.coordinator.hud.isExpanded)
}

// MARK: Window

@MainActor @Test func oneQuietWindowInTheIslandsSlot() {
    let rig = Rig()
    defer { rig.close() }
    let panel = rig.panel
    #expect(!panel.canBecomeKey && !panel.canBecomeMain && panel.ignoresMouseEvents && !panel.isVisible)
    #expect(panel.level == .statusBar && panel.styleMask.contains(.nonactivatingPanel))
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .stationary, .ignoresCycle])
    #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))  // full-screen Spaces: not shown, like the island

    let compact = CGRect(x: 606, y: 1068, width: 300, height: 42)
    let frame = SystemHUDPanel.frame(for: compact)
    #expect(frame.maxY == compact.maxY && frame.midX == compact.midX)  // the same top edge and centre
    #expect(frame.width == 316 && frame.height == 48)  // room for the 1.04 expansion
    #expect(SonicPulse.size.width * 1.04 <= frame.width && SonicPulse.size.height * 1.04 <= frame.height)
    if let screen = NSScreen.screens.first {
        #expect(screen.frame.contains(panel.frame))  // the primary display
    }
}

@MainActor @Test func showsOnAChangeAndLeavesAfterTheDismissal() async {
    let rig = Rig()
    defer { rig.close() }
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible })
    #expect(rig.covers.last == true && rig.coordinator.hud.pulse == 1)
    #expect(await eventually { rig.coordinator.overlay == .none && rig.panel.isDismissing })  // the HUD's own timer ran out
    #expect(rig.panel.isVisible)  // the fade-out still plays
    #expect(rig.covers.last == true)  // the island waits for it
    #expect(await eventually { !rig.panel.isVisible })
    #expect(rig.covers.last == false && !rig.panel.isDismissing)
}

@MainActor @Test func aChangeDuringTheDismissalKeepsTheSameWindow() async {
    let rig = Rig(dismiss: .milliseconds(80), fade: .seconds(60))  // a fade that can't finish during the test
    defer { rig.close() }
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isDismissing })
    rig.inputs.volume = device(volume: 0.7)  // pressed again as it faded
    #expect(await eventually { rig.coordinator.overlay == .volumeHUD && !rig.panel.isDismissing })
    #expect(rig.panel.isVisible && !rig.covers.contains(false))  // the same window, never handed back mid-adjustment
}

// MARK: Arbitration

@MainActor @Test func theDashboardAndTheExpandedPlayerTakeTheSlotAtOnce() async {
    let rig = Rig(dismiss: .seconds(60))
    defer { rig.close() }
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible })
    rig.inputs.dashboardOpen = true
    #expect(await eventually { !rig.panel.isVisible })
    #expect(!rig.panel.isDismissing)  // gone at once, never fading over the dashboard
    rig.inputs.volume = device(volume: 0.7)  // a change while it's open
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!rig.panel.isVisible)
    rig.inputs.dashboardOpen = false

    rig.inputs.volume = device(volume: 0.75)
    #expect(await eventually { rig.panel.isVisible })
    rig.inputs.island = .expanded  // the player opened
    #expect(await eventually { !rig.panel.isVisible && rig.coordinator.overlay == .musicIsland })
    rig.inputs.volume = device(volume: 0.8)
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!rig.panel.isVisible)  // never over the expanded player
}

@MainActor @Test func theDashboardOpeningMidFadeEndsItAtOnce() async {
    let rig = Rig(dismiss: .milliseconds(60))
    defer { rig.close() }
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isDismissing })
    rig.inputs.dashboardOpen = true
    #expect(await eventually { !rig.panel.isVisible && !rig.panel.isDismissing })
}

@MainActor @Test func theHUDReplacesACompactIslandAndRestoresIt() async {
    let island = MusicIsland()
    island.autoDismiss = .seconds(60)
    let islandPanel = MusicIslandPanel(island: island) { _, _ in }
    islandPanel.alphaValue = 0
    defer { islandPanel.orderOut(nil) }
    let rig = Rig()
    defer { rig.close() }
    rig.panel.onCoverIsland = { islandPanel.setCovered($0) }  // as AppDelegate wires it
    let playing = NowPlaying(sourceID: "music", appName: "Music", title: "Song", artist: "Artist", state: .playing,
                             duration: 200, position: 50, positionAt: .now, capabilities: [], updatedAt: .now)
    island.refresh(item: playing, enabled: true, dashboardOpen: false)
    #expect(island.phase == .compact && islandPanel.isVisible)
    rig.inputs.island = island.phase

    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible && !islandPanel.isVisible })  // one thing in the slot
    #expect(island.phase == .compact && islandPanel.isCovered)  // the island's state untouched
    #expect(await eventually { !rig.panel.isVisible && islandPanel.isVisible })  // and back afterwards
    #expect(!islandPanel.isCovered && island.phase == .compact)

    rig.inputs.volume = device(volume: 0.7)
    #expect(await eventually { !islandPanel.isVisible })
    island.spaceChanged()  // the island dismisses itself underneath
    rig.inputs.island = island.phase
    #expect(await eventually { !rig.panel.isVisible && !islandPanel.isCovered })
    try? await Task.sleep(for: .milliseconds(450))
    #expect(!islandPanel.isVisible && island.phase == .dismissed)  // not brought back
}

@MainActor @Test func aSpaceChangeHidesIt() async {
    let rig = Rig(dismiss: .seconds(60))
    defer { rig.close() }
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible })
    rig.coordinator.spaceChanged()  // e.g. into a full-screen app
    #expect(await eventually { !rig.panel.isVisible && rig.covers.last == false })
}

@MainActor @Test func unsupportedAndMissingDevicesShowNoLevel() async {
    let rig = Rig(dismiss: .seconds(60))
    defer { rig.close() }
    rig.inputs.volume = device(30, volume: nil, muted: nil, name: "LG HDR 4K")  // switched to a display
    #expect(await eventually { rig.panel.isVisible })
    #expect(rig.coordinator.hud.shown?.volume == nil && rig.coordinator.hud.showsDevice)
    #expect(SonicPulse.litSegments(rig.coordinator.hud.shown?.volume) == 0)
    rig.inputs.volume = .noOutputDevice  // unplugged
    #expect(await eventually { !rig.panel.isVisible })
}

// MARK: Shutdown

@MainActor @Test func shutdownStopsEverything() async {
    let rig = Rig(dismiss: .seconds(60))
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible })
    rig.close()
    #expect(!rig.panel.isVisible && !rig.panel.isDismissing && rig.coordinator.hud.pendingTimers == 0)
    rig.inputs.volume = device(volume: 0.9)
    try? await Task.sleep(for: .milliseconds(40))
    #expect(!rig.panel.isVisible && rig.coordinator.overlay == .none)  // nothing follows after quitting
}

// MARK: Setting (4.1-4)

@Test func theVolumeHUDSettingIsOnByDefaultAndOldFilesKeepIt() throws {
    #expect(OrbitPreferences().volumeHUD)
    let old = #"{"hideDelay": 2, "musicIsland": false, "musicIslandSeconds": 6}"#  // saved before 4.1-4
    let decoded = try JSONDecoder().decode(OrbitPreferences.self, from: Data(old.utf8))
    #expect(decoded.volumeHUD && decoded.hideDelay == 2 && !decoded.musicIsland && decoded.musicIslandSeconds == 6)
    let invalid = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"volumeHUD": "nope", "hideDelay": 2}"#.utf8))
    #expect(invalid.volumeHUD && invalid.hideDelay == 2)  // the rest kept
}

@MainActor @Test func theVolumeHUDSettingPersistsAndResets() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let model = PreferencesModel(file: file)
    var notified: OrbitPreferences?
    model.onChange = { notified = $0 }
    model.update { $0.volumeHUD = false }
    #expect(notified?.volumeHUD == false)  // the app hears about it at once
    #expect(PreferencesModel(file: file).value.volumeHUD == false)  // and it survives a relaunch
    model.update { $0.appearance = .light }
    model.resetGeneral()
    #expect(model.value.volumeHUD && model.value.appearance == .light)  // General reset only
}

/// The app's Sonic Pulse with a fake audio layer: what AppDelegate builds.
@MainActor
private final class Enabled {
    let audio = FakeAudio()
    let volume: SystemVolume
    let coordinator = NotchOverlayCoordinator(hud: VolumeHUD(settleDelay: .milliseconds(40), dismissDelay: .milliseconds(150)))
    let panel: SystemHUDPanel
    let controller: SonicPulseController
    var island = MusicIsland.Phase.hidden
    private(set) var covers: [Bool] = []

    init() {
        volume = SystemVolume(hardware: audio)
        panel = SystemHUDPanel(coordinator: coordinator)
        panel.alphaValue = 0
        controller = SonicPulseController(volume: volume, overlay: coordinator, panel: panel) { (.hidden, false) }
        panel.onCoverIsland = { [unowned self] in covers.append($0) }
    }

    func change(to level: Float) {
        audio.volumes[10] = [0: level]
        audio.fire(.volume(0), on: 10)
    }

    var shows: Int { covers.filter { $0 }.count }
}

@MainActor @Test func turningItOffStopsEverythingAndOnRestoresIt() async {
    let rig = Enabled()
    defer { rig.controller.setEnabled(false) }
    #expect(!rig.panel.isFollowing)  // off until enabled
    rig.controller.setEnabled(true)
    #expect(rig.controller.isEnabled && rig.volume.listenerCount == 3 && rig.panel.isFollowing)
    rig.change(to: 0.6)
    #expect(await eventually { rig.panel.isVisible })

    rig.controller.setEnabled(false)  // mid-show
    #expect(!rig.panel.isVisible && rig.covers.last == false)  // gone at once, the island handed back
    #expect(rig.audio.active.isEmpty && rig.volume.status == .stopped && !rig.coordinator.isRunning)
    #expect(rig.coordinator.hud.pendingTimers == 0 && !rig.panel.isFollowing)
    rig.change(to: 0.7)  // nothing listens now
    try? await Task.sleep(for: .milliseconds(60))
    #expect(!rig.panel.isVisible && rig.coordinator.overlay == .none)

    for _ in 0 ..< 3 {  // toggled repeatedly
        rig.controller.setEnabled(true)
        rig.controller.setEnabled(true)
        rig.controller.setEnabled(false)
    }
    #expect(rig.audio.adds == rig.audio.removes && rig.audio.active.isEmpty)  // balanced

    rig.audio.volumes[10] = [0: 0.2]  // changed while off
    rig.controller.setEnabled(true)
    try? await Task.sleep(for: .milliseconds(60))
    #expect(!rig.panel.isVisible && rig.volume.listenerCount == 3)  // turning it on shows nothing by itself
    let before = rig.shows
    rig.change(to: 0.3)
    #expect(await eventually { rig.panel.isVisible })
    try? await Task.sleep(for: .milliseconds(30))
    #expect(rig.shows == before + 1)  // one follow loop, not one per start
    #expect(await eventually { !rig.panel.isVisible })  // and it dismisses as usual
}

@MainActor @Test func turningItOffMidFadeHandsTheIslandBackAtOnce() async {
    let rig = Enabled()
    defer { rig.controller.setEnabled(false) }
    rig.controller.setEnabled(true)
    rig.panel.dismissal = .seconds(60)
    rig.change(to: 0.6)
    #expect(await eventually { rig.panel.isDismissing })
    rig.controller.setEnabled(false)
    #expect(!rig.panel.isVisible && !rig.panel.isDismissing && rig.covers.last == false)
}

// MARK: Core Animation (4.1-4)

@MainActor
private func inWindow<V: NSView>(_ view: V, size: NSSize = NSSize(width: 160, height: 20)) -> (V, NSWindow) {
    let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.alphaValue = 0
    window.isReleasedWhenClosed = false
    view.frame = NSRect(origin: .zero, size: size)
    window.contentView?.addSubview(view)
    view.layout()
    return (view, window)
}

@MainActor @Test func theMeterIsTwelveLayersThatFadeOnlyOnAChange() throws {
    let (meter, window) = inWindow(SegmentMeterView())
    defer { window.close() }
    let accent = NSColor.systemBlue
    meter.apply(lit: 6, dimmed: false, animated: true, accent: accent)  // the first value: drawn at once
    #expect(meter.segments.count == 12 && meter.segments.allSatisfy { $0.animationKeys() == nil })
    #expect(meter.segments.filter { $0.backgroundColor?.alpha == 1 }.count == 6)  // lit; the rest at 0.1
    #expect(meter.segments.filter { abs(($0.backgroundColor?.alpha ?? 0) - 0.1) < 0.001 }.count == 6)
    #expect(meter.segments.allSatisfy { $0.frame.height == 6 && $0.frame.maxX <= 160.001 })
    let gap = meter.segments[1].frame.minX - meter.segments[0].frame.maxX
    #expect(abs(gap - SegmentMeterView.spacing) < 0.01)

    meter.apply(lit: 7, dimmed: false, animated: true, accent: accent)
    #expect(meter.segments[6].animation(forKey: SegmentMeterView.fadeKey)?.duration == 0.18)  // a fade in the render server
    #expect(meter.segments.filter { $0.animationKeys() != nil }.count == 1)  // only the segment that changed
    meter.segments.forEach { $0.removeAllAnimations() }
    meter.apply(lit: 7, dimmed: false, animated: true, accent: accent)  // the same value again: nothing
    #expect(meter.segments.allSatisfy { $0.animationKeys() == nil })
    meter.apply(lit: 7, dimmed: true, animated: false, accent: accent)  // muted, Reduce Motion: instant
    #expect(meter.segments.allSatisfy { $0.animationKeys() == nil })
    #expect(abs((meter.segments[0].backgroundColor?.alpha ?? 0) - 0.35) < 0.001)
}

@MainActor @Test func theLevelSlidesInTheDirectionOfTheChange() throws {
    let (text, window) = inWindow(LevelTextView(), size: NSSize(width: 66, height: 16))
    defer { window.close() }
    text.apply("30%", level: 0.3, muted: false, animated: true)  // the first value: no slide
    #expect(text.label.animation(forKey: LevelTextView.transitionKey) == nil)
    text.apply("36%", level: 0.36, muted: false, animated: true)
    let up = try #require(text.label.animation(forKey: LevelTextView.transitionKey) as? CATransition)
    #expect(up.type == .push && up.subtype == .fromBottom && up.duration == 0.2)
    text.apply("20%", level: 0.2, muted: false, animated: true)
    let down = try #require(text.label.animation(forKey: LevelTextView.transitionKey) as? CATransition)
    #expect(down.subtype == .fromTop)
    text.label.removeAllAnimations()
    text.apply("20%", level: 0.2, muted: false, animated: true)  // unchanged
    text.apply("Muted", level: 0.2, muted: true, animated: false)  // Reduce Motion
    #expect(text.label.animationKeys() == nil && text.text == "Muted")
    #expect(text.layer?.masksToBounds == true)  // the old value slides out of sight
}

@MainActor @Test func theStageAppearsGrowsAndLeavesInCoreAnimation() {
    let content = NSView()
    let (stage, window) = inWindow(SonicPulseStage(content: content), size: NSSize(width: 316, height: 48))
    defer { window.close() }
    #expect(stage.opacity == 0 && stage.scale == SonicPulseStage.hiddenScale)  // made hidden
    stage.present(animated: true)
    #expect(stage.opacity == 1 && stage.scale == 1)
    #expect(stage.scaler.layer?.animation(forKey: "orbit.scale") is CASpringAnimation)
    // About the top centre: the top edge stays put while it grows.
    let layer = stage.scaler.layer!
    let topCentre = CGPoint(x: layer.bounds.midX, y: layer.bounds.maxY)
    let pivot = CGPoint(x: topCentre.x - layer.anchorPoint.x * layer.bounds.width, y: topCentre.y - layer.anchorPoint.y * layer.bounds.height)
    stage.setExpanded(true, animated: false)
    #expect(stage.scale == SonicPulseStage.expandedScale && layer.animationKeys() == nil)
    let moved = CGPointApplyAffineTransform(pivot, CATransform3DGetAffineTransform(layer.sublayerTransform))
    #expect(abs(moved.x - pivot.x) < 0.001 && abs(moved.y - pivot.y) < 0.001)
    stage.setExpanded(false, animated: true)
    #expect(stage.scale == 1)
    stage.leave(animated: true)
    #expect(stage.isLeaving && stage.opacity == 0 && stage.scale == SonicPulseStage.hiddenScale)
    #expect(layer.animation(forKey: "orbit.fade") != nil)
    stage.setExpanded(true, animated: true)  // an expansion while leaving doesn't bring it back
    #expect(stage.scale == SonicPulseStage.hiddenScale)
    stage.reset()
    #expect(layer.animationKeys() == nil && !stage.isLeaving)  // nothing left running
}

@MainActor @Test func reduceMotionShowsAndHidesTheStageInstantly() async {
    let rig = Rig(dismiss: .milliseconds(120))
    defer { rig.close() }
    rig.coordinator.hud.reduceMotion = true
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible })
    #expect(rig.panel.stage.opacity == 1 && rig.panel.stage.scale == 1)
    #expect(rig.panel.stage.scaler.layer?.animationKeys() == nil)  // no spring, no fade
    #expect(await eventually { !rig.panel.isVisible })
    #expect(rig.panel.stage.opacity == 0 && rig.panel.stage.scaler.layer?.animationKeys() == nil)
}

@MainActor @Test func theStageFollowsTheHUDAndNothingRunsOnceHidden() async {
    let rig = Rig(dismiss: .milliseconds(400))
    defer { rig.close() }
    rig.inputs.volume = device(volume: 0.6)
    #expect(await eventually { rig.panel.isVisible && rig.panel.stage.opacity == 1 })
    rig.inputs.volume = device(volume: 0.62)
    #expect(await eventually { rig.panel.stage.scale == SonicPulseStage.expandedScale })  // adjusting: it grows
    #expect(await eventually { rig.panel.stage.scale == 1 })  // settled
    #expect(await eventually { rig.panel.stage.isLeaving })  // its time ran out: fading out
    #expect(await eventually { !rig.panel.isVisible })
    #expect(!rig.panel.stage.isLeaving && rig.panel.stage.scaler.layer?.animationKeys() == nil)  // reset, nothing running

    rig.inputs.volume = device(volume: 0.7)
    #expect(await eventually { rig.panel.stage.opacity == 1 })
    rig.inputs.dashboardOpen = true  // taken at once
    #expect(await eventually { !rig.panel.isVisible })
    #expect(rig.panel.stage.opacity == 0 && rig.panel.stage.scaler.layer?.animationKeys() == nil)
}
