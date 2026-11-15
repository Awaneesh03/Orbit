import AppKit
import CoreWLAN
import Darwin
import Foundation
import Network
import SystemConfiguration

// Wi-Fi and IP details from public frameworks only: CoreWLAN for the radio,
// SystemConfiguration for router and DNS, getifaddrs for addresses. macOS
// hides network names (SSIDs) from apps without Location access; Orbit shows
// that as a state to grant, never guesses a name, and never reads passwords.

enum WiFiSecurity: String, Sendable, Equatable {
    case open = "Open", enhancedOpen = "Enhanced Open", wep = "WEP", wpa = "WPA",
         wpa2 = "WPA2", wpa3 = "WPA3", wpa2wpa3 = "WPA2/WPA3", enterprise = "Enterprise", unknown = "Secured"

    var isSecured: Bool { self != .open && self != .enhancedOpen }
}

/// Signal quality from RSSI (dBm), as the menu bar does: four steps.
enum WiFiSignal {
    static func bars(rssi: Int) -> Int {
        switch rssi {
        case 0: 0  // no reading
        case (-55)...: 4
        case (-67)...: 3
        case (-75)...: 2
        case (-85)...: 1
        default: 0
        }
    }

    static func quality(rssi: Int) -> String {
        ["No signal", "Weak", "Fair", "Good", "Excellent"][bars(rssi: rssi)]
    }

    /// Signal-to-noise ratio in dB, when both readings exist.
    static func snr(rssi: Int, noise: Int) -> Int? {
        rssi != 0 && noise != 0 ? rssi - noise : nil
    }
}

/// The Wi-Fi interface right now.
struct WiFiStatus: Equatable, Sendable {
    var interfaceName: String
    var isPoweredOn: Bool
    /// nil: not associated, or the name is hidden (no Location access).
    var ssid: String?
    var isAssociated: Bool
    var rssi: Int
    var noise: Int
    var transmitRate: Double
    var channel: Int?
    var band: String?
    var security: WiFiSecurity?
}

/// One network from a scan, merged by name (a mesh shows once, strongest wins).
struct WiFiNetwork: Identifiable, Equatable, Sendable {
    var ssid: String
    var rssi: Int
    var security: WiFiSecurity
    var band: String?
    var isKnown = false
    var isCurrent = false

    var id: String { ssid }
}

/// Addresses, router and DNS of the primary interface.
struct IPDetails: Equatable, Sendable {
    var interface: String?
    var ipv4: [String] = []
    var ipv6: [String] = []
    var router: String?
    var dns: [String] = []
}

extension WiFiNetwork {
    /// One entry per name, strongest signal kept; the current network first,
    /// then known networks, then by signal. Hidden (nameless) results dropped.
    static func merged(_ networks: [WiFiNetwork], known: Set<String>, current: String?) -> [WiFiNetwork] {
        var best: [String: WiFiNetwork] = [:]
        for network in networks where !network.ssid.isEmpty {
            if let existing = best[network.ssid], existing.rssi >= network.rssi { continue }
            best[network.ssid] = network
        }
        return best.values.map { network in
            var network = network
            network.isKnown = known.contains(network.ssid)
            network.isCurrent = network.ssid == current
            return network
        }.sorted {
            if $0.isCurrent != $1.isCurrent { return $0.isCurrent }
            if $0.isKnown != $1.isKnown { return $0.isKnown }
            if $0.rssi != $1.rssi { return $0.rssi > $1.rssi }
            return $0.ssid.localizedStandardCompare($1.ssid) == .orderedAscending
        }
    }
}

/// The readers. Each is synchronous; `scan` blocks for a few seconds, so
/// callers run it off the main actor.
enum NetworkInspector {
    static func wifiStatus() -> WiFiStatus? {
        guard let interface = CWWiFiClient.shared().interface() else { return nil }
        let channel = interface.wlanChannel()
        let associated = channel != nil && interface.rssiValue() != 0
        return WiFiStatus(
            interfaceName: interface.interfaceName ?? "Wi-Fi",
            isPoweredOn: interface.powerOn(),
            ssid: interface.ssid(),
            isAssociated: associated,
            rssi: interface.rssiValue(),
            noise: interface.noiseMeasurement(),
            transmitRate: interface.transmitRate(),
            channel: channel.map { $0.channelNumber },
            band: channel.flatMap { band($0.channelBand) },
            security: associated ? security(of: interface.security()) : nil)
    }

