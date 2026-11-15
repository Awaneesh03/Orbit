import AppKit
import CoreImage
import Vision

// The pet's look (Milestone 7): a preset coat for a cat or a dog, or colours
// taken from the user's own photo. The photo is read once, on this Mac
// (Vision lifts the animal from the background), and only two colours are
// kept; the photo itself is never stored, copied or sent anywhere.

/// What preferences.json keeps about the pet's look.
struct PetLook: Codable, Equatable, Sendable {
    /// A preset id (`PetAppearance.presets`), or "photo".
    var coat = "ginger"
    /// Only with coat "photo": hex colours from the photo, and the species chosen for it.
    var photoPrimary: String?
    var photoSecondary: String?
    var photoSpecies = PetAppearance.Species.cat
    /// The character's id (Milestone 10): a bundled or installed character, or
    /// `builtIn` for Orbit's own illustrated pet. Default: the CC0 tabby.
    var character: String? = PetLook.defaultCharacter
    static let builtIn = "builtin"
    static let defaultCharacter = "pzuh-cat"
    /// What you call your pet (shown in accessibility labels and Settings).
    var name = ""
    var behavior = PetBehavior()
    /// List test (non-production) characters in Settings.
    var showTestCharacters = false
    /// 2: Settings chooses the character first (10.1). Files without it are migrated once.
    var selectionVersion = PetLook.currentSelectionVersion
    static let currentSelectionVersion = 2

    init(coat: String = "ginger", photoPrimary: String? = nil, photoSecondary: String? = nil,
         photoSpecies: PetAppearance.Species = .cat) {
        self.coat = coat
        self.photoPrimary = photoPrimary
        self.photoSecondary = photoSecondary
        self.photoSpecies = photoSpecies
    }

    /// Tolerant: a missing or invalid field keeps its default, so a newer field never resets the rest.
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        coat = (try? c.decode(String.self, forKey: .coat)) ?? "ginger"
        photoPrimary = try? c.decode(String.self, forKey: .photoPrimary)
        photoSecondary = try? c.decode(String.self, forKey: .photoSecondary)
        photoSpecies = (try? c.decode(PetAppearance.Species.self, forKey: .photoSpecies)) ?? .cat
        character = (try? c.decode(String.self, forKey: .character)) ?? Self.defaultCharacter
        name = String(((try? c.decode(String.self, forKey: .name)) ?? "").prefix(40))
        behavior = (try? c.decode(PetBehavior.self, forKey: .behavior)) ?? PetBehavior()
        showTestCharacters = (try? c.decode(Bool.self, forKey: .showTestCharacters)) ?? false
        let fileVersion = (try? c.decode(Int.self, forKey: .selectionVersion)) ?? 1
        selectionVersion = Self.currentSelectionVersion
        // 10.0 offered dog coats in a picker that only styled the hidden illustrated pet, while the
        // default Tabby was drawn: a dog coat chosen then meant "a dog". Honour it once.
        if fileVersion < 2, character == Self.defaultCharacter, PetAppearance.preset(coat)?.species == .dog {
            character = "pzuh-dog"
        }
    }

    var appearance: PetAppearance {
        if coat == "photo", let primary = photoPrimary.flatMap(PetColor.init(hex:)),
           let secondary = photoSecondary.flatMap(PetColor.init(hex:)) {
            return PetPhotoPalette.appearance(primary: primary, secondary: secondary, species: photoSpecies)
        }
        return PetAppearance.preset(coat) ?? .orbit
    }
}

extension PetColor {
    init?(hex: String) {
        let digits = hex.hasPrefix("#") ? String(hex.dropFirst()) : hex
        guard digits.count == 6, let value = UInt32(digits, radix: 16) else { return nil }
        self.init(red: CGFloat((value >> 16) & 0xFF) / 255, green: CGFloat((value >> 8) & 0xFF) / 255, blue: CGFloat(value & 0xFF) / 255)
    }

