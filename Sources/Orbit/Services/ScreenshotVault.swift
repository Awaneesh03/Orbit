import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers

struct VaultItem: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    let fileName: String
    let importedAt: Date
    let source: String
    var isKept = false
    // Metadata. Optional so indexes written before it existed still load.
    var pixelWidth: Int?
    var pixelHeight: Int?
    var byteCount: Int?
    var format: String?
    var sha256: String?
    // Stage 2. Optional and left out of the JSON while unset, so older
    // indexes load unchanged and untouched items keep their old shape.
    var isFavorite: Bool?
    var collectionID: UUID?
    var tagIDs: [UUID]?
    /// When it was moved to Recently Deleted; nil while it's in the Vault.
    var deletedAt: Date?

    var isDeleted: Bool { deletedAt != nil }
    /// Favorited, in a collection or tagged: never swept by Clear Inbox.
    var isOrganized: Bool { isFavorite == true || collectionID != nil || !(tagIDs ?? []).isEmpty }
}

struct VaultCollection: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
    let createdAt: Date
}

struct VaultTag: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    var name: String
}

/// library.json: collections and tags. Empty until those features exist.
struct VaultLibrary: Codable, Equatable, Sendable {
    var version = 2
    var collections: [VaultCollection] = []
    var tags: [VaultTag] = []
}

/// What an explicit index rebuild found.
struct VaultRebuild: Equatable {
    var recovered: Int
    /// "file name: reason" for every file left out.
    var skipped: [String]
    /// Where the old index was moved, if there was one.
    var preservedIndex: String?

    var summary: String {
        var parts = ["Recovered \(recovered) screenshot\(recovered == 1 ? "" : "s"), marked Kept."]
        if !skipped.isEmpty { parts.append("Skipped \(skipped.count) file\(skipped.count == 1 ? "" : "s") that aren't valid screenshots.") }
        if let preservedIndex { parts.append("The unreadable index was kept as \(preservedIndex).") }
        return parts.joined(separator: " ")
    }
}

enum VaultError: Error, Equatable {
    case notAnImage
    case unsupportedFormat(String)
    case tooLarge
    case alreadyExists
    case outsideVault
}

enum VaultImport: Equatable {
    case added(VaultItem)
    case duplicate(VaultItem)
    /// The same image was in Recently Deleted and is back in the Vault.
    case restored(VaultItem)

    var item: VaultItem {
        switch self {
        case .added(let item), .duplicate(let item), .restored(let item): item
        }
    }
}

/// Decoded, validated image bytes ready to store. Sendable: made off the
/// main actor, stored on it.
struct PreparedImage: Equatable, Sendable {
    let data: Data
    let type: UTType
    let pixelWidth: Int
    let pixelHeight: Int
    let sha256: String

    var facts: ImageFacts {
        ImageFacts(sha256: sha256, format: type.identifier, pixelWidth: pixelWidth, pixelHeight: pixelHeight, byteCount: data.count)
    }
}

/// What the hash backfill learns about a stored file (no image bytes kept).
struct ImageFacts: Equatable, Sendable {
    let sha256: String
    let format: String
    let pixelWidth: Int
    let pixelHeight: Int
    let byteCount: Int
}

/// Orbit's own screenshot inbox in Application Support. It only ever reads
/// sources, writes new files of its own and deletes its own copies; originals
/// are never moved, modified or deleted. Deleting is recoverable: items go to
/// Recently Deleted and their files are removed only when purged.
struct ScreenshotVault {
    static let supportedTypes: [UTType] = [.png, .tiff, .jpeg, .heic]
    static let maxBytes = 100 * 1024 * 1024
    /// How long Recently Deleted keeps an item before launch cleanup purges it.
    static let retention: TimeInterval = 30 * 24 * 60 * 60

    let directory: URL
    /// Everything in the index, including Recently Deleted.
    private(set) var items: [VaultItem]
    private(set) var library: VaultLibrary
    /// library.json exists but can't be read. It is left as it is (never rewritten).
    private(set) var libraryIsUnreadable = false

    /// Only reads: loading never rewrites the index.
    init(directory: URL) throws {
        self.directory = directory
        items = try Self.indexFile(in: directory).load() ?? []
        do {
            library = try Self.libraryFile(in: directory).load() ?? VaultLibrary()
        } catch {
            library = VaultLibrary()
            libraryIsUnreadable = true
        }
    }

