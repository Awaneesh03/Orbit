import AppKit
import EventKit
import SwiftUI
import Synchronization

// Read-only access to the Mac's calendars through EventKit. Events are read
// on demand and kept in memory only; Orbit never writes events, never asks
// for Reminders, and never sends calendar data anywhere. Only the selected
// calendars' identifiers are saved (calendar.json).

enum CalendarAccess: Equatable, Sendable {
    case notDetermined, granted, denied, restricted
    /// Write-only access can't read events: treated like not granted.
    case writeOnly
}

struct CalendarColor: Equatable, Sendable {
    let red: Double, green: Double, blue: Double
    var color: Color { Color(red: red, green: green, blue: blue) }
}

struct CalendarInfo: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    let source: String
    let color: CalendarColor?
}

/// One occurrence of an event on the agenda.
struct AgendaEvent: Identifiable, Equatable, Sendable {
    /// The event's identifier plus this occurrence's start: recurring events
    /// and events with the same title stay distinct.
    let id: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let calendarID: String
    let calendarTitle: String
    let color: CalendarColor?

    func isHappening(at now: Date) -> Bool { start <= now && now < end }
}

/// What Orbit needs from a calendar store (EventKit, or a mock in tests).
protocol CalendarStore: AnyObject, Sendable {
    func access() -> CalendarAccess
    /// Shows the system prompt (only ever called from an explicit Connect click).
    func requestFullAccess() async throws -> Bool
    func calendars() -> [CalendarInfo]
    /// Occurrences overlapping [start, end) in the given calendars (nil: all).
    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [AgendaEvent]
    /// Calls `changed` on the main queue whenever the calendar database changes.
    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any NSObjectProtocol
}

final class EventKitStore: CalendarStore, @unchecked Sendable {
    // ponytail: EKEventStore isn't Sendable; Orbit only reads from it, which EventKit allows from any thread.
    private let store = EKEventStore()

    func access() -> CalendarAccess {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: .notDetermined
        case .fullAccess: .granted
        case .writeOnly: .writeOnly
        case .restricted: .restricted
        case .denied: .denied
        @unknown default: .denied
        }
    }

    func requestFullAccess() async throws -> Bool {
        let granted = try await store.requestFullAccessToEvents()
        if granted { store.reset() }  // pick up calendars visible only after the grant
        return granted
    }

    func calendars() -> [CalendarInfo] {
        store.calendars(for: .event).map { calendar in
            let rgb = NSColor(cgColor: calendar.cgColor)?.usingColorSpace(.sRGB)
            return CalendarInfo(id: calendar.calendarIdentifier, title: calendar.title, source: calendar.source?.title ?? "",
                                color: rgb.map { CalendarColor(red: $0.redComponent, green: $0.greenComponent, blue: $0.blueComponent) })
        }
        .sorted { ($0.source, $0.title) < ($1.source, $1.title) }
    }

    func events(from start: Date, to end: Date, calendarIDs: Set<String>?) -> [AgendaEvent] {
        let chosen = store.calendars(for: .event).filter { calendarIDs?.contains($0.calendarIdentifier) ?? true }
        guard !chosen.isEmpty else { return [] }
        let colors = Dictionary(uniqueKeysWithValues: calendars().map { ($0.id, $0.color) })
        return store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: chosen)).map { event in
            AgendaEvent(
                id: "\(event.eventIdentifier ?? event.calendarItemIdentifier)@\(Int(event.startDate.timeIntervalSinceReferenceDate))",
                title: event.title?.isEmpty == false ? event.title : "Untitled event",
                start: event.startDate, end: event.endDate, isAllDay: event.isAllDay,
                calendarID: event.calendar.calendarIdentifier, calendarTitle: event.calendar.title,
                color: colors[event.calendar.calendarIdentifier] ?? nil)
        }
    }

    func observeChanges(_ changed: @escaping @Sendable () -> Void) -> any NSObjectProtocol {
        NotificationCenter.default.addObserver(forName: .EKEventStoreChanged, object: store, queue: .main) { _ in changed() }
    }
}

// MARK: Agenda

/// One local day's events: all-day ones apart, timed ones in order.
struct Agenda: Equatable, Sendable {
    let day: Date
    let allDay: [AgendaEvent]
    let timed: [AgendaEvent]

    init(events: [AgendaEvent], day: Date) {
        self.day = day
        allDay = events.filter(\.isAllDay).sorted { ($0.title, $0.id) < ($1.title, $1.id) }
        timed = events.filter { !$0.isAllDay }.sorted {
            ($0.start, $0.end, $0.title, $0.id) < ($1.start, $1.end, $1.title, $1.id)
        }
    }

    var isEmpty: Bool { allDay.isEmpty && timed.isEmpty }

