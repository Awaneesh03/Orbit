import Darwin
import Foundation
import Synchronization
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phase 1, steps 5–6: the bridge server (real sockets in short temporary
// folders), the router, the session registry, adapters, redaction, discovery.

private func socketPath() -> (path: String, cleanup: () -> Void) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "op-\(UUID().uuidString.prefix(8))")
    return (folder.appending(path: "a.sock").path(percentEncoded: false), { try? FileManager.default.removeItem(at: folder) })
}

/// Collects what the server delivers, from its queue.
private final class Inbox: Sendable {
    private let state = Mutex<(batches: [AgentBridgeServer.Batch], offMain: Bool)>(([], true))
    func add(_ batch: AgentBridgeServer.Batch) {
        let offMain = !Thread.isMainThread
        state.withLock { $0.batches.append(batch); $0.offMain = $0.offMain && offMain }
    }
    var batches: [AgentBridgeServer.Batch] { state.withLock { $0.batches } }
    var events: [AgentEvent] { batches.flatMap(\.events) }
    var deliveredOffMain: Bool { state.withLock { $0.offMain } }
    var counters: AgentBridgeServer.Counters {
        batches.reduce(into: AgentBridgeServer.Counters()) { $0 += $1.counters }
    }
}

/// Waits (real time, 3 s at most) for a socket-driven condition.
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func demoEnvelope(_ kind: AgentEvent.Kind, session: String = "s1", agent: String = "demo-alpha",
                          extra: [String: JSONValue] = [:], at time: Date = .now) -> AgentEnvelope {
    var payload: [String: JSONValue] = ["session_id": .string(session), "event_id": .string(UUID().uuidString)]
    payload.merge(extra) { $1 }
    return AgentEnvelope(agent: agent, event: kind.rawValue, sentAt: time, payload: payload)!
}

@discardableResult
private func send(_ envelopes: [AgentEnvelope], to path: String) async -> [AgentHookClient.Outcome] {
    await withCheckedContinuation { (done: CheckedContinuation<[AgentHookClient.Outcome], Never>) in
        DispatchQueue.global().async {
            done.resume(returning: envelopes.map { AgentHookClient.send($0, socketPath: path) })
        }
    }
}

private func server(_ path: String, _ inbox: Inbox, limits: AgentBridgeServer.Limits = .init()) -> AgentBridgeServer {
    AgentBridgeServer(path: path, registry: .phaseOne, limits: limits, deliver: { inbox.add($0) })
}

// MARK: Redaction and adapters

@Test func secretsAreRedactedFromEverythingShownOrStored() {
    let cases = [
        "export OPENAI_API_KEY=sk-proj-abcdefghijklmnop1234": "export OPENAI_API_KEY=[redacted]",
        "curl -H 'Authorization: Bearer abc.def.ghi' x": "curl -H 'Authorization: [redacted]' x",
        "auth bearer abc.def.ghi": "auth bearer [redacted]",
        "token: ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ012345": "token: [redacted]",
        "aws AKIAABCDEFGHIJKLMNOP done": "aws [redacted] done",
        "password=hunter2 next": "password=[redacted] next",
        "slack xoxb-1234567890-abcdef": "slack [redacted]",
        "-----BEGIN RSA PRIVATE KEY-----": "[redacted]",
        "nothing secret here": "nothing secret here",
    ]
    for (input, expected) in cases {
        #expect(!Redactor.redact(input).contains("sk-proj") && !Redactor.redact(input).contains("hunter2"))
        #expect(Redactor.redact(input) == expected, "\(input)")
    }
    #expect(!Redactor.redact("Authorization: Bearer abc.def.ghi").contains("abc.def"))
    #expect(Redactor.line("first\nsecond\t\u{0}third   fourth", limit: 100) == "first second third fourth")
    #expect(Redactor.line(String(repeating: "a", count: 300), limit: 10) == "aaaaaaaaa…")
    #expect(Redactor.line("  \n ", limit: 10) == nil)
}

