import AppKit
import IOKit.ps
import QuartzCore
import SwiftUI

/// Internal battery charge. Live and push-driven: while visible it subscribes
/// to IOKit power-source notifications instead of polling. No permission.
/// Milestone 16: the five charge states, a charging animation that runs only
/// while macOS says it's charging, and Apps Using Significant Energy
/// (`EnergyMonitor`, sampled only while this widget shows).
@MainActor @Observable
final class BatteryWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "battery", title: "Battery", description: "Charge, power source and apps using significant energy",
        symbol: "battery.100percent", category: .system, availability: .live, presentations: [.compact, .expanded],
        isEnabledByDefault: false)  // the header shows the battery (M21); its own page is System
    private(set) var state = WidgetState.loading
    private(set) var status: BatteryStatus?
    /// Settings › General › Battery (set by the app).
    var showsEnergy = true { didSet { if showsEnergy != oldValue { syncEnergy() } } }
    var chargingAnimation = true
    /// What's playing in the Brave helper, if anything (context for a browser row; never energy attribution).
    @ObservationIgnored var browserMedia: @MainActor () -> String? = { nil }
    let energy: EnergyMonitor
    private(set) var isShown = false

    private let read: () -> BatteryStatus?
    @ObservationIgnored private let now: () -> Date
    /// The charging animation's state machine (completion once, never at launch).
    private(set) var chargeAnimation = ChargeAnimationState()
    // ponytail: unretained self in the IOKit context; safe because widgets live
    // for the app's lifetime and stop() removes the source. Retain it if
    // widgets ever become short-lived.
    @ObservationIgnored private var source: CFRunLoopSource?

    var isObserving: Bool { source != nil }

    init(read: @escaping () -> BatteryStatus? = BatteryStatus.current, energy: EnergyMonitor = .shared, now: @escaping () -> Date = { .now }) {
        self.read = read
        self.energy = energy
        self.now = now
    }

    func start() {
        isShown = true
        refresh()
        syncEnergy()
        guard source == nil else { return }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let newSource = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated {
                Unmanaged<BatteryWidget>.fromOpaque(context).takeUnretainedValue().refresh()
            }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), newSource, .commonModes)
        source = newSource
    }

    func stop() {
        isShown = false
        syncEnergy()
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }

    private func syncEnergy() {
        if isShown && showsEnergy { energy.start(client: "battery") } else { energy.stop(client: "battery") }
    }

    func refresh() {
        let reading = read()
        if reading != status { status = reading }  // an unchanged reading changes nothing on screen
        chargeAnimation.observe(reading?.chargeState, at: now())
        state = reading == nil ? .unavailable("No battery") : .ready
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        guard let status else { return AnyView(EmptyView()) }
        return AnyView(BatteryView(status: status, widget: self, expanded: presentation == .expanded))
    }
}

enum BatteryStyle {
    static let charging = Color(red: 0.36, green: 0.86, blue: 0.52)
    /// One curve for the fill and the percentage, so they arrive together.
    static let levelAnimation = Animation.smooth(duration: 0.6)

    static func label(_ state: BatteryStatus.ChargeState) -> String {
        switch state {
        case .onBattery: "On battery"
        case .charging: "Charging"
        case .pluggedInNotCharging: "Plugged in, not charging"
        case .charged: "Fully charged"
        }
    }

    static func tint(_ status: BatteryStatus) -> Color {
        switch status.chargeState {
        case .charging, .charged: charging
        case .pluggedInNotCharging: Theme.accent
        case .onBattery: status.percent <= 20 ? OrbitGlass.critical : Theme.accent
        }
    }
}

private struct BatteryView: View {
    let status: BatteryStatus
    let widget: BatteryWidget
    let expanded: Bool
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let state = status.chargeState
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 10) {
                BatteryGlyph(level: Double(status.percent) / 100, state: state,
                             animated: ChargeAnimationState.effect(state, shown: widget.isShown, enabled: widget.chargingAnimation,
                                                                   reduceMotion: reduceMotion) == .charging,
                             completion: widget.chargeAnimation.completions)
                VStack(alignment: .leading, spacing: 0) {
                    // The number and the fill move together, between real readings only.
                    OrbitGlassMetric(value: "\(status.percent)", unit: "%")
                        .contentTransition(reduceMotion ? .identity : .numericText(value: Double(status.percent)))
                        .animation(reduceMotion ? nil : BatteryStyle.levelAnimation, value: status.percent)
                    Text(BatteryStyle.label(state)).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Battery \(status.percent) percent, \(BatteryStyle.label(state))")
            if widget.showsEnergy { EnergySection(monitor: widget.energy, expanded: expanded, browserMedia: widget.browserMedia()) }
        }
    }
}

