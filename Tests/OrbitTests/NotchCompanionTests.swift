import AppKit
import SwiftUI
import Testing
@testable import Orbit

// The Notch Companion (docs/AI_HUB_SPEC.md §22): its state machine, lifecycle
// and timers, the cat's reactions, several agents and sessions, display
// geometry, full screen and Space changes, Coucou, the panel priority, and
// render-based QA of every phase.

private let start = Date(timeIntervalSince1970: 1_800_000_000)

@MainActor
private final class Clock {
    var now = start
}

private func session(_ id: String, _ status: AgentSession.Status, agent: String = "claude-code", ago: TimeInterval = 0,
                     title: String? = nil, cwd: String? = "/tmp/project", bundle: String? = "com.microsoft.VSCode") -> AgentSession {
    AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: id)!, title: title ?? id, cwd: cwd, status: status,
                 startedAt: start - ago - 60, lastEventAt: start - ago, originBundleID: bundle)
}

private func event(_ session: AgentSession, _ kind: AgentEvent.Kind, _ summary: String? = nil, files: [String] = []) -> AgentEvent {
    AgentEvent(id: UUID(), session: session.key, kind: kind, nativeName: kind.rawValue, occurredAt: start, receivedAt: start,
               cwd: session.cwd, tool: nil, summary: summary, files: files, dedupeKey: UUID().uuidString)
}

@MainActor
private func companion(_ scheduler: FakeScheduler = FakeScheduler(), clock: Clock = Clock()) -> NotchCompanion {
    NotchCompanion(scheduler: scheduler, now: { clock.now })
}

@MainActor
private func update(_ companion: NotchCompanion, available: Bool = true, _ sessions: [AgentSession], events: [AgentEvent] = [],
                    requests: [ApprovalDraft] = [], coucouAnswers: Bool = false) {
    companion.update(available: available, sessions: sessions, events: Dictionary(grouping: events, by: \.session), requests: requests,
                     waiting: { WaitingPlace.of($0, coucouAnswersClaude: coucouAnswers) })
}

// MARK: State machine

@Test func theIslandTableAllowsExactlyItsTransitions() {
    typealias C = NotchCompanion
    let phases: [C.Phase] = [.hidden, .idle, .compact, .expanded]
    let events: [C.Event] = [.available(true), .available(false), .active(true), .active(false), .tap, .collapse, .spaceChanged]
    var allowed: [String] = []
    for phase in phases {
        for event in events {
            for active in [false, true] {
                if let next = C.next(phase, event, active: active) { allowed.append("\(phase)-\(event)-\(active)->\(next)") }
            }
        }
    }
    #expect(Set(allowed) == [
        "hidden-available(true)-false->idle", "hidden-available(true)-true->compact",
        "idle-available(false)-false->hidden", "idle-available(false)-true->hidden",
        "compact-available(false)-false->hidden", "compact-available(false)-true->hidden",
        "expanded-available(false)-false->hidden", "expanded-available(false)-true->hidden",
        "idle-active(true)-false->compact", "idle-active(true)-true->compact",
        "compact-active(false)-false->idle", "compact-active(false)-true->idle",
        "idle-tap-false->expanded", "idle-tap-true->expanded", "compact-tap-false->expanded", "compact-tap-true->expanded",
        "expanded-collapse-false->idle", "expanded-collapse-true->compact",
        "expanded-spaceChanged-false->idle", "expanded-spaceChanged-true->compact",
    ])
}

// MARK: Lifecycle

