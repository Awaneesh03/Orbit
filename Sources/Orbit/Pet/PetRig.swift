import AppKit
import Observation
import QuartzCore

// Orbit Pet (Stage 5.3): the cat, drawn in code as a Core Animation layer
// rig. `PetModel` stays the source of truth: `PetCharacter` follows it and
// tells the rig which state to show; the rig only draws and animates. Every
// part is a layer whose anchor is its joint, built once and reused; all
// motion is render-server animation (no SwiftUI loops, no timers here).

// MARK: Appearance

struct PetColor: Equatable, Sendable {
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat

    func cg(_ alpha: CGFloat = 1) -> CGColor { CGColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
    /// `amount` of the way towards `other` (0…1).
    func mixed(_ amount: CGFloat, with other: PetColor) -> PetColor {
        PetColor(red: red + (other.red - red) * amount, green: green + (other.green - green) * amount,
                 blue: blue + (other.blue - blue) * amount)
    }
    func lighter(_ amount: CGFloat) -> PetColor { mixed(amount, with: .white) }
    func darker(_ amount: CGFloat) -> PetColor { mixed(amount, with: .black) }

    static let white = PetColor(red: 1, green: 1, blue: 1)
    static let black = PetColor(red: 0, green: 0, blue: 0)
}

/// What the cat looks like: everything a later photo or customization step
/// can change, with nothing about how it moves.
struct PetAppearance: Equatable, Sendable {
    /// Cat or dog: the same skeleton and motion, different head, ears, tail and eyes.
    enum Species: String, CaseIterable, Codable, Sendable {
        case cat, dog
    }

    enum Marking: String, CaseIterable, Sendable {
        case muzzle, bib, socks, tailTip
    }

    enum Accessory: String, CaseIterable, Sendable {
        case none
    }

    struct Proportions: Equatable, Sendable {
        var head: CGFloat = 1
        var ears: CGFloat = 1
        var tail: CGFloat = 1
        var legs: CGFloat = 1
    }

    var species = Species.cat
    var primary: PetColor
    var secondary: PetColor
    var eyes: PetColor
    /// Nose, inner ears, blush.
    var pink: PetColor
    var markings: Set<Marking>
    var accessory = Accessory.none
    var proportions = Proportions()

    /// Orbit's own cat: a warm ginger with cream markings and green eyes.
    static let orbit = PetAppearance(
        primary: PetColor(red: 0.95, green: 0.62, blue: 0.34), secondary: PetColor(red: 1.0, green: 0.93, blue: 0.84),
        eyes: PetColor(red: 0.40, green: 0.76, blue: 0.46), pink: PetColor(red: 1.0, green: 0.60, blue: 0.64),
        markings: Set(Marking.allCases))

    /// The coats Settings offers, by id, for each species.
    static let presets: [(id: String, name: String, appearance: PetAppearance)] = [
        ("ginger", "Ginger", .orbit),
        ("tuxedo", "Tuxedo", PetAppearance(
            primary: PetColor(red: 0.16, green: 0.16, blue: 0.18), secondary: PetColor(red: 0.96, green: 0.96, blue: 0.95),
            eyes: PetColor(red: 0.86, green: 0.74, blue: 0.30), pink: PetColor(red: 0.96, green: 0.62, blue: 0.66),
            markings: [.muzzle, .bib, .socks])),
        ("silver", "Silver Tabby", PetAppearance(
            primary: PetColor(red: 0.62, green: 0.64, blue: 0.68), secondary: PetColor(red: 0.92, green: 0.92, blue: 0.93),
            eyes: PetColor(red: 0.42, green: 0.66, blue: 0.82), pink: PetColor(red: 0.95, green: 0.64, blue: 0.68),
            markings: [.muzzle, .bib])),
        ("golden", "Golden Retriever", PetAppearance(
            species: .dog, primary: PetColor(red: 0.86, green: 0.62, blue: 0.32), secondary: PetColor(red: 0.98, green: 0.86, blue: 0.64),
            eyes: PetColor(red: 0.38, green: 0.24, blue: 0.14), pink: PetColor(red: 0.90, green: 0.50, blue: 0.52),
            markings: [.muzzle, .bib], proportions: Proportions(ears: 1, tail: 1.1, legs: 1.05))),
        ("beagle", "Beagle", PetAppearance(
            species: .dog, primary: PetColor(red: 0.62, green: 0.40, blue: 0.22), secondary: PetColor(red: 0.98, green: 0.96, blue: 0.92),
            eyes: PetColor(red: 0.30, green: 0.18, blue: 0.10), pink: PetColor(red: 0.90, green: 0.52, blue: 0.54),
            markings: [.muzzle, .bib, .socks, .tailTip])),
        ("greywhite", "Grey & White", PetAppearance(
            species: .dog, primary: PetColor(red: 0.40, green: 0.42, blue: 0.46), secondary: PetColor(red: 0.97, green: 0.97, blue: 0.98),
            eyes: PetColor(red: 0.45, green: 0.72, blue: 0.95), pink: PetColor(red: 0.90, green: 0.55, blue: 0.58),
            markings: [.muzzle, .bib, .socks, .tailTip])),
    ]

    static func preset(_ id: String) -> PetAppearance? { presets.first { $0.id == id }?.appearance }
}

// MARK: Pose

/// The tail's curve: `curl` bends the tip forward (+) or back (−), `lift`
/// raises it (−1 hanging … 1 straight up), `wrap` lays it around the paws.
struct TailShape: Equatable, Sendable {
    var curl: CGFloat
    var lift: CGFloat
    var wrap: CGFloat = 0
}

/// A static pose: where every joint rests. States move between poses and
/// add their own motion on top.
struct PetPose: Equatable, Sendable {
    var bodyScaleY: CGFloat = 1
    var bodyDrop: CGFloat = 0
    /// Radians, + towards the face (down and forward).
    var headTilt: CGFloat = 0
    var headDrop: CGFloat = 0
    /// 0 upright … 1 flat back.
    var earsBack: CGFloat = 0
    /// 0 open … 1 closed.
    var eyelids: CGFloat = 0
    /// The ^ ^ eyes.
    var happy = false
    /// 1 standing; < 1 tucked under the body; > 1 dangling.
    var legs: CGFloat = 1
    var tail = TailShape(curl: 0.3, lift: 0.6)
}

enum PetFacing: Sendable { case right, left }

// MARK: Rig

/// The cat's layer tree, in a 120 × 100 design space (y down), scaled to
/// `size` points wide. Parts drawn back to front: shadow, tail, legs (far
/// darker, near lighter), body, head (ears, face, eyes, muzzle, whiskers).
@MainActor
final class PetRig {
    static let design = CGSize(width: 120, height: 100)

