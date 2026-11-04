import Foundation
import Testing
@testable import Orbit

@MainActor @Test func batteryIsLoadingUntilStartedThenObservesUntilStopped() {
    let widget = BatteryWidget(read: { BatteryStatus(percent: 64, isCharging: true, isPluggedIn: true) })
    #expect(widget.state == .loading)
    #expect(!widget.isObserving)

    widget.start()
    #expect(widget.state == .ready)
    #expect(widget.status?.percent == 64)
    #expect(widget.isObserving)

    widget.start()  // idempotent: still one subscription
    #expect(widget.isObserving)

    widget.stop()
    #expect(!widget.isObserving)
    widget.stop()  // safe to repeat
    #expect(!widget.isObserving)
}

@MainActor @Test func batteryWithoutBatteryIsUnavailable() {
    let widget = BatteryWidget(read: { nil })
    widget.start()
    defer { widget.stop() }
    #expect(widget.state == .unavailable("No battery"))
}

@MainActor @Test func visibilityStartsOnFirstHostAndStopsAfterLast() {
    // Battery appears on both the Overview and System; switching between them
    // must not stop a widget that is still on screen.
    let widget = FakeWidget("shared")
    WidgetVisibility.appeared(widget)
    WidgetVisibility.appeared(widget)
    #expect(widget.starts == 1)
    WidgetVisibility.disappeared(widget)
    #expect(widget.stops == 0)
    #expect(WidgetVisibility.isVisible(widget))
    WidgetVisibility.disappeared(widget)
    #expect(widget.stops == 1)
    #expect(!WidgetVisibility.isVisible(widget))
    WidgetVisibility.disappeared(widget)  // unbalanced extra call is ignored
    #expect(widget.stops == 1)
}

@MainActor @Test func stateIsReadyForStaticWidgets() {
    #expect(ClockWidget().state == .ready)
    #expect(QuickActionsWidget { _ in }.state == .ready)
    #expect(GitHubWidget().state == .ready)
    #expect(GitHubWidget(activity: []).state == .empty("No recent activity"))
}

@Test func greetingFollowsTimeOfDay() {
    #expect(ClockWidget.greeting(hour: 4) == "Good night")
    #expect(ClockWidget.greeting(hour: 5) == "Good morning")
    #expect(ClockWidget.greeting(hour: 12) == "Good afternoon")
    #expect(ClockWidget.greeting(hour: 17) == "Good evening")
    #expect(ClockWidget.greeting(hour: 22) == "Good night")
}
