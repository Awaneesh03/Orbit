import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.4: task fields, today's ordering and progress, editing, goals
// history, backups and migration of existing files.

private let calendar = Calendar.current
private let noon = calendar.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 12))!
private func day(_ offset: Int) -> Date { calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: noon))! }

private func task(_ title: String, _ priority: TaskPriority? = nil, due: Int? = nil, done: Bool = false,
                  completed: Date? = nil) -> ChecklistItem {
    ChecklistItem(title: title, isDone: done, priority: priority, dueDate: due.map(day), completedAt: completed)
}

private func listing(_ directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path(percentEncoded: false))) ?? []).sorted()
}

/// The shape of a real Stage 1 tasks.json.
private let legacyTasks = #"{"items":[{"id":"8E8A2B1C-2E2D-4E8A-9C3B-1F5B7D9A0C11","title":"okay so i have to check how orbit is working","isDone":false},{"id":"0F0E7C2A-3B4D-4C5E-8F6A-7B8C9D0E1F22","title":"old done task","isDone":true}]}"#

// MARK: Model

@Test func legacyTasksDecodeAndKeepTheirShape() throws {
    let list = try JSONDecoder().decode(Checklist.self, from: Data(legacyTasks.utf8))
    #expect(list.items.map(\.title) == ["okay so i have to check how orbit is working", "old done task"])
    #expect(list.items.map(\.isDone) == [false, true])
    #expect(list.items.allSatisfy { $0.priority == nil && $0.dueDate == nil && $0.completedAt == nil })
    #expect(list.items[0].effectivePriority == .normal)
    let encoded = String(decoding: try JSONEncoder().encode(list), as: UTF8.self)
    for key in ["priority", "dueDate", "completedAt"] { #expect(!encoded.contains(key)) }  // unchanged items stay legacy-shaped
    #expect(try JSONDecoder().decode(Checklist.self, from: Data(encoded.utf8)) == list)
}

@Test func newFieldsRoundTripAndUnknownValuesAreTolerated() throws {
    var list = Checklist(items: [task("a", .high, due: 0, done: true, completed: noon)])
    list.items.append(task("b", .low))
    #expect(try JSONDecoder().decode(Checklist.self, from: JSONEncoder().encode(list)) == list)
    let future = #"{"items":[{"id":"8E8A2B1C-2E2D-4E8A-9C3B-1F5B7D9A0C11","title":"x","isDone":false,"priority":"urgent","tags":["new"]}]}"#
    let decoded = try JSONDecoder().decode(Checklist.self, from: Data(future.utf8))
    #expect(decoded.items[0].priority == nil && decoded.items[0].effectivePriority == .normal)  // a newer value doesn't break the file
}

@Test func completingRecordsTheTimeAndReopeningClearsIt() {
    var list = Checklist()
    list.add("Ship")
    let id = list.items[0].id
    list.toggle(id, now: noon)
    #expect(list.items[0].isDone && list.items[0].completedAt == noon)
    list.toggle(id, now: noon.addingTimeInterval(60))
    #expect(!list.items[0].isDone && list.items[0].completedAt == nil)
}

@Test func editingKeepsIdentityAndRejectsEmptyTitles() {
    var list = Checklist()
    list.add("Draft")
    let id = list.items[0].id
    let renamed = list.rename(id, to: "  Final  ")
    let blank = list.rename(id, to: "   ")
    #expect(renamed && !blank)
    #expect(list.items[0].id == id && list.items[0].title == "Final")
    list.setPriority(id, .high)
    #expect(list.items[0].priority == .high)
    list.setPriority(id, .normal)
    #expect(list.items[0].priority == nil)  // normal is the default, stored as absent
    list.setDueDate(id, noon)
    #expect(list.items[0].dueDate == calendar.startOfDay(for: noon))
    list.setDueDate(id, nil)
    #expect(list.items[0].dueDate == nil && list.items[0].id == id)
}

// MARK: Ordering and progress

@Test func activeTasksAreOrderedOverdueTodayUpcomingUndatedThenByPriority() {
    let items = [
        task("undated low", .low), task("undated normal"), task("undated high", .high),
        task("later in week", due: 5), task("tomorrow", .low, due: 1),
        task("today normal", due: 0), task("today high", .high, due: 0),
        task("overdue normal", due: -3), task("overdue high", .high, due: -1),
        task("done", due: -2, done: true, completed: noon),
    ]
    let plan = TodayPlan(items, now: noon)
    #expect(plan.active.map(\.title) == [
        "overdue high", "overdue normal", "today high", "today normal",
        "tomorrow", "later in week", "undated high", "undated normal", "undated low",
    ])
    #expect(plan.completed.map(\.title) == ["done"])
    #expect(plan.overdueCount == 2)
}

