import SwiftUI

/// The dashboard shell (redesigned in Milestone 21). It grows out of the notch:
/// the black surface starts at the camera housing's exact size and springs open
/// to the full panel, revealing the content through it; closing is quicker and
/// settles without overshoot. The row beside the camera, unused before, is the
/// header: the time, battery and a running timer on the left, the section tabs
/// (icons; the selected one shows its name) on the right. Everything below is
/// the section. Motion is GPU-composited and runs only while opening or
/// closing; with Reduce Motion (or Low Power Mode) it's a short fade.
struct DashboardView: View {
    let interaction: NotchInteraction
    let model: DashboardModel
    /// Height of the camera housing; the header sits beside it.
    let topInset: CGFloat
    /// Width of the camera housing (or the trigger strip on a display without one).
    var notchWidth: CGFloat = 200

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    /// Orbit's Reduce Motion setting, or the system's (Accessibility › Display).
    static func reducesMotion(preference: Bool, system: Bool) -> Bool { preference || system }
    private var reducesMotion: Bool {
        Self.reducesMotion(preference: model.preferences.reduceMotion, system: systemReduceMotion)
    }

    /// Opening: a quick spring with a little life in it. Closing: shorter and without overshoot.
    static let openSpring = Animation.spring(response: 0.38, dampingFraction: 0.8)
    static let closeSpring = Animation.spring(response: 0.26, dampingFraction: 1)
    static let openRadius: CGFloat = 30
    static let closedRadius: CGFloat = 10

    /// The surface's size: the camera housing (plus its shoulders) when closed, the whole panel when open.
    static func surfaceSize(open: Bool, panel: CGSize, notchWidth: CGFloat, topInset: CGFloat) -> CGSize {
        open ? panel : CGSize(width: min(panel.width, notchWidth + 2 * NotchStyle.attachedShoulder),
                              height: min(panel.height, max(topInset, 1)))
    }

    var body: some View {
        let open = interaction.isOpen
        GeometryReader { geometry in
            let surface = Self.surfaceSize(open: open, panel: geometry.size, notchWidth: notchWidth, topInset: topInset)
            let radius = open ? Self.openRadius : Self.closedRadius
            ZStack(alignment: .top) {
                Color.clear
                    .notchSurface(bottomRadius: radius, opacity: model.preferences.dashboardOpacity)
                    .opacity(open ? 1 : 0)
                    // Fades in at once; on closing it waits for the surface to tuck back into the notch.
                    .animation(reducesMotion ? nil : open ? .easeOut(duration: 0.1) : .easeIn(duration: 0.1).delay(0.16), value: open)
                    .frame(width: surface.width, height: surface.height)
                if open {
                    panel
                        .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
                        .transition(contentTransition)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            // The content is revealed through the growing surface.
            .mask(alignment: .top) {
                NotchShape(shoulder: NotchStyle.attachedShoulder, bottomRadius: radius)
                    .frame(width: surface.width, height: surface.height)
            }
        }
        .animation(reducesMotion ? .easeOut(duration: 0.15) : open ? Self.openSpring : Self.closeSpring, value: open)
        .environment(\.colorScheme, .dark)
        .environment(\.widgetSpacing, model.preferences.widgetSpacing.points)
        .environment(\.orbitReduceMotion, reducesMotion)
    }

    private var contentTransition: AnyTransition {
        guard !reducesMotion else { return .opacity }
        return .asymmetric(
            insertion: .opacity.combined(with: .scale(scale: 0.97, anchor: .top)).combined(with: .offset(y: -6))
                .animation(.easeOut(duration: 0.24).delay(0.05)),
            removal: .opacity.animation(.easeIn(duration: 0.09)))
    }

    private func motion(_ animation: Animation) -> Animation? {
        OrbitMotion.animation(animation, reduced: reducesMotion)
    }

    private var panel: some View {
        VStack(alignment: .leading, spacing: 10) {
            NotchHeader(model: model, notchWidth: notchWidth, height: max(topInset, 28))
            Group {
                if model.isDropTargeted {
                    // Replaces the content (and its text fields) so the drop always lands on Orbit.
                    DropTargetView()
                } else {
                    Group {
                        switch model.section {
                        case .overview:
                            OverviewSection(model: model)
                        case .briefing:
                            BriefingSection(widgets: model.briefingWidgets)
                        case .ai:
                            if let hub = model.aiHub {
                                AIHubPage(hub: hub, chat: model.sectionWidgets(.ai))
                            } else {
                                CategorySection(widgets: model.sectionWidgets(.ai))
                            }
                        case .system:
                            SystemPage(services: model.system, widgets: model.sectionWidgets(.system))
                        default:
                            CategorySection(widgets: model.sectionWidgets(model.section))
                        }
                    }
                    .id(model.section)
                    .transition(.opacity.combined(with: .offset(y: 6)))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
        .animation(motion(.snappy(duration: 0.24)), value: model.section)
        .animation(motion(.snappy(duration: 0.2)), value: model.isDropTargeted)
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(.white)
        .padding(.horizontal, 18 + NotchStyle.attachedShoulder)
        .padding(.bottom, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                NoticeView(notice: notice)
                    .padding(.bottom, 14)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(motion(.snappy(duration: 0.25)), value: model.notice)
    }
}

/// The row beside the camera: the time, battery and timer on the left, the tabs on the right.
private struct NotchHeader: View {
    let model: DashboardModel
    let notchWidth: CGFloat
    let height: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 10) {
                Button { NotificationCenter.default.post(name: SettingsWindowController.showRequest, object: nil) } label: {
                    Image(systemName: "gearshape.fill").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.tertiary)
                        .frame(width: 24, height: 24).contentShape(.circle)
                }
                .buttonStyle(PressableStyle())
                .help("Orbit Settings")
                .accessibilityLabel("Orbit Settings")
                HeaderGlance(battery: model.battery)
                if let timer = model.quickTimer, timer.isRunning { TimerChip(timer: timer) }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity)
            Color.clear.frame(width: notchWidth + 12)
            NotchTabs(sections: model.visibleSections, selection: model.section) { model.section = $0 }
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .frame(height: height)
    }
}

/// The time and date (redrawn once a minute while the dashboard is open) and the battery (as it changes).
private struct HeaderGlance: View {
    let battery: BatteryStatus?

    var body: some View {
        TimelineView(.everyMinute) { context in
            HStack(spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(context.date, format: .dateTime.hour().minute())
                        .font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
                    Text(context.date, format: .dateTime.weekday(.abbreviated).day().month(.abbreviated))
                        .font(OrbitType.caption).foregroundStyle(Theme.secondary)
                }
                if let battery {
                    HStack(spacing: 4) {
                        Image(systemName: battery.isCharging ? "battery.100percent.bolt" : PowerNotices.symbol(battery.percent))
                            .symbolRenderingMode(.hierarchical)
                            .foregroundStyle(battery.isCharging ? OrbitGlass.goal : battery.percent <= 20 ? OrbitGlass.warning : Theme.secondary)
                        Text("\(battery.percent)%").font(OrbitType.caption.monospacedDigit()).foregroundStyle(Theme.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Battery \(battery.percent) percent\(battery.isCharging ? ", charging" : "")")
                }
            }
            .lineLimit(1)
        }
    }
}

/// A running quick timer: ticks once a second, only while the dashboard shows it.
private struct TimerChip: View {
    let timer: QuickTimer

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 4) {
                Image(systemName: "timer")
                Text(QuickTimer.format(timer.remaining(at: context.date))).monospacedDigit()
            }
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Theme.accent)
            .padding(.horizontal, 8)
            .frame(height: 22)
            .background(Theme.accent.opacity(0.14), in: .capsule)
        }
        .contextMenu { Button("Cancel Timer") { timer.cancel() } }
        .help(timer.label.isEmpty ? "Timer (right-click to cancel)" : "\(timer.label) (right-click to cancel)")
    }
}

