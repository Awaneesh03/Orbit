import Testing
@testable import Orbit

// Stage 5.2: the pet's state machine and activity model. A manual clock
// (`FakeScheduler`) and a fake idle source: no real waiting, no windows.

/// "Seconds since the last input", on the manual clock.
@MainActor
private final class IdleSource {
    let clock: FakeScheduler
    private var lastInput = Duration.zero
    init(_ clock: FakeScheduler) { self.clock = clock }
    var seconds: Double { PetActivity.seconds(clock.now - lastInput) }
    /// The user typed or moved, without any event reaching the pet (like the real timestamp).
    func input() { lastInput = clock.now }
}

@MainActor
private final class Pet {
    let clock = FakeScheduler()
    let idle: IdleSource
    let activity: PetActivity
    let model: PetModel
    /// What the pet's own wander chooses: a run (true) or a walk.
    var runs = false

    init(desktop: Bool = true, companion: Bool = true, threshold: Duration = .seconds(120)) {
        idle = IdleSource(clock)
        activity = PetActivity(scheduler: clock, inactivityThreshold: threshold, idleSeconds: { [idle] in idle.seconds })
        var chooser: () -> Bool = { false }
        model = PetModel(activity: activity, scheduler: clock, choosesRunning: { chooser() })
        chooser = { [unowned self] in self.runs }
        model.toggles.desktop = desktop
        model.toggles.companion = companion
    }

    func enable() { model.toggles.pet = true }
    var timers: Int { model.pendingTimers + activity.pendingTimers }
}

// MARK: Table

private let events: [PetModel.Event] = [.show, .hide, .click, .reactionEnded, .move(running: false), .move(running: true),
                                        .moveEnded, .inactive, .active, .dragBegan, .dragEnded]

@Test func everyValidTransitionAndNothingElse() {
    let valid: [String: PetModel.State] = [
        "hidden show": .idle,
        "idle hide": .hidden, "idle click": .playful, "idle move(running: false)": .walking,
        "idle move(running: true)": .running, "idle inactive": .sleeping, "idle dragBegan": .dragged,
        "playful hide": .hidden, "playful click": .playful, "playful reactionEnded": .idle, "playful dragBegan": .dragged,
        "walking hide": .hidden, "walking click": .playful, "walking move(running: true)": .running,
        "walking moveEnded": .idle, "walking dragBegan": .dragged,
        "running hide": .hidden, "running click": .playful, "running move(running: false)": .walking,
        "running moveEnded": .idle, "running dragBegan": .dragged,
        "sleeping hide": .hidden, "sleeping click": .playful, "sleeping active": .idle, "sleeping dragBegan": .dragged,
        "dragged hide": .hidden, "dragged dragEnded": .idle,
    ]
    var accepted = 0
    for state in PetModel.State.allCases {
        for event in events {
            let key = "\(state.rawValue) \(event)"
            let next = PetModel.next(state, event, canMove: true, canDrag: true)
            #expect(next == valid[key], "\(key)")
            if next != nil { accepted += 1 }
        }
    }
    #expect(accepted == valid.count)
    // Without the desktop (or with Reduce Motion) nothing moves; without it nothing is dragged.
    for state in PetModel.State.allCases {
        #expect(PetModel.next(state, .move(running: false), canMove: false, canDrag: true) == nil)
        #expect(PetModel.next(state, .move(running: true), canMove: false, canDrag: true) == nil)
        #expect(PetModel.next(state, .dragBegan, canMove: true, canDrag: false) == nil)
    }
}

// MARK: Showing

@MainActor @Test func hiddenAndOffUntilEnabled() {
    let pet = Pet()
    #expect(pet.model.state == .hidden && !pet.model.toggles.pet)  // Orbit Pet is off by default
    #expect(pet.model.toggles.desktop && pet.model.toggles.companion)
    #expect(pet.timers == 0)
    #expect(!pet.model.click() && !pet.model.beginDrag() && !pet.model.startMoving(running: false))
    #expect(pet.model.state == .hidden && pet.model.reactions == 0 && pet.timers == 0)
    pet.enable()
    #expect(pet.model.state == .idle && pet.model.desktopVisible && pet.model.companionVisible)
    pet.model.toggles.pet = false
    #expect(pet.model.state == .hidden && pet.timers == 0)
}

@MainActor @Test func theTwoExperiencesAreIndependent() {
    let pet = Pet(desktop: true, companion: false)
    pet.enable()
    #expect(pet.model.state == .idle && pet.model.desktopVisible && !pet.model.companionVisible && pet.model.canMove)
    pet.model.toggles.desktop = false
    #expect(pet.model.state == .hidden)  // master on, both experiences off
    pet.model.toggles.companion = true
    #expect(pet.model.state == .idle && pet.model.companionVisible && !pet.model.desktopVisible && !pet.model.canMove)
    pet.model.toggles.desktop = true
    #expect(pet.model.desktopVisible && pet.model.companionVisible)
    pet.model.toggles.pet = false  // master off hides both
    #expect(pet.model.state == .hidden && !pet.model.desktopVisible && !pet.model.companionVisible)
    #expect(pet.model.toggles.desktop && pet.model.toggles.companion)  // their own settings kept
}

