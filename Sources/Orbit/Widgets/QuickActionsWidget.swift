import SwiftUI

/// App shortcuts (see `QuickAction`). Compact: 2×2 grid; expanded: one row.
@MainActor
final class QuickActionsWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "quickActions", title: "Quick actions", description: "Open common apps",
        symbol: "bolt", category: .general, availability: .live,
        presentations: [.compact, .expanded])
    let state = WidgetState.ready
    private let perform: @MainActor (QuickAction) -> Void
    /// What's going on right now (Milestone 14; set by the app). Read when the dashboard shows the widget.
    var context: @MainActor () -> QuickContext = { QuickContext() }
    var run: @MainActor (ContextAction) -> Void = { _ in }
    /// True while the Overview's "Suggested for You" shows: suggestions live in one place (Milestone 17).
    var hidesSuggestions: @MainActor () -> Bool = { false }

    /// `perform` runs the action; the app also closes the dashboard there.
    init(perform: @escaping @MainActor (QuickAction) -> Void) {
        self.perform = perform
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(QuickActionsView(columns: presentation == .compact ? 2 : 4, perform: perform,
                                 suggested: hidesSuggestions() ? [] : ContextAction.suggest(context()), run: run))
    }
}

private struct QuickActionsView: View {
    let columns: Int
    let perform: @MainActor (QuickAction) -> Void
    var suggested: [ContextAction] = []
    var run: @MainActor (ContextAction) -> Void = { _ in }

    var body: some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: columns)
        VStack(alignment: .leading, spacing: 6) {
        if !suggested.isEmpty {
            HubScroll(axes: .horizontal, indicators: .never) {
                HStack(spacing: 5) {
                    ForEach(suggested) { action in
                        Button { run(action) } label: {
                            Label(action.title, systemImage: action.symbol).font(.system(size: 10.5, weight: .semibold)).lineLimit(1)
                                .padding(.horizontal, 9).padding(.vertical, 5)
                        }
                        .buttonStyle(OrbitGlassButtonStyle(shape: AnyShape(Capsule())))
                        .help(action.help)
                    }
                }
            }
            .accessibilityLabel("Suggested actions")
        }
        GlassEffectContainer(spacing: 6) {
        LazyVGrid(columns: grid, spacing: 6) {
            ForEach(QuickAction.allCases) { action in
                Button { perform(action) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 13))
                            .frame(height: 15)  // equal icon boxes keep labels aligned
                        Text(action.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(OrbitGlassButtonStyle(
                    shape: AnyShape(RoundedRectangle(cornerRadius: OrbitGlass.innerRadius, style: .continuous))))
            }
        }
        }
        }
    }
}

/// What's going on, for the suggested quick actions (Milestone 14). Plain values from Orbit's own state.
struct QuickContext {
    var waiting: AgentSession?
    var meeting: MeetingCue?
    var playing: NowPlaying?
    var project: String?
    var shelfItem: ShelfItem?
    /// Milestone 15: whether a focus session could start, and whether Keep Awake is already on.
    var focusIdle = false
    var keepingAwake = false
    /// Milestone 16: workspaces, energy, battery and displays.
    var suggestedWorkspace: WorkspaceProfile?
    var activeWorkspace: WorkspaceProfile?
    /// An app macOS estimates is using a lot of energy (only known while the Battery widget samples).
    var energyHog: String?
    var lowBattery = false
    var externalDisplay = false
}

/// A suggestion for right now. Public APIs only: opening an app, Finder, the clipboard, a playback command
/// to a source that supports it, and AgentJump (no Accessibility, no input monitoring, nothing run).
enum ContextAction: Identifiable, Equatable {
    case goToAgent(AgentSession)
    case join(MeetingCue, URL)
    case openCalendar(MeetingCue)
    case keepAwake
    case startFocus
    case switchWorkspace(WorkspaceProfile)
    case openWorkspace(WorkspaceProfile)
    case activityMonitor(String)
    case batterySettings
    case displaySettings
    case pause(NowPlaying)
    case revealProject(String)
    case copyShelfPath(ShelfItem)

    var id: String {
        switch self {
        case .goToAgent(let session): "agent-\(session.key.agent)-\(session.key.nativeID)"
        case .join(let cue, _): "join-\(cue.eventID)"
        case .openCalendar(let cue): "meeting-\(cue.eventID)"
        case .keepAwake: "keep-awake"
        case .startFocus: "focus"
        case .switchWorkspace(let profile): "switch-\(profile.id)"
        case .openWorkspace(let profile): "open-\(profile.id)"
        case .activityMonitor: "activity-monitor"
        case .batterySettings: "battery-settings"
        case .displaySettings: "display-settings"
        case .pause(let item): "pause-\(item.sourceID)"
        case .revealProject(let path): "project-\(path)"
        case .copyShelfPath(let item): "shelf-\(item.id)"
        }
    }

