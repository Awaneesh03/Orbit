import AppKit
import OrbitBridge

// The AI Hub (docs/AI_HUB_SPEC.md §2, §14): owns the bridge, the router, the
// session registries, the stores, discovery and demo mode, and brings them in
// line with the master switch and the demo switch. Off: no socket, no
// database file, no timers. Changes are applied one at a time, in order, so
// rapid toggling can't leave a second socket or store behind.

@MainActor @Observable
final class AIHubService {
    /// The File Shelf, for a session's "on the shelf" files (Milestone 14). Set by the app.
    @ObservationIgnored var shelf: FileShelf?
    struct Paths: Sendable {
        var socket: String
        var store: URL
        var demoStore: URL
        /// Chat conversations (Phase 7); nil keeps them in memory (tests).
        var chat: URL?

        static var standard: Paths {
            let folder = OrbitStorage.directory.appending(path: "AIHub")
            return Paths(socket: UnixSocket.agentsPath, store: folder.appending(path: "hub.sqlite"),
                         demoStore: folder.appending(path: "demo.sqlite"), chat: folder.appending(path: "chat.sqlite"))
        }
    }

    let health = AgentHealth()
    let approvals: ApprovalManager
    /// Local chat (Phase 7): used only while the AI Hub is on.
    let chat: ChatService
    /// Alerts below the notch (Phase 10).
    let alerts: AgentAlerts
    /// Every batch of accepted events, after the stores and alerts (the Notch Companion's reactions, §22).
    @ObservationIgnored var onEvents: (([AgentEvent]) -> Void)?
    let real: AgentSessionManager
    let demo: AgentSessionManager
    private(set) var agents: [AgentDiscovery.Found] = []
    private(set) var isEnabled = false
    private(set) var isDemoEnabled = false

    @ObservationIgnored let paths: Paths
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let registry: AgentRegistry
    /// Third-party manifests (Phase 12), read when the hub starts.
    @ObservationIgnored var manifestFolder: URL? = AdapterManifests.folder
    private(set) var manifests = AdapterManifests.Loaded()
    @ObservationIgnored private let limits: AgentBridgeServer.Limits
    @ObservationIgnored private let discover: () -> [AgentDiscovery.Found]
    @ObservationIgnored private let makeDemoAgents: (String) -> DemoAgents
    @ObservationIgnored private let router: AgentEventRouter
    @ObservationIgnored private var server: AgentBridgeServer?
    @ObservationIgnored private var store: HubStore?
    @ObservationIgnored private var demoStore: HubStore?
    @ObservationIgnored private var demoAgents: DemoAgents?
    @ObservationIgnored private var desired = (enabled: false, demo: false)
    @ObservationIgnored private var reconciling: Task<Void, Never>?
    @ObservationIgnored private var serverToken: UUID?

    init(paths: Paths, scheduler: any HUDScheduler = TaskHUDScheduler(), registry: AgentRegistry = .standard,
         limits: AgentBridgeServer.Limits = .init(), discover: @escaping () -> [AgentDiscovery.Found] = { AgentDiscovery.scan() },
         makeDemoAgents: ((String) -> DemoAgents)? = nil) {
        self.paths = paths
        self.scheduler = scheduler
        self.registry = registry
        self.limits = limits
        self.discover = discover
        self.makeDemoAgents = makeDemoAgents ?? { DemoAgents(socketPath: $0, scheduler: scheduler) }
        real = AgentSessionManager(scheduler: scheduler)
        demo = AgentSessionManager(scheduler: scheduler)
        router = AgentEventRouter(real: real, demo: demo, health: health)
        approvals = ApprovalManager(scheduler: scheduler)
        chat = ChatService(store: paths.chat.map { HubStore(url: $0) })
        alerts = AgentAlerts(scheduler: scheduler)
        approvals.output = { decision, draft in registry.adapter(for: draft.session.agent)?.output(for: decision, to: draft) }
        approvals.supports = { draft in registry.adapter(for: draft.session.agent)?.manifest.capabilities.contains(draft.capability) ?? false }
        approvals.reply = { [weak self] connection, output in self?.server?.reply(to: connection, output: output) }
        approvals.onRecord = { [weak self] record in
            guard let self else { return }
            let store = record.draft.session.agent.isDemo ? self.demoStore : self.store
            Task { await store?.save(approval: record) }
        }
    }

