import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.5: the Calendar widget over a mock EventKit store. No test touches
// the real calendar database or asks for permission.

/// A stand-in for EventKit: scripted access, calendars and occurrences.
private final class MockCalendarStore: CalendarStore, @unchecked Sendable {
    struct State {
        var access = CalendarAccess.notDetermined
        var grantOnRequest = true
        var requests = 0
        var fetches = 0
        var calendars: [CalendarInfo] = []
        var events: [AgendaEvent] = []
        var handlers: [@Sendable () -> Void] = []
    }
    let state = Mutex(State())

    func access() -> CalendarAccess { state.withLock { $0.access } }

    func requestFullAccess() async throws -> Bool {
        state.withLock {
            $0.requests += 1
            if $0.access == .notDetermined { $0.access = $0.grantOnRequest ? .granted : .denied }
            return $0.access == .granted
        }
    }

    func calendars() -> [CalendarInfo] { state.withLock { $0.calendars } }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [AgendaEvent] {
        state.withLock { state in
            state.fetches += 1
            return state.events.filter { event in
                event.start < end && event.end > start && (calendarIDs?.contains(event.calendarID) ?? true)
            }
        }
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any NSObjectProtocol {
        state.withLock { $0.handlers.append(changed) }
        return NSObject()
    }

    /// What EventKit does when the database (or the permission) changes.
    func simulateChange() { for handler in state.withLock({ $0.handlers }) { handler() } }
    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var fetches: Int { state.withLock { $0.fetches } }
    var requests: Int { state.withLock { $0.requests } }
    var observers: Int { state.withLock { $0.handlers.count } }
}

private let pune = TimeZone(identifier: "Asia/Kolkata")!
private func cal(_ zone: TimeZone = pune) -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = zone
    return calendar
}

/// `hour` hours after local midnight on 2026-`month`-`day` (Pune unless stated).
private func at(_ hour: Double, day: Int = 2, month: Int = 11, zone: TimeZone = pune) -> Date {
    cal(zone).date(from: DateComponents(year: 2026, month: month, day: day))!.addingTimeInterval(hour * 3600)
}

private func event(_ title: String, _ start: Date, _ end: Date, allDay: Bool = false, calendar id: String = "work",
                   identifier: String? = nil) -> AgendaEvent {
    AgendaEvent(id: "\(identifier ?? title)@\(Int(start.timeIntervalSinceReferenceDate))", title: title, start: start, end: end,
                isAllDay: allDay, calendarID: id, calendarTitle: id.capitalized, color: nil)
}

private let work = CalendarInfo(id: "work", title: "Work", source: "iCloud", color: CalendarColor(red: 0.3, green: 0.5, blue: 1))
private let home = CalendarInfo(id: "home", title: "Home", source: "iCloud", color: nil)

private final class Now: @unchecked Sendable {
    let date = Mutex(at(10))
    var value: Date { date.withLock { $0 } }
}

@MainActor
private func makeWidget(_ store: MockCalendarStore, settings: CalendarSettingsModel = CalendarSettingsModel(file: nil),
                        zone: TimeZone = pune) -> EventsWidget {
    let now = Now()
    return EventsWidget(store: store, settings: settings, calendar: { cal(zone) }, clock: { now.value })
}

@MainActor
private func settle(_ widget: EventsWidget) async {
    if widget.refresher.isRefreshing { await widget.refresher.refresh().value }
}

// MARK: Permission

@MainActor @Test func accessIsNeverRequestedUntilConnectIsClicked() async throws {
    let store = MockCalendarStore()
    store.set { $0.calendars = [work]; $0.events = [event("Stand-up", at(10.5), at(10.75))] }
    let widget = makeWidget(store)
    widget.start()
    widget.stop()
    widget.start()
    #expect(store.requests == 0 && store.fetches == 0)
    guard case .needsAccess = widget.state else {
        Issue.record("expected the Connect state, got \(widget.state)")
        return
    }
    #expect(widget.stateAction?.title == "Connect Calendar")
    #expect(widget.refresher.value == nil)  // no sample or fabricated events

    await widget.connect()
    await settle(widget)
    #expect(store.requests == 1)
    #expect(widget.state == .ready && widget.refresher.value?.timed.map(\.title) == ["Stand-up"])
}

