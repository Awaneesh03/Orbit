import AppKit
import MetalKit
import RiveRuntime

// Orbit Pet on Rive (Milestone 10). A character is a folder with a manifest
// (character.json), a .riv file and its licence. The manifest says how
// Orbit's pet states and actions map onto the file's state-machine inputs,
// so any properly licensed character drops in without code changes. The
// vector rig stays the fallback: no character chosen, a missing or invalid
// file, or a failed load all keep today's pet, never a blank window.

// MARK: Manifest

struct PetCharacterManifest: Codable, Equatable, Sendable, Identifiable {
    /// How one Orbit state or action drives an input.
    struct InputAction: Codable, Equatable, Sendable {
        enum Kind: String, Codable, Sendable { case bool, number, trigger }
        var input: String
        var kind: Kind
        /// For bool (0/1) and number inputs.
        var value: Double?
    }

    struct Licence: Codable, Equatable, Sendable {
        var type: String
        var creator: String
        var source: String
        var attribution: String
        var commercialUse: Bool
        var redistribution: Bool
        var modification: Bool
        var cost: String
    }

    /// A Rive file, or frame strips played by Orbit (`SpritePetSkin`).
    enum Kind: String, Codable, Sendable { case rive, sprites }

    /// One frame strip: `frames` equal cells left to right.
    struct Clip: Codable, Equatable, Sendable {
        var file: String
        var frames: Int
        var fps: Double
    }

    var id: String
    var name: String
    var species: PetAppearance.Species
    var version: Int
    var kind: Kind? = nil
    /// Rive only.
    var file: String?
    var artboard: String?
    var stateMachine: String?
    /// Sprites only: clips by name, and which clip each Orbit state and action uses.
    var clips: [String: Clip]? = nil
    var spriteStates: [String: String]? = nil
    var spriteActions: [String: String]? = nil

    var isSprites: Bool { kind == .sprites }
    /// Production characters show in Settings; test characters only when development characters are on.
    var production: Bool
    /// The artwork looks right when the pet walks right (mirrored for left).
    var facesRight = true
    var licence: Licence
    /// Orbit state (`PetModel.State` raw value) → inputs to set while in it.
    var states: [String: [InputAction]] = [:]
    /// One-shot actions: click, doubleClick, pet, stretch, lookAround, happy, concerned, attention, wake.
    var actions: [String: [InputAction]] = [:]

    static let fileName = "character.json"
    static let maxBytes = 20 * 1024 * 1024
}

enum PetCharacterError: Error, Equatable {
    case missingManifest, badManifest(String), missingFile, tooLarge, malformed, missingArtboard(String), missingStateMachine(String)
    case badClip(String)
}

// MARK: Library

/// Characters bundled with Orbit (Resources/Pets) and ones the user installed
/// (Application Support/Orbit/Pets). Parses each .riv once and releases it
/// when no pet shows that character.
@MainActor
final class PetCharacterLibrary {
    static let shared = PetCharacterLibrary(folders: PetCharacterLibrary.defaultFolders())

    let folders: [URL]
    private var files: [String: RiveFile] = [:]
    private var sprites: [String: [String: SpriteAtlas]] = [:]
    private(set) var loads = 0

    init(folders: [URL]) { self.folders = folders }

    static func defaultFolders() -> [URL] {
        [Bundle.main.resourceURL?.appending(path: "Pets", directoryHint: .isDirectory),
         OrbitStorage.directory.appending(path: "Pets", directoryHint: .isDirectory)].compactMap { $0 }
    }

    /// Every valid manifest found (unreadable folders and manifests are skipped).
    func available(includeTest: Bool) -> [(manifest: PetCharacterManifest, folder: URL)] {
        folders.flatMap { root -> [(PetCharacterManifest, URL)] in
            let children = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            return children.compactMap { folder in (try? Self.manifest(in: folder)).map { ($0, folder) } }
        }
        .filter { includeTest || $0.0.production }
        .sorted { $0.0.name < $1.0.name }
    }