    /// In progress now (an all-day event isn't counted: it's the whole day).
    func current(at now: Date) -> [AgendaEvent] { timed.filter { $0.isHappening(at: now) } }
    /// The next event that hasn't started; ended events never count.
    func next(at now: Date) -> AgendaEvent? { timed.first { $0.start > now } }
    /// Happening now or still to come.
    func remaining(at now: Date) -> [AgendaEvent] { timed.filter { $0.end > now } }

    /// [start of the day, start of the next day) in `calendar`: 23 or 25 hours across DST.
    static func bounds(of now: Date, in calendar: Calendar) -> (start: Date, end: Date) {
        let start = calendar.startOfDay(for: now)
        return (start, calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400))
    }

    /// "10:30 – 11:00 AM", "Until 2:00 AM" (began on an earlier day), "11:00 PM – tomorrow".
    static func timeRange(_ event: AgendaEvent, day: Date, calendar: Calendar) -> String {
        let style = Date.FormatStyle(date: .omitted, time: .shortened, timeZone: calendar.timeZone)
        let (dayStart, dayEnd) = bounds(of: day, in: calendar)
        switch (event.start < dayStart, event.end > dayEnd) {
        case (true, true): return "All day"
        case (true, false): return "Until \(event.end.formatted(style))"
        case (false, true): return "\(event.start.formatted(style)) – tomorrow"
        case (false, false): return "\(event.start.formatted(style)) – \(event.end.formatted(style))"
        }
    }

    /// "in 25 min", "in 2 hr 5 min", "Starting now".
    static func countdown(to start: Date, from now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        if minutes <= 0 { return "Starting now" }
        if minutes < 60 { return "in \(minutes) min" }
        let (hours, rest) = minutes.quotientAndRemainder(dividingBy: 60)
        return rest == 0 ? "in \(hours) hr" : "in \(hours) hr \(rest) min"
    }
}

/// The calendars to read, shared with the off-main data source.
final class CalendarSelection: Sendable {
    private let ids = Mutex<Set<String>?>(nil)
    var current: Set<String>? { ids.withLock { $0 } }
    func set(_ value: Set<String>?) { ids.withLock { $0 = value } }
}

/// Today's agenda from the store, read off the main actor.
struct AgendaSource: DataSource {
    let store: any CalendarStore
    let selection: CalendarSelection
    let calendar: @Sendable () -> Calendar
    let now: @Sendable () -> Date

    func fetch() async throws -> Agenda {
        switch store.access() {
        case .granted: break
        case .restricted: throw DataSourceError.unavailable("Calendar access is restricted on this Mac.")
        case .notDetermined, .denied, .writeOnly: throw DataSourceError.needsAccess("Calendar access isn't granted.")
        }
        try Task.checkCancellation()
        let calendar = calendar()
        let date = now()
        let (start, end) = Agenda.bounds(of: date, in: calendar)
        return Agenda(events: store.events(from: start, to: end, calendarIDs: selection.current), day: start)
    }
}

// MARK: Settings (calendar.json: identifiers only, never events)

struct CalendarSettings: Codable, Equatable, Sendable {
    /// Off after Disconnect: Orbit stops reading (macOS keeps the permission;
    /// revoke it in System Settings › Privacy & Security › Calendars).
    var isEnabled = true
    /// nil until the user customises: every calendar, including new ones.
    /// Once set, new calendars stay unselected; missing ones are skipped.
    var selectedCalendarIDs: [String]?

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isEnabled = (try? container.decode(Bool.self, forKey: .isEnabled)) ?? true
        selectedCalendarIDs = try? container.decodeIfPresent([String].self, forKey: .selectedCalendarIDs)
    }
}

@MainActor @Observable
final class CalendarSettingsModel {
    static let fileName = "calendar.json"
    private var stored: Persisted<CalendarSettings>

    var value: CalendarSettings { stored.value }
    var problem: String? { stored.problem }

    init(file: JSONFile<CalendarSettings>?) {
        stored = file.map { Persisted($0, initial: CalendarSettings()) } ?? Persisted(memory: CalendarSettings())
    }

    func setEnabled(_ enabled: Bool) {
        guard value.isEnabled != enabled else { return }
        stored.update { $0.isEnabled = enabled }
    }

    /// Which of `available` are read: all by default, else the chosen ones that still exist.
    func selected(in available: [CalendarInfo]) -> Set<String> {
        let ids = Set(available.map(\.id))
        return value.selectedCalendarIDs.map { Set($0).intersection(ids) } ?? ids
    }

    func setSelected(_ id: String, _ isSelected: Bool, available: [CalendarInfo]) {
        var chosen = value.selectedCalendarIDs.map(Set.init) ?? Set(available.map(\.id))
        if isSelected { chosen.insert(id) } else { chosen.remove(id) }
        stored.update { $0.selectedCalendarIDs = chosen.sorted() }
    }

    /// Back to "all calendars, including new ones".
    func selectAll() { stored.update { $0.selectedCalendarIDs = nil } }
}
