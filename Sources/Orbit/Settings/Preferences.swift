import AppKit
import CoreBluetooth
import CoreLocation
import EventKit
import ServiceManagement

enum AppearancePreference: String, Codable, CaseIterable, Identifiable, Sendable {
    case system, dark, light
    var id: Self { self }

    var title: String {
        switch self {
        case .system: "Follow System"
        case .dark: "Dark"
        case .light: "Light"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .dark: NSAppearance(named: .darkAqua)
        case .light: NSAppearance(named: .aqua)
        }
    }
}

enum WidgetSpacing: String, Codable, CaseIterable, Identifiable, Sendable {
    case compact, regular, comfortable
    var id: Self { self }
    var title: String { rawValue.capitalized }

    var points: CGFloat {
        switch self {
        case .compact: 6
        case .regular: 10
        case .comfortable: 14
        }
    }
}

/// How the notch dashboard opens (Milestone 21).
enum NotchOpening: String, Codable, CaseIterable, Sendable {
    case hover, click
    var title: String { self == .hover ? "Hover over the notch" : "Click the notch" }
}

/// User preferences. The defaults reproduce Orbit's approved design exactly.
struct OrbitPreferences: Codable, Equatable, Sendable {
    static let hideDelayRange: ClosedRange<Double> = 0.3...3
    static let opacityRange: ClosedRange<Double> = 0.6...1
    static let musicIslandSecondsRange: ClosedRange<Double> = 2...10
    static let hudSecondsRange: ClosedRange<Double> = 1...5
    static let meetingNoticeRange: ClosedRange<Int> = 10...60
    static let meetingUrgentRange: ClosedRange<Int> = 1...10

    var hideDelay = 1.0
    /// Milestone 21: the notch master switch. Off: no hover dashboard, island, HUDs, alerts or notices in the
    /// notch (as when Coucou has it); the dashboard still opens with its shortcut.
    var notchEnabled = true
    var notchOpen = NotchOpening.hover
    /// Follow macOS Low Power Mode: no opening morph, no decorative motion, while it's on.
    var lowPowerFollows = true
    var appearance = AppearancePreference.dark
    var dashboardOpacity = 0.85
    var widgetSpacing = WidgetSpacing.regular
    var reduceMotion = false
    /// The music island below the notch. Off hides only the island: the Now
    /// Playing widget and playback detection carry on.
    var musicIsland = true
    /// How long the compact island stays when a track starts, unless clicked.
    var musicIslandSeconds = 4.0
    /// Sonic Pulse, the volume HUD below the notch. Off stops its volume
    /// listeners too; the system's own indicator is unaffected.
    var volumeHUD = true
    /// The brightness HUD (Milestone 9): shows the built-in display's level when it changes.
    var brightnessHUD = true
    /// How long the volume and brightness HUDs stay after the last change.
    var hudSeconds = 1.5
    /// Where compact notch info goes: a pill below the notch (default), or wings beside the camera (Milestone 9).
    var compactStyle = CompactStyle.below
    /// Where meetings and agents that need you show (Milestone 15): Automatic = the wings on a notched main display
    /// with "Beside the camera", otherwise the floating pill below the menu bar or notch.
    var statusDisplay = StatusDisplay.automatic
    /// The next meeting in the wings (Milestone 14): a heads-up `meetingNoticeMinutes`
    /// before, more noticeable `meetingUrgentMinutes` before, "now" at the start.
    var meetingHeadsUp = true
    var meetingNoticeMinutes = 30
    var meetingUrgentMinutes = 5
    /// Orbit Pet's master switch, off on a fresh install. Its two experiences
    /// keep their own choice while it's off.
    var orbitPet = false
    var desktopPet = true
    var notchCompanion = true
    /// The pet's look: a cat or dog coat, or colours from your photo (M7).
    var petLook = PetLook()
    /// The AI Hub's master switch (docs/AI_HUB_SPEC.md §14), off by default.
    var aiHub = false
    /// Simulated agents in the AI Hub (§14, P1-2), off by default; only with `aiHub`.
    var aiHubDemo = false
    /// Agent alerts below the notch (Phase 10), while the AI Hub is on.
    var aiHubAlerts = true
    /// Which agent alerts show, and when (Milestone 14).
    var agentAlerts = AgentAlertRules()
    /// Light automations (Milestone 14), none by default.
    var automations: [AutomationRule] = []
    /// Milestone 16: the Universal Launcher's shortcut and whether it searches files (Spotlight, names only).
    var launcherShortcut = LauncherShortcut.controlOptionSpace
    var launcherFiles = true
    /// Milestone 20: Apple Shortcuts in the launcher (Return runs one you chose).
    var launcherShortcuts = true
    /// The Battery widget's Apps Using Significant Energy (sampled only while it shows) and charging animation.
    var batteryEnergy = true
    var chargingAnimation = true
    /// Milestone 20: a 3 s note below the notch when a Bluetooth device connects or disconnects
    /// (only once Orbit has Bluetooth access; it never asks for it).
    var deviceNotices = true
    /// Milestone 21: charger connected or removed, fully charged, low battery, as a note below the notch.
    var powerNotices = true
    /// Lyrics in the expanded Now Playing widget, from LRCLIB (the track's title and artist are sent). Off by default.
    var lyrics = false
    /// Clipboard history's switch and size (Milestone 20). The history itself stays in memory only.
    var clipboardHistory = false
    var clipboardLimit = ClipboardHistory.limit
    /// The Get Started page has been shown once.
    var onboardingSeen = false
    /// Milestone 21's one-time tidy of the Overview (the header now shows the time and battery) is done.
    var headerTidyDone = false
    /// Proactive suggestions (Milestone 17): conservative by default (2 at most).
    var suggestions = SuggestionPreferences()

