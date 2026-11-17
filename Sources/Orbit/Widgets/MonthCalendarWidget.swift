import SwiftUI

// Month (Milestone 20): an interactive month grid, like Sapphire's calendar
// grid. The grid itself needs nothing; event dots and the chosen day's events
// come from the Calendar widget's store and calendars, only when Orbit is
// already connected to Calendar (it never asks here). Events live in memory
// while the widget is on screen.

enum MonthGrid {
    /// The first moment of the month containing `date`.
    static func monthStart(_ date: Date, calendar: Calendar) -> Date {
        calendar.dateInterval(of: .month, for: date)?.start ?? calendar.startOfDay(for: date)
    }

    /// Six full weeks (42 days) covering the month, starting on the calendar's first weekday.
    static func days(containing date: Date, calendar: Calendar) -> [Date] {
        let first = monthStart(date, calendar: calendar)
        let weekday = calendar.component(.weekday, from: first)
        let lead = (weekday - calendar.firstWeekday + 7) % 7
        guard let start = calendar.date(byAdding: .day, value: -lead, to: first) else { return [] }
        return (0..<42).compactMap { calendar.date(byAdding: .day, value: $0, to: start) }
    }

    /// Weekday initials in the calendar's order (S M T W T F S, or M T W … for Monday-first).
    static func weekdaySymbols(_ calendar: Calendar) -> [String] {
        let symbols = calendar.veryShortStandaloneWeekdaySymbols
        return (0..<7).map { symbols[(calendar.firstWeekday - 1 + $0) % 7] }
    }

    /// Every day an event touches (a multi-day event marks each day; one ending at midnight doesn't mark the next).
    static func busyDays(_ events: [AgendaEvent], calendar: Calendar) -> Set<Date> {
        var days = Set<Date>()
        for event in events {
            var day = calendar.startOfDay(for: event.start)
            let last = event.end > event.start ? event.end.addingTimeInterval(-1) : event.start
            var count = 0
            while day <= last, count < 400 {  // a runaway multi-year event can't stall the grid
                days.insert(day)
                count += 1
                guard let next = calendar.date(byAdding: .day, value: 1, to: day) else { break }
                day = next
            }
        }
        return days
    }

    /// Events touching `day`, all-day first, then by start.
    static func events(_ events: [AgendaEvent], on day: Date, calendar: Calendar) -> [AgendaEvent] {
        let start = calendar.startOfDay(for: day)
        guard let end = calendar.date(byAdding: .day, value: 1, to: start) else { return [] }
        return events.filter { $0.start < end && ($0.end > start || ($0.end == $0.start && $0.start >= start)) }
            .sorted { ($0.isAllDay ? 0 : 1, $0.start) < ($1.isAllDay ? 0 : 1, $1.start) }
    }
}

@MainActor @Observable
final class MonthCalendarWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "month", title: "Month", description: "A month at a glance; pick a day to see its events",
        symbol: "calendar.badge.clock", category: .productivity, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded, isEnabledByDefault: false)
    let events: EventsWidget
    private(set) var month: Date
    private(set) var selected: Date
    private(set) var monthEvents: [AgendaEvent] = []
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var isShown = false

    init(events: EventsWidget, clock: @escaping () -> Date = { .now }) {
        self.events = events
        self.clock = clock
        let calendar = events.calendar
        month = MonthGrid.monthStart(clock(), calendar: calendar)
        selected = calendar.startOfDay(for: clock())
    }

    var state: WidgetState { .ready }
    var calendar: Calendar { events.calendar }
    var days: [Date] { MonthGrid.days(containing: month, calendar: calendar) }
    var busy: Set<Date> { MonthGrid.busyDays(monthEvents, calendar: calendar) }
    var selectedEvents: [AgendaEvent] { MonthGrid.events(monthEvents, on: selected, calendar: calendar) }
    var today: Date { calendar.startOfDay(for: clock()) }

    func start() {
        isShown = true
        events.refreshAccess()
        reload()
    }

    func stop() {
        isShown = false
        generation += 1
        monthEvents = []
    }

    /// Back or forward by months; the selection moves to that month's first day (or today in this month).
    func move(by months: Int) {
        guard let next = calendar.date(byAdding: .month, value: months, to: month) else { return }
        month = MonthGrid.monthStart(next, calendar: calendar)
        selected = calendar.isDate(today, equalTo: month, toGranularity: .month) ? today : month
        reload()
    }

    func goToToday() {
        month = MonthGrid.monthStart(clock(), calendar: calendar)
        selected = today
        reload()
    }

    func select(_ day: Date) {
        selected = calendar.startOfDay(for: day)
        if !calendar.isDate(selected, equalTo: month, toGranularity: .month) {
            month = MonthGrid.monthStart(selected, calendar: calendar)
            reload()
        }
    }

    /// Reads the grid's six weeks from the Calendar widget's calendars, off the main thread.
    func reload() {
        generation += 1
        guard isShown, events.isConnected, let first = days.first, let last = days.last,
              let end = calendar.date(byAdding: .day, value: 1, to: last) else {
            monthEvents = []
            return
        }
        let registered = generation
        let store = events.store
        let ids = events.selectedCalendarIDs
        Task {
            let found = await Task.detached(priority: .userInitiated) { store.events(from: first, to: end, calendarIDs: ids) }.value
            guard registered == generation else { return }
            monthEvents = found
        }
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(MonthView(widget: self, isExpanded: presentation == .expanded))
    }
}

