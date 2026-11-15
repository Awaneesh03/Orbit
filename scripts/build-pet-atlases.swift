// Builds Orbit Pet sprite atlases from the CC0 "Cat & Dog Free Sprites" by pzUH
// (https://opengameart.org/content/cat-dog-free-sprites). Run once by hand:
//   swift scripts/build-pet-atlases.swift <extracted png folder> Resources/Pets
// For each animal: one shared crop (so frames never jump), scaled to 240 px
// tall, one horizontal strip per clip. "sleep" is made here (CC0 permits
// modification): the lounging Slide pose with its open mouth painted closed.
import AppKit
import CoreGraphics

let source = URL(filePath: CommandLine.arguments[1])
let output = URL(filePath: CommandLine.arguments[2])
let clips: [(name: String, from: String, frames: [Int])] = [
    ("idle", "Idle", Array(1...10)), ("walk", "Walk", Array(1...10)), ("run", "Run", Array(1...8)),
    ("jump", "Jump", Array(1...8)), ("fall", "Fall", Array(1...8)), ("sit", "Slide", [3, 4, 5]),
]
let height = 200.0  // the pet is at most 80 pt tall (160 px on Retina): headroom without waste

func load(_ url: URL) -> CGImage {
    let image = NSImage(contentsOf: url)!
    return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
}

func rgba(_ image: CGImage) -> (CGContext, UnsafeMutablePointer<UInt8>) {
    let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return (context, context.data!.assumingMemoryBound(to: UInt8.self))
}

/// Opaque bounds in CG coordinates (origin bottom-left).
func bounds(_ image: CGImage) -> CGRect {
    let (context, px) = rgba(image)  // the context owns the pixels: keep it alive while reading
    defer { withExtendedLifetime(context) {} }
    var minX = image.width, minY = image.height, maxX = 0, maxY = 0
    for y in 0 ..< image.height { for x in 0 ..< image.width where px[(y * image.width + x) * 4 + 3] > 8 {
        minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
    } }
    // Context rows run top to bottom in memory: flip to CG coordinates.
    return CGRect(x: minX, y: image.height - 1 - maxY, width: maxX - minX + 1, height: maxY - minY + 1)
}

/// The Slide pose with a closed, sleeping mouth: the tongue and open mouth
/// (pink/dark pixels under the nose) covered with the muzzle colour, and a
/// small closed-mouth line drawn in the outline colour.
func sleeping(_ image: CGImage) -> CGImage {
    let (context, px) = rgba(image)
    let w = image.width, h = image.height
    var tongue: (minX: Int, minY: Int, maxX: Int, maxY: Int)?
    for row in 0 ..< h { for x in 0 ..< w {
        let i = (row * w + x) * 4
        let (r, g, b, a) = (Int(px[i]), Int(px[i + 1]), Int(px[i + 2]), Int(px[i + 3]))
        guard a > 200, r > 200, g < 150, b > 110, b < 190 else { continue }  // tongue pink
        let t = tongue ?? (x, row, x, row)
        tongue = (min(t.minX, x), min(t.minY, row), max(t.maxX, x), max(t.maxY, row))
    } }
    guard var t = tongue else { return image }
    // The largest pink blob under the nose is the tongue; widen to cover the mouth's dark rim.
    t = (t.minX - 8, t.minY - 7, t.maxX + 8, t.maxY + 5)
    // The muzzle colour beside the mouth (above it is the nose).
    let sampleRow = (t.minY + t.maxY) / 2, sampleX = max(0, t.minX - 5)
    let s = (sampleRow * w + sampleX) * 4
    let muzzle = CGColor(srgbRed: CGFloat(px[s]) / 255, green: CGFloat(px[s + 1]) / 255, blue: CGFloat(px[s + 2]) / 255, alpha: 1)
    let rect = CGRect(x: t.minX, y: h - 1 - t.maxY, width: t.maxX - t.minX, height: t.maxY - t.minY)
    context.setFillColor(muzzle)
    context.fillEllipse(in: rect)
    context.setStrokeColor(CGColor(srgbRed: 0.08, green: 0.06, blue: 0.06, alpha: 1))
    context.setLineWidth(4)
    context.setLineCap(.round)
    let mid = CGPoint(x: rect.midX, y: rect.maxY - rect.height * 0.25)
    context.move(to: CGPoint(x: mid.x - rect.width * 0.22, y: mid.y))
    context.addQuadCurve(to: CGPoint(x: mid.x + rect.width * 0.22, y: mid.y), control: CGPoint(x: mid.x, y: mid.y - 8))
    context.strokePath()
    return context.makeImage()!
}

for (animal, id) in [("cat", "pzuh-cat"), ("dog", "pzuh-dog")] {
    var frames: [String: [CGImage]] = [:]
    for clip in clips {
        frames[clip.name] = clip.frames.map { load(source.appending(path: "\(animal)/\(clip.from) (\($0)).png")) }
    }
    frames["sleep"] = [sleeping(load(source.appending(path: "\(animal)/Slide (5).png")))]
    // One crop for every clip of this animal, so switching clips never shifts the character.
    let crop = frames.values.joined().map(bounds).reduce(CGRect.null) { $0.union($1) }.insetBy(dx: -4, dy: -4)
    let scale = height / crop.height
    let cell = CGSize(width: (crop.width * scale).rounded(.up), height: height)
    let folder = output.appending(path: id, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, images) in frames {
        let strip = CGContext(data: nil, width: Int(cell.width) * images.count, height: Int(cell.height), bitsPerComponent: 8, bytesPerRow: 0,
                              space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        strip.interpolationQuality = .high
        for (index, image) in images.enumerated() {
            let full = CGRect(x: -crop.minX * scale + Double(index) * cell.width, y: -crop.minY * scale,
                              width: Double(image.width) * scale, height: Double(image.height) * scale)
            strip.saveGState()
            strip.clip(to: CGRect(x: Double(index) * cell.width, y: 0, width: cell.width, height: cell.height))
            strip.draw(image, in: full)
            strip.restoreGState()
        }
        let png = NSBitmapImageRep(cgImage: strip.makeImage()!).representation(using: .png, properties: [:])!
        try png.write(to: folder.appending(path: "\(name).png"))
        print(id, name, images.count, "frames", Int(cell.width), "x", Int(cell.height), png.count / 1024, "KB")
    }
}
