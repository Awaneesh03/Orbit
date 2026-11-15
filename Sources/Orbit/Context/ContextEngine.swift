import Foundation
import Observation
import os

// The Context Engine (Milestone 17): what's going on in Orbit, in one place,
// and what might help next. It monitors nothing itself: registered sources
// read models Orbit already keeps current (AI Hub, meetings, workspaces,
// tasks, goals, focus, battery, energy, music, shelf, displays, automations).
// Observation reports when any of them change; the engine re-reads (coalesced),
// diffs the result into events (an unchanged value is never an event), runs
// the suggestion rules, ranks, and explains what it showed and what it held
// back. It wakes by itself only at a known time: an expiry, a snooze ending,
// a focus run ending, the evening goal check. Suggestions never act on their
// own: every action needs a click.

/// Everything the rules look at: plain values, read from Orbit's models.
struct ContextSnapshot: Equatable {
    struct Agent: Equatable, Sendable {
        let key: String
        let name: String
        let project: String?
        let folder: String?
        let status: AgentSession.Status
        let lastEventAt: Date
        let canJump: Bool
    }

    enum Focus: Equatable, Sendable {
        case unavailable, idle, resting
        case running(endsAt: Date, length: TimeInterval)
        case paused(remaining: TimeInterval)
    }

    var workspace: WorkspaceProfile?
    var workspaces: [WorkspaceProfile] = []
    /// Real agent sessions active in the last day (never simulated).
    var agents: [Agent] = []
    var meeting: MeetingCue?
    var todayEvents: [AgendaEvent] = []
    var openTasks: [ChecklistItem] = []
    /// Tasks completed today (for the focus summary).
    var doneToday: [ChecklistItem] = []
    var goals: [ChecklistItem] = []
    var focus = Focus.unavailable
    var focusSessionsToday = 0
    var battery: BatteryStatus?
    /// A High-energy app, while the Battery widget samples (nil otherwise: not known, not "none").
    var energyHog: String?
    var music: String?
    var shelfNewest: String?
    var displays = 1
    var externalDisplay = false
    var automations: [AutomationRule] = []

    var waitingAgents: [Agent] { agents.filter { $0.status == .waiting } }
    var workingAgents: [Agent] { agents.filter { $0.status == .running } }
}

/// One registered provider. `read` fills its part of the snapshot from an existing model; a throw is shown in the inspector.
struct ContextSource: Sendable {
    let id: String
    let name: String
    let read: @MainActor @Sendable (inout ContextSnapshot) throws -> Void
}

struct ContextEvent: Identifiable, Equatable, Sendable {
    enum Kind: String, Sendable { case change, suggestion, automation, error }
    let id: Int
    let at: Date
    let source: String
    let kind: Kind
    let text: String
}

struct Suggestion: Identifiable, Equatable, Sendable {
    enum Category: String, Codable, CaseIterable, Sendable {
        case attention, calendar, agents, productivity, workspace, battery
        var title: String {
            switch self {
            case .attention: "Needs attention"
            case .calendar: "Calendar"
            case .agents: "AI agents"
            case .productivity: "Focus and tasks"
            case .workspace: "Workspaces"
            case .battery: "Battery and energy"
            }
        }
    }

    enum Action: Equatable, Sendable {
        case goToAgent(String), reviewAgent(String), openAIHub, joinMeeting(URL), openCalendar, pauseMusic
        case switchWorkspace(UUID), openProductivity, startFocus(minutes: Int), resumeFocus, batterySettings, activityMonitor

        var label: String {
            switch self {
            case .goToAgent: "Open Session"
            case .reviewAgent: "Review"
            case .openAIHub: "AI Hub"
            case .joinMeeting(let url): MeetingLink.service(of: url).map { "Join \($0)" } ?? "Join"
            case .openCalendar: "Calendar"
            case .pauseMusic: "Pause Music"
            case .switchWorkspace: "Switch"
            case .openProductivity: "Open Tasks"
            case .startFocus(let minutes): "Focus \(minutes) min"
            case .resumeFocus: "Resume"
            case .batterySettings: "Battery Settings"
            case .activityMonitor: "Activity Monitor"
            }
        }
    }

    /// "<kind>:<instance>": a new meeting, session or day is a new suggestion; the same one isn't shown twice.
    let id: String
    let kind: String
    let category: Category
    let title: String
    let detail: String
    /// Why it appeared, in words.
    let reason: String
    let symbol: String
    /// 0…100 before learning.
    let priority: Int
    let primary: Action
    var secondary: Action?
    var expiresAt: Date?
}

