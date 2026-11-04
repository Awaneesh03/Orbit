import AppKit

/// Overview shortcuts. Each only launches an app bundle, so none needs a
/// permission. Never target a user folder: opening ~/Downloads, ~/Desktop or
/// ~/Documents from Orbit's process triggers a macOS privacy (TCC) prompt.
enum QuickAction: CaseIterable, Identifiable {
    case screenshot, settings, calendar, activityMonitor

    var id: Self { self }

    var title: String {
        switch self {
        case .screenshot: "Screenshot"
        case .settings: "Settings"
        case .calendar: "Calendar"
        case .activityMonitor: "Activity"
        }
    }

    var symbol: String {
        switch self {
        case .screenshot: "camera.viewfinder"
        case .settings: "gearshape"
        case .calendar: "calendar"
        case .activityMonitor: "waveform.path.ecg"
        }
    }

    /// nil: Orbit's own Settings window (handled by the app delegate).
    var target: URL? {
        switch self {
        case .screenshot: URL(filePath: "/System/Applications/Utilities/Screenshot.app")
        case .settings: nil
        case .calendar: URL(filePath: "/System/Applications/Calendar.app")
        case .activityMonitor: URL(filePath: "/System/Applications/Utilities/Activity Monitor.app")
        }
    }

    @MainActor func perform() {
        if let target { NSWorkspace.shared.open(target) }
    }
}
