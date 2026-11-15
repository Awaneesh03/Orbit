import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 14: This Week. Only recorded data; estimates say "about"; short history says so.
// ORBIT_RENDER=1 writes docs/screenshots/m14-weekly/*.png.

private let calendar: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    return calendar
}()
/// Saturday 2026-11-14, 18:00 IST.
private let now = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 18))!
private func daysAgo(_ days: Int, hour: Int = 11) -> Date {
    calendar.date(byAdding: .day, value: -days, to: calendar.startOfDay(for: now))!.addingTimeInterval(TimeInterval(hour * 3600))
}
private func task(done: Date?) -> ChecklistItem {
    var item = ChecklistItem(title: "t")
    item.isDone = done != nil
    item.completedAt = done
    return item
}
private func goals(_ day: Date, done: Int, of total: Int) -> GoalDay {
    GoalDay(day: GoalsWidget.dayKey(day, calendar: calendar),
            items: (0 ..< total).map { index in var item = ChecklistItem(title: "g\(index)"); item.isDone = index < done; return item })
}

@Test func theWeekCountsOnlyWhatWasRecorded() {
    var inputs = WeeklyReport.Inputs()
    inputs.tasks = [task(done: daysAgo(0)), task(done: daysAgo(2)), task(done: daysAgo(6, hour: 0)), task(done: daysAgo(9)), task(done: nil),
                    task(done: daysAgo(30))]
    inputs.goalsToday = goals(daysAgo(0), done: 1, of: 3)
    inputs.goalHistory = [goals(daysAgo(1), done: 3, of: 3), goals(daysAgo(10), done: 2, of: 2)]
    inputs.focusLog = [daysAgo(0), daysAgo(0, hour: 15), daysAgo(3), daysAgo(8)]
    let report = WeeklyReport.make(inputs, now: now, calendar: calendar)

    #expect(report.days.count == 7 && calendar.isDate(report.days.last!.date, inSameDayAs: now))
    #expect(report.tasksDone == 3 && report.previousTasksDone == 1)  // 9 days ago is last week; 30 days ago neither
    #expect(report.goalsSet == 6 && report.goalsDone == 4)  // 10 days ago is outside
    #expect(report.focusSessions == 3 && report.previousFocusSessions == 1 && report.focusMinutes == 75)
    #expect(report.focusSince == daysAgo(8))
    #expect(report.days[6].tasks == 1 && report.days[6].focus == 2 && report.days[6].goalsDone == 1)
    #expect(report.coding == nil)  // the AI Hub is off: no coding numbers are made up
    let lines = report.highlights
    #expect(lines.contains("3 tasks done (+2 vs last week)"))
    #expect(lines.contains("4 of 6 daily goals met"))
    #expect(lines.contains("3 focus sessions, about 75 min planned (+2 vs last week)"))
    #expect(lines.contains("Busiest day: Saturday"))
}

@Test func anEmptyWeekSaysSoWithoutInventingTrends() {
    let report = WeeklyReport.make(.init(), now: now, calendar: calendar)
    #expect(report.highlights == ["0 tasks done"])  // no goals, no focus history, no coding: nothing claimed
    #expect(WeeklyReport.trend(3, 0) == "" && WeeklyReport.trend(2, 2) == " (same as last week)")
}

@Test func codingComesFromTheAIHubAndIsMarkedAsAnEstimate() {
    var insights = AIHubService.Insights()
    insights.agents = [HubStore.AgentTotals(agent: "claude-code", sessions: 4, events: 120, activeSeconds: 9000)]
    insights.days = [(GoalsWidget.dayKey(daysAgo(1), calendar: calendar), 70), (GoalsWidget.dayKey(daysAgo(0), calendar: calendar), 50)]
    insights.filesChanged = 12
    insights.projects = [("/Users/me/Developer/Orbit", 3)]
    insights.since = daysAgo(6)
    insights.historyStart = daysAgo(2)
    var inputs = WeeklyReport.Inputs()
    inputs.insights = insights
    let report = WeeklyReport.make(inputs, now: now, calendar: calendar)
    #expect(report.coding == .init(sessions: 4, activeHours: 2.5, filesChanged: 12, topProject: "Orbit", isPartial: true))
    #expect(report.days[5].agentEvents == 70 && report.days[6].agentEvents == 50)
    #expect(report.highlights.contains("4 agent sessions, about 2.5 h active"))
    #expect(report.highlights.contains("Most agent work: Orbit"))
}

@Test func focusSessionsAreDatedWhenTheyEnd() {
    var timer = PomodoroTimer()
    let start = Date(timeIntervalSinceReferenceDate: 1000)
    timer.start(at: start)
    let settled = timer.settle(at: start + 3600)  // settled long after it ended
    #expect(settled)
    #expect(timer.focusLog == [start + timer.focusLength] && timer.completedSessions == 1)
    timer.start(at: start + 4000)
    timer.settle(at: start + 4000 + timer.breakLength)  // a break isn't logged
    #expect(timer.focusLog?.count == 1)
    let old = try? JSONDecoder().decode(PomodoroTimer.self, from: Data(#"{"phase":"focus","status":{"idle":{}},"focusLength":1500,"breakLength":300,"completedSessions":9}"#.utf8))
    #expect(old?.completedSessions == 9 && old?.focusLog == nil)  // older files load unchanged
}

@MainActor @Test func thisWeekRenders() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let goalsWidget = GoalsWidget(file: temp.file("goals.json"))
    let tasks = TasksWidget(file: temp.file("tasks.json"), goals: goalsWidget)
    let pomodoro = PomodoroWidget(file: temp.file("pomodoro.json"))
    let widget = WeeklyInsightsWidget(tasks: tasks, goals: goalsWidget, pomodoro: pomodoro)
    var insights = AIHubService.Insights()
    insights.agents = [HubStore.AgentTotals(agent: "claude-code", sessions: 6, events: 300, activeSeconds: 5 * 3600)]
    insights.filesChanged = 41
    insights.projects = [("/Users/me/Developer/Orbit", 5)]
    widget.codingInsights = { insights }
    for (presentation, name) in [(WidgetPresentation.compact, "compact"), (.expanded, "expanded")] {
        let view = widget.content(presentation).padding(14).frame(width: presentation == .compact ? 300 : 420)
            .background(Color(red: 0.11, green: 0.12, blue: 0.16)).environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m14-weekly").standardized
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
    }
}
