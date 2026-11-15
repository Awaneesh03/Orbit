import AppKit

// Which pet is drawn (Milestone 10.1). One function decides, for the desktop
// pet and the notch companion alike, and reports exactly what happened, so a
// selection can never silently turn into another character: a character that
// can't load shows Orbit's illustrated pet and says why.

enum PetSelection: Equatable {
    /// Orbit's illustrated pet (its coat and photo colours).
    case builtIn
    /// A bundled or installed character, loaded and validated.
    case character(id: String, species: PetAppearance.Species)
    /// The chosen character couldn't be used: the illustrated pet stands in.
    case fallback(id: String, reason: String)

    var characterID: String? {
        if case .character(let id, _) = self { return id }
        return nil
    }

    /// What `look` resolves to, loading (and caching) the character's files.
    @MainActor
    static func resolve(_ look: PetLook, library: PetCharacterLibrary) -> PetSelection {
        guard let id = look.character, id != PetLook.builtIn else { return .builtIn }
        guard let entry = library.available(includeTest: true).first(where: { $0.manifest.id == id }) else {
            return .fallback(id: id, reason: "No character named “\(id)” is installed.")
        }
        do {
            if entry.manifest.isSprites { _ = try library.atlases(for: entry.manifest, in: entry.folder) }
            else { _ = try library.file(for: entry.manifest, in: entry.folder) }
            return .character(id: id, species: entry.manifest.species)
        } catch {
            return .fallback(id: id, reason: "“\(entry.manifest.name)” couldn't be loaded (\(error)).")
        }
    }

    /// Puts the selection on every rig (desktop, notch): the same character on
    /// each, or the illustrated pet on each. Releases the previous character's files.
    @MainActor @discardableResult
    static func apply(_ look: PetLook, to rigs: [PetRig], library: PetCharacterLibrary) -> PetSelection {
        let previous = rigs.compactMap { $0.skin?.characterID }.first
        var selection = resolve(look, library: library)
        if case .character(let id, _) = selection, let entry = library.available(includeTest: true).first(where: { $0.manifest.id == id }) {
            do {
                for rig in rigs where rig.skin?.characterID != id { rig.attach(try library.skin(for: entry.manifest, in: entry.folder)) }
            } catch {
                selection = .fallback(id: id, reason: "“\(entry.manifest.name)” couldn't be shown (\(error)).")
            }
        }
        if selection.characterID == nil { rigs.forEach { $0.attach(nil) } }
        if let previous, previous != selection.characterID { library.release(previous) }
        return selection
    }

    /// A still of what's selected, for Settings: the character's first idle
    /// frame, or the illustrated pet. nil if nothing can be drawn.
    @MainActor
    static func preview(_ look: PetLook, library: PetCharacterLibrary) -> CGImage? {
        switch resolve(look, library: library) {
        case .character(let id, _):
            guard let entry = library.available(includeTest: true).first(where: { $0.manifest.id == id }), entry.manifest.isSprites,
                  let atlases = try? library.atlases(for: entry.manifest, in: entry.folder),
                  let idle = atlases[entry.manifest.spriteStates?["idle"] ?? "idle"] ?? atlases.values.first else { return nil }
            return idle.image.cropping(to: CGRect(origin: .zero, size: idle.frameSize))
        case .builtIn, .fallback:
            let rig = PetRig(appearance: look.appearance, size: 120)
            rig.apply(.idle, reduceMotion: true)
            return rig.still()
        }
    }
}
