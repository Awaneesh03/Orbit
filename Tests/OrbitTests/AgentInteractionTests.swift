import AppKit
import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import Orbit
import OrbitBridge

// Milestone 4 (docs/AI_HUB_SPEC.md §23): answering only where an adapter is
// verified, structured questions, the companion's switching, tabs, live
// activity and diff, safe file drops, Coucou, and renders.

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func key(_ agent: String, _ id: String) -> SessionKey { SessionKey(agent: AgentID(agent)!, nativeID: id)! }

private func draft(_ session: SessionKey, _ kind: ApprovalDraft.Kind = .permission, options: [String] = [], questions: [ApprovalQuestion] = [],
                   expires: TimeInterval = 30, summary: String = "Run the tests") -> ApprovalDraft {
    ApprovalDraft(session: session, kind: kind, nativeName: "x", tool: "Bash", summary: summary, options: options, createdAt: now,
                  expiresAt: now + expires, detail: kind == .permission ? "swift test\n  --parallel" : nil, questions: questions)
}

private let setup = [
    ApprovalQuestion(header: "Database", prompt: "Which database?", options: [.init(label: "SQLite", detail: "One file"), .init(label: "Postgres")]),
    ApprovalQuestion(header: "Extras", prompt: "What else?", options: [.init(label: "Seed data"), .init(label: "Indexes"), .init(label: "Fixtures")],
                     multiSelect: true),
]

// MARK: Capabilities: answering only what's verified

@Test func onlyVerifiedAdaptersDeclareAnswering() {
    for adapter in AgentRegistry.standard.adapters {
        let answers = adapter.manifest.capabilities.intersection([.answerPermissions, .answerQuestions])
        if adapter.manifest.id.isDemo {
            #expect(answers == [.answerPermissions, .answerQuestions])  // verified end to end (Phase 4)
        } else {
            #expect(answers.isEmpty, "\(adapter.manifest.id) must stay observe-only until verified")  // Claude (D1) and the unverified hook agents
        }
    }
    #expect(draft(key("codex", "c")).capability == .answerPermissions && draft(key("codex", "c"), .question).capability == .answerQuestions)
}

@MainActor @Test func theApprovalCenterRefusesWhatItsAdapterCantAnswer() {
    let scheduler = FakeScheduler()
    let approvals = ApprovalManager(scheduler: scheduler, now: { now })
    var replies: [(Int, [String: JSONValue]?)] = []
    approvals.reply = { replies.append(($0, $1)) }
    approvals.output = { OrbitEventAdapter.demo.output(for: $0, to: $1) }
    approvals.supports = { $0.session.agent.isDemo }
    approvals.add(connection: 1, draft: draft(key("codex", "c")))  // unverified adapter
    #expect(approvals.pending.isEmpty && replies.count == 1 && replies[0].0 == 1 && replies[0].1 == nil)  // the agent asks its user now
    #expect(scheduler.live == 0 && approvals.history.isEmpty)
    approvals.add(connection: 2, draft: draft(key("demo-beta", "r")))
    let request = approvals.pending[0]
    approvals.supports = { _ in false }  // the second lock holds even after a request was listed
    #expect(!approvals.decide(request.id, .allowOnce) && approvals.pending.count == 1)
}

@MainActor @Test func theBridgeClosesRequestsFromAdaptersThatCantBeAnswered() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = FileManager.default.temporaryDirectory.appending(path: "ou-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let hub = AIHubService(paths: .init(socket: folder.appending(path: "a.sock").path(percentEncoded: false),
                                        store: temp.url.appending(path: "hub.sqlite"), demoStore: temp.url.appending(path: "demo.sqlite")),
                           scheduler: FakeScheduler(), discover: { [] })
    hub.manifestFolder = nil
    hub.set(enabled: true, demo: false)
    await hub.settled()
    defer { hub.set(enabled: false, demo: false) }
    let envelope = AgentEnvelope(kind: .request, agent: "codex", event: "PermissionRequest", sentAt: .now, deadline: .now + 30,
                                 payload: ["session_id": .string("x1"), "tool_name": .string("Bash"), "tool_input": .object(["command": .string("rm -rf build")])])!
    let path = hub.paths.socket
    let started = Date()
    let result = Mutex<(done: Bool, decision: AgentDecision?)>((false, nil))
    DispatchQueue.global().async {
        let decision = AgentHookClient.request(envelope, socketPath: path)
        result.withLock { $0 = (true, decision) }
    }
    for _ in 0 ..< 300 where !result.withLock({ $0.done }) { try await Task.sleep(for: .milliseconds(10)) }
    #expect(result.withLock { $0.done && $0.decision?.output == nil })  // closed with no answer: Codex asks its user
    #expect(Date().timeIntervalSince(started) < 3)  // at once, not after the 30 s deadline
    #expect(hub.approvals.pending.isEmpty)
    for _ in 0 ..< 100 where hub.health.counters.unanswerable == 0 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(hub.health.counters.unanswerable == 1)
}

