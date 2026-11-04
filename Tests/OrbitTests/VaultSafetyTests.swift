import AppKit
import Testing
@testable import Orbit

// Stage 2 Step 1: compatible model, migration backup, Recently Deleted,
// Clear Inbox safety and explicit index rebuild.

private func contents(of directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
}

private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) }

private let day: TimeInterval = 24 * 60 * 60

/// A vault folder holding `items` and a PNG file for each (bytes by seed).
private func makeVault(_ temp: TemporaryDirectory, _ items: [VaultItem]) throws -> URL {
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for (index, item) in items.enumerated() {
        try sampleImage(.png, seed: UInt8(index + 40)).write(to: directory.appending(path: item.fileName))
    }
    try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save(items)
    return directory
}

private func item(_ name: String, kept: Bool = false, favorite: Bool? = nil, collection: UUID? = nil,
                  tags: [UUID]? = nil, deletedAt: Date? = nil) -> VaultItem {
    VaultItem(id: UUID(), fileName: "\(name).png", importedAt: .now, source: "test", isKept: kept,
              isFavorite: favorite, collectionID: collection, tagIDs: tags, deletedAt: deletedAt)
}

/// The Stage 1 index as it exists for current users: one item without a hash.
private let legacyIndex = """
    [{"id":"FA0A47D0-504E-47E0-98A0-E9ECA66A6F94","fileName":"FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png",\
    "importedAt":800000000,"source":"Clipboard","isKept":true,"pixelWidth":4,"pixelHeight":4}]
    """

private func makeLegacyVault(_ temp: TemporaryDirectory, image: Data) throws -> URL {
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try image.write(to: directory.appending(path: "FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png"))
    try Data(legacyIndex.utf8).write(to: directory.appending(path: "index.json"))
    return directory
}

// MARK: Compatibility and migration

@MainActor @Test func legacyIndexLoadsWithoutAnyWrite() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let image = sampleImage(.png, seed: 1)
    let directory = try makeLegacyVault(temp, image: image)
    let before = contents(of: directory)

    let vault = try ScreenshotVault(directory: directory)
    #expect(vault.items.count == 1)
    #expect(vault.items[0].sha256 == nil && vault.items[0].isKept)
    #expect(vault.items[0].deletedAt == nil && vault.items[0].isFavorite == nil)
    #expect(vault.library == VaultLibrary())
    // What launch does: load the widget and run the expiry cleanup.
    let widget = VaultWidget(directory: directory)
    #expect(widget.purgeExpired() == 0)
    #expect(widget.items.count == 1)

    #expect(contents(of: directory) == before)  // no backup, no library.json
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == Data(legacyIndex.utf8))
    #expect(try Data(contentsOf: directory.appending(path: "FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png")) == image)
}

@Test func newFieldsRoundTripAndAreOmittedWhileUnset() throws {
    let full = VaultItem(id: UUID(), fileName: "a.png", importedAt: Date(timeIntervalSince1970: 1), source: "x",
                         isFavorite: true, collectionID: UUID(), tagIDs: [UUID(), UUID()],
                         deletedAt: Date(timeIntervalSince1970: 2))
    let plain = VaultItem(id: UUID(), fileName: "b.png", importedAt: Date(timeIntervalSince1970: 1), source: "x")
    let data = try JSONEncoder().encode([full, plain])
    #expect(try JSONDecoder().decode([VaultItem].self, from: data) == [full, plain])

    let plainJSON = String(decoding: try JSONEncoder().encode(plain), as: UTF8.self)
    for key in ["isFavorite", "collectionID", "tagIDs", "deletedAt"] {
        #expect(!plainJSON.contains(key), "\(key) must be left out while unset")
    }
    #expect(full.isOrganized && full.isDeleted)
    #expect(!plain.isOrganized && !plain.isDeleted)
}

@Test func firstWriteBacksUpTheLegacyIndexExactlyOnce() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = try makeLegacyVault(temp, image: sampleImage(.png, seed: 2))
    let backup = directory.appending(path: ScreenshotVault.backupName)
    var vault = try ScreenshotVault(directory: directory)
    let id = vault.items[0].id

    try vault.setKept(id, false)  // first write by this version
    #expect(try Data(contentsOf: backup) == Data(legacyIndex.utf8))
    #expect(try JSONFile<VaultLibrary>(url: directory.appending(path: "library.json")).load() == VaultLibrary())

    try vault.setKept(id, true)
    try vault.delete(id)
    try vault.restore(id)
    _ = try vault.importImage(sampleImage(.png, seed: 3), source: "x")
    #expect(try Data(contentsOf: backup) == Data(legacyIndex.utf8))  // still the original
    #expect(contents(of: directory).filter { $0.hasPrefix("index") } == ["index.json", ScreenshotVault.backupName])
}

@Test func anExistingBackupIsNeverOverwritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = try makeLegacyVault(temp, image: sampleImage(.png, seed: 4))
    let backup = directory.appending(path: ScreenshotVault.backupName)
    let earlier = Data("an earlier backup".utf8)
    try earlier.write(to: backup)

    var vault = try ScreenshotVault(directory: directory)
    try vault.setKept(vault.items[0].id, false)
    #expect(try Data(contentsOf: backup) == earlier)
}

@Test func aNewVaultNeedsNoBackupAndStartsAnEmptyLibrary() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    #expect(vault.library == VaultLibrary() && !vault.libraryIsUnreadable)
    let first = try vault.importImage(sampleImage(.png, seed: 5), source: "x").item
    _ = try vault.importImage(sampleImage(.png, seed: 6), source: "x")
    #expect(!exists(directory.appending(path: ScreenshotVault.backupName)))
    #expect(contents(of: directory).contains("library.json"))
    #expect(try ScreenshotVault(directory: directory).items.last == first)
}

@Test func anUnreadableLibraryIsLeftAloneAndTheVaultStillWorks() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = try makeVault(temp, [item("a")])
    let garbage = Data("{ not a library".utf8)
    try garbage.write(to: directory.appending(path: "library.json"))

    var vault = try ScreenshotVault(directory: directory)
    #expect(vault.libraryIsUnreadable)
    #expect(vault.library == VaultLibrary())
    _ = try vault.importImage(sampleImage(.png, seed: 7), source: "x")
    try vault.delete(vault.items[0].id)
    #expect(try Data(contentsOf: directory.appending(path: "library.json")) == garbage)
    #expect(try ScreenshotVault(directory: directory).items.count == 2)
}

@Test func aCorruptIndexIsNeverOverwritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let garbage = Data("[{\"id\": broken".utf8)
    try garbage.write(to: directory.appending(path: "index.json"))
    #expect(throws: (any Error).self) { try ScreenshotVault(directory: directory) }
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == garbage)
    #expect(contents(of: directory) == ["index.json"])
}

@Test func aLegacyItemWithoutAHashIsStillRecognisedAsADuplicate() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let image = sampleImage(.png, seed: 8)
    let directory = try makeLegacyVault(temp, image: image)
    var vault = try ScreenshotVault(directory: directory)

    #expect(try vault.importImage(image, source: "again") == .duplicate(vault.items[0]))
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == Data(legacyIndex.utf8))  // nothing written
    #expect(try Data(contentsOf: directory.appending(path: "FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png")) == image)
}

// MARK: Recently Deleted

@Test func deleteIsRecoverableAndKeepsTheFile() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    var vault = try ScreenshotVault(directory: directory)
    let bytes = sampleImage(.png, seed: 9)
    let added = try vault.importImage(bytes, source: "x").item
    let deletedAt = Date(timeIntervalSince1970: 1_800_000_000)

    try vault.delete(added.id, now: deletedAt)
    #expect(vault.active.isEmpty)
    #expect(vault.recentlyDeleted.map(\.id) == [added.id])
    #expect(try Data(contentsOf: vault.url(for: added)) == bytes)
    try vault.delete(added.id, now: deletedAt.addingTimeInterval(day))  // deleting again keeps the first date
    #expect(try ScreenshotVault(directory: directory).recentlyDeleted.first?.deletedAt == deletedAt)

    try vault.restore(added.id)
    #expect(vault.active.map(\.id) == [added.id])
    #expect(vault.recentlyDeleted.isEmpty)
    let reloaded = try ScreenshotVault(directory: directory)
    #expect(reloaded.items == [added])  // exactly as imported
    #expect(try Data(contentsOf: vault.url(for: added)) == bytes)
    #expect(try reloaded.exportCopy(of: added, root: temp.url.appending(path: "Exports")).lastPathComponent.hasSuffix(".png"))
}

@Test func reimportingADeletedImageRestoresIt() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var vault = try ScreenshotVault(directory: temp.url.appending(path: "Vault"))
    let bytes = sampleImage(.png, seed: 10)
    let added = try vault.importImage(bytes, source: "x").item
    try vault.delete(added.id)

    guard case .restored(let restored) = try vault.importImage(bytes, source: "again") else {
        Issue.record("a deleted duplicate must be restored")
        return
    }
    #expect(restored.id == added.id && !restored.isDeleted)
    #expect(vault.items.count == 1)
}

