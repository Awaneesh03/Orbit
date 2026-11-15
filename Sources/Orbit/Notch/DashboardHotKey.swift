import Carbon.HIToolbox

/// One global key combination (Carbon's RegisterEventHotKey): no Accessibility or Input Monitoring permission,
/// nothing else observed. Several can be registered; each handler answers only its own ID (Milestone 16: before,
/// the dashboard's handler would have fired for any Orbit hotkey).
@MainActor
final class GlobalHotKey {
    let id: UInt32
    private(set) var keyCode: UInt32
    private(set) var modifiers: UInt32
    private let action: @MainActor () -> Void
    private var hotKey: EventHotKeyRef?
    private var handler: EventHandlerRef?

    var isRegistered: Bool { hotKey != nil }

    init(id: UInt32, keyCode: UInt32, modifiers: UInt32, action: @escaping @MainActor () -> Void) {
        self.id = id
        self.keyCode = keyCode
        self.modifiers = modifiers
        self.action = action
    }

    /// False when another app already holds the combination.
    @discardableResult
    func register() -> Bool {
        guard hotKey == nil else { return true }
        var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let context, let event else { return OSStatus(eventNotHandledErr) }
            var pressedID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &pressedID)
            let hotKey = Unmanaged<GlobalHotKey>.fromOpaque(context).takeUnretainedValue()
            guard status == noErr, pressedID.signature == GlobalHotKey.signature, pressedID.id == hotKey.id else {
                return OSStatus(eventNotHandledErr)  // another Orbit hotkey: let its own handler answer
            }
            MainActor.assumeIsolated { hotKey.action() }  // Carbon delivers on the main thread
            return noErr
        }, 1, &pressed, context, &handler)
        let hotKeyID = EventHotKeyID(signature: Self.signature, id: id)
        let status = RegisterEventHotKey(keyCode, modifiers, hotKeyID, GetApplicationEventTarget(), 0, &hotKey)
        if status != noErr { unregister() }
        return status == noErr
    }

    /// A different combination: re-registers if it was registered. False when the new one is taken.
    @discardableResult
    func change(keyCode: UInt32, modifiers: UInt32) -> Bool {
        let wasRegistered = isRegistered
        unregister()
        self.keyCode = keyCode
        self.modifiers = modifiers
        return wasRegistered ? register() : true
    }

    func unregister() {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let handler { RemoveEventHandler(handler) }
        hotKey = nil
        handler = nil
    }

    nonisolated static let signature = OSType(0x4F52_4254)  // 'ORBT'
}

/// ⌃⌥⌘O anywhere: opens or closes the dashboard (docs/AI_HUB_SPEC.md §22) —
/// the way in that never competes for the notch, so it works while Coucou
/// has it. Coucou's own shortcuts are ⌘⇧N and ⌃⌥ + a key, so this one never clashes.
@MainActor
final class DashboardHotKey {
    static let keyCode = UInt32(kVK_ANSI_O)
    static let modifiers = UInt32(controlKey | optionKey | cmdKey)
    static let label = "⌃⌥⌘O"

    private let hotKey: GlobalHotKey

    var isRegistered: Bool { hotKey.isRegistered }

    init(action: @escaping @MainActor () -> Void) {
        hotKey = GlobalHotKey(id: 1, keyCode: Self.keyCode, modifiers: Self.modifiers, action: action)
    }

    @discardableResult
    func register() -> Bool { hotKey.register() }
    func unregister() { hotKey.unregister() }
}

/// The Universal Launcher's shortcut (Milestone 16): a few combinations that don't clash with macOS or
/// Coucou, chosen in Settings › Launcher. ⌥Space is left out: it types a non-breaking space in many layouts.
enum LauncherShortcut: String, Codable, CaseIterable, Sendable {
    case controlOptionSpace, controlOptionCommandL, commandShiftSpace, off

    var label: String {
        switch self {
        case .controlOptionSpace: "⌃⌥Space"
        case .controlOptionCommandL: "⌃⌥⌘L"
        case .commandShiftSpace: "⌘⇧Space"
        case .off: "Off"
        }
    }

    var combination: (keyCode: UInt32, modifiers: UInt32)? {
        switch self {
        case .controlOptionSpace: (UInt32(kVK_Space), UInt32(controlKey | optionKey))
        case .controlOptionCommandL: (UInt32(kVK_ANSI_L), UInt32(controlKey | optionKey | cmdKey))
        case .commandShiftSpace: (UInt32(kVK_Space), UInt32(cmdKey | shiftKey))
        case .off: nil
        }
    }
}
