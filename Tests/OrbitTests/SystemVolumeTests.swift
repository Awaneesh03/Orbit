import CoreAudio
import Testing
@testable import Orbit

// Stage 4.1-1: SystemVolume over a fake audio layer. Deterministic, and the
// real system volume is never changed (the one real-device test only reads).

/// Stands in for CoreAudio (also used by SonicPulseTests): devices, elements, values, listeners
/// that tests fire by hand. Keeps every handler ever given, so a late
/// ("stale") delivery can be simulated after the listener was removed.
@MainActor
final class FakeAudio: AudioHardware {
    var defaultDevice: AudioObjectID? = 10
    var names: [AudioObjectID: String] = [10: "MacBook Air Speakers", 20: "CX80U", 30: "LG HDR 4K"]
    var elements: [AudioObjectID: [AudioObjectPropertyElement]] = [10: [0], 20: [1, 2], 30: []]  // 30: no software volume
    var volumes: [AudioObjectID: [AudioObjectPropertyElement: Float]] = [10: [0: 0.5], 20: [1: 0.3, 2: 0.4]]
    var settable: Set<AudioObjectID> = [10, 20]
    var mutes: [AudioObjectID: Bool] = [10: false, 20: false]  // 30: no mute control
    var unreadableMute: Set<AudioObjectID> = []
    var refusing: Set<AudioListenProperty> = []
    private(set) var adds = 0
    private(set) var removes = 0
    private(set) var active: [ObjectIdentifier: (AudioListener, @MainActor () -> Void)] = [:]
    private(set) var everHandled: [(AudioListenProperty, AudioObjectID, @MainActor () -> Void)] = []