@Test func orbitEventsAreNormalisedAndSanitised() throws {
    let adapter = OrbitEventAdapter.demo
    let agent = try #require(AgentID("demo-alpha"))
    let claude = try #require(AgentID("claude-code"))
    #expect(adapter.accepts(agent) && !adapter.accepts(claude))
    let envelope = demoEnvelope(.fileChanged, extra: [
        "cwd": .string("/Sim/Atlas/./src/.."), "tool": .string("Edit\nfile"), "summary": .string("Set token=abc123secret"),
        "files": .array([.string("/Sim/Atlas/a.swift"), .string("relative.swift"), .number(3), .string("/Sim/../etc/x")]),
        "event_id": .string("e-1"),
    ])
    let events = adapter.normalise(envelope, agent: agent, receivedAt: .now)
    let event = try #require(events.first)
    #expect(events.count == 1 && event.kind == .fileChanged && event.session.description == "demo-alpha:s1")
    #expect(event.cwd == "/Sim/Atlas" && event.tool == "Edit file" && event.summary == "Set token=[redacted]")
    #expect(event.files == ["/Sim/Atlas/a.swift", "/etc/x"] && event.dedupeKey == "demo-alpha:s1|fileChanged|e-1")
    // Unattributable: no session, or an event name outside the vocabulary.
    #expect(adapter.normalise(AgentEnvelope(agent: "demo-alpha", event: "toolStarted", sentAt: .now, payload: [:])!,
                              agent: agent, receivedAt: .now).isEmpty)
    #expect(adapter.normalise(AgentEnvelope(agent: "demo-alpha", event: "PreToolUse", sentAt: .now,
                                            payload: ["session_id": .string("s")])!, agent: agent, receivedAt: .now).isEmpty)
    #expect(AgentRegistry.phaseOne.adapter(for: claude) == nil)  // no real adapters in Phase 1
}

@Test func discoveryLooksOnlyAtKnownPaths() {
    var asked: [String] = []
    let found = AgentDiscovery.scan(home: URL(filePath: "/Users/me")) { path in
        asked.append(path)
        return ["/Users/me/.local/bin/claude", "/opt/homebrew/bin/copilot", "/Applications/Cursor.app"].contains(path)
    }
    #expect(found.map(\.id) == ["claude-code", "codex", "copilot-cli", "cursor", "antigravity", "gemini-cli", "opencode"])
    #expect(found.filter(\.isInstalled).map(\.path) == ["/Users/me/.local/bin/claude", "/opt/homebrew/bin/copilot", "/Applications/Cursor.app"])
    #expect(asked.allSatisfy { $0.hasPrefix("/") } && asked.contains("/Users/me/.opencode/bin/opencode"))
    #expect(!AgentDiscovery.installed("/nonexistent/agent"))
}

// MARK: The server

@Test func theServerDeliversNormalisedEventsOffTheMainThread() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let inbox = Inbox()
    let bridge = server(path, inbox)
    try bridge.start()
    let folder = (path as NSString).deletingLastPathComponent
    #expect(try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int == 0o600)
    #expect(try FileManager.default.attributesOfItem(atPath: folder)[.posixPermissions] as? Int == 0o700)
    await send([demoEnvelope(.sessionStarted), demoEnvelope(.toolStarted, extra: ["tool": .string("Read")])], to: path)
    #expect(await eventually { inbox.events.count == 2 })
    #expect(inbox.deliveredOffMain && inbox.counters.accepted == 2)
    #expect(inbox.events.map(\.kind) == [.sessionStarted, .toolStarted])
    bridge.stop()
    #expect(!FileManager.default.fileExists(atPath: path) && !bridge.isListening)
    #expect(AgentHookClient.send(demoEnvelope(.toolCompleted), socketPath: path) == .orbitUnavailable)
    try bridge.start()  // restartable
    await send([demoEnvelope(.toolCompleted)], to: path)
    #expect(await eventually { inbox.events.count == 3 })
    bridge.stop()
}

@Test func invalidAndUnattributableInputIsCountedNeverDelivered() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let inbox = Inbox()
    let bridge = server(path, inbox)
    try bridge.start()
    defer { bridge.stop() }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            for bytes in [Data("garbage".utf8), BridgeFraming.frame(Data("{\"v\":2}".utf8)), Data([0, 0, 0, 0])] {
                if let fd = try? UnixSocket.connect(to: path) {
                    _ = UnixSocket.writeAll(fd, bytes)
                    close(fd)
                }
            }
            done.resume()
        }
    }
    await send([AgentEnvelope(agent: "claude-code", event: "Stop", sentAt: .now, payload: ["session_id": .string("x")])!,  // no adapter yet
                demoEnvelope(.toolStarted, session: "")],  // no session
               to: path)
    #expect(await eventually { inbox.counters.invalid == 3 && inbox.counters.unattributed == 2 })
    #expect(inbox.events.isEmpty && inbox.counters.accepted == 0)
}

