import Foundation
import Observation

// Light automations (Milestone 14): "when this happens, do that", from a
// fixed menu. Safe by construction:
// - Triggers are Orbit's own signals (the next meeting, the AI Hub's alerts).
//   Simulated agents never trigger anything.
// - Actions are a closed list of local, reversible things Orbit already does
//   (pause music, keep awake for an hour, start a focus session, open Calendar).
//   No shell, no scripts, no URLs, nothing taken from an agent's text.
// - Each rule runs at most once a minute (no loops), and every run or skip is
//   kept in a short history (memory only).

struct AutomationRule: Codable, Equatable, Identifiable, Sendable {
    enum Trigger: String, Codable, CaseIterable, Sendable {
        case meetingSoon, agentNeedsYou, agentFinished
        var title: String {
            switch self {
            case .meetingSoon: "A meeting is about to start"
            case .agentNeedsYou: "An agent needs you"
            case .agentFinished: "An agent finishes"
            }
        }
    }

    enum Condition: String, Codable, CaseIterable, Sendable {
        case always, weekdays, musicPlaying, onBattery, notDuringFocus
        var title: String {
            switch self {
            case .always: "Any time"
            case .weekdays: "On weekdays"
            case .musicPlaying: "While music plays"
            case .onBattery: "While on battery"
            case .notDuringFocus: "Not during a focus session"
            }
        }
    }

    enum Action: String, Codable, CaseIterable, Sendable {
        case pauseMusic, keepAwakeHour, startFocus, openCalendar
        var title: String {
            switch self {
            case .pauseMusic: "Pause music"
            case .keepAwakeHour: "Keep the Mac awake for an hour"
            case .startFocus: "Start a focus session"
            case .openCalendar: "Open Calendar"
            }
        }
    }

    var id = UUID()
    var trigger: Trigger
    var condition = Condition.always
    var action: Action
    var isEnabled = true

    /// Rules saved by a newer Orbit (an unknown trigger or action) are skipped, never fatal.
    static func decodeList<Key: CodingKey>(_ container: KeyedDecodingContainer<Key>, forKey key: Key) -> [AutomationRule]? {
        (try? container.decode([Lossy].self, forKey: key))?.compactMap(\.rule)
    }

    private struct Lossy: Decodable {
        let rule: AutomationRule?
        init(from decoder: any Decoder) throws { rule = try? AutomationRule(from: decoder) }
    }
}

@MainActor @Observable
final class Automations {
    struct Run: Identifiable, Equatable {
        enum Outcome: Equatable { case done, skipped(String) }
        let id: Int
        let text: String
        let at: Date
        let outcome: Outcome
        /// Why it fired (Milestone 17), e.g. "Design review starts in 4 min".
        var reason = ""
    }

    /// From the Context Engine's snapshot (Milestone 17): the same picture the suggestions see.
    struct Context {
        var musicPlaying = false
        var onBattery = false
        var focusRunning = false
    }

    static let cooldown: TimeInterval = 60
    static let historyLimit = 30

    var rules: [AutomationRule] = []
    private(set) var history: [Run] = []
    /// Does it; false when there was nothing to do (no music playing, a focus session already running…).
    @ObservationIgnored private let perform: @MainActor (AutomationRule.Action) -> Bool
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let calendar: Calendar
    @ObservationIgnored private var lastRun: [UUID: Date] = [:]
    @ObservationIgnored private var nextID = 0
    /// Every run or skip, for the Context Inspector (labelled as an automation, never a suggestion).
    @ObservationIgnored var onRun: (@MainActor (Run) -> Void)?

    init(perform: @escaping @MainActor (AutomationRule.Action) -> Bool, now: @escaping () -> Date = { .now }, calendar: Calendar = .current) {
        self.perform = perform
        self.now = now
        self.calendar = calendar
    }

    /// Whether any enabled rule listens for `trigger` (e.g. the meeting watcher runs for one).
    func listens(for trigger: AutomationRule.Trigger) -> Bool { rules.contains { $0.isEnabled && $0.trigger == trigger } }

    func fire(_ trigger: AutomationRule.Trigger, context: Context, reason: String = "") {
        let time = now()
        for rule in rules where rule.isEnabled && rule.trigger == trigger {
            let text = "\(rule.trigger.title) → \(rule.action.title)"
            if let last = lastRun[rule.id], time.timeIntervalSince(last) < Self.cooldown {
                record(text, .skipped("ran less than a minute ago"), reason)
                continue
            }
            switch rule.condition {
            case .always: break
            case .weekdays where calendar.isDateInWeekend(time): record(text, .skipped("weekend"), reason); continue
            case .musicPlaying where !context.musicPlaying: record(text, .skipped("no music playing"), reason); continue
            case .onBattery where !context.onBattery: record(text, .skipped("on power"), reason); continue
            case .notDuringFocus where context.focusRunning: record(text, .skipped("focus session running"), reason); continue
            default: break
            }
            lastRun[rule.id] = time
            record(text, perform(rule.action) ? .done : .skipped("nothing to do"), reason)
        }
    }

    private func record(_ text: String, _ outcome: Run.Outcome, _ reason: String = "") {
        nextID += 1
        let run = Run(id: nextID, text: text, at: now(), outcome: outcome, reason: reason)
        onRun?(run)
        history.insert(run, at: 0)
        if history.count > Self.historyLimit { history.removeLast() }
    }
}
