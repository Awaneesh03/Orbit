import SwiftUI

struct DailyGoals: Codable, Equatable, Sendable {
    var day: String
    var checklist = Checklist()
    /// Earlier days' goals, newest first (Stage 3.4: kept instead of discarded
    /// at the daily reset). Optional, so older files load unchanged.
    var history: [GoalDay]?
}

struct GoalDay: Codable, Equatable, Sendable {
    var day: String
    var items: [ChecklistItem]
}

/// Up to three goals for today; a new day starts a fresh list. Your data,
/// saved to goals.json.
@MainActor @Observable
final class GoalsWidget: DashboardWidget {
    static let limit = 3
    /// Days of earlier goals kept in goals.json.
    static let historyDays = 60

    let metadata = WidgetMetadata(
        id: "goals", title: "Daily goals", description: "Up to three goals for today",
        symbol: "target", category: .productivity, availability: .live, isEnabledByDefault: false)
    private(set) var stored: Persisted<DailyGoals>
    var draft = ""
    var editingID: UUID?
    var editDraft = ""
    private let today: () -> Date

    var state: WidgetState { stored.problem.map(WidgetState.failed) ?? .ready }
    var goals: [ChecklistItem] { stored.value.checklist.items }

    init(file: JSONFile<DailyGoals>, today: @escaping () -> Date = { .now }) {
        self.today = today
        stored = Persisted(file, initial: DailyGoals(day: Self.dayKey(today())), backupName: "goals.v1-backup.json")
        rollOver()
    }

    func start() { rollOver() }
    func stop() { if editingID != nil { rename() } }

    var doneCount: Int { stored.value.checklist.doneCount }
    var history: [GoalDay] { stored.value.history ?? [] }

    /// A new day starts an empty list; the previous day's goals move to the history.
    func rollOver() {
        let key = Self.dayKey(today())
        guard stored.value.day != key else { return }
        editingID = nil
        stored.update { goals in
            var history = goals.history ?? []
            if !goals.checklist.items.isEmpty { history.insert(GoalDay(day: goals.day, items: goals.checklist.items), at: 0) }
            goals = DailyGoals(day: key, history: history.isEmpty ? nil : Array(history.prefix(Self.historyDays)))
        }
    }

    /// Saves the title being edited (an unchanged or empty title writes nothing).
    func rename() {
        guard let id = editingID else { return }
        editingID = nil
        let title = editDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, goals.first(where: { $0.id == id })?.title != title else { return }
        stored.update { $0.checklist.rename(id, to: title) }
    }

    func add() {
        rollOver()
        var added = false
        stored.update { added = $0.checklist.add(draft, limit: Self.limit) }
        if added { draft = "" }
    }

    func toggle(_ id: UUID) { stored.update { $0.checklist.toggle(id, now: today()) } }
    func delete(_ id: UUID) { stored.update { $0.checklist.delete(id) } }

    /// Local calendar day, e.g. "2026-10-31".
    nonisolated static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        let checklist = stored.value.checklist
        return AnyView(VStack(alignment: .leading, spacing: 6) {
            if !checklist.items.isEmpty {
                HStack(spacing: 8) {
                    OrbitProgressRing(done: checklist.doneCount, total: checklist.items.count, tint: OrbitGlass.goal, size: 24, lineWidth: 3)
                    Text("\(checklist.doneCount) of \(checklist.items.count) goals")
                        .font(OrbitType.body)
                        .foregroundStyle(Theme.secondary)
                }
            }
            ChecklistView(
                items: checklist.items, placeholder: "Add a goal", emptyText: "Set up to three goals for today.",
                canAdd: checklist.items.count < Self.limit,
                draft: Binding(get: { self.draft }, set: { self.draft = $0 }),
                onAdd: add, onToggle: toggle, onDelete: delete,
                editing: Binding(get: { self.editingID }, set: { self.editingID = $0 }),
                editDraft: Binding(get: { self.editDraft }, set: { self.editDraft = $0 }),
                onRename: rename)
        })
    }
}
