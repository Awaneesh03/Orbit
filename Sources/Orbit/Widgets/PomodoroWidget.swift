import SwiftUI

/// Pomodoro state. No timer runs anywhere: the countdown is derived from
/// `endsAt`, so the dashboard can be closed (or Orbit relaunched) mid-session.
struct PomodoroTimer: Codable, Equatable, Sendable {
    enum Phase: String, Codable, Sendable { case focus, rest }

    enum Status: Codable, Equatable, Sendable {
        case idle
        case running(endsAt: Date)
        case paused(remaining: TimeInterval)
    }

    var phase = Phase.focus
    var status = Status.idle
    var focusLength: TimeInterval = 25 * 60
    var breakLength: TimeInterval = 5 * 60
    var completedSessions = 0

    var length: TimeInterval { phase == .focus ? focusLength : breakLength }

    func remaining(at now: Date) -> TimeInterval {
        switch status {
        case .idle: length
        case .running(let endsAt): max(0, endsAt.timeIntervalSince(now))
        case .paused(let remaining): remaining
        }
    }

    func isFinished(at now: Date) -> Bool {
        guard case .running = status else { return false }
        return remaining(at: now) <= 0
    }

    mutating func start(at now: Date) {
        guard case .idle = status else { return }
        status = .running(endsAt: now.addingTimeInterval(length))
    }

    mutating func pause(at now: Date) {
        guard case .running = status, !isFinished(at: now) else { return }
        status = .paused(remaining: remaining(at: now))
    }

    mutating func resume(at now: Date) {
        guard case .paused(let remaining) = status else { return }
        status = .running(endsAt: now.addingTimeInterval(remaining))
    }

    mutating func reset() {
        status = .idle
    }

    /// Completes a finished run: focus → break (counting a session), break → focus.
    @discardableResult
    mutating func settle(at now: Date) -> Bool {
        guard isFinished(at: now) else { return false }
        if phase == .focus {
            completedSessions += 1
            phase = .rest
        } else {
            phase = .focus
        }
        status = .idle
        return true
    }

    static func format(_ seconds: TimeInterval) -> String {
        let whole = Int(seconds.rounded(.up))
        return String(format: "%02d:%02d", whole / 60, whole % 60)
    }
}

/// Focus timer: 25-minute focus, 5-minute break. Your data, saved to pomodoro.json.
@MainActor @Observable
final class PomodoroWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "pomodoro", title: "Focus timer", description: "Pomodoro: 25 min focus, 5 min break",
        symbol: "timer", category: .productivity, availability: .live, isEnabledByDefault: false)
    private(set) var stored: Persisted<PomodoroTimer>
    private let now: () -> Date

    var timer: PomodoroTimer { stored.value }
    var state: WidgetState { stored.problem.map(WidgetState.failed) ?? .ready }

    init(file: JSONFile<PomodoroTimer>, now: @escaping () -> Date = { .now }) {
        self.now = now
        stored = Persisted(file, initial: PomodoroTimer())
    }

    /// Catches up on a run that finished while the dashboard was closed.
    func start() { settle() }

    func settle() {
        let time = now()
        if timer.isFinished(at: time) { stored.update { $0.settle(at: time) } }
    }

    func startTimer() {
        settle()
        let time = now()
        stored.update { $0.start(at: time) }
    }

    func pause() {
        let time = now()
        stored.update { $0.pause(at: time) }
    }

    func resume() {
        let time = now()
        stored.update { $0.resume(at: time) }
    }

    func reset() { stored.update { $0.reset() } }

    /// Settles the finished phase and starts the next one.
    func startNext() {
        let time = now()
        stored.update {
            $0.settle(at: time)
            $0.start(at: time)
        }
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        AnyView(PomodoroView(timer: timer, start: startTimer, pause: pause, resume: resume,
                             reset: reset, next: startNext))
    }
}

private struct PomodoroView: View {
    let timer: PomodoroTimer
    let start: () -> Void
    let pause: () -> Void
    let resume: () -> Void
    let reset: () -> Void
    let next: () -> Void

    private var isRunning: Bool {
        if case .running = timer.status { return true }
        return false
    }

    var body: some View {
        // Redraws every second only while running (and only while on screen).
        TimelineView(.periodic(from: .now, by: isRunning ? 1 : 3600)) { context in
            let finished = timer.isFinished(at: context.date)
            VStack(alignment: .leading, spacing: 6) {
                Text(label(finished: finished))
                    .foregroundStyle(finished ? Theme.accent : Theme.secondary)
                OrbitGlassMetric(value: PomodoroTimer.format(timer.remaining(at: context.date)))
                GlassEffectContainer(spacing: 6) {
                    HStack(spacing: 6) { controls(finished: finished) }
                }
                if timer.completedSessions > 0 {
                    Text("\(timer.completedSessions) focus session\(timer.completedSessions == 1 ? "" : "s") done")
                        .foregroundStyle(Theme.tertiary)
                }
            }
        }
    }

    private func label(finished: Bool) -> String {
        switch (timer.phase, finished) {
        case (.focus, false): "Focus"
        case (.rest, false): "Break"
        case (.focus, true): "Focus complete"
        case (.rest, true): "Break over"
        }
    }

    @ViewBuilder
    private func controls(finished: Bool) -> some View {
        switch timer.status {
        case .idle:
            OrbitGlassButton(title: "Start", symbol: "play.fill", prominent: true, action: start)
        case .running where finished:
            OrbitGlassButton(title: timer.phase == .focus ? "Start break" : "Start focus", symbol: "play.fill",
                             prominent: true, action: next)
            OrbitGlassButton(title: "Reset", symbol: "arrow.counterclockwise", action: reset)
        case .running:
            OrbitGlassButton(title: "Pause", symbol: "pause.fill", action: pause)
            OrbitGlassButton(title: "Reset", symbol: "arrow.counterclockwise", action: reset)
        case .paused:
            OrbitGlassButton(title: "Resume", symbol: "play.fill", prominent: true, action: resume)
            OrbitGlassButton(title: "Reset", symbol: "arrow.counterclockwise", action: reset)
        }
    }
}