    /// Names of networks this Mac has joined before, as macOS exposes them
    /// (empty without Location access). Passwords are never read.
    static func knownNetworks() -> Set<String> {
        guard let profiles = CWWiFiClient.shared().interface()?.configuration()?.networkProfiles else { return [] }
        return Set(profiles.compactMap { ($0 as? CWNetworkProfile)?.ssid })
    }

    static func scan() throws -> [WiFiNetwork] {
        guard let interface = CWWiFiClient.shared().interface() else { return [] }
        return try interface.scanForNetworks(withSSID: nil).compactMap { network in
            guard let ssid = network.ssid else { return nil }
            return WiFiNetwork(ssid: ssid, rssi: network.rssiValue, security: security(of: network),
                               band: network.wlanChannel.flatMap { band($0.channelBand) })
        }
    }

    /// Turns the Wi-Fi radio on or off (the same public call the menu uses).
    static func setPower(_ on: Bool) throws {
        try CWWiFiClient.shared().interface()?.setPower(on)
    }

    /// Joins a network macOS already knows, using the password macOS keeps
    /// (Orbit never sees it). Throws if macOS needs the user: callers then
    /// open Wi-Fi Settings, the native flow.
    static func joinKnown(_ ssid: String) throws {
        guard let interface = CWWiFiClient.shared().interface() else { throw CocoaError(.featureUnsupported) }
        let matches = try interface.scanForNetworks(withSSID: Data(ssid.utf8))
        guard let network = matches.max(by: { $0.rssiValue < $1.rssiValue }) else { throw CocoaError(.fileNoSuchFile) }
        try interface.associate(to: network, password: nil)
    }

    static func ipDetails() -> IPDetails {
        var details = IPDetails()
        if let store = SCDynamicStoreCreate(nil, "Orbit" as CFString, nil, nil) {
            if let ipv4 = SCDynamicStoreCopyValue(store, "State:/Network/Global/IPv4" as CFString) as? [String: Any] {
                details.interface = ipv4["PrimaryInterface"] as? String
                details.router = ipv4["Router"] as? String
            }
            if let dns = SCDynamicStoreCopyValue(store, "State:/Network/Global/DNS" as CFString) as? [String: Any] {
                details.dns = dns["ServerAddresses"] as? [String] ?? []
            }
        }
        if let name = details.interface {
            let addresses = interfaceAddresses(name)
            details.ipv4 = addresses.ipv4
            details.ipv6 = addresses.ipv6
        }
        return details
    }

    static func interfaceAddresses(_ name: String) -> (ipv4: [String], ipv6: [String]) {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return ([], []) }
        defer { freeifaddrs(head) }
        var v4: [String] = [], v6: [String] = []
        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let entry = pointer.pointee
            guard String(cString: entry.ifa_name) == name, let address = entry.ifa_addr else { continue }
            let family = Int32(address.pointee.sa_family)
            guard family == AF_INET || family == AF_INET6 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let length = socklen_t(family == AF_INET ? MemoryLayout<sockaddr_in>.size : MemoryLayout<sockaddr_in6>.size)
            guard getnameinfo(address, length, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 else { continue }
            let text = String(decoding: host.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if family == AF_INET { v4.append(text) } else if !text.hasPrefix("fe80") { v6.append(text) }
        }
        return (v4, v6)
    }

    static func band(_ band: CWChannelBand) -> String? {
        switch band {
        case .band2GHz: "2.4 GHz"
        case .band5GHz: "5 GHz"
        case .band6GHz: "6 GHz"
        default: nil
        }
    }

    static func security(of interfaceSecurity: CWSecurity) -> WiFiSecurity {
        switch interfaceSecurity {
        case .none: .open
        case .OWE, .oweTransition: .enhancedOpen
        case .WEP, .dynamicWEP: .wep
        case .wpaPersonal, .wpaPersonalMixed: .wpa
        case .wpa2Personal, .personal: .wpa2
        case .wpa3Personal: .wpa3
        case .wpa3Transition: .wpa2wpa3
        case .wpaEnterprise, .wpaEnterpriseMixed, .wpa2Enterprise, .enterprise, .wpa3Enterprise: .enterprise
        default: .unknown
        }
    }

