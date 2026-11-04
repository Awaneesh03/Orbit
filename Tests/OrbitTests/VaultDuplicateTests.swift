import AppKit
import ImageIO
import Testing
@testable import Orbit

// Duplicate detection through the path a real notch drop takes
// (`VaultWidget.receive` → serial import queue → the outcome's notice, which
// the app delegate shows). A duplicate is a byte-identical stored image
// (SHA-256 of the stored bytes); a new capture of the same screen is a new image.

@MainActor
private final class Notices: @unchecked Sendable {
    var outcomes: [VaultImportOutcome] = []
}

private func imageFiles(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? [])
        .filter { !$0.hasSuffix(".json") }
}

/// What macOS would hand over for a dropped screenshot file.
private func screenshotFile(_ temp: TemporaryDirectory, _ name: String, _ data: Data) throws -> URL {
    let url = temp.url.appending(path: name)
    try data.write(to: url)
    return url
}

@MainActor
private func drop(_ items: [ScreenshotDrag.Item], on widget: VaultWidget) async -> [VaultImportOutcome] {
    let notices = Notices()
    widget.receive(items) { notices.outcomes.append($0) }
    await widget.importsFinished()
    return notices.outcomes
}

private func heic(seed: UInt8) -> Data? {
    guard let cgImage = NSBitmapImageRep(data: sampleImage(.png, width: 32, height: 32, seed: seed))?.cgImage else { return nil }
    let data = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(data, "public.heic" as CFString, 1, nil) else { return nil }
    CGImageDestinationAddImage(destination, cgImage, nil)
    return CGImageDestinationFinalize(destination) ? data as Data : nil
}

@MainActor @Test func droppingTheSameScreenshotTwiceSaysAlreadyInYourVault() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let file = try screenshotFile(temp, "Screenshot 2026-11-02 at 12.00.02 AM.png", sampleImage(.png, width: 300, height: 200, seed: 1))
    let widget = VaultWidget(directory: directory)

    let first = await drop([.file(file)], on: widget)
    let index = try Data(contentsOf: directory.appending(path: "index.json"))
    let second = await drop([.file(file)], on: widget)

    #expect(first.map(\.notice) == ["Screenshot saved to Vault"])
    #expect(second.map(\.notice) == ["Already in your Vault"])
    #expect(second.allSatisfy { !$0.isError })
    guard case .duplicate(let existing) = second.first, case .saved(let saved) = first.first else {
        Issue.record("expected saved then duplicate, got \(first) \(second)")
        return
    }
    #expect(existing.id == saved.id)
    #expect(widget.selectedItem?.id == saved.id)  // the Vault shows the one it already has
    #expect(widget.items.count == 1 && imageFiles(in: directory).count == 1)
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == index)  // nothing written
}

@MainActor @Test func aDuplicateIsStillRecognisedAfterRelaunch() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let file = try screenshotFile(temp, "Screenshot.png", sampleImage(.png, width: 300, height: 200, seed: 2))
    _ = await drop([.file(file)], on: VaultWidget(directory: directory))
    let index = try Data(contentsOf: directory.appending(path: "index.json"))

    let relaunched = VaultWidget(directory: directory)
    _ = await relaunched.backfillHashes()  // what launch does
    #expect(await drop([.file(file)], on: relaunched).map(\.notice) == ["Already in your Vault"])
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == index)
}

@MainActor @Test func droppingAScreenshotFromRecentlyDeletedRestoresIt() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let file = try screenshotFile(temp, "Screenshot.png", sampleImage(.png, width: 300, height: 200, seed: 3))
    let widget = VaultWidget(directory: directory)
    _ = await drop([.file(file)], on: widget)
    widget.delete(widget.items[0])
    widget.showsDeleted = true

    #expect(await drop([.file(file)], on: widget).map(\.notice) == ["Restored from Recently Deleted"])
    #expect(widget.items.count == 1 && widget.deletedItems.isEmpty && !widget.showsDeleted)
    #expect(imageFiles(in: directory).count == 1)
    #expect(await drop([.file(file)], on: widget).map(\.notice) == ["Already in your Vault"])  // then a plain duplicate
}

@MainActor @Test func aMultiScreenshotDropReportsTheDuplicateAmongNewOnes() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let a = sampleImage(.png, width: 300, height: 200, seed: 4)
    let b = sampleImage(.png, width: 300, height: 200, seed: 5)
    let c = sampleImage(.jpeg, width: 300, height: 200, seed: 6)
    let widget = VaultWidget(directory: directory)
    _ = await drop([.file(try screenshotFile(temp, "a.png", a))], on: widget)

    let outcomes = await drop([.data(b), .file(try screenshotFile(temp, "a-again.png", a)), .data(c), .data(b)], on: widget)
    #expect(outcomes.map(\.notice) == ["Screenshot saved to Vault", "Already in your Vault",
                                       "Screenshot saved to Vault", "Already in your Vault"])
    #expect(widget.items.count == 3 && imageFiles(in: directory).count == 3)
}

@MainActor @Test func theSameBytesAreADuplicateWhicheverWayTheyArrive() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    let png = sampleImage(.png, width: 300, height: 200, seed: 7)

    _ = await drop([.file(try screenshotFile(temp, "shot.png", png))], on: widget)  // dragged file
    #expect(await drop([.data(png)], on: widget).map(\.notice) == ["Already in your Vault"])  // dragged image data
    widget.importPasted(png)  // the Paste button
    await widget.importsFinished()
    #expect(widget.items.count == 1)

    // Every stored format: a second copy of the same bytes is a duplicate.
    let jpeg = sampleImage(.jpeg, width: 300, height: 200, seed: 8)
    let tiff = sampleImage(.tiff, width: 300, height: 200, seed: 9)  // stored as PNG; the conversion is repeatable
    var formats: [(String, Data)] = [("jpeg", jpeg), ("tiff", tiff)]
    if let heic = heic(seed: 10) { formats.append(("heic", heic)) } else { Issue.record("HEIC encoding unavailable") }
    for (name, data) in formats {
        let outcomes = await drop([.data(data), .file(try screenshotFile(temp, "copy.\(name)", data))], on: widget)
        #expect(outcomes.map(\.notice) == ["Screenshot saved to Vault", "Already in your Vault"], "\(name)")
    }
    #expect(widget.items.count == 1 + formats.count)
}

@MainActor @Test func aNewCaptureOfTheSameScreenIsANewScreenshot() async throws {
    // The reported case: screenshots taken seconds apart (12.00.02, 12.00.08,
    // 12.00.14) differ in some pixels (clock, pointer), so they are different
    // images and each is saved.
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    let original = sampleImage(.png, width: 300, height: 200, seed: 11)
    let rep = try #require(NSBitmapImageRep(data: original))
    rep.setColor(.red, atX: 299, y: 0)  // one pixel changed, like the menu-bar clock ticking
    let recaptured = try #require(rep.representation(using: .png, properties: [:]))

    let outcomes = await drop([.file(try screenshotFile(temp, "Screenshot at 12.00.02 AM.png", original)),
                               .file(try screenshotFile(temp, "Screenshot at 12.00.08 AM.png", recaptured))], on: widget)
    #expect(outcomes.map(\.notice) == ["Screenshot saved to Vault", "Screenshot saved to Vault"])
    #expect(widget.items.count == 2)
}
