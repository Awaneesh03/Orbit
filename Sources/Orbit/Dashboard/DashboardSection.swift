/// The dashboard's sections in tab order. The Overview shows the user's widget
/// layout; the Briefing (only while enabled) shows the Daily Briefing's own
/// widgets; every other section shows the widgets of its category.
enum DashboardSection: String, CaseIterable, Identifiable {
    case overview, briefing, productivity, developer, screenshots, system, ai

    var id: Self { self }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .briefing: "Briefing"
        case .productivity: "Productivity"
        case .developer: "Developer Hub"
        case .screenshots: "Screenshot Vault"
        case .system: "System"
        case .ai: "AI Hub"
        }
    }

    /// The tab's icon (Milestone 21: icons in the header beside the camera).
    var symbol: String {
        switch self {
        case .overview: "square.grid.2x2.fill"
        case .briefing: "sun.horizon.fill"
        case .productivity: "checklist"
        case .developer: "chevron.left.forwardslash.chevron.right"
        case .screenshots: "photo.on.rectangle.angled"
        case .system: "macbook"
        case .ai: "sparkles"
        }
    }

    /// The name the selected tab shows, short enough for the header.
    var shortTitle: String {
        switch self {
        case .developer: "Developer"
        case .screenshots: "Vault"
        default: title
        }
    }

    var category: WidgetCategory? {
        switch self {
        case .overview, .briefing: nil
        case .productivity: .productivity
        case .developer: .developer
        case .screenshots: .screenshots
        case .system: .system
        case .ai: .ai
        }
    }
}