@MainActor @Test func deniedRestrictedAndWriteOnlyAccess() async throws {
    let denied = MockCalendarStore()
    denied.set { $0.grantOnRequest = false }
    let widget = makeWidget(denied)
    widget.start()
    await widget.connect()
    guard case .needsAccess(let reason) = widget.state else {
        Issue.record("denied access must ask for access")
        return
    }
    #expect(reason.contains("System Settings"))
    #expect(widget.stateAction?.title == "Open Privacy Settings")  // macOS won't prompt twice
    await widget.connect()
    #expect(denied.requests == 1)

    let restricted = MockCalendarStore()
    restricted.set { $0.access = .restricted }
    let blocked = makeWidget(restricted)
    blocked.start()
    #expect(blocked.state == .unavailable("Calendar access is restricted on this Mac.") && blocked.stateAction == nil)

    let writeOnly = MockCalendarStore()
    writeOnly.set { $0.access = .writeOnly }
    let limited = makeWidget(writeOnly)
    limited.start()
    #expect(limited.stateAction?.title == "Open Privacy Settings" && writeOnly.fetches == 0)
}

@MainActor @Test func revokingAccessDropsEveryEventAndOffersReconnect() async throws {
    let store = MockCalendarStore()
    store.set { $0.access = .granted; $0.calendars = [work]; $0.events = [event("1:1", at(11), at(11.5))] }
    let widget = makeWidget(store)
    widget.start()
    await settle(widget)
    #expect(widget.refresher.value != nil)

    store.set { $0.access = .denied }  // turned off in System Settings while Orbit runs
    store.simulateChange()
    #expect(widget.refresher.value == nil && widget.calendars.isEmpty)
    guard case .needsAccess = widget.state else {
        Issue.record("revoked access must show the access state")
        return
    }
    store.set { $0.access = .granted }  // turned back on
    widget.stop()
    widget.start()
    await settle(widget)
    #expect(widget.refresher.value?.timed.count == 1)
}

@MainActor @Test func disconnectStopsReadingAndReconnectNeedsNoPrompt() async throws {
    let store = MockCalendarStore()
    store.set { $0.access = .granted; $0.calendars = [work]; $0.events = [event("Review", at(15), at(16))] }
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = makeWidget(store, settings: CalendarSettingsModel(file: temp.file("calendar.json")))
    widget.start()
    await settle(widget)
    widget.disconnect()
    #expect(widget.refresher.value == nil && !widget.isConnected)
    #expect(widget.stateAction?.title == "Connect Calendar")
    widget.stop()
    widget.start()
    #expect(store.fetches == 1)  // disconnected: nothing read
    #expect(CalendarSettingsModel(file: temp.file("calendar.json")).value.isEnabled == false)  // remembered
    await widget.connect()
    await settle(widget)
    #expect(store.requests == 0 && widget.isConnected && widget.refresher.value?.timed.count == 1)
}

// MARK: Agenda rules

@Test func agendaOrdersEventsAndSeparatesAllDay() {
    let events = [
        event("Lunch", at(13), at(14)), event("Stand-up", at(9.5), at(9.75)),
        event("Standup", at(9.5), at(10)),  // same start: shorter first
        event("Holiday", at(0), at(24), allDay: true), event("Trip", at(0, day: 1), at(24, day: 3), allDay: true),
    ]
    let agenda = Agenda(events: events, day: at(0))
    #expect(agenda.timed.map(\.title) == ["Stand-up", "Standup", "Lunch"])
    #expect(agenda.allDay.map(\.title) == ["Holiday", "Trip"])
    #expect(agenda.current(at: at(10.5)).isEmpty)  // all-day events aren't "in progress"
}

@Test func pastCurrentAndNextEvents() {
    let agenda = Agenda(events: [event("Early", at(8), at(9)), event("Now", at(9.5), at(10.5)), event("Later", at(14), at(15))],
                        day: at(0))
    let now = at(10)
    #expect(agenda.current(at: now).map(\.title) == ["Now"])
    #expect(agenda.next(at: now)?.title == "Later")         // never a past event
    #expect(agenda.remaining(at: now).map(\.title) == ["Now", "Later"])
    #expect(agenda.next(at: at(15.5)) == nil)
    #expect(Agenda.countdown(to: at(14), from: now) == "in 4 hr")
    #expect(Agenda.countdown(to: at(10.42), from: now) == "in 26 min")
    #expect(Agenda.countdown(to: at(11.5), from: now) == "in 1 hr 30 min")
    #expect(Agenda.countdown(to: now, from: now) == "Starting now")
}

