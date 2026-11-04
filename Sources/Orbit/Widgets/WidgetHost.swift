import SwiftUI

/// One widget in its card: its content when ready, otherwise a uniform
/// loading / empty / error / unavailable message. Starts the widget when it
/// appears and stops it when it disappears, so disabled widgets, hidden tabs
/// and a closed dashboard do no work.
struct WidgetHost: View {
    let widget: any DashboardWidget
    let presentation: WidgetPresentation

    var body: some View {
        let meta = widget.metadata
        OrbitGlassCard(id: meta.id, title: meta.title, symbol: meta.symbol,
                       badge: meta.availability == .sample ? "SAMPLE" : nil) {
            switch widget.state {
            case .ready:
                if let note = widget.statusNote {
                    // Stale data stays on screen, with a note instead of an error.
                    VStack(alignment: .leading, spacing: 6) {
                        widget.content(presentation)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        Label(note.text, systemImage: note.symbol)
                            .font(OrbitType.caption)
                            .foregroundStyle(Theme.tertiary)
                            .lineLimit(1)
                    }
                } else {
                    widget.content(presentation)
                }
            case .loading:
                OrbitLoadingView()
            case .empty(let message):
                status(message, symbol: "tray")
            case .failed(let message):
                status(message, symbol: "exclamationmark.triangle", tone: .warning)
            case .unavailable(let reason):
                status(reason, symbol: "slash.circle")
            case .needsAccess(let reason):
                status(reason, symbol: "lock")
            }
        }
        .onAppear { WidgetVisibility.appeared(widget) }
        .onDisappear { WidgetVisibility.disappeared(widget) }
    }

    private func status(_ text: String, symbol: String, tone: StatusMessage.Tone = .neutral) -> some View {
        VStack(spacing: 10) {
            StatusMessage(text: text, symbol: symbol, tone: tone)
                .fixedSize(horizontal: false, vertical: true)
            if let action = widget.stateAction {
                OrbitGlassButton(title: action.title, symbol: action.symbol, action: action.perform)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Counts on-screen hosts per widget, so a widget shown in two places during
/// a transition (Battery on both the Overview and System) starts once and
/// stops only when its last host disappears.
@MainActor
enum WidgetVisibility {
    /// The count belongs to this exact widget: a freed widget's leftover entry
    /// (an address can be reused) is never mistaken for a new one's.
    private final class Entry {
        weak var widget: (any DashboardWidget)?
        var count = 1
        init(_ widget: any DashboardWidget) { self.widget = widget }
    }

    private static var entries: [ObjectIdentifier: Entry] = [:]

    private static func entry(for widget: any DashboardWidget) -> Entry? {
        guard let entry = entries[ObjectIdentifier(widget)], entry.widget === widget else { return nil }
        return entry
    }

    static func appeared(_ widget: any DashboardWidget) {
        if let entry = entry(for: widget) {
            entry.count += 1
        } else {
            entries[ObjectIdentifier(widget)] = Entry(widget)
            widget.start()
        }
    }

    static func disappeared(_ widget: any DashboardWidget) {
        guard let entry = entry(for: widget) else { return }
        if entry.count > 1 {
            entry.count -= 1
        } else {
            entries[ObjectIdentifier(widget)] = nil
            widget.stop()
        }
    }

    static func isVisible(_ widget: any DashboardWidget) -> Bool { entry(for: widget) != nil }
}

/// Lays widgets out on a grid of equal cells; expanded widgets span two.
/// One or two rows fill the available height; further rows scroll.
struct WidgetGrid: View {
    let widgets: [DashboardModel.PlacedWidget]
    var columns = 3
    @Environment(\.widgetSpacing) private var spacing

    var body: some View {
        GeometryReader { geometry in
            // Never negative: the first layout pass can measure zero (SwiftUI faults on negative frames).
            let cell = max(0, (geometry.size.width - spacing * CGFloat(columns - 1)) / CGFloat(columns))
            let rows = WidgetGridPacking.rows(spans: widgets.map(\.presentation.span), columns: columns)
            let visibleRows = CGFloat(min(max(rows.count, 1), 2))
            let rowHeight = max(0, (geometry.size.height - spacing * (visibleRows - 1)) / visibleRows)
            ScrollView {
                VStack(spacing: spacing) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        HStack(spacing: spacing) {
                            ForEach(rows[rowIndex].map { widgets[$0] }) { placed in
                                let span = CGFloat(min(placed.presentation.span, columns))
                                WidgetHost(widget: placed.widget, presentation: placed.presentation)
                                    .frame(width: cell * span + spacing * (span - 1))
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: rowHeight)
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)  // a grid that fits never rubber-bands (e.g. after a card's list ends)
        }
    }
}

private struct WidgetSpacingKey: EnvironmentKey {
    static let defaultValue = Theme.spacing
}

extension EnvironmentValues {
    var widgetSpacing: CGFloat {
        get { self[WidgetSpacingKey.self] }
        set { self[WidgetSpacingKey.self] = newValue }
    }
}
