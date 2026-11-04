import AppKit
import Testing
@testable import Orbit

private func files(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
}

// MARK: Import service

@Test func validPNGIsStoredByteForByteWithMetadata() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    let png = sampleImage(.png, width: 8, height: 5)

    let result = try vault.importImage(png, source: "Drag and drop")
    guard case .added(let item) = result else {
        Issue.record("expected a new item, got \(result)")
        return
    }
    #expect(item.pixelWidth == 8 && item.pixelHeight == 5)
    #expect(item.format == "public.png")
    #expect(item.byteCount == png.count)
    #expect(item.sha256?.count == 64)
    #expect(item.fileName.hasSuffix(".png"))
    #expect(try Data(contentsOf: vault.url(for: item)) == png)
    #expect(VaultImages.decode(vault.url(for: item), maxPixelSize: VaultImages.thumbnailPixels) != nil)  // preview

    let reloaded = try ScreenshotVault(directory: directory)
    #expect(reloaded.items == [item])  // metadata persisted
}

@Test func tiffIsStoredAsPNGAndJPEGIsKept() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var vault = try ScreenshotVault(directory: temp.url.appending(path: "Vault"))
    let tiff = try vault.importImage(sampleImage(.tiff, width: 6, height: 3), source: "Drag and drop").item
    #expect(tiff.format == "public.png")
    #expect(tiff.fileName.hasSuffix(".png"))
    #expect(tiff.pixelWidth == 6 && tiff.pixelHeight == 3)
    let jpeg = try vault.importImage(sampleImage(.jpeg, seed: 9), source: "Drag and drop").item
    #expect(jpeg.format == "public.jpeg")
    #expect(jpeg.fileName.hasSuffix(".jpeg"))
}

@Test func unsupportedFormatsAreRejectedWithoutWriting() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    #expect(throws: VaultError.unsupportedFormat("gif")) {
        try vault.importImage(sampleImage(.gif), source: "Drag and drop")
    }
    #expect(vault.items.isEmpty)
    #expect(files(in: directory).isEmpty)
}

@Test func invalidDataIsRejected() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var vault = try ScreenshotVault(directory: temp.url.appending(path: "Vault"))
    #expect(throws: VaultError.notAnImage) { try vault.importImage(Data("not an image".utf8), source: "x") }
    #expect(throws: VaultError.notAnImage) { try vault.importImage(Data(), source: "x") }
    // Truncated files (e.g. an interrupted transfer) are rejected, not stored half-blank.
    for type in [NSBitmapImageRep.FileType.png, .jpeg, .tiff] {
        let full = sampleImage(type, width: 64, height: 64)
        #expect(throws: VaultError.notAnImage, "\(type)") { try vault.importImage(full.prefix(full.count / 2), source: "x") }
        #expect(throws: VaultError.notAnImage, "\(type)") { try vault.importImage(full.dropLast(8), source: "x") }
    }
    let png = sampleImage(.png, width: 64, height: 64)
    #expect(throws: VaultError.tooLarge) { try ScreenshotVault.prepare(png, maxBytes: 16) }
    #expect(vault.items.isEmpty)
}

@Test func fileImportNeverTouchesTheOriginal() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let original = temp.url.appending(path: "Screenshot 2026-10-31 at 08.30.00.png")
    let bytes = sampleImage(.png, width: 10, height: 7)
    try bytes.write(to: original)
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: original.path(percentEncoded: false))
    var vault = try ScreenshotVault(directory: temp.url.appending(path: "Vault"))

    let item = try vault.importFile(at: original).item
    #expect(item.source == original.path(percentEncoded: false))
    #expect(vault.url(for: item) != original)
    try vault.delete(item.id)
    try vault.purge(item.id)  // permanently deleting Orbit's copy doesn't touch the original either

    // Still there, same bytes, same modification date.
    #expect(try Data(contentsOf: original) == bytes)
    let attributes = try FileManager.default.attributesOfItem(atPath: original.path(percentEncoded: false))
    #expect(attributes[.modificationDate] as? Date == modified)
}

@Test func duplicatesAreDetectedWithoutWritingAgain() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let original = temp.url.appending(path: "shot.png")
    let png = sampleImage(.png, seed: 3)
    try png.write(to: original)
    var vault = try ScreenshotVault(directory: directory)

    let first = try vault.importImage(png, source: "Drag and drop")
    let again = try vault.importImage(png, source: "Drag and drop")
    let asFile = try vault.importFile(at: original)
    #expect(again == .duplicate(first.item))
    #expect(asFile == .duplicate(first.item))
    #expect(vault.items.count == 1)
    #expect(files(in: directory) == ["index.json", "library.json", first.item.fileName].sorted())
    // A different image is not a duplicate.
    guard case .added = try vault.importImage(sampleImage(.png, seed: 4), source: "x") else {
        Issue.record("a different image must be added")
        return
    }
}

