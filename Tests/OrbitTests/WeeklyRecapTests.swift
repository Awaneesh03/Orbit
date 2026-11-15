import Foundation
import Testing
@testable import Orbit

// Milestone 9: the weekly recap, from hub.sqlite only. Quiet days show as
// zero, incomplete history is said, and no trend or highlight is invented.

private let base = Date(timeIntervalSince1970: 1_763_040_000)

private func session(_ native: String, agent: String = "claude-code", at time: Date, status: AgentSession.Status) -> AgentSession {
    AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: native)!, title: native, cwd: "/Users/me/orbit",
                 model: nil, status: status, startedAt: time, lastEventAt: time.addingTimeInterval(1800))
}

private func event(_ session: AgentSession, at time: Date, files: [String] = []) -> AgentEvent {
    AgentEvent(id: UUID(), session: session.key, kind: .fileChanged, nativeName: "PostToolUse", occurredAt: time, receivedAt: time,
               cwd: nil, tool: "Edit", summary: "Edit", files: files, dedupeKey: "\(session.key)|\(UUID())")
}

@Test func everyDayOfTheWeekShowsEvenTheQuietOnes() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let since = Date(timeIntervalSince1970: 1_763_078_400)  // a midnight UTC
    let format = AIHubService.Insights.dayFormatter(calendar)
    let day2 = format.string(from: since.addingTimeInterval(2 * 86_400))
    let filled = AIHubService.Insights.filled([(day2, 9)], since: since, calendar: calendar)
    #expect(filled.count == 7 && filled.map(\.count) == [0, 0, 9, 0, 0, 0, 0])
    #expect(filled.first?.day == format.string(from: since))
}

@Test func incompleteHistoryHasNoTrendAndSaysSo() {
    var insights = AIHubService.Insights()
    insights.since = base
    insights.historyStart = base.addingTimeInterval(3 * 86_400)  // Orbit started recording mid-week
    insights.days = [("2025-11-14", 10)]
    insights.previousWeekEvents = 5
    #expect(insights.isPartial && insights.trend == nil)  // never compared against a week that wasn't recorded
    insights.historyStart = base.addingTimeInterval(-30 * 86_400)
    #expect(!insights.isPartial && insights.trend == 1.0)  // 10 vs 5
    insights.previousWeekEvents = 0
    #expect(insights.trend == nil)
    insights.historyStart = nil
    #expect(insights.isPartial)  // nothing recorded at all
}

@Test func highlightsComeOnlyFromRecordedFacts() {
    #expect(AIHubService.Insights().highlights.isEmpty)
    var insights = AIHubService.Insights()
    insights.agents = [HubStore.AgentTotals(agent: "codex", sessions: 3, events: 40, activeSeconds: 5400),
                       HubStore.AgentTotals(agent: "claude-code", sessions: 2, events: 10, activeSeconds: 600)]
    insights.days = [("2025-11-10", 3), ("2025-11-11", 30)]
    insights.longest = ("codex", "/Users/me/orbit", 4000)
    insights.statuses = ["failed": 1, "running": 2, "completed": 3]
    let lines = insights.highlights
    #expect(lines.first?.hasPrefix("OpenAI Codex did most of the work") == true)
    #expect(lines.contains { $0.hasPrefix("Busiest day:") && $0.contains("30 events") })
    #expect(lines.contains { $0.contains("Longest session") && $0.contains("orbit") })
    #expect(lines.contains("1 session failed; worth a look in Agents."))
    #expect(insights.active == 2 && insights.finished == 3 && insights.failed == 1)
}

@Test func theStoreCountsFilesHistoryAndTheLongestSession() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let store = HubStore(url: temp.url.appending(path: "AIHub/hub.sqlite"), clock: { base })
    #expect(await store.open() == .ok)
    let emptyStart = await store.firstEventAt(), emptyFiles = await store.filesTouched(from: .distantPast)
    #expect(emptyStart == nil && emptyFiles == 0)
    let a = session("a", at: base, status: .completed), b = session("b", agent: "codex", at: base.addingTimeInterval(86_400), status: .failed)
    let saved = await store.save(sessions: [a, b], events: [
        event(a, at: base, files: ["/p/One.swift", "/p/Two.swift"]),
        event(a, at: base.addingTimeInterval(60), files: ["/p/One.swift"]),  // the same file again: counted once
        event(b, at: base.addingTimeInterval(86_400), files: ["/p/Three.swift"]),
        event(b, at: base.addingTimeInterval(86_500)),
    ])
    #expect(saved == .ok)
    let all = await store.filesTouched(from: .distantPast), later = await store.filesTouched(from: base.addingTimeInterval(3600))
    #expect(all == 3 && later == 1)  // the same file twice counts once; only b's after the first hour
    let count = await store.eventCount(from: base, to: base.addingTimeInterval(3600))
    let first = await store.firstEventAt()
    #expect(count == 2 && first == base)
    let longest = await store.longestSession(since: .distantPast)
    #expect(longest?.seconds == 1800)
}
