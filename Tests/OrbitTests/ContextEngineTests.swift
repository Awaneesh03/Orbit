import AppKit
import Foundation
import Observation
import SwiftUI
import Testing
@testable import Orbit

// Milestone 17: the Context Engine. Sources, events, rules, ranking, feedback, privacy,
// automations and cost. Fixed clock; no real data.

private let calendar: Calendar = { var c = Calendar(identifier: .gregorian); c.timeZone = .gmt; return c }()
/// Wednesday 2026-11-11 at `hour`.
private func at(_ hour: Int, _ minute: Int = 0) -> Date { calendar.date(from: DateComponents(year: 2026, month: 11, day: 11, hour: hour, minute: minute))! }

private func agent(_ name: String, _ status: AgentSession.Status, at time: Date, folder: String? = "/p/orbit", jump: Bool = true) -> ContextSnapshot.Agent {
    ContextSnapshot.Agent(key: "\(name):1", name: name, project: folder.map { ($0 as NSString).lastPathComponent }, folder: folder,
                          status: status, lastEventAt: time, canJump: jump)
}
private func task(_ title: String, done: Date? = nil) -> ChecklistItem {
    var item = ChecklistItem(title: title)
    item.isDone = done != nil
    item.completedAt = done
    return item
}
private func generate(_ s: ContextSnapshot, now: Date, memory: ContextMemory = ContextMemory(), prefs: SuggestionPreferences = .init()) -> [Suggestion] {
    SuggestionRules.generate(s, memory: memory, preferences: prefs, now: now, calendar: calendar)
}

@Test func agentsWaitingFailedAndFinishedBecomeSuggestions() {
    var s = ContextSnapshot()
    s.agents = [agent("Claude Code", .waiting, at: at(10)), agent("Codex", .failed, at: at(9, 30)), agent("Gemini", .completed, at: at(9, 50)),
                agent("Old", .failed, at: at(6))]
    let list = generate(s, now: at(10, 5))
    #expect(list.map(\.kind) == ["agent.waiting", "agent.failed", "agent.done"])  // a failure 4 h old isn't news
    #expect(list[0].priority == 100 && list[0].primary == .goToAgent("Claude Code:1") && list[0].reason.contains("waiting"))
    #expect(list[1].primary == .reviewAgent("Codex:1") && list[1].expiresAt == at(11, 30))
    s.agents = [agent("Claude Code", .waiting, at: at(10), jump: false)]
    #expect(generate(s, now: at(10)).first?.primary == .reviewAgent("Claude Code:1"))  // nowhere to jump: open its session in the AI Hub
}

@Test func meetingsOfferTheRightActions() {
    var s = ContextSnapshot()
    let link = URL(string: "https://meet.google.com/abc-defg-hij")!
    s.meeting = MeetingCue(eventID: "m", title: "Standup", start: at(10, 4), phase: .soon, joinURL: link, end: at(10, 30))
    s.music = "Song"
    s.agents = [agent("Claude Code", .running, at: at(10))]
    let list = generate(s, now: at(10))
    let meeting = list.first { $0.kind == "meeting.soon" }
    #expect(meeting?.primary == .joinMeeting(link) && meeting?.secondary == .pauseMusic && meeting?.priority == 92 && meeting?.expiresAt == at(10, 4))
    #expect(list.contains { $0.kind == "meeting.agent" && $0.title == "Check Claude Code before your meeting" })
    s.meeting = MeetingCue(eventID: "m", title: "Standup", start: at(9, 58), phase: .started, end: at(10, 30))
    s.music = nil
    #expect(generate(s, now: at(10)).first { $0.kind == "meeting.now" }?.primary == .openCalendar)  // no link: Calendar
}

@Test func focusTasksAndGoalsFollowTheDay() {
    var s = ContextSnapshot()
    s.focus = .idle
    s.openTasks = [task("Chapter 3 outline"), task("Email"), task("Groceries")]
    let morning = generate(s, now: at(10))
    #expect(morning.first { $0.kind == "focus.start" }.map { $0.primary == .startFocus(minutes: 25) && $0.secondary == .startFocus(minutes: 50) } == true)
    #expect(!generate(s, now: at(23)).contains { $0.kind == "focus.start" })  // not at night
    var busy = s
    busy.meeting = MeetingCue(eventID: "m", title: "Lecture", start: at(10, 20), phase: .upcoming)
    #expect(!generate(busy, now: at(10)).contains { $0.kind == "focus.start" })  // a meeting soon: no focus suggestion
    var college = WorkspaceProfile(name: "College")
    college.taskKeywords = ["chapter"]
    s.workspace = college
    let mine = generate(s, now: at(10))
    #expect(mine.first { $0.kind == "focus.start" }?.title == "Focus on “Chapter 3 outline”")
    #expect(mine.contains { $0.kind == "task.workspace" && $0.title == "Chapter 3 outline" })
    s.focus = .paused(remaining: 600)
    #expect(generate(s, now: at(10)).contains { $0.kind == "focus.resume" && $0.primary == .resumeFocus })
    var prefs = SuggestionPreferences()
    prefs.smartFocus = false
    #expect(!generate(s, now: at(10), prefs: prefs).contains { $0.kind.hasPrefix("focus.") })
    s.goals = [task("Ship M17", done: at(9)), task("Read paper")]
    #expect(generate(s, now: at(18)).first { $0.kind == "goal.evening" }?.title == "Continue “Read paper”")
    #expect(!generate(s, now: at(15)).contains { $0.kind == "goal.evening" })
}

