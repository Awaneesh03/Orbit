import Foundation
import Testing
@testable import Orbit

// MARK: Checklist

@Test func checklistAddsTrimmedTitlesAndRejectsEmptyOnes() {
    var list = Checklist()
    // #expect can't call mutating methods, so results are captured first.
    let added = list.add("  Buy milk \n")
    let blank = list.add("   ")
    #expect(added && !blank)
    #expect(list.items.map(\.title) == ["Buy milk"])
    let long = list.add(String(repeating: "x", count: 500))
    #expect(long)
    #expect(list.items[1].title.count == Checklist.maxTitleLength)
}

@Test func checklistRespectsLimitTogglesAndDeletes() {
    var list = Checklist()
    let results = [list.add("one", limit: 2), list.add("two", limit: 2), list.add("three", limit: 2)]
    #expect(results == [true, true, false])
    let first = list.items[0].id
    list.toggle(first)
    #expect(list.doneCount == 1)
    list.toggle(UUID())  // unknown id ignored
    list.delete(first)
    #expect(list.items.map(\.title) == ["two"])
    #expect(list.doneCount == 0)
}

// MARK: Tasks

@MainActor @Test func tasksAddCompleteDeleteAndPersist() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = TasksWidget(file: temp.file("tasks.json"))
    #expect(widget.items.isEmpty)
    widget.draft = "Write tests"
    widget.add()
    #expect(widget.draft.isEmpty)
    widget.draft = "   "
    widget.add()
    #expect(widget.draft == "   ")  // rejected input stays for editing
    widget.draft = "Ship it"
    widget.add()
    widget.toggle(widget.items[0].id)
    widget.delete(widget.items[1].id)

    let relaunched = TasksWidget(file: temp.file("tasks.json"))
    #expect(relaunched.items.map(\.title) == ["Write tests"])
    #expect(relaunched.items.map(\.isDone) == [true])
}

@MainActor @Test func tasksWithUnreadableFileFailWithoutOverwriting() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    try Data("garbage".utf8).write(to: file.url)
    let widget = TasksWidget(file: file)
    guard case .failed = widget.state else {
        Issue.record("expected a failed state, got \(widget.state)")
        return
    }
    widget.draft = "new"
    widget.add()
    #expect(try Data(contentsOf: file.url) == Data("garbage".utf8))
}

// MARK: Daily goals

@MainActor @Test func goalsAreLimitedToThree() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let widget = GoalsWidget(file: temp.file("goals.json"))
    for title in ["a", "b", "c", "d"] {
        widget.draft = title
        widget.add()
    }
    #expect(widget.goals.map(\.title) == ["a", "b", "c"])
    #expect(widget.draft == "d")
}

@MainActor @Test func goalsStartFreshOnANewDayAndPersistWithinTheDay() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var day = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let widget = GoalsWidget(file: temp.file("goals.json"), today: { day })
    widget.draft = "Exercise"
    widget.add()

    let sameDay = GoalsWidget(file: temp.file("goals.json"), today: { day })
    #expect(sameDay.goals.map(\.title) == ["Exercise"])

    day = day.addingTimeInterval(24 * 3600)
    widget.start()  // appearing on a new day rolls over
    #expect(widget.goals.isEmpty)
    #expect(GoalsWidget(file: temp.file("goals.json"), today: { day }).goals.isEmpty)
}

@Test func dayKeyIsTheLocalCalendarDay() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "Asia/Kolkata")!
    // 2026-10-30 20:00 UTC is already 31 October in India.
    let date = Date(timeIntervalSince1970: 1_793_390_400)
    #expect(GoalsWidget.dayKey(date, calendar: calendar) == "2026-10-31")
}

// MARK: Pomodoro

@Test func pomodoroStartsPausesResumesAndResets() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    var timer = PomodoroTimer()
    #expect(timer.remaining(at: t0) == 25 * 60)
    timer.start(at: t0)
    #expect(timer.remaining(at: t0.addingTimeInterval(60)) == 24 * 60)
    timer.pause(at: t0.addingTimeInterval(60))
    #expect(timer.status == .paused(remaining: 24 * 60))
    #expect(timer.remaining(at: t0.addingTimeInterval(600)) == 24 * 60)  // frozen while paused
    timer.resume(at: t0.addingTimeInterval(600))
    #expect(timer.remaining(at: t0.addingTimeInterval(660)) == 23 * 60)
    timer.start(at: t0)  // already running: ignored
    #expect(timer.remaining(at: t0.addingTimeInterval(660)) == 23 * 60)
    timer.reset()
    #expect(timer.status == .idle)
    #expect(timer.remaining(at: t0) == 25 * 60)
}

@Test func pomodoroFinishesIntoBreakAndBackToFocus() {
    let t0 = Date(timeIntervalSinceReferenceDate: 0)
    var timer = PomodoroTimer()
    timer.start(at: t0)
    let early = timer.settle(at: t0.addingTimeInterval(60))
    #expect(!early)  // not finished yet
    let end = t0.addingTimeInterval(25 * 60)
    #expect(timer.isFinished(at: end))
    timer.pause(at: end)  // can't pause a finished run
    #expect(timer.isFinished(at: end))
    let settled = timer.settle(at: end)
    #expect(settled)
    #expect(timer.phase == .rest)
    #expect(timer.completedSessions == 1)
    #expect(timer.remaining(at: end) == 5 * 60)
    timer.start(at: end)
    let breakSettled = timer.settle(at: end.addingTimeInterval(5 * 60))
    #expect(breakSettled)
    #expect(timer.phase == .focus)
    #expect(timer.completedSessions == 1)
}

@Test func pomodoroFormatsMinutesAndSeconds() {
    #expect(PomodoroTimer.format(25 * 60) == "25:00")
    #expect(PomodoroTimer.format(61.2) == "01:02")
    #expect(PomodoroTimer.format(0) == "00:00")
}

@MainActor @Test func pomodoroWidgetPersistsAndSettlesWhenShownAgain() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var now = Date(timeIntervalSinceReferenceDate: 0)
    let widget = PomodoroWidget(file: temp.file("pomodoro.json"), now: { now })
    widget.startTimer()

    // Dashboard closed and Orbit relaunched; the run ends meanwhile.
    now = now.addingTimeInterval(30 * 60)
    let relaunched = PomodoroWidget(file: temp.file("pomodoro.json"), now: { now })
    #expect(relaunched.timer.isFinished(at: now))
    relaunched.start()  // appearing catches up
    #expect(relaunched.timer.phase == .rest)
    #expect(relaunched.timer.status == .idle)
    #expect(relaunched.timer.completedSessions == 1)
    relaunched.startNext()
    #expect(relaunched.timer.remaining(at: now) == 5 * 60)
}
