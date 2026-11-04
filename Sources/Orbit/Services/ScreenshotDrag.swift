import AppKit
import UniformTypeIdentifiers

/// What a drag onto the notch can carry and how Orbit reads it. Reading the
/// drag pasteboard is part of a user-initiated drop: no permission, no
/// clipboard-privacy alert, and no access to the general clipboard.
enum ScreenshotDrag {
    enum Item {
        /// An image file. Only read, never moved, modified or deleted.
        case file(URL)
        /// Image bytes (PNG, TIFF, JPEG or HEIC).
        case data(Data)
        /// A promised file, written on request into a staging folder of Orbit's own.
        case promise(NSFilePromiseReceiver)

        /// For the log: no paths or content.
        var kind: String {
            switch self {
            case .file(let url): "file(.\(url.pathExtension.lowercased()))"
            case .data(let data): "data(\(data.count) bytes)"
            case .promise: "promise"
            }
        }
    }

    static let imageDataTypes: [NSPasteboard.PasteboardType] =
        ScreenshotVault.supportedTypes.map { NSPasteboard.PasteboardType($0.identifier) }

    /// Types the notch window registers for.
    static var draggedTypes: [NSPasteboard.PasteboardType] {
        [.fileURL] + imageDataTypes + NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) }
    }

    /// True if the drag offers an image file, image data or a promised image.
    /// Looks at types and file names only; reads no file and no image bytes.
    static func containsImage(_ pasteboard: NSPasteboard) -> Bool {
        for item in pasteboard.pasteboardItems ?? [] {
            if let url = fileURL(item), isImageFile(url) { return true }
            if item.availableType(from: imageDataTypes) != nil { return true }
        }
        return !imagePromises(pasteboard).isEmpty
    }

    /// One representation per dragged item: the file (full quality) first, then
    /// image data. Promises are used only when nothing else is offered.
    static func items(from pasteboard: NSPasteboard) -> [Item] {
        var result: [Item] = []
        for item in pasteboard.pasteboardItems ?? [] {
            if let url = fileURL(item), isImageFile(url) {
                result.append(.file(url))
            } else if let type = item.availableType(from: imageDataTypes), let data = item.data(forType: type) {
                result.append(.data(data))
            }
        }
        if result.isEmpty { result = imagePromises(pasteboard).map(Item.promise) }
        return result
    }

    /// Type identifiers only, for the log.
    static func describe(_ pasteboard: NSPasteboard) -> String {
        (pasteboard.types ?? []).map(\.rawValue).joined(separator: ", ")
    }

    static func isImageFile(_ url: URL) -> Bool {
        UTType(filenameExtension: url.pathExtension)?.conforms(to: .image) == true
    }

    private static func fileURL(_ item: NSPasteboardItem) -> URL? {
        guard let string = item.string(forType: .fileURL), let url = URL(string: string), url.isFileURL else { return nil }
        return url
    }

    private static func imagePromises(_ pasteboard: NSPasteboard) -> [NSFilePromiseReceiver] {
        let receivers = pasteboard.readObjects(forClasses: [NSFilePromiseReceiver.self]) as? [NSFilePromiseReceiver] ?? []
        return receivers.filter { $0.fileTypes.contains { UTType($0)?.conforms(to: .image) == true } }
    }
}
