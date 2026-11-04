import AppKit
import Testing
@testable import Orbit

/// A private, uniquely named pasteboard: never the user's clipboard.
private func withPasteboard(_ body: (NSPasteboard) throws -> Void) rethrows {
    let pasteboard = NSPasteboard(name: .init("orbit.tests.\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    pasteboard.clearContents()
    try body(pasteboard)
}

private func fileItem(_ url: URL) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setString(url.absoluteString, forType: .fileURL)
    return item
}

private func dataItem(_ data: Data, _ type: NSPasteboard.PasteboardType) -> NSPasteboardItem {
    let item = NSPasteboardItem()
    item.setData(data, forType: type)
    return item
}

@Test func acceptsImageFilesAndPrefersTheFile() {
    withPasteboard { pasteboard in
        let url = URL(filePath: "/tmp/Screenshot 2026-10-31.png")
        let item = fileItem(url)
        item.setData(samplePNG(), forType: .png)  // the file wins over data in the same item
        pasteboard.writeObjects([item])
        #expect(ScreenshotDrag.containsImage(pasteboard))
        #expect(ScreenshotDrag.items(from: pasteboard).map(\.kind) == ["file(.png)"])
    }
}

@Test func acceptsRawImageData() {
    withPasteboard { pasteboard in
        pasteboard.writeObjects([dataItem(samplePNG(), .png), dataItem(sampleImage(.tiff), .tiff)])
        #expect(ScreenshotDrag.containsImage(pasteboard))
        let kinds = ScreenshotDrag.items(from: pasteboard).map(\.kind)
        #expect(kinds.count == 2)
        #expect(kinds.allSatisfy { $0.hasPrefix("data(") })
    }
}

@Test func ignoresTextAndNonImageFiles() {
    withPasteboard { pasteboard in
        pasteboard.setString("hello", forType: .string)
        #expect(!ScreenshotDrag.containsImage(pasteboard))
        #expect(ScreenshotDrag.items(from: pasteboard).isEmpty)
    }
    withPasteboard { pasteboard in
        pasteboard.writeObjects([fileItem(URL(filePath: "/tmp/notes.txt"))])
        #expect(!ScreenshotDrag.containsImage(pasteboard))
        #expect(ScreenshotDrag.items(from: pasteboard).isEmpty)
    }
}

@Test func registersForFilesImagesAndPromises() {
    let types = Set(ScreenshotDrag.draggedTypes.map(\.rawValue))
    #expect(types.isSuperset(of: ["public.file-url", "public.png", "public.tiff", "public.jpeg", "public.heic"]))
    #expect(types.isSuperset(of: NSFilePromiseReceiver.readableDraggedTypes))
}

@Test func imageFileDetectionUsesTheExtensionOnly() {
    #expect(ScreenshotDrag.isImageFile(URL(filePath: "/x/Shot.PNG")))
    #expect(ScreenshotDrag.isImageFile(URL(filePath: "/x/a.heic")))
    #expect(!ScreenshotDrag.isImageFile(URL(filePath: "/x/a.pdf")))
    #expect(!ScreenshotDrag.isImageFile(URL(filePath: "/x/folder")))
}
