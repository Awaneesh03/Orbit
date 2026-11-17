import AppKit
import Observation
import UniformTypeIdentifiers

// The Universal Launcher (Milestone 16): one search over apps, files, projects,
// agent sessions, the File Shelf, tasks and goals, calendar events, settings
// and Orbit itself. Local only:
// - Apps: the standard Applications folders, listed (names only) and cached.
// - Files and folders: Spotlight's index (NSMetadataQuery), names only; icons
//   come from the file type, so Orbit never opens a file to search for it.
// - Everything else is Orbit's own data, already in memory.
// Nothing runs until Return: opening is what the user chose (scripts and
// executables are shown in Finder instead of run).

struct LauncherItem: Identifiable, Equatable, Codable, Sendable {
    enum Kind: String, Codable, CaseIterable, Sendable {
        case app, file, folder, project, agent, shelf, task, goal, event, setting, orbit, workspace
        /// Milestone 20: a sum typed into the search, and Apple Shortcuts.
        case calculation, shortcut

        var label: String {
            switch self {
            case .app: "App"
            case .file: "File"
            case .folder: "Folder"
            case .project: "Project"
            case .agent: "Agent"
            case .shelf: "Shelf"
            case .task: "Task"
            case .goal: "Goal"
            case .event: "Event"
            case .setting: "Setting"
            case .orbit: "Orbit"
            case .workspace: "Workspace"
            case .calculation: "Calculator"
            case .shortcut: "Shortcut"
            }
        }

        var symbol: String {
            switch self {
            case .app: "app"
            case .file: "doc"
            case .folder: "folder"
            case .project: "chevron.left.forwardslash.chevron.right"
            case .agent: "sparkles"
            case .shelf: "tray.full"
            case .task: "checklist"
            case .goal: "target"
            case .event: "calendar"
            case .setting: "gearshape"
            case .orbit: "circle.hexagongrid"
            case .workspace: "square.stack.3d.up"
            case .calculation: "equal.circle"
            case .shortcut: "square.2.layers.3d"
            }
        }

        /// Ties break toward the kinds people open most.
        var weight: Int {
            switch self {
            case .calculation: 100
            case .app: 40
            case .project, .workspace: 35
            case .agent, .event: 30
            case .orbit, .setting, .shortcut: 25
            case .task, .goal, .shelf: 20
            case .folder: 15
            case .file: 10
            }
        }
    }

    /// "<kind>:<key>": stable across launches (recents).
    let id: String
    let kind: Kind
    let title: String
    var subtitle = ""
    /// A path for apps, files, folders, projects and shelf items.
    var path: String?
    /// Extra words that find it ("display", "notch"…).
    var keywords = ""
    /// What Return does, when it isn't the kind's default (an Orbit action, a settings pane…).
    var action = ""
}

/// What the launcher can narrow to (⌘1…⌘8).
enum LauncherCategory: String, CaseIterable, Identifiable, Sendable {
    case all, apps, files, projects, agents, tasks, calendar, orbit
    var id: Self { self }

    var title: String {
        switch self {
        case .all: "All"
        case .apps: "Apps"
        case .files: "Files"
        case .projects: "Projects"
        case .agents: "Agents"
        case .tasks: "Tasks"
        case .calendar: "Calendar"
        case .orbit: "Orbit"
        }
    }

    func contains(_ kind: LauncherItem.Kind) -> Bool {
        switch self {
        case .all: true
        case .apps: kind == .app
        case .files: kind == .file || kind == .folder || kind == .shelf
        case .projects: kind == .project || kind == .workspace
        case .agents: kind == .agent
        case .tasks: kind == .task || kind == .goal
        case .calendar: kind == .event
        case .orbit: kind == .orbit || kind == .setting || kind == .workspace || kind == .shortcut
        }
    }
}