// MARK: Structured questions

@Test func structuredQuestionsAreParsedDefensively() {
    let questions = ApprovalQuestion.parse(.array([
        .object(["header": .string("Database"), "question": .string("Which one?\nreally"), "options": .array([
            .object(["label": .string("SQLite"), "description": .string("token=abc123secret")]), .string("Postgres"), .string("SQLite")])]),
        .object(["header": .string("Database"), "question": .string("Duplicate header"), "options": .array([.string("A"), .string("B")])]),
        .object(["header": .string("One"), "question": .string("Only one option"), "options": .array([.string("A")])]),
        .object(["question": .string("No header"), "options": .array([.string("A"), .string("B")])]),
        .string("not an object"),
        .object(["header": .string("Extras"), "question": .string("Any?"), "multiSelect": .string("yes"),  // not a bool: single
                 "options": .array((1 ... 9).map { .string("Option \($0)") })]),
    ]))
    #expect(questions.map(\.header) == ["Database", "Extras"])
    #expect(questions[0].prompt == "Which one? really" && questions[0].options.map(\.label) == ["SQLite", "Postgres"])  // one line; labels unique
    #expect(questions[0].options[0].detail == "token=[redacted]")
    #expect(!questions[1].multiSelect && questions[1].options.count == ApprovalQuestion.maxOptions)
    let many = ApprovalQuestion.parse(.array((1 ... 8).map {
        .object(["header": .string("Q\($0)"), "question": .string("?"), "options": .array([.string("A"), .string("B")])])
    }))
    #expect(many.count == ApprovalQuestion.maxQuestions)
    #expect(ApprovalQuestion.parse(.string("nope")).isEmpty && ApprovalQuestion.parse(nil).isEmpty)
}

@Test func onlyCompleteOfferedAnswersAreSent() {
    let valid = ["Database": ["SQLite"], "Extras": ["Seed data", "Indexes"]]
    #expect(ApprovalQuestion.valid(valid, for: setup))
    #expect(!ApprovalQuestion.valid(["Database": ["SQLite"]], for: setup))  // one unanswered
    #expect(!ApprovalQuestion.valid(["Database": ["SQLite", "Postgres"], "Extras": ["Indexes"]], for: setup))  // two for single choice
    #expect(!ApprovalQuestion.valid(["Database": ["MySQL"], "Extras": ["Indexes"]], for: setup))  // not offered
    #expect(!ApprovalQuestion.valid(["Database": ["SQLite"], "Extras": ["Indexes", "Indexes"]], for: setup))  // repeated
    #expect(!ApprovalQuestion.valid(valid.merging(["Other": ["x"]]) { $1 }, for: setup))  // extra key
    #expect(!ApprovalQuestion.valid(["Database": ["SQLite"], "Extras": []], for: setup))
    #expect(ApprovalQuestion.describe(valid, for: setup) == "Database: SQLite; Extras: Seed data, Indexes")

    let question = draft(key("demo-beta", "q"), .question, questions: setup)
    #expect(OrbitEventAdapter.demo.output(for: .answers(valid), to: question) == ["answers": .object([
        "Database": .array([.string("SQLite")]), "Extras": .array([.string("Seed data"), .string("Indexes")])])])
    #expect(OrbitEventAdapter.demo.output(for: .answers(["Database": ["SQLite"]]), to: question) == nil)
    #expect(OrbitEventAdapter.demo.output(for: .answer("SQLite"), to: question) == nil)  // a structured question needs structured answers
    #expect(HookAdapter.codex.output(for: .answers(valid), to: question) == nil)
}

