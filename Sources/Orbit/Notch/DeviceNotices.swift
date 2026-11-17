import AppKit
import IOBluetooth
import SwiftUI

// Notch notices: a 3-second note below the notch. Milestone 20: a paired
// Bluetooth device connects or disconnects (IOBluetooth's public notifications,
// only once Orbit already has Bluetooth access; it never asks for it).
// Milestone 21: the charger and battery (`PowerNotices`), a finished timer and
// a picked colour use the same note (`LiveActivities.swift`).

/// What shows, and for how long. Pure logic: the watcher posts, the panel follows `current`.
@MainActor @Observable
final class DeviceNotices {
    struct Notice: Equatable, Sendable {
        enum Tint: Sendable { case accent, good, warning, critical, neutral }

        /// What it's about (a device's address, "power", "timer"…) and its state there: the same
        /// id and state again within `repeatWindow` isn't shown twice.
        let id: String
        var state = ""
        let title: String
        let detail: String
        let symbol: String
        var tint = Tint.accent
        /// A small level bar (battery charge), 0…1.
        var level: Double?
        /// A colour swatch (a picked colour), sRGB 0…1.
        var swatch: [Double]?

        /// A Bluetooth device connected or disconnected (Milestone 20).
        static func device(id: String, name: String, symbol: String, connected: Bool, battery: Int?) -> Notice {
            Notice(id: id, state: connected ? "connected" : "disconnected", title: name,
                   detail: connected ? battery.map { "Connected · \($0)%" } ?? "Connected" : "Disconnected",
                   symbol: symbol, tint: connected ? .accent : .neutral)
        }
    }

    private(set) var current: Notice?
    /// Settings › General › Bluetooth device notices.
    var isEnabled = true {
        didSet { if !isEnabled { dismiss() } }
    }
    /// Whether the slot below the notch is free for a notice right now (set by the app).
    @ObservationIgnored var canShow: @MainActor () -> Bool = { true }
    @ObservationIgnored var duration = Duration.seconds(3)
    /// A device that flaps (connects, drops, reconnects) is announced once per state in this window.
    static let repeatWindow: TimeInterval = 10

    @ObservationIgnored private let scheduler: any HUDScheduler
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private var timer: (any HUDTimer)?
    @ObservationIgnored private var lastShown: [String: (state: String, at: Date)] = [:]

    init(scheduler: any HUDScheduler = TaskHUDScheduler(), clock: @escaping () -> Date = { .now }) {
        self.scheduler = scheduler
        self.clock = clock
    }

    /// A transient note: if something more important holds the slot, it's dropped rather than queued.
    func post(_ notice: Notice) {
        guard isEnabled else { return }
        let now = clock()
        if let last = lastShown[notice.id], last.state == notice.state,
           now.timeIntervalSince(last.at) < Self.repeatWindow { return }
        guard canShow() else { return }
        lastShown[notice.id] = (notice.state, now)
        current = notice
        timer?.cancel()
        timer = scheduler.after(duration) { [weak self] in self?.dismiss() }
    }

    func dismiss() {
        timer?.cancel()
        timer = nil
        if current != nil { current = nil }
    }
}

/// IOBluetooth's connect and disconnect notifications, turned into notices.
@MainActor
final class BluetoothConnectionWatcher: NSObject {
    private let notices: DeviceNotices
    private var connectNote: IOBluetoothUserNotification?
    private var disconnectNotes: [String: IOBluetoothUserNotification] = [:]
    private var connected: Set<String> = []

    init(notices: DeviceNotices) { self.notices = notices }

    var isRunning: Bool { connectNote != nil }