    /// A scanned network advertises several modes; the strongest one names it.
    static func security(of network: CWNetwork) -> WiFiSecurity {
        let order: [(CWSecurity, WiFiSecurity)] = [
            (.wpa3Enterprise, .enterprise), (.wpa2Enterprise, .enterprise), (.enterprise, .enterprise),
            (.wpa3Transition, .wpa2wpa3), (.wpa3Personal, .wpa3), (.wpa2Personal, .wpa2), (.personal, .wpa2),
            (.wpaPersonal, .wpa), (.dynamicWEP, .wep), (.WEP, .wep), (.OWE, .enhancedOpen), (.none, .open),
        ]
        return order.first { network.supportsSecurity($0.0) }?.1 ?? .unknown
    }
}

// MARK: Diagnostics

/// One step of "Diagnose": what was checked and what was found.
struct DiagnosticStep: Identifiable, Equatable, Sendable {
    enum Result: Equatable, Sendable { case pass, warn, fail }
    let id: String
    let title: String
    let result: Result
    let detail: String
}

enum NetworkDiagnostics {
    /// Checks from the radio outwards. `lookupMilliseconds` nil: the DNS lookup failed.
    static func steps(wifi: WiFiStatus?, ip: IPDetails, online: Bool, lookupMilliseconds: Int?) -> [DiagnosticStep] {
        var steps: [DiagnosticStep] = []
        if let wifi {
            steps.append(DiagnosticStep(id: "radio", title: "Wi-Fi radio", result: wifi.isPoweredOn ? .pass : .fail,
                                        detail: wifi.isPoweredOn ? "On" : "Off"))
            if wifi.isPoweredOn {
                let bars = WiFiSignal.bars(rssi: wifi.rssi)
                steps.append(DiagnosticStep(
                    id: "signal", title: "Signal", result: !wifi.isAssociated ? .fail : bars >= 2 ? .pass : .warn,
                    detail: wifi.isAssociated ? "\(WiFiSignal.quality(rssi: wifi.rssi)) (\(wifi.rssi) dBm)" : "Not connected to a network"))
            }
        }
        steps.append(DiagnosticStep(id: "address", title: "IP address", result: ip.ipv4.isEmpty && ip.ipv6.isEmpty ? .fail : .pass,
                                    detail: ip.ipv4.first ?? ip.ipv6.first ?? "None assigned"))
        steps.append(DiagnosticStep(id: "router", title: "Router", result: ip.router == nil ? .fail : .pass,
                                    detail: ip.router ?? "No router"))
        steps.append(DiagnosticStep(id: "dns", title: "DNS servers", result: ip.dns.isEmpty ? .fail : .pass,
                                    detail: ip.dns.isEmpty ? "None configured" : ip.dns.prefix(2).joined(separator: ", ")))
        let lookup: DiagnosticStep.Result = switch lookupMilliseconds {
        case nil: .fail
        case let ms? where ms > 300: .warn
        default: .pass
        }
        steps.append(DiagnosticStep(id: "lookup", title: "Name lookup", result: lookup,
                                    detail: lookupMilliseconds.map { "\($0) ms" } ?? "Failed"))
        steps.append(DiagnosticStep(id: "internet", title: "Internet", result: online ? .pass : .fail,
                                    detail: online ? "Reachable" : "No route"))
        return steps
    }

    /// Times one lookup through the system resolver (the user's own DNS;
    /// nothing else is contacted). Blocking: call off the main actor.
    static func timeLookup(host: String = "apple.com") -> Int? {
        let start = ContinuousClock.now
        var result: UnsafeMutablePointer<addrinfo>?
        var hints = addrinfo()
        hints.ai_socktype = SOCK_STREAM
        guard getaddrinfo(host, nil, &hints, &result) == 0 else { return nil }
        freeaddrinfo(result)
        let elapsed = ContinuousClock.now - start
        return Int(elapsed.components.seconds * 1000 + elapsed.components.attoseconds / 1_000_000_000_000_000)
    }
}

// MARK: Model

