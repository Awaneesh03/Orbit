import SwiftUI

typealias WidgetID = String

/// How much room a widget takes on a dashboard grid.
enum WidgetPresentation: String, Codable, CaseIterable, Sendable {
    case compact, expanded

    /// Grid cells occupied: one, or two side by side.
    var span: Int { self == .compact ? 1 : 2 }
}

/// Which dashboard section a widget belongs to beyond the Overview.
enum WidgetCategory: String, Codable, CaseIterable, Sendable {
    case general, productivity, developer, screenshots, system, ai
}

/// Where a widget's data comes from. `.sample` widgets show a SAMPLE badge.
enum WidgetAvailability: Sendable, Equatable {
    case live, sample
}

struct WidgetMetadata: Identifiable, Sendable, Equatable {
    let id: WidgetID
    let title: String
    let description: String
    let symbol: String
    let category: WidgetCategory
    let availability: WidgetAvailability
    var presentations: Set<WidgetPresentation> = [.compact]
    /// Size on its section page (Productivity, System, …); must be supported.
    var sectionPresentation: WidgetPresentation = .compact
    /// Shown on the Overview by default. Every widget always appears on its section page.
    var isEnabledByDefault = true
}

/// What a widget can currently show. The host renders everything except
/// `.ready` the same way for every widget.
enum WidgetState: Equatable, Sendable {
    case loading
    case ready
    case empty(String)
    case failed(String)
    /// The source doesn't exist here (no battery, app not installed). Nothing to grant.
    case unavailable(String)
    /// The source exists but a permission isn't granted; the user can grant it.
    /// Only for a real permission check, never as a placeholder.
    case needsAccess(String)
}

/// A button shown with a widget's state (Retry, Open Settings…).
struct WidgetAction {
    let title: String
    var symbol = "arrow.clockwise"
    let perform: @MainActor () -> Void
}

/// A line under ready content: the data is old, or couldn't be refreshed.
struct WidgetNote: Equatable, Sendable {
    let text: String
    var symbol = "clock"
}

/// A dashboard widget: metadata, a load state, a visibility lifecycle and its
/// views. Concrete widgets are small classes (`@Observable` when their data
/// changes) that get data from services or `MockData`; their views are plain
/// structs that only render values.
@MainActor
protocol DashboardWidget: AnyObject {
    var metadata: WidgetMetadata { get }
    var state: WidgetState { get }

    /// The widget became visible. Start any updates here; must be idempotent.
    func start()
    /// The widget is no longer visible. Stop all work here.
    func stop()

    /// Rendered only while `state == .ready`.
    func content(_ presentation: WidgetPresentation) -> AnyView

    /// Shown under ready content when its data is stale (stale-while-revalidate).
    var statusNote: WidgetNote? { get }
    /// Shown with a non-ready state, e.g. Retry after a failure.
    var stateAction: WidgetAction? { get }
}

extension DashboardWidget {
    func start() {}
    func stop() {}
    var statusNote: WidgetNote? { nil }
    var stateAction: WidgetAction? { nil }
}
