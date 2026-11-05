import AppKit
import Foundation
import Testing
@testable import Orbit

@MainActor
private func makeSettings(_ temp: TemporaryDirectory) -> (SettingsModel, MemoryLayoutStorage) {
    let storage = MemoryLayoutStorage()
    let dashboard = DashboardModel(registry: makeBuiltInRegistry(temp), store: storage.store)
    let model = SettingsModel(dashboard: dashboard, preferences: PreferencesModel(file: nil),
                              dataDirectory: temp.url, exportRoot: temp.url.appending(path: "Exports"))
    return (model, storage)
}

// MARK: Preferences

@Test func defaultPreferencesMatchTheApprovedDesign() {
    let defaults = OrbitPreferences()
    #expect(defaults.hideDelay == 1)
    #expect(defaults.appearance == .dark)
    #expect(defaults.dashboardOpacity == 0.85)
    #expect(defaults.widgetSpacing.points == Theme.spacing)
    #expect(defaults.reduceMotion == false)
}

@Test func preferencesKeepValidFieldsAndDefaultTheRest() throws {
    let json = #"{"hideDelay": 2, "appearance": "purple", "dashboardOpacity": "x", "widgetSpacing": "compact"}"#
    let decoded = try JSONDecoder().decode(OrbitPreferences.self, from: Data(json.utf8))
    #expect(decoded.hideDelay == 2)
    #expect(decoded.appearance == .dark)
    #expect(decoded.dashboardOpacity == 0.85)
    #expect(decoded.widgetSpacing == .compact)
    #expect(decoded.reduceMotion == false)
}

@Test func outOfRangePreferencesAreClamped() throws {
    let decoded = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"hideDelay": 60, "dashboardOpacity": 0}"#.utf8))
    #expect(decoded.hideDelay == OrbitPreferences.hideDelayRange.upperBound)
    #expect(decoded.dashboardOpacity == OrbitPreferences.opacityRange.lowerBound)
}

@MainActor @Test func missingPreferencesFileGivesDefaultsAndChangesPersist() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let model = PreferencesModel(file: file)
    #expect(model.value == OrbitPreferences())
    #expect(model.problem == nil)

    var notified: OrbitPreferences?
    model.onChange = { notified = $0 }
    model.update { $0.appearance = .light; $0.widgetSpacing = .comfortable; $0.hideDelay = 0 }
    #expect(notified?.appearance == .light)
    #expect(model.value.hideDelay == OrbitPreferences.hideDelayRange.lowerBound)

    let reloaded = PreferencesModel(file: file)
    #expect(reloaded.value.appearance == .light)
    #expect(reloaded.value.widgetSpacing == .comfortable)
}

@MainActor @Test func resetsRestoreDefaults() {
    let model = PreferencesModel(file: nil)
    model.update { $0.hideDelay = 2.5; $0.appearance = .system; $0.dashboardOpacity = 1; $0.reduceMotion = true }
    model.resetGeneral()
    #expect(model.value.hideDelay == 1)
    #expect(model.value.appearance == .system)  // General reset leaves Appearance alone
    model.resetAppearance()
    #expect(model.value == OrbitPreferences())
}

@MainActor @Test func corruptPreferencesAreNeverOverwritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let garbage = Data("not json".utf8)
    try garbage.write(to: file.url)

    let model = PreferencesModel(file: file)
    #expect(model.problem != nil)
    #expect(model.value == OrbitPreferences())
    model.update { $0.appearance = .light }
    #expect(try Data(contentsOf: file.url) == garbage)

    // Only an explicit reset moves on, and it moves the unreadable file aside.
    model.resetAll()
    #expect(model.problem == nil)
    #expect(try file.load() == OrbitPreferences())
    let aside = try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false))
        .filter { $0.hasPrefix("preferences.unreadable-") }
    #expect(aside.count == 1)
    #expect(try Data(contentsOf: temp.url.appending(path: aside[0])) == garbage)
}

// MARK: Orbit Pet

@Test func orbitPetIsOffOnAFreshInstallWithBothExperiencesChosen() {
    let defaults = OrbitPreferences()
    #expect(!defaults.orbitPet && defaults.desktopPet && defaults.notchCompanion)
    #expect(defaults.petToggles == PetModel.Toggles(pet: false, desktop: true, companion: false))
}

@Test func petPreferencesDecodeTolerantly() throws {
    // A file from before Settings › Pet: the pet off, every other field kept.
    let old = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"hideDelay": 2, "volumeHUD": false}"#.utf8))
    #expect(old.hideDelay == 2 && !old.volumeHUD)
    #expect(!old.orbitPet && old.desktopPet && old.notchCompanion)
    // Invalid values take their default; valid ones are kept.
    let bad = try JSONDecoder().decode(OrbitPreferences.self,
                                       from: Data(#"{"orbitPet": "yes", "desktopPet": false, "notchCompanion": 3}"#.utf8))
    #expect(!bad.orbitPet && !bad.desktopPet && bad.notchCompanion)
}

@Test func petTogglesCombineIndependently() {
    for master in [false, true] {
        for desktop in [false, true] {
            for companion in [false, true] {
                var value = OrbitPreferences()
                value.orbitPet = master
                value.desktopPet = desktop
                value.notchCompanion = companion
                #expect(value.petToggles.pet == master && value.petToggles.desktop == desktop)
                #expect(!value.petToggles.companion)  // saved, but not shown until the companion exists (5.6)
            }
        }
    }
}

@MainActor @Test func petChoicesPersistAndLeaveOtherPreferencesAlone() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let model = PreferencesModel(file: file)
    model.update { $0.volumeHUD = false; $0.hideDelay = 2 }
    model.update { $0.orbitPet = true; $0.notchCompanion = false }
    model.update { $0.orbitPet = false }  // master off: the experiences keep their choice
    let reloaded = PreferencesModel(file: file)
    #expect(!reloaded.value.orbitPet && reloaded.value.desktopPet && !reloaded.value.notchCompanion)
    #expect(!reloaded.value.volumeHUD && reloaded.value.hideDelay == 2)
    // Only the three choices: no state, position or animation.
    let json = try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: file.url)) as? [String: Any])
    #expect(json.keys.filter { $0.localizedCaseInsensitiveContains("pet") || $0.contains("Companion") }.sorted()
        == ["desktopPet", "notchCompanion", "orbitPet"])
}