/// Fuzzy matching: prefix › word start › anywhere › letters in order (with gaps penalised).
enum FuzzyMatch {
    static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
    }

    /// nil: no match. Higher is better. `inOrder`: also match letters in order ("vsc"); off for hidden keywords.
    static func score(_ word: String, in text: String, inOrder: Bool = true) -> Int? {
        let needle = normalized(word), haystack = normalized(text)
        guard !needle.isEmpty else { return 0 }
        if haystack == needle { return 1150 }  // the exact name beats any longer one
        if haystack.hasPrefix(needle) { return 1000 - min(haystack.count - needle.count, 200) }
        if let range = haystack.range(of: needle) {
            let start = haystack[..<range.lowerBound]
            let atWord = start.last.map { !$0.isLetter && !$0.isNumber } ?? true
            return (atWord ? 800 : 600) - min(start.count, 200)
        }
        guard inOrder else { return nil }
        // Letters in order: "vsc" → "Visual Studio Code". Word starts and runs score higher.
        var score = 300
        var index = haystack.startIndex
        var previous: String.Index?
        for character in needle {
            guard let found = haystack[index...].firstIndex(of: character) else { return nil }
            let atWordStart = found == haystack.startIndex || !(haystack[haystack.index(before: found)].isLetter)
            if atWordStart { score += 25 }
            if let previous, haystack.index(after: previous) == found { score += 15 } else if previous != nil { score -= 8 }
            previous = found
            index = haystack.index(after: found)
        }
        return max(score, 1)
    }

    /// Every word of the query must match the title or the extra text; title matches count most.
    static func score(query: String, item: LauncherItem) -> Int? {
        let words = query.split(whereSeparator: \.isWhitespace).map(String.init)
        guard !words.isEmpty else { return 0 }
        var total = 0
        for word in words {
            if let title = score(word, in: item.title) {
                total += title
            } else if let other = score(word, in: item.subtitle + " " + item.keywords, inOrder: false) {
                total += other / 3
            } else {
                return nil
            }
        }
        return total
    }
}

/// Spotlight, names only (it's an index query: Orbit opens no file to answer it).
@MainActor
protocol FileSearching: AnyObject {
    func search(_ query: String, limit: Int, results: @escaping @MainActor ([LauncherItem]) -> Void)
    func cancel()
}

@MainActor
final class SpotlightSearch: FileSearching {
    private var query: NSMetadataQuery?
    private var observer: (any NSObjectProtocol)?

    func search(_ text: String, limit: Int, results: @escaping @MainActor ([LauncherItem]) -> Void) {
        cancel()
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.count >= 2 else { return results([]) }
        let query = NSMetadataQuery()
        query.searchScopes = [NSMetadataQueryUserHomeScope]
        query.predicate = NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemDisplayNameKey, "*\(trimmed)*")
        query.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSContentChangeDateKey, ascending: false)]
        self.query = query
        observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering, object: query, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let query = self.query else { return }
                query.disableUpdates()
                var items: [LauncherItem] = []
                for index in 0 ..< min(query.resultCount, limit * 3) {
                    guard let item = query.result(at: index) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String,
                          !path.contains("/Library/"), !path.contains("/."), !path.contains("/node_modules/") else { continue }
                    let isFolder = (item.value(forAttribute: "kMDItemContentType") as? String) == UTType.folder.identifier
                    items.append(LauncherItem(id: "file:" + path, kind: isFolder ? .folder : .file, title: (path as NSString).lastPathComponent,
                                              subtitle: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath, path: path))
                    if items.count >= limit { break }
                }
                self.cancel()
                results(items)
            }
        }
        query.start()
    }

    func cancel() {
        query?.stop()
        query = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }
}

enum AppCatalog {
    static let folders = ["/Applications", "/Applications/Utilities", "/System/Applications", "/System/Applications/Utilities",
                          NSHomeDirectory() + "/Applications", "/System/Library/CoreServices/Applications"]

    /// App bundles in the standard folders (one level, plus app folders like "Adobe…/"). Names only.
    nonisolated static func scan(folders: [String] = folders) -> [LauncherItem] {
        let manager = FileManager.default
        var seen = Set<String>()
        var items: [LauncherItem] = []
        func add(_ path: String) {
            let name = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
            guard seen.insert(name.lowercased()).inserted else { return }
            items.append(LauncherItem(id: "app:" + path, kind: .app, title: name,
                                      subtitle: ((path as NSString).deletingLastPathComponent as NSString).abbreviatingWithTildeInPath, path: path))
        }
        for folder in folders {
            guard let names = try? manager.contentsOfDirectory(atPath: folder) else { continue }
            for name in names.sorted() where !name.hasPrefix(".") {
                let path = folder + "/" + name
                if name.hasSuffix(".app") { add(path); continue }
                var isFolder: ObjCBool = false
                guard manager.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue, !folders.contains(path),
                      let inner = try? manager.contentsOfDirectory(atPath: path) else { continue }
                for app in inner.sorted() where app.hasSuffix(".app") { add(path + "/" + app) }
            }
        }
        return items
    }
}

struct LauncherMemory: Codable, Equatable, Sendable {
    var recentQueries: [String] = []
    var recentItems: [LauncherItem] = []
    static let queryLimit = 8
    static let itemLimit = 12
}

