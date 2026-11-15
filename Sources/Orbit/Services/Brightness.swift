import AppKit
import IOKit
import Observation
import os

// Built-in display brightness (Milestone 9), public APIs only.
//
// - Control: **not possible**. `IODisplayGet/SetFloatParameter` return
//   kIOReturnUnsupported on Apple Silicon (measured on this M4, 2026-11-14);
//   the working setters (DisplayServices, CoreDisplay) are private. Orbit
//   never changes brightness.
// - Observation: the backlight driver (`AppleARMBacklight`) publishes its
//   state in the I/O Registry, `IODisplayParameters.brightness {value, max}`,
//   read with the public `IORegistryEntryCreateCFProperty` (16 µs a read).
// - Noticing a change, three sources, each counted so the first live run
//   shows which ones macOS delivers: IOKit interest notifications on the
//   backlight; a global monitor for the brightness keys' system-defined
//   events (no permission is requested: macOS either delivers them or not);
//   and a 4 Hz registry read as the safety net, only while the HUD is on.

/// Reads the built-in backlight level (0…1) from the I/O Registry.
enum BrightnessReader {
    static func service() -> io_service_t {
        IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleARMBacklight"))
    }

    /// nil when there's no built-in backlight (a desktop Mac, the lid closed on some models).
    static func level(_ service: io_service_t) -> Double? {
        guard service != 0,
              let parameters = IORegistryEntryCreateCFProperty(service, "IODisplayParameters" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any]
        else { return nil }
        return level(from: parameters)
    }

    /// `brightness.value / brightness.max` from the driver's parameters, clamped.
    static func level(from parameters: [String: Any]) -> Double? {
        guard let brightness = parameters["brightness"] as? [String: Any],
              let value = (brightness["value"] as? NSNumber)?.doubleValue,
              let max = (brightness["max"] as? NSNumber)?.doubleValue else { return nil }
        let min = (brightness["min"] as? NSNumber)?.doubleValue ?? 0
        guard max > min else { return nil }
        return Swift.min(Swift.max((value - min) / (max - min), 0), 1)
    }

    /// NX_KEYTYPE_BRIGHTNESS_UP (2) / _DOWN (3), key down, in a system-defined
    /// aux-button event (subtype 8).
    static func isBrightnessKey(subtype: Int, data1: Int) -> Bool {
        guard subtype == 8 else { return false }
        let key = (data1 & 0xFFFF_0000) >> 16
        let isDown = ((data1 & 0xFF00) >> 8) == 0x0A
        return isDown && (key == 2 || key == 3)
    }
}

/// The current level and key presses, for the brightness HUD.
@MainActor @Observable
final class BrightnessMonitor {
    enum Source: String, Sendable { case interest, key, poll }

    /// 0…1; nil: no built-in backlight.
    private(set) var level: Double?
    /// Brightness key presses seen (a press at 0 % or 100 % changes no level, yet should show the HUD).
    private(set) var presses = 0
    /// How each change was first noticed (diagnostics for the live check).
    private(set) var noticed: [Source: Int] = [:]
    private(set) var isRunning = false

    @ObservationIgnored private let read: @MainActor () -> Double?
    @ObservationIgnored private let pollInterval: Duration
    @ObservationIgnored private let watchesSystem: Bool
    @ObservationIgnored private var poll: Task<Void, Never>?
    @ObservationIgnored private var keyMonitor: Any?
    @ObservationIgnored private var port: IONotificationPortRef?
    @ObservationIgnored private var interest: io_object_t = 0
    @ObservationIgnored private let service: io_service_t

    /// `watchesSystem: false` (tests): only the injected reader, driven by the poll.
    init(read: (@MainActor () -> Double?)? = nil, pollInterval: Duration = .milliseconds(250), watchesSystem: Bool = true) {
        let service = watchesSystem ? BrightnessReader.service() : 0
        self.service = service
        self.read = read ?? { BrightnessReader.level(service) }
        self.pollInterval = pollInterval
        self.watchesSystem = watchesSystem
    }

    /// Who wants readings (the HUD, the Brightness widget): it runs while anyone does (Milestone 16: one monitor, shared).
    @ObservationIgnored private var clients: Set<String> = []

    func start(client: String = "hud") {
        clients.insert(client)
        guard !isRunning else { return }
        isRunning = true
        level = read()
        if watchesSystem { watchSystem() }
        poll = Task { [weak self, pollInterval] in
            while !Task.isCancelled {
                try? await Task.sleep(for: pollInterval, tolerance: .milliseconds(100))
                self?.refresh(.poll)
            }
        }
    }

    func stop(client: String = "hud") {
        clients.remove(client)
        guard isRunning, clients.isEmpty else { return }
        isRunning = false
        poll?.cancel()
        poll = nil
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if interest != 0 { IOObjectRelease(interest) }
        interest = 0
        if let port { IONotificationPortDestroy(port) }
        port = nil
    }

    /// Reads the level now; counts the source if it changed.
    func refresh(_ source: Source) {
        guard isRunning else { return }
        let now = read()
        guard now != level else { return }
        level = now
        noticed[source, default: 0] += 1
        Self.log.notice("brightness \(now.map { String(format: "%.3f", $0) } ?? "none", privacy: .public) noticed by \(source.rawValue, privacy: .public)")
    }

    private static let log = Logger(subsystem: "com.awaneeshgupta.orbit", category: "brightness")

    #if DEBUG
    /// A simulated reading for the HUD (debug command `brightness:<0…1>`); the real brightness is never changed.
    func debugSimulate(_ value: Double) {
        guard isRunning else { return }
        level = min(max(value, 0), 1)
    }
    #endif

    /// A brightness key went down: re-read at once and while the system
    /// eases to the new level.
    func keyPressed() {
        guard isRunning else { return }
        presses += 1
        Self.log.notice("brightness key pressed (\(self.presses, privacy: .public))")
        refresh(.key)
        for delay in [80, 200, 400] {
            Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(delay))
                self?.refresh(.key)
            }
        }
    }

    private func watchSystem() {
        keyMonitor = NSEvent.addGlobalMonitorForEvents(matching: .systemDefined) { [weak self] event in
            guard BrightnessReader.isBrightnessKey(subtype: Int(event.subtype.rawValue), data1: event.data1) else { return }
            MainActor.assumeIsolated { self?.keyPressed() }
        }
        guard service != 0, let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        IONotificationPortSetDispatchQueue(port, .main)
        self.port = port
        // Unretained: stop() removes the notification before the monitor can go away.
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOServiceAddInterestNotification(port, service, kIOGeneralInterest, { context, _, _, _ in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<BrightnessMonitor>.fromOpaque(context).takeUnretainedValue().refresh(.interest) }
        }, context, &interest)
    }
}