// MARK: Behaviour

@MainActor @Test func aClickIsOnePlayfulReaction() {
    let pet = Pet()
    pet.enable()
    #expect(pet.model.click() && pet.model.state == .playful && pet.model.reactions == 1)
    #expect(pet.model.pendingTimers == 1)  // just the reaction: idle's timers went
    pet.clock.advance(.milliseconds(1199))
    #expect(pet.model.state == .playful)
    pet.clock.advance(.milliseconds(1))
    #expect(pet.model.state == .idle && pet.model.pendingTimers == 2)  // idle's fidget and wander back

    pet.model.click()
    pet.clock.advance(.milliseconds(600))
    pet.model.click()  // again: the reaction restarts
    #expect(pet.model.reactions == 3)
    pet.clock.advance(.milliseconds(700))
    #expect(pet.model.state == .playful)
    pet.clock.advance(.milliseconds(500))
    #expect(pet.model.state == .idle)
}

@MainActor @Test func walkingAndRunningEndInIdle() {
    let pet = Pet(desktop: true, companion: false)
    pet.enable()
    #expect(pet.model.startMoving(running: false) && pet.model.state == .walking)
    #expect(!pet.model.startMoving(running: false))  // already walking
    #expect(pet.model.startMoving(running: true) && pet.model.state == .running)
    #expect(pet.model.startMoving(running: false) && pet.model.state == .walking)
    pet.model.finishMoving()
    #expect(pet.model.state == .idle)

    pet.runs = true
    pet.clock.advance(.seconds(45))  // the pet's own wander
    #expect(pet.model.state == .running)
    pet.clock.advance(.seconds(8))  // the mover never finished: the safety limit
    #expect(pet.model.state == .idle)
    pet.runs = false
    pet.idle.input()
    pet.clock.advance(.seconds(45))
    #expect(pet.model.state == .walking)
    #expect(pet.model.fidgets == 10)  // a cue every 8 s while idle, which never delayed the wander

    let notch = Pet(desktop: false, companion: true)
    notch.enable()
    #expect(!notch.model.startMoving(running: false) && notch.model.state == .idle)  // the companion doesn't roam
    #expect(notch.model.pendingTimers == 1)  // fidget only, no wander
}

@MainActor @Test func inactivitySleepsAndActivityWakes() {
    let pet = Pet(desktop: false, companion: true)
    pet.enable()
    #expect(pet.activity.pendingTimers == 1)  // one timer, set for when 120 s would pass
    pet.clock.advance(.seconds(60))
    pet.idle.input()  // typing: a timestamp only, no event
    pet.clock.advance(.seconds(60))  // the check finds 60 s, not 120: it waits for the rest
    #expect(pet.model.state == .idle && pet.activity.pendingTimers == 1)
    pet.clock.advance(.milliseconds(59_999))
    #expect(pet.model.state == .idle)
    pet.clock.advance(.milliseconds(1))
    #expect(pet.model.state == .sleeping && pet.activity.isUserInactive)
    #expect(pet.timers == 0)  // asleep: nothing scheduled anywhere
    pet.clock.advance(.seconds(3600))
    #expect(pet.model.state == .sleeping && pet.timers == 0)

    pet.idle.input()
    pet.activity.userActivity()  // the pointer moved
    #expect(pet.model.state == .idle && pet.activity.pendingTimers == 1 && pet.model.pendingTimers == 1)

    pet.clock.advance(.seconds(120))
    #expect(pet.model.state == .sleeping)
    pet.idle.input()
    #expect(pet.model.click() && pet.model.state == .playful && !pet.activity.isUserInactive)  // a click wakes it, playfully
}

@MainActor @Test func dragStartsAndEndsOnTheDesktopOnly() {
    let pet = Pet()
    pet.enable()
    #expect(pet.model.beginDrag() && pet.model.state == .dragged && pet.model.pendingTimers == 0)
    #expect(!pet.model.click() && !pet.model.startMoving(running: true) && !pet.model.beginDrag())  // held
    pet.model.endDrag()
    #expect(pet.model.state == .idle)

    pet.model.startMoving(running: false)
    #expect(pet.model.beginDrag() && pet.model.state == .dragged)  // picked up mid-walk
    pet.model.spaceChanged()  // a drag doesn't carry over to another Space
    #expect(pet.model.state == .idle)
    pet.model.startMoving(running: true)
    pet.model.spaceChanged()
    #expect(pet.model.state == .idle)

    pet.model.beginDrag()
    pet.model.toggles.desktop = false  // turned off mid-drag: the companion carries on
    #expect(pet.model.state == .idle && !pet.model.beginDrag())  // nothing to drag at the notch
    pet.model.toggles.desktop = true
    pet.model.beginDrag()
    pet.model.toggles.pet = false
    #expect(pet.model.state == .hidden)
}

