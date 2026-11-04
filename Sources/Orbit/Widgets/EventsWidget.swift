import SwiftUI

/// Today's agenda from the Mac's calendars (EventKit, read-only). Nothing is
/// read, and access is never requested, until the user clicks Connect
/// Calendar. Events live in memory only and are released when the widget is
/// hidden, when Orbit is disconnected and when access is revoked.
@MainActor @Observable
final class EventsWidget: DashboardWidget {
    static let privacyURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!

    let metadata = WidgetMetadata(
        id: "events", title: "Calendar", description: "Today's agenda and what's next",
        symbol: "calendar", category: .productivity, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded)
    let store: any CalendarStore
    let settings: CalendarSettingsModel
    let refresher: Refresher<Agenda>
    private(set) var access: CalendarAccess
    private(set) var calendars: [CalendarInfo] = []
    private(set) var isConnecting = false
    private(set) var isShown = false
    @ObservationIgnored private let selection = CalendarSelection()
    @ObservationIgnored private let calendarProvider: @Sendable () -> Calendar
    @ObservationIgnored private var observers: [any NSObjectProtocol] = []

    init(store: any CalendarStore, settings: CalendarSettingsModel,
         calendar: @escaping @Sendable () -> Calendar = { .autoupdatingCurrent },
         clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store
        self.settings = settings
        calendarProvider = calendar
        refresher = Refresher(source: AgendaSource(store: store, selection: selection, calendar: calendar, now: clock),
                              policy: .init(maxAge: 300))
        access = store.access()
        // Added once for the widget's lifetime; they only mark the agenda stale
        // (it refreshes only while visible).
        observers.append(store.observeChanges { [weak self] in
            MainActor.assumeIsolated { self?.calendarDatabaseChanged() }
        })
        for name in [Notification.Name.NSSystemTimeZoneDidChange, .NSCalendarDayChanged] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresher.markStale() }
            })
        }
    }

    var calendar: Calendar { calendarProvider() }
    var isConnected: Bool { access == .granted && settings.value.isEnabled }
    var selectedCalendarIDs: Set<String> { settings.selected(in: calendars) }

    var state: WidgetState {
        guard settings.value.isEnabled else {
            return .needsAccess("Calendar is disconnected.")
        }
        switch access {
        case .granted:
            return refresher.widgetState { $0.isEmpty ? "Nothing on your calendar today." : nil }
        case .notDetermined:
            return .needsAccess("See today's agenda here, read-only.")
        case .denied, .writeOnly:
            return .needsAccess("Calendar access is off. Turn it on in System Settings.")
        case .restricted:
            return .unavailable("Calendar access is restricted on this Mac.")
        }
    }

    var statusNote: WidgetNote? { isConnected ? refresher.statusNote : nil }

    var stateAction: WidgetAction? {
        if isConnected { return refresher.retryAction }
        if !settings.value.isEnabled || access == .notDetermined {
            return WidgetAction(title: "Connect Calendar", symbol: "calendar.badge.plus") { [weak self] in
                Task { await self?.connect() }
            }
        }
        switch access {
        case .denied, .writeOnly:  // macOS won't ask twice: the switch is in System Settings
            return WidgetAction(title: "Open Privacy Settings", symbol: "hand.raised") { NSWorkspace.shared.open(Self.privacyURL) }
        default:
            return nil
        }
    }

    func start() {
        isShown = true
        refreshAccess()
        if isConnected { refresher.becameVisible() }
    }

    /// Hidden: stop any read and let go of the events.
    func stop() {
        isShown = false
        refresher.becameHidden()
        refresher.reset()
    }

    /// The only place Orbit asks for calendar access: the user clicked Connect.
    func connect() async {
        settings.setEnabled(true)
        if store.access() == .notDetermined {
            isConnecting = true
            _ = try? await store.requestFullAccess()
            isConnecting = false
        }
        refreshAccess()
        if isConnected && isShown { refresher.becameVisible() }
    }

    /// Orbit stops reading; macOS keeps the permission until it's turned off there.
    func disconnect() {
        settings.setEnabled(false)
        refreshAccess()
    }

    /// Permission can change in System Settings at any time: re-read it, and
    /// drop every event if Orbit may no longer show them.
    func refreshAccess() {
        access = store.access()
        if isConnected {
            calendars = store.calendars()
            selection.set(selectedCalendarIDs)
        } else {
            refresher.becameHidden()
            refresher.reset()
            calendars = []
        }
    }

    func setCalendar(_ id: String, selected: Bool) {
        settings.setSelected(id, selected, available: calendars)
        selection.set(selectedCalendarIDs)
        refresher.markStale()
    }

    func selectAllCalendars() {
        settings.selectAll()
        selection.set(selectedCalendarIDs)
        refresher.markStale()
    }

    private func calendarDatabaseChanged() {
        refreshAccess()
        if isConnected { refresher.markStale() }
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        presentation == .compact ? AnyView(AgendaCompactView(widget: self)) : AnyView(AgendaExpandedView(widget: self))
    }
}

// MARK: Views

private struct AgendaCompactView: View {
    let widget: EventsWidget

