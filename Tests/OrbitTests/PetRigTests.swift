import AppKit
import QuartzCore
import Testing
@testable import Orbit

// Stage 5.3: the cat's Core Animation rig, offscreen (no window), and the
// follower that keeps it in step with PetModel on a manual clock.

@MainActor
private func keys(_ layer: CALayer) -> Set<String> { Set(layer.animationKeys() ?? []) }

@MainActor
private func allKeys(_ rig: PetRig) -> [String] {
    var keys: [String] = []
    PetRig.walk(rig.root) { keys += $0.animationKeys() ?? [] }
    return keys.sorted()
}

private let shown = PetModel.State.allCases.filter { $0 != .hidden }

@MainActor @Test func theRigIsBuiltOnceWithEveryPart() {
    let rig = PetRig()
    #expect(rig.root.isHidden && rig.state == nil && rig.animationCount == 0)  // nothing until a state arrives
    #expect(rig.legs.count == 4 && rig.eyes.count == 2 && rig.lids.count == 2 && rig.whiskers.count == 2)
    for part in [rig.body, rig.head, rig.leftEar, rig.rightEar, rig.tail, rig.accessory] + rig.legs {
        #expect(part.superlayer != nil)  // all in the tree
    }
    #expect(rig.leftEar.superlayer === rig.head && rig.rightEar.superlayer === rig.head && rig.eyes.allSatisfy { $0.superlayer === rig.head })
    #expect(rig.content.isGeometryFlipped)
    // Joints: the head turns about the neck, legs about the hip and shoulder, the body breathes from the belly.
    #expect(abs(rig.head.position.x - 82) < 0.001 && abs(rig.head.position.y - 54) < 0.001)
    #expect(rig.legs.allSatisfy { abs($0.position.y - 64) < 0.001 })
    #expect(abs(rig.body.position.y - 78) < 0.001)
    var layers = 0
    PetRig.walk(rig.root) { _ in layers += 1 }
    let identity = ObjectIdentifier(rig.body)
    for state in PetModel.State.allCases { rig.apply(state, reduceMotion: false) }
    var after = 0
    PetRig.walk(rig.root) { _ in after += 1 }
    #expect(after == layers && ObjectIdentifier(rig.body) == identity)  // reused, never rebuilt
}

@MainActor @Test func sizeFacingAndScale() {
    let rig = PetRig(size: 96)
    #expect(rig.root.bounds.size == CGSize(width: 96, height: 80))
    #expect(abs(rig.content.transform.m11 - 0.8) < 0.0001 && abs(rig.content.transform.m22 - 0.8) < 0.0001)
    rig.setSize(28)  // the notch companion's size
    #expect(rig.root.bounds.width == 28 && abs(rig.content.transform.m11 - 28.0 / 120) < 0.0001)
    rig.setSize(0)  // ignored
    #expect(rig.size == 28)
    rig.setFacing(.left)
    #expect(rig.content.transform.m11 < 0 && rig.content.transform.m22 > 0)  // mirrored, not flipped
    rig.setContentsScale(2)
    #expect(rig.lids[0].contentsScale == 2)
    #expect(rig.rasterizedParts.allSatisfy { $0.shouldRasterize && abs($0.rasterizationScale - 2 * 28.0 / 120) < 0.0001 })
    rig.setSize(240)
    #expect(rig.rasterizedParts.allSatisfy { abs($0.rasterizationScale - 2 * 240.0 / 120) < 0.0001 })  // follows the size
    rig.setContentsScale(2)
    #expect(rig.lids[0].contentsScale == 4)  // drawn larger than the design: sharper rasterisation
    #expect(rig.rasterizedParts.allSatisfy { abs($0.rasterizationScale - 2 * 240.0 / 120) < 0.0001 })  // screen × display scale, once
}

@MainActor @Test func appearanceAndMarkingsAreConfigurable() {
    var plain = PetAppearance.orbit
    plain.markings = []
    plain.proportions.tail = 1.3
    let rig = PetRig(appearance: plain)
    #expect(rig.tailTip.isHidden)
    #expect(rig.tailStroke.lineWidth == 9 * 1.3)
    let tall = rig.tailPath(TailShape(curl: 0, lift: 1)).boundingBoxOfPath
    let usual = PetRig().tailPath(TailShape(curl: 0, lift: 1)).boundingBoxOfPath
    #expect(tall.height > usual.height)  // a longer tail
    #expect(!PetRig().tailTip.isHidden)
    #expect(PetColor(red: 0.5, green: 0.5, blue: 0.5).lighter(1) == .white)
}