@MainActor @Test func hiddenIdleCompactExpandedAndBackWithNoTimersAtRest() {
    let scheduler = FakeScheduler()
    let companion = companion(scheduler)
    var phases: [NotchCompanion.Phase] = []
    companion.onPhaseChange = { phases.append($1) }
    update(companion, available: false, [])
    #expect(companion.phase == .hidden && phases.isEmpty)
    update(companion, [])
    #expect(companion.phase == .idle)  // the cat peeks: nothing to report
    let working = session("w", .running)
    update(companion, [working], events: [event(working, .toolStarted, "Edit OrbitApp.swift")])
    #expect(companion.phase == .compact && companion.lead?.headline == "Edit OrbitApp.swift")
    companion.tap()
    #expect(companion.phase == .expanded && companion.selected == working.key)
    companion.collapse()
    #expect(companion.phase == .compact)
    update(companion, [session("w", .idle)])  // the turn ended
    #expect(companion.phase == .idle)
    update(companion, available: false, [])
    #expect(companion.phase == .hidden)
    #expect(phases == [.idle, .compact, .expanded, .compact, .idle, .hidden])
    #expect(scheduler.live == 0 && companion.pendingTimers == 0)  // nothing scheduled at rest or while working
}

@MainActor @Test func finishedAndFailedMomentsEndByThemselvesAndShutdownLeavesNothing() {
    let scheduler = FakeScheduler()
    let clock = Clock()
    let companion = companion(scheduler, clock: clock)
    var cues: [AgentCue] = []
    companion.onCue = { cues.append($0) }
    let done = session("d", .idle)
    update(companion, [done])
    #expect(companion.phase == .idle)
    companion.receive([event(done, .turnCompleted)])
    #expect(companion.phase == .compact && companion.flash?.tone == .finished && cues == [.finished] && companion.pendingTimers == 1)
    scheduler.advance(NotchCompanion.flashFor)
    #expect(companion.flash == nil && companion.phase == .idle && companion.pendingTimers == 0)

    let broken = session("b", .failed)
    update(companion, [broken], events: [event(broken, .error, "rate limited")])
    companion.receive([event(broken, .error, "rate limited")])
    #expect(companion.lead?.headline == "rate limited" && companion.flash?.tone == .failed && cues.last == .failed)
    companion.receive([event(broken, .waitingForUser)])
    #expect(cues.last == .attention)
    companion.receive([event(broken, .toolStarted), event(broken, .toolStarted)])  // throttled: one tail flick
    clock.now += 1
    companion.receive([event(broken, .fileChanged)])
    #expect(cues.filter { $0 == .activity }.count == 1)
    clock.now += NotchCompanion.activityCueInterval
    companion.receive([event(broken, .fileChanged)])
    #expect(cues.filter { $0 == .activity }.count == 2)

    companion.shutdown()
    #expect(companion.phase == .hidden && companion.pendingTimers == 0 && scheduler.live == 0)
}

// MARK: Several agents and sessions

@MainActor @Test func theMostUrgentSessionLeadsAndTheUserCanSwitch() {
    let companion = companion()
    let codex = session("x", .running, agent: "codex", ago: 5, title: "payments-api")
    let claude = session("c", .waiting, ago: 50, title: "Orbit")
    let failed = session("p", .failed, agent: "copilot-cli", ago: 100, title: "site")
    let old = session("old", .completed, ago: NotchCompanion.recent + 1)  // finished long ago: not listed
    let simulated = session("s", .running, agent: "demo-alpha", ago: 1, title: "Atlas")
    update(companion, [codex, claude, failed, old, simulated], coucouAnswers: true)
    #expect(companion.rows.map(\.session.title) == ["Orbit", "site", "Atlas", "payments-api"])
    #expect(companion.rows.first?.headline == "Answer in Coucou")  // Claude in VS Code while Coucou answers
    update(companion, [codex, claude, failed, simulated])
    #expect(companion.rows.first?.headline == "Waiting in terminal")
    #expect(companion.lead?.session.key == claude.key && companion.phase == .compact)

    companion.tap()
    #expect(companion.selected == claude.key)
    companion.selectNext(1)
    #expect(companion.selected == failed.key)
    companion.selectNext(-2)  // wraps
    #expect(companion.selected == codex.key)
    companion.select(simulated.key)
    #expect(companion.selectedRow?.session.isDemo == true && companion.changes == nil)  // simulated: no repository read
    update(companion, [codex, claude, failed])  // the selected session went away
    #expect(companion.selected == claude.key)

    let many = (0 ..< 9).map { session("m\($0)", .running, ago: Double($0)) }
    update(companion, many)
    #expect(companion.rows.count == NotchCompanion.maxRows && companion.rows.first?.session.key.nativeID == "m0")
    let asking = SessionKey(agent: AgentID("demo-beta")!, nativeID: "r")!
    let drafts = (0 ..< 2).map { ApprovalDraft(session: asking, kind: .permission, nativeName: "x", tool: "Bash", summary: "Run \($0)", options: [],
                                                createdAt: start, expiresAt: start + 30) }
    update(companion, [], requests: drafts)  // two requests from a session Orbit had no events from
    #expect(companion.isActive && companion.rows.map(\.id) == [asking] && companion.rows.first?.pending.count == 2)
}

