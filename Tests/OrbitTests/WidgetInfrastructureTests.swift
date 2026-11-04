import Foundation
import SwiftUI
import Testing
@testable import Orbit

// Stage 3 Step 3: widget states, Refresher (staleness, joining, cancellation,
// intervals, visibility), DataCache, data-source errors and briefing.json.

/// A data source that returns scripted results, optionally after a delay.
private actor MockSource: DataSource {
    private let results: [Result<Int, DataSourceError>]
    private let delay: Duration
    private(set) var calls = 0

    init(_ results: [Result<Int, DataSourceError>], delay: Duration = .zero) {
        self.results = results
        self.delay = delay
    }

    func fetch() async throws -> Int {
        calls += 1
        let result = results[min(calls - 1, results.count - 1)]
        if delay > .zero { try await Task.sleep(for: delay) }
        return try result.get()
    }
}

private final class TestClock: @unchecked Sendable {
    var now = Date(timeIntervalSince1970: 1_800_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

private let tenMinutes = Refresher<Int>.Policy(maxAge: 600)

@MainActor
private func settle(_ refresher: Refresher<Int>) async {
    if refresher.isRefreshing { await refresher.refresh().value }
}

// MARK: States

@MainActor @Test func refresherStatesWithoutData() async throws {
    let cases: [(DataSourceError, WidgetState)] = [
        (.needsAccess("Allow access to Calendars"), .needsAccess("Allow access to Calendars")),
        (.unavailable("Music isn't installed"), .unavailable("Music isn't installed")),
        (.offline, .failed("You're offline.")),
        (.failed("Couldn't load"), .failed("Couldn't load")),
    ]
    for (error, expected) in cases {
        let refresher = Refresher(source: MockSource([.failure(error)]), policy: tenMinutes)
        #expect(refresher.widgetState() == .loading)
        await refresher.refresh().value
        #expect(refresher.widgetState() == expected)
        #expect(refresher.statusNote == nil)  // nothing loaded, so nothing to annotate
        let retry = refresher.retryAction != nil
        #expect(retry == (error == .offline || error == .failed("Couldn't load")), "\(error)")  // no fake retry for access
    }
    let empty = Refresher(source: MockSource([.success(0)]), policy: tenMinutes)
    await empty.refresh().value
    #expect(empty.widgetState(empty: { $0 == 0 ? "Nothing today" : nil }) == .empty("Nothing today"))
}

@MainActor @Test func everyStateRendersDistinctlyInTheHost() throws {
    let size = CGSize(width: 229, height: 160)
    let widget = FakeWidget("states")
    func image() throws -> [UInt8] { try #require(render(WidgetHost(widget: widget, presentation: .compact), size: size)).pixels }

    widget.state = .unavailable("Music isn't installed")
    let unavailable = try image()
    widget.state = .needsAccess("Music isn't installed")
    let needsAccess = try image()
    #expect(needsAccess != unavailable)  // a lock, not a slash: denied isn't the same as absent

    widget.state = .failed("Couldn't load")
    let plainFailure = try image()
    widget.stateAction = WidgetAction(title: "Retry") {}
    #expect(try image() != plainFailure)  // the Retry button shows
    widget.stateAction = nil

    widget.state = .ready
    let fresh = try image()
    widget.statusNote = WidgetNote(text: "Updated 2 hr ago · Offline", symbol: "wifi.slash")
    #expect(try image() != fresh)  // stale data keeps its content and gains a note
}

@MainActor @Test func existingWidgetsHaveNoNotesOrActions() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    for widget in makeBuiltInRegistry(temp).widgets where !["events", "weather"].contains(widget.metadata.id) {
        #expect(widget.statusNote == nil && widget.stateAction == nil, "\(widget.metadata.id)")
    }
    // Calendar (Stage 3.5) is the first to adopt them: Connect, or Open Privacy Settings if access was denied earlier.
    let calendar = try #require(makeBuiltInRegistry(temp).widget("events"))
    #expect(calendar.stateAction != nil || calendar.state == .unavailable("Calendar access is restricted on this Mac."))
    // Weather (Stage 3.6): with no city yet, Choose City.
    #expect(makeBuiltInRegistry(temp).widget("weather")?.stateAction?.title == "Choose City")
}

// MARK: Refresh policy

@MainActor @Test func becomingVisibleRefreshesOnlyWhenStale() async throws {
    let source = MockSource([.success(1), .success(2)])
    let clock = TestClock()
    let refresher = Refresher(source: source, policy: tenMinutes, clock: { clock.now })

    refresher.becameVisible()
    await settle(refresher)
    #expect(refresher.value == 1 && refresher.updatedAt == clock.now && refresher.widgetState() == .ready)
    refresher.becameHidden()

    clock.advance(300)  // reopened five minutes later: still fresh
    refresher.becameVisible()
    await settle(refresher)
    #expect(await source.calls == 1)
    #expect(refresher.statusNote == nil)
    refresher.becameHidden()

    clock.advance(301)  // now past ten minutes
    #expect(refresher.isStale)
    #expect(refresher.statusNote?.text.hasPrefix("Updated") == true)  // stale data is labelled while it refreshes
    refresher.becameVisible()
    await settle(refresher)
    #expect(await source.calls == 2 && refresher.value == 2)
}

@MainActor @Test func simultaneousRefreshesShareOneFetch() async throws {
    let source = MockSource([.success(7)], delay: .milliseconds(50))
    let refresher = Refresher(source: source, policy: tenMinutes)
    let first = refresher.refresh()
    #expect(refresher.refresh() == first)
    refresher.becameVisible()  // stale, but a refresh is already running: joins it
    #expect(refresher.refresh() == first)
    await first.value
    #expect(await source.calls == 1)
    #expect(refresher.value == 7 && !refresher.isRefreshing)
}

@MainActor @Test func aFailedRefreshKeepsTheDataAndOffersRetry() async throws {
    let source = MockSource([.success(1), .failure(.offline), .failure(.failed("Server error")), .success(4)])
    let clock = TestClock()
    let refresher = Refresher(source: source, policy: tenMinutes, clock: { clock.now })
    await refresher.refresh().value
    clock.advance(3600)

    await refresher.refresh().value
    #expect(refresher.value == 1 && refresher.widgetState() == .ready)  // not replaced by an error screen
    #expect(refresher.statusNote?.symbol == "wifi.slash")
    #expect(refresher.statusNote?.text.contains("Offline") == true)

    await refresher.refresh().value
    #expect(refresher.statusNote?.text.contains("Couldn't refresh") == true)
    let retry = try #require(refresher.retryAction)
    retry.perform()
    await settle(refresher)
    #expect(refresher.value == 4 && refresher.error == nil && refresher.statusNote == nil)
}

@MainActor @Test func hidingCancelsARunningRefreshAndDropsItsResult() async throws {
    let source = MockSource([.success(1), .success(2)], delay: .milliseconds(300))
    let refresher = Refresher(source: source, policy: tenMinutes)
    refresher.becameVisible()
    #expect(refresher.isRefreshing)
    refresher.becameHidden()  // the dashboard closed
    #expect(!refresher.isRefreshing)
    try await Task.sleep(for: .milliseconds(450))
    #expect(refresher.value == nil && refresher.error == nil)  // no late result, no error

    refresher.becameVisible()  // still stale: a fresh fetch, not the cancelled one
    await settle(refresher)
    #expect(refresher.value == 2)
    #expect(await source.calls == 2)

    // A refresh that's kept running while hidden (`cancelsWhenHidden: false`) still lands.
    let keep = Refresher(source: MockSource([.success(9)], delay: .milliseconds(50)),
                         policy: .init(maxAge: 600, cancelsWhenHidden: false))
    keep.becameVisible()
    keep.becameHidden()
    await settle(keep)
    #expect(keep.value == 9)
}

@MainActor @Test func markingStaleWhileHiddenRefreshesOnTheNextAppearance() async throws {
    let source = MockSource([.success(1), .success(2), .success(3)])
    let refresher = Refresher(source: source, policy: tenMinutes)
    refresher.becameVisible()
    await settle(refresher)
    refresher.becameHidden()

    refresher.markStale()  // e.g. a change notification while hidden
    #expect(!refresher.isRefreshing && refresher.isStale)
    #expect(await source.calls == 1)
    refresher.becameVisible()
    await settle(refresher)
    #expect(refresher.value == 2 && !refresher.isStale)

    refresher.markStale()  // while visible: refreshes straight away
    await settle(refresher)
    #expect(refresher.value == 3)
}

@MainActor @Test func intervalRefreshesRunOnlyWhileVisible() async throws {
    let source = MockSource([.success(1)])
    let refresher = Refresher(source: source, policy: .init(maxAge: 600, interval: .milliseconds(25)))
    #expect(!refresher.isIntervalRunning)
    refresher.becameVisible()
    refresher.becameVisible()  // shown twice (two hosts): still one interval
    #expect(refresher.isIntervalRunning)
    for _ in 0..<100 where await source.calls < 4 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(await source.calls >= 4)

    refresher.becameHidden()
    #expect(!refresher.isIntervalRunning)
    await settle(refresher)
    // Hiding cancels an in-flight refresh (its result is dropped), but a fetch
    // that had already started can still reach the source a moment later.
    try await Task.sleep(for: .milliseconds(50))
    let afterHiding = await source.calls
    try await Task.sleep(for: .milliseconds(150))
    #expect(await source.calls == afterHiding)  // nothing runs while hidden
}

@MainActor @Test func visibilityCountingDrivesTheRefresher() async throws {
    let source = MockSource([.success(1), .success(2)])
    let clock = TestClock()
    let widget = RefreshingWidget(refresher: Refresher(source: source, policy: tenMinutes, clock: { clock.now }))

    WidgetVisibility.appeared(widget)  // Overview…
    WidgetVisibility.appeared(widget)  // …and its section during a transition
    await settle(widget.refresher)
    #expect(await source.calls == 1)
    WidgetVisibility.disappeared(widget)
    #expect(widget.refresher.isVisible)  // one host is still on screen
    WidgetVisibility.disappeared(widget)
    #expect(!widget.refresher.isVisible)

    for _ in 0..<3 {  // reopening the dashboard repeatedly while the data is fresh
        WidgetVisibility.appeared(widget)
        WidgetVisibility.disappeared(widget)
    }
    #expect(await source.calls == 1)

    clock.advance(601)
    WidgetVisibility.appeared(widget)
    await settle(widget.refresher)
    WidgetVisibility.disappeared(widget)
    #expect(await source.calls == 2 && widget.refresher.value == 2)
}

@Test func errorsMapToRecoverableKinds() {
    #expect(DataSourceError.from(CancellationError()) == nil)
    #expect(DataSourceError.from(URLError(.cancelled)) == nil)
    #expect(DataSourceError.from(URLError(.notConnectedToInternet)) == .offline)
    #expect(DataSourceError.from(URLError(.timedOut)) == .offline)
    #expect(DataSourceError.from(URLError(.badServerResponse)) == .failed("Couldn't load the latest data."))
    #expect(DataSourceError.from(DataSourceError.needsAccess("x")) == .needsAccess("x"))
    #expect(DataSourceError.from(CocoaError(.fileReadCorruptFile)) == .failed("Couldn't load the latest data."))
}

// MARK: Cache

@MainActor @Test func cacheExpiresByAgeButKeepsTheLatestValue() {
    let cache = DataCache<Int>.memoryOnly()
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(cache.latest == nil)
    cache.store(5, at: now)
    #expect(cache.value(notOlderThan: 60, now: now.addingTimeInterval(59)) == 5)
    #expect(cache.value(notOlderThan: 60, now: now.addingTimeInterval(60)) == nil)  // expired…
    #expect(cache.latest?.value == 5)                                               // …but still there to show as stale
    cache.clear()
    #expect(cache.latest == nil)
}

@MainActor @Test func diskCacheIsWrittenOnlyOnStoreAndSurvivesCorruption() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<CachedValue<[String]>> = temp.file("cache.json")
    let path = file.url.path(percentEncoded: false)

    let cache = DataCache(file: file)
    #expect(cache.latest == nil)
    #expect(!FileManager.default.fileExists(atPath: path))  // nothing created until something is stored
    let stored = Date(timeIntervalSince1970: 1_800_000_000)
    cache.store(["a", "b"], at: stored)
    let reopened = DataCache(file: file)
    #expect(reopened.latest?.value == ["a", "b"] && reopened.latest?.storedAt == stored)

    try Data("{ broken".utf8).write(to: file.url)
    let damaged = DataCache(file: file)
    #expect(damaged.latest == nil)  // an unreadable cache is a cache miss, not a crash
    damaged.store(["c"])
    #expect(DataCache(file: file).latest?.value == ["c"])
    damaged.clear()
    #expect(!FileManager.default.fileExists(atPath: path))
}

@MainActor @Test func aRefresherStartsFromTheCacheAndUpdatesIt() async throws {
    let cache = DataCache<Int>.memoryOnly()
    let clock = TestClock()
    cache.store(41, at: clock.now.addingTimeInterval(-3600))
    let refresher = Refresher(source: MockSource([.success(42)]), policy: tenMinutes, cache: cache, clock: { clock.now })
    #expect(refresher.value == 41 && refresher.widgetState() == .ready)  // shown at once…
    #expect(refresher.isStale && refresher.statusNote != nil)              // …labelled as old
    refresher.becameVisible()
    await settle(refresher)
    #expect(refresher.value == 42 && cache.latest?.value == 42 && cache.latest?.storedAt == clock.now)
}

// MARK: briefing.json

@MainActor @Test func briefingDefaultsAreOffAndLoadingWritesNothing() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let model = BriefingPreferencesModel(file: BriefingPreferencesModel.file(in: temp.url))
    #expect(model.value == BriefingPreferences())
    #expect(model.value.dailyBriefingEnabled == false)  // never on by default
    #expect(model.value.widgets == ["weather", "events", "clock", "goals", "tasks"])  // 3.8-1's preset
    #expect(model.problem == nil)
    #expect(!FileManager.default.fileExists(atPath: temp.url.appending(path: "briefing.json").path(percentEncoded: false)))
}

