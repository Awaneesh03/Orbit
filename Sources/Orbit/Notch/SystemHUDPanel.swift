import AppKit
import SwiftUI

// Sonic Pulse (Stage 4.1-3): the volume HUD's window and view. It shows what
// `NotchOverlayCoordinator` decides, in the compact Music Island's slot below
// the notch. Decorative only: nothing listens to or draws the actual audio.

/// The pure parts of the design, so they're testable.
enum SonicPulse {
    static let segmentCount = 12
    static let size = CGSize(width: 300, height: 42)

    /// Lit segments for a volume: none at 0, at least one above it, all 12 at full.
    static func litSegments(_ volume: Float?) -> Int {
        guard let volume, volume > 0.0005 else { return 0 }
        return min(segmentCount, max(1, Int((Double(volume) * Double(segmentCount)).rounded())))
    }

    static func symbol(volume: Float?, isMuted: Bool?) -> String {
        if isMuted == true { return "speaker.slash.fill" }
        guard let volume else { return "hifispeaker.fill" }  // the device sets its own volume
        if volume <= 0.0005 { return "speaker.fill" }
        return volume < 1.0 / 3 ? "speaker.wave.1.fill" : volume < 2.0 / 3 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
    }

    /// "60%"; nil for a device without software volume (never a made-up value).
    static func percentage(_ volume: Float?) -> String? {
        volume.map { "\(Int((Double($0) * 100).rounded()))%" }
    }

    static func accessibilityLabel(_ state: VolumeState) -> String {
        let device = state.name.map { "\($0): " } ?? ""
        if state.isMuted == true { return device + "Volume muted" }
        guard let percent = percentage(state.volume) else { return device + "Volume is set on the device" }
        return device + "Volume \(percent.dropLast()) percent"
    }
}

/// Turns Sonic Pulse on and off as a whole (Settings › General › Show Volume
/// HUD; quitting). Off: the HUD leaves the screen at once, the island gets its
/// slot back, the coordinator and the volume listeners stop, so nothing runs
/// for it. On: all of it again; the first reading is a baseline, so turning it
/// on never shows the HUD by itself. The window is kept, never recreated.
@MainActor
final class SonicPulseController {
    let volume: SystemVolume
    let overlay: NotchOverlayCoordinator
    let panel: SystemHUDPanel
    private let context: @MainActor () -> (island: MusicIsland.Phase, dashboardOpen: Bool)

    init(volume: SystemVolume, overlay: NotchOverlayCoordinator, panel: SystemHUDPanel,
         context: @escaping @MainActor () -> (island: MusicIsland.Phase, dashboardOpen: Bool)) {
        self.volume = volume
        self.overlay = overlay
        self.panel = panel
        self.context = context
        if !overlay.isRunning { panel.stop() }  // off until `setEnabled(true)`
    }

    var isEnabled: Bool { overlay.isRunning }

    func setEnabled(_ enabled: Bool) {
        guard enabled != isEnabled else { return }
        if enabled {
            volume.start()
            panel.start()
            overlay.start { [volume, context] in
                let (island, open) = context()
                return .init(volume: volume.status, island: island, dashboardOpen: open)
            }
        } else {
            overlay.shutdown()
            panel.stop()
            volume.stop()
        }
    }
}

/// The HUD's window: one, made once, borderless and non-activating, in the
/// compact island's slot (a little larger, for the interaction expansion).
/// It ignores the mouse and never becomes key, so it never takes a click or
/// keyboard focus. Not on full-screen Spaces (no `.fullScreenAuxiliary`), like
/// the island. Off the screen whenever the HUD isn't showing.
final class SystemHUDPanel: NSPanel {
    let coordinator: NotchOverlayCoordinator
    /// Appearing, leaving and the interaction expansion, in Core Animation.
    let stage: SonicPulseStage
    /// The HUD takes the compact island's slot (true) or gives it back (false).
    var onCoverIsland: ((Bool) -> Void)?
    private var hideTask: Task<Void, Never>?
    private var following = false
    /// Each start's follow loop; a re-run left over from before a stop is stale.
    private var generation = 0

    static let expansionRoom = CGSize(width: 16, height: 6)
    /// How long the dismissal animation gets before the window leaves the screen.
    var dismissal = Duration.milliseconds(320)

