import AppKit
import Observation
import QuartzCore

// Orbit Pet (Stage 5.4): the Desktop Pet. A transparent, borderless,
// non-activating window just above the desktop icons and below every
// application window, holding the cat rig; it walks, runs, is dragged and
// remembers where it stands. `PetModel` stays the only state machine.

// MARK: Geometry

/// A display the pet can stand on: its whole frame and the part free of
/// the menu bar and the Dock.
struct PetDisplay: Equatable, Sendable {
    let id: UInt32
    let frame: CGRect
    let visible: CGRect
}

/// Where the pet stands, as fractions (0…1) of the room it has to move in
/// on its display's visible frame, so a resolution change keeps it in the
/// same place relative to the desktop.
struct DesktopPetPlacement: Codable, Equatable, Sendable {
    var x: Double
    var y: Double
    var display: UInt32?
}

enum DesktopPetGeometry {
    /// Room around the rig for the hop and the shadow.
    static let padding = CGSize(width: 8, height: 16)
    static let walkSpeed: CGFloat = 45  // points per second
    static let runSpeed: CGFloat = 130
    /// Every move finishes within this, well inside the model's 8 s safety limit.
    static let longestMove: TimeInterval = 6.5
    /// The share of a move spent speeding up (and again slowing down).
    static let ramp: Double = 0.15
    /// The first time: near the left of the desktop, on the floor (above the Dock).
    static let defaultPlacement = DesktopPetPlacement(x: 0.12, y: 0, display: nil)

    static func windowSize(rigSize: CGSize) -> CGSize {
        CGSize(width: rigSize.width + padding.width, height: rigSize.height + padding.height)
    }

    /// The window's origin kept wholly inside `visible` (never over the menu bar or the Dock).
    static func clamp(_ origin: CGPoint, size: CGSize, in visible: CGRect) -> CGPoint {
        CGPoint(x: min(max(origin.x, visible.minX), max(visible.minX, visible.maxX - size.width)),
                y: min(max(origin.y, visible.minY), max(visible.minY, visible.maxY - size.height)))
    }

    static func origin(for placement: DesktopPetPlacement, size: CGSize, on display: PetDisplay) -> CGPoint {
        let room = CGSize(width: max(0, display.visible.width - size.width), height: max(0, display.visible.height - size.height))
        let fraction = CGPoint(x: min(max(placement.x, 0), 1), y: min(max(placement.y, 0), 1))
        return clamp(CGPoint(x: display.visible.minX + room.width * fraction.x, y: display.visible.minY + room.height * fraction.y),
                     size: size, in: display.visible)
    }

    static func placement(for origin: CGPoint, size: CGSize, on display: PetDisplay) -> DesktopPetPlacement {
        let room = CGSize(width: display.visible.width - size.width, height: display.visible.height - size.height)
        let clamped = clamp(origin, size: size, in: display.visible)
        return DesktopPetPlacement(x: room.width > 0 ? Double((clamped.x - display.visible.minX) / room.width) : 0,
                                   y: room.height > 0 ? Double((clamped.y - display.visible.minY) / room.height) : 0,
                                   display: display.id)
    }

    /// The display the pet lives on: the primary display in this stage, so a
    /// saved display that's gone (or any other) falls back to it.
    static func display(for placement: DesktopPetPlacement?, in displays: [PetDisplay]) -> PetDisplay? {
        displays.first
    }

    /// Where a walk or run goes: along the pet's own floor (the same height),
    /// a random distance in a random direction, turning back at the edges,
    /// never further than it covers in `longestMove`.
    static func moveTarget(from origin: CGPoint, size: CGSize, in visible: CGRect, running: Bool,
                           random: () -> Double) -> CGPoint {
        let speed = running ? runSpeed : walkSpeed
        let range: ClosedRange<CGFloat> = running ? 220 ... 620 : 70 ... 260
        let longest = min(range.upperBound, speed * CGFloat(longestMove) * CGFloat(1 - ramp))
        let distance = min(longest, range.lowerBound + (range.upperBound - range.lowerBound) * CGFloat(random()))
        let leftRoom = origin.x - visible.minX
        let rightRoom = visible.maxX - size.width - origin.x
        var goesLeft = random() < 0.5
        if goesLeft, leftRoom < distance, rightRoom > leftRoom { goesLeft = false }
        if !goesLeft, rightRoom < distance, leftRoom > rightRoom { goesLeft = true }
        return clamp(CGPoint(x: origin.x + (goesLeft ? -distance : distance), y: origin.y), size: size, in: visible)
    }

