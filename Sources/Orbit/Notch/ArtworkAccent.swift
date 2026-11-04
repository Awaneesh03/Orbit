import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// A calm accent colour taken from the artwork: the average colour of a
/// small copy (Core Image's area average), then held within a band of
/// saturation and brightness so it's never harsh, muddy or unreadable on
/// Orbit's dark glass. Greyish artwork gets none (the neutral look stays).
struct ArtworkAccent: Equatable, Sendable {
    let hue: Double
    let saturation: Double
    let brightness: Double

    static let saturationRange = 0.35 ... 0.65
    static let brightnessRange = 0.62 ... 0.85
    /// Below this the artwork is essentially grey: no accent.
    static let minimumSaturation = 0.08
    /// The surface tint over the black glass.
    static let tintOpacity = 0.18
    /// Larger artwork is shrunk to this before averaging.
    static let analysisSize: CGFloat = 64

    var color: Color { Color(hue: hue, saturation: saturation, brightness: brightness) }

    /// From an average colour (sRGB, 0…1), or nil for near-grey.
    static func clamped(red: Double, green: Double, blue: Double) -> ArtworkAccent? {
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        NSColor(srgbRed: red, green: green, blue: blue, alpha: 1).getHue(&hue, saturation: &saturation,
                                                                          brightness: &brightness, alpha: &alpha)
        guard Double(saturation) >= minimumSaturation else { return nil }
        return ArtworkAccent(hue: Double(hue),
                             saturation: min(max(Double(saturation), saturationRange.lowerBound), saturationRange.upperBound),
                             brightness: min(max(Double(brightness), brightnessRange.lowerBound), brightnessRange.upperBound))
    }

    /// The artwork's accent; runs anywhere (callers keep it off the main thread).
    static func extract(from image: CGImage) -> ArtworkAccent? {
        guard let rgb = averageColor(image) else { return nil }
        return clamped(red: rgb.red, green: rgb.green, blue: rgb.blue)
    }

    static func averageColor(_ image: CGImage) -> (red: Double, green: Double, blue: Double)? {
        let input = CIImage(cgImage: image)
        let longest = max(input.extent.width, input.extent.height)
        guard longest > 0 else { return nil }
        let scale = min(1, analysisSize / longest)
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let filter = CIFilter.areaAverage()
        filter.inputImage = small
        filter.extent = small.extent
        guard let output = filter.outputImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else { return nil }
        var pixel = [UInt8](repeating: 0, count: 4)
        // A short-lived context on the CPU renderer, caches cleared after: a
        // shared one kept ~40 MB more memory for the rest of the session, for
        // work that happens once per new thumbnail.
        autoreleasepool {
            let context = CIContext(options: [.useSoftwareRenderer: true, .cacheIntermediates: false])
            context.render(output, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                           format: .RGBA8, colorSpace: space)
            context.clearCaches()
        }
        return (Double(pixel[0]) / 255, Double(pixel[1]) / 255, Double(pixel[2]) / 255)
    }
}
