import IOKit.ps

/// The internal battery, read from IOKit power sources (no permission needed).
struct BatteryStatus: Equatable {
    var percent: Int
    var isCharging: Bool
    var isPluggedIn: Bool

    /// Parses one power-source description; nil for anything but the internal
    /// battery (e.g. a UPS) or when capacity is missing.
    init?(description d: [String: Any]) {
        guard d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
              let current = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { return nil }
        percent = Int((Double(current) / Double(max) * 100).rounded())
        isCharging = d[kIOPSIsChargingKey] as? Bool ?? false
        isPluggedIn = d[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
    }

    init(percent: Int, isCharging: Bool, isPluggedIn: Bool) {
        self.percent = percent
        self.isCharging = isCharging
        self.isPluggedIn = isPluggedIn
    }

    static func current() -> BatteryStatus? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return nil }
        for source in sources {
            if let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
               let status = BatteryStatus(description: d) {
                return status
            }
        }
        return nil
    }
}