    /// What a view hosts; `size` × `size` · 100/120 points.
    let root = CALayer()
    /// The design space, scaled (and mirrored when facing left).
    let content = CALayer()
    /// Everything but the shadow: what jumps.
    let figure = CALayer()
    let shadow = CAGradientLayer()
    let body = CALayer()
    let head = CALayer()
    let leftEar = CALayer()
    let rightEar = CALayer()
    let tail = CALayer()
    let tailStroke = CAShapeLayer()
    let tailTip = CAShapeLayer()
    /// Rear near, rear far, front near, front far.
    let legs: [CALayer]
    let eyes: [CALayer]
    let lids: [CAShapeLayer]
    let happyEyes = CAShapeLayer()
    let closedEyes = CAShapeLayer()
    let whiskers: [CAShapeLayer]
    let mouth = CAShapeLayer()
    /// An empty mount at the neck for later accessories (a collar).
    let accessory = CALayer()

    private(set) var appearance: PetAppearance
    private(set) var size: CGFloat
    private(set) var facing = PetFacing.right
    private(set) var state: PetModel.State?
    private(set) var reduceMotion = false
    private(set) var pose = PetPose()
    /// One-shots actually played (tests, diagnostics).
    /// A Rive character drawn in place of the vector cat (Milestone 10); nil: the vector pet.
    private(set) var skin: (any PetSkin)?
    /// The host view puts the skin's view in place (desktop window, notch companion).
    var onSkinChange: (() -> Void)?
    private(set) var fidgetsPlayed = 0
    private(set) var gesturesPlayed = 0
    private(set) var reactionsPlayed = 0
    /// What the agents are doing, tinting the resting pose (Notch Companion only; the Desktop Pet keeps none).
    private(set) var mood = AgentMood.none
    private(set) var cuesPlayed = 0

    init(appearance: PetAppearance = .orbit, size: CGFloat = 96) {
        self.appearance = appearance
        self.size = size
        legs = (0 ..< 4).map { _ in CALayer() }
        eyes = (0 ..< 2).map { _ in CALayer() }
        lids = (0 ..< 2).map { _ in CAShapeLayer() }
        whiskers = (0 ..< 2).map { _ in CAShapeLayer() }
        build()
        layOut()
        for part in rasterizedParts {
            part.shouldRasterize = true
            part.rasterizationScale = 2 * size / Self.design.width
        }
        root.isHidden = true  // nothing shown or animated until a state arrives
    }

    // MARK: Configuration

    func setSize(_ newSize: CGFloat) {
        guard newSize != size, newSize > 0 else { return }
        let screenScale = (rasterizedParts.first?.rasterizationScale ?? 2) * Self.design.width / size
        size = newSize
        layOut()
        for part in rasterizedParts { part.rasterizationScale = screenScale * size / Self.design.width }
    }

    /// Draws `newSkin` instead of the vector figure, or the vector figure again
    /// (nil). The skin gets the current state and facing at once; the rig keeps
    /// all its state, so detaching is instant and nothing is lost.
    func attach(_ newSkin: (any PetSkin)?) {
        guard newSkin !== skin else { return }
        skin?.setVisible(false)
        skin?.view.removeFromSuperview()
        skin = newSkin
        Self.quietly { content.isHidden = newSkin != nil }
        if let newSkin {
            newSkin.view.isHidden = state == nil || state == .hidden
            newSkin.setFacing(facing)
            if let state { newSkin.apply(state, reduceMotion: reduceMotion) }
        }
        onSkinChange?()
    }

    /// A new look (species, coat, a photo's colours): the parts are redrawn,
    /// the current state and pose kept. Nothing runs while it's rebuilt.
    func setAppearance(_ newAppearance: PetAppearance) {
        guard newAppearance != appearance else { return }
        appearance = newAppearance
        let parts: [CALayer] = [figure, shadow, body, head, leftEar, rightEar, tail, tailStroke, tailTip, happyEyes, closedEyes,
                                mouth, accessory] + legs + eyes + lids + whiskers
        let scale = rasterizedParts.first?.rasterizationScale ?? 2 * size / Self.design.width
        Self.quietly {
            for part in parts {
                part.removeAllAnimations()
                part.removeFromSuperlayer()
                part.sublayers = nil
                part.mask = nil
                part.transform = CATransform3DIdentity
                part.opacity = 1
            }
            for whisker in whiskers { whisker.path = nil }
            content.sublayers = nil
            build()
            layOut()
            for part in rasterizedParts {
                part.shouldRasterize = true
                part.rasterizationScale = scale
            }
        }
        let shown = state
        state = nil
        pose = PetPose()
        if let shown { apply(shown, reduceMotion: reduceMotion) }
    }

    func setFacing(_ newFacing: PetFacing) {
        guard newFacing != facing else { return }
        facing = newFacing
        layOut()
        skin?.setFacing(newFacing)
    }

    /// Sharp vector edges at the screen's scale (and when drawn larger than the design).
    func setContentsScale(_ scale: CGFloat) {
        let effective = scale * max(1, size / Self.design.width)
        Self.walk(root) { $0.contentsScale = effective }
        for part in rasterizedParts { part.rasterizationScale = scale * size / Self.design.width }  // one pixel per pixel
    }

    /// The moving parts, each drawn once into a cached bitmap: their gradients
    /// and masks would otherwise be re-rendered offscreen every frame while a
    /// parent breathes, bobs or strides (measured: that, not the motion,
    /// was the render server's cost).
    var rasterizedParts: [CALayer] { [body, head, tail] + legs }

    private func layOut() {
        let scale = size / Self.design.width
        Self.quietly {
            root.bounds = CGRect(x: 0, y: 0, width: size, height: size * Self.design.height / Self.design.width)
            content.bounds = CGRect(origin: .zero, size: Self.design)
            content.position = CGPoint(x: root.bounds.midX, y: root.bounds.midY)
            content.transform = CATransform3DMakeScale(facing == .right ? scale : -scale, scale, 1)
        }
    }

    // MARK: State

    /// Shows `state`: its pose (eased in, or a short crossfade with Reduce
    /// Motion) and its motion (none with Reduce Motion). The same state again
    /// changes nothing, so nothing restarts; hidden stops everything.
    func apply(_ newState: PetModel.State, reduceMotion newReduce: Bool) {
        guard newState != state || newReduce != reduceMotion else { return }
        let wasShown = state != nil && state != .hidden
        state = newState
        reduceMotion = newReduce
        skin?.apply(newState, reduceMotion: newReduce)
        skin?.view.isHidden = newState == .hidden  // hidden means gone, not a frozen frame
        guard newState != .hidden else {
            Self.quietly { root.isHidden = true }  // no implicit fade: hidden means nothing animating
            Self.walk(root) { $0.removeAllAnimations() }
            return
        }
        Self.walk(root) { layer in  // the old state's motion and one-shots
            for key in layer.animationKeys() ?? [] where !key.hasPrefix(Self.posePrefix) { layer.removeAnimation(forKey: key) }
        }
        Self.quietly { root.isHidden = false }
        let next = Self.pose(for: newState, mood: mood)
        let ease = wasShown && !newReduce
        if wasShown, newReduce {
            let fade = CATransition()
            fade.type = .fade
            fade.duration = 0.2
            content.add(fade, forKey: Self.fadeKey)
        }
        set(next, animated: ease)
        pose = next
        if !newReduce { addMotion(for: newState, after: ease ? Self.poseDuration : 0) }
    }

