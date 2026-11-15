import Foundation
import OrbitBridge

// Demo mode (docs/AI_HUB_SPEC.md §14, P1-2): two simulated agents that send
// made-up sessions through the real socket, exactly as a hook helper would,
// so the whole pipeline runs without a real agent. Their IDs are in the
// reserved `demo-` namespace, so their events land only in the demo registry
// and demo.sqlite; every summary says "Simulated", and the projects are under
// /Simulated (no such folder is touched or needed).

@MainActor
final class DemoAgents {
    struct Step {
        let kind: AgentEvent.Kind
        let tool: String?
        let summary: String?
        let files: [String]
    }

    static let agents: [(id: String, project: String)] = [("demo-alpha", "/Simulated/Atlas"), ("demo-beta", "/Simulated/Beacon")]

    /// One simulated session, then a new one.
    static func script(project: String) -> [Step] {
        [
            Step(kind: .sessionStarted, tool: nil, summary: "Simulated session started", files: []),
            Step(kind: .promptSubmitted, tool: nil, summary: "Simulated prompt: tidy up the settings screen", files: []),
            Step(kind: .toolStarted, tool: "Read", summary: "Simulated: reading SettingsView.swift", files: ["\(project)/SettingsView.swift"]),
            Step(kind: .toolCompleted, tool: "Read", summary: "Simulated: read 120 lines", files: []),
            Step(kind: .toolStarted, tool: "Edit", summary: "Simulated: editing SettingsView.swift", files: ["\(project)/SettingsView.swift"]),
            Step(kind: .fileChanged, tool: "Edit", summary: "Simulated: changed SettingsView.swift", files: ["\(project)/SettingsView.swift"]),
            Step(kind: .toolCompleted, tool: "Edit", summary: "Simulated: edit applied", files: []),
            Step(kind: .toolStarted, tool: "Bash", summary: "Simulated: running the tests", files: []),
            Step(kind: .toolFailed, tool: "Bash", summary: "Simulated: one test failed", files: []),
            Step(kind: .turnCompleted, tool: nil, summary: "Simulated turn finished", files: []),
            Step(kind: .sessionEnded, tool: nil, summary: "Simulated session ended", files: []),
        ]
    }

    let socketPath: String
    private let scheduler: any HUDScheduler
    private let interval: Duration
    private let send: @Sendable (AgentEnvelope, String) -> Void
    private var timer: (any HUDTimer)?
    private var tick = 0
    private(set) var sent = 0
    var isRunning: Bool { timer != nil }

    /// `send` runs off the main thread (a socket write can take up to 1 s).
    init(socketPath: String, scheduler: any HUDScheduler, interval: Duration = .milliseconds(2500),
         send: @escaping @Sendable (AgentEnvelope, String) -> Void = { envelope, path in
             DispatchQueue.global(qos: .utility).async { _ = AgentHookClient.send(envelope, socketPath: path) }
         }) {
        self.socketPath = socketPath
        self.scheduler = scheduler
        self.interval = interval
        self.send = send
    }

    func start() {
        guard timer == nil else { return }
        schedule()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    /// The envelopes for one tick: each agent advances one step, the second half a script behind.
    func envelopes(at tick: Int, now: Date = .now) -> [AgentEnvelope] {
        Self.agents.enumerated().compactMap { index, agent in
            let script = Self.script(project: agent.project)
            let position = tick + index * script.count / 2
            let step = script[position % script.count]
            var payload: [String: JSONValue] = [
                "session_id": .string("sim-\(position / script.count + 1)"), "event_id": .string(UUID().uuidString),
                "cwd": .string(agent.project), "files": .array(step.files.map { .string($0) }),
            ]
            if let tool = step.tool { payload["tool"] = .string(tool) }
            if let summary = step.summary { payload["summary"] = .string(summary) }
            return AgentEnvelope(agent: agent.id, event: step.kind.rawValue, sentAt: now, payload: payload)
        }
    }

    /// Every 8th tick a simulated permission request, every 8th (offset) a question: they wait for an answer in
    /// the Approval Center like a real agent would, and give up after a minute.
    func request(at tick: Int, now: Date = .now) -> AgentEnvelope? {
        guard tick % 8 == 3 || tick % 8 == 7 else { return nil }
        let isQuestion = tick % 8 == 7
        var payload: [String: JSONValue] = ["session_id": .string("sim-request-\(tick)"), "cwd": .string(Self.agents[1].project)]
        if isQuestion, tick % 16 == 15 {  // every other question is structured (§23)
            payload["summary"] = .string("Simulated questions: how should the demo be set up?")
            payload["questions"] = .array([
                .object(["header": .string("Database"), "question": .string("Which database should the demo use?"),
                         "options": .array([.object(["label": .string("SQLite"), "description": .string("One file, nothing to run")]),
                                            .object(["label": .string("Postgres"), "description": .string("Like production")])])]),
                .object(["header": .string("Extras"), "question": .string("What else should it set up?"), "multiSelect": .bool(true),
                         "options": .array([.string("Seed data"), .string("Indexes"), .string("Fixtures")])]),
            ])
        } else if isQuestion {
            payload["summary"] = .string("Simulated question: which database should the demo use?")
            payload["options"] = .array([.string("SQLite"), .string("Postgres"), .string("In memory")])
        } else {
            payload["tool"] = .string("Bash")
            payload["summary"] = .string("Simulated request: run the test suite (swift test)")
        }
        return AgentEnvelope(kind: .request, agent: Self.agents[1].id, event: isQuestion ? "questionAsked" : "permissionRequested",
                             sentAt: now, deadline: now.addingTimeInterval(60), payload: payload)
    }

    private func schedule() {
        timer = scheduler.after(interval) { [weak self] in
            guard let self, self.timer != nil else { return }
            if let request = self.request(at: self.tick) {
                let path = self.socketPath
                DispatchQueue.global(qos: .utility).async { _ = AgentHookClient.request(request, socketPath: path) }
            }
            for envelope in self.envelopes(at: self.tick) { self.send(envelope, self.socketPath) }
            self.sent += Self.agents.count
            self.tick += 1
            self.schedule()
        }
    }
}
