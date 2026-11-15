import CoreAudio
import SwiftUI

/// The System tab's long-lived state: one of each model, kept by the
/// dashboard so panes keep their data between visits. Cheap to create;
/// nothing touches hardware until a pane appears.
@MainActor @Observable
final class SystemServices {
    /// View state lives here: SwiftUI's @State is a macro this toolchain lacks.
    var pane = SystemPane.overview
    private(set) var battery: BatteryStatus?
    private(set) var health: BatteryHealth?
    @ObservationIgnored let wifi = WiFiModel()
    @ObservationIgnored let bluetooth = BluetoothModel()
    @ObservationIgnored let audio = AudioDevicesModel()
    @ObservationIgnored let keepAwake = KeepAwakeModel.shared

    func readPower() {
        battery = BatteryStatus.current()
        health = BatteryHealth.current()
    }
}

enum SystemPane: String, CaseIterable, Identifiable {
    case overview, wifi, bluetooth, sound, power
    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .wifi: "Wi-Fi"
        case .bluetooth: "Bluetooth"
        case .sound: "Sound"
        case .power: "Power"
        }
    }

    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .wifi: "wifi"
        case .bluetooth: "dot.radiowaves.left.and.right"
        case .sound: "speaker.wave.2"
        case .power: "bolt.batteryblock"
        }
    }
}

/// System: a rail of panes beside the selected pane. Overview keeps the
/// existing System widgets; the other panes are full-height tools.
struct SystemPage: View {
    let services: SystemServices
    let widgets: [DashboardModel.PlacedWidget]
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        let pane = services.pane
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 2) {
                ForEach(SystemPane.allCases) { item in
                    Button { services.pane = item } label: {
                        Label(item.title, systemImage: item.symbol)
                            .font(.system(size: 12, weight: pane == item ? .semibold : .medium))
                            .foregroundStyle(pane == item ? .white : Theme.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 7)
                            .background(pane == item ? Theme.selectedFill : .clear, in: .rect(cornerRadius: 9, style: .continuous))
                    }
                    .buttonStyle(DashboardButtonStyle())
                    .accessibilityAddTraits(pane == item ? .isSelected : [])
                }
                Spacer(minLength: 0)
            }
            .frame(width: 118)

            Group {
                switch pane {
                case .overview: CategorySection(widgets: widgets)
                case .wifi: WiFiPane(model: services.wifi)
                case .bluetooth: BluetoothPane(model: services.bluetooth)
                case .sound: SoundPane(model: services.audio)
                case .power: PowerPane(services: services)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .id(pane)
            .transition(.opacity)
        }
        .animation(OrbitMotion.animation(.snappy(duration: 0.2), reduced: reduceMotion), value: pane)
    }
}

// MARK: Shared pieces

/// A full-height pane surface with a title row.
struct PaneCard<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(title).font(OrbitType.title)
                Spacer(minLength: 0)
                accessory
            }
            content
        }
        .padding(OrbitGlass.cardPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(OrbitGlass.cardFill, in: .rect(cornerRadius: OrbitGlass.cardRadius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: OrbitGlass.cardRadius, style: .continuous)
            .strokeBorder(OrbitGlass.rim, lineWidth: 1).allowsHitTesting(false))
    }
}

/// Label: value, in a small surface.
struct Fact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased()).font(.system(size: 8.5, weight: .semibold)).tracking(0.5).foregroundStyle(Theme.tertiary)
            Text(value).font(.system(size: 11.5, weight: .medium)).monospacedDigit().lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 9)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .orbitSurface(radius: 9)
        .accessibilityElement(children: .combine)
    }
}

/// A notice row with an action (permissions, limits).
struct InlineNotice: View {
    let text: String
    let symbol: String
    var action: (title: String, run: () -> Void)?

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: symbol).foregroundStyle(OrbitGlass.warning)
            Text(text).font(OrbitType.caption).foregroundStyle(Theme.secondary).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
            if let action { OrbitGlassButton(title: action.title, symbol: "arrow.right", action: action.run) }
        }
        .padding(8)
        .orbitSurface(radius: 10)
    }
}

