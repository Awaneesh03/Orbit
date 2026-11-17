import AppKit
import IOKit.ps
import Observation

// Live activities (Milestone 21), all shown with the 3-second notch notice:
// - Power: the charger connected or removed, fully charged, low battery at
//   20 % and 10 %. Event-driven (IOKit's power-source notification): no polling.
// - Quick timer: "timer 10m" in the launcher. One sleeping task, nothing ticks
//   while the dashboard is closed; its time left shows in the dashboard header.
// - Colour picker: macOS's own colour loupe (NSColorSampler, no permission);
//   the hex goes on the clipboard.

enum PowerNotices {
    /// The note for a change of power state, or nil (the first reading is the baseline: nothing at launch).
    static func notice(from old: BatteryStatus?, to new: BatteryStatus) -> DeviceNotices.Notice? {
        guard let old else { return nil }
        let level = Double(new.percent) / 100
        switch (old.chargeState, new.chargeState) {
        case (let before, .charging) where before != .charging:
            return .init(id: "power", state: "charging", title: "Charging", detail: "\(new.percent)%",
                         symbol: "battery.100percent.bolt", tint: .good, level: level)
        case (.charging, .charged):
            return .init(id: "power", state: "full", title: "Fully charged", detail: "\(new.percent)% · you can unplug",
                         symbol: "battery.100percent", tint: .good, level: 1)
        case (.onBattery, .pluggedInNotCharging):
            return .init(id: "power", state: "plugged", title: "Plugged in", detail: "\(new.percent)% · not charging",
                         symbol: "powerplug", tint: .neutral, level: level)
        case (let before, .onBattery) where before != .onBattery:
            return .init(id: "power", state: "battery", title: "On battery", detail: "\(new.percent)%",
                         symbol: symbol(new.percent), tint: new.percent <= 20 ? .warning : .neutral, level: level)
        case (.onBattery, .onBattery):
            for threshold in [10, 20] where old.percent > threshold && new.percent <= threshold {
                return .init(id: "power", state: "low\(threshold)", title: "Low battery", detail: "\(new.percent)% left",
                             symbol: "battery.25percent", tint: threshold == 10 ? .critical : .warning, level: level)
            }
            return nil
        default:
            return nil
        }
    }

    static func symbol(_ percent: Int) -> String {
        switch percent {
        case ..<13: "battery.0percent"
        case ..<38: "battery.25percent"
        case ..<63: "battery.50percent"
        case ..<88: "battery.75percent"
        default: "battery.100percent"
        }
    }
}

/// IOKit's power-source change notification, for the notices. Only on Macs with a battery.
@MainActor
final class PowerWatcher {
    private var source: CFRunLoopSource?
    private var last: BatteryStatus?
    private let read: () -> BatteryStatus?
    var onNotice: (DeviceNotices.Notice) -> Void = { _ in }
    /// Every reading, for the dashboard header's battery (event-driven, so it's current without polling).
    var onReading: (BatteryStatus) -> Void = { _ in }

    init(read: @escaping () -> BatteryStatus? = BatteryStatus.current) { self.read = read }

    var isRunning: Bool { source != nil }

    func start() {
        guard source == nil else { return }
        last = read()
        guard let first = last else { return }  // no battery: nothing to say
        onReading(first)
        // ponytail: unretained self; the watcher lives as long as the app and stop() removes the source.
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let created = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            MainActor.assumeIsolated { Unmanaged<PowerWatcher>.fromOpaque(context).takeUnretainedValue().changed() }
        }, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), created, .commonModes)
        source = created
    }

    func stop() {
        guard let source else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFRunLoopSourceInvalidate(source)
        self.source = nil
        last = nil
    }

    /// A new reading (the notification, or a test).
    func changed() {
        guard let reading = read() else { return }
        defer { last = reading }
        onReading(reading)
        if let notice = PowerNotices.notice(from: last, to: reading) { onNotice(notice) }
    }

    /// Tests: take a first reading without the IOKit source.
    func prime() { last = read() }
}

/// One countdown at a time, started from the launcher ("timer 10m").
@MainActor @Observable
final class QuickTimer {
    private(set) var endsAt: Date?
    private(set) var length: TimeInterval = 0
    private(set) var label = ""
    @ObservationIgnored var onFinish: (String) -> Void = { _ in }
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private let clock: () -> Date

