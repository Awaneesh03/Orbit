import AppKit
import SwiftUI

/// Pure geometry so positioning is testable without a window server.
enum NotchGeometry {
    static let dashboardSize = CGSize(width: 740, height: 420)
    static let fallbackTriggerWidth: CGFloat = 200
    static let fallbackTriggerMinHeight: CGFloat = 24

    /// The camera housing (between the two auxiliary top areas), or a top-centre
    /// strip the height of the menu bar on screens without a notch.
    static func triggerRect(screen: CGRect, visible: CGRect, left: CGRect?, right: CGRect?) -> CGRect {
        if let left, let right, right.minX > left.maxX {
            return CGRect(x: left.maxX, y: screen.maxY - left.height,
                          width: right.minX - left.maxX, height: left.height)
        }
        let height = max(screen.maxY - visible.maxY, fallbackTriggerMinHeight)
        return CGRect(x: screen.midX - fallbackTriggerWidth / 2, y: screen.maxY - height,
                      width: fallbackTriggerWidth, height: height)
    }

    /// Where an approaching screenshot drag opens the drop target: just below the
    /// camera housing, clear of the top edge (where macOS opens Mission Control
    /// for screenshot-thumbnail drags, with or without Orbit).
    static let dropZoneTopGap: CGFloat = 32
    static let dropZoneDepth: CGFloat = 80
    static let dropZoneWidth: CGFloat = 420

    static func dropZone(trigger: CGRect, screen: CGRect) -> CGRect {
        let x = min(max(trigger.midX - dropZoneWidth / 2, screen.minX), screen.maxX - dropZoneWidth)
        return CGRect(x: x, y: screen.maxY - dropZoneTopGap - dropZoneDepth,
                      width: dropZoneWidth, height: dropZoneDepth)
    }

    /// Hangs from the top edge, centred on the trigger, kept on screen. Always
    /// contains the trigger, so notch → dashboard never leaves the window.
    static func dashboardRect(trigger: CGRect, screen: CGRect) -> CGRect {
        let size = dashboardSize
        let x = min(max(trigger.midX - size.width / 2, screen.minX), screen.maxX - size.width)
        return CGRect(x: x, y: screen.maxY - size.height, width: size.width, height: size.height)
    }
}

/// Receives screenshot drags for the notch window.
@MainActor
protocol NotchDropHandler: AnyObject {
    func dragEntered(_ info: any NSDraggingInfo) -> NSDragOperation
    func dragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation
    func dragExited()
    func performDrop(_ info: any NSDraggingInfo) -> Bool
    func dragEnded()
}

/// Takes the first click in a non-key panel, shows its AppKit menu on
/// right-click regardless of key status, and is the window's drag
/// destination (idle trigger and open dashboard alike).
final class FirstMouseHostingView<Content: View>: NSHostingView<Content> {
    weak var dropHandler: (any NotchDropHandler)?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropHandler?.dragEntered(sender) ?? []
    }

    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation {
        dropHandler?.dragUpdated(sender) ?? []
    }

    override func draggingExited(_ sender: (any NSDraggingInfo)?) { dropHandler?.dragExited() }

    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { dropHandler != nil }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        dropHandler?.performDrop(sender) ?? false
    }

    override func draggingEnded(_ sender: any NSDraggingInfo) { dropHandler?.dragEnded() }

    override func rightMouseDown(with event: NSEvent) {
        guard let menu else { return super.rightMouseDown(with: event) }
        NSMenu.popUpContextMenu(menu, with: event, for: self)
    }
}

/// One borderless, non-activating panel: an invisible hover trigger over the
/// notch that grows into the dashboard while open.
final class NotchPanel: NSPanel {
    private let interaction: NotchInteraction
    private let model: DashboardModel
    private let host: FirstMouseHostingView<DashboardView>
    private var triggerFrame = CGRect.zero
    private var dashboardFrame = CGRect.zero
    private var dropZone = CGRect.zero
    private var approachWatcher: DragApproachWatcher?
    private var outsideClickMonitor: Any?
    /// Called with what was dropped on the notch or dashboard.
    var onScreenshotDrop: (([ScreenshotDrag.Item]) -> Void)?
    var onOpenSettings: (() -> Void)?

