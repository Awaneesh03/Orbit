import AppKit
import SwiftUI

/// Every animation the Music Island uses, in one place, so Reduce Motion
/// (Orbit's or the system's) turns off each nonessential one: the
/// compact ⇄ expanded morph, hover lift, tint fade, press scale and icon swap.
/// Playback progress keeps moving (it's information, not decoration).
struct IslandMotion: Equatable {
    let reduced: Bool

    static let pressedScale: CGFloat = 0.94

    var morph: Animation? { reduced ? nil : .spring(duration: 0.35, bounce: 0.18) }
    var hover: Animation? { reduced ? nil : .orbitHover }
    var tint: Animation? { reduced ? nil : .easeInOut(duration: 0.6) }
    var press: Animation? { reduced ? nil : .easeOut(duration: 0.12) }
    var symbol: ContentTransition { reduced ? .identity : .symbolEffect(.replace) }

    func scale(pressed: Bool) -> CGFloat { pressed && !reduced ? Self.pressedScale : 1 }
}

/// The island's controls: Orbit Glass, plus a slight press scale that
/// leaves the layout and hit target alone. The action runs on press release,
/// as any button's does; the animation never delays it.
struct IslandPressStyle: ButtonStyle {
    var prominent = false
    let motion: IslandMotion

    func makeBody(configuration: Configuration) -> some View {
        OrbitGlassButtonStyle(prominent: prominent, shape: AnyShape(Circle())).makeBody(configuration: configuration)
            .scaleEffect(motion.scale(pressed: configuration.isPressed))
            .animation(motion.press, value: configuration.isPressed)
    }
}

/// Playback progress drawn by Core Animation: the fill runs linearly from
/// where playback is to the end at the playback rate, in the render server,
/// so it moves smoothly with no per-frame work and no timers in Orbit.
struct ProgressTrack: NSViewRepresentable {
    let item: NowPlaying
    var fill: Color = .white.opacity(0.55)
    var track: Color = .white.opacity(0.1)

    func makeNSView(context: Context) -> ProgressTrackView { ProgressTrackView() }

    func updateNSView(_ view: ProgressTrackView, context: Context) {
        view.apply(ProgressTrackView.Anchor(item, at: .now), fill: NSColor(fill), track: NSColor(track))
    }

    static func dismantleNSView(_ view: ProgressTrackView, coordinator: ()) { view.apply(nil, fill: .clear, track: .clear) }
}

/// The layers behind `ProgressTrack`. The fill's width animates once from
/// "now" to the end; it's restarted only when the position genuinely changes
/// (seek, pause, resume, rate or duration), never for an update that agrees
/// with where it already is, and a seek jumps rather than slides.
final class ProgressTrackView: NSView {
    /// Where playback is, and how fast the fraction moves (0 when it isn't).
    struct Anchor: Equatable {
        let fraction: Double
        let at: Date
        /// Fraction per second.
        let speed: Double

        /// Nil when there's nothing to show: live streams, unknown durations.
        init?(_ item: NowPlaying, at date: Date) {
            guard let fraction = item.progress(at: date), !item.isAd else { return nil }
            self.init(fraction: fraction, at: date,
                      speed: item.state == .playing && item.playbackRate > 0 && fraction < 1
                          ? item.playbackRate / (item.duration ?? 1) : 0)
        }

        init(fraction: Double, at: Date, speed: Double) {
            self.fraction = fraction
            self.at = at
            self.speed = speed
        }

        func fraction(at date: Date) -> Double { min(max(fraction + max(0, date.timeIntervalSince(at)) * speed, 0), 1) }
    }

    static let animationKey = "orbit.progress"
    /// An update within this much playback time of where the bar already is
    /// is the same position: no restart.
    static let tolerance: TimeInterval = 0.75

    let trackLayer = CALayer()
    let fillLayer = CALayer()
    private(set) var anchor: Anchor?
    /// Times the fill's animation was (re)started (tests, diagnostics).
    private(set) var starts = 0
    private var laidOutWidth: CGFloat = -1

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        fillLayer.anchorPoint = CGPoint(x: 0, y: 0.5)
        layer?.addSublayer(trackLayer)
        layer?.addSublayer(fillLayer)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    var isRunning: Bool { fillLayer.animation(forKey: Self.animationKey) != nil }
    /// The fill's resting width as a fraction of the track.
    var shownFraction: Double { bounds.width > 0 ? Double(fillLayer.bounds.width / bounds.width) : 0 }

    func apply(_ new: Anchor?, fill: NSColor, track: NSColor) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        trackLayer.backgroundColor = track.cgColor
        fillLayer.backgroundColor = fill.cgColor
        CATransaction.commit()
        guard let new else {
            anchor = nil
            isHidden = true
            return stop()
        }
        isHidden = false
        if let anchor, !Self.restarts(from: anchor, to: new) { return }  // agrees with what's on screen
        anchor = new
        refresh()
    }

    /// Whether `new` really moves the bar: a different speed (pause, resume,
    /// rate), or a position away from where `old` has got to (a seek).
    static func restarts(from old: Anchor, to new: Anchor) -> Bool {
        guard old.speed == new.speed else { return true }
        let drift = abs(old.fraction(at: new.at) - new.fraction)
        return drift > max(tolerance * new.speed, 0.0005)
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        let radius = bounds.height / 2
        trackLayer.frame = bounds
        trackLayer.cornerRadius = radius
        fillLayer.cornerRadius = radius
        fillLayer.position = CGPoint(x: 0, y: bounds.midY)
        CATransaction.commit()
        // Only a new width needs the fill redone: SwiftUI lays out often (the
        // times beside it tick every second) and that mustn't restart it.
        guard bounds.width != laidOutWidth else { return }
        laidOutWidth = bounds.width
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()  // out of a window: no animation; back in: from where playback is now
    }

    private func refresh() {
        stop()
        guard let anchor, bounds.width > 0 else { return }
        let width = bounds.width
        let now = Date.now
        let fraction = anchor.fraction(at: now)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fillLayer.bounds = CGRect(x: 0, y: 0, width: width * fraction, height: bounds.height)
        guard anchor.speed > 0, fraction < 1, window != nil else { return CATransaction.commit() }
        fillLayer.bounds.size.width = width  // where the animation ends
        let run = CABasicAnimation(keyPath: "bounds.size.width")
        run.fromValue = width * fraction
        run.toValue = width
        run.duration = (1 - fraction) / anchor.speed
        run.timingFunction = CAMediaTimingFunction(name: .linear)
        fillLayer.add(run, forKey: Self.animationKey)
        starts += 1
        CATransaction.commit()
    }

    private func stop() {
        fillLayer.removeAnimation(forKey: Self.animationKey)
    }
}