@MainActor @Observable
final class LauncherModel {
    var query = "" { didSet { if query != oldValue { search() } } }
    var category = LauncherCategory.all { didSet { if category != oldValue { search() } } }
    private(set) var results: [LauncherItem] = []
    var selection = 0
    private(set) var message: String?
    private(set) var isSearchingFiles = false
    private(set) var stored: Persisted<LauncherMemory>
    var memory: LauncherMemory { stored.value }

    /// Orbit's own items (projects, sessions, shelf, tasks, events, settings, features, workspaces), read when searching.
    @ObservationIgnored var sources: @MainActor () -> [LauncherItem] = { [] }
    /// Paths the active workspace prefers (ranked higher).
    @ObservationIgnored var boosted: @MainActor () -> Set<String> = { [] }
    @ObservationIgnored var searchesFiles = true
    /// Settings › Launcher: Apple Shortcuts in the results (Milestone 20).
    @ObservationIgnored var searchesShortcuts = true
    @ObservationIgnored private let files: (any FileSearching)?
    @ObservationIgnored private var apps: [LauncherItem] = []
    @ObservationIgnored private var appsScannedAt: Date?
    @ObservationIgnored private var shortcuts: [LauncherItem] = []
    @ObservationIgnored private var fileResults: [LauncherItem] = []
    @ObservationIgnored private var fileDebounce: Task<Void, Never>?
    @ObservationIgnored private let now: () -> Date
    /// Time to rank the last query (performance audit).
    private(set) var lastSearchDuration: Duration = .zero

    init(file: JSONFile<LauncherMemory>?, files: (any FileSearching)? = SpotlightSearch(), apps: [LauncherItem]? = nil,
         shortcuts: [String] = [], now: @escaping () -> Date = { .now }) {
        stored = file.map { Persisted($0, initial: LauncherMemory()) } ?? Persisted(memory: LauncherMemory())
        self.files = files
        self.now = now
        self.shortcuts = shortcuts.map(Self.shortcutItem)
        if let apps {
            self.apps = apps
            appsScannedAt = .distantFuture
        }
    }

    /// Called as the launcher opens: fresh app list at most every 10 minutes (off the main thread).
    func prepare() {
        message = nil
        selection = 0
        if let scanned = appsScannedAt, now().timeIntervalSince(scanned) < 600 { search(); return }
        appsScannedAt = now()
        Task {
            let scanned = await Task.detached(priority: .userInitiated) { AppCatalog.scan() }.value
            apps = scanned
            search()
            guard searchesShortcuts else { return }  // off: the names aren't even read
            let names = await Task.detached(priority: .utility) { ShortcutsCatalog.list() }.value
            shortcuts = names.map(Self.shortcutItem)
            search()
        }
        search()
    }

    func reset() {
        query = ""
        category = .all
        selection = 0
        files?.cancel()
        fileResults = []
    }

    /// Ranks everything for the query now; Spotlight answers shortly after (debounced).
    func search() {
        let clock = ContinuousClock()
        let start = clock.now
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty {
            fileResults = []
            files?.cancel()
            results = memory.recentItems.filter { category.contains($0.kind) }
        } else {
            results = ranked(trimmed, files: fileResults)
            scheduleFileSearch(trimmed)
        }
        selection = min(selection, max(results.count - 1, 0))
        lastSearchDuration = start.duration(to: clock.now)
    }

    private var searchable: [LauncherItem] { apps + (searchesShortcuts ? shortcuts : []) + sources() }

    /// Everything for a query: ranked items, then a sum and a timer on top when the query is one. One place,
    /// for the first pass and when Spotlight answers.
    private func ranked(_ text: String, files: [LauncherItem]) -> [LauncherItem] {
        var items = Self.rank(query: text, items: searchable + files, category: category,
                              recent: Set(memory.recentItems.map(\.id)), boosted: boosted())
        if category == .all, let sum = Self.calculation(text) { items.insert(sum, at: 0) }
        if category == .all || category == .orbit, let timer = Self.timer(text) { items.insert(timer, at: 0) }
        return items
    }

    /// "= 42" for a query that's arithmetic; Return copies 42.
    nonisolated static func calculation(_ query: String) -> LauncherItem? {
        guard let value = Calculator.evaluate(query) else { return nil }
        return LauncherItem(id: "calculation:" + query, kind: .calculation, title: "= " + Calculator.format(value),
                            subtitle: query + " · Return copies the result", action: Calculator.plain(value))
    }

