import Foundation
import Testing
@testable import Orbit

// Literal IOKit power-source keys, so the tests also pin the constants' values.
private func source(type: String = "InternalBattery", current: Int? = 87, max: Int? = 100,
                    charging: Bool = false, state: String = "Battery Power") -> [String: Any] {
    var d: [String: Any] = ["Type": type, "Is Charging": charging, "Power Source State": state]
    d["Current Capacity"] = current
    d["Max Capacity"] = max
    return d
}

@Test func parsesInternalBatteryOnBatteryPower() {
    #expect(BatteryStatus(description: source()) == BatteryStatus(percent: 87, isCharging: false, isPluggedIn: false))
}

@Test func parsesChargingOnACPower() {
    let status = BatteryStatus(description: source(current: 40, charging: true, state: "AC Power"))
    #expect(status == BatteryStatus(percent: 40, isCharging: true, isPluggedIn: true))
}

@Test func scalesWhenMaxCapacityIsNotOneHundred() {
    #expect(BatteryStatus(description: source(current: 2000, max: 4000))?.percent == 50)
}

@Test func ignoresNonBatterySourcesAndMissingCapacity() {
    #expect(BatteryStatus(description: source(type: "UPS")) == nil)
    #expect(BatteryStatus(description: source(current: nil)) == nil)
    #expect(BatteryStatus(description: source(max: 0)) == nil)
}

@Test func quickActionsOnlyLaunchApps() {
    // Opening a user folder (e.g. ~/Downloads) from Orbit triggered a TCC prompt.
    for action in QuickAction.allCases {
        guard let target = action.target else { continue }  // Orbit's own Settings
        #expect(target.pathExtension == "app", "\(action) must target an app bundle")
    }
    #expect(QuickAction.settings.target == nil, "Settings opens Orbit Settings, not System Settings")
}

@Test func quickActionTargetsExist() {
    for action in QuickAction.allCases {
        guard let target = action.target else { continue }
        #expect(FileManager.default.fileExists(atPath: target.path(percentEncoded: false)),
                "\(action) target missing: \(target.path(percentEncoded: false))")
    }
}
