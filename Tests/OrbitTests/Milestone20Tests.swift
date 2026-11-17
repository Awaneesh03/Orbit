import Foundation
import Synchronization
import Testing
@testable import Orbit

// Milestone 20 (Sapphire parity and more): device notices, lyrics, the month
// grid, the launcher's calculator and Shortcuts, AirDrop from the shelf and the
// completed settings. No test touches Bluetooth, the network, Calendar or Shortcuts.

// MARK: Device notices

private func notice(_ id: String = "aa-bb", connected: Bool = true, battery: Int? = nil) -> DeviceNotices.Notice {
    .device(id: id, name: "AirPods Pro", symbol: "headphones", connected: connected, battery: battery)
}

@MainActor @Test func deviceNoticeShowsThenLeavesOnItsOwn() {
    let scheduler = FakeScheduler()
    let notices = DeviceNotices(scheduler: scheduler)
    notices.post(notice(battery: 80))
    #expect(notices.current?.detail == "Connected · 80%")
    scheduler.advance(.seconds(2))
    #expect(notices.current != nil)
    scheduler.advance(.seconds(1))
    #expect(notices.current == nil)
    #expect(notice(connected: false).detail == "Disconnected" && notice().detail == "Connected")
}

@MainActor @Test func aFlappingDeviceIsAnnouncedOncePerState() {
    let scheduler = FakeScheduler()
    var now = Date(timeIntervalSince1970: 1_000)
    let notices = DeviceNotices(scheduler: scheduler, clock: { now })
    notices.post(notice())
    scheduler.advance(.seconds(3))
    notices.post(notice())  // the same state again within 10 s: not repeated
    #expect(notices.current == nil)
    notices.post(notice(connected: false))  // a real change shows
    #expect(notices.current?.state == "disconnected")
    scheduler.advance(.seconds(3))
    now += DeviceNotices.repeatWindow + 1
    notices.post(notice(connected: false))
    #expect(notices.current?.state == "disconnected" && notices.current?.title == "AirPods Pro")
}

@MainActor @Test func deviceNoticesYieldTheSlotAndTheSwitch() {
    let notices = DeviceNotices(scheduler: FakeScheduler())
    notices.canShow = { false }  // something more important holds the slot: dropped, not queued
    notices.post(notice())
    #expect(notices.current == nil)
    notices.canShow = { true }
    notices.post(notice("other"))
    #expect(notices.current != nil)
    notices.isEnabled = false  // turning it off clears what shows and stops new ones
    #expect(notices.current == nil)
    notices.post(notice("third"))
    #expect(notices.current == nil)
}

// MARK: Lyrics

@Test func lrcParsesTimesAndSkipsMetadata() {
    let lines = Lyrics.parseLRC("""
    [ar:Someone]
    [00:12.50]First line
    [00:05.00][01:00.00]Chorus
    [bad]ignored tag only
    [00:20]Third
    """)
    #expect(lines.map(\.time) == [5, 12.5, 20, 60])
    #expect(lines.map(\.text) == ["Chorus", "First line", "Third", "Chorus"])
    let lyrics = Lyrics(synced: lines)
    #expect(lyrics.lineIndex(at: 1) == nil)
    #expect(lyrics.lineIndex(at: 5) == 0 && lyrics.lineIndex(at: 15) == 1 && lyrics.lineIndex(at: 400) == 3)
}

@Test func youTubeTitlesBecomeCleanQueries() {
    #expect(LyricsQuery.clean(title: "Daft Punk - Get Lucky (Official Video)", artist: "DaftPunkVEVO") == ("Get Lucky", "Daft Punk"))
    #expect(LyricsQuery.clean(title: "Shape of You [Official Lyric Video] | Ed Sheeran", artist: "Ed Sheeran") == ("Shape of You", "Ed Sheeran"))
    #expect(LyricsQuery.clean(title: "Song (feat. Friend)", artist: "Artist - Topic") == ("Song (feat. Friend)", "Artist"))
    #expect(LyricsQuery.clean(title: "Bohemian Rhapsody", artist: nil) == ("Bohemian Rhapsody", nil))
}

