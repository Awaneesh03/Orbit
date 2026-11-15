import Foundation
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.8-1: the Daily Briefing model. Its own list and sizes in
// briefing.json, the same widget instances as the Overview, and never a
// change to the Overview's layout.

private let preset: [WidgetID] = ["weather", "news", "tasks"]

/// A registry of the five briefing widgets plus one the briefing doesn't use.
@MainActor
private func briefingRegistry() throws -> WidgetRegistry {
    try WidgetRegistry([
        FakeWidget("clock"),
        FakeWidget("weather", presentations: [.compact, .expanded]),
        FakeWidget("battery"),
        FakeWidget("tasks", presentations: [.compact, .expanded]),
        FakeWidget("goals", enabledByDefault: false),
        FakeWidget("news", presentations: [.compact, .expanded]),
    ])
}

private func decode(_ json: String) throws -> BriefingPreferences {
    try JSONDecoder().decode(BriefingPreferences.self, from: Data(json.utf8))
}

// MARK: Defaults and migration

@Test func defaultsAreTheTwoRowPresetAndOff() {
    let briefing = BriefingPreferences()
    #expect(!briefing.dailyBriefingEnabled && briefing.version == 3)
    #expect(briefing.widgets == preset)
    #expect(preset.map(briefing.presentation(for:)) == [.compact, .expanded, .compact])
    // Tech News two cells wide and two rows tall, Weather and Tasks beside it: all six cells, no scrolling.
    let split = BriefingLayout.split(preset.map(briefing.presentation(for:)))
    #expect(split?.feature == 1 && split?.side == [0, 2] && split?.rest == [])
    #expect(BriefingPreferences.availableWidgets == ["weather", "news", "tasks", "goals", "clock", "linkedin", "digest"])
}

@Test func versionOneFilesMoveToTheNewPreset() throws {
    let old = try decode(#"{"version":1,"dailyBriefingEnabled":false,"widgets":["clock","weather","events","tasks"],"options":{}}"#)
    #expect(old.widgets == preset && old.version == 3)
    #expect(old.presentation(for: "news") == .expanded)

    let unversioned = try decode(#"{"widgets":["clock","weather","events","tasks"],"options":{"weather":{"city":"Pune"}}}"#)
    #expect(unversioned.widgets == preset && unversioned.options["weather"]?["city"] == "Pune")  // other options kept
    #expect(unversioned.presentation(for: "news") == .expanded)

    let keptSize = try decode(#"{"version":1,"widgets":["clock","weather","events","tasks"],"options":{"events":{"presentation":"compact"}}}"#)
    #expect(keptSize.presentation(for: "news") == .compact)  // Calendar's size carries over to Tech News

    let custom = try decode(#"{"version":1,"dailyBriefingEnabled":true,"widgets":["tasks","weather"]}"#)
    #expect(custom.widgets == ["tasks", "weather"] && custom.dailyBriefingEnabled)  // a customised list stays

    let newer = try decode(#"{"version":4,"widgets":["clock","weather","events","tasks"]}"#)
    #expect(newer.widgets == ["clock", "weather", "events", "tasks"] && newer.version == 4)  // a newer file isn't "migrated"
    #expect(try decode("{}") == BriefingPreferences())
}

@Test func featureLayoutNeedsAnExpandedWidgetAndTwoCompactOnes() {
    #expect(BriefingLayout.split([.compact, .compact, .compact]) == nil)  // no feature: the plain grid
    #expect(BriefingLayout.split([.expanded, .compact]) == nil)  // nothing to stack beside it
    let split = BriefingLayout.split([.expanded, .compact, .expanded, .compact, .compact])
    #expect(split?.feature == 0 && split?.side == [1, 3] && split?.rest == [2, 4])  // only the first expanded is the feature
}

@Test func versionTwoFilesSwapCalendarForTechNews() throws {
    // The version 2 preset: Calendar's place and size go to Tech News.
    let preset2 = try decode(#"{"version":2,"dailyBriefingEnabled":true,"widgets":["weather","events","clock","goals","tasks"],"options":{"events":{"presentation":"expanded"}}}"#)
    #expect(preset2.widgets == preset && preset2.version == 3 && preset2.dailyBriefingEnabled)
    #expect(preset2.presentation(for: "news") == .expanded)
    // A customised list keeps its order; Calendar's compact size carries over.
    let custom = try decode(#"{"version":2,"widgets":["tasks","events","weather"],"options":{"events":{"presentation":"compact"},"weather":{"city":"Pune"}}}"#)
    #expect(custom.widgets == ["tasks", "news", "weather"] && custom.presentation(for: "news") == .compact)
    #expect(custom.options["weather"]?["city"] == "Pune")
    // Already has news: Calendar is simply removed, never duplicated.
    let both = try decode(#"{"version":2,"widgets":["news","events","clock"]}"#)
    #expect(both.widgets == ["news", "clock"] && both.presentation(for: "news") == .expanded)
    // No Calendar at all: nothing changes but the version.
    let none = try decode(#"{"version":2,"widgets":["clock","tasks"]}"#)
    #expect(none.widgets == ["clock", "tasks"] && none.version == 3)
}

@MainActor @Test func unknownMissingAndUnsupportedEntriesAreSafe() throws {
    let dashboard = DashboardModel(registry: try briefingRegistry(), store: MemoryLayoutStorage().store)
    #expect(dashboard.briefingWidgets.map(\.id) == preset)
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .expanded, .compact])

    var briefing = BriefingPreferences()
    briefing.widgets = ["spotify", "weather", "goals", "", "weather", "news"]  // unknown, empty, repeated
    briefing.setPresentation(.expanded, for: "goals")  // goals has no expanded size
    briefing.options["weather"] = [BriefingPreferences.presentationKey: "enormous"]
    dashboard.briefing = briefing
    #expect(dashboard.briefingWidgets.map(\.id) == ["weather", "goals", "news"])  // skipped, once each
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .compact, .expanded])  // unsupported → compact

    dashboard.briefing.widgets = ["nothing", "here"]
    #expect(dashboard.briefingWidgets.isEmpty)  // never a crash, just nothing to show
}

// MARK: The Overview is never touched

@MainActor @Test func turningTheBriefingOnAndOffNeverChangesTheOverview() throws {
    let storage = MemoryLayoutStorage()
    let dashboard = DashboardModel(registry: try briefingRegistry(), store: storage.store)
    dashboard.setEnabled("goals", true)
    dashboard.setPresentation("tasks", .expanded)
    dashboard.move("battery", to: 0)  // a customised Overview
    let savedLayout = storage.data
    let layout = dashboard.layout
    let overview = dashboard.overviewWidgets.map { "\($0.id):\($0.presentation)" }

    for enabled in [true, false, true, false] {
        dashboard.briefing.dailyBriefingEnabled = enabled
        _ = dashboard.briefingWidgets
    }
    dashboard.briefing.widgets = ["news"]
    dashboard.briefing.setPresentation(.compact, for: "news")
    #expect(storage.data == savedLayout)  // widgetLayout: not a byte changed, never re-saved
    #expect(dashboard.layout == layout)
    #expect(dashboard.overviewWidgets.map { "\($0.id):\($0.presentation)" } == overview)
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact])  // the briefing has its own sizes
}

@MainActor @Test func briefingWritesOnlyItsOwnFileAndOnlyOnARealChange() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let preferencesFile: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let preferences = PreferencesModel(file: preferencesFile)
    preferences.update { $0.hideDelay = 2.5; $0.musicIslandSeconds = 6 }
    let preferencesBytes = try Data(contentsOf: preferencesFile.url)

    let file = BriefingPreferencesModel.file(in: temp.url)
    let model = BriefingPreferencesModel(file: file)
    #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))  // loading writes nothing
    model.update { $0.dailyBriefingEnabled = false }  // already off: no change
    model.update { $0.widgets = preset }
    #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))  // still nothing
    model.update { $0.dailyBriefingEnabled = true }
    #expect(FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))
    #expect(try Data(contentsOf: preferencesFile.url) == preferencesBytes)  // preferences.json untouched
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false)).sorted()
        == ["briefing.json", "preferences.json"])
    let firstWrite = try Data(contentsOf: file.url)
    model.update { $0.dailyBriefingEnabled = true }  // the same again
    #expect(try Data(contentsOf: file.url) == firstWrite)

    // A version 1 file is migrated in memory, and not rewritten until something changes.
    let legacy = temp.url.appending(path: "legacy")
    try FileManager.default.createDirectory(at: legacy, withIntermediateDirectories: true)
    let legacyFile = BriefingPreferencesModel.file(in: legacy)
    let legacyBytes = Data(#"{"version":1,"widgets":["clock","weather","events","tasks"]}"#.utf8)
    try legacyBytes.write(to: legacyFile.url)
    let reopened = BriefingPreferencesModel(file: legacyFile)
    #expect(reopened.value.widgets == preset && reopened.value.presentation(for: "news") == .expanded)
    #expect(try Data(contentsOf: legacyFile.url) == legacyBytes)
}