@MainActor @Test func aStructuredAnswerIsRecordedReadably() {
    let approvals = ApprovalManager(scheduler: FakeScheduler(), now: { now })
    approvals.output = { OrbitEventAdapter.demo.output(for: $0, to: $1) }
    var sent: [String: JSONValue]?
    approvals.reply = { sent = $1 }
    approvals.add(connection: 1, draft: draft(key("demo-beta", "q"), .question, questions: setup))
    let id = approvals.pending[0].id
    #expect(!approvals.decide(id, .answers(["Database": ["SQLite"]])) && approvals.pending.count == 1)  // incomplete: nothing sent
    #expect(approvals.decide(id, .answers(["Database": ["Postgres"], "Extras": ["Fixtures"]])))
    #expect(approvals.history.first?.answer == "Database: Postgres; Extras: Fixtures" && sent?["answers"] != nil)
}

@MainActor @Test func untrustedRequestsWithoutUsableChoicesAreRefused() {
    func envelope(_ payload: [String: JSONValue]) -> AgentEnvelope {
        AgentEnvelope(kind: .request, agent: "demo-beta", event: "questionAsked", sentAt: now, deadline: now + 30,
                      payload: ["session_id": .string("q")].merging(payload) { $1 })!
    }
    let agent = AgentID("demo-beta")!
    #expect(OrbitEventAdapter.demo.approval(from: envelope(["questions": .array([.string("x")])]), agent: agent, receivedAt: now) == nil)
    #expect(OrbitEventAdapter.demo.approval(from: envelope(["questions": .object([:]), "options": .array([])]), agent: agent, receivedAt: now) == nil)
    let structured = OrbitEventAdapter.demo.approval(from: envelope(["summary": .string("Set up"), "questions": .array([
        .object(["header": .string("Database"), "question": .string("Which?"), "options": .array([.string("A"), .string("B")])])])]),
        agent: agent, receivedAt: now)
    #expect(structured?.questions.count == 1 && structured?.options.isEmpty == true)
    #expect(DemoAgents(socketPath: "/tmp/x", scheduler: FakeScheduler()).request(at: 15)?.payload["questions"] != nil)  // the demo asks both kinds
    #expect(DemoAgents(socketPath: "/tmp/x", scheduler: FakeScheduler()).request(at: 7)?.payload["options"] != nil)
}

// MARK: Several agents and sessions in the companion

@MainActor
private func companion(_ scheduler: FakeScheduler = FakeScheduler()) -> NotchCompanion {
    NotchCompanion(scheduler: scheduler, now: { now })
}

private func session(_ agent: String, _ id: String, _ status: AgentSession.Status, ago: TimeInterval = 0, cwd: String? = nil) -> AgentSession {
    AgentSession(key: key(agent, id), title: id, cwd: cwd, status: status, startedAt: now - ago - 60, lastEventAt: now - ago,
                 originBundleID: "com.apple.Terminal")
}

private func event(_ session: SessionKey, _ kind: AgentEvent.Kind, _ summary: String, files: [String] = [], at: TimeInterval = 0) -> AgentEvent {
    AgentEvent(id: UUID(), session: session, kind: kind, nativeName: kind.rawValue, occurredAt: now + at, receivedAt: now + at, cwd: nil,
               tool: nil, summary: summary, files: files, dedupeKey: UUID().uuidString)
}

@MainActor @Test func requestsRankTheirSessionsAndOpenOnTheRequestsTab() async throws {
    let companion = companion()
    let codex = session("codex", "api", .running, ago: 1)
    let copilot = session("copilot-cli", "site", .running, ago: 5)
    let beta = key("demo-beta", "sim-request-3")  // asks before any event of its own
    let requests = [draft(beta), draft(copilot.key, .question, options: ["Yes", "No"], summary: "Deploy now?")]
    companion.update(available: true, sessions: [codex, copilot], events: [:], requests: requests, waiting: { _ in nil })
    #expect(Set(companion.rows.prefix(2).map(\.id)) == [copilot.key, beta] && companion.rows.last?.id == codex.key)
    #expect(companion.rows.prefix(2).allSatisfy { $0.tone == .attention && $0.pending.count == 1 })
    #expect(companion.rows.first { $0.id == copilot.key }?.headline == "Deploy now?" && companion.approvals == 2)

    companion.open(codex.key)  // a click on its mark in the compact island
    #expect(companion.phase == .expanded && companion.selected == codex.key && companion.tab == .changes)
    companion.select(at: companion.rows.firstIndex { $0.id == beta }!)  // number key
    #expect(companion.selected == beta && companion.tab == .requests)
    companion.select(at: 9)  // nothing there: unchanged
    #expect(companion.selected == beta)
    companion.show(.activity)
    #expect(companion.tab == .activity)

    // The request is answered (or expires, or is withdrawn): the session drops back.
    companion.update(available: true, sessions: [codex, copilot], events: [:], requests: [requests[1]], waiting: { _ in nil })
    #expect(!companion.rows.contains { $0.id == beta } && companion.selected != beta && companion.approvals == 1)
}