@Test func theBestRecordPrefersSyncedAndTheRightLength() {
    typealias R = LyricsQuery.Record
    let records = [R(trackName: "A", artistName: nil, duration: 300, instrumental: false, plainLyrics: "long", syncedLyrics: "[00:01]x"),
                   R(trackName: "A", artistName: nil, duration: 200, instrumental: false, plainLyrics: "plain", syncedLyrics: nil),
                   R(trackName: "A", artistName: nil, duration: 201, instrumental: false, plainLyrics: nil, syncedLyrics: "[00:01]y"),
                   R(trackName: "A", artistName: nil, duration: 200, instrumental: false, plainLyrics: nil, syncedLyrics: nil)]
    #expect(LyricsQuery.best(records, duration: 200)?.syncedLyrics == "[00:01]y")
    #expect(LyricsQuery.best(records, duration: nil)?.syncedLyrics == "[00:01]x")
    #expect(LyricsQuery.best(records, duration: 999) == nil)
    let url = LyricsQuery.searchURL(track: "Get Lucky", artist: "Daft Punk").absoluteString
    #expect(url.hasPrefix("https://lrclib.net/api/search?") && url.contains("track_name=Get%20Lucky") && url.contains("artist_name=Daft%20Punk"))
}

private final class LyricsHTTP: WeatherHTTP, @unchecked Sendable {
    let state = Mutex<(body: String, code: Int, calls: [URL])>(("[]", 200, []))
    func get(_ url: URL) async throws -> (Data, Int) {
        let (body, code) = state.withLock { $0.calls.append(url); return ($0.body, $0.code) }
        return (Data(body.utf8), code)
    }
    var calls: Int { state.withLock { $0.calls.count } }
}

private func track(_ title: String, artist: String = "Artist") -> NowPlaying {
    NowPlaying(sourceID: "brave-youtube", appName: "Brave", title: title, artist: artist, state: .playing, duration: 200, updatedAt: .now)
}

@MainActor @Test func lyricsLookUpEachTrackOnceAndOnlyWhenOn() async {
    let http = LyricsHTTP()
    http.state.withLock { $0.body = #"[{"trackName":"Song","duration":200,"instrumental":false,"plainLyrics":"la","syncedLyrics":"[00:01.00]la"}]"# }
    let model = LyricsModel(http: http)
    model.follow(track("Song"))
    #expect(http.calls == 0 && model.status == .off)  // off by default: nothing is sent
    model.isEnabled = true
    model.follow(track("Song"))
    await model.settle()
    #expect(model.status == .found && model.lyrics?.synced.first?.text == "la")
    model.follow(track("Song"))  // a position update of the same track
    model.follow(track("Other"))
    await model.settle()
    model.follow(track("Song"))  // back: from memory
    #expect(http.calls == 2 && model.status == .found)
    model.isEnabled = false
    #expect(model.lyrics == nil && model.status == .off)
}

@MainActor @Test func lyricsFailuresAreRetriedAndMissesRemembered() async {
    let http = LyricsHTTP()
    http.state.withLock { $0.code = 500 }
    let model = LyricsModel(http: http)
    model.isEnabled = true
    model.follow(track("Song"))
    await model.settle()
    #expect(model.status == .failed)
    http.state.withLock { $0.code = 200; $0.body = "[]" }
    model.follow(track("Song"))  // a failure isn't remembered
    await model.settle()
    #expect(model.status == .notFound && http.calls == 2)
    model.follow(track("Song"))
    #expect(http.calls == 2)  // a miss is
}

// MARK: Calculator and Shortcuts

@Test func calculatorDoesArithmeticOnly() {
    #expect(Calculator.evaluate("12*4+3") == 51)
    #expect(Calculator.evaluate("(5+3)/2") == 4)
    #expect(Calculator.evaluate("2^3^2") == 512)
    #expect(Calculator.evaluate("-3 + 10 % 4") == -1)
    #expect(Calculator.evaluate("6 × 7") == 42 && Calculator.evaluate("84 ÷ 2") == 42)
    #expect(Calculator.evaluate("1,000 + 1") == 1001)
    #expect(Calculator.evaluate("2*pi").map { abs($0 - 2 * .pi) < 1e-12 } == true)
    for text in ["2024", "safari", "1/0", "5 +", "(2", "2)(", "rm -rf", "3..4+1", ""] {
        #expect(Calculator.evaluate(text) == nil, "\(text)")
    }
    #expect(Calculator.format(51) == 51.formatted() && !Calculator.format(1.0 / 3).contains("e"))
    #expect(Calculator.plain(1024) == "1024" && Calculator.plain(2.5) == "2.5" && Calculator.plain(1.0 / 3) == "0.3333333333")
}

@MainActor @Test func theLauncherShowsASumFirstAndNeverRemembersIt() {
    let model = LauncherModel(file: nil, files: nil, apps: [LauncherItem(id: "app:/Calculator.app", kind: .app, title: "Calculator", path: "/Calculator.app")],
                              shortcuts: ShortcutsCatalog.parse("Morning Routine\nMorning Routine\n"))
    model.query = "12*4"
    #expect(model.results.first?.kind == .calculation && model.results.first?.action == "48")
    model.remember(model.results[0])
    #expect(model.memory.recentItems.isEmpty)
    model.category = .apps
    #expect(model.results.allSatisfy { $0.kind == .app })  // a sum only in All
    model.category = .all
    model.query = "morning"
    #expect(model.results.filter { $0.kind == .shortcut }.map(\.title) == ["Morning Routine"])
    model.searchesShortcuts = false
    model.search()
    #expect(!model.results.contains { $0.kind == .shortcut })
    #expect(LauncherCategory.orbit.contains(.shortcut) && !LauncherCategory.files.contains(.calculation))
}

@Test func shortcutsListAndEditLinks() {
    #expect(ShortcutsCatalog.parse("A\n\n B \nA\nC") == ["A", "B", "C"])
    #expect(ShortcutsCatalog.editURL("Log Water")?.absoluteString == "shortcuts://open-shortcut?name=Log%20Water")
}

// MARK: Month grid

private func gregorian(firstWeekday: Int) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    calendar.firstWeekday = firstWeekday
    return calendar
}

