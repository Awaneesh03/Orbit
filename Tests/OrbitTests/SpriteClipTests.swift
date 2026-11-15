import AppKit
import QuartzCore
import Testing
@testable import Orbit

// Milestone 9 proof of concept: frames → one atlas → render-server playback.
// The frames here come from the vector rig (a breathing, tail-swinging
// cycle) because that's what exists locally; generated or animated frames
// would go through the same path. ORBIT_RENDER=1 writes the strip to
// docs/screenshots/m9-pet-poc/.

@MainActor
private func frame(_ rig: PetRig, phase: Double) throws -> CGImage {
    let swing = sin(phase * 2 * .pi)
    rig.tail.transform = CATransform3DMakeRotation(0.28 * swing, 0, 0, 1)
    rig.body.transform = CATransform3DMakeScale(1, 1 + 0.025 * swing, 1)
    rig.head.transform = CATransform3DMakeTranslation(0, -1.2 * swing, 0)
    let bounds = rig.root.bounds
    let context = try #require(CGContext(data: nil, width: Int(bounds.width * 2), height: Int(bounds.height * 2), bitsPerComponent: 8,
                                         bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                         bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.scaleBy(x: 2, y: 2)
    rig.root.render(in: context)
    return try #require(context.makeImage())
}

@MainActor @Test func framesPackIntoAnAtlasThatPlaysInTheRenderServer() throws {
    let rig = PetRig(size: 120)
    rig.apply(.idle, reduceMotion: true)
    let frames = try (0 ..< 8).map { try frame(rig, phase: Double($0) / 8) }
    let atlas = try #require(SpriteAtlas.pack(frames))
    #expect(atlas.frameCount == 8 && atlas.image.width == frames[0].width * 8)
    #expect(atlas.rect(3) == CGRect(x: 3.0 / 8, y: 0, width: 1.0 / 8, height: 1))
    // Budget: 8 frames at 240 × 200 px is under 1.6 MB decoded.
    #expect(atlas.bytes <= 8 * 240 * 200 * 4 + 4096)

    let clip = SpriteClip(atlas: atlas, framesPerSecond: 12, loops: true)
    let animation = clip.animation()
    #expect(animation.calculationMode == .discrete && animation.values?.count == 8 && animation.repeatCount == .infinity)
    #expect(abs(clip.duration - 8.0 / 12) < 0.0001)

    let layer = CALayer()
    clip.play(on: layer, reduceMotion: false)
    #expect(layer.animation(forKey: "sprite") != nil && layer.contentsRect == atlas.rect(0))
    clip.play(on: layer, reduceMotion: true)
    #expect(layer.animation(forKey: "sprite") == nil)  // Reduce Motion: a still first frame

    #expect(SpriteAtlas.pack([]) == nil)
    let small = try #require(CGContext(data: nil, width: 10, height: 10, bitsPerComponent: 8, bytesPerRow: 0,
                                       space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage())
    #expect(SpriteAtlas.pack([frames[0], small]) == nil)  // mixed sizes are refused

    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m9-pet-poc").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try NSBitmapImageRep(cgImage: atlas.image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "atlas-strip.png"))
}
