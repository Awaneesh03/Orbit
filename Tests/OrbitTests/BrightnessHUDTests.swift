import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 9: the brightness HUD. Orbit observes brightness (I/O Registry,
// public) and never sets it. These pin the reading, the HUD's timing rules
// (the volume HUD's twin), the shared slot and the capsule's rendering.
// ORBIT_RENDER=1 writes docs/screenshots/m9-brightness/*.png.

@Test func theLevelIsTheDriversBrightnessValueOverItsRange() {
    #expect(BrightnessReader.level(from: ["brightness": ["min": 0, "max": 65536, "value": 32768]]) == 0.5)
    #expect(BrightnessReader.level(from: ["brightness": ["min": 0, "max": 65536, "value": 70000]]) == 1)  // clamped
    #expect(BrightnessReader.level(from: ["brightness": ["min": 100, "max": 100, "value": 100]]) == nil)  // no range: no value
    #expect(BrightnessReader.level(from: ["rawBrightness": ["max": 2047, "value": 1524]]) == nil)  // never a guess from another key
    #expect(BrightnessReader.level(0) == nil)  // no backlight service
}

@Test func onlyBrightnessKeyDownsCount() {
    func data1(key: Int, down: Bool) -> Int { (key << 16) | ((down ? 0x0A : 0x0B) << 8) }
    #expect(BrightnessReader.isBrightnessKey(subtype: 8, data1: data1(key: 2, down: true)))  // up
    #expect(BrightnessReader.isBrightnessKey(subtype: 8, data1: data1(key: 3, down: true)))  // down
    #expect(!BrightnessReader.isBrightnessKey(subtype: 8, data1: data1(key: 2, down: false)))  // key up
    #expect(!BrightnessReader.isBrightnessKey(subtype: 8, data1: data1(key: 0, down: true)))  // volume up
    #expect(!BrightnessReader.isBrightnessKey(subtype: 7, data1: data1(key: 2, down: true)))  // another subtype
}

@MainActor @Test func theFirstReadingIsABaselineAndChangesShowAndDismiss() {
    let scheduler = FakeScheduler()
    let hud = BrightnessHUD(scheduler: scheduler)
    hud.receive(level: 0.5, presses: 0, suppressed: false)
    #expect(!hud.isVisible)  // turning it on never shows it
    hud.receive(level: 0.502, presses: 0, suppressed: false)
    #expect(!hud.isVisible)  // driver rounding isn't a change
    hud.receive(level: 0.5625, presses: 0, suppressed: false)
    #expect(hud.phase == .visible && hud.shown == 0.5625 && hud.pulse == 1)
    hud.receive(level: 0.625, presses: 0, suppressed: false)
    #expect(hud.phase == .updating && hud.isExpanded && hud.pendingTimers == 2)  // never more than one of each timer
    scheduler.advance(.milliseconds(300))
    #expect(hud.phase == .pendingDismissal)
    scheduler.advance(.milliseconds(1200))
    #expect(!hud.isVisible && hud.shown == 0.625)  // kept for the leaving animation
}

@MainActor @Test func aKeyPressAtTheEndsStillShowsTheLevel() {
    let hud = BrightnessHUD(scheduler: FakeScheduler())
    hud.receive(level: 1, presses: 0, suppressed: false)
    hud.receive(level: 1, presses: 1, suppressed: false)  // brightness up at 100 %
    #expect(hud.isVisible && hud.shown == 1)
}

@MainActor @Test func noBacklightAndSuppressionShowNothing() {
    let hud = BrightnessHUD(scheduler: FakeScheduler())
    hud.receive(level: nil, presses: 0, suppressed: false)
    hud.receive(level: nil, presses: 1, suppressed: false)
    #expect(!hud.isVisible)  // no built-in display: never a made-up value
    hud.receive(level: 0.3, presses: 1, suppressed: false)
    hud.receive(level: 0.6, presses: 1, suppressed: true)  // the dashboard is open
    #expect(!hud.isVisible)
    hud.receive(level: 0.7, presses: 1, suppressed: false)
    #expect(hud.isVisible)
    hud.shutdown()
    #expect(!hud.isVisible && hud.pendingTimers == 0)
    hud.receive(level: 0.1, presses: 2, suppressed: false)
    #expect(!hud.isVisible)  // off: nothing
}

@Test func theSlotKeepsTheApprovedOrderWithBrightnessBesideVolume() {
    for island in [MusicIsland.Phase.hidden, .compact, .expanded, .dismissed] {
        // Without brightness, exactly the original decision.
        for volume in [false, true] {
            #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: island, volumeVisible: volume, brightnessVisible: false, last: .brightness)
                == NotchOverlayCoordinator.decide(dashboardOpen: false, island: island, volumeVisible: volume))
        }
        #expect(NotchOverlayCoordinator.decide(dashboardOpen: true, island: island, volumeVisible: true, brightnessVisible: true, last: .brightness) == .none)
    }
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .expanded, volumeVisible: false, brightnessVisible: true, last: .brightness) == .musicIsland)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .compact, volumeVisible: false, brightnessVisible: true, last: .volume) == .brightnessHUD)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .hidden, volumeVisible: true, brightnessVisible: true, last: .brightness) == .brightnessHUD)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .hidden, volumeVisible: true, brightnessVisible: true, last: .volume) == .volumeHUD)
    #expect(NotchOverlay.brightnessHUD.isHUD && NotchOverlay.volumeHUD.isHUD && !NotchOverlay.musicIsland.isHUD)
    // Coucou: the brightness HUD steps aside like the volume HUD.
    #expect(!NotchCoordination.permits(.brightnessHUD, owner: .coucou) && NotchCoordination.permits(.brightnessHUD, owner: .orbit))
}

