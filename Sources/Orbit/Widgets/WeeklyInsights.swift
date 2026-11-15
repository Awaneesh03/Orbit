import SwiftUI

// This Week (Milestone 14): productivity and coding, from what Orbit already
// recorded on this Mac. Nothing is guessed: a number Orbit can't know is left
// out, a derived one says "about", and a source with short history says since
// when. Local only; nothing is sent anywhere.

struct WeeklyReport: Equatable {
    struct Day: Equatable {
        let date: Date
        var tasks = 0
        var goalsDone = 0
        var focus = 0
        var agentEvents = 0
        var total: Int { tasks + goalsDone + focus }
    }

    /// The last seven days, oldest first (today last).
    var days: [Day] = []
    var tasksDone = 0
    var previousTasksDone = 0
    var goalsSet = 0
    var goalsDone = 0
    var focusSessions = 0
    var previousFocusSessions = 0
    /// Planned focus minutes: sessions × the timer's focus length (an estimate: a session may have been cut short).
    var focusMinutes = 0.0
    /// The first dated focus session: before it, sessions weren't dated (nil: none yet).
    var focusSince: Date?
    // Coding, from the AI Hub's history (nil: the AI Hub is off or has nothing).
    var coding: Coding?

    struct Coding: Equatable {
        var sessions: Int
        /// First-to-last event span per session (an estimate of active time).
        var activeHours: Double
        var filesChanged: Int
        var topProject: String?
        var isPartial: Bool
    }

    struct Inputs {
        var tasks: [ChecklistItem] = []
        var goalsToday: GoalDay?
        var goalHistory: [GoalDay] = []
        var focusLog: [Date] = []
        var focusLength: TimeInterval = 25 * 60
        var insights: AIHubService.Insights?
    }

    static func make(_ inputs: Inputs, now: Date, calendar: Calendar = .current) -> WeeklyReport {
        let today = calendar.startOfDay(for: now)
        guard let start = calendar.date(byAdding: .day, value: -6, to: today),
              let previousStart = calendar.date(byAdding: .day, value: -7, to: start) else { return WeeklyReport() }
        var report = WeeklyReport()
        report.days = (0 ..< 7).compactMap { calendar.date(byAdding: .day, value: $0, to: start).map { Day(date: $0) } }
        func index(_ date: Date) -> Int? {
            guard date >= start, date <= now else { return nil }
            return calendar.dateComponents([.day], from: start, to: calendar.startOfDay(for: date)).day.flatMap { (0 ..< 7).contains($0) ? $0 : nil }
        }

        for completed in inputs.tasks.compactMap(\.completedAt) {
            if let day = index(completed) { report.days[day].tasks += 1; report.tasksDone += 1 }
            else if completed >= previousStart, completed < start { report.previousTasksDone += 1 }
        }
        for goalDay in [inputs.goalsToday].compactMap({ $0 }) + inputs.goalHistory {
            guard let date = Self.date(fromKey: goalDay.day, calendar: calendar), let day = index(date) else { continue }
            report.goalsSet += goalDay.items.count
            let done = goalDay.items.filter(\.isDone).count
            report.goalsDone += done
            report.days[day].goalsDone += done
        }
        for ended in inputs.focusLog {
            if let day = index(ended) { report.days[day].focus += 1; report.focusSessions += 1 }
            else if ended >= previousStart, ended < start { report.previousFocusSessions += 1 }
        }
        report.focusSince = inputs.focusLog.min()
        report.focusMinutes = Double(report.focusSessions) * inputs.focusLength / 60

        if let insights = inputs.insights, insights.sessions > 0 || insights.events > 0 {
            report.coding = Coding(sessions: insights.sessions,
                                   activeHours: insights.agents.map(\.activeSeconds).reduce(0, +) / 3600,
                                   filesChanged: insights.filesChanged,
                                   topProject: insights.projects.first.map { ($0.project as NSString).lastPathComponent },
                                   isPartial: insights.isPartial)
            let byKey = Dictionary(insights.days.map { ($0.day, $0.count) }, uniquingKeysWith: +)
            for index in report.days.indices {
                report.days[index].agentEvents = byKey[GoalsWidget.dayKey(report.days[index].date, calendar: calendar)] ?? 0
            }
        }
        return report
    }