    var body: some View {
        // Redraws once a minute, only while on screen: the countdown's only clock.
        TimelineView(.everyMinute) { context in
            let now = context.date
            let agenda = widget.refresher.value
            VStack(alignment: .leading, spacing: 7) {
                Text(now.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(OrbitType.caption)
                    .foregroundStyle(Theme.secondary)
                if let agenda {
                    if let current = agenda.current(at: now).first {
                        EventLine(event: current, agenda: agenda, calendar: widget.calendar, badge: "Happening now", isLive: true)
                    } else if let next = agenda.next(at: now) {
                        EventLine(event: next, agenda: agenda, calendar: widget.calendar,
                                  badge: Agenda.countdown(to: next.start, from: now), isLive: false)
                    } else {
                        Label("Nothing else today", systemImage: "checkmark.circle")
                            .font(OrbitType.body)
                            .foregroundStyle(Theme.tertiary)
                    }
                    Spacer(minLength: 0)
                    let later = max(0, agenda.remaining(at: now).count - 1)
                    let summary = [later > 0 ? "+\(later) more today" : nil,
                                   agenda.allDay.isEmpty ? nil : "\(agenda.allDay.count) all-day"].compactMap(\.self)
                    if !summary.isEmpty {
                        Text(summary.joined(separator: " · ")).font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                    }
                }
            }
        }
    }
}

private struct AgendaExpandedView: View {
    let widget: EventsWidget

    var body: some View {
        TimelineView(.everyMinute) { context in
            let now = context.date
            if let agenda = widget.refresher.value {
                HStack(alignment: .top, spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(now.formatted(.dateTime.weekday(.wide))).font(OrbitType.caption).foregroundStyle(Theme.secondary)
                        Text(now.formatted(.dateTime.day().month(.wide))).font(OrbitType.title)
                        Spacer(minLength: 6)
                        if let current = agenda.current(at: now).first {
                            Badge(text: "Happening now", isLive: true)
                            Text(current.title).font(OrbitType.caption).lineLimit(2)
                        } else if let next = agenda.next(at: now) {
                            Badge(text: "Next " + Agenda.countdown(to: next.start, from: now), isLive: false)
                            Text(next.title).font(OrbitType.caption).lineLimit(2)
                        } else {
                            Text("Nothing else today").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                        }
                    }
                    .frame(width: 118, alignment: .leading)
                    Rectangle().fill(OrbitGlass.hairline).frame(width: 0.5)
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            if !agenda.allDay.isEmpty {
                                Text("ALL DAY").font(OrbitType.eyebrow).tracking(0.7).foregroundStyle(Theme.tertiary)
                                ForEach(agenda.allDay) { event in
                                    HStack(spacing: 7) {
                                        Capsule().fill(event.color?.color ?? Theme.accent).frame(width: 3, height: 14)
                                        Text(event.title).lineLimit(1)
                                        Spacer(minLength: 4)
                                        Text(event.calendarTitle).font(OrbitType.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                                    }
                                }
                            }
                            if agenda.timed.isEmpty {
                                Text("No timed events today.").foregroundStyle(Theme.tertiary)
                            }
                            ForEach(agenda.timed) { event in
                                AgendaRow(event: event, day: agenda.day, calendar: widget.calendar, now: now,
                                          isNext: event.id == agenda.next(at: now)?.id)
                            }
                        }
                    }
                    .scrollIndicators(.never)
                }
            }
        }
    }
}

private struct AgendaRow: View {
    let event: AgendaEvent
    let day: Date
    let calendar: Calendar
    let now: Date
    let isNext: Bool

    var body: some View {
        let ended = event.end <= now
        let live = event.isHappening(at: now)
        HStack(spacing: 8) {
            Capsule()
                .fill(ended ? Theme.selectedFill : event.color?.color ?? Theme.accent)
                .frame(width: 3, height: 26)
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title).font(OrbitType.body).foregroundStyle(ended ? Theme.tertiary : .white).lineLimit(1)
                Text(Agenda.timeRange(event, day: day, calendar: calendar))
                    .font(OrbitType.caption.monospacedDigit())
                    .foregroundStyle(ended ? Theme.tertiary : Theme.secondary)
            }
            Spacer(minLength: 4)
            if live { Badge(text: "Now", isLive: true) } else if isNext { Badge(text: "Next", isLive: false) }
        }
    }
}

/// The highlighted event in the compact view.
private struct EventLine: View {
    let event: AgendaEvent
    let agenda: Agenda
    let calendar: Calendar
    let badge: String
    let isLive: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Capsule().fill(event.color?.color ?? Theme.accent).frame(width: 3, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(event.title).font(OrbitType.title).lineLimit(1)
                Text(Agenda.timeRange(event, day: agenda.day, calendar: calendar))
                    .font(OrbitType.caption.monospacedDigit())
                    .foregroundStyle(Theme.secondary)
                Badge(text: badge, isLive: isLive)
            }
        }
    }
}

/// "in 25 min" / "Happening now": digits roll once a minute unless motion is reduced.
private struct Badge: View {
    let text: String
    let isLive: Bool
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        Text(text)
            .font(OrbitType.caption.monospacedDigit())
            .foregroundStyle(isLive ? OrbitGlass.goal : Theme.accent)
            .contentTransition(reduceMotion ? .identity : .numericText())
            .animation(OrbitMotion.animation(.orbitSpring, reduced: reduceMotion), value: text)
            .lineLimit(1)
    }
}