private func day(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0, _ calendar: Calendar) -> Date {
    calendar.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
}

private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false) -> AgendaEvent {
    AgendaEvent(id: title, title: title, start: start, end: end, isAllDay: allDay, calendarID: "work", calendarTitle: "Work", color: nil)
}

@Test func theGridIsSixWeeksFromTheFirstWeekday() {
    let sunday = gregorian(firstWeekday: 1), monday = gregorian(firstWeekday: 2)
    let november = day(2026, 11, 17, 10, sunday)  // 1 November 2026 is a Sunday
    let a = MonthGrid.days(containing: november, calendar: sunday)
    #expect(a.count == 42 && a.first == day(2026, 11, 1, 0, sunday))
    let b = MonthGrid.days(containing: november, calendar: monday)
    #expect(b.first == day(2026, 10, 26, 0, monday) && sunday.component(.weekday, from: b[0]) == 2)
    #expect(MonthGrid.weekdaySymbols(monday).first == monday.veryShortStandaloneWeekdaySymbols[1])
}

@Test func busyDaysAndADaysEvents() {
    let calendar = gregorian(firstWeekday: 1)
    let trip = event("Trip", day(2026, 11, 3, 0, calendar), day(2026, 11, 6, 0, calendar), allDay: true)  // ends at midnight
    let call = event("Call", day(2026, 11, 4, 10, calendar), day(2026, 11, 4, 11, calendar))
    let busy = MonthGrid.busyDays([trip, call], calendar: calendar)
    #expect(busy == Set([3, 4, 5].map { day(2026, 11, $0, 0, calendar) }))
    #expect(MonthGrid.events([call, trip], on: day(2026, 11, 4, 0, calendar), calendar: calendar).map(\.title) == ["Trip", "Call"])
    #expect(MonthGrid.events([call, trip], on: day(2026, 11, 6, 0, calendar), calendar: calendar).isEmpty)
}

