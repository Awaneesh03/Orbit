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
        FakeWidget("news", presentations: [.compact, .expanded]),
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
    briefing.setShown("news", false)
    #expect(!briefing.isShown("news") && briefing.widgets == ["weather", "tasks"])
    #expect(briefing.presentation(for: "news") == .expanded)  // hidden, its size kept
    briefing.setShown("weather", false)
    briefing.setShown("news", true)
    briefing.setShown("weather", true)
    #expect(briefing.widgets == BriefingPreferences.defaultWidgets)  // back in their places
    briefing.setShown("clock", true)  // offered, not shown by default: goes to its place in the order
    briefing.setShown("goals", true)
    #expect(briefing.widgets == ["weather", "news", "tasks", "goals", "clock"])
    briefing.widgets.insert("future-widget", at: 3)
    briefing.setShown("tasks", false)
    briefing.setShown("tasks", true)
    #expect(briefing.widgets == ["weather", "news", "tasks", "future-widget", "goals", "clock"])  // unknown ids stay
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
    briefing.update { $0.setShown("goals", true) }
    briefing.update { $0.setShown("tasks", false) }
    briefing.update { $0.setPresentation(.compact, for: "news") }
    #expect(dashboard.briefingWidgets.map(\.id) == ["weather", "news", "goals"])
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .compact, .compact])
    briefing.update { $0.setPresentation(.expanded, for: "goals") }  // goals has one size
    #expect(dashboard.briefingWidgets.first { $0.id == "goals" }?.presentation == .compact)

    let reopened = BriefingPreferencesModel(file: BriefingPreferencesModel.file(in: temp.url))  // a relaunch
    #expect(reopened.value.dailyBriefingEnabled && !reopened.value.isShown("tasks") && reopened.value.isShown("goals"))
    #expect(reopened.value.presentation(for: "news") == .compact)

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
    #expect(dashboard.briefingWidgets.map(\.presentation) == [.compact, .expanded, .compact])
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
