import AppKit
import CryptoKit
import Testing
@testable import Orbit

// Full Vault lifecycle against disposable *copies* of a real Vault. Skipped
// unless a copy is named, e.g.
//   ORBIT_VAULT_COPY_LEGACY=/tmp/copy/legacy ORBIT_VAULT_COPY_CURRENT=/tmp/copy/current \
//     scripts/test.sh --filter vaultCopy
// The copies are modified (deleted, purged, corrupted, rebuilt); the real
// Vault is refused outright.

private func copyDirectory(_ key: String) -> URL? {
    guard let path = ProcessInfo.processInfo.environment[key] else { return nil }
    let url = URL(filePath: path, directoryHint: .isDirectory).standardizedFileURL
    let real = OrbitStorage.directory.standardizedFileURL.path(percentEncoded: false)
    guard !url.path(percentEncoded: false).hasPrefix(real) else {
        Issue.record("refusing to run destructive checks inside Orbit's real data folder")
        return nil
    }
    return url
}

private func digests(_ directory: URL, _ names: [String]) throws -> [String: String] {
    try Dictionary(uniqueKeysWithValues: names.map { name in
        (name, SHA256.hash(data: try Data(contentsOf: directory.appending(path: name))).map { String(format: "%02x", $0) }.joined())
    })
}