@Test func equalTasksKeepTheirListOrder() {
    let items = (1...6).map { task("t\($0)", due: $0.isMultiple(of: 2) ? 0 : nil) }
    #expect(TodayPlan(items, now: noon).active.map(\.title) == ["t2", "t4", "t6", "t1", "t3", "t5"])
}

@Test func progressCountsOnlyTodaysTasks() {
    let items = [
        task("open undated"), task("open today", due: 0), task("open overdue", due: -1),
        task("tomorrow", due: 1),                                        // not today's
        task("done today", done: true, completed: noon),
        task("done yesterday", done: true, completed: day(-1)),          // not today's
        task("done before completion times", done: true),               // unknown: not counted
    ]
    let plan = TodayPlan(items, now: noon)
    #expect(plan.doneToday == 1 && plan.totalToday == 4)
    #expect(plan.completed.first?.title == "done today")  // most recent first; unknown times last
    let empty = TodayPlan([], now: noon)
    #expect(empty.doneToday == 0 && empty.totalToday == 0 && empty.active.isEmpty)
    #expect(OrbitProgressRing.fraction(done: 0, total: 0) == 0)  // nothing to do isn't 100% or NaN
    #expect(OrbitProgressRing.fraction(done: 3, total: 7) == 3.0 / 7.0)
    #expect(OrbitProgressRing.fraction(done: 9, total: 7) == 1)
}

// MARK: Widget, persistence and backups

@MainActor @Test func tasksWidgetCreatesEditsAndDeletesPersistently() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    let widget = TasksWidget(file: file, clock: { noon })
    widget.draft = "Write report"
    widget.add()
    let id = try #require(widget.items.first?.id)

    widget.beginEditing(widget.items[0])
    widget.editDraft = "Write the report"
    widget.commitEdit()
    widget.setPriority(id, .high)
    widget.setDueDate(id, widget.day(0))
    widget.toggle(id)
    var saved = try #require(try file.load())
    #expect(saved.items == [ChecklistItem(id: id, title: "Write the report", isDone: true, priority: .high,
                                          dueDate: day(0), completedAt: noon)])

    let before = try Data(contentsOf: file.url)
    widget.beginEditing(widget.items[0])
    widget.commitEdit()  // unchanged: nothing written
    widget.setPriority(id, .high)  // unchanged: nothing written
    #expect(try Data(contentsOf: file.url) == before)

    widget.delete(id)
    saved = try #require(try file.load())
    #expect(saved.items.isEmpty)
    #expect(listing(temp.url) == ["tasks.json"])  // atomic writes leave no temporary files
}

@MainActor @Test func theFirstWriteBacksUpTheExistingFileExactlyOnce() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    try Data(legacyTasks.utf8).write(to: file.url)
    let backup = temp.url.appending(path: "tasks.v1-backup.json")

    let widget = TasksWidget(file: file, clock: { noon })
    #expect(!FileManager.default.fileExists(atPath: backup.path(percentEncoded: false)))  // loading writes nothing
    widget.toggle(widget.items[0].id)
    #expect(try Data(contentsOf: backup) == Data(legacyTasks.utf8))
    widget.toggle(widget.items[0].id)
    TasksWidget(file: file).toggle(widget.items[1].id)  // a later launch
    #expect(try Data(contentsOf: backup) == Data(legacyTasks.utf8))  // never replaced
}

@MainActor @Test func aFailedBackupMeansNothingIsWritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    try Data(legacyTasks.utf8).write(to: file.url)
    let widget = TasksWidget(file: file, clock: { noon })
    let path = file.url.path(percentEncoded: false)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path)  // can be replaced, not copied
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path) }

    widget.toggle(widget.items[0].id)
    try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path)
    #expect(try Data(contentsOf: file.url) == Data(legacyTasks.utf8))
    guard case .failed = widget.state else {
        Issue.record("a failed backup must be reported")
        return
    }
}

@MainActor @Test func unreadableTaskAndGoalFilesAreNeverOverwritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let garbage = Data("{ not json".utf8)
    let tasksFile: JSONFile<Checklist> = temp.file("tasks.json")
    let goalsFile: JSONFile<DailyGoals> = temp.file("goals.json")
    try garbage.write(to: tasksFile.url)
    try garbage.write(to: goalsFile.url)
    let goals = GoalsWidget(file: goalsFile, today: { noon })
    let tasks = TasksWidget(file: tasksFile, goals: goals, clock: { noon })
    tasks.draft = "x"
    tasks.add()
    goals.draft = "y"
    goals.add()
    #expect(try Data(contentsOf: tasksFile.url) == garbage && (try Data(contentsOf: goalsFile.url)) == garbage)
    #expect(listing(temp.url) == ["goals.json", "tasks.json"])  // no backup of garbage either
    for state in [tasks.state, goals.state] {
        guard case .failed = state else {
            Issue.record("an unreadable file must show as failed")
            continue
        }
    }
}