    /// In the Vault (not Recently Deleted), newest first.
    var active: [VaultItem] { items.filter { !$0.isDeleted } }
    /// Most recently deleted first.
    var recentlyDeleted: [VaultItem] {
        items.filter(\.isDeleted).sorted { ($0.deletedAt ?? .distantPast) > ($1.deletedAt ?? .distantPast) }
    }
    /// What Clear Inbox moves to Recently Deleted: not kept, not organised, not deleted.
    var inbox: [VaultItem] { active.filter { !$0.isKept && !$0.isOrganized } }

    static func purgeDate(of item: VaultItem) -> Date? { item.deletedAt?.addingTimeInterval(retention) }

    func url(for item: VaultItem) -> URL { directory.appending(path: item.fileName) }

    /// Decodes and validates image bytes. TIFF (uncompressed, as drags and the
    /// clipboard deliver it) is stored as PNG; PNG, JPEG and HEIC are kept byte for byte.
    static func prepare(_ data: Data, maxBytes: Int = maxBytes) throws -> PreparedImage {
        guard data.count <= maxBytes else { throw VaultError.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetStatus(source) == .statusComplete,
              CGImageSourceGetCount(source) > 0,
              let typeID = CGImageSourceGetType(source), let type = UTType(typeID as String)
        else { throw VaultError.notAnImage }
        guard let supported = supportedTypes.first(where: { type.conforms(to: $0) }) else {
            throw VaultError.unsupportedFormat(type.preferredFilenameExtension ?? type.identifier)
        }
        guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int, width > 0, height > 0,
              // A full decode (catches truncated TIFF)…
              CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary) != nil,
              // …plus an end-marker check: ImageIO happily decodes truncated PNG and JPEG.
              hasCompleteEnding(data, type: supported)
        else { throw VaultError.notAnImage }

        var stored = data
        var storedType = supported
        if supported == .tiff {
            guard let png = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) else {
                throw VaultError.notAnImage
            }
            stored = png
            storedType = .png
        }
        return PreparedImage(data: stored, type: storedType, pixelWidth: width, pixelHeight: height, sha256: sha256(stored))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// PNG must end with its IEND chunk; JPEG must end with an end-of-image
    /// marker (allowing a little trailing padding).
    static func hasCompleteEnding(_ data: Data, type: UTType) -> Bool {
        switch type {
        case .png:
            return Data(data.suffix(8)) == Data([0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82])
        case .jpeg:
            let tail = Array(data.suffix(32))
            return zip(tail, tail.dropFirst()).contains { $0 == 0xFF && $1 == 0xD9 }
        default:
            return true
        }
    }

    /// Validates and stores image bytes as a new file. An identical image already
    /// in the vault is returned as `.duplicate` and nothing is written; one in
    /// Recently Deleted is restored instead of stored twice.
    @discardableResult
    mutating func importImage(_ data: Data, source: String, now: Date = .now) throws -> VaultImport {
        let image = try Self.prepare(data)
        if let resolved = try resolveDuplicate(of: image) { return resolved }
        let item = newItem(for: image, source: source, now: now)
        try Self.writeFile(image, for: item, in: directory)
        return try register(item, sha256: image.sha256)
    }

    /// Imports the image at `original`, which is only read: never moved,
    /// modified or deleted.
    @discardableResult
    mutating func importFile(at original: URL, source: String? = nil, now: Date = .now) throws -> VaultImport {
        try importImage(Self.readImport(original), source: source ?? original.path(percentEncoded: false), now: now)
    }

    // The import steps. `readImport`, `prepare` and `writeFile` touch no vault
    // state, so they can run off the main actor; the others are quick.

    /// Reads a file to import (only reads), enforcing the size limit first.
    static func readImport(_ original: URL) throws -> Data {
        if let size = try? original.resourceValues(forKeys: [.fileSizeKey]).fileSize, size > maxBytes {
            throw VaultError.tooLarge
        }
        return try Data(contentsOf: original, options: .mappedIfSafe)
    }

    /// An identical image already here is `.duplicate` (nothing written); one
    /// in Recently Deleted is restored. nil: the image is new.
    mutating func resolveDuplicate(of image: PreparedImage) throws -> VaultImport? {
        guard let existing = items.first(where: { isSameImage($0, sha256: image.sha256) }) else { return nil }
        guard existing.isDeleted else { return .duplicate(existing) }
        try restore(existing.id)
        return .restored(items.first { $0.id == existing.id } ?? existing)
    }