    static func manifest(in folder: URL) throws(PetCharacterError) -> PetCharacterManifest {
        guard let data = try? Data(contentsOf: folder.appending(path: PetCharacterManifest.fileName)) else { throw .missingManifest }
        do { return try JSONDecoder().decode(PetCharacterManifest.self, from: data) } catch {
            throw .badManifest(String(describing: error).prefix(120).description)
        }
    }

    /// The parsed file, validated against its manifest; cached until released.
    func file(for manifest: PetCharacterManifest, in folder: URL) throws(PetCharacterError) -> RiveFile {
        if let cached = files[manifest.id] { return cached }
        guard let name = manifest.file, let machine = manifest.stateMachine else { throw .missingFile }
        let url = folder.appending(path: name)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)),
              let size = attributes[.size] as? Int else { throw .missingFile }
        guard size <= PetCharacterManifest.maxBytes else { throw .tooLarge }
        guard let data = try? Data(contentsOf: url), let file = try? RiveFile(data: data, loadCdn: false) else { throw .malformed }
        let artboard: RiveArtboard
        do {
            artboard = try manifest.artboard.map { try file.artboard(fromName: $0) } ?? file.artboard()
        } catch { throw .missingArtboard(manifest.artboard ?? "default") }
        guard artboard.stateMachineNames().contains(machine) else { throw .missingStateMachine(machine) }
        loads += 1
        files[manifest.id] = file
        return file
    }

    /// A sprite character's strips, decoded once and checked (each divides into its frames).
    func atlases(for manifest: PetCharacterManifest, in folder: URL) throws(PetCharacterError) -> [String: SpriteAtlas] {
        if let cached = sprites[manifest.id] { return cached }
        guard let clips = manifest.clips, !clips.isEmpty else { throw .missingFile }
        var result: [String: SpriteAtlas] = [:]
        for (name, clip) in clips {
            let url = folder.appending(path: clip.file)
            guard let size = (try? FileManager.default.attributesOfItem(atPath: url.path(percentEncoded: false)))?[.size] as? Int
            else { throw .missingFile }
            guard size <= PetCharacterManifest.maxBytes else { throw .tooLarge }
            guard clip.frames > 0, clip.fps > 0, let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateImageAtIndex(source, 0, nil), image.width % clip.frames == 0
            else { throw .badClip(name) }
            result[name] = SpriteAtlas(image: image, frameSize: CGSize(width: image.width / clip.frames, height: image.height),
                                       frameCount: clip.frames)
        }
        for clipName in (manifest.spriteStates ?? [:]).values where result[clipName] == nil { throw .badClip(clipName) }
        loads += 1
        sprites[manifest.id] = result
        return result
    }

    /// A skin for any kind of character (desktop and notch each get their own; files are shared).
    func skin(for manifest: PetCharacterManifest, in folder: URL) throws(PetCharacterError) -> any PetSkin {
        if manifest.isSprites { return SpritePetSkin(manifest: manifest, atlases: try atlases(for: manifest, in: folder)) }
        return RivePetSkin(manifest: manifest, file: try file(for: manifest, in: folder))
    }

    func release(_ id: String) {
        files[id] = nil
        sprites[id] = nil
    }
    var cachedCount: Int { files.count + sprites.count }
}

// MARK: Skin

/// What the vector rig hands its state to when a character is attached.
@MainActor
protocol PetSkin: AnyObject {
    var view: NSView { get }
    var characterID: String { get }
    func apply(_ state: PetModel.State, reduceMotion: Bool)
    func perform(_ action: String)
    func setFacing(_ facing: PetFacing)
    func setVisible(_ visible: Bool)
}

/// A Rive character as the pet's skin, with the vector rig's energy rule:
/// only a pet that's really moving renders continuously (walking, running,
/// being dragged, at 30 fps). Any change of state or action plays a short
/// burst (`settle`), then the character holds its frame, so idle and
/// sleeping cost nothing between gestures (measured: an always-playing
/// character cost ~14 % CPU). Nothing renders while hidden or with Reduce Motion.
@MainActor
final class RivePetSkin: PetSkin {
    let manifest: PetCharacterManifest
    let viewModel: RiveViewModel
    let view: NSView
    private(set) var state: PetModel.State?
    private(set) var applied: [String] = []
    private var visible = true
    private var reduceMotion = false
    private var settleTask: Task<Void, Never>?
    /// How long a change plays before the character holds still.
    let settle: Duration
    /// Rendering right now (tests, diagnostics).
    private(set) var isPlaying = false
    var characterID: String { manifest.id }