    /// A small idle cue (from `PetModel.fidgets`, every 8 s): a blink, plus
    /// an ear twitch, a head tilt or a tail flick in turn, all done within a
    /// second; still in between. Idle only; none with Reduce Motion.
    func playFidget(_ count: Int) {
        guard state == .idle, !reduceMotion else { return }
        fidgetsPlayed += 1
        skin?.perform("fidget")
        for lid in lids { oneShot(lid, "cue.blink", "transform.scale.y", [0.001, 1, 0.001], duration: 0.22, additive: false) }
        switch count % 3 {
        case 1: oneShot(leftEar, "cue.ear", "transform.rotation.z", [0, -0.28, 0.08, 0], duration: 0.4)
        case 2: oneShot(head, "cue.head", "transform.rotation.z", [0, -0.07, -0.07, 0], duration: 0.9)
        default:
            // A dog wags; a cat flicks.
            let swing: [CGFloat] = appearance.species == .dog ? [0, 0.3, -0.25, 0.3, -0.2, 0] : [0, 0.22, -0.1, 0]
            oneShot(tail, "cue.tail", "transform.rotation.z", swing, duration: appearance.species == .dog ? 0.9 : 0.7)
        }
        if count > 0, count % 4 == 0 { playGesture(count / 4) }
    }

    /// The bigger idle gestures, one every fourth fidget (about every half
    /// minute), each a single one-shot under 2.6 s: looking around, a full
    /// stretch, sitting down for a moment. Still in between, like the cues.
    func playGesture(_ index: Int) {
        guard state == .idle, !reduceMotion else { return }
        gesturesPlayed += 1
        skin?.perform(["lookAround", "stretch", "sit"][index % 3])
        switch index % 3 {
        case 0:  // look left, then right, eyes leading the head
            oneShot(head, "gesture.look", "transform.rotation.z", [0, 0.09, 0.09, -0.07, -0.07, 0], duration: 2.2,
                    keyTimes: [0, 0.18, 0.42, 0.58, 0.85, 1])
            for eye in eyes {
                oneShot(eye, "gesture.eyes", "transform.translation.x", [0, -1.2, -1.2, 1.2, 1.2, 0], duration: 2.2,
                        keyTimes: [0, 0.14, 0.42, 0.55, 0.85, 1])
            }
        case 1:  // stretch: front paws forward, body long, head low, then back
            oneShot(body, "gesture.stretch", "transform.scale.x", [1, 1.08, 1.08, 1], duration: 2, additive: false,
                    keyTimes: [0, 0.3, 0.75, 1])
            for leg in [legs[2], legs[3]] {
                oneShot(leg, "gesture.reach", "transform.rotation.z", [0, -0.42, -0.42, 0], duration: 2, keyTimes: [0, 0.3, 0.75, 1])
            }
            oneShot(head, "gesture.stretch", "transform.translation.y", [0, 5, 5, 0], duration: 2, keyTimes: [0, 0.3, 0.75, 1])
            oneShot(tail, "gesture.stretch", "transform.rotation.z", [0, -0.25, -0.25, 0], duration: 2, keyTimes: [0, 0.3, 0.75, 1])
        default:  // sit: haunches down, chest up, tail curled round
            for leg in [legs[0], legs[1]] {
                oneShot(leg, "gesture.sit", "transform.scale.y", [1, 0.5, 0.5, 1], duration: 2.5, additive: false,
                        keyTimes: [0, 0.2, 0.8, 1])
            }
            oneShot(body, "gesture.sit", "transform.rotation.z", [0, -0.16, -0.16, 0], duration: 2.5, keyTimes: [0, 0.2, 0.8, 1])
            oneShot(head, "gesture.sit", "transform.translation.y", [0, -3, -3, 0], duration: 2.5, keyTimes: [0, 0.2, 0.8, 1])
            oneShot(tail, "gesture.sit", "transform.rotation.z", [0, 0.35, 0.35, 0], duration: 2.5, keyTimes: [0, 0.2, 0.8, 1])
        }
    }

    /// The click reaction (from `PetModel.reactions`): two happy hops with a
    /// tail wag; the happy face alone with Reduce Motion. Playful only; a
    /// second click restarts it rather than stacking.
    func playReaction() {
        guard state == .playful, !reduceMotion else { return }
        reactionsPlayed += 1
        skin?.perform("click")
        let hops: [CGFloat] = [0, -13, 0, -6, 0]
        let times: [NSNumber] = [0, 0.22, 0.45, 0.62, 0.8]
        oneShot(figure, "react.hop", "transform.translation.y", hops, duration: 1.1, keyTimes: times)
        oneShot(shadow, "react.shadow", "transform.scale", [1, 0.72, 1, 0.86, 1], duration: 1.1, additive: false, keyTimes: times)
        oneShot(tail, "react.wag", "transform.rotation.z", [0, 0.3, -0.25, 0.3, -0.15, 0], duration: 1.1)
        oneShot(leftEar, "react.ear", "transform.rotation.z", [0, 0.12, 0], duration: 0.5)
        oneShot(rightEar, "react.ear", "transform.rotation.z", [0, -0.12, 0], duration: 0.5)
    }

    /// Animations on any layer of the rig (tests, diagnostics).
    var animationCount: Int {
        var count = 0
        Self.walk(root) { count += $0.animationKeys()?.count ?? 0 }
        return count
    }

    /// Repeating animations on any layer (none while hidden or with Reduce Motion).
    var repeatingAnimationCount: Int {
        var count = 0
        Self.walk(root) { layer in
            for key in layer.animationKeys() ?? [] where (layer.animation(forKey: key)?.repeatCount ?? 0) > 1 { count += 1 }
        }
        return count
    }

    /// The pose each state rests in.
    nonisolated static func pose(for state: PetModel.State) -> PetPose {
        switch state {
        case .hidden, .idle:
            PetPose()
        case .playful:
            PetPose(headTilt: -0.06, earsBack: -0.15, happy: true, tail: TailShape(curl: 0.6, lift: 1))
        case .walking:
            PetPose(headDrop: 1, tail: TailShape(curl: -0.1, lift: 0.45))
        case .running:
            PetPose(bodyScaleY: 0.96, headTilt: 0.08, headDrop: 2, earsBack: 0.35, tail: TailShape(curl: -0.6, lift: 0.1))
        case .sleeping:
            PetPose(bodyScaleY: 0.9, bodyDrop: 5, headTilt: 0.12, headDrop: 9, earsBack: 0.3, eyelids: 1, legs: 0.5,
                    tail: TailShape(curl: 0, lift: 0, wrap: 1))
        case .dragged:
            PetPose(bodyScaleY: 1.04, earsBack: 0.15, legs: 1.12, tail: TailShape(curl: 0, lift: -0.7))
        }
    }

    // MARK: Motion