@Test func onlyItemsDeletedThirtyDaysAgoArePurged() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let old = item("old", deletedAt: now.addingTimeInterval(-30 * day))
    let recent = item("recent", deletedAt: now.addingTimeInterval(-29 * day))
    let future = item("future", deletedAt: now.addingTimeInterval(day))  // clock moved back
    let active = item("active")
    let directory = try makeVault(temp, [old, recent, future, active])
    var vault = try ScreenshotVault(directory: directory)

    #expect(try vault.purgeExpired(now: now) == 1)
    #expect(Set(vault.items.map(\.id)) == [recent.id, future.id, active.id])
    #expect(!exists(directory.appending(path: old.fileName)))
    for kept in [recent, future, active] { #expect(exists(directory.appending(path: kept.fileName))) }
    #expect(try ScreenshotVault(directory: directory).items.count == 3)
    #expect(try vault.purgeExpired(now: now) == 0)
}

@Test func purgeOnlyAppliesToRecentlyDeletedItems() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let active = item("active")
    let directory = try makeVault(temp, [active])
    var vault = try ScreenshotVault(directory: directory)
    try vault.purge(active.id)
    #expect(vault.items == [active])
    #expect(exists(directory.appending(path: active.fileName)))
}

@Test func purgingAnItemWhoseFileIsMissingRemovesItsEntry() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let gone = item("gone", deletedAt: .now)
    let directory = try makeVault(temp, [gone])
    try FileManager.default.removeItem(at: directory.appending(path: gone.fileName))
    var vault = try ScreenshotVault(directory: directory)
    try vault.purge(gone.id)
    #expect(vault.items.isEmpty)
    #expect(try ScreenshotVault(directory: directory).items.isEmpty)
}

@Test func aFailedPurgeLeavesTheEntryAndItsFile() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let doomed = item("doomed", deletedAt: Date(timeIntervalSince1970: 0))
    let directory = try makeVault(temp, [doomed])
    var vault = try ScreenshotVault(directory: directory)
    let path = directory.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path) }

    #expect(throws: (any Error).self) { try vault.purge(doomed.id) }
    #expect(throws: (any Error).self) { try vault.purgeExpired() }
    #expect(vault.items == [doomed])
    #expect(exists(directory.appending(path: doomed.fileName)))
    #expect(try ScreenshotVault(directory: directory).items == [doomed])
}

@Test func expiredItemsOutsideTheVaultAreNeverPurged() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let outside = temp.url.appending(path: "precious.png")
    let precious = sampleImage(.png, seed: 11)
    try precious.write(to: outside)
    let tampered = VaultItem(id: UUID(), fileName: "../precious.png", importedAt: .now, source: "?",
                             deletedAt: Date(timeIntervalSince1970: 0))
    try JSONFile<[VaultItem]>(url: directory.appending(path: "index.json")).save([tampered])
    var vault = try ScreenshotVault(directory: directory)

    #expect(try vault.purgeExpired() == 0)
    #expect(throws: VaultError.outsideVault) { try vault.purge(tampered.id) }
    #expect(try Data(contentsOf: outside) == precious)
    #expect(vault.items == [tampered])
}

// MARK: Clear Inbox

@Test func clearInboxSparesKeptOrganisedAndDeletedItems() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    let plain = item("plain")
    let protected = [item("kept", kept: true), item("favorite", favorite: true), item("collected", collection: UUID()),
                     item("tagged", tags: [UUID()]), item("deleted", deletedAt: earlier)]
    let notFavorite = item("unfavorited", favorite: false, tags: [])  // an explicit "no" isn't organised
    let directory = try makeVault(temp, [plain, notFavorite] + protected)
    var vault = try ScreenshotVault(directory: directory)

    #expect(Set(vault.inbox.map(\.id)) == [plain.id, notFavorite.id])
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(try vault.clearInbox(now: now) == 2)
    #expect(vault.items.first { $0.id == plain.id }?.deletedAt == now)
    #expect(vault.items.first { $0.id == protected[4].id }?.deletedAt == earlier)  // unchanged
    #expect(Set(vault.active.map(\.id)) == Set(protected.prefix(4).map(\.id)))
    for entry in [plain, notFavorite] + protected { #expect(exists(directory.appending(path: entry.fileName))) }
    #expect(try vault.clearInbox() == 0)
}

