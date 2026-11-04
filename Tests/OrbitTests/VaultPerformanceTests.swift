import AppKit
import CryptoKit
import Testing
@testable import Orbit

// Stage 2 Step 2: background import, async thumbnails and previews, hash
// backfill, launch drag-copy cleanup. Lines starting "PERF" are measurements
// (wall clock, this Mac, tests running in parallel unless filtered).

private func ms(_ duration: Duration) -> String {
    let (seconds, attoseconds) = duration.components
    return String(format: "%.1f ms", Double(seconds) * 1000 + Double(attoseconds) / 1e15)
}

private func listing(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
}

private func sha(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

/// A large image, made off the main actor so it doesn't skew main-actor timings.
private func bigPNG(_ width: Int = 4000, _ height: Int = 3000, seed: UInt8 = 0) async -> Data {
    await Task.detached { sampleImage(.png, width: width, height: height, seed: seed) }.value
}

/// Random pixels: incompressible, so the PNG is as large as a busy real
/// screenshot can get (worst case for read, decode and hash).
private func noisePNG(_ width: Int, _ height: Int) async -> Data {
    await Task.detached {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8,
                                   samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                   colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        arc4random_buf(rep.bitmapData!, rep.bytesPerRow * height)
        return rep.representation(using: .png, properties: [:])!
    }.value
}

/// Measures the longest gap between main-actor ticks while `work` runs.
@MainActor
private func mainActorGaps<T>(during work: () async -> T) async -> (result: T, ticks: Int, longestGap: Duration) {
    let ticker = Task { @MainActor () -> (Int, Duration) in
        var ticks = 0
        var longest = Duration.zero
        var last = ContinuousClock.now
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(5))
            let now = ContinuousClock.now
            longest = max(longest, last.duration(to: now))
            last = now
            ticks += 1
        }
        return (ticks, longest)
    }
    let result = await work()
    ticker.cancel()
    let (ticks, longest) = await ticker.value
    return (result, ticks, longest)
}

// MARK: Import

@MainActor @Test func largeImportKeepsTheMainActorResponsive() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let png = await noisePNG(4000, 3000)
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))

    let clock = ContinuousClock()
    // What Step 1 did on the main actor for every import (measured off it here).
    let blocking = await Task.detached { ContinuousClock().measure { _ = try? ScreenshotVault.prepare(png) } }.value
    let start = clock.now
    let (outcome, ticks, gap) = await mainActorGaps { await widget.importData(png, source: "big") }
    let elapsed = start.duration(to: clock.now)
    print("PERF large import \(png.count / 1024 / 1024) MB 4000×3000 PNG: \(ms(elapsed)) total; main actor ticked \(ticks)× (every ~5 ms), longest gap \(ms(gap)); validate+decode+hash alone \(ms(blocking)), which Step 1 ran on the main actor")

    guard case .saved(let item) = outcome else {
        Issue.record("expected saved, got \(outcome)")
        return
    }
    #expect(item.pixelWidth == 4000 && item.pixelHeight == 3000 && item.byteCount == png.count)
    #expect(try Data(contentsOf: widget.vault!.url(for: item)) == png)  // byte for byte
    #expect(ticks > 0)
    #expect(gap < .milliseconds(500))
}

@MainActor @Test func queuedImportsKeepTheirOrder() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    let images = (0..<4).map { sampleImage(.png, width: 300, height: 200, seed: UInt8($0 + 60)) }
    let log = ReportLog()
    widget.receive(images.map { .data($0) }) { log.values.append($0) }
    await widget.importsFinished()

    #expect(log.values.map(\.message) == Array(repeating: "Screenshot saved to Vault", count: 4))
    let hashes = images.map(sha)
    #expect(widget.items.map(\.sha256) == hashes.reversed())  // newest first, in drop order
    #expect(log.values.compactMap { if case .saved(let item) = $0 { item.sha256 } else { nil } } == hashes)
}

