import CoreAudio
import CoreBluetooth
import Foundation
import IOBluetooth
import IOKit
import IOKit.ps
import IOKit.pwr_mgt
import Observation

// System tab services (Milestone 2): Bluetooth devices, audio devices,
// battery health and Keep Awake. Public frameworks only. Bluetooth needs the
// user's Bluetooth permission, asked only when they click "Show devices";
// nothing else here needs a permission.

// MARK: Bluetooth

struct BluetoothDevice: Identifiable, Equatable, Sendable {
    enum Kind: Sendable { case headphones, speaker, keyboard, mouse, phone, computer, gamepad, other }
    let id: String  // the device address
    let name: String
    let kind: Kind
    let isConnected: Bool
    /// Reported by Apple HID peripherals only; nil otherwise (never guessed).
    let batteryPercent: Int?

    var symbol: String {
        switch kind {
        case .headphones: "headphones"
        case .speaker: "hifispeaker"
        case .keyboard: "keyboard"
        case .mouse: "computermouse"
        case .phone: "iphone"
        case .computer: "laptopcomputer"
        case .gamepad: "gamecontroller"
        case .other: "dot.radiowaves.left.and.right"
        }
    }

    /// From the Bluetooth class of device (major/minor).
    static func kind(major: UInt32, minor: UInt32) -> Kind {
        switch major {
        case 0x01: .computer
        case 0x02: .phone
        case 0x04: minor == 0x05 || minor == 0x06 ? .speaker : .headphones
        case 0x05:
            switch minor & 0x30 {
            case 0x10: .keyboard
            case 0x20: .mouse
            default: minor & 0x0F == 0x02 ? .gamepad : .other
            }
        default: .other
        }
    }

    /// Connected first, then by name.
    static func sorted(_ devices: [BluetoothDevice]) -> [BluetoothDevice] {
        devices.sorted {
            if $0.isConnected != $1.isConnected { return $0.isConnected }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }
    }
}

enum BluetoothAccess: Equatable { case notDetermined, denied, allowed }

@MainActor @Observable
final class BluetoothModel: NSObject, CBCentralManagerDelegate {
    private(set) var devices: [BluetoothDevice] = []
    private(set) var isPoweredOn: Bool?
    private(set) var access = BluetoothModel.currentAccess()
    private(set) var busy: Set<String> = []
    private(set) var lastError: String?
    @ObservationIgnored private var central: CBCentralManager?

    static func currentAccess() -> BluetoothAccess {
        switch CBManager.authorization {
        case .allowedAlways: .allowed
        case .notDetermined: .notDetermined
        default: .denied
        }
    }

    /// Asks macOS for Bluetooth access (shows the system prompt once).
    func requestAccess() {
        guard central == nil else { return refresh() }
        central = CBCentralManager(delegate: self, queue: .main)
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated { refresh() }
    }

    func refresh() {
        access = Self.currentAccess()
        guard access == .allowed else { devices = []; return }
        isPoweredOn = IOBluetoothHostController.default()?.powerState == kBluetoothHCIPowerStateON
        let batteries = Self.hidBatteries()
        let paired = (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice]) ?? []
        devices = BluetoothDevice.sorted(paired.compactMap { device in
            guard let address = device.addressString else { return nil }
            let name = device.name ?? device.nameOrAddress ?? address
            return BluetoothDevice(id: address, name: name,
                                   kind: BluetoothDevice.kind(major: device.deviceClassMajor, minor: device.deviceClassMinor),
                                   isConnected: device.isConnected(), batteryPercent: batteries[name])
        })
    }

    /// Opens or closes the baseband connection, like the Bluetooth menu.
    func toggleConnection(_ id: String) {
        guard let device = IOBluetoothDevice(addressString: id), !busy.contains(id) else { return }
        busy.insert(id)
        lastError = nil
        let result = device.isConnected() ? device.closeConnection() : device.openConnection()
        busy.remove(id)
        if result != kIOReturnSuccess {
            lastError = "Couldn't reach \(device.name ?? "the device"). Make sure it's on and nearby."
        }
        refresh()
    }

    /// Battery levels Apple HID peripherals publish in the I/O Registry, by product name.
    static func hidBatteries() -> [String: Int] {
        var result: [String: Int] = [:]
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleDeviceManagementHIDEventService"),
                                           &iterator) == KERN_SUCCESS else { return result }
        defer { IOObjectRelease(iterator) }
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let name = IORegistryEntryCreateCFProperty(service, "Product" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let percent = IORegistryEntryCreateCFProperty(service, "BatteryPercent" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? Int
            else { continue }
            result[name] = percent
        }
        return result
    }
}

