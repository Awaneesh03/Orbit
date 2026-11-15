import AppKit
import QuartzCore

/// A character drawn from frame strips (Milestone 10, zero-cost path): Orbit
/// plays them in the render server with discrete `contentsRect` animations,
/// following the same energy rule as the vector rig and Rive skins:
/// - walking, running, dragged: their clip loops (the only continuous motion);
/// - every other state shows one still frame (idle, sit, sleep): free;
/// - a reaction (click, happy, fidget, sit…) plays its clip once as an
///   animation that removes itself and reveals the still frame again, so no
///   timer is involved and nothing keeps running.
/// Reduce Motion or hidden: stills only.
@MainActor
final class SpritePetSkin: PetSkin {
    let manifest: PetCharacterManifest
    let atlases: [String: SpriteAtlas]
    let view: NSView
    private let sprite = CALayer()
    private let shadow = CAGradientLayer()
    private(set) var state: PetModel.State?
    /// The clip on screen and whether it's moving (tests, diagnostics).
    private(set) var clip: String?
    private(set) var isLooping = false
    private(set) var reactions = 0
    private var visible = true
    private var reduceMotion = false
    var characterID: String { manifest.id }

    static let loopingStates: Set<PetModel.State> = [.walking, .running, .dragged]

    init(manifest: PetCharacterManifest, atlases: [String: SpriteAtlas]) {
        self.manifest = manifest
        self.atlases = atlases
        let host = SpritePetView()
        host.wantsLayer = true
        view = host
        shadow.type = .radial
        shadow.colors = [CGColor(gray: 0, alpha: 0.22), CGColor(gray: 0, alpha: 0)]
        shadow.startPoint = CGPoint(x: 0.5, y: 0.5)
        shadow.endPoint = CGPoint(x: 1, y: 1)
        sprite.contentsGravity = .resize
        sprite.magnificationFilter = .linear
        sprite.minificationFilter = .trilinear
        host.layer?.addSublayer(shadow)
        host.layer?.addSublayer(sprite)
        host.onLayout = { [weak self] bounds in self?.layOut(in: bounds) }
    }

    /// Bottom-centred, aspect-fit to the pet's box, with a soft contact shadow.
    private func layOut(in bounds: CGRect) {
        guard let frame = atlases.values.first?.frameSize, frame.height > 0 else { return }
        let scale = min(bounds.width / frame.width, bounds.height / frame.height)
        let size = CGSize(width: frame.width * scale, height: frame.height * scale)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.frame = CGRect(x: bounds.midX - size.width / 2, y: bounds.minY + size.height * 0.02, width: size.width, height: size.height)
        shadow.frame = CGRect(x: bounds.midX - size.width * 0.3, y: bounds.minY, width: size.width * 0.6, height: max(4, size.height * 0.07))
        CATransaction.commit()
    }

    func apply(_ newState: PetModel.State, reduceMotion newReduce: Bool) {
        reduceMotion = newReduce
        state = newState
        show()
    }

    func perform(_ action: String) {
        guard visible, !reduceMotion, let state, !Self.loopingStates.contains(state), state != .hidden,
              let name = manifest.spriteActions?[action], let atlas = atlases[name] else { return }
        reactions += 1
        let clip = SpriteClip(atlas: atlas, framesPerSecond: manifest.clips?[name]?.fps ?? 12, loops: false)
        let frames = clip.animation()
        let contents = CABasicAnimation(keyPath: "contents")
        contents.fromValue = atlas.image
        contents.toValue = atlas.image
        let group = CAAnimationGroup()
        group.animations = [frames, contents]
        group.duration = clip.duration
        group.isRemovedOnCompletion = true  // the still frame underneath shows again: nothing left running
        sprite.add(group, forKey: "reaction")
    }

    func setFacing(_ facing: PetFacing) {
        let mirrored = (facing == .left) == manifest.facesRight
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        sprite.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
        CATransaction.commit()
    }

    func setVisible(_ newVisible: Bool) {
        visible = newVisible
        show()
    }

    /// The state's clip: looping while moving, otherwise its first frame, still.
    private func show() {
        sprite.removeAllAnimations()
        guard let state, state != .hidden else {
            isLooping = false
            return
        }
        let name = manifest.spriteStates?[state.rawValue] ?? manifest.spriteStates?["idle"] ?? atlases.keys.sorted().first
        guard let name, let atlas = atlases[name] else { return }
        clip = name
        let loops = visible && !reduceMotion && Self.loopingStates.contains(state)
        isLooping = loops
        SpriteClip(atlas: atlas, framesPerSecond: manifest.clips?[name]?.fps ?? 12, loops: loops)
            .play(on: sprite, reduceMotion: !loops)
        sprite.contentsGravity = .resize  // `play` sets aspect; the layer is already aspect-fitted
    }
}

/// Lays out the sprite whenever the host resizes it.
final class SpritePetView: NSView {
    var onLayout: ((CGRect) -> Void)? { didSet { onLayout?(bounds) } }
    override func layout() {
        super.layout()
        onLayout?(bounds)
    }

    /// At once on every size change, not only at the next display pass: the
    /// sprite is never left zero-sized before its first layout.
    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        onLayout?(bounds)
    }
    override var isFlipped: Bool { false }
}
