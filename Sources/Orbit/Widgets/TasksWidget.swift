import SwiftUI

/// Your to-do list, organised for today (see `TodayPlan`). Your data, saved
/// to tasks.json; the existing file is copied to tasks.v1-backup.json before
/// this version's first write. Compact: today's progress and the next tasks.
/// Expanded: every task with editing, plus today's goals.
@MainActor @Observable
final class TasksWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "tasks", title: "Tasks", description: "Your to-do list",
        symbol: "checklist", category: .productivity, availability: .live,
        presentations: [.compact, .expanded], sectionPresentation: .expanded)
    private(set) var stored: Persisted<Checklist>
    var draft = ""
    /// The task being edited in the expanded view.
    var editingID: UUID?
    var editDraft = ""
    /// "Today", as of the last time the dashboard opened (no timer needed).
    private(set) var now: Date
    private let clock: () -> Date
    let goals: GoalsWidget?

    var state: WidgetState { stored.problem.map(WidgetState.failed) ?? .ready }
    var items: [ChecklistItem] { stored.value.items }
    var plan: TodayPlan { TodayPlan(items, now: now) }

    init(file: JSONFile<Checklist>, goals: GoalsWidget? = nil, clock: @escaping () -> Date = { .now }) {
        stored = Persisted(file, initial: Checklist(), backupName: "tasks.v1-backup.json")
        self.goals = goals
        self.clock = clock
        now = clock()
    }

    func start() {
        now = clock()
        goals?.rollOver()
    }

    func stop() { if editingID != nil { commitEdit() } }

    func add() {
        var added = false
        stored.update { added = $0.add(draft) }
        if added { draft = "" }
    }

    func toggle(_ id: UUID) { stored.update { $0.toggle(id, now: clock()) } }

    func delete(_ id: UUID) {
        if editingID == id { editingID = nil }
        stored.update { $0.delete(id) }
    }

    func beginEditing(_ item: ChecklistItem) {
        if editingID != nil { commitEdit() }
        editDraft = item.title
        editingID = item.id
    }

    /// Saves the edited title; an unchanged or empty title writes nothing.
    func commitEdit() {
        guard let id = editingID else { return }
        editingID = nil
        let title = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, items.first(where: { $0.id == id })?.title != title else { return }
        stored.update { $0.rename(id, to: title) }
    }

    func setPriority(_ id: UUID, _ priority: TaskPriority) {
        guard items.first(where: { $0.id == id })?.effectivePriority != priority else { return }
        stored.update { $0.setPriority(id, priority) }
    }

    func setDueDate(_ id: UUID, _ date: Date?) { stored.update { $0.setDueDate(id, date) } }

    /// A due date `days` from today, for the presets.
    func day(_ days: Int) -> Date {
        Calendar.current.date(byAdding: .day, value: days, to: Calendar.current.startOfDay(for: now)) ?? now
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        presentation == .compact ? AnyView(CompactTodayView(widget: self)) : AnyView(ExpandedTodayView(widget: self))
    }
}

// MARK: Views

/// "3 of 7 today" with the ring; never a percentage, calm when there's nothing.
private struct TodayProgress: View {
    let plan: TodayPlan
    var size: CGFloat = 30

    var body: some View {
        HStack(spacing: 9) {
            OrbitProgressRing(done: plan.doneToday, total: plan.totalToday, size: size)
            VStack(alignment: .leading, spacing: 1) {
                Text(plan.totalToday == 0 ? "Nothing due today" : "\(plan.doneToday) of \(plan.totalToday) today")
                    .font(OrbitType.body)
                if plan.overdueCount > 0 {
                    Text("\(plan.overdueCount) overdue")
                        .font(OrbitType.caption)
                        .foregroundStyle(OrbitGlass.critical)
                }
            }
        }
    }
}

private struct CompactTodayView: View {
    let widget: TasksWidget