    init() {}

    /// Tolerant: a missing or invalid field takes its default and every other
    /// valid field is kept; out-of-range numbers are clamped.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OrbitPreferences()
        hideDelay = (try? container.decode(Double.self, forKey: .hideDelay)) ?? defaults.hideDelay
        notchEnabled = (try? container.decode(Bool.self, forKey: .notchEnabled)) ?? defaults.notchEnabled
        notchOpen = (try? container.decode(NotchOpening.self, forKey: .notchOpen)) ?? defaults.notchOpen
        lowPowerFollows = (try? container.decode(Bool.self, forKey: .lowPowerFollows)) ?? defaults.lowPowerFollows
        appearance = (try? container.decode(AppearancePreference.self, forKey: .appearance)) ?? defaults.appearance
        dashboardOpacity = (try? container.decode(Double.self, forKey: .dashboardOpacity)) ?? defaults.dashboardOpacity
        widgetSpacing = (try? container.decode(WidgetSpacing.self, forKey: .widgetSpacing)) ?? defaults.widgetSpacing
        reduceMotion = (try? container.decode(Bool.self, forKey: .reduceMotion)) ?? defaults.reduceMotion
        musicIsland = (try? container.decode(Bool.self, forKey: .musicIsland)) ?? defaults.musicIsland
        musicIslandSeconds = (try? container.decode(Double.self, forKey: .musicIslandSeconds)) ?? defaults.musicIslandSeconds
        volumeHUD = (try? container.decode(Bool.self, forKey: .volumeHUD)) ?? defaults.volumeHUD
        brightnessHUD = (try? container.decode(Bool.self, forKey: .brightnessHUD)) ?? defaults.brightnessHUD
        hudSeconds = (try? container.decode(Double.self, forKey: .hudSeconds)) ?? defaults.hudSeconds
        compactStyle = (try? container.decode(CompactStyle.self, forKey: .compactStyle)) ?? defaults.compactStyle
        statusDisplay = (try? container.decode(StatusDisplay.self, forKey: .statusDisplay)) ?? defaults.statusDisplay
        meetingHeadsUp = (try? container.decode(Bool.self, forKey: .meetingHeadsUp)) ?? defaults.meetingHeadsUp
        meetingNoticeMinutes = (try? container.decode(Int.self, forKey: .meetingNoticeMinutes)) ?? defaults.meetingNoticeMinutes
        meetingUrgentMinutes = (try? container.decode(Int.self, forKey: .meetingUrgentMinutes)) ?? defaults.meetingUrgentMinutes
        orbitPet = (try? container.decode(Bool.self, forKey: .orbitPet)) ?? defaults.orbitPet
        desktopPet = (try? container.decode(Bool.self, forKey: .desktopPet)) ?? defaults.desktopPet
        notchCompanion = (try? container.decode(Bool.self, forKey: .notchCompanion)) ?? defaults.notchCompanion
        petLook = (try? container.decode(PetLook.self, forKey: .petLook)) ?? defaults.petLook
        aiHub = (try? container.decode(Bool.self, forKey: .aiHub)) ?? defaults.aiHub
        aiHubDemo = (try? container.decode(Bool.self, forKey: .aiHubDemo)) ?? defaults.aiHubDemo
        aiHubAlerts = (try? container.decode(Bool.self, forKey: .aiHubAlerts)) ?? defaults.aiHubAlerts
        agentAlerts = (try? container.decode(AgentAlertRules.self, forKey: .agentAlerts)) ?? defaults.agentAlerts
        automations = AutomationRule.decodeList(container, forKey: .automations) ?? defaults.automations
        launcherShortcut = (try? container.decode(LauncherShortcut.self, forKey: .launcherShortcut)) ?? defaults.launcherShortcut
        launcherFiles = (try? container.decode(Bool.self, forKey: .launcherFiles)) ?? defaults.launcherFiles
        launcherShortcuts = (try? container.decode(Bool.self, forKey: .launcherShortcuts)) ?? defaults.launcherShortcuts
        batteryEnergy = (try? container.decode(Bool.self, forKey: .batteryEnergy)) ?? defaults.batteryEnergy
        chargingAnimation = (try? container.decode(Bool.self, forKey: .chargingAnimation)) ?? defaults.chargingAnimation
        deviceNotices = (try? container.decode(Bool.self, forKey: .deviceNotices)) ?? defaults.deviceNotices
        powerNotices = (try? container.decode(Bool.self, forKey: .powerNotices)) ?? defaults.powerNotices
        lyrics = (try? container.decode(Bool.self, forKey: .lyrics)) ?? defaults.lyrics
        clipboardHistory = (try? container.decode(Bool.self, forKey: .clipboardHistory)) ?? defaults.clipboardHistory
        clipboardLimit = (try? container.decode(Int.self, forKey: .clipboardLimit)) ?? defaults.clipboardLimit
        onboardingSeen = (try? container.decode(Bool.self, forKey: .onboardingSeen)) ?? defaults.onboardingSeen
        headerTidyDone = (try? container.decode(Bool.self, forKey: .headerTidyDone)) ?? defaults.headerTidyDone
        suggestions = (try? container.decode(SuggestionPreferences.self, forKey: .suggestions)) ?? defaults.suggestions
        self = clamped()
    }

    /// What the pet model is told. The Notch Companion has no window until
    /// Stage 5.6, so its saved choice isn't passed on yet: it would only keep
    /// the model running for a pet nobody can see.
    var petToggles: PetModel.Toggles { PetModel.Toggles(pet: orbitPet, desktop: desktopPet, companion: false) }

    func clamped() -> OrbitPreferences {
        var copy = self
        copy.hideDelay = min(max(hideDelay, Self.hideDelayRange.lowerBound), Self.hideDelayRange.upperBound)
        copy.dashboardOpacity = min(max(dashboardOpacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        copy.musicIslandSeconds = min(max(musicIslandSeconds.isFinite ? musicIslandSeconds : 4,
                                          Self.musicIslandSecondsRange.lowerBound), Self.musicIslandSecondsRange.upperBound)
        copy.hudSeconds = min(max(hudSeconds.isFinite ? hudSeconds : 1.5, Self.hudSecondsRange.lowerBound), Self.hudSecondsRange.upperBound)
        copy.meetingNoticeMinutes = meetingNoticeMinutes.clamped(to: Self.meetingNoticeRange)
        copy.meetingUrgentMinutes = meetingUrgentMinutes.clamped(to: Self.meetingUrgentRange)
        if !ClipboardHistory.limitChoices.contains(clipboardLimit) { copy.clipboardLimit = ClipboardHistory.limit }
        return copy
    }
}

/// Preferences, saved to preferences.json through `Persisted`: an unreadable
/// file is left untouched until the user explicitly resets.
@MainActor @Observable
final class PreferencesModel {
    private var stored: Persisted<OrbitPreferences>
    @ObservationIgnored var onChange: ((OrbitPreferences) -> Void)?

    var value: OrbitPreferences { stored.value }
    var problem: String? { stored.problem }

    /// `nil` keeps preferences in memory only (tests).
    init(file: JSONFile<OrbitPreferences>?) {
        stored = file.map { Persisted($0, initial: OrbitPreferences()) } ?? Persisted(memory: OrbitPreferences())
    }

    func update(_ change: (inout OrbitPreferences) -> Void) {
        stored.update {
            change(&$0)
            $0 = $0.clamped()
        }
        onChange?(value)
    }

    func resetGeneral() {
        let defaults = OrbitPreferences()
        update {
            $0.hideDelay = defaults.hideDelay
            $0.notchEnabled = defaults.notchEnabled
            $0.notchOpen = defaults.notchOpen
            $0.lowPowerFollows = defaults.lowPowerFollows
            $0.musicIsland = defaults.musicIsland
            $0.musicIslandSeconds = defaults.musicIslandSeconds
            $0.volumeHUD = defaults.volumeHUD
            $0.brightnessHUD = defaults.brightnessHUD
            $0.hudSeconds = defaults.hudSeconds
            $0.compactStyle = defaults.compactStyle
            $0.statusDisplay = defaults.statusDisplay
            $0.batteryEnergy = defaults.batteryEnergy
            $0.chargingAnimation = defaults.chargingAnimation
            $0.deviceNotices = defaults.deviceNotices
            $0.powerNotices = defaults.powerNotices
            $0.lyrics = defaults.lyrics
            $0.meetingHeadsUp = defaults.meetingHeadsUp
            $0.meetingNoticeMinutes = defaults.meetingNoticeMinutes
            $0.meetingUrgentMinutes = defaults.meetingUrgentMinutes
        }
    }

    func resetAppearance() {
        let defaults = OrbitPreferences()
        update {
            $0.appearance = defaults.appearance
            $0.dashboardOpacity = defaults.dashboardOpacity
            $0.widgetSpacing = defaults.widgetSpacing
            $0.reduceMotion = defaults.reduceMotion
        }
    }

    /// The only way past an unreadable file: it is moved aside, then defaults saved.
    func resetAll() {
        stored.replace(with: OrbitPreferences())
        onChange?(value)
    }
}

/// Launch at login via `SMAppService` (supported API). The system is the
/// source of truth; macOS may ask the user to approve it in Login Items.
enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static var needsApproval: Bool { SMAppService.mainApp.status == .requiresApproval }

    static func set(_ enabled: Bool) throws {
        if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
    }
}

