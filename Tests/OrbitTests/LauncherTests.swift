import AppKit
import Foundation
import Testing
@testable import Orbit

// Milestone 16: the Universal Launcher. Matching, ranking, categories, recents, missing files, scripts, speed.

private func item(_ kind: LauncherItem.Kind, _ title: String, path: String? = nil, keywords: String = "") -> LauncherItem {
    LauncherItem(id: "\(kind.rawValue):\(title)", kind: kind, title: title, path: path, keywords: keywords)
}

@Test func fuzzyMatchingPrefersPrefixesWordStartsAndOrder() {
    let prefix = FuzzyMatch.score("saf", in: "Safari")!, word = FuzzyMatch.score("stu", in: "Visual Studio Code")!
    let inside = FuzzyMatch.score("ari", in: "Safari")!, letters = FuzzyMatch.score("vsc", in: "Visual Studio Code")!
    #expect(prefix > word && word > inside && inside > letters && letters > 0)
    #expect(FuzzyMatch.score("xyz", in: "Safari") == nil)
    #expect(FuzzyMatch.score("CAFE", in: "Café Menu") != nil)  // case and accents don't matter
    #expect(FuzzyMatch.score(query: "orbit road", item: item(.file, "ORBIT_ROADMAP.md")) != nil)  // every word
    #expect(FuzzyMatch.score(query: "orbit zebra", item: item(.file, "ORBIT_ROADMAP.md")) == nil)
    #expect(FuzzyMatch.score(query: "brightness", item: item(.setting, "General Settings", keywords: "brightness hud")) != nil)  // keywords find it
}

@Test func rankingUsesCategoriesRecentsAndTheWorkspace() {
    let items = [item(.file, "Orbit notes.txt"), item(.project, "Orbit", path: "/p/Orbit"), item(.app, "Orbiter", path: "/Applications/Orbiter.app"),
                 item(.task, "Read Orbit spec")]
    #expect(LauncherModel.rank(query: "orbit", items: items, category: .all, recent: [], boosted: []).first?.kind == .project)
    #expect(LauncherModel.rank(query: "orbit", items: items, category: .apps, recent: [], boosted: []).map(\.kind) == [.app])
    #expect(LauncherModel.rank(query: "orbit", items: items, category: .tasks, recent: [], boosted: []).map(\.kind) == [.task])
    #expect(LauncherModel.rank(query: "orbit", items: items, category: .all, recent: ["file:Orbit notes.txt"], boosted: []).first?.kind == .file)
    #expect(LauncherModel.rank(query: "orbit", items: items, category: .all, recent: [], boosted: ["/Applications/Orbiter.app"]).first?.kind == .app)
    let duplicated = items + [items[0]]
    #expect(LauncherModel.rank(query: "orbit", items: duplicated, category: .all, recent: [], boosted: []).count == 4)  // no duplicates
}

@MainActor @Test func recentsSurviveARestartAndMissingFilesAreForgotten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let first = LauncherModel(file: temp.file("launcher.json"), files: nil, apps: [item(.app, "Safari", path: "/Applications/Safari.app")])
    first.query = "saf"
    let safari = try #require(first.selected)
    first.remember(safari)
    let missing = item(.file, "gone.txt", path: temp.url.appending(path: "gone.txt").path(percentEncoded: false))
    first.remember(missing)
    let second = LauncherModel(file: temp.file("launcher.json"), files: nil, apps: [])
    #expect(second.memory.recentItems.map(\.title) == ["gone.txt", "Safari"] && second.memory.recentQueries == ["saf"])
    #expect(!LauncherModel.exists(missing.path) && LauncherModel.exists("/Applications"))
    second.forget(missing, because: "gone.txt is no longer there.")
    #expect(second.memory.recentItems.map(\.title) == ["Safari"] && second.message == "gone.txt is no longer there.")
    second.prepare()
    #expect(second.results.map(\.title) == ["Safari"])  // empty query: recents
    second.clearHistory()
    #expect(second.memory == LauncherMemory())
}

@Test func scriptsAndExecutablesAreRevealedNotRun() {
    #expect(LauncherModel.isRunnable("/Users/me/install.sh") && LauncherModel.isRunnable("/Users/me/deploy.command"))
    #expect(LauncherModel.isRunnable("/Users/me/tool.py") && LauncherModel.isRunnable("/Users/me/Setup.pkg"))
    #expect(!LauncherModel.isRunnable("/Users/me/notes.md") && !LauncherModel.isRunnable("/Users/me/photo.png"))
}

