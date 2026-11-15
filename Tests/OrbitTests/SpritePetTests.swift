import AppKit
import QuartzCore
import Testing
@testable import Orbit

// Milestone 10 (zero-cost): the bundled CC0 cat and dog by pzUH, played as
// frame strips. ORBIT_RENDER=1 writes docs/screenshots/m10-pets/*.png.

private let bundled = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/Pets", directoryHint: .isDirectory).standardized

@MainActor @Test func theBundledCatAndDogAreFreeLicensedAndValid() throws {
    let library = PetCharacterLibrary(folders: [bundled])
    let characters = library.available(includeTest: false)
    #expect(characters.map(\.manifest.id).sorted() == ["pzuh-cat", "pzuh-dog"])
    for (manifest, folder) in characters {
        #expect(manifest.isSprites && manifest.production)
        #expect(manifest.licence.cost == "free" && manifest.licence.type.hasPrefix("CC0"))
        #expect(manifest.licence.commercialUse && manifest.licence.redistribution && manifest.licence.modification)
        #expect(FileManager.default.fileExists(atPath: folder.appending(path: "LICENSE.md").path(percentEncoded: false)))
        let atlases = try library.atlases(for: manifest, in: folder)
        for state in ["idle", "walking", "running", "sleeping", "dragged", "playful"] {
            #expect(manifest.spriteStates?[state].flatMap { atlases[$0] } != nil, "\(manifest.id) \(state)")
        }
        let decoded = atlases.values.map(\.bytes).reduce(0, +)
        #expect(decoded < 10 * 1024 * 1024, "\(manifest.id): \(decoded) bytes decoded")  // memory budget per character
    }
    #expect(PetLook().character == "pzuh-cat")  // the default pet for a fresh install
}

@MainActor @Test func spriteClipsLoopOnlyWhileMovingAndReactionsRemoveThemselves() throws {
    let library = PetCharacterLibrary(folders: [bundled])
    let entry = try #require(library.available(includeTest: false).first { $0.manifest.id == "pzuh-dog" })
    let skin = try #require(try library.skin(for: entry.manifest, in: entry.folder) as? SpritePetSkin)
    skin.view.frame = CGRect(x: 0, y: 0, width: 96, height: 80)
    skin.view.layout()
    skin.apply(.idle, reduceMotion: false)
    #expect(skin.clip == "idle" && !skin.isLooping)  // a still frame: free
    skin.apply(.walking, reduceMotion: false)
    #expect(skin.clip == "walk" && skin.isLooping)
    skin.perform("click")
    #expect(skin.reactions == 0)  // not while walking
    skin.apply(.sleeping, reduceMotion: false)
    #expect(skin.clip == "sleep" && !skin.isLooping)
    skin.apply(.playful, reduceMotion: false)
    skin.perform("click")
    #expect(skin.reactions == 1)
    let sprite = try #require(skin.view.layer?.sublayers?.last)
    let reaction = try #require(sprite.animation(forKey: "reaction"))
    #expect(reaction.isRemovedOnCompletion && reaction.repeatCount == 0 && reaction.duration < 1)
    skin.perform("concerned")  // no clip for it: nothing, no crash
    skin.apply(.running, reduceMotion: true)
    #expect(!skin.isLooping && sprite.animationKeys() == nil)  // Reduce Motion: stills only
    skin.setFacing(.left)
    #expect(sprite.affineTransform().a == -1)
    skin.apply(.hidden, reduceMotion: false)
    #expect(sprite.animationKeys() == nil)
}

@MainActor @Test func everyBundledStateRenders() throws {
    let library = PetCharacterLibrary(folders: [bundled])
    for (manifest, folder) in library.available(includeTest: false) {
        for state in [PetModel.State.idle, .walking, .sleeping, .playful, .dragged] {
            let skin = try #require(try library.skin(for: manifest, in: folder) as? SpritePetSkin)
            skin.view.frame = CGRect(x: 0, y: 0, width: 240, height: 200)
            skin.view.layout()
            skin.apply(state, reduceMotion: true)  // a still frame of each state
            let context = try #require(CGContext(data: nil, width: 480, height: 400, bitsPerComponent: 8, bytesPerRow: 0,
                                                 space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 480, height: 400))
            context.scaleBy(x: 2, y: 2)
            try #require(skin.view.layer).render(in: context)
            let image = try #require(context.makeImage())
            guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
            let out = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m10-pets").standardized
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: out.appending(path: "\(manifest.id)-\(state.rawValue).png"))
        }
    }
}