@MainActor @Test func resettingTheBriefingTouchesNothingElse() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let storage = MemoryLayoutStorage()
    let dashboard = DashboardModel(registry: try briefingRegistry(), store: storage.store)
    dashboard.setEnabled("battery", false)
    let savedLayout = storage.data
    let preferences = PreferencesModel(file: nil)
    preferences.update { $0.reduceMotion = true }

    let model = BriefingPreferencesModel(file: BriefingPreferencesModel.file(in: temp.url))
    model.update {
        $0.dailyBriefingEnabled = true
        $0.widgets = ["tasks"]
        $0.setPresentation(.expanded, for: "tasks")
    }
    model.resetAll()
    #expect(model.value == BriefingPreferences() && !model.value.dailyBriefingEnabled)
    #expect(storage.data == savedLayout && preferences.value.reduceMotion)  // the Overview and preferences stay

    dashboard.resetLayout()  // and the other way round: restoring the Overview leaves the briefing alone
    #expect(model.value == BriefingPreferences())
}

// MARK: Shared instances and lifecycle

@MainActor @Test func theBriefingSharesWidgetInstancesAndTheirLifecycle() throws {
    let registry = try briefingRegistry()
    let dashboard = DashboardModel(registry: registry, store: MemoryLayoutStorage().store)
    let tasks = try #require(registry.widget("tasks") as? FakeWidget)
    let inBriefing = try #require(dashboard.briefingWidgets.first { $0.id == "tasks" })
    let onOverview = try #require(dashboard.overviewWidgets.first { $0.id == "tasks" })
    #expect(inBriefing.widget === tasks && onOverview.widget === tasks)  // one instance: one data source

    // Shown on both tabs during a switch: started once, stopped when the last host goes.
    WidgetVisibility.appeared(inBriefing.widget)
    WidgetVisibility.appeared(onOverview.widget)
    #expect(tasks.starts == 1)
    WidgetVisibility.disappeared(onOverview.widget)
    #expect(tasks.stops == 0)
    WidgetVisibility.disappeared(inBriefing.widget)
    #expect(tasks.starts == 1 && tasks.stops == 1)
}