    var isDemoRunning: Bool { demoAgents?.isRunning ?? false }
    var demoSessionCount: Int { demo.sessions.count }

    // MARK: Switches

    /// The master switch and demo mode (demo needs the master on).
    func set(enabled: Bool, demo: Bool) {
        desired = (enabled, enabled && demo)
        guard reconciling == nil else { return }
        reconciling = Task { await reconcile() }
    }

    /// Waits until the switches have taken effect (tests, Clear Demo Data).
    func settled() async {
        while let task = reconciling { await task.value }
    }

    /// Re-reads the known agent locations (read-only).
    func refreshAgents() { agents = discover() }

    /// Removes every simulated session and event, in memory and on disk; real
    /// history is untouched. Demo mode keeps running if it's on.
    func clearDemoData() async {
        await settled()
        guard reconciling == nil else { return await clearDemoData() }  // a toggle arrived meanwhile: let it finish first
        let wasOn = isDemoEnabled
        if wasOn { await stopDemo() }
        demo.clear()
        let store = demoStore ?? HubStore(url: paths.demoStore)
        await store.removeAll()
        demoStore = nil
        health.demoStore = .closed
        if wasOn, desired.demo { await startDemo() }
    }

    /// Orbit quitting: socket removed and demo stopped at once (SQLite closes with the process).
    func shutdown() {
        desired = (false, false)
        reconciling?.cancel()
        approvals.withdrawAll()
        demoAgents?.stop()
        server?.stop()
        server = nil
        real.stop()
        demo.stop()
    }

    // MARK: Sessions (Phase 3)

    /// The dashboard's view state (kept in a model: no @State macro with the CLT).
    let browser = AgentBrowser()

    /// Coucou as Orbit last saw it (set by the app; docs/AI_HUB_SPEC.md §21).
    var coucou = CoucouPresence.State()
    /// Coucou runs and its PermissionRequest hook is installed, so it answers
    /// Claude sessions in VS Code and Cursor.
    var coucouAnswersClaude = false

    /// Whether Orbit may answer this request (its adapter declares the capability; never Claude Code, D1).
    func canAnswer(_ draft: ApprovalDraft) -> Bool { approvals.supports(draft) }

    /// Where a waiting Claude Code session is answered (nil: not Claude, or not waiting).
    func waitingPlace(of session: AgentSession) -> WaitingPlace? {
        WaitingPlace.of(session, coucouAnswersClaude: coucouAnswersClaude)
    }

    /// A session's events, oldest first: what's saved plus what's arrived since.
    func timeline(for session: AgentSession) async -> [AgentEvent] {
        let store = session.isDemo ? demoStore : self.store
        let stored = await store?.events(for: session.key, limit: 300) ?? []
        let live = (session.isDemo ? demo : real).recentEvents[session.key] ?? []
        return AgentBrowser.merge(stored, live)
    }

    /// Brings the app the session runs in to the front (Terminal, VS Code…).
    /// Activating the app is all public API allows: not a particular window or tab.
    @discardableResult
    /// Goes to the session's app as precisely as public APIs allow (`AgentJump`, Milestone 9):
    /// the project's editor window, else the exact terminal process, else the app.
    func openOrigin(of session: AgentSession) -> Bool {
        guard session.originBundleID != nil else { return false }
        return AgentJump.perform(AgentJump.plan(session))
    }

    func originName(of session: AgentSession) -> String? {
        guard let bundleID = session.originBundleID,
              let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return FileManager.default.displayName(atPath: url.path(percentEncoded: false)).replacingOccurrences(of: ".app", with: "")
    }

