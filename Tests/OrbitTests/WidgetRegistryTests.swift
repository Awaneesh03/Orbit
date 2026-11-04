import Testing
@testable import Orbit

private let builtInOrder = [
    "clock", "weather", "battery", "quickActions", "tasks", "pomodoro", "goals", "events",
    "projects", "github", "vault", "system", "storage", "network", "ai", "nowPlaying",
]

@MainActor @Test func builtInRegistryIsValidAndInDefaultOrder() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    #expect(makeBuiltInRegistry(temp).metadata.map(\.id) == builtInOrder)
}

@MainActor @Test func builtInMetadataIsCompleteAndHonest() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let metadata = makeBuiltInRegistry(temp).metadata
    for meta in metadata {
        #expect(!meta.title.isEmpty && !meta.description.isEmpty && !meta.symbol.isEmpty, "\(meta.id)")
        #expect(meta.presentations.contains(.compact), "\(meta.id)")
        #expect(meta.presentations.contains(meta.sectionPresentation), "\(meta.id)")
    }
    // Mock-backed widgets must say so (SAMPLE badge); live ones must not.
    #expect(metadata.filter { $0.availability == .sample }.map(\.id) == ["github", "ai"])
    // The Overview default stays the six Step 3 widgets.
    #expect(metadata.filter(\.isEnabledByDefault).map(\.id)
            == ["clock", "weather", "battery", "quickActions", "tasks", "events"])
}

@MainActor @Test func everySectionHasWidgets() {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let registry = makeBuiltInRegistry(temp)
    for section in DashboardSection.allCases {
        guard let category = section.category else { continue }
        #expect(!registry.widgets(in: category).isEmpty, "\(section) has no widgets")
    }
}

@MainActor @Test func discoversWidgetsByIDAndCategory() throws {
    let registry = try WidgetRegistry([
        FakeWidget("a", category: .system), FakeWidget("b", category: .developer), FakeWidget("c", category: .system),
    ])
    #expect(registry.widget("b")?.metadata.id == "b")
    #expect(registry.widget("missing") == nil)
    #expect(registry.widgets(in: .system).map(\.metadata.id) == ["a", "c"])
    #expect(registry.widgets(in: .ai).isEmpty)
}

@MainActor @Test func rejectsDuplicateIDs() {
    #expect(throws: WidgetRegistryError.duplicateID("a")) {
        try WidgetRegistry([FakeWidget("a"), FakeWidget("b"), FakeWidget("a")])
    }
}

@MainActor @Test func rejectsEmptyID() {
    #expect(throws: WidgetRegistryError.emptyID) { try WidgetRegistry([FakeWidget("")]) }
}

@MainActor @Test func rejectsWidgetWithoutCompactPresentation() {
    #expect(throws: WidgetRegistryError.missingCompactPresentation("big")) {
        try WidgetRegistry([FakeWidget("big", presentations: [.expanded], sectionPresentation: .expanded)])
    }
}

@MainActor @Test func rejectsUnsupportedSectionPresentation() {
    #expect(throws: WidgetRegistryError.unsupportedSectionPresentation("narrow")) {
        try WidgetRegistry([FakeWidget("narrow", sectionPresentation: .expanded)])
    }
}
