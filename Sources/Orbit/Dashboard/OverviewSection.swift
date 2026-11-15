import SwiftUI

/// The Overview: every enabled widget, in the user's order, on the widget grid.
struct OverviewSection: View {
    let model: DashboardModel

    var body: some View {
        let widgets = model.overviewWidgets
        VStack(spacing: 10) {
            if let engine = model.context { SuggestionStrip(engine: engine) }
            if widgets.isEmpty {
                StatusMessage(text: "No widgets enabled", symbol: "square.dashed")
            } else {
                WidgetGrid(widgets: widgets)
            }
        }
    }
}

/// The Daily Briefing: its own widgets and sizes (`briefingWidgets`, from
/// briefing.json), the same widget instances as the Overview. Its first
/// expanded widget is the feature (Tech News by default): two cells wide
/// and both rows tall, with two compact widgets stacked beside it; anything
/// else follows below and scrolls. Without a feature, the plain grid.
struct BriefingSection: View {
    let widgets: [DashboardModel.PlacedWidget]
    @Environment(\.widgetSpacing) private var spacing

    var body: some View {
        if widgets.isEmpty {
            StatusMessage(text: "Nothing in your briefing", symbol: "sun.horizon")
        } else if let split = BriefingLayout.split(widgets.map(\.presentation)) {
            GeometryReader { geometry in
                let cell = max(0, (geometry.size.width - spacing * 2) / 3)
                let row = max(0, (geometry.size.height - spacing) / 2)
                HubScroll(indicators: .never) {
                    VStack(spacing: spacing) {
                        HStack(spacing: spacing) {
                            VStack(spacing: spacing) {
                                ForEach(split.side, id: \.self) { host(widgets[$0]).frame(height: row) }
                            }
                            .frame(width: cell)
                            host(widgets[split.feature]).frame(height: row * 2 + spacing)
                        }
                        ForEach(WidgetGridPacking.rows(spans: split.rest.map { widgets[$0].presentation.span }, columns: 3),
                                id: \.self) { line in
                            HStack(spacing: spacing) {
                                ForEach(line.map { split.rest[$0] }, id: \.self) { index in
                                    let span = CGFloat(widgets[index].presentation.span)
                                    host(widgets[index]).frame(width: cell * span + spacing * (span - 1))
                                }
                                Spacer(minLength: 0)
                            }
                            .frame(height: row)
                        }
                    }
                }
                .scrollBounceBehavior(.basedOnSize)
            }
        } else {
            WidgetGrid(widgets: widgets)
        }
    }

    private func host(_ placed: DashboardModel.PlacedWidget) -> some View {
        WidgetHost(widget: placed.widget, presentation: placed.presentation)
    }
}

enum BriefingLayout {
    /// Indexes for the feature layout: the first expanded widget, the first
    /// two compact widgets (they stack beside it) and everything else in
    /// order. nil without an expanded widget and two compact ones.
    static func split(_ presentations: [WidgetPresentation]) -> (feature: Int, side: [Int], rest: [Int])? {
        guard let feature = presentations.firstIndex(of: .expanded) else { return nil }
        let side = Array(presentations.indices.filter { presentations[$0] == .compact }.prefix(2))
        guard side.count == 2 else { return nil }
        return (feature, side, presentations.indices.filter { $0 != feature && !side.contains($0) })
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
