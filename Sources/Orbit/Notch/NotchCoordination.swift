// Who uses the notch, as one table (docs/AI_HUB_SPEC.md §21, decision A).
//
// Owner: Orbit, unless Coucou runs — then Coucou's island sits above Orbit's
// panels and answers Claude there, so Orbit yields everything that would
// duplicate it or be covered by it (§22: Orbit can't see Coucou's island
// state without polling another app's windows, so "never overlap" means
// "step aside while it runs"). Surfaces: Orbit's own, highest priority first;
// the first that wants the notch and may show holds it. The first four rows
// are NotchOverlayCoordinator's order, unchanged (dashboard, expanded player,
// volume HUD, compact island), then the agent alert, the eye-break reminder,
// the Bluetooth device notice (Milestone 20), the status pill (Milestone 15: meetings and agents that need you, on
// displays without wings), and last the Notch Companion. All of them share
// one slot below the menu bar or notch, so at most one shows there.
// Only the dashboard stays while Coucou runs, opened from ⌃⌥⌘O rather than
// the notch. Agent monitoring and history don't go through here.

enum NotchCoordination {
    enum Owner: String, Sendable {
        /// `off`: Settings › Notch › Use the notch is off (Milestone 21). Orbit leaves the notch like it does
        /// for Coucou; the dashboard still opens from its shortcut and the launcher.
        case orbit, coucou, off
        init(coucouRunning: Bool, enabled: Bool = true) { self = !enabled ? .off : coucouRunning ? .coucou : .orbit }
    }

    enum Surface: String, CaseIterable, Sendable {
        case dashboard, expandedMusic, volumeHUD, brightnessHUD, compactMusic, agentAlert, eyeBreak, deviceNotice, statusPill, companion
    }

    struct Inputs: Equatable, Sendable {
        var owner = Owner.orbit
        var dashboardOpen = false
        var island = MusicIsland.Phase.hidden
        var volumeHUD = false
        var brightnessHUD = false
        /// An agent alert is waiting to be seen.
        var alert = false
        /// The eye-break reminder is resting (its pill is up).
        var eyeBreak = false
        /// A Bluetooth device just connected or disconnected (Milestone 20, a 3 s notice).
        var deviceNotice = false
        /// The status pill has something to show.
        var statusPill = false
        /// The Notch Companion wants to show (Orbit Pet; no window yet).
        var companion = false
    }

    struct Rule: Sendable {
        let surface: Surface
        let yieldsToCoucou: Bool
        let wants: @Sendable (Inputs) -> Bool
    }

    /// Highest priority first.
    static let table: [Rule] = [
        Rule(surface: .dashboard, yieldsToCoucou: false) { $0.dashboardOpen },
        Rule(surface: .expandedMusic, yieldsToCoucou: true) { $0.island == .expanded },
        Rule(surface: .volumeHUD, yieldsToCoucou: true) { $0.volumeHUD },
        Rule(surface: .brightnessHUD, yieldsToCoucou: true) { $0.brightnessHUD },
        Rule(surface: .compactMusic, yieldsToCoucou: true) { $0.island == .compact },
        Rule(surface: .agentAlert, yieldsToCoucou: true) { $0.alert },
        Rule(surface: .eyeBreak, yieldsToCoucou: true) { $0.eyeBreak },
        Rule(surface: .deviceNotice, yieldsToCoucou: true) { $0.deviceNotice },
        Rule(surface: .statusPill, yieldsToCoucou: true) { $0.statusPill },
        Rule(surface: .companion, yieldsToCoucou: true) { $0.companion },
    ]

    /// Whether `surface` may show at all while `owner` has the notch.
    static func permits(_ surface: Surface, owner: Owner) -> Bool {
        owner == .orbit || !(table.first { $0.surface == surface }?.yieldsToCoucou ?? false)
    }

    /// The surface that holds the notch: the first that wants it and is permitted.
    static func holder(_ inputs: Inputs) -> Surface? {
        table.first { $0.wants(inputs) && permits($0.surface, owner: inputs.owner) }?.surface
    }
}