    static func date(fromKey key: String, calendar: Calendar) -> Date? {
        let parts = key.split(separator: "-").compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        return calendar.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2]))
    }

    /// One line per fact, measured first; estimates say "about".
    var highlights: [String] {
        var lines: [String] = []
        lines.append("\(tasksDone) task\(tasksDone == 1 ? "" : "s") done" + Self.trend(tasksDone, previousTasksDone))
        if goalsSet > 0 { lines.append("\(goalsDone) of \(goalsSet) daily goals met") }
        if focusSessions > 0 || focusSince != nil {
            lines.append("\(focusSessions) focus session\(focusSessions == 1 ? "" : "s")"
                         + (focusSessions > 0 ? ", about \(Self.minutes(focusMinutes)) planned" : "")
                         + Self.trend(focusSessions, previousFocusSessions))
        }
        if let coding {
            lines.append("\(coding.sessions) agent session\(coding.sessions == 1 ? "" : "s"), about \(String(format: "%.1f", coding.activeHours)) h active")
            if coding.filesChanged > 0 { lines.append("\(coding.filesChanged) file\(coding.filesChanged == 1 ? "" : "s") changed by agents") }
            if let top = coding.topProject { lines.append("Most agent work: \(top)") }
        }
        if let best = days.max(by: { $0.total < $1.total }), best.total > 0 {
            lines.append("Busiest day: \(best.date.formatted(.dateTime.weekday(.wide)))")
        }
        return lines
    }

    static func trend(_ now: Int, _ before: Int) -> String {
        guard before > 0 else { return "" }
        let change = now - before
        return change == 0 ? " (same as last week)" : " (\(change > 0 ? "+" : "")\(change) vs last week)"
    }

    static func minutes(_ value: Double) -> String {
        value >= 90 ? String(format: "%.1f h", value / 60) : "\(Int(value.rounded())) min"
    }
}

@MainActor @Observable
final class WeeklyInsightsWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "weekly", title: "This Week", description: "Tasks, goals, focus and coding over the last 7 days",
        symbol: "chart.bar.xaxis", category: .productivity, availability: .live, isEnabledByDefault: false)
    var state: WidgetState { .ready }
    private let tasks: TasksWidget
    private let goals: GoalsWidget
    private let pomodoro: PomodoroWidget
    /// The AI Hub's recap, when it's on (set by the app); refreshed when shown.
    @ObservationIgnored var codingInsights: @MainActor () -> AIHubService.Insights? = { nil }
    @ObservationIgnored var refreshCoding: @MainActor () async -> Void = {}
    private(set) var refreshed = 0
    @ObservationIgnored private let now: () -> Date

    init(tasks: TasksWidget, goals: GoalsWidget, pomodoro: PomodoroWidget, now: @escaping () -> Date = { .now }) {
        self.tasks = tasks
        self.goals = goals
        self.pomodoro = pomodoro
        self.now = now
    }

    func start() {
        Task { [weak self] in
            await self?.refreshCoding()
            self?.refreshed += 1
        }
    }

    var report: WeeklyReport {
        _ = refreshed
        let today = GoalDay(day: GoalsWidget.dayKey(now()), items: goals.goals)
        return WeeklyReport.make(.init(tasks: tasks.items, goalsToday: today, goalHistory: goals.history,
                                       focusLog: pomodoro.timer.focusLog ?? [], focusLength: pomodoro.timer.focusLength,
                                       insights: codingInsights()), now: now())
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(WeeklyInsightsView(report: report, compact: presentation == .compact))
    }
}

private struct WeeklyInsightsView: View {
    let report: WeeklyReport
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            bars
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(report.highlights.prefix(compact ? 3 : 8).enumerated()), id: \.offset) { _, line in
                    Text(line).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            if !compact {
                Text(footnote).font(.system(size: 9)).foregroundStyle(Theme.tertiary).lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bars: some View {
        let peak = max(1, report.days.map(\.total).max() ?? 1)
        return HStack(alignment: .bottom, spacing: 5) {
            ForEach(report.days, id: \.date) { day in
                VStack(spacing: 3) {
                    Capsule().fill(day.total > 0 ? Theme.accent : Theme.tertiary.opacity(0.4))
                        .frame(height: max(3, 34 * CGFloat(day.total) / CGFloat(peak)))
                    Text(day.date.formatted(.dateTime.weekday(.narrow))).font(.system(size: 8.5)).foregroundStyle(Theme.tertiary)
                }
                .frame(maxWidth: .infinity)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("\(day.date.formatted(.dateTime.weekday(.wide))): \(day.tasks) tasks, \(day.goalsDone) goals, \(day.focus) focus sessions")
            }
        }
        .frame(height: 48)
    }

    private var footnote: String {
        var parts = ["Bars: tasks done, goals met and focus sessions each day. Counts only what Orbit recorded on this Mac."]
        if let since = report.focusSince { parts.append("Focus sessions dated since \(since.formatted(date: .abbreviated, time: .omitted)).") }
        if report.coding?.isPartial == true { parts.append("Agent history covers part of the week.") }
        if report.coding == nil { parts.append("Coding: turn on the AI Hub.") }
        return parts.joined(separator: " ")
    }
}
