import AppKit
import Observation

// The Notch Companion (docs/AI_HUB_SPEC.md §22, §23): Orbit Pet below the
// notch, telling what the AI agents are doing. One cat — the same PetModel as
// the Desktop Pet, never a second mascot — in the place NotchCoordination
// gives it (last in line; never while Coucou has the notch).
//
// - hidden: off, the slot is taken, Coucou runs, or the display sleeps;
// - idle: the cat peeks out; nothing to report;
// - compact: one line of live activity, the most urgent session first, and
//   the other sessions' marks to jump straight to;
// - expanded: after a click — switch sessions, open the app or Finder, and per
//   session its activity, its changed files with a live diff, and its requests.
//
// Nothing runs while nothing happens: inputs arrive through Observation and
// agent events; one timer only while a "finished" or "failed" moment shows.

@MainActor @Observable
final class NotchCompanion {
    enum Phase: String, Sendable { case hidden, idle, compact, expanded }
    enum Event: Equatable, Sendable { case available(Bool), active(Bool), tap, collapse, spaceChanged }
    /// How a session reads at a glance, most urgent first.
    enum Tone: Int, Comparable, Sendable {
        case attention, failed, working, finished, quiet
        static func < (a: Tone, b: Tone) -> Bool { a.rawValue < b.rawValue }
    }
    /// What the expanded island shows for the selected session.
    enum Tab: String, CaseIterable, Identifiable, Sendable {
        case activity = "Activity", changes = "Changes", requests = "Requests"
        var id: Self { self }
    }

    struct Row: Identifiable, Equatable {
        let session: AgentSession
        let tone: Tone
        /// One line: what it's doing, what it asks, or where to answer it.
        let headline: String
        /// Files its events named (absolute), newest first.
        let files: [String]
        /// Requests from this session waiting in Orbit's Approval Center.
        var pending: [ApprovalDraft] = []
        var id: SessionKey { session.key }
    }

    /// A finished turn or a failure, shown for a moment.
    struct Flash: Equatable {
        let session: SessionKey
        let tone: Tone
    }

    static let maxRows = 6
    static let maxFiles = 8
    static let maxActivity = 12
    /// Finished and failed sessions stay listed this long after their last event.
    static let recent: TimeInterval = 600
    static let flashFor: Duration = .seconds(5)
    /// The cat flicks its tail at most this often while tools run.
    static let activityCueInterval: TimeInterval = 2

    /// The island's transitions; anything else leaves the phase alone.
    nonisolated static func next(_ phase: Phase, _ event: Event, active: Bool) -> Phase? {
        switch (phase, event) {
        case (.hidden, .available(false)): nil
        case (_, .available(false)): .hidden
        case (.hidden, .available(true)): active ? .compact : .idle
        case (.idle, .active(true)): .compact
        case (.compact, .active(false)): .idle
        case (.idle, .tap), (.compact, .tap): .expanded
        case (.expanded, .collapse), (.expanded, .spaceChanged): active ? .compact : .idle
        default: nil
        }
    }

    private(set) var phase = Phase.hidden
    private(set) var rows: [Row] = []
    private(set) var selected: SessionKey?
    private(set) var tab = Tab.changes
    private(set) var flash: Flash?
    /// Requests waiting in Orbit's Approval Center (agents Orbit may answer; never Claude Code).
    private(set) var approvals = 0
    /// Expanded: the selected session's latest events, newest first (saved and live).
    private(set) var activity: [AgentEvent] = []
    /// Expanded: its repository and one file's diff (git off the main thread, as in the AI Hub).
    private(set) var changes: CodeChangeService.Snapshot?
    private(set) var diffPath: String?
    private(set) var diffText: String?
    private(set) var loadingChanges = false
    /// A short confirmation (e.g. after a file drop), until the next selection or phase change.
    private(set) var notice: String?

    /// The cat's reaction to each agent event worth one.
    @ObservationIgnored var onCue: ((AgentCue) -> Void)?
    @ObservationIgnored var onPhaseChange: ((Phase, Phase) -> Void)?
    /// A session's saved and live events (the AI Hub's timeline), read when it's selected.
    @ObservationIgnored var timeline: ((AgentSession) async -> [AgentEvent])?
    /// Announce attention, finishes and failures to VoiceOver (while the companion stands in for agent alerts).
    @ObservationIgnored var announces = false
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var flashTimer: (any HUDTimer)?
    @ObservationIgnored private var lastActivityCue = Date.distantPast
    @ObservationIgnored private var loadGeneration = 0
    @ObservationIgnored private var touched: Set<String> = []
    @ObservationIgnored private var refreshAgain = false
    @ObservationIgnored private var refreshing = false

    init(scheduler: any HUDScheduler, now: @escaping () -> Date = { .now }) {
        self.scheduler = scheduler
        self.now = now
    }