@Test func workspacesAreRecommendedWithAReasonAndNeverTheActiveOne() {
    var college = WorkspaceProfile(name: "College", symbol: "graduationcap")
    var fixkaru = WorkspaceProfile(name: "FixKaru")
    fixkaru.projects = ["/p/fixkaru"]
    fixkaru.taskKeywords = ["fixkaru"]
    college.schedule = WorkspaceProfile.Schedule(weekdays: [4], startHour: 9, endHour: 12)
    var s = ContextSnapshot()
    s.workspaces = [college, fixkaru]
    s.todayEvents = [AgendaEvent(id: "e", title: "College seminar", start: at(11), end: at(12), isAllDay: false, calendarID: "c", calendarTitle: "C", color: nil)]
    s.agents = [agent("Claude Code", .running, at: at(10), folder: "/p/fixkaru/api")]
    let list = generate(s, now: at(10)).filter { $0.kind == "workspace.recommend" }
    #expect(list.count == 2)
    #expect(list[0].primary == .switchWorkspace(college.id) && list[0].detail.contains("College seminar"))  // the calendar beats its schedule
    #expect(list[1].detail == "Claude Code is working in api.")
    s.workspace = college
    #expect(!generate(s, now: at(10)).contains { $0.primary == .switchWorkspace(college.id) })
    s.agents = []
    s.openTasks = [task("FixKaru invoice"), task("fixkaru logo")]
    #expect(generate(s, now: at(10)).first { $0.kind == "workspace.recommend" }?.detail == "2 open tasks match its task words.")
    var off = SuggestionPreferences()
    off.workspaceRecommendations = false
    #expect(!generate(s, now: at(10), prefs: off).contains { $0.kind == "workspace.recommend" })
}

@Test func batteryAndEnergyAreHonestAndQuietWhileCharging() {
    var s = ContextSnapshot()
    s.battery = BatteryStatus(percent: 15, isCharging: false, isPluggedIn: false)
    s.energyHog = "Brave Browser"
    let list = generate(s, now: at(10))
    #expect(list.first { $0.kind == "battery.low" }.map { $0.primary == .batterySettings && $0.reason.contains("can't turn Low Power Mode on") } == true)
    #expect(list.contains { $0.kind == "energy.high" && $0.primary == .activityMonitor })
    s.battery = BatteryStatus(percent: 15, isCharging: true, isPluggedIn: true)
    #expect(!generate(s, now: at(10)).contains { $0.category == .battery })  // charging: nothing to say
}

@Test func rankingLimitsAndExplainsWhatItHolds() {
    func make(_ id: String, _ priority: Int, _ category: Suggestion.Category = .agents, expires: Date? = nil) -> Suggestion {
        Suggestion(id: id, kind: id.components(separatedBy: ":")[0], category: category, title: id, detail: "", reason: "", symbol: "x",
                   priority: priority, primary: .openAIHub, expiresAt: expires)
    }
    let list = [make("a:1", 60), make("b:1", 90), make("c:1", 70), make("d:1", 40, .battery), make("e:1", 50, expires: at(9)), make("f:1", 30),
                make("g:1", 95), make("h:1", 20)]
    var feedback = SuggestionFeedbackStore()
    feedback.dismissed["g:1"] = at(8)
    feedback.snoozed["f:1"] = at(11)
    feedback.irrelevant = ["h"]
    var prefs = SuggestionPreferences()
    prefs.disabledCategories = [.battery]
    let ranked = SuggestionRanking.rank(list, feedback: feedback, preferences: prefs, focusRunning: false, now: at(10))
    #expect(ranked.shown.map(\.id) == ["b:1", "c:1"])  // calm: 2
    let reasons = Dictionary(uniqueKeysWithValues: ranked.suppressed.map { ($0.id, $0.reason) })
    #expect(reasons["g:1"] == "Dismissed" && reasons["d:1"] == "Battery and energy is turned off" && reasons["e:1"] == "Expired")
    #expect(reasons["h:1"] == "Marked not relevant" && reasons["f:1"]?.hasPrefix("Snoozed until") == true)
    #expect(reasons["a:1"] == "Beyond the 2 shown (score 60)")
    let focusing = SuggestionRanking.rank([make("b:1", 90), make("c:1", 70), make("focus.summary:1", 66)], feedback: .init(), preferences: .init(),
                                          focusRunning: true, now: at(10))
    #expect(focusing.shown.map(\.id) == ["b:1", "focus.summary:1"] && focusing.suppressed.first?.reason == "Held during your focus session")
    prefs.enabled = false
    #expect(SuggestionRanking.rank(list, feedback: .init(), preferences: prefs, focusRunning: false, now: at(10)).shown.isEmpty)
}