@MainActor @Test func aRowNamesItsFilesNewestFirst() {
    let working = session("w", .running)
    let rows = NotchCompanion.rows([working], events: [working.key: [
        event(working, .toolStarted, "Read a", files: ["/p/a.swift"]),
        event(working, .fileChanged, "Edit b", files: ["/p/b.swift", "/p/a.swift"]),
    ]], now: start, waiting: { _ in nil })
    #expect(rows.first?.files == ["/p/b.swift", "/p/a.swift"] && rows.first?.headline == "Edit b")
}

// MARK: Display, full screen, Space changes, Coucou

@Test func itSitsCentredBelowTheNotchOrTheMenuBarOnAnyDisplay() {
    let notched = CGRect(x: 0, y: 0, width: 1512, height: 982)
    let trigger = NotchGeometry.triggerRect(screen: notched, visible: CGRect(x: 0, y: 0, width: 1512, height: 944),
                                            left: CGRect(x: 0, y: 950, width: 660, height: 32), right: CGRect(x: 852, y: 950, width: 660, height: 32))
    for phase in [NotchCompanion.Phase.idle, .compact, .expanded] {
        let rect = CompanionGeometry.rect(phase, trigger: trigger, screen: notched)
        #expect(rect.size == CompanionGeometry.size(phase))
        #expect(abs(rect.midX - trigger.midX) < 0.5 && rect.maxY == trigger.minY - MusicIslandGeometry.gap)
    }
    let plain = CGRect(x: 1512, y: 0, width: 1920, height: 1080)  // an external display, no notch
    let bar = NotchGeometry.triggerRect(screen: plain, visible: CGRect(x: 1512, y: 0, width: 1920, height: 1055), left: nil, right: nil)
    let expanded = CompanionGeometry.rect(.expanded, trigger: bar, screen: plain)
    #expect(plain.contains(expanded) && abs(expanded.midX - plain.midX) < 0.5)
    let small = CGRect(x: 0, y: 0, width: 1024, height: 768)  // a trigger at the edge: kept on screen
    #expect(small.contains(CompanionGeometry.rect(.expanded, trigger: CGRect(x: 0, y: 744, width: 100, height: 24), screen: small)))
}

@MainActor @Test func aSpaceChangeCollapsesAndSleepOrFullScreenHidesEverything() {
    let companion = companion()
    let working = session("w", .running)
    update(companion, [working])
    companion.tap()
    companion.spaceChanged()
    #expect(companion.phase == .compact)  // nothing follows the user to another Space
    companion.spaceChanged()
    #expect(companion.phase == .compact)

    // Display asleep, locked, or a full-screen Space: the app makes it unavailable and tells the pet nobody sees it.
    update(companion, available: false, [working])
    #expect(companion.phase == .hidden)
    let activity = PetActivity(scheduler: FakeScheduler())
    let pet = PetModel(activity: activity, scheduler: FakeScheduler())
    pet.toggles = .init(pet: true, desktop: false, companion: true)
    #expect(pet.state == .idle || pet.state == .sleeping)
    activity.setCompanionOccluded(true)  // what syncCompanionPet does when it isn't on the active Space
    #expect(pet.state == .hidden && pet.pendingTimers == 0)
    activity.setCompanionOccluded(false)
    activity.setDisplayAsleep(true)
    #expect(pet.state == .hidden)
}

