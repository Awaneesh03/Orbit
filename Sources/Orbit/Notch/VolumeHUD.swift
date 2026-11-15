import Foundation
import Observation

// The Sonic Pulse volume HUD's logic (Stage 4.1-2): when to show, update and
// dismiss it, and which overlay owns the slot below the notch. The window and
// view are `SystemHUDPanel` / `SonicPulseView` (4.1-3).

/// Runs an action later, cancellably; injectable so tests needn't wait.
@MainActor
protocol HUDScheduler: AnyObject {
    func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any HUDTimer
}

@MainActor
protocol HUDTimer: AnyObject {
    func cancel()
}

/// The real scheduler: one sleeping task per timer, no polling.
@MainActor
final class TaskHUDScheduler: HUDScheduler {
    private final class Timer: HUDTimer {
        var task: Task<Void, Never>?
        func cancel() { task?.cancel() }
    }

    func after(_ delay: Duration, _ action: @escaping @MainActor () -> Void) -> any HUDTimer {
        let timer = Timer()
        timer.task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled else { return }
            action()
        }
        return timer
    }
}

/// The volume HUD's state.
/// - hidden: nothing on screen.
/// - visible: a change just showed it.
/// - updating: more changes are arriving (the user is adjusting; the HUD may
///   grow a little, not with Reduce Motion).
/// - pendingDismissal: no change for `settleDelay`; it hides `dismissDelay`
///   after the last change.
/// Only a real change of device, volume or mute shows it: the first reading,
/// a repeat of the same values, a name change and an expected echo of a change
/// Orbit itself made don't.
@MainActor @Observable
final class VolumeHUD {
    enum Phase: Equatable { case hidden, visible, updating, pendingDismissal }

    private(set) var phase = Phase.hidden
    /// What the HUD shows; kept while hiding so it can animate away. A device
    /// without software volume has `volume == nil`: never a made-up percentage.
    private(set) var shown: VolumeState?
    /// Counts the changes shown: the view plays one decorative pulse per new value.
    private(set) var pulse = 0
    /// The last change was a different output device: the HUD names it.
    private(set) var showsDevice = false
    var reduceMotion = false

    @ObservationIgnored let settleDelay: Duration
    /// Settings › General › Stay for (read at each new change).
    @ObservationIgnored var dismissDelay: Duration
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private var baseline: VolumeState?
    @ObservationIgnored private var settleTimer: (any HUDTimer)?
    @ObservationIgnored private var dismissTimer: (any HUDTimer)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = true
    @ObservationIgnored private var expectedEcho: (volume: Float?, isMuted: Bool?)?
    @ObservationIgnored private var echoTimer: (any HUDTimer)?

    /// Volume differences smaller than this are the same level (driver rounding).
    static let volumeTolerance: Float = 0.001
    /// How long an expected echo of Orbit's own change is waited for.
    static let echoWindow = Duration.seconds(1)

    init(scheduler: any HUDScheduler = TaskHUDScheduler(), settleDelay: Duration = .milliseconds(300),
         dismissDelay: Duration = .milliseconds(1500)) {
        self.scheduler = scheduler
        self.settleDelay = settleDelay
        self.dismissDelay = dismissDelay
    }

    var isVisible: Bool { phase != .hidden }
    /// The interaction expansion: only while changes are arriving, never with Reduce Motion.
    var isExpanded: Bool { phase == .updating && !reduceMotion }
    /// Timers pending (tests: never more than one of each).
    var pendingTimers: Int { (settleTimer == nil ? 0 : 1) + (dismissTimer == nil ? 0 : 1) + (echoTimer == nil ? 0 : 1) }

    /// A new reading from `SystemVolume`. `suppressed`: something with higher
    /// priority owns the slot (the dashboard, the expanded player); the change
    /// is noted but not shown.
    func receive(_ status: SystemVolumeStatus, suppressed: Bool) {
        guard running else { return }
        guard case .device(let new) = status else {
            baseline = nil  // stopped, or no output: nothing to show or compare with
            return hide()
        }
        let old = baseline
        baseline = new
        guard let old, Self.differs(old, new) else {
            if isVisible, shown != new { shown = new }  // e.g. a name change: refreshed quietly
            return
        }
        if let echo = expectedEcho {
            clearEcho()  // the next change uses up the expectation, whatever it is
            if Self.matches(new, echo) {  // Orbit's own change coming back: no HUD, no loop
                if isVisible { shown = new }
                return
            }
        }
        guard !suppressed else { return hide() }
        showsDevice = old.device != new.device
        show(new)
    }

