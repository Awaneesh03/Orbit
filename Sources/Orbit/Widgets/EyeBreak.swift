import AppKit
import CoreGraphics
import SwiftUI

// Eye-break reminder (Milestone 9): the 20-20-20 rule by default, off until
// turned on. One sleeping task until the next break (no polling). When a
// break is due but you've already been away from the keyboard and mouse that
// long (system idle time, no permission needed), it just starts over. The
// reminder is a small pill below the notch with a countdown, Snooze and
// Skip; quiet mode keeps it still and wordless-short. It waits while the
// dashboard or the full player is open, or Coucou has the notch.

struct EyeBreakSettings: Codable, Equatable, Sendable {
    var isOn = false
    var workMinutes = 20
    var breakSeconds = 20
    var snoozeMinutes = 5
    /// No motion, no sound, a shorter message.
    var quiet = false

    static let workRange = 5...90
    static let breakRange = 10...120

    func clamped() -> EyeBreakSettings {
        var copy = self
        copy.workMinutes = min(max(workMinutes, Self.workRange.lowerBound), Self.workRange.upperBound)
        copy.breakSeconds = min(max(breakSeconds, Self.breakRange.lowerBound), Self.breakRange.upperBound)
        copy.snoozeMinutes = min(max(snoozeMinutes, 1), 30)
        return copy
    }

    init() {}

    init(from decoder: any Decoder) throws {  // tolerant, like every Orbit settings file
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EyeBreakSettings()
        isOn = (try? c.decode(Bool.self, forKey: .isOn)) ?? d.isOn
        workMinutes = (try? c.decode(Int.self, forKey: .workMinutes)) ?? d.workMinutes
        breakSeconds = (try? c.decode(Int.self, forKey: .breakSeconds)) ?? d.breakSeconds
        snoozeMinutes = (try? c.decode(Int.self, forKey: .snoozeMinutes)) ?? d.snoozeMinutes
        quiet = (try? c.decode(Bool.self, forKey: .quiet)) ?? d.quiet
        self = clamped()
    }
}

@MainActor @Observable
final class EyeBreakModel {
    enum Phase: Equatable {
        case off
        /// Working; the next break at this time.
        case working(until: Date)
        case paused
        /// The break is showing, until this time.
        case resting(until: Date)
    }

    private(set) var phase = Phase.off
    private var stored: Persisted<EyeBreakSettings>
    var settings: EyeBreakSettings { stored.value }
    /// Asked when a break is due: may the reminder show now? (false: try again in a minute)
    @ObservationIgnored var canShow: @MainActor () -> Bool = { true }
    @ObservationIgnored private let clock: () -> Date
    @ObservationIgnored private let idleSeconds: () -> TimeInterval
    @ObservationIgnored private var timer: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    /// Breaks taken, skipped and skipped because you were already away (this launch).
    private(set) var taken = 0
    private(set) var autoReset = 0

    init(file: JSONFile<EyeBreakSettings>?, clock: @escaping () -> Date = { .now },
         idleSeconds: @escaping () -> TimeInterval = EyeBreakModel.systemIdleSeconds,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0, tolerance: .seconds(1)) }) {
        stored = file.map { Persisted($0, initial: EyeBreakSettings()) } ?? Persisted(memory: EyeBreakSettings())
        self.clock = clock
        self.idleSeconds = idleSeconds
        self.sleep = sleep
        if settings.isOn { startWork() }
    }

    /// Seconds since the last keyboard or mouse input (public; no permission).
    nonisolated static func systemIdleSeconds() -> TimeInterval {
        CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
    }

    func update(_ change: (inout EyeBreakSettings) -> Void) {
        var next = settings
        change(&next)
        next = next.clamped()
        guard next != settings else { return }
        let wasOn = settings.isOn, oldWork = settings.workMinutes
        stored.update { $0 = next }
        if next.isOn != wasOn {
            next.isOn ? startWork() : turnOff()
        } else if next.isOn, next.workMinutes != oldWork, case .working = phase {
            startWork()  // a new interval counts from now
        }
    }

    func pause() {
        guard case .working = phase else { return }
        timer?.cancel()
        phase = .paused
    }

    func resume() {
        guard phase == .paused else { return }
        startWork()
    }

    /// From the reminder: later.
    func snooze() { startWork(after: TimeInterval(settings.snoozeMinutes * 60)) }
    /// From the reminder: not this time.
    func skip() { startWork() }
    /// The Mac slept or the screen locked: you've had your break.
    func systemRested() { if case .working = phase { startWork() } else if case .resting = phase { startWork() } }

    func startWork(after seconds: TimeInterval? = nil) {
        timer?.cancel()
        guard settings.isOn else { return turnOff() }
        let due = clock().addingTimeInterval(seconds ?? TimeInterval(settings.workMinutes * 60))
        phase = .working(until: due)
        wait(until: due) { [weak self] in self?.breakDue() }
    }

    func breakDue() {
        guard case .working = phase else { return }
        if idleSeconds() >= TimeInterval(settings.breakSeconds) {  // already away from the screen
            autoReset += 1
            return startWork()
        }
        guard canShow() else { return startWork(after: 60) }
        let end = clock().addingTimeInterval(TimeInterval(settings.breakSeconds))
        phase = .resting(until: end)
        wait(until: end) { [weak self] in
            self?.taken += 1
            self?.startWork()
        }
    }

    private func turnOff() {
        timer?.cancel()
        timer = nil
        phase = .off
    }

    private func wait(until date: Date, then action: @escaping @MainActor () -> Void) {
        let delay = max(0, date.timeIntervalSince(clock()))
        let sleep = self.sleep
        timer = Task {
            try? await sleep(.seconds(delay))
            guard !Task.isCancelled else { return }
            action()
        }
    }
}

