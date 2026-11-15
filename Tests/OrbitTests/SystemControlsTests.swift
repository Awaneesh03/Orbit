import Foundation
import IOKit.pwr_mgt
import Testing
@testable import Orbit

// Milestone 2: the System tab's pure logic. Hardware readers are covered by
// one plausibility test each; everything that decides what the user sees is
// tested with fixtures.

@Test func signalBarsFollowTheMenuBarSteps() {
    #expect(WiFiSignal.bars(rssi: -45) == 4)
    #expect(WiFiSignal.bars(rssi: -55) == 4)
    #expect(WiFiSignal.bars(rssi: -60) == 3)
    #expect(WiFiSignal.bars(rssi: -72) == 2)
    #expect(WiFiSignal.bars(rssi: -80) == 1)
    #expect(WiFiSignal.bars(rssi: -92) == 0)
    #expect(WiFiSignal.bars(rssi: 0) == 0)  // no reading is never "excellent"
    #expect(WiFiSignal.quality(rssi: -60) == "Good")
    #expect(WiFiSignal.snr(rssi: -50, noise: -90) == 40)
    #expect(WiFiSignal.snr(rssi: -50, noise: 0) == nil)
}

@Test func scanResultsMergeByNameAndSortCurrentKnownThenSignal() {
    let raw = [
        WiFiNetwork(ssid: "Cafe", rssi: -70, security: .open),
        WiFiNetwork(ssid: "Home", rssi: -80, security: .wpa3),
        WiFiNetwork(ssid: "Home", rssi: -50, security: .wpa3, band: "5 GHz"),  // mesh: strongest wins
        WiFiNetwork(ssid: "Neighbour", rssi: -40, security: .wpa2),
        WiFiNetwork(ssid: "Office", rssi: -75, security: .enterprise),
        WiFiNetwork(ssid: "", rssi: -30, security: .wpa2),  // hidden network: dropped
    ]
    let merged = WiFiNetwork.merged(raw, known: ["Home", "Office"], current: "Office")
    #expect(merged.map(\.ssid) == ["Office", "Home", "Neighbour", "Cafe"])
    #expect(merged[0].isCurrent && merged[0].isKnown)
    #expect(merged[1].rssi == -50 && merged[1].band == "5 GHz" && merged[1].isKnown && !merged[1].isCurrent)
    #expect(!merged[2].isKnown)
}

@Test func securityTypesSayWhetherAPasswordIsNeeded() {
    #expect(!WiFiSecurity.open.isSecured)
    #expect(!WiFiSecurity.enhancedOpen.isSecured)
    #expect(WiFiSecurity.wpa3.isSecured && WiFiSecurity.enterprise.isSecured && WiFiSecurity.unknown.isSecured)
}

@Test func diagnosticsNameTheFirstProblem() {
    let wifi = WiFiStatus(interfaceName: "en0", isPoweredOn: true, ssid: "Home", isAssociated: true,
                          rssi: -50, noise: -90, transmitRate: 600, channel: 36, band: "5 GHz", security: .wpa3)
    let good = IPDetails(interface: "en0", ipv4: ["192.168.1.5"], router: "192.168.1.1", dns: ["1.1.1.1"])
    let healthy = NetworkDiagnostics.steps(wifi: wifi, ip: good, online: true, lookupMilliseconds: 20)
    #expect(healthy.allSatisfy { $0.result == .pass })
    #expect(healthy.map(\.id) == ["radio", "signal", "address", "router", "dns", "lookup", "internet"])

    let noDNS = NetworkDiagnostics.steps(wifi: wifi, ip: IPDetails(interface: "en0", ipv4: ["10.0.0.2"], router: "10.0.0.1"),
                                         online: false, lookupMilliseconds: nil)
    #expect(noDNS.first { $0.result == .fail }?.id == "dns")

    let slow = NetworkDiagnostics.steps(wifi: nil, ip: good, online: true, lookupMilliseconds: 900)
    #expect(slow.first { $0.id == "lookup" }?.result == .warn)
    #expect(!slow.contains { $0.id == "radio" })  // wired Mac: no Wi-Fi steps

    var off = wifi
    off.isPoweredOn = false
    let radioOff = NetworkDiagnostics.steps(wifi: off, ip: IPDetails(), online: false, lookupMilliseconds: nil)
    #expect(radioOff.first?.id == "radio" && radioOff.first?.result == .fail)
    #expect(!radioOff.contains { $0.id == "signal" })
}

@Test func ipDetailsReadTheRealRoutingTable() {
    // Plausibility only: values depend on the Mac's network.
    let details = NetworkInspector.ipDetails()
    if let name = details.interface {
        #expect(!name.isEmpty)
        #expect(details.ipv4.allSatisfy { $0.split(separator: ".").count == 4 })
    }
    #expect(NetworkInspector.interfaceAddresses("lo0").ipv4.contains("127.0.0.1"))
}

