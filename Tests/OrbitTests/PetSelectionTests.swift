import AppKit
import Foundation
import Testing
@testable import Orbit

// Milestone 10.1: the dog-selection bug. Root cause: Settings offered dogs in
// a Coat picker that only styled the hidden illustrated pet while the
// default Tabby was drawn. These tests pin the character actually drawn
// (manifest id, species and atlas: cat cells are 191 px wide, dog 184 px).

private let bundled = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../Resources/Pets", directoryHint: .isDirectory).standardized

@MainActor
private func drawn(_ rig: PetRig) -> (id: String?, species: PetAppearance.Species?, cell: CGFloat?) {
    let skin = rig.skin as? SpritePetSkin
    return (skin?.characterID, skin?.manifest.species, skin?.atlases["idle"]?.frameSize.width)
}

private func look(_ character: String?, coat: String = "ginger") -> PetLook {
    var look = PetLook(coat: coat)
    look.character = character
    return look
}

/// A private copy of the bundled characters, to break on purpose.
private func copyOfBundled(_ temp: TemporaryDirectory) throws -> URL {
    let folder = temp.url.appending(path: "Pets", directoryHint: .isDirectory)
    try FileManager.default.copyItem(at: bundled, to: folder)
    return folder
}

@MainActor @Test func catAndDogEachDrawTheirOwnCharacterOnBothRenderers() {
    let library = PetCharacterLibrary(folders: [bundled])
    let desktop = PetRig(size: 96), notch = PetRig(size: 40)
    #expect(PetSelection.apply(look("pzuh-dog"), to: [desktop, notch], library: library) == .character(id: "pzuh-dog", species: .dog))
    for rig in [desktop, notch] {
        let (id, species, cell) = drawn(rig)
        #expect(id == "pzuh-dog" && species == .dog && cell == 184)
    }
    #expect(PetSelection.apply(look("pzuh-cat"), to: [desktop, notch], library: library) == .character(id: "pzuh-cat", species: .cat))
    for rig in [desktop, notch] { #expect(drawn(rig).cell == 191 && drawn(rig).species == .cat) }
    #expect(desktop.skin !== notch.skin)  // separate views, shared files
    PetSelection.apply(look("pzuh-dog"), to: [desktop, notch], library: library)
    #expect(drawn(desktop).cell == 184 && library.cachedCount == 1)  // the cat's files were released, not kept around
}

@MainActor @Test func theSelectionSurvivesARelaunch() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let preferences = PreferencesModel(file: file)
    preferences.update { $0.petLook.character = "pzuh-dog" }
    let relaunched = PreferencesModel(file: file)
    #expect(relaunched.value.petLook.character == "pzuh-dog")
    let rig = PetRig(size: 96)
    PetSelection.apply(relaunched.value.petLook, to: [rig], library: PetCharacterLibrary(folders: [bundled]))
    #expect(drawn(rig).species == .dog)
    relaunched.update { $0.petLook.character = "pzuh-cat" }
    #expect(PreferencesModel(file: file).value.petLook.character == "pzuh-cat")
}

