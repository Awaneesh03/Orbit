import AppKit
import SwiftUI
import Testing
@testable import Orbit

// AI Hub 2.0 visual QA without Screen Recording: every screen rendered
// in-process (ImageRenderer) at the dashboard's real content size with
// realistic fixtures. Always checks each renders; with ORBIT_RENDER=1 the PNGs
// are written to docs/screenshots/ai-hub-2/ for inspection.

@MainActor
private func fixtureHub() async throws -> (AIHubService, () -> Void) {
    let temp = TemporaryDirectory()
    let folder = FileManager.default.temporaryDirectory.appending(path: "or-\(UUID().uuidString.prefix(8))")
    let hub = AIHubService(paths: .init(socket: folder.appending(path: "a.sock").path(percentEncoded: false),
                                        store: temp.url.appending(path: "hub.sqlite"), demoStore: temp.url.appending(path: "demo.sqlite")),
                           scheduler: FakeScheduler(),
                           discover: { [.init(id: "claude-code", name: "Claude Code", path: "/x"), .init(id: "codex", name: "OpenAI Codex", path: "/y"),
                                        .init(id: "cursor", name: "Cursor", path: nil)] })
    hub.manifestFolder = nil
    hub.set(enabled: true, demo: false)
    await hub.settled()
    let now = Date.now
    func event(_ agent: String, _ session: String, _ kind: AgentEvent.Kind, _ summary: String, tool: String? = nil, ago: TimeInterval,
               cwd: String, files: [String] = []) -> AgentEvent {
        AgentEvent(id: UUID(), session: SessionKey(agent: AgentID(agent)!, nativeID: session)!, kind: kind, nativeName: kind.rawValue,
                   occurredAt: now - ago, receivedAt: now - ago, cwd: cwd, tool: tool, summary: summary, files: files, dedupeKey: UUID().uuidString)
    }
    let orbit = "/Users/me/Developer/Orbit", api = "/Users/me/Developer/payments-api", web = "/Users/me/Developer/marketing-site"
    hub.real.apply([
        event("claude-code", "c1", .sessionStarted, "Session started (startup)", ago: 2400, cwd: orbit),
        event("claude-code", "c1", .promptSubmitted, "Prompt submitted", ago: 2390, cwd: orbit),
        event("claude-code", "c1", .toolStarted, "Read AIHubDesign.swift", tool: "Read", ago: 300, cwd: orbit, files: ["\(orbit)/AIHubDesign.swift"]),
        event("claude-code", "c1", .fileChanged, "Changed AgentSessionsView.swift", tool: "Edit", ago: 120, cwd: orbit, files: ["\(orbit)/AgentSessionsView.swift"]),
        event("claude-code", "c1", .toolStarted, "Bash: ./scripts/test.sh --filter AIHub", tool: "Bash", ago: 20, cwd: orbit),
        event("codex", "x9", .sessionStarted, "Session started", ago: 900, cwd: api),
        event("codex", "x9", .toolCompleted, "apply_patch: *** Begin Patch", tool: "apply_patch", ago: 400, cwd: api),
        event("codex", "x9", .waitingForUser, "Waiting for you in the agent (inferred)", ago: 60, cwd: api),
        event("copilot-cli", "p3", .sessionStarted, "Session started", ago: 7200, cwd: web),
        event("copilot-cli", "p3", .sessionEnded, "Session ended", ago: 3600, cwd: web),
    ])
    hub.demo.apply([event("demo-alpha", "sim-1", .toolStarted, "Simulated: running the tests", tool: "Bash", ago: 10, cwd: "/Simulated/Atlas")])
    hub.approvals.add(connection: 1, draft: ApprovalDraft(
        session: SessionKey(agent: AgentID("copilot-cli")!, nativeID: "p4")!, kind: .permission, nativeName: "permissionRequest", tool: "bash",
        summary: "bash: npm run migrate", options: [], createdAt: now, expiresAt: now + 25,
        detail: "npm run migrate\nnpm run seed -- --env=staging"))
    hub.approvals.add(connection: 2, draft: ApprovalDraft(
        session: SessionKey(agent: AgentID("demo-beta")!, nativeID: "sim-request-7")!, kind: .question, nativeName: "questionAsked", tool: nil,
        summary: "Simulated question: which database should the demo use?", options: ["SQLite", "Postgres", "In memory"],
        createdAt: now, expiresAt: now + 55))
    hub.insights = AIHubService.Insights(
        days: [("2026-11-08", 42), ("2026-11-09", 12), ("2026-11-10", 88), ("2026-11-11", 64), ("2026-11-12", 120), ("2026-11-13", 96), ("2026-11-14", 31)],
        agents: [.init(agent: "claude-code", sessions: 14, events: 380, activeSeconds: 41_000), .init(agent: "codex", sessions: 6, events: 140, activeSeconds: 12_600),
                 .init(agent: "copilot-cli", sessions: 3, events: 33, activeSeconds: 3_100)],
        approvals: ["allowed": 5, "denied": 1, "expired": 2],
        tools: [("Bash", 210), ("Edit", 160), ("Read", 140), ("apply_patch", 60), ("Grep", 44)],
        statuses: ["completed": 9, "ended": 8, "failed": 2, "running": 2],
        projects: [(orbit, 11), (api, 6), (web, 3)])
    hub.insights.filesChanged = 57
    hub.insights.previousWeekEvents = 380
    hub.insights.since = now.addingTimeInterval(-6 * 86_400)
    hub.insights.historyStart = now.addingTimeInterval(-40 * 86_400)
    hub.insights.longest = ("claude-code", orbit, 9_400)
    return (hub, { hub.set(enabled: false, demo: false); temp.cleanup(); try? FileManager.default.removeItem(at: folder) })
}