@MainActor @Test func theMonthWidgetMovesAndReadsOnlyWhenConnected() async throws {
    let calendar = gregorian(firstWeekday: 1)
    let now = day(2026, 11, 17, 9, calendar)
    let store = MockCalendarStore()
    store.set {
        $0.calendars = [CalendarInfo(id: "work", title: "Work", source: "iCloud", color: nil)]
        $0.events = [event("Standup", day(2026, 11, 18, 9, calendar), day(2026, 11, 18, 10, calendar))]
    }
    let events = EventsWidget(store: store, settings: CalendarSettingsModel(file: nil), calendar: { calendar }, clock: { now })
    let month = MonthCalendarWidget(events: events, clock: { now })
    month.start()
    #expect(store.fetches == 0 && month.monthEvents.isEmpty)  // not connected: the grid only, nothing read or asked
    #expect(store.requests == 0)
    store.set { $0.access = .granted }
    month.start()
    for _ in 0..<100 where month.monthEvents.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(month.busy.contains(day(2026, 11, 18, 0, calendar)))
    month.select(day(2026, 11, 18, 15, calendar))
    #expect(month.selectedEvents.map(\.title) == ["Standup"])
    month.move(by: 1)
    #expect(month.month == day(2026, 12, 1, 0, calendar) && month.selected == month.month)
    month.goToToday()
    #expect(month.selected == day(2026, 11, 17, 0, calendar))
    month.stop()
    #expect(month.monthEvents.isEmpty)
}

// MARK: Shelf, clipboard, focus, preferences, settings

@MainActor @Test func airDropSendsOnlyFilesStillThere() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let here = temp.url.appending(path: "here.txt"), gone = temp.url.appending(path: "gone.txt")
    try Data("a".utf8).write(to: here)
    try Data("b".utf8).write(to: gone)
    let shelf = FileShelf(file: nil, folder: temp.url.appending(path: "Shelf"))
    shelf.add([here, gone])
    try FileManager.default.removeItem(at: gone)
    #expect(shelf.airDropURLs(shelf.items).map(\.lastPathComponent) == ["here.txt"])
}

@MainActor @Test func clipboardKeepsTheChosenNumber() {
    var change = 0
    var text = ""
    let clips = ClipboardHistory(read: { (change, text, []) }, write: { _ in change })
    clips.setOn(true)
    for index in 0..<30 {
        change += 1
        text = "item \(index)"
        clips.poll()
    }
    #expect(clips.items.count == 30)
    clips.capacity = 20
    #expect(clips.items.count == 20 && clips.items.first?.text == "item 29")
    var saved: Bool?
    clips.onUserToggle = { saved = $0 }
    clips.userSetOn(false)
    #expect(saved == false && clips.items.isEmpty)
}

@MainActor @Test func focusLengthsAreSetAndBounded() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let pomodoro = PomodoroWidget(file: temp.file("pomodoro.json"))
    pomodoro.setLengths(focusMinutes: 50, breakMinutes: 10)
    #expect(pomodoro.timer.focusLength == 3000 && pomodoro.timer.breakLength == 600)
    pomodoro.setLengths(focusMinutes: 500, breakMinutes: 0)
    #expect(pomodoro.timer.focusLength == 7200 && pomodoro.timer.breakLength == 60)
}

@Test func newPreferencesDecodeWithSafeDefaults() throws {
    let old = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"hideDelay":1}"#.utf8))
    #expect(old.deviceNotices && !old.lyrics && !old.clipboardHistory && old.clipboardLimit == 40 && old.launcherShortcuts)
    let odd = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"clipboardLimit":7,"lyrics":true}"#.utf8))
    #expect(odd.clipboardLimit == 40 && odd.lyrics)  // not one of the choices: back to the default
    var value = OrbitPreferences()
    value.clipboardLimit = 200
    let round = try JSONDecoder().decode(OrbitPreferences.self, from: JSONEncoder().encode(value))
    #expect(round.clipboardLimit == 200)
}

@MainActor @Test func settingsHaveAProductivityPaneAndFindNewThings() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let dashboard = DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store)
    let model = SettingsModel(dashboard: dashboard, preferences: PreferencesModel(file: nil), dataDirectory: temp.url)
    #expect(SettingsSection.allCases.contains(.productivity))
    for (search, section) in [("clipboard", SettingsSection.productivity), ("airdrop", .productivity), ("lyrics", .general),
                              ("bluetooth devices", .notch), ("calculator", .launcher)] {
        model.search = search
        #expect(model.visibleSections.contains(section), "\(search)")
    }
    let permissions = PermissionCatalog.current()
    #expect(permissions.contains { $0.name == "Bluetooth" } && permissions.contains { $0.name == "Location" })
    #expect(!permissions.contains { $0.purpose.contains("sample data") })
}