    init(interaction: NotchInteraction, model: DashboardModel) {
        self.interaction = interaction
        self.model = model
        host = FirstMouseHostingView(rootView: DashboardView(interaction: interaction, model: model, topInset: 0))
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        level = .statusBar  // Above the menu bar (.mainMenu) so the dashboard can hang from the notch.
        // Every Space, including full-screen ones (.fullScreenAuxiliary). On a
        // notched display the trigger sits in the black strip above full-screen
        // content, so it never covers the app.
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        hidesOnDeactivate = false  // Orbit is an accessory app and is never "active".
        isMovable = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = false  // Explicit: receive the pointer over fully transparent pixels.
        host.sizingOptions = []  // The panel sizes the view, not the other way round.
        host.menu = contextMenu()
        host.addTrackingArea(NSTrackingArea(
            rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
        contentView = host
        // Dark by design (Settings › Appearance styles Orbit's windows, not the
        // notch): native glass must not turn light under white text.
        host.appearance = NSAppearance(named: .darkAqua)
        // Native drag destination: screenshot thumbnails, image files, image data, file promises.
        host.registerForDraggedTypes(ScreenshotDrag.draggedTypes)
        host.dropHandler = self
        interaction.onOpenChange = { [weak self] open in self?.openChanged(open) }
        // Editing a text field (its field editor is first responder) keeps it open.
        interaction.holdsOpen = { [weak self] in self?.firstResponder is NSText }
        reposition()
        approachWatcher = DragApproachWatcher(
            zone: { [weak self] in self?.dropZone ?? .zero },
            onApproach: { [weak self] in self?.dragApproached() },
            onRelease: { [weak self] in self?.dragEnded() })
    }

    /// An image drag reached the zone below the notch: open the drop target so
    /// the user can drop without touching the top edge.
    private func dragApproached() {
        guard !model.isDropTargeted else { return }
        log.notice("drag approached below the notch")
        model.isDropTargeted = true
        interaction.dragEntered()
    }

    // Key only while open, and only via a click inside: hovering never takes
    // keyboard focus from the frontmost app.
    override var canBecomeKey: Bool { interaction.isOpen }
    override var canBecomeMain: Bool { false }

    override func mouseEntered(with event: NSEvent) {
        log.debug("pointer entered at \(NSStringFromPoint(NSEvent.mouseLocation), privacy: .public)")
        interaction.pointerEntered()
    }

    override func mouseExited(with event: NSEvent) {
        log.debug("pointer exited at \(NSStringFromPoint(NSEvent.mouseLocation), privacy: .public)")
        guard NSEvent.pressedMouseButtons & 1 != 0 else { return interaction.pointerExited() }
        // Button held: a screenshot being dragged out of the Vault. Closing now
        // would pull the drag's source away; wait for the release instead.
        Task { [weak self] in
            while NSEvent.pressedMouseButtons & 1 != 0 { try? await Task.sleep(for: .milliseconds(100)) }
            guard let self, !self.frame.contains(NSEvent.mouseLocation) else { return }
            self.interaction.pointerExited()
        }
    }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown {
            if event.keyCode == 53 { return interaction.close() }  // Escape
            if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
               event.charactersIgnoringModifiers == "q" {
                return NSApp.terminate(nil)
            }
        }
        super.sendEvent(event)
    }

    // ponytail: primary display only; one panel per NSScreen when multi-monitor matters.
    func reposition() {
        guard let screen = NSScreen.screens.first else { return }
        triggerFrame = NotchGeometry.triggerRect(
            screen: screen.frame, visible: screen.visibleFrame,
            left: screen.auxiliaryTopLeftArea, right: screen.auxiliaryTopRightArea)
        dashboardFrame = NotchGeometry.dashboardRect(trigger: triggerFrame, screen: screen.frame)
        dropZone = NotchGeometry.dropZone(trigger: triggerFrame, screen: screen.frame)
        host.rootView = DashboardView(interaction: interaction, model: model, topInset: triggerFrame.height)
        setFrame(interaction.isOpen ? dashboardFrame : triggerFrame, display: true)
    }

    private func openChanged(_ open: Bool) {
        log.notice("dashboard \(open ? "open" : "closed", privacy: .public)")
        if open {
            setFrame(dashboardFrame, display: true)
            outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(
                matching: [.leftMouseDown, .rightMouseDown]
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.interaction.close() }
            }
            return
        }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        outsideClickMonitor = nil
        // Let the close animation play, then shrink back to the trigger.
        // orderOut hands keyboard focus back to the frontmost app.
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))  // spring is 0.3s
            guard let self, !self.interaction.isOpen else { return }
            self.orderOut(nil)
            self.setFrame(self.triggerFrame, display: false)
            self.orderFrontRegardless()
        }
    }

    @objc private func openSettings() { onOpenSettings?() }

    private func contextMenu() -> NSMenu {
        let menu = NSMenu()
        let settings = menu.addItem(withTitle: "Orbit Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        menu.addItem(.separator())
        let quit = menu.addItem(withTitle: "Quit Orbit",
                                action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        return menu
    }
}

/// Notices an image drag approaching the notch from below. Wakes only on a
/// mouse-button press (global mouse monitor, no permission) and polls every
/// 50 ms only while that button stays down, reading the drag pasteboard's
/// types (not the general clipboard, never content) and the pointer location.
@MainActor
final class DragApproachWatcher {
    private var monitor: Any?
    private var task: Task<Void, Never>?
    private let zone: () -> CGRect
    private let onApproach: () -> Void
    private let onRelease: () -> Void

    init(zone: @escaping () -> CGRect, onApproach: @escaping () -> Void, onRelease: @escaping () -> Void) {
        self.zone = zone
        self.onApproach = onApproach
        self.onRelease = onRelease
        monitor = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.pressBegan() }
        }
    }

    private func pressBegan() {
        guard task == nil else { return }
        let pasteboard = NSPasteboard(name: .drag)
        let countAtPress = pasteboard.changeCount
        task = Task { [weak self] in
            var approached = false
            while NSEvent.pressedMouseButtons & 1 != 0, !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !approached, let self, pasteboard.changeCount != countAtPress,
                      self.zone().contains(NSEvent.mouseLocation),
                      ScreenshotDrag.containsImage(pasteboard)
                else { continue }
                approached = true
                self.onApproach()
            }
            if approached {
                // Let a drop on the dashboard finish first; this only cleans up
                // a drag that was released somewhere else.
                try? await Task.sleep(for: .milliseconds(300))
                self?.onRelease()
            }
            self?.task = nil
        }
    }
}