    init(coordinator: NotchOverlayCoordinator) {
        self.coordinator = coordinator
        let host = NSHostingView(rootView: SonicPulseView(coordinator: coordinator))
        host.sizingOptions = []
        stage = SonicPulseStage(content: host)
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        contentView = stage
        reposition()
        start()
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// The compact island's frame, widened and deepened so the expansion
    /// isn't clipped; the same top edge and centre.
    static func frame(for compact: CGRect) -> CGRect {
        CGRect(x: compact.minX - expansionRoom.width / 2, y: compact.minY - expansionRoom.height,
               width: compact.width + expansionRoom.width, height: compact.height + expansionRoom.height)
    }

    /// Primary display only, like the island.
    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let trigger = NotchGeometry.triggerRect(screen: screen.frame, visible: screen.visibleFrame,
                                                left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        setFrame(Self.frame(for: MusicIslandGeometry.compactRect(trigger: trigger, screen: screen.frame)), display: isVisible)
    }

    /// Follows the coordinator (at creation, and when the setting is turned back on).
    func start() {
        guard !following else { return }
        following = true
        generation += 1
        follow(generation)
    }

    /// Stops following and leaves the screen at once, handing the island back
    /// (the setting turned off, or Orbit quitting).
    func stop() {
        guard following else { return }
        following = false
        generation += 1
        hideTask?.cancel()
        hideTask = nil
        orderOut(nil)
        stage.reset()
        onCoverIsland?(false)
    }

    /// Orbit's setting or the system's.
    var reduceMotion: Bool { coordinator.hud.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    var isFollowing: Bool { following }

    private func follow(_ registered: Int) {
        guard following, registered == generation else { return }
        // Suppression too (the dashboard opening mid-dismissal ends it at once),
        // and the expansion.
        let (overlay, _, expanded, _) = withObservationTracking {
            (coordinator.overlay, coordinator.isSuppressed, coordinator.hud.isExpanded, coordinator.hud.reduceMotion)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(registered) }
        }
        apply(overlay)
        if overlay == .volumeHUD { stage.setExpanded(expanded, animated: !reduceMotion) }
    }

    /// Shows the HUD over a compact island at once; when it goes, lets the
    /// dismissal animation play, leaves the screen, and only then gives the
    /// island its slot back. Leaves at once if the dashboard or the expanded
    /// player took the slot, so it never sits over them.
    private func apply(_ overlay: NotchOverlay) {
        hideTask?.cancel()
        hideTask = nil
        if overlay == .volumeHUD {
            onCoverIsland?(true)
            if !isVisible || stage.isLeaving { stage.present(animated: !reduceMotion) }
            orderFrontRegardless()
            return
        }
        guard isVisible, !coordinator.isSuppressed else {
            orderOut(nil)
            stage.reset()
            onCoverIsland?(false)
            return
        }
        stage.leave(animated: !reduceMotion)
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: self?.dismissal ?? .zero)
            guard let self, !Task.isCancelled else { return }
            self.hideTask = nil
            self.orderOut(nil)
            self.stage.reset()
            self.onCoverIsland?(false)
        }
    }

    /// The dismissal still playing (tests).
    var isDismissing: Bool { hideTask != nil }
}

// MARK: Views

/// The HUD's motion, in Core Animation so SwiftUI never redraws the glass
/// capsule while it moves: it appears from the top centre (0.85 → 1 with a
/// little spring, fading in), grows to 1.04 while changes keep arriving, and
/// leaves the way it came. A scale on `sublayerTransform` and an opacity on a
/// plain layer above the SwiftUI content; instant with Reduce Motion.
final class SonicPulseStage: NSView {
    static let hiddenScale: CGFloat = 0.85
    static let expandedScale: CGFloat = 1.04
    let scaler = NSView()
    private(set) var scale: CGFloat = SonicPulseStage.hiddenScale
    private(set) var isLeaving = false
    private var expanded = false

    init(content: NSView) {
        super.init(frame: .zero)
        wantsLayer = true
        scaler.wantsLayer = true
        scaler.autoresizingMask = [.width, .height]
        content.autoresizingMask = [.width, .height]
        addSubview(scaler)
        scaler.addSubview(content)
        reset()
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        scaler.frame = bounds
        apply(scale: scale, opacity: scaler.layer?.opacity ?? 0, animation: nil)  // the pivot follows the size
    }

    var opacity: Float { scaler.layer?.opacity ?? 0 }

    func present(animated: Bool) {
        isLeaving = false
        apply(scale: expanded ? Self.expandedScale : 1, opacity: 1,
              animation: animated ? Self.spring(duration: 0.3, bounce: 0.15) : nil)
    }

