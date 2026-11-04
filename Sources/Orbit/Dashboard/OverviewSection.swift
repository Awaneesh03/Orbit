import SwiftUI

/// The Overview: every enabled widget, in the user's order, on the widget grid.
struct OverviewSection: View {
    let model: DashboardModel

    var body: some View {
        let widgets = model.overviewWidgets
        if widgets.isEmpty {
            StatusMessage(text: "No widgets enabled", symbol: "square.dashed")
        } else {
            WidgetGrid(widgets: widgets)
        }
    }
}

/// The Daily Briefing: its own widgets and sizes (`briefingWidgets`, from
/// briefing.json) on the same grid as the Overview, the same widget
/// instances. Two rows of three cells by default, so it fits without scrolling.
struct BriefingSection: View {
    let widgets: [DashboardModel.PlacedWidget]

    var body: some View {
        if widgets.isEmpty {
            StatusMessage(text: "Nothing in your briefing", symbol: "sun.horizon")
        } else {
            WidgetGrid(widgets: widgets)
        }
    }
}

/// Any other section: its category's widgets. A section with a single widget
/// (Screenshot Vault, AI Hub) gives it the whole page.
struct CategorySection: View {
    let widgets: [DashboardModel.PlacedWidget]

    var body: some View {
        if widgets.isEmpty {
            StatusMessage(text: "Nothing here yet", symbol: "square.dashed")
        } else if widgets.count == 1, let only = widgets.first {
            WidgetHost(widget: only.widget, presentation: only.presentation)
        } else {
            WidgetGrid(widgets: widgets)
        }
    }
}