// MARK: Audio devices

struct AudioDevice: Identifiable, Equatable, Sendable {
    let id: AudioObjectID
    let name: String
    let hasOutput: Bool
    let hasInput: Bool
    let transport: UInt32

    var symbol: String {
        switch transport {
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: "headphones"
        case kAudioDeviceTransportTypeBuiltIn: hasInput && !hasOutput ? "mic" : "laptopcomputer"
        case kAudioDeviceTransportTypeAirPlay: "airplayaudio"
        case kAudioDeviceTransportTypeHDMI, kAudioDeviceTransportTypeDisplayPort: "tv"
        case kAudioDeviceTransportTypeUSB: "cable.connector"
        default: hasInput && !hasOutput ? "mic" : "hifispeaker"
        }
    }
}

/// Lists audio devices and switches the default input and output (public
/// Core Audio; no permission). Read on demand: the Sound pane refreshes
/// when shown and after each change.
@MainActor @Observable
final class AudioDevicesModel {
    private(set) var outputs: [AudioDevice] = []
    private(set) var inputs: [AudioDevice] = []
    private(set) var defaultOutput: AudioObjectID?
    private(set) var defaultInput: AudioObjectID?
    private(set) var outputVolume: Float?
    private(set) var inputVolume: Float?

    func refresh() {
        let devices = Self.allDevices()
        outputs = devices.filter(\.hasOutput)
        inputs = devices.filter(\.hasInput)
        defaultOutput = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        defaultInput = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        outputVolume = defaultOutput.flatMap { Self.volume($0, scope: kAudioDevicePropertyScopeOutput) }
        inputVolume = defaultInput.flatMap { Self.volume($0, scope: kAudioDevicePropertyScopeInput) }
    }

    func setDefault(_ device: AudioObjectID, output: Bool) {
        var id = device
        var address = AudioObjectPropertyAddress(
            mSelector: output ? kAudioHardwarePropertyDefaultOutputDevice : kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil,
                                   UInt32(MemoryLayout<AudioObjectID>.size), &id)
        refresh()
    }

    func setVolume(_ value: Float, output: Bool) {
        guard let device = output ? defaultOutput : defaultInput else { return }
        let scope = output ? kAudioDevicePropertyScopeOutput : kAudioDevicePropertyScopeInput
        var level = min(max(value, 0), 1)
        for element in [kAudioObjectPropertyElementMain, 1, 2] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            var settable: DarwinBoolean = false
            guard AudioObjectHasProperty(device, &address),
                  AudioObjectIsPropertySettable(device, &address, &settable) == noErr, settable.boolValue else { continue }
            AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<Float>.size), &level)
            if element == kAudioObjectPropertyElementMain { break }
        }
        if output { outputVolume = level } else { inputVolume = level }
    }

    private static func allDevices() -> [AudioDevice] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids.compactMap { id in
            let hasOutput = channels(id, scope: kAudioDevicePropertyScopeOutput) > 0
            let hasInput = channels(id, scope: kAudioDevicePropertyScopeInput) > 0
            guard hasOutput || hasInput, let name = string(id, kAudioObjectPropertyName) else { return nil }
            return AudioDevice(id: id, name: name, hasOutput: hasOutput, hasInput: hasInput,
                               transport: uint32(id, kAudioDevicePropertyTransportType) ?? 0)
        }
    }

    private static func channels(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope,
                                                 mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(size), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, raw) == noErr else { return 0 }
        let list = UnsafeMutableAudioBufferListPointer(raw.assumingMemoryBound(to: AudioBufferList.self))
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        uint32(AudioObjectID(kAudioObjectSystemObject), selector).flatMap { $0 == 0 ? nil : $0 }
    }

    private static func uint32(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr ? value : nil
    }

    private static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value?.takeRetainedValue() as String?
    }

    private static func volume(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Float? {
        for element in [kAudioObjectPropertyElementMain, 1] {
            var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar, mScope: scope, mElement: element)
            guard AudioObjectHasProperty(device, &address) else { continue }
            var value: Float = 0
            var size = UInt32(MemoryLayout<Float>.size)
            if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr { return value }
        }
        return nil
    }
}

