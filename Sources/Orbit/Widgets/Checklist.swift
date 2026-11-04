import SwiftUI

enum TaskPriority: String, Codable, CaseIterable, Identifiable, Sendable {
    case high, normal, low
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var rank: Int {
        switch self {
        case .high: 0
        case .normal: 1
        case .low: 2
        }
    }
}

struct ChecklistItem: Codable, Identifiable, Equatable, Sendable {
    var id = UUID()
    var title: String
    var isDone = false
    // Stage 3.4. Optional and left out of the file while unset, so older files
    // load unchanged and untouched items keep their shape. Normal priority is nil.
    var priority: TaskPriority?
    /// The start of the local day it's due.
    var dueDate: Date?
    var completedAt: Date?

    var effectivePriority: TaskPriority { priority ?? .normal }

    init(id: UUID = UUID(), title: String, isDone: Bool = false, priority: TaskPriority? = nil,
         dueDate: Date? = nil, completedAt: Date? = nil) {
        self.id = id
        self.title = title
        self.isDone = isDone
        self.priority = priority
        self.dueDate = dueDate
        self.completedAt = completedAt
    }

    /// The original fields are required as before; the new ones are tolerant
    /// (an unknown priority from a newer version reads as normal).
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        title = try container.decode(String.self, forKey: .title)
        isDone = try container.decode(Bool.self, forKey: .isDone)
        priority = try? container.decodeIfPresent(TaskPriority.self, forKey: .priority)
        dueDate = try? container.decodeIfPresent(Date.self, forKey: .dueDate)
        completedAt = try? container.decodeIfPresent(Date.self, forKey: .completedAt)
    }
}

/// Add / complete / delete, shared by Tasks and Daily goals.
struct Checklist: Codable, Equatable, Sendable {
    static let maxTitleLength = 200

    var items: [ChecklistItem] = []

    var doneCount: Int { items.filter(\.isDone).count }

    /// Adds a trimmed, non-empty title. Returns false when rejected (empty, or `limit` reached).
    @discardableResult
    mutating func add(_ title: String, limit: Int = .max) -> Bool {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        guard !trimmed.isEmpty, items.count < limit else { return false }
        items.append(ChecklistItem(title: trimmed))
        return true
    }

    /// Completing records when; reopening clears it.
    mutating func toggle(_ id: UUID, now: Date = .now) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].isDone.toggle()
        items[index].completedAt = items[index].isDone ? now : nil
    }

    /// Keeps the id; rejects an empty title (the old one stays).
    @discardableResult
    mutating func rename(_ id: UUID, to title: String) -> Bool {
        let trimmed = String(title.trimmingCharacters(in: .whitespacesAndNewlines).prefix(Self.maxTitleLength))
        guard !trimmed.isEmpty, let index = items.firstIndex(where: { $0.id == id }) else { return false }
        items[index].title = trimmed
        return true
    }

    mutating func setPriority(_ id: UUID, _ priority: TaskPriority) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].priority = priority == .normal ? nil : priority
    }

    /// Stored as the start of that local day; nil clears it.
    mutating func setDueDate(_ id: UUID, _ date: Date?, calendar: Calendar = .current) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].dueDate = date.map { calendar.startOfDay(for: $0) }
    }

    mutating func delete(_ id: UUID) {
        items.removeAll { $0.id == id }
    }
}

/// Today's view of the task list: what to do in what order, and what counts
/// toward today's progress.
struct TodayPlan: Equatable {
    enum Due: Int, Comparable {
        case overdue, today, upcoming, none
        static func < (a: Due, b: Due) -> Bool { a.rawValue < b.rawValue }
    }

    /// Open tasks: overdue, due today, due later (soonest first), then undated;
    /// high before normal before low within each; otherwise in list order.
    let active: [ChecklistItem]
    /// Done tasks, most recently completed first.
    let completed: [ChecklistItem]
    /// Done today, out of today's tasks: open ones due by today or undated,
    /// plus those completed today. Tasks due later, or completed before today
    /// (or before completion times were recorded), don't count.
    let doneToday: Int
    let totalToday: Int
    let overdueCount: Int