/// The section tabs: icons, with the selected one widening to show its name. The selection pill slides
/// and resizes with one spring; hover lights a tab up.
private struct NotchTabs: View {
    let sections: [DashboardSection]
    let selection: DashboardSection
    let onSelect: (DashboardSection) -> Void
    @Environment(\.orbitReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 2) {
            ForEach(sections) { section in
                tab(section)
            }
        }
        .animation(OrbitMotion.animation(.spring(response: 0.32, dampingFraction: 0.82), reduced: reduceMotion), value: selection)
    }

    private func tab(_ section: DashboardSection) -> some View {
        let isSelected = section == selection
        let hovered = OrbitHover.shared.card == "tab-" + section.rawValue
        return Button { onSelect(section) } label: {
            HStack(spacing: 5) {
                Image(systemName: section.symbol)
                    .font(.system(size: 11.5, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                if isSelected {
                    Text(section.shortTitle).font(.system(size: 11.5, weight: .semibold)).fixedSize()
                        .transition(.opacity.combined(with: .scale(scale: 0.9, anchor: .leading)))
                }
            }
            .foregroundStyle(isSelected ? Color.white : hovered ? Color.white.opacity(0.85) : Theme.secondary)
            .padding(.horizontal, isSelected ? 10 : 7)
            .frame(minWidth: 26, minHeight: 26)
            .background {
                Capsule().fill(isSelected ? Color.white.opacity(0.15) : hovered ? Color.white.opacity(0.07) : .clear)
                    .overlay(Capsule().strokeBorder(isSelected ? Color.white.opacity(0.12) : .clear, lineWidth: 0.5))
            }
            .contentShape(.capsule)
        }
        .buttonStyle(PressableStyle())
        .onHover { OrbitHover.shared.pointer(inside: $0, card: "tab-" + section.rawValue) }
        .help(section.title)
        .accessibilityLabel(section.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// A tactile press: a little smaller while held (not with Reduce Motion).
struct PressableStyle: ButtonStyle {
    @Environment(\.orbitReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.94 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(OrbitMotion.animation(.easeOut(duration: 0.12), reduced: reduceMotion), value: configuration.isPressed)
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
        .background(Theme.accent.opacity(0.08), in: .rect(cornerRadius: 20))
        .overlay(RoundedRectangle(cornerRadius: 20)
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
            .background(.black.opacity(0.9), in: .capsule)
            .overlay(Capsule().strokeBorder(notice.isError ? Color.orange.opacity(0.5) : Theme.accent.opacity(0.6)))
            .shadow(color: .black.opacity(0.4), radius: 10, y: 4)
    }
}
