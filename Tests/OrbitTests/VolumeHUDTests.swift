import CoreAudio
import Observation
import Testing
@testable import Orbit

// Stage 4.1-2: the volume HUD's state machine and the notch overlay
// arbitration. A manual clock and fake inputs: no real delays, no real volume.

/// Timers on a manual clock (also used by PetModelTests); keeps every action ever scheduled so a stale one
/// can be run by hand.
@MainActor
final class FakeScheduler: HUDScheduler {
    final class Timer: HUDTimer {
        let due: Duration
        var action: (@MainActor () -> Void)?
        init(due: Duration, action: @escaping @MainActor () -> Void) {
            self.due = due
            self.action = action
        }
        func cancel() { action = nil }
    }

    private(set) var now = Duration.zero
    private(set) var timers: [Timer] = []
    private(set) var everScheduled: [@MainActor () -> Void] = []
    var live: Int { timers.filter { $0.action != nil }.count }

    func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any HUDTimer {
        let timer = Timer(due: now + delay, action: action)
        timers.append(timer)
        everScheduled.append(action)
        return timer
    }

    func advance(_ step: Duration) {
        let end = now + step
        while let next = timers.filter({ $0.action != nil && $0.due <= end }).min(by: { $0.due < $1.due }) {
            now = next.due
            let action = next.action
            next.action = nil
            action?()
        }
        now = end
    }
}

private func device(_ id: AudioObjectID = 10, volume: Float? = 0.5, muted: Bool? = false, name: String = "Speakers") -> SystemVolumeStatus {
    .device(VolumeState(device: id, name: name, volume: volume, isMuted: muted, canSetVolume: volume != nil))
}

@MainActor
private func hud() -> (VolumeHUD, FakeScheduler) {
    let scheduler = FakeScheduler()
    return (VolumeHUD(scheduler: scheduler), scheduler)
}

// MARK: State machine

@MainActor @Test func theFirstReadingAndRepeatsNeverShowIt() {
    let (hud, scheduler) = hud()
    #expect(hud.phase == .hidden)
    hud.receive(device(), suppressed: false)  // the reading at start: a baseline, not a change
    hud.receive(device(), suppressed: false)
    hud.receive(device(name: "Speakers (renamed)"), suppressed: false)  // not a volume change
    hud.receive(device(volume: 0.5004), suppressed: false)  // driver rounding
    #expect(hud.phase == .hidden && scheduler.live == 0)
}

@MainActor @Test func aChangeShowsItAndItDismissesAfterOneAndAHalfSeconds() {
    let (hud, scheduler) = hud()
    hud.receive(device(), suppressed: false)
    hud.receive(device(volume: 0.6), suppressed: false)
    #expect(hud.phase == .visible && hud.shown?.volume == 0.6 && scheduler.live == 2)
    scheduler.advance(.milliseconds(300))
    #expect(hud.phase == .pendingDismissal)  // settled: the interaction expansion ends
    scheduler.advance(.milliseconds(1199))
    #expect(hud.isVisible)
    scheduler.advance(.milliseconds(1))
    #expect(hud.phase == .hidden && scheduler.live == 0 && hud.shown?.volume == 0.6)  // kept to animate away

    hud.receive(device(volume: 0.6, muted: true), suppressed: false)  // mute
    #expect(hud.phase == .visible && hud.shown?.isMuted == true)
    scheduler.advance(.milliseconds(1500))
    hud.receive(device(volume: 0.6, muted: false), suppressed: false)  // unmute
    #expect(hud.phase == .visible && hud.shown?.isMuted == false)
}

@MainActor @Test func rapidChangesUpdateOneHUDAndRestartItsTimer() {
    let (hud, scheduler) = hud()
    hud.reduceMotion = false
    hud.receive(device(), suppressed: false)
    for (step, level) in [(0, 0.55), (200, 0.6), (200, 0.65), (400, 0.7), (500, 0.75)] as [(Int, Float)] {
        scheduler.advance(.milliseconds(step))
        hud.receive(device(volume: level), suppressed: false)
        #expect(scheduler.live == 2)  // one settle timer, one dismiss timer: never more
    }
    #expect(hud.phase == .updating && hud.isExpanded && hud.shown?.volume == 0.75)
    hud.reduceMotion = true
    #expect(!hud.isExpanded)  // no growing with Reduce Motion
    scheduler.advance(.milliseconds(1499))
    #expect(hud.isVisible)  // 1.5 s after the last change, not the first
    scheduler.advance(.milliseconds(1))
    #expect(hud.phase == .hidden)
}