    static let posePrefix = "pose."
    /// Core Animation keeps a transition under `kCATransition`, whatever key it's given.
    static let fadeKey = kCATransition
    static let poseDuration: CFTimeInterval = 0.28

    /// The state's continuous motion, all in the render server. Only a cat
    /// that is really moving animates continuously: any continuous motion
    /// keeps the compositor drawing frames (Stage 5.3: about +15 points of
    /// WindowServer CPU on a quiet screen), so idle is still between its
    /// fidget one-shots and sleep is still.
    private func addMotion(for state: PetModel.State, after delay: CFTimeInterval) {
        switch state {
        case .walking:
            stride(period: 0.72, swing: 0.34, bob: 1.1, delay: delay)
            swayTail(0.09, duration: 0.72, delay: delay)
        case .running:
            stride(period: 0.36, swing: 0.62, bob: 1.8, delay: delay)
            swayTail(0.06, duration: 0.36, delay: delay)
        case .idle, .sleeping, .playful, .dragged, .hidden:
            break  // idle: fidgets; playful: the reaction; dragged: still, so nothing fights the drag
        }
    }

    /// Diagonal pairs in step (near rear with far front), the body and head
    /// bobbing twice a stride.
    private func stride(period: CFTimeInterval, swing: CGFloat, bob: CGFloat, delay: CFTimeInterval) {
        let half = period / 2
        for (index, leg) in legs.enumerated() {
            let inStep = index == 0 || index == 3
            loop(leg, "stride", "transform.rotation.z", [-swing, swing], duration: half, delay: delay, phase: inStep ? 0 : half)
        }
        loop(body, "bob", "transform.translation.y", [0, -bob], duration: period / 4, delay: delay)
        loop(head, "bob", "transform.translation.y", [0, -bob * 0.8], duration: period / 4, delay: delay, phase: period / 16)
    }

    /// The tail sways by turning about its root: compositing only. (Morphing
    /// its path every frame made the render server redraw it each time; the
    /// path changes only between poses.)
    private func swayTail(_ angle: CGFloat, duration: CFTimeInterval, delay: CFTimeInterval) {
        loop(tail, "tail", "transform.rotation.z", [-angle, angle], duration: duration, delay: delay)
    }

    private func loop(_ layer: CALayer, _ name: String, _ keyPath: String, _ values: [Any], duration: CFTimeInterval,
                      additive: Bool = true, delay: CFTimeInterval, phase: CFTimeInterval = 0) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.duration = duration
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.isAdditive = additive
        animation.calculationMode = .cubic
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        animation.beginTime = CACurrentMediaTime() + delay
        animation.timeOffset = phase
        animation.fillMode = .backwards
        layer.add(animation, forKey: "loop." + name)
    }

    private func oneShot(_ layer: CALayer, _ key: String, _ keyPath: String, _ values: [Any], duration: CFTimeInterval,
                         additive: Bool = true, keyTimes: [NSNumber]? = nil) {
        let animation = CAKeyframeAnimation(keyPath: keyPath)
        animation.values = values
        animation.keyTimes = keyTimes
        animation.duration = duration
        animation.isAdditive = additive
        animation.calculationMode = .cubic
        animation.isRemovedOnCompletion = true
        layer.add(animation, forKey: key)  // the same key again replaces it: never stacked
    }

    // MARK: Pose application

    private func set(_ pose: PetPose, animated: Bool) {
        let p = appearance.proportions
        transform(body, CATransform3DScale(CATransform3DMakeTranslation(0, pose.bodyDrop, 0), 1, pose.bodyScaleY, 1), animated)
        var headTransform = CATransform3DMakeTranslation(0, pose.headDrop, 0)
        headTransform = CATransform3DRotate(headTransform, pose.headTilt, 0, 0, 1)
        transform(head, CATransform3DScale(headTransform, p.head, p.head, 1), animated)
        let ear = 0.55 * pose.earsBack
        transform(leftEar, CATransform3DScale(CATransform3DMakeRotation(-ear, 0, 0, 1), p.ears, p.ears, 1), animated)
        transform(rightEar, CATransform3DScale(CATransform3DMakeRotation(ear, 0, 0, 1), p.ears, p.ears, 1), animated)
        for leg in legs { transform(leg, CATransform3DMakeScale(1, pose.legs * p.legs, 1), animated) }
        for lid in lids { transform(lid, CATransform3DMakeScale(1, max(0.001, pose.eyelids), 1), animated) }
        let open: Float = pose.happy || pose.eyelids > 0.5 ? 0 : 1  // closed: just the lines, no lid outline
        for eye in eyes { fade(eye, open, animated) }
        fade(happyEyes, pose.happy ? 1 : 0, animated)
        fade(closedEyes, !pose.happy && pose.eyelids > 0.5 ? 1 : 0, animated)
        let path = tailPath(pose.tail)
        for stroke in [tailStroke, tailTip] { shape(stroke, path, animated) }
    }

    private func transform(_ layer: CALayer, _ value: CATransform3D, _ animated: Bool) {
        let from = layer.transform
        Self.quietly { layer.transform = value }
        guard animated, !CATransform3DEqualToTransform(from, value) else { return }
        ease(layer, "transform", from: NSValue(caTransform3D: from), to: NSValue(caTransform3D: value))
    }

    private func fade(_ layer: CALayer, _ opacity: Float, _ animated: Bool) {
        let from = layer.opacity
        Self.quietly { layer.opacity = opacity }
        guard animated, from != opacity else { return }
        ease(layer, "opacity", from: from, to: opacity)
    }

    private func shape(_ layer: CAShapeLayer, _ path: CGPath, _ animated: Bool) {
        let from = layer.path
        Self.quietly { layer.path = path }
        guard animated, let from, from != path else { return }
        ease(layer, "path", from: from, to: path)
    }

    private func ease(_ layer: CALayer, _ keyPath: String, from: Any, to: Any) {
        let animation = CABasicAnimation(keyPath: keyPath)
        animation.fromValue = from
        animation.toValue = to
        animation.duration = Self.poseDuration
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        layer.add(animation, forKey: Self.posePrefix + keyPath)
    }

    // MARK: Construction