@Test func bluetoothKindsComeFromTheClassOfDevice() {
    #expect(BluetoothDevice.kind(major: 0x04, minor: 0x01) == .headphones)
    #expect(BluetoothDevice.kind(major: 0x04, minor: 0x05) == .speaker)
    #expect(BluetoothDevice.kind(major: 0x05, minor: 0x10) == .keyboard)
    #expect(BluetoothDevice.kind(major: 0x05, minor: 0x20) == .mouse)
    #expect(BluetoothDevice.kind(major: 0x05, minor: 0x02) == .gamepad)
    #expect(BluetoothDevice.kind(major: 0x02, minor: 0x00) == .phone)
    #expect(BluetoothDevice.kind(major: 0x1F, minor: 0x00) == .other)
    let sorted = BluetoothDevice.sorted([
        BluetoothDevice(id: "a", name: "Zeta", kind: .other, isConnected: false, batteryPercent: nil),
        BluetoothDevice(id: "b", name: "alpha", kind: .other, isConnected: false, batteryPercent: nil),
        BluetoothDevice(id: "c", name: "Mouse", kind: .mouse, isConnected: true, batteryPercent: 80),
    ])
    #expect(sorted.map(\.id) == ["c", "b", "a"])
}

@Test func batteryHealthIsNominalOverDesignAndNeverInvented() {
    #expect(BatteryHealth.capacity(nominal: 4193, design: 4629).map { Int(($0 * 100).rounded()) } == 91)
    #expect(BatteryHealth.capacity(nominal: 5000, design: 4629) == 1)  // a new cell over design reads 100%
    #expect(BatteryHealth.capacity(nominal: nil, design: 4629) == nil)
    #expect(BatteryHealth.capacity(nominal: 4000, design: 0) == nil)
    #expect(BatteryHealth.minutes(65535) == nil)  // "calculating"
    #expect(BatteryHealth.minutes(-1) == nil)
    #expect(BatteryHealth.minutes(95) == 95)
}

@MainActor @Test func keepAwakeHoldsOneAssertionAndReleasesIt() async throws {
    var created = 0
    var released: [IOPMAssertionID] = []
    let model = KeepAwakeModel(create: { created += 1; return IOPMAssertionID(created) }, release: { released.append($0) })
    let now = Date(timeIntervalSince1970: 1_000)
    model.start(.oneHour, now: now)
    #expect(model.isActive && model.until == now.addingTimeInterval(3600))
    model.start(.indefinitely)  // replacing: the old assertion is released first
    #expect(released == [1] && model.isActive && model.until == nil)
    model.stop()
    #expect(released == [1, 2] && !model.isActive)
    model.stop()  // idempotent
    #expect(released == [1, 2])
}

@MainActor @Test func keepAwakeEndsByItself() async throws {
    var released = 0
    let model = KeepAwakeModel(create: { 7 }, release: { _ in released += 1 })
    // A start "15 minutes ago" ends almost at once.
    model.start(.fifteenMinutes, now: Date().addingTimeInterval(-15 * 60 + 0.05))
    // Poll (the full suite keeps the main actor busy, so a fixed wait flakes).
    for _ in 0 ..< 100 where model.isActive { try await Task.sleep(for: .milliseconds(50)) }
    #expect(!model.isActive && released == 1)
}

@MainActor @Test func keepAwakeStaysOffWhenMacOSRefuses() {
    let model = KeepAwakeModel(create: { nil }, release: { _ in Issue.record("nothing to release") })
    model.start(.oneHour)
    #expect(!model.isActive)
    model.stop()
}

@MainActor @Test func networkCardNamesTheWiFiLinkWhenItCan() {
    let wifi = WiFiStatus(interfaceName: "en0", isPoweredOn: true, ssid: nil, isAssociated: true,
                          rssi: -60, noise: -92, transmitRate: 400, channel: 6, band: "2.4 GHz", security: .wpa2)
    let online = NetworkSummary(isOnline: true, link: .wifi, isExpensive: false, isLowData: false)
    #expect(NetworkWidget.detail(online, wifi: nil) == "Wi-Fi")
    #expect(NetworkWidget.detail(online, wifi: wifi) == "Wi-Fi · Good · 2.4 GHz")
    var dropped = wifi
    dropped.isAssociated = false
    #expect(NetworkWidget.detail(online, wifi: dropped) == "Wi-Fi")
    let offline = NetworkSummary(isOnline: false, link: nil, isExpensive: false, isLowData: false)
    #expect(NetworkWidget.detail(offline, wifi: wifi) == "No connection")
}
