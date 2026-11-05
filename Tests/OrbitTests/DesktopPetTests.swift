import AppKit
import Testing
@testable import Orbit

// Stage 5.4: the Desktop Pet. Fake displays, a manual frame clock for
// movement and the manual scheduler for the model; the real window stays at
// alpha 0 (never visible) and occlusion isn't followed (a test window behind
// the editor would really be covered). No real-time waits: only yields, so
// Observation's hop to the main actor can run.

/// Frames on demand.
@MainActor
private final class FakeFrameClock: PetFrameClock {
    private var tick: (@MainActor (CFTimeInterval) -> Void)?
    var isRunning: Bool { tick != nil }
    func start(_ tick: @escaping @MainActor (CFTimeInterval) -> Void) { self.tick = tick }
    func stop() { tick = nil }
    func frame(at time: CFTimeInterval) { tick?(time) }
}

private let primary = PetDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1470, height: 956),
                                 visible: CGRect(x: 0, y: 70, width: 1470, height: 853))  // a Dock below, the menu bar above
private let external = PetDisplay(id: 2, frame: CGRect(x: 1470, y: 0, width: 1920, height: 1080),
                                  visible: CGRect(x: 1470, y: 0, width: 1920, height: 1055))

private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 0.01 && abs(a.y - b.y) < 0.01 }

@MainActor
private final class Desk {
    let temp = TemporaryDirectory()
    let scheduler = FakeScheduler()
    var idle = 0.0
    let activity: PetActivity
    let model: PetModel
    let frames = FakeFrameClock()
    var displays: [PetDisplay]
    var randoms: [Double]
    let store: JSONFile<DesktopPetPlacement>
    private(set) var pet: DesktopPet!

    /// `toggles`: set before the controller starts, as a relaunch with saved preferences does.
    init(displays: [PetDisplay] = [primary], saved: DesktopPetPlacement? = nil, randoms: [Double] = [0.5, 0.9],
         toggles: PetModel.Toggles? = nil) {
        self.displays = displays
        self.randoms = randoms
        store = temp.file("desktop-pet.json")
        if let saved { try? store.save(saved) }
        var idleSource: () -> Double = { 0 }
        activity = PetActivity(scheduler: scheduler, idleSeconds: { idleSource() })
        model = PetModel(activity: activity, scheduler: scheduler)
        idleSource = { [unowned self] in self.idle }
        model.toggles.companion = false
        if let toggles { model.toggles = toggles }
        var index = 0
        pet = DesktopPet(model: model, store: store, displays: { [unowned self] in self.displays },
                         random: { [unowned self] in
                             defer { index += 1 }
                             return self.randoms[index % self.randoms.count]
                         },
                         clock: { [frames] _ in frames }, alpha: 0, observesOcclusion: false)
        pet.start()
    }

    func enable(_ on: Bool = true) async {
        model.toggles.pet = on
        await settle()
    }

    var origin: CGPoint { pet.panel?.frame.origin ?? .zero }
    var size: CGSize { pet.panel?.frame.size ?? .zero }

    func close() {
        pet.stop()
        model.shutdown()
        temp.cleanup()
    }
}

/// Lets Observation's follow-up tasks run (no clock time passes).
@MainActor
private func settle() async {
    for _ in 0 ..< 20 { await Task.yield() }
}

// MARK: Window