@MainActor @Test func goalsAreEditableCompletableAndKeptInHistoryAtTheDailyReset() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<DailyGoals> = temp.file("goals.json")
    var now = noon
    let goals = GoalsWidget(file: file, today: { now })
    for title in ["Run", "Read", "Write", "Fourth"] {
        goals.draft = title
        goals.add()
    }
    #expect(goals.goals.map(\.title) == ["Run", "Read", "Write"])  // still three at most
    let id = goals.goals[1].id
    goals.editingID = id
    goals.editDraft = "Read 20 pages"
    goals.rename()
    goals.toggle(id)
    #expect(goals.goals[1].title == "Read 20 pages" && goals.goals[1].id == id && goals.goals[1].completedAt == noon)

    goals.rollOver()  // same day: nothing reset
    #expect(goals.goals.count == 3)
    now = day(1).addingTimeInterval(9 * 3600)
    goals.rollOver()  // a new day starts empty…
    #expect(goals.goals.isEmpty)
    #expect(goals.history.first?.day == "2026-11-02")  // …and yesterday's goals are kept, not deleted
    #expect(goals.history.first?.items.map(\.title) == ["Run", "Read 20 pages", "Write"])
    #expect(try file.load()?.history?.count == 1)
}

@MainActor @Test func goalHistoryIsCappedAndEmptyDaysAreNotRecorded() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var now = noon
    let goals = GoalsWidget(file: temp.file("goals.json"), today: { now })
    for offset in 1...70 {
        goals.draft = "goal \(offset)"
        goals.add()
        now = day(offset)
        goals.rollOver()
        if offset == 70 { now = day(71); goals.rollOver() }  // an empty day adds nothing
    }
    #expect(goals.history.count == GoalsWidget.historyDays)
    #expect(goals.history.first?.items.first?.title == "goal 70")
}

// MARK: Rendering and motion

@MainActor @Test func compactAndExpandedTasksRender() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let goals = GoalsWidget(file: temp.file("goals.json"), today: { noon })
    for title in ["Run", "Read"] { goals.draft = title; goals.add() }
    goals.toggle(goals.goals[0].id)
    let file: JSONFile<Checklist> = temp.file("tasks.json")
    try file.save(Checklist(items: [task("Pay the bill", .high, due: -1), task("Ship Settings", due: 0),
                                    task("Book flights", .low), task("Stand-up notes", done: true, completed: noon)]))
    let widget = TasksWidget(file: file, goals: goals, clock: { noon })
    let empty = TasksWidget(file: temp.file("empty.json"), clock: { noon })

    let compact = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
    let expanded = try #require(render(WidgetHost(widget: widget, presentation: .expanded), size: CGSize(width: 468, height: 160)))
    let nothing = try #require(render(WidgetHost(widget: empty, presentation: .compact), size: CGSize(width: 229, height: 160)))
    #expect(compact.pixels != nothing.pixels)
    #expect(expanded.width == 468 && compact.width == 229)
    // ImageRenderer doesn't draw ScrollView contents or text fields, so the
    // expanded list and editor are checked in the running app; here, the state.
    widget.beginEditing(widget.plan.active[0])
    #expect(widget.editingID == widget.plan.active[0].id && widget.editDraft == "Pay the bill")
    #expect(DueLabel(item: widget.plan.active[0], now: noon, short: true)?.text == "Overdue")
    #expect(DueLabel(item: widget.plan.active[0], now: noon)?.text.hasPrefix("Overdue · ") == true)

    // Visual evidence for review, only when asked for.
    if let folder = ProcessInfo.processInfo.environment["ORBIT_RENDER_DIR"] {
        for (name, presentation, width) in [("tasks-editing", WidgetPresentation.expanded, 468.0)] {
            try save(WidgetHost(widget: widget, presentation: presentation), width: width, to: folder, name: name)
        }
        try save(TaskEditor(widget: widget, item: widget.plan.active[0]).padding(8), width: 300, to: folder, name: "task-editor")
        widget.commitEdit()
        for (name, presentation, width) in [("tasks-compact", WidgetPresentation.compact, 229.0), ("tasks-expanded", .expanded, 468.0)] {
            try save(WidgetHost(widget: widget, presentation: presentation), width: width, to: folder, name: name)
        }
    }
}