    func defaultOutputDevice() -> AudioObjectID? { defaultDevice }
    func name(of device: AudioObjectID) -> String? { names[device] }
    func volumeElements(of device: AudioObjectID) -> [AudioObjectPropertyElement] { elements[device] ?? [] }
    func volume(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Float? { volumes[device]?[element] }
    func canSetVolume(of device: AudioObjectID, element: AudioObjectPropertyElement) -> Bool { settable.contains(device) }
    func hasMute(_ device: AudioObjectID) -> Bool { mutes[device] != nil }
    func isMuted(_ device: AudioObjectID) -> Bool? { unreadableMute.contains(device) ? nil : mutes[device] }

    func listen(to property: AudioListenProperty, on object: AudioObjectID,
                _ handler: @escaping @MainActor () -> Void) -> AudioListener? {
        guard !refusing.contains(property) else { return nil }
        let listener = AudioListener(object: object, property: property, block: { _, _ in })
        active[ObjectIdentifier(listener)] = (listener, handler)
        everHandled.append((property, object, handler))
        adds += 1
        return listener
    }

    func stopListening(_ listener: AudioListener) {
        if active.removeValue(forKey: ObjectIdentifier(listener)) != nil { removes += 1 }
    }

    /// CoreAudio reporting a change to a registered listener.
    func fire(_ property: AudioListenProperty, on object: AudioObjectID) {
        for (listener, handler) in active.values where listener.property == property && listener.object == object { handler() }
    }

    func switchDefault(to device: AudioObjectID?) {
        defaultDevice = device
        fire(.defaultOutputDevice, on: AudioObjectID(kAudioObjectSystemObject))
    }
}

@MainActor
private func state(_ volume: SystemVolume) -> VolumeState? {
    if case .device(let state) = volume.status { state } else { nil }
}

@MainActor @Test func readsTheDefaultDeviceVolumeMuteAndName() {
    let audio = FakeAudio()
    let volume = SystemVolume(hardware: audio)
    #expect(volume.status == .stopped)
    volume.start()
    #expect(state(volume) == VolumeState(device: 10, name: "MacBook Air Speakers", volume: 0.5, isMuted: false, canSetVolume: true))
    #expect(volume.listenerCount == 3)  // the system's default device, the main volume, mute
}

@MainActor @Test func followsVolumeAndMuteChanges() {
    let audio = FakeAudio()
    let volume = SystemVolume(hardware: audio)
    volume.start()
    audio.volumes[10] = [0: 0.8]
    audio.fire(.volume(0), on: 10)
    #expect(state(volume)?.volume == 0.8)
    audio.mutes[10] = true
    audio.fire(.mute, on: 10)
    #expect(state(volume)?.isMuted == true && state(volume)?.volume == 0.8)
    audio.mutes[10] = false
    audio.fire(.mute, on: 10)
    #expect(state(volume)?.isMuted == false)
    audio.volumes[10] = [0: 1.7]  // out of range from a misbehaving driver
    audio.fire(.volume(0), on: 10)
    #expect(state(volume)?.volume == 1)
    audio.volumes[10] = [0: .nan]
    audio.fire(.volume(0), on: 10)
    #expect(state(volume)?.volume == nil && state(volume)?.canSetVolume == false)  // never a made-up value
}

@MainActor @Test func switchingDevicesReplacesTheListeners() {
    let audio = FakeAudio()
    let volume = SystemVolume(hardware: audio)
    volume.start()
    audio.switchDefault(to: 20)  // a USB headset with volume on its stereo channels, no main element
    #expect(state(volume) == VolumeState(device: 20, name: "CX80U", volume: 0.4, isMuted: false, canSetVolume: true))
    #expect(volume.listenerCount == 4 && audio.active.count == 4)  // system + channels 1, 2 + mute
    #expect(audio.removes == 2)  // the speakers' volume and mute listeners went
    audio.volumes[20] = [1: 0.6, 2: 0.6]
    audio.fire(.volume(2), on: 20)
    #expect(state(volume)?.volume == 0.6)

    audio.switchDefault(to: 30)  // a display with no software volume and no mute
    #expect(state(volume) == VolumeState(device: 30, name: "LG HDR 4K", volume: nil, isMuted: nil, canSetVolume: false))
    #expect(volume.listenerCount == 1)  // nothing on the device to listen to

    audio.switchDefault(to: nil)  // no output device at all
    #expect(volume.status == .noOutputDevice)
    audio.switchDefault(to: 10)
    #expect(state(volume)?.device == 10 && volume.listenerCount == 3)
}

@MainActor @Test func lateCallbacksFromOldDevicesOrAfterStopAreIgnored() throws {
    let audio = FakeAudio()
    let volume = SystemVolume(hardware: audio)
    volume.start()
    let speakersVolume = try #require(audio.everHandled.first { $0.0 == .volume(0) && $0.1 == 10 }?.2)
    audio.switchDefault(to: 20)
    audio.volumes[10] = [0: 0.9]
    speakersVolume()  // CoreAudio delivers one more for the old device
    #expect(state(volume)?.device == 20 && state(volume)?.volume == 0.4)

    let system = try #require(audio.everHandled.first { $0.0 == .defaultOutputDevice }?.2)
    volume.stop()
    #expect(volume.status == .stopped && volume.listenerCount == 0 && audio.active.isEmpty)
    audio.defaultDevice = 10
    system()  // a device change that was already on its way
    #expect(volume.status == .stopped)
}

@MainActor @Test func repeatedStartAndStopNeverDuplicatesListeners() {
    let audio = FakeAudio()
    let volume = SystemVolume(hardware: audio)
    volume.start()
    volume.start()
    #expect(audio.adds == 3 && audio.active.count == 3)
    volume.stop()
    volume.stop()
    #expect(audio.removes == 3 && audio.active.isEmpty)  // balanced
    for _ in 0 ..< 3 {
        volume.start()
        volume.stop()
    }
    #expect(audio.adds == audio.removes && audio.active.isEmpty)
    volume.start()
    audio.fire(.defaultOutputDevice, on: AudioObjectID(kAudioObjectSystemObject))  // same device again: no reattach
    #expect(audio.active.count == 3 && audio.adds == 15)
}

@MainActor @Test func missingPropertiesAndFailedListenersAreHandled() {
    let audio = FakeAudio()
    audio.unreadableMute = [10]  // a mute control that can't be read right now
    audio.refusing = [.mute]  // and its listener can't be added
    let volume = SystemVolume(hardware: audio)
    volume.start()
    #expect(state(volume)?.isMuted == nil && state(volume)?.volume == 0.5)  // the rest still works
    #expect(volume.listenerFailures == 1 && volume.listenerCount == 2)

    audio.volumes[10] = nil  // unplugged mid-read: the read fails
    audio.fire(.volume(0), on: 10)
    #expect(state(volume)?.volume == nil)

    let noSystemListener = FakeAudio()
    noSystemListener.refusing = [.defaultOutputDevice]
    let fallback = SystemVolume(hardware: noSystemListener)
    fallback.start()
    #expect(fallback.listenerFailures == 1 && state(fallback)?.volume == 0.5)  // still read once
    fallback.stop()
    #expect(noSystemListener.active.isEmpty)
}

@MainActor @Test func theRealDefaultDeviceIsOnlyRead() {
    // Read-only: whatever this Mac has. Nothing is set.
    let hardware = CoreAudioHardware()
    guard let device = hardware.defaultOutputDevice() else { return }  // a Mac without output: nothing to check
    let volume = SystemVolume(hardware: hardware)
    volume.start()
    defer { volume.stop() }
    guard case .device(let state) = volume.status else { Issue.record("no state for device \(device)"); return }
    #expect(state.device == device)
    if let level = state.volume { #expect((0 ... 1).contains(level)) }
    #expect(state.canSetVolume == false || state.volume != nil)
    #expect(volume.listenerCount >= 1)
}