@MainActor @Test func clearInboxWaitsForConfirmation() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = try makeVault(temp, [item("a"), item("b"), item("kept", kept: true)])
    let index = directory.appending(path: "index.json")
    let before = try Data(contentsOf: index)
    let widget = VaultWidget(directory: directory)

    widget.confirmClearInbox()  // nothing requested: no-op
    widget.requestClearInbox()
    #expect(widget.pendingClear == 2)
    #expect(try Data(contentsOf: index) == before)  // asking writes nothing
    widget.cancelPending()
    #expect(widget.pendingClear == nil)
    widget.requestClearInbox()
    widget.stop()  // closing the dashboard cancels too
    #expect(widget.pendingClear == nil)
    #expect(widget.items.count == 3)

    widget.requestClearInbox()
    widget.confirmClearInbox()
    #expect(widget.items.map(\.fileName) == ["kept.png"])
    #expect(widget.deletedItems.count == 2)
    #expect(widget.feedback == .init(text: "Moved 2 screenshots to Recently Deleted.", isError: false))
    widget.requestClearInbox()
    #expect(widget.pendingClear == nil)  // empty inbox: nothing to confirm
}

@MainActor @Test func widgetDeleteRestoreAndPermanentDelete() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    guard case .saved(let added) = await widget.importData(sampleImage(.png, seed: 12), source: "x") else {
        Issue.record("import failed")
        return
    }
    let file = try #require(widget.vault?.url(for: added))

    widget.delete(added)
    #expect(widget.items.isEmpty && widget.deletedItems.map(\.id) == [added.id])
    widget.showsDeleted = true
    #expect(widget.selectedItem?.id == added.id)
    widget.restore(widget.deletedItems[0])
    #expect(widget.items.map(\.id) == [added.id])

    widget.delete(widget.items[0])
    widget.confirmPurge()  // nothing requested: no-op
    #expect(exists(file))
    widget.requestPurge(widget.deletedItems[0])
    widget.cancelPending()
    #expect(exists(file) && widget.deletedItems.count == 1)
    widget.requestPurge(widget.deletedItems[0])
    widget.confirmPurge()
    #expect(!exists(file) && widget.deletedItems.isEmpty)
    #expect(widget.feedback == .init(text: "Deleted permanently.", isError: false))

    // Importing while Recently Deleted is shown switches back to the Vault.
    widget.showsDeleted = true
    await widget.importData(sampleImage(.png, seed: 13), source: "x")
    #expect(!widget.showsDeleted)
}

// MARK: Index rebuild

@Test func rebuildRecoversValidImagesAndPreservesTheCorruptIndex() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let ids = [UUID(), UUID()]
    let pngs = [sampleImage(.png, seed: 20), sampleImage(.png, seed: 21)]
    for (id, png) in zip(ids, pngs) { try png.write(to: directory.appending(path: "\(id.uuidString).png")) }
    let jpeg = sampleImage(.jpeg, seed: 22)
    try jpeg.write(to: directory.appending(path: "holiday.jpg"))
    let garbage = Data("corrupt".utf8)
    try garbage.write(to: directory.appending(path: "index.json"))

    let (vault, report) = try ScreenshotVault.rebuild(directory: directory)
    #expect(report.recovered == 3)
    #expect(report.skipped.isEmpty)
    #expect(Set(vault.items.map(\.id)).isSuperset(of: ids))  // ids come from the file names
    #expect(vault.items.allSatisfy { $0.isKept && $0.sha256 != nil && !$0.isDeleted })
    #expect(vault.items.first { $0.fileName == "holiday.jpg" }?.format == "public.jpeg")

    let preserved = try #require(report.preservedIndex)
    #expect(preserved.hasPrefix("index.corrupt-"))
    #expect(try Data(contentsOf: directory.appending(path: preserved)) == garbage)
    for (id, png) in zip(ids, pngs) { #expect(try Data(contentsOf: directory.appending(path: "\(id.uuidString).png")) == png) }
    #expect(try Data(contentsOf: directory.appending(path: "holiday.jpg")) == jpeg)
    #expect(try ScreenshotVault(directory: directory).items == vault.items)
    #expect(contents(of: directory).contains("library.json"))
}