/// When the battery's look should change, decided from observed states only (Milestone 18).
/// - The energy animation runs only while macOS says *charging*, the widget is on screen, the setting is on
///   and Reduce Motion is off.
/// - The completion plays once, when Orbit saw it charging and then saw it full within 15 minutes:
///   never for a battery that was already full at launch, never again on later refreshes.
struct ChargeAnimationState: Equatable, Sendable {
    enum Effect: Equatable, Sendable { case none, charging }

    private(set) var previous: BatteryStatus.ChargeState?
    private(set) var lastCharging: Date?
    /// Bumped once per completion: the view plays when it changes.
    private(set) var completions = 0
    static let completionWindow: TimeInterval = 15 * 60

    static func effect(_ state: BatteryStatus.ChargeState?, shown: Bool, enabled: Bool, reduceMotion: Bool) -> Effect {
        state == .charging && shown && enabled && !reduceMotion ? .charging : .none
    }

    /// A new reading. True when the completion should play now.
    @discardableResult
    mutating func observe(_ state: BatteryStatus.ChargeState?, at now: Date) -> Bool {
        defer {
            previous = state
            if state == .charging { lastCharging = now }
        }
        guard state == .charged, previous == .charging || previous == .pluggedInNotCharging,
              let lastCharging, now.timeIntervalSince(lastCharging) <= Self.completionWindow else { return false }
        completions += 1
        return true
    }
}

/// A battery drawn to match Orbit: outline, the real level as the fill, and while charging an energy flow made of
/// Core Animation layers (`ChargingEffectsView`), animated by the window server: Orbit does no per-frame work.
struct BatteryGlyph: View {
    let level: Double
    let state: BatteryStatus.ChargeState
    var animated = false
    /// Changes once per completion (`ChargeAnimationState.completions`).
    var completion = 0
    @Environment(\.orbitReduceMotion) private var reduceMotion

    static let size = CGSize(width: 54, height: 26)
    static let inset: CGFloat = 3

    /// The fill's width for a level: the level, never decoration.
    static func fillWidth(_ level: Double) -> CGFloat {
        max(3, (size.width - 2 * inset) * min(max(level, 0), 1))
    }

    var body: some View {
        let size = Self.size
        let charging = state == .charging
        let tint: Color = state == .onBattery ? (level <= 0.2 ? OrbitGlass.critical : .white.opacity(0.9))
            : state == .pluggedInNotCharging ? Theme.accent : BatteryStyle.charging
        let inner = CGSize(width: size.width - 2 * Self.inset, height: size.height - 2 * Self.inset)
        let fill = Self.fillWidth(level)
        HStack(spacing: 1.5) {
            ZStack(alignment: .leading) {
                if charging && !animated {
                    // Static charging look (Reduce Motion, or off screen): a soft glow, no movement.
                    RoundedRectangle(cornerRadius: 6, style: .continuous).fill(BatteryStyle.charging.opacity(0.18)).blur(radius: 4)
                }
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(.white.opacity(charging ? 0.72 : 0.45), lineWidth: 1.5)
                RoundedRectangle(cornerRadius: 3.5, style: .continuous)
                    .fill(LinearGradient(colors: [tint.opacity(0.7), tint], startPoint: .leading, endPoint: .trailing))
                    .frame(width: fill, height: inner.height)
                    .overlay {
                        if animated {
                            ChargingEffects(mode: .charging, completion: completion).allowsHitTesting(false)
                        } else if state == .charged && !reduceMotion && completion > 0 {
                            ChargingEffects(mode: .completion, completion: completion).allowsHitTesting(false)
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 3.5, style: .continuous))
                    .padding(Self.inset)
                    .animation(reduceMotion ? nil : BatteryStyle.levelAnimation, value: level)
                if let symbol = Self.symbol(state) {
                    Image(systemName: symbol)
                        .font(.system(size: state == .charged ? 9 : 10, weight: .heavy))
                        .foregroundStyle(.white)
                        .shadow(color: .black.opacity(0.5), radius: 1)
                        .overlay {
                            if animated { BoltShine().mask(Image(systemName: symbol).font(.system(size: 10, weight: .heavy))) }
                        }
                        .frame(width: size.width)
                        .transition(.opacity)
                }
            }
            .frame(width: size.width, height: size.height)
            .background {
                // Outside the layout (a background never changes the battery's size), centred on the outline.
                if animated { ChargingGlow().frame(width: size.width + 16, height: size.height + 16).allowsHitTesting(false) }
            }
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.35), value: state)
            Capsule().fill(.white.opacity(charging ? 0.6 : 0.45)).frame(width: 2.5, height: 7)
        }
        .accessibilityHidden(true)
    }

    static func symbol(_ state: BatteryStatus.ChargeState) -> String? {
        switch state {
        case .charging: "bolt.fill"
        case .pluggedInNotCharging: "powerplug.fill"
        case .charged: "checkmark"
        case .onBattery: nil
        }
    }
}