/// The Wi-Fi pane's state. Live only while shown: CoreWLAN events and a path
/// monitor push changes; a scan runs on open and on Refresh, never on a timer.
@MainActor @Observable
final class WiFiModel: NSObject, CWEventDelegate {
    private(set) var status: WiFiStatus?
    private(set) var ip = IPDetails()
    private(set) var networks: [WiFiNetwork] = []
    private(set) var isOnline = false
    private(set) var isScanning = false
    private(set) var scanError: String?
    private(set) var joining: String?
    private(set) var diagnostics: [DiagnosticStep]?
    private(set) var isDiagnosing = false
    private(set) var locationAccess: LocationAccess
    private(set) var lastScan: Date?
    /// View state for the pane (no @State on this toolchain).
    var showingDiagnostics = false
    var hovered: String?
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private let location: CoreLocationProvider
    @ObservationIgnored private var isMonitoring = false

    init(location: CoreLocationProvider = CoreLocationProvider()) {
        self.location = location
        locationAccess = location.access()
    }

    /// macOS shows network names only to apps with Location access.
    var namesHidden: Bool { locationAccess != .authorized }

    func start() {
        guard !isMonitoring else { return }
        isMonitoring = true
        let client = CWWiFiClient.shared()
        client.delegate = self
        for event: CWEventType in [.ssidDidChange, .linkDidChange, .powerDidChange, .linkQualityDidChange] {
            try? client.startMonitoringEvent(with: event)
        }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            MainActor.assumeIsolated {
                self?.isOnline = online
                self?.readState()
            }
        }
        monitor.start(queue: .main)
        pathMonitor = monitor
        readState()
        scan()
    }

    func stop() {
        guard isMonitoring else { return }
        isMonitoring = false
        try? CWWiFiClient.shared().stopMonitoringAllEvents()
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    func readState() {
        locationAccess = location.access()
        status = NetworkInspector.wifiStatus()
        ip = NetworkInspector.ipDetails()
    }

    func scan() {
        guard !isScanning else { return }
        isScanning = true
        scanError = nil
        Task {
            let result = await Task.detached(priority: .utility) { () -> Result<([WiFiNetwork], Set<String>), any Error> in
                Result { (try NetworkInspector.scan(), NetworkInspector.knownNetworks()) }
            }.value
            isScanning = false
            lastScan = .now
            switch result {
            case .success(let (found, known)):
                networks = WiFiNetwork.merged(found, known: known, current: status?.ssid)
            case .failure:
                scanError = status?.isPoweredOn == false ? "Wi-Fi is off" : "Scan failed. Try again in a moment."
            }
            readState()
        }
    }

    func setPower(_ on: Bool) {
        try? NetworkInspector.setPower(on)
        readState()
        if on { scan() } else { networks = [] }
    }

    /// Known networks join with the password macOS keeps; anything else goes
    /// to Wi-Fi Settings, where macOS asks for the password itself.
    func join(_ network: WiFiNetwork) {
        guard network.isKnown || !network.security.isSecured else { return openSettings() }
        joining = network.ssid
        Task {
            let ssid = network.ssid
            let ok = await Task.detached(priority: .userInitiated) { (try? NetworkInspector.joinKnown(ssid)) != nil }.value
            joining = nil
            if !ok { openSettings() }
            readState()
            networks = WiFiNetwork.merged(networks, known: Set(networks.filter(\.isKnown).map(\.ssid)), current: status?.ssid)
        }
    }

    func requestLocation() {
        Task {
            if location.access() == .notDetermined {
                await location.requestAccess()
            } else {
                NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocationServices")!)
            }
            readState()
            scan()
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.wifi-settings-extension")!)
    }

    func diagnose() {
        guard !isDiagnosing else { return }
        isDiagnosing = true
        readState()
        Task {
            let ms = await Task.detached(priority: .userInitiated) { NetworkDiagnostics.timeLookup() }.value
            diagnostics = NetworkDiagnostics.steps(wifi: status, ip: ip, online: isOnline, lookupMilliseconds: ms)
            isDiagnosing = false
        }
    }

    // CoreWLAN delivers events on its own queue.
    nonisolated func ssidDidChangeForWiFiInterface(withName interfaceName: String) { refreshSoon() }
    nonisolated func linkDidChangeForWiFiInterface(withName interfaceName: String) { refreshSoon() }
    nonisolated func powerStateDidChangeForWiFiInterface(withName interfaceName: String) { refreshSoon() }
    nonisolated func linkQualityDidChangeForWiFiInterface(withName interfaceName: String, rssi: Int, transmitRate: Double) {
        refreshSoon()
    }

    private nonisolated func refreshSoon() {
        Task { @MainActor [weak self] in self?.readState() }
    }
}
