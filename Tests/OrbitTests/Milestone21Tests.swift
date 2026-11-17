import Foundation
import Testing
@testable import Orbit

// Milestone 21: the redesigned notch (morph, header, tabs, roomier grid), the
// notch master switch and opening choice, Low Power Mode, and the live
// activities (power, quick timer, colour picker). No test touches the real
// battery, Bluetooth or screen.

// MARK: The notch switch

@Test func turningTheNotchOffLeavesOnlyTheDashboard() {
    #expect(NotchCoordination.Owner(coucouRunning: false, enabled: false) == .off)
    #expect(NotchCoordination.Owner(coucouRunning: true, enabled: false) == .off)
    #expect(NotchCoordination.Owner(coucouRunning: true) == .coucou && NotchCoordination.Owner(coucouRunning: false) == .orbit)
    for surface in NotchCoordination.Surface.allCases {
        #expect(NotchCoordination.permits(surface, owner: .off) == (surface == .dashboard), "\(surface)")
    }
    let everything = NotchCoordination.Inputs(owner: .off, island: .compact, volumeHUD: true, alert: true, eyeBreak: true,
                                              deviceNotice: true, statusPill: true, companion: true)
    #expect(NotchCoordination.holder(everything) == nil)
    var open = everything
    open.dashboardOpen = true
    #expect(NotchCoordination.holder(open) == .dashboard)  // still opens from its shortcut
}

@Test func newNotchPreferencesDecodeSafely() throws {
    let old = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"hideDelay":1}"#.utf8))
    #expect(old.notchEnabled && old.notchOpen == .hover && old.lowPowerFollows && old.powerNotices && !old.headerTidyDone)
    let chosen = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"notchEnabled":false,"notchOpen":"click"}"#.utf8))
    #expect(!chosen.notchEnabled && chosen.notchOpen == .click)
    let bad = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"notchOpen":"wave"}"#.utf8))
    #expect(bad.notchOpen == .hover)
}

@Test func lowPowerModeReducesMotionOnlyWhenFollowed() {
    var value = OrbitPreferences()
    #expect(!AppDelegate.reducesMotion(value, lowPower: false))
    #expect(AppDelegate.reducesMotion(value, lowPower: true))
    value.lowPowerFollows = false
    #expect(!AppDelegate.reducesMotion(value, lowPower: true))
    value.reduceMotion = true
    #expect(AppDelegate.reducesMotion(value, lowPower: false))
}

// MARK: The redesigned shell

@Test func theSurfaceGrowsFromTheCameraHousing() {
    let panel = NotchGeometry.dashboardSize
    let closed = DashboardView.surfaceSize(open: false, panel: panel, notchWidth: 185, topInset: 32)
    #expect(closed == CGSize(width: 185 + 2 * NotchStyle.attachedShoulder, height: 32))
    #expect(DashboardView.surfaceSize(open: true, panel: panel, notchWidth: 185, topInset: 32) == panel)
    // A closed window is only the trigger: the surface never asks for more than it has.
    #expect(DashboardView.surfaceSize(open: false, panel: CGSize(width: 150, height: 20), notchWidth: 185, topInset: 32)
            == CGSize(width: 150, height: 20))
    #expect(panel.width > 740 && panel.height > 420)  // roomier than before
    #expect(DashboardView.closedRadius < DashboardView.openRadius)
}

@Test func everyTabHasAnIconAndAShortName() {
    let sections = DashboardSection.allCases
    #expect(Set(sections.map(\.symbol)).count == sections.count)
    #expect(sections.allSatisfy { !$0.shortTitle.isEmpty && $0.shortTitle.count <= 12 })
    #expect(DashboardSection.screenshots.shortTitle == "Vault" && DashboardSection.developer.shortTitle == "Developer")
}