/// Facts the engine remembers between updates (memory only).
struct ContextMemory: Equatable {
    /// The meeting that started, its end and the workspace active then (for "back to your workspace").
    var meeting: (id: String, title: String, end: Date?, workspace: UUID?)?
    /// The focus run being watched, and the summary of the last one that ended.
    var focusRun: (start: Date, end: Date)?
    var focusSummary: (end: Date, minutes: Int, tasks: [String], agents: [String])?

    static func == (a: ContextMemory, b: ContextMemory) -> Bool {
        a.meeting?.id == b.meeting?.id && a.focusRun?.end == b.focusRun?.end && a.focusSummary?.end == b.focusSummary?.end
    }
}

enum SuggestionRules {
    static let eveningHour = 17

    /// Every suggestion the current context supports, unranked.
    static func generate(_ s: ContextSnapshot, memory: ContextMemory, preferences: SuggestionPreferences, now: Date,
                         calendar: Calendar = .current) -> [Suggestion] {
        var list: [Suggestion] = []
        let hour = calendar.component(.hour, from: now)
        let today = Int(calendar.startOfDay(for: now).timeIntervalSinceReferenceDate)

        // Agents.
        for agent in s.waitingAgents {
            list.append(Suggestion(id: "agent.waiting:\(agent.key)", kind: "agent.waiting", category: .attention,
                                   title: "\(agent.name) needs you", detail: agent.project.map { "Waiting in \($0)" } ?? "It reported it needs your input",
                                   reason: "The session reported it's waiting for input.", symbol: "hand.raised.fill", priority: 100,
                                   primary: agent.canJump ? .goToAgent(agent.key) : .reviewAgent(agent.key), secondary: .openAIHub))
        }
        for agent in s.agents where agent.status == .failed && now.timeIntervalSince(agent.lastEventAt) < 7200 {
            list.append(Suggestion(id: "agent.failed:\(agent.key):\(Int(agent.lastEventAt.timeIntervalSinceReferenceDate))", kind: "agent.failed",
                                   category: .agents, title: "\(agent.name) failed", detail: agent.project.map { "In \($0): see what went wrong" } ?? "See what went wrong",
                                   reason: "Its last turn ended with an error \(Self.ago(agent.lastEventAt, now)).", symbol: "exclamationmark.triangle.fill",
                                   priority: 88, primary: .reviewAgent(agent.key), secondary: agent.canJump ? .goToAgent(agent.key) : nil,
                                   expiresAt: agent.lastEventAt.addingTimeInterval(7200)))
        }
        for agent in s.agents where (agent.status == .completed || agent.status == .ended) && now.timeIntervalSince(agent.lastEventAt) < 3600 {
            list.append(Suggestion(id: "agent.done:\(agent.key):\(Int(agent.lastEventAt.timeIntervalSinceReferenceDate))", kind: "agent.done",
                                   category: .agents, title: "Review \(agent.name)'s work", detail: agent.project.map { "Finished in \($0)" } ?? "It finished",
                                   reason: "The session finished \(Self.ago(agent.lastEventAt, now)).", symbol: "checkmark.circle.fill", priority: 60,
                                   primary: .reviewAgent(agent.key), expiresAt: agent.lastEventAt.addingTimeInterval(3600)))
        }

        // Calendar.
        if let cue = s.meeting {
            let pause: Suggestion.Action? = s.music != nil ? .pauseMusic : nil
            let primary: Suggestion.Action = cue.joinURL.map { .joinMeeting($0) } ?? .openCalendar
            switch cue.phase {
            case .started:
                list.append(Suggestion(id: "meeting.now:\(cue.eventID)", kind: "meeting.now", category: .calendar, title: "\(cue.title) has started",
                                       detail: cue.joinURL.flatMap(MeetingLink.service(of:)).map { "On \($0)" } ?? "Started \(cue.start.formatted(date: .omitted, time: .shortened))",
                                       reason: "It's on your calendar for now.", symbol: "video.fill", priority: 96, primary: primary,
                                       secondary: pause ?? (cue.joinURL != nil ? .openCalendar : nil), expiresAt: cue.start.addingTimeInterval(600)))
            case .soon, .upcoming:
                list.append(Suggestion(id: "meeting.soon:\(cue.eventID)", kind: "meeting.soon", category: .calendar,
                                       title: "\(cue.title) \(cue.countdown(at: now))", detail: cue.start.formatted(date: .omitted, time: .shortened)
                                        + (cue.joinURL.flatMap(MeetingLink.service(of:)).map { " · \($0)" } ?? ""),
                                       reason: "It starts within your \(cue.phase == .soon ? "reminder" : "heads-up") time.", symbol: "calendar",
                                       priority: cue.phase == .soon ? 92 : 78, primary: primary,
                                       secondary: pause ?? (cue.joinURL != nil ? .openCalendar : nil), expiresAt: cue.start))
                if let busy = s.workingAgents.first {
                    list.append(Suggestion(id: "meeting.agent:\(cue.eventID):\(busy.key)", kind: "meeting.agent", category: .agents,
                                           title: "Check \(busy.name) before your meeting", detail: busy.project.map { "Still working in \($0)" } ?? "Still working",
                                           reason: "\(cue.title) starts \(cue.countdown(at: now)) and this agent hasn't finished.",
                                           symbol: "sparkles", priority: 82, primary: busy.canJump ? .goToAgent(busy.key) : .reviewAgent(busy.key),
                                           expiresAt: cue.start))
                }
            }
        }
        if let met = memory.meeting, let end = met.end, now >= end, now.timeIntervalSince(end) < 900, let before = met.workspace,
           before != s.workspace?.id, let profile = s.workspaces.first(where: { $0.id == before }) {
            list.append(Suggestion(id: "meeting.after:\(met.id)", kind: "meeting.after", category: .workspace, title: "Back to \(profile.name)?",
                                   detail: "\(met.title) has ended", reason: "\(profile.name) was your workspace when the meeting started.",
                                   symbol: profile.symbol, priority: 50, primary: .switchWorkspace(before), expiresAt: end.addingTimeInterval(900)))
        }

        // Focus and tasks.
        if preferences.smartFocus {
            if case .paused = s.focus {
                list.append(Suggestion(id: "focus.resume:\(today)", kind: "focus.resume", category: .productivity, title: "Resume your focus session",
                                       detail: "It's paused", reason: "A focus session was interrupted and hasn't finished.", symbol: "timer",
                                       priority: 72, primary: .resumeFocus))
            }
            if let summary = memory.focusSummary, now.timeIntervalSince(summary.end) < 1800 {
                var parts = ["\(summary.minutes) min"]
                if !summary.tasks.isEmpty { parts.append("\(summary.tasks.count) task\(summary.tasks.count == 1 ? "" : "s") done") }
                if !summary.agents.isEmpty { parts.append(summary.agents.joined(separator: ", ") + " finished") }
                list.append(Suggestion(id: "focus.summary:\(Int(summary.end.timeIntervalSinceReferenceDate))", kind: "focus.summary",
                                       category: .productivity, title: "Focus session complete", detail: parts.joined(separator: " · "),
                                       reason: "From your tasks and agent sessions during the session.", symbol: "checkmark.seal.fill", priority: 66,
                                       primary: .startFocus(minutes: 25), expiresAt: summary.end.addingTimeInterval(1800)))
            }
            let meetingSoon = s.meeting.map { $0.start.timeIntervalSince(now) < 1800 } ?? false
            if s.focus == .idle, s.openTasks.count >= 3, !meetingSoon, (8 ..< 21).contains(hour) {
                let mine = s.workspace.flatMap { workspace in s.openTasks.first { workspace.owns(task: $0.title) } }
                list.append(Suggestion(id: "focus.start:\(today):\(hour / 3)", kind: "focus.start", category: .productivity,
                                       title: mine.map { "Focus on “\($0.title)”" } ?? "Start a focus session",
                                       detail: "\(s.openTasks.count) tasks open" + (mine != nil ? " · from \(s.workspace?.name ?? "")" : ""),
                                       reason: "Several tasks are open and nothing is scheduled for the next 30 minutes.", symbol: "timer",
                                       priority: 48, primary: .startFocus(minutes: 25), secondary: .startFocus(minutes: 50)))
            }
        }
        if hour >= eveningHour, hour < 23, let goal = s.goals.first(where: { !$0.isDone }) {
            let left = s.goals.filter { !$0.isDone }.count
            list.append(Suggestion(id: "goal.evening:\(today)", kind: "goal.evening", category: .productivity, title: "Continue “\(goal.title)”",
                                   detail: "\(left) of \(s.goals.count) daily goals left", reason: "It's evening and today's goals aren't done.",
                                   symbol: "target", priority: 55, primary: .openProductivity))
        }
        if let workspace = s.workspace, let task = s.openTasks.first(where: { workspace.owns(task: $0.title) }) {
            list.append(Suggestion(id: "task.workspace:\(task.id)", kind: "task.workspace", category: .productivity, title: task.title,
                                   detail: "Next for \(workspace.name)", reason: "It matches \(workspace.name)'s task words.", symbol: "checklist",
                                   priority: 36, primary: .openProductivity))
        }

        // Workspaces.
        if preferences.workspaceRecommendations {
            list += workspaceSuggestions(s, now: now, calendar: calendar)
        }

        // Battery and energy (never while charging).
        if let battery = s.battery, battery.chargeState == .onBattery, battery.percent <= 20 {
            list.append(Suggestion(id: "battery.low:\(today):\(battery.percent <= 10 ? 10 : 20)", kind: "battery.low", category: .battery,
                                   title: "Battery at \(battery.percent)%", detail: "Low Power Mode is in Battery Settings",
                                   reason: "The Mac is unplugged and below 20%. Orbit can't turn Low Power Mode on itself.",
                                   symbol: battery.percent <= 10 ? "battery.0percent" : "battery.25percent", priority: battery.percent <= 10 ? 94 : 80,
                                   primary: .batterySettings))
        }
        if let app = s.energyHog, s.battery?.chargeState != .charging {
            list.append(Suggestion(id: "energy.high:\(app):\(today)", kind: "energy.high", category: .battery, title: "\(app) is using a lot of energy",
                                   detail: "macOS's estimate is High", reason: "Measured over the last few seconds by the Battery widget.",
                                   symbol: "bolt.circle.fill", priority: 58, primary: .activityMonitor, expiresAt: now.addingTimeInterval(600)))
        }
        return list
    }

