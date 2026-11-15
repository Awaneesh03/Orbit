import AppKit
import Foundation
import Testing
@testable import Orbit

// Milestone 10: Orbit Pet on Rive. Uses a CC BY test character (fixture,
// see Fixtures/Pets/test-interactive-dog/LICENSE.md), never bundled.

private let fixtures = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/Pets", directoryHint: .isDirectory)

@MainActor @Test func theLibraryFindsValidatesAndCachesCharacters() throws {
    let library = PetCharacterLibrary(folders: [fixtures, URL(filePath: "/nonexistent/Pets")])
    #expect(library.available(includeTest: false).isEmpty)  // test characters stay out of the normal list
    let entry = try #require(library.available(includeTest: true).first)
    #expect(entry.manifest.id == "test-interactive-dog" && entry.manifest.species == .dog && !entry.manifest.production)
    #expect(entry.manifest.licence.type == "CC BY 4.0" && entry.manifest.licence.redistribution)
    let file = try library.file(for: entry.manifest, in: entry.folder)
    let again = try library.file(for: entry.manifest, in: entry.folder)
    #expect(file === again && library.loads == 1)  // parsed once
    library.release(entry.manifest.id)
    #expect(library.cachedCount == 0)
}

@MainActor @Test func brokenCharactersFailCleanly() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let library = PetCharacterLibrary(folders: [temp.url])
    let base = try PetCharacterLibrary.manifest(in: fixtures.appending(path: "test-interactive-dog"))
    func folder(_ name: String, riv: Data?, manifest: PetCharacterManifest?) throws -> URL {
        let url = temp.url.appending(path: name, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        if let riv { try riv.write(to: url.appending(path: "character.riv")) }
        if let manifest { try JSONEncoder().encode(manifest).write(to: url.appending(path: "character.json")) }
        return url
    }
    let good = try Data(contentsOf: fixtures.appending(path: "test-interactive-dog/character.riv"))
    var manifest = base
    manifest.id = "corrupt"
    #expect(throws: PetCharacterError.malformed) { try library.file(for: manifest, in: try folder("corrupt", riv: Data("junk".utf8), manifest: manifest)) }
    manifest.id = "missing"
    #expect(throws: PetCharacterError.missingFile) { try library.file(for: manifest, in: try folder("missing", riv: nil, manifest: manifest)) }
    manifest.id = "wrong-machine"
    manifest.stateMachine = "Nope"
    #expect(throws: PetCharacterError.missingStateMachine("Nope")) { try library.file(for: manifest, in: try folder("wrong-machine", riv: good, manifest: manifest)) }
    manifest = base
    manifest.id = "wrong-artboard"
    manifest.artboard = "Nope"
    #expect(throws: PetCharacterError.missingArtboard("Nope")) { try library.file(for: manifest, in: try folder("wrong-artboard", riv: good, manifest: manifest)) }
    let bad = try folder("bad-json", riv: good, manifest: nil)
    try Data("{\"id\": 3}".utf8).write(to: bad.appending(path: "character.json"))
    #expect(library.available(includeTest: true).allSatisfy { $0.manifest.id != "bad-json" })  // skipped, not a crash
    #expect(library.cachedCount == 0)  // nothing broken is kept
}

@MainActor @Test func theSkinMapsStatesAndActionsToInputs() throws {
    let library = PetCharacterLibrary(folders: [fixtures])
    let entry = try #require(library.available(includeTest: true).first)
    let skin = RivePetSkin(manifest: entry.manifest, file: try library.file(for: entry.manifest, in: entry.folder))
    skin.apply(.idle, reduceMotion: false)
    #expect(skin.applied.suffix(3) == ["Hit Tong=0.0", "Hit Staart=0.0", "Hit Oor=0.0"])
    skin.apply(.playful, reduceMotion: false)
    #expect(skin.applied.last == "Hit Tong=1.0")
    let count = skin.applied.count
    skin.apply(.playful, reduceMotion: false)
    #expect(skin.applied.count == count)  // the same state again sets nothing
    skin.perform("click")
    #expect(skin.applied.last == "Hit Tong=1.0")
    skin.perform("doesNotExist")  // an input the file doesn't have: ignored by the runtime, no crash
    skin.perform("unmapped-action")
    skin.apply(.idle, reduceMotion: true)
    let still = skin.applied.count
    skin.perform("happy")
    #expect(skin.applied.count == still)  // Reduce Motion: no one-shots
    skin.setFacing(.left)
    #expect(skin.view.layer?.affineTransform().a == -1)
    skin.setFacing(.right)
    #expect(skin.view.layer?.affineTransform().a == 1)
}

