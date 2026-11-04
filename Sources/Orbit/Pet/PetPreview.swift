#if DEBUG
import AppKit

// Debug builds only (Stage 5.3): a window for looking at the cat rig. It
// drives the rig directly with a state picker (the preview has no
// PetModel: nothing here is a second state machine). Opened from the debug
// hook (`pet:preview`); never part of the production app.

@MainActor
final class PetPreview: NSObject {
    static var shared: PetPreview?

    let window: NSWindow
    private(set) var rigs: [PetRig] = []
    private let picker = NSSegmentedControl()
    private let reduceBox = NSButton(checkboxWithTitle: "Reduce Motion", target: nil, action: nil)
    private var fidgets = 0
    private var facing = PetFacing.right
    static let states: [PetModel.State] = [.idle, .playful, .walking, .running, .sleeping, .dragged]

    /// `single`: one 96 pt cat (for measuring); otherwise every size on dark
    /// and light backgrounds plus a large one for detail.
    init(single: Bool) {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: single ? 220 : 760, height: single ? 180 : 380),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        super.init()
        window.title = "Orbit Pet Preview (debug)"
        window.isReleasedWhenClosed = false
        window.contentView = single ? singleContent() : fullContent()
        select(.idle)
    }

    func show() {
        window.center()
        window.orderFrontRegardless()  // without activating Orbit or taking focus
    }

    func close() {
        for rig in rigs { rig.apply(.hidden, reduceMotion: rig.reduceMotion) }
        window.orderOut(nil)
    }

    func select(_ state: PetModel.State) {
        if let index = Self.states.firstIndex(of: state) { picker.selectedSegment = index }
        for rig in rigs {
            rig.apply(state, reduceMotion: reduceBox.state == .on)
            if state == .playful { rig.playReaction() }
        }
    }

    func setReduceMotion(_ on: Bool) {
        reduceBox.state = on ? .on : .off
        let state = rigs.first?.state ?? .idle
        for rig in rigs { rig.apply(state, reduceMotion: on) }
    }

    func fidget() {
        fidgets += 1
        for rig in rigs { rig.playFidget(fidgets) }
    }

    func react() {
        for rig in rigs { rig.playReaction() }
    }

    func setFacing(_ newFacing: PetFacing) {
        facing = newFacing
        for rig in rigs { rig.setFacing(newFacing) }
    }

    // MARK: Layout

    private func controls() -> NSView {
        picker.segmentCount = Self.states.count
        for (index, state) in Self.states.enumerated() {
            picker.setLabel(state.rawValue.capitalized, forSegment: index)
        }
        picker.trackingMode = .selectOne
        picker.target = self
        picker.action = #selector(picked)
        reduceBox.target = self
        reduceBox.action = #selector(reduceToggled)
        let fidgetButton = NSButton(title: "Fidget", target: self, action: #selector(fidgetPressed))
        let reactButton = NSButton(title: "Click", target: self, action: #selector(reactPressed))
        let faceButton = NSButton(title: "Turn", target: self, action: #selector(turnPressed))
        let row = NSStackView(views: [picker, reduceBox, fidgetButton, reactButton, faceButton])
        row.spacing = 10
        return row
    }

    private func fullContent() -> NSView {
        let sizes: [CGFloat] = [28, 48, 72, 120]
        func strip(_ background: NSColor) -> NSView {
            let views = sizes.map { size -> NSView in
                let rig = PetRig(size: size)
                rigs.append(rig)
                return PetRigView(rig: rig)
            }
            let row = NSStackView(views: views)
            row.spacing = 24
            row.alignment = .bottom
            row.edgeInsets = NSEdgeInsets(top: 12, left: 16, bottom: 12, right: 16)
            row.wantsLayer = true
            row.layer?.backgroundColor = background.cgColor
            row.layer?.cornerRadius = 10
            return row
        }
        let big = PetRig(size: 300)
        rigs.append(big)
        let detail = NSStackView(views: [PetRigView(rig: big)])
        detail.edgeInsets = NSEdgeInsets(top: 10, left: 10, bottom: 10, right: 10)
        detail.wantsLayer = true
        detail.layer?.backgroundColor = NSColor(white: 0.32, alpha: 1).cgColor
        detail.layer?.cornerRadius = 10
        let strips = NSStackView(views: [strip(NSColor(white: 0.11, alpha: 1)), strip(NSColor(red: 0.91, green: 0.9, blue: 0.87, alpha: 1))])
        strips.orientation = .vertical
        strips.spacing = 12
        let body = NSStackView(views: [strips, detail])
        body.spacing = 12
        body.alignment = .top
        let stack = NSStackView(views: [controls(), body])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        return stack
    }

    private func singleContent() -> NSView {
        let rig = PetRig(size: 96)
        rigs.append(rig)
        let view = NSStackView(views: [PetRigView(rig: rig)])
        view.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor(white: 0.11, alpha: 1).cgColor
        return view
    }

    @objc private func picked() { select(Self.states[max(0, picker.selectedSegment)]) }
    @objc private func reduceToggled() { setReduceMotion(reduceBox.state == .on) }
    @objc private func fidgetPressed() { fidget() }
    @objc private func reactPressed() { react() }
    @objc private func turnPressed() { setFacing(facing == .right ? .left : .right) }
}
#endif
