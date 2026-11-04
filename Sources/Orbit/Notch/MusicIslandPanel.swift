import AppKit
import SwiftUI

/// The music island's own borderless, non-activating panel, separate from
/// `NotchPanel` (the dashboard). Sized to what's on screen, so it never
/// blocks clicks beyond the island: the compact pill, or the expanded player
/// (grown before the expand animation, shrunk after the collapse). Becomes
/// key only while expanded, so Escape reaches it; compact never takes focus.
/// Not shown on full-screen Spaces (no `.fullScreenAuxiliary`): it would sit
/// over the full-screen app's content.
final class MusicIslandPanel: NSPanel {
    let island: MusicIsland
    private let host: FirstMouseHostingView<MusicIslandView>
    private var compactFrame = CGRect.zero
    private var expandedFrame = CGRect.zero
    private var outsideClickMonitor: Any?
    private var settleTask: Task<Void, Never>?

    /// True while a global monitor is collapsing the player on outside clicks.
    var watchesOutsideClicks: Bool { outsideClickMonitor != nil }
    /// The volume HUD has the slot for a moment (`NotchOverlayCoordinator.coversIsland`).
    private(set) var isCovered = false

    /// Takes the compact island's window off the screen while the volume HUD
    /// shows, and brings it back after if the island is still compact. The
    /// island's own state (phase, timer, item) is never touched.
    func setCovered(_ covered: Bool) {
        guard covered != isCovered else { return }
        isCovered = covered
        if covered {
            if island.phase == .compact { orderOut(nil) }
        } else if island.phase == .compact {
            setFrame(compactFrame, display: true)
            orderFrontRegardless()
        }
    }

    init(island: MusicIsland, perform: @escaping (PlaybackCommand, NowPlaying) -> Void) {
        self.island = island
        host = FirstMouseHostingView(rootView: MusicIslandView(island: island, perform: perform))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        host.sizingOptions = []
        host.appearance = NSAppearance(named: .darkAqua)
        contentView = host
        island.onPhaseChange = { [weak self] old, new in self?.phaseChanged(from: old, to: new) }
        reposition()
    }

    override var canBecomeKey: Bool { island.phase == .expanded }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown, event.keyCode == 53 { return island.collapse() }  // Escape
        super.sendEvent(event)
    }

    // ponytail: primary display only, like NotchPanel.
    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let trigger = NotchGeometry.triggerRect(screen: screen.frame, visible: screen.visibleFrame,
                                                left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        compactFrame = MusicIslandGeometry.compactRect(trigger: trigger, screen: screen.frame)
        expandedFrame = MusicIslandGeometry.expandedRect(trigger: trigger, screen: screen.frame)
        setFrame(island.phase == .expanded ? expandedFrame : compactFrame, display: island.isVisible)
    }

    /// A click anywhere outside Orbit (the global monitor) while expanded.
    func outsideClick() { island.collapse() }

    private func phaseChanged(from old: MusicIsland.Phase, to new: MusicIsland.Phase) {
        log.notice("music island: \(String(describing: new), privacy: .public)")
        settleTask?.cancel()
        if new == .expanded {
            setFrame(expandedFrame, display: true)
            orderFrontRegardless()
            makeKey()  // the user clicked the island; Escape needs key status
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.outsideClick() }
            }
            return
        }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        let wasVisible = old == .compact || old == .expanded
        if new == .compact, !wasVisible {
            setFrame(compactFrame, display: true)
            if !isCovered { orderFrontRegardless() }
            return
        }
        guard wasVisible else { return }  // hidden ⇄ dismissed: nothing on screen either way
        // Let the hide animation play, then take the panel off the screen (it
        // blocks nothing while gone). orderOut hands keyboard focus back.
        settleTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(380))
            guard let self, !Task.isCancelled, self.island.phase == new else { return }
            self.orderOut(nil)
            guard new == .compact else { return }
            self.setFrame(self.compactFrame, display: false)
            if !self.isCovered { self.orderFrontRegardless() }
        }
    }
}

// MARK: Views