@MainActor @Test func simultaneousImportsDetectDuplicatesAndKeepEveryImage() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let widget = VaultWidget(directory: directory)
    let same = sampleImage(.png, width: 800, height: 600, seed: 70)

    async let a = widget.importData(same, source: "a")
    async let b = widget.importData(same, source: "b")
    async let c = widget.importData(same, source: "c")
    let results = await [a, b, c]
    #expect(results.filter { if case .saved = $0 { true } else { false } }.count == 1)
    #expect(results.filter { if case .duplicate = $0 { true } else { false } }.count == 2)
    #expect(widget.items.count == 1)
    #expect(listing(directory).filter { $0.hasSuffix(".png") }.count == 1)

    async let d = widget.importData(sampleImage(.png, seed: 71), source: "d")
    async let e = widget.importData(sampleImage(.png, seed: 72), source: "e")
    async let f = widget.importData(sampleImage(.jpeg, seed: 73), source: "f")
    _ = await [d, e, f]
    #expect(widget.items.count == 4)
    #expect(Set(widget.items.map(\.sha256)).count == 4)
    #expect(try ScreenshotVault(directory: directory).items == widget.vault?.items)
}

@MainActor @Test func aCancelledImportWritesNothing() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let widget = VaultWidget(directory: directory)
    let png = await bigPNG(2000, 1500, seed: 74)

    let task = Task { await widget.importData(png, source: "x") }
    task.cancel()
    #expect(await task.value == .failed("Import cancelled."))
    #expect(widget.items.isEmpty)
    #expect(listing(directory).allSatisfy { !$0.hasSuffix(".png") })
    #expect(widget.feedback == nil)  // a cancellation isn't an error
    guard case .saved = await widget.importData(png, source: "x") else {
        Issue.record("the next import must still work")
        return
    }
}

@MainActor @Test func failedBackgroundWritesLeaveNoTrace() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let widget = VaultWidget(directory: directory)
    guard case .saved(let existing) = await widget.importData(sampleImage(.png, seed: 75), source: "x") else {
        Issue.record("setup import failed")
        return
    }
    let before = listing(directory)
    let path = directory.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
    let failed = await widget.importData(sampleImage(.png, seed: 76), source: "x")
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path)
    #expect(failed.isError)
    #expect(widget.items == [existing])
    #expect(listing(directory) == before)

    // Index can't be written: the new image file is removed again.
    let other = temp.url.appending(path: "Other")
    try FileManager.default.createDirectory(at: other.appending(path: "index.json"), withIntermediateDirectories: true)
    let blocked = VaultWidget(directory: other)
    #expect(await blocked.importData(sampleImage(.png, seed: 77), source: "x").isError)
    #expect(blocked.items.isEmpty)
    #expect(listing(other) == ["index.json"])
}

@MainActor @Test func backgroundImportKeepsFormatsMetadataAndOriginals() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    let original = temp.url.appending(path: "Screenshot 2026-11-02 at 09.00.00.jpg")
    let jpeg = sampleImage(.jpeg, width: 640, height: 400, seed: 78)
    try jpeg.write(to: original)
    let modified = Date(timeIntervalSince1970: 1_700_000_000)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: original.path(percentEncoded: false))

    guard case .saved(let kept) = await widget.importFile(original) else {
        Issue.record("jpeg import failed")
        return
    }
    #expect(kept.format == "public.jpeg" && kept.pixelWidth == 640 && kept.pixelHeight == 400)
    #expect(kept.source == original.path(percentEncoded: false))
    #expect(try Data(contentsOf: widget.vault!.url(for: kept)) == jpeg)
    #expect(try Data(contentsOf: original) == jpeg)
    let attributes = try FileManager.default.attributesOfItem(atPath: original.path(percentEncoded: false))
    #expect(attributes[.modificationDate] as? Date == modified)

    guard case .saved(let converted) = await widget.importData(sampleImage(.tiff, width: 50, height: 30, seed: 79), source: "x") else {
        Issue.record("tiff import failed")
        return
    }
    #expect(converted.format == "public.png" && converted.fileName.hasSuffix(".png"))

    // The 100 MB limit is checked before reading (a sparse file: no disk used).
    let huge = temp.url.appending(path: "huge.png")
    FileManager.default.createFile(atPath: huge.path(percentEncoded: false), contents: nil)
    let handle = try FileHandle(forWritingTo: huge)
    try handle.truncate(atOffset: UInt64(ScreenshotVault.maxBytes + 1))
    try handle.close()
    #expect(await widget.importFile(huge) == .failed("That image is larger than 100 MB."))
}

// MARK: Thumbnails