@Test func connectionsAreLimitedAndIdleOnesClosed() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let inbox = Inbox()
    let bridge = server(path, inbox, limits: .init(maxConnections: 4, idleTimeout: 0.2))
    try bridge.start()
    defer { bridge.stop() }
    let held = (0 ..< 6).compactMap { _ in try? UnixSocket.connect(to: path) }  // connect, never send
    defer { held.forEach { close($0) } }
    #expect(await eventually { inbox.counters.refusedConnections == 2 })
    #expect(await eventually { bridge.connectionCount == 0 })  // the silent four timed out
    await send([demoEnvelope(.sessionStarted)], to: path)  // and the server still works
    #expect(await eventually { inbox.events.count == 1 })
}

@Test func aFloodIsRateLimitedBatchedAndBounded() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let inbox = Inbox()
    let bridge = server(path, inbox, limits: .init(maxFramesPerConnection: 2000, eventsPerSecond: 200))
    try bridge.start()
    defer { bridge.stop() }
    // 1,000 frames on one connection: the rate limit, not accepting, is what's tested.
    let frames = (0 ..< 1000).reduce(into: Data()) { data, index in
        data += BridgeFraming.frame(demoEnvelope(.toolStarted, session: "s\(index % 10)").encoded())
    }
    await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in
        DispatchQueue.global().async {
            if let fd = try? UnixSocket.connect(to: path) {
                _ = UnixSocket.writeAll(fd, frames)
                close(fd)
            }
            done.resume()
        }
    }
    #expect(await eventually { let c = inbox.counters; return c.accepted + c.rateLimited == 1000 })
    let counters = inbox.counters
    #expect(counters.accepted >= 200 && counters.accepted <= 600 && counters.rateLimited >= 400)  // 200 per second
    #expect(inbox.events.count == counters.accepted)
    #expect(inbox.batches.count < counters.accepted / 2)  // delivered together, not one by one
    #expect(inbox.batches.allSatisfy { $0.events.count <= AgentBridgeServer.Limits().maxBatch })
    #expect(inbox.deliveredOffMain)
}

@Test func aBurstOfConnectionsIsAccountedForAndTheServerRecovers() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let inbox = Inbox()
    let bridge = server(path, inbox, limits: .init(eventsPerSecond: 10_000))
    try bridge.start()
    defer { bridge.stop() }
    let outcomes = await send((0 ..< 1000).map { demoEnvelope(.toolStarted, session: "s\($0 % 10)") }, to: path)
    let reached = outcomes.filter { $0 == .sent || $0 == .sendFailed }.count  // the rest the kernel refused (backlog full)
    #expect(await eventually { let c = inbox.counters; return c.accepted + c.refusedConnections + c.invalid == reached })
    #expect(!outcomes.contains(.invalidArguments))
    let before = inbox.counters.accepted
    #expect(await send([demoEnvelope(.sessionStarted, session: "after")], to: path) == [.sent])
    #expect(await eventually { inbox.counters.accepted == before + 1 })  // still serving
    #expect(await eventually { bridge.connectionCount == 0 })
}

// MARK: Router and sessions

@MainActor @Test func theRouterDedupesAndKeepsSimulatedDataApart() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let scheduler = FakeScheduler()
    let health = AgentHealth()
    let router = AgentEventRouter(real: AgentSessionManager(scheduler: scheduler), demo: AgentSessionManager(scheduler: scheduler), health: health)
    let realStore = HubStore(url: temp.url.appending(path: "AIHub/hub.sqlite"))
    let demoStore = HubStore(url: temp.url.appending(path: "AIHub/demo.sqlite"))
    await realStore.open()
    await demoStore.open()
    router.realWriter = StoreWriter(store: realStore) { health.store = $0; _ = $1 }
    router.demoWriter = StoreWriter(store: demoStore) { health.demoStore = $0; _ = $1 }
    let agent = try #require(AgentID("demo-alpha"))
    let realAgent = try #require(AgentID("claude-code"))
    func event(_ id: AgentID, _ kind: AgentEvent.Kind, key: String) -> AgentEvent {
        AgentEvent(id: UUID(), session: SessionKey(agent: id, nativeID: "s1")!, kind: kind, nativeName: kind.rawValue,
                   occurredAt: .now, receivedAt: .now, cwd: "/Sim/Atlas", tool: nil, summary: nil, files: [], dedupeKey: key)
    }
    let demoStart = event(agent, .sessionStarted, key: "d1")
    router.receive(.init(events: [demoStart, demoStart, event(realAgent, .sessionStarted, key: "r1")],
                         counters: .init(accepted: 3)))
    router.receive(.init(events: [event(agent, .sessionStarted, key: "d1")], counters: .init()))  // a replay of d1
    #expect(health.duplicates == 2 && health.counters.accepted == 3)
    #expect(router.demo.sessions.count == 1 && router.real.sessions.count == 1)
    #expect(router.demo.sessions.keys.allSatisfy(\.agent.isDemo) && !router.real.sessions.keys.contains { $0.agent.isDemo })
    #expect(health.lastEvent.keys.map(\.rawValue) == ["claude-code"])  // simulated activity never counts as a real agent's
    await router.realWriter?.drain()
    await router.demoWriter?.drain()
    #expect(await realStore.recentSessions().map(\.key.agent.rawValue) == ["claude-code"])
    #expect(await demoStore.recentSessions().map(\.key.agent.rawValue) == ["demo-alpha"])
    let realCounts = await realStore.counts()
    let demoCounts = await demoStore.counts()
    #expect(realCounts == (1, 1) && demoCounts == (1, 1))
    await realStore.close()
    await demoStore.close()
}