    init(manifest: PetCharacterManifest, file: RiveFile, settle: Duration = .milliseconds(2500)) {
        self.manifest = manifest
        self.settle = settle
        viewModel = RiveViewModel(RiveModel(riveFile: file), stateMachineName: manifest.stateMachine, fit: .contain,
                                  alignment: .bottomCenter, autoPlay: false, artboardName: manifest.artboard)
        viewModel.setPreferredFramesPerSecond(preferredFramesPerSecond: 30)
        let riveView = viewModel.createRiveView()
        riveView.wantsLayer = true
        // Still until a visible state arrives (a hidden companion's copy never renders).
        riveView.isPaused = true
        riveView.enableSetNeedsDisplay = true
        view = riveView
    }

    func apply(_ newState: PetModel.State, reduceMotion newReduce: Bool) {
        reduceMotion = newReduce
        if newState != state {
            // Bool inputs other states use are switched off first, so states never stack.
            for (other, actions) in manifest.states where other != newState.rawValue {
                for action in actions where action.kind == .bool { set(InputAction(input: action.input, kind: .bool, value: 0)) }
            }
            manifest.states[newState.rawValue]?.forEach(set)
            state = newState
        }
        updatePlayback(burst: true)
    }

    func perform(_ action: String) {
        guard !reduceMotion, let inputs = manifest.actions[action] else { return }
        inputs.forEach(set)
        updatePlayback(burst: true)
    }

    func setFacing(_ facing: PetFacing) {
        let mirrored = (facing == .left) == manifest.facesRight
        view.layer?.setAffineTransform(mirrored ? CGAffineTransform(scaleX: -1, y: 1) : .identity)
    }

    func setVisible(_ newVisible: Bool) {
        visible = newVisible
        updatePlayback()
    }

    /// Continuous for movement; a burst for a change; otherwise held still.
    static func keepsMoving(_ state: PetModel.State?) -> Bool { state == .walking || state == .running || state == .dragged }

    private func updatePlayback(burst: Bool = false) {
        settleTask?.cancel()
        settleTask = nil
        guard visible, !reduceMotion, let state, state != .hidden else { return pause() }
        play()
        guard !Self.keepsMoving(state), burst else { return Self.keepsMoving(state) ? () : pause() }
        settleTask = Task { [weak self, settle] in
            try? await Task.sleep(for: settle)
            guard !Task.isCancelled, let self, !Self.keepsMoving(self.state) else { return }
            self.pause()
        }
    }

    private func play() {
        guard !isPlaying else { return }
        isPlaying = true
        if let mtk = view as? MTKView {
            mtk.enableSetNeedsDisplay = false
            mtk.isPaused = false
        }
        viewModel.play()
    }

    /// Rive's pause stops drawing, but MetalKit's display link keeps ticking
    /// (measured: ~0.5 % CPU with nothing on screen), so the view pauses too.
    private func pause() {
        guard isPlaying else { return }
        isPlaying = false
        viewModel.pause()
        if let mtk = view as? MTKView {
            mtk.isPaused = true
            mtk.enableSetNeedsDisplay = true  // on-demand: MetalKit drops its display link
        }
    }

    /// The display link (tests, diagnostics): running only while playing.
    var displayLinkRunning: Bool { !((view as? MTKView)?.isPaused ?? true) }

    typealias InputAction = PetCharacterManifest.InputAction

    private func set(_ action: InputAction) {
        applied.append("\(action.input)=\(action.kind == .trigger ? "fire" : String(action.value ?? 1))")
        if applied.count > 50 { applied.removeFirst(applied.count - 50) }
        switch action.kind {
        case .trigger: viewModel.triggerInput(action.input)
        case .bool: viewModel.setInput(action.input, value: (action.value ?? 1) != 0)
        case .number: viewModel.setInput(action.input, value: action.value ?? 0)
        }
    }
}
