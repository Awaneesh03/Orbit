import Testing
@testable import Orbit

// Short delay keeps the suite fast; waits are 6× the delay to stay robust under load.
private let delay = Duration.milliseconds(50)
private let settle = Duration.milliseconds(300)

/// "Eventually hidden": waits up to 2 s, because parallel tests can keep the
/// main actor busy past a fixed sleep. ("Still open" checks keep fixed sleeps:
/// a late hide can only make them stricter.)
@MainActor private func waitUntilHidden(_ interaction: NotchInteraction) async throws {
    for _ in 0..<100 where interaction.phase != .hidden { try await Task.sleep(for: .milliseconds(20)) }
}

@MainActor @Test func startsHidden() {
    let interaction = NotchInteraction(hideDelay: delay)
    #expect(interaction.phase == .hidden)
    #expect(!interaction.isOpen)
}

@MainActor @Test func pointerEnterOpensImmediately() {
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerEntered()
    #expect(interaction.phase == .open)
}

@MainActor @Test func reopensAfterBeingClosed() {
    // No Space gating: after a close (e.g. a Space change into a full-screen
    // app) the next hover opens again.
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerEntered()
    interaction.close()
    interaction.pointerEntered()
    #expect(interaction.phase == .open)
}

@MainActor @Test func exitHidesAfterDelay() async throws {
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerEntered()
    interaction.pointerExited()
    #expect(interaction.phase == .closing)
    #expect(interaction.isOpen)  // still on screen during the delay
    try await waitUntilHidden(interaction)
    #expect(interaction.phase == .hidden)
}

@MainActor @Test func reenteringCancelsPendingHide() async throws {
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerEntered()
    interaction.pointerExited()
    interaction.pointerEntered()
    try await Task.sleep(for: settle)
    #expect(interaction.phase == .open)
}

@MainActor @Test func closeIsImmediateAndCancelsPendingHide() async throws {
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerEntered()
    interaction.pointerExited()
    interaction.close()  // Escape / outside click / Space change
    #expect(interaction.phase == .hidden)
    interaction.pointerEntered()
    try await Task.sleep(for: settle)
    #expect(interaction.phase == .open)  // the cancelled hide must not fire later
}

@MainActor @Test func typingHoldsTheDashboardOpen() async throws {
    let interaction = NotchInteraction(hideDelay: delay)
    var typing = true
    interaction.holdsOpen = { typing }
    interaction.pointerEntered()
    interaction.pointerExited()  // pointer leaves while a text field is being edited
    try await Task.sleep(for: settle)
    #expect(interaction.phase == .open)
    interaction.close()  // Escape / outside click still close it
    #expect(interaction.phase == .hidden)
    typing = false
    interaction.pointerEntered()
    interaction.pointerExited()
    try await waitUntilHidden(interaction)
    #expect(interaction.phase == .hidden)
}

@MainActor @Test func dragOpensAndHoldsTheDashboard() async throws {
    let interaction = NotchInteraction(hideDelay: delay, lingerAfterDrop: .milliseconds(400))
    interaction.dragEntered()
    #expect(interaction.phase == .open)
    interaction.pointerExited()  // tracking noise during a drag is ignored
    try await Task.sleep(for: settle)
    #expect(interaction.phase == .open)
}

@MainActor @Test func spaceChangesCloseExceptDuringADrag() {
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerEntered()
    interaction.spaceChanged()
    #expect(interaction.phase == .hidden)

    // Mission Control or a Space switch mid-drag must not close (and re-open) the panel.
    interaction.dragEntered()
    interaction.spaceChanged()
    #expect(interaction.phase == .open)
    interaction.dragEnded(dropped: false)
    interaction.spaceChanged()
    #expect(interaction.phase == .hidden)
}

@MainActor @Test func draggingAwayHidesAfterTheUsualDelay() async throws {
    let interaction = NotchInteraction(hideDelay: delay, lingerAfterDrop: .milliseconds(400))
    interaction.dragEntered()
    interaction.dragEnded(dropped: false)
    #expect(interaction.phase == .closing)
    try await waitUntilHidden(interaction)
    #expect(interaction.phase == .hidden)
}

@MainActor @Test func aDropLingersAndThePointerCanKeepItOpen() async throws {
    let interaction = NotchInteraction(hideDelay: delay, lingerAfterDrop: .milliseconds(400))
    interaction.dragEntered()
    interaction.dragEnded(dropped: true)
    try await Task.sleep(for: settle)  // past the normal delay…
    #expect(interaction.isOpen)          // …still showing the result
    try await waitUntilHidden(interaction)  // then it hides
    #expect(interaction.phase == .hidden)

    interaction.dragEntered()
    interaction.dragEnded(dropped: true)
    interaction.pointerEntered()  // the user moves into the dashboard
    try await Task.sleep(for: .milliseconds(600))
    #expect(interaction.phase == .open)
}

@MainActor @Test func exitWhileHiddenDoesNothing() {
    let interaction = NotchInteraction(hideDelay: delay)
    interaction.pointerExited()
    #expect(interaction.phase == .hidden)
}

@MainActor @Test func openChangeFiresOncePerVisibilityTransition() {
    let interaction = NotchInteraction(hideDelay: delay)
    var events: [Bool] = []
    interaction.onOpenChange = { events.append($0) }
    interaction.pointerEntered()
    interaction.pointerExited()  // closing: still visible, no event
    interaction.pointerEntered()
    interaction.close()
    #expect(events == [true, false])
}
