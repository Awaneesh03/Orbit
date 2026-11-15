import Foundation
import Testing
@testable import Orbit

// Milestone 9: the eye-break reminder. Off by default; one sleeping task;
// an away user isn't interrupted; the reminder waits for a free notch.

/// Sleeps that return only when the test says so (no real waiting).
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var count: Int { lock.withLock { waiters.count } }
    func sleep() async { await withCheckedContinuation { c in lock.withLock { waiters.append(c) } } }
    func open() { lock.withLock { let w = waiters; waiters = []; return w }.forEach { $0.resume() } }
}

@MainActor
private func model(idle: @escaping () -> TimeInterval = { 0 }, clock: @escaping () -> Date = { Date(timeIntervalSince1970: 0) },
                   gate: Gate) -> EyeBreakModel {
    EyeBreakModel(file: nil, clock: clock, idleSeconds: idle, sleep: { _ in await gate.sleep() })
}

@MainActor private func settle() async { for _ in 0 ..< 10 { await Task.yield() } }

@MainActor @Test func itsOffByDefaultWithTheTwentyTwentyTwentyRule() {
    let breaks = model(gate: Gate())
    #expect(breaks.phase == .off)
    #expect(breaks.settings.workMinutes == 20 && breaks.settings.breakSeconds == 20 && !breaks.settings.isOn)
}

@MainActor @Test func aBreakComesDueRestsAndStartsOver() async {
    let gate = Gate()
    let breaks = model(gate: gate)
    breaks.update { $0.isOn = true }
    #expect(breaks.phase == .working(until: Date(timeIntervalSince1970: 1200)))
    await settle()
    gate.open()  // 20 minutes pass
    await settle()
    #expect(breaks.phase == .resting(until: Date(timeIntervalSince1970: 20)))
    gate.open()  // the break ends
    await settle()
    #expect(breaks.taken == 1)
    guard case .working = breaks.phase else { Issue.record("not working again: \(breaks.phase)"); return }
    breaks.update { $0.isOn = false }
    #expect(breaks.phase == .off)
}

@MainActor @Test func someoneAlreadyAwayIsntInterrupted() async {
    let gate = Gate()
    let breaks = model(idle: { 45 }, gate: gate)  // no input for 45 s ≥ the 20 s break
    breaks.update { $0.isOn = true }
    await settle()
    gate.open()
    await settle()
    #expect(breaks.autoReset == 1)
    guard case .working = breaks.phase else { Issue.record("expected a fresh interval"); return }
    breaks.update { $0.isOn = false }
}

@MainActor @Test func theReminderWaitsForAFreeNotchAndCanBeSnoozedOrPaused() async {
    let gate = Gate()
    let breaks = model(gate: gate)
    var free = false
    breaks.canShow = { free }
    breaks.update { $0.isOn = true }
    await settle()
    gate.open()
    await settle()
    #expect(breaks.phase == .working(until: Date(timeIntervalSince1970: 60)))  // the dashboard was open: a minute later
    free = true
    breaks.breakDue()
    guard case .resting = breaks.phase else { Issue.record("should rest"); return }
    breaks.snooze()
    #expect(breaks.phase == .working(until: Date(timeIntervalSince1970: 300)))
    breaks.pause()
    #expect(breaks.phase == .paused)
    breaks.breakDue()
    #expect(breaks.phase == .paused)  // a stale timer can't fire while paused
    breaks.resume()
    #expect(breaks.phase == .working(until: Date(timeIntervalSince1970: 1200)))
    breaks.update { $0.isOn = false }
}

@MainActor @Test func settingsAreClampedAndPersisted() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<EyeBreakSettings> = temp.file("eyebreak.json")
    let breaks = EyeBreakModel(file: file, sleep: { _ in try await Task.sleep(for: .seconds(3600)) })
    breaks.update { $0.workMinutes = 500; $0.breakSeconds = 1; $0.quiet = true }
    #expect(breaks.settings.workMinutes == 90 && breaks.settings.breakSeconds == 10 && breaks.settings.quiet)
    #expect(try file.load()?.quiet == true)
    let decoded = try JSONDecoder().decode(EyeBreakSettings.self, from: Data(#"{"workMinutes": "lots", "quiet": true}"#.utf8))
    #expect(decoded.workMinutes == 20 && decoded.quiet)  // tolerant
}