    func newItem(for image: PreparedImage, source: String, now: Date = .now) -> VaultItem {
        let id = UUID()
        return VaultItem(
            id: id, fileName: "\(id.uuidString).\(image.type.preferredFilenameExtension ?? "png")",
            importedAt: now, source: source, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight,
            byteCount: image.data.count, format: image.type.identifier, sha256: image.sha256)
    }

    /// Writes a new item's file. Never overwrites anything (names are fresh
    /// UUIDs, but it checks regardless); atomic.
    static func writeFile(_ image: PreparedImage, for item: VaultItem, in directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appending(path: item.fileName)
        guard !FileManager.default.fileExists(atPath: file.path(percentEncoded: false)) else {
            throw VaultError.alreadyExists
        }
        try image.data.write(to: file, options: .atomic)
    }

    /// Adds an item whose file `writeFile` wrote. If an identical image was
    /// registered meanwhile, or the index can't be written, the new file is
    /// removed: no orphan, no half entry.
    mutating func register(_ item: VaultItem, sha256: String) throws -> VaultImport {
        let file = url(for: item)
        if let existing = items.first(where: { $0.sha256 == sha256 }) {
            try? FileManager.default.removeItem(at: file)
            return .duplicate(existing)
        }
        do {
            try commit([item] + items)
        } catch {
            try? FileManager.default.removeItem(at: file)
            throw error
        }
        return .added(item)
    }

    /// Removes a file `writeFile` wrote for an import that was then abandoned
    /// (cancelled). Only an unregistered file directly inside the vault.
    func discardUnregistered(_ item: VaultItem) {
        guard !items.contains(where: { $0.id == item.id }), let file = try? ownedFile(for: item) else { return }
        try? FileManager.default.removeItem(at: file)
    }

    /// Legacy items have no stored hash; their file is hashed (only read) to compare.
    private func isSameImage(_ item: VaultItem, sha256: String) -> Bool {
        if let stored = item.sha256 { return stored == sha256 }
        guard let file = try? ownedFile(for: item), let data = try? Data(contentsOf: file, options: .mappedIfSafe) else { return false }
        return Self.sha256(data) == sha256
    }

    mutating func setKept(_ id: UUID, _ isKept: Bool) throws { try change(id) { $0.isKept = isKept } }

    /// Files to hash for items saved before hashes existed (only files
    /// directly inside the vault).
    var filesMissingHash: [(id: UUID, url: URL)] {
        items.filter { $0.sha256 == nil }.compactMap { item in (try? ownedFile(for: item)).map { (item.id, $0) } }
    }

    /// Reads and validates a stored file (only reads). nil if it's missing,
    /// unreadable, or not a valid image in a stored format.
    static func facts(ofStoredFile url: URL) -> ImageFacts? {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = try? prepare(data),
              image.data == data
        else { return nil }
        return image.facts
    }

    /// Fills in missing metadata. Never replaces a value that's already there;
    /// writes once, and only if something changed.
    mutating func fillMissingMetadata(_ found: [UUID: ImageFacts]) throws {
        var updated = items
        for index in updated.indices {
            guard let facts = found[updated[index].id], updated[index].sha256 == nil else { continue }
            updated[index].sha256 = facts.sha256
            if updated[index].format == nil { updated[index].format = facts.format }
            if updated[index].byteCount == nil { updated[index].byteCount = facts.byteCount }
            if updated[index].pixelWidth == nil { updated[index].pixelWidth = facts.pixelWidth }
            if updated[index].pixelHeight == nil { updated[index].pixelHeight = facts.pixelHeight }
        }
        guard updated != items else { return }
        try commit(updated)
    }

    /// Moves an item to Recently Deleted. Its file stays until it is purged.
    mutating func delete(_ id: UUID, now: Date = .now) throws {
        try change(id) { if $0.deletedAt == nil { $0.deletedAt = now } }
    }

    mutating func restore(_ id: UUID) throws { try change(id) { $0.deletedAt = nil } }

    /// Moves every inbox item to Recently Deleted; returns how many. No file is removed.
    @discardableResult
    mutating func clearInbox(now: Date = .now) throws -> Int {
        let ids = Set(inbox.map(\.id))
        guard !ids.isEmpty else { return 0 }
        try commit(items.map { item in
            var item = item
            if ids.contains(item.id) { item.deletedAt = now }
            return item
        })
        return ids.count
    }