@MainActor @Test func devicesWithoutVolumeAndMissingDevicesNeverInventALevel() {
    let (hud, scheduler) = hud()
    hud.receive(device(), suppressed: false)
    hud.receive(device(20, volume: 0.3, name: "CX80U"), suppressed: false)  // switched to a headset
    #expect(hud.isVisible && hud.shown?.name == "CX80U" && hud.shown?.volume == 0.3)
    hud.receive(device(30, volume: nil, muted: nil, name: "LG HDR 4K"), suppressed: false)  // no software volume
    #expect(hud.isVisible && hud.shown?.volume == nil && hud.shown?.isMuted == nil)
    scheduler.advance(.milliseconds(1500))
    hud.receive(device(30, volume: nil, muted: nil, name: "LG HDR 4K"), suppressed: false)
    #expect(hud.phase == .hidden)  // nothing changed on it

    hud.receive(.noOutputDevice, suppressed: false)
    #expect(hud.phase == .hidden)
    hud.receive(device(), suppressed: false)  // a device again: a fresh baseline, not a "change"
    #expect(hud.phase == .hidden)
}

@MainActor @Test func orbitsOwnChangeComingBackDoesNotShowIt() {
    let (hud, _) = hud()
    hud.receive(device(), suppressed: false)
    hud.expectOrbitChange(volume: 0.7, isMuted: false)  // a later volume control sets 70 %
    hud.receive(device(volume: 0.7), suppressed: false)  // CoreAudio's echo of it
    #expect(hud.phase == .hidden)
    hud.receive(device(volume: 0.8), suppressed: false)  // the next change is the user's
    #expect(hud.isVisible)
}

@MainActor @Test func anExpectedEchoNeverGoesStale() {
    let (hud, scheduler) = hud()
    hud.receive(device(), suppressed: false)
    hud.expectOrbitChange(volume: 0.7, isMuted: false)
    hud.receive(device(volume: 0.6), suppressed: false)  // the user's change arrives first
    #expect(hud.isVisible && !hud.expectsEcho)  // shown, and the expectation is used up
    hud.receive(device(volume: 0.7), suppressed: false)  // that value later is the user's too
    #expect(hud.pulse == 2)
    scheduler.advance(.seconds(3))
    #expect(!hud.isVisible && scheduler.live == 0)

    hud.expectOrbitChange(volume: 0.4, isMuted: false)  // and its echo never comes
    #expect(hud.expectsEcho && scheduler.live == 1)
    scheduler.advance(VolumeHUD.echoWindow)
    #expect(!hud.expectsEcho && scheduler.live == 0)  // expired
    hud.receive(device(volume: 0.4), suppressed: false)  // the user picks that level later
    #expect(hud.isVisible && hud.pulse == 3)

    hud.expectOrbitChange(volume: 0.1, isMuted: false)
    hud.expectOrbitChange(volume: 0.2, isMuted: false)  // a second one replaces the first
    #expect(hud.pendingTimers == 3)  // settle, dismiss, one echo window
    hud.shutdown()
    #expect(!hud.expectsEcho && scheduler.live == 0)
    hud.expectOrbitChange(volume: 0.3, isMuted: false)  // ignored while off
    #expect(!hud.expectsEcho && scheduler.live == 0)
}

@MainActor @Test func lateTimersAndEventsAfterShutdownAreIgnored() {
    let (hud, scheduler) = hud()
    hud.receive(device(), suppressed: false)
    hud.receive(device(volume: 0.6), suppressed: false)
    let firstDismiss = scheduler.everScheduled[1]
    scheduler.advance(.milliseconds(1000))
    hud.receive(device(volume: 0.7), suppressed: false)  // restarts the timers
    firstDismiss()  // the old dismissal fires anyway
    #expect(hud.isVisible)

    hud.shutdown()
    #expect(hud.phase == .hidden && scheduler.live == 0)
    hud.receive(device(volume: 0.2), suppressed: false)
    scheduler.everScheduled.forEach { $0() }  // every timer ever made, late
    #expect(hud.phase == .hidden && scheduler.live == 0)
}

@MainActor @Test func suppressedChangesAreNotedButNotShown() {
    let (hud, _) = hud()
    hud.receive(device(), suppressed: false)
    hud.receive(device(volume: 0.6), suppressed: true)  // while the dashboard is open
    #expect(hud.phase == .hidden)
    hud.receive(device(volume: 0.6), suppressed: false)  // the dashboard closes: not a new change
    #expect(hud.phase == .hidden)
    hud.receive(device(volume: 0.65), suppressed: false)
    hud.spaceChanged()
    #expect(hud.phase == .hidden)
}