    /// Workspaces that fit what's happening (one per workspace, its strongest reason). Never switches.
    static func workspaceSuggestions(_ s: ContextSnapshot, now: Date, calendar: Calendar) -> [Suggestion] {
        var list: [Suggestion] = []
        for profile in s.workspaces where profile.id != s.workspace?.id {
            var reason: (text: String, priority: Int)?
            let name = profile.name.trimmingCharacters(in: .whitespaces)
            if name.count >= 3, let event = s.todayEvents.first(where: { $0.title.localizedCaseInsensitiveContains(name)
                && $0.end > now && $0.start.timeIntervalSince(now) < 7200 }) {
                reason = ("Your calendar has “\(event.title)” at \(event.start.formatted(date: .omitted, time: .shortened)).", 56)
            } else if let agent = s.agents.first(where: { ($0.status == .running || $0.status == .waiting) && profile.owns(folder: $0.folder) }) {
                reason = ("\(agent.name) is working in \(agent.project ?? "one of its projects").", 50)
            } else if profile.schedule?.contains(now, calendar: calendar) == true {
                reason = ("It's within its schedule.", 46)
            } else {
                let owned = s.openTasks.filter { profile.owns(task: $0.title) }.count
                if owned >= 2 { reason = ("\(owned) open tasks match its task words.", 42) }
            }
            guard let reason else { continue }
            list.append(Suggestion(id: "workspace:\(profile.id):\(Int(calendar.startOfDay(for: now).timeIntervalSinceReferenceDate))",
                                   kind: "workspace.recommend", category: .workspace, title: "Switch to \(profile.name)?",
                                   detail: reason.text, reason: reason.text + " Orbit only suggests; it never switches by itself.",
                                   symbol: profile.symbol, priority: reason.priority, primary: .switchWorkspace(profile.id)))
        }
        return list
    }

