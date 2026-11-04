import AppKit
import Foundation
import SwiftUI
@testable import Orbit

/// Minimal widget for registry, layout and lifecycle tests.
@MainActor
final class FakeWidget: DashboardWidget {
    let metadata: WidgetMetadata
    var state = WidgetState.ready
    var statusNote: WidgetNote?
    var stateAction: WidgetAction?
    private(set) var starts = 0
    private(set) var stops = 0

    init(_ id: WidgetID, presentations: Set<WidgetPresentation> = [.compact],
         sectionPresentation: WidgetPresentation = .compact,
         enabledByDefault: Bool = true, category: WidgetCategory = .general) {
        metadata = WidgetMetadata(
            id: id, title: id, description: "Test widget \(id)", symbol: "circle",
            category: category, availability: .live, presentations: presentations,
            sectionPresentation: sectionPresentation, isEnabledByDefault: enabledByDefault)
    }

    func start() { starts += 1 }
    func stop() { stops += 1 }
    func content(_ presentation: WidgetPresentation) -> AnyView { AnyView(EmptyView()) }
}

/// In-memory layout storage. Tests never touch UserDefaults: cfprefsd writes
/// suite plists to ~/Library/Preferences lazily, even after cleanup.
final class MemoryLayoutStorage {
    var data: Data?
    var store: WidgetLayoutStore { WidgetLayoutStore(read: { self.data }, write: { self.data = $0 }) }
}

/// A fresh folder under the system temp directory; call `cleanup()` when done.
struct TemporaryDirectory {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "orbit-tests-\(UUID().uuidString)", directoryHint: .isDirectory)

    init() { try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }

    func file<Value>(_ name: String) -> JSONFile<Value> { JSONFile(url: url.appending(path: name)) }
    func cleanup() { try? FileManager.default.removeItem(at: url) }
}

@MainActor
func makeBuiltInRegistry(_ temp: TemporaryDirectory) -> WidgetRegistry {
    WidgetRegistry.builtIn(dataDirectory: temp.url, projectsRoot: temp.url.appending(path: "projects"),
                           perform: { _ in }, didLaunch: {})
}

/// A tiny real PNG.
func samplePNG() -> Data { sampleImage(.png) }

/// A real image of the given size and format; `seed` makes the pixels (and so the bytes) differ.
func sampleImage(_ type: NSBitmapImageRep.FileType, width: Int = 4, height: Int = 4, seed: UInt8 = 0) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    if let pixels = rep.bitmapData {
        for index in 0..<(rep.bytesPerRow * height) { pixels[index] = UInt8(truncatingIfNeeded: index) &+ seed }
    }
    return rep.representation(using: type, properties: [:])!
}

// MARK: Rendering (ImageRenderer pixel checks)

struct Bitmap {
    let width: Int
    let height: Int
    let pixels: [UInt8]

    /// Brightness 0…255 at (x, y), y measured from the top.
    func brightness(_ x: Int, _ y: Int) -> Double {
        let i = (y * width + x) * 4
        return (Double(pixels[i]) + Double(pixels[i + 1]) + Double(pixels[i + 2])) / 3
    }
}

/// A view rendered at 1× on Orbit's dark dashboard background.
@MainActor
func render<V: View>(_ view: V, size: CGSize, scheme: ColorScheme = .dark) -> Bitmap? {
    let renderer = ImageRenderer(content: view
        .frame(width: size.width, height: size.height)
        .background(Color.black)
        .environment(\.colorScheme, scheme))
    renderer.scale = 1
    guard let image = renderer.cgImage else { return nil }
    var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                  bytesPerRow: image.width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return Bitmap(width: image.width, height: image.height, pixels: pixels)
}
