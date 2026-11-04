import AppKit
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

/// User preferences. The defaults reproduce Orbit's approved design exactly.
struct OrbitPreferences: Codable, Equatable, Sendable {
    static let hideDelayRange: ClosedRange<Double> = 0.3...3
    static let opacityRange: ClosedRange<Double> = 0.6...1
    static let musicIslandSecondsRange: ClosedRange<Double> = 2...10

    var hideDelay = 1.0
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

    init() {}

    /// Tolerant: a missing or invalid field takes its default and every other
    /// valid field is kept; out-of-range numbers are clamped.
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = OrbitPreferences()
        hideDelay = (try? container.decode(Double.self, forKey: .hideDelay)) ?? defaults.hideDelay
        appearance = (try? container.decode(AppearancePreference.self, forKey: .appearance)) ?? defaults.appearance
        dashboardOpacity = (try? container.decode(Double.self, forKey: .dashboardOpacity)) ?? defaults.dashboardOpacity
        widgetSpacing = (try? container.decode(WidgetSpacing.self, forKey: .widgetSpacing)) ?? defaults.widgetSpacing
        reduceMotion = (try? container.decode(Bool.self, forKey: .reduceMotion)) ?? defaults.reduceMotion
        musicIsland = (try? container.decode(Bool.self, forKey: .musicIsland)) ?? defaults.musicIsland
        musicIslandSeconds = (try? container.decode(Double.self, forKey: .musicIslandSeconds)) ?? defaults.musicIslandSeconds
        volumeHUD = (try? container.decode(Bool.self, forKey: .volumeHUD)) ?? defaults.volumeHUD
        self = clamped()
    }

    func clamped() -> OrbitPreferences {
        var copy = self
        copy.hideDelay = min(max(hideDelay, Self.hideDelayRange.lowerBound), Self.hideDelayRange.upperBound)
        copy.dashboardOpacity = min(max(dashboardOpacity, Self.opacityRange.lowerBound), Self.opacityRange.upperBound)
        copy.musicIslandSeconds = min(max(musicIslandSeconds.isFinite ? musicIslandSeconds : 4,
                                          Self.musicIslandSecondsRange.lowerBound), Self.musicIslandSecondsRange.upperBound)
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
            $0.musicIsland = defaults.musicIsland
            $0.musicIslandSeconds = defaults.musicIslandSeconds
            $0.volumeHUD = defaults.volumeHUD
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
                  purpose: "Future: local weather (it shows sample data today)",
                  status: "Never requested by Orbit"),
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
