import SwiftUI

/// App shortcuts (see `QuickAction`). Compact: 2×2 grid; expanded: one row.
@MainActor
final class QuickActionsWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "quickActions", title: "Quick actions", description: "Open common apps",
        symbol: "bolt", category: .general, availability: .live,
        presentations: [.compact, .expanded])
    let state = WidgetState.ready
    private let perform: @MainActor (QuickAction) -> Void

    /// `perform` runs the action; the app also closes the dashboard there.
    init(perform: @escaping @MainActor (QuickAction) -> Void) {
        self.perform = perform
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(QuickActionsView(columns: presentation == .compact ? 2 : 4, perform: perform))
    }
}

private struct QuickActionsView: View {
    let columns: Int
    let perform: @MainActor (QuickAction) -> Void

    var body: some View {
        let grid = Array(repeating: GridItem(.flexible(), spacing: 6), count: columns)
        GlassEffectContainer(spacing: 6) {
        LazyVGrid(columns: grid, spacing: 6) {
            ForEach(QuickAction.allCases) { action in
                Button { perform(action) } label: {
                    VStack(spacing: 4) {
                        Image(systemName: action.symbol)
                            .font(.system(size: 13))
                            .frame(height: 15)  // equal icon boxes keep labels aligned
                        Text(action.title)
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 7)
                }
                .buttonStyle(OrbitGlassButtonStyle(
                    shape: AnyShape(RoundedRectangle(cornerRadius: OrbitGlass.innerRadius, style: .continuous))))
            }
        }
        }
    }
}
