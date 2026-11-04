import Foundation
import Testing
@testable import Orbit

private func meta(_ id: WidgetID, expandable: Bool = false, enabled: Bool = true) -> WidgetMetadata {
    WidgetMetadata(id: id, title: id, description: id, symbol: "circle", category: .general,
                   availability: .live, presentations: expandable ? [.compact, .expanded] : [.compact],
                   isEnabledByDefault: enabled)
}

private let registered = [meta("a"), meta("b", expandable: true), meta("c", enabled: false)]

@Test func defaultsFollowRegistryOrderAndDefaultEnablement() {
    let layout = WidgetLayout.defaults(for: registered)
    #expect(layout.items.map(\.id) == ["a", "b", "c"])
    #expect(layout.items.map(\.isEnabled) == [true, true, false])
    #expect(layout.items.allSatisfy { $0.presentation == .compact })
}

@Test func enablingAndDisabling() {
    var layout = WidgetLayout.defaults(for: registered)
    layout.setEnabled("a", false)
    layout.setEnabled("c", true)
    layout.setEnabled("missing", true)  // ignored
    #expect(layout.items.map(\.isEnabled) == [false, true, true])
}

@Test func movingClampsToValidRange() {
    var layout = WidgetLayout.defaults(for: registered)
    layout.move("c", to: 0)
    #expect(layout.items.map(\.id) == ["c", "a", "b"])
    layout.move("c", to: 99)
    #expect(layout.items.map(\.id) == ["a", "b", "c"])
    layout.move("b", to: -5)
    #expect(layout.items.map(\.id) == ["b", "a", "c"])
    layout.move("missing", to: 0)
    #expect(layout.items.map(\.id) == ["b", "a", "c"])
}

@Test func normalizationRepairsInvalidLayouts() {
    let stale = WidgetLayout(items: [
        .init(id: "gone", isEnabled: true, presentation: .compact),     // unregistered → dropped
        .init(id: "b", isEnabled: false, presentation: .expanded),      // kept with user choices
        .init(id: "a", isEnabled: true, presentation: .expanded),       // unsupported → compact
        .init(id: "b", isEnabled: true, presentation: .compact),        // duplicate → dropped
    ])
    let fixed = stale.normalized(for: registered)
    #expect(fixed.items == [
        .init(id: "b", isEnabled: false, presentation: .expanded),
        .init(id: "a", isEnabled: true, presentation: .compact),
        .init(id: "c", isEnabled: false, presentation: .compact),     // newly registered → appended
    ])
    #expect(fixed.normalized(for: registered) == fixed)  // idempotent
}

@Test func storeRoundTripsAndRejectsCorruptData() {
    let storage = MemoryLayoutStorage()
    let store = storage.store
    #expect(store.load() == nil)
    var layout = WidgetLayout.defaults(for: registered)
    layout.move("c", to: 0)
    store.save(layout)
    #expect(store.load() == layout)
    storage.data = Data("not json".utf8)
    #expect(store.load() == nil)
}

@Test func gridPackingKeepsOrderAndWrapsWideWidgets() {
    #expect(WidgetGridPacking.rows(spans: [1, 1, 1, 1, 1, 1], columns: 3) == [[0, 1, 2], [3, 4, 5]])
    #expect(WidgetGridPacking.rows(spans: [1, 2, 2, 1], columns: 3) == [[0, 1], [2, 3]])
    #expect(WidgetGridPacking.rows(spans: [1, 1, 2], columns: 3) == [[0, 1], [2]])
    #expect(WidgetGridPacking.rows(spans: [5], columns: 3) == [[0]])  // clamped to a full row
    #expect(WidgetGridPacking.rows(spans: [], columns: 3).isEmpty)
}