    func setExpanded(_ on: Bool, animated: Bool) {
        guard on != expanded else { return }
        expanded = on
        guard !isLeaving, opacity > 0 else { return }
        apply(scale: on ? Self.expandedScale : 1, opacity: 1, animation: animated ? Self.spring(duration: 0.25, bounce: 0.1) : nil)
    }

    func leave(animated: Bool) {
        isLeaving = true
        expanded = false
        let ease = CABasicAnimation()
        ease.duration = 0.25
        ease.timingFunction = CAMediaTimingFunction(name: .easeIn)
        apply(scale: Self.hiddenScale, opacity: 0, animation: animated ? ease : nil)
    }

    /// Off the screen: back to the start, nothing running.
    func reset() {
        isLeaving = false
        expanded = false
        scaler.layer?.removeAllAnimations()
        apply(scale: Self.hiddenScale, opacity: 0, animation: nil)
    }

    private static func spring(duration: Double, bounce: Double) -> CABasicAnimation {
        let spring = CASpringAnimation(perceptualDuration: duration, bounce: bounce)
        spring.duration = spring.settlingDuration
        return spring
    }

    /// Scales about the top centre (the capsule hangs from the top edge).
    private func transform(_ scale: CGFloat, in layer: CALayer) -> CATransform3D {
        let pivot = CGPoint(x: layer.bounds.midX - layer.anchorPoint.x * layer.bounds.width,
                            y: layer.bounds.maxY - layer.anchorPoint.y * layer.bounds.height)
        var t = CATransform3DMakeTranslation(pivot.x, pivot.y, 0)
        t = CATransform3DScale(t, scale, scale, 1)
        return CATransform3DTranslate(t, -pivot.x, -pivot.y, 0)
    }

    private func apply(scale newScale: CGFloat, opacity newOpacity: Float, animation: CABasicAnimation?) {
        guard let layer = scaler.layer else { return }
        scale = newScale
        let target = transform(newScale, in: layer)
        let fromTransform = layer.presentation()?.sublayerTransform ?? layer.sublayerTransform
        let fromOpacity = layer.presentation()?.opacity ?? layer.opacity
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer.sublayerTransform = target
        layer.opacity = newOpacity
        CATransaction.commit()
        guard let animation, window != nil else {
            layer.removeAllAnimations()
            return
        }
        let move = animation.copy() as! CABasicAnimation
        move.keyPath = "sublayerTransform"
        move.fromValue = NSValue(caTransform3D: fromTransform)
        move.toValue = NSValue(caTransform3D: target)
        layer.add(move, forKey: "orbit.scale")
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.duration = min(animation.duration, 0.25)
        fade.timingFunction = animation.timingFunction ?? CAMediaTimingFunction(name: .easeOut)
        fade.fromValue = fromOpacity
        fade.toValue = newOpacity
        layer.add(fade, forKey: "orbit.fade")
    }
}

