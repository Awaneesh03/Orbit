import Foundation
import Observation

// Orbit Pet (Stage 5.2): the cat's behaviour, before any graphics or windows.
// One pet, shown by up to two experiences (the Desktop Pet and the Notch
// Companion); this model decides what it's doing and what the renderer may
// animate. Later stages draw it (5.3), move it (5.4) and place it (5.6).

/// The pet's state machine. Every change goes through `next`, a pure table;
/// anything it rejects leaves the state alone. Each state owns its timers:
/// - hidden, sleeping, dragged: none.
/// - idle: a low-frequency `fidget` cue (a blink or tail flick for the
///   renderer) and, on the desktop, a `wander` that starts a walk; neither
///   with Reduce Motion.
/// - playful: one reaction, then idle.
/// - walking / running: a safety limit, in case the mover never finishes.
/// Entering a state cancels the previous state's timers and bumps the
/// generation, so a late callback can't act on a state that has moved on.
@MainActor @Observable
final class PetModel {
    enum State: String, CaseIterable, Sendable {
        case hidden, idle, playful, walking, running, sleeping, dragged
    }

    enum Event: Equatable, Sendable {
        case show, hide
        case click, reactionEnded
        case move(running: Bool), moveEnded
        case inactive, active
        case dragBegan, dragEnded
    }

    /// The master switch and the two experiences; each experience shows only
    /// with the master on, and neither needs the other.
    struct Toggles: Equatable, Codable, Sendable {
        var pet = false  // Orbit Pet is off by default
        var desktop = true
        var companion = true
    }

    struct Timing: Sendable {
        var fidget: Duration = .seconds(8)
        var wander: Duration = .seconds(45)
        var play: Duration = .milliseconds(1200)
        /// The click reaction with Reduce Motion: kept, but brief and still.
        var reducedPlay: Duration = .milliseconds(500)
        var maxMove: Duration = .seconds(8)
    }

    /// The transition table. `canMove`: the Desktop Pet is on screen and
    /// Reduce Motion is off; `canDrag`: the Desktop Pet is on screen (the
    /// companion only reacts to clicks).
    nonisolated static func next(_ state: State, _ event: Event, canMove: Bool, canDrag: Bool) -> State? {
        switch (state, event) {
        case (.hidden, .show): .idle
        case (.hidden, _), (_, .show): nil
        case (_, .hide): .hidden
        case (.dragged, .dragEnded): .idle
        case (.dragged, _): nil  // held: nothing else until it's let go
        case (_, .click): .playful  // from idle, playful (again), moving or asleep
        case (.playful, .reactionEnded): .idle
        case (.idle, .move(let running)), (.walking, .move(let running)), (.running, .move(let running)):
            canMove && state != (running ? .running : .walking) ? (running ? .running : .walking) : nil
        case (.walking, .moveEnded), (.running, .moveEnded): .idle
        case (.idle, .inactive): .sleeping
        case (.sleeping, .active): .idle
        case (_, .dragBegan): canDrag ? .dragged : nil
        default: nil
        }
    }

    private(set) var state = State.hidden
    /// Idle cues so far: the renderer plays one small one-shot per change.
    private(set) var fidgets = 0
    /// Click reactions so far: one one-shot per change.
    private(set) var reactions = 0
    var toggles = Toggles() { didSet { if toggles != oldValue { update() } } }

    let activity: PetActivity
    @ObservationIgnored let timing: Timing
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let choosesRunning: @MainActor () -> Bool
    @ObservationIgnored private var stateTimer: (any HUDTimer)?
    @ObservationIgnored private var fidgetTimer: (any HUDTimer)?
    @ObservationIgnored private var wanderTimer: (any HUDTimer)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = true

    init(activity: PetActivity, scheduler: any HUDScheduler = TaskHUDScheduler(), timing: Timing = Timing(),
         choosesRunning: @escaping @MainActor () -> Bool = { Double.random(in: 0 ..< 1) < 0.25 }) {
        self.activity = activity
        self.scheduler = scheduler
        self.timing = timing
        self.choosesRunning = choosesRunning
        activity.onChange = { [weak self] in self?.update() }
    }

    // MARK: Where the pet is shown

