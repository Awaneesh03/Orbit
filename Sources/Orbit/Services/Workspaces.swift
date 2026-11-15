import Foundation
import Observation

// Workspace Profiles (Milestone 16): named contexts (Development, College,
// FixKaru, Personal, or your own) that remember projects, apps, a task filter,
// what to do with music, an Overview layout, pinned launcher items and a few
// workspace settings. Activating one only changes Orbit (its layout, the
// launcher's ranking, Suggested actions) and, if you chose so, pauses music,
// starts a focus session or keeps the Mac awake. "Open Workspace" opens its
// apps and projects only when clicked. Nothing is ever closed, no file is
// changed, and no system setting is touched.

struct WorkspaceProfile: Codable, Identifiable, Equatable, Sendable {
    enum Music: String, Codable, CaseIterable, Sendable {
        case leave, pause
        var title: String { self == .leave ? "Leave music as it is" : "Pause music" }
    }

    /// Hours and weekdays when Orbit may suggest switching (never switches by itself).
    struct Schedule: Codable, Equatable, Sendable {
        /// 1 = Sunday … 7 = Saturday (Calendar.weekday).
        var weekdays: [Int] = [2, 3, 4, 5, 6]
        var startHour = 9
        var endHour = 17

        func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
            let parts = calendar.dateComponents([.weekday, .hour], from: date)
            guard let weekday = parts.weekday, let hour = parts.hour, weekdays.contains(weekday) else { return false }
            return startHour <= endHour ? (startHour ..< endHour).contains(hour) : (hour >= startHour || hour < endHour)
        }
    }

    var id = UUID()
    var name: String
    var symbol = "square.stack.3d.up"
    /// Project folders (opened in the editor by "Open Workspace"; their agent sessions count as relevant).
    var projects: [String] = []
    /// App bundles to open with "Open Workspace".
    var apps: [String] = []
    /// Tasks and goals whose titles contain one of these words are this workspace's.
    var taskKeywords: [String] = []
    var music = Music.leave
    var startFocus = false
    var keepAwake = false
    /// The Overview this workspace shows (nil: leave the current one).
    var layout: WidgetLayout?
    /// Launcher items pinned to this workspace's Suggested actions (LauncherItem ids).
    var pinned: [String] = []
    var schedule: Schedule?

    init(name: String, symbol: String = "square.stack.3d.up") {
        self.name = name
        self.symbol = symbol
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = (try? container.decode(UUID.self, forKey: .id)) ?? UUID()
        name = (try? container.decode(String.self, forKey: .name)) ?? "Workspace"
        symbol = (try? container.decode(String.self, forKey: .symbol)) ?? "square.stack.3d.up"
        projects = (try? container.decode([String].self, forKey: .projects)) ?? []
        apps = (try? container.decode([String].self, forKey: .apps)) ?? []
        taskKeywords = (try? container.decode([String].self, forKey: .taskKeywords)) ?? []
        music = (try? container.decode(Music.self, forKey: .music)) ?? .leave
        startFocus = (try? container.decode(Bool.self, forKey: .startFocus)) ?? false
        keepAwake = (try? container.decode(Bool.self, forKey: .keepAwake)) ?? false
        layout = try? container.decode(WidgetLayout.self, forKey: .layout)
        pinned = (try? container.decode([String].self, forKey: .pinned)) ?? []
        schedule = try? container.decode(Schedule.self, forKey: .schedule)
    }

    /// Whether a task or goal title belongs here.
    func owns(task title: String) -> Bool {
        taskKeywords.contains { !$0.isEmpty && title.localizedCaseInsensitiveContains($0) }
    }

    /// Whether an agent session's folder is one of this workspace's projects.
    func owns(folder: String?) -> Bool {
        guard let folder else { return false }
        return projects.contains { folder == $0 || folder.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }
    }
}

struct WorkspaceStore: Codable, Equatable, Sendable {
    var profiles: [WorkspaceProfile] = WorkspaceStore.starters
    var activeID: UUID?

    static var starters: [WorkspaceProfile] {
        [WorkspaceProfile(name: "Development", symbol: "chevron.left.forwardslash.chevron.right"),
         WorkspaceProfile(name: "College", symbol: "graduationcap"),
         WorkspaceProfile(name: "FixKaru", symbol: "wrench.and.screwdriver"),
         WorkspaceProfile(name: "Personal", symbol: "house")]
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        profiles = (try? container.decode([WorkspaceProfile].self, forKey: .profiles)) ?? Self.starters
        activeID = try? container.decode(UUID.self, forKey: .activeID)
        if let activeID, !profiles.contains(where: { $0.id == activeID }) { self.activeID = nil }
    }
}

@MainActor @Observable
final class Workspaces {
    static let fileName = "workspaces.json"
    private(set) var stored: Persisted<WorkspaceStore>
    var profiles: [WorkspaceProfile] { stored.value.profiles }
    var active: WorkspaceProfile? { stored.value.activeID.flatMap { id in profiles.first { $0.id == id } } }
    var problem: String? { stored.problem }

    init(file: JSONFile<WorkspaceStore>?) {
        stored = file.map { Persisted($0, initial: WorkspaceStore()) } ?? Persisted(memory: WorkspaceStore())
    }

    @discardableResult
    func create(named name: String = "New Workspace") -> WorkspaceProfile {
        let profile = WorkspaceProfile(name: uniqueName(name))
        stored.update { $0.profiles.append(profile) }
        return profile
    }

    @discardableResult
    func duplicate(_ id: UUID) -> WorkspaceProfile? {
        guard let original = profiles.first(where: { $0.id == id }) else { return nil }
        var copy = original
        copy.id = UUID()
        copy.name = uniqueName(original.name + " Copy")
        stored.update { store in
            let index = (store.profiles.firstIndex { $0.id == id } ?? store.profiles.count - 1) + 1
            store.profiles.insert(copy, at: index)
        }
        return copy
    }

    func delete(_ id: UUID) {
        stored.update { store in
            store.profiles.removeAll { $0.id == id }
            if store.activeID == id { store.activeID = nil }
        }
    }

    func update(_ id: UUID, _ change: (inout WorkspaceProfile) -> Void) {
        stored.update { store in
            guard let index = store.profiles.firstIndex(where: { $0.id == id }) else { return }
            change(&store.profiles[index])
            store.profiles[index].name = store.profiles[index].name.trimmingCharacters(in: .whitespacesAndNewlines)
            if store.profiles[index].name.isEmpty { store.profiles[index].name = "Workspace" }
        }
    }

    /// Makes it the active workspace; the app applies what it asks for. nil: no workspace.
    func setActive(_ id: UUID?) {
        guard id == nil || profiles.contains(where: { $0.id == id }) else { return }
        stored.update { $0.activeID = id }
    }

    /// A workspace whose schedule covers `date`, other than the active one (Suggested actions offer it; nothing switches).
    func suggestion(at date: Date, calendar: Calendar = .current) -> WorkspaceProfile? {
        profiles.first { $0.id != stored.value.activeID && $0.schedule?.contains(date, calendar: calendar) == true }
    }

    private func uniqueName(_ base: String) -> String {
        let names = Set(profiles.map(\.name))
        guard names.contains(base) else { return base }
        var number = 2
        while names.contains("\(base) \(number)") { number += 1 }
        return "\(base) \(number)"
    }
}