    /// "timer 10m tea" → Start a 10:00 timer (Milestone 21).
    nonisolated static func timer(_ query: String) -> LauncherItem? {
        guard let parsed = QuickTimer.parse(query) else { return nil }
        let length = QuickTimer.format(parsed.seconds)
        return LauncherItem(id: "orbit:timer", kind: .orbit, title: "Start a \(length) Timer" + (parsed.label.isEmpty ? "" : ": \(parsed.label)"),
                            subtitle: "Shows in the dashboard header; a note below the notch when it's done",
                            action: "timer|\(Int(parsed.seconds))|\(parsed.label)")
    }

    nonisolated static func shortcutItem(_ name: String) -> LauncherItem {
        LauncherItem(id: "shortcut:" + name, kind: .shortcut, title: name,
                     subtitle: "Apple Shortcut · Return runs it, ⌘Return opens it in Shortcuts", keywords: "shortcut automation", action: name)
    }

    nonisolated static func rank(query: String, items: [LauncherItem], category: LauncherCategory, recent: Set<String>, boosted: Set<String>,
                     limit: Int = 40) -> [LauncherItem] {
        var seen = Set<String>()
        let scored = items.compactMap { item -> (LauncherItem, Int)? in
            guard category.contains(item.kind), seen.insert(item.id).inserted, let score = FuzzyMatch.score(query: query, item: item) else { return nil }
            var total = score + item.kind.weight
            if recent.contains(item.id) { total += 200 }  // what you opened before outranks an exact name
            if let path = item.path, boosted.contains(path) { total += 150 }  // the active workspace's apps and projects
            return (item, total)
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 > $1.1 : $0.0.title.count < $1.0.title.count }.prefix(limit).map(\.0)
    }

    private func scheduleFileSearch(_ text: String) {
        fileDebounce?.cancel()
        guard searchesFiles, let files, category == .all || category == .files, text.count >= 2 else { return }
        fileDebounce = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(160))
            guard !Task.isCancelled, let self, self.query.trimmingCharacters(in: .whitespaces) == text else { return }
            self.isSearchingFiles = true
            files.search(text, limit: 12) { [weak self] found in
                guard let self, self.query.trimmingCharacters(in: .whitespaces) == text else { return }
                self.isSearchingFiles = false
                self.fileResults = found
                self.results = self.ranked(text, files: found)
                self.selection = min(self.selection, max(self.results.count - 1, 0))
            }
        }
    }

    func move(_ delta: Int) {
        guard !results.isEmpty else { return }
        selection = (selection + delta + results.count) % results.count
    }

    func cycleCategory(_ delta: Int = 1) {
        let all = LauncherCategory.allCases
        category = all[((all.firstIndex(of: category) ?? 0) + delta + all.count) % all.count]
    }

    var selected: LauncherItem? { results.indices.contains(selection) ? results[selection] : nil }

    /// Remembers what was opened (and the query that found it).
    func remember(_ item: LauncherItem) {
        guard item.kind != .calculation else { return }  // a sum isn't something to reopen
        let text = query.trimmingCharacters(in: .whitespaces)
        stored.update { memory in
            memory.recentItems.removeAll { $0.id == item.id }
            memory.recentItems.insert(item, at: 0)
            memory.recentItems = Array(memory.recentItems.prefix(LauncherMemory.itemLimit))
            if !text.isEmpty {
                memory.recentQueries.removeAll { $0.caseInsensitiveCompare(text) == .orderedSame }
                memory.recentQueries.insert(text, at: 0)
                memory.recentQueries = Array(memory.recentQueries.prefix(LauncherMemory.queryLimit))
            }
        }
    }

    /// A recent item whose file is gone: dropped, with a note.
    func forget(_ item: LauncherItem, because note: String) {
        stored.update { $0.recentItems.removeAll { $0.id == item.id } }
        message = note
        search()
    }

    func clearHistory() { stored.update { $0 = LauncherMemory() }; search() }

    /// A path still there (files move): checked before opening.
    nonisolated static func exists(_ path: String?) -> Bool {
        guard let path else { return true }
        return FileManager.default.fileExists(atPath: path)
    }

    /// Scripts and executables are revealed, never run, from the launcher.
    nonisolated static func isRunnable(_ path: String) -> Bool {
        let url = URL(filePath: path)
        guard let type = UTType(filenameExtension: url.pathExtension) else {
            return FileManager.default.isExecutableFile(atPath: path) && !path.hasSuffix(".app")
        }
        return type.conforms(to: .script) || type.conforms(to: .shellScript) || type.conforms(to: .unixExecutable)
            || ["command", "tool", "workflow", "terminal", "pkg", "mpkg"].contains(url.pathExtension.lowercased())
    }
}