private func listing(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_VAULT_COPY_LEGACY"] != nil))
func vaultCopyLegacyLifecycle() async throws {
    guard let directory = copyDirectory("ORBIT_VAULT_COPY_LEGACY") else { return }
    let indexURL = directory.appending(path: "index.json")
    let originalIndex = try Data(contentsOf: indexURL)
    let originalItems = try JSONDecoder().decode([VaultItem].self, from: originalIndex)
    let images = originalItems.map(\.fileName)
    let imageDigests = try digests(directory, images)
    let startListing = listing(directory)

    // Load: compatible, consistent, and nothing written.
    let loaded = try ScreenshotVault(directory: directory)
    #expect(loaded.items == originalItems)
    #expect(loaded.recentlyDeleted.isEmpty)
    for item in loaded.items {
        #expect(FileManager.default.fileExists(atPath: loaded.url(for: item).path(percentEncoded: false)))
        if let sha = item.sha256 { #expect(imageDigests[item.fileName] == sha, "\(item.fileName) hash") }
    }
    let widget = VaultWidget(directory: directory)
    #expect(widget.purgeExpired() == 0)
    let legacy = try #require(widget.items.first { $0.sha256 == nil })
    #expect(await widget.importData(try Data(contentsOf: loaded.url(for: legacy)), source: "again") == .duplicate(legacy))
    let inboxCount = loaded.inbox.count
    widget.requestClearInbox()
    #expect(widget.pendingClear == inboxCount)
    widget.cancelPending()
    #expect(listing(directory) == startListing)
    #expect(try Data(contentsOf: indexURL) == originalIndex)

    // First write: backup of the original index, then the empty library.
    widget.requestClearInbox()
    widget.confirmClearInbox()
    let backup = directory.appending(path: ScreenshotVault.backupName)
    #expect(try Data(contentsOf: backup) == originalIndex)
    #expect(try JSONFile<VaultLibrary>(url: directory.appending(path: "library.json")).load() == VaultLibrary())
    #expect(widget.deletedItems.count == inboxCount)
    #expect(Set(widget.items.map(\.id)) == Set(originalItems.filter(\.isKept).map(\.id)))
    let written = try JSONDecoder().decode([VaultItem].self, from: Data(contentsOf: indexURL))
    #expect(written.map { var item = $0; item.deletedAt = nil; return item } == originalItems)  // only deletedAt changed

    // Restore everything: the index content is back to the original items.
    for item in widget.deletedItems { widget.restore(item) }
    #expect(try ScreenshotVault(directory: directory).items == originalItems)
    #expect(try Data(contentsOf: backup) == originalIndex)

    // Retention: a future deletion date isn't expired; 29 days isn't, 30 days is.
    var vault = try ScreenshotVault(directory: directory)
    let now = Date.now
    try vault.delete(originalItems[0].id, now: now.addingTimeInterval(10 * 86_400))
    #expect(try vault.purgeExpired(now: now) == 0)
    try vault.restore(originalItems[0].id)
    let probe = try vault.importImage(sampleImage(.png, width: 9, height: 9, seed: 99), source: "probe").item
    try vault.delete(probe.id, now: now)
    #expect(try vault.purgeExpired(now: now.addingTimeInterval(29 * 86_400)) == 0)
    #expect(try vault.purgeExpired(now: now.addingTimeInterval(30 * 86_400)) == 1)
    #expect(!FileManager.default.fileExists(atPath: vault.url(for: probe).path(percentEncoded: false)))
    #expect(try ScreenshotVault(directory: directory).items == originalItems)

    // Corrupt index: nothing happens until an explicit rebuild, which recovers every image.
    try Data("corrupted for the test".utf8).write(to: indexURL)
    let broken = VaultWidget(directory: directory)
    #expect(broken.problem != nil)
    #expect(try Data(contentsOf: indexURL) == Data("corrupted for the test".utf8))
    let result = broken.rebuildIndex()
    #expect(result.text.hasPrefix("Recovered \(originalItems.count) screenshots, marked Kept."))
    #expect(Set(broken.items.map(\.fileName)) == Set(images))
    #expect(broken.items.allSatisfy { $0.isKept })
    #expect(listing(directory).contains { $0.hasPrefix("index.corrupt-") })
    #expect(try Data(contentsOf: backup) == originalIndex)
    #expect(try digests(directory, images) == imageDigests)  // every image byte-for-byte
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_VAULT_COPY_CURRENT"] != nil))
func vaultCopyMigratedLifecycle() async throws {
    guard let directory = copyDirectory("ORBIT_VAULT_COPY_CURRENT") else { return }
    let backup = directory.appending(path: ScreenshotVault.backupName)
    let backupBytes = try Data(contentsOf: backup)
    let libraryBytes = try Data(contentsOf: directory.appending(path: "library.json"))
    let index = try Data(contentsOf: directory.appending(path: "index.json"))
    let items = try JSONDecoder().decode([VaultItem].self, from: index)
    let imageDigests = try digests(directory, items.map(\.fileName))

    let widget = VaultWidget(directory: directory)
    #expect(widget.items.count + widget.deletedItems.count == items.count)
    #expect(widget.purgeExpired() == 0)
    #expect(try Data(contentsOf: directory.appending(path: "index.json")) == index)  // no write on load

    // Hash backfill (Stage 2 Step 2): fills only missing fields; images and backup untouched.
    let missing = items.filter { $0.sha256 == nil }
    #expect(await widget.backfillHashes() == missing.count)
    let filled = try JSONDecoder().decode([VaultItem].self, from: Data(contentsOf: directory.appending(path: "index.json")))
    #expect(filled.map(\.id) == items.map(\.id))
    for (before, after) in zip(items, filled) {
        guard before.sha256 == nil else {
            #expect(after == before, "\(before.fileName) must be unchanged")
            continue
        }
        #expect(after.sha256 == imageDigests[before.fileName])
        var stripped = after
        stripped.sha256 = nil
        if before.format == nil { stripped.format = nil }
        if before.byteCount == nil { stripped.byteCount = nil }
        if before.pixelWidth == nil { stripped.pixelWidth = nil }
        if before.pixelHeight == nil { stripped.pixelHeight = nil }
        #expect(stripped == before, "only missing fields may change")
    }
    #expect(await VaultWidget(directory: directory).backfillHashes() == 0)  // relaunch: nothing left to do
    #expect(try Data(contentsOf: backup) == backupBytes)
    #expect(try digests(directory, items.map(\.fileName)) == imageDigests)

    // Writes after migration never touch the existing backup or the library.
    for item in widget.deletedItems { widget.restore(item) }
    widget.delete(widget.items[0])
    #expect(try Data(contentsOf: backup) == backupBytes)
    #expect(try Data(contentsOf: directory.appending(path: "library.json")) == libraryBytes)
    #expect(try digests(directory, items.map(\.fileName)) == imageDigests)
}