@MainActor @Test func sessionStatusFollowsEventsAndGoesStaleOnItsOwnTimer() throws {
    let scheduler = FakeScheduler()
    var clock = Date(timeIntervalSince1970: 1_763_040_000)
    let manager = AgentSessionManager(scheduler: scheduler, now: { clock })
    var saved: [AgentSession] = []
    manager.onChange = { saved.append(contentsOf: $0) }
    let demoAgent = try #require(AgentID("demo-alpha"))
    let key = try #require(SessionKey(agent: demoAgent, nativeID: "s1"))
    func apply(_ kind: AgentEvent.Kind) -> AgentSession.Status? {
        manager.apply([AgentEvent(id: UUID(), session: key, kind: kind, nativeName: "x", occurredAt: clock, receivedAt: clock,
                                  cwd: "/Sim/Atlas", tool: nil, summary: nil, files: [], dedupeKey: UUID().uuidString)])
        return manager.sessions[key]?.status
    }
    #expect(apply(.sessionStarted) == .running && manager.sessions[key]?.title == "Atlas")
    #expect(apply(.turnCompleted) == .idle)
    #expect(apply(.toolStarted) == .running)
    #expect(apply(.error) == .failed)
    #expect(apply(.promptSubmitted) == .running)
    clock += 60
    #expect(apply(.sessionEnded) == .ended && manager.sessions[key]?.endedAt == clock)
    #expect(!manager.hasPendingTimer)  // nothing active: no timer at all
    #expect(apply(.sessionStarted) == .running && manager.hasPendingTimer)  // resumed
    clock += AgentSessionManager.staleAfter
    scheduler.advance(.seconds(Int64(AgentSessionManager.staleAfter)))
    #expect(manager.sessions[key]?.status == .stale && saved.map(\.status) == [.stale] && !manager.hasPendingTimer)
    #expect(manager.recentEvents[key]?.count == 7)
}

@MainActor @Test func theRegistryStaysBounded() throws {
    let manager = AgentSessionManager(scheduler: FakeScheduler())
    let agent = try #require(AgentID("demo-alpha"))
    var events: [AgentEvent] = []
    for index in 0 ..< AgentSessionManager.maxSessions + 20 {
        events.append(AgentEvent(id: UUID(), session: SessionKey(agent: agent, nativeID: "s\(index)")!, kind: .sessionEnded,
                                 nativeName: "x", occurredAt: Date(timeIntervalSince1970: Double(index)), receivedAt: .now,
                                 cwd: nil, tool: nil, summary: nil, files: [], dedupeKey: "\(index)"))
    }
    let key = SessionKey(agent: agent, nativeID: "busy")!
    for index in 0 ..< AgentSessionManager.maxEventsPerSession + 30 {
        events.append(AgentEvent(id: UUID(), session: key, kind: .toolStarted, nativeName: "x", occurredAt: .now, receivedAt: .now,
                                 cwd: nil, tool: nil, summary: nil, files: [], dedupeKey: "b\(index)"))
    }
    manager.apply(events)
    #expect(manager.sessions.count == AgentSessionManager.maxSessions && manager.sessions[key] != nil)
    #expect(manager.sessions[SessionKey(agent: agent, nativeID: "s0")!] == nil)  // the oldest finished one went first
    #expect(manager.recentEvents[key]?.count == AgentSessionManager.maxEventsPerSession)
}

@Test func commonSecretShapesAreRedactedToo() {
    for input in ["GITHUB_TOKEN=abc123def", "AWS_SECRET_ACCESS_KEY=wJalrXUtnFEMI", "DATABASE_PASSWORD: hunter2",
                  "MY_API_KEY=k-123", #"{"password":"hunter2","user":"me"}"#, "api-key=xyz789"] {
        let output = Redactor.redact(input)
        #expect(output.contains(Redactor.mask) && !["abc123def", "wJalrXUtnFEMI", "hunter2", "k-123", "xyz789"].contains { output.contains($0) }, "\(input)")
    }
    #expect(Redactor.line("-----BEGIN OPENSSH PRIVATE KEY----- b3BlbnNzaC1rZXk AAAA -----END", limit: 200) == Redactor.mask)
    #expect(Redactor.redact(#"{"password":"x","user":"me"}"#).contains(#""user":"me""#))  // neighbours kept
}

