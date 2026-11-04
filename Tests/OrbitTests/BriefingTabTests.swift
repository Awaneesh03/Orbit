import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.8-2: the Briefing tab. Shown only while enabled, its own widgets
// (briefingWidgets) on the existing grid, the same instances as the Overview,
// and nothing written anywhere by showing or switching to it.

@MainActor
private func fakeRegistry() throws -> WidgetRegistry {
    try WidgetRegistry([
        FakeWidget("clock"),
        FakeWidget("weather", presentations: [.compact, .expanded]),
        FakeWidget("battery"),
        FakeWidget("tasks", presentations: [.compact, .expanded], category: .productivity),
        FakeWidget("goals", enabledByDefault: false, category: .productivity),
        FakeWidget("events", presentations: [.compact, .expanded], category: .productivity),
    ])
}

private func findScrollViews(_ view: NSView) -> [NSScrollView] {
    (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap(findScrollViews)
}

/// The real dashboard view, open, in an invisible 740 × 420 window.
@MainActor
private final class HostedDashboard {
    let interaction = NotchInteraction()
    let model: DashboardModel
    let window: NSWindow
    let host: NSHostingView<DashboardView>

    init(_ model: DashboardModel, reduceMotion: Bool = false) {
        self.model = model
        model.preferences.reduceMotion = reduceMotion
        host = NSHostingView(rootView: DashboardView(interaction: interaction, model: model, topInset: 0))
        window = NSWindow(contentRect: NSRect(origin: .zero, size: NotchGeometry.dashboardSize), styleMask: .borderless,
                          backing: .buffered, defer: false)
        window.alphaValue = 0  // never on screen
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFrontRegardless()
        interaction.pointerEntered()
    }

    func settle() async {
        for _ in 0 ..< 30 {
            host.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(15))
        }
    }

    func close() {
        interaction.close()
        window.orderOut(nil)
    }
}

// MARK: Visibility and navigation

@MainActor @Test func theBriefingTabShowsOnlyWhileEnabled() throws {
    let model = DashboardModel(registry: try fakeRegistry(), store: MemoryLayoutStorage().store)
    #expect(model.visibleSections == [.overview, .productivity, .developer, .screenshots, .system, .ai])  // as before
    model.section = .briefing  // can't be selected while off
    #expect(model.section == .overview)

    model.briefing.dailyBriefingEnabled = true
    #expect(model.visibleSections == [.overview, .briefing, .productivity, .developer, .screenshots, .system, .ai])
    model.section = .briefing
    #expect(model.section == .briefing)

    model.briefing.dailyBriefingEnabled = false  // turned off while selected
    #expect(model.section == .overview && !model.visibleSections.contains(.briefing))
    #expect(model.briefing.widgets == BriefingPreferences.defaultWidgets)  // its configuration is kept
}

@MainActor @Test func theBriefingUsesItsOwnOrderAndSizes() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let model = DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store)
    model.briefing.dailyBriefingEnabled = true
    let placed = model.sectionWidgets(.briefing)
    #expect(placed.map(\.id) == ["weather", "events", "clock", "goals", "tasks"])
    #expect(placed.map(\.presentation) == [.compact, .expanded, .compact, .compact, .compact])
    #expect(WidgetGridPacking.rows(spans: placed.map(\.presentation.span), columns: 3) == [[0, 1], [2, 3, 4]])  // two rows
    #expect(model.sectionWidgets(.overview).map(\.id) == model.overviewWidgets.map(\.id))  // the Overview is its own
}

@MainActor @Test func switchingTabsNeverTouchesTheOverviewLayout() throws {
    let storage = MemoryLayoutStorage()
    let model = DashboardModel(registry: try fakeRegistry(), store: storage.store)
    model.setEnabled("goals", true)
    model.move("battery", to: 0)
    let bytes = storage.data
    let overview = model.overviewWidgets.map { "\($0.id):\($0.presentation)" }
    model.briefing.dailyBriefingEnabled = true
    for section in [DashboardSection.briefing, .overview, .briefing, .productivity, .briefing] { model.section = section }
    model.briefing.dailyBriefingEnabled = false
    #expect(storage.data == bytes && model.overviewWidgets.map { "\($0.id):\($0.presentation)" } == overview)
}

// MARK: The real view