@MainActor
private func render(_ hub: AIHubService, _ name: String) throws {
    let view = AIHubPage(hub: hub, chat: [])
        .frame(width: 708, height: 330)
        .padding(16)
        .background(HubTokens.canvas)
        .environment(\.colorScheme, .dark)
        .environment(\.hubStaticRender, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage, "\(name) didn't render")
    #expect(image.width == 740 * 2 && image.height == 362 * 2)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/ai-hub-2").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}

@MainActor @Test func everyAIHubScreenRenders() async throws {
    let (hub, cleanup) = try await fixtureHub()
    defer { cleanup() }
    let browser = hub.browser
    browser.page = .overview
    try render(hub, "1-overview")
    browser.page = .agents
    try render(hub, "2-agents")
    browser.select(try #require(hub.real.sessions[SessionKey(agent: AgentID("claude-code")!, nativeID: "c1")!]), in: hub)
    try render(hub, "3-session-timeline")
    browser.page = .approvals
    try render(hub, "4-approvals")
    _ = hub.approvals.decide(try #require(hub.approvals.pending.first).id, .deny)
    browser.showsApprovalHistory = true
    try render(hub, "5-approval-history")
    browser.page = .insights
    try render(hub, "6-insights")
    browser.page = .chat
    try render(hub, "7-chat")
    hub.set(enabled: false, demo: false)
    await hub.settled()
    browser.page = .overview
    try render(hub, "8-off")
}

@MainActor @Test func theNotchAlertRenders() throws {
    let alerts = AgentAlerts(scheduler: FakeScheduler())
    alerts.receive(request: ApprovalDraft(session: SessionKey(agent: AgentID("copilot-cli")!, nativeID: "p")!, kind: .permission, nativeName: "x",
                                          tool: "bash", summary: "s", options: [], createdAt: .now, expiresAt: .now + 20))
    let renderer = ImageRenderer(content: AgentAlertView(alerts: alerts).frame(width: 300, height: 32).background(Color(white: 0.3)))
    renderer.scale = 3
    let image = try #require(renderer.cgImage)
    #expect(alerts.current?.agent?.rawValue == "copilot-cli" && image.width == 900)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/ai-hub-2/9-notch-alert.png").standardized)
}

// MARK: Accessibility follow-ups

@MainActor @Test func notchAlertsHonourOrbitsReduceMotionToo() {
    let alerts = AgentAlerts(scheduler: FakeScheduler())
    let system = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    #expect(alerts.effectiveReduceMotion == system)
    alerts.reduceMotion = true  // Orbit's own preference
    #expect(alerts.effectiveReduceMotion)
}

@MainActor @Test func increaseContrastStrengthensTextAndBorders() async throws {
    let appearance = HubAppearance.shared
    let original = appearance.increasedContrast
    defer { appearance.increasedContrast = original }
    appearance.increasedContrast = false
    let normal = (HubTokens.textTertiary, HubTokens.border, HubTokens.textSecondary)
    appearance.increasedContrast = true
    #expect(HubTokens.textTertiary != normal.0 && HubTokens.border != normal.1 && HubTokens.textSecondary != normal.2)
    let (hub, cleanup) = try await fixtureHub()
    defer { cleanup() }
    try render(hub, "10-overview-increased-contrast")
}

@MainActor @Test func copyingConfirmsBrieflyWithoutTouchingTheUsersClipboard() async throws {
    let browser = AgentBrowser()
    let pasteboard = NSPasteboard(name: .init("orbit-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    browser.copy("weekly summary", to: pasteboard, confirmFor: .milliseconds(50))
    #expect(browser.copied && pasteboard.string(forType: .string) == "weekly summary")
    for _ in 0 ..< 100 where browser.copied { try await Task.sleep(for: .milliseconds(10)) }
    #expect(!browser.copied)  // the confirmation goes away by itself
}

@MainActor @Test func aFailedDecisionSaysWhyAndASuccessfulOneClearsIt() throws {
    let scheduler = FakeScheduler()
    let approvals = ApprovalManager(scheduler: scheduler)
    approvals.output = { OrbitEventAdapter.demo.output(for: $0, to: $1) }
    let browser = AgentBrowser()
    let session = SessionKey(agent: AgentID("demo-beta")!, nativeID: "r")!
    approvals.add(connection: 1, draft: ApprovalDraft(session: session, kind: .question, nativeName: "x", tool: nil, summary: "s",
                                                      options: ["A", "B"], createdAt: .now, expiresAt: .now + 30))
    let request = try #require(approvals.pending.first)
    #expect(!browser.decide(request, .answer("Z"), in: approvals))
    #expect(browser.decisionError?.contains("isn't one the agent offered") == true)
    #expect(browser.decide(request, .answer("A"), in: approvals) && browser.decisionError == nil)
    #expect(!browser.decide(request, .answer("B"), in: approvals))  // already answered
    #expect(browser.decisionError?.contains("no longer waiting") == true)
}

// MARK: Coexistence with Coucou (docs/AI_HUB_SPEC.md §21)

@MainActor @Test func whereToAnswerAndChangesRender() async throws {
    let (hub, cleanup) = try await fixtureHub()
    defer { cleanup() }
    var waiting = AgentEvent(id: UUID(), session: SessionKey(agent: AgentID("claude-code")!, nativeID: "vs1")!, kind: .waitingForUser,
                             nativeName: "PreToolUse", occurredAt: .now - 30, receivedAt: .now - 30, cwd: "/Users/me/Developer/Orbit", tool: "AskUserQuestion",
                             summary: "Asked a question (inferred; Orbit doesn't answer it)", files: [], dedupeKey: "vs1-wait")
    waiting.origin = AgentOrigin(bundleID: "com.microsoft.VSCode", pid: 4242)
    hub.real.apply([waiting])
    let session = try #require(hub.real.sessions[waiting.session])
    let browser = hub.browser

    hub.coucouAnswersClaude = true  // Coucou runs and answers Claude in VS Code
    browser.select(session, in: hub)
    try render(hub, "11-session-answer-in-coucou")
    browser.page = .overview
    try render(hub, "12-overview-answer-in-coucou")
    hub.coucouAnswersClaude = false  // Coucou quit
    browser.select(session, in: hub)
    try render(hub, "13-session-waiting-in-terminal")

    browser.detailTab = .changes
    browser.changes = CodeChangeService.Snapshot(root: "/Users/me/Developer/Orbit", branch: "main", commit: "353f578", subject: "Orbit Pet",
                                                 files: [.init(path: "Sources/Orbit/OrbitApp.swift", status: " M", additions: 100, deletions: 1, touchedBySession: true),
                                                         .init(path: "docs/AI_HUB_SPEC.md", status: "??", additions: nil, deletions: nil, touchedBySession: true),
                                                         .init(path: "Package.swift", status: " M", additions: 4, deletions: 0)])
    browser.diffPath = "Sources/Orbit/OrbitApp.swift"
    browser.diffText = (["diff --git a/Sources/Orbit/OrbitApp.swift b/Sources/Orbit/OrbitApp.swift", "@@ -141,6 +141,9 @@ final class AppDelegate"]
        + (0 ..< 30).map { $0 % 4 == 0 ? "-        aiHub.alerts.isEnabled = value.aiHubAlerts" : "+        // line \($0) of the change" }).joined(separator: "\n")
    try render(hub, "14-session-changes-diff")
}
