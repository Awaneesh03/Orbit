import Foundation
import Testing
@testable import Orbit

// Milestone 14: light automations. Fixed triggers and actions, conditions, a cooldown,
// history, tolerant saving, and agent alerts as a trigger (never simulated ones).

/// Wednesday 2026-11-11 and Saturday 2026-11-14, noon (Gregorian, UTC).
private let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }()
private let wednesday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: 12))!
private let saturday = calendar.date(from: DateComponents(year: 2026, month: 11, day: 14, hour: 12))!

@MainActor @Test func rulesRunTheirActionOnTheirTriggerOnly() {
    var done: [AutomationRule.Action] = []
    var clock = wednesday
    let automations = Automations(perform: { done.append($0); return true }, now: { clock }, calendar: calendar)
    automations.rules = [AutomationRule(trigger: .meetingSoon, action: .pauseMusic),
                         AutomationRule(trigger: .agentNeedsYou, action: .keepAwakeHour, isEnabled: false),
                         AutomationRule(trigger: .agentFinished, action: .startFocus)]
    #expect(automations.listens(for: .meetingSoon) && !automations.listens(for: .agentNeedsYou))  // off rules don't listen
    automations.fire(.meetingSoon, context: .init())
    automations.fire(.agentNeedsYou, context: .init())
    #expect(done == [.pauseMusic])
    automations.fire(.meetingSoon, context: .init())  // again within a minute: skipped, no loop
    #expect(done == [.pauseMusic] && automations.history.first?.outcome == .skipped("ran less than a minute ago"))
    clock += Automations.cooldown
    automations.fire(.meetingSoon, context: .init())
    #expect(done == [.pauseMusic, .pauseMusic])
    #expect(automations.history.first?.text == "A meeting is about to start → Pause music")
}

@MainActor @Test func conditionsAreChecked() {
    var done = 0
    var clock = saturday
    let automations = Automations(perform: { _ in done += 1; return true }, now: { clock }, calendar: calendar)
    automations.rules = [AutomationRule(trigger: .agentFinished, condition: .weekdays, action: .startFocus),
                         AutomationRule(trigger: .meetingSoon, condition: .musicPlaying, action: .pauseMusic)]
    automations.fire(.agentFinished, context: .init())
    #expect(done == 0 && automations.history.first?.outcome == .skipped("weekend"))
    clock = wednesday
    automations.fire(.agentFinished, context: .init())
    automations.fire(.meetingSoon, context: .init(musicPlaying: false))
    #expect(done == 1 && automations.history.first?.outcome == .skipped("no music playing"))
    automations.fire(.meetingSoon, context: .init(musicPlaying: true))
    #expect(done == 2)
}

@MainActor @Test func nothingToDoIsRecordedNotRetried() {
    let automations = Automations(perform: { _ in false }, now: { wednesday }, calendar: calendar)
    automations.rules = [AutomationRule(trigger: .meetingSoon, action: .pauseMusic)]
    automations.fire(.meetingSoon, context: .init())
    #expect(automations.history.first?.outcome == .skipped("nothing to do"))
}

@MainActor @Test func historyIsBounded() {
    var clock = wednesday
    let automations = Automations(perform: { _ in true }, now: { clock }, calendar: calendar)
    automations.rules = [AutomationRule(trigger: .meetingSoon, action: .openCalendar)]
    for _ in 0 ..< 40 { automations.fire(.meetingSoon, context: .init()); clock += 61 }
    #expect(automations.history.count == Automations.historyLimit)
}

@Test func savedRulesSurviveUnknownOnes() throws {
    let json = #"""
    {"automations":[{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","trigger":"meetingSoon","condition":"always","action":"pauseMusic","isEnabled":true},
                    {"id":"7F9619FF-8B86-D011-B42D-00C04FC964FF","trigger":"teleport","condition":"always","action":"pauseMusic","isEnabled":true},
                    {"id":"8F9619FF-8B86-D011-B42D-00C04FC964FF","trigger":"agentFinished","condition":"always","action":"runShell","isEnabled":true}]}
    """#
    let prefs = try JSONDecoder().decode(OrbitPreferences.self, from: Data(json.utf8))
    #expect(prefs.automations.map(\.trigger) == [.meetingSoon])  // a future trigger or an unknown action is skipped, never run
    #expect(OrbitPreferences().automations.isEmpty)  // none by default
    let round = try JSONDecoder().decode(OrbitPreferences.self, from: JSONEncoder().encode(prefs))
    #expect(round.automations == prefs.automations)
}

@MainActor @Test func realAgentAlertsTriggerAutomationsButSimulatedOnesNever() {
    var kinds: [AgentAlerts.Kind] = []
    let alerts = AgentAlerts(scheduler: FakeScheduler(), playSound: { _ in })
    alerts.onAlert = { kinds.append($0) }
    alerts.isEnabled = false  // even while alerts are off (e.g. Coucou has the notch)
    func event(_ agent: String, _ kind: AgentEvent.Kind) -> AgentEvent {
        AgentEvent(id: UUID(), session: SessionKey(agent: AgentID(agent)!, nativeID: "s")!, kind: kind, nativeName: kind.rawValue,
                   occurredAt: .now, receivedAt: .now, cwd: nil, tool: nil, summary: nil, files: [], dedupeKey: UUID().uuidString)
    }
    alerts.receive([event("codex", .waitingForUser), event("demo-alpha", .waitingForUser), event("codex", .turnCompleted)])
    #expect(kinds == [.needsYou, .finished])
}
