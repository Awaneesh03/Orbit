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
/// One or two rows fill the available height; further rows scroll. A row
/// that isn't full shares its width between its widgets (Milestone 21), so
/// there's never an empty hole at the end of the Overview.
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
            HubScroll(indicators: .never) {
                VStack(spacing: spacing) {
                    ForEach(rows.indices, id: \.self) { rowIndex in
                        let row = rows[rowIndex].map { widgets[$0] }
                        let spans = row.map { min($0.presentation.span, columns) }
                        HStack(spacing: spacing) {
                            ForEach(Array(row.enumerated()), id: \.element.id) { index, placed in
                                WidgetHost(widget: placed.widget, presentation: placed.presentation)
                                    .frame(width: Self.width(span: spans[index], rowSpans: spans, total: geometry.size.width,
                                                             cell: cell, spacing: spacing, columns: columns))
                            }
                            Spacer(minLength: 0)
                        }
                        .frame(height: rowHeight)
                    }
                }
            }
            .scrollBounceBehavior(.basedOnSize)  // a grid that fits never rubber-bands (e.g. after a card's list ends)
        }
    }
}

extension WidgetGrid {
    /// A widget's width in its row: whole cells in a full row; a row that isn't full shares the width by span.
    static func width(span: Int, rowSpans: [Int], total: CGFloat, cell: CGFloat, spacing: CGFloat, columns: Int) -> CGFloat {
        let used = rowSpans.reduce(0, +)
        guard used < columns, used > 0 else { return max(0, cell * CGFloat(span) + spacing * CGFloat(span - 1)) }
        let free = total - spacing * CGFloat(rowSpans.count - 1)
        return max(0, free * CGFloat(span) / CGFloat(used))
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