    /// The tail as one cubic from its root, so every shape morphs into every other.
    func tailPath(_ shape: TailShape) -> CGPath {
        let t = appearance.proportions.tail
        let base = CGPoint(x: 26, y: 58)
        func lerp(_ a: CGPoint, _ b: CGPoint, _ f: CGFloat) -> CGPoint { CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f) }
        func scaled(_ p: CGPoint) -> CGPoint { CGPoint(x: base.x + (p.x - base.x) * t, y: base.y + (p.y - base.y) * t) }
        let lift = shape.lift, curl = shape.curl
        var c1 = CGPoint(x: 12, y: 60 - 4 * lift)
        var c2 = CGPoint(x: 5 + 5 * curl, y: 42 - 16 * lift)
        var tip = CGPoint(x: 13 + 13 * curl, y: 32 - 20 * lift)
        if lift < 0 {  // hanging down
            c1 = CGPoint(x: 14, y: 60)
            c2 = CGPoint(x: 8, y: 62 - 8 * lift)
            tip = CGPoint(x: 12 + 6 * curl, y: 66 - 22 * lift)
        }
        if shape.wrap > 0 {  // around the paws
            c1 = lerp(c1, CGPoint(x: 18, y: 84), shape.wrap)
            c2 = lerp(c2, CGPoint(x: 52, y: 92), shape.wrap)
            tip = lerp(tip, CGPoint(x: 86, y: 87), shape.wrap)
        }
        let path = CGMutablePath()
        path.move(to: base)
        path.addCurve(to: scaled(tip), control1: scaled(c1), control2: scaled(c2))
        return path
    }

    private func build() {
        let a = appearance
        let coat = a.primary, cream = a.secondary
        let edge = coat.darker(0.32).cg(0.55)
        content.isGeometryFlipped = true  // design coordinates: y down
        root.addSublayer(content)

        // Shadow on the ground.
        shadow.type = .radial
        shadow.colors = [PetColor.black.cg(0.24), PetColor.black.cg(0)]
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 1)
        shadow.frame = CGRect(x: 22, y: 85, width: 74, height: 12)
        content.addSublayer(shadow)
        figure.frame = CGRect(origin: .zero, size: Self.design)
        content.addSublayer(figure)

        // Tail.
        joint(tail, frame: CGRect(origin: .zero, size: Self.design), pivot: CGPoint(x: 26, y: 58), in: figure)
        for (layer, color) in [(tailStroke, coat), (tailTip, cream)] {
            layer.frame = tail.bounds
            layer.fillColor = nil
            layer.strokeColor = color.cg()
            layer.lineWidth = (a.species == .dog ? 10.5 : 9) * a.proportions.tail
            layer.lineCap = .round
            tail.addSublayer(layer)
        }
        tailTip.strokeStart = 0.78
        tailTip.isHidden = !a.markings.contains(.tailTip)

        // Legs: far ones (index 1, 3) a shade darker, all behind the body.
        let pivots = [CGPoint(x: 35, y: 64), CGPoint(x: 44, y: 64), CGPoint(x: 70, y: 64), CGPoint(x: 79, y: 64)]
        for index in [1, 3, 0, 2] {
            let leg = legs[index]
            let far = index == 1 || index == 3
            let pivot = pivots[index]
            joint(leg, frame: CGRect(x: pivot.x - 6.5, y: pivot.y - 2, width: 13, height: 30), pivot: pivot, in: figure)
            let tone = far ? coat.darker(0.16) : coat
            fill(CGPath(roundedRect: CGRect(x: 1.5, y: 0, width: 10, height: 26), cornerWidth: 5, cornerHeight: 5, transform: nil),
                 [tone.lighter(0.06), tone.darker(0.08)], in: leg, edge: edge)
            let pawTone = a.markings.contains(.socks) ? (far ? cream.darker(0.1) : cream) : tone
            fill(CGPath(ellipseIn: CGRect(x: 0.5, y: 22.5, width: 12.5, height: 7.5), transform: nil), [pawTone.lighter(0.05), pawTone.darker(0.04)],
                 in: leg, edge: edge)
        }

        // Body.
        // A rounded rump, a slight dip along the back, a deep chest, a soft belly.
        joint(body, frame: CGRect(x: 18, y: 38, width: 74, height: 44), pivot: CGPoint(x: 54, y: 78), in: figure)
        let bodyPath = CGMutablePath()
        bodyPath.move(to: CGPoint(x: 30, y: 49))
        bodyPath.addCurve(to: CGPoint(x: 72, y: 46), control1: CGPoint(x: 42, y: 42), control2: CGPoint(x: 58, y: 45))
        bodyPath.addCurve(to: CGPoint(x: 86, y: 63), control1: CGPoint(x: 82, y: 47), control2: CGPoint(x: 87, y: 55))
        bodyPath.addCurve(to: CGPoint(x: 76, y: 77), control1: CGPoint(x: 85, y: 71), control2: CGPoint(x: 82, y: 77))
        bodyPath.addCurve(to: CGPoint(x: 34, y: 77), control1: CGPoint(x: 60, y: 79.5), control2: CGPoint(x: 46, y: 79.5))
        bodyPath.addCurve(to: CGPoint(x: 21, y: 61), control1: CGPoint(x: 25, y: 76), control2: CGPoint(x: 21, y: 69))
        bodyPath.addCurve(to: CGPoint(x: 30, y: 49), control1: CGPoint(x: 21, y: 55), control2: CGPoint(x: 24, y: 50))
        bodyPath.closeSubpath()
        fill(local(bodyPath, in: body), [coat.lighter(0.14), coat, coat.darker(0.12)], in: body, edge: edge)
        if a.markings.contains(.bib) {
            fill(local(CGPath(ellipseIn: CGRect(x: 72, y: 50, width: 14, height: 22), transform: nil), in: body),
                 [cream, cream.darker(0.05)], in: body)  // the chest, under the chin
        }
        fill(local(CGPath(ellipseIn: CGRect(x: 37, y: 45.5, width: 30, height: 6), transform: nil), in: body),
             [PetColor.white, PetColor.white], alphas: [0.2, 0], in: body)  // a soft highlight along the back

        // Head, around the neck.
        joint(head, frame: CGRect(x: 64, y: 4, width: 54, height: 58), pivot: CGPoint(x: 82, y: 54), in: figure)
        joint(accessory, frame: CGRect(x: 72, y: 48, width: 22, height: 10), pivot: CGPoint(x: 83, y: 53), in: head)
        for (ear, mirror) in [(leftEar, false), (rightEar, true)] {
            if a.species == .dog {
                continue  // floppy ears hang in front of the head: added after it
            } else {
                let pivot = mirror ? CGPoint(x: 103, y: 25) : CGPoint(x: 79, y: 25)
                joint(ear, frame: CGRect(x: pivot.x - 11, y: pivot.y - 21, width: 22, height: 24), pivot: pivot, in: head)
                fill(local(earPath(mirror: mirror, inset: 0), in: ear), [coat.lighter(0.1), coat], in: ear, edge: edge)
                fill(local(earPath(mirror: mirror, inset: 3.6), in: ear), [a.pink.lighter(0.1), a.pink.darker(0.05)], in: ear)
            }
        }
        let headPath = CGMutablePath()
        headPath.move(to: CGPoint(x: 91, y: 17))
        headPath.addCurve(to: CGPoint(x: 113, y: 39), control1: CGPoint(x: 104, y: 17), control2: CGPoint(x: 113, y: 26))
        headPath.addCurve(to: CGPoint(x: 91, y: 57), control1: CGPoint(x: 113, y: 51), control2: CGPoint(x: 103, y: 57))
        headPath.addCurve(to: CGPoint(x: 69, y: 39), control1: CGPoint(x: 79, y: 57), control2: CGPoint(x: 69, y: 51))
        headPath.addCurve(to: CGPoint(x: 91, y: 17), control1: CGPoint(x: 69, y: 26), control2: CGPoint(x: 78, y: 17))
        headPath.closeSubpath()
        if a.species == .cat {  // cheek ruffs: the head's silhouette reads as fur, not a ball
            let ruff = CGMutablePath()
            for mirror in [false, true] {
                func m(_ p: CGPoint) -> CGPoint { mirror ? CGPoint(x: 182 - p.x, y: p.y) : p }
                ruff.move(to: m(CGPoint(x: 71, y: 40)))
                ruff.addLine(to: m(CGPoint(x: 66.5, y: 45)))
                ruff.addLine(to: m(CGPoint(x: 71.5, y: 46)))
                ruff.addLine(to: m(CGPoint(x: 68, y: 51)))
                ruff.addLine(to: m(CGPoint(x: 75, y: 51)))
                ruff.closeSubpath()
            }
            fill(local(ruff, in: head), [coat, coat.darker(0.06)], in: head)
        }
        fill(local(headPath, in: head), [coat.lighter(0.16), coat, coat.darker(0.06)], in: head, edge: edge)
        if a.species == .dog {  // the snout, forward and a little down, with its own soft shading
            fill(local(CGPath(roundedRect: CGRect(x: 81, y: 37, width: 24, height: 17), cornerWidth: 8.5, cornerHeight: 8.5, transform: nil), in: head),
                 [cream.lighter(0.04), cream.darker(0.1)], in: head, edge: edge)
            for (ear, mirror) in [(leftEar, false), (rightEar, true)] {  // floppy, hung from the crown, pivoting at the root
                let pivot = mirror ? CGPoint(x: 105, y: 22) : CGPoint(x: 77, y: 22)
                joint(ear, frame: CGRect(x: pivot.x - 12, y: pivot.y - 4, width: 24, height: 30), pivot: pivot, in: head)
                fill(local(dogEarPath(mirror: mirror), in: ear), [coat.darker(0.06), coat.darker(0.24)], in: ear, edge: edge)
            }
        }
        fill(local(CGPath(ellipseIn: CGRect(x: 80, y: 19, width: 22, height: 6), transform: nil), in: head),
             [PetColor.white, PetColor.white], alphas: [0.24, 0], in: head)
        if a.markings.contains(.muzzle), a.species == .cat {
            fill(local(CGPath(ellipseIn: CGRect(x: 81.5, y: 40, width: 19, height: 14), transform: nil), in: head),
                 [cream, cream.darker(0.04)], in: head)
        }
        for x: CGFloat in [74.5, 100.5] where a.species == .cat {  // blush
            fill(local(CGPath(ellipseIn: CGRect(x: x, y: 42, width: 7, height: 4), transform: nil), in: head),
                 [a.pink, a.pink], alphas: [0.5, 0.5], in: head)
        }

        // Eyes: iris, pupil, two highlights, and a lid that closes from the top.
        let lidColor = coat.lighter(0.1)
        for (index, center) in [CGPoint(x: 83, y: 34.5), CGPoint(x: 99, y: 34.5)].enumerated() {
            let eye = eyes[index]
            let frame = CGRect(x: center.x - 4.6, y: center.y - 5.6, width: 9.2, height: 11.2)
            eye.frame = local(frame, in: head)
            let bounds = CGRect(origin: .zero, size: frame.size)
            let mask = CAShapeLayer()
            mask.path = CGPath(ellipseIn: bounds, transform: nil)
            eye.mask = mask
            let iris = CAGradientLayer()
            iris.type = .radial
            iris.frame = bounds
            iris.colors = [a.eyes.lighter(0.35).cg(), a.eyes.cg(), a.eyes.darker(0.35).cg()]
            iris.startPoint = CGPoint(x: 0.5, y: 0.62)
            iris.endPoint = CGPoint(x: 1.05, y: 1.1)
            eye.addSublayer(iris)
            let pupil = CAShapeLayer()
            pupil.path = a.species == .dog
                ? CGPath(ellipseIn: CGRect(x: 1.9, y: 2.9, width: 5.4, height: 5.4), transform: nil)  // round
                : CGPath(ellipseIn: CGRect(x: 2.6, y: 1.6, width: 4, height: 8.2), transform: nil)  // a cat's slit
            pupil.fillColor = PetColor(red: 0.12, green: 0.1, blue: 0.12).cg()
            eye.addSublayer(pupil)
            for (spot, radius) in [(CGPoint(x: 5.8, y: 3.2), CGFloat(1.5)), (CGPoint(x: 3.2, y: 7.6), CGFloat(0.75))] {
                let shine = CAShapeLayer()
                shine.path = CGPath(ellipseIn: CGRect(x: spot.x - radius, y: spot.y - radius, width: radius * 2, height: radius * 2),
                                    transform: nil)
                shine.fillColor = PetColor.white.cg(0.95)
                eye.addSublayer(shine)
            }
            let lid = lids[index]
            lid.bounds = bounds
            lid.anchorPoint = CGPoint(x: 0.5, y: 0)
            lid.position = CGPoint(x: bounds.midX, y: 0)
            lid.path = CGPath(rect: bounds, transform: nil)
            lid.fillColor = lidColor.cg()
            eye.addSublayer(lid)
            head.addSublayer(eye)
        }
        let face = PetColor(red: 0.2, green: 0.14, blue: 0.14)
        for (layer, path) in [(happyEyes, happyEyesPath()), (closedEyes, closedEyesPath())] {
            layer.frame = head.bounds
            layer.path = local(path, in: head)
            layer.fillColor = nil
            layer.strokeColor = face.cg(0.9)
            layer.lineWidth = 1.4
            layer.lineCap = .round
            layer.opacity = 0
            head.addSublayer(layer)
        }

        // Nose, mouth, whiskers.
        let nose = CGMutablePath()
        nose.move(to: CGPoint(x: 88.6, y: 42))
        nose.addQuadCurve(to: CGPoint(x: 93.4, y: 42), control: CGPoint(x: 91, y: 40.8))
        nose.addQuadCurve(to: CGPoint(x: 91, y: 44.8), control: CGPoint(x: 93.2, y: 43.6))
        nose.addQuadCurve(to: CGPoint(x: 88.6, y: 42), control: CGPoint(x: 88.8, y: 43.6))
        nose.closeSubpath()
        if a.species == .dog {
            fill(local(CGPath(roundedRect: CGRect(x: 96.5, y: 38.5, width: 9, height: 6.5), cornerWidth: 3, cornerHeight: 3, transform: nil), in: head),
                 [PetColor(red: 0.24, green: 0.2, blue: 0.2), PetColor(red: 0.08, green: 0.07, blue: 0.08)], in: head)
        } else {
            fill(local(nose, in: head), [a.pink.lighter(0.15), a.pink.darker(0.1)], in: head)
        }
        let mouthPath = CGMutablePath()
        if a.species == .dog {  // under the snout's nose: a short line and a soft smile
            mouthPath.move(to: CGPoint(x: 101, y: 45))
            mouthPath.addLine(to: CGPoint(x: 101, y: 47.5))
            mouthPath.move(to: CGPoint(x: 94, y: 48.5))
            mouthPath.addQuadCurve(to: CGPoint(x: 101, y: 47.5), control: CGPoint(x: 97.5, y: 51))
            mouthPath.addQuadCurve(to: CGPoint(x: 105, y: 48), control: CGPoint(x: 103.5, y: 50.5))
        } else {
            mouthPath.move(to: CGPoint(x: 91, y: 44.8))
            mouthPath.addLine(to: CGPoint(x: 91, y: 46.2))
            mouthPath.move(to: CGPoint(x: 87.8, y: 46.4))
            mouthPath.addQuadCurve(to: CGPoint(x: 91, y: 46.2), control: CGPoint(x: 89.4, y: 48.2))
            mouthPath.addQuadCurve(to: CGPoint(x: 94.2, y: 46.4), control: CGPoint(x: 92.6, y: 48.2))
        }
        mouth.frame = head.bounds
        mouth.path = local(mouthPath, in: head)
        mouth.fillColor = nil
        mouth.strokeColor = face.cg(0.75)
        mouth.lineWidth = 0.9
        mouth.lineCap = .round
        mouth.lineJoin = .round
        head.addSublayer(mouth)
        for (index, mirror) in [false, true].enumerated() where a.species == .cat {
            let whisker = whiskers[index]
            let pivot = CGPoint(x: mirror ? 99 : 83, y: 45)
            let origin = origin(of: head)
            whisker.bounds = head.bounds
            whisker.anchorPoint = CGPoint(x: (pivot.x - origin.x) / head.bounds.width, y: (pivot.y - origin.y) / head.bounds.height)
            whisker.position = local(pivot, in: head)
            let lines = CGMutablePath()
            for (dy, end) in [(-1.6, CGPoint(x: 68, y: 41)), (0.4, CGPoint(x: 67, y: 45.5)), (2.4, CGPoint(x: 69, y: 50))] {
                let start = CGPoint(x: 82, y: 45 + dy)
                lines.move(to: mirror ? CGPoint(x: 182 - start.x, y: start.y) : start)
                lines.addLine(to: mirror ? CGPoint(x: 182 - end.x, y: end.y) : end)
            }
            whisker.path = local(lines, in: head)
            whisker.fillColor = nil
            whisker.strokeColor = PetColor.white.cg(0.85)
            whisker.lineWidth = 0.55
            whisker.lineCap = .round
            head.addSublayer(whisker)
        }
    }

    private func earPath(mirror: Bool, inset: CGFloat) -> CGPath {
        // The left ear; the right one mirrored about the face's centre (x = 91).
        let base1 = CGPoint(x: 70 + inset * 1.2, y: 30 - inset * 0.4)
        let tip = CGPoint(x: 74.5 + inset * 0.35, y: 6.5 + inset * 1.5)
        let base2 = CGPoint(x: 89 - inset * 1.1, y: 23.5 + inset * 0.2)
        let path = CGMutablePath()
        func m(_ p: CGPoint) -> CGPoint { mirror ? CGPoint(x: 182 - p.x, y: p.y) : p }
        path.move(to: m(base1))
        path.addQuadCurve(to: m(tip), control: m(CGPoint(x: 70.2 + inset, y: 14)))
        path.addQuadCurve(to: m(base2), control: m(CGPoint(x: 82 - inset * 0.4, y: 11 + inset)))
        path.closeSubpath()
        return path
    }

    /// A dog's soft ear, hanging from its root beside the crown.
    private func dogEarPath(mirror: Bool) -> CGPath {
        func m(_ p: CGPoint) -> CGPoint { mirror ? CGPoint(x: 182 - p.x, y: p.y) : p }
        let path = CGMutablePath()
        path.move(to: m(CGPoint(x: 71, y: 20)))
        path.addCurve(to: m(CGPoint(x: 70, y: 46)), control1: m(CGPoint(x: 64, y: 26)), control2: m(CGPoint(x: 63, y: 42)))
        path.addCurve(to: m(CGPoint(x: 81, y: 40)), control1: m(CGPoint(x: 75, y: 50)), control2: m(CGPoint(x: 81, y: 46)))
        path.addCurve(to: m(CGPoint(x: 71, y: 20)), control1: m(CGPoint(x: 82, y: 30)), control2: m(CGPoint(x: 78, y: 21)))
        path.closeSubpath()
        return path
    }

    private func happyEyesPath() -> CGPath {
        let path = CGMutablePath()
        for x: CGFloat in [83, 99] {
            path.move(to: CGPoint(x: x - 3.6, y: 36))
            path.addQuadCurve(to: CGPoint(x: x + 3.6, y: 36), control: CGPoint(x: x, y: 29.5))
        }
        return path
    }

    private func closedEyesPath() -> CGPath {
        let path = CGMutablePath()
        for x: CGFloat in [83, 99] {
            path.move(to: CGPoint(x: x - 3.8, y: 35))
            path.addQuadCurve(to: CGPoint(x: x + 3.8, y: 35), control: CGPoint(x: x, y: 39))
        }
        return path
    }

    // MARK: Helpers

    private static let originKey = "orbit.origin"

    /// A part whose anchor is its joint: `frame` in design coordinates,
    /// rotating and scaling about `pivot` (also in design coordinates).
    private func joint(_ layer: CALayer, frame: CGRect, pivot: CGPoint, in parent: CALayer) {
        layer.bounds = CGRect(origin: .zero, size: frame.size)
        layer.anchorPoint = CGPoint(x: (pivot.x - frame.minX) / frame.width, y: (pivot.y - frame.minY) / frame.height)
        layer.position = local(pivot, in: parent)
        layer.setValue(NSValue(point: frame.origin), forKey: Self.originKey)
        parent.addSublayer(layer)
    }

    /// Where a part's own coordinates start, in design coordinates (the figure's are the design's).
    private func origin(of layer: CALayer) -> CGPoint {
        (layer.value(forKey: Self.originKey) as? NSValue)?.pointValue ?? .zero
    }

    private func local(_ point: CGPoint, in layer: CALayer) -> CGPoint {
        let o = origin(of: layer)
        return CGPoint(x: point.x - o.x, y: point.y - o.y)
    }

    private func local(_ rect: CGRect, in layer: CALayer) -> CGRect {
        CGRect(origin: local(rect.origin, in: layer), size: rect.size)
    }

    private func local(_ path: CGPath, in layer: CALayer) -> CGPath {
        let o = origin(of: layer)
        var shift = CGAffineTransform(translationX: -o.x, y: -o.y)
        return path.copy(using: &shift) ?? path
    }

    /// A shape (in `parent`'s coordinates) filled with a top-to-bottom
    /// gradient, with an optional edge line for contrast on any wallpaper.
    private func fill(_ path: CGPath, _ colors: [PetColor], alphas: [CGFloat]? = nil, in parent: CALayer, edge: CGColor? = nil) {
        let box = path.boundingBoxOfPath.insetBy(dx: -1, dy: -1)
        let gradient = CAGradientLayer()
        gradient.frame = box
        gradient.colors = colors.enumerated().map { index, color in color.cg(alphas.map { $0[min(index, $0.count - 1)] } ?? 1) }
        gradient.startPoint = CGPoint(x: 0.5, y: 0)
        gradient.endPoint = CGPoint(x: 0.5, y: 1)
        let mask = CAShapeLayer()
        var shift = CGAffineTransform(translationX: -box.minX, y: -box.minY)
        mask.path = path.copy(using: &shift)
        gradient.mask = mask
        parent.addSublayer(gradient)
        guard let edge else { return }
        let outline = CAShapeLayer()
        outline.frame = parent.bounds
        outline.path = path
        outline.fillColor = nil
        outline.strokeColor = edge
        outline.lineWidth = 0.7
        parent.addSublayer(outline)
    }

    static func quietly(_ work: () -> Void) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        work()
        CATransaction.commit()
    }

    static func walk(_ layer: CALayer, _ visit: (CALayer) -> Void) {
        visit(layer)
        if let mask = layer.mask { walk(mask, visit) }
        for sublayer in layer.sublayers ?? [] { walk(sublayer, visit) }
    }
}