// MARK: Conditions

@MainActor @Test func displaySleepAndLockHideEverything() {
    let pet = Pet()
    pet.enable()
    pet.activity.setDisplayAsleep(true)
    #expect(pet.model.state == .hidden && pet.timers == 0)
    pet.activity.setDisplayAsleep(false)
    #expect(pet.model.state == .idle && pet.activity.pendingTimers == 1)

    pet.model.startMoving(running: false)
    pet.activity.setSessionLocked(true)
    #expect(pet.model.state == .hidden && pet.timers == 0)
    pet.clock.advance(.seconds(3600))  // locked for an hour
    #expect(pet.model.state == .hidden && pet.timers == 0)
    pet.idle.input()
    pet.activity.setSessionLocked(false)  // back: awake, not asleep
    #expect(pet.model.state == .idle && !pet.activity.isUserInactive)
}

@MainActor @Test func fullScreenAndOcclusion() {
    let pet = Pet()
    pet.enable()
    pet.activity.setFullScreen(true)  // neither experience shows over a full-screen app
    #expect(pet.model.state == .hidden && pet.timers == 0)
    pet.activity.setFullScreen(false)
    #expect(pet.model.state == .idle)

    pet.model.startMoving(running: false)
    pet.activity.setDesktopOccluded(true)  // covered by windows: it stops roaming
    #expect(pet.model.state == .idle && !pet.model.desktopVisible && pet.model.companionVisible && !pet.model.canMove)
    #expect(pet.model.pendingTimers == 1)  // the companion's fidget only
    pet.activity.setCompanionOccluded(true)
    #expect(pet.model.state == .hidden && pet.timers == 0)  // nobody can see it: nothing runs
    pet.activity.setDesktopOccluded(false)
    #expect(pet.model.state == .idle && pet.model.canMove)
}

@MainActor @Test func reduceMotionKeepsItStill() {
    let pet = Pet()
    pet.enable()
    pet.model.startMoving(running: true)
    pet.activity.setReduceMotion(true)
    #expect(pet.model.state == .idle && pet.model.pendingTimers == 0)  // no fidgets, no wander
    #expect(!pet.model.startMoving(running: false) && !pet.model.startMoving(running: true))
    pet.clock.advance(.seconds(60))
    #expect(pet.model.state == .idle && pet.model.fidgets == 0)
    #expect(pet.model.click() && pet.model.state == .playful)  // the reaction is kept, brief
    pet.clock.advance(.milliseconds(500))
    #expect(pet.model.state == .idle)
    pet.idle.input()
    pet.clock.advance(.seconds(120))
    #expect(pet.model.state == .sleeping)  // sleep still works
    pet.activity.userActivity()  // a wake event, though the idle timestamp hasn't moved yet
    #expect(pet.model.state == .idle && pet.activity.pendingTimers == 1)  // doesn't bounce back to sleep
    pet.activity.setReduceMotion(false)
    #expect(pet.model.state == .idle && pet.model.pendingTimers == 2)  // fidget and wander again
}

// MARK: Timers

@MainActor @Test func staleCallbacksAreIgnored() {
    let pet = Pet()
    pet.enable()
    let idleTimers = pet.clock.everScheduled.count
    pet.model.click()  // idle's fidget, wander and the inactivity check are now obsolete
    for action in pet.clock.everScheduled.prefix(idleTimers) { action() }
    #expect(pet.model.state == .playful && pet.model.fidgets == 0 && !pet.activity.isUserInactive)

    let reactionEnd = pet.clock.everScheduled.count - 1
    pet.clock.advance(.milliseconds(1200))
    pet.model.startMoving(running: false)
    pet.clock.everScheduled[reactionEnd]()  // the old reaction ending, late
    #expect(pet.model.state == .walking)
    pet.model.finishMoving()
    let moveLimit = pet.clock.everScheduled.count - 3
    pet.model.click()
    pet.clock.everScheduled[moveLimit]()  // the old walk's limit
    #expect(pet.model.state == .playful)
}

@MainActor @Test func shutdownLeavesNothingBehind() {
    let pet = Pet()
    pet.enable()
    pet.model.startMoving(running: false)
    pet.model.shutdown()
    #expect(pet.model.state == .hidden && pet.timers == 0)
    pet.model.toggles.companion = false
    pet.model.toggles.companion = true
    #expect(!pet.model.click() && !pet.model.startMoving(running: true) && !pet.model.beginDrag())
    pet.activity.setDisplayAsleep(true)
    pet.activity.setDisplayAsleep(false)
    pet.activity.userActivity()
    for action in pet.clock.everScheduled { action() }  // every timer ever made, late
    pet.clock.advance(.seconds(3600))
    #expect(pet.model.state == .hidden && pet.timers == 0)
    pet.model.shutdown()  // twice: harmless
}
