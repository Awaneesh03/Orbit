import Foundation
import Testing
@testable import Orbit

// Milestone 14: smarter agent alerts. Priority, grouping, mute, quiet hours,
// expiry, sound and history, all on a fake clock and scheduler.

private func event(_ agent: String, _ session: String, _ kind: AgentEvent.Kind) -> AgentEvent {
    AgentEvent(id: UUID(), session: SessionKey(agent: AgentID(agent)!, nativeID: session)!, kind: kind, nativeName: kind.rawValue,
               occurredAt: .now, receivedAt: .now, cwd: nil, tool: nil, summary: kind == .error ? "Build failed" : nil, files: [],
               dedupeKey: UUID().uuidString)
}

/// 2026-11-14 at `hour`:00 local time.
private func at(_ hour: Int) -> Date {
    Calendar.current.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: hour))!
}

@MainActor @Test func urgentAlertsJumpTheQueue() {
    let scheduler = FakeScheduler()
    let alerts = AgentAlerts(scheduler: scheduler, now: { at(12) }, playSound: { _ in })
    alerts.receive([event("codex", "a", .turnCompleted)])  // showing
    alerts.receive([event("claude-code", "b", .turnCompleted), event("gemini-cli", "c", .error), event("cursor", "d", .waitingForUser)])
    #expect(alerts.queue.map(\.kind) == [.needsYou, .failed, .finished])
    scheduler.advance(AgentAlerts.showFor)
    #expect(alerts.current?.text == "Cursor is waiting for you")
}

@MainActor @Test func simultaneousFinishesAreGrouped() {
    let scheduler = FakeScheduler()
    let alerts = AgentAlerts(scheduler: scheduler, now: { at(12) }, playSound: { _ in })
    alerts.receive([event("claude-code", "x", .error)])  // occupies the slot
    alerts.receive([event("codex", "a", .turnCompleted), event("claude-code", "b", .turnCompleted), event("gemini-cli", "c", .sessionEnded)])
    #expect(alerts.queue.count == 1)
    #expect(alerts.queue[0].text == "OpenAI Codex and 2 others finished")
    #expect(AgentAlerts.finishedText(["A", "B"]) == "A and B finished")
    alerts.receive([event("demo-alpha", "d", .turnCompleted)])  // simulated is never grouped with real agents
    #expect(alerts.queue.count == 2 && alerts.queue[1].isSimulated)
    #expect(alerts.history.filter { $0.outcome == .grouped }.count == 2)
}

@MainActor @Test func mutedAgentsAndFinishedOffStayQuiet() {
    let alerts = AgentAlerts(scheduler: FakeScheduler(), now: { at(12) }, playSound: { _ in })
    alerts.rules.mutedAgents = ["codex"]
    alerts.receive([event("codex", "a", .waitingForUser)])
    #expect(alerts.current == nil && alerts.history.first?.outcome == .muted)
    alerts.rules.showFinished = false
    alerts.receive([event("claude-code", "b", .turnCompleted)])
    #expect(alerts.current == nil)
    alerts.receive([event("claude-code", "b", .error)])
    #expect(alerts.current?.kind == .failed)  // failures still show
}

@MainActor @Test func quietHoursLetOnlyNeedsYouThrough() {
    var rules = AgentAlertRules()
    rules.quietHours = true  // 22:00–08:00, across midnight
    #expect(rules.isQuiet(at: at(23)) && rules.isQuiet(at: at(3)) && !rules.isQuiet(at: at(8)) && !rules.isQuiet(at: at(14)))
    rules.quietStart = 13 * 60; rules.quietEnd = 15 * 60  // same-day range
    #expect(rules.isQuiet(at: at(14)) && !rules.isQuiet(at: at(16)))
    rules.quietStart = rules.quietEnd
    #expect(!rules.isQuiet(at: at(14)))  // an empty range is never quiet

    var sounds: [AgentAlerts.Kind] = []
    let alerts = AgentAlerts(scheduler: FakeScheduler(), now: { at(23) }, playSound: { sounds.append($0) })
    alerts.rules.quietHours = true
    alerts.rules.sound = true
    alerts.receive([event("codex", "a", .error), event("codex", "b", .turnCompleted)])
    #expect(alerts.current == nil && alerts.history.allSatisfy { $0.outcome == .quiet })
    alerts.receive([event("codex", "c", .waitingForUser)])
    #expect(alerts.current?.kind == .needsYou)
    #expect(sounds.isEmpty)  // never a sound in quiet hours
}

@MainActor @Test func soundIsOptInAndOnlyForUrgentAlerts() {
    var sounds: [AgentAlerts.Kind] = []
    let scheduler = FakeScheduler()
    let alerts = AgentAlerts(scheduler: scheduler, now: { at(12) }, playSound: { sounds.append($0) })
    alerts.receive([event("codex", "a", .error)])
    #expect(sounds.isEmpty)  // off by default
    alerts.rules.sound = true
    alerts.receive([event("codex", "b", .turnCompleted), event("codex", "c", .waitingForUser)])
    #expect(sounds == [.needsYou])  // never for "finished"
}

@MainActor @Test func staleQueuedAlertsExpire() {
    let scheduler = FakeScheduler()
    var clock = at(12)
    let alerts = AgentAlerts(scheduler: scheduler, now: { clock }, playSound: { _ in })
    alerts.receive([event("codex", "a", .error), event("claude-code", "b", .error)])
    clock += AgentAlerts.expiresAfter + 1  // the slot was busy (e.g. the music island) for a while
    scheduler.advance(AgentAlerts.showFor)
    #expect(alerts.current == nil && alerts.history.first?.outcome == .expired)
}

@MainActor @Test func historyIsBoundedAndNewestFirst() {
    let scheduler = FakeScheduler()
    let alerts = AgentAlerts(scheduler: scheduler, now: { at(12) }, playSound: { _ in })
    for index in 0 ..< 40 {
        alerts.receive([event("codex", "s\(index)", .error)])
        scheduler.advance(AgentAlerts.showFor)
    }
    #expect(alerts.history.count == AgentAlerts.historyLimit)
    #expect(alerts.history.first!.id > alerts.history.last!.id)
}

@Test func alertRulesDecodeTolerantly() throws {
    let rules = try JSONDecoder().decode(AgentAlertRules.self, from: Data(#"{"mutedAgents":["codex"],"quietStart":99999,"sound":"loud"}"#.utf8))
    #expect(rules.mutedAgents == ["codex"] && rules.quietStart == 1439 && !rules.sound && rules.showFinished)
    let prefs = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"agentAlerts":42,"aiHubAlerts":false}"#.utf8))
    #expect(prefs.agentAlerts == AgentAlertRules() && !prefs.aiHubAlerts)
}
