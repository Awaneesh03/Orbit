import SwiftUI

/// Greeting, time and date. Live; `TimelineView` redraws once a minute and
/// only while visible, so the widget needs no lifecycle work.
@MainActor
final class ClockWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "clock", title: "Clock", description: "Greeting, time and date",
        symbol: "clock", category: .general, availability: .live)
    let state = WidgetState.ready
    let firstName = NSFullUserName().split(separator: " ").first.map(String.init)

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(ClockView(firstName: firstName))
    }

    nonisolated static func greeting(hour: Int) -> String {
        switch hour {
        case 5..<12: "Good morning"
        case 12..<17: "Good afternoon"
        case 17..<22: "Good evening"
        default: "Good night"
        }
    }
}

private struct ClockView: View {
    let firstName: String?

    var body: some View {
        TimelineView(.everyMinute) { context in
            let hour = Calendar.current.component(.hour, from: context.date)
            VStack(alignment: .leading, spacing: 2) {
                Text(ClockWidget.greeting(hour: hour) + (firstName.map { ", \($0)" } ?? ""))
                    .font(OrbitType.body)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
                OrbitGlassMetric(value: context.date.formatted(date: .omitted, time: .shortened))
                Text(context.date.formatted(.dateTime.weekday(.wide).day().month(.wide)))
                    .font(OrbitType.caption)
                    .foregroundStyle(Theme.secondary)
                    .lineLimit(1)
            }
        }
    }
}