@Test func learningIsBoundedSoNothingUrgentDisappears() {
    var store = SuggestionFeedbackStore()
    store.counts["agent.done"] = .init(accepted: 10)
    store.counts["focus.start"] = .init(dismissed: 50)
    #expect(store.adjustment(for: "agent.done") == 12 && store.adjustment(for: "focus.start") == -30 && store.adjustment(for: "new") == 0)
    store.dismissed["old"] = at(10).addingTimeInterval(-15 * 86_400)
    store.snoozed["past"] = at(9)
    store.prune(now: at(10))
    #expect(store.dismissed.isEmpty && store.snoozed.isEmpty)
}

@MainActor @Observable private final class FakeModel {
    var tasks: [ChecklistItem] = []
    var battery = BatteryStatus(percent: 80, isCharging: false, isPluggedIn: false)
}

@MainActor @Test func theEngineIsEventDrivenAndCoalesces() async {
    let model = FakeModel()
    var reads = 0
    let engine = ContextEngine(file: nil, now: { at(10) }, calendar: calendar)
    engine.register(ContextSource(id: "tasks", name: "Tasks") { s in reads += 1; s.openTasks = model.tasks })
    engine.register(ContextSource(id: "battery", name: "Battery") { s in s.battery = model.battery })
    engine.register(ContextSource(id: "broken", name: "Broken") { _ in throw CocoaError(.fileReadNoPermission) })
    engine.start()
    #expect(engine.updates == 1 && engine.errors.keys.sorted() == ["broken"] && engine.snapshot.battery?.percent == 80)  // one failing source doesn't stop the rest
    for index in 0 ..< 5 { model.tasks.append(task("Task \(index)")) }  // five quick changes
    // Wait for the coalesced refresh (a busy main actor delays it under a loaded full-suite run), then make sure no more follow.
    for _ in 0 ..< 300 where engine.updates < 2 { try? await Task.sleep(for: .milliseconds(10)) }
    try? await Task.sleep(for: .milliseconds(400))
    #expect(engine.updates == 2 && engine.snapshot.openTasks.count == 5)  // one refresh for all of them
    #expect(engine.events.filter { $0.text == "5 open tasks" }.count == 1)
    #expect(engine.events.filter { $0.source == "battery" }.count == 1)  // the first reading
    model.battery = BatteryStatus(percent: 80, isCharging: false, isPluggedIn: false)  // set, but the same value
    try? await Task.sleep(for: .milliseconds(600))
    #expect(engine.updates == 2)  // Observation doesn't even report an equal value: no refresh at all…
    #expect(engine.events.filter { $0.source == "battery" }.count == 1)  // not a new event
    let before = reads
    try? await Task.sleep(for: .milliseconds(400))
    #expect(reads == before)  // nothing changed: nothing read (no polling)
    engine.register(ContextSource(id: "tasks", name: "Tasks (replaced)") { _ in })
    #expect(engine.sources.filter { $0.id == "tasks" }.count == 1)
    engine.stop()
}

