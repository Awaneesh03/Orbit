import AppKit
import ImageIO

/// Off-main-actor image decoding for the Vault. ImageIO downsamples while
/// decoding (no full-resolution bitmap for a thumbnail), and the result is
/// decoded up front so drawing on the main thread doesn't decode lazily.
enum VaultImages {
    /// Thumbnails: the grid cells are 74×48 pt.
    static let thumbnailPixels = 240
    /// Previews: at least twice the preview's on-screen size; smaller images
    /// are shown at full resolution. The stored file is never changed.
    static let previewPixels = 2048

    /// nil if the file is missing, unreadable or not an image. Not started if
    /// the calling task is already cancelled.
    static func image(at url: URL, maxPixelSize: Int) async -> CGImage? {
        let work = Task.detached(priority: .userInitiated) { () -> CGImage? in
            guard !Task.isCancelled else { return nil }
            return decode(url, maxPixelSize: maxPixelSize)
        }
        return await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
    }

    static func decode(_ url: URL, maxPixelSize: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [kCGImageSourceShouldCache: false] as CFDictionary)
        else { return nil }
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary)
    }

    /// Approximate memory of a decoded image.
    static func cost(of image: CGImage) -> Int { image.bytesPerRow * image.height }
}

/// Least-recently-used thumbnails, bounded by decoded bytes. Main actor only.
@MainActor
final class ThumbnailCache {
    /// 24 MB holds about 160 typical 240 px screenshot thumbnails.
    static let defaultCostLimit = 24 * 1024 * 1024

    let costLimit: Int
    private(set) var totalCost = 0
    private var entries: [UUID: (image: NSImage, cost: Int)] = [:]
    /// Least recently used first. ponytail: O(n) reordering; fine for the
    /// ~200 entries the limit allows.
    private var order: [UUID] = []

    init(costLimit: Int = defaultCostLimit) {
        self.costLimit = costLimit
    }

    var count: Int { entries.count }

    func image(for id: UUID) -> NSImage? {
        guard let entry = entries[id] else { return nil }
        touch(id)
        return entry.image
    }

    func insert(_ image: NSImage, cost: Int, for id: UUID) {
        remove(id)
        guard cost <= costLimit else { return }  // never let one image flush everything
        entries[id] = (image, cost)
        order.append(id)
        totalCost += cost
        while totalCost > costLimit, let oldest = order.first { remove(oldest) }
    }

    func remove(_ id: UUID) {
        guard let entry = entries.removeValue(forKey: id) else { return }
        totalCost -= entry.cost
        order.removeAll { $0 == id }
    }

    func removeAll() {
        entries = [:]
        order = []
        totalCost = 0
    }

    private func touch(_ id: UUID) {
        order.removeAll { $0 == id }
        order.append(id)
    }
}