    /// Something worth the compact line: a session working, waiting or asking, a moment, or a request.
    var isActive: Bool { flash != nil || approvals > 0 || rows.contains { $0.tone <= .working } }
    /// What the compact line shows: the moment's session, else the most urgent.
    var lead: Row? { flash.flatMap { flash in rows.first { $0.id == flash.session } } ?? rows.first }
    var selectedRow: Row? { rows.first { $0.id == selected } ?? rows.first }
    /// Timers pending (tests).
    var pendingTimers: Int { flashTimer == nil ? 0 : 1 }

    // MARK: Inputs

    /// Whether the companion may show (NotchCoordination, awake display), what the agents are doing, and
    /// the requests waiting in the Approval Center.
    func update(available: Bool, sessions: some Collection<AgentSession>, events: [SessionKey: [AgentEvent]], requests: [ApprovalDraft],
                waiting: (AgentSession) -> WaitingPlace?) {
        let next = Self.rows(sessions, events: events, requests: requests, now: now(), waiting: waiting)
        if next != rows { rows = next }
        if requests.count != approvals { approvals = requests.count }
        if let selected, !rows.contains(where: { $0.id == selected }) {
            self.selected = rows.first?.id
            if phase == .expanded { loadSelection() }
        }
        send(.available(available))
        send(.active(isActive))
    }

    /// Each batch of agent events: the cat's reactions, the finished/failed moments, and the selected
    /// session's live activity and diff.
    func receive(_ events: [AgentEvent]) {
        for event in events {
            let name = AgentDiscovery.displayName(for: event.session.agent)
            switch event.kind {
            case .waitingForUser:
                onCue?(.attention)
                announce("\(name) needs you")
            case .turnCompleted, .sessionEnded:
                show(Flash(session: event.session, tone: .finished))
                onCue?(.finished)
                announce("\(name) finished")
            case .error:
                show(Flash(session: event.session, tone: .failed))
                onCue?(.failed)
                announce("\(name) failed")
            case .toolStarted, .fileChanged:
                guard now().timeIntervalSince(lastActivityCue) >= Self.activityCueInterval else { break }
                lastActivityCue = now()
                onCue?(.activity)
            default:
                break
            }
        }
        if phase == .expanded, let key = selectedRow?.id {
            let mine = events.filter { $0.session == key }
            if !mine.isEmpty { activity = Array((mine.reversed() + activity).prefix(Self.maxActivity)) }
            let edited = mine.filter { !$0.files.isEmpty && ($0.kind == .fileChanged || $0.kind == .toolCompleted) }
            if !edited.isEmpty {
                touched.formUnion(edited.flatMap(\.files))
                refreshChanges()  // live: the diff follows the session's edits
            }
        }
        send(.active(isActive))
    }

    // MARK: The user

    /// A click on the idle or compact island: the expanded view, on the lead session.
    func tap() {
        guard send(.tap) else { return }
        selected = selected.flatMap { key in rows.contains { $0.id == key } ? key : nil } ?? lead?.id
        loadSelection()
    }

    /// A click on another session's mark in the compact island: expanded, on that session.
    func open(_ key: SessionKey) {
        if phase != .expanded { tap() }
        select(key)
    }

    /// Escape, an outside click or the close button.
    func collapse() { send(.collapse) }

    /// Another Space: nothing follows the user there.
    func spaceChanged() { send(.spaceChanged) }

    func select(_ key: SessionKey) {
        guard key != selectedRow?.id, rows.contains(where: { $0.id == key }) else { return }
        selected = key
        loadSelection()
    }

    /// ← / →: the previous or next session, wrapping.
    func selectNext(_ step: Int) {
        guard !rows.isEmpty else { return }
        let index = rows.firstIndex { $0.id == selectedRow?.id } ?? 0
        select(rows[((index + step) % rows.count + rows.count) % rows.count].id)
    }

    /// 1–6: the session at that position.
    func select(at position: Int) {
        guard rows.indices.contains(position) else { return }
        select(rows[position].id)
    }

    func show(_ tab: Tab) { self.tab = tab }

    /// ↑ / ↓: the previous or next changed file's diff (on the Changes tab).
    func selectFile(_ step: Int) {
        guard let files = changes?.files, !files.isEmpty else { return }
        tab = .changes
        let index = files.firstIndex { $0.path == diffPath } ?? -step
        showDiff(files[((index + step) % files.count + files.count) % files.count].path)
    }

    func showDiff(_ path: String) {
        guard let root = changes?.root else { return }
        diffPath = path
        diffText = nil
        let generation = loadGeneration
        Task {
            let text = await CodeChangeService.diff(of: path, in: root)
            guard generation == loadGeneration, diffPath == path else { return }
            diffText = text.flatMap { $0.isEmpty ? nil : $0 } ?? "No diff (new or binary file)."
        }
    }

    /// A confirmation after the user did something (a file drop): shown until the next selection.
    func say(_ text: String) {
        notice = text
        announce(text, always: true)
    }

    /// Orbit quitting: no timer, no load left behind.
    func shutdown() {
        flashTimer?.cancel()
        flashTimer = nil
        flash = nil
        send(.available(false))
    }

    // MARK: Rows

