import AppKit
import Observation
import SwiftUI

// The floating status pill (Milestone 15): Orbit's contextual status where the
// camera-flanking wings can't be, such as an external main display with no
// notch, or the "Below the notch" style. It sits in the same slot as the music
// island and the HUDs (6 pt below the menu bar or notch, centred), so it
// never covers menu-bar items, and it doesn't pretend the display has a notch:
// a floating black capsule with its own shadow.
// - Content: the next meeting (all phases) and an agent that needs you or
//   failed. Working agents and music stay with the wings, companion and island:
//   a pill for hours of work would be a permanent obstruction.
// - Click to expand (Join, Calendar, Go to agent, Dismiss); it collapses when
//   the pointer leaves. Nothing runs by itself: Join opens a link only on a click.
// - Takes the slot only when NotchCoordination gives it (.statusPill), and
//   never while Coucou has the notch.

/// Where contextual status goes (Settings › General › Compact Notch).
enum StatusDisplay: String, Codable, CaseIterable, Sendable {
    case automatic, pill, off
    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .pill: "Floating pill on every display"
        case .off: "Off"
        }
    }
}

/// The primary display (the one with the menu bar), as plain values: tests use fixtures.
struct DisplayProfile: Equatable, Sendable {
    var frame: CGRect
    var visible: CGRect
    var left: CGRect?
    var right: CGRect?
    var scale: CGFloat = 2

    @MainActor init(_ screen: NSScreen) {
        frame = screen.frame
        visible = screen.visibleFrame
        left = screen.auxiliaryTopLeftArea
        right = screen.auxiliaryTopRightArea
        scale = screen.backingScaleFactor
    }

    init(frame: CGRect, visible: CGRect, left: CGRect? = nil, right: CGRect? = nil, scale: CGFloat = 2) {
        self.frame = frame
        self.visible = visible
        self.left = left
        self.right = right
        self.scale = scale
    }

    /// `NSScreen.screens.first`: the display with the menu bar, wherever it is.
    @MainActor static var primary: DisplayProfile? { NSScreen.screens.first.map(DisplayProfile.init) }

    var hasNotch: Bool { WingGeometry.frame(screen: frame, left: left, right: right) != nil }
    var trigger: CGRect { NotchGeometry.triggerRect(screen: frame, visible: visible, left: left, right: right) }
}

/// Which surface carries contextual status on the current display.
enum StatusPresenter: Equatable, Sendable {
    case wings, pill, none

    static func choose(_ display: StatusDisplay, compactStyle: CompactStyle, hasNotch: Bool) -> StatusPresenter {
        switch display {
        case .off: .none
        case .pill: .pill
        case .automatic: hasNotch && compactStyle == .beside ? .wings : .pill
        }
    }
}

extension WingContent {
    /// What the pill shows: an agent that needs you or failed, then the meeting. Never music or work in progress.
    static func pill(lead: (agent: AgentID, tone: NotchCompanion.Tone)?, meeting: MeetingCue?, dashboardOpen: Bool,
                     owner: NotchCoordination.Owner) -> WingContent? {
        choose(lead: lead.flatMap { $0.tone <= .failed ? $0 : nil }, music: nil, meeting: meeting, dashboardOpen: dashboardOpen,
               owner: owner, hasNotch: true)
    }
}

@MainActor @Observable
final class ContextPill {
    enum Action: Equatable { case join(URL), openCalendar, goToAgent(AgentID), openHub }

    private(set) var content: WingContent?
    private(set) var isExpanded = false
    /// The slot is ours (NotchCoordination); content waits while it isn't.
    var slotIsFree = true
    var reduceMotion = false
    /// What the user dismissed: that item in that phase stays away (a meeting comes back when it escalates).
    @ObservationIgnored private(set) var dismissed: String?

    var isShowing: Bool { content != nil && slotIsFree }

    func show(_ next: WingContent?) {
        let shown = next.flatMap { Self.key($0) == dismissed ? nil : $0 }
        if shown != content { content = shown }
        if shown == nil, isExpanded { isExpanded = false }
    }

    func toggle() {
        guard content != nil else { return }
        isExpanded.toggle()
    }

    func collapse() { if isExpanded { isExpanded = false } }

    func dismiss() {
        dismissed = content.flatMap(Self.key)
        content = nil
        isExpanded = false
    }

    static func key(_ content: WingContent) -> String? {
        switch content {
        case .meeting(let cue): "meeting:\(cue.eventID):\(cue.phase)"
        case .agent(let agent, let tone): "agent:\(agent):\(tone)"
        case .music: nil
        }
    }
}

enum ContextPillGeometry {
    static let height: CGFloat = 30
    static let minWidth: CGFloat = 132
    static let maxWidth: CGFloat = 360
    static let expandedSize = CGSize(width: 340, height: 96)