@MainActor @Test func coucouLaunchingHidesItAndQuittingBringsItBack() {
    let companion = companion()
    let working = session("w", .running)
    func available(_ owner: NotchCoordination.Owner) -> Bool {
        NotchCoordination.holder(.init(owner: owner, companion: true)) == .companion
    }
    update(companion, available: available(.orbit), [working])
    companion.tap()
    #expect(companion.phase == .expanded)
    update(companion, available: available(.coucou), [working])  // Coucou launched
    #expect(companion.phase == .hidden && companion.changes == nil)
    update(companion, available: available(.orbit), [working])  // and quit
    #expect(companion.phase == .compact)
}

@Test func theCompanionIsLastInLineAndNothingButTheDashboardStaysForCoucou() {
    func holder(_ inputs: NotchCoordination.Inputs) -> NotchCoordination.Surface? { NotchCoordination.holder(inputs) }
    var inputs = NotchCoordination.Inputs(companion: true)
    #expect(holder(inputs) == .companion)
    let steps: [(NotchCoordination.Surface, (inout NotchCoordination.Inputs) -> Void)] = [
        (.agentAlert, { $0.alert = true }), (.compactMusic, { $0.island = .compact }), (.volumeHUD, { $0.volumeHUD = true }),
        (.expandedMusic, { $0.island = .expanded }), (.dashboard, { $0.dashboardOpen = true }),
    ]
    for (surface, change) in steps {
        change(&inputs)
        #expect(holder(inputs) == surface)  // each higher surface takes the slot from the ones below
    }
    inputs.owner = .coucou
    #expect(holder(inputs) == .dashboard)  // opened from ⌃⌥⌘O
    inputs.dashboardOpen = false
    #expect(holder(inputs) == nil)  // music, HUD, alert and companion all step aside
}

// MARK: The cat

@MainActor @Test func agentCuesAreOneShotsAndMoodIsAStillPose() {
    let rig = PetRig(size: 40)
    rig.play(.finished)
    #expect(rig.cuesPlayed == 0)  // hidden: nothing
    rig.apply(.idle, reduceMotion: false)
    for cue in [AgentCue.activity, .attention, .finished, .failed] { rig.play(cue) }
    #expect(rig.cuesPlayed == 4 && rig.animationCount > 0 && rig.repeatingAnimationCount == 0)
    rig.setMood(.needsYou)
    #expect(rig.pose == PetRig.pose(for: .idle, mood: .needsYou) && rig.pose != PetRig.pose(for: .idle))
    #expect(PetRig.pose(for: .walking, mood: .failed) == PetRig.pose(for: .walking))  // moods only tint the rest pose
    #expect(rig.repeatingAnimationCount == 0)

    let still = PetRig(size: 40)
    still.apply(.idle, reduceMotion: true)
    still.play(.finished)
    #expect(still.cuesPlayed == 0 && still.repeatingAnimationCount == 0)  // Reduce Motion: words and symbols only
    rig.apply(.hidden, reduceMotion: false)
    #expect(rig.animationCount == 0)
}

// MARK: Render-based QA

private func git(_ arguments: [String], in folder: URL) throws {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "init.defaultBranch=main"] + arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try process.run()
    process.waitUntilExit()
}

