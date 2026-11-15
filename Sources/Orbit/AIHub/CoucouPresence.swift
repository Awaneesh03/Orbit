import AppKit

// Coucou (github.com/Louis-CFM/coucou; "NotchBuddy" on disk) is a notch
// companion that, while it runs, draws its own island over the notch and
// answers Claude Code's permission prompts and questions (docs/AI_HUB_SPEC.md
// §20). Orbit coexists with it (decision A, §21): it only *looks* — running
// applications and Launch Services, by bundle ID. It never launches, signals,
// reads into or changes Coucou, its files, its hooks or its settings.

@MainActor @Observable
final class CoucouPresence {
    struct State: Equatable, Sendable {
        enum Kind: String, Sendable { case notInstalled = "not installed", installed = "installed, not running", running }
        /// Every copy Launch Services knows (e.g. /Applications/Coucou.app and ~/Desktop/Coucou 2.app).
        var installed: [URL] = []
        /// The copies running now (nil: a running copy with no bundle URL).
        var running: [URL?] = []

        var isRunning: Bool { !running.isEmpty }
        var kind: Kind { isRunning ? .running : installed.isEmpty ? .notInstalled : .installed }

        /// For Settings and the log, e.g. "running · /Applications/Coucou.app".
        var summary: String {
            switch kind {
            case .running: "running · " + running.map { $0.map { $0.path(percentEncoded: false) } ?? "?" }.joined(separator: ", ")
            case .installed: "installed, not running (\(installed.count == 1 ? "1 copy" : "\(installed.count) copies"))"
            case .notInstalled: "not installed"
            }
        }
    }

    /// What Orbit can see of other apps (injected in tests).
    struct Sources {
        var installed: @MainActor (_ bundleIDs: [String]) -> [URL]
        var running: @MainActor () -> [(bundleID: String?, url: URL?)]

        static let system = Sources(
            installed: { ids in ids.flatMap { NSWorkspace.shared.urlsForApplications(withBundleIdentifier: $0) } },
            running: { NSWorkspace.shared.runningApplications.map { ($0.bundleIdentifier, $0.bundleURL) } })
    }

    /// The Developer ID build (GitHub, Homebrew; the one on this Mac) and the App Store build.
    static let bundleIDs = ["fr.louisraille.NotchBuddy", "fr.louisraille.Coucou"]

    private(set) var state = State()
    /// Called after every change of `state` (launch, quit, first look).
    @ObservationIgnored var onChange: (@MainActor (State) -> Void)?
    /// Which apps count as Coucou; debug builds can point it elsewhere to try transitions live.
    @ObservationIgnored var bundleIDs = CoucouPresence.bundleIDs
    @ObservationIgnored private let sources: Sources
    @ObservationIgnored private var observation: NSKeyValueObservation?
    @ObservationIgnored private var lastRunning: [URL?]?

    init(sources: Sources = .system) {
        self.sources = sources
    }

    /// The state from what's installed and what runs (pure).
    nonisolated static func state(installed: [URL], running: [(bundleID: String?, url: URL?)], bundleIDs: [String]) -> State {
        let mine = running.filter { $0.bundleID.map(bundleIDs.contains) ?? false }.map(\.url)
        var copies: [URL] = []
        for url in installed + mine.compactMap({ $0 }) where !copies.contains(where: { $0.standardizedFileURL == url.standardizedFileURL }) {
            copies.append(url)
        }
        return State(installed: copies, running: mine)
    }

    /// Looks now, then follows launches and quits (NSWorkspace's running
    /// applications are key-value observable; no polling).
    func start() {
        guard observation == nil else { return }
        refresh(force: true)
        observation = NSWorkspace.shared.observe(\.runningApplications) { [weak self] _, _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func stop() {
        observation?.invalidate()
        observation = nil
    }

    /// Re-reads; Launch Services is asked only when Coucou's running copies changed.
    func refresh(force: Bool = false) {
        let running = sources.running()
        let mine = running.filter { $0.bundleID.map(bundleIDs.contains) ?? false }.map(\.url)
        guard force || mine != lastRunning else { return }  // another app launched or quit
        lastRunning = mine
        let next = Self.state(installed: sources.installed(bundleIDs), running: running, bundleIDs: bundleIDs)
        guard force || next != state else { return }
        state = next
        onChange?(next)
    }
}

/// Where a waiting Claude Code session is answered. Never in Orbit (D1).
enum WaitingPlace: Equatable, Sendable {
    case coucou, terminal

    var label: String { self == .coucou ? "Answer in Coucou" : "Waiting in terminal" }

    /// Coucou 0.2.2 (the installed version) shows its card for Claude sessions
    /// in VS Code or Cursor and sends terminal sessions back to the terminal
    /// (`HookServer.processPermissionRequest`); it does so only while it runs
    /// and its PermissionRequest hook is installed (`coucouAnswersClaude`).
    static func of(_ session: AgentSession, coucouAnswersClaude: Bool) -> WaitingPlace? {
        guard session.status == .waiting, session.key.agent.rawValue == "claude-code" else { return nil }
        let host = session.originBundleID?.lowercased() ?? ""
        let editor = host.contains("vscode") || host == "com.todesktop.230313mzl4w4u92"  // Cursor
        return coucouAnswersClaude && editor ? .coucou : .terminal
    }
}