    /// The compact pill's width for its text: glyph, gaps and padding, clamped.
    @MainActor static func compactWidth(title: String, detail: String) -> CGFloat {
        let titleWidth = (title as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 12, weight: .semibold)]).width
        let detailWidth = detail.isEmpty ? 0
            : (detail as NSString).size(withAttributes: [.font: NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .bold)]).width + 8
        return min(max(ceil(5 + 20 + 8 + titleWidth + detailWidth + 14), minWidth), maxWidth)
    }

    /// The slot below the menu bar or notch, centred on it, kept on screen.
    static func rect(_ size: CGSize, display: DisplayProfile) -> CGRect {
        MusicIslandGeometry.rect(size, trigger: display.trigger, screen: display.frame)
    }

    static func text(_ content: WingContent, at now: Date = .now) -> (title: String, detail: String) {
        switch content {
        case .meeting(let cue): (cue.title, cue.countdown(at: now))
        case .agent(let agent, let tone): ("\(AgentDiscovery.displayName(for: agent)) \(tone == .failed ? "failed" : "needs you")", "")
        case .music(let item): (item.title ?? "Playing", "")
        }
    }
}

struct ContextPillView: View {
    let pill: ContextPill
    let perform: @MainActor (ContextPill.Action) -> Void
    /// nil: follow macOS's Increase Contrast live (HubAppearance is observable); tests pass a value.
    var contrast: Bool?
    private var highContrast: Bool { contrast ?? HubAppearance.shared.increasedContrast }

    var body: some View {
        ZStack(alignment: .top) {
            if let content = pill.content {
                Group {
                    if pill.isExpanded { expanded(content) } else { compact(content) }
                }
                .transition(pill.reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.92, anchor: .top)))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(pill.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.34, bounce: 0.16), value: pill.isExpanded)
        .animation(pill.reduceMotion ? .easeOut(duration: 0.12) : .spring(duration: 0.34, bounce: 0.16), value: pill.content)
        .environment(\.colorScheme, .dark)
    }

    private func tint(_ content: WingContent) -> Color {
        switch content {
        case .meeting(let cue): cue.phase == .upcoming ? Color.white.opacity(highContrast ? 0.85 : 0.6) : HubTokens.attention
        case .agent(_, let tone): tone == .failed ? HubTokens.failure : HubTokens.attention
        case .music: Theme.accent
        }
    }

    private func glyph(_ content: WingContent) -> String {
        switch content {
        case .meeting(let cue): cue.phase == .started ? "video.fill" : "calendar"
        case .agent(_, let tone): tone == .failed ? "exclamationmark.triangle.fill" : "hand.raised.fill"
        case .music: "music.note"
        }
    }

    @ViewBuilder private func leading(_ content: WingContent, size: CGFloat) -> some View {
        let tint = tint(content)
        if case .agent(let agent, _) = content {
            AgentAvatar(agent: agent, size: size)
        } else {
            Image(systemName: glyph(content)).font(.system(size: size * 0.5, weight: .bold)).foregroundStyle(tint)
                .frame(width: size, height: size).background(tint.opacity(0.16), in: .circle)
        }
    }

    // A: the hardware capsule (chosen from three prototypes, ContextPillPrototypeTests).
    private func compact(_ content: WingContent) -> some View {
        let tint = tint(content)
        let shape = Capsule(style: .continuous)
        return Button { pill.toggle() } label: {
            HStack(spacing: 8) {
                leading(content, size: 20)
                // Re-read on the meeting's own minute marks, where the rounded-up countdown changes.
                TimelineView(.periodic(from: Self.anchor(content), by: 60)) { _ in
                    let text = ContextPillGeometry.text(content)
                    HStack(spacing: 8) {
                        Text(text.title).font(.system(size: 12, weight: .semibold)).foregroundStyle(.white.opacity(0.95))
                            .lineLimit(1).truncationMode(.tail)
                        if !text.detail.isEmpty {
                            Text(text.detail).font(.system(size: 11.5, weight: .bold, design: .rounded).monospacedDigit())
                                .foregroundStyle(tint).fixedSize()
                        }
                    }
                }
            }
            .padding(.leading, 5).padding(.trailing, 14)
            .frame(height: ContextPillGeometry.height)
            .islandSurface(in: shape)
            .overlay(shape.strokeBorder(.white.opacity(highContrast ? 0.5 : 0), lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Self.label(content))
        .accessibilityHint("Shows actions")
        .accessibilityActions { actionButtons(content, accessible: true) }
    }

    private func expanded(_ content: WingContent) -> some View {
        let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 10) {
                leading(content, size: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(ContextPillGeometry.text(content).title).font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white).lineLimit(2)
                    Text(Self.subtitle(content)).font(.system(size: 11, weight: .medium)).foregroundStyle(.white.opacity(highContrast ? 0.85 : 0.6))
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            HStack(spacing: 6) {
                actionButtons(content, accessible: false)
                Spacer(minLength: 0)
                Button { pill.dismiss() } label: { Image(systemName: "xmark").font(.system(size: 10, weight: .bold)) }
                    .buttonStyle(PillButtonStyle(prominent: false)).help("Dismiss").accessibilityLabel("Dismiss")
            }
        }
        .padding(12)
        .frame(width: ContextPillGeometry.expandedSize.width, height: ContextPillGeometry.expandedSize.height, alignment: .topLeading)
        .islandSurface(in: shape)
        .overlay(shape.strokeBorder(.white.opacity(highContrast ? 0.5 : 0), lineWidth: 1))
        .onHover { inside in if !inside { pill.collapse() } }
    }

    @ViewBuilder private func actionButtons(_ content: WingContent, accessible: Bool) -> some View {
        switch content {
        case .meeting(let cue):
            if let url = cue.joinURL {
                Button(MeetingLink.service(of: url).map { "Join \($0)" } ?? "Join") { perform(.join(url)) }
                    .buttonStyle(PillButtonStyle(prominent: true))
            }
            Button("Calendar") { perform(.openCalendar) }.buttonStyle(PillButtonStyle(prominent: false))
        case .agent(let agent, _):
            Button("Go to \(AgentDiscovery.displayName(for: agent))") { perform(.goToAgent(agent)) }.buttonStyle(PillButtonStyle(prominent: true))
            Button("AI Hub") { perform(.openHub) }.buttonStyle(PillButtonStyle(prominent: false))
        case .music:
            EmptyView()
        }
        if accessible { Button("Dismiss") { pill.dismiss() } }
    }

    static func anchor(_ content: WingContent) -> Date {
        if case .meeting(let cue) = content { return cue.start.addingTimeInterval(-86_400) }
        return .distantPast
    }

    static func subtitle(_ content: WingContent, now: Date = .now) -> String {
        switch content {
        case .meeting(let cue):
            [cue.start.formatted(date: .omitted, time: .shortened), cue.countdown(at: now),
             cue.joinURL.flatMap(MeetingLink.service(of:))].compactMap { $0 }.joined(separator: " · ")
        case .agent(_, let tone): tone == .failed ? "Its last turn failed" : "Waiting for your answer, in its own app"
        case .music: ""
        }
    }

    static func label(_ content: WingContent) -> String {
        let text = ContextPillGeometry.text(content)
        if case .meeting(let cue) = content {
            return "\(cue.title), \(cue.start.formatted(date: .omitted, time: .shortened)), \(text.detail)" + (cue.joinURL == nil ? "" : ", join link available")
        }
        return text.title
    }
}