@Test func appsAreFoundInTheApplicationsFolders() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let apps = temp.url.appending(path: "Applications", directoryHint: .isDirectory)
    for path in ["Safari.app", "Utilities/Terminal.app", "Adobe Thing/Adobe Thing.app", "notes.txt"] {
        try FileManager.default.createDirectory(at: apps.appending(path: path), withIntermediateDirectories: true)
    }
    let found = AppCatalog.scan(folders: [apps.path(percentEncoded: false)])
    #expect(Set(found.map(\.title)) == ["Safari", "Terminal", "Adobe Thing"])
    #expect(AppCatalog.scan().contains { $0.title == "Safari" })  // this Mac
}

@MainActor private final class FakeFiles: FileSearching {
    var searched: [String] = []
    func search(_ query: String, limit: Int, results: @escaping @MainActor ([LauncherItem]) -> Void) {
        searched.append(query)
        results([LauncherItem(id: "file:/x/\(query).pdf", kind: .file, title: "\(query) report.pdf", path: "/x/\(query).pdf")])
    }
    func cancel() {}
}

@MainActor @Test func filesArriveAfterAPauseAndOnlyWhereFilesBelong() async {
    let files = FakeFiles()
    let model = LauncherModel(file: nil, files: files, apps: [])
    model.query = "q"  // one letter: no file search
    model.query = "budget"
    #expect(files.searched.isEmpty)  // debounced
    for _ in 0 ..< 60 where files.searched.isEmpty { try? await Task.sleep(for: .milliseconds(10)) }
    #expect(files.searched == ["budget"] && model.results.first?.kind == .file)
    model.category = .tasks
    #expect(!model.results.contains { $0.kind == .file })
    model.searchesFiles = false
    model.category = .all
    model.query = "taxes"
    try? await Task.sleep(for: .milliseconds(300))
    #expect(files.searched == ["budget"])  // file search off: Spotlight isn't asked
}

@MainActor @Test func keyboardNavigationWrapsAndCategoriesCycle() {
    let model = LauncherModel(file: nil, files: nil, apps: ["Alpha", "Alpine", "Altitude"].map { item(.app, $0) })
    model.query = "al"
    #expect(model.results.count == 3 && model.selection == 0)
    model.move(-1)
    #expect(model.selection == 2)
    model.move(1)
    #expect(model.selection == 0)
    model.cycleCategory()
    #expect(model.category == .apps)
    model.cycleCategory(-1)
    #expect(model.category == .all)
}

@MainActor @Test func searchingFiveThousandItemsIsFast() {
    let many = (0 ..< 5000).map { item(.file, "Document \($0) quarterly report.txt") }
    let model = LauncherModel(file: nil, files: nil, apps: [])
    model.sources = { many }
    model.query = "quart rep 49"
    #expect(!model.results.isEmpty)
    #expect(model.lastSearchDuration < .milliseconds(150), "took \(model.lastSearchDuration)")
}

@MainActor @Test func launcherShortcutsAreDistinctAndNeverTheDashboards() {
    let combos = LauncherShortcut.allCases.compactMap(\.combination)
    #expect(Set(combos.map { "\($0.keyCode)-\($0.modifiers)" }).count == combos.count)
    #expect(!combos.contains { $0.keyCode == DashboardHotKey.keyCode && $0.modifiers == DashboardHotKey.modifiers })
    #expect(LauncherShortcut.off.combination == nil)
}

@MainActor @Test func aGlobalHotKeyRegistersAndChanges() {
    // F19 with ⌃⌥⇧⌘ (Carbon masks: no Caps Lock bit): nothing on this Mac uses it.
    let hotKey = GlobalHotKey(id: 99, keyCode: 80, modifiers: 0x1B00) {}
    #expect(hotKey.register() && hotKey.isRegistered)
    #expect(hotKey.change(keyCode: 79, modifiers: 0x1B00) && hotKey.isRegistered)
    hotKey.unregister()
    #expect(!hotKey.isRegistered)
}

@Test func hiddenWordsNeedARealMatch() {
    let workspace = item(.workspace, "College", keywords: "workspace profile")
    #expect(FuzzyMatch.score(query: "saf", item: workspace) == nil)  // letters scattered through "workspace profile" don't count
    #expect(FuzzyMatch.score(query: "profile", item: workspace) != nil)
    #expect(FuzzyMatch.score(query: "saf", item: item(.orbit, "Start a Focus Session")) != nil)  // initials in a title still do
}
