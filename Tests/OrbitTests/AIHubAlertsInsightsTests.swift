import Foundation
import Testing
@testable import Orbit

// AI Hub Phases 9–10: local insights and alerts below the notch.

private func event(_ agent: String, _ session: String, _ kind: AgentEvent.Kind, at time: Date = .now) -> AgentEvent {
    AgentEvent(id: UUID(), session: SessionKey(agent: AgentID(agent)!, nativeID: session)!, kind: kind, nativeName: kind.rawValue,
               occurredAt: time, receivedAt: time, cwd: nil, tool: nil, summary: kind == .error ? "Turn failed" : nil, files: [],
               dedupeKey: UUID().uuidString)
}

// MARK: Alerts (Phase 10)

@MainActor @Test func alertsCoverWaitingFailuresFinishesAndRequests() throws {
    let scheduler = FakeScheduler()
    var clock = Date(timeIntervalSince1970: 1000)
    let alerts = AgentAlerts(scheduler: scheduler, now: { clock })
    alerts.receive([event("claude-code", "s1", .toolStarted)])
    #expect(alerts.current == nil)  // routine activity isn't an alert
    alerts.receive([event("claude-code", "s1", .waitingForUser)])
    #expect(alerts.current?.text == "Claude Code is waiting for you" && alerts.current?.symbol == "hand.raised" && alerts.current?.isSimulated == false)
    alerts.receive([event("codex", "c1", .error), event("demo-alpha", "d1", .turnCompleted), event("demo-alpha", "d1", .turnCompleted),
                    event("codex", "c2", .sessionEnded), event("codex", "c3", .sessionEnded)])
    #expect(alerts.queue.count == AgentAlerts.maxQueued)  // bounded; the repeat finish was throttled, one dropped
    #expect(alerts.queue.map(\.text) == ["OpenAI Codex: Turn failed", "Simulated agent (alpha) finished", "OpenAI Codex finished"])
    #expect(alerts.queue[1].isSimulated)
    scheduler.advance(AgentAlerts.showFor)
    #expect(alerts.current?.text == "OpenAI Codex: Turn failed" && alerts.queue.count == 2)
    for _ in 0 ..< 3 { scheduler.advance(AgentAlerts.showFor) }
    #expect(alerts.current == nil && alerts.queue.isEmpty)
    clock += AgentAlerts.completionInterval
    alerts.receive([event("demo-alpha", "d1", .turnCompleted)])  // a minute later: shown again
    #expect(alerts.current?.text == "Simulated agent (alpha) finished")
    alerts.isEnabled = false
    #expect(alerts.current == nil)
    alerts.receive(request: ApprovalDraft(session: SessionKey(agent: AgentID("demo-beta")!, nativeID: "r")!, kind: .permission, nativeName: "x",
                                          tool: nil, summary: "s", options: [], createdAt: clock, expiresAt: clock + 30))
    #expect(alerts.current == nil)  // switched off: nothing
    alerts.isEnabled = true
    alerts.receive(request: ApprovalDraft(session: SessionKey(agent: AgentID("demo-beta")!, nativeID: "r")!, kind: .question, nativeName: "x",
                                          tool: nil, summary: "s", options: ["a"], createdAt: clock, expiresAt: clock + 30))
    #expect(alerts.current?.text == "Simulated agent (beta) asks a question")
}

@Test func theApprovedOverlayPrioritiesAreUnchanged() {
    // The free-slot rule moved to NotchCoordination (NotchCoordinationTests.theAlertOnlyTakesAFreeSlot).
    // The approved priorities are unchanged: the coordinator's decision never involves agent alerts.
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .compact, volumeVisible: false) == .musicIsland)
    #expect(NotchOverlayCoordinator.decide(dashboardOpen: false, island: .hidden, volumeVisible: true) == .volumeHUD)
}

// MARK: Insights (Phase 9)

@MainActor @Test func insightsSummariseRealAgentsOnly() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = FileManager.default.temporaryDirectory.appending(path: "oi-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let now = Date.now
    let store = HubStore(url: temp.url.appending(path: "hub.sqlite"))
    await store.open()
    let key = SessionKey(agent: AgentID("claude-code")!, nativeID: "s1")!
    let session = AgentSession(key: key, title: "Orbit", cwd: nil, model: nil, status: .ended, startedAt: now - 7200, lastEventAt: now)
    await store.save(sessions: [session], events: [event("claude-code", "s1", .toolStarted, at: now - 3600), event("claude-code", "s1", .toolCompleted, at: now)])
    await store.close()
    let hub = AIHubService(paths: .init(socket: folder.appending(path: "a.sock").path(percentEncoded: false), store: temp.url.appending(path: "hub.sqlite"),
                                        demoStore: temp.url.appending(path: "demo.sqlite")), scheduler: FakeScheduler(), discover: { [] })
    hub.set(enabled: true, demo: true)
    await hub.settled()
    hub.demo.apply([event("demo-alpha", "d", .toolStarted)])  // simulated activity, in its own registry and store
    await hub.refreshInsights(now: now)
    let insights = hub.insights
    #expect(insights.agents.map(\.agent) == ["claude-code"] && insights.agents[0].sessions == 1 && insights.agents[0].events == 2)
    #expect(abs(insights.agents[0].activeSeconds - 7200) < 1 && insights.days.map(\.count).reduce(0, +) == 2)
    #expect(insights.report.contains("Claude Code: 1 session, 2 events, about 2.0 h active"))
    #expect(insights.report.contains("not available") && !insights.report.contains("Simulated"))
    hub.set(enabled: false, demo: false)
    await hub.settled()
}