@Test func failedImageWriteLeavesTheVaultUnchanged() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    let existing = try vault.importImage(sampleImage(.png, seed: 1), source: "x").item
    let before = files(in: directory)

    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path(percentEncoded: false))
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path(percentEncoded: false)) }
    #expect(throws: (any Error).self) { try vault.importImage(sampleImage(.png, seed: 2), source: "x") }

    #expect(vault.items == [existing])
    #expect(files(in: directory) == before)
    #expect(try ScreenshotVault(directory: directory).items == [existing])
}

@Test func failedIndexWriteRemovesTheNewFile() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    // Make the index impossible to write: a folder where the file should be.
    try FileManager.default.createDirectory(at: directory.appending(path: "index.json"), withIntermediateDirectories: true)

    #expect(throws: (any Error).self) { try vault.importImage(samplePNG(), source: "x") }
    #expect(vault.items.isEmpty)
    #expect(files(in: directory) == ["index.json"])  // no orphaned image, no half entry
}

@Test func clearInboxKeepsKeptItemsAndPersists() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    let keep = try vault.importImage(sampleImage(.png, seed: 5), source: "x").item
    let drop = try vault.importImage(sampleImage(.png, seed: 6), source: "x").item
    try vault.setKept(keep.id, true)
    #expect(vault.inbox.map(\.id) == [drop.id])

    #expect(try vault.clearInbox() == 1)
    #expect(vault.active.map(\.id) == [keep.id])
    #expect(vault.recentlyDeleted.map(\.id) == [drop.id])
    // Recoverable: no file is removed by Clear Inbox.
    #expect(FileManager.default.fileExists(atPath: vault.url(for: drop).path(percentEncoded: false)))
    #expect(FileManager.default.fileExists(atPath: vault.url(for: keep).path(percentEncoded: false)))
    let reloaded = try ScreenshotVault(directory: directory)
    #expect(reloaded.active.first?.isKept == true)
    #expect(reloaded.recentlyDeleted.map(\.id) == [drop.id])
}

@Test func refusesToDeleteOutsideTheVault() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let outside = temp.url.appending(path: "precious.png")
    try samplePNG().write(to: outside)
    let id = UUID()
    let tampered = [VaultItem(id: id, fileName: "../precious.png", importedAt: .now, source: "?")]
    try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save(tampered)

    var vault = try ScreenshotVault(directory: directory)
    try vault.delete(id)  // only marks the entry; no file is touched
    #expect(throws: VaultError.outsideVault) { try vault.purge(id) }
    #expect(try vault.purgeExpired(now: .now.addingTimeInterval(ScreenshotVault.retention * 2)) == 0)
    #expect(FileManager.default.fileExists(atPath: outside.path(percentEncoded: false)))
    #expect(vault.items.count == 1)
}

@Test func indexesWithoutMetadataStillLoad() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    // The Step 5 format, as already on disk for existing users.
    let legacy = #"[{"id":"FA0A47D0-504E-47E0-98A0-E9ECA66A6F94","fileName":"a.png","importedAt":800000000,"source":"Clipboard","isKept":false}]"#
    try Data(legacy.utf8).write(to: directory.appending(path: "index.json"))
    let vault = try ScreenshotVault(directory: directory)
    #expect(vault.items.count == 1)
    #expect(vault.items[0].sha256 == nil)
}

// MARK: Outbound drag export

@Test func exportIsASeparateIdenticalCopyAndTheVaultFileIsUntouched() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let original = temp.url.appending(path: "Screenshot 2026-10-31 at 8.46.04 AM.png")
    try sampleImage(.png, width: 30, height: 20).write(to: original)
    var vault = try ScreenshotVault(directory: temp.url.appending(path: "Vault"))
    let item = try vault.importFile(at: original).item
    let stored = vault.url(for: item)
    let before = try Data(contentsOf: stored)
    let exports = temp.url.appending(path: "Exports")

    let export = try vault.exportCopy(of: item, root: exports)
    #expect(export.lastPathComponent == "Screenshot 2026-10-31 at 8.46.04 AM.png")  // the original name
    #expect(export.pathExtension == "png")
    #expect(export != stored)
    #expect(try Data(contentsOf: export) == before)
    // Only the selected screenshot is exposed.
    #expect(try FileManager.default.contentsOfDirectory(atPath: export.deletingLastPathComponent().path(percentEncoded: false)) == [export.lastPathComponent])

    // Whatever the destination does (e.g. Finder moves it), the vault keeps its file.
    try FileManager.default.removeItem(at: export)
    #expect(try Data(contentsOf: stored) == before)
    #expect(vault.items == [item])
}