@MainActor @Test func aDogChosenAsACoatIn10Point0BecomesTheDog() throws {
    // Exactly the saved state that showed the bug: default Tabby drawn, Golden Retriever coat chosen.
    let saved = Data(#"{"character":"pzuh-cat","coat":"golden","photoSpecies":"cat","name":"","showTestCharacters":true}"#.utf8)
    let migrated = try JSONDecoder().decode(PetLook.self, from: saved)
    #expect(migrated.character == "pzuh-dog" && migrated.coat == "golden" && migrated.selectionVersion == 2)
    // A cat coat, an explicit choice made in 10.1, or the illustrated pet: left alone.
    #expect(try JSONDecoder().decode(PetLook.self, from: Data(#"{"character":"pzuh-cat","coat":"tuxedo"}"#.utf8)).character == "pzuh-cat")
    #expect(try JSONDecoder().decode(PetLook.self, from: Data(#"{"character":"pzuh-cat","coat":"golden","selectionVersion":2}"#.utf8)).character == "pzuh-cat")
    #expect(try JSONDecoder().decode(PetLook.self, from: Data(#"{"character":"builtin","coat":"golden"}"#.utf8)).character == "builtin")
    // Re-encoding records the version, so it never migrates twice.
    let again = try JSONDecoder().decode(PetLook.self, from: try JSONEncoder().encode(migrated))
    #expect(again.character == "pzuh-dog" && again.selectionVersion == 2)
}

@MainActor @Test func aBrokenCharacterShowsTheIllustratedPetNeverTheOtherAnimal() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = try copyOfBundled(temp)
    try FileManager.default.removeItem(at: folder.appending(path: "pzuh-dog/walk.png"))  // a missing dog atlas
    let rig = PetRig(size: 96)
    let library = PetCharacterLibrary(folders: [folder])
    PetSelection.apply(look("pzuh-cat"), to: [rig], library: library)
    #expect(drawn(rig).species == .cat)
    let selection = PetSelection.apply(look("pzuh-dog"), to: [rig], library: library)
    guard case .fallback(let id, let reason) = selection else { Issue.record("expected a fallback, got \(selection)"); return }
    #expect(id == "pzuh-dog" && reason.contains("Shiba"))
    #expect(rig.skin == nil && !rig.content.isHidden)  // the illustrated pet, not the cat

    try Data("not a png".utf8).write(to: folder.appending(path: "pzuh-cat/idle.png"))  // a corrupt cat atlas
    guard case .fallback = PetSelection.apply(look("pzuh-cat"), to: [rig], library: PetCharacterLibrary(folders: [folder])) else {
        Issue.record("corrupt atlas should fall back"); return
    }
    #expect(rig.skin == nil)

    try Data("{\"id\": 1}".utf8).write(to: folder.appending(path: "pzuh-cat/character.json"))  // invalid metadata: not listed
    #expect(PetSelection.resolve(look("pzuh-cat"), library: PetCharacterLibrary(folders: [folder])) != .character(id: "pzuh-cat", species: .cat))
    #expect(PetSelection.resolve(look("unicorn"), library: library) == .fallback(id: "unicorn", reason: "No character named “unicorn” is installed."))
    #expect(PetSelection.apply(look("builtin"), to: [rig], library: library) == .builtIn && rig.skin == nil)
    #expect(PetSelection.apply(look(nil), to: [rig], library: library) == .builtIn)
}

@MainActor @Test func switchingMidActionKeepsTheStateAndShowsNoStaleFrames() throws {
    let library = PetCharacterLibrary(folders: [bundled])
    let rig = PetRig(size: 96)
    rig.apply(.walking, reduceMotion: false)
    PetSelection.apply(look("pzuh-cat"), to: [rig], library: library)
    let cat = try #require(rig.skin as? SpritePetSkin)
    #expect(cat.clip == "walk" && cat.isLooping)
    PetSelection.apply(look("pzuh-dog"), to: [rig], library: library)  // switched while walking
    let dog = try #require(rig.skin as? SpritePetSkin)
    #expect(dog.characterID == "pzuh-dog" && dog.clip == "walk" && dog.isLooping)
    #expect(cat.view.superview == nil && !cat.isLooping)  // the old cat is gone and stopped: no stale frames
    rig.apply(.dragged, reduceMotion: false)
    PetSelection.apply(look("pzuh-cat"), to: [rig], library: library)  // switched while dragged
    #expect((rig.skin as? SpritePetSkin)?.clip == "fall" && drawn(rig).species == .cat)
    // Sleep/wake, Spaces, pet off and on: state changes only, never the character.
    for state in [PetModel.State.hidden, .idle, .sleeping, .idle, .hidden, .idle] { rig.apply(state, reduceMotion: false) }
    #expect(drawn(rig).species == .cat && (rig.skin as? SpritePetSkin)?.clip == "idle")
}

