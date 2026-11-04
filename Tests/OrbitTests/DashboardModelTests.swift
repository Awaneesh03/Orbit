import Foundation
import Testing
@testable import Orbit

@MainActor
private func makeModel(_ storage: MemoryLayoutStorage) throws -> DashboardModel {
    let registry = try WidgetRegistry([
        FakeWidget("a"), FakeWidget("b", presentations: [.compact, .expanded]), FakeWidget("c", enabledByDefault: false),
    ])
    return DashboardModel(registry: registry, store: storage.store)
}

@MainActor @Test func dashboardStartsOnOverviewWithDefaultLayout() throws {
    let model = try makeModel(MemoryLayoutStorage())
    #expect(model.section == .overview)
    #expect(model.overviewWidgets.map(\.id) == ["a", "b"])  // c is off by default
}

@MainActor @Test func overviewFollowsEnablementOrderAndPresentation() throws {
    let model = try makeModel(MemoryLayoutStorage())
    model.setEnabled("c", true)
    model.setEnabled("a", false)
    model.move("c", to: 0)
    model.setPresentation("b", .expanded)
    model.setPresentation("c", .expanded)  // unsupported → stays compact
    #expect(model.overviewWidgets.map(\.id) == ["c", "b"])
    #expect(model.overviewWidgets.map(\.presentation) == [.compact, .expanded])
}

@MainActor @Test func layoutPersistsAcrossLaunchesAndResets() throws {
    let storage = MemoryLayoutStorage()
    let first = try makeModel(storage)
    first.setEnabled("a", false)
    first.move("b", to: 2)

    let relaunched = try makeModel(storage)
    #expect(relaunched.layout == first.layout)

    relaunched.resetLayout()
    #expect(try makeModel(storage).overviewWidgets.map(\.id) == ["a", "b"])
}

@MainActor @Test func sectionPagesShowTheirCategoryAtSectionSize() throws {
    let registry = try WidgetRegistry([
        FakeWidget("t", presentations: [.compact, .expanded], sectionPresentation: .expanded, category: .productivity),
        FakeWidget("g", category: .productivity),
        FakeWidget("c", category: .system),
    ])
    let model = DashboardModel(registry: registry, store: MemoryLayoutStorage().store)
    #expect(model.sectionWidgets(.productivity).map(\.id) == ["t", "g"])
    #expect(model.sectionWidgets(.productivity).map(\.presentation) == [.expanded, .compact])
    #expect(model.sectionWidgets(.system).map(\.id) == ["c"])
    #expect(model.sectionWidgets(.ai).isEmpty)
    // Section pages ignore the Overview on/off switch.
    model.setEnabled("c", false)
    #expect(model.sectionWidgets(.system).map(\.id) == ["c"])
}

@MainActor @Test func noticesDisappearAndNewerOnesReplaceOlder() async throws {
    let model = DashboardModel(registry: try WidgetRegistry([]), store: MemoryLayoutStorage().store,
                               noticeDuration: .milliseconds(60))
    model.show("Screenshot saved to Vault")
    #expect(model.notice?.text == "Screenshot saved to Vault")
    #expect(model.notice?.isError == false)
    try await Task.sleep(for: .milliseconds(30))
    model.show("That isn't an image Orbit can read.", isError: true)
    try await Task.sleep(for: .milliseconds(45))
    #expect(model.notice?.isError == true)  // the first one's timer didn't clear the second
    try await Task.sleep(for: .milliseconds(150))
    #expect(model.notice == nil)
}

@Test func sectionsAreInTabOrderWithCategories() {
    // Briefing sits after the Overview, shown only while enabled (3.8-2); the rest keep their order.
    #expect(DashboardSection.allCases.map(\.title) ==
            ["Overview", "Briefing", "Productivity", "Developer Hub", "Screenshot Vault", "System", "AI Hub"])
    #expect(DashboardSection.overview.category == nil && DashboardSection.briefing.category == nil)
    #expect(DashboardSection.allCases.dropFirst(2).allSatisfy { $0.category != nil })
}