@MainActor @Test func eachStateHasItsPose() {
    #expect(PetRig.pose(for: .idle) == PetPose())
    #expect(PetRig.pose(for: .hidden) == PetPose())
    let sleeping = PetRig.pose(for: .sleeping)
    #expect(sleeping.eyelids == 1 && sleeping.legs < 1 && sleeping.tail.wrap == 1 && sleeping.headDrop > 0)
    #expect(PetRig.pose(for: .playful).happy && PetRig.pose(for: .playful).tail.lift == 1)
    #expect(PetRig.pose(for: .dragged).legs > 1 && PetRig.pose(for: .dragged).tail.lift < 0)
    #expect(PetRig.pose(for: .running).earsBack > PetRig.pose(for: .walking).earsBack)
    for state in shown where state != .sleeping { #expect(PetRig.pose(for: state).eyelids == 0) }

    let rig = PetRig()
    rig.apply(.sleeping, reduceMotion: false)
    #expect(abs(rig.lids[0].transform.m22 - 1) < 0.0001 && rig.closedEyes.opacity == 1 && rig.eyes[0].opacity == 0)
    rig.apply(.playful, reduceMotion: false)
    #expect(rig.happyEyes.opacity == 1 && rig.eyes[0].opacity == 0 && rig.closedEyes.opacity == 0)
    rig.apply(.dragged, reduceMotion: false)
    #expect(abs(rig.legs[0].transform.m22 - 1.12) < 0.0001 && rig.happyEyes.opacity == 0)
}

@MainActor @Test func eachStateStartsItsOwnMotion() throws {
    let rig = PetRig()
    rig.apply(.idle, reduceMotion: false)
    #expect(!rig.root.isHidden)
    #expect(rig.repeatingAnimationCount == 0)  // still between fidgets (5.4): nothing keeps the compositor busy

    rig.apply(.walking, reduceMotion: false)
    rig.apply(.walking, reduceMotion: false)
    #expect(keys(rig.tail).contains("loop.tail") && !keys(rig.tailStroke).contains("loop.tail"))  // the tail turns; its path never morphs in a loop
    #expect(rig.legs.allSatisfy { keys($0).contains("loop.stride") } && keys(rig.body).contains("loop.bob"))
    let walk = try #require(rig.legs[0].animation(forKey: "loop.stride"))
    rig.apply(.running, reduceMotion: false)
    let run = try #require(rig.legs[0].animation(forKey: "loop.stride"))
    #expect(run.duration < walk.duration)  // faster strides
    let inStep = try #require(rig.legs[3].animation(forKey: "loop.stride")).timeOffset
    let opposite = try #require(rig.legs[1].animation(forKey: "loop.stride")).timeOffset
    #expect(inStep == run.timeOffset && opposite != run.timeOffset)  // diagonal pairs, half a stride apart

    rig.apply(.sleeping, reduceMotion: false)
    #expect(rig.repeatingAnimationCount == 0)  // asleep: still
    rig.apply(.dragged, reduceMotion: false)
    #expect(rig.repeatingAnimationCount == 0)  // nothing that fights the drag
}

@MainActor @Test func clickReactionsAndFidgetsAreOneShotsInTheirOwnState() {
    let rig = PetRig()
    rig.apply(.idle, reduceMotion: false)
    rig.playReaction()  // not playful: ignored
    #expect(!keys(rig.figure).contains("react.hop"))
    rig.playFidget(1)
    #expect(keys(rig.lids[0]).contains("cue.blink") && keys(rig.leftEar).contains("cue.ear"))
    rig.playFidget(2)
    #expect(keys(rig.head).contains("cue.head"))
    rig.playFidget(3)
    #expect(keys(rig.tail).contains("cue.tail"))
    #expect(rig.lids[0].animation(forKey: "cue.blink")?.repeatCount == 0)
    for layer in [rig.lids[0], rig.leftEar, rig.head, rig.tail] {  // every fidget is done within a second
        for key in keys(layer) where key.hasPrefix("cue.") { #expect((layer.animation(forKey: key)?.duration ?? 9) <= 1) }
    }

    rig.apply(.playful, reduceMotion: false)
    #expect(!keys(rig.lids[0]).contains("cue.blink"))  // idle's cues cancelled
    rig.playReaction()
    rig.playReaction()  // a second click restarts it, never stacks
    #expect(keys(rig.figure) == ["react.hop"] && keys(rig.shadow).contains("react.shadow"))
    #expect(rig.figure.animation(forKey: "react.hop")?.isRemovedOnCompletion == true)
    rig.playFidget(4)  // not idle: ignored
    #expect(!keys(rig.lids[0]).contains("cue.blink"))
    rig.apply(.walking, reduceMotion: false)
    #expect(!keys(rig.figure).contains("react.hop"))  // a stale reaction can't carry over
}

@MainActor @Test func reduceMotionMeansStillPosesAndCrossfades() {
    let rig = PetRig()
    rig.apply(.idle, reduceMotion: true)
    #expect(rig.repeatingAnimationCount == 0 && rig.animationCount == 0)  // no breathing, no tail
    for state in shown {
        rig.apply(state, reduceMotion: true)
        #expect(rig.repeatingAnimationCount == 0)
        #expect(!allKeys(rig).contains { $0.hasPrefix(PetRig.posePrefix) })  // no eased movement between poses
    }
    #expect(keys(rig.content).contains(PetRig.fadeKey))  // a short crossfade instead
    rig.apply(.playful, reduceMotion: true)
    rig.playReaction()
    #expect(rig.happyEyes.opacity == 1 && !keys(rig.figure).contains("react.hop"))  // the face, not the hop
    rig.apply(.idle, reduceMotion: true)
    rig.playFidget(1)
    #expect(!keys(rig.lids[0]).contains("cue.blink"))
    rig.apply(.walking, reduceMotion: false)  // turned off: the motion comes back
    #expect(rig.repeatingAnimationCount > 0)
}

@MainActor @Test func hiddenStopsEverything() {
    let rig = PetRig()
    rig.apply(.running, reduceMotion: false)
    rig.playFidget(1)
    #expect(rig.animationCount > 0)
    rig.apply(.hidden, reduceMotion: false)
    #expect(rig.root.isHidden && rig.animationCount == 0)
    rig.playFidget(2)
    rig.playReaction()
    #expect(rig.animationCount == 0)  // nothing starts while hidden
    rig.apply(.walking, reduceMotion: false)
    #expect(!rig.root.isHidden && rig.animationCount > 0)
    #expect(!allKeys(rig).contains { $0.hasPrefix(PetRig.posePrefix) })  // appearing: placed, not eased in from the old pose
}

@MainActor @Test func repeatedStatesNeverRestartOrDuplicate() throws {
    let rig = PetRig()
    rig.apply(.walking, reduceMotion: false)
    let first = try #require(rig.legs[0].animation(forKey: "loop.stride")).beginTime
    let count = rig.animationCount
    rig.apply(.walking, reduceMotion: false)
    rig.apply(.walking, reduceMotion: false)
    #expect(rig.animationCount == count && rig.legs[0].animation(forKey: "loop.stride")?.beginTime == first)
    for _ in 0 ..< 50 {
        for state in PetModel.State.allCases { rig.apply(state, reduceMotion: false) }
    }
    rig.apply(.walking, reduceMotion: false)
    #expect(rig.legs.allSatisfy { keys($0).filter { $0.hasPrefix("loop.") } == ["loop.stride"] })
    #expect(rig.repeatingAnimationCount == 7)  // four legs, the body and head bob, the tail: nothing left over
}

@MainActor @Test func theCharacterFollowsTheModel() async {
    let clock = FakeScheduler()
    let activity = PetActivity(scheduler: clock, idleSeconds: { 0 })
    let model = PetModel(activity: activity, scheduler: clock)
    let rig = PetRig()
    let character = PetCharacter(model: model, rig: rig)
    character.start()
    #expect(rig.state == .hidden && rig.root.isHidden)
    model.toggles.pet = true
    #expect(await eventually { rig.state == .idle })
    model.click()
    #expect(await eventually { rig.state == .playful && rig.reactionsPlayed == 1 })
    clock.advance(.milliseconds(1200))
    #expect(await eventually { rig.state == .idle })
    clock.advance(.seconds(8))  // the model's fidget
    #expect(await eventually { rig.fidgetsPlayed == 1 })
    model.startMoving(running: true)
    #expect(await eventually { rig.state == .running })
    character.reduceMotion = true  // Orbit's setting: still poses
    #expect(rig.reduceMotion && rig.repeatingAnimationCount == 0)
    character.reduceMotion = false
    model.toggles.pet = false
    #expect(await eventually { rig.state == .hidden && rig.animationCount == 0 })

    model.toggles.pet = true
    #expect(await eventually { rig.state == .idle })
    character.stop()
    #expect(rig.root.isHidden && rig.animationCount == 0)
    model.click()  // no longer followed: nothing happens to the rig
    try? await Task.sleep(for: .milliseconds(30))
    #expect(rig.state == .hidden && !character.isFollowing && rig.reactionsPlayed == 1)
    model.shutdown()
}

@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 100 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}