@MainActor @Test func theWindowIsAQuietDesktopLevelPanel() {
    let panel = DesktopPetPanel(rig: PetRig(size: 96))
    let icons = Int(CGWindowLevelForKey(.desktopIconWindow))
    #expect(panel.level.rawValue == icons + 1)  // just above the desktop icons
    #expect(panel.level.rawValue > Int(CGWindowLevelForKey(.desktopWindow)) && panel.level < .normal)  // below every app window
    #expect(panel.collectionBehavior == [.canJoinAllSpaces, .stationary, .ignoresCycle])
    #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))  // never over a full-screen app
    #expect(panel.styleMask.contains(.borderless) && panel.styleMask.contains(.nonactivatingPanel))
    #expect(!panel.canBecomeKey && !panel.canBecomeMain)  // never takes keyboard focus
    #expect(!panel.isOpaque && panel.backgroundColor == .clear && !panel.hasShadow)
    #expect(!panel.ignoresMouseEvents)  // left at AppKit's default: clicks on transparent pixels pass through
    #expect(panel.frame.size == CGSize(width: 104, height: 96))  // the 96 pt cat, room for the hop and shadow
    #expect(panel.petView.rig.root.superlayer === panel.petView.layer)
}

@MainActor @Test func theWindowExistsOnlyWhileEnabledAndIsReused() async {
    let desk = Desk()
    defer { desk.close() }
    await settle()
    #expect(desk.pet.panel == nil)  // off by default: no window at all
    await desk.enable()
    let panel = desk.pet.panel
    #expect(panel?.isVisible == true && desk.pet.panelsCreated == 1)
    #expect(desk.model.state == .idle && !desk.pet.rig.root.isHidden)
    for _ in 0 ..< 5 {  // repeated enable/disable: one window, nothing piling up
        await desk.enable(false)
        #expect(desk.pet.panel?.isVisible == false && desk.pet.rig.root.isHidden && desk.pet.rig.animationCount == 0)
        await desk.enable()
        #expect(desk.pet.panel?.isVisible == true)
    }
    #expect(desk.pet.panelsCreated == 1 && desk.pet.panel === panel && !desk.frames.isRunning)
    desk.model.toggles.desktop = false  // the Desktop Pet alone off, the master on
    await settle()
    #expect(desk.pet.panel?.isVisible == false)
}

// MARK: Geometry

@Test func positionsAreClampedToTheVisibleDesktop() {
    let size = CGSize(width: 104, height: 96)
    let v = primary.visible
    #expect(DesktopPetGeometry.clamp(CGPoint(x: -50, y: 10), size: size, in: v) == CGPoint(x: 0, y: 70))  // not under the Dock
    #expect(DesktopPetGeometry.clamp(CGPoint(x: 2000, y: 2000), size: size, in: v) == CGPoint(x: 1366, y: 827))  // not under the menu bar
    let first = DesktopPetGeometry.origin(for: DesktopPetGeometry.defaultPlacement, size: size, on: primary)
    #expect(first.y == v.minY && first.x > v.minX && first.x < v.midX)  // on the floor, towards the left
    for x in [0.0, 0.3, 1.0] {
        let placement = DesktopPetPlacement(x: x, y: 0.25, display: 1)
        let origin = DesktopPetGeometry.origin(for: placement, size: size, on: primary)
        let back = DesktopPetGeometry.placement(for: origin, size: size, on: primary)
        #expect(abs(back.x - x) < 0.0001 && abs(back.y - 0.25) < 0.0001 && back.display == 1)  // round trip
    }
    let smaller = PetDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800), visible: CGRect(x: 0, y: 60, width: 1280, height: 715))
    let centre = DesktopPetPlacement(x: 0.5, y: 0, display: 1)
    let o = DesktopPetGeometry.origin(for: centre, size: size, on: smaller)
    #expect(abs(o.x + size.width / 2 - 640) < 0.001 && o.y == 60)  // a resolution change keeps it centred, on the floor
    let wild = DesktopPetPlacement(x: 7, y: -3, display: 9)
    #expect(DesktopPetGeometry.origin(for: wild, size: size, on: primary) == CGPoint(x: 1366, y: 70))  // a bad file can't put it off screen
}