@Test func rebuildRefusesInvalidUnsupportedAndExternalFiles() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = temp.url.appending(path: "Vault")
    let nested = directory.appending(path: "Nested")
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    let external = temp.url.appending(path: "external.png")
    let externalBytes = sampleImage(.png, seed: 30)
    try externalBytes.write(to: external)
    try FileManager.default.createSymbolicLink(at: directory.appending(path: "link.png"), withDestinationURL: external)
    try sampleImage(.png, seed: 31).write(to: nested.appending(path: "inside-subfolder.png"))
    try Data("not an image".utf8).write(to: directory.appending(path: "fake.png"))
    try sampleImage(.png, seed: 32).dropLast(12).write(to: directory.appending(path: "truncated.png"))
    try sampleImage(.gif, seed: 33).write(to: directory.appending(path: "anim.gif"))
    try sampleImage(.tiff, seed: 34).write(to: directory.appending(path: "raw.tiff"))
    try sampleImage(.png, seed: 35).write(to: directory.appending(path: "mislabelled.jpg"))
    try Data("notes".utf8).write(to: directory.appending(path: "notes.txt"))
    try sampleImage(.png, seed: 36).write(to: directory.appending(path: ".hidden.png"))
    let valid = sampleImage(.png, seed: 37)
    try valid.write(to: directory.appending(path: "good.png"))

    let (vault, report) = try ScreenshotVault.rebuild(directory: directory)
    #expect(vault.items.map(\.fileName) == ["good.png"])
    #expect(report.preservedIndex == nil)  // there was no index to move
    let skippedNames = Set(report.skipped.map { String($0.prefix { $0 != ":" }) })
    #expect(skippedNames == ["Nested", "link.png", "fake.png", "truncated.png", "anim.gif", "raw.tiff",
                             "mislabelled.jpg", "notes.txt"])
    #expect(try Data(contentsOf: external) == externalBytes)
    #expect(exists(nested.appending(path: "inside-subfolder.png")))
    #expect(try Data(contentsOf: directory.appending(path: "good.png")) == valid)
}

@MainActor @Test func widgetRebuildsOnlyWhenTheIndexIsUnreadable() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let healthy = try makeVault(temp, [item("a")])
    let before = contents(of: healthy)
    let fine = VaultWidget(directory: healthy)
    #expect(fine.rebuildIndex() == .init(text: "The Vault index is readable; nothing to rebuild.", isError: false))
    #expect(contents(of: healthy) == before)

    try Data("nope".utf8).write(to: healthy.appending(path: "index.json"))
    let broken = VaultWidget(directory: healthy)
    #expect(broken.problem != nil)
    #expect(contents(of: healthy) == before)  // nothing happens without the explicit action
    let result = broken.rebuildIndex()
    #expect(!result.isError)
    #expect(result.text.hasPrefix("Recovered 1 screenshot, marked Kept."))
    #expect(broken.problem == nil)
    #expect(broken.items.map(\.fileName) == ["a.png"])
}

// MARK: Verification additions

@Test func aFailedBackupLeavesTheIndexUntouched() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let directory = try makeLegacyVault(temp, image: sampleImage(.png, seed: 50))
    var vault = try ScreenshotVault(directory: directory)
    let before = vault.items
    let index = directory.appending(path: "index.json").path(percentEncoded: false)
    // The index can be replaced (the folder is writable) but not copied.
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: index)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index) }

    #expect(throws: (any Error).self) { try vault.setKept(before[0].id, false) }
    #expect(throws: (any Error).self) { try vault.delete(before[0].id) }
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: index)
    #expect(vault.items == before)
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == Data(legacyIndex.utf8))
    #expect(contents(of: directory) == ["FA0A47D0-504E-47E0-98A0-E9ECA66A6F94.png", "index.json"])
}

@MainActor @Test func droppingAScreenshotThatIsInRecentlyDeletedRestoresIt() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let original = temp.url.appending(path: "Screenshot 2026-11-01 at 11.29.55 PM.png")
    let bytes = sampleImage(.png, seed: 51)
    try bytes.write(to: original)
    let widget = VaultWidget(directory: temp.url.appending(path: "Vault"))
    let outcomes = Outcomes()
    widget.receive([.file(original)]) { outcomes.values.append($0) }
    await widget.importsFinished()
    widget.delete(widget.items[0])

    widget.receive([.file(original)]) { outcomes.values.append($0) }

    await widget.importsFinished()
    #expect(outcomes.values.map(\.notice) == ["Screenshot saved to Vault", "Restored from Recently Deleted"])
    #expect(widget.items.count == 1 && widget.deletedItems.isEmpty)
    #expect(try Data(contentsOf: original) == bytes)  // the dropped original is only read
    let copy = try #require(try widget.vault?.exportCopy(of: widget.items[0], root: temp.url.appending(path: "Exports")))
    #expect(copy.lastPathComponent == original.lastPathComponent)
    #expect(try Data(contentsOf: copy) == bytes)
}

@MainActor
private final class Outcomes: @unchecked Sendable {
    var values: [VaultImportOutcome] = []
}