// MARK: Arbitration

@Test func theOverlayPriorityRules() {
    for island in [MusicIsland.Phase.hidden, .compact, .expanded, .dismissed] {
        for volume in [false, true] {
            #expect(NotchOverlayCoordinator.decide(dashboardOpen: true, island: island, volumeVisible: volume) == .none)
        }
        let expected: NotchOverlay = switch island {
        case .expanded: .musicIsland
        default: .volumeHUD
        }
        #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: island, volumeVisible: true) == expected)
    }
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .compact, volumeVisible: false) == .musicIsland)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .expanded, volumeVisible: false) == .musicIsland)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .dismissed, volumeVisible: false) == .none)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .hidden, volumeVisible: false) == .none)
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
    for _ in 0 ..< 100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor @Test func theHUDCoversACompactIslandAndHandsItBack() async {
    let scheduler = FakeScheduler()
    let coordinator = NotchOverlayCoordinator(hud: VolumeHUD(scheduler: scheduler))
    let inputs = FakeInputs()
    inputs.island = .compact
    coordinator.start { inputs.snapshot }
    #expect(coordinator.overlay == .musicIsland)

    inputs.volume = device(volume: 0.7)
    #expect(await eventually { coordinator.overlay == .volumeHUD && coordinator.coversIsland })
    #expect(inputs.island == .compact)  // the island's own state untouched
    scheduler.advance(.milliseconds(1500))
    #expect(await eventually { coordinator.overlay == .musicIsland })  // still compact: it comes back

    inputs.volume = device(volume: 0.8)
    #expect(await eventually { coordinator.overlay == .volumeHUD })
    inputs.island = .dismissed  // its own 4 s ran out underneath
    scheduler.advance(.milliseconds(1500))
    #expect(await eventually { coordinator.overlay == .none })  // it stays dismissed
    coordinator.shutdown()
}

@MainActor @Test func theDashboardAndTheExpandedPlayerSuppressTheHUD() async {
    let scheduler = FakeScheduler()
    let coordinator = NotchOverlayCoordinator(hud: VolumeHUD(scheduler: scheduler))
    let inputs = FakeInputs()
    coordinator.start { inputs.snapshot }
    inputs.volume = device(volume: 0.6)
    #expect(await eventually { coordinator.overlay == .volumeHUD })

    inputs.dashboardOpen = true  // the user hovers the notch mid-adjustment
    #expect(await eventually { coordinator.overlay == .none && !coordinator.hud.isVisible })
    inputs.volume = device(volume: 0.7)  // changed while it's open
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!coordinator.hud.isVisible && scheduler.live == 0)
    inputs.dashboardOpen = false
    try? await Task.sleep(for: .milliseconds(30))
    #expect(coordinator.overlay == .none)  // closing it doesn't replay the change

    inputs.island = .expanded
    inputs.volume = device(volume: 0.5)
    #expect(await eventually { coordinator.overlay == .musicIsland })
    try? await Task.sleep(for: .milliseconds(30))
    #expect(!coordinator.hud.isVisible)  // the expanded player keeps the slot
    coordinator.shutdown()
}

@MainActor @Test func rapidTransitionsKeepOneOverlayAndShutdownStopsEverything() async {
    let scheduler = FakeScheduler()
    let coordinator = NotchOverlayCoordinator(hud: VolumeHUD(scheduler: scheduler))
    let inputs = FakeInputs()
    coordinator.start { inputs.snapshot }
    coordinator.start { inputs.snapshot }  // a second start does nothing
    for step in 0 ..< 12 {
        inputs.volume = device(volume: Float(step) / 20)
        inputs.island = [.compact, .expanded, .compact, .dismissed][step % 4]
        inputs.dashboardOpen = step % 5 == 4
        try? await Task.sleep(for: .milliseconds(3))
        #expect(scheduler.live <= 2)  // never duplicate timers
    }
    let expected = NotchOverlayCoordinator.decide(dashboardOpen: inputs.dashboardOpen, island: inputs.island,
                                                  volumeVisible: coordinator.hud.isVisible)
    #expect(await eventually { coordinator.overlay == expected })  // settles on the rules' answer

    coordinator.shutdown()
    #expect(coordinator.overlay == .none && !coordinator.hud.isVisible && scheduler.live == 0)
    inputs.volume = device(volume: 0.99)
    inputs.island = .compact
    try? await Task.sleep(for: .milliseconds(30))
    #expect(coordinator.overlay == .none && !coordinator.hud.isVisible)  // nothing follows after shutdown
}