@MainActor @Test func expiryAndWithdrawalClearTheRequestEverywhere() {
    let scheduler = FakeScheduler()
    let approvals = ApprovalManager(scheduler: scheduler, now: { now })
    approvals.output = { OrbitEventAdapter.demo.output(for: $0, to: $1) }
    approvals.add(connection: 1, draft: draft(key("demo-beta", "a"), expires: 5))
    approvals.add(connection: 2, draft: draft(key("demo-alpha", "b"), expires: 50))
    let companion = companion(scheduler)
    func sync() { companion.update(available: true, sessions: [], events: [:], requests: approvals.pending.map(\.draft), waiting: { _ in nil }) }
    sync()
    #expect(companion.rows.count == 2 && companion.phase == .compact)
    scheduler.advance(.seconds(5))  // the first expires
    sync()
    #expect(approvals.history.first?.outcome == .expired && companion.rows.map(\.id) == [key("demo-alpha", "b")])
    approvals.withdrawn(connection: 2)  // the agent stopped waiting
    sync()
    #expect(approvals.history.first?.outcome == .withdrawn && companion.rows.isEmpty && companion.phase == .idle)
}

@MainActor @Test func theSelectedSessionsActivityAndFilesComeFromItsTimelineAndLiveEvents() async throws {
    let companion = companion()
    let working = session("codex", "api", .running, cwd: nil)
    let saved = [event(working.key, .toolStarted, "Read Package.swift", files: ["/p/Package.swift"], at: -20),
                 event(working.key, .fileChanged, "Changed main.swift", files: ["/p/main.swift"], at: -10)]
    companion.timeline = { _ in saved }
    companion.update(available: true, sessions: [working], events: [:], requests: [], waiting: { _ in nil })  // nothing live since launch
    companion.tap()
    for _ in 0 ..< 100 where companion.activity.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(companion.activity.map(\.summary) == ["Changed main.swift", "Read Package.swift"])  // newest first, from the saved timeline
    companion.receive([event(working.key, .toolStarted, "Bash: swift test"), event(key("codex", "other"), .toolStarted, "Elsewhere")])
    #expect(companion.activity.first?.summary == "Bash: swift test" && companion.activity.count == 3)  // only its own events
    companion.selectNext(1)
    #expect(companion.selected == working.key)  // one session: wraps onto itself
    companion.collapse()
    #expect(companion.activity.isEmpty)  // nothing kept while collapsed
}

private func git(_ arguments: [String], in folder: URL) {
    let process = Process()
    process.executableURL = URL(filePath: "/usr/bin/git")
    process.arguments = ["-c", "user.name=T", "-c", "user.email=t@example.invalid", "-c", "init.defaultBranch=main"] + arguments
    process.currentDirectoryURL = folder
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    try? process.run()
    process.waitUntilExit()
}