    /// Progress 0…1 along a move at time fraction `t`: a gentle start and
    /// stop around a steady pace (a trapezoid of speed), so the legs' cadence
    /// matches the ground covered for most of the way.
    static func progress(_ t: Double) -> Double {
        let t = min(max(t, 0), 1), r = ramp, peak = 1 / (1 - r)
        if t < r { return peak * t * t / (2 * r) }
        if t > 1 - r { return 1 - peak * (1 - t) * (1 - t) / (2 * r) }
        return peak * (r / 2 + (t - r))
    }

    static func duration(from: CGPoint, to: CGPoint, speed: CGFloat) -> TimeInterval {
        TimeInterval(hypot(to.x - from.x, to.y - from.y) / speed) / (1 - ramp)
    }
}

// MARK: Movement

/// Per-frame callbacks while something moves; nothing runs otherwise.
@MainActor
protocol PetFrameClock: AnyObject {
    var isRunning: Bool { get }
    func start(_ tick: @escaping @MainActor (CFTimeInterval) -> Void)
    func stop()
}

/// The real clock: the view's display link, in step with the screen.
@MainActor
final class DisplayLinkFrameClock: NSObject, PetFrameClock {
    private weak var view: NSView?
    private var link: CADisplayLink?
    private var tick: (@MainActor (CFTimeInterval) -> Void)?

    init(view: NSView) { self.view = view }

    var isRunning: Bool { link != nil }

    func start(_ tick: @escaping @MainActor (CFTimeInterval) -> Void) {
        stop()
        guard let view else { return }
        self.tick = tick
        let link = view.displayLink(target: self, selector: #selector(step(_:)))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
        tick = nil
    }

    @objc private func step(_ link: CADisplayLink) { tick?(link.targetTimestamp) }
}

/// Moves the window from one point to another at a given speed; the clock
/// runs only during the move. A newer move or `cancel()` ends the old one,
/// and a late frame from an old move is ignored (generation).
@MainActor
final class DesktopPetMover {
    private let clock: any PetFrameClock
    private var generation = 0
    private(set) var target: CGPoint?
    private(set) var isRunning = false
    private(set) var position: CGPoint = .zero

    init(clock: any PetFrameClock) { self.clock = clock }

    var isMoving: Bool { target != nil }

    func move(from start: CGPoint, to end: CGPoint, running: Bool,
              step: @escaping @MainActor (CGPoint) -> Void, arrived: @escaping @MainActor () -> Void) {
        cancel()
        position = start
        target = end
        isRunning = running
        let speed = running ? DesktopPetGeometry.runSpeed : DesktopPetGeometry.walkSpeed
        let duration = max(0.05, DesktopPetGeometry.duration(from: start, to: end, speed: speed))
        let current = generation
        var began: CFTimeInterval?
        clock.start { [weak self] now in
            guard let self, current == self.generation else { return }  // a frame from an older move
            let first = began ?? now
            began = first
            let t = (now - first) / duration
            let p = DesktopPetGeometry.progress(t)
            self.position = CGPoint(x: start.x + (end.x - start.x) * p, y: start.y + (end.y - start.y) * p)
            step(self.position)
            guard t >= 1 else { return }
            self.finish()
            arrived()
        }
    }

    /// Stops where it is.
    func cancel() {
        guard isMoving || clock.isRunning else { return }
        finish()
    }