// MARK: Hosting

/// An NSView that hosts a rig at the screen's scale.
final class PetRigView: NSView {
    let rig: PetRig

    init(rig: PetRig) {
        self.rig = rig
        super.init(frame: CGRect(origin: .zero, size: rig.root.bounds.size))
        wantsLayer = true
        layer?.addSublayer(rig.root)
        rig.onSkinChange = { [weak self] in self?.installSkin() }
        installSkin()
    }

    /// The Rive character's view over the rig's place (or none).
    func installSkin() {
        guard let view = rig.skin?.view else { return }
        if view.superview !== self { addSubview(view) }
        view.frame = rig.root.frame
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override var intrinsicContentSize: NSSize { rig.root.bounds.size }

    /// The character's view only draws: clicks land where they did before it existed.
    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === rig.skin?.view ? self : hit
    }

    override func layout() {
        super.layout()
        PetRig.quietly { rig.root.position = CGPoint(x: bounds.midX, y: bounds.midY) }
        rig.skin?.view.frame = rig.root.frame
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rig.setContentsScale(window?.backingScaleFactor ?? 2)
    }
}

// MARK: Following the model

/// Keeps a rig in step with a `PetModel`: its state, one fidget cue per new
/// `fidgets`, one reaction per new `reactions`. The model stays the only
/// state machine. `reduceMotion` is Orbit's setting or the system's, set by
/// the owner (combined with the model's own condition).
@MainActor
final class PetCharacter {
    let model: PetModel
    let rig: PetRig
    var reduceMotion = false {
        didSet { if reduceMotion != oldValue { sync() } }
    }
    private var following = false
    private var generation = 0
    private var fidgets = 0
    private var reactions = 0

