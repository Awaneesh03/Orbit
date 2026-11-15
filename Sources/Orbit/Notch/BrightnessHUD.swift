import Foundation
import Observation
import SwiftUI

// The brightness HUD (Milestone 9): the volume HUD's twin, sharing its slot,
// window, priorities and motion (`NotchOverlayCoordinator`, `SystemHUDPanel`).
// Orbit only observes brightness (see Brightness.swift); it never sets it.

/// When to show, update and dismiss the brightness HUD. Same phases and
/// timing as `VolumeHUD`. Shows for a real level change, or a brightness key
/// press (a press at 0 % or 100 % changes nothing, but you pressed it). The
/// first reading is a baseline: turning the HUD on never shows it.
@MainActor @Observable
final class BrightnessHUD {
    typealias Phase = VolumeHUD.Phase

    private(set) var phase = Phase.hidden
    /// 0…1 shown; kept while hiding so it can animate away.
    private(set) var shown: Double?
    /// One per new value: the view's sun pulses.
    private(set) var pulse = 0
    var reduceMotion = false
    var dismissDelay: Duration

    @ObservationIgnored let settleDelay: Duration
    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private var baseline: (level: Double, presses: Int)?
    @ObservationIgnored private var settleTimer: (any HUDTimer)?
    @ObservationIgnored private var dismissTimer: (any HUDTimer)?
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = true

    /// Differences below this are the same level (driver steps are ~1/16).
    static let tolerance = 0.004

    init(scheduler: any HUDScheduler = TaskHUDScheduler(), settleDelay: Duration = .milliseconds(300),
         dismissDelay: Duration = .milliseconds(1500)) {
        self.scheduler = scheduler
        self.settleDelay = settleDelay
        self.dismissDelay = dismissDelay
    }

    var isVisible: Bool { phase != .hidden }
    var isExpanded: Bool { phase == .updating && !reduceMotion }
    var pendingTimers: Int { (settleTimer == nil ? 0 : 1) + (dismissTimer == nil ? 0 : 1) }

    /// A reading from `BrightnessMonitor`. `level` nil: no built-in backlight
    /// (nothing to show, ever: never a made-up value).
    func receive(level: Double?, presses: Int, suppressed: Bool) {
        guard running else { return }
        guard let level else {
            baseline = nil
            return hide()
        }
        let old = baseline
        baseline = (level, presses)
        guard let old, abs(old.level - level) >= Self.tolerance || old.presses != presses else {
            if isVisible, shown != level { shown = level }
            return
        }
        guard !suppressed else { return hide() }
        show(level)
    }

    func suppress() { hide() }

    func shutdown() {
        running = false
        baseline = nil
        hide()
    }

    func resume() { running = true }

    private func show(_ level: Double) {
        shown = level
        pulse += 1
        phase = phase == .hidden ? .visible : .updating
        generation += 1
        let current = generation
        settleTimer?.cancel()
        dismissTimer?.cancel()
        settleTimer = scheduler.after(settleDelay) { [weak self] in self?.settled(current) }
        dismissTimer = scheduler.after(dismissDelay) { [weak self] in self?.dismissed(current) }
    }

    private func settled(_ registered: Int) {
        guard registered == generation, phase == .visible || phase == .updating else { return }
        settleTimer = nil
        phase = .pendingDismissal
    }

    private func dismissed(_ registered: Int) {
        guard registered == generation else { return }
        hide()
    }

    private func hide() {
        generation += 1
        settleTimer?.cancel()
        dismissTimer?.cancel()
        settleTimer = nil
        dismissTimer = nil
        if phase != .hidden { phase = .hidden }
    }
}

// MARK: View

enum BrightnessStyle {
    static let segments = 16
    /// Warm light, so brightness never reads as volume's indigo.
    static let warm = Color(red: 1.0, green: 0.80, blue: 0.38)

    static func lit(_ level: Double) -> Int {
        guard level > 0.0005 else { return 0 }
        return min(segments, max(1, Int((level * Double(segments)).rounded())))
    }

    static func symbol(_ level: Double) -> String { level < 0.34 ? "sun.min.fill" : "sun.max.fill" }
    static func percentage(_ level: Double) -> String { "\(Int((level * 100).rounded()))%" }
}

/// Sun, a 16-segment meter in warm light, and the level: the same capsule
/// as Sonic Pulse, drawn in SwiftUI (it changes only when the level does).
struct BrightnessCapsule: View {
    let level: Double
    let pulse: Int
    let reduceMotion: Bool
    var highContrast = HubAppearance.shared.increasedContrast

    var body: some View {
        let shape = Capsule(style: .continuous)
        let lit = BrightnessStyle.lit(level)
        HStack(spacing: 12) {
            Image(systemName: BrightnessStyle.symbol(level))
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(BrightnessStyle.warm)
                .symbolEffect(.bounce, options: .nonRepeating, value: reduceMotion ? 0 : pulse)
                .rotationEffect(.degrees(reduceMotion ? 0 : level * 90))
                .shadow(color: BrightnessStyle.warm.opacity(highContrast ? 0 : 0.6 * level), radius: 6)
                .frame(width: 26)
            HStack(spacing: 2.5) {
                ForEach(0 ..< BrightnessStyle.segments, id: \.self) { index in
                    Capsule().fill(index < lit
                        ? BrightnessStyle.warm.opacity(0.55 + 0.45 * Double(index + 1) / Double(BrightnessStyle.segments))
                        : Color.white.opacity(highContrast ? 0.32 : 0.14))
                }
            }
            .frame(height: 6)
            .animation(reduceMotion ? nil : .spring(duration: 0.22, bounce: 0.1), value: lit)
            Text(BrightnessStyle.percentage(level))
                .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(reduceMotion ? .identity : .numericText(value: level))
                .animation(reduceMotion ? nil : .snappy(duration: 0.2), value: level)
                .frame(width: 44, alignment: .trailing)
        }
        .padding(.leading, 14)
        .padding(.trailing, 16)
        .frame(width: SonicPulse.size.width, height: SonicPulse.size.height)
        .islandSurface(in: shape)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Brightness \(Int((level * 100).rounded())) percent")
    }
}