    static func ago(_ date: Date, _ now: Date) -> String {
        let minutes = max(0, Int(now.timeIntervalSince(date) / 60))
        return minutes < 1 ? "just now" : minutes < 60 ? "\(minutes) min ago" : "\(minutes / 60) h ago"
    }
}

struct SuggestionPreferences: Codable, Equatable, Sendable {
    enum Frequency: String, Codable, CaseIterable, Sendable {
        case calm, balanced, more
        var limit: Int { switch self { case .calm: 2; case .balanced: 3; case .more: 5 } }
        var title: String { switch self { case .calm: "Calm (2 at most)"; case .balanced: "Balanced (3)"; case .more: "More (5)" } }
    }

    var enabled = true
    var disabledCategories: [Suggestion.Category] = []
    var frequency = Frequency.calm
    var snoozeMinutes = 60
    var workspaceRecommendations = true
    var smartFocus = true
    /// Agents, workspace, focus and suggestions in the Daily Digest.
    var dailyBriefing = true
    /// The inspector's in-memory event log (and its log lines).
    var diagnostics = true

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let d = SuggestionPreferences()
        enabled = (try? container.decode(Bool.self, forKey: .enabled)) ?? d.enabled
        disabledCategories = ((try? container.decode([String].self, forKey: .disabledCategories)) ?? []).compactMap(Suggestion.Category.init(rawValue:))
        frequency = (try? container.decode(Frequency.self, forKey: .frequency)) ?? d.frequency
        snoozeMinutes = ((try? container.decode(Int.self, forKey: .snoozeMinutes)) ?? d.snoozeMinutes).clamped(to: 10 ... 1440)
        workspaceRecommendations = (try? container.decode(Bool.self, forKey: .workspaceRecommendations)) ?? d.workspaceRecommendations
        smartFocus = (try? container.decode(Bool.self, forKey: .smartFocus)) ?? d.smartFocus
        dailyBriefing = (try? container.decode(Bool.self, forKey: .dailyBriefing)) ?? d.dailyBriefing
        diagnostics = (try? container.decode(Bool.self, forKey: .diagnostics)) ?? d.diagnostics
    }
}