// MARK: Battery health

/// What System Settings › Battery shows, from the I/O Registry (no permission).
struct BatteryHealth: Equatable, Sendable {
    var cycleCount: Int?
    /// Nominal full-charge capacity as a share of the design capacity (0…1).
    var maximumCapacity: Double?
    /// "Normal" / "Service Recommended", from IOPS.
    var condition: String?
    /// Minutes, while discharging or charging; nil while macOS is still estimating.
    var minutesToEmpty: Int?
    var minutesToFull: Int?
    var adapterWatts: Int?

    static func capacity(nominal: Int?, design: Int?) -> Double? {
        guard let nominal, let design, design > 0, nominal > 0 else { return nil }
        return min(Double(nominal) / Double(design), 1)
    }

    /// 65535 (and negatives) mean "still calculating".
    static func minutes(_ raw: Int?) -> Int? {
        guard let raw, raw > 0, raw < 65535 else { return nil }
        return raw
    }

    static func current() -> BatteryHealth? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func property(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        let data = property("BatteryData") as? [String: Any]
        var health = BatteryHealth(
            cycleCount: property("CycleCount") as? Int,
            maximumCapacity: capacity(nominal: data?["NominalChargeCapacity"] as? Int ?? property("NominalChargeCapacity") as? Int,
                                      design: data?["DesignCapacity"] as? Int ?? property("DesignCapacity") as? Int),
            minutesToEmpty: minutes(property("AvgTimeToEmpty") as? Int),
            minutesToFull: minutes(property("AvgTimeToFull") as? Int))
        if let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for source in sources {
                guard let d = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                      d[kIOPSTypeKey] as? String == kIOPSInternalBatteryType else { continue }
                health.condition = (d[kIOPSBatteryHealthConditionKey] as? String) ?? (d[kIOPSBatteryHealthKey] as? String)
            }
        }
        if let adapter = IOPSCopyExternalPowerAdapterDetails()?.takeRetainedValue() as? [String: Any] {
            health.adapterWatts = adapter[kIOPSPowerAdapterWattsKey] as? Int
        }
        return health
    }
}

// MARK: Keep Awake

/// Keeps the Mac (and display) awake with a power assertion, for a set time
/// or until turned off. The assertion dies with Orbit, so a crash or quit
/// never leaves the Mac unable to sleep.
@MainActor @Observable
final class KeepAwakeModel {
    /// One power assertion per app: the System pane and the widget share it.
    static let shared = KeepAwakeModel()

    enum Duration: Int, CaseIterable, Identifiable, Sendable {
        case fifteenMinutes = 15, oneHour = 60, twoHours = 120, indefinitely = 0
        var id: Int { rawValue }
        var title: String {
            switch self {
            case .fifteenMinutes: "15 min"
            case .oneHour: "1 hour"
            case .twoHours: "2 hours"
            case .indefinitely: "Until off"
            }
        }
    }

    private(set) var until: Date?
    private(set) var isActive = false
    @ObservationIgnored private var assertion: IOPMAssertionID = 0
    @ObservationIgnored private var timer: Task<Void, Never>?
    private let createAssertion: () -> IOPMAssertionID?
    private let releaseAssertion: (IOPMAssertionID) -> Void

    init(create: @escaping () -> IOPMAssertionID? = KeepAwakeModel.systemCreate,
         release: @escaping (IOPMAssertionID) -> Void = { IOPMAssertionRelease($0) }) {
        createAssertion = create
        releaseAssertion = release
    }

    nonisolated static func systemCreate() -> IOPMAssertionID? {
        var id: IOPMAssertionID = 0
        let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleDisplaySleep as CFString,
                                                 IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                 "Orbit Keep Awake" as CFString, &id)
        return result == kIOReturnSuccess ? id : nil
    }

    func start(_ duration: Duration, now: Date = .now) {
        stop()
        guard let id = createAssertion() else { return }
        assertion = id
        isActive = true
        guard duration != .indefinitely else { return }
        let end = now.addingTimeInterval(TimeInterval(duration.rawValue * 60))
        until = end
        timer = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.stop()
        }
    }

    func stop() {
        timer?.cancel()
        timer = nil
        if isActive { releaseAssertion(assertion) }
        assertion = 0
        isActive = false
        until = nil
    }
}
