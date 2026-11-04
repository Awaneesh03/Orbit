import CoreGraphics
import Foundation

// Orbit Pet (Stage 5.2): what's going on around the pet, as plain inputs.
// No windows, no event monitors and no permissions here: later phases feed
// it (window occlusion, NSWorkspace sleep/lock notifications, a mouse
// monitor), tests feed it directly.

/// The conditions the pet adapts to, and whether the user has stepped away.
/// Inactivity is tracked with one timer set for the moment the threshold
/// would pass (no polling); while the user is away, the display is asleep or
/// the session is locked, nothing is scheduled at all.
@MainActor
final class PetActivity {
    struct Conditions: Equatable, Sendable {
        var displayAsleep = false
        var sessionLocked = false
        /// The active Space is a full-screen app: neither experience shows there.
        var fullScreen = false
        var desktopOccluded = false
        var companionOccluded = false
        var reduceMotion = false
    }

    private(set) var conditions = Conditions()
    /// No input for `inactivityThreshold`; cleared by the next activity.
    private(set) var isUserInactive = false
    /// Called after any change to `conditions` or `isUserInactive`.
    var onChange: (@MainActor () -> Void)?

    let inactivityThreshold: Duration
    private let scheduler: any HUDScheduler
    private let idleSeconds: @MainActor () -> Double
    private var timer: (any HUDTimer)?
    private var generation = 0
    private var tracking = false

    /// `idleSeconds`: time since the user's last input of any kind. The real
    /// source (`systemIdleSeconds`) is a timestamp only: no event content, no
    /// monitoring, no permission.
    init(scheduler: any HUDScheduler = TaskHUDScheduler(), inactivityThreshold: Duration = .seconds(120),
         idleSeconds: @escaping @MainActor () -> Double = PetActivity.systemIdleSeconds) {
        self.scheduler = scheduler
        self.inactivityThreshold = inactivityThreshold
        self.idleSeconds = idleSeconds
    }

    static func systemIdleSeconds() -> Double {
        // kCGAnyInputEventType (~0): the most recent input of any type.
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    var isAwake: Bool { !conditions.displayAsleep && !conditions.sessionLocked }
    /// Timers pending (tests: zero or one).
    var pendingTimers: Int { timer == nil ? 0 : 1 }

    /// Whether inactivity is worth tracking: the pet model turns it off while
    /// the pet is hidden, so nothing runs for a pet nobody can see.
    func setTracking(_ on: Bool) {
        guard on != tracking else { return }
        tracking = on
        rearm()
    }

    /// The pointer moved, the user clicked the pet, …: they're here.
    func userActivity() { markActive() }
    /// Switching Spaces is the user acting too.
    func spaceChanged() { markActive() }

    func setDisplayAsleep(_ asleep: Bool) { change { $0.displayAsleep = asleep }; if !asleep { markActive() } }
    func setSessionLocked(_ locked: Bool) { change { $0.sessionLocked = locked }; if !locked { markActive() } }
    func setFullScreen(_ on: Bool) { change { $0.fullScreen = on } }
    func setDesktopOccluded(_ on: Bool) { change { $0.desktopOccluded = on } }
    func setCompanionOccluded(_ on: Bool) { change { $0.companionOccluded = on } }
    func setReduceMotion(_ on: Bool) { change { $0.reduceMotion = on } }

    /// Orbit quitting: nothing scheduled, nothing reported.
    func stop() {
        tracking = false
        onChange = nil
        cancel()
    }

    private func change(_ edit: (inout Conditions) -> Void) {
        var next = conditions
        edit(&next)
        guard next != conditions else { return }
        let wasAwake = isAwake
        conditions = next
        if isAwake != wasAwake { rearm() }  // only sleep and lock affect inactivity tracking
        onChange?()
    }

    /// An activity event: the user is here now, whatever the idle timestamp
    /// last said (so a wake never bounces straight back to sleep).
    private func markActive() {
        if isUserInactive {
            isUserInactive = false
            rearm(justActive: true)
            onChange?()
        } else {
            rearm(justActive: true)
        }
    }

    /// One timer for when the threshold would pass, given the idle time so far.
    private func rearm(justActive: Bool = false) {
        cancel()
        guard tracking, isAwake, !isUserInactive else { return }
        let remaining = Self.seconds(inactivityThreshold) - (justActive ? 0 : idleSeconds())
        guard remaining > 0 else { return becomeInactive() }
        let current = generation
        timer = scheduler.after(.milliseconds(Int((remaining * 1000).rounded(.up)))) { [weak self] in
            self?.check(current)
        }
    }

    private func check(_ registered: Int) {
        guard registered == generation else { return }  // superseded
        timer = nil
        rearm()  // inactive by now, or input came meanwhile: wait for the rest
    }

    private func becomeInactive() {
        isUserInactive = true
        onChange?()
    }

    private func cancel() {
        generation += 1
        timer?.cancel()
        timer = nil
    }

    static func seconds(_ duration: Duration) -> Double {
        Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18
    }
}
