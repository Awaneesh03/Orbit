import Foundation
import Synchronization
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phase 4: the Approval Center, with simulated agents only (real agents
// need their hooks installed — an approval gate — and Claude Code is never
// answered, D1). Real sockets and SQLite in throwaway folders.

private func request(_ event: String = "permissionRequested", agent: String = "demo-beta", wait: TimeInterval = 30,
                     extra: [String: JSONValue] = [:]) -> AgentEnvelope {
    var payload: [String: JSONValue] = ["session_id": .string("r1"), "tool": .string("Bash"), "summary": .string("Run tests")]
    payload.merge(extra) { $1 }
    return AgentEnvelope(kind: .request, agent: agent, event: event, sentAt: .now, deadline: .now + wait, payload: payload)!
}

@Test func requestsFollowStricterRulesAndNeverComeFromClaude() throws {
    #expect(AgentEnvelope(kind: .request, agent: "claude-code", event: "PermissionRequest", sentAt: .now, deadline: .now + 30, payload: [:]) == nil)
    #expect(AgentEnvelope(kind: .request, agent: "codex", event: "PermissionRequest", sentAt: .now, payload: [:]) == nil)  // no deadline
    #expect(AgentEnvelope(kind: .request, agent: "codex", event: "PermissionRequest", sentAt: .now, deadline: .now + 601, payload: [:]) == nil)
    #expect(AgentEnvelope(agent: "codex", event: "Stop", sentAt: .now, deadline: .now + 5, payload: [:]) == nil)  // hooks have none
    let original = request()
    let decoded = try AgentEnvelope.decode(original.encoded())
    #expect(decoded == original && decoded.kind == .request && decoded.deadline != nil)
    var object = try #require(try JSONSerialization.jsonObject(with: original.encoded()) as? [String: Any])
    object["agent"] = "claude-code"
    #expect(throws: AgentEnvelopeError.self) { try AgentEnvelope.decode(JSONSerialization.data(withJSONObject: object)) }
    object["agent"] = "demo-beta"
    object["deadline"] = nil
    #expect(throws: AgentEnvelopeError.self) { try AgentEnvelope.decode(JSONSerialization.data(withJSONObject: object)) }
}

@Test func decisionsRoundTripAndPrintOnlyValidOutput() throws {
    let allow = AgentDecision(output: ["decision": .string("allow")])
    #expect(try AgentDecision.decode(allow.encoded()) == allow)
    #expect(allow.printable == Data("{\"decision\":\"allow\"}\n".utf8))
    let none = AgentDecision(output: nil)
    #expect(try AgentDecision.decode(none.encoded()) == none && none.printable == nil)
    #expect(throws: AgentEnvelopeError.self) { try AgentDecision.decode(Data(#"{"v":1,"type":"hook","output":null}"#.utf8)) }
}

@Test func claudeCodeNeverWaitsEvenWhenAskedTo() {
    var printed: [Data] = []
    let start = ContinuousClock.now
    let status = AgentHookClient.main(arguments: ["--agent", "claude-code", "--event", "PermissionRequest", "--wait", "30"],
                                      input: -1, stdinIsTerminal: false, environment: [:], parentPID: 1,
                                      socketPath: "/nonexistent/a.sock", writeError: { _ in }, writeOutput: { printed.append($0) })
    #expect(status == 0 && printed.isEmpty && ContinuousClock.now - start < .seconds(3))  // a plain hook, never an answer
}

// MARK: Manager

@MainActor @Test func decisionsAreSingleUseAndAnswersMustBeOffered() throws {
    let scheduler = FakeScheduler()
    var clock = Date(timeIntervalSince1970: 1000)
    let manager = ApprovalManager(scheduler: scheduler, now: { clock })
    manager.output = { OrbitEventAdapter.demo.output(for: $0, to: $1) }
    var replies: [(Int, [String: JSONValue]?)] = []
    var records: [ApprovalManager.Record] = []
    manager.reply = { replies.append(($0, $1)) }
    manager.onRecord = { records.append($0) }
    let session = SessionKey(agent: AgentID("demo-beta")!, nativeID: "r1")!
    func draft(_ kind: ApprovalDraft.Kind, options: [String] = []) -> ApprovalDraft {
        ApprovalDraft(session: session, kind: kind, nativeName: "x", tool: nil, summary: "s", options: options,
                      createdAt: clock, expiresAt: clock + 30)
    }
    manager.add(connection: 1, draft: draft(.permission))
    manager.add(connection: 1, draft: draft(.permission))  // a duplicate on the same connection
    #expect(manager.pending.count == 1)
    let first = try #require(manager.pending.first)
    #expect(manager.decide(first.id, .allowOnce) && !manager.decide(first.id, .deny))  // once only
    #expect(replies.count == 1 && replies[0].1 == ["decision": .string("allow")] && records.map(\.outcome) == [.allowed])

    manager.add(connection: 2, draft: draft(.question, options: ["SQLite", "Postgres"]))
    let question = try #require(manager.pending.first)
    #expect(!manager.decide(question.id, .answer("MongoDB")) && !manager.decide(question.id, .allowOnce))  // not an offered answer
    #expect(manager.decide(question.id, .answer("SQLite")) && records.last?.answer == "SQLite")

    manager.add(connection: 3, draft: draft(.permission))
    clock += 31
    scheduler.advance(.seconds(31))
    #expect(manager.pending.isEmpty && records.last?.outcome == .expired && replies.last?.0 == 3 && replies.last?.1 == nil)

    manager.add(connection: 4, draft: draft(.permission))
    manager.withdrawn(connection: 4)  // the agent stopped waiting
    #expect(records.last?.outcome == .withdrawn && replies.last?.0 == 3)  // nothing sent to a closed connection
    manager.add(connection: 5, draft: draft(.permission))
    manager.withdrawAll()
    #expect(manager.pending.isEmpty && records.last?.outcome == .withdrawn && manager.history.count == 5)
}

// MARK: End to end

@MainActor private func service(_ temp: TemporaryDirectory, _ folder: URL, scheduler: FakeScheduler) -> AIHubService {
    AIHubService(paths: .init(socket: folder.appending(path: "a.sock").path(percentEncoded: false),
                              store: temp.url.appending(path: "hub.sqlite"), demoStore: temp.url.appending(path: "demo.sqlite")),
                 scheduler: scheduler, discover: { [] })
}

@MainActor @Test func aDecisionTravelsBackToTheWaitingHelper() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = FileManager.default.temporaryDirectory.appending(path: "oq-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let hub = service(temp, folder, scheduler: FakeScheduler())
    hub.set(enabled: true, demo: true)
    await hub.settled()
    let answers = Mutex<[AgentDecision?]>([])
    let path = hub.paths.socket
    for envelope in [request(), request("questionAsked", extra: ["options": .array([.string("SQLite"), .string("Postgres")])])] {
        DispatchQueue.global().async {
            let decision = AgentHookClient.request(envelope, socketPath: path)
            answers.withLock { $0.append(decision) }
        }
    }
    for _ in 0 ..< 300 where hub.approvals.pending.count < 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(hub.approvals.pending.count == 2 && hub.approvals.pending.allSatisfy(\.isSimulated))
    for request in hub.approvals.pending {
        #expect(hub.approvals.decide(request.id, request.draft.kind == .question ? .answer("Postgres") : .allowOnce))
    }
    for _ in 0 ..< 300 where answers.withLock({ $0.count }) < 2 { try await Task.sleep(for: .milliseconds(10)) }
    let outputs = answers.withLock { $0 }.compactMap { $0?.output }
    let allow: [String: JSONValue] = ["decision": .string("allow")]
    let answer: [String: JSONValue] = ["answer": .string("Postgres")]
    #expect(outputs.count == 2 && outputs.contains(allow) && outputs.contains(answer))
    hub.set(enabled: false, demo: false)
    await hub.settled()
    let demoStore = HubStore(url: hub.paths.demoStore)
    await demoStore.open()
    #expect(await demoStore.approvals().map(\.outcome).sorted() == ["allowed", "answered"])  // audited, in the demo store
    await demoStore.close()
}

@MainActor @Test func turningTheHubOffLetsWaitingAgentsAskTheirUser() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = FileManager.default.temporaryDirectory.appending(path: "ow-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let hub = service(temp, folder, scheduler: FakeScheduler())
    hub.set(enabled: true, demo: true)
    await hub.settled()
    let result = Mutex<(done: Bool, decision: AgentDecision?)>((false, nil))
    let path = hub.paths.socket
    let envelope = request()
    DispatchQueue.global().async {
        let decision = AgentHookClient.request(envelope, socketPath: path)
        result.withLock { $0 = (true, decision) }
    }
    for _ in 0 ..< 300 where hub.approvals.pending.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    hub.set(enabled: false, demo: false)
    await hub.settled()
    for _ in 0 ..< 300 where !result.withLock({ $0.done }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(result.withLock { $0.done && $0.decision?.output == nil })  // no answer: the agent asks its user
    #expect(hub.approvals.history.first?.outcome == .withdrawn)
}