/// The energy inside the fill, or the one-time completion.
private struct ChargingEffects: NSViewRepresentable {
    let mode: ChargingEffectsView.Mode
    let completion: Int
    func makeNSView(context: Context) -> ChargingEffectsView { ChargingEffectsView(mode: mode) }
    func updateNSView(_ view: ChargingEffectsView, context: Context) { view.mode = mode }
}

/// The outline's glow, pulsing gently (window server animation).
private struct ChargingGlow: NSViewRepresentable {
    func makeNSView(context: Context) -> ChargingGlowView { ChargingGlowView() }
    func updateNSView(_ view: ChargingGlowView, context: Context) {}
}

/// A light crossing the bolt every few seconds (masked to the bolt by SwiftUI).
private struct BoltShine: NSViewRepresentable {
    func makeNSView(context: Context) -> ChargeSweepView { ChargeSweepView(duration: 2.6, delay: 0.9, alpha: 0.9) }
    func updateNSView(_ view: ChargeSweepView, context: Context) {}
}

/// Layers for the charging energy (Milestone 18). Each is one Core Animation animation, set up once per size:
/// - a luminous band sweeping left to right (1.8 s),
/// - a soft liquid surface: a sine wave translating by exactly one wavelength, so it loops seamlessly (2.6 s),
/// - a few tiny particles drifting toward the leading edge (CAEmitterLayer, ~4 a second),
/// - a glow at the fill's leading edge, breathing (2.2 s).
/// `.completion` instead plays once: one bright sweep and a flash that settles.
final class ChargingEffectsView: NSView {
    enum Mode: Equatable { case charging, completion }

    var mode: Mode { didSet { if mode != oldValue { configuredWidth = -1; needsLayout = true } } }
    let band = CAGradientLayer()
    let wave = CAShapeLayer()
    let particles = CAEmitterLayer()
    let edge = CAGradientLayer()
    let flash = CALayer()
    private var configuredWidth: CGFloat = -1
    private(set) var completionPlayed = false