struct RankedSuggestion: Identifiable, Equatable, Sendable {
    let suggestion: Suggestion
    let score: Int
    /// How the score was made ("priority 92 · learning −4").
    let breakdown: String
    var id: String { suggestion.id }
}

struct SuppressedSuggestion: Identifiable, Equatable, Sendable {
    let suggestion: Suggestion
    let reason: String
    var id: String { suggestion.id }
}

enum SuggestionRanking {
    /// What to show, and everything held back with the reason. During a focus run only urgent ones (≥ 85) and focus's own show.
    static func rank(_ suggestions: [Suggestion], feedback: SuggestionFeedbackStore, preferences: SuggestionPreferences,
                     focusRunning: Bool, now: Date) -> (shown: [RankedSuggestion], suppressed: [SuppressedSuggestion]) {
        var kept: [RankedSuggestion] = []
        var suppressed: [SuppressedSuggestion] = []
        var seen = Set<String>()
        for suggestion in suggestions {
            guard seen.insert(suggestion.id).inserted else { continue }
            let reason: String? =
                !preferences.enabled ? "Suggestions are off"
                : preferences.disabledCategories.contains(suggestion.category) ? "\(suggestion.category.title) is turned off"
                : feedback.irrelevant.contains(suggestion.kind) ? "Marked not relevant"
                : feedback.dismissed[suggestion.id] != nil ? "Dismissed"
                : (feedback.snoozed[suggestion.id].map { $0 > now } ?? false) ? "Snoozed until \(feedback.snoozed[suggestion.id]!.formatted(date: .omitted, time: .shortened))"
                : (suggestion.expiresAt.map { $0 <= now } ?? false) ? "Expired"
                : focusRunning && suggestion.priority < 85 && !suggestion.kind.hasPrefix("focus.") ? "Held during your focus session"
                : nil
            if let reason {
                suppressed.append(SuppressedSuggestion(suggestion: suggestion, reason: reason))
                continue
            }
            let learning = feedback.adjustment(for: suggestion.kind)
            let breakdown = "priority \(suggestion.priority)" + (learning == 0 ? "" : " · learning \(learning > 0 ? "+" : "−")\(abs(learning))")
            kept.append(RankedSuggestion(suggestion: suggestion, score: suggestion.priority + learning, breakdown: breakdown))
        }
        kept.sort { $0.score != $1.score ? $0.score > $1.score : $0.suggestion.id < $1.suggestion.id }
        let limit = preferences.frequency.limit
        for extra in kept.dropFirst(limit) {
            suppressed.append(SuppressedSuggestion(suggestion: extra.suggestion, reason: "Beyond the \(limit) shown (score \(extra.score))"))
        }
        return (Array(kept.prefix(limit)), suppressed)
    }
}