@MainActor @Test func aLateEventDoesntReopenAnEndedSession() throws {
    let manager = AgentSessionManager(scheduler: FakeScheduler())
    let agent = try #require(AgentID("claude-code"))
    let key = try #require(SessionKey(agent: agent, nativeID: "s1"))
    let start = Date(timeIntervalSince1970: 1000)
    func event(_ kind: AgentEvent.Kind, at seconds: Double) -> AgentEvent {
        AgentEvent(id: UUID(), session: key, kind: kind, nativeName: "x", occurredAt: start + seconds, receivedAt: .now,
                   cwd: nil, tool: nil, summary: nil, files: [], dedupeKey: UUID().uuidString)
    }
    manager.apply([event(.sessionStarted, at: 0), event(.sessionEnded, at: 10)])
    manager.apply([event(.toolCompleted, at: 9)])  // sent before the end, arrived after it
    #expect(manager.sessions[key]?.status == .ended && manager.sessions[key]?.endedAt == start + 10)
    #expect(manager.recentEvents[key]?.count == 3 && !manager.hasPendingTimer)
    manager.apply([event(.notification, at: 11)])
    #expect(manager.sessions[key]?.status == .ended)  // informational events don't revive it
    manager.apply([event(.sessionStarted, at: 20)])  // a real resume does
    #expect(manager.sessions[key]?.status == .running && manager.sessions[key]?.endedAt == nil)
}

@MainActor @Test func theBrowserFiltersSearchesAndMerges() throws {
    func session(_ id: String, _ agent: String, _ status: AgentSession.Status, title: String, at seconds: Double) -> AgentSession {
        AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: id)!, title: title, cwd: "/Users/me/\(title)", model: nil,
                     status: status, startedAt: .now, lastEventAt: Date(timeIntervalSince1970: seconds))
    }
    let all = [session("1", "claude-code", .running, title: "Orbit", at: 3), session("2", "codex", .waiting, title: "Atlas", at: 2),
               session("3", "claude-code", .ended, title: "Notes", at: 1), session("4", "codex", .idle, title: "Beacon", at: 4)]
    #expect(AgentBrowser.visible(all, filter: .active, search: "").map(\.key.nativeID) == ["1", "4"])
    #expect(AgentBrowser.visible(all, filter: .waiting, search: "").map(\.key.nativeID) == ["2"])
    #expect(AgentBrowser.visible(all, filter: .finished, search: "").map(\.key.nativeID) == ["3"])
    #expect(AgentBrowser.visible(all, filter: .all, search: "  openai ").map(\.key.nativeID) == ["2", "4"])  // by agent name
    #expect(AgentBrowser.visible(all, filter: .all, search: "me/orb").map(\.key.nativeID) == ["1"])  // by path
    let key = all[0].key
    func event(_ id: UUID, at seconds: Double) -> AgentEvent {
        AgentEvent(id: id, session: key, kind: .toolStarted, nativeName: "x", occurredAt: nil,
                   receivedAt: Date(timeIntervalSince1970: seconds), cwd: nil, tool: nil, summary: nil, files: [], dedupeKey: "\(seconds)")
    }
    let shared = UUID()
    let merged = AgentBrowser.merge([event(shared, at: 1), event(UUID(), at: 2)], [event(shared, at: 1), event(UUID(), at: 3)])
    #expect(merged.map(\.receivedAt.timeIntervalSince1970) == [1, 2, 3])
    #expect(AgentDiscovery.displayName(for: AgentID("demo-alpha")!) == "Simulated agent (alpha)")
}

@Test func theOriginTravelsWithTheEvents() async throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let inbox = Inbox()
    let bridge = server(path, inbox)
    try bridge.start()
    defer { bridge.stop() }
    let envelope = AgentEnvelope(agent: "demo-alpha", event: "toolStarted", sentAt: .now,
                                 origin: .init(bundleID: "com.microsoft.VSCode", termProgram: "vscode", ppid: 777),
                                 payload: ["session_id": .string("s1")])!
    await send([envelope], to: path)
    #expect(await eventually { inbox.events.count == 1 })
    #expect(inbox.events.first?.origin == AgentOrigin(bundleID: "com.microsoft.VSCode", pid: 777))
}