    /// Starts only with Bluetooth access already granted; never prompts. Devices already
    /// connected are the baseline: registering replays them, and they aren't announced.
    func start() {
        guard connectNote == nil, BluetoothModel.currentAccess() == .allowed else { return }
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? [] where device.isConnected() {
            guard let address = device.addressString else { continue }
            connected.insert(address)
            watchDisconnect(device, address: address)
        }
        connectNote = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(deviceConnected(_:device:)))
    }

    func stop() {
        connectNote?.unregister()
        connectNote = nil
        disconnectNotes.values.forEach { $0.unregister() }
        disconnectNotes = [:]
        connected = []
    }

    @objc nonisolated private func deviceConnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // IOBluetooth delivers on the main run loop it was registered from.
        nonisolated(unsafe) let device = device
        MainActor.assumeIsolated { changed(device, isConnected: true) }
    }

    @objc nonisolated private func deviceDisconnected(_ note: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        // IOBluetooth delivers on the main run loop it was registered from.
        nonisolated(unsafe) let device = device
        MainActor.assumeIsolated { changed(device, isConnected: false) }
    }

    private func changed(_ device: IOBluetoothDevice, isConnected: Bool) {
        guard let address = device.addressString else { return }
        if isConnected {
            watchDisconnect(device, address: address)
            guard connected.insert(address).inserted else { return }  // the replay of an already-connected device
        } else {
            disconnectNotes.removeValue(forKey: address)?.unregister()
            guard connected.remove(address) != nil else { return }
        }
        let name = device.name ?? device.nameOrAddress ?? address
        let kind = BluetoothDevice.kind(major: device.deviceClassMajor, minor: device.deviceClassMinor)
        let symbol = BluetoothDevice(id: address, name: name, kind: kind, isConnected: isConnected, batteryPercent: nil).symbol
        notices.post(.device(id: address, name: name, symbol: symbol, connected: isConnected,
                             battery: isConnected ? BluetoothModel.hidBatteries()[name] : nil))
    }

    private func watchDisconnect(_ device: IOBluetoothDevice, address: String) {
        guard disconnectNotes[address] == nil,
              let note = device.register(forDisconnectNotification: self, selector: #selector(deviceDisconnected(_:device:))) else { return }
        disconnectNotes[address] = note
    }
}

struct DeviceNoticeView: View {
    let notices: DeviceNotices

    var body: some View {
        HStack(spacing: 10) {
            if let notice = notices.current {
                if let swatch = notice.swatch, swatch.count == 3 {
                    Circle().fill(Color(red: swatch[0], green: swatch[1], blue: swatch[2]))
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 1))
                        .frame(width: 22, height: 22)
                } else {
                    Image(systemName: notice.symbol)
                        .font(.system(size: 15, weight: .semibold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(Self.color(notice.tint))
                        .frame(width: 22)
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(notice.title).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(notice.detail).font(.system(size: 10, weight: .medium).monospacedDigit()).foregroundStyle(Theme.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
                if let level = notice.level {
                    Capsule().fill(.white.opacity(0.12)).frame(width: 34, height: 6)
                        .overlay(alignment: .leading) {
                            Capsule().fill(Self.color(notice.tint)).frame(width: max(4, 34 * min(max(level, 0), 1)), height: 6)
                        }
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.horizontal, 14)
        .frame(width: DeviceNoticePanel.size.width, height: DeviceNoticePanel.size.height)
        .islandSurface(in: Capsule(style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .combine)
    }

    static func color(_ tint: DeviceNotices.Notice.Tint) -> Color {
        switch tint {
        case .accent: Theme.accent
        case .good: OrbitGlass.goal
        case .warning: OrbitGlass.warning
        case .critical: OrbitGlass.critical
        case .neutral: Theme.secondary
        }
    }
}

/// The notice's window, in the compact island's slot; on screen only while a notice shows. Never takes a click.
final class DeviceNoticePanel: NSPanel {
    static let size = CGSize(width: 260, height: 42)
    let notices: DeviceNotices
    private var generation = 0

    init(notices: DeviceNotices) {
        self.notices = notices
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        contentView = NSHostingView(rootView: DeviceNoticeView(notices: notices))
        reposition()
        follow()
    }

    override var canBecomeKey: Bool { false }

    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let trigger = NotchGeometry.triggerRect(screen: screen.frame, visible: screen.visibleFrame,
                                                left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        setFrame(MusicIslandGeometry.rect(Self.size, trigger: trigger, screen: screen.frame), display: false)
    }

    private func follow() {
        generation += 1
        let registered = generation
        let showing = withObservationTracking { notices.current != nil } onChange: { [weak self] in
            Task { @MainActor in if self?.generation == registered { self?.follow() } }
        }
        if showing { orderFrontRegardless() } else { orderOut(nil) }
    }
}