    init(mode: Mode) {
        self.mode = mode
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(0.7).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        wave.fillColor = NSColor.white.withAlphaComponent(0.24).cgColor
        edge.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor(red: 0.88, green: 1, blue: 0.92, alpha: 0.95).cgColor]
        edge.startPoint = CGPoint(x: 0, y: 0.5)
        edge.endPoint = CGPoint(x: 1, y: 0.5)
        flash.backgroundColor = NSColor.white.cgColor
        flash.opacity = 0
        let cell = CAEmitterCell()
        cell.contents = Self.dot
        cell.birthRate = 4
        cell.lifetime = 2.4
        cell.velocity = 12
        cell.velocityRange = 4
        cell.emissionLongitude = 0  // toward +x: into the leading edge
        cell.emissionRange = .pi / 10
        cell.scale = 0.75
        cell.scaleRange = 0.25
        cell.alphaSpeed = -0.3
        cell.color = NSColor.white.withAlphaComponent(0.95).cgColor
        particles.emitterCells = [cell]
        particles.emitterShape = .line
        particles.renderMode = .additive
        for sublayer in [wave, band, particles, edge, flash] { layer?.addSublayer(sublayer) }
    }

    required init?(coder: NSCoder) { nil }

    /// A tiny soft dot for the particles (drawn once).
    private static let dot: CGImage? = {
        let size = 6
        guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let colors = [CGColor(red: 1, green: 1, blue: 1, alpha: 1), CGColor(red: 1, green: 1, blue: 1, alpha: 0)] as CFArray
        if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
            context.drawRadialGradient(gradient, startCenter: CGPoint(x: 3, y: 3), startRadius: 0, endCenter: CGPoint(x: 3, y: 3), endRadius: 3, options: [])
        }
        return context.makeImage()
    }()

    var isAnimating: Bool { band.animation(forKey: "flow") != nil }
    var activeAnimations: [String] {
        [(band, "flow"), (wave, "surface"), (edge, "breathe"), (flash, "flash"), (band, "complete")]
            .filter { $0.0.animation(forKey: $0.1) != nil }.map(\.1)
    }

    override func layout() {
        super.layout()
        let width = bounds.width, height = bounds.height
        guard width > 0, height > 0, width != configuredWidth else { return }
        configuredWidth = width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [band, wave, edge, flash] { item.removeAllAnimations() }
        particles.birthRate = 0
        let bandWidth = max(width * 0.36, 12)
        band.frame = CGRect(x: -bandWidth, y: 0, width: bandWidth, height: height)
        let wavelength = max(height * 1.6, 14)
        wave.frame = CGRect(x: 0, y: 0, width: width + wavelength, height: height)
        wave.path = Self.wavePath(width: width + wavelength, height: height, wavelength: wavelength)
        edge.frame = CGRect(x: width - 10, y: 0, width: 10, height: height)
        flash.frame = bounds
        particles.frame = bounds
        particles.emitterPosition = CGPoint(x: 0, y: height / 2)
        particles.emitterSize = CGSize(width: 0, height: height * 0.8)
        CATransaction.commit()
        switch mode {
        case .charging: startCharging(width: width, bandWidth: bandWidth, wavelength: wavelength)
        case .completion: playCompletion(width: width, bandWidth: bandWidth)
        }
    }

    private func startCharging(width: CGFloat, bandWidth: CGFloat, wavelength: CGFloat) {
        let flow = CABasicAnimation(keyPath: "position.x")
        flow.fromValue = -bandWidth / 2
        flow.toValue = width + bandWidth / 2
        flow.duration = 1.8
        flow.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        flow.repeatCount = .infinity
        band.add(flow, forKey: "flow")

        let surface = CABasicAnimation(keyPath: "position.x")
        surface.fromValue = (width + wavelength) / 2
        surface.toValue = (width + wavelength) / 2 - wavelength  // exactly one wavelength: seamless
        surface.duration = 2.6
        surface.repeatCount = .infinity
        wave.add(surface, forKey: "surface")

        let breathe = CABasicAnimation(keyPath: "opacity")
        breathe.fromValue = 0.35
        breathe.toValue = 1
        breathe.duration = 1.1
        breathe.autoreverses = true
        breathe.repeatCount = .infinity
        breathe.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        edge.add(breathe, forKey: "breathe")

        particles.emitterCells?.first?.lifetime = Float(max(width / 12, 0.8))
        particles.birthRate = width > 12 ? 1 : 0  // a nearly empty battery: no room for particles
        completionPlayed = false
    }

    private func playCompletion(width: CGFloat, bandWidth: CGFloat) {
        guard !completionPlayed else { return }
        completionPlayed = true
        band.opacity = 0
        wave.opacity = 0
        edge.opacity = 0
        let sweep = CABasicAnimation(keyPath: "position.x")
        sweep.fromValue = -bandWidth / 2
        sweep.toValue = width + bandWidth / 2
        sweep.duration = 1.1
        sweep.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        let show = CABasicAnimation(keyPath: "opacity")
        show.fromValue = 1
        show.toValue = 1
        show.duration = 1.1
        let group = CAAnimationGroup()
        group.animations = [sweep, show]
        group.duration = 1.1
        band.add(group, forKey: "complete")
        let glow = CAKeyframeAnimation(keyPath: "opacity")
        glow.values = [0, 0.45, 0]
        glow.keyTimes = [0, 0.35, 1]
        glow.duration = 1.4
        glow.beginTime = CACurrentMediaTime() + 0.5
        glow.fillMode = .backwards
        flash.add(glow, forKey: "flash")
    }

    /// One period after another, on the fill's upper part (a liquid surface seen from the side).
    static func wavePath(width: CGFloat, height: CGFloat, wavelength: CGFloat) -> CGPath {
        let path = CGMutablePath()
        let baseline = height * 0.58, amplitude = max(height * 0.1, 1)
        path.move(to: CGPoint(x: 0, y: 0))
        var x: CGFloat = 0
        while x <= width {
            path.addLine(to: CGPoint(x: x, y: baseline + amplitude * sin(x / wavelength * 2 * .pi)))
            x += 1
        }
        path.addLine(to: CGPoint(x: width, y: 0))
        path.closeSubpath()
        return path
    }

    /// For screenshots and the recording: the layers posed as the animation shows them at `t` seconds.
    func pose(at t: TimeInterval) {
        let width = bounds.width
        let bandWidth = max(width * 0.36, 12), wavelength = max(bounds.height * 1.6, 14)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for item in [band, wave, edge] { item.removeAllAnimations() }
        particles.birthRate = 0
        let phase = (t.truncatingRemainder(dividingBy: 1.8)) / 1.8
        let eased = phase < 0.5 ? 2 * phase * phase : 1 - pow(-2 * phase + 2, 2) / 2
        band.position.x = -bandWidth / 2 + (width + bandWidth) * eased
        wave.position.x = (width + wavelength) / 2 - wavelength * (t.truncatingRemainder(dividingBy: 2.6)) / 2.6
        let breath = (1 - cos(t / 1.1 * .pi)) / 2
        edge.opacity = Float(0.35 + 0.65 * breath)
        CATransaction.commit()
    }
}