@MainActor @Test func feedbackSurvivesARestartAndResetsCleanly() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    var accepted: [Suggestion.Action] = []
    var clock = at(10)
    let engine = ContextEngine(file: temp.file("suggestions.json"), now: { clock }, calendar: calendar)
    engine.register(ContextSource(id: "s", name: "s") { s in
        s.agents = [agent("Claude Code", .waiting, at: at(9, 59)), agent("Codex", .completed, at: at(9, 50))]
        s.battery = BatteryStatus(percent: 15, isCharging: false, isPluggedIn: false)
    })
    engine.perform = { accepted.append($0) }
    engine.start()
    #expect(engine.shown.map(\.suggestion.kind) == ["agent.waiting", "battery.low"])
    engine.accept(engine.shown[0].id)
    #expect(accepted == [.goToAgent("Claude Code:1")])
    #expect(engine.shown.map(\.suggestion.kind) == ["battery.low", "agent.done"])  // accepted: not offered again
    engine.snooze(engine.shown[0].id)
    #expect(engine.shown.map(\.suggestion.kind) == ["agent.done"])
    engine.markIrrelevant(engine.shown[0].id)
    #expect(engine.shown.isEmpty)
    engine.stop()

    let restarted = ContextEngine(file: temp.file("suggestions.json"), now: { clock }, calendar: calendar)
    restarted.register(engine.sources[0])
    restarted.start()
    #expect(restarted.shown.isEmpty && restarted.feedback.history.map(\.outcome) == ["Not relevant", "Snoozed", "Accepted"])
    clock = at(11, 1)  // the snooze (60 min) is over
    restarted.refresh()
    #expect(restarted.shown.map(\.suggestion.kind) == ["battery.low"])
    restarted.resetLearning()
    #expect(restarted.feedback == SuggestionFeedbackStore() && restarted.shown.count == 2)
    let saved = try String(contentsOf: temp.url.appending(path: "suggestions.json"), encoding: .utf8)
    #expect(!saved.contains("/p/orbit"))  // titles and outcomes only: no paths
    restarted.stop()
}

@MainActor @Test func aMeetingThenBackToTheWorkspaceAndAFocusSummary() {
    var clock = at(10)
    let development = WorkspaceProfile(name: "Development")
    let college = WorkspaceProfile(name: "College")
    var active = development
    var focus = ContextSnapshot.Focus.running(endsAt: at(10, 25), length: 1500)
    var meeting: MeetingCue? = MeetingCue(eventID: "m", title: "Seminar", start: at(10), phase: .started, end: at(10, 20))
    var done: [ChecklistItem] = []
    var agents: [ContextSnapshot.Agent] = []
    let engine = ContextEngine(file: nil, now: { clock }, calendar: calendar)
    engine.register(ContextSource(id: "s", name: "s") { s in
        s.workspace = active
        s.workspaces = [development, college]
        s.meeting = meeting
        s.focus = focus
        s.doneToday = done
        s.agents = agents
    })
    engine.start()
    active = college  // switched during the meeting
    meeting = nil
    clock = at(10, 21)
    engine.refresh()
    var prefs = engine.preferences
    prefs.frequency = .more
    engine.preferences = prefs
    // Still focusing until 10:25: a priority-50 suggestion waits.
    #expect(engine.suppressed.first { $0.suggestion.kind == "meeting.after" }?.reason == "Held during your focus session")
    done = [task("Outline", done: at(10, 10)), task("Earlier", done: at(9))]
    agents = [agent("Codex", .completed, at: at(10, 15))]
    focus = .idle
    clock = at(10, 26)
    engine.refresh()
    let summary = engine.shown.first { $0.suggestion.kind == "focus.summary" }?.suggestion
    #expect(summary?.detail == "25 min · 1 task done · Codex finished")  // only what happened during it
    #expect(engine.shown.contains { $0.suggestion.kind == "meeting.after" && $0.suggestion.primary == .switchWorkspace(development.id) })
    clock = at(10, 40)
    engine.refresh()
    #expect(!engine.shown.contains { $0.suggestion.kind == "meeting.after" })  // 15 minutes after: gone
    engine.stop()
}

@MainActor @Test func diagnosticsCanBeTurnedOff() {
    let model = FakeModel()
    let engine = ContextEngine(file: nil, now: { at(10) }, calendar: calendar)
    engine.register(ContextSource(id: "tasks", name: "Tasks") { s in s.openTasks = model.tasks })
    var prefs = SuggestionPreferences()
    prefs.diagnostics = false
    engine.preferences = prefs
    engine.start()
    model.tasks = [task("A")]
    engine.refresh()
    engine.noteAutomation("Automation ran")
    #expect(engine.events.isEmpty)
    engine.stop()
}