/// The capsule: static glass in SwiftUI, the moving parts (speaker, meter,
/// level, pulse) in Core Animation, so a change costs one SwiftUI update and
/// the animation runs in the render server.
struct SonicPulseView: View {
    let coordinator: NotchOverlayCoordinator
    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    var body: some View {
        let hud = coordinator.hud
        ZStack(alignment: .top) {
            if let state = hud.shown {  // kept while it leaves, so it can fade out
                SonicPulseCapsule(state: state, pulse: hud.pulse, showsDevice: hud.showsDevice,
                                  reduceMotion: hud.reduceMotion || systemReduceMotion)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .environment(\.colorScheme, .dark)
    }
}

/// Speaker (with its pulse), the 12-segment meter, and the level.
struct SonicPulseCapsule: View {
    let state: VolumeState
    let pulse: Int
    let showsDevice: Bool
    let reduceMotion: Bool

    var body: some View {
        let shape = Capsule(style: .continuous)
        let muted = state.isMuted == true
        HStack(spacing: 10) {
            ZStack {
                PulseRing(pulse: pulse, animated: !reduceMotion).frame(width: 34, height: 34)
                SpeakerSymbol(name: SonicPulse.symbol(volume: state.volume, isMuted: state.isMuted), muted: muted,
                              animated: !reduceMotion)
                    .frame(width: 24, height: 22)
            }
            .frame(width: 26)
            if state.volume != nil {
                SegmentMeter(lit: SonicPulse.litSegments(state.volume), dimmed: muted, animated: !reduceMotion)
                    .frame(height: 6)
            } else {
                Text("\(state.name ?? "This output") sets its own volume")
                    .font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            VStack(alignment: .trailing, spacing: 0) {
                if showsDevice, let name = state.name {
                    Text(name).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                LevelText(text: muted ? "Muted" : SonicPulse.percentage(state.volume) ?? "", level: state.volume,
                          muted: muted, animated: !reduceMotion)
                    .frame(height: 16)
            }
            .frame(width: 66, alignment: .trailing)
        }
        .padding(.leading, 12)
        .padding(.trailing, 16)
        .frame(width: SonicPulse.size.width, height: SonicPulse.size.height)
        .background(.black.opacity(0.82), in: shape)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: shape)
        .overlay(shape.strokeBorder(OrbitGlass.rim, lineWidth: 0.6))
        .overlay(alignment: .top) {  // the specular highlight along the top
            shape.fill(LinearGradient(colors: [.white.opacity(0.14), .clear], startPoint: .top, endPoint: .bottom))
                .frame(height: 13).padding(.horizontal, 14).padding(.top, 1).allowsHitTesting(false)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SonicPulse.accessibilityLabel(state))
    }
}

/// Twelve rounded segments; lit ones in Orbit's accent, dimmed when muted.
struct SegmentMeter: NSViewRepresentable {
    let lit: Int
    let dimmed: Bool
    let animated: Bool

    func makeNSView(context: Context) -> SegmentMeterView { SegmentMeterView() }
    func updateNSView(_ view: SegmentMeterView, context: Context) {
        view.apply(lit: lit, dimmed: dimmed, animated: animated, accent: NSColor(Theme.accent))
    }
}

/// The meter's segments as layers: a change fades the colours over 0.18 s in
/// the render server (instant with Reduce Motion); nothing runs in between.
final class SegmentMeterView: NSView {
    static let spacing: CGFloat = 3
    static let fadeKey = "orbit.segment"
    let segments: [CALayer] = (0 ..< SonicPulse.segmentCount).map { _ in CALayer() }
    private(set) var lit = -1
    private var dimmed = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        for segment in segments {
            segment.cornerCurve = .continuous
            layer?.addSublayer(segment)
        }
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let count = CGFloat(segments.count)
        let width = max(0, (bounds.width - Self.spacing * (count - 1)) / count)
        let height = min(6, bounds.height)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, segment) in segments.enumerated() {
            segment.frame = CGRect(x: CGFloat(index) * (width + Self.spacing), y: (bounds.height - height) / 2,
                                   width: width, height: height)
            segment.cornerRadius = height / 2
        }
        CATransaction.commit()
    }

    func apply(lit newLit: Int, dimmed newDimmed: Bool, animated: Bool, accent: NSColor) {
        guard newLit != lit || newDimmed != dimmed else { return }
        let first = lit < 0
        lit = newLit
        dimmed = newDimmed
        let on = accent.withAlphaComponent(newDimmed ? 0.35 : 1).cgColor
        let off = NSColor.white.withAlphaComponent(0.1).cgColor
        let fade = animated && !first && window != nil
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, segment) in segments.enumerated() {
            let color = index < newLit ? on : off
            // Explicit: implicit actions don't run for these layers (as with the island's tint).
            if fade, let from = segment.presentation()?.backgroundColor ?? segment.backgroundColor, from != color {
                let animation = CABasicAnimation(keyPath: "backgroundColor")
                animation.fromValue = from
                animation.toValue = color
                animation.duration = 0.18
                animation.timingFunction = CAMediaTimingFunction(name: .easeOut)
                segment.add(animation, forKey: Self.fadeKey)
            }
            segment.backgroundColor = color
        }
        CATransaction.commit()
    }
}

/// "60%" / "Muted": a text layer whose new value slides in (up when the
/// level rises, down when it falls) like rolling digits, in the render server.
struct LevelText: NSViewRepresentable {
    let text: String
    let level: Float?
    let muted: Bool
    let animated: Bool

    func makeNSView(context: Context) -> LevelTextView { LevelTextView() }
    func updateNSView(_ view: LevelTextView, context: Context) {
        view.apply(text, level: level, muted: muted, animated: animated)
    }
}

