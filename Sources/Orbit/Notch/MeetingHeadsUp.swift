import AppKit
import Observation

// Next-meeting heads-up in the notch wings (Milestone 14). Uses the Calendar
// widget's EventKit store and its choices (connected, which calendars); never
// asks for access. Contextual and temporary: a subtle heads-up inside the
// notice window, an urgent one close to the start, "now" for the first
// minutes, then nothing. All-day, cancelled and finished events never show.

struct MeetingCue: Equatable, Sendable {
    enum Phase: Equatable, Sendable { case upcoming, soon, started }
    let eventID: String
    let title: String
    let start: Date
    let phase: Phase
    /// The event's validated join link, if any (Milestone 15).
    var joinURL: URL? = nil
    /// When it ends (Milestone 17: "back to your workspace" after a meeting).
    var end: Date? = nil

    struct Settings: Equatable, Sendable {
        var noticeMinutes = 30
        var urgentMinutes = 5
        /// How long "now" shows after the start.
        var startedMinutes = 5
    }

    /// The cue for `now`, from the occurrences Orbit can read: the next
    /// timed event that starts within the notice window, or started less than
    /// `startedMinutes` ago (the most recent start wins).
    static func current(from events: [AgendaEvent], now: Date, settings: Settings) -> MeetingCue? {
        let candidates = events.filter { !$0.isAllDay && $0.end > now }
            .compactMap { event -> MeetingCue? in
                let until = event.start.timeIntervalSince(now)
                let phase: Phase
                switch until {
                case ...(-Double(settings.startedMinutes) * 60): return nil  // started a while ago
                case ...0: phase = .started
                case ...(Double(settings.urgentMinutes) * 60): phase = .soon
                case ...(Double(settings.noticeMinutes) * 60): phase = .upcoming
                default: return nil
                }
                return MeetingCue(eventID: event.id, title: event.title, start: event.start, phase: phase, joinURL: event.meetingURL, end: event.end)
            }
        return candidates.min { abs($0.start.timeIntervalSince(now)) < abs($1.start.timeIntervalSince(now)) }
    }

    /// When the cue can next change (a phase boundary, or the next event
    /// entering the window), so the watcher sleeps until then instead of polling.
    static func nextChange(after now: Date, events: [AgendaEvent], settings: Settings) -> Date? {
        let offsets = [-Double(settings.noticeMinutes), -Double(settings.urgentMinutes), 0, Double(settings.startedMinutes)].map { $0 * 60 }
        return events.filter { !$0.isAllDay && $0.end > now }
            .flatMap { event in offsets.map { event.start.addingTimeInterval($0) } }
            .filter { $0 > now }
            .min()
    }

    /// "in 12 min", "in 1 min", "now".
    func countdown(at now: Date) -> String {
        let minutes = Int((start.timeIntervalSince(now) / 60).rounded(.up))
        return minutes <= 0 ? "now" : "in \(minutes) min"
    }
}

/// Follows the calendar for the wings: reads on start, on calendar changes
/// and at the next boundary only. Off: nothing scheduled, nothing read.
@MainActor @Observable
final class MeetingWatcher {
    private(set) var cue: MeetingCue?
    var settings = MeetingCue.Settings() { didSet { if settings != oldValue { refresh() } } }
    @ObservationIgnored private let store: (any CalendarStore)?
    @ObservationIgnored private let calendarSettings: () -> CalendarSettings
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private var observer: (any NSObjectProtocol)?
    private(set) var isRunning = false

    init(store: (any CalendarStore)?, calendarSettings: @escaping () -> CalendarSettings, clock: @escaping () -> Date = { .now }) {
        self.store = store
        self.calendarSettings = calendarSettings
        self.clock = clock
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        observer = store?.observeChanges { [weak self] in Task { @MainActor in self?.refresh() } }
        refresh()
    }

    func stop() {
        isRunning = false
        timer?.cancel()
        timer = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        cue = nil
    }

    #if DEBUG
    /// A simulated meeting `minutes` from now (debug command `meeting:<minutes>`; `meeting:off` clears).
    func debugSimulate(minutes: Double?) {
        guard let minutes else { return refresh() }
        let start = clock().addingTimeInterval(minutes * 60)
        let fake = AgendaEvent(id: "debug", title: "Design review", start: start, end: start.addingTimeInterval(1800), isAllDay: false,
                               calendarID: "debug", calendarTitle: "Debug", color: nil,
                               meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
        timer?.cancel()
        cue = MeetingCue.current(from: [fake], now: clock(), settings: settings)
    }
    #endif

    /// The events near `now` that a cue could come from: only with access already granted and the
    /// Calendar widget connected, from its chosen calendars. Never asks for access.
    static func nearbyEvents(store: (any CalendarStore)?, chosen: CalendarSettings, now: Date, settings: MeetingCue.Settings) -> [AgendaEvent]? {
        guard let store, store.access() == .granted, chosen.isEnabled else { return nil }
        let horizon = now.addingTimeInterval(TimeInterval(max(settings.noticeMinutes, 60) * 60 + 3600))
        return store.events(from: now.addingTimeInterval(-Double(settings.startedMinutes) * 60), to: horizon,
                            calendarIDs: chosen.selectedCalendarIDs.map(Set.init))
    }

    /// The cue right now without following the calendar (Quick Actions, when the dashboard opens).
    func peek() -> MeetingCue? {
        if isRunning { return cue }
        let now = clock()
        return Self.nearbyEvents(store: store, chosen: calendarSettings(), now: now, settings: settings)
            .flatMap { MeetingCue.current(from: $0, now: now, settings: settings) }
    }

    func refresh() {
        timer?.cancel()
        timer = nil
        let now = clock()
        guard isRunning, let events = Self.nearbyEvents(store: store, chosen: calendarSettings(), now: now, settings: settings) else {
            cue = nil
            return
        }
        let next = MeetingCue.current(from: events, now: now, settings: settings)
        if next != cue { cue = next }
        // Wake at the next boundary, or in an hour to look further ahead.
        let wake = MeetingCue.nextChange(after: now, events: events, settings: settings) ?? now.addingTimeInterval(3600)
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, wake.timeIntervalSince(now))), tolerance: .seconds(1))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }
}
