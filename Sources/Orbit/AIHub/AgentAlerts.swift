import AppKit
import SwiftUI

// Agent alerts below the notch (Phase 10; docs/AI_HUB_SPEC.md §4 I). The
// lowest priority in the slot: shown only while it's free — no dashboard, no
// music island (compact or expanded), no volume HUD — and gone the moment any
// of them appears; and none at all while Coucou runs (NotchCoordination). It
// reads NotchOverlayCoordinator and changes nothing in it, so Music Island and
// Sonic Pulse keep their approved priorities.
// Simulated activity is labelled; Claude Code waiting is labelled inferred.

/// What the user chose for agent alerts (Milestone 14). Saved with the preferences.
struct AgentAlertRules: Codable, Equatable, Sendable {
    /// Agents whose alerts never show (raw agent IDs). Their activity still reaches the AI Hub.
    var mutedAgents: [String] = []
    var showFinished = true
    /// Quiet hours: only "needs you" alerts show (an agent blocked on you is work waiting).
    var quietHours = false
    /// Minutes after local midnight; the range may cross midnight (22:00–08:00).
    var quietStart = 22 * 60
    var quietEnd = 8 * 60
    /// A system sound for "needs you" and failures (off by default; never in quiet hours).
    var sound = false

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AgentAlertRules()
        mutedAgents = (try? container.decode([String].self, forKey: .mutedAgents)) ?? defaults.mutedAgents
        showFinished = (try? container.decode(Bool.self, forKey: .showFinished)) ?? defaults.showFinished
        quietHours = (try? container.decode(Bool.self, forKey: .quietHours)) ?? defaults.quietHours
        quietStart = ((try? container.decode(Int.self, forKey: .quietStart)) ?? defaults.quietStart).clamped(to: 0...1439)
        quietEnd = ((try? container.decode(Int.self, forKey: .quietEnd)) ?? defaults.quietEnd).clamped(to: 0...1439)
        sound = (try? container.decode(Bool.self, forKey: .sound)) ?? defaults.sound
    }

    func isQuiet(at date: Date, calendar: Calendar = .current) -> Bool {
        guard quietHours, quietStart != quietEnd else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        return quietStart < quietEnd ? (quietStart ..< quietEnd).contains(minute) : (minute >= quietStart || minute < quietEnd)
    }

    func isMuted(_ agent: AgentID) -> Bool { mutedAgents.contains(agent.rawValue) }
}

@MainActor @Observable
final class AgentAlerts {
    /// Most urgent first.
    enum Kind: Int, Comparable, Sendable {
        case needsYou, failed, finished
        static func < (a: Kind, b: Kind) -> Bool { a.rawValue < b.rawValue }
    }

    struct Alert: Equatable {
        let symbol: String
        let text: String
        let isSimulated: Bool
        /// Whose alert it is (its identity mark shows beside the text).
        var agent: AgentID? = nil
        var kind = Kind.finished
        /// Names in a grouped "finished" alert.
        var finished: [String] = []
        var postedAt = Date.distantPast

        static func == (a: Alert, b: Alert) -> Bool {
            a.symbol == b.symbol && a.text == b.text && a.isSimulated == b.isSimulated && a.agent == b.agent && a.kind == b.kind
        }
    }

    /// What became of an alert, for the history in Settings › AI Hub.
    struct Record: Equatable, Identifiable {
        enum Outcome: String, Sendable { case shown, grouped, muted, quiet, expired, dropped, hidden }
        let id: Int
        let text: String
        let kind: Kind
        let isSimulated: Bool
        let at: Date
        let outcome: Outcome
    }

    static let showFor: Duration = .seconds(4)
    static let maxQueued = 3
    /// "Finished" alerts per session at most this often (agents finish many turns).
    static let completionInterval: TimeInterval = 60
    /// A queued alert this old is stale by the time the slot frees: dropped.
    static let expiresAfter: TimeInterval = 30
    static let historyLimit = 30