    init(_ items: [ChecklistItem], now: Date, calendar: Calendar = .current) {
        let indexed = Array(items.enumerated())
        func due(_ item: ChecklistItem) -> Due { Self.due(item, now: now, calendar: calendar) }
        active = indexed.filter { !$0.element.isDone }.sorted { a, b in
            let (x, y) = (a.element, b.element)
            if due(x) != due(y) { return due(x) < due(y) }
            if due(x) == .upcoming, x.dueDate != y.dueDate { return (x.dueDate ?? .distantFuture) < (y.dueDate ?? .distantFuture) }
            if x.effectivePriority != y.effectivePriority { return x.effectivePriority.rank < y.effectivePriority.rank }
            return a.offset < b.offset
        }.map(\.element)
        completed = indexed.filter { $0.element.isDone }.sorted { a, b in
            let (x, y) = (a.element.completedAt ?? .distantPast, b.element.completedAt ?? .distantPast)
            return x != y ? x > y : a.offset < b.offset
        }.map(\.element)
        let doneToday = items.filter { $0.isDone && $0.completedAt.map { calendar.isDate($0, inSameDayAs: now) } == true }.count
        self.doneToday = doneToday
        totalToday = doneToday + active.filter { due($0) != .upcoming }.count
        overdueCount = active.filter { due($0) == .overdue }.count
    }

    static func due(_ item: ChecklistItem, now: Date, calendar: Calendar = .current) -> Due {
        guard let dueDate = item.dueDate else { return .none }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: dueDate)
        return day < today ? .overdue : day == today ? .today : .upcoming
    }
}

/// Rows you can tick or delete, plus an add field.
struct ChecklistView: View {
    let items: [ChecklistItem]
    let placeholder: String
    let emptyText: String
    let canAdd: Bool
    let draft: Binding<String>
    let onAdd: () -> Void
    let onToggle: (UUID) -> Void
    let onDelete: (UUID) -> Void
    /// Click a title to edit it in place (Return saves, Escape closes the dashboard).
    var editing: Binding<UUID?>?
    var editDraft: Binding<String>?
    var onRename: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if items.isEmpty {
                Text(emptyText).foregroundStyle(Theme.tertiary)
                Spacer(minLength: 0)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 5) {
                        ForEach(items) { item in row(item) }
                    }
                }
                .scrollIndicators(.never)
            }
            if canAdd {
                TextField(placeholder, text: draft)
                    .textFieldStyle(.plain)
                    .onSubmit(onAdd)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 6)
                    .orbitSurface(radius: 10)
            }
        }
    }

    private func row(_ item: ChecklistItem) -> some View {
        HStack(spacing: 7) {
            if let editing, let editDraft, let onRename, editing.wrappedValue == item.id {
                Image(systemName: "pencil").foregroundStyle(Theme.accent)
                TextField("Title", text: editDraft)
                    .textFieldStyle(.plain)
                    .onSubmit(onRename)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .orbitSurface(radius: 6)
            } else if let editing, let editDraft, onRename != nil {
                Button { onToggle(item.id) } label: { checkbox(item) }
                    .buttonStyle(DashboardButtonStyle())
                Button {
                    editDraft.wrappedValue = item.title
                    editing.wrappedValue = item.id
                } label: {
                    title(item).frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(DashboardButtonStyle())
                .help("Click to edit")
            } else {
                Button { onToggle(item.id) } label: {
                    HStack(spacing: 7) {
                        checkbox(item)
                        title(item)
                        Spacer(minLength: 4)
                    }
                }
                .buttonStyle(DashboardButtonStyle())
            }
            Button { onDelete(item.id) } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Theme.tertiary)
                    .padding(3)
            }
            .buttonStyle(DashboardButtonStyle())
            .help("Delete")
        }
    }

    private func checkbox(_ item: ChecklistItem) -> some View {
        Image(systemName: item.isDone ? "checkmark.circle.fill" : "circle")
            .foregroundStyle(item.isDone ? Theme.accent : Theme.secondary)
    }

    private func title(_ item: ChecklistItem) -> some View {
        Text(item.title)
            .strikethrough(item.isDone, color: Theme.tertiary)
            .foregroundStyle(item.isDone ? Theme.tertiary : .white)
            .lineLimit(1)
    }
}