@MainActor @Test func theDiffFollowsTheSessionsEditsAndTheArrowsStepThroughFiles() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let repo = temp.url.appending(path: "repo")
    try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
    git(["init", "-q"], in: repo)
    for name in ["a.swift", "b.swift"] { try "one\n".write(to: repo.appending(path: name), atomically: true, encoding: .utf8) }
    git(["add", "-A"], in: repo)
    git(["commit", "-q", "-m", "First"], in: repo)
    try "one\ntwo\n".write(to: repo.appending(path: "a.swift"), atomically: true, encoding: .utf8)

    let companion = companion()
    let working = session("codex", "api", .running, cwd: repo.path(percentEncoded: false))
    companion.timeline = { _ in [] }
    companion.update(available: true, sessions: [working], events: [:], requests: [], waiting: { _ in nil })
    companion.tap()
    for _ in 0 ..< 300 where companion.diffText == nil { try await Task.sleep(for: .milliseconds(10)) }
    #expect(companion.changes?.files.map(\.path) == ["a.swift"] && companion.diffText?.contains("+two") == true)

    try "one\nTHREE\n".write(to: repo.appending(path: "b.swift"), atomically: true, encoding: .utf8)  // the agent edits another file
    companion.receive([event(working.key, .fileChanged, "Changed b.swift", files: [repo.appending(path: "b.swift").path(percentEncoded: false)])])
    for _ in 0 ..< 300 where companion.changes?.files.count != 2 { try await Task.sleep(for: .milliseconds(10)) }
    #expect(companion.changes?.files.count == 2 && companion.changes?.files.first { $0.path == "b.swift" }?.touchedBySession == true)
    #expect(companion.diffPath == "a.swift")  // live refresh keeps the file being read
    companion.selectFile(1)
    for _ in 0 ..< 300 where companion.diffText?.contains("+THREE") != true { try await Task.sleep(for: .milliseconds(10)) }
    #expect(companion.diffPath == "b.swift" && companion.tab == .changes)
    companion.selectFile(1)  // wraps
    #expect(companion.diffPath == "a.swift")
}

// MARK: Dropping files on a session