@Test func movesFollowTheFloorAndStayOnTheDesktop() {
    let size = CGSize(width: 104, height: 96)
    let v = primary.visible
    var values = [0.5, 0.9]  // half the range, to the right
    var i = 0
    let random = { () -> Double in defer { i += 1 }; return values[i % values.count] }
    let start = CGPoint(x: 400, y: 70)
    let walk = DesktopPetGeometry.moveTarget(from: start, size: size, in: v, running: false, random: random)
    #expect(walk.y == start.y && walk.x - start.x == 165)  // 70 + 0.5 × 190, along its floor
    values = [1, 0.9]
    let nearEdge = CGPoint(x: 1300, y: 70)
    let turned = DesktopPetGeometry.moveTarget(from: nearEdge, size: size, in: v, running: true, random: random)
    #expect(turned.x < nearEdge.x && turned.x >= v.minX)  // no room to the right: it turns back
    #expect(DesktopPetGeometry.duration(from: start, to: walk, speed: DesktopPetGeometry.walkSpeed) <= DesktopPetGeometry.longestMove)
    #expect(DesktopPetGeometry.duration(from: nearEdge, to: turned, speed: DesktopPetGeometry.runSpeed) <= DesktopPetGeometry.longestMove)
    // Eased at both ends, steady in between, monotonic.
    let steps = (0 ... 20).map { DesktopPetGeometry.progress(Double($0) / 20) }
    #expect(steps.first == 0 && abs(steps.last! - 1) < 1e-9 && steps == steps.sorted())
    #expect(steps[1] < 0.05 && abs((steps[11] - steps[10]) - (steps[10] - steps[9])) < 1e-9)
}

@MainActor @Test func itLivesOnThePrimaryDisplayAndRecoversWhenOneGoes() async {
    let desk = Desk(displays: [primary, external], saved: DesktopPetPlacement(x: 0.5, y: 0, display: 2))
    defer { desk.close() }
    await desk.enable()
    #expect(primary.visible.contains(CGRect(origin: desk.origin, size: desk.size)))  // primary only in this stage
    desk.displays = [PetDisplay(id: 1, frame: CGRect(x: 0, y: 0, width: 1280, height: 800),
                                visible: CGRect(x: 0, y: 60, width: 1280, height: 715))]  // resolution change, external unplugged
    desk.pet.screensChanged()
    let now = CGRect(origin: desk.origin, size: desk.size)
    #expect(desk.displays[0].visible.contains(now) && abs(now.midX - 640) < 1)  // same relative place, still on the desktop
}

// MARK: Interaction

@MainActor @Test func aClickIsAReactionAndADragMovesAndSaves() async throws {
    let desk = Desk()
    defer { desk.close() }
    await desk.enable()
    let view = try #require(desk.pet.panel?.petView)
    let start = desk.origin
    view.press(at: CGPoint(x: 100, y: 100))
    view.drag(to: CGPoint(x: 102, y: 101))  // a wobble, not a drag
    view.release()
    await settle()
    #expect(desk.model.state == .playful && desk.model.reactions == 1 && desk.origin == start)

    desk.scheduler.advance(.milliseconds(1200))
    await settle()
    view.press(at: CGPoint(x: 100, y: 100))
    view.drag(to: CGPoint(x: 400, y: 350))
    #expect(desk.model.state == .dragged)
    #expect(near(desk.origin, CGPoint(x: start.x + 300, y: start.y + 250)))
    view.drag(to: CGPoint(x: 9000, y: -9000))  // dragged off the screen: held at the edge
    #expect(near(desk.origin, CGPoint(x: primary.visible.maxX - desk.size.width, y: primary.visible.minY)))
    view.drag(to: CGPoint(x: 300, y: 500))
    view.release()
    await settle()
    #expect(desk.model.state == .idle && desk.model.reactions == 1)  // a drag isn't a click
    let saved = try #require(try desk.store.load())
    #expect(saved == desk.pet.placement && saved.display == 1)
    #expect(near(DesktopPetGeometry.origin(for: saved, size: desk.size, on: primary), desk.origin))  // where it was let go
}