/// The glow around the outline: a rounded-rect shadow whose opacity breathes (2.4 s).
final class ChargingGlowView: NSView {
    let glow = CAShapeLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        glow.fillColor = NSColor.clear.cgColor
        glow.strokeColor = NSColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 0.9).cgColor
        glow.lineWidth = 1.5
        glow.shadowColor = NSColor(red: 0.36, green: 0.86, blue: 0.52, alpha: 1).cgColor
        glow.shadowRadius = 5
        glow.shadowOffset = .zero
        glow.shadowOpacity = 0.35
        layer?.addSublayer(glow)
    }

    required init?(coder: NSCoder) { nil }

    var isAnimating: Bool { glow.animation(forKey: "pulse") != nil }

    override func layout() {
        super.layout()
        let rect = bounds.insetBy(dx: 8, dy: 8)
        guard rect.width > 0 else { return }
        glow.frame = bounds
        glow.path = CGPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerWidth: 6, cornerHeight: 6, transform: nil)
        guard glow.animation(forKey: "pulse") == nil else { return }
        let pulse = CABasicAnimation(keyPath: "shadowOpacity")
        pulse.fromValue = 0.25
        pulse.toValue = 0.75
        pulse.duration = 1.2
        pulse.autoreverses = true
        pulse.repeatCount = .infinity
        pulse.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        glow.add(pulse, forKey: "pulse")
    }
}

/// A light sweep (the bolt's shine): repeats every `duration + delay` seconds.
final class ChargeSweepView: NSView {
    private let band = CAGradientLayer()
    private let duration: TimeInterval, delay: TimeInterval
    private var configuredWidth: CGFloat = -1

    init(duration: TimeInterval, delay: TimeInterval, alpha: CGFloat) {
        self.duration = duration
        self.delay = delay
        super.init(frame: .zero)
        wantsLayer = true
        layer?.masksToBounds = true
        band.colors = [NSColor.white.withAlphaComponent(0).cgColor, NSColor.white.withAlphaComponent(alpha).cgColor,
                       NSColor.white.withAlphaComponent(0).cgColor]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
        layer?.addSublayer(band)
    }

    required init?(coder: NSCoder) { nil }

    override func layout() {
        super.layout()
        let width = bounds.width
        guard width > 0, width != configuredWidth else { return }
        configuredWidth = width
        band.frame = CGRect(x: -width, y: 0, width: width * 0.6, height: bounds.height)
        let move = CABasicAnimation(keyPath: "position.x")
        move.fromValue = -width * 0.3
        move.toValue = width * 1.3
        move.duration = duration
        let group = CAAnimationGroup()
        group.animations = [move]
        group.duration = duration + delay
        group.repeatCount = .infinity
        band.add(group, forKey: "shine")
    }
}