@MainActor @Test func anUnreadablePreferencesFileKeepsThePetOffAndIsNotOverwritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let garbage = Data(#"{"orbitPet": tru"#.utf8)
    try garbage.write(to: file.url)
    let model = PreferencesModel(file: file)
    #expect(model.problem != nil && !model.value.petToggles.pet)
    model.update { $0.orbitPet = true }  // ignored until the user resets: the file is never overwritten
    #expect(try !model.value.petToggles.pet && Data(contentsOf: file.url) == garbage)
    model.resetAll()  // the unreadable file moved aside, defaults saved: the pet still off
    #expect(model.problem == nil && !model.value.orbitPet)
    model.update { $0.orbitPet = true }
    #expect(try file.load()?.orbitPet == true)
}

// MARK: Widgets (through the dashboard's own model)

@MainActor @Test func settingsEditsTheDashboardLayout() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let (settings, storage) = makeSettings(temp)
    let dashboard = settings.dashboard
    let first = dashboard.layout.items[0].id
    let second = dashboard.layout.items[1].id

    dashboard.move(first, to: 1)  // "move down"
    #expect(dashboard.layout.items.map(\.id).prefix(2) == [second, first])
    dashboard.move(first, to: 0)  // "move up"
    #expect(dashboard.layout.items[0].id == first)

    dashboard.setEnabled("vault", true)
    dashboard.setPresentation("vault", .expanded)
    #expect(dashboard.overviewWidgets.contains { $0.id == "vault" && $0.presentation == .expanded })
    #expect(storage.data != nil)  // saved immediately

    dashboard.resetLayout()
    #expect(dashboard.layout == .defaults(for: dashboard.registry.metadata).normalized(for: dashboard.registry.metadata))
}

// MARK: Storage

@MainActor @Test func storageReportCountsVaultAndDragCopies() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let (settings, _) = makeSettings(temp)
    let vault = try #require(settings.dashboard.registry.widget("vault") as? VaultWidget)
    await vault.importData(sampleImage(.png, seed: 1), source: "test")
    await vault.importData(sampleImage(.png, seed: 2), source: "test")
    vault.toggleKept(vault.items[0])
    _ = try vault.vault?.exportCopy(of: vault.items[0], root: settings.exportRoot)

    settings.refresh()
    let report = try #require(settings.storage)
    #expect(report.screenshotCount == 2)
    #expect(report.keptCount == 1)
    #expect(report.vaultBytes > 0)
    #expect(report.exportCopies == 1)
    #expect(report.exportBytes > 0)
}

@MainActor @Test func cleanupRemovesOnlyExpiredDragCopiesNeverVaultScreenshots() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let (settings, _) = makeSettings(temp)
    let vault = try #require(settings.dashboard.registry.widget("vault") as? VaultWidget)
    await vault.importData(sampleImage(.png, seed: 3), source: "test")
    let item = vault.items[0]
    let copy = try #require(try vault.vault?.exportCopy(of: item, root: settings.exportRoot))
    let original = try #require(vault.vault?.url(for: item))

    settings.cleanUpDragCopies()  // the copy is fresh: kept
    #expect(FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    #expect(settings.cleanupMessage == "No expired drag copies.")

    settings.cleanUpDragCopies(olderThan: -1)  // everything counts as expired
    #expect(!FileManager.default.fileExists(atPath: copy.path(percentEncoded: false)))
    #expect(settings.cleanupMessage == "Removed 1 expired drag copy.")
    #expect(FileManager.default.fileExists(atPath: original.path(percentEncoded: false)))
    #expect(vault.items.count == 1)
    #expect(settings.storage?.exportCopies == 0)
}

@Test func storageSizeOfMissingFolderIsZero() {
    #expect(StorageInspector.size(of: URL(filePath: "/nonexistent-orbit-\(UUID().uuidString)")) == 0)
}

// MARK: Window lifecycle

@MainActor @Test func settingsWindowIsCreatedOnceAndSurvivesClosing() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let controller = SettingsWindowController(model: makeSettings(temp).0)
    #expect(controller.window == nil)  // nothing until first opened

    let window = controller.prepareWindow()
    #expect(controller.prepareWindow() === window)
    #expect(window.isReleasedWhenClosed == false)
    #expect(window.collectionBehavior.contains(.moveToActiveSpace))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(window.appearance?.name == .darkAqua)

    window.close()
    #expect(controller.prepareWindow() === window)  // reopening reuses it

    controller.apply(.light)
    #expect(window.appearance?.name == .aqua)
    controller.apply(.system)
    #expect(window.appearance == nil)
}
