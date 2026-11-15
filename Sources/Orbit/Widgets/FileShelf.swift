import AppKit
import Quartz
import QuickLookThumbnailing
import SwiftUI
import UniformTypeIdentifiers

// File Shelf (Milestone 9): a place to park files for a while. Separate from
// the Screenshot Vault. Rules:
// - Dropping a file shelves a *reference* (a bookmark). The original is never
//   moved, renamed or modified.
// - "Keep a copy" is explicit: the copy goes in Orbit's own folder
//   (Shelf/<id>/<name>), one folder per item, so nothing is ever overwritten.
// - Name, size and a thumbnail are taken at drop time (when your drop grants
//   access); afterwards Orbit touches the original only when you drag it
//   out, open it or reveal it, so protected folders aren't read in the background.
// - Items expire (7 days by default): a copy's file is deleted, a reference is
//   only forgotten. Nothing is uploaded anywhere.
// - Projects (Milestone 14) come from paths Orbit already knows (AI Hub
//   session folders, the Projects folder) by string match only: Orbit never
//   walks up the disk looking for a repository (that would read folders the
//   drop didn't grant).

struct ShelfItem: Codable, Identifiable, Equatable, Sendable {
    enum Storage: String, Codable, Sendable { case reference, copy }

    let id: UUID
    var name: String
    var storage: Storage
    /// The original's bookmark (reference), or nil for a copy.
    var bookmark: Data?
    /// Where it was when shelved (a reference), or the copy's path.
    var path: String
    var size: Int64
    var isFolder: Bool
    var typeIdentifier: String?
    var addedAt: Date
    /// A copy's original location (Milestone 14), for grouping by project. nil for a reference (its `path` is the original).
    var originalPath: String? = nil

    /// Where the file came from: the original's path, for a reference or a copy.
    var sourcePath: String { originalPath ?? path }
}

struct ShelfIndex: Codable, Equatable, Sendable {
    var items: [ShelfItem] = []
    var expiryDays = 7
}

@MainActor @Observable
final class FileShelf {
    static let maxItems = 50
    static let maxCopyBytes: Int64 = 2 * 1024 * 1024 * 1024
    static let expiryChoices = [1, 3, 7, 30]

    private var stored: Persisted<ShelfIndex>
    var items: [ShelfItem] { stored.value.items }
    var expiryDays: Int { stored.value.expiryDays }
    private(set) var message: String?
    /// Thumbnails made at drop time, by item (memory only; rebuilt from copies or the file icon after relaunch).
    private(set) var thumbnails: [UUID: NSImage] = [:]
    var hovered: UUID?
    /// The expanded shelf's search and project filter (Milestone 14).
    var query = ""
    var projectFilter: String?
    /// Known project folders (AI Hub session folders) and folders of projects (~/Developer). Set by the app.
    @ObservationIgnored var projectRoots: @MainActor () -> (roots: [String], containers: [String]) = { ([], []) }
    @ObservationIgnored let folder: URL
    @ObservationIgnored private let clock: () -> Date

    init(file: JSONFile<ShelfIndex>?, folder: URL, clock: @escaping () -> Date = { .now }) {
        stored = file.map { Persisted($0, initial: ShelfIndex()) } ?? Persisted(memory: ShelfIndex())
        self.folder = folder
        self.clock = clock
        expire()
    }

    // MARK: Adding