    init(model: PetModel, rig: PetRig) {
        self.model = model
        self.rig = rig
    }

    var isFollowing: Bool { following }

    func start() {
        guard !following else { return }
        following = true
        generation += 1
        fidgets = model.fidgets
        reactions = model.reactions
        follow(generation)
    }

    /// Stops following and hides the rig: nothing left animating.
    func stop() {
        guard following else { return }
        following = false
        generation += 1
        rig.apply(.hidden, reduceMotion: rig.reduceMotion)
    }

    private func follow(_ registered: Int) {
        guard following, registered == generation else { return }
        withObservationTracking {
            _ = (model.state, model.fidgets, model.reactions)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(registered) }
        }
        sync()
    }

    private func sync() {
        guard following else { return }
        rig.apply(model.state, reduceMotion: reduceMotion || model.reduceMotion)
        if model.reactions != reactions {
            reactions = model.reactions
            rig.playReaction()
        }
        if model.fidgets != fidgets {
            fidgets = model.fidgets
            rig.playFidget(fidgets)
        }
    }
}

// MARK: Agent reactions (Notch Companion, docs/AI_HUB_SPEC.md §22)

extension PetRig {
    /// The resting pose, tinted by the agents' mood. Idle only: walking,
    /// sleeping or a click reaction keep their own pose. All static — a mood
    /// never adds continuous motion.
    nonisolated static func pose(for state: PetModel.State, mood: AgentMood) -> PetPose {
        var pose = pose(for: state)
        guard state == .idle else { return pose }
        switch mood {
        case .none: break
        case .working: pose.headDrop = 1.5; pose.eyelids = 0.18  // focused
        case .needsYou: pose.headTilt = -0.1; pose.earsBack = -0.25  // perked up, looking your way
        case .failed: pose.headDrop = 2; pose.earsBack = 0.45; pose.eyelids = 0.35  // a little down
        }
        return pose
    }