private struct MonthView: View {
    let widget: MonthCalendarWidget
    let isExpanded: Bool

    var body: some View {
        let calendar = widget.calendar
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 4) {
                header
                grid(calendar)
            }
            .frame(maxWidth: isExpanded ? 230 : .infinity)
            if isExpanded { dayList(calendar) }
        }
        // Connected, calendars chosen, or the calendar database changed (the agenda follows it): read again.
        .onChange(of: widget.events.isConnected) { widget.reload() }
        .onChange(of: widget.events.selectedCalendarIDs) { widget.reload() }
        .onChange(of: widget.events.refresher.value) { widget.reload() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            Text(widget.month.formatted(.dateTime.month(.wide).year())).font(OrbitType.body.weight(.semibold)).lineLimit(1)
            Spacer(minLength: 4)
            arrow("chevron.left", help: "Previous month") { widget.move(by: -1) }
            Button("Today", action: widget.goToToday).buttonStyle(.plain).font(OrbitType.caption).foregroundStyle(Theme.accent)
            arrow("chevron.right", help: "Next month") { widget.move(by: 1) }
        }
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol).font(.system(size: 10, weight: .semibold)).frame(width: 18, height: 18) }
            .buttonStyle(.plain).foregroundStyle(Theme.secondary).help(help).accessibilityLabel(help)
    }

    private func grid(_ calendar: Calendar) -> some View {
        let columns = Array(repeating: GridItem(.flexible(), spacing: 2), count: 7)
        let busy = widget.busy
        return LazyVGrid(columns: columns, spacing: 2) {
            ForEach(Array(MonthGrid.weekdaySymbols(calendar).enumerated()), id: \.offset) { _, symbol in
                Text(symbol).font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Theme.tertiary)
            }
            ForEach(widget.days, id: \.self) { day in
                cell(day, calendar: calendar, hasEvents: busy.contains(day))
            }
        }
    }

    private func cell(_ day: Date, calendar: Calendar, hasEvents: Bool) -> some View {
        let inMonth = calendar.isDate(day, equalTo: widget.month, toGranularity: .month)
        let isToday = day == widget.today
        let isSelected = day == widget.selected
        return Button { widget.select(day) } label: {
            VStack(spacing: 1) {
                Text("\(calendar.component(.day, from: day))")
                    .font(.system(size: 10, weight: isToday ? .bold : .medium).monospacedDigit())
                    .foregroundStyle(isToday ? Color.black : inMonth ? Color.white : Theme.tertiary)
                    .frame(width: 18, height: 18)
                    .background(isToday ? Theme.accent : .clear, in: .circle)
                Circle().fill(hasEvents ? Theme.accent : .clear).frame(width: 3, height: 3)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 1)
            .background(isSelected && !isToday ? Theme.selectedFill : .clear, in: .rect(cornerRadius: 6))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(day.formatted(date: .complete, time: .omitted) + (hasEvents ? ", has events" : ""))
    }

    private func dayList(_ calendar: Calendar) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(widget.selected.formatted(.dateTime.weekday(.wide).day().month()))
                .font(OrbitType.caption.weight(.semibold)).foregroundStyle(Theme.secondary)
            if !widget.events.isConnected {
                Text("Connect Calendar in the Calendar widget or Settings › Calendar to see events here.")
                    .font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            } else if widget.selectedEvents.isEmpty {
                Text("Nothing on this day.").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            } else {
                HubScroll(axes: .vertical, indicators: .never) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(widget.selectedEvents) { event in
                            HStack(spacing: 8) {
                                Capsule().fill(event.color?.color ?? Theme.accent).frame(width: 3, height: 24)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(event.title).font(OrbitType.body).lineLimit(1)
                                    Text(Agenda.timeRange(event, day: widget.selected, calendar: calendar))
                                        .font(OrbitType.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                                }
                                Spacer(minLength: 4)
                                if let url = event.meetingURL, event.end > .now { JoinButton(url: url) }
                            }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