/// What the user did with suggestions: local only (suggestions.json), cleared from Settings.
struct SuggestionFeedbackStore: Codable, Equatable, Sendable {
    struct Counts: Codable, Equatable, Sendable { var accepted = 0, dismissed = 0, snoozed = 0 }
    struct Entry: Codable, Equatable, Identifiable, Sendable {
        var id: String { "\(at.timeIntervalSinceReferenceDate)-\(title)" }
        let at: Date
        let title: String
        let outcome: String
    }

    var counts: [String: Counts] = [:]
    /// Instance ids dismissed (pruned after 14 days).
    var dismissed: [String: Date] = [:]
    var snoozed: [String: Date] = [:]
    /// Kinds marked "not relevant": never shown again until learning is reset.
    var irrelevant: Set<String> = []
    var history: [Entry] = []
    static let historyLimit = 50

    /// Learning: accepted kinds rise a little, dismissed and snoozed ones sink. Bounded so nothing urgent drops out.
    func adjustment(for kind: String) -> Int {
        guard let c = counts[kind] else { return 0 }
        return min(max(c.accepted * 3 - c.dismissed * 4 - c.snoozed * 2, -30), 12)
    }

    mutating func record(_ suggestion: Suggestion, outcome: String, at now: Date) {
        history.insert(Entry(at: now, title: suggestion.title, outcome: outcome), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    mutating func prune(now: Date) {
        dismissed = dismissed.filter { now.timeIntervalSince($0.value) < 14 * 86_400 }
        snoozed = snoozed.filter { $0.value > now }
    }
}

@MainActor @Observable
final class ContextEngine {
    private(set) var snapshot = ContextSnapshot()
    private(set) var shown: [RankedSuggestion] = []
    private(set) var suppressed: [SuppressedSuggestion] = []
    private(set) var events: [ContextEvent] = []
    private(set) var errors: [String: String] = [:]
    private(set) var lastUpdate: Date?
    private(set) var lastDuration: Duration = .zero
    private(set) var updates = 0
    var preferences = SuggestionPreferences() { didSet { if preferences != oldValue { refresh() } } }
    private(set) var stored: Persisted<SuggestionFeedbackStore>
    var feedback: SuggestionFeedbackStore { stored.value }
    @ObservationIgnored private(set) var memory = ContextMemory()
    @ObservationIgnored private(set) var sources: [ContextSource] = []
    /// Runs a suggestion's action (set by the app). Only ever called from a click.
    @ObservationIgnored var perform: @MainActor (Suggestion.Action) -> Void = { _ in }
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var pending: Task<Void, Never>?
    @ObservationIgnored private var wake: Task<Void, Never>?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var nextEventID = 0
    @ObservationIgnored private(set) var isRunning = false
    static let eventLimit = 80
    static let coalesce: Duration = .milliseconds(250)
    private static let log = Logger(subsystem: "com.awaneeshgupta.orbit", category: "context")

    init(file: JSONFile<SuggestionFeedbackStore>?, now: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        stored = file.map { Persisted($0, initial: SuggestionFeedbackStore()) } ?? Persisted(memory: SuggestionFeedbackStore())
        self.now = now
        self.calendar = calendar
    }

    /// Adds a provider (one per id; a later one replaces it).
    func register(_ source: ContextSource) {
        sources.removeAll { $0.id == source.id }
        sources.append(source)
        if isRunning { refresh() }
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true
        stored.update { $0.prune(now: now()) }
        refresh()
    }

    func stop() {
        isRunning = false
        generation += 1
        pending?.cancel()
        wake?.cancel()
    }

    /// Reads every source now (under observation: a later change schedules one coalesced refresh), diffs, rates.
    func refresh() {
        let clock = ContinuousClock()
        let started = clock.now
        generation += 1
        let registered = generation
        var fresh = ContextSnapshot()
        var failures: [String: String] = [:]
        withObservationTracking {
            for source in sources {
                do { try source.read(&fresh) } catch { failures[source.id] = String(describing: error) }
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.scheduleRefresh(registered) }
        }
        let time = now()
        for (id, message) in failures where errors[id] != message {
            record(source: id, kind: .error, text: "Couldn't read: \(message)", at: time)
        }
        errors = failures
        for change in ContextDiff.events(from: snapshot, to: fresh, now: time) { record(source: change.source, kind: .change, text: change.text, at: time) }
        remember(old: snapshot, new: fresh, at: time)
        if fresh != snapshot { snapshot = fresh }
        rate(at: time)
        lastUpdate = time
        updates += 1
        lastDuration = started.duration(to: clock.now)
        scheduleWake(after: time)
    }

    private func scheduleRefresh(_ registered: Int) {
        guard isRunning, registered == generation else { return }
        pending?.cancel()
        pending = Task { [weak self] in
            try? await Task.sleep(for: Self.coalesce)
            guard !Task.isCancelled, let self, self.isRunning, registered == self.generation else { return }
            self.refresh()
        }
    }

    /// Ranks again without re-reading (feedback or preferences changed, or a timer fired).
    private func rate(at time: Date) {
        let focusRunning: Bool = if case .running(let ends, _) = snapshot.focus { ends > time } else { false }
        let all = SuggestionRules.generate(snapshot, memory: memory, preferences: preferences, now: time, calendar: calendar)
        let ranked = SuggestionRanking.rank(all, feedback: feedback, preferences: preferences, focusRunning: focusRunning, now: time)
        let newIDs = Set(ranked.shown.map(\.id)).subtracting(shown.map(\.id))
        for item in ranked.shown where newIDs.contains(item.id) {
            record(source: "suggestions", kind: .suggestion, text: "Suggested “\(item.suggestion.title)” (\(item.breakdown))", at: time)
        }
        if ranked.shown != shown { shown = ranked.shown }
        if ranked.suppressed != suppressed { suppressed = ranked.suppressed }
    }

    /// Facts that need the previous state: the meeting that started (and the workspace then), a focus run that ended.
    private func remember(old: ContextSnapshot, new: ContextSnapshot, at time: Date) {
        if let cue = new.meeting, cue.phase == .started, memory.meeting?.id != cue.eventID {
            memory.meeting = (cue.eventID, cue.title, cue.end, old.workspace?.id ?? new.workspace?.id)
        }
        if case .running(let ends, let length) = new.focus { memory.focusRun = (ends.addingTimeInterval(-length), ends) }
        if let run = memory.focusRun, run.end <= time {
            let tasks = new.doneToday.filter { ($0.completedAt ?? .distantPast) >= run.start && ($0.completedAt ?? .distantFuture) <= run.end }.map(\.title)
            let agents = new.agents.filter { ($0.status == .completed || $0.status == .ended) && $0.lastEventAt >= run.start && $0.lastEventAt <= run.end }.map(\.name)
            memory.focusSummary = (run.end, Int((run.end.timeIntervalSince(run.start) / 60).rounded()), tasks, Array(Set(agents)).sorted())
            memory.focusRun = nil
            record(source: "focus", kind: .change, text: "Focus session ended: \(tasks.count) task(s), \(agents.count) agent finish(es) during it", at: time)
        }
    }

    /// The next moment something changes by itself: no polling in between.
    private func scheduleWake(after time: Date) {
        wake?.cancel()
        guard isRunning else { return }
        var moments: [Date] = shown.compactMap(\.suggestion.expiresAt) + feedback.snoozed.values.map { $0 }
        if let run = memory.focusRun { moments.append(run.end) }
        if let end = memory.meeting?.end { moments += [end, end.addingTimeInterval(900)] }
        if let summary = memory.focusSummary { moments.append(summary.end.addingTimeInterval(1800)) }
        if let evening = calendar.date(bySettingHour: SuggestionRules.eveningHour, minute: 0, second: 0, of: time) { moments.append(evening) }
        moments.append(calendar.startOfDay(for: time).addingTimeInterval(86_400))  // a new day
        guard let next = moments.filter({ $0 > time }).min() else { return }
        let registered = generation
        wake = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(time))), tolerance: .seconds(2))
            guard !Task.isCancelled, let self, self.isRunning, registered == self.generation else { return }
            self.refresh()
        }
    }

    // MARK: Feedback (explicit only)

    func accept(_ id: String, secondary: Bool = false) {
        guard let item = shown.first(where: { $0.id == id })?.suggestion else { return }
        stored.update {
            $0.counts[item.kind, default: .init()].accepted += 1
            $0.dismissed[item.id] = now()  // done: don't offer it again
            $0.record(item, outcome: "Accepted", at: now())
        }
        if let action = secondary ? item.secondary : item.primary { perform(action) }
        rate(at: now())
    }

    func dismiss(_ id: String) {
        guard let item = shown.first(where: { $0.id == id })?.suggestion else { return }
        stored.update {
            $0.counts[item.kind, default: .init()].dismissed += 1
            $0.dismissed[item.id] = now()
            $0.record(item, outcome: "Dismissed", at: now())
        }
        rate(at: now())
    }

    func snooze(_ id: String) {
        guard let item = shown.first(where: { $0.id == id })?.suggestion else { return }
        let until = now().addingTimeInterval(TimeInterval(preferences.snoozeMinutes * 60))
        stored.update {
            $0.counts[item.kind, default: .init()].snoozed += 1
            $0.snoozed[item.id] = until
            $0.record(item, outcome: "Snoozed", at: now())
        }
        rate(at: now())
        scheduleWake(after: now())
    }

    func markIrrelevant(_ id: String) {
        guard let item = shown.first(where: { $0.id == id })?.suggestion else { return }
        stored.update {
            $0.irrelevant.insert(item.kind)
            $0.record(item, outcome: "Not relevant", at: now())
        }
        rate(at: now())
    }

    func disableCategory(_ category: Suggestion.Category) {
        guard !preferences.disabledCategories.contains(category) else { return }
        preferences.disabledCategories.append(category)  // the app saves it to preferences
        onPreferencesChange?(preferences)
    }

    @ObservationIgnored var onPreferencesChange: (@MainActor (SuggestionPreferences) -> Void)?

    /// Settings › Suggestions › Reset: history, learning, dismissals, snoozes and "not relevant" all go.
    func resetLearning() {
        stored.update { $0 = SuggestionFeedbackStore() }
        rate(at: now())
    }

    /// An automation ran (Milestone 14 engine): shown in the inspector as an automation, never a suggestion.
    func noteAutomation(_ text: String) { record(source: "automations", kind: .automation, text: text, at: now()) }

    private func record(source: String, kind: ContextEvent.Kind, text: String, at time: Date) {
        guard preferences.diagnostics else { return }
        nextEventID += 1
        events.insert(ContextEvent(id: nextEventID, at: time, source: source, kind: kind, text: text), at: 0)
        if events.count > Self.eventLimit { events.removeLast(events.count - Self.eventLimit) }
        Self.log.debug("\(source, privacy: .public): \(text, privacy: .private)")
    }

    func clearEvents() { events = [] }
}

