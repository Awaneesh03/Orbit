import SwiftUI
import UniformTypeIdentifiers

enum VaultImportOutcome: Equatable {
    case saved(VaultItem)
    case duplicate(VaultItem)
    case restored(VaultItem)
    case failed(String)

    var message: String {
        switch self {
        case .saved: "Screenshot saved to Vault"
        case .duplicate: "Already in your Vault"
        case .restored: "Restored from Recently Deleted"
        case .failed(let reason): reason
        }
    }

    /// The short headline for the dashboard notice; the full reason for a
    /// failure is shown inside the Vault (`message`).
    var notice: String {
        switch self {
        case .saved, .duplicate, .restored: message
        case .failed: "Screenshot not saved"
        }
    }

    var isError: Bool {
        if case .failed = self { return true }
        return false
    }

    /// For the log: no paths or content.
    var summary: String {
        switch self {
        case .saved(let item): "saved \(item.pixelWidth ?? 0)x\(item.pixelHeight ?? 0) \(item.format ?? "?")"
        case .duplicate: "duplicate"
        case .restored: "restored from Recently Deleted"
        case .failed(let reason): "failed: \(reason)"
        }
    }
}

/// Screenshot Vault: a local inbox with previews. Screenshots arrive by
/// dragging them onto the notch (see `ScreenshotDrag`) or through the system
/// Paste button. No folder watching, no screen recording; originals are never
/// touched.
@MainActor @Observable
final class VaultWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "vault", title: "Screenshot Vault", description: "A local inbox for screenshots",
        symbol: "photo.stack", category: .screenshots, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    struct Feedback: Equatable {
        let text: String
        let isError: Bool
    }

    let directory: URL
    private(set) var vault: ScreenshotVault?
    private(set) var problem: String?
    /// The last action's result, shown under the thumbnails.
    private(set) var feedback: Feedback?
    var selection: UUID?
    /// Showing Recently Deleted instead of the Vault.
    var showsDeleted = false {
        didSet {
            selection = nil
            cancelPending()
        }
    }
    /// Clear Inbox is waiting for confirmation: how many it would move.
    private(set) var pendingClear: Int?
    /// Permanent deletion of this item is waiting for confirmation.
    private(set) var pendingPurge: UUID?
    struct Preview {
        let id: UUID
        let image: NSImage
    }

    /// The selected item's decoded preview; only one is held at a time.
    private(set) var preview: Preview?
    /// The preview of this item couldn't be decoded.
    private(set) var previewFailed: UUID?
    /// Bumped when a thumbnail arrives, so thumbnail views redraw.
    private(set) var thumbnailRevision = 0
    @ObservationIgnored let thumbnails = ThumbnailCache()
    @ObservationIgnored private var thumbnailsLoading: Set<UUID> = []
    @ObservationIgnored private var thumbnailFailures: Set<UUID> = []
    /// The newest queued import; each one waits for the one before it.
    @ObservationIgnored private var importQueue: Task<Void, Never>?
    private let promiseQueue = OperationQueue()

    var state: WidgetState { problem.map(WidgetState.failed) ?? .ready }
    /// In the Vault, newest first (not Recently Deleted).
    var items: [VaultItem] { vault?.active ?? [] }
    var deletedItems: [VaultItem] { vault?.recentlyDeleted ?? [] }
    var visibleItems: [VaultItem] { showsDeleted ? deletedItems : items }
    var selectedItem: VaultItem? { visibleItems.first { $0.id == selection } ?? visibleItems.first }

    init(directory: URL) {
        self.directory = directory
        do {
            vault = try ScreenshotVault(directory: directory)
        } catch {
            problem = "Couldn't read the vault index. Nothing was changed. Rebuild it in Orbit Settings › Storage."
        }
    }

    /// Leaving the dashboard drops any half-finished confirmation and the
    /// large preview image (thumbnails stay in their bounded cache).
    func stop() {
        cancelPending()
        preview = nil
    }

    @discardableResult
    func importData(_ data: Data, source: String) async -> VaultImportOutcome {
        await finish(enqueueData(data, source: source))
    }

    @discardableResult
    func importFile(_ url: URL, source: String? = nil) async -> VaultImportOutcome {
        await finish(enqueueFile(url, source: source))
    }

    func importPasted(_ data: Data) { enqueueData(data, source: "Clipboard") }

    /// Waits for every queued import (tests, scripted checks).
    func importsFinished() async { await importQueue?.value }

    @discardableResult
    private func enqueueData(_ data: Data, source: String, report: Report? = nil) -> Task<VaultImportOutcome, Never> {
        enqueueImport(source: source, report: report) { try ScreenshotVault.prepare(data) }
    }

    @discardableResult
    private func enqueueFile(_ url: URL, source: String? = nil, report: Report? = nil) -> Task<VaultImportOutcome, Never> {
        enqueueImport(source: source ?? url.path(percentEncoded: false), report: report) {
            try ScreenshotVault.prepare(ScreenshotVault.readImport(url))
        }
    }

    typealias Report = @MainActor @Sendable (VaultImportOutcome) -> Void

    /// Awaits a queued import; cancelling the caller cancels the import.
    private func finish(_ job: Task<VaultImportOutcome, Never>) async -> VaultImportOutcome {
        await withTaskCancellationHandler { await job.value } onCancel: { job.cancel() }
    }

    /// Imports run one at a time, in the order queued, so ordering and
    /// duplicate detection are predictable. Reading, validating, decoding,
    /// hashing, converting and writing the file happen off the main actor;
    /// the vault itself is only changed here, on the main actor.
    private func enqueueImport(source: String, report: Report?, prepare: @escaping @Sendable () throws -> PreparedImage)
        -> Task<VaultImportOutcome, Never> {
        let previous = importQueue
        let job = Task { [weak self] () -> VaultImportOutcome in
            await previous?.value
            guard let self else { return .failed("The vault is unavailable.") }
            let result = await self.runImport(source: source, prepare: prepare)
            report?(result)  // in queue order, before the next import starts
            return result
        }
        importQueue = Task { _ = await job.value }
        return job
    }

    private func runImport(source: String, prepare: @escaping @Sendable () throws -> PreparedImage) async -> VaultImportOutcome {
        guard vault != nil else { return .failed(problem ?? "The vault is unavailable.") }
        do {
            try Task.checkCancellation()
            let image = try await Task.detached(priority: .userInitiated) { try prepare() }.value
            try Task.checkCancellation()
            guard var current = vault else { return .failed(problem ?? "The vault is unavailable.") }
            if let resolved = try current.resolveDuplicate(of: image) {
                vault = current
                return outcome(resolved)
            }
            let item = current.newItem(for: image, source: source)
            let directory = current.directory
            try await Task.detached(priority: .userInitiated) {
                try ScreenshotVault.writeFile(image, for: item, in: directory)
            }.value
            guard var latest = vault else { return .failed("The vault is unavailable.") }
            if Task.isCancelled {
                latest.discardUnregistered(item)
                throw CancellationError()
            }
            let result = try latest.register(item, sha256: image.sha256)  // removes the file if it fails
            vault = latest
            return outcome(result)
        } catch is CancellationError {
            return .failed("Import cancelled.")
        } catch {
            let message = Self.message(for: error)
            feedback = Feedback(text: message, isError: true)
            return .failed(message)
        }
    }

    private func outcome(_ result: VaultImport) -> VaultImportOutcome {
        showsDeleted = false
        selection = result.item.id
        switch result {
        case .added(let item):
            feedback = nil
            return .saved(item)
        case .duplicate(let item):
            feedback = nil
            return .duplicate(item)
        case .restored(let item):
            say("Restored from Recently Deleted.")
            return .restored(item)
        }
    }

    /// Launch: hashes items saved before hashes existed, off the main actor,
    /// then saves what it found in one index write. Files are only read; a
    /// missing, unreadable or invalid file is skipped (and tried again next
    /// launch). Returns how many items were filled in.
    @discardableResult
    func backfillHashes() async -> Int {
        guard let pending = vault?.filesMissingHash, !pending.isEmpty else { return 0 }
        let found = await Task.detached(priority: .utility) {
            pending.compactMap { entry in ScreenshotVault.facts(ofStoredFile: entry.url).map { (entry.id, $0) } }
        }.value
        guard !found.isEmpty, var current = vault else { return 0 }
        do {
            try current.fillMissingMetadata(Dictionary(uniqueKeysWithValues: found))
            vault = current
            return found.count
        } catch {
            return 0  // nothing was written; tried again next launch
        }
    }

    /// Imports everything dropped on the notch and reports each outcome.
    /// Promised files are written by the sender into a temporary staging
    /// folder of Orbit's own, imported, then that staging copy is removed.
    func receive(_ dropped: [ScreenshotDrag.Item], report: @escaping Report) {
        for item in dropped {
            switch item {
            case .file(let url):
                enqueueFile(url, report: report)
            case .data(let data):
                enqueueData(data, source: "Drag and drop", report: report)
            case .promise(let receiver):
                let staging = FileManager.default.temporaryDirectory
                    .appending(path: "OrbitIncoming-\(UUID().uuidString)", directoryHint: .isDirectory)
                try? FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
                receiver.receivePromisedFiles(atDestination: staging, options: [:], operationQueue: promiseQueue) {
                    [weak self] url, error in
                    let failed = error != nil
                    Task { @MainActor in
                        defer { try? FileManager.default.removeItem(at: staging) }  // our staging copy only
                        guard let self, !failed else {
                            report(.failed("Couldn't receive the dragged screenshot."))
                            return
                        }
                        report(await self.finish(self.enqueueFile(url, source: "Screenshot (drag)")))
                    }
                }
            }
        }
    }

    func toggleKept(_ item: VaultItem) { mutate { try $0.setKept(item.id, !item.isKept) } }

    /// Moves the item to Recently Deleted (recoverable for 30 days).
    func delete(_ item: VaultItem) {
        guard mutate({ try $0.delete(item.id) }) else { return }
        if selection == item.id { selection = nil }
        say("Moved to Recently Deleted. Restore it within 30 days.")
    }

    func restore(_ item: VaultItem) {
        guard mutate({ try $0.restore(item.id) }) else { return }
        if selection == item.id { selection = nil }
        say("Restored to the Vault.")
    }

    func requestPurge(_ item: VaultItem) {
        pendingClear = nil
        pendingPurge = item.id
    }

    func confirmPurge() {
        guard let id = pendingPurge else { return }
        pendingPurge = nil
        guard mutate({ try $0.purge(id) }) else { return }
        thumbnails.remove(id)
        if preview?.id == id { preview = nil }
        if selection == id { selection = nil }
        say("Deleted permanently.")
    }

    func requestClearInbox() {
        pendingPurge = nil
        let count = vault?.inbox.count ?? 0
        pendingClear = count > 0 ? count : nil
    }

    func confirmClearInbox() {
        guard pendingClear != nil else { return }
        pendingClear = nil
        var moved = 0
        guard mutate({ moved = try $0.clearInbox() }) else { return }
        selection = nil
        say("Moved \(moved) screenshot\(moved == 1 ? "" : "s") to Recently Deleted.")
    }

    func cancelPending() {
        pendingClear = nil
        pendingPurge = nil
    }

    /// Launch cleanup: purges items that have been in Recently Deleted for 30 days.
    @discardableResult
    func purgeExpired(now: Date = .now) -> Int {
        var purged = 0
        mutate { purged = try $0.purgeExpired(now: now) }
        return purged
    }

    /// Explicit recovery when the index can't be read (Settings › Storage).
    func rebuildIndex() -> Feedback {
        guard problem != nil else { return Feedback(text: "The Vault index is readable; nothing to rebuild.", isError: false) }
        do {
            let (rebuilt, report) = try ScreenshotVault.rebuild(directory: directory)
            vault = rebuilt
            problem = nil
            thumbnails.removeAll()
            thumbnailFailures = []
            preview = nil
            return Feedback(text: report.summary, isError: false)
        } catch {
            return Feedback(text: "Couldn't rebuild the index. Nothing was changed.", isError: true)
        }
    }

    func revealInFinder() {
        guard let directory = vault?.directory else { return }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        NSWorkspace.shared.open(directory)
    }

    /// What an outbound drag hands to another app: a fresh export copy (see
    /// `ScreenshotVault.exportCopy`), never the vault file itself.
    func dragProvider(for item: VaultItem) -> NSItemProvider {
        guard let vault, let url = try? vault.exportCopy(of: item),
              let provider = NSItemProvider(contentsOf: url) else { return NSItemProvider() }
        provider.suggestedName = url.deletingPathExtension().lastPathComponent
        return provider
    }

    /// The cached thumbnail, or nil until `loadThumbnail` has made it.
    func thumbnail(_ item: VaultItem) -> NSImage? {
        _ = thumbnailRevision  // redraw when thumbnails arrive
        return thumbnails.image(for: item.id)
    }

    /// Decodes a thumbnail off the main actor (once; failures aren't retried).
    /// Skipped if the view asking for it has already gone away.
    func loadThumbnail(_ item: VaultItem) async {
        guard let vault, thumbnails.image(for: item.id) == nil, !thumbnailFailures.contains(item.id),
              !thumbnailsLoading.contains(item.id), !Task.isCancelled else { return }
        thumbnailsLoading.insert(item.id)
        defer { thumbnailsLoading.remove(item.id) }
        guard let image = await VaultImages.image(at: vault.url(for: item), maxPixelSize: VaultImages.thumbnailPixels) else {
            if !Task.isCancelled { thumbnailFailures.insert(item.id) }
            return
        }
        thumbnails.insert(NSImage(cgImage: image, size: .zero), cost: VaultImages.cost(of: image), for: item.id)
        thumbnailRevision += 1
    }

    /// What the preview area shows: the decoded preview, or the thumbnail while it loads.
    func previewImage(for item: VaultItem) -> NSImage? {
        if let preview, preview.id == item.id { return preview.image }
        return thumbnail(item)
    }

    /// Decodes the selected item's preview off the main actor. The previous
    /// preview is released first; a result for an item that is no longer
    /// selected is dropped.
    func loadPreview(_ item: VaultItem) async {
        guard preview?.id != item.id, let vault else { return }
        preview = nil
        previewFailed = nil
        let image = await VaultImages.image(at: vault.url(for: item), maxPixelSize: VaultImages.previewPixels)
        guard !Task.isCancelled, selectedItem?.id == item.id else { return }
        if let image {
            preview = Preview(id: item.id, image: NSImage(cgImage: image, size: .zero))
        } else {
            previewFailed = item.id
        }
    }

    static func message(for error: any Error) -> String {
        switch error as? VaultError {
        case .notAnImage?: "That isn't an image Orbit can read."
        case .unsupportedFormat(let format)?: "\(format.uppercased()) isn't supported. Use PNG, TIFF, JPEG or HEIC."
        case .tooLarge?: "That image is larger than 100 MB."
        default: "Couldn't save the screenshot. Your Vault is unchanged."
        }
    }

    /// Runs a change; on failure the vault (in memory and on disk) is unchanged.
    @discardableResult
    private func mutate(_ change: (inout ScreenshotVault) throws -> Void) -> Bool {
        guard var current = vault else { return false }
        do {
            try change(&current)
            vault = current
            return true
        } catch {
            feedback = Feedback(text: "Couldn't update the Vault. Nothing was changed.", isError: true)
            return false
        }
    }

    private func say(_ text: String) { feedback = Feedback(text: text, isError: false) }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(VaultView(widget: self, isCompact: presentation == .compact))
    }
}