private struct PillButtonStyle: ButtonStyle {
    let prominent: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
            .foregroundStyle(prominent ? Color.black : .white.opacity(0.92))
            .padding(.horizontal, 11).frame(height: 26)
            .background(prominent ? HubTokens.attention : Color.white.opacity(configuration.isPressed ? 0.2 : 0.12), in: .capsule)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .contentShape(.capsule)
    }
}

/// The pill's window: exactly the pill's size (no invisible area takes clicks), in the slot below the
/// menu bar or notch of the primary display. Not on full-screen Spaces. Off screen while there's nothing to show
/// (an ordered-out window doesn't render, so its countdown stops too).
final class ContextPillPanel: NSPanel {
    let pill: ContextPill
    private(set) var display: DisplayProfile?
    private var hideTask: Task<Void, Never>?
    private var generation = 0

    init(pill: ContextPill, perform: @escaping @MainActor (ContextPill.Action) -> Void) {
        self.pill = pill
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true  // follows the pill's shape: lifts it off any wallpaper
        animationBehavior = .none
        contentView = FirstMouseHostingView(rootView: ContextPillView(pill: pill, perform: perform))
        reposition()
        follow()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The primary display now (after a display change, sleep and wake, or the lid closing).
    func reposition(_ display: DisplayProfile? = DisplayProfile.primary) {
        self.display = display
        refresh()
    }

    /// The frame for what's shown, on the current display.
    var targetFrame: CGRect? {
        guard let display, let content = pill.content else { return nil }
        let size: CGSize
        if pill.isExpanded {
            size = ContextPillGeometry.expandedSize
        } else {
            let text = ContextPillGeometry.text(content)
            size = CGSize(width: ContextPillGeometry.compactWidth(title: text.title, detail: text.detail), height: ContextPillGeometry.height)
        }
        return ContextPillGeometry.rect(size, display: display)
    }

    private func follow() {
        generation += 1
        let registered = generation
        withObservationTracking { _ = (pill.content, pill.isExpanded, pill.slotIsFree) } onChange: { [weak self] in
            Task { @MainActor in
                guard let self, self.generation == registered else { return }
                self.refresh()
                self.follow()
            }
        }
    }

    func refresh() {
        hideTask?.cancel()
        hideTask = nil
        if pill.isShowing, let frame = targetFrame {
            if frame != self.frame { setFrame(frame, display: true) }
            invalidateShadow()
            orderFrontRegardless()
            return
        }
        guard isVisible else { return }
        hideTask = Task { [weak self] in  // let the closing animation play
            try? await Task.sleep(for: .milliseconds(360))
            guard !Task.isCancelled else { return }
            self?.orderOut(nil)
        }
    }
}