@Test func briefingDecodingIsTolerant() throws {
    let json = """
        {"version": 7, "dailyBriefingEnabled": "yes", "widgets": ["clock", "", "clock", "music"],
         "options": {"weather": {"city": "Pune"}}, "somethingNew": {"x": 1}}
        """
    let decoded = try JSONDecoder().decode(BriefingPreferences.self, from: Data(json.utf8))
    #expect(decoded.version == 7)                     // a newer file still opens
    #expect(decoded.dailyBriefingEnabled == false)    // invalid value: default
    #expect(decoded.widgets == ["clock", "music"])    // no empty or repeated ids; unknown ids kept
    #expect(decoded.options == ["weather": ["city": "Pune"]])
    let empty = try JSONDecoder().decode(BriefingPreferences.self, from: Data("{}".utf8))
    #expect(empty == BriefingPreferences())
}

@MainActor @Test func briefingChangesPersistAtomicallyAndTouchNothingElse() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file = BriefingPreferencesModel.file(in: temp.url)
    let model = BriefingPreferencesModel(file: file)
    model.update {
        $0.dailyBriefingEnabled = true
        $0.widgets = ["tasks", "tasks", "clock"]
        $0.options["weather"] = ["city": "Pune"]
    }
    let reopened = BriefingPreferencesModel(file: file)
    #expect(reopened.value.dailyBriefingEnabled)
    #expect(reopened.value.widgets == ["tasks", "clock"])
    #expect(reopened.value.options["weather"]?["city"] == "Pune")
    // Atomic write: just the file itself, no temporary leftovers, and no other settings file.
    let files = try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false))
    #expect(files == ["briefing.json"])
}