@Test func exportNamesFallBackToADatedName() throws {
    let item = VaultItem(id: UUID(), fileName: "X.jpeg", importedAt: Date(timeIntervalSince1970: 0),
                         source: "Clipboard")
    let name = ScreenshotVault.exportName(for: item)
    #expect(name.hasPrefix("Orbit Screenshot ") && name.hasSuffix(".jpeg"))
}

@Test func multipleAndLargeExportsAreDistinctAndOldOnesAreCleanedUp() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var vault = try ScreenshotVault(directory: temp.url.appending(path: "Vault"))
    let small = try vault.importImage(sampleImage(.png, seed: 21), source: "x").item
    let large = try vault.importImage(sampleImage(.png, width: 3000, height: 2000, seed: 22), source: "x").item
    let exports = temp.url.appending(path: "Exports")

    let a = try vault.exportCopy(of: small, root: exports)
    let b = try vault.exportCopy(of: large, root: exports)
    let c = try vault.exportCopy(of: small, root: exports)  // dragging the same one twice
    #expect(Set([a, b, c].map { $0.deletingLastPathComponent() }).count == 3)
    #expect(try Data(contentsOf: b) == Data(contentsOf: vault.url(for: large)))

    ScreenshotVault.removeExports(in: exports, olderThan: 60, now: .now.addingTimeInterval(3600))
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: exports.path(percentEncoded: false))) ?? []).isEmpty)
    #expect(FileManager.default.fileExists(atPath: vault.url(for: large).path(percentEncoded: false)))
}

@MainActor @Test func dragProviderOffersAFileOfTheRightType() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    guard case .saved(let item) = await widget.importData(sampleImage(.png, seed: 23), source: "Drag and drop") else {
        Issue.record("expected saved")
        return
    }
    let provider = widget.dragProvider(for: item)
    #expect(provider.hasItemConformingToTypeIdentifier("public.png"))
    #expect(provider.suggestedName?.hasPrefix("Orbit Screenshot") == true)
}

// MARK: Widget

@MainActor @Test func widgetReportsSavedDuplicateAndFailedImports() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    #expect(widget.state == .ready)

    let png = sampleImage(.png, seed: 7)
    guard case .saved(let item) = await widget.importData(png, source: "Drag and drop") else {
        Issue.record("expected saved")
        return
    }
    #expect(widget.selectedItem?.id == item.id)
    #expect(await widget.importData(png, source: "Drag and drop") == .duplicate(item))
    let bad = await widget.importData(Data("nope".utf8), source: "Drag and drop")
    #expect(bad == .failed("That isn't an image Orbit can read."))
    #expect(bad.isError)
    #expect(widget.items == [item])  // unchanged by the failure
    #expect(await widget.importData(sampleImage(.gif), source: "x") == .failed("GIF isn't supported. Use PNG, TIFF, JPEG or HEIC."))
}

@MainActor @Test func widgetReceivesDroppedFilesAndData() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let original = temp.url.appending(path: "Screenshot.png")
    try sampleImage(.png, seed: 11).write(to: original)
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    let outcomes = OutcomeLog()
    widget.receive([.file(original), .data(sampleImage(.tiff, seed: 12))]) { outcomes.append($0) }
    await widget.importsFinished()
    #expect(outcomes.values.map(\.message) == ["Screenshot saved to Vault", "Screenshot saved to Vault"])
    #expect(widget.items.count == 2)
    #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
}

@MainActor @Test func corruptIndexFailsOnlyTheVault() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let broken = temp.url.appending(path: "Broken")
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    try Data("nope".utf8).write(to: broken.appending(path: "index.json"))
    let widget = VaultWidget(directory: broken)
    guard case .failed = widget.state else {
        Issue.record("a corrupt index must fail this widget only")
        return
    }
    #expect(await widget.importData(samplePNG(), source: "x").isError)
    #expect(try Data(contentsOf: broken.appending(path: "index.json")) == Data("nope".utf8))
}

@MainActor
private final class OutcomeLog: @unchecked Sendable {
    private(set) var values: [VaultImportOutcome] = []
    func append(_ outcome: VaultImportOutcome) { values.append(outcome) }
}