private struct SignalGlyph: View {
    let rssi: Int
    var size: CGFloat = 13

    var body: some View {
        let bars = WiFiSignal.bars(rssi: rssi)
        Image(systemName: "wifi", variableValue: Double(bars) / 4)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(bars >= 2 ? Theme.accent : OrbitGlass.warning)
            .accessibilityLabel("Signal \(WiFiSignal.quality(rssi: rssi))")
    }
}

// MARK: Wi-Fi

private struct WiFiPane: View {
    let model: WiFiModel
    private var showingDiagnostics: Bool { model.showingDiagnostics }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            hero
            PaneCard(title: showingDiagnostics ? "Diagnostics" : "Networks") {
                if showingDiagnostics {
                    OrbitGlassButton(title: "Networks", symbol: "chevron.left") { model.showingDiagnostics = false }
                } else {
                    if model.isScanning { Text("Scanning…").font(OrbitType.caption).foregroundStyle(Theme.tertiary) }
                    OrbitGlassButton(title: "Diagnose", symbol: "stethoscope") { model.showingDiagnostics = true; model.diagnose() }
                    OrbitGlassButton(title: "Refresh", symbol: "arrow.clockwise") { model.scan() }
                        .disabled(model.isScanning)
                }
            } content: {
                if showingDiagnostics { diagnostics } else { networkList }
            }
        }
        .onAppear { model.start() }
        .onDisappear { model.stop() }
    }

    @ViewBuilder private var hero: some View {
        let status = model.status
        HStack(alignment: .top, spacing: 12) {
            ZStack {
                Circle().fill(Theme.accent.opacity(status?.isAssociated == true ? 0.18 : 0.06))
                if let status, status.isAssociated {
                    SignalGlyph(rssi: status.rssi, size: 20)
                } else {
                    Image(systemName: status?.isPoweredOn == false ? "wifi.slash" : "wifi.exclamationmark")
                        .font(.system(size: 18, weight: .semibold)).foregroundStyle(Theme.secondary)
                }
            }
            .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Text(title).font(.system(size: 16, weight: .semibold, design: .rounded)).lineLimit(1)
                    if status?.isAssociated == true {
                        Label(model.isOnline ? "Connected" : "No internet",
                              systemImage: model.isOnline ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .font(OrbitType.caption)
                            .foregroundStyle(model.isOnline ? HubTokens.running : OrbitGlass.warning)
                    }
                    Spacer(minLength: 0)
                    if let status {
                        OrbitSwitch(label: "Wi-Fi power", isOn: status.isPoweredOn, set: model.setPower)
                    }
                }
                Text(subtitle).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                HStack(spacing: 6) {
                    Fact(label: "IP address", value: model.ip.ipv4.first ?? model.ip.ipv6.first ?? "—")
                    Fact(label: "Router", value: model.ip.router ?? "—")
                    Fact(label: "DNS", value: (model.ip.dns.first { $0.contains(".") } ?? model.ip.dns.first) ?? "—")
                    if let status, status.isAssociated {
                        Fact(label: "Tx rate", value: "\(Int(status.transmitRate)) Mbps")
                    }
                }
            }
        }
        .padding(12)
        .orbitSurface(radius: OrbitGlass.cardRadius)
    }

    private var title: String {
        guard let status = model.status else { return "No Wi-Fi hardware" }
        guard status.isPoweredOn else { return "Wi-Fi is off" }
        guard status.isAssociated else { return "Not connected" }
        return status.ssid ?? (model.namesHidden ? "Network name hidden" : "Connected network")
    }

    private var subtitle: String {
        guard let status = model.status, status.isAssociated else {
            return model.ip.interface.map { "Online via \($0)" } ?? "Choose a network below"
        }
        let snr = WiFiSignal.snr(rssi: status.rssi, noise: status.noise).map { "SNR \($0) dB" }
        return [WiFiSignal.quality(rssi: status.rssi) + " signal (\(status.rssi) dBm)", snr, status.security?.rawValue,
                status.band, status.channel.map { "Channel \($0)" }]
            .compactMap { $0 }.joined(separator: " · ")
    }

    @ViewBuilder private var networkList: some View {
        if model.namesHidden {
            InlineNotice(text: "macOS hides Wi-Fi names from apps without Location access. Orbit only reads them on this Mac.",
                         symbol: "location.slash", action: ("Allow", model.requestLocation))
        }
        if let error = model.scanError {
            StatusMessage(text: error, symbol: "wifi.exclamationmark", tone: .warning)
        } else if model.networks.isEmpty {
            StatusMessage(text: model.isScanning ? "Looking for networks…" : model.namesHidden ? "Names hidden" : "No networks found",
                          symbol: "wifi")
        } else {
            HubScroll {
                VStack(spacing: 4) {
                    ForEach(model.networks) { network in
                        NetworkRow(network: network, model: model)
                    }
                }
            }
        }
        HStack {
            if let last = model.lastScan {
                Text("Scanned \(last.formatted(.relative(presentation: .named)))").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            }
            Spacer()
            OrbitLinkButton(title: "Wi-Fi Settings…", action: model.openSettings)
        }
    }

    @ViewBuilder private var diagnostics: some View {
        if model.isDiagnosing || model.diagnostics == nil {
            OrbitLoadingView()
        } else if let steps = model.diagnostics {
            let failure = steps.first { $0.result == .fail }
            Text(failure.map { "Problem found: \($0.title.lowercased()) — \($0.detail)." } ?? "Everything looks healthy.")
                .font(OrbitType.body)
                .foregroundStyle(failure == nil ? HubTokens.running : OrbitGlass.warning)
            HubScroll {
                VStack(spacing: 4) {
                    ForEach(steps) { step in
                        HStack(spacing: 8) {
                            Image(systemName: step.result == .pass ? "checkmark.circle.fill"
                                  : step.result == .warn ? "exclamationmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(step.result == .pass ? HubTokens.running
                                                 : step.result == .warn ? OrbitGlass.warning : OrbitGlass.critical)
                            Text(step.title)
                            Spacer()
                            Text(step.detail).foregroundStyle(Theme.secondary).monospacedDigit().lineLimit(1)
                        }
                        .font(OrbitType.body)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .orbitSurface(radius: 9)
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
    }
}

private struct NetworkRow: View {
    let network: WiFiNetwork
    let model: WiFiModel

    var body: some View {
        let joining = model.joining == network.ssid
        let hovering = model.hovered == network.ssid
        let join = { model.join(network) }
        HStack(spacing: 9) {
            SignalGlyph(rssi: network.rssi)
                .frame(width: 18)
            Text(network.ssid).font(.system(size: 12, weight: network.isCurrent ? .semibold : .medium)).lineLimit(1)
            if network.isCurrent {
                HubTag(text: "CONNECTED", tint: HubTokens.running)
            } else if network.isKnown {
                HubTag(text: "KNOWN")
            }
            Spacer(minLength: 4)
            if let band = network.band { Text(band).font(OrbitType.caption).foregroundStyle(Theme.tertiary) }
            Label(network.security.rawValue, systemImage: network.security.isSecured ? "lock.fill" : "lock.open")
                .font(OrbitType.caption).foregroundStyle(Theme.secondary)
            if !network.isCurrent {
                Button(action: join) {
                    Text(joining ? "Joining…" : "Join").font(.system(size: 10.5, weight: .semibold))
                        .padding(.horizontal, 10).padding(.vertical, 3)
                }
                .buttonStyle(OrbitGlassButtonStyle())
                    .opacity(hovering || joining ? 1 : 0)
                    .disabled(joining)
                    .help(network.isKnown || !network.security.isSecured
                          ? "Join with the password macOS keeps" : "Opens Wi-Fi Settings to enter the password")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(hovering ? Theme.selectedFill : OrbitGlass.surfaceFill, in: .rect(cornerRadius: 9, style: .continuous))
        .onHover { inside in model.hovered = inside ? network.ssid : (model.hovered == network.ssid ? nil : model.hovered) }
        .accessibilityElement(children: .combine)
        .accessibilityAction(named: "Join", join)
    }
}

// MARK: Bluetooth

private struct BluetoothPane: View {
    let model: BluetoothModel

    var body: some View {
        PaneCard(title: "Bluetooth") {
            if let on = model.isPoweredOn {
                Label(on ? "On" : "Off", systemImage: on ? "checkmark.circle.fill" : "power")
                    .font(OrbitType.caption).foregroundStyle(on ? HubTokens.running : Theme.secondary)
            }
            if model.access == .allowed {
                OrbitGlassButton(title: "Refresh", symbol: "arrow.clockwise", action: model.refresh)
            }
            OrbitLinkButton(title: "Bluetooth Settings…") {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.BluetoothSettings")!)
            }
        } content: {
            switch model.access {
            case .notDetermined:
                VStack(spacing: 12) {
                    StatusMessage(text: "See your paired devices and connect them from here. macOS asks once for Bluetooth access.",
                                  symbol: "dot.radiowaves.left.and.right")
                        .fixedSize(horizontal: false, vertical: true)
                    OrbitGlassButton(title: "Show Devices", symbol: "lock.open", prominent: true, action: model.requestAccess)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .denied:
                InlineNotice(text: "Bluetooth access is off for Orbit.", symbol: "lock", action: ("Open Privacy", {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Bluetooth")!)
                }))
            case .allowed:
                if let error = model.lastError { InlineNotice(text: error, symbol: "exclamationmark.triangle") }
                if model.devices.isEmpty {
                    StatusMessage(text: "No paired devices", symbol: "dot.radiowaves.left.and.right")
                } else {
                    HubScroll {
                        VStack(spacing: 4) {
                            ForEach(model.devices) { device in BluetoothRow(device: device, model: model) }
                        }
                    }
                }
            }
        }
        .onAppear { if model.access == .allowed { model.requestAccess() } }
    }
}

private struct BluetoothRow: View {
    let device: BluetoothDevice
    let model: BluetoothModel

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.symbol).frame(width: 20)
                .foregroundStyle(device.isConnected ? Theme.accent : Theme.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name).lineLimit(1)
                Text(device.isConnected ? "Connected" : "Not connected")
                    .font(OrbitType.caption).foregroundStyle(device.isConnected ? HubTokens.running : Theme.tertiary)
            }
            Spacer()
            if let battery = device.batteryPercent {
                Label("\(battery)%", systemImage: "battery.75percent").font(OrbitType.caption).foregroundStyle(Theme.secondary)
            }
            OrbitGlassButton(title: model.busy.contains(device.id) ? "…" : device.isConnected ? "Disconnect" : "Connect",
                             symbol: device.isConnected ? "xmark" : "link") { model.toggleConnection(device.id) }
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .orbitSurface(radius: 9)
        .accessibilityElement(children: .combine)
    }
}

// MARK: Sound

private struct SoundPane: View {
    let model: AudioDevicesModel

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            column(title: "Output", devices: model.outputs, selected: model.defaultOutput, volume: model.outputVolume, output: true)
            column(title: "Input", devices: model.inputs, selected: model.defaultInput, volume: model.inputVolume, output: false)
        }
        .onAppear(perform: model.refresh)
    }

    private func column(title: String, devices: [AudioDevice], selected: AudioObjectID?, volume: Float?, output: Bool) -> some View {
        PaneCard(title: title) {
            EmptyView()
        } content: {
            HStack(spacing: 8) {
                Image(systemName: output ? "speaker.fill" : "mic.fill").foregroundStyle(Theme.secondary)
                if let volume {
                    OrbitSlider(label: "\(title) volume", value: Double(volume)) { model.setVolume(Float($0), output: output) }
                    Text("\(Int((volume * 100).rounded()))%").font(OrbitType.caption).monospacedDigit().frame(width: 34, alignment: .trailing)
                } else {
                    Text("Volume is set on the device").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
                }
            }
            HubScroll {
                VStack(spacing: 4) {
                    ForEach(devices) { device in
                        Button { model.setDefault(device.id, output: output) } label: {
                            HStack(spacing: 8) {
                                Image(systemName: device.symbol).frame(width: 18)
                                Text(device.name).lineLimit(1)
                                Spacer()
                                if device.id == selected { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                            .padding(.horizontal, 10).padding(.vertical, 7)
                            .background(device.id == selected ? Theme.selectedFill : OrbitGlass.surfaceFill,
                                        in: .rect(cornerRadius: 9, style: .continuous))
                        }
                        .buttonStyle(DashboardButtonStyle())
                        .accessibilityAddTraits(device.id == selected ? .isSelected : [])
                    }
                }
            }
        }
    }
}

// MARK: Power

private struct PowerPane: View {
    let services: SystemServices

    var body: some View {
        let battery = services.battery, health = services.health
        HStack(alignment: .top, spacing: 10) {
            PaneCard(title: "Battery") {
                OrbitLinkButton(title: "Battery Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Battery-Settings.extension")!)
                }
            } content: {
                if let battery {
                    HStack(alignment: .firstTextBaseline) {
                        OrbitGlassMetric(value: "\(battery.percent)", unit: "%")
                        Spacer()
                        Label(battery.isCharging ? "Charging" : battery.isPluggedIn ? "On power" : "On battery",
                              systemImage: battery.isCharging ? "bolt.fill" : battery.isPluggedIn ? "powerplug.fill" : "battery.75percent")
                            .font(OrbitType.caption).foregroundStyle(Theme.secondary)
                    }
                    MeterBar(fraction: Double(battery.percent) / 100,
                             tint: battery.percent <= 20 && !battery.isPluggedIn ? OrbitGlass.critical : Theme.accent)
                    let h = health ?? BatteryHealth()
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                        Fact(label: "Maximum capacity", value: h.maximumCapacity.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                        Fact(label: "Cycle count", value: h.cycleCount.map(String.init) ?? "—")
                        if let condition = h.condition { Fact(label: "Condition", value: condition) }
                        if let watts = h.adapterWatts { Fact(label: "Power adapter", value: "\(watts) W") }
                        Fact(label: battery.isCharging ? "Until full" : "Remaining", value: remaining(h, charging: battery.isCharging))
                    }
                    Text("A charge limit (such as 80%) is set in Battery Settings › Charging; apps can't change it.")
                        .font(OrbitType.caption).foregroundStyle(Theme.tertiary).fixedSize(horizontal: false, vertical: true)
                } else {
                    StatusMessage(text: "No battery in this Mac", symbol: "powerplug")
                }
            }
            KeepAwakeCard(model: services.keepAwake)
                .frame(width: 210)
        }
        .onAppear(perform: services.readPower)
    }

    private func remaining(_ health: BatteryHealth, charging: Bool) -> String {
        let minutes = charging ? health.minutesToFull : health.minutesToEmpty
        guard let minutes else { return "Calculating" }
        return Duration.seconds(minutes * 60).formatted(.units(allowed: [.hours, .minutes], width: .abbreviated))
    }
}

/// Keep Awake controls in a pane card.
struct KeepAwakeCard: View {
    let model: KeepAwakeModel

    var body: some View {
        PaneCard(title: "Keep Awake") {
            Image(systemName: model.isActive ? "cup.and.heat.waves.fill" : "cup.and.saucer")
                .foregroundStyle(model.isActive ? Theme.accent : Theme.secondary)
        } content: {
            KeepAwakeControls(model: model)
        }
    }
}

/// The controls alone; also the body of the Keep Awake widget.
struct KeepAwakeControls: View {
    let model: KeepAwakeModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusText).font(OrbitType.body).foregroundStyle(model.isActive ? .white : Theme.secondary)
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 6) {
                ForEach(KeepAwakeModel.Duration.allCases) { duration in
                    Button { model.start(duration) } label: {
                        Text(duration.title).font(.system(size: 11, weight: .semibold))
                            .frame(maxWidth: .infinity).padding(.vertical, 6)
                    }
                    .buttonStyle(OrbitGlassButtonStyle())
                }
            }
            if model.isActive {
                OrbitGlassButton(title: "Let it sleep", symbol: "moon", prominent: true, action: model.stop)
            }
        }
    }

    private var statusText: String {
        guard model.isActive else { return "Your Mac sleeps normally." }
        guard let until = model.until else { return "Awake until you turn this off." }
        return "Awake until \(until.formatted(date: .omitted, time: .shortened))."
    }
}