struct StorageReport: Equatable {
    var vaultBytes: Int64
    var screenshotCount: Int
    var keptCount: Int
    var deletedCount: Int
    var exportBytes: Int64
    var exportCopies: Int
}

enum StorageInspector {
    /// Bytes on disk of every file under `url` (0 if it doesn't exist).
    static func size(of url: URL) -> Int64 {
        let keys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey]
        guard let files = FileManager.default.enumerator(at: url, includingPropertiesForKeys: Array(keys)) else { return 0 }
        var total: Int64 = 0
        for case let file as URL in files {
            guard let values = try? file.resourceValues(forKeys: keys), values.isRegularFile == true else { continue }
            total += Int64(values.totalFileAllocatedSize ?? values.fileSize ?? 0)
        }
        return total
    }

    static func report(vault: ScreenshotVault?, exportRoot: URL) -> StorageReport {
        let exports = (try? FileManager.default.contentsOfDirectory(atPath: exportRoot.path(percentEncoded: false))) ?? []
        return StorageReport(
            vaultBytes: vault.map { size(of: $0.directory) } ?? 0,
            screenshotCount: vault?.active.count ?? 0,
            keptCount: vault?.active.filter(\.isKept).count ?? 0,
            deletedCount: vault?.recentlyDeleted.count ?? 0,
            exportBytes: size(of: exportRoot),
            exportCopies: exports.count)
    }
}