@Test func aRowThatIsntFullSharesItsWidth() {
    // Three columns, 600 pt, 10 pt gaps: a cell is 193.3 pt.
    let cell: CGFloat = (600 - 20) / 3
    let full = WidgetGrid.width(span: 1, rowSpans: [1, 1, 1], total: 600, cell: cell, spacing: 10, columns: 3)
    #expect(abs(full - cell) < 0.01)
    let half = WidgetGrid.width(span: 1, rowSpans: [1, 1], total: 600, cell: cell, spacing: 10, columns: 3)
    #expect(abs(half - 295) < 0.01)  // (600 − 10) / 2
    let wide = WidgetGrid.width(span: 2, rowSpans: [2], total: 600, cell: cell, spacing: 10, columns: 3)
    #expect(abs(wide - 600) < 0.01)
    let expandedPlusOne = WidgetGrid.width(span: 2, rowSpans: [2, 1], total: 600, cell: cell, spacing: 10, columns: 3)
    #expect(abs(expandedPlusOne - (cell * 2 + 10)) < 0.01)  // a full row keeps whole cells
}

@MainActor @Test func theHeaderTidyTakesOnlyClockAndBatteryOffTheOverview() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let dashboard = DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store)
    dashboard.setEnabled("clock", true)
    dashboard.setEnabled("battery", true)
    dashboard.setEnabled("news", true)
    dashboard.tidyForHeader()
    let on = Set(dashboard.overviewWidgets.map(\.id))
    #expect(!on.contains("clock") && !on.contains("battery") && on.contains("news") && on.contains("tasks"))
    #expect(dashboard.sectionWidgets(.system).contains { $0.id == "battery" })  // still on its own page
}

// MARK: Live activities

private func status(_ percent: Int, _ state: BatteryStatus.ChargeState) -> BatteryStatus {
    switch state {
    case .onBattery: BatteryStatus(percent: percent, isCharging: false, isPluggedIn: false)
    case .charging: BatteryStatus(percent: percent, isCharging: true, isPluggedIn: true)
    case .pluggedInNotCharging: BatteryStatus(percent: percent, isCharging: false, isPluggedIn: true)
    case .charged: BatteryStatus(percent: percent, isCharging: false, isPluggedIn: true, isCharged: true)
    }
}

@Test func powerChangesBecomeNotes() {
    #expect(PowerNotices.notice(from: nil, to: status(50, .charging)) == nil)  // the first reading is the baseline
    #expect(PowerNotices.notice(from: status(50, .onBattery), to: status(50, .charging))?.title == "Charging")
    #expect(PowerNotices.notice(from: status(50, .charging), to: status(51, .charging)) == nil)  // still charging: nothing new
    #expect(PowerNotices.notice(from: status(99, .charging), to: status(100, .charged))?.title == "Fully charged")
    #expect(PowerNotices.notice(from: status(70, .charging), to: status(70, .onBattery))?.title == "On battery")
    #expect(PowerNotices.notice(from: status(60, .onBattery), to: status(60, .pluggedInNotCharging))?.title == "Plugged in")
    let low = PowerNotices.notice(from: status(21, .onBattery), to: status(20, .onBattery))
    #expect(low?.title == "Low battery" && low?.tint == .warning && low?.state == "low20")
    #expect(PowerNotices.notice(from: status(11, .onBattery), to: status(10, .onBattery))?.tint == .critical)
    #expect(PowerNotices.notice(from: status(19, .onBattery), to: status(18, .onBattery)) == nil)  // already below 20
    #expect(PowerNotices.notice(from: status(70, .charging), to: status(70, .onBattery))?.level == 0.7)
    #expect(PowerNotices.symbol(5) == "battery.0percent" && PowerNotices.symbol(100) == "battery.100percent")
}

@MainActor @Test func thePowerWatcherNotesOnlyChanges() {
    var reading: BatteryStatus? = status(40, .onBattery)
    let watcher = PowerWatcher(read: { reading })
    var notes: [String] = []
    watcher.onNotice = { notes.append($0.title) }
    watcher.prime()
    watcher.changed()  // the same reading again
    reading = status(40, .charging)
    watcher.changed()
    reading = status(41, .charging)
    watcher.changed()
    #expect(notes == ["Charging"])
    let noBattery = PowerWatcher(read: { nil })
    noBattery.start()
    #expect(!noBattery.isRunning)  // a Mac without a battery: nothing is registered
}