    /// Permanently deletes an item that is in Recently Deleted.
    mutating func purge(_ id: UUID) throws {
        guard let item = items.first(where: { $0.id == id }), item.isDeleted else { return }
        try remove([item])
    }

    /// Purges items deleted at least `retention` ago (run at launch); returns
    /// how many. An item whose file isn't directly inside the vault is skipped.
    @discardableResult
    mutating func purgeExpired(now: Date = .now) throws -> Int {
        let expired = items.filter { item in
            guard let deletedAt = item.deletedAt else { return false }
            return now.timeIntervalSince(deletedAt) >= Self.retention && (try? ownedFile(for: item)) != nil
        }
        guard !expired.isEmpty else { return 0 }
        try remove(expired)
        return expired.count
    }

    /// The index is updated first, so a failure can at worst leave an
    /// unreferenced file, never an entry without its file. A file that is
    /// already missing is fine.
    private mutating func remove(_ doomed: [VaultItem]) throws {
        let files = try doomed.map(ownedFile(for:))
        let ids = Set(doomed.map(\.id))
        try commit(items.filter { !ids.contains($0.id) })
        for file in files { try? FileManager.default.removeItem(at: file) }
    }

    /// Edits one item; writes only if something actually changed.
    private mutating func change(_ id: UUID, _ edit: (inout VaultItem) -> Void) throws {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        var updated = items
        edit(&updated[index])
        guard updated != items else { return }
        try commit(updated)
    }

    /// The item's file, provided it lives directly inside the vault folder.
    private func ownedFile(for item: VaultItem) throws -> URL {
        let file = url(for: item).standardizedFileURL
        guard file.deletingLastPathComponent().pathComponents == directory.standardizedFileURL.pathComponents,
              file.lastPathComponent != "index.json"
        else { throw VaultError.outsideVault }
        return file
    }

    private mutating func commit(_ newItems: [VaultItem]) throws {
        try backUpLegacyIndex()
        try Self.indexFile(in: directory).save(newItems)
        items = newItems
        // Marks the vault as migrated. An existing library, even an unreadable
        // one, is never rewritten; a failed write is retried on the next commit.
        let library = Self.libraryFile(in: directory)
        if !Self.exists(library.url) { try? library.save(self.library) }
    }

    /// Before this version's first write (no library.json yet), keeps a copy
    /// of the existing index. An existing backup is never replaced.
    private func backUpLegacyIndex() throws {
        let index = Self.indexFile(in: directory).url
        let backup = directory.appending(path: Self.backupName)
        guard (try? index.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true,
              !Self.exists(Self.libraryFile(in: directory).url), !Self.exists(backup) else { return }
        try FileManager.default.copyItem(at: index, to: backup)
    }

    static let backupName = "index.v1-backup.json"

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
    }

    private static func libraryFile(in directory: URL) -> JSONFile<VaultLibrary> {
        JSONFile(url: directory.appending(path: "library.json"))
    }