@MainActor @Test func agentReactionsPlayOnTheSelectedCharacter() throws {
    let rig = PetRig(size: 96)
    PetSelection.apply(look("pzuh-dog"), to: [rig], library: PetCharacterLibrary(folders: [bundled]))
    rig.apply(.idle, reduceMotion: false)
    let dog = try #require(rig.skin as? SpritePetSkin)
    rig.play(.finished)  // happy → the dog's jump
    #expect(dog.reactions == 1 && dog.characterID == "pzuh-dog")
    let sprite = try #require(dog.view.layer?.sublayers?.last)
    let reaction = try #require(sprite.animation(forKey: "reaction") as? CAAnimationGroup)
    let contents = try #require(reaction.animations?.compactMap { $0 as? CABasicAnimation }.first { $0.keyPath == "contents" })
    #expect((contents.toValue as AnyObject?) === dog.atlases["jump"]?.image)  // the dog's own jump frames
    rig.play(.failed)  // no "concerned" clip: nothing plays, nothing breaks
    #expect(dog.reactions == 1 && rig.skin === dog)
    rig.play(.attention)
    #expect(dog.reactions == 2)
}

@MainActor @Test func desktopAndNotchHostsShowTheSameCharacter() throws {
    let library = PetCharacterLibrary(folders: [bundled])
    for id in ["pzuh-cat", "pzuh-dog"] {
        let desktop = PetRig(size: 96), notch = PetRig(size: 40)
        let desktopHost = PetRigView(rig: desktop), notchHost = PetRigView(rig: notch)
        // In real (never shown) windows, as in the app: AppKit only joins a subview's layer to its host's then.
        let windows = [desktopHost, notchHost].map { host -> NSWindow in
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: host.intrinsicContentSize), styleMask: .borderless,
                                  backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            return window
        }
        defer { windows.forEach { $0.close() } }
        PetSelection.apply(look(id), to: [desktop, notch], library: library)
        desktop.apply(.idle, reduceMotion: true)
        notch.apply(.idle, reduceMotion: true)
        for (rig, host) in [(desktop, desktopHost), (notch, notchHost)] {
            host.layoutSubtreeIfNeeded()
            host.window?.displayIfNeeded()  // AppKit joins the layer trees on its display pass, as on screen
            CATransaction.flush()
            #expect(rig.skin?.view.superview === host && rig.skin?.characterID == id)
            #expect(rig.skin?.view.layer?.superlayer === host.layer)  // really in the host's layer tree
            #expect(rig.skin?.view.frame == rig.root.frame && rig.content.isHidden)  // in the pet's place, vector figure hidden
        }
        guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
        for (name, host) in [("desktop", desktopHost), ("notch", notchHost)] {
            let size = host.bounds.size
            let context = try #require(CGContext(data: nil, width: Int(size.width * 2), height: Int(size.height * 2), bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                 bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(srgbRed: 0.93, green: 0.93, blue: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
            context.scaleBy(x: 2, y: 2)
            try #require(host.layer).render(in: context)
            let out = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m10-1-selection").standardized
            try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try NSBitmapImageRep(cgImage: try #require(context.makeImage())).representation(using: .png, properties: [:])?
                .write(to: out.appending(path: "\(id)-\(name).png"))
        }
    }
}

@MainActor @Test func settingsPreviewShowsTheSelectedPet() throws {
    let library = PetCharacterLibrary(folders: [bundled])
    let dog = try #require(PetSelection.preview(look("pzuh-dog"), library: library))
    let cat = try #require(PetSelection.preview(look("pzuh-cat"), library: library))
    #expect(dog.width == 184 && cat.width == 191)  // the selected animal's own first idle frame
    #expect(PetSelection.preview(look("builtin", coat: "golden"), library: library) != nil)  // the illustrated pet
}

@MainActor @Test func aHiddenPetShowsNoFrozenCharacterFrame() {
    let rig = PetRig(size: 96)
    rig.apply(.idle, reduceMotion: false)
    PetSelection.apply(look("pzuh-dog"), to: [rig], library: PetCharacterLibrary(folders: [bundled]))
    #expect(rig.skin?.view.isHidden == false)
    rig.apply(.hidden, reduceMotion: false)  // covered by windows, display asleep, pet off
    #expect(rig.skin?.view.isHidden == true)
    rig.apply(.idle, reduceMotion: false)
    #expect(rig.skin?.view.isHidden == false)
    let fresh = PetRig(size: 96)  // a character attached before any state: hidden until shown
    PetSelection.apply(look("pzuh-cat"), to: [fresh], library: PetCharacterLibrary(folders: [bundled]))
    #expect(fresh.skin?.view.isHidden == true)
}