@Test func timersAreParsedFromWhatYouType() {
    #expect(QuickTimer.parse("timer 10m")?.seconds == 600)
    #expect(QuickTimer.parse("timer 1h30m")?.seconds == 5400)
    #expect(QuickTimer.parse("timer 90s")?.seconds == 90)
    #expect(QuickTimer.parse("timer 25")?.seconds == 1500)  // a bare number is minutes
    #expect(QuickTimer.parse("10 min timer")?.seconds == 600)
    #expect(QuickTimer.parse("timer 2 hours")?.seconds == 7200)
    let tea = QuickTimer.parse("timer 5m green tea")
    #expect(tea?.seconds == 300 && tea?.label == "Green tea")
    #expect(QuickTimer.parse("Timer 5m Call Mom about NYC")?.label == "Call Mom about NYC")  // the label keeps its case
    for text in ["timer", "timer soon", "safari", "timer 0m", "timer 99h", "timer 5x"] {
        #expect(QuickTimer.parse(text) == nil, "\(text)")
    }
    #expect(QuickTimer.format(65) == "1:05" && QuickTimer.format(0.2) == "0:01")
}

@MainActor @Test func aQuickTimerFinishesOnceAndCanBeCancelled() {
    var now = Date(timeIntervalSince1970: 0)
    let timer = QuickTimer(clock: { now })
    var finished: [String] = []
    timer.onFinish = { finished.append($0) }
    timer.start(300, label: "Tea")
    now += 120
    #expect(timer.isRunning && timer.remaining(at: now) == 180)
    timer.finish()
    timer.finish()
    #expect(finished == ["Tea"] && !timer.isRunning)
    timer.start(60)
    timer.cancel()
    timer.finish()  // nothing: it was cancelled
    #expect(finished == ["Tea"])
    timer.start(60)
    timer.finish()
    #expect(finished == ["Tea", "Timer done"])
}

@Test func theLauncherStartsATimerFromTheQuery() {
    let item = LauncherModel.timer("timer 10m pasta")
    #expect(item?.title == "Start a 10:00 Timer: Pasta" && item?.action == "timer|600|Pasta")
    #expect(LauncherModel.timer("pasta") == nil)
}

@Test func pickedColoursBecomeHex() {
    #expect(ColorPick.hex(red: 1, green: 0, blue: 0) == "#FF0000")
    #expect(ColorPick.hex(red: 0.2, green: 0.4, blue: 0.6) == "#336699")
    #expect(ColorPick.hex(red: -1, green: 2, blue: 0.5) == "#00FF80")  // clamped
}

@MainActor @Test func notesForPowerTimersAndColoursShareTheSlot() {
    let notices = DeviceNotices(scheduler: FakeScheduler())
    notices.post(.init(id: "color-1", title: "#336699", detail: "Copied to the clipboard", symbol: "eyedropper", swatch: [0.2, 0.4, 0.6]))
    #expect(notices.current?.swatch == [0.2, 0.4, 0.6])
    notices.post(.init(id: "power", state: "charging", title: "Charging", detail: "50%", symbol: "battery.100percent.bolt", tint: .good, level: 0.5))
    #expect(notices.current?.title == "Charging")
    notices.post(.init(id: "power", state: "charging", title: "Charging", detail: "51%", symbol: "battery.100percent.bolt"))
    #expect(notices.current?.detail == "50%")  // the same state again within 10 s isn't repeated
}

// MARK: Settings

