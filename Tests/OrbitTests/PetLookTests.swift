import AppKit
import QuartzCore
import Testing
@testable import Orbit

// Milestone 7: cat and dog looks, photo colours, the bigger idle gestures.
// ORBIT_RENDER=1 writes docs/screenshots/m7-pet/*.png.

@Test func presetsCoverCatsAndDogsWithUniqueIDs() {
    let presets = PetAppearance.presets
    #expect(Set(presets.map(\.id)).count == presets.count)
    #expect(presets.filter { $0.appearance.species == .cat }.count >= 3)
    #expect(presets.filter { $0.appearance.species == .dog }.count >= 3)
    #expect(PetAppearance.preset("ginger") == .orbit)
    #expect(PetAppearance.preset("nope") == nil)
}

@Test func theLookFallsBackSafely() {
    #expect(PetLook().appearance == .orbit)  // a fresh install: Orbit's ginger cat
    #expect(PetLook(coat: "greywhite").appearance.species == .dog)
    #expect(PetLook(coat: "unknown-coat").appearance == .orbit)
    #expect(PetLook(coat: "photo").appearance == .orbit)  // "photo" without colours: never a broken pet
    let photo = PetLook(coat: "photo", photoPrimary: "#3A2A1C", photoSecondary: "#F2EDE6", photoSpecies: .dog)
    #expect(photo.appearance.species == .dog && photo.appearance.primary.hex == "#3A2A1C")
    #expect(photo.appearance.markings.contains(.bib))  // strong contrast: light markings shown
}

@Test func hexRoundTrips() {
    #expect(PetColor(hex: "#FF8000")?.hex == "#FF8000")
    #expect(PetColor(hex: "00ff00")?.green == 1)
    #expect(PetColor(hex: "#12") == nil && PetColor(hex: "zzzzzz") == nil)
}

@Test func photoColoursAreTheTypicalFurAndItsLightMarkings() throws {
    // Mostly brown fur, some shadow, some white chest.
    let brown = PetColor(red: 0.55, green: 0.35, blue: 0.2), shadow = PetColor(red: 0.1, green: 0.07, blue: 0.05)
    let white = PetColor(red: 0.96, green: 0.95, blue: 0.93)
    let pixels = Array(repeating: brown, count: 65) + Array(repeating: shadow, count: 15) + Array(repeating: white, count: 20)
    let colors = try #require(PetPhotoPalette.colors(from: pixels))
    #expect(colors.primary.hex == brown.hex)  // shadows don't darken it
    #expect(colors.secondary.hex == white.hex)
    // A uniform coat: the markings are a lighter shade of it, not invented white.
    let grey = PetColor(red: 0.5, green: 0.5, blue: 0.52)
    let uniform = try #require(PetPhotoPalette.colors(from: Array(repeating: grey, count: 40)))
    #expect(uniform.secondary.hex == grey.lighter(0.55).hex)
    #expect(PetPhotoPalette.colors(from: [grey]) == nil)  // too little to go on
}

@MainActor @Test func photoPixelsSkipTheBackground() throws {
    // A tiny synthetic "photo": a red disc on transparent: only opaque pixels come back.
    let side = 64
    let context = try #require(CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.9, green: 0.1, blue: 0.1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: side, height: side))
    let image = try #require(context.makeImage())
    let pixels = PetPhotoPalette.pixels(from: image)
    #expect(!pixels.isEmpty)
    #expect(pixels.allSatisfy { $0.red > 0.8 && $0.green < 0.2 })
}

@MainActor @Test func changingTheLookKeepsTheStateAndRedraws() {
    let rig = PetRig(size: 96)
    rig.apply(.sleeping, reduceMotion: true)
    let golden = PetAppearance.preset("golden")!
    rig.setAppearance(golden)
    #expect(rig.appearance == golden && rig.state == .sleeping)
    #expect(rig.pose == PetRig.pose(for: .sleeping))
    #expect(rig.whiskers.allSatisfy { $0.path == nil })  // dogs have no whiskers
    rig.setAppearance(.orbit)
    #expect(rig.whiskers.allSatisfy { $0.path != nil })
    #expect(rig.repeatingAnimationCount == 0)  // sleeping is still, before and after
}

@MainActor @Test func biggerGesturesAreShortOneShotsOnlyWhenIdle() {
    let rig = PetRig(size: 96)
    rig.apply(.idle, reduceMotion: false)
    rig.playFidget(4)  // every fourth fidget adds a gesture
    #expect(rig.gesturesPlayed == 1)
    for index in 0 ..< 3 {
        rig.playGesture(index)
    }
    var longest: CFTimeInterval = 0
    PetRig.walk(rig.root) { layer in
        for key in layer.animationKeys() ?? [] where key.hasPrefix("gesture.") {
            let animation = layer.animation(forKey: key)
            longest = max(longest, animation?.duration ?? 99)
            #expect((animation?.repeatCount ?? 1) == 0)  // one-shots, never loops
        }
    }
    #expect(longest > 1 && longest <= 2.6)
    #expect(rig.repeatingAnimationCount == 0)  // idle stays still between gestures
    rig.apply(.walking, reduceMotion: false)
    rig.playGesture(1)
    #expect(rig.gesturesPlayed == 4)  // not idle: ignored
    let calm = PetRig(size: 96)
    calm.apply(.idle, reduceMotion: true)
    calm.playGesture(0)
    #expect(calm.gesturesPlayed == 0)  // Reduce Motion: none
}

@MainActor @Test func everyLookRenders() throws {
    for (id, _, appearance) in PetAppearance.presets {
        for (state, name) in [(PetModel.State.idle, "idle"), (.playful, "happy"), (.sleeping, "sleeping")] {
            let rig = PetRig(appearance: appearance, size: 240)
            rig.setContentsScale(2)
            rig.apply(state, reduceMotion: true)
            try write(rig, "\(id)-\(name)")
        }
    }
}

@MainActor
private func write(_ rig: PetRig, _ name: String) throws {
    let bounds = rig.root.bounds
    let scale: CGFloat = 2
    let width = Int(bounds.width * scale), height = Int(bounds.height * scale)
    let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                         space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
    context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    context.scaleBy(x: scale, y: scale)
    rig.root.render(in: context)
    let image = try #require(context.makeImage())
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m7-pet").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}
