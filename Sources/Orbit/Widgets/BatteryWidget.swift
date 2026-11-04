import IOKit.ps
import SwiftUI

/// Internal battery charge. Live and push-driven: while visible it subscribes
/// to IOKit power-source notifications instead of polling. No permission.
@MainActor @Observable
final class BatteryWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "battery", title: "Battery", description: "Charge level and power source",
        symbol: "battery.100percent", category: .system, availability: .live)
    private(set) var state = WidgetState.loading
    private(set) var status: BatteryStatus?

    private let read: () -> BatteryStatus?
    // ponytail: unretained self in the IOKit context; safe because widgets live
    // for the app's lifetime and stop() removes the source. Retain it if
    // widgets ever become short-lived.
    @ObservationIgnored private var source: CFRunLoopSource?

    var isObserving: Bool { source != nil }

    init(read: @escaping () -> BatteryStatus? = BatteryStatus.current) {
        self.read = read
    }

    func start() {
        refresh()
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
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
    }

    func refresh() {
        status = read()
        state = status == nil ? .unavailable("No battery") : .ready
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        guard let status else { return AnyView(EmptyView()) }
        return AnyView(BatteryView(status: status))
    }
}

private struct BatteryView: View {
    let status: BatteryStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            OrbitGlassMetric(value: "\(status.percent)", unit: "%")
            if status.isCharging {
                Image(systemName: "bolt.fill").foregroundStyle(Theme.accent)
            }
        }
        MeterBar(fraction: Double(status.percent) / 100,
                 tint: status.percent <= 20 && !status.isPluggedIn ? OrbitGlass.critical : Theme.accent)
        Text(status.isCharging ? "Charging" : status.isPluggedIn ? "Plugged in" : "On battery")
            .font(OrbitType.body)
            .foregroundStyle(Theme.secondary)
    }
}