@MainActor @Test func theRigForwardsToItsSkinAndFallsBackInstantly() throws {
    let library = PetCharacterLibrary(folders: [fixtures])
    let entry = try #require(library.available(includeTest: true).first)
    let rig = PetRig(size: 96)
    var installs = 0
    rig.onSkinChange = { installs += 1 }
    rig.apply(.idle, reduceMotion: false)
    let skin = RivePetSkin(manifest: entry.manifest, file: try library.file(for: entry.manifest, in: entry.folder))
    rig.attach(skin)
    #expect(rig.content.isHidden && installs == 1 && skin.state == .idle)  // the current state, at once
    rig.apply(.playful, reduceMotion: false)
    rig.playReaction()
    #expect(skin.applied.last == "Hit Tong=1.0")
    #expect(PetRig.skinAction(for: .finished) == "happy" && PetRig.skinAction(for: .failed) == "concerned")
    rig.attach(nil)
    #expect(!rig.content.isHidden && installs == 2 && rig.skin == nil)
}

@MainActor @Test func roamingAndIdleGesturesSwitchOffIndependently() {
    let clock = FakeScheduler()
    let activity = PetActivity(scheduler: clock, inactivityThreshold: .seconds(600), idleSeconds: { 0 })
    let model = PetModel(activity: activity, scheduler: clock, choosesRunning: { false })
    model.toggles = PetModel.Toggles(pet: true, desktop: true, companion: false)
    #expect(model.state == .idle && model.pendingTimers >= 2)  // a gesture and a wander pending
    model.behavior.roaming = false
    clock.advance(.seconds(120))
    #expect(model.state == .idle && model.fidgets > 0)  // gestures continue, no walk
    model.behavior.idleGestures = false
    let fidgets = model.fidgets
    clock.advance(.seconds(120))
    #expect(model.fidgets == fidgets && model.state == .idle)  // still
    model.behavior = PetBehavior(roaming: true, idleGestures: true, liveliness: .calm)
    #expect(PetBehavior.Liveliness.calm.scale(.seconds(8)) == .seconds(16) && PetBehavior.Liveliness.lively.scale(.seconds(10)) == .seconds(6))
}

@Test func thePetLookDecodesOldFilesWithoutLosingAnything() throws {
    let old = try JSONDecoder().decode(PetLook.self, from: Data(##"{"coat":"photo","photoPrimary":"#3A2A1C","photoSecondary":"#F2EDE6","photoSpecies":"dog"}"##.utf8))
    #expect(old.coat == "photo" && old.photoPrimary == "#3A2A1C" && old.photoSpecies == .dog)  // M7 file: kept
    #expect(old.character == PetLook.defaultCharacter && old.behavior == PetBehavior() && !old.showTestCharacters)
    let named = try JSONDecoder().decode(PetLook.self, from: Data(#"{"name":"\#(String(repeating: "x", count: 99))","behavior":"garbage"}"#.utf8))
    #expect(named.name.count == 40 && named.behavior == PetBehavior())
}

@MainActor @Test func theCharacterOnlyRendersWhileMovingOrForABriefBurst() async throws {
    let library = PetCharacterLibrary(folders: [fixtures])
    let entry = try #require(library.available(includeTest: true).first)
    let skin = RivePetSkin(manifest: entry.manifest, file: try library.file(for: entry.manifest, in: entry.folder), settle: .milliseconds(40))
    #expect(!skin.isPlaying && !skin.displayLinkRunning)  // created still: a hidden copy never renders
    skin.apply(.walking, reduceMotion: false)
    #expect(skin.isPlaying)  // moving: continuous (the view itself only ticks in a window; measured live)
    try await Task.sleep(for: .milliseconds(120))
    #expect(skin.isPlaying)  // still walking: no settle
    skin.apply(.idle, reduceMotion: false)
    #expect(skin.isPlaying)  // the change plays a burst…
    for _ in 0 ..< 50 where skin.isPlaying { try await Task.sleep(for: .milliseconds(20)) }
    #expect(!skin.isPlaying && !skin.displayLinkRunning)  // …then holds its frame: no display link at all
    skin.perform("fidget")
    #expect(skin.isPlaying)
    skin.setVisible(false)
    #expect(!skin.isPlaying)  // hidden: nothing
    skin.setVisible(true)
    skin.apply(.running, reduceMotion: true)
    #expect(!skin.isPlaying)  // Reduce Motion: still, even when running
    skin.apply(.hidden, reduceMotion: false)
    #expect(!skin.isPlaying)
}
