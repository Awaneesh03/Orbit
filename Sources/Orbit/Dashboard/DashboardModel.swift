import Foundation
import Observation

/// Dashboard state: the selected section and the widget layout. Widgets own
/// their data; this model decides which ones show, in what order and size.
/// Owned by the app delegate, so state survives closing the dashboard.
@MainActor @Observable
final class DashboardModel {
    struct PlacedWidget: Identifiable {
        let id: WidgetID
        let widget: any DashboardWidget
        let presentation: WidgetPresentation
    }

    /// A short-lived message over the dashboard ("Screenshot saved to Vault").
    struct Notice: Equatable {
        let id = UUID()
        let text: String
        let isError: Bool
    }

    /// The Briefing tab exists only while the briefing is enabled: asking for
    /// it otherwise stays on the Overview.
    var section = DashboardSection.overview {
        didSet { if section == .briefing, !briefing.dailyBriefingEnabled { section = .overview } }
    }
    /// An image drag is over the notch or dashboard: show the drop target.
    var isDropTargeted = false
    private(set) var notice: Notice?
    /// Look and feel from Settings; the defaults are the approved design.
    var preferences = OrbitPreferences()
    /// The Daily Briefing (briefing.json), pushed in like `preferences`. Never
    /// touches `layout`: the Briefing has its own list and sizes. Turning it off
    /// while its tab is selected returns to the Overview.
    var briefing = BriefingPreferences() {
        didSet { if !briefing.dailyBriefingEnabled, section == .briefing { section = .overview } }
    }

    /// The tabs to show, in order: the Briefing only while enabled.
    var visibleSections: [DashboardSection] {
        DashboardSection.allCases.filter { $0 != .briefing || briefing.dailyBriefingEnabled }
    }
    let registry: WidgetRegistry
    private(set) var layout: WidgetLayout
    private let store: WidgetLayoutStore
    private let noticeDuration: Duration
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    init(registry: WidgetRegistry, store: WidgetLayoutStore, noticeDuration: Duration = .milliseconds(2500)) {
        self.registry = registry
        self.store = store
        self.noticeDuration = noticeDuration
        layout = (store.load() ?? .defaults(for: registry.metadata)).normalized(for: registry.metadata)
    }

    /// Enabled widgets in the user's order: what the Overview renders.
    var overviewWidgets: [PlacedWidget] {
        layout.items.filter(\.isEnabled).compactMap { item in
            registry.widget(item.id).map { PlacedWidget(id: item.id, widget: $0, presentation: item.presentation) }
        }
    }

    /// The Briefing tab's widgets: the briefing's own list, in its order, the
    /// same widget instances as everywhere else (one data source each), at the
    /// briefing's sizes. Unknown, empty and repeated ids are skipped; a size
    /// the widget doesn't support falls back to compact. Independent of the
    /// Overview's choices.
    var briefingWidgets: [PlacedWidget] {
        BriefingPreferences.cleaned(briefing.widgets).compactMap { id in
            guard let widget = registry.widget(id) else { return nil }
            let wanted = briefing.presentation(for: id)
            return PlacedWidget(id: id, widget: widget,
                                presentation: widget.metadata.presentations.contains(wanted) ? wanted : .compact)
        }
    }

    /// A section page: its category's widgets in registry order, at their section size.
    func sectionWidgets(_ section: DashboardSection) -> [PlacedWidget] {
        if section == .briefing { return briefingWidgets }
        guard let category = section.category else { return overviewWidgets }
        return registry.widgets(in: category).map {
            PlacedWidget(id: $0.metadata.id, widget: $0, presentation: $0.metadata.sectionPresentation)
        }
    }

    /// Shows a notice for `noticeDuration`; a newer notice replaces it.
    func show(_ text: String, isError: Bool = false) {
        let notice = Notice(text: text, isError: isError)
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task { [weak self, noticeDuration] in
            try? await Task.sleep(for: noticeDuration)
            guard !Task.isCancelled, let self, self.notice == notice else { return }
            self.notice = nil
        }
    }

    func setEnabled(_ id: WidgetID, _ isEnabled: Bool) { update { $0.setEnabled(id, isEnabled) } }
    func setPresentation(_ id: WidgetID, _ presentation: WidgetPresentation) { update { $0.setPresentation(id, presentation) } }
    func move(_ id: WidgetID, to index: Int) { update { $0.move(id, to: index) } }
    func resetLayout() { apply(.defaults(for: registry.metadata)) }

    private func update(_ change: (inout WidgetLayout) -> Void) {
        var changed = layout
        change(&changed)
        apply(changed)
    }

    private func apply(_ newLayout: WidgetLayout) {
        layout = newLayout.normalized(for: registry.metadata)
        store.save(layout)
    }
}
