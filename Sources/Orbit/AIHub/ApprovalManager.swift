import Foundation
import OrbitBridge

// The Approval Center (Phase 4; docs/AI_HUB_SPEC.md §4 C, §5, §8). Requests
// arrive from agents whose adapter can be answered (never Claude Code, D1);
// each is decided once, by the user, before it expires. Orbit never decides
// on its own, never "always allows" and never invents rules: no answer —
// expiry, Orbit quitting, the agent giving up — means the agent asks the
// user itself. Every outcome is recorded for the audit history.

@MainActor @Observable
final class ApprovalManager {
    struct Request: Identifiable, Equatable {
        let id = UUID()  // random: can't be guessed or reused
        let connection: Int
        let draft: ApprovalDraft
        var isSimulated: Bool { draft.session.agent.isDemo }
    }

    enum Outcome: String, Codable, Sendable {
        case allowed, denied, answered
        /// Not answered in time: the agent asked the user itself.
        case expired
        /// The agent stopped waiting (or the AI Hub was turned off).
        case withdrawn
    }

    struct Record: Identifiable, Equatable, Sendable {
        let id: UUID
        let draft: ApprovalDraft
        let outcome: Outcome
        let answer: String?
        let decidedAt: Date
    }

    static let historyLimit = 200

    private(set) var pending: [Request] = []
    private(set) var history: [Record] = []
    /// Sends a decision's output (nil: no answer) back on the request's connection.
    @ObservationIgnored var reply: ((Int, [String: JSONValue]?) -> Void)?
    /// The agent's own hook output for a decision (from its adapter).
    @ObservationIgnored var output: (ApprovalDecision, ApprovalDraft) -> [String: JSONValue]? = { _, _ in nil }
    /// Each outcome, for the audit table.
    @ObservationIgnored var onRecord: ((Record) -> Void)?
    /// Whether the request's adapter may be answered (§23; the bridge already refuses the rest — this is the second lock).
    @ObservationIgnored var supports: (ApprovalDraft) -> Bool = { _ in true }
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var timers: [UUID: any HUDTimer] = [:]

    init(scheduler: any HUDScheduler, now: @escaping () -> Date = { .now }) {
        self.scheduler = scheduler
        self.now = now
    }

    func add(connection: Int, draft: ApprovalDraft) {
        guard !pending.contains(where: { $0.connection == connection }) else { return }  // one request per connection
        guard supports(draft) else { reply?(connection, nil); return }  // not offered: the agent asks its user now
        let request = Request(connection: connection, draft: draft)
        let delay = max(0, draft.expiresAt.timeIntervalSince(now()))
        guard delay > 0 else { return finish(request, .expired, answer: nil, output: nil) }
        pending.append(request)
        timers[request.id] = scheduler.after(.milliseconds(Int64((delay * 1000).rounded(.up)))) { [weak self] in
            guard let self, let current = self.pending.first(where: { $0.id == request.id }) else { return }
            self.finish(current, .expired, answer: nil, output: nil)
        }
    }

    /// The user's decision. False (and nothing sent) if the request is gone,
    /// expired, already decided, or the answer isn't one of its options.
    @discardableResult
    func decide(_ id: UUID, _ decision: ApprovalDecision) -> Bool {
        guard let request = pending.first(where: { $0.id == id }), now() < request.draft.expiresAt, supports(request.draft),
              let output = output(decision, request.draft) else { return false }
        switch decision {
        case .allowOnce: finish(request, .allowed, answer: nil, output: output)
        case .deny: finish(request, .denied, answer: nil, output: output)
        case .answer(let text): finish(request, .answered, answer: text, output: output)
        case .answers(let answers):
            finish(request, .answered, answer: ApprovalQuestion.describe(answers, for: request.draft.questions), output: output)
        }
        return true
    }

    /// The request's connection closed before a decision.
    func withdrawn(connection: Int) {
        guard let request = pending.first(where: { $0.connection == connection }) else { return }
        finish(request, now() >= request.draft.expiresAt ? .expired : .withdrawn, answer: nil, output: nil, send: false)
    }

    /// The AI Hub is stopping: every waiting agent asks its user instead.
    func withdrawAll() {
        for request in pending { finish(request, .withdrawn, answer: nil, output: nil) }
    }

    private func finish(_ request: Request, _ outcome: Outcome, answer: String?, output: [String: JSONValue]?, send: Bool = true) {
        pending.removeAll { $0.id == request.id }
        timers.removeValue(forKey: request.id)?.cancel()
        if send { reply?(request.connection, output) }
        let record = Record(id: request.id, draft: request.draft, outcome: outcome, answer: answer, decidedAt: now())
        history.insert(record, at: 0)
        if history.count > Self.historyLimit { history.removeLast(history.count - Self.historyLimit) }
        onRecord?(record)
    }
}
