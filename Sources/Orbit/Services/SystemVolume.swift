import CoreAudio
import Observation

// The default output device's volume and mute, from public CoreAudio only,
// event-driven (property listeners; no polling, no permission). No UI here:
// the Sonic Pulse HUD (4.1-2 onward) reads `SystemVolume.status`.

/// What the default output device offers right now.
struct VolumeState: Equatable, Sendable {
    let device: AudioObjectID
    let name: String?
    /// 0…1, or nil when the device has no software volume (some HDMI,
    /// DisplayPort and USB devices): never a made-up percentage.
    let volume: Float?
    /// Nil when the device has no mute control.
    let isMuted: Bool?
    /// Whether Orbit could change the volume (a later phase; nothing sets it yet).
    let canSetVolume: Bool
}

enum SystemVolumeStatus: Equatable, Sendable {
    case stopped
    case noOutputDevice
    case device(VolumeState)
}

/// The CoreAudio calls `SystemVolume` needs, behind a protocol so tests use
/// a fake and never touch the real device.
@MainActor
protocol AudioHardware: AnyObject {
    func defaultOutputDevice() -> AudioObjectID?
    func name(of device: AudioObjectID) -> String?
    /// Where the device's output volume lives: its main element, else its
    /// preferred stereo channels that have one; empty means no software volume.
    func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement]
    func volume(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Float?
    func canSetVolume(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool
    func hasMute(_ device: AudioObjectID) -> Bool
    func isMuted(_ device: AudioObjectID) -> Bool?
    /// Calls `handler` on the main actor whenever the property changes; nil if
    /// the listener couldn't be added.
    func listen(to property: AudioListenProperty, on object: AudioObjectID,
                _ handler: @escaping @MainActor () -> Void) -> AudioListener?
    func stopListening(_ listener: AudioListener)
}

enum AudioListenProperty: Hashable, Sendable {
    case defaultOutputDevice
    case volume(AudioObjectPropertyElement)
    case mute
}

/// One registered listener; removing it needs the exact block it was added with.
final class AudioListener {
    let object: AudioObjectID
    let property: AudioListenProperty
    let block: AudioObjectPropertyListenerBlock

    init(object: AudioObjectID, property: AudioListenProperty, block: @escaping AudioObjectPropertyListenerBlock) {
        self.object = object
        self.property = property
        self.block = block
    }
}

/// Follows the default output device: its volume (main element or stereo
/// channels) and mute, re-attaching when the default device changes. Every
/// callback carries the generation it was registered in, so one that arrives
/// after a device change or `stop()` is ignored. A later volume control must
/// set the value through this service and ignore its own echo; nothing sets it yet.
@MainActor @Observable
final class SystemVolume {
    private(set) var status = SystemVolumeStatus.stopped
    /// Listeners that couldn't be added (diagnostics; readings still work).
    private(set) var listenerFailures = 0

    @ObservationIgnored private let hardware: any AudioHardware
    @ObservationIgnored private var systemListener: AudioListener?
    @ObservationIgnored private var deviceListeners: [AudioListener] = []
    @ObservationIgnored private var device: AudioObjectID?
    @ObservationIgnored private var elements: [AudioObjectPropertyElement] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var running = false

    var isRunning: Bool { running }
    /// Listeners currently registered (tests: balanced add/remove).
    var listenerCount: Int { (systemListener == nil ? 0 : 1) + deviceListeners.count }

    init(hardware: any AudioHardware = CoreAudioHardware()) {
        self.hardware = hardware
    }

    func start() {
        guard !running else { return }
        running = true
        generation += 1
        let current = generation
        systemListener = hardware.listen(to: .defaultOutputDevice, on: AudioObjectID(kAudioObjectSystemObject)) { [weak self] in
            self?.defaultDeviceChanged(generation: current)
        }
        if systemListener == nil {
            listenerFailures += 1
            log.error("volume: couldn't listen for default output device changes")
        }
        attach(hardware.defaultOutputDevice())
    }

    func stop() {
        guard running else { return }
        running = false
        generation += 1  // anything already in flight is now stale
        detachDevice()
        if let systemListener { hardware.stopListening(systemListener) }
        systemListener = nil
        status = .stopped
    }

    #if DEBUG
    /// Debug builds: a made-up reading on the current device, to drive the HUD
    /// from a script without changing the real volume. `debugReread()` puts
    /// the real reading back.
    func debugSimulate(volume: Float?, isMuted: Bool?) {
        guard running, case .device(let current) = status else { return }
        status = .device(VolumeState(device: current.device, name: current.name, volume: volume,
                                     isMuted: isMuted, canSetVolume: volume != nil))
    }

    func debugReread() {
        if running { refresh() }
    }
    #endif

    private func defaultDeviceChanged(generation registered: Int) {
        guard registered == generation, running else { return }
        let next = hardware.defaultOutputDevice()
        if next == device { return refresh() }
        attach(next)
    }

    private func attach(_ next: AudioObjectID?) {
        detachDevice()
        device = next
        guard let next else {
            status = .noOutputDevice
            return
        }
        elements = hardware.volumeElements(of: next)
        let current = generation
        let watched = elements.map(AudioListenProperty.volume) + (hardware.hasMute(next) ? [.mute] : [])
        for property in watched {
            if let listener = hardware.listen(to: property, on: next, { [weak self] in self?.deviceChanged(generation: current, device: next) }) {
                deviceListeners.append(listener)
            } else {
                listenerFailures += 1
                log.error("volume: couldn't listen to \(String(describing: property), privacy: .public)")
            }
        }
        refresh()
    }

    private func detachDevice() {
        deviceListeners.forEach(hardware.stopListening)
        deviceListeners = []
        device = nil
        elements = []
    }

    private func deviceChanged(generation registered: Int, device changed: AudioObjectID) {
        guard registered == generation, running, changed == device else { return }  // an old device's late callback
        refresh()
    }

    private func refresh() {
        guard let device else { return status = .noOutputDevice }
        // The loudest channel: with the balance centred, all channels agree.
        let levels = elements.compactMap { hardware.volume(of: device, element: $0) }.filter(\.isFinite)
        let volume = levels.max().map { min(max($0, 0), 1) }
        let state = VolumeState(device: device, name: hardware.name(of: device), volume: volume,
                                isMuted: hardware.hasMute(device) ? hardware.isMuted(device) : nil,
                                canSetVolume: volume != nil && elements.contains { hardware.canSetVolume(of: device, element: $0) })
        if status != .device(state) { status = .device(state) }
    }
}

// MARK: CoreAudio

/// The real thing: public CoreAudio HAL calls on the system object and the
/// default output device. Reads that fail (a device unplugged mid-read, a
/// property it doesn't have) return nil rather than a guess.
@MainActor
final class CoreAudioHardware: AudioHardware {
    func defaultOutputDevice() -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let result = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
        return result == noErr && device != kAudioObjectUnknown ? device : nil
    }

    func name(of device: AudioObjectID) -> String? {
        var address = Self.address(kAudioObjectPropertyName, kAudioObjectPropertyScopeGlobal)
        guard AudioObjectHasProperty(device, &address) else { return nil }
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] {
        if hasVolume(device, kAudioObjectPropertyElementMain) { return [kAudioObjectPropertyElementMain] }
        var address = Self.address(kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyScopeOutput)
        var channels: [UInt32] = [0, 0]
        var size = UInt32(MemoryLayout<UInt32>.size * 2)
        guard AudioObjectHasProperty(device, &address),
              AudioObjectGetPropertyData(device, &address, 0, nil, &size, &channels) == noErr else { return [] }
        return Array(Set(channels)).sorted().filter { $0 != 0 && hasVolume(device, $0) }
    }

    func volume(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        var value: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value
    }

    func canSetVolume(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        var settable: DarwinBoolean = false
        return AudioObjectIsPropertySettable(device, &address, &settable) == noErr && settable.boolValue
    }

    func hasMute(_ device: AudioObjectID) -> Bool {
        var address = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        return AudioObjectHasProperty(device, &address)
    }

    func isMuted(_ device: AudioObjectID) -> Bool? {
        var address = Self.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &value) == noErr else { return nil }
        return value != 0
    }

    func listen(to property: AudioListenProperty, on object: AudioObjectID,
                _ handler: @escaping @MainActor () -> Void) -> AudioListener? {
        var address = Self.address(for: property)
        // Delivered on the main queue, so the handler runs on the main actor.
        let block: AudioObjectPropertyListenerBlock = { _, _ in MainActor.assumeIsolated { handler() } }
        guard AudioObjectAddPropertyListenerBlock(object, &address, .main, block) == noErr else { return nil }
        return AudioListener(object: object, property: property, block: block)
    }

    func stopListening(_ listener: AudioListener) {
        var address = Self.address(for: listener.property)
        let result = AudioObjectRemovePropertyListenerBlock(listener.object, &address, .main, listener.block)
        if result != noErr { log.error("volume: removing a listener failed (\(result, privacy: .public))") }
    }

    private func hasVolume(_ device: AudioObjectID, _ element: AudioObjectPropertyElement) -> Bool {
        var address = Self.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        return AudioObjectHasProperty(device, &address)
    }

    private static func address(for property: AudioListenProperty) -> AudioObjectPropertyAddress {
        switch property {
        case .defaultOutputDevice: address(kAudioHardwarePropertyDefaultOutputDevice, kAudioObjectPropertyScopeGlobal)
        case .volume(let element): address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput, element)
        case .mute: address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
        }
    }

    private static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                                _ element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }
}
