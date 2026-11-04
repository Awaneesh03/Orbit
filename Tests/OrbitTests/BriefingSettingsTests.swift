import Foundation
import Testing
@testable import Orbit

// Stage 3.8-3: Settings › Widgets › Daily Briefing. The settings drive
// briefing.json, and the app pushes every change to the dashboard at once.

@MainActor
private func registry() throws -> WidgetRegistry {
    try WidgetRegistry([
        FakeWidget("clock"),
        FakeWidget("weather", presentations: [.compact, .expanded]),
        FakeWidget("battery"),
        FakeWidget("tasks", presentations: [.compact, .expanded]),
        FakeWidget("goals", enabledByDefault: false),
        FakeWidget("events", presentations: [.compact, .expanded]),
    ])
}

/// The briefing model wired to a dashboard the way AppDelegate wires them.
@MainActor
private func wired(_ temp: TemporaryDirectory) throws -> (BriefingPreferencesModel, DashboardModel, MemoryLayoutStorage) {
    let storage = MemoryLayoutStorage()
    let dashboard = DashboardModel(registry: try registry(), store: storage.store)
    let briefing = BriefingPreferencesModel(file: BriefingPreferencesModel.file(in: temp.url))
    dashboard.briefing = briefing.value
    briefing.onChange = { [dashboard] in dashboard.briefing = $0 }
    return (briefing, dashboard, storage)
}

@Test func hidingAndShowingKeepsTheApprovedOrderAndSizes() {
    var briefing = BriefingPreferences()
    briefing.setShown("events", false)
    #expect(!briefing.isShown("events") && briefing.widgets == ["weather", "clock", "goals", "tasks"])
    #expect(briefing.presentation(for: "events") == .expanded)  // hidden, its size kept
    briefing.setShown("weather", false)
    briefing.setShown("events", true)
    briefing.setShown("weather", true)
    #expect(briefing.widgets == BriefingPreferences.defaultWidgets)  // back in their places
    briefing.widgets.insert("future-widget", at: 2)
    briefing.setShown("clock", false)
    briefing.setShown("clock", true)
    #expect(briefing.widgets == ["weather", "events", "clock", "future-widget", "goals", "tasks"])  // unknown ids stay
    briefing.setShown("clock", true)
    #expect(briefing.widgets.filter { $0 == "clock" }.count == 1)  // never twice
}

@MainActor @Test func theSettingsDriveTheTabImmediatelyAndPersist() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let (briefing, dashboard, storage) = try wired(temp)
    let layoutBytes = storage.data
    #expect(!dashboard.visibleSections.contains(.briefing))  // off by default

    briefing.update { $0.dailyBriefingEnabled = true }
    #expect(dashboard.visibleSections.contains(.briefing))  // the tab appears at once
    dashboard.section = .briefing
    briefing.update { $0.setShown("clock", false) }
    briefing.update { $0.setPresentation(.compact, for: "events") }
    #expect(dashboard.briefingWidgets.map(\.id) == ["weather", "events", "goals", "tasks"])
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .compact, .compact, .compact])
    briefing.update { $0.setPresentation(.expanded, for: "goals") }  // goals has one size
    #expect(dashboard.briefingWidgets.first { $0.id == "goals" }?.presentation == .compact)

    let reopened = BriefingPreferencesModel(file: BriefingPreferencesModel.file(in: temp.url))  // a relaunch
    #expect(reopened.value.dailyBriefingEnabled && !reopened.value.isShown("clock"))
    #expect(reopened.value.presentation(for: "events") == .compact)

    briefing.update { $0.dailyBriefingEnabled = false }  // turned off while viewing it
    #expect(dashboard.section == .overview && !dashboard.visibleSections.contains(.briefing))
    #expect(storage.data == layoutBytes)  // the Overview's layout never moved
}

@MainActor @Test func resetRestoresTheApprovedDefaultsInBriefingJSONOnly() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let preferencesFile: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    PreferencesModel(file: preferencesFile).update { $0.hideDelay = 2 }
    let preferencesBytes = try Data(contentsOf: preferencesFile.url)
    let (briefing, dashboard, storage) = try wired(temp)
    dashboard.setEnabled("goals", true)  // a customised Overview
    let layoutBytes = storage.data

    briefing.update {
        $0.dailyBriefingEnabled = true
        $0.setShown("weather", false)
        $0.setPresentation(.expanded, for: "tasks")
    }
    dashboard.section = .briefing
    briefing.resetAll()
    #expect(briefing.value == BriefingPreferences() && dashboard.briefing == BriefingPreferences())
    #expect(dashboard.section == .overview)  // reset turns it off again: back to the Overview
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .expanded, .compact, .compact, .compact])
    #expect(try BriefingPreferencesModel.file(in: temp.url).load() == BriefingPreferences())  // saved
    #expect(try Data(contentsOf: preferencesFile.url) == preferencesBytes && storage.data == layoutBytes)
    #expect(try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false)).sorted()
        == ["briefing.json", "preferences.json"])
}

@MainActor @Test func theInMemoryDebugHookStillWorksAlongsideSettings() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let (briefing, dashboard, _) = try wired(temp)
    dashboard.briefing.dailyBriefingEnabled = true  // what `briefing:on` does: memory only
    #expect(dashboard.visibleSections.contains(.briefing))
    #expect(!FileManager.default.fileExists(atPath: BriefingPreferencesModel.file(in: temp.url).url.path(percentEncoded: false)))
    briefing.update { $0.setShown("tasks", false) }  // a later Settings change wins: the saved value
    #expect(!dashboard.visibleSections.contains(.briefing) && !dashboard.briefing.isShown("tasks"))
}