@Test func recurringOccurrencesAndDuplicateTitlesStayDistinct() {
    let morning = event("Stand-up", at(9), at(9.25), identifier: "series-1")
    let evening = event("Stand-up", at(18), at(18.25), identifier: "series-1")  // same event, second occurrence
    let other = event("Stand-up", at(9), at(9.25), calendar: "home", identifier: "series-2")
    let agenda = Agenda(events: [evening, other, morning], day: at(0))
    #expect(Set(agenda.timed.map(\.id)).count == 3)
    #expect(agenda.timed.map(\.start) == [at(9), at(9), at(18)])
}

@Test func multiDayEventsAreLabelledFromTodaysPointOfView() {
    let calendar = cal()
    #expect(Agenda.timeRange(event("Flight", at(-2), at(2)), day: at(0), calendar: calendar).hasPrefix("Until "))
    #expect(Agenda.timeRange(event("Late show", at(23), at(25)), day: at(0), calendar: calendar).hasSuffix("– tomorrow"))
    #expect(Agenda.timeRange(event("Conference", at(-5), at(30)), day: at(0), calendar: calendar) == "All day")
    #expect(Agenda.timeRange(event("Lunch", at(13), at(14)), day: at(0), calendar: calendar).contains("–"))
}

@Test func dayBoundsFollowTheTimeZoneAndDaylightSaving() {
    let newYork = TimeZone(identifier: "America/New_York")!
    let springForward = Agenda.bounds(of: at(12, day: 8, month: 3, zone: newYork), in: cal(newYork))
    #expect(springForward.end.timeIntervalSince(springForward.start) == 23 * 3600)
    let fallBack = Agenda.bounds(of: at(12, day: 1, zone: newYork), in: cal(newYork))
    #expect(fallBack.end.timeIntervalSince(fallBack.start) == 25 * 3600)
    // The same instant falls on different local days in different zones (time-zone change).
    let instant = at(23)  // 11 PM in Pune is 12:30 PM in New York
    #expect(Agenda.bounds(of: instant, in: cal(pune)).start != Agenda.bounds(of: instant, in: cal(newYork)).start)
    // 1 AM on the spring-forward day, before the clocks change, shows as 1:00 local.
    let early = event("Call", at(1, day: 8, month: 3, zone: newYork), at(1.5, day: 8, month: 3, zone: newYork))
    #expect(Agenda.timeRange(early, day: springForward.start, calendar: cal(newYork)).hasPrefix("1:00"))
}

// MARK: Selection, refresh and lifecycle

@MainActor @Test func calendarSelectionDefaultsToAllAndRespectsCustomisation() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<CalendarSettings> = temp.file("calendar.json")
    let store = MockCalendarStore()
    store.set {
        $0.access = .granted
        $0.calendars = [work, home]
        $0.events = [event("Standup", at(11), at(11.5)), event("Dinner", at(20), at(21), calendar: "home")]
    }
    let widget = makeWidget(store, settings: CalendarSettingsModel(file: file))
    widget.start()
    await settle(widget)
    #expect(widget.selectedCalendarIDs == ["work", "home"])  // first connection: every calendar
    #expect(widget.refresher.value?.timed.count == 2)
    #expect(!FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)))  // nothing saved for a default

    widget.setCalendar("home", selected: false)
    await settle(widget)
    #expect(widget.refresher.value?.timed.map(\.title) == ["Standup"])
    #expect(try file.load()?.selectedCalendarIDs == ["work"])

    let family = CalendarInfo(id: "family", title: "Family", source: "iCloud", color: nil)
    store.set { $0.calendars = [work, family] }  // "home" removed, "family" added
    store.simulateChange()
    #expect(widget.selectedCalendarIDs == ["work"])  // the new calendar isn't silently selected
    widget.selectAllCalendars()
    #expect(widget.selectedCalendarIDs == ["work", "family"])
    #expect(try file.load()?.selectedCalendarIDs == nil)
}