@MainActor @Test func theNotchHasItsOwnSettingsPane() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let dashboard = DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store)
    let model = SettingsModel(dashboard: dashboard, preferences: PreferencesModel(file: nil), dataDirectory: temp.url)
    for (search, section) in [("notch", SettingsSection.notch), ("disable notch", .notch), ("low power", .notch),
                              ("charging", .notch), ("colour picker", .launcher), ("timer", .launcher)] {
        model.search = search
        #expect(model.visibleSections.contains(section), "\(search)")
    }
    let preferences = PreferencesModel(file: nil)
    preferences.update { $0.notchEnabled = false; $0.notchOpen = .click }
    preferences.resetGeneral()
    #expect(preferences.value.notchEnabled && preferences.value.notchOpen == .hover)
}

// MARK: Review fixes

@Test func signsAndIdentifiersInTheCalculator() {
    #expect(Calculator.evaluate("-2^2") == -4 && Calculator.evaluate("2^-1") == 0.5 && Calculator.evaluate("(-2)^2") == 4)
    for text in ["2024-11-17", "555-1234", "12/25/2024", "1.2.3", "5-3"] {
        #expect(Calculator.evaluate(text) == nil, "\(text)")  // dates, phone numbers and versions stay searches
    }
    #expect(Calculator.evaluate("10 - 3") == 7 && Calculator.evaluate("10/4") == 2.5)
}

@Test func appleMusicTitlesKeepTheirArtist() {
    #expect(LyricsQuery.clean(title: "Bohemian Rhapsody - Remastered 2011", artist: "Queen", videoTitle: false)
            == ("Bohemian Rhapsody", "Queen"))
    #expect(LyricsQuery.clean(title: "Daft Punk - Get Lucky", artist: "Some Channel") == ("Get Lucky", "Daft Punk"))
}

@MainActor @Test func anAdClearsTheLastSongsLyrics() async {
    final class HTTP: WeatherHTTP, @unchecked Sendable {
        func get(_ url: URL) async throws -> (Data, Int) {
            (Data(#"[{"trackName":"Song","duration":200,"instrumental":false,"syncedLyrics":"[00:01.00]la"}]"#.utf8), 200)
        }
    }
    let model = LyricsModel(http: HTTP())
    model.isEnabled = true
    model.follow(NowPlaying(sourceID: "brave-youtube", appName: "Brave", title: "Song", artist: "A", state: .playing, duration: 200, updatedAt: .now))
    await model.settle()
    #expect(model.status == .found)
    var ad = NowPlaying(sourceID: "brave-youtube", appName: "Brave", title: "Ad", artist: "A", state: .playing, updatedAt: .now)
    ad.isAd = true
    model.follow(ad)
    #expect(model.lyrics == nil && model.status == .idle)
}

@MainActor @Test func theTimerRowSurvivesSpotlightsAnswer() async throws {
    final class Files: FileSearching {
        func search(_ query: String, limit: Int, results: @escaping @MainActor ([LauncherItem]) -> Void) {
            results([LauncherItem(id: "file:/tmp/timer 10m notes.txt", kind: .file, title: "timer 10m notes.txt", path: "/tmp/timer 10m notes.txt")])
        }
        func cancel() {}
    }
    let model = LauncherModel(file: nil, files: Files(), apps: [])
    model.query = "timer 10m"
    #expect(model.results.first?.id == "orbit:timer")
    for _ in 0..<40 where !model.results.contains(where: { $0.kind == .file }) { try await Task.sleep(for: .milliseconds(20)) }
    #expect(model.results.contains { $0.kind == .file })
    #expect(model.results.first?.id == "orbit:timer")  // still first after the file results arrive
}

@MainActor @Test func thePowerWatcherFeedsEveryReading() {
    var reading: BatteryStatus? = BatteryStatus(percent: 40, isCharging: false, isPluggedIn: false)
    let watcher = PowerWatcher(read: { reading })
    var seen: [Int] = []
    watcher.onReading = { seen.append($0.percent) }
    watcher.prime()
    reading = BatteryStatus(percent: 39, isCharging: false, isPluggedIn: false)
    watcher.changed()
    #expect(seen == [39])
}