@MainActor
private func save<V: View>(_ view: V, width: Double, to folder: String, name: String) throws {
    let renderer = ImageRenderer(content: view.frame(width: width, height: 160).background(Color.black)
        .environment(\.colorScheme, .dark))
    renderer.scale = 2
    if let image = renderer.nsImage, let tiff = image.tiffRepresentation,
       let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
        try png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
    }
}

@MainActor @Test func theRingRendersTheSameFinalStateWithReducedMotion() throws {
    // With Reduce Motion the ring and digits change without animating; the result is identical.
    let size = CGSize(width: 40, height: 40)
    let moving = try #require(render(OrbitProgressRing(done: 3, total: 7), size: size))
    let still = try #require(render(OrbitProgressRing(done: 3, total: 7).environment(\.orbitReduceMotion, true), size: size))
    #expect(moving.pixels == still.pixels)
    #expect(OrbitMotion.animation(.orbitSpring, reduced: true) == nil)
    let zero = try #require(render(OrbitProgressRing(done: 0, total: 0), size: size))
    #expect(zero.pixels != moving.pixels)
}

// MARK: Migration of a copy of real data

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ORBIT_TODAY_COPY"] != nil))
func todayCopyMigration() throws {
    let folder = URL(filePath: ProcessInfo.processInfo.environment["ORBIT_TODAY_COPY"]!, directoryHint: .isDirectory)
    let real = OrbitStorage.directory.standardizedFileURL.path(percentEncoded: false)
    guard !folder.standardizedFileURL.path(percentEncoded: false).hasPrefix(real) else {
        Issue.record("refusing to run inside Orbit's real data folder")
        return
    }
    let tasksFile: JSONFile<Checklist> = JSONFile(url: folder.appending(path: "tasks.json"))
    let goalsFile: JSONFile<DailyGoals> = JSONFile(url: folder.appending(path: "goals.json"))
    let originalTasks = try Data(contentsOf: tasksFile.url)
    let originalGoals = try Data(contentsOf: goalsFile.url)
    let before = try #require(try tasksFile.load())
    let goalsBefore = try #require(try goalsFile.load())

    let goals = GoalsWidget(file: goalsFile)
    let tasks = TasksWidget(file: tasksFile, goals: goals)
    #expect(tasks.items == before.items && tasks.state == .ready)
    #expect(goals.goals == goalsBefore.checklist.items)
    print("MIGRATION before: \(before.items.count) task(s), \(before.doneCount) done; \(goalsBefore.checklist.items.count) goal(s) for \(goalsBefore.day)")

    // A write by this version: backup first, then every record kept.
    let first = try #require(tasks.items.first)
    tasks.toggle(first.id)
    tasks.toggle(first.id)
    let after = try #require(try tasksFile.load())
    #expect(try Data(contentsOf: folder.appending(path: "tasks.v1-backup.json")) == originalTasks)
    #expect(after.items.map(\.id) == before.items.map(\.id))
    #expect(after.items.map(\.title) == before.items.map(\.title))
    #expect(after.items.map(\.isDone) == before.items.map(\.isDone))
    #expect(after.items.allSatisfy { $0.completedAt == nil && $0.priority == nil && $0.dueDate == nil })
    if goalsBefore.day == GoalsWidget.dayKey(.now) {
        #expect(try Data(contentsOf: goalsFile.url) == originalGoals)  // same day: goals untouched, not reset
    }
    print("MIGRATION after: \(after.items.count) task(s), \(after.doneCount) done; \(goals.goals.count) goal(s); backup identical to original")
}

@MainActor @Test func theCompactListScrollsInsideAFixedCard() throws {
    // However many tasks, the card keeps its size and the add field stays put
    // (only the list in between scrolls). ImageRenderer doesn't draw ScrollView
    // contents, so the bottom band (add field) is compared.
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var bands: [[UInt8]] = []
    for count in [1, 5, 10, 20] {
        let file: JSONFile<Checklist> = temp.file("tasks-\(count).json")
        try file.save(Checklist(items: (0..<count).map { task("Task \($0)", $0 % 4 == 0 ? .high : nil, due: $0 % 3 == 0 ? -1 : nil) }))
        let widget = TasksWidget(file: file, clock: { noon })
        #expect(widget.plan.active.count == count)  // every task is in the list, none cut off
        let image = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
        #expect(image.width == 229 && image.height == 160)
        bands.append(Array(image.pixels[(image.width * 120 * 4)...]))
    }
    // Allow antialiasing noise between renders; a moved field differs in thousands of values.
    for band in bands.dropFirst() {
        let differing = zip(bands[0], band).filter { abs(Int($0) - Int($1)) > 24 }.count
        #expect(differing < band.count / 200, "the add field moved (\(differing) values differ)")
    }
}
