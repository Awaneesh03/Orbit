import Foundation

// The main-actor half of the pipeline (docs/AI_HUB_SPEC.md §2, §14): takes
// the bridge's batches of already-normalised events, drops duplicates, sends
// real and simulated events to their own registries and stores (P1-2, S4),
// and keeps health. No parsing happens here (P1-4).

/// What the Settings pane shows about the bridge, the stores and each agent.
@MainActor @Observable
final class AgentHealth {
    enum Bridge: Equatable {
        case off
        case listening
        case failed(String)
    }

    var bridge = Bridge.off
    var store = HubStore.Health.closed
    var demoStore = HubStore.Health.closed
    private(set) var counters = AgentBridgeServer.Counters()
    private(set) var duplicates = 0
    /// Writes dropped because the store couldn't keep up (bounded memory).
    private(set) var unsavedEvents = 0
    /// Real agents only: simulated activity never counts as an agent's.
    private(set) var lastEvent: [AgentID: Date] = [:]
    private(set) var eventCounts: [AgentID: Int] = [:]

    /// Nothing saved, or the bridge couldn't start.
    var isDegraded: Bool {
        if case .failed = bridge { return true }
        if case .degraded = store { return true }
        return false
    }

    func record(_ counters: AgentBridgeServer.Counters, duplicates: Int) {
        self.counters += counters
        self.duplicates += duplicates
    }

    func record(realEvents events: [AgentEvent]) {
        for event in events {
            lastEvent[event.session.agent] = max(lastEvent[event.session.agent] ?? .distantPast, event.receivedAt)
            eventCounts[event.session.agent, default: 0] += 1
        }
    }

    func recordUnsaved(_ count: Int) { unsavedEvents += count }

    func reset() {
        counters = AgentBridgeServer.Counters()
        duplicates = 0
        unsavedEvents = 0
        lastEvent = [:]
        eventCounts = [:]
    }
}

/// Serialises writes to one store: at most one in flight; what arrives
/// meanwhile is merged and written next. Bounded (oldest events dropped and
/// counted); a store that's degraded or closed just doesn't save.
@MainActor
final class StoreWriter {
    static let maxPendingEvents = 5000
    let store: HubStore
    private var sessions: [SessionKey: AgentSession] = [:]
    private var events: [AgentEvent] = []
    private var inFlight: Task<Void, Never>?
    private let report: (HubStore.Health, _ dropped: Int) -> Void

    init(store: HubStore, report: @escaping (HubStore.Health, Int) -> Void) {
        self.store = store
        self.report = report
    }

    var isIdle: Bool { inFlight == nil && sessions.isEmpty && events.isEmpty }

    func enqueue(sessions changed: [AgentSession], events new: [AgentEvent]) {
        for session in changed { sessions[session.key] = session }
        events.append(contentsOf: new)
        var dropped = 0
        if events.count > Self.maxPendingEvents {
            dropped = events.count - Self.maxPendingEvents
            events.removeFirst(dropped)
        }
        if dropped > 0 { report(.degraded("History couldn't keep up; some events weren't saved"), dropped) }
        flush()
    }

    /// Waits until everything enqueued so far is written (tests, shutdown).
    func drain() async {
        while let task = inFlight { await task.value }
    }

    func discard() {
        sessions = [:]
        events = []
    }

    private func flush() {
        guard inFlight == nil, !sessions.isEmpty || !events.isEmpty else { return }
        let batchSessions = Array(sessions.values)
        let batchEvents = events
        sessions = [:]
        events = []
        let store = store
        inFlight = Task { [weak self] in
            let health = await store.save(sessions: batchSessions, events: batchEvents)
            guard let self else { return }
            self.inFlight = nil
            self.report(health, 0)
            self.flush()
        }
    }
}

@MainActor
final class AgentEventRouter {
    static let dedupeWindow: TimeInterval = 5
    static let maxRememberedKeys = 10_000

    let real: AgentSessionManager
    let demo: AgentSessionManager
    let health: AgentHealth
    var realWriter: StoreWriter?
    var demoWriter: StoreWriter?
    private var seen: [String: Date] = [:]
    private let now: () -> Date

    init(real: AgentSessionManager, demo: AgentSessionManager, health: AgentHealth, now: @escaping () -> Date = { .now }) {
        self.real = real
        self.demo = demo
        self.health = health
        self.now = now
        real.onChange = { [weak self] in self?.realWriter?.enqueue(sessions: $0, events: []) }
        demo.onChange = { [weak self] in self?.demoWriter?.enqueue(sessions: $0, events: []) }
    }

    func receive(_ batch: AgentBridgeServer.Batch) {
        let time = now()
        if seen.count > Self.maxRememberedKeys / 2 { seen = seen.filter { time.timeIntervalSince($0.value) < Self.dedupeWindow } }
        var fresh: [AgentEvent] = []
        var duplicates = 0
        for event in batch.events {
            if let last = seen[event.dedupeKey], time.timeIntervalSince(last) < Self.dedupeWindow {
                duplicates += 1
                continue
            }
            if seen.count < Self.maxRememberedKeys { seen[event.dedupeKey] = time }
            fresh.append(event)
        }
        health.record(batch.counters, duplicates: duplicates)
        let realEvents = fresh.filter { !$0.session.agent.isDemo }
        let demoEvents = fresh.filter { $0.session.agent.isDemo }
        if !realEvents.isEmpty {
            health.record(realEvents: realEvents)
            realWriter?.enqueue(sessions: real.apply(realEvents), events: realEvents)
        }
        if !demoEvents.isEmpty {
            demoWriter?.enqueue(sessions: demo.apply(demoEvents), events: demoEvents)
        }
    }

    func reset() { seen = [:] }
}