@MainActor @Test func thumbnailsLoadInTheBackgroundAndStaySmall() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    guard case .saved(let item) = await widget.importData(await noisePNG(2940, 1912), source: "x") else {
        Issue.record("import failed")
        return
    }
    #expect(widget.thumbnail(item) == nil)  // nothing decoded on the main actor
    let revision = widget.thumbnailRevision
    let elapsed = await ContinuousClock().measure { await widget.loadThumbnail(item) }
    let thumbnail = try #require(widget.thumbnail(item))
    print("PERF thumbnail of a 2940×1912 noise PNG (\(item.byteCount! / 1024 / 1024) MB): \(ms(elapsed)); \(Int(thumbnail.size.width))×\(Int(thumbnail.size.height)) px, \(widget.thumbnails.totalCost / 1024) KB in cache")
    #expect(max(thumbnail.size.width, thumbnail.size.height) <= CGFloat(VaultImages.thumbnailPixels))
    #expect(widget.thumbnailRevision == revision + 1)
    #expect(widget.thumbnails.totalCost > 0 && widget.thumbnails.totalCost <= ThumbnailCache.defaultCostLimit)
}

@MainActor @Test func thumbnailCacheEvictsTheLeastRecentlyUsed() {
    let cache = ThumbnailCache(costLimit: 1000)
    let (a, b, c, huge) = (UUID(), UUID(), UUID(), UUID())
    let image = NSImage(size: NSSize(width: 1, height: 1))
    cache.insert(image, cost: 400, for: a)
    cache.insert(image, cost: 400, for: b)
    _ = cache.image(for: a)  // a is now the most recent
    cache.insert(image, cost: 400, for: c)
    #expect(cache.image(for: b) == nil)
    #expect(cache.image(for: a) != nil && cache.image(for: c) != nil)
    #expect(cache.totalCost == 800 && cache.count == 2)
    cache.insert(image, cost: 2000, for: huge)  // larger than the whole cache: not kept, nothing flushed
    #expect(cache.image(for: huge) == nil && cache.count == 2)
    cache.insert(image, cost: 100, for: a)  // replacing an entry updates its cost
    #expect(cache.totalCost == 500)
    cache.removeAll()
    #expect(cache.totalCost == 0 && cache.count == 0)
}

@MainActor @Test func missingAndCorruptImagesFailSafely() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let missing = VaultItem(id: UUID(), fileName: "missing.png", importedAt: .now, source: "x")
    let corrupt = VaultItem(id: UUID(), fileName: "corrupt.png", importedAt: .now, source: "x")
    try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save([missing, corrupt])
    try Data("not an image".utf8).write(to: directory.appending(path: "corrupt.png"))
    let widget = VaultWidget(directory: directory)

    for item in [missing, corrupt] {
        await widget.loadThumbnail(item)
        #expect(widget.thumbnail(item) == nil)
        widget.selection = item.id
        await widget.loadPreview(item)
        #expect(widget.preview == nil && widget.previewFailed == item.id)
    }
    #expect(widget.thumbnails.count == 0)
}

@MainActor @Test func cancelledThumbnailWorkIsSkipped() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    guard case .saved(let item) = await widget.importData(sampleImage(.png, width: 600, height: 400, seed: 81), source: "x") else {
        Issue.record("import failed")
        return
    }
    let task = Task { await widget.loadThumbnail(item) }
    task.cancel()  // the cell scrolled away before the work started
    await task.value
    #expect(widget.thumbnail(item) == nil)
    await widget.loadThumbnail(item)  // a cancelled load isn't recorded as a failure
    #expect(widget.thumbnail(item) != nil)
}

// MARK: Preview

@MainActor @Test func previewIsDecodedInTheBackgroundBoundedAndReleased() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    guard case .saved(let big) = await widget.importData(await noisePNG(4000, 3000), source: "x"),
          case .saved(let small) = await widget.importData(sampleImage(.png, width: 300, height: 200, seed: 83), source: "y")
    else {
        Issue.record("import failed")
        return
    }
    widget.selection = big.id
    let elapsed = await ContinuousClock().measure { await widget.loadPreview(big) }
    let preview = try #require(widget.preview)
    print("PERF preview of a 4000×3000 noise PNG (\(big.byteCount! / 1024 / 1024) MB): \(ms(elapsed)); decoded at \(Int(preview.image.size.width))×\(Int(preview.image.size.height)) px")
    #expect(preview.id == big.id)
    #expect(preview.image.size == NSSize(width: 2048, height: 1536))  // bounded, same aspect ratio
    #expect(try Data(contentsOf: widget.vault!.url(for: big)).count == big.byteCount)  // stored file untouched

    widget.selection = small.id
    await widget.loadPreview(small)
    #expect(widget.preview?.id == small.id)
    #expect(widget.preview?.image.size == NSSize(width: 300, height: 200))  // small images: full resolution, not enlarged
    widget.stop()  // the dashboard closed
    #expect(widget.preview == nil)
}

