import Foundation
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.8-1: the Daily Briefing model. Its own list and sizes in
// briefing.json, the same widget instances as the Overview, and never a
// change to the Overview's layout.

private let preset: [WidgetID] = ["weather", "events", "clock", "goals", "tasks"]

/// A registry of the five briefing widgets plus one the briefing doesn't use.
@MainActor
private func briefingRegistry() throws -> WidgetRegistry {
    try WidgetRegistry([
        FakeWidget("clock"),
        FakeWidget("weather", presentations: [.compact, .expanded]),
        FakeWidget("battery"),
        FakeWidget("tasks", presentations: [.compact, .expanded]),
        FakeWidget("goals", enabledByDefault: false),
        FakeWidget("events", presentations: [.compact, .expanded]),
    ])
}

private func decode(_ json: String) throws -> BriefingPreferences {
    try JSONDecoder().decode(BriefingPreferences.self, from: Data(json.utf8))
}

// MARK: Defaults and migration

@Test func defaultsAreTheTwoRowPresetAndOff() {
    let briefing = BriefingPreferences()
    #expect(!briefing.dailyBriefingEnabled && briefing.version == 2)
    #expect(briefing.widgets == preset)
    #expect(preset.map(briefing.presentation(for:)) == [.compact, .expanded, .compact, .compact, .compact])
    // 1 + 2 cells, then 1 + 1 + 1: exactly two rows of three.
    let spans = preset.map { briefing.presentation(for: $0).span }
    #expect(WidgetGridPacking.rows(spans: spans, columns: 3) == [[0, 1], [2, 3, 4]])
}

@Test func versionOneFilesMoveToTheNewPreset() throws {
    let old = try decode(#"{"version":1,"dailyBriefingEnabled":false,"widgets":["clock","weather","events","tasks"],"options":{}}"#)
    #expect(old.widgets == preset && old.version == 2)
    #expect(old.presentation(for: "events") == .expanded)

    let unversioned = try decode(#"{"widgets":["clock","weather","events","tasks"],"options":{"weather":{"city":"Pune"}}}"#)
    #expect(unversioned.widgets == preset && unversioned.options["weather"]?["city"] == "Pune")  // other options kept
    #expect(unversioned.presentation(for: "events") == .expanded)

    let keptSize = try decode(#"{"version":1,"widgets":["clock","weather","events","tasks"],"options":{"events":{"presentation":"compact"}}}"#)
    #expect(keptSize.presentation(for: "events") == .compact)  // a size the file sets is never overwritten

    let custom = try decode(#"{"version":1,"dailyBriefingEnabled":true,"widgets":["tasks","weather"]}"#)
    #expect(custom.widgets == ["tasks", "weather"] && custom.dailyBriefingEnabled)  // a customised list stays

    let newer = try decode(#"{"version":3,"widgets":["clock","weather","events","tasks"]}"#)
    #expect(newer.widgets == ["clock", "weather", "events", "tasks"] && newer.version == 3)  // a newer file isn't "migrated"
    #expect(try decode("{}") == BriefingPreferences())
}

@MainActor @Test func unknownMissingAndUnsupportedEntriesAreSafe() throws {
    let dashboard = DashboardModel(registry: try briefingRegistry(), store: MemoryLayoutStorage().store)
    #expect(dashboard.briefingWidgets.map(\.id) == preset)
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .expanded, .compact, .compact, .compact])

    var briefing = BriefingPreferences()
    briefing.widgets = ["spotify", "weather", "goals", "", "weather", "events"]  // unknown, empty, repeated
    briefing.setPresentation(.expanded, for: "goals")  // goals has no expanded size
    briefing.options["weather"] = [BriefingPreferences.presentationKey: "enormous"]
    dashboard.briefing = briefing
    #expect(dashboard.briefingWidgets.map(\.id) == ["weather", "goals", "events"])  // skipped, once each
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
    dashboard.briefing.widgets = ["events"]
    dashboard.briefing.setPresentation(.compact, for: "events")
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
    #expect(reopened.value.widgets == preset && reopened.value.presentation(for: "events") == .expanded)
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
