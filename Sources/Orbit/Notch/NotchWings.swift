import AppKit
import SwiftUI

// Camera-flanking compact state (Milestone 9), opt-in: Settings › General ›
// Compact style › Beside the camera. Instead of a pill hanging below the
// notch, a glance of what's happening sits in two black "wings" on either
// side of the camera, the height of the notch, so the notch looks like it
// widened. The middle is left clear (the hardware notch is already black).
//
// The wings never take a click: the window ignores the mouse entirely, so
// menu-bar items under them stay clickable and the notch's own hover (the
// dashboard trigger) works as before. Details live one hover away in the
// dashboard. Notched displays only; elsewhere the compact pills stay.

enum CompactStyle: String, Codable, CaseIterable, Sendable {
    case below, beside

    var title: String { self == .below ? "Below the notch" : "Beside the camera" }
}

/// What the wings show, most important first.
enum WingContent: Equatable {
    /// An agent session that needs you, failed, or is working.
    case agent(AgentID, NotchCompanion.Tone)
    case music(NowPlaying)
    /// The next meeting (Milestone 14).
    case meeting(MeetingCue)

    /// Most urgent first: an agent that needs you or failed; a meeting about
    /// to start or started; a working agent; a meeting heads-up; music.
    /// Finished and quiet sessions don't take the wings. Nothing while the
    /// dashboard is open, Coucou holds the notch, or the display has no notch.
    static func choose(lead: (agent: AgentID, tone: NotchCompanion.Tone)?, music: NowPlaying?, meeting: MeetingCue? = nil,
                       dashboardOpen: Bool, owner: NotchCoordination.Owner, hasNotch: Bool) -> WingContent? {
        guard !dashboardOpen, owner == .orbit, hasNotch else { return nil }
        if let lead, lead.tone <= .failed { return .agent(lead.agent, lead.tone) }
        if let meeting, meeting.phase != .upcoming { return .meeting(meeting) }
        if let lead, lead.tone == .working { return .agent(lead.agent, lead.tone) }
        if let meeting { return .meeting(meeting) }
        if let music, music.state == .playing { return .music(music) }
        return nil
    }
}

enum WingGeometry {
    static let width: CGFloat = 64

    /// The wings' window: the notch's rect widened by a wing on each side,
    /// the notch's height, flush with the top of the screen. nil without a notch.
    static func frame(screen: CGRect, left: CGRect?, right: CGRect?) -> CGRect? {
        guard let left, let right, right.minX > left.maxX else { return nil }
        let height = left.height
        return CGRect(x: left.maxX - width, y: screen.maxY - height, width: right.minX - left.maxX + 2 * width, height: height)
    }
}

/// The wings' state, pushed in by the app (one value; no timers of its own).
@MainActor @Observable
final class NotchWings {
    private(set) var content: WingContent?
    var reduceMotion = false

    func show(_ new: WingContent?) {
        if new != content { content = new }
    }
}

struct NotchWingsView: View {
    let wings: NotchWings
    let notchWidth: CGFloat