    /// A later volume control calls this before changing the volume, so the
    /// listener's echo of that change doesn't show (or re-trigger) the HUD.
    /// The expectation lasts until the next change or `echoWindow`, so it can
    /// never hide an unrelated change later (e.g. if the echo never came).
    func expectOrbitChange(volume: Float?, isMuted: Bool?) {
        guard running else { return }
        clearEcho()
        expectedEcho = (volume, isMuted)
        echoTimer = scheduler.after(Self.echoWindow) { [weak self] in self?.clearEcho() }
    }

    /// An expectation still waiting for its echo (tests).
    var expectsEcho: Bool { expectedEcho != nil }

    private func clearEcho() {
        echoTimer?.cancel()
        echoTimer = nil
        expectedEcho = nil
    }

    /// Something with higher priority took the slot, or the Space changed.
    func suppress() { hide() }
    func spaceChanged() { hide() }

    /// Orbit is quitting or the HUD is turned off: no timers, nothing later.
    func shutdown() {
        running = false
        baseline = nil
        clearEcho()
        hide()
    }

    /// Back on after `shutdown()` (the setting turned on again). The next
    /// reading is a baseline, so turning it on never shows the HUD by itself.
    func resume() {
        running = true
    }

    private func show(_ state: VolumeState) {
        shown = state
        pulse += 1
        phase = phase == .hidden ? .visible : .updating
        generation += 1
        let current = generation
        settleTimer?.cancel()
        dismissTimer?.cancel()
        settleTimer = scheduler.after(settleDelay) { [weak self] in self?.settled(current) }
        dismissTimer = scheduler.after(dismissDelay) { [weak self] in self?.dismissed(current) }
    }

    private func settled(_ registered: Int) {
        guard registered == generation, phase == .visible || phase == .updating else { return }
        settleTimer = nil
        phase = .pendingDismissal
    }

    private func dismissed(_ registered: Int) {
        guard registered == generation else { return }
        hide()
    }

    private func hide() {
        generation += 1  // any timer still in flight is now stale
        settleTimer?.cancel()
        dismissTimer?.cancel()
        settleTimer = nil
        dismissTimer = nil
        if phase != .hidden { phase = .hidden }
    }

    static func differs(_ a: VolumeState, _ b: VolumeState) -> Bool {
        a.device != b.device || a.isMuted != b.isMuted || !sameLevel(a.volume, b.volume)
    }

    private static func matches(_ state: VolumeState, _ echo: (volume: Float?, isMuted: Bool?)) -> Bool {
        sameLevel(state.volume, echo.volume) && state.isMuted == echo.isMuted
    }

    private static func sameLevel(_ a: Float?, _ b: Float?) -> Bool {
        switch (a, b) {
        case (nil, nil): true
        case let (a?, b?): abs(a - b) < volumeTolerance
        default: false
        }
    }
}

// MARK: Overlay arbitration

/// What occupies the slot below the notch. One at a time.
enum NotchOverlay: Equatable {
    case none, musicIsland, volumeHUD, brightnessHUD

    /// Either system HUD (they share one window and slot).
    var isHUD: Bool { self == .volumeHUD || self == .brightnessHUD }
}

/// Which system HUD showed last: it owns the shared slot and window.
enum SystemHUDKind: Equatable, Sendable { case volume, brightness }

/// Decides who owns the slot below the notch, and keeps the volume HUD in
/// step with its inputs. Priority: an open dashboard (neither: the dashboard
/// covers the slot), then the expanded music player, then the volume HUD
/// (it covers a compact island for a moment), then the compact island. It
/// never changes the island's own state: a compact island covered by the HUD
/// comes back if it's still compact when the HUD goes, and one that dismissed
/// itself meanwhile stays dismissed.
@MainActor @Observable
final class NotchOverlayCoordinator {
    struct Inputs: Equatable {
        var volume: SystemVolumeStatus
        var island: MusicIsland.Phase
        var dashboardOpen: Bool
        /// The built-in backlight (nil: none, or the brightness HUD is off) and key presses (Milestone 9).
        var brightness: Double? = nil
        var brightnessPresses = 0
    }