    init(clock: @escaping () -> Date = { .now }) { self.clock = clock }

    var isRunning: Bool { endsAt != nil }
    func remaining(at date: Date) -> TimeInterval { max(0, (endsAt ?? date).timeIntervalSince(date)) }

    func start(_ seconds: TimeInterval, label: String = "") {
        task?.cancel()
        let length = min(max(seconds, 1), 24 * 3600)
        self.length = length
        self.label = label
        endsAt = clock().addingTimeInterval(length)
        task = Task { [weak self] in
            try? await Task.sleep(for: .seconds(length))
            guard !Task.isCancelled else { return }
            self?.finish()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
        endsAt = nil
    }

    /// The countdown reached zero (the sleeping task, or a test).
    func finish() {
        guard endsAt != nil else { return }
        task = nil
        endsAt = nil
        onFinish(label.isEmpty ? "Timer done" : label)
    }

    /// "timer 10m", "timer 1h30m", "timer 90s", "timer 25" (minutes), "10 min timer", "timer 5m tea".
    nonisolated static func parse(_ query: String) -> (seconds: TimeInterval, label: String)? {
        var original = query.split(whereSeparator: \.isWhitespace).map(String.init)  // the label keeps its case
        var words = original.map { $0.lowercased() }
        if words.first == "timer" {
            words.removeFirst(); original.removeFirst()
        } else if words.last == "timer" {
            words.removeLast(); original.removeLast()
        } else {
            return nil
        }
        var total: TimeInterval = 0
        var used = 0
        while used < words.count {
            let word = words[used]
            if let seconds = duration(word) {
                total += seconds
                used += 1
            } else if let number = Double(word), used + 1 < words.count, let unit = unitSeconds(words[used + 1]) {
                total += number * unit
                used += 2
            } else if let number = Double(word), used == 0 {
                total += number * 60  // a bare number is minutes
                used += 1
            } else {
                break
            }
        }
        guard used > 0, total > 0, total <= 24 * 3600 else { return nil }
        let label = original.dropFirst(used).joined(separator: " ")
        return (total, label.prefix(1).uppercased() + label.dropFirst())
    }

    /// "1h30m", "10m", "90s": a number glued to units, possibly several.
    private nonisolated static func duration(_ word: String) -> TimeInterval? {
        var total: TimeInterval = 0
        var number = ""
        var unit = ""
        func flush() -> Bool {
            guard !number.isEmpty || !unit.isEmpty else { return true }
            guard let value = Double(number), let seconds = unitSeconds(unit) else { return false }
            total += value * seconds
            number = ""
            unit = ""
            return true
        }
        for character in word {
            if character.isNumber || character == "." {
                if !unit.isEmpty, !flush() { return nil }
                number.append(character)
            } else if character.isLetter {
                guard !number.isEmpty || !unit.isEmpty else { return nil }
                unit.append(character)
            } else {
                return nil
            }
        }
        guard !unit.isEmpty, flush(), total > 0 else { return nil }
        return total
    }

    private nonisolated static func unitSeconds(_ unit: String) -> TimeInterval? {
        switch unit {
        case "s", "sec", "secs", "second", "seconds": 1
        case "m", "min", "mins", "minute", "minutes": 60
        case "h", "hr", "hrs", "hour", "hours": 3600
        default: nil
        }
    }

    /// "4:05", "1:02:07".
    nonisolated static func format(_ seconds: TimeInterval) -> String { PlaybackTime.format(seconds.rounded(.up)) }
}

/// macOS's colour loupe: the user picks any pixel on screen (no Screen Recording: the system samples it).
@MainActor
enum ColorPick {
    nonisolated static func hex(red: Double, green: Double, blue: Double) -> String {
        func byte(_ value: Double) -> Int { Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(red), byte(green), byte(blue))
    }

    /// Shows the loupe; calls back with the colour's sRGB components, or not at all if cancelled.
    static func pick(_ picked: @escaping @MainActor ([Double]) -> Void) {
        NSColorSampler().show { color in
            guard let srgb = color?.usingColorSpace(.sRGB) else { return }
            let components = [Double(srgb.redComponent), Double(srgb.greenComponent), Double(srgb.blueComponent)]
            Task { @MainActor in picked(components) }
        }
    }
}