    var body: some View {
        let content = wings.content
        let open = content != nil
        let total = notchWidth + 2 * WingGeometry.width
        let motion: Animation? = wings.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.38, bounce: 0.18)
        let bar = UnevenRoundedRectangle(bottomLeadingRadius: 12, bottomTrailingRadius: 12, style: .continuous)
        ZStack {
            // One bar that widens out of the notch: no seam at the notch's own rounded corners.
            ZStack {
                bar.fill(NotchStyle.fill)
                bar.stroke(NotchStyle.rim, lineWidth: 1)
            }
            .frame(width: open ? total : notchWidth)
            .opacity(open ? 1 : 0)
            HStack(spacing: 0) {
                leading(content).frame(width: WingGeometry.width)
                Spacer(minLength: notchWidth)
                trailing(content).frame(width: WingGeometry.width)
            }
            .opacity(open ? 1 : 0)
            .scaleEffect(open || wings.reduceMotion ? 1 : 0.6)
        }
        .frame(width: total)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .animation(motion, value: content)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Self.label(content))
    }

    @ViewBuilder private func leading(_ content: WingContent?) -> some View {
        switch content {
        case .agent(let agent, _): AgentAvatar(agent: agent, size: 20)
        case .music(let item): Artwork(item: item, height: 20, iconSize: 20)
        case .meeting(let cue):
            Text(cue.title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(cue.phase == .upcoming ? Theme.secondary : .white)
                .lineLimit(1).truncationMode(.tail).minimumScaleFactor(0.85)
                .padding(.leading, 9).padding(.trailing, 3)
        case nil: EmptyView()
        }
    }

    @ViewBuilder private func trailing(_ content: WingContent?) -> some View {
        switch content {
        case .agent(_, let tone):
            let status = Self.status(tone)
            Image(systemName: status.symbol).font(.system(size: 13, weight: .semibold)).foregroundStyle(status.color)
        case .meeting(let cue):
            // Entries on the meeting's own minute marks, where the rounded-up countdown changes.
            TimelineView(.periodic(from: cue.start.addingTimeInterval(-86_400), by: 60)) { _ in
                HStack(spacing: 3) {
                    Image(systemName: cue.phase == .started ? "video.fill" : "calendar").font(.system(size: 8.5, weight: .bold))
                    Text(cue.countdown(at: .now))
                        .font(.system(size: 10.5, weight: .bold, design: .rounded).monospacedDigit())
                        .lineLimit(1).minimumScaleFactor(0.7)
                }
                .foregroundStyle(cue.phase == .upcoming ? Theme.secondary : HubTokens.attention)
                .padding(.leading, 2).padding(.trailing, 9)
            }
        case .music(let item):
            MusicEqualizer(mode: item.state == .playing ? .playing : .paused, accent: ArtworkLoader.shared.accent(for: item)?.color)
                .frame(width: 16, height: 13)
        case nil: EmptyView()
        }
    }

    static func status(_ tone: NotchCompanion.Tone) -> (symbol: String, color: Color) {
        switch tone {
        case .attention: ("hand.raised.fill", HubTokens.attention)
        case .failed: ("xmark.octagon.fill", HubTokens.failure)
        case .working: ("circle.dotted.circle", HubTokens.running)
        case .finished, .quiet: ("checkmark.circle", HubTokens.quiet)
        }
    }

    static func label(_ content: WingContent?) -> String {
        switch content {
        case .agent(let agent, let tone):
            "\(AgentDiscovery.displayName(for: agent)): \(tone == .attention ? "needs you" : tone == .failed ? "failed" : "working")"
        case .music(let item): "Playing \(item.title ?? "audio")"
        case .meeting(let cue): "\(cue.title), \(cue.start.formatted(date: .omitted, time: .shortened)), \(cue.countdown(at: .now))"
        case nil: ""
        }
    }
}

/// The wings' window: flush with the top of the screen around the notch,
/// above the menu bar, and deaf to the mouse (never intercepts a click or
/// hover). Not on full-screen Spaces. Off screen while there's nothing to show.
final class NotchWingsPanel: NSPanel {
    let wings: NotchWings
    private var hideTask: Task<Void, Never>?
    private(set) var notchWidth: CGFloat = 0

    init(wings: NotchWings) {
        self.wings = wings
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        reposition()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The primary display's notch; without one the wings never show.
    func reposition() {
        guard let screen = NSScreen.screens.first,
              let frame = WingGeometry.frame(screen: screen.frame, left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        else {
            notchWidth = 0
            orderOut(nil)
            return
        }
        notchWidth = frame.width - 2 * WingGeometry.width
        contentView = NSHostingView(rootView: NotchWingsView(wings: wings, notchWidth: notchWidth))
        setFrame(frame, display: false)
    }

    var hasNotch: Bool { notchWidth > 0 }

    /// On screen while there's content; after it goes, the closing animation plays first.
    func refreshVisibility() {
        hideTask?.cancel()
        hideTask = nil
        if wings.content != nil {
            if hasNotch { orderFrontRegardless() }
            return
        }
        guard isVisible else { return }
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(420))
            guard !Task.isCancelled else { return }
            self?.orderOut(nil)
        }
    }
}