// MARK: Movement

@MainActor @Test func walkingAndRunningMoveTheWindow() async throws {
    let desk = Desk(randoms: [0.5, 0.9])
    defer { desk.close() }
    await desk.enable()
    let start = desk.origin
    desk.model.startMoving(running: false)
    await settle()
    let mover = try #require(desk.pet.mover)
    let target = try #require(mover.target)
    #expect(desk.frames.isRunning && target.x > start.x && target.y == start.y && desk.pet.rig.facing == .right)
    let duration = DesktopPetGeometry.duration(from: start, to: target, speed: DesktopPetGeometry.walkSpeed)
    desk.frames.frame(at: 100)
    desk.frames.frame(at: 100 + duration / 2)
    #expect(abs(desk.origin.x - (start.x + target.x) / 2) <= 1 && desk.origin.y == start.y)  // half way at half time (windows sit on whole points)
    desk.frames.frame(at: 100 + duration + 0.01)
    await settle()
    #expect(near(desk.origin, target) && desk.model.state == .idle && !desk.frames.isRunning)  // arrived, clock off
    #expect(try desk.store.load() == desk.pet.placement)  // remembered

    desk.randoms = [0.2, 0.1]  // a run to the left
    desk.model.startMoving(running: true)
    await settle()
    let runTarget = try #require(desk.pet.mover?.target)
    #expect(runTarget.x < target.x && desk.pet.rig.facing == .left && desk.pet.rig.state == .running)
    #expect(DesktopPetGeometry.duration(from: target, to: runTarget, speed: DesktopPetGeometry.runSpeed)
        < DesktopPetGeometry.duration(from: target, to: runTarget, speed: DesktopPetGeometry.walkSpeed))
    desk.frames.frame(at: 200)
    desk.frames.frame(at: 300)
    await settle()
    #expect(near(desk.origin, runTarget) && desk.model.state == .idle)
    #expect(primary.visible.contains(CGRect(origin: desk.origin, size: desk.size)))
}

@MainActor @Test func movementStopsCleanlyWhenAnythingIntervenes() async throws {
    let desk = Desk()
    defer { desk.close() }
    await desk.enable()
    for interruption in 0 ..< 4 {
        desk.model.startMoving(running: false)
        await settle()
        let target = try #require(desk.pet.mover?.target)
        desk.frames.frame(at: 10)
        desk.frames.frame(at: 11)
        let midway = desk.origin
        #expect(!near(midway, target))
        switch interruption {
        case 0:  // picked up
            desk.pet.panel?.petView.press(at: .zero)
            desk.pet.panel?.petView.drag(to: CGPoint(x: 30, y: 0))
        case 1: desk.activity.setFullScreen(true)  // a full-screen app
        case 2: desk.pet.spaceChanged()  // another Space
        default: await desk.enable(false)  // turned off
        }
        await settle()
        #expect(!(desk.pet.mover?.isMoving ?? true) && !desk.frames.isRunning, "interruption \(interruption)")
        desk.frames.frame(at: 99)  // a late frame from the old move
        if interruption == 0 {
            desk.pet.panel?.petView.release()
        } else {
            #expect(desk.origin == midway)  // stopped where it was
            #expect(try desk.store.load() == desk.pet.placement)
        }
        desk.activity.setFullScreen(false)
        await desk.enable()
        #expect(desk.model.state == .idle)
    }
    #expect(desk.pet.panelsCreated == 1)
}

// MARK: Spaces and full screen