    var body: some View {
        let plan = widget.plan
        VStack(alignment: .leading, spacing: 7) {
            TodayProgress(plan: plan, size: 28)  // fixed: never scrolls
            if plan.active.isEmpty {
                Text(widget.items.isEmpty ? "Nothing to do yet." : "All done.").foregroundStyle(Theme.tertiary)
                Spacer(minLength: 0)
            } else {
                // Only the list scrolls, inside the card's fixed height. The system's
                // overlay scroller shows only while scrolling; the bottom edge fades
                // to hint at more.
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(plan.active) { TaskRow(widget: widget, item: $0, editable: false) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.bottom, 4)
                }
                .scrollIndicators(.automatic)
                .scrollBounceBehavior(.basedOnSize)
                .mask(LinearGradient(stops: [.init(color: .black, location: 0), .init(color: .black, location: 0.82),
                                             .init(color: .black.opacity(0.15), location: 1)],
                                     startPoint: .top, endPoint: .bottom))
                .frame(maxHeight: .infinity)
            }
            TaskAddField(widget: widget)
        }
    }
}

private struct ExpandedTodayView: View {
    let widget: TasksWidget
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let plan = widget.plan
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                TodayProgress(plan: plan, size: 32)
                if let goals = widget.goals { GoalsSummary(goals: goals) }
                Spacer(minLength: 0)
            }
            .frame(width: 132, alignment: .leading)
            Rectangle().fill(OrbitGlass.hairline).frame(width: 0.5)
            VStack(alignment: .leading, spacing: 6) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        if plan.active.isEmpty && plan.completed.isEmpty {
                            Text("Nothing to do yet.").foregroundStyle(Theme.tertiary)
                        }
                        ForEach(plan.active) { row($0) }
                        if !plan.completed.isEmpty {
                            Text("COMPLETED")
                                .font(OrbitType.eyebrow)
                                .tracking(0.7)
                                .foregroundStyle(Theme.tertiary)
                                .padding(.top, 4)
                            ForEach(plan.completed) { row($0) }
                        }
                    }
                    .animation(OrbitMotion.animation(.orbitSpring, reduced: reduceMotion), value: plan.active.map(\.id))
                }
                .scrollIndicators(.never)
                TaskAddField(widget: widget)
            }
        }
    }

    @ViewBuilder
    private func row(_ item: ChecklistItem) -> some View {
        if widget.editingID == item.id {
            TaskEditor(widget: widget, item: item)
        } else {
            TaskRow(widget: widget, item: item, editable: true)
        }
    }
}

private struct TaskRow: View {
    let widget: TasksWidget
    let item: ChecklistItem
    let editable: Bool

