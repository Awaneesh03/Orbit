import SwiftUI

/// The dashboard shell: section tabs and the selected section, on the dark
/// glass panel that hangs from the notch. Section content lives in its own views.
struct DashboardView: View {
    let interaction: NotchInteraction
    let model: DashboardModel
    /// Height of the camera housing; content starts below it.
    let topInset: CGFloat

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion
    private let shape = UnevenRoundedRectangle(bottomLeadingRadius: 26, bottomTrailingRadius: 26)

    /// Orbit's Reduce Motion setting, or the system's (Accessibility › Display).
    static func reducesMotion(preference: Bool, system: Bool) -> Bool { preference || system }
    private var reducesMotion: Bool {
        Self.reducesMotion(preference: model.preferences.reduceMotion, system: systemReduceMotion)
    }

    var body: some View {
        // Content exists only while open: when hidden the panel is the tiny
        // notch trigger, and the content's minimum size must not enlarge it.
        ZStack {
            if interaction.isOpen {
                panel.transition(.scale(0.85, anchor: .top).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(motion(.spring(duration: 0.3)), value: interaction.isOpen)
        .environment(\.colorScheme, .dark)
        .environment(\.widgetSpacing, model.preferences.widgetSpacing.points)
        .environment(\.orbitReduceMotion, reducesMotion)
    }

    private func motion(_ animation: Animation) -> Animation? {
        OrbitMotion.animation(animation, reduced: reducesMotion)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 12) {
            if model.isDropTargeted {
                // Replaces the content (and its text fields) so the drop always lands on Orbit.
                DropTargetView()
            } else {
                SectionTabs(sections: model.visibleSections, selection: model.section) { model.section = $0 }

                Group {
                    switch model.section {
                    case .overview:
                        OverviewSection(model: model)
                    case .briefing:
                        BriefingSection(widgets: model.briefingWidgets)
                    default:
                        CategorySection(widgets: model.sectionWidgets(model.section))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .id(model.section)
                .transition(.opacity.combined(with: .offset(y: 4)))
            }
        }
        .animation(motion(.snappy(duration: 0.22)), value: model.section)
        .animation(motion(.snappy(duration: 0.2)), value: model.isDropTargeted)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.top, topInset + 8)
        .padding([.horizontal, .bottom], 16)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Top right, level with the tabs: the one spot that never covers content.
        .overlay(alignment: .topTrailing) {
            if let notice = model.notice {
                NoticeView(notice: notice)
                    .padding(.top, topInset + 4)
                    .padding(.trailing, 16)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(motion(.snappy(duration: 0.25)), value: model.notice)
        // Black at the top so the panel reads as an extension of the notch.
        .background(.black.opacity(model.preferences.dashboardOpacity), in: shape)
        .glassEffect(.regular.tint(.black.opacity(0.55)), in: shape)
    }
}

private struct SectionTabs: View {
    let sections: [DashboardSection]
    let selection: DashboardSection
    let onSelect: (DashboardSection) -> Void

    var body: some View {
        GlassEffectContainer(spacing: 2) {
            HStack(spacing: 2) {
                ForEach(sections) { section in
                    let isSelected = section == selection
                    Button { onSelect(section) } label: { tab(section.title, isSelected: isSelected) }
                        .buttonStyle(DashboardButtonStyle())
                }
            }
        }
    }

    /// The selected tab is an interactive glass capsule; the others are plain text.
    @ViewBuilder
    private func tab(_ title: String, isSelected: Bool) -> some View {
        let label = Text(title)
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .foregroundStyle(isSelected ? .white : Theme.secondary)
        if isSelected {
            label.glassEffect(.regular.interactive(), in: .capsule)
        } else {
            label
        }
    }
}

/// Shown while an image is dragged over the notch or dashboard.
private struct DropTargetView: View {
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down.fill")
                .font(.system(size: 34))
                .foregroundStyle(Theme.accent)
            Text("Drop to save to Screenshot Vault")
                .font(.system(size: 17, weight: .semibold))
            Text("Orbit keeps its own copy. The original stays where it is.")
                .foregroundStyle(Theme.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18)
            .strokeBorder(Theme.accent, style: StrokeStyle(lineWidth: 2, dash: [7, 5])))
    }
}

private struct NoticeView: View {
    let notice: DashboardModel.Notice

    var body: some View {
        Label(notice.text, systemImage: notice.isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
            .font(.system(size: 12, weight: .semibold))
            .foregroundStyle(notice.isError ? Color.orange : .white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.black.opacity(0.85), in: .capsule)
            .overlay(Capsule().strokeBorder(notice.isError ? Color.orange.opacity(0.5) : Theme.accent.opacity(0.6)))
    }
}
