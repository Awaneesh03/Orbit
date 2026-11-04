import AppKit
import SwiftUI

/// Four bars that bounce while playing: a decorative playback indicator, not
/// a level meter (it knows nothing about the audio). Core Animation runs the
/// bounce in the render server, so Orbit does no per-frame work; SwiftUI only
/// says playing, paused or stopped, and repeating that adds nothing.
struct MusicEqualizer: NSViewRepresentable {
    enum Mode: Equatable { case playing, paused, stopped }

    let mode: Mode
    /// The artwork's accent colour when there is one (Stage 3.7F-3); the theme's otherwise.
    var accent: Color?
    @Environment(\.orbitReduceMotion) private var reduceMotion

    static func color(accent: Color?) -> Color { accent ?? OrbitGlass.goal }

    func makeNSView(context: Context) -> EqualizerBarsView { EqualizerBarsView() }

    func updateNSView(_ view: EqualizerBarsView, context: Context) {
        view.apply(mode: mode, animated: !reduceMotion, color: NSColor(Self.color(accent: accent)))
    }

    static func dismantleNSView(_ view: EqualizerBarsView, coordinator: ()) {
        view.apply(mode: .stopped, animated: false, color: .clear)
    }
}

/// The bars themselves: four reused layers, one repeating animation each
/// while playing, none otherwise or while out of a window.
final class EqualizerBarsView: NSView {
    static let barCount = 4
    static let animationKey = "orbit.equalizer"
    static let gap: CGFloat = 1.5
    /// Heights as a fraction of the view: resting (paused) and, with Reduce
    /// Motion, a still "playing" arrangement.
    static let restingHeights: [CGFloat] = [0.35, 0.6, 0.45, 0.3]
    static let stillPlayingHeights: [CGFloat] = [0.55, 0.95, 0.7, 0.45]
    /// Each bar's own bounce, so they never move in step.
    static let bounces: [(duration: Double, low: CGFloat, high: CGFloat, phase: Double)] = [
        (0.47, 0.25, 0.9, 0.0), (0.61, 0.35, 1.0, 0.21), (0.39, 0.2, 0.75, 0.13), (0.53, 0.3, 0.85, 0.34),
    ]
    static let pausedOpacity: Float = 0.55
    static let colorFade = 0.6
    static let colorAnimationKey = "orbit.equalizer.colour"

    private(set) var bars: [CALayer] = []
    private(set) var mode = MusicEqualizer.Mode.stopped
    private(set) var animates = true

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        bars = (0 ..< Self.barCount).map { _ in
            let bar = CALayer()
            bar.anchorPoint = CGPoint(x: 0.5, y: 0)  // grows up from the bottom (unflipped view)
            layer?.addSublayer(bar)
            return bar
        }
        settle(Self.restingHeights, animated: false)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    /// Bars with their animation attached (tests, diagnostics).
    var animatingBars: Int { bars.filter { $0.animation(forKey: Self.animationKey) != nil }.count }

    override func layout() {
        super.layout()
        let width = max((bounds.width - Self.gap * CGFloat(Self.barCount - 1)) / CGFloat(Self.barCount), 1)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (index, bar) in bars.enumerated() {
            bar.bounds = CGRect(x: 0, y: 0, width: width, height: bounds.height)
            bar.position = CGPoint(x: CGFloat(index) * (width + Self.gap) + width / 2, y: 0)
            bar.cornerRadius = width / 2
        }
        CATransaction.commit()
    }

    /// Idempotent: the same mode again changes nothing (no duplicate animations).
    /// A new colour fades in over `colorFade` (its own animation key: the
    /// bounce is untouched); instantly with Reduce Motion or out of a window.
    func apply(mode new: MusicEqualizer.Mode, animated: Bool, color: NSColor) {
        let cgColor = color.cgColor
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for bar in bars {
            if bar.backgroundColor != cgColor {
                if animated, window != nil, let from = bar.presentation()?.backgroundColor ?? bar.backgroundColor {
                    let fade = CABasicAnimation(keyPath: "backgroundColor")
                    fade.fromValue = from
                    fade.toValue = cgColor
                    fade.duration = Self.colorFade
                    fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    bar.add(fade, forKey: Self.colorAnimationKey)
                }
                bar.backgroundColor = cgColor
            }
            bar.opacity = new == .paused ? Self.pausedOpacity : 1
        }
        CATransaction.commit()
        guard new != mode || animated != animates else { return }
        mode = new
        animates = animated
        refresh()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        refresh()  // out of a window: no animations at all; back in: resume
    }

    private func refresh() {
        switch (mode, animates) {
        case (.playing, true) where window != nil: bounce()
        case (.playing, true): stopBouncing()
        case (.playing, false): settle(Self.stillPlayingHeights, animated: false)
        case (.paused, let animated): settle(Self.restingHeights, animated: animated && window != nil)
        case (.stopped, _): stopBouncing()
        }
    }

    private func bounce() {
        let now = CACurrentMediaTime()
        for (bar, spec) in zip(bars, Self.bounces) where bar.animation(forKey: Self.animationKey) == nil {
            let animation = CABasicAnimation(keyPath: "transform.scale.y")
            animation.fromValue = spec.low
            animation.toValue = spec.high
            animation.duration = spec.duration
            animation.autoreverses = true
            animation.repeatCount = .infinity
            animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            animation.beginTime = now - spec.phase
            animation.isRemovedOnCompletion = false
            bar.add(animation, forKey: Self.animationKey)
        }
    }

    private func stopBouncing() {
        bars.forEach { $0.removeAnimation(forKey: Self.animationKey) }
    }

    private func settle(_ heights: [CGFloat], animated: Bool) {
        stopBouncing()
        CATransaction.begin()
        CATransaction.setDisableActions(!animated)
        CATransaction.setAnimationDuration(0.25)
        for (bar, height) in zip(bars, heights) { bar.transform = CATransform3DMakeScale(1, height, 1) }
        CATransaction.commit()
    }
}