    var body: some View {
        HStack(spacing: 7) {
            Button { widget.toggle(item.id) } label: {
                Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(item.isDone ? Theme.accent : item.effectivePriority == .high ? OrbitGlass.critical : Theme.secondary)
            }
            .buttonStyle(DashboardButtonStyle())
            .help(item.isDone ? "Reopen" : "Complete")
            if editable {
                Button { widget.beginEditing(item) } label: {
                    title.frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(DashboardButtonStyle())
                .help("Edit")
            } else {
                title
                Spacer(minLength: 4)
            }
            if !item.isDone {
                if item.effectivePriority == .high {
                    Image(systemName: "flag.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(OrbitGlass.critical)
                        .help("High priority")
                }
                if let due = DueLabel(item: item, now: widget.now, short: !editable) {
                    Text(due.text).font(OrbitType.caption).foregroundStyle(due.color).lineLimit(1)
                }
            }
            if editable {
                Button { widget.delete(item.id) } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(Theme.tertiary)
                        .padding(3)
                }
                .buttonStyle(DashboardButtonStyle())
                .help("Delete")
            }
        }
    }

    private var title: some View {
        Text(item.title)
            .strikethrough(item.isDone, color: Theme.tertiary)
            .foregroundStyle(item.isDone ? Theme.tertiary : item.effectivePriority == .low ? Theme.secondary : .white)
            .lineLimit(1)
    }
}

/// Title, priority, due date and delete for one task, in place of its row.
struct TaskEditor: View {
    let widget: TasksWidget
    let item: ChecklistItem

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                TextField("Title", text: Binding(get: { widget.editDraft }, set: { widget.editDraft = $0 }))
                    .textFieldStyle(.plain)
                    .onSubmit { widget.commitEdit() }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .orbitSurface(radius: 8)
                Button { widget.commitEdit() } label: {
                    Text("Done").font(OrbitType.caption).padding(.horizontal, 10).padding(.vertical, 4).fixedSize()
                }
                .buttonStyle(OrbitGlassButtonStyle(prominent: true))
            }
            HStack(spacing: 3) {
                ForEach(TaskPriority.allCases) { priority in
                    Button { widget.setPriority(item.id, priority) } label: {
                        Text(priority.title).font(OrbitType.caption).padding(.horizontal, 8).padding(.vertical, 3).fixedSize()
                    }
                    .buttonStyle(OrbitSelectableStyle(isSelected: item.effectivePriority == priority))
                }
                Spacer(minLength: 6)
                Menu {
                    Button("Today") { widget.setDueDate(item.id, widget.day(0)) }
                    Button("Tomorrow") { widget.setDueDate(item.id, widget.day(1)) }
                    Button("Next week") { widget.setDueDate(item.id, widget.day(7)) }
                    if item.dueDate != nil {
                        Divider()
                        Button("No due date") { widget.setDueDate(item.id, nil) }
                    }
                } label: {
                    Label(item.dueDate.map { $0.formatted(.dateTime.day().month(.abbreviated)) } ?? "Due date",
                          systemImage: "calendar")
                        .font(OrbitType.caption)
                        .foregroundStyle(item.dueDate == nil ? Theme.secondary : .white)
                        .fixedSize()
                }
                .menuStyle(.button)
                .buttonStyle(DashboardButtonStyle())
                .menuIndicator(.hidden)
                .fixedSize()
                Button { widget.delete(item.id) } label: { Image(systemName: "trash").font(OrbitType.caption) }
                    .buttonStyle(DashboardButtonStyle())
                    .foregroundStyle(Theme.secondary)
                    .help("Delete")
            }
            if let dueDate = item.dueDate {
                DatePicker("Due", selection: Binding(get: { dueDate }, set: { widget.setDueDate(item.id, $0) }),
                           displayedComponents: .date)
                    .datePickerStyle(.field)
                    .font(OrbitType.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
        .padding(6)
        .orbitSurface(radius: 10)
    }
}

/// Today's goals (mint ring) next to the task progress (indigo ring).
private struct GoalsSummary: View {
    let goals: GoalsWidget

    var body: some View {
        let items = goals.goals
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                OrbitProgressRing(done: goals.doneCount, total: items.count, tint: OrbitGlass.goal, size: 22, lineWidth: 3)
                Text(items.isEmpty ? "No goals today" : "\(goals.doneCount) of \(items.count) goals")
                    .font(OrbitType.caption)
                    .foregroundStyle(Theme.secondary)
            }
            ForEach(items) { goal in
                Button { goals.toggle(goal.id) } label: {
                    HStack(spacing: 5) {
                        Image(systemName: goal.isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(goal.isDone ? OrbitGlass.goal : Theme.secondary)
                        Text(goal.title).lineLimit(1).foregroundStyle(goal.isDone ? Theme.tertiary : .white)
                    }
                    .font(OrbitType.caption)
                }
                .buttonStyle(DashboardButtonStyle())
            }
        }
    }
}

private struct TaskAddField: View {
    let widget: TasksWidget

    var body: some View {
        TextField("Add a task", text: Binding(get: { widget.draft }, set: { widget.draft = $0 }))
            .textFieldStyle(.plain)
            .onSubmit { widget.add() }
            .padding(.horizontal, 9)
            .padding(.vertical, 6)
            .orbitSurface(radius: 10)
    }
}

/// "Overdue · 1 Nov" ("Overdue" when short), "Today" or "Tue 4 Nov".
struct DueLabel {
    let text: String
    let color: Color

    init?(item: ChecklistItem, now: Date, short: Bool = false) {
        guard let due = item.dueDate else { return nil }
        switch TodayPlan.due(item, now: now) {
        case .overdue:
            (text, color) = (short ? "Overdue" : "Overdue · " + due.formatted(.dateTime.day().month(.abbreviated)), OrbitGlass.critical)
        case .today: (text, color) = ("Today", Theme.accent)
        case .upcoming: (text, color) = (due.formatted(.dateTime.weekday(.abbreviated).day().month(.abbreviated)), Theme.tertiary)
        case .none: return nil
        }
    }
}