struct PermissionInfo: Identifiable {
    enum Need: String { case required = "Required", optional = "Optional", unused = "Not Used" }

    var id: String { name }
    let name: String
    let need: Need
    let purpose: String
    let status: String
}

/// What Orbit uses. Status comes only from supported calls that never prompt;
/// Orbit never requests any of these by itself.
@MainActor
enum PermissionCatalog {
    static func current() -> [PermissionInfo] {
        [
            .init(name: "Calendars", need: .optional,
                  purpose: "Today's agenda in the Calendar widget, read-only, after you click Connect Calendar",
                  status: calendarStatus()),
            .init(name: "Location", need: .optional,
                  purpose: "Local weather and the Wi-Fi network's name, only after you click Use My Location (Weather) or Allow (System › Wi-Fi)",
                  status: locationStatus()),
            .init(name: "Bluetooth", need: .optional,
                  purpose: "Paired devices in System › Bluetooth and device notices below the notch, after you click Show Devices",
                  status: bluetoothStatus()),
            .init(name: "Accessibility", need: .unused,
                  purpose: "No global key monitoring or control of other windows",
                  status: AXIsProcessTrusted() ? "Allowed, but not used" : "Not granted"),
            .init(name: "Screen Recording", need: .unused,
                  purpose: "Screenshots arrive by drag and drop or Paste",
                  status: CGPreflightScreenCaptureAccess() ? "Allowed, but not used" : "Not granted"),
            .init(name: "Files & Folders", need: .unused,
                  purpose: "Drops and Paste carry your permission; Orbit stores data only in its own folder",
                  status: "Never requested by Orbit"),
        ]
    }

    private static func locationStatus() -> String {
        switch CLLocationManager().authorizationStatus {
        case .notDetermined: "Never requested by Orbit"
        case .authorizedAlways: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    private static func bluetoothStatus() -> String {
        switch CBManager.authorization {
        case .notDetermined: "Never requested by Orbit"
        case .allowedAlways: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    private static func calendarStatus() -> String {
        switch EKEventStore.authorizationStatus(for: .event) {
        case .notDetermined: "Never requested by Orbit"
        case .fullAccess, .writeOnly: "Allowed"
        case .denied: "Denied"
        case .restricted: "Restricted"
        @unknown default: "Unknown"
        }
    }

    static let privacySettingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy")!
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self { min(max(self, range.lowerBound), range.upperBound) }
}