extension NotchPanel: NotchDropHandler {
    /// Accepts only drags that carry an image; anything else is ignored and
    /// doesn't open the dashboard. Never makes the panel key.
    func dragEntered(_ info: any NSDraggingInfo) -> NSDragOperation {
        let pasteboard = info.draggingPasteboard
        // A drag that starts in Orbit (out of the Vault) is never re-imported.
        let accepted = info.draggingSource == nil && ScreenshotDrag.containsImage(pasteboard)
        log.notice("""
            drag entered (accepted: \(accepted, privacy: .public)); \
            types: \(ScreenshotDrag.describe(pasteboard), privacy: .public)
            """)
        guard accepted else { return [] }
        model.isDropTargeted = true
        interaction.dragEntered()
        return .copy
    }

    func dragUpdated(_ info: any NSDraggingInfo) -> NSDragOperation {
        model.isDropTargeted ? .copy : []
    }

    func dragExited() { endDropTargeting(dropped: false) }

    func performDrop(_ info: any NSDraggingInfo) -> Bool {
        let items = ScreenshotDrag.items(from: info.draggingPasteboard)
        log.notice("drop: \(items.map(\.kind).joined(separator: ", "), privacy: .public)")
        endDropTargeting(dropped: !items.isEmpty)
        guard !items.isEmpty else { return false }
        onScreenshotDrop?(items)
        return true
    }

    /// Also covers a drag cancelled over the window; a no-op after a drop.
    func dragEnded() { endDropTargeting(dropped: false) }

    private func endDropTargeting(dropped: Bool) {
        guard model.isDropTargeted else { return }
        model.isDropTargeted = false
        interaction.dragEnded(dropped: dropped)
    }
}
