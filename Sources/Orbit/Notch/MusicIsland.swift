import CoreGraphics
import Observation

/// The music island: a small player below the notch, separate from the
/// Control Center dashboard (its own panel, its own state). Contextual, not
/// permanent: it announces playback, then gets out of the way.
///
/// - hidden: nothing is playing or paused (or the island is off).
/// - compact: playback just started, or a new track or video began; it
///   dismisses itself after `autoDismiss` (4 s) unless clicked. Position
///   updates, pausing and resuming never bring it back.
/// - expanded: the player, after a click; stays until an outside click,
///   Escape, its close button or a Space change.
/// - dismissed: the same track is still playing or paused, but the island has
///   had its moment; only the next track (or playback starting again after it
///   stopped) shows it again.
///
/// While the dashboard is open the island stays out of the way (an open
/// player collapses first); playback that starts meanwhile is shown in the
/// dashboard's widget instead. Dismissing never touches playback.
@MainActor @Observable
final class MusicIsland {
    enum Phase: Equatable { case hidden, compact, expanded, dismissed }

    private(set) var phase: Phase = .hidden
    /// What's shown; kept while hiding so the island can animate away.
    private(set) var item: NowPlaying?
    /// The pointer is over the compact island (hover feedback; holds off auto-dismiss).
    private(set) var isHovered = false
    /// Orbit's own Reduce Motion setting (the system one is read by the view).
    var reduceMotion = false

    var isVisible: Bool { phase == .compact || phase == .expanded }

    @ObservationIgnored var autoDismiss: Duration = .seconds(4)
    /// After the pointer leaves an island whose time ran out while it was over it.
    @ObservationIgnored var lingerAfterHover: Duration = .milliseconds(1500)
    @ObservationIgnored var onPhaseChange: ((Phase, Phase) -> Void)?
    /// Tracks already announced since playback last stopped, so switching
    /// back to one (another tab, another app) isn't "new". Memory only.
    @ObservationIgnored private var announced: [String] = []
    private static let rememberedTracks = 20
    @ObservationIgnored private var dismissTask: Task<Void, Never>?
    @ObservationIgnored private var dismissWaitsForHover = false

    /// Playing and paused items are "active"; stopped, unknown or nothing isn't.
    static func isActive(_ item: NowPlaying?) -> Bool {
        item?.state == .playing || item?.state == .paused
    }

    /// The same track or video across position, state and metadata updates:
    /// the source and what it says is on screen (YouTube: tab + video), or the
    /// track's own names (Music).
    static func trackKey(_ item: NowPlaying) -> String {
        "\(item.sourceID)|" + (item.itemID ?? "\(item.title ?? "")|\(item.artist ?? "")|\(item.album ?? "")")
    }

    /// Called whenever playback, the setting or the dashboard changes, which
    /// includes every position update: only a new track or playback starting
    /// shows the island.
    func refresh(item newItem: NowPlaying?, enabled: Bool, dashboardOpen: Bool) {
        let active = Self.isActive(newItem)
        guard let newItem, active else {
            announced = []  // stopped or gone: the next start is announced again
            return set(.hidden)
        }
        if newItem != item { item = newItem }
        let key = Self.trackKey(newItem)
        let announce = newItem.state == .playing && !announced.contains(key)
        if announce {  // even when it can't be shown: never pops up late
            announced.append(key)
            if announced.count > Self.rememberedTracks { announced.removeFirst() }
        }
        guard enabled, !dashboardOpen else { return set(.dismissed) }
        if announce, phase != .expanded {
            set(.compact)
            scheduleDismiss(after: autoDismiss)
        } else if phase == .hidden {
            set(.dismissed)  // found already paused, or turned back on mid-track: no pop-up
        }
    }

    /// Keeps the island in step with its inputs: `refresh` runs now and again
    /// whenever anything `inputs` reads changes (Observation; no polling).
    func follow(_ inputs: @escaping @MainActor () -> (item: NowPlaying?, enabled: Bool, dashboardOpen: Bool)) {
        let (item, enabled, open) = withObservationTracking(inputs) { [weak self] in
            Task { @MainActor in self?.follow(inputs) }
        }
        refresh(item: item, enabled: enabled, dashboardOpen: open)
    }

    /// A click on the compact island.
    func tap() {
        guard phase == .compact else { return }
        isHovered = false
        set(.expanded)
    }

    /// An outside click, Escape or the close button.
    func collapse() {
        guard phase == .expanded else { return }
        set(.dismissed)
    }

    /// Another Space: nothing follows the user there.
    func spaceChanged() {
        if isVisible { set(.dismissed) }
    }

    func hover(_ inside: Bool) {
        guard phase == .compact else { return }
        isHovered = inside
        if !inside, dismissWaitsForHover { scheduleDismiss(after: lingerAfterHover) }
    }

    /// Orbit is quitting: no timers left behind.
    func shutdown() {
        dismissTask?.cancel()
        dismissTask = nil
        set(.hidden)
    }

    private func scheduleDismiss(after delay: Duration) {
        dismissTask?.cancel()
        dismissWaitsForHover = false
        dismissTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard let self, !Task.isCancelled, self.phase == .compact else { return }
            if self.isHovered {
                self.dismissWaitsForHover = true  // the pointer may be about to click
            } else {
                self.set(.dismissed)
            }
        }
    }

    private func set(_ new: Phase) {
        guard new != phase else { return }
        let old = phase
        phase = new
        if new != .compact {
            dismissTask?.cancel()
            dismissTask = nil
            isHovered = false
        }
        onPhaseChange?(old, new)
    }
}

/// Where the island sits: centred on the notch, just below the menu bar, so
/// it never covers the menu bar or the notch (whose hover opens the dashboard).
enum MusicIslandGeometry {
    static let compactSize = CGSize(width: 300, height: 42)
    static let expandedSize = CGSize(width: 384, height: 172)
    /// Between the bottom of the menu bar / notch and the island.
    static let gap: CGFloat = 6

    static func rect(_ size: CGSize, trigger: CGRect, screen: CGRect) -> CGRect {
        let x = min(max(trigger.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        return CGRect(x: x, y: trigger.minY - gap - size.height, width: size.width, height: size.height)
    }

    static func compactRect(trigger: CGRect, screen: CGRect) -> CGRect {
        rect(compactSize, trigger: trigger, screen: screen)
    }

    static func expandedRect(trigger: CGRect, screen: CGRect) -> CGRect {
        rect(expandedSize, trigger: trigger, screen: screen)
    }
}