@MainActor @Test func aCorruptBriefingFileIsNeverOverwrittenUntilReset() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file = BriefingPreferencesModel.file(in: temp.url)
    let garbage = Data("not json".utf8)
    try garbage.write(to: file.url)

    let model = BriefingPreferencesModel(file: file)
    #expect(model.problem != nil)
    #expect(model.value == BriefingPreferences())  // safe defaults meanwhile
    model.update { $0.dailyBriefingEnabled = true }
    #expect(try Data(contentsOf: file.url) == garbage)

    model.resetAll()  // the only way past it: the unreadable file is moved aside first
    #expect(model.problem == nil)
    #expect(try file.load() == BriefingPreferences())
    let aside = try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false))
        .filter { $0.hasPrefix("briefing.unreadable-") }
    #expect(aside.count == 1)
}

// MARK: Support

/// A widget built the intended way: state, note and retry from its refresher;
/// start/stop forwarded from the host's visibility.
@MainActor
private final class RefreshingWidget: DashboardWidget {
    let metadata = WidgetMetadata(id: "refreshing", title: "Refreshing", description: "", symbol: "circle",
                                  category: .general, availability: .live)
    let refresher: Refresher<Int>

    init(refresher: Refresher<Int>) {
        self.refresher = refresher
    }

    var state: WidgetState { refresher.widgetState() }
    var statusNote: WidgetNote? { refresher.statusNote }
    var stateAction: WidgetAction? { refresher.retryAction }
    func start() { refresher.becameVisible() }
    func stop() { refresher.becameHidden() }
    func content(_ presentation: WidgetPresentation) -> AnyView { AnyView(Text("\(refresher.value ?? 0)")) }
}