    private func finish() {
        generation += 1
        target = nil
        clock.stop()
    }
}

// MARK: Window

/// The Desktop Pet's window. Borderless, transparent, no shadow; it never
/// becomes key or main, so it never takes keyboard focus or activates Orbit.
/// Its level is the desktop icons' plus one: above the wallpaper and the
/// icons, below every normal application window. It joins every Space but,
/// without `.fullScreenAuxiliary`, never shows on a full-screen app's Space;
/// `.stationary` keeps it still in Mission Control. `ignoresMouseEvents` is
/// left alone: AppKit then passes clicks on fully transparent pixels through
/// to whatever is behind, so only the cat itself takes the pointer (setting
/// it to false explicitly would capture the whole rectangle; see NotchPanel).
final class DesktopPetPanel: NSPanel {
    static let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopIconWindow)) + 1)
    let petView: DesktopPetView

    init(rig: PetRig) {
        petView = DesktopPetView(rig: rig)
        super.init(contentRect: CGRect(origin: .zero, size: DesktopPetGeometry.windowSize(rigSize: rig.root.bounds.size)),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        level = Self.level
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        hidesOnDeactivate = false
        isMovable = false  // moved by Orbit, never by the window server
        isReleasedWhenClosed = false
        animationBehavior = .none
        contentView = petView
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

/// Hosts the rig standing on the window's floor, and turns the pointer into
/// a click or a drag (more than `dragThreshold` points of movement).
final class DesktopPetView: NSView {
    static let dragThreshold: CGFloat = 4
    let rig: PetRig
    var onClick: (() -> Void)?
    var onDragBegan: (() -> Bool)?
    var onDragMoved: ((CGSize) -> Void)?
    var onDragEnded: (() -> Void)?
    private var pressedAt: CGPoint?
    private var dragging = false

    init(rig: PetRig) {
        self.rig = rig
        super.init(frame: CGRect(origin: .zero, size: DesktopPetGeometry.windowSize(rigSize: rig.root.bounds.size)))
        wantsLayer = true
        layer?.addSublayer(rig.root)
    }

    @available(*, unavailable) required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        PetRig.quietly {
            rig.root.position = CGPoint(x: bounds.midX, y: rig.root.bounds.height / 2 + 2)  // on the floor, room above for the hop
        }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        rig.setContentsScale(window?.backingScaleFactor ?? 2)
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }  // a click works without activating Orbit

    override func mouseDown(with event: NSEvent) { press(at: NSEvent.mouseLocation) }
    override func mouseDragged(with event: NSEvent) { drag(to: NSEvent.mouseLocation) }
    override func mouseUp(with event: NSEvent) { release() }

    /// Pointer handling, by screen position (tests call these directly).
    func press(at point: CGPoint) {
        pressedAt = point
        dragging = false
    }

    func drag(to point: CGPoint) {
        guard let pressedAt else { return }
        let delta = CGSize(width: point.x - pressedAt.x, height: point.y - pressedAt.y)
        if !dragging {
            guard hypot(delta.width, delta.height) > Self.dragThreshold else { return }  // still a click
            dragging = onDragBegan?() ?? false
            guard dragging else { return }
        }
        onDragMoved?(delta)
    }

    func release() {
        defer { pressedAt = nil; dragging = false }
        guard pressedAt != nil else { return }
        if dragging { onDragEnded?() } else { onClick?() }
    }
}

// MARK: Controller

/// The Desktop Pet as a whole: creates the window the first time it's
/// enabled and reuses it (ordered out while disabled), keeps the rig in step
/// with the model (`PetCharacter`), moves the window while the model walks or
/// runs, handles the click and the drag, and keeps the pet on the primary
/// display's visible desktop as displays change. Nothing runs while it's
/// still: the frame clock only during a move, no timers of its own.
@MainActor
final class DesktopPet {
    let model: PetModel
    let rig: PetRig
    let character: PetCharacter
    private(set) var panel: DesktopPetPanel?
    private(set) var placement: DesktopPetPlacement?
    private(set) var mover: DesktopPetMover?
    private let displays: @MainActor () -> [PetDisplay]
    private let store: JSONFile<DesktopPetPlacement>?
    private let random: @MainActor () -> Double
    private let makeClock: @MainActor (NSView) -> any PetFrameClock
    private let alpha: CGFloat
    private let observesOcclusion: Bool
    private var following = false
    private var generation = 0
    private var observers: [any NSObjectProtocol] = []
    private var dragStart: CGPoint?
    /// Windows created so far (tests: never more than one).
    private(set) var panelsCreated = 0

    init(model: PetModel, rig: PetRig = PetRig(size: 96), store: JSONFile<DesktopPetPlacement>?,
         displays: @escaping @MainActor () -> [PetDisplay] = DesktopPet.systemDisplays,
         random: @escaping @MainActor () -> Double = { Double.random(in: 0 ..< 1) },
         clock: (@MainActor (NSView) -> any PetFrameClock)? = nil, alpha: CGFloat = 1, observesOcclusion: Bool = true) {
        self.model = model
        self.rig = rig
        self.store = store
        self.displays = displays
        self.random = random
        self.makeClock = clock ?? { DisplayLinkFrameClock(view: $0) }
        self.alpha = alpha
        self.observesOcclusion = observesOcclusion
        character = PetCharacter(model: model, rig: rig)
        placement = (try? store?.load()) ?? nil
    }

    static func systemDisplays() -> [PetDisplay] {
        NSScreen.screens.map { screen in
            let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return PetDisplay(id: id, frame: screen.frame, visible: screen.visibleFrame)
        }
    }

    var isEnabled: Bool { model.toggles.pet && model.toggles.desktop }
    var isFollowing: Bool { following }
    /// Notification observers held (tests: constant across enable/disable).
    var observerCount: Int { observers.count }

    func start() {
        guard !following else { return }
        following = true
        generation += 1
        character.start()
        follow(generation)
    }

    /// Orbit quitting: no window, no movement, nothing observed.
    func stop() {
        guard following else { return }
        following = false
        generation += 1
        mover?.cancel()
        character.stop()
        panel?.orderOut(nil)
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
    }

    /// A Space change: the model ends a walk or a drag; on a full-screen
    /// app's Space the window isn't there (no `.fullScreenAuxiliary`), so the
    /// pet is suppressed until a normal Space returns.
    func spaceChanged() {
        guard following else { return }
        model.spaceChanged()
        updateFullScreen()
    }

    /// Displays were added, removed or changed: back onto the primary
    /// display's visible desktop, in the same relative place.
    func screensChanged() {
        guard following, let panel, panel.isVisible, !(mover?.isMoving ?? false), dragStart == nil else { return }
        place(panel)
    }

    // MARK: Following

    private func follow(_ registered: Int) {
        guard following, registered == generation else { return }
        withObservationTracking {
            _ = (model.toggles, model.state)
        } onChange: { [weak self] in
            Task { @MainActor in self?.follow(registered) }
        }
        sync()
    }

    private func sync() {
        guard following else { return }
        if isEnabled {
            let panel = self.panel ?? makePanel()
            if !panel.isVisible {
                place(panel)
                panel.orderFrontRegardless()
                updateFullScreen()
            }
        } else if let panel, panel.isVisible {
            stopMoving()
            panel.orderOut(nil)
        }
        switch model.state {
        case .walking: walk(running: false)
        case .running: walk(running: true)
        default: stopMoving()
        }
    }

    private func makePanel() -> DesktopPetPanel {
        let panel = DesktopPetPanel(rig: rig)
        panel.alphaValue = alpha
        panelsCreated += 1
        let view = panel.petView
        view.onClick = { [weak self] in self?.model.click() }
        view.onDragBegan = { [weak self] in self?.dragBegan() ?? false }
        view.onDragMoved = { [weak self] in self?.dragMoved($0) }
        view.onDragEnded = { [weak self] in self?.dragEnded() }
        mover = DesktopPetMover(clock: makeClock(view))
        if observesOcclusion { observers.append(contentsOf: occlusionObserver(panel)) }
        self.panel = panel
        return panel
    }

    private func occlusionObserver(_ panel: DesktopPetPanel) -> [any NSObjectProtocol] {
        [NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: panel, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.occlusionChanged() }
        }]
    }

    private func occlusionChanged() {
        guard let panel, panel.isVisible else { return }
        // Covered by windows (or on a Space it can't be on): nothing to animate.
        model.activity.setDesktopOccluded(!panel.occlusionState.contains(.visible))
    }

    private func updateFullScreen() {
        guard let panel else { return }
        model.activity.setFullScreen(panel.isVisible && !panel.isOnActiveSpace)
    }

    // MARK: Placement

    private var currentDisplay: PetDisplay? { DesktopPetGeometry.display(for: placement, in: displays()) }

    private func place(_ panel: DesktopPetPanel) {
        guard let display = currentDisplay else { return }
        let origin = DesktopPetGeometry.origin(for: placement ?? DesktopPetGeometry.defaultPlacement, size: panel.frame.size, on: display)
        panel.setFrameOrigin(origin)
    }

    private func save() {
        guard let panel, let display = currentDisplay else { return }
        let next = DesktopPetGeometry.placement(for: panel.frame.origin, size: panel.frame.size, on: display)
        guard next != placement else { return }
        placement = next
        do { try store?.save(next) } catch { log.error("desktop pet: couldn't save its place (\(String(describing: error), privacy: .public))") }
    }

    // MARK: Moving

    /// A walk or a run the model started: a target along the floor, the
    /// window moved there frame by frame. Already on the way at this pace:
    /// nothing changes; a walk turning into a run restarts from where it is.
    private func walk(running: Bool) {
        guard let panel, let mover, let display = currentDisplay, panel.isVisible else { return model.finishMoving() }
        if mover.isMoving, mover.isRunning == running { return }
        let from = panel.frame.origin
        let to = DesktopPetGeometry.moveTarget(from: from, size: panel.frame.size, in: display.visible, running: running, random: random)
        guard abs(to.x - from.x) >= 20 else { return model.finishMoving() }  // no room to go anywhere
        rig.setFacing(to.x < from.x ? .left : .right)
        mover.move(from: from, to: to, running: running, step: { [weak panel] point in
            panel?.setFrameOrigin(point)
        }, arrived: { [weak self] in
            self?.save()
            self?.model.finishMoving()
        })
    }

    /// Stops a move where it is (and remembers the spot).
    private func stopMoving() {
        guard let mover, mover.isMoving else { return }
        mover.cancel()
        save()
    }

    // MARK: Dragging

    private func dragBegan() -> Bool {
        guard let panel, model.beginDrag() else { return false }
        mover?.cancel()
        dragStart = panel.frame.origin
        return true
    }

    private func dragMoved(_ delta: CGSize) {
        guard let panel, let dragStart, let display = currentDisplay else { return }
        let origin = CGPoint(x: dragStart.x + delta.width, y: dragStart.y + delta.height)
        panel.setFrameOrigin(DesktopPetGeometry.clamp(origin, size: panel.frame.size, in: display.visible))
    }

    private func dragEnded() {
        guard dragStart != nil else { return }
        dragStart = nil
        model.endDrag()
        save()
    }
}