@MainActor @Test func changesWhileHiddenWaitAndVisibleChangesRefresh() async throws {
    let store = MockCalendarStore()
    store.set { $0.access = .granted; $0.calendars = [work]; $0.events = [event("A", at(11), at(12))] }
    let widget = makeWidget(store)
    #expect(store.observers == 1)
    for _ in 0..<5 {  // repeated dashboard openings: no extra observers, no leftover data
        widget.start()
        await settle(widget)
        widget.stop()
        #expect(widget.refresher.value == nil)
    }
    #expect(store.observers == 1)
    let fetches = store.fetches

    store.set { $0.events.append(event("B", at(15), at(16))) }
    store.simulateChange()  // hidden: no read
    #expect(store.fetches == fetches)
    widget.start()
    await settle(widget)
    #expect(widget.refresher.value?.timed.map(\.title) == ["A", "B"])
    store.set { $0.events.append(event("C", at(17), at(18))) }
    store.simulateChange()  // visible: re-read
    await settle(widget)
    #expect(widget.refresher.value?.timed.map(\.title) == ["A", "B", "C"])

    NotificationCenter.default.post(name: .NSSystemTimeZoneDidChange, object: nil)  // time-zone change while visible
    await settle(widget)
    #expect(store.fetches == fetches + 3)
    widget.stop()
}

@MainActor @Test func hidingCancelsAndReleasesTheAgenda() async throws {
    let store = MockCalendarStore()
    store.set { $0.access = .granted; $0.calendars = [work]; $0.events = [event("A", at(11), at(12))] }
    let widget = makeWidget(store)
    widget.start()
    widget.stop()
    #expect(!widget.refresher.isRefreshing && widget.refresher.value == nil)
    try await Task.sleep(for: .milliseconds(50))
    #expect(widget.refresher.value == nil)  // a cancelled read never lands
}

@MainActor @Test func anEmptyDayIsEmptyNotFailed() async throws {
    let store = MockCalendarStore()
    store.set { $0.access = .granted; $0.calendars = [work] }
    let widget = makeWidget(store)
    widget.start()
    await settle(widget)
    #expect(widget.state == .empty("Nothing on your calendar today."))
    widget.stop()
}

// MARK: Privacy and rendering

@MainActor @Test func noEventDataIsWrittenToDisk() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let store = MockCalendarStore()
    store.set { $0.access = .granted; $0.calendars = [work, home]; $0.events = [event("Secret meeting", at(11), at(12))] }
    let widget = makeWidget(store, settings: CalendarSettingsModel(file: temp.file("calendar.json")))
    widget.start()
    await settle(widget)
    widget.setCalendar("home", selected: false)
    await settle(widget)
    widget.stop()
    let files = try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false))
    #expect(files == ["calendar.json"])
    let saved = try String(contentsOf: temp.url.appending(path: "calendar.json"), encoding: .utf8)
    #expect(!saved.contains("Secret") && !saved.contains("Work"))  // identifiers only, no titles
}

@MainActor @Test func compactAndExpandedAgendaRender() async throws {
    let store = MockCalendarStore()
    store.set {
        $0.access = .granted
        $0.calendars = [work]
        $0.events = [event("Design review", at(10.5), at(11)), event("Team sync", at(14), at(15)),
                     event("Holiday", at(0), at(24), allDay: true)]
    }
    let widget = makeWidget(store)
    widget.start()
    await settle(widget)
    let size = CGSize(width: 229, height: 160)
    let compact = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: size))
    let expanded = try #require(render(WidgetHost(widget: widget, presentation: .expanded), size: CGSize(width: 468, height: 160)))
    let connect = makeWidget(MockCalendarStore())
    let notConnected = try #require(render(WidgetHost(widget: connect, presentation: .compact), size: size))
    #expect(compact.pixels != notConnected.pixels && expanded.width == 468)
    let still = try #require(render(WidgetHost(widget: widget, presentation: .compact).environment(\.orbitReduceMotion, true), size: size))
    #expect(still.width == compact.width)  // Reduce Motion: same content, no transitions

    if let folder = ProcessInfo.processInfo.environment["ORBIT_RENDER_DIR"] {
        for (name, view, width) in [("calendar-compact", AnyView(WidgetHost(widget: widget, presentation: .compact)), 229.0),
                                    ("calendar-expanded", AnyView(WidgetHost(widget: widget, presentation: .expanded)), 468.0),
                                    ("calendar-connect", AnyView(WidgetHost(widget: connect, presentation: .compact)), 229.0)] {
            let renderer = ImageRenderer(content: view.frame(width: width, height: 160).background(Color.black)
                .environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
            }
        }
    }
    widget.stop()
}