    let hud: VolumeHUD
    let brightness: BrightnessHUD
    private(set) var overlay = NotchOverlay.none
    /// The system HUD that showed last; the other one gives way at once (no stacking, no flicker).
    private(set) var lastHUD = SystemHUDKind.volume
    /// The dashboard or the expanded player owns the slot: the HUD leaves at
    /// once rather than fading out over them.
    private(set) var isSuppressed = false
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private(set) var isRunning = false

    init(hud: VolumeHUD, brightness: BrightnessHUD = BrightnessHUD()) {
        self.hud = hud
        self.brightness = brightness
    }

    /// The compact island is covered by a system HUD right now (the island
    /// panel hides without touching the island's state).
    var coversIsland: Bool { overlay.isHUD }

    nonisolated static func decide(dashboardOpen: Bool, island: MusicIsland.Phase, volumeVisible: Bool) -> NotchOverlay {
        decide(dashboardOpen: dashboardOpen, island: island, volumeVisible: volumeVisible, brightnessVisible: false, last: .volume)
    }

    /// The approved order, with brightness in the volume HUD's place: when
    /// both are up, the one that changed last holds the slot.
    nonisolated static func decide(dashboardOpen: Bool, island: MusicIsland.Phase, volumeVisible: Bool,
                                   brightnessVisible: Bool, last: SystemHUDKind) -> NotchOverlay {
        if dashboardOpen { return .none }
        if island == .expanded { return .musicIsland }
        switch (volumeVisible, brightnessVisible) {
        case (true, true): return last == .brightness ? .brightnessHUD : .volumeHUD
        case (true, false): return .volumeHUD
        case (false, true): return .brightnessHUD
        case (false, false): return island == .compact ? .musicIsland : .none
        }
    }

    /// Follows `inputs` (and the HUD's own timers) through Observation; no polling.
    func start(_ inputs: @escaping @MainActor () -> Inputs) {
        guard !isRunning else { return }
        isRunning = true
        hud.resume()
        brightness.resume()
        generation += 1
        follow(inputs, generation: generation)
    }

    func shutdown() {
        guard isRunning else { return }
        isRunning = false
        generation += 1  // a pending re-run is now stale
        hud.shutdown()
        brightness.shutdown()
        isSuppressed = false
        overlay = .none
    }

    func spaceChanged() { hud.spaceChanged() }

    private func follow(_ inputs: @escaping @MainActor () -> Inputs, generation registered: Int) {
        guard isRunning, registered == generation else { return }
        let current = withObservationTracking {
            (inputs(), hud.isVisible, brightness.isVisible)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(inputs, generation: registered) }
        }.0
        let suppressed = current.dashboardOpen || current.island == .expanded
        if suppressed, hud.isVisible { hud.suppress() }
        if suppressed, brightness.isVisible { brightness.suppress() }
        let (volumePulse, brightnessPulse) = (hud.pulse, brightness.pulse)
        hud.receive(current.volume, suppressed: suppressed)
        brightness.receive(level: current.brightness, presses: current.brightnessPresses, suppressed: suppressed)
        // The newest HUD takes the shared slot; the other leaves at once.
        if brightness.pulse != brightnessPulse, brightness.isVisible {
            lastHUD = .brightness
            if hud.isVisible { hud.suppress() }
        } else if hud.pulse != volumePulse, hud.isVisible {
            lastHUD = .volume
            if brightness.isVisible { brightness.suppress() }
        }
        let next = Self.decide(dashboardOpen: current.dashboardOpen, island: current.island, volumeVisible: hud.isVisible,
                               brightnessVisible: brightness.isVisible, last: lastHUD)
        if isSuppressed != suppressed { isSuppressed = suppressed }
        if overlay != next { overlay = next }
    }
}
