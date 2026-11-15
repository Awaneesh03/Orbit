import AppKit
import CoreGraphics
import SwiftUI

// How bright the displays are (Milestone 16). Read-only, public APIs only:
// - Built-in panel: the backlight driver's level from the I/O Registry
//   (`BrightnessMonitor`, shared with the brightness HUD: one monitor, event
//   driven with a light poll only while someone is looking).
// - External displays: their brightness lives in the monitor itself and is
//   read over DDC/CI. On Apple Silicon every app that does this (MonitorControl,
//   MacBrightnessKit, OpenDisplay) calls IOAVService functions that aren't in
//   Apple's public SDK, so Orbit says "not readable" instead of guessing.
// - Changing brightness needs private frameworks (DisplayServices) or DDC
//   writes: not done. "Display Settings…" opens the real control.

struct DisplayBrightness: Identifiable, Equatable, Sendable {
    let id: CGDirectDisplayID
    let name: String
    let isBuiltIn: Bool
    /// 0…1; nil when it can't be read.
    let level: Double?

    var note: String {
        if level != nil { return "" }
        return isBuiltIn ? "Not reported by this Mac" : "Not readable: external displays report brightness over DDC/CI, which needs a private macOS interface"
    }

    enum Band: String, Sendable { case low, medium, high }
    static func band(_ level: Double) -> Band { level < 0.34 ? .low : level < 0.67 ? .medium : .high }

    /// Every connected display; the built-in one carries `builtInLevel`.
    @MainActor static func current(builtInLevel: Double?) -> [DisplayBrightness] {
        NSScreen.screens.compactMap { screen in
            guard let number = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber else { return nil }
            let id = CGDirectDisplayID(number.uint32Value)
            let builtIn = CGDisplayIsBuiltin(id) != 0
            return DisplayBrightness(id: id, name: screen.localizedName, isBuiltIn: builtIn, level: builtIn ? builtInLevel : nil)
        }
        .sorted { $0.isBuiltIn && !$1.isBuiltIn }
    }
}

@MainActor @Observable
final class BrightnessWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "brightness", title: "Brightness", description: "How bright each display is (read-only)",
        symbol: "sun.max", category: .system, availability: .live, isEnabledByDefault: false)
    var state: WidgetState { .ready }
    /// The shared monitor (set by the app; tests inject their own).
    var monitor: BrightnessMonitor?
    /// Connected displays, re-read on start and when displays change.
    private(set) var displayChanges = 0
    @ObservationIgnored private var observer: (any NSObjectProtocol)?

    init(monitor: BrightnessMonitor? = nil) { self.monitor = monitor }

    func start() {
        monitor?.start(client: "widget")
        observer = NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.displayChanges += 1 }
        }
    }

    func stop() {
        monitor?.stop(client: "widget")
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    var displays: [DisplayBrightness] {
        _ = displayChanges
        return DisplayBrightness.current(builtInLevel: monitor?.isRunning == true ? monitor?.level : nil)
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(BrightnessList(displays: displays, compact: presentation == .compact))
    }
}

struct BrightnessList: View {
    let displays: [DisplayBrightness]
    let compact: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if displays.isEmpty {
                Text("No display found").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            }
            ForEach(displays.prefix(compact ? 2 : 4)) { display in BrightnessRow(display: display) }
            if !compact {
                HStack {
                    Text("Read-only: macOS doesn't let apps change brightness.").font(.system(size: 9.5)).foregroundStyle(Theme.tertiary)
                    Spacer(minLength: 4)
                    OrbitLinkButton(title: "Display Settings…") { SystemSettingsLink.displays.open() }
                }
            }
        }
    }
}

struct BrightnessRow: View {
    let display: DisplayBrightness
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: display.level.map(BrightnessStyle.symbol) ?? "sun.max")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(display.level == nil ? Theme.tertiary : BrightnessStyle.warm)
                    .frame(width: 14)
                Text(display.name).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 4)
                if let level = display.level {
                    Text(BrightnessStyle.percentage(level)).font(.system(size: 11, weight: .semibold, design: .rounded).monospacedDigit())
                        .contentTransition(reduceMotion ? .identity : .numericText(value: level))
                }
            }
            if let level = display.level {
                Capsule().fill(Color.white.opacity(0.08)).frame(height: 6)
                    .overlay(alignment: .leading) {
                        GeometryReader { geometry in
                            Capsule().fill(LinearGradient(colors: [BrightnessStyle.warm.opacity(0.55), BrightnessStyle.warm],
                                                          startPoint: .leading, endPoint: .trailing))
                                .frame(width: max(6, geometry.size.width * level))
                        }
                    }
                    .animation(reduceMotion ? nil : .snappy(duration: 0.25), value: level)
            } else {
                Text(display.note).font(.system(size: 9.5)).foregroundStyle(Theme.tertiary).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(display.level.map { "\(display.name) brightness \(Int(($0 * 100).rounded())) percent, \(DisplayBrightness.band($0).rawValue)" }
                            ?? "\(display.name): brightness not readable")
    }
}