    /// Sessions worth showing — active ones, ones with a waiting request, and finished or failed ones for
    /// `recent` — most urgent first, then most recent.
    static func rows(_ sessions: some Collection<AgentSession>, events: [SessionKey: [AgentEvent]], requests: [ApprovalDraft] = [],
                     now: Date, waiting: (AgentSession) -> WaitingPlace?) -> [Row] {
        let asking = Dictionary(grouping: requests, by: \.session)
        // A request can come from a session Orbit hasn't seen events from yet: list it too.
        let known = Set(sessions.map(\.key))
        let askingOnly = asking.compactMap { key, drafts -> AgentSession? in
            guard !known.contains(key), let first = drafts.min(by: { $0.createdAt < $1.createdAt }) else { return nil }
            return AgentSession(key: key, title: nil, status: .waiting, startedAt: first.createdAt, lastEventAt: first.createdAt)
        }
        let rows = (Array(sessions) + askingOnly).compactMap { session -> Row? in
            let pending = asking[session.key] ?? []
            guard !pending.isEmpty || session.status.isActive || now.timeIntervalSince(session.lastEventAt) < recent else { return nil }
            let log = events[session.key] ?? []
            let tone: Tone = if !pending.isEmpty { .attention } else {
                switch session.status {
                case .waiting: .attention
                case .failed: .failed
                case .running: .working
                case .idle, .completed, .ended: .finished
                case .stale: .quiet
                }
            }
            let headline = if let request = pending.first { request.summary } else {
                switch tone {
                case .attention: waiting(session)?.label ?? "Needs you"
                case .failed: log.last { $0.kind == .error }?.summary ?? "Failed"
                case .working: log.last { $0.kind == .toolStarted || $0.kind == .fileChanged }?.summary ?? "Working"
                case .finished: session.status == .idle ? "Finished its turn" : "Finished"
                case .quiet: "Quiet"
                }
            }
            return Row(session: session, tone: tone, headline: headline, files: files(in: log), pending: pending)
        }
        return Array(rows.sorted { $0.tone != $1.tone ? $0.tone < $1.tone : $0.session.lastEventAt > $1.session.lastEventAt }.prefix(maxRows))
    }

    /// Files named by the events, newest first, at most `maxFiles`.
    static func files(in log: [AgentEvent]) -> [String] {
        var files: [String] = []
        for event in log.reversed() where files.count < maxFiles {
            for file in event.files where !files.contains(file) && files.count < maxFiles { files.append(file) }
        }
        return files
    }

    // MARK: Private

    @discardableResult
    private func send(_ event: Event) -> Bool {
        guard let new = Self.next(phase, event, active: isActive) else { return false }
        let old = phase
        phase = new
        if new != .expanded { clearSelectionData() }
        onPhaseChange?(old, new)
        return true
    }

    private func show(_ flash: Flash) {
        self.flash = flash
        flashTimer?.cancel()
        flashTimer = scheduler.after(Self.flashFor) { [weak self] in
            guard let self else { return }
            self.flashTimer = nil
            self.flash = nil
            self.send(.active(self.isActive))
        }
    }

    private func announce(_ text: String, always: Bool = false) {
        guard announces || always else { return }
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    private func clearSelectionData() {
        loadGeneration += 1
        activity = []
        changes = nil
        diffPath = nil
        diffText = nil
        loadingChanges = false
        notice = nil
        touched = []
        refreshAgain = false
        refreshing = false
    }

    /// The selected session's tab, activity (saved + live) and repository.
    private func loadSelection() {
        clearSelectionData()
        guard phase == .expanded, let row = selectedRow else { return }
        tab = row.pending.isEmpty ? .changes : .requests
        let generation = loadGeneration
        touched = Set(row.files)
        loadingChanges = !row.session.isDemo && row.session.cwd != nil
        Task {
            let saved = await timeline?(row.session) ?? []
            guard generation == loadGeneration else { return }
            activity = Array(saved.suffix(Self.maxActivity).reversed())
            touched.formUnion(Self.files(in: saved))  // after a relaunch, the session's files come from its saved events
            await loadChanges(of: row.session, generation: generation)
        }
    }

    private func loadChanges(of session: AgentSession, generation: Int) async {
        guard !session.isDemo, let cwd = session.cwd else { return loadingChanges = false }
        refreshing = true
        let snapshot = await CodeChangeService.snapshot(of: cwd, touched: touched)
        guard generation == loadGeneration else { return }
        refreshing = false
        loadingChanges = false
        changes = snapshot
        let keep = diffPath.flatMap { path in snapshot?.files.contains { $0.path == path } == true ? path : nil }
        if let file = keep ?? snapshot?.files.first(where: \.touchedBySession)?.path ?? snapshot?.files.first?.path { showDiff(file) }
        if refreshAgain {  // more edits arrived while git ran
            refreshAgain = false
            await loadChanges(of: session, generation: generation)
        }
    }

    /// One reload at a time; edits meanwhile ask for one more after it.
    private func refreshChanges() {
        guard let session = selectedRow?.session else { return }
        guard !refreshing else { return refreshAgain = true }
        let generation = loadGeneration
        Task { await loadChanges(of: session, generation: generation) }
    }
}