    /// Eases into the mood's pose (at once with Reduce Motion).
    /// Agent cues as character actions: working, attention, a happy finish, a concerned failure.
    nonisolated static func skinAction(for cue: AgentCue) -> String {
        switch cue {
        case .activity: "activity"
        case .attention: "attention"
        case .finished: "happy"
        case .failed: "concerned"
        }
    }

    func setMood(_ newMood: AgentMood) {
        guard newMood != mood else { return }
        mood = newMood
        skin?.perform("mood.\(newMood.rawValue)")
        guard let state, state != .hidden else { return }
        let next = Self.pose(for: state, mood: newMood)
        set(next, animated: !reduceMotion)
        pose = next
    }

    /// One short reaction to an agent event; nothing while hidden or with
    /// Reduce Motion (the island's words and symbols say it instead). The same
    /// cue again replaces the running one rather than stacking.
    func play(_ cue: AgentCue) {
        guard let state, state != .hidden, !reduceMotion else { return }
        cuesPlayed += 1
        skin?.perform(Self.skinAction(for: cue))
        switch cue {
        case .activity:
            oneShot(tail, "agent.tail", "transform.rotation.z", [0, 0.18, -0.08, 0], duration: 0.6)
        case .attention:
            oneShot(leftEar, "agent.ear", "transform.rotation.z", [0, -0.3, 0.1, -0.3, 0], duration: 0.7)
            oneShot(rightEar, "agent.ear", "transform.rotation.z", [0, 0.3, -0.1, 0.3, 0], duration: 0.7)
            oneShot(figure, "agent.hop", "transform.translation.y", [0, -5, 0], duration: 0.4)
        case .finished:
            oneShot(figure, "agent.hop", "transform.translation.y", [0, -10, 0, -4, 0], duration: 0.9)
            oneShot(tail, "agent.tail", "transform.rotation.z", [0, 0.3, -0.25, 0.3, 0], duration: 0.9)
        case .failed:
            oneShot(figure, "agent.shake", "transform.translation.x", [0, -3, 3, -2, 2, 0], duration: 0.5)
            oneShot(leftEar, "agent.ear", "transform.rotation.z", [0, 0.35, 0], duration: 0.6)
            oneShot(rightEar, "agent.ear", "transform.rotation.z", [0, -0.35, 0], duration: 0.6)
        }
    }
}