    private var presentable: Bool { running && toggles.pet && activity.isAwake && !activity.conditions.fullScreen }
    /// The Desktop Pet is on screen and should animate.
    var desktopVisible: Bool { presentable && toggles.desktop && !activity.conditions.desktopOccluded }
    /// The Notch Companion is on screen and should animate.
    var companionVisible: Bool { presentable && toggles.companion && !activity.conditions.companionOccluded }
    var reduceMotion: Bool { activity.conditions.reduceMotion }
    var canMove: Bool { desktopVisible && !reduceMotion }
    /// Timers pending (tests).
    var pendingTimers: Int { [stateTimer, fidgetTimer, wanderTimer].compactMap { $0 }.count }

    // MARK: Inputs

    /// A click on the pet: a playful reaction (counts as the user being here).
    @discardableResult
    func click() -> Bool {
        guard state != .hidden else { return false }
        activity.userActivity()
        return send(.click)
    }

    /// The desktop mover starts a walk or a run (or the pet's own wander does).
    @discardableResult
    func startMoving(running: Bool) -> Bool { send(.move(running: running)) }

    /// The mover arrived.
    func finishMoving() { send(.moveEnded) }

    @discardableResult
    func beginDrag() -> Bool {
        guard state != .hidden else { return false }
        activity.userActivity()
        return send(.dragBegan)
    }

    func endDrag() { send(.dragEnded) }

    /// Another Space: a walk or a drag doesn't carry over.
    func spaceChanged() {
        activity.spaceChanged()
        if state == .dragged { send(.dragEnded) }
        if state == .walking || state == .running { send(.moveEnded) }
    }

    /// Orbit quitting: hidden, nothing scheduled, every later input ignored.
    func shutdown() {
        guard running else { return }
        send(.hide)
        running = false
        cancelTimers()
        activity.stop()
    }

    // MARK: State

    /// Brings the state in line with the toggles and conditions.
    private func update() {
        guard running else { return }
        guard desktopVisible || companionVisible else {
            send(.hide)
            activity.setTracking(false)  // nothing runs for a pet nobody can see
            return
        }
        activity.setTracking(true)
        if state == .hidden { send(.show) }
        if !desktopVisible, state == .dragged { send(.dragEnded) }
        if !canMove, state == .walking || state == .running { send(.moveEnded) }
        send(activity.isUserInactive ? .inactive : .active)
        if state == .idle { scheduleIdle() }  // e.g. Reduce Motion or the desktop changed what idle runs
    }

    @discardableResult
    private func send(_ event: Event) -> Bool {
        guard running, let next = Self.next(state, event, canMove: canMove, canDrag: desktopVisible) else { return false }
        enter(next, by: event)
        return true
    }

    private func enter(_ next: State, by event: Event) {
        cancelTimers()
        state = next
        if event == .click { reactions += 1 }
        let current = generation
        switch next {
        case .idle:
            if activity.isUserInactive { send(.inactive); return }
            scheduleIdle()
        case .playful:
            stateTimer = scheduler.after(reduceMotion ? timing.reducedPlay : timing.play) { [weak self] in
                self?.fired(current) { $0.send(.reactionEnded) }
            }
        case .walking, .running:
            stateTimer = scheduler.after(timing.maxMove) { [weak self] in
                self?.fired(current) { $0.send(.moveEnded) }
            }
        case .hidden, .sleeping, .dragged:
            break
        }
    }

    /// Idle's two low-frequency timers, neither with Reduce Motion.
    private func scheduleIdle() {
        fidgetTimer?.cancel()
        wanderTimer?.cancel()
        fidgetTimer = nil
        wanderTimer = nil
        guard !reduceMotion else { return }
        scheduleFidget()
        guard canMove else { return }
        let current = generation
        wanderTimer = scheduler.after(timing.wander) { [weak self] in
            self?.fired(current) { model in
                model.wanderTimer = nil
                model.startMoving(running: model.choosesRunning())
            }
        }
    }

    /// The next idle cue; rescheduled on its own, so it never delays the wander.
    private func scheduleFidget() {
        let current = generation
        fidgetTimer = scheduler.after(timing.fidget) { [weak self] in
            self?.fired(current) { model in
                model.fidgets += 1
                model.scheduleFidget()
            }
        }
    }

    /// Runs a timer's work only if nothing has changed since it was set.
    private func fired(_ registered: Int, _ work: (PetModel) -> Void) {
        guard running, registered == generation else { return }
        work(self)
    }

    private func cancelTimers() {
        generation += 1
        for timer in [stateTimer, fidgetTimer, wanderTimer] { timer?.cancel() }
        stateTimer = nil
        fidgetTimer = nil
        wanderTimer = nil
    }
}