/// The compact pill and the expanded player, morphing into each other from
/// the top centre. Dark translucent Orbit Glass; no motion with Reduce Motion.
struct MusicIslandView: View {
    let island: MusicIsland
    let perform: (PlaybackCommand, NowPlaying) -> Void
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let reduce = island.reduceMotion || systemReduceMotion
        let motion = IslandMotion(reduced: reduce)
        let expanded = island.phase == .expanded
        let size = expanded ? MusicIslandGeometry.expandedSize : MusicIslandGeometry.compactSize
        let shape = RoundedRectangle(cornerRadius: expanded ? 26 : size.height / 2, style: .continuous)
        ZStack(alignment: .top) {
            if island.isVisible, let item = island.item {
                // The accent of the artwork on screen (none for Music, missing or greyish artwork).
                let accent = ArtworkLoader.shared.accent(for: item)
                ZStack(alignment: .top) {
                    if expanded {
                        ExpandedMusicPlayer(item: item, accent: accent?.color, motion: motion, perform: { perform($0, item) },
                                            close: island.collapse)
                            .transition(.opacity.combined(with: .scale(0.96, anchor: .top)))
                    } else {
                        CompactMusicIsland(item: item, accent: accent?.color, isHovered: island.isHovered, onTap: island.tap)
                            .transition(.opacity)
                    }
                }
                .frame(width: size.width, height: size.height)
                // A faint wash of the artwork's colour over the black glass, never a replacement for it.
                .background {
                    shape.fill(accent?.color.opacity(ArtworkAccent.tintOpacity) ?? .clear)
                        .animation(motion.tint, value: accent)
                }
                .background(.black.opacity(0.82), in: shape)
                .glassEffect(.regular.tint(.black.opacity(0.55)), in: shape)
                .overlay(shape.strokeBorder(OrbitGlass.rim, lineWidth: 0.6))
                .clipShape(shape)
                .scaleEffect(island.isHovered && !expanded && !reduce ? 1.02 : 1, anchor: .top)
                .onHover { island.hover($0) }
                .transition(.scale(0.7, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(motion.morph, value: island.phase)
        .animation(motion.hover, value: island.isHovered)
        .environment(\.colorScheme, .dark)
        .environment(\.orbitReduceMotion, reduce)
    }
}

/// Thumbnail, title, artist, a small equalizer (decorative) and a hairline
/// of progress along the bottom.
private struct CompactMusicIsland: View {
    let item: NowPlaying
    let accent: Color?
    let isHovered: Bool
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 9) {
                Artwork(item: item, height: 26, iconSize: 26)
                VStack(alignment: .leading, spacing: 0) {
                    Text(item.title ?? "Unknown title").font(.system(size: 11.5, weight: .semibold)).lineLimit(1)
                    if let artist = item.artist {
                        Text(artist).font(.system(size: 9.5, weight: .medium)).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                }
                Spacer(minLength: 4)
                stateGlyph
            }
            .padding(.leading, 9)
            .padding(.trailing, 14)
            .padding(.bottom, 2)  // clear of the progress hairline
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .overlay(alignment: .bottom) {
                if ProgressTrackView.Anchor(item, at: .now) != nil {
                    ProgressTrack(item: item).frame(height: 2).padding(.horizontal, 18).padding(.bottom, 3)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the music player")
        .accessibilityLabel("\(item.title ?? "Now playing"), \(item.state == .playing ? "playing" : "paused"). Open the music player")
    }

    /// Bouncing while playing, still and dimmed while paused (Core Animation;
    /// still with Reduce Motion).
    private var stateGlyph: some View {
        MusicEqualizer(mode: item.state == .playing ? .playing : .paused, accent: accent)
            .frame(width: 14, height: 12)
            .accessibilityHidden(true)  // the label already says playing or paused
    }
}

/// Larger artwork, title, artist, source, progress with times, and the
/// source's own controls (none for Music).
private struct ExpandedMusicPlayer: View {
    let item: NowPlaying
    let accent: Color?
    let motion: IslandMotion
    let perform: (PlaybackCommand) -> Void
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .top, spacing: 14) {
                Artwork(item: item, height: 72, iconSize: 72)
                VStack(alignment: .leading, spacing: 3) {
                    SourceLabel(item: item)
                    Text(item.title ?? "Unknown title").font(OrbitType.title).lineLimit(2)
                    if let artist = item.artist {
                        Text(artist).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    }
                    if let album = item.album {
                        Text(album).font(OrbitType.caption).foregroundStyle(Theme.tertiary).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Button(action: close) {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).frame(width: 20, height: 20)
                }
                .buttonStyle(OrbitGlassButtonStyle(shape: AnyShape(Circle())))
                .help("Close the player (playback continues)")
                .accessibilityLabel("Close the player")
            }
            Spacer(minLength: 0)
            if item.position != nil, !item.isAd { IslandProgress(item: item) }
            HStack(spacing: 8) {
                StatusLabel(item: item)
                MusicEqualizer(mode: item.state == .playing ? .playing : .paused, accent: accent)
                    .frame(width: 11, height: 9)
                    .accessibilityHidden(true)
                Spacer(minLength: 0)
                PlaybackControls(item: item, isExpanded: true, islandMotion: motion, perform: perform)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// The expanded player's progress: a Core Animation bar that moves on its
/// own, and elapsed / total times that tick once a second while playing.
private struct IslandProgress: View {
    let item: NowPlaying

    var body: some View {
        VStack(spacing: 3) {
            if ProgressTrackView.Anchor(item, at: .now) != nil {  // live: times only ("Live")
                ProgressTrack(item: item, fill: Theme.accent, track: .white.opacity(0.08)).frame(height: 6)
            }
            if item.state == .playing, item.playbackRate > 0 {
                TimelineView(.periodic(from: .now, by: 1)) { context in times(at: context.date) }
            } else {
                times(at: .now)
            }
        }
    }

    private func times(at date: Date) -> some View {
        HStack {
            Text(PlaybackTime.format(item.elapsed(at: date) ?? 0))
            Spacer(minLength: 4)
            Text(item.duration.map(PlaybackTime.format) ?? "Live")
        }
        .font(OrbitType.caption.monospacedDigit())
        .foregroundStyle(Theme.tertiary)
    }
}