@MainActor @Test func rapidSelectionChangesShowOnlyTheLatestPreview() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    guard case .saved(let first) = await widget.importData(await bigPNG(3000, 2000, seed: 84), source: "x"),
          case .saved(let second) = await widget.importData(sampleImage(.png, width: 320, height: 200, seed: 85), source: "y")
    else {
        Issue.record("import failed")
        return
    }
    widget.selection = first.id
    let slow = Task { await widget.loadPreview(first) }  // still decoding…
    widget.selection = second.id                          // …when the user moves on
    await widget.loadPreview(second)
    await slow.value
    #expect(widget.preview?.id == second.id)  // the first result was dropped
    #expect(widget.previewFailed == nil)
}

// MARK: Hash backfill

private let legacyJSON = """
    [{"id":"FA0A47D0-504E-47E0-98A0-E9ECA66A6F94","fileName":"FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png",\
    "importedAt":800000000,"source":"Clipboard","isKept":true,"pixelWidth":64,"pixelHeight":40}]
    """

@MainActor @Test func backfillHashesLegacyItemsOnceAndPersists() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let png = sampleImage(.png, width: 64, height: 40, seed: 86)
    let file = directory.appending(path: "FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png")
    try png.write(to: file)
    try Data(legacyJSON.utf8).write(to: directory.appending(path: "index.json"))
    let widget = VaultWidget(directory: directory)

    #expect(await widget.backfillHashes() == 1)
    let item = try #require(widget.items.first)
    #expect(item.sha256 == sha(png))
    #expect(item.format == "public.png" && item.byteCount == png.count)
    #expect(item.pixelWidth == 64 && item.isKept && item.source == "Clipboard")  // existing values untouched
    #expect(try Data(contentsOf: file) == png)
    #expect(try Data(contentsOf: directory.appending(path: ScreenshotVault.backupName)) == Data(legacyJSON.utf8))

    // Relaunch: the hash was saved, so there's nothing left to do and nothing is written.
    let index = try Data(contentsOf: directory.appending(path: "index.json"))
    let relaunched = VaultWidget(directory: directory)
    #expect(relaunched.items.first?.sha256 == sha(png))
    #expect(await relaunched.backfillHashes() == 0)
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == index)
}

@MainActor @Test func backfillNeverReplacesAnExistingHash() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let hashed = VaultItem(id: UUID(), fileName: "a.png", importedAt: .now, source: "x", sha256: "kept-as-is")
    let legacy = VaultItem(id: UUID(), fileName: "b.png", importedAt: .now, source: "x")
    try sampleImage(.png, seed: 87).write(to: directory.appending(path: "a.png"))
    try sampleImage(.png, seed: 88).write(to: directory.appending(path: "b.png"))
    try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save([hashed, legacy])
    let widget = VaultWidget(directory: directory)

    #expect(await widget.backfillHashes() == 1)
    #expect(widget.items.first { $0.id == hashed.id }?.sha256 == "kept-as-is")
    #expect(widget.items.first { $0.id == legacy.id }?.sha256 == sha(sampleImage(.png, seed: 88)))
}

@MainActor @Test func backfillSkipsMissingUnreadableAndCorruptFiles() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let items = ["missing.png", "locked.png", "corrupt.png", "../outside.png"].map {
        VaultItem(id: UUID(), fileName: $0, importedAt: .now, source: "x")
    }
    try sampleImage(.png, seed: 89).write(to: directory.appending(path: "locked.png"))
    try Data("garbage".utf8).write(to: directory.appending(path: "corrupt.png"))
    try sampleImage(.png, seed: 90).write(to: temp.url.appending(path: "outside.png"))
    try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save(items)
    let locked = directory.appending(path: "locked.png").path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
    let index = try Data(contentsOf: directory.appending(path: "index.json"))

    let widget = VaultWidget(directory: directory)
    #expect(await widget.backfillHashes() == 0)
    #expect(widget.vault?.items.allSatisfy { $0.sha256 == nil } == true)
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == index)  // nothing written
    #expect(!listing(directory).contains(ScreenshotVault.backupName))
}

// MARK: Drag copies at launch