private struct VaultView: View {
    let widget: VaultWidget
    let isCompact: Bool

    var body: some View {
        if isCompact {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    pasteButton
                    Spacer()
                    Text("\(widget.vault?.inbox.count ?? 0) in inbox").foregroundStyle(Theme.secondary)
                }
                HStack(spacing: 6) {
                    ForEach(widget.items.prefix(3)) { thumb($0) }
                }
            }
        } else {
            HStack(alignment: .top, spacing: Theme.spacing) {
                VStack(alignment: .leading, spacing: 8) {
                    if widget.showsDeleted { deletedHeader } else { vaultHeader }
                    if let count = widget.pendingClear { clearConfirmation(count) }
                    if widget.visibleItems.isEmpty {
                        Text(widget.showsDeleted
                             ? "Nothing in Recently Deleted."
                             : "No screenshots yet. Drag a screenshot thumbnail onto the notch, or copy one (⌃⇧⌘4) and press Paste.")
                            .foregroundStyle(Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    } else {
                        ScrollView {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: 74), spacing: 6)], spacing: 6) {
                                ForEach(widget.visibleItems) { thumb($0) }
                            }
                        }
                        .scrollIndicators(.never)
                    }
                    if let feedback = widget.feedback {
                        Text(feedback.text)
                            .foregroundStyle(feedback.isError ? Color.red : Theme.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(width: 260)
                preview
            }
        }
    }

    private var vaultHeader: some View {
        HStack(spacing: 6) {
            pasteButton
            Button("Clear inbox") { widget.requestClearInbox() }
                .disabled(widget.vault?.inbox.isEmpty ?? true)
                .help("Move screenshots that aren't kept to Recently Deleted")
            Spacer(minLength: 0)
            Button { widget.showsDeleted = true } label: {
                if widget.deletedItems.isEmpty {
                    Image(systemName: "trash")
                } else {
                    Label("\(widget.deletedItems.count)", systemImage: "trash")
                }
            }
            .help("Recently Deleted")
            Button { widget.revealInFinder() } label: { Image(systemName: "folder") }
                .help("Show the vault folder in Finder")
        }
        .controlSize(.small)
    }

    private var deletedHeader: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Button { widget.showsDeleted = false } label: { Label("Vault", systemImage: "chevron.left") }
                    .controlSize(.small)
                Text("Recently Deleted").font(.system(size: 12, weight: .semibold))
            }
            Text("Kept for 30 days, then removed for good.").foregroundStyle(Theme.tertiary)
        }
    }

    private func clearConfirmation(_ count: Int) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Move \(count) screenshot\(count == 1 ? "" : "s") to Recently Deleted?")
                .font(.system(size: 12, weight: .semibold))
            Text("Kept screenshots stay. You can restore any of them for 30 days.")
                .foregroundStyle(Theme.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 6) {
                Button("Cancel") { widget.cancelPending() }
                Button("Move") { widget.confirmClearInbox() }
            }
            .controlSize(.small)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Theme.cardFill, in: .rect(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Theme.cardStroke))
    }

    private var pasteButton: some View {
        // The system paste control: user-initiated, so no clipboard-privacy alert.
        PasteButton(supportedContentTypes: [.png, .tiff]) { providers in
            for provider in providers {
                let type: UTType = provider.hasItemConformingToTypeIdentifier(UTType.png.identifier) ? .png : .tiff
                _ = provider.loadDataRepresentation(for: type) { [widget] data, _ in
                    guard let data else { return }
                    Task { @MainActor in widget.importPasted(data) }
                }
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.small)
    }

    @ViewBuilder
    private func thumb(_ item: VaultItem) -> some View {
        if item.isDeleted {
            thumbButton(item).help("Click to preview")
        } else {
            thumbButton(item)
                .onDrag { widget.dragProvider(for: item) }  // click selects; drag exports a copy
                .help("Click to preview, drag into another app")
        }
    }

    private func thumbButton(_ item: VaultItem) -> some View {
        Button { widget.selection = item.id } label: {
            ZStack(alignment: .topTrailing) {
                Group {
                    if let image = widget.thumbnail(item) {
                        Image(nsImage: image).resizable().scaledToFill()
                    } else {
                        Theme.cardFill
                    }
                }
                .frame(width: 74, height: 48)
                .task(id: item.id) { await widget.loadThumbnail(item) }
                .clipShape(.rect(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(widget.selectedItem?.id == item.id ? Theme.accent : Theme.cardStroke, lineWidth: 1.5))
                if item.isKept {
                    Image(systemName: "pin.fill")
                        .font(.system(size: 8))
                        .padding(3)
                        .background(.black.opacity(0.6), in: .circle)
                        .padding(3)
                }
            }
        }
        .buttonStyle(DashboardButtonStyle())
    }

    @ViewBuilder
    private var preview: some View {
        if let item = widget.selectedItem {
            VStack(alignment: .leading, spacing: 8) {
                Group {
                    if let image = widget.previewImage(for: item) {
                        if item.isDeleted {
                            Image(nsImage: image).resizable().scaledToFit().opacity(0.6)
                        } else {
                            Image(nsImage: image).resizable().scaledToFit()
                                .onDrag { widget.dragProvider(for: item) }
                        }
                    } else if widget.previewFailed == item.id {
                        StatusMessage(text: "Preview unavailable", symbol: "photo")
                    } else {
                        Color.clear
                    }
                }
                .task(id: item.id) { await widget.loadPreview(item) }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Theme.cardFill, in: .rect(cornerRadius: 10))
                HStack(spacing: 6) {
                    Text(Self.caption(item))
                        .foregroundStyle(Theme.tertiary)
                        .lineLimit(1)
                        .help(item.source)
                    Spacer()
                    actions(for: item)
                }
                .controlSize(.small)
            }
        } else if widget.showsDeleted {
            StatusMessage(text: "Deleted screenshots appear here for 30 days", symbol: "trash")
        } else {
            StatusMessage(text: "Drop a screenshot on the notch to see it here", symbol: "photo.on.rectangle")
        }
    }

    @ViewBuilder
    private func actions(for item: VaultItem) -> some View {
        if !item.isDeleted {
            Button(item.isKept ? "Unkeep" : "Keep") { widget.toggleKept(item) }
            Button("Delete", role: .destructive) { widget.delete(item) }
                .help("Move to Recently Deleted")
        } else if widget.pendingPurge == item.id {
            Text("Delete permanently?").foregroundStyle(.orange)
            Button("Cancel") { widget.cancelPending() }
            Button("Delete", role: .destructive) { widget.confirmPurge() }
        } else {
            Button("Restore") { widget.restore(item) }
            Button("Delete Now…", role: .destructive) { widget.requestPurge(item) }
                .help("Delete permanently; this can't be undone")
        }
    }

    /// "1470×956 · PNG · 245 KB · 31 Oct, 1:30 AM"
    static func caption(_ item: VaultItem) -> String {
        if let deletedAt = item.deletedAt, let purge = ScreenshotVault.purgeDate(of: item) {
            let days = max(0, Calendar.current.dateComponents([.day], from: .now, to: purge).day ?? 0)
            return "Deleted \(deletedAt.formatted(date: .abbreviated, time: .shortened)) · removed in \(days) day\(days == 1 ? "" : "s")"
        }
        var parts: [String] = []
        if let width = item.pixelWidth, let height = item.pixelHeight { parts.append("\(width)×\(height)") }
        if let ext = item.format.flatMap({ UTType($0)?.preferredFilenameExtension }) { parts.append(ext.uppercased()) }
        if let bytes = item.byteCount { parts.append(Int64(bytes).formatted(.byteCount(style: .file))) }
        parts.append(item.importedAt.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }
}