final class LevelTextView: NSView {
    /// Core Animation keeps a transition under `kCATransition`, whatever key it's given.
    static let transitionKey = kCATransition
    let label = CATextLayer()
    private(set) var text: String?
    private var level: Float?
    private static let font = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .medium)

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.masksToBounds = true  // the old value slides out of sight
        label.alignmentMode = .right
        label.truncationMode = .end
        layer?.addSublayer(label)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        let height = ceil(Self.font.ascender - Self.font.descender + Self.font.leading)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        label.frame = CGRect(x: 0, y: (bounds.height - height) / 2, width: bounds.width, height: height)
        CATransaction.commit()
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        label.contentsScale = window?.backingScaleFactor ?? 2
    }

    func apply(_ newText: String, level newLevel: Float?, muted: Bool, animated: Bool) {
        let color = NSColor.white.withAlphaComponent(muted ? 0.58 : 1)
        let string = NSAttributedString(string: newText, attributes: [.font: Self.font, .foregroundColor: color])
        guard newText != text || (label.string as? NSAttributedString) != string else { return }
        let old = (text, level)
        text = newText
        level = newLevel
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if animated, old.0 != nil, old.0 != newText, window != nil {
            let slide = CATransition()
            slide.type = .push
            slide.subtype = (newLevel ?? 0) >= (old.1 ?? 0) ? .fromBottom : .fromTop
            slide.duration = 0.2
            slide.timingFunction = CAMediaTimingFunction(name: .easeOut)
            label.add(slide, forKey: Self.transitionKey)
        }
        label.string = string
        CATransaction.commit()
    }
}

/// The speaker symbol in AppKit, changing with the system's replace effect
/// (none with Reduce Motion).
struct SpeakerSymbol: NSViewRepresentable {
    let name: String
    let muted: Bool
    let animated: Bool

    func makeNSView(context: Context) -> NSImageView {
        let view = NSImageView()
        view.imageScaling = .scaleNone
        view.symbolConfiguration = .init(pointSize: 15, weight: .semibold)
        return view
    }

    func updateNSView(_ view: NSImageView, context: Context) {
        view.contentTintColor = NSColor.white.withAlphaComponent(muted ? 0.58 : 1)
        guard view.image?.accessibilityDescription != name,
              let image = NSImage(systemSymbolName: name, accessibilityDescription: name) else { return }
        if animated, view.image != nil, view.window != nil {
            view.setSymbolImage(image, contentTransition: .replace)
        } else {
            view.image = image
        }
    }
}

/// One ring that expands and fades from the speaker each time the value
/// changes: a single Core Animation run in the render server, removed when
/// done, so nothing runs while the HUD is idle or hidden. None with Reduce Motion.
struct PulseRing: NSViewRepresentable {
    let pulse: Int
    let animated: Bool

    func makeNSView(context: Context) -> PulseRingView { PulseRingView() }
    func updateNSView(_ view: PulseRingView, context: Context) {
        view.play(pulse, animated: animated, color: NSColor(Theme.accent))
    }
}

final class PulseRingView: NSView {
    static let animationKey = "orbit.pulse"
    let ring = CAShapeLayer()
    private var lastPulse: Int?
    private var pending = false
    /// Rings played (tests, diagnostics).
    private(set) var played = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        ring.fillColor = nil
        ring.lineWidth = 1.5
        ring.opacity = 0
        layer?.addSublayer(ring)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        ring.frame = bounds
        ring.path = CGPath(ellipseIn: bounds.insetBy(dx: bounds.width * 0.2, dy: bounds.height * 0.2), transform: nil)
        CATransaction.commit()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            ring.removeAllAnimations()  // hidden: nothing left running
            pending = false
        } else if pending {
            pending = false
            run()
        }
    }

    /// Plays once for each new `pulse` value (including the one that brought
    /// the HUD on screen); repeats of the same value play nothing.
    func play(_ pulse: Int, animated: Bool, color: NSColor) {
        ring.strokeColor = color.cgColor
        guard pulse != lastPulse else { return }
        lastPulse = pulse
        guard animated else { return }
        guard window != nil else { return pending = true }  // just made: plays once it's in the window
        run()
    }

    private func run() {
        let grow = CABasicAnimation(keyPath: "transform.scale")
        grow.fromValue = 0.7
        grow.toValue = 1.5
        let fade = CABasicAnimation(keyPath: "opacity")
        fade.fromValue = 0.6
        fade.toValue = 0
        let group = CAAnimationGroup()
        group.animations = [grow, fade]
        group.duration = 0.6
        group.timingFunction = CAMediaTimingFunction(name: .easeOut)
        group.isRemovedOnCompletion = true
        ring.add(group, forKey: Self.animationKey)  // replaces a ring still running: one at a time
        played += 1
    }
}