@MainActor @Test func fullScreenSuppressesItAndANormalSpaceRestoresIt() async {
    let desk = Desk()
    defer { desk.close() }
    await desk.enable()
    desk.activity.setFullScreen(true)
    await settle()
    #expect(desk.model.state == .hidden && desk.pet.rig.root.isHidden && desk.pet.rig.animationCount == 0)
    #expect(desk.model.pendingTimers == 0)  // no fidgets or wander while suppressed
    #expect(!desk.model.startMoving(running: false))
    desk.activity.setFullScreen(false)
    await settle()
    #expect(desk.model.state == .idle && !desk.pet.rig.root.isHidden && desk.pet.panel?.isVisible == true)

    desk.pet.spaceChanged()  // a normal Space (the window is on it): not full screen
    await settle()
    #expect(!desk.activity.conditions.fullScreen && desk.model.state == .idle)
}

// MARK: Idle

@MainActor @Test func idleIsStillBetweenShortFidgetsAndSleepIsStill() async {
    let desk = Desk()
    defer { desk.close() }
    await desk.enable()
    let rig = desk.pet.rig
    #expect(rig.state == .idle && rig.repeatingAnimationCount == 0 && rig.animationCount == 0)  // nothing runs between cues
    rig.root.speed = 0  // the layer clock held, so a busy machine can't finish the one-shot before it's measured
    desk.scheduler.advance(.seconds(8))  // the model's fidget
    await settle()
    #expect(rig.fidgetsPlayed == 1 && rig.repeatingAnimationCount == 0)
    var longest = 0.0
    PetRig.walk(rig.root) { layer in
        for key in layer.animationKeys() ?? [] { longest = max(longest, layer.animation(forKey: key)?.duration ?? 0) }
    }
    #expect(longest > 0 && longest <= 1)  // a short burst
    rig.root.speed = 1
    desk.model.toggles.desktop = false  // the companion alone, so the wander can't interrupt
    desk.model.toggles.companion = true
    desk.idle = 120
    desk.scheduler.advance(.seconds(120))  // the user stepped away
    await settle()
    #expect(desk.model.state == .sleeping && rig.state == .sleeping && rig.repeatingAnimationCount == 0)
    let fidgets = rig.fidgetsPlayed
    desk.model.toggles.desktop = true
    desk.activity.setReduceMotion(true)
    desk.activity.userActivity()
    await settle()
    desk.scheduler.advance(.seconds(30))
    await settle()
    #expect(desk.model.state == .idle && rig.fidgetsPlayed == fidgets)  // Reduce Motion: no decorative fidgets
}

// MARK: Shutdown

@MainActor @Test func stoppingLeavesNothingBehind() async {
    let desk = Desk()
    await desk.enable()
    desk.model.startMoving(running: true)
    await settle()
    #expect(desk.frames.isRunning)
    desk.pet.stop()
    #expect(desk.pet.panel?.isVisible == false && !desk.frames.isRunning && !desk.pet.isFollowing)
    #expect(desk.pet.rig.root.isHidden && desk.pet.rig.animationCount == 0)
    desk.model.toggles.pet = false
    desk.model.toggles.pet = true
    await settle()
    #expect(desk.pet.panel?.isVisible == false)  // no longer following the model
    desk.pet.stop()  // twice: harmless
    desk.close()
}

@MainActor @Test func theOcclusionObserverIsAddedOnceAndRemovedOnStop() async {
    let scheduler = FakeScheduler()
    let model = PetModel(activity: PetActivity(scheduler: scheduler, idleSeconds: { 0 }), scheduler: scheduler)
    model.toggles.companion = false
    let pet = DesktopPet(model: model, store: nil, displays: { [primary] }, clock: { _ in FakeFrameClock() }, alpha: 0)
    pet.start()
    for on in [true, false, true, false, true] {
        model.toggles.pet = on
        await settle()
    }
    #expect(pet.observerCount == 1 && pet.panelsCreated == 1)
    pet.stop()
    #expect(pet.observerCount == 0)
    model.shutdown()
}

// MARK: Settings › Pet

/// Preferences feeding the model as `AppDelegate.apply` does.
@MainActor
private func wire(_ preferences: PreferencesModel, to desk: Desk) -> @MainActor (@escaping (inout OrbitPreferences) -> Void) async -> Void {
    preferences.onChange = { [model = desk.model] in model.toggles = $0.petToggles }
    return { change in
        preferences.update(change)
        await settle()
    }
}