@Test func theBriefingKeepsFactsAndSuggestionsApart() {
    var inputs = DailyDigest.Inputs()
    inputs.workspace = "Development"
    inputs.goals = [task("Ship", done: at(9)), task("Read")]
    inputs.agentsWaiting = ["Claude Code"]
    inputs.agentsDoneToday = ["Codex", "Codex"]
    inputs.focusSessionsToday = 2
    inputs.suggestions = ["Start a focus session"]
    let facts = DailyDigest.facts(inputs, now: at(10))
    #expect(facts.map(\.source) == ["Workspace", "Goals", "AI Hub", "Focus"])
    #expect(facts[1].text == "1 of 2 daily goals done; next: Read")
    #expect(facts[2].text == "Claude Code waiting for you; 2 agent sessions finished today")
    #expect(!facts.contains { $0.text.contains("focus session") && $0.source != "Focus" })  // a suggestion is never a fact
    #expect(!DailyDigest.messages(facts, now: at(10))[1].content.contains("Start a focus session"))  // nor sent to a model as one
    #expect(DailyDigest.facts(.init(), now: at(10)).isEmpty)
}

@MainActor @Test func automationsUseTheSameContextAndSayWhy() {
    var runs: [Automations.Run] = []
    let automations = Automations(perform: { _ in true }, now: { at(10) }, calendar: calendar)
    automations.onRun = { runs.append($0) }
    automations.rules = [AutomationRule(trigger: .meetingSoon, condition: .onBattery, action: .keepAwakeHour),
                         AutomationRule(trigger: .agentFinished, condition: .notDuringFocus, action: .pauseMusic)]
    automations.fire(.meetingSoon, context: .init(onBattery: false), reason: "“Standup” starts in 4 min")
    automations.fire(.agentFinished, context: .init(focusRunning: true), reason: "An agent finished")
    #expect(runs.map(\.outcome) == [.skipped("on power"), .skipped("focus session running")])
    #expect(runs[0].reason == "“Standup” starts in 4 min")
    automations.fire(.agentFinished, context: .init(focusRunning: false))
    #expect(runs.last?.outcome == .done)
    #expect(AutomationRule.Condition.allCases.count == 5)
}

@MainActor @Test func quickActionChipsStepAsideForSuggestions() {
    let widget = QuickActionsWidget(perform: { _ in })
    widget.context = { QuickContext(project: "/p/orbit") }
    #expect(!ContextAction.suggest(widget.context()).isEmpty)
    widget.hidesSuggestions = { true }
    _ = widget.content(.compact)  // renders with no chip row (one place for suggestions)
}

@MainActor @Test func theEngineIsCheapUnderRepeatedEvents() {
    var s = ContextSnapshot()
    s.openTasks = (0 ..< 300).map { task("Task \($0)") }
    s.agents = (0 ..< 150).map { agent("Agent\($0)", $0 % 3 == 0 ? .waiting : .running, at: at(9, $0 % 60)) }
    s.workspaces = (0 ..< 10).map { WorkspaceProfile(name: "Space \($0)") }
    let engine = ContextEngine(file: nil, now: { at(10) }, calendar: calendar)
    engine.register(ContextSource(id: "big", name: "Big") { snapshot in snapshot = s })
    engine.start()
    let clock = ContinuousClock()
    let start = clock.now
    for _ in 0 ..< 200 { engine.refresh() }
    let average = start.duration(to: clock.now) / 200
    #expect(average < .milliseconds(10), "average refresh \(average)")
    #expect(engine.events.count <= ContextEngine.eventLimit)  // bounded memory
    engine.stop()
}

@Test func suggestionPreferencesDecodeTolerantly() throws {
    let prefs = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"suggestions":{"enabled":false,"disabledCategories":["battery","nonsense"],"snoozeMinutes":5}}"#.utf8))
    #expect(!prefs.suggestions.enabled && prefs.suggestions.disabledCategories == [.battery] && prefs.suggestions.snoozeMinutes == 10)
    let defaults = OrbitPreferences().suggestions
    #expect(defaults.enabled && defaults.frequency == .calm && defaults.diagnostics && defaults.workspaceRecommendations)
}

@MainActor @Test func suggestionStripRenders() throws {
    let engine = ContextEngine(file: nil, now: { at(10) }, calendar: calendar)
    engine.register(ContextSource(id: "s", name: "s") { s in
        s.agents = [agent("Claude Code", .waiting, at: at(9, 59))]
        s.meeting = MeetingCue(eventID: "m", title: "Design review", start: at(10, 4), phase: .soon,
                               joinURL: URL(string: "https://zoom.us/j/1"), end: at(10, 30))
    })
    engine.start()
    let view = SuggestionStrip(engine: engine).padding(14).frame(width: 740, height: 90, alignment: .top)
        .background(LinearGradient(colors: [Color(red: 0.22, green: 0.26, blue: 0.40), Color(red: 0.40, green: 0.30, blue: 0.36)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark)
    let host = NSHostingView(rootView: view)
    let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 740, height: 90), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.displayIfNeeded()
    CATransaction.flush()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    engine.stop()
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m17").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "suggested-for-you.png"))
}