/// Apps Using Significant Energy: macOS's per-process estimate, grouped by app. Honest about what it is.
private struct EnergySection: View {
    let monitor: EnergyMonitor
    let expanded: Bool
    let browserMedia: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Apps Using Significant Energy").font(OrbitType.eyebrow).foregroundStyle(Theme.tertiary).textCase(.uppercase)
            switch monitor.state {
            case .idle, .measuring:
                Text("Measuring…").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            case .unavailable(let reason):
                Text(reason).font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            case .ready(let apps, let measured, _):
                if apps.isEmpty {
                    Text("None right now").font(OrbitType.caption).foregroundStyle(Theme.secondary)
                } else {
                    ForEach(apps.prefix(expanded ? 6 : 2)) { app in EnergyRow(app: app, expanded: expanded) }
                }
                if expanded {
                    Text(Self.footnote(apps: apps, measured: measured, browserMedia: browserMedia))
                        .font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 12) {
                        OrbitLinkButton(title: "Activity Monitor") { QuickAction.activityMonitor.perform() }
                        OrbitLinkButton(title: "Battery Settings") { SystemSettingsLink.battery.open() }
                    }
                }
            }
        }
    }

    static func footnote(apps: [AppEnergy], measured: Bool, browserMedia: String?) -> String {
        var parts = [measured
            ? "≈ watts: macOS's own per-process estimate (CPU work, not the display or GPU), averaged over 5 s. Activity Monitor's Energy Impact is a different scale."
            : "This Mac reports no per-process energy, so apps are ranked by CPU time: an estimate, not battery use."]
        if apps.contains(where: { EnergyRow.isBrowser($0) }) {
            parts.append("A browser's energy is the whole browser's: macOS and browsers don't say which website uses it."
                         + (browserMedia.map { " Playing now: \($0)." } ?? ""))
        }
        return parts.joined(separator: " ")
    }
}

private struct EnergyRow: View {
    let app: AppEnergy
    let expanded: Bool

    static func isBrowser(_ app: AppEnergy) -> Bool {
        guard let path = app.bundlePath, let id = Bundle(path: path)?.bundleIdentifier else { return false }
        return EnergyAttribution.browsers.contains(id)
    }

    private var running: NSRunningApplication? {
        guard let path = app.bundlePath else { return nil }
        return NSWorkspace.shared.runningApplications.first { $0.bundleURL?.path(percentEncoded: false).hasPrefix(path) == true }
    }

    var body: some View {
        let running = running
        HStack(spacing: 7) {
            Group {
                if let path = app.bundlePath {
                    Image(nsImage: NSWorkspace.shared.icon(forFile: path)).resizable().interpolation(.high)
                } else {
                    Image(systemName: "terminal").font(.system(size: 10)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 16, height: 16)
            Text(app.name).font(OrbitType.caption).foregroundStyle(.white.opacity(0.9)).lineLimit(1)
            if expanded, running?.isActive == true {
                Text("In use").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.secondary)
            }
            Spacer(minLength: 4)
            if expanded {
                Text(app.watts.map { String(format: "≈ %.1f W", $0) } ?? String(format: "%.0f%% CPU", app.cpuPercent))
                    .font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary)
            }
            Text(app.level == .high ? "High" : "Moderate")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(app.level == .high ? Color.black : .white.opacity(0.85))
                .padding(.horizontal, 6).frame(height: 15)
                .background(app.level == .high ? HubTokens.attention : Color.white.opacity(0.14), in: .capsule)
            if expanded, let running {
                Button { running.activate() } label: { Image(systemName: "arrow.up.forward.app").font(.system(size: 10)) }
                    .buttonStyle(.plain).foregroundStyle(Theme.secondary).help("Bring \(app.name) to the front")
                    .accessibilityLabel("Show \(app.name)")
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(app.name), \(app.level == .high ? "high" : "moderate") energy"
                            + (app.watts.map { String(format: ", about %.1f watts", $0) } ?? ""))
    }
}

/// System Settings panes Orbit links to (public x-apple.systempreferences URLs; opening shows the pane, nothing changes).
enum SystemSettingsLink: String {
    case battery = "com.apple.Battery-Settings.extension"
    case displays = "com.apple.Displays-Settings.extension"

    @MainActor func open() {
        if let url = URL(string: "x-apple.systempreferences:\(rawValue)") { NSWorkspace.shared.open(url) }
    }
}