/// Changes worth an event (the same value twice is not a change).
enum ContextDiff {
    static func events(from old: ContextSnapshot, to new: ContextSnapshot, now: Date) -> [(source: String, text: String)] {
        var out: [(String, String)] = []
        if old.workspace?.id != new.workspace?.id { out.append(("workspaces", "Workspace: \(new.workspace?.name ?? "none")")) }
        let before = Dictionary(old.agents.map { ($0.key, $0.status) }, uniquingKeysWith: { a, _ in a })
        for agent in new.agents where before[agent.key] != agent.status {
            out.append(("aiHub", "\(agent.name)\(agent.project.map { " (\($0))" } ?? ""): \(agent.status.rawValue)"))
        }
        if old.meeting?.eventID != new.meeting?.eventID || old.meeting?.phase != new.meeting?.phase {
            out.append(("calendar", new.meeting.map { "Meeting “\($0.title)”: \($0.phase)" } ?? "No meeting in the heads-up window"))
        }
        if old.focus != new.focus { out.append(("focus", "Focus: \(describe(new.focus))")) }
        if old.battery?.chargeState != new.battery?.chargeState || (old.battery?.percent ?? 100 > 20) != (new.battery?.percent ?? 100 > 20) {
            out.append(("battery", new.battery.map { "Battery \($0.percent)%, \($0.chargeState)" } ?? "Battery unavailable"))
        }
        if old.energyHog != new.energyHog, let app = new.energyHog { out.append(("energy", "\(app) using High energy")) }
        if old.openTasks.count != new.openTasks.count { out.append(("tasks", "\(new.openTasks.count) open tasks")) }
        if (old.music == nil) != (new.music == nil) { out.append(("music", new.music == nil ? "Music stopped" : "Music playing")) }
        if old.displays != new.displays { out.append(("displays", "\(new.displays) display(s)" + (new.externalDisplay ? ", external connected" : ""))) }
        return out
    }

    static func describe(_ focus: ContextSnapshot.Focus) -> String {
        switch focus {
        case .unavailable: "unavailable"
        case .idle: "idle"
        case .resting: "break"
        case .running(let ends, _): "running until \(ends.formatted(date: .omitted, time: .shortened))"
        case .paused: "paused"
        }
    }
}