@Test func launchCleanupRemovesOnlyExpiredOrbitCopies() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let root = temp.url.appending(path: "OrbitExports")
    let now = Date.now
    func folder(_ name: String, age: TimeInterval) throws -> URL {
        let url = root.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try Data("copy".utf8).write(to: url.appending(path: "Screenshot.png"))
        try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-age)], ofItemAtPath: url.path(percentEncoded: false))
        return url
    }
    let expired = try folder(UUID().uuidString, age: 11 * 60)
    let recent = try folder(UUID().uuidString, age: 9 * 60)
    let active = try folder(UUID().uuidString, age: 5)
    let notOurs = try folder("Something Else", age: 3600)
    let outside = temp.url.appending(path: "user-file.png")
    try Data("user".utf8).write(to: outside)
    try FileManager.default.setAttributes([.creationDate: now.addingTimeInterval(-3600)], ofItemAtPath: outside.path(percentEncoded: false))

    let clock = ContinuousClock()
    var removed = 0
    let elapsed = await clock.measure { removed = await ScreenshotVault.cleanUpExpiredExports(in: root, now: now) }
    print("PERF launch drag-copy cleanup (4 folders): \(ms(elapsed))")
    #expect(removed == 1)
    #expect(!FileManager.default.fileExists(atPath: expired.path(percentEncoded: false)))
    for kept in [recent, active, notOurs, outside] {
        #expect(FileManager.default.fileExists(atPath: kept.path(percentEncoded: false)), "\(kept.lastPathComponent)")
    }
    #expect(await ScreenshotVault.cleanUpExpiredExports(in: temp.url.appending(path: "Missing")) == 0)  // no folder: fine
}

// MARK: Scale

@MainActor @Test func aThousandScreenshotLibrary() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let png = sampleImage(.png, width: 1440, height: 900, seed: 91)
    let template = temp.url.appending(path: "template.png")
    try png.write(to: template)
    let clock = ContinuousClock()
    var items: [VaultItem] = []
    let setup = try clock.measure {
        for index in 0..<1000 {
            let id = UUID()
            let item = VaultItem(id: id, fileName: "\(id.uuidString).png", importedAt: Date(timeIntervalSince1970: Double(1_800_000_000 - index)),
                                 source: "/Users/test/Desktop/Screenshot \(index).png", isKept: index % 10 == 0,
                                 pixelWidth: 1440, pixelHeight: 900, byteCount: png.count, format: "public.png",
                                 sha256: String(format: "%064x", index), deletedAt: index % 50 == 0 ? .now : nil)
            try FileManager.default.copyItem(at: template, to: directory.appending(path: item.fileName))
            items.append(item)
        }
        try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save(items)
    }
    let indexBytes = try Data(contentsOf: directory.appending(path: "index.json")).count

    var widget: VaultWidget!
    let load = clock.measure { widget = VaultWidget(directory: directory) }
    let lists = clock.measure { _ = (widget.items.count, widget.deletedItems.count, widget.vault?.inbox.count) }
    let purge = clock.measure { _ = widget.purgeExpired() }
    let backfill = await clock.measure { _ = await widget.backfillHashes() }
    let write = clock.measure { widget.toggleKept(widget.items[1]) }
    let thumbs = await clock.measure {
        for item in widget.items.prefix(200) { await widget.loadThumbnail(item) }
    }
    let newImport = await clock.measure { _ = await widget.importData(png, source: "new") }
    print("""
        PERF 1,000-screenshot library (index \(indexBytes / 1024) KB): setup \(ms(setup)); load \(ms(load)); \
        active/deleted/inbox lists \(ms(lists)); expiry scan \(ms(purge)); backfill check \(ms(backfill)); \
        one index write (Keep) \(ms(write)); 200 thumbnails \(ms(thumbs)) \
        (cache \(widget.thumbnails.count) kept, \(widget.thumbnails.totalCost / 1024 / 1024) MB of \(ThumbnailCache.defaultCostLimit / 1024 / 1024) MB); \
        new import into a 1,000-item vault \(ms(newImport))
        """)
    #expect(widget.items.count == 981 && widget.deletedItems.count == 20)
    #expect(widget.thumbnails.totalCost <= ThumbnailCache.defaultCostLimit)
    #expect(widget.vault?.items.count == 1001)
    #expect(load < .seconds(2) && write < .seconds(1))
}

@MainActor
private final class ReportLog: @unchecked Sendable {
    var values: [VaultImportOutcome] = []
}