@MainActor
private func render(_ companion: NotchCompanion, hub: AIHubService, rig: PetRig, _ name: String) throws {
    let size = CompanionGeometry.size(companion.phase)
    let view = NotchCompanionView(companion: companion, hub: hub, rig: rig, actions: CompanionActions())
        .frame(width: size.width, height: size.height)
        .padding(20)
        .background(Color(white: 0.32))
        .environment(\.colorScheme, .dark)
        .environment(\.hubStaticRender, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage, "\(name) didn't render")
    #expect(image.width == Int(size.width + 40) * 2)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/notch-companion").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}

@MainActor @Test func everyCompanionPhaseRendersWithARealDiff() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let repo = temp.url.appending(path: "Orbit")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    try git(["init", "-q"], in: repo)
    let file = repo.appending(path: "OrbitApp.swift")
    try (1 ... 12).map { "let line\($0) = \($0)" }.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
    try git(["add", "-A"], in: repo)
    try git(["commit", "-q", "-m", "First"], in: repo)
    try ((1 ... 12).map { $0 % 4 == 0 ? "let line\($0) = \($0 * 10)  // changed" : "let line\($0) = \($0)" } + ["let added = true"])
        .joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)

    let hub = AIHubService(paths: .init(socket: "/tmp/unused.sock", store: temp.url.appending(path: "h.sqlite"),
                                        demoStore: temp.url.appending(path: "d.sqlite")), scheduler: FakeScheduler(), discover: { [] })
    let rig = PetRig(size: CompanionGeometry.catSize)
    rig.apply(.idle, reduceMotion: true)
    let companion = NotchCompanion(scheduler: FakeScheduler())
    let path = repo.path(percentEncoded: false)
    let claude = AgentSession(key: SessionKey(agent: AgentID("claude-code")!, nativeID: "c1")!, title: "Orbit", cwd: path, status: .running,
                              startedAt: .now - 600, lastEventAt: .now, originBundleID: "com.microsoft.VSCode")
    let codex = AgentSession(key: SessionKey(agent: AgentID("codex")!, nativeID: "x1")!, title: "payments-api", cwd: "/tmp/none",
                             status: .waiting, startedAt: .now - 900, lastEventAt: .now - 30)
    let edit = AgentEvent(id: UUID(), session: claude.key, kind: .toolStarted, nativeName: "PreToolUse", occurredAt: .now, receivedAt: .now,
                          cwd: path, tool: "Edit", summary: "Edit OrbitApp.swift", files: [file.path(percentEncoded: false)], dedupeKey: "e")
    func feed(_ sessions: [AgentSession]) {
        companion.update(available: true, sessions: sessions, events: [claude.key: [edit]], requests: [], waiting: hub.waitingPlace(of:))
    }

    feed([])
    try render(companion, hub: hub, rig: rig, "1-idle")
    feed([claude])
    try render(companion, hub: hub, rig: rig, "2-compact-working")
    feed([claude, codex])
    try render(companion, hub: hub, rig: rig, "3-compact-needs-you")
    companion.receive([AgentEvent(id: UUID(), session: claude.key, kind: .turnCompleted, nativeName: "Stop", occurredAt: .now, receivedAt: .now,
                                  cwd: path, tool: nil, summary: nil, files: [], dedupeKey: "t")])
    try render(companion, hub: hub, rig: rig, "4-compact-finished")
    companion.tap()
    companion.select(claude.key)
    for _ in 0 ..< 200 where companion.diffText == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(companion.changes?.files.first?.path == "OrbitApp.swift" && companion.changes?.files.first?.touchedBySession == true)
    #expect(companion.diffText?.contains("+let added = true") == true)  // real git, through CodeChangeService
    try render(companion, hub: hub, rig: rig, "5-expanded-diff")
    let contrast = HubAppearance.shared.increasedContrast
    HubAppearance.shared.increasedContrast = true
    try render(companion, hub: hub, rig: rig, "6-expanded-increased-contrast")
    HubAppearance.shared.increasedContrast = contrast
    companion.selectNext(1)
    try render(companion, hub: hub, rig: rig, "7-expanded-other-session")
}
