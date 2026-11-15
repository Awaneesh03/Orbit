import AppKit
import QuartzCore

// Proof of concept (Milestone 9) for a frame-based pet: whatever produces the
// frames (an animator, an exported Rive/Spine clip, or generated video that
// you approve), Orbit plays them the same way: one atlas image, and a
// discrete keyframe animation of `contentsRect` that runs entirely in the
// render server (no timer, no per-frame work in Orbit, like the vector rig).

/// Frames packed left to right in one image.
struct SpriteAtlas {
    let image: CGImage
    let frameSize: CGSize
    let frameCount: Int

    /// Packs equally sized frames into one strip; nil for no frames or mixed sizes.
    static func pack(_ frames: [CGImage]) -> SpriteAtlas? {
        guard let first = frames.first, frames.allSatisfy({ $0.width == first.width && $0.height == first.height }),
              let context = CGContext(data: nil, width: first.width * frames.count, height: first.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        for (index, frame) in frames.enumerated() {
            context.draw(frame, in: CGRect(x: index * first.width, y: 0, width: first.width, height: first.height))
        }
        guard let image = context.makeImage() else { return nil }
        return SpriteAtlas(image: image, frameSize: CGSize(width: first.width, height: first.height), frameCount: frames.count)
    }

    /// Unit-space rect of frame `index` (what `contentsRect` takes).
    func rect(_ index: Int) -> CGRect {
        let width = 1 / CGFloat(frameCount)
        return CGRect(x: CGFloat(index) * width, y: 0, width: width, height: 1)
    }

    /// Decoded memory the atlas costs (RGBA): the budget figure for a clip.
    var bytes: Int { image.bytesPerRow * image.height }
}

/// One clip of a state (walk, sleep…): frames at a rate, looping or once.
struct SpriteClip {
    let atlas: SpriteAtlas
    let framesPerSecond: Double
    let loops: Bool

    var duration: CFTimeInterval { Double(atlas.frameCount) / framesPerSecond }

    /// The render-server animation: discrete steps through the frames.
    func animation() -> CAKeyframeAnimation {
        let animation = CAKeyframeAnimation(keyPath: "contentsRect")
        animation.values = (0 ..< atlas.frameCount).map { NSValue(rect: atlas.rect($0)) }
        animation.keyTimes = (0 ..< atlas.frameCount).map { NSNumber(value: Double($0) / Double(atlas.frameCount)) }
        animation.calculationMode = .discrete
        animation.duration = duration
        animation.repeatCount = loops ? .infinity : 1
        animation.isRemovedOnCompletion = !loops
        return animation
    }

    /// Plays on `layer` (replacing what it played), or shows the first frame
    /// only with Reduce Motion.
    func play(on layer: CALayer, reduceMotion: Bool) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.contents = atlas.image
        layer.contentsRect = atlas.rect(0)
        layer.contentsGravity = .resizeAspect
        CATransaction.commit()
        layer.removeAnimation(forKey: "sprite")
        guard !reduceMotion, atlas.frameCount > 1 else { return }
        layer.add(animation(), forKey: "sprite")
    }
}
