import Observation

/// Hover state machine for the notch dashboard:
/// hidden → (pointer enters) → open → (pointer leaves) → closing → (delay) → hidden.
/// Re-entering while closing cancels the hide; `close()` is immediate.
@MainActor @Observable
final class NotchInteraction {
    enum Phase { case hidden, open, closing }

    private(set) var phase: Phase = .hidden {
        didSet {
            if (oldValue == .hidden) != (phase == .hidden) { onOpenChange?(isOpen) }
        }
    }

    /// True while the dashboard is on screen, including the hide delay.
    var isOpen: Bool { phase != .hidden }

    @ObservationIgnored var onOpenChange: ((Bool) -> Void)?
    /// While true, leaving the dashboard doesn't start the hide delay (the
    /// user is typing). Escape, outside clicks and Space changes still close it.
    @ObservationIgnored var holdsOpen: () -> Bool = { false }

    /// True while an accepted screenshot drag is over the notch or dashboard.
    @ObservationIgnored private(set) var isDragging = false

    @ObservationIgnored var hideDelay: Duration
    @ObservationIgnored private let lingerAfterDrop: Duration
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    init(hideDelay: Duration = .seconds(1), lingerAfterDrop: Duration = .seconds(3)) {
        self.hideDelay = hideDelay
        self.lingerAfterDrop = lingerAfterDrop
    }

    func pointerEntered() {
        hideTask?.cancel()
        phase = .open
    }

    func pointerExited() {
        guard phase == .open, !isDragging, !holdsOpen() else { return }
        scheduleHide(after: hideDelay)
    }

    /// An image drag reached the notch or dashboard: open, and stay open for
    /// the whole drag (pointer tracking is suspended while dragging).
    func dragEntered() {
        isDragging = true
        hideTask?.cancel()
        phase = .open
    }

    /// The active Space changed (switching Spaces, entering full screen). Ignored
    /// during a drag: the drag continues and the user is still aiming at Orbit.
    func spaceChanged() {
        guard !isDragging else { return }
        close()
    }

    /// The drag left or finished. After a drop the dashboard lingers so the
    /// result can be seen; moving the pointer into it keeps it open as usual.
    func dragEnded(dropped: Bool) {
        isDragging = false
        guard phase == .open else { return }
        scheduleHide(after: dropped ? lingerAfterDrop : hideDelay)
    }

    private func scheduleHide(after delay: Duration) {
        phase = .closing
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, let self, self.phase == .closing else { return }
            self.phase = .hidden
        }
    }

    /// Escape, outside click or Space change.
    func close() {
        hideTask?.cancel()
        phase = .hidden
    }
}