@MainActor @Test func theNewestHUDTakesTheSharedSlot() async {
    var volume = SystemVolumeStatus.device(VolumeState(device: 1, name: "Speakers", volume: 0.5, isMuted: false, canSetVolume: true))
    var level: Double? = 0.5
    var presses = 0
    let coordinator = NotchOverlayCoordinator(hud: VolumeHUD(scheduler: FakeScheduler()), brightness: BrightnessHUD(scheduler: FakeScheduler()))
    let box = InputsBox()
    coordinator.start { [box] in
        _ = box.tick
        return .init(volume: volume, island: .hidden, dashboardOpen: false, brightness: level, brightnessPresses: presses)
    }
    level = 0.75
    box.tick += 1
    await settle()
    #expect(coordinator.overlay == .brightnessHUD && coordinator.lastHUD == .brightness)
    volume = .device(VolumeState(device: 1, name: "Speakers", volume: 0.2, isMuted: false, canSetVolume: true))
    box.tick += 1
    await settle()
    #expect(coordinator.overlay == .volumeHUD && coordinator.lastHUD == .volume && !coordinator.brightness.isVisible)  // no stacking
    presses += 1
    box.tick += 1
    await settle()
    #expect(coordinator.overlay == .brightnessHUD && !coordinator.hud.isVisible && coordinator.coversIsland)
    coordinator.shutdown()
    #expect(coordinator.overlay == .none && !coordinator.brightness.isVisible)
}

@MainActor @Observable private final class InputsBox { var tick = 0 }

@MainActor private func settle() async {
    for _ in 0 ..< 5 { await Task.yield() }
    try? await Task.sleep(for: .milliseconds(20))
}

@MainActor @Test func theMonitorReadsOnlyWhileRunningAndCountsItsSources() async {
    var value: Double? = 0.4
    let monitor = BrightnessMonitor(read: { value }, pollInterval: .milliseconds(10), watchesSystem: false)
    #expect(monitor.level == nil && !monitor.isRunning)
    monitor.start()
    #expect(monitor.level == 0.4)
    value = 0.8
    for _ in 0 ..< 100 where monitor.level != 0.8 { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(monitor.level == 0.8 && monitor.noticed[.poll] == 1)
    monitor.keyPressed()
    #expect(monitor.presses == 1)
    monitor.stop()
    value = 0.1
    try? await Task.sleep(for: .milliseconds(60))
    #expect(monitor.level == 0.8)  // stopped: no reads
    monitor.keyPressed()
    #expect(monitor.presses == 1)
}

@MainActor @Test func theCapsuleRenders() throws {
    for (level, name) in [(0.08, "brightness-low"), (0.5, "brightness-half"), (1.0, "brightness-full")] {
        try renderCapsule(BrightnessCapsule(level: level, pulse: 0, reduceMotion: true), name)
    }
    try renderCapsule(BrightnessCapsule(level: 0.62, pulse: 0, reduceMotion: true, highContrast: true), "brightness-increased-contrast")
}

@MainActor
private func renderCapsule(_ view: some View, _ name: String) throws {
    let framed = view.padding(24)
        .background(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.62, blue: 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    let image = try #require(renderer.cgImage, "\(name) didn't render")
    #expect(image.width == Int((SonicPulse.size.width + 48) * 2))
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m9-brightness").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}