    var hex: String {
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    var luminance: CGFloat { 0.2126 * red + 0.7152 * green + 0.0722 * blue }
}

enum PetPhotoPalette {
    /// The coat from sampled fur colours: the typical colour (the middle of
    /// the brightness range, so shadows and highlights don't skew it) and the
    /// light markings (the brightest sixth), when they really differ.
    static func colors(from pixels: [PetColor]) -> (primary: PetColor, secondary: PetColor)? {
        guard pixels.count >= 16 else { return nil }
        let sorted = pixels.sorted { $0.luminance < $1.luminance }
        func average(_ slice: ArraySlice<PetColor>) -> PetColor {
            let n = CGFloat(slice.count)
            return PetColor(red: slice.reduce(0) { $0 + $1.red } / n, green: slice.reduce(0) { $0 + $1.green } / n,
                            blue: slice.reduce(0) { $0 + $1.blue } / n)
        }
        let primary = average(sorted[(sorted.count / 5) ..< (sorted.count * 4 / 5)])
        let bright = average(sorted[(sorted.count * 5 / 6)...])
        let secondary = bright.luminance - primary.luminance > 0.15 ? bright : primary.lighter(0.55)
        return (primary, secondary)
    }

    static func appearance(primary: PetColor, secondary: PetColor, species: PetAppearance.Species) -> PetAppearance {
        let base = species == .dog ? PetAppearance.preset("golden")! : .orbit
        var look = base
        look.primary = primary
        look.secondary = secondary
        look.markings = secondary.luminance - primary.luminance > 0.25 ? [.muzzle, .bib, .socks] : [.muzzle]
        return look
    }

    /// Fur pixels from a photo: the foreground animal if Vision finds one,
    /// else the middle of the picture; sampled small (64 px), opaque pixels only.
    static func pixels(from image: CGImage) -> [PetColor] {
        var subject = CIImage(cgImage: image)
        let request = VNGenerateForegroundInstanceMaskRequest()
        let handler = VNImageRequestHandler(cgImage: image)
        if (try? handler.perform([request])) != nil, let result = request.results?.first,
           let masked = try? result.generateMaskedImage(ofInstances: result.allInstances, from: handler, croppedToInstancesExtent: true) {
            subject = CIImage(cvPixelBuffer: masked)
        } else {
            let e = subject.extent
            subject = subject.cropped(to: e.insetBy(dx: e.width * 0.2, dy: e.height * 0.2))
        }
        let side = 64
        let scale = CGFloat(side) / max(subject.extent.width, subject.extent.height, 1)
        let small = subject.transformed(by: CGAffineTransform(translationX: -subject.extent.minX, y: -subject.extent.minY))
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        var bytes = [UInt8](repeating: 0, count: side * side * 4)
        CIContext(options: [.useSoftwareRenderer: false]).render(
            small, toBitmap: &bytes, rowBytes: side * 4, bounds: CGRect(x: 0, y: 0, width: side, height: side),
            format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return stride(from: 0, to: bytes.count, by: 4).compactMap { i in
            guard bytes[i + 3] > 200 else { return nil }  // background (or outside the image): skipped
            let a = CGFloat(bytes[i + 3]) / 255  // premultiplied
            return PetColor(red: CGFloat(bytes[i]) / 255 / a, green: CGFloat(bytes[i + 1]) / 255 / a, blue: CGFloat(bytes[i + 2]) / 255 / a)
        }
    }

    /// Asks for a photo (the system's open panel) and returns its look. Runs
    /// the analysis off the main thread; nil if cancelled or nothing usable.
    @MainActor
    static func chooseLook(species: PetAppearance.Species) async -> PetLook? {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.message = "Choose a photo of your pet. Orbit takes its colours on this Mac and keeps only those."
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let colors = await Task.detached(priority: .userInitiated) { () -> (PetColor, PetColor)? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                              kCGImageSourceThumbnailMaxPixelSize: 768,
                                                                              kCGImageSourceCreateThumbnailWithTransform: true] as CFDictionary)
            else { return nil }
            return colors(from: pixels(from: image)).map { ($0.primary, $0.secondary) }
        }.value
        guard let (primary, secondary) = colors else { return nil }
        return PetLook(coat: "photo", photoPrimary: primary.hex, photoSecondary: secondary.hex, photoSpecies: species)
    }
}