    private(set) var current: Alert?
    /// Orbit's own Reduce Motion preference (the view also honours the system setting).
    var reduceMotion = false
    /// Either Orbit's preference or macOS's Reduce Motion.
    var effectiveReduceMotion: Bool { reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    private(set) var queue: [Alert] = []
    /// Recent alerts and what became of each, newest first. In memory only.
    private(set) var history: [Record] = []
    var rules = AgentAlertRules()
    /// Every real (not simulated) alert as it arrives, before the display rules: automations listen here.
    @ObservationIgnored var onAlert: (@MainActor (Kind) -> Void)?
    var isEnabled = true {
        didSet { if !isEnabled { clear() } }
    }
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private let playSound: @MainActor (Kind) -> Void
    @ObservationIgnored private var timer: (any HUDTimer)?
    @ObservationIgnored private var lastCompletion: [SessionKey: Date] = [:]
    @ObservationIgnored private var nextRecord = 0

    init(scheduler: any HUDScheduler, now: @escaping () -> Date = { .now },
         playSound: @escaping @MainActor (Kind) -> Void = { kind in NSSound(named: kind == .needsYou ? "Tink" : "Basso")?.play() }) {
        self.scheduler = scheduler
        self.now = now
        self.playSound = playSound
    }

    /// Events worth a glance: waiting for the user, failures, finished turns (throttled).
    func receive(_ events: [AgentEvent]) {
        for event in events {
            let id = event.session.agent
            let agent = AgentDiscovery.displayName(for: id)
            switch event.kind {
            case .waitingForUser:
                post(Alert(symbol: "hand.raised", text: "\(agent) is waiting for you", isSimulated: id.isDemo, agent: id, kind: .needsYou))
            case .error:
                post(Alert(symbol: "exclamationmark.triangle", text: "\(agent): \(event.summary ?? "failed")", isSimulated: id.isDemo, agent: id, kind: .failed))
            case .turnCompleted, .sessionEnded:
                if let last = lastCompletion[event.session], now().timeIntervalSince(last) < Self.completionInterval { continue }
                lastCompletion[event.session] = now()
                post(Alert(symbol: "checkmark.circle", text: "\(agent) finished", isSimulated: id.isDemo, agent: id, kind: .finished, finished: [agent]))
            default:
                continue
            }
        }
    }

    func receive(request draft: ApprovalDraft) {
        let agent = AgentDiscovery.displayName(for: draft.session.agent)
        post(Alert(symbol: draft.kind == .question ? "questionmark.bubble" : "lock.shield",
                   text: draft.kind == .question ? "\(agent) asks a question" : "\(agent) needs approval",
                   isSimulated: draft.session.agent.isDemo, agent: draft.session.agent, kind: .needsYou))
    }

    func clear() {
        timer?.cancel()
        timer = nil
        current = nil
        queue = []
    }

    private func post(_ incoming: Alert) {
        var alert = incoming
        alert.postedAt = now()
        if !alert.isSimulated { onAlert?(alert.kind) }
        guard isEnabled else { return record(alert, .hidden) }
        if let agent = alert.agent, rules.isMuted(agent) { return record(alert, .muted) }
        if alert.kind == .finished, !rules.showFinished { return record(alert, .muted) }
        let quiet = rules.isQuiet(at: alert.postedAt)
        if quiet, alert.kind != .needsYou { return record(alert, .quiet) }
        if current == nil {
            if rules.sound, !quiet, alert.kind != .finished { playSound(alert.kind) }
            return show(alert)
        }
        if current == alert || queue.contains(alert) { return }
        // Simultaneous finishes from different agents: one alert names them all.
        if alert.kind == .finished, let index = queue.firstIndex(where: { $0.kind == .finished && $0.isSimulated == alert.isSimulated }) {
            let names = queue[index].finished + alert.finished.filter { !queue[index].finished.contains($0) }
            queue[index] = Alert(symbol: "checkmark.circle", text: Self.finishedText(names), isSimulated: alert.isSimulated,
                                 agent: queue[index].agent, kind: .finished, finished: names, postedAt: alert.postedAt)
            return record(alert, .grouped)
        }
        // Most urgent first; when full, the least urgent (newest among equals) gives way.
        let at = queue.firstIndex { alert.kind < $0.kind } ?? queue.endIndex
        queue.insert(alert, at: at)
        if rules.sound, !quiet, alert.kind != .finished { playSound(alert.kind) }
        if queue.count > Self.maxQueued { record(queue.removeLast(), .dropped) }
    }

    static func finishedText(_ names: [String]) -> String {
        switch names.count {
        case 0, 1: "\(names.first ?? "An agent") finished"
        case 2: "\(names[0]) and \(names[1]) finished"
        default: "\(names[0]) and \(names.count - 1) others finished"
        }
    }

    private func record(_ alert: Alert, _ outcome: Record.Outcome) {
        nextRecord += 1
        history.insert(Record(id: nextRecord, text: alert.text, kind: alert.kind, isSimulated: alert.isSimulated, at: now(), outcome: outcome), at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
    }

    private func show(_ alert: Alert) {
        current = alert
        record(alert, .shown)
        // VoiceOver: the panel never takes focus, so announce it.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: (alert.isSimulated ? "Simulated: " : "") + alert.text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
        timer = scheduler.after(Self.showFor) { [weak self] in
            guard let self else { return }
            self.timer = nil
            self.current = nil
            self.showNext()
        }
    }

    private func showNext() {
        while !queue.isEmpty {
            let next = queue.removeFirst()
            if now().timeIntervalSince(next.postedAt) > Self.expiresAfter { record(next, .expired); continue }
            return show(next)
        }
    }
}

/// The capsule's window: the compact island's place, never interactive.
final class AgentAlertPanel: NSPanel {
    private let alerts: AgentAlerts
    private let slotIsFree: @MainActor () -> Bool
    private var generation = 0

    /// `slotIsFree`: NotchCoordination gives the agent alert the notch (it's last in line, and yields to Coucou).
    init(alerts: AgentAlerts, slotIsFree: @escaping @MainActor () -> Bool) {
        self.alerts = alerts
        self.slotIsFree = slotIsFree
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        animationBehavior = .none
        contentView = NSHostingView(rootView: AgentAlertView(alerts: alerts))
        reposition()
        follow(generation)
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let trigger = NotchGeometry.triggerRect(screen: screen.frame, visible: screen.visibleFrame,
                                                left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        let compact = MusicIslandGeometry.compactRect(trigger: trigger, screen: screen.frame)
        let width = max(compact.width, 260)
        setFrame(CGRect(x: compact.midX - width / 2, y: compact.minY, width: width, height: compact.height), display: isVisible)
    }

    func stop() {
        generation += 1
        orderOut(nil)
    }

    private func follow(_ registered: Int) {
        guard registered == generation else { return }
        let show = withObservationTracking {
            alerts.current != nil && slotIsFree()
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(registered) }
        }
        if show, !isVisible { orderFrontRegardless() } else if !show, isVisible { orderOut(nil) }
    }
}

struct AgentAlertView: View {
    let alerts: AgentAlerts

    var body: some View {
        let reduceMotion = alerts.effectiveReduceMotion
        ZStack {
            if let alert = alerts.current {
                HStack(spacing: 7) {
                    if let agent = alert.agent { AgentAvatar(agent: agent, size: 16) }
                    Image(systemName: alert.symbol).font(.system(size: 10, weight: .bold)).foregroundStyle(tint(alert))
                    Text(alert.text).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white.opacity(0.95)).lineLimit(1)
                    if alert.symbol == "hand.raised" { HubTag(text: "INFERRED", tint: HubTokens.attention) }
                    if alert.isSimulated { HubTag(text: "SIM", tint: .white.opacity(0.7)) }
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(.black, in: .rect(bottomLeadingRadius: 14, bottomTrailingRadius: 14))
                .transition(reduceMotion ? .opacity : .opacity.combined(with: .offset(y: -6)))
                .id(alert.text)
                .accessibilityElement(children: .combine)
                .accessibilityLabel(alert.isSimulated ? "Simulated: \(alert.text)" : alert.text)
            }
        }
        .animation(reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.28, bounce: 0.1), value: alerts.current)
    }

    private func tint(_ alert: AgentAlerts.Alert) -> Color {
        switch alert.symbol {
        case "exclamationmark.triangle": HubTokens.failure
        case "checkmark.circle": HubTokens.running
        default: HubTokens.attention
        }
    }
}