@MainActor @Test func theBriefingFitsTheDashboardWithoutScrolling() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let model = DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store)
    model.briefing.dailyBriefingEnabled = true
    model.section = .briefing
    let dashboard = HostedDashboard(model)
    defer { dashboard.close() }
    await dashboard.settle()
    let scrollViews = findScrollViews(dashboard.host)
    #expect(!scrollViews.isEmpty)
    for scroll in scrollViews {
        let content = scroll.documentView?.frame.height ?? 0
        #expect(content <= scroll.contentView.bounds.height + 1, "content \(content) > visible \(scroll.contentView.bounds.height)")
    }
}

@MainActor @Test(arguments: [false, true]) func switchingKeepsSharedWidgetsRunning(reduceMotion: Bool) async throws {
    let registry = try fakeRegistry()
    let model = DashboardModel(registry: registry, store: MemoryLayoutStorage().store)
    model.briefing.dailyBriefingEnabled = true
    let tasks = try #require(registry.widget("tasks") as? FakeWidget)  // on the Overview and in the Briefing
    let goals = try #require(registry.widget("goals") as? FakeWidget)  // in the Briefing only (off on the Overview)
    let battery = try #require(registry.widget("battery") as? FakeWidget)  // on the Overview only
    let dashboard = HostedDashboard(model, reduceMotion: reduceMotion)
    await dashboard.settle()
    #expect(tasks.starts == 1 && battery.starts == 1 && goals.starts == 0)

    model.section = .briefing
    await dashboard.settle()
    #expect(tasks.starts == 1 && tasks.stops == 0)  // shown on both: never restarted
    #expect(goals.starts == 1 && battery.stops == 1)

    model.section = .overview
    await dashboard.settle()
    #expect(tasks.starts == 1 && tasks.stops == 0 && goals.stops == 1 && battery.starts == 2)

    dashboard.close()  // the last host goes: everything stops
    for _ in 0 ..< 10 where !(tasks.stops == 1 && battery.stops == 2) { await dashboard.settle() }  // the close animation, under load
    #expect(tasks.stops == 1 && battery.stops == 2 && goals.stops == 1)
}

@MainActor @Test func everyWidgetStateRendersInTheBriefing() throws {
    let states: [WidgetState] = [.loading, .ready, .empty("Choose a city to see the weather."), .failed("You're offline."),
                                 .unavailable("Calendar access is restricted on this Mac."),
                                 .needsAccess("Calendar access is off. Turn it on in System Settings.")]
    let blank = try #require(render(Color.black, size: CGSize(width: 229, height: 160)))
    for state in states {
        for presentation in [WidgetPresentation.compact, .expanded] {
            let widget = FakeWidget("events", presentations: [.compact, .expanded])
            widget.state = state
            widget.stateAction = WidgetAction(title: "Connect Calendar", symbol: "calendar.badge.plus") {}
            let width: CGFloat = presentation == .expanded ? 468 : 229
            let image = try #require(render(WidgetHost(widget: widget, presentation: presentation),
                                            size: CGSize(width: width, height: 160)))
            #expect(image.width == Int(width) && (presentation == .expanded || image.pixels != blank.pixels), "\(state)")
        }
    }
}

@MainActor @Test func theRealWidgetsKeepTheirOwnStates() throws {
    let temp = TemporaryDirectory()  // isolated: no city, no tasks, no goals; Calendar as this Mac allows (never asked)
    defer { temp.cleanup() }
    let model = DashboardModel(registry: makeBuiltInRegistry(temp), store: MemoryLayoutStorage().store)
    model.briefing.dailyBriefingEnabled = true
    let placed = Dictionary(uniqueKeysWithValues: model.briefingWidgets.map { ($0.id, $0.widget) })
    #expect(placed.count == 5 && placed.values.allSatisfy { widget in model.registry.widget(widget.metadata.id) === widget })
    let weather = try #require(placed["weather"])
    #expect(weather.state == .empty("Choose a city to see the weather.") && weather.stateAction?.title == "Choose City")
    let calendar = try #require(placed["events"])
    switch calendar.state {  // whatever this Mac's Calendar permission is; Orbit never asks on its own
    case .needsAccess, .unavailable, .ready, .loading, .empty: break
    case .failed(let message): Issue.record("calendar failed: \(message)")
    }
    #expect(placed["tasks"]?.state != nil && placed["goals"]?.state != nil && placed["clock"]?.state == .ready)
}