// MARK: Widget

@MainActor
final class EyeBreakWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "eyeBreak", title: "Eye Break", description: "A gentle 20-20-20 reminder below the notch",
        symbol: "eye", category: .productivity, availability: .live, isEnabledByDefault: false)
    let model: EyeBreakModel
    var state: WidgetState { .ready }

    init(model: EyeBreakModel) { self.model = model }

    func content(_ presentation: WidgetPresentation) -> AnyView { AnyView(EyeBreakWidgetView(model: model)) }
}

private struct EyeBreakWidgetView: View {
    let model: EyeBreakModel

    var body: some View {
        let s = model.settings
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                OrbitSwitch(label: "Eye breaks", isOn: s.isOn) { on in model.update { $0.isOn = on } }
                Text(status).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                Spacer(minLength: 0)
                switch model.phase {
                case .working: OrbitLinkButton(title: "Pause", action: model.pause)
                case .paused: OrbitLinkButton(title: "Resume", action: model.resume)
                default: EmptyView()
                }
            }
            stepper("Every", value: "\(s.workMinutes) min") { delta in model.update { $0.workMinutes += delta * 5 } }
            stepper("Rest for", value: "\(s.breakSeconds) s") { delta in model.update { $0.breakSeconds += delta * 10 } }
            HStack(spacing: 8) {
                OrbitSwitch(label: "Quiet mode", isOn: s.quiet) { on in model.update { $0.quiet = on } }
                Text("Quiet: no motion").font(OrbitType.caption).foregroundStyle(Theme.tertiary)
            }
        }
    }

    private var status: String {
        switch model.phase {
        case .off: "Off"
        case .paused: "Paused"
        case .working(let until): "Next at \(until.formatted(date: .omitted, time: .shortened))"
        case .resting: "Resting now"
        }
    }

    private func stepper(_ title: String, value: String, change: @escaping (Int) -> Void) -> some View {
        HStack(spacing: 6) {
            Text(title).font(OrbitType.caption).foregroundStyle(Theme.secondary).frame(width: 52, alignment: .leading)
            Button { change(-1) } label: { Image(systemName: "minus").frame(width: 18, height: 18).contentShape(.rect) }
                .buttonStyle(DashboardButtonStyle()).accessibilityLabel("Less")
            Text(value).font(.system(size: 12, weight: .semibold).monospacedDigit()).frame(minWidth: 52)
            Button { change(1) } label: { Image(systemName: "plus").frame(width: 18, height: 18).contentShape(.rect) }
                .buttonStyle(DashboardButtonStyle()).accessibilityLabel("More")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) \(value)")
    }
}

// MARK: Reminder

/// The break: a pill below the notch with the time left, Snooze and Skip.
struct EyeBreakReminder: View {
    let model: EyeBreakModel

    var body: some View {
        let quiet = model.settings.quiet
        HStack(spacing: 10) {
            if case .resting(let until) = model.phase {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    let left = max(0, Int(until.timeIntervalSince(context.date).rounded(.up)))
                    ZStack {
                        Circle().stroke(Color.white.opacity(0.14), lineWidth: 3)
                        Circle().trim(from: 0, to: Double(left) / Double(max(model.settings.breakSeconds, 1)))
                            .stroke(Theme.accent, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                            .animation(quiet ? nil : .linear(duration: 1), value: left)
                        Text("\(left)").font(.system(size: 10, weight: .bold, design: .rounded).monospacedDigit())
                    }
                    .frame(width: 26, height: 26)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(quiet ? "Eye break" : "Look at something far away").font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if !quiet {
                    Text("About 6 m (20 ft) off, until the ring empties").font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Theme.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Button("Snooze", action: model.snooze).buttonStyle(DashboardButtonStyle()).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Button("Skip", action: model.skip).buttonStyle(DashboardButtonStyle()).font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.secondary)
        }
        .padding(.horizontal, 14)
        .frame(width: 340, height: 46)
        .islandSurface(in: Capsule(style: .continuous))
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Eye break")
    }
}

/// The reminder's window, in the compact island's slot; on screen only while resting.
final class EyeBreakPanel: NSPanel {
    let model: EyeBreakModel
    private var generation = 0

    init(model: EyeBreakModel) {
        self.model = model
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        contentView = NSHostingView(rootView: EyeBreakReminder(model: model))
        reposition()
        follow()
    }

    override var canBecomeKey: Bool { false }

    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        let trigger = NotchGeometry.triggerRect(screen: screen.frame, visible: screen.visibleFrame,
                                                left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        let size = CGSize(width: 340, height: 46)
        setFrame(MusicIslandGeometry.rect(size, trigger: trigger, screen: screen.frame), display: false)
    }

    private func follow() {
        generation += 1
        let registered = generation
        let resting = withObservationTracking {
            if case .resting = model.phase { return true } else { return false }
        } onChange: { [weak self] in
            Task { @MainActor in if self?.generation == registered { self?.follow() } }
        }
        if resting { orderFrontRegardless() } else { orderOut(nil) }
    }
}