    /// Explicit recovery when the index can't be read: rebuilds it from the
    /// image files directly inside `directory` (no subfolders, no symbolic
    /// links, nothing outside it). Each image is validated; none is moved,
    /// renamed or rewritten. The old index is moved aside first, never
    /// overwritten. Keep, source, original name, Recently Deleted and import
    /// dates can't be recovered from files, so items come back marked Kept
    /// (safe from Clear Inbox) and dated by their file.
    static func rebuild(directory: URL, now: Date = .now) throws -> (ScreenshotVault, VaultRebuild) {
        let manager = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .creationDateKey]
        let urls = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles])
        var items: [VaultItem] = []
        var skipped: [String] = []
        var ids = Set<UUID>()
        for url in urls.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        where url.pathExtension.lowercased() != "json" {  // indexes, backups, library
            let name = url.lastPathComponent
            let values = try? url.resourceValues(forKeys: keys)
            guard values?.isSymbolicLink != true, values?.isRegularFile == true else {
                skipped.append("\(name): not a regular file")
                continue
            }
            guard (values?.fileSize ?? 0) <= maxBytes else {
                skipped.append("\(name): larger than 100 MB")
                continue
            }
            guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), let image = try? prepare(data),
                  image.data == data  // stored formats only (TIFF is never stored as is)
            else {
                skipped.append("\(name): not a valid PNG, JPEG or HEIC image")
                continue
            }
            guard UTType(filenameExtension: url.pathExtension)?.conforms(to: image.type) == true else {
                skipped.append("\(name): extension doesn't match its contents")
                continue
            }
            let id = UUID(uuidString: url.deletingPathExtension().lastPathComponent).flatMap { ids.contains($0) ? nil : $0 } ?? UUID()
            ids.insert(id)
            items.append(VaultItem(
                id: id, fileName: name, importedAt: values?.creationDate ?? now, source: "Recovered by index rebuild",
                isKept: true, pixelWidth: image.pixelWidth, pixelHeight: image.pixelHeight,
                byteCount: image.data.count, format: image.type.identifier, sha256: image.sha256))
        }
        items.sort { $0.importedAt > $1.importedAt }

        let index = indexFile(in: directory)
        var preserved: URL?
        if exists(index.url) {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = "yyyyMMdd-HHmmss"
            let aside = directory.appending(path: "index.corrupt-\(formatter.string(from: now))-\(UUID().uuidString.prefix(8)).json")
            try manager.moveItem(at: index.url, to: aside)  // fails rather than overwrite
            preserved = aside
        }
        do {
            try index.save(items)
        } catch {
            if let preserved { try? manager.moveItem(at: preserved, to: index.url) }  // put it back
            throw error
        }
        if !exists(libraryFile(in: directory).url) { try? libraryFile(in: directory).save(VaultLibrary()) }
        let report = VaultRebuild(recovered: items.count, skipped: skipped, preservedIndex: preserved?.lastPathComponent)
        return (try ScreenshotVault(directory: directory), report)
    }

    private static func indexFile(in directory: URL) -> JSONFile<[VaultItem]> {
        JSONFile(url: directory.appending(path: "index.json"))
    }

    /// Where outbound drags get their files.
    static var exportRoot: URL {
        FileManager.default.temporaryDirectory.appending(path: "OrbitExports", directoryHint: .isDirectory)
    }

    /// A fresh copy of one item for an outbound drag, in its own folder under
    /// `root`. An APFS clone: instant, no extra space, nothing loaded into
    /// memory. Whatever the destination does with it (Finder may *move* it),
    /// the vault file is untouched. Exports older than `maxAge` are removed.
    func exportCopy(of item: VaultItem, root: URL = Self.exportRoot, maxAge: TimeInterval = exportMaxAge) throws -> URL {
        let source = try ownedFile(for: item)
        Self.removeExports(in: root, olderThan: maxAge)  // a quick folder listing
        let folder = root.appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let destination = folder.appending(path: Self.exportName(for: item))
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    /// The original screenshot's name when known ("Screenshot … .png"),
    /// otherwise "Orbit Screenshot <date>.<ext>".
    static func exportName(for item: VaultItem) -> String {
        let ext = URL(filePath: item.fileName).pathExtension
        let original = URL(filePath: item.source).lastPathComponent
        if item.source.hasPrefix("/"), URL(filePath: original).pathExtension.lowercased() == ext.lowercased() {
            return original
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
        return "Orbit Screenshot \(formatter.string(from: item.importedAt)).\(ext)"
    }

    /// Removes export folders older than `maxAge`; returns how many.
    @discardableResult
    static func removeExports(in root: URL, olderThan maxAge: TimeInterval, now: Date = .now) -> Int {
        var removed = 0
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.creationDateKey])) ?? []
        // Only Orbit's own per-drag folders (UUID names), and only when their age is known.
        for folder in folders where UUID(uuidString: folder.lastPathComponent) != nil {
            guard let created = try? folder.resourceValues(forKeys: [.creationDateKey]).creationDate else { continue }
            if now.timeIntervalSince(created) > maxAge, (try? FileManager.default.removeItem(at: folder)) != nil {
                removed += 1
            }
        }
        return removed
    }

    /// Drag copies older than this are expired.
    static let exportMaxAge: TimeInterval = 600

    /// Launch cleanup of expired drag copies, off the main actor. Returns how
    /// many folders were removed.
    static func cleanUpExpiredExports(in root: URL = exportRoot, now: Date = .now) async -> Int {
        await Task.detached(priority: .utility) { removeExports(in: root, olderThan: exportMaxAge, now: now) }.value
    }
}