    /// Shelves dropped files (references). Returns how many were added.
    @discardableResult
    func add(_ urls: [URL], copy: Bool = false) -> Int {
        message = nil
        var added = 0
        for url in urls {
            guard items.count < Self.maxItems else { message = "The shelf holds \(Self.maxItems) items."; break }
            switch Self.inspect(url) {
            case .failure(let refusal): message = refusal.reason
            case .success(let info):
                if !copy, items.contains(where: { $0.storage == .reference && $0.path == url.path(percentEncoded: false) }) { continue }
                var item = ShelfItem(id: UUID(), name: url.lastPathComponent, storage: .reference,
                                     bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil),
                                     path: url.path(percentEncoded: false), size: info.size, isFolder: info.isFolder,
                                     typeIdentifier: info.type, addedAt: clock())
                if copy {
                    guard let copied = makeCopy(of: url, item: item) else { continue }
                    item = copied
                }
                stored.update { $0.items.insert(item, at: 0) }
                thumbnail(for: item, from: url)
                added += 1
            }
        }
        return added
    }

    struct FileInfo { var size: Int64; var isFolder: Bool; var type: String? }
    struct Refusal: Error, Equatable { let reason: String }

    /// Only regular files and folders on a local volume; never a symlink's target by surprise.
    nonisolated static func inspect(_ url: URL) -> Result<FileInfo, Refusal> {
        guard url.isFileURL else { return .failure(Refusal(reason: "Only files can go on the shelf.")) }
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey,
                                                             .totalFileAllocatedSizeKey, .contentTypeKey]) else {
            return .failure(Refusal(reason: "\(url.lastPathComponent) couldn't be read."))
        }
        if values.isSymbolicLink == true { return .failure(Refusal(reason: "Links aren't shelved; drop the file itself.")) }
        guard values.isRegularFile == true || values.isDirectory == true else { return .failure(Refusal(reason: "\(url.lastPathComponent) isn't a file or folder.")) }
        let size = Int64(values.fileSize ?? values.totalFileAllocatedSize ?? 0)
        return .success(FileInfo(size: size, isFolder: values.isDirectory == true, type: values.contentType?.identifier))
    }

    /// Copies into Shelf/<id>/<name>: a fresh folder per item, so nothing is overwritten.
    private func makeCopy(of url: URL, item: ShelfItem) -> ShelfItem? {
        if item.isFolder { message = "Folders are shelved as references, not copied."; return nil }
        guard item.size <= Self.maxCopyBytes else { message = "\(item.name) is over 2 GB; shelve a reference instead."; return nil }
        let destination = folder.appending(path: item.id.uuidString, directoryHint: .isDirectory).appending(path: item.name)
        do {
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: url, to: destination)
        } catch {
            message = "\(item.name) couldn't be copied."
            return nil
        }
        var copy = item
        copy.storage = .copy
        copy.bookmark = nil
        copy.path = destination.path(percentEncoded: false)
        copy.originalPath = url.path(percentEncoded: false)
        return copy
    }

    private func thumbnail(for item: ShelfItem, from url: URL) {
        let request = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 64, height: 64), scale: 2, representationTypes: .thumbnail)
        let id = item.id
        QLThumbnailGenerator.shared.generateBestRepresentation(for: request) { representation, _ in
            guard let image = representation?.nsImage else { return }
            Task { @MainActor [weak self] in self?.thumbnails[id] = image }
        }
    }

    // MARK: Using

    /// The file's current location (a reference follows a move via its bookmark); nil if it's gone.
    func resolve(_ item: ShelfItem) -> URL? {
        if item.storage == .reference, let bookmark = item.bookmark {
            var stale = false
            if let url = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI], relativeTo: nil, bookmarkDataIsStale: &stale),
               FileManager.default.fileExists(atPath: url.path(percentEncoded: false)) { return url }
        }
        let url = URL(filePath: item.path)
        return FileManager.default.fileExists(atPath: item.path) ? url : nil
    }

    func reveal(_ item: ShelfItem) {
        guard let url = resolve(item) else { message = "\(item.name) is no longer there."; return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// The path, shell-quoted, on the clipboard: paste it to an agent (the AI Hub's safe hand-off).
    func copyPathForAgent(_ item: ShelfItem) {
        guard let url = resolve(item) else { message = "\(item.name) is no longer there."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Self.quoted(url.path(percentEncoded: false)), forType: .string)
        message = "Path copied: paste it into your agent."
    }

    nonisolated static func quoted(_ path: String) -> String { "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    /// Several shelved paths, each shell-quoted, space-separated, for an agent's prompt. Missing files are left out and named.
    func copyPathsForAgent(_ chosen: [ShelfItem]) {
        let paths = agentPaths(chosen)
        guard paths.found > 0 else { message = "Those files are no longer there."; return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(paths.text, forType: .string)
        message = "\(paths.found) path\(paths.found == 1 ? "" : "s") copied" + (paths.missing > 0 ? "; \(paths.missing) no longer there." : ".")
    }

    /// The text `copyPathsForAgent` puts on the clipboard: each file that's still there, quoted, space-separated.
    func agentPaths(_ chosen: [ShelfItem]) -> (text: String, found: Int, missing: Int) {
        let found = chosen.compactMap { item in resolve(item).map { Self.quoted($0.path(percentEncoded: false)) } }
        return (found.joined(separator: " "), found.count, chosen.count - found.count)
    }

    // MARK: Finding (Milestone 14)

    /// The project a path belongs to: the longest known project folder containing it, else
    /// the first folder inside a folder of projects. Pure string matching; nothing is read from disk.
    nonisolated static func project(of path: String, roots: [String], containers: [String]) -> String? {
        func inside(_ folder: String) -> Bool {
            let base = trimmed(folder)
            return !base.isEmpty && path.hasPrefix(base + "/")
        }
        if let root = roots.filter(inside).map(trimmed).max(by: { $0.count < $1.count }) { return root }
        for container in containers where inside(container) {
            let base = trimmed(container)
            let rest = path.dropFirst(base.count + 1)
            // A file directly in the folder of projects isn't a project of its own.
            guard rest.contains("/"), let first = rest.split(separator: "/").first else { continue }
            return base + "/" + first
        }
        return nil
    }

    /// A folder path without trailing slashes.
    nonisolated static func trimmed(_ folder: String) -> String {
        var base = Substring(folder)
        while base.hasSuffix("/") { base = base.dropLast() }
        return String(base)
    }

    func project(of item: ShelfItem) -> String? {
        let known = projectRoots()
        return Self.project(of: item.sourcePath, roots: known.roots, containers: known.containers)
    }

    /// The projects on the shelf, by name, for the filter.
    var projects: [String] {
        Array(Set(items.compactMap(project(of:)))).sorted { ($0 as NSString).lastPathComponent.localizedStandardCompare(($1 as NSString).lastPathComponent) == .orderedAscending }
    }

    /// Newest first, narrowed by the search (name or folder) and the project filter.
    var visibleItems: [ShelfItem] {
        let words = query.lowercased().split(separator: " ")
        return items.sorted { $0.addedAt > $1.addedAt }.filter { item in
            (projectFilter == nil || project(of: item) == projectFilter)
                && words.allSatisfy { item.name.lowercased().contains($0) || item.sourcePath.lowercased().contains($0) }
        }
    }

    /// Shelved files inside `folder` (an agent session's working folder), newest first.
    func items(inside folder: String) -> [ShelfItem] {
        let base = Self.trimmed(folder)
        guard !base.isEmpty else { return [] }
        return items.filter { $0.sourcePath.hasPrefix(base + "/") }.sorted { $0.addedAt > $1.addedAt }
    }

    /// Quick Look, the system's own preview (read-only: nothing is opened in another app or run).
    func preview(_ item: ShelfItem) {
        guard let url = resolve(item) else { message = "\(item.name) is no longer there."; return }
        ShelfQuickLook.shared.show(url)
    }

    /// Off the shelf. A copy's file goes too; a reference's original is never touched.
    func remove(_ item: ShelfItem) {
        if item.storage == .copy { deleteCopy(item) }
        thumbnails[item.id] = nil
        stored.update { $0.items.removeAll { $0.id == item.id } }
    }

    func clear() { items.forEach(remove) }

    func setExpiry(_ days: Int) {
        stored.update { $0.expiryDays = days }
        expire()
    }

    /// Drops items older than the expiry (at launch and when shown).
    func expire() {
        let limit = clock().addingTimeInterval(-TimeInterval(expiryDays) * 86_400)
        for item in items where item.addedAt < limit { remove(item) }
    }

    private func deleteCopy(_ item: ShelfItem) {
        // Only ever inside Orbit's own shelf folder.
        let copyFolder = URL(filePath: item.path).deletingLastPathComponent().standardizedFileURL
        guard copyFolder.deletingLastPathComponent().path(percentEncoded: false) == folder.standardizedFileURL.path(percentEncoded: false),
              copyFolder.lastPathComponent == item.id.uuidString else { return }
        try? FileManager.default.removeItem(at: copyFolder)
    }
}

/// Feeds one file to the shared Quick Look panel.
@MainActor final class ShelfQuickLook: NSObject, @preconcurrency QLPreviewPanelDataSource {
    static let shared = ShelfQuickLook()
    private(set) var url: URL?

    func show(_ url: URL) {
        self.url = url
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()
        panel.makeKeyAndOrderFront(nil)
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { url == nil ? 0 : 1 }
    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! { url as NSURL? }
}

// MARK: Widget

@MainActor
final class FileShelfWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "fileShelf", title: "File Shelf", description: "Park files for later; drag them out anywhere",
        symbol: "tray.full", category: .productivity, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    let shelf: FileShelf
    var state: WidgetState { .ready }

    init(shelf: FileShelf) { self.shelf = shelf }

    func start() { shelf.expire() }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(FileShelfView(shelf: shelf, compact: presentation == .compact))
    }
}

private struct FileShelfView: View {
    let shelf: FileShelf
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if shelf.items.isEmpty {
                VStack(spacing: 6) {
                    Image(systemName: "tray.and.arrow.down").font(.system(size: 20)).foregroundStyle(Theme.secondary)
                    Text("Drop files here to keep them handy. Originals stay where they are.")
                        .font(OrbitType.caption).foregroundStyle(Theme.secondary).multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.tertiary, style: StrokeStyle(lineWidth: 1, dash: [5, 4])))
            } else {
                if !compact { finder }
                let shown = compact ? Array(shelf.items.prefix(3)) : shelf.visibleItems
                HubScroll(axes: .horizontal, indicators: .never) {
                    HStack(spacing: 8) {
                        ForEach(shown) { item in tile(item) }
                        if shown.isEmpty {
                            Text("Nothing matches.").font(OrbitType.caption).foregroundStyle(Theme.tertiary).frame(height: 80)
                        }
                    }
                }
                HStack(spacing: 10) {
                    if let message = shelf.message {
                        Text(message).font(OrbitType.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                    } else {
                        Text("\(shelf.items.count) item\(shelf.items.count == 1 ? "" : "s") · kept \(shelf.expiryDays) day\(shelf.expiryDays == 1 ? "" : "s")")
                            .font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                    }
                    Spacer()
                    if !compact {
                        Menu("Keep for") {
                            ForEach(FileShelf.expiryChoices, id: \.self) { days in
                                Button("\(days) day\(days == 1 ? "" : "s")") { shelf.setExpiry(days) }
                            }
                        }
                        .menuStyle(.borderlessButton).fixedSize().font(OrbitType.caption)
                        OrbitLinkButton(title: "Clear", action: shelf.clear)
                    }
                }
            }
        }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in shelf.add([url]) }
                }
            }
            return true
        }
    }

    /// Search, the project filter, and every visible path at once for an agent.
    private var finder: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").font(.system(size: 10)).foregroundStyle(Theme.tertiary)
            TextField("Search the shelf", text: Binding(get: { shelf.query }, set: { shelf.query = $0 }))
                .textFieldStyle(.plain).font(OrbitType.caption)
            let projects = shelf.projects
            if !projects.isEmpty {
                Menu(shelf.projectFilter.map { ($0 as NSString).lastPathComponent } ?? "All projects") {
                    Button("All projects") { shelf.projectFilter = nil }
                    Divider()
                    ForEach(projects, id: \.self) { project in
                        Button((project as NSString).lastPathComponent) { shelf.projectFilter = project }
                    }
                }
                .menuStyle(.borderlessButton).fixedSize().font(OrbitType.caption)
            }
            OrbitLinkButton(title: "Copy paths") { shelf.copyPathsForAgent(shelf.visibleItems) }
                .help("Every file shown, shell-quoted, ready to paste into an agent")
        }
    }

    private func tile(_ item: ShelfItem) -> some View {
        VStack(spacing: 4) {
            ZStack(alignment: .bottomTrailing) {
                Group {
                    if let thumbnail = shelf.thumbnails[item.id] {
                        Image(nsImage: thumbnail).resizable().scaledToFit()
                    } else {
                        Image(nsImage: NSWorkspace.shared.icon(for: item.typeIdentifier.flatMap(UTType.init) ?? (item.isFolder ? .folder : .data)))
                            .resizable().scaledToFit()
                    }
                }
                .frame(width: 44, height: 44)
                Image(systemName: item.storage == .copy ? "doc.on.doc.fill" : "link")
                    .font(.system(size: 8, weight: .bold)).foregroundStyle(.white)
                    .padding(3).background(item.storage == .copy ? Theme.accent : Color.gray, in: .circle)
                    .help(item.storage == .copy ? "Orbit's own copy" : "A link to the original (not copied)")
            }
            Text(item.name).font(.system(size: 9.5, weight: .medium)).lineLimit(1).truncationMode(.middle).frame(width: 64)
            Text(item.isFolder ? "Folder" : ByteCountFormatter.string(fromByteCount: item.size, countStyle: .file))
                .font(.system(size: 8.5)).foregroundStyle(Theme.tertiary)
        }
        .padding(6)
        .background(shelf.hovered == item.id ? Theme.selectedFill : OrbitGlass.surfaceFill, in: .rect(cornerRadius: 10))
        .onHover { inside in shelf.hovered = inside ? item.id : (shelf.hovered == item.id ? nil : shelf.hovered) }
        .onDrag {  // drag out: the original (or Orbit's copy), never moved
            guard let url = shelf.resolve(item) else { return NSItemProvider() }
            return NSItemProvider(object: url as NSURL)
        }
        .contextMenu {
            Button("Quick Look") { shelf.preview(item) }
            Button("Show in Finder") { shelf.reveal(item) }
            Button("Copy Path for an Agent") { shelf.copyPathForAgent(item) }
            if item.storage == .reference, let url = shelf.resolve(item), !item.isFolder {
                Button("Keep a Copy in Orbit") {
                    if shelf.add([url], copy: true) > 0 { shelf.remove(item) }
                }
            }
            Divider()
            Button(item.storage == .copy ? "Remove (deletes Orbit's copy)" : "Remove from Shelf", role: .destructive) { shelf.remove(item) }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(item.name), \(item.storage == .copy ? "copy" : "reference")")
        .help([item.storage == .copy ? "Orbit's copy of \(item.sourcePath)" : item.sourcePath,
               shelf.project(of: item).map { "Project: \(($0 as NSString).lastPathComponent)" }].compactMap { $0 }.joined(separator: "\n"))
    }
}