    static func == (a: ContextAction, b: ContextAction) -> Bool { a.id == b.id }

    var title: String {
        switch self {
        case .goToAgent(let session): "Go to \(AgentDiscovery.displayName(for: session.key.agent))"
        case .join(_, let url): MeetingLink.service(of: url).map { "Join \($0)" } ?? "Join meeting"
        case .openCalendar(let cue): cue.phase == .started ? "Meeting now" : "Meeting \(cue.countdown(at: .now))"
        case .keepAwake: "Keep awake 1 h"
        case .startFocus: "Focus"
        case .switchWorkspace(let profile): "Switch to \(profile.name)"
        case .openWorkspace(let profile): "Open \(profile.name)"
        case .activityMonitor: "Activity Monitor"
        case .batterySettings: "Battery Settings"
        case .displaySettings: "Display Settings"
        case .pause: "Pause"
        case .revealProject(let path): (path as NSString).lastPathComponent
        case .copyShelfPath(let item): "Copy \(item.name)"
        }
    }

    var symbol: String {
        switch self {
        case .goToAgent: "hand.raised"
        case .join: "video.fill"
        case .openCalendar: "calendar"
        case .keepAwake: "cup.and.saucer"
        case .startFocus: "timer"
        case .switchWorkspace(let profile): profile.symbol
        case .openWorkspace: "arrow.up.forward.app"
        case .activityMonitor: "bolt.circle"
        case .batterySettings: "battery.25percent"
        case .displaySettings: "display"
        case .pause: "pause.fill"
        case .revealProject: "folder"
        case .copyShelfPath: "doc.on.clipboard"
        }
    }

    var help: String {
        switch self {
        case .goToAgent: "The agent is waiting for you: open its window"
        case .join(let cue, let url): "Join \(cue.title): opens \(url.host() ?? "the link") in your browser or meeting app"
        case .openCalendar(let cue): "\(cue.title) — open Calendar"
        case .keepAwake: "Keep the Mac awake for an hour (it won't sleep mid-meeting)"
        case .startFocus: "Start a focus session before the meeting"
        case .switchWorkspace(let profile): "It's \(profile.name) time on its schedule: switch Orbit to it"
        case .openWorkspace(let profile): "Open \(profile.name)'s apps and projects"
        case .activityMonitor(let app): "\(app) is using a lot of energy (macOS's estimate): see details in Activity Monitor"
        case .batterySettings: "Battery is low: open Battery Settings (Low Power Mode is there)"
        case .displaySettings: "Arrange or adjust the connected displays"
        case .pause(let item): "Pause \(item.title ?? item.appName)"
        case .revealProject(let path): "Show \(path) in Finder (the project agents worked in last)"
        case .copyShelfPath(let item): "Copy the newest shelf file's path, quoted, for an agent"
        }
    }

    /// Most pressing first: an agent waiting on you, then the meeting's own actions (Join when it has a link,
    /// Calendar, pause music, keep awake, a focus session before it), then the latest project and shelf file.
    /// Three at most, four while a meeting is near. Each runs only when clicked.
    static func suggest(_ context: QuickContext) -> [ContextAction] {
        var actions: [ContextAction] = []
        if let session = context.waiting, !session.isDemo, session.originBundleID != nil { actions.append(.goToAgent(session)) }
        if let meeting = context.meeting {
            if let url = meeting.joinURL { actions.append(.join(meeting, url)) }
            actions.append(.openCalendar(meeting))
        }
        if let playing = context.playing, playing.state == .playing, playing.capabilities.contains(.playPause) { actions.append(.pause(playing)) }
        if let meeting = context.meeting {
            if !context.keepingAwake { actions.append(.keepAwake) }
            if context.focusIdle, meeting.phase == .upcoming { actions.append(.startFocus) }
        }
        if let profile = context.suggestedWorkspace { actions.append(.switchWorkspace(profile)) }
        if let profile = context.activeWorkspace, !(profile.apps.isEmpty && profile.projects.isEmpty) { actions.append(.openWorkspace(profile)) }
        if let app = context.energyHog { actions.append(.activityMonitor(app)) }
        if context.lowBattery { actions.append(.batterySettings) }
        if let project = context.project { actions.append(.revealProject(project)) }
        if let item = context.shelfItem { actions.append(.copyShelfPath(item)) }
        if context.externalDisplay { actions.append(.displaySettings) }
        return Array(actions.prefix(context.meeting == nil ? 3 : 4))
    }
}