    /// Shows a changed file in Finder. Never opens it: an agent-written file could be
    /// an executable or a script that its default app would run.
    func revealFile(_ path: String, in root: String) {
        guard let file = AgentEnvelope.sanitizedPath(root + "/" + path), file.hasPrefix(root + "/"),
              FileManager.default.fileExists(atPath: file) else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: file)])
    }

    /// Shows the session's project folder in Finder, if it exists.
    @discardableResult
    func revealProject(of session: AgentSession) -> Bool {
        var isDirectory: ObjCBool = false
        guard let cwd = session.cwd, FileManager.default.fileExists(atPath: cwd, isDirectory: &isDirectory), isDirectory.boolValue else { return false }
        NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: cwd)])
        return true
    }

    // MARK: Insights (Phase 9)

    struct Insights: Equatable {
        var days: [(day: String, count: Int)] = []
        var agents: [HubStore.AgentTotals] = []
        var approvals: [String: Int] = [:]
        var tools: [(tool: String, count: Int)] = []
        var statuses: [String: Int] = [:]
        var projects: [(project: String, sessions: Int)] = []
        // Weekly recap (Milestone 9).
        var filesChanged = 0
        var previousWeekEvents = 0
        /// The oldest event Orbit has kept: before it, nothing was recorded.
        var historyStart: Date?
        var longest: (agent: String, cwd: String?, seconds: Double)?
        /// The first day of the 7 shown.
        var since: Date?

        static func == (a: Insights, b: Insights) -> Bool {
            a.agents == b.agents && a.approvals == b.approvals && a.days.map(\.count) == b.days.map(\.count)
                && a.tools.map(\.count) == b.tools.map(\.count) && a.statuses == b.statuses && a.projects.map(\.sessions) == b.projects.map(\.sessions)
                && a.filesChanged == b.filesChanged && a.previousWeekEvents == b.previousWeekEvents && a.historyStart == b.historyStart
                && a.longest?.seconds == b.longest?.seconds && a.since == b.since
        }

        var sessions: Int { agents.map(\.sessions).reduce(0, +) }
        var finished: Int { statuses["completed", default: 0] + statuses["ended", default: 0] }
        var failed: Int { statuses["failed", default: 0] }
        var active: Int { ["running", "idle", "waiting"].map { statuses[$0, default: 0] }.reduce(0, +) }
        var events: Int { days.map(\.count).reduce(0, +) }

        /// History doesn't cover the whole week (Orbit or the AI Hub is newer than that).
        var isPartial: Bool {
            guard let since else { return false }
            return historyStart.map { $0 > since } ?? true
        }

        /// All seven days, oldest first, zero where nothing happened (a quiet day still shows).
        static func filled(_ days: [(day: String, count: Int)], since: Date, calendar: Calendar = .current) -> [(day: String, count: Int)] {
            let format = dayFormatter(calendar)
            let counts = Dictionary(days.map { ($0.day, $0.count) }, uniquingKeysWith: +)
            return (0 ..< 7).compactMap { offset in
                calendar.date(byAdding: .day, value: offset, to: calendar.startOfDay(for: since)).map { date in
                    let key = format.string(from: date)
                    return (key, counts[key] ?? 0)
                }
            }
        }

        /// SQLite's `date(…, 'localtime')`: yyyy-MM-dd in the local time zone.
        static func dayFormatter(_ calendar: Calendar = .current) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.dateFormat = "yyyy-MM-dd"
            return formatter
        }

        /// Week over week, nil without a previous week to compare (never a made-up trend).
        var trend: Double? {
            guard previousWeekEvents > 0, !isPartial else { return nil }
            return Double(events - previousWeekEvents) / Double(previousWeekEvents)
        }

        /// Facts worth a line, only from what was recorded.
        var highlights: [String] {
            var lines: [String] = []
            if let top = agents.max(by: { $0.activeSeconds < $1.activeSeconds }), let agent = AgentID(top.agent) {
                lines.append("\(AgentDiscovery.displayName(for: agent)) did most of the work (\(HubFormat.duration(top.activeSeconds)) active).")
            }
            if let busiest = days.max(by: { $0.count < $1.count }), busiest.count > 0,
               let date = Self.dayFormatter().date(from: busiest.day) {
                lines.append("Busiest day: \(date.formatted(.dateTime.weekday(.wide))) with \(busiest.count) events.")
            }
            if let longest, longest.seconds >= 60, let agent = AgentID(longest.agent) {
                let project = longest.cwd.map { " on \(($0 as NSString).lastPathComponent)" } ?? ""
                lines.append("Longest session: \(HubFormat.duration(longest.seconds)) with \(AgentDiscovery.displayName(for: agent))\(project).")
            }
            if let project = projects.first { lines.append("Most active project: \((project.project as NSString).lastPathComponent).") }
            if let tool = tools.first { lines.append("Most used tool: \(tool.tool) (\(tool.count) calls).") }
            if failed > 0 { lines.append("\(failed) session\(failed == 1 ? "" : "s") failed; worth a look in Agents.") }
            return lines
        }

        /// A plain-text summary of the week (real agents only).
        var report: String {
            guard !agents.isEmpty else { return "No agent activity in the last 7 days." }
            var lines = ["Orbit AI Hub — last 7 days"]
            for totals in agents {
                let name = AgentID(totals.agent).map(AgentDiscovery.displayName(for:)) ?? totals.agent
                let hours = totals.activeSeconds / 3600
                lines.append("• \(name): \(totals.sessions) session\(totals.sessions == 1 ? "" : "s"), \(totals.events) events, about \(String(format: "%.1f", hours)) h active")
            }
            if !approvals.isEmpty {
                lines.append("• Approvals: " + approvals.sorted { $0.key < $1.key }.map { "\($0.value) \($0.key)" }.joined(separator: ", "))
            }
            lines.append("Provider usage and limits: not available (they need API keys, not yet supported).")
            return lines.joined(separator: "\n")
        }
    }

    /// Set by `refreshInsights` (internal so previews and render checks can supply fixtures).
    var insights = Insights()

    /// Re-reads the last 7 days from hub.sqlite (on demand, when the page opens).
    func refreshInsights(now: Date = .now) async {
        guard let store else { insights = Insights(); return }
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: now)) ?? now
        let weekBefore = Calendar.current.date(byAdding: .day, value: -7, to: since) ?? since
        var fresh = Insights(days: Insights.filled(await store.eventsPerDay(since: since), since: since),
                             agents: await store.agentTotals(since: since),
                             approvals: await store.approvalOutcomes(since: since), tools: await store.toolCounts(since: since),
                             statuses: await store.statusCounts(since: since), projects: await store.projectCounts(since: since))
        fresh.filesChanged = await store.filesTouched(from: since)
        fresh.previousWeekEvents = await store.eventCount(from: weekBefore, to: since)
        fresh.historyStart = await store.firstEventAt()
        fresh.longest = await store.longestSession(since: since)
        fresh.since = since
        insights = fresh
    }

    // MARK: Claude Code hooks (only on the user's explicit confirmation)

    @ObservationIgnored var claudeSettingsURL = ClaudeHookInstaller.settingsURL
    @ObservationIgnored var claudeHelperPath = ClaudeHookInstaller.helperPath
    private(set) var claudeHooks: Set<String> = []
    private(set) var claudeHookMessage: String?
    enum HookAction: Identifiable {
        case install, remove
        var id: Self { self }
    }
    /// The confirmation Settings is showing (view state lives in the model: no @State macro with the CLT).
    var confirmingClaudeHooks: HookAction?

    func refreshClaudeHooks() {
        claudeHooks = ClaudeHookInstaller.installedEvents(in: try? Data(contentsOf: claudeSettingsURL), helper: claudeHelperPath)
    }

    func claudeHookPreview() -> String {
        ClaudeHookInstaller.preview(settings: try? Data(contentsOf: claudeSettingsURL), helper: claudeHelperPath)
    }

    /// Installs the helper and Orbit's observe-only hooks. Called only from
    /// the confirmation dialog in Settings › AI Hub.
    func installClaudeHooks(helperSource: URL? = Bundle.main.url(forAuxiliaryExecutable: "OrbitAgentHook")) {
        do {
            try ClaudeHookInstaller.installHelper(from: helperSource, to: claudeHelperPath)
            let current = FileManager.default.fileExists(atPath: claudeSettingsURL.path(percentEncoded: false))
                ? try Data(contentsOf: claudeSettingsURL) : nil
            let backup = try ClaudeHookInstaller.apply(ClaudeHookInstaller.installing(into: current, helper: claudeHelperPath),
                                                       to: claudeSettingsURL)
            claudeHookMessage = "Installed. Backup: \(backup?.lastPathComponent ?? "none (no settings file before)")"
        } catch {
            claudeHookMessage = (error as? ClaudeHookInstaller.Failure)?.description ?? "Couldn't read ~/.claude/settings.json"
        }
        refreshClaudeHooks()
    }

    /// Removes Orbit's hooks only. Called only from the confirmation dialog.
    func removeClaudeHooks() {
        do {
            let current = try Data(contentsOf: claudeSettingsURL)
            let backup = try ClaudeHookInstaller.apply(ClaudeHookInstaller.removing(from: current, helper: claudeHelperPath),
                                                       to: claudeSettingsURL)
            claudeHookMessage = "Removed. Backup: \(backup?.lastPathComponent ?? "none")"
        } catch {
            claudeHookMessage = (error as? ClaudeHookInstaller.Failure)?.description ?? "Couldn't read ~/.claude/settings.json"
        }
        refreshClaudeHooks()
    }

    // MARK: Lifecycle

    private func reconcile() async {
        while !Task.isCancelled {
            if desired.enabled != isEnabled {
                if desired.enabled { await startHub() } else { await stopHub() }
            } else if desired.demo != isDemoEnabled {
                if desired.demo { await startDemo() } else { await stopDemo() }
            } else {
                break
            }
        }
        reconciling = nil
    }

    private func startHub() async {
        let store = HubStore(url: paths.store)
        health.store = await store.open()
        real.load(await store.recentSessions())
        self.store = store
        router.realWriter = StoreWriter(store: store) { [weak self] state, dropped in
            self?.health.store = state
            if dropped > 0 { self?.health.recordUnsaved(dropped) }
        }
        let token = UUID()
        serverToken = token
        manifests = manifestFolder.map { AdapterManifests.load(from: $0, reserved: Set(registry.adapters.map(\.manifest.id.rawValue))) }
            ?? AdapterManifests.Loaded()
        let registry = registry.adding(Array(manifests.adapters.values))
        let server = AgentBridgeServer(path: paths.socket, registry: registry, limits: limits) { [weak self] batch in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self, self.serverToken == token else { return }  // a batch from a bridge since stopped
                    self.router.receive(batch)
                    self.alerts.receive(batch.events)
                    self.onEvents?(batch.events)
                    for (connection, draft) in batch.requests {
                        self.approvals.add(connection: connection, draft: draft)
                        self.alerts.receive(request: draft)
                    }
                    for connection in batch.closedRequests { self.approvals.withdrawn(connection: connection) }
                }
            }
        }
        do {
            try server.start()
            health.bridge = .listening
            self.server = server
        } catch {
            health.bridge = .failed((error as? UnixSocket.Failure)?.description ?? "The agent socket couldn't be opened")
        }
        refreshAgents()
        isEnabled = true
    }

    private func stopHub() async {
        if isDemoEnabled { await stopDemo() }
        approvals.withdrawAll()
        alerts.clear()
        server?.stop()
        server = nil
        serverToken = nil
        await router.realWriter?.drain()
        router.realWriter = nil
        await store?.close()
        store = nil
        real.clear()
        demo.clear()
        router.reset()
        health.reset()
        health.bridge = .off
        health.store = .closed
        isEnabled = false
    }

    private func startDemo() async {
        let store = demoStore ?? HubStore(url: paths.demoStore)
        health.demoStore = await store.open()
        demo.load(await store.recentSessions())
        demoStore = store
        router.demoWriter = StoreWriter(store: store) { [weak self] state, _ in self?.health.demoStore = state }
        let agents = makeDemoAgents(paths.socket)
        agents.start()
        demoAgents = agents
        isDemoEnabled = true
    }

    private func stopDemo() async {
        demoAgents?.stop()
        demoAgents = nil
        await router.demoWriter?.drain()
        router.demoWriter = nil
        await demoStore?.close()
        health.demoStore = .closed
        demo.clear()
        isDemoEnabled = false
    }
}