@MainActor @Test func theSettingsSwitchesShowAndHideTheDesktopPetAtOnce() async {
    let desk = Desk()
    defer { desk.close() }
    let set = wire(PreferencesModel(file: nil), to: desk)
    await set { _ in }  // the defaults: master off
    #expect(desk.pet.panel == nil && desk.model.state == .hidden)
    await set { $0.orbitPet = true }
    #expect(desk.pet.panel?.isVisible == true && desk.model.state == .idle)
    await set { $0.desktopPet = false }  // the Desktop Pet alone off
    #expect(desk.pet.panel?.isVisible == false && desk.model.state == .hidden && desk.model.pendingTimers == 0)
    await set { $0.orbitPet = false }
    await set { $0.orbitPet = true }  // master back on: the Desktop Pet stays off, as chosen
    #expect(desk.pet.panel?.isVisible == false)
    await set { $0.notchCompanion = false }
    await set { $0.notchCompanion = true }  // saved, but no companion window yet: nothing runs for it
    #expect(desk.model.state == .hidden && desk.model.pendingTimers == 0 && desk.pet.panel?.isVisible == false)
    await set { $0.desktopPet = true }
    #expect(desk.pet.panel?.isVisible == true && desk.model.state == .idle)
    desk.model.startMoving(running: false)
    await settle()
    #expect(desk.frames.isRunning)
    await set { $0.orbitPet = false }  // master off mid-walk: stops cleanly
    #expect(desk.pet.panel?.isVisible == false && desk.pet.rig.root.isHidden && desk.pet.rig.animationCount == 0)
    #expect(!desk.frames.isRunning && desk.model.pendingTimers == 0 && desk.model.state == .hidden)
    await set { $0.orbitPet = true }  // and back: the Desktop Pet returns
    #expect(desk.pet.panel?.isVisible == true && desk.model.state == .idle)
}

@MainActor @Test func repeatedSwitchingKeepsOneWindowNoExtraTimersAndItsPlace() async {
    let saved = DesktopPetPlacement(x: 0.6, y: 0, display: 1)
    let desk = Desk(saved: saved)
    defer { desk.close() }
    let set = wire(PreferencesModel(file: nil), to: desk)
    await set { $0.orbitPet = true }
    let panel = desk.pet.panel
    let timers = desk.scheduler.live
    for _ in 0 ..< 5 {
        await set { $0.orbitPet = false }
        await set { $0.orbitPet = true }
        await set { $0.desktopPet = false }
        await set { $0.desktopPet = true }
        await set { $0.notchCompanion.toggle() }
    }
    #expect(desk.pet.panelsCreated == 1 && desk.pet.panel === panel && panel?.isVisible == true)
    #expect(desk.scheduler.live == timers && desk.model.pendingTimers == 2)  // one fidget and one wander, as at first
    #expect(!desk.frames.isRunning)
    let left = DesktopPetGeometry.origin(for: saved, size: desk.size, on: primary)
    #expect(abs(desk.origin.x - left.x) <= 1 && desk.origin.y == left.y)  // where it was left (windows sit on whole points)
}

@MainActor @Test func launchRestoresTheSavedPetChoice() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    PreferencesModel(file: file).update { $0.orbitPet = true }
    let desk = Desk(toggles: PreferencesModel(file: file).value.petToggles)  // the next launch
    defer { desk.close() }
    await settle()
    #expect(desk.pet.panel?.isVisible == true && desk.model.state == .idle && desk.pet.panelsCreated == 1)

    let off = Desk(toggles: OrbitPreferences().petToggles)  // a fresh install
    defer { off.close() }
    await settle()
    #expect(off.pet.panel == nil && off.model.state == .hidden)
}
