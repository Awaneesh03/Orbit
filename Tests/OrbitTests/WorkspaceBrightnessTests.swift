import AppKit
import Foundation
import Testing
@testable import Orbit

// Milestone 16: workspace profiles, the shared brightness monitor, the per-display list,
// new quick actions, Settings search and preferences.

@MainActor @Test func workspacesStartWithFourAndCanBeManaged() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let workspaces = Workspaces(file: temp.file(Workspaces.fileName))
    #expect(workspaces.profiles.map(\.name) == ["Development", "College", "FixKaru", "Personal"] && workspaces.active == nil)
    let custom = workspaces.create()
    #expect(workspaces.create().name == "New Workspace 2")
    let copy = try #require(workspaces.duplicate(workspaces.profiles[1].id))
    #expect(copy.name == "College Copy" && workspaces.profiles[2].id == copy.id)
    workspaces.update(custom.id) {
        $0.name = "  Thesis  "
        $0.projects = ["/Users/me/Developer/thesis"]
        $0.taskKeywords = ["chapter"]
    }
    workspaces.setActive(custom.id)
    let reloaded = Workspaces(file: temp.file(Workspaces.fileName))  // restart
    #expect(reloaded.active?.name == "Thesis" && reloaded.active?.projects == ["/Users/me/Developer/thesis"])
    #expect(reloaded.active?.owns(task: "Write chapter 3") == true && reloaded.active?.owns(task: "Groceries") == false)
    #expect(reloaded.active?.owns(folder: "/Users/me/Developer/thesis/src") == true && reloaded.active?.owns(folder: "/Users/me/Developer/thesis2") == false)
    reloaded.delete(custom.id)
    #expect(reloaded.active == nil)  // deleting the active one leaves none active
    reloaded.setActive(UUID())  // unknown: ignored
    #expect(reloaded.active == nil)
    reloaded.update(copy.id) { $0.name = "   " }
    #expect(reloaded.profiles.first { $0.id == copy.id }?.name == "Workspace")
}

@Test func schedulesSuggestButNeverSwitch() throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = .gmt
    let wednesday10 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 10))!
    let saturday10 = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 10))!
    let schedule = WorkspaceProfile.Schedule()
    #expect(schedule.contains(wednesday10, calendar: calendar) && !schedule.contains(saturday10, calendar: calendar))
    let night = WorkspaceProfile.Schedule(weekdays: Array(1 ... 7), startHour: 22, endHour: 6)
    #expect(night.contains(calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 23))!, calendar: calendar))
    #expect(!night.contains(wednesday10, calendar: calendar))
    let decoded = try JSONDecoder().decode(WorkspaceStore.self, from: Data(#"{"profiles":[{"name":"Lab","music":"loud"}],"activeID":"6F9619FF-8B86-D011-B42D-00C04FC964FF"}"#.utf8))
    #expect(decoded.profiles.map(\.name) == ["Lab"] && decoded.profiles[0].music == .leave && decoded.activeID == nil)  // tolerant
}

@MainActor @Test func workspaceSuggestionsSkipTheActiveOne() {
    let workspaces = Workspaces(file: nil)
    let college = workspaces.profiles[1]
    workspaces.update(college.id) { $0.schedule = WorkspaceProfile.Schedule(weekdays: Array(1 ... 7), startHour: 0, endHour: 24) }
    #expect(workspaces.suggestion(at: .now)?.name == "College")
    workspaces.setActive(college.id)
    #expect(workspaces.suggestion(at: .now) == nil)
}

@MainActor @Test func oneBrightnessMonitorServesTheHUDAndTheWidget() {
    var reading: Double? = 0.42
    let monitor = BrightnessMonitor(read: { reading }, watchesSystem: false)
    let widget = BrightnessWidget(monitor: monitor)
    monitor.start()  // the HUD
    widget.start()
    monitor.stop()  // HUD off: the widget still reads
    #expect(monitor.isRunning && monitor.level == 0.42)
    reading = 0.8
    monitor.refresh(.poll)
    #expect(widget.displays.first { $0.isBuiltIn }.map { $0.level == 0.8 } ?? true)
    widget.stop()
    #expect(!monitor.isRunning)
}

@Test func brightnessBandsAndHonestNotes() {
    #expect(DisplayBrightness.band(0.1) == .low && DisplayBrightness.band(0.5) == .medium && DisplayBrightness.band(0.9) == .high)
    let external = DisplayBrightness(id: 2, name: "LF27T35", isBuiltIn: false, level: nil)
    #expect(external.note.contains("DDC/CI"))
    #expect(DisplayBrightness(id: 1, name: "Built-in", isBuiltIn: true, level: 0.5).note.isEmpty)
}

@MainActor @Test func thisMacsDisplaysAreListed() {
    let displays = DisplayBrightness.current(builtInLevel: 0.6)
    #expect(!displays.isEmpty)
    #expect(displays.filter { !$0.isBuiltIn }.allSatisfy { $0.level == nil })  // an external display's level is never made up
    if let builtIn = displays.first(where: \.isBuiltIn) { #expect(builtIn.level == 0.6 && displays.first == builtIn) }
    #expect(BrightnessReader.level(BrightnessReader.service()) != nil || !displays.contains(where: \.isBuiltIn))  // a real reading on this Mac
}

@Test func newSuggestionsAppearOnlyWhenTheyHelp() {
    let workspace = WorkspaceProfile(name: "College", symbol: "graduationcap")
    var active = WorkspaceProfile(name: "Development")
    #expect(ContextAction.suggest(QuickContext(activeWorkspace: active)).isEmpty)  // nothing to open
    active.apps = ["/Applications/Safari.app"]
    let all = ContextAction.suggest(QuickContext(suggestedWorkspace: workspace, activeWorkspace: active, energyHog: "Brave Browser",
                                                 lowBattery: true, externalDisplay: true))
    #expect(all.map(\.title) == ["Switch to College", "Open Development", "Activity Monitor"])  // three at most
    #expect(ContextAction.suggest(QuickContext(lowBattery: true, externalDisplay: true)).map(\.title) == ["Battery Settings", "Display Settings"])
}

@MainActor @Test func settingsSearchFindsSectionsByWhatTheyContain() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let model = SettingsModel(dashboard: DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store),
                              preferences: PreferencesModel(file: nil), dataDirectory: temp.url)
    #expect(model.visibleSections == SettingsSection.allCases)
    model.search = "shortcut"
    #expect(model.visibleSections.contains(.launcher) && model.visibleSections.contains(.welcome))
    model.search = "brightness"
    #expect(model.visibleSections == [.general])
    model.search = "fixkaru"
    #expect(model.visibleSections == [.workspaces])
}

@Test func milestone16PreferencesDecodeTolerantly() throws {
    let defaults = OrbitPreferences()
    #expect(defaults.launcherShortcut == .controlOptionSpace && defaults.launcherFiles && defaults.batteryEnergy && defaults.chargingAnimation && !defaults.onboardingSeen)
    let decoded = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"launcherShortcut":"hyper","batteryEnergy":false,"onboardingSeen":true}"#.utf8))
    #expect(decoded.launcherShortcut == .controlOptionSpace && !decoded.batteryEnergy && decoded.onboardingSeen)
}
