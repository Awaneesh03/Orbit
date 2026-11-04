import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.7F-2: the decorative equalizer. Core Animation layers, one
// repeating animation per bar while playing, none otherwise.

@MainActor
private func barsInWindow() -> (EqualizerBarsView, NSWindow) {
    let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 40, height: 30), styleMask: .borderless,
                          backing: .buffered, defer: false)
    window.alphaValue = 0  // never on screen
    window.isReleasedWhenClosed = false
    let bars = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 12))
    window.contentView?.addSubview(bars)
    bars.layout()
    return (bars, window)
}

private func heights(_ view: EqualizerBarsView) -> [CGFloat] { view.bars.map { $0.transform.m22 } }

@MainActor @Test func playingBouncesFourBarsOutOfStep() {
    let (view, window) = barsInWindow()
    defer { window.close() }
    view.apply(mode: .playing, animated: true, color: .systemGreen)
    #expect(view.animatingBars == 4 && view.bars.count == EqualizerBarsView.barCount)
    let animations = view.bars.compactMap { $0.animation(forKey: EqualizerBarsView.animationKey) as? CABasicAnimation }
    #expect(Set(animations.map(\.duration)).count == 4)  // each bar has its own timing
    #expect(animations.allSatisfy { $0.keyPath == "transform.scale.y" && $0.repeatCount == .infinity && $0.autoreverses })
    #expect(view.bars.allSatisfy { $0.opacity == 1 })
    #expect(view.bars.allSatisfy { $0.frame.minY == 0 && $0.frame.height <= 12 })  // inside the 14 × 12 frame, from the bottom
}

@MainActor @Test func pausedSettlesStillAndDimmed() {
    let (view, window) = barsInWindow()
    defer { window.close() }
    view.apply(mode: .playing, animated: true, color: .systemGreen)
    view.apply(mode: .paused, animated: true, color: .systemGreen)
    #expect(view.animatingBars == 0)
    #expect(heights(view) == EqualizerBarsView.restingHeights)
    #expect(view.bars.allSatisfy { $0.opacity == EqualizerBarsView.pausedOpacity })
    view.apply(mode: .playing, animated: true, color: .systemGreen)
    #expect(view.animatingBars == 4)  // resuming bounces again
}

@MainActor @Test func stoppedAndHiddenLeaveNoAnimations() {
    let (view, window) = barsInWindow()
    defer { window.close() }
    view.apply(mode: .playing, animated: true, color: .systemGreen)
    view.apply(mode: .stopped, animated: true, color: .systemGreen)
    #expect(view.animatingBars == 0)

    view.apply(mode: .playing, animated: true, color: .systemGreen)
    view.removeFromSuperview()  // the island hid: its content left the window
    #expect(view.animatingBars == 0)
    window.contentView?.addSubview(view)  // shown again
    #expect(view.animatingBars == 4)

    let detached = EqualizerBarsView(frame: NSRect(x: 0, y: 0, width: 14, height: 12))
    detached.apply(mode: .playing, animated: true, color: .systemGreen)
    #expect(detached.animatingBars == 0)  // never animates outside a window
}

@MainActor @Test func reduceMotionShowsStillBars() {
    let (view, window) = barsInWindow()
    defer { window.close() }
    view.apply(mode: .playing, animated: false, color: .systemGreen)
    #expect(view.animatingBars == 0 && heights(view) == EqualizerBarsView.stillPlayingHeights)
    view.apply(mode: .paused, animated: false, color: .systemGreen)
    #expect(view.animatingBars == 0 && heights(view) == EqualizerBarsView.restingHeights)
    view.apply(mode: .playing, animated: true, color: .systemGreen)  // Reduce Motion turned off
    #expect(view.animatingBars == 4)
}

@MainActor @Test func repeatedUpdatesAndAppearancesNeverStackAnimations() {
    let (view, window) = barsInWindow()
    defer { window.close() }
    for _ in 0 ..< 20 { view.apply(mode: .playing, animated: true, color: .systemGreen) }  // SwiftUI updates every second
    #expect(view.bars.allSatisfy { $0.animationKeys() == [EqualizerBarsView.animationKey] })
    let first = view.bars[0].animation(forKey: EqualizerBarsView.animationKey)?.beginTime
    view.apply(mode: .playing, animated: true, color: .systemOrange)  // a colour change doesn't restart them
    #expect(view.bars[0].animation(forKey: EqualizerBarsView.animationKey)?.beginTime == first)
    #expect(view.bars.allSatisfy { $0.backgroundColor == NSColor.systemOrange.cgColor })
    for _ in 0 ..< 5 {
        view.removeFromSuperview()
        window.contentView?.addSubview(view)
    }
    // One bounce per bar (the colour change's brief fade has its own key).
    #expect(view.bars.allSatisfy {
        ($0.animationKeys() ?? []).filter { $0 != EqualizerBarsView.colorAnimationKey } == [EqualizerBarsView.animationKey]
    })
}

@MainActor @Test func theAccentFallsBackToTheTheme() {
    #expect(MusicEqualizer.color(accent: nil) == OrbitGlass.goal)  // no artwork colour yet (3.7F-3)
    #expect(MusicEqualizer.color(accent: .orange) == .orange)
    let (view, window) = barsInWindow()
    defer { window.close() }
    view.apply(mode: .paused, animated: true, color: NSColor(MusicEqualizer.color(accent: nil)))
    #expect(view.bars.allSatisfy { $0.backgroundColor == NSColor(OrbitGlass.goal).cgColor })
}