@Test func dropsBecomeQuotedPathsAndNothingElse() {
    let exists: (String) -> Bool = { !$0.hasSuffix("gone.txt") }
    let files = [URL(filePath: "/Users/me/My Files/report (final).pdf"), URL(filePath: "/Users/me/it's.txt"),
                 URL(filePath: "/Users/me/a/../b/$(rm -rf ~)`x`.txt"), URL(filePath: "/Users/me/My Files/report (final).pdf")]
    let paths = try? SessionAttachment.paths(files, exists: exists).get()
    #expect(paths == ["/Users/me/My Files/report (final).pdf", "/Users/me/it's.txt", "/Users/me/b/$(rm -rf ~)`x`.txt"])  // standardised, deduplicated
    #expect(SessionAttachment.text(paths ?? []) == #"'/Users/me/My Files/report (final).pdf' '/Users/me/it'\''s.txt' '/Users/me/b/$(rm -rf ~)`x`.txt'"#)
    #expect(SessionAttachment.paths([], exists: exists) == .failure(.nothing))
    #expect(SessionAttachment.paths(Array(repeating: files[0], count: SessionAttachment.maxFiles + 1), exists: exists) == .failure(.tooMany))
    #expect(SessionAttachment.paths([URL(string: "https://example.com/x.txt")!], exists: exists) == .failure(.notLocal))
    #expect(SessionAttachment.paths([URL(filePath: "/tmp/gone.txt")], exists: exists) == .failure(.missing("gone.txt")))
    #expect(SessionAttachment.paths([URL(filePath: "/tmp/evil\nname.txt")], exists: exists) == .failure(.unsafeName("evil\nname.txt")))
    #expect(SessionAttachment.Refusal.simulated.description.contains("Simulated"))

    let pasteboard = NSPasteboard(name: .init("orbit-tests-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    SessionAttachment.copy(["/tmp/a b.txt"], to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "'/tmp/a b.txt'" && !(pasteboard.types ?? []).contains(.fileURL))  // text only: no file is placed
}

@MainActor @Test func aDropConfirmationIsShownAndClearedOnTheNextSelection() {
    let companion = companion()
    let one = session("codex", "one", .running), two = session("codex", "two", .running, ago: 3)
    companion.update(available: true, sessions: [one, two], events: [:], requests: [], waiting: { _ in nil })
    companion.open(one.key)
    companion.say("Copied 1 path: paste into Terminal with ⌘V")
    #expect(companion.notice?.hasPrefix("Copied 1 path") == true)
    companion.select(two.key)
    #expect(companion.notice == nil)
}

// MARK: Coucou

@MainActor @Test func whileCoucouHasTheNotchRequestsStillWaitInTheAIHub() {
    let approvals = ApprovalManager(scheduler: FakeScheduler(), now: { now })
    approvals.output = { OrbitEventAdapter.demo.output(for: $0, to: $1) }
    approvals.add(connection: 1, draft: draft(key("demo-beta", "r")))
    let companion = companion()
    let available = NotchCoordination.holder(.init(owner: .coucou, companion: true)) == .companion
    companion.update(available: available, sessions: [], events: [:], requests: approvals.pending.map(\.draft), waiting: { _ in nil })
    #expect(companion.phase == .hidden && companion.approvals == 1)  // nothing below the notch…
    #expect(approvals.decide(approvals.pending[0].id, .allowOnce))  // …but the AI Hub still answers it
}

// MARK: Renders

@MainActor @Test func requestsAndActivityRender() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let hub = AIHubService(paths: .init(socket: "/tmp/unused.sock", store: temp.url.appending(path: "h.sqlite"),
                                        demoStore: temp.url.appending(path: "d.sqlite")), scheduler: FakeScheduler(), discover: { [] })
    let rig = PetRig(size: CompanionGeometry.catSize)
    rig.apply(.idle, reduceMotion: true)
    let companion = NotchCompanion(scheduler: FakeScheduler())
    let live = Date.now
    let permission = ApprovalDraft(session: key("demo-beta", "sim-request-3"), kind: .permission, nativeName: "permissionRequested", tool: "Bash",
                                   summary: "Simulated request: run the test suite", options: [], createdAt: live, expiresAt: live + 45,
                                   detail: "swift test --parallel\n  --filter AIHub")
    let structured = ApprovalDraft(session: key("demo-beta", "sim-request-15"), kind: .question, nativeName: "questionAsked", tool: nil,
                                   summary: "Simulated questions: how should the demo be set up?", options: [], createdAt: live,
                                   expiresAt: live + 50, questions: setup)
    hub.approvals.add(connection: 1, draft: permission)
    hub.approvals.add(connection: 2, draft: structured)
    let claude = AgentSession(key: key("claude-code", "c1"), title: "Orbit", cwd: nil, status: .running, startedAt: live - 600, lastEventAt: live)
    let codex = AgentSession(key: key("codex", "x1"), title: "payments-api", cwd: nil, status: .running, startedAt: live - 300, lastEventAt: live - 20)
    func logEvent(_ kind: AgentEvent.Kind, _ native: String, _ summary: String, ago: TimeInterval) -> AgentEvent {
        AgentEvent(id: UUID(), session: claude.key, kind: kind, nativeName: native, occurredAt: live - ago, receivedAt: live - ago, cwd: nil,
                   tool: nil, summary: summary, files: [], dedupeKey: UUID().uuidString)
    }
    let log = [logEvent(.promptSubmitted, "UserPromptSubmit", "Prompt submitted", ago: 90),
               logEvent(.toolStarted, "PreToolUse", "Edit NotchCompanion.swift", ago: 30),
               logEvent(.toolCompleted, "PostToolUse", "Bash: ./scripts/test.sh", ago: 5)]
    companion.timeline = { session in session.key == claude.key ? log : [] }
    companion.update(available: true, sessions: [claude, codex], events: [claude.key: log], requests: hub.approvals.pending.map(\.draft),
                     waiting: hub.waitingPlace(of:))
    #expect(companion.rows.count == 4)
    try render(companion, hub: hub, rig: rig, "8-compact-several-sessions")
    companion.open(permission.session)
    try render(companion, hub: hub, rig: rig, "9-expanded-permission")
    companion.select(structured.session)
    try render(companion, hub: hub, rig: rig, "10-expanded-structured-question")
    companion.select(claude.key)
    companion.show(.activity)
    for _ in 0 ..< 100 where companion.activity.isEmpty { try await Task.sleep(for: .milliseconds(5)) }
    #expect(companion.activity.count == 3)
    try render(companion, hub: hub, rig: rig, "11-expanded-activity")
    companion.show(.requests)
    try render(companion, hub: hub, rig: rig, "12-expanded-claude-observe-only")

    hub.browser.page = .approvals
    let page = AIHubPage(hub: hub, chat: []).frame(width: 708, height: 330).padding(16).background(HubTokens.canvas)
        .environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
    try write(page, "13-ai-hub-structured-question")
}

@MainActor
private func render(_ companion: NotchCompanion, hub: AIHubService, rig: PetRig, _ name: String) throws {
    let size = CompanionGeometry.size(companion.phase)
    let view = NotchCompanionView(companion: companion, hub: hub, rig: rig, actions: CompanionActions())
        .frame(width: size.width, height: size.height).padding(20).background(Color(white: 0.32))
        .environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
    try write(view, name)
}

@MainActor
private func write(_ view: some View, _ name: String) throws {
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage, "\(name) didn't render")
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/notch-companion").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}
