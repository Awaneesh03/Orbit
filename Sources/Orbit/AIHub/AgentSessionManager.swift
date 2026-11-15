import Foundation

// The session registry (docs/AI_HUB_SPEC.md §5, §14): every known session of
// one kind of agent (real or simulated: two separate registries, P1-2), its
// status and its latest events, for the UI. Main actor; bounded.

@MainActor @Observable
final class AgentSessionManager {
    static let staleAfter: TimeInterval = 30 * 60
    static let maxSessions = 500
    static let maxEventsPerSession = 100

    private(set) var sessions: [SessionKey: AgentSession] = [:]
    private(set) var recentEvents: [SessionKey: [AgentEvent]] = [:]

    /// Sessions whose status changed without an event (went stale), to be saved.
    @ObservationIgnored var onChange: (([AgentSession]) -> Void)?
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var staleTimer: (any HUDTimer)?

    init(scheduler: any HUDScheduler, now: @escaping () -> Date = { .now }) {
        self.scheduler = scheduler
        self.now = now
    }

    /// Most recently active first.
    var ordered: [AgentSession] { sessions.values.sorted { ($0.lastEventAt, $0.key.description) > ($1.lastEventAt, $1.key.description) } }
    var activeCount: Int { sessions.values.filter(\.status.isActive).count }
    var hasPendingTimer: Bool { staleTimer != nil }

    /// Sessions from the store at start; any active one that's gone quiet is stale.
    func load(_ stored: [AgentSession]) {
        for var session in stored.prefix(Self.maxSessions) where sessions[session.key] == nil {
            if session.status.isActive, now().timeIntervalSince(session.lastEventAt) >= Self.staleAfter { session.status = .stale }
            sessions[session.key] = session
        }
        scheduleStaleCheck()
    }

    /// Applies events in order; returns the sessions they changed.
    @discardableResult
    func apply(_ events: [AgentEvent]) -> [AgentSession] {
        var changed: [SessionKey: AgentSession] = [:]
        for event in events {
            let time = event.occurredAt ?? event.receivedAt
            var session = sessions[event.session] ?? AgentSession(
                key: event.session, title: nil, cwd: nil, model: nil, status: .running, startedAt: time, lastEventAt: time)
            // Hook helpers run concurrently: an event sent before the session ended can arrive after it.
            if let ended = session.endedAt, time < ended, event.kind != .sessionEnded {
                var recent = recentEvents[event.session, default: []]
                recent.append(event)
                recentEvents[event.session] = Array(recent.suffix(Self.maxEventsPerSession))
                continue
            }
            if let cwd = event.cwd {
                session.cwd = cwd
                session.title = session.title ?? (cwd as NSString).lastPathComponent
            }
            session.lastEventAt = max(session.lastEventAt, time)
            if let origin = event.origin {
                session.originBundleID = origin.bundleID ?? session.originBundleID
                session.originPID = origin.pid ?? session.originPID
            }
            switch event.kind {
            case .sessionEnded:
                session.status = .ended
                session.endedAt = time
            case .error:
                session.status = .failed
            case .turnCompleted:
                session.status = .idle
            case .waitingForUser:
                session.status = .waiting
            case .notification:
                break  // informational: doesn't change what the session is doing
            case .sessionStarted, .promptSubmitted, .toolStarted, .toolCompleted, .toolFailed, .fileChanged:
                session.status = .running
                session.endedAt = nil
            }
            sessions[event.session] = session
            changed[event.session] = session
            var recent = recentEvents[event.session, default: []]
            recent.append(event)
            if recent.count > Self.maxEventsPerSession { recent.removeFirst(recent.count - Self.maxEventsPerSession) }
            recentEvents[event.session] = recent
        }
        evict()
        scheduleStaleCheck()
        return Array(changed.values)
    }

    /// Forgets everything (demo data, or the AI Hub turned off).
    func clear() {
        sessions = [:]
        recentEvents = [:]
        stop()
    }

    func stop() {
        staleTimer?.cancel()
        staleTimer = nil
    }

    // MARK: Private

    /// Over the limit, the least recently active finished sessions go first, then any.
    private func evict() {
        guard sessions.count > Self.maxSessions else { return }
        let victims = sessions.values.sorted { ($0.status.isActive ? 1 : 0, $0.lastEventAt) < ($1.status.isActive ? 1 : 0, $1.lastEventAt) }
            .prefix(sessions.count - Self.maxSessions)
        for session in victims {
            sessions[session.key] = nil
            recentEvents[session.key] = nil
        }
    }

    /// One timer, for the next active session to go quiet (no polling).
    private func scheduleStaleCheck() {
        staleTimer?.cancel()
        staleTimer = nil
        guard let next = sessions.values.filter(\.status.isActive).map(\.lastEventAt).min() else { return }
        let delay = max(0, next.addingTimeInterval(Self.staleAfter).timeIntervalSince(now()))
        staleTimer = scheduler.after(.milliseconds(Int64((delay * 1000).rounded(.up)))) { [weak self] in self?.markStale() }
    }

    private func markStale() {
        staleTimer = nil
        var changed: [AgentSession] = []
        for (key, session) in sessions where session.status.isActive && now().timeIntervalSince(session.lastEventAt) >= Self.staleAfter {
            sessions[key]?.status = .stale
            changed.append(sessions[key]!)
        }
        if !changed.isEmpty { onChange?(changed) }
        scheduleStaleCheck()
    }
}
