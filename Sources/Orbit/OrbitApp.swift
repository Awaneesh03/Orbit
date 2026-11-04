import SwiftUI
import os

let log = Logger(subsystem: "com.awaneeshgupta.orbit", category: "app")

// Accessory app: LSUIElement in Info.plist keeps Orbit out of the Dock and
// leaves the native menu bar alone. Running the raw binary (`swift run`)
// bypasses Info.plist, so always launch through scripts/run.sh.
@main
struct OrbitApp: App {
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        // Required by SwiftUI; never shown. Orbit's own Settings window is
        // `SettingsWindowController`, and ⌘, is routed to it at launch.
        Settings { EmptyView() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let interaction = NotchInteraction()
    private lazy var dashboard = DashboardModel(
        registry: .builtIn(
            dataDirectory: OrbitStorage.directory,
            projectsRoot: FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer"),
            perform: { [weak self] action in
                if action == .settings { self?.showOrbitSettings(nil) } else { action.perform() }
                self?.interaction.close()
            },
            didLaunch: { [interaction] in interaction.close() }),
        store: WidgetLayoutStore(defaults: .standard))
    private let preferences = PreferencesModel(
        file: JSONFile(url: OrbitStorage.directory.appending(path: "preferences.json")))
    /// briefing.json: read at launch (reading never writes); changed only from Settings (3.8-3).
    private let briefing = BriefingPreferencesModel(file: BriefingPreferencesModel.file(in: OrbitStorage.directory))
    private lazy var settings = SettingsWindowController(model: SettingsModel(
        dashboard: dashboard, preferences: preferences, briefing: briefing, dataDirectory: OrbitStorage.directory))
    private var panel: NotchPanel?
    private let island = MusicIsland()
    private var islandPanel: MusicIslandPanel?
    private let systemVolume = SystemVolume()
    private let overlay = NotchOverlayCoordinator(hud: VolumeHUD())
    private var hudPanel: SystemHUDPanel?
    private var sonicPulse: SonicPulseController?
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        preferences.onChange = { [weak self] in self?.apply($0) }
        apply(preferences.value)
        dashboard.briefing = briefing.value
        briefing.onChange = { [weak self] in self?.dashboard.briefing = $0 }  // Settings › Widgets: the tab follows at once
        routeSettingsShortcut()
        NotificationCenter.default.addObserver(forName: SettingsWindowController.showRequest, object: nil, queue: .main) { [weak self] note in
            let section = (note.object as? String).flatMap(SettingsSection.init(rawValue:))
            MainActor.assumeIsolated {
                self?.interaction.close()
                self?.settings.show(section: section)
            }
        }

        let panel = NotchPanel(interaction: interaction, model: dashboard)
        panel.onScreenshotDrop = { [weak self] items in self?.receiveScreenshots(items) }
        panel.onOpenSettings = { [weak self] in self?.showOrbitSettings(nil) }
        panel.orderFrontRegardless()
        self.panel = panel
        startMusicIsland()
        startSonicPulse()
        // Recently Deleted keeps items for 30 days; writes only if something expired.
        if let vault = dashboard.registry.widget("vault") as? VaultWidget {
            if case let purged = vault.purgeExpired(), purged > 0 { log.notice("vault: purged \(purged) expired item(s)") }
            Task {
                let start = ContinuousClock.now
                let filled = await vault.backfillHashes()
                log.notice("vault: hash backfill filled \(filled) item(s) in \(start.duration(to: .now), privacy: .public)")
            }
        }
        // Expired drag-out copies (10 min) in Orbit's own temporary folder only.
        Task.detached(priority: .utility) {
            let start = ContinuousClock.now
            let removed = await ScreenshotVault.cleanUpExpiredExports()
            log.notice("drag copies: removed \(removed) expired in \(start.duration(to: .now), privacy: .public)")
        }

        NotificationCenter.default.addObserver(
            self, selector: #selector(screensChanged),
            name: NSApplication.didChangeScreenParametersNotification, object: nil)
        // Close on any Space change (including entering/leaving full screen)
        // so the dashboard never follows the user to another Space.
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(spaceChanged),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil)

        // scripts/run.sh stops Orbit with SIGTERM; route it through normal
        // NSApplication termination so applicationWillTerminate runs.
        signal(SIGTERM, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        source.setEventHandler { MainActor.assumeIsolated { NSApp.terminate(nil) } }
        source.resume()
        terminationSignal = source

        #if DEBUG
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(debugCommand(_:)),
            name: .init("com.awaneeshgupta.orbit.debug"), object: nil)
        #endif
        log.notice("launched")
    }

    /// Opening Orbit again (Finder, `open`) while it runs shows Settings.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showOrbitSettings(nil)
        return false
    }

    /// Settings quick action, notch right-click menu, ⌘, and reopening.
    @objc func showOrbitSettings(_ sender: Any?) {
        interaction.close()
        settings.show()
    }

    private func apply(_ value: OrbitPreferences) {
        interaction.hideDelay = .milliseconds(Int(value.hideDelay * 1000))
        island.reduceMotion = value.reduceMotion
        overlay.hud.reduceMotion = value.reduceMotion
        setVolumeHUD(value.volumeHUD)  // at launch startSonicPulse applies it, once the panel exists
        island.autoDismiss = .milliseconds(Int(value.musicIslandSeconds * 1000))
        dashboard.preferences = value
        settings.apply(value.appearance)
    }

    /// SwiftUI's "Settings…" (⌘,) would open the empty placeholder scene.
    private func routeSettingsShortcut() {
        for item in NSApp.mainMenu?.items.flatMap({ $0.submenu?.items ?? [] }) ?? [] where item.keyEquivalent == "," {
            item.target = self
            item.action = #selector(showOrbitSettings(_:))
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        island.shutdown()
        sonicPulse?.setEnabled(false)
        log.notice("terminating")
    }

    /// A drop on the notch: import into the vault, show it, confirm.
    private func receiveScreenshots(_ items: [ScreenshotDrag.Item]) {
        guard let vault = dashboard.registry.widget("vault") as? VaultWidget else { return }
        dashboard.section = .screenshots
        vault.receive(items) { [weak self] outcome in
            log.notice("vault import: \(outcome.summary, privacy: .public)")
            self?.dashboard.show(outcome.notice, isError: outcome.isError)
        }
    }

    @objc private func screensChanged() {
        panel?.reposition()
        islandPanel?.reposition()
        hudPanel?.reposition()
    }

    @objc private func spaceChanged() {
        interaction.spaceChanged()
        island.spaceChanged()
        overlay.spaceChanged()
    }

    /// Sonic Pulse: the volume HUD in the slot below the notch, fed by the
    /// default output device's volume and mute (listeners, no polling). It
    /// covers a compact island for a moment and never the dashboard or the
    /// expanded player (`NotchOverlayCoordinator`).
    private func startSonicPulse() {
        let hudPanel = SystemHUDPanel(coordinator: overlay)
        hudPanel.onCoverIsland = { [weak self] in self?.islandPanel?.setCovered($0) }
        self.hudPanel = hudPanel
        sonicPulse = SonicPulseController(volume: systemVolume, overlay: overlay, panel: hudPanel) { [island, interaction] in
            (island.phase, interaction.isOpen)
        }
        setVolumeHUD(preferences.value.volumeHUD)
    }

    /// Settings › General › Show Volume HUD, at once (`SonicPulseController`).
    private func setVolumeHUD(_ enabled: Bool) {
        guard let sonicPulse, enabled != sonicPulse.isEnabled else { return }
        sonicPulse.setEnabled(enabled)
        log.notice("volume hud: \(enabled ? "on" : "off", privacy: .public)")
    }

    /// The music island: its own panel, fed by the Now Playing coordinator
    /// (which runs whether or not the widget is on the Overview), the setting,
    /// and whether the dashboard is open. Commands go the widget's way.
    private func startMusicIsland() {
        guard let coordinator = (dashboard.registry.widget("nowPlaying") as? NowPlayingWidget)?.coordinator else { return }
        islandPanel = MusicIslandPanel(island: island) { command, item in
            Task {
                do {
                    try await coordinator.perform(command, on: item)
                } catch {
                    log.error("music island: \(String(describing: error), privacy: .public)")
                }
            }
        }
        island.follow { [preferences, interaction] in
            (coordinator.current, preferences.value.musicIsland, interaction.isOpen)
        }
    }

    #if DEBUG
    private func petPreviewCommand(_ parts: [String]) {
        switch (parts.first, parts.count) {
        case ("preview", _):
            PetPreview.shared?.close()
            let preview = PetPreview(single: parts.last == "single")
            PetPreview.shared = preview
            preview.show()
            log.notice("pet preview window=\(preview.window.windowNumber, privacy: .public)")
        case ("state", 2): if let state = PetModel.State(rawValue: parts[1]) { PetPreview.shared?.select(state) }
        case ("reducemotion", 2): PetPreview.shared?.setReduceMotion(parts[1] == "on")
        case ("fidget", 1): PetPreview.shared?.fidget()
        case ("react", 1): PetPreview.shared?.react()
        case ("face", 2): PetPreview.shared?.setFacing(parts[1] == "left" ? .left : .right)
        case ("close", 1):
            PetPreview.shared?.close()
            PetPreview.shared = nil
        default: break
        }
    }

    /// Drives the same paths as the pointer so the UI can be verified from a
    /// script, e.g. `hover`, `leave`, `close`. Debug builds only.
    @objc private func debugCommand(_ note: Notification) {
        switch note.object as? String {
        case "hover": interaction.pointerEntered()
        case "leave": interaction.pointerExited()
        case "close": interaction.close()
        case "state":
            let widgets = dashboard.overviewWidgets
                .map { "\($0.id)\($0.presentation == .expanded ? "+" : ""):\($0.widget.state)" }
                .joined(separator: ",")
            let battery = dashboard.registry.widget("battery") as? BatteryWidget
            let batteryText = "\(battery?.status.map { "\($0.percent)%" } ?? "-") observing=\(battery?.isObserving ?? false)"
            log.notice("""
                state phase=\(String(describing: self.interaction.phase), privacy: .public) \
                section=\(self.dashboard.section.rawValue, privacy: .public) \
                widgets=\(widgets, privacy: .public) \
                battery=\(batteryText, privacy: .public) \
                artwork=\(ArtworkLoader.shared.cachedCount, privacy: .public)cached/\(ArtworkLoader.shared.failedCount, privacy: .public)failed/\(ArtworkLoader.shared.requests, privacy: .public)requests \
                island=\(String(describing: self.island.phase), privacy: .public)/\(self.island.item.map { String(describing: $0.state) } ?? "-", privacy: .public)/\(NSStringFromRect(self.islandPanel?.frame ?? .zero), privacy: .public)/visible=\(self.islandPanel?.isVisible ?? false, privacy: .public)/key=\(self.islandPanel?.isKeyWindow ?? false, privacy: .public) \
                hud=\(String(describing: self.overlay.overlay), privacy: .public)/\(String(describing: self.overlay.hud.phase), privacy: .public)/\(self.overlay.hud.shown.map { "\($0.name ?? "-"):\($0.volume.map { String(format: "%.2f", $0) } ?? "nil"):\($0.isMuted.map(String.init) ?? "nil")" } ?? "-", privacy: .public)/pulse=\(self.overlay.hud.pulse, privacy: .public)/visible=\(self.hudPanel?.isVisible ?? false, privacy: .public)/covered=\(self.islandPanel?.isCovered ?? false, privacy: .public)/listeners=\(self.systemVolume.listenerCount, privacy: .public) \
                frame=\(NSStringFromRect(self.panel?.frame ?? .zero), privacy: .public) \
                key=\(self.panel?.isKeyWindow ?? false, privacy: .public) \
                front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-", privacy: .public) \
                pointer=\(NSStringFromPoint(NSEvent.mouseLocation), privacy: .public) \
                settings=\(self.settings.window?.isVisible ?? false, privacy: .public)/\(self.settings.model.section.rawValue, privacy: .public) \
                settingsFrame=\(NSStringFromRect(self.settings.window?.frame ?? .zero), privacy: .public) \
                cmdComma=\(NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.keyEquivalent == "," }?.action.map(NSStringFromSelector) ?? "-", privacy: .public)
                """)
        case "settings": showOrbitSettings(nil)
        case "closesettings": settings.window?.performClose(nil)
        case "menusettings":  // the right-click menu item, without a click
            if let menu = panel?.contentView?.menu, let index = menu.items.firstIndex(where: { $0.title == "Orbit Settings…" }) {
                menu.performActionForItem(at: index)
            }
        default:
            // Layout commands (also in Settings › Widgets), and settings:<section>:
            // enable:<id> disable:<id> expand:<id> compact:<id> move:<id>:<index> reset section:<name>
            let parts = (note.object as? String ?? "").split(separator: ":").map(String.init)
            // island:tap / island:collapse: the island's click and an outside click.
            if parts == ["island", "tap"] { return island.tap() }
            if parts == ["island", "collapse"] { islandPanel?.outsideClick(); return }
            // briefing:on|off: show or hide the Briefing tab, in memory only (briefing.json untouched).
            if parts.first == "briefing", parts.count == 2 { dashboard.briefing.dailyBriefingEnabled = parts[1] == "on"; return }
            // reducemotion:on|off: the island's and the HUD's Reduce Motion, in memory only (not saved).
            if parts.first == "reducemotion", parts.count == 2 { island.reduceMotion = parts[1] == "on"; overlay.hud.reduceMotion = island.reduceMotion; return }
            // volume:<0…1> | volume:mute | volume:real: a simulated reading for the HUD
            // (the real volume is never changed); volumehud:on|off: the setting, in memory only.
            if parts.first == "volume", parts.count == 2 {
                switch parts[1] {
                case "real": systemVolume.debugReread()
                case "mute": systemVolume.debugSimulate(volume: 0.18, isMuted: true)
                case "none": systemVolume.debugSimulate(volume: nil, isMuted: nil)
                default: if let level = Float(parts[1]) { systemVolume.debugSimulate(volume: level, isMuted: false) }
                }
                return
            }
            if parts.first == "volumehud", parts.count == 2 { setVolumeHUD(parts[1] == "on"); return }
            // The cat rig's preview window: pet:preview[:single], pet:state:<idle|playful|…>,
            // pet:reducemotion:on|off, pet:fidget, pet:react, pet:face:left|right, pet:close.
            if parts.first == "pet" { return petPreviewCommand(Array(parts.dropFirst())) }
            switch (parts.first, parts.count) {
            case ("enable", 2): dashboard.setEnabled(parts[1], true)
            case ("disable", 2): dashboard.setEnabled(parts[1], false)
            case ("expand", 2): dashboard.setPresentation(parts[1], .expanded)
            case ("compact", 2): dashboard.setPresentation(parts[1], .compact)
            case ("move", 3): if let index = Int(parts[2]) { dashboard.move(parts[1], to: index) }
            case ("reset", 1): dashboard.resetLayout()
            case ("settings", 2): if let section = SettingsSection(rawValue: parts[1]) { settings.show(section: section) }
            case ("section", 2): if let section = DashboardSection(rawValue: parts[1]) { dashboard.section = section }
            // The Now Playing buttons' own command, on the item on screen:
            // playback:toggle, playback:skip:<seconds> (e.g. playback:skip:-10).
            case ("playback", _):
                guard let widget = dashboard.registry.widget("nowPlaying") as? NowPlayingWidget,
                      let item = widget.coordinator.current else { break }
                let command: PlaybackCommand? = switch (parts.count, parts.dropFirst().first) {
                case (2, "toggle"): .togglePlayPause
                case (3, "skip"): Double(parts[2]).map { .skip($0) }
                default: nil
                }
                guard let command else { break }
                Task {
                    do {
                        try await widget.coordinator.perform(command, on: item)
                        log.notice("debug playback: sent \(String(describing: command), privacy: .public)")
                    } catch {
                        log.notice("debug playback: refused (\(String(describing: error), privacy: .public))")
                    }
                }
            // Drag stand-ins for scripted UI checks (real drags go through NotchPanel).
            case ("dragenter", 1):
                dashboard.isDropTargeted = true
                interaction.dragEntered()
            case ("dragexit", 1):
                dashboard.isDropTargeted = false
                interaction.dragEnded(dropped: false)
            case ("vaultdelete", 2):
                if let vault = dashboard.registry.widget("vault") as? VaultWidget,
                   let item = vault.items.first(where: { $0.id.uuidString == parts[1] }) { vault.delete(item) }
            // UI only: opens or closes the task editor (an unchanged title writes nothing).
            case ("taskedit", 2):
                guard let tasks = dashboard.registry.widget("tasks") as? TasksWidget else { break }
                if parts[1] == "done" { tasks.commitEdit() } else if let first = tasks.plan.active.first { tasks.beginEditing(first) }
            case ("vaultrestore", 2):
                if let vault = dashboard.registry.widget("vault") as? VaultWidget,
                   let item = vault.deletedItems.first(where: { $0.id.uuidString == parts[1] }) { vault.restore(item) }
            case ("vaultpurge", 2):  // permanent: only items already in Recently Deleted
                if let vault = dashboard.registry.widget("vault") as? VaultWidget,
                   let item = vault.deletedItems.first(where: { $0.id.uuidString == parts[1] }) {
                    vault.requestPurge(item)
                    vault.confirmPurge()
                }
            // UI only, nothing is written: vault:deleted, vault:inbox, vault:clear (asks), vault:cancel
            case ("vault", 2):
                guard let vault = dashboard.registry.widget("vault") as? VaultWidget else { break }
                switch parts[1] {
                case "deleted": vault.showsDeleted = true
                case "inbox": vault.showsDeleted = false
                case "clear": vault.requestClearInbox()
                case "cancel": vault.cancelPending()
                default: break
                }
            case ("dropfile", let count) where count >= 2:
                dashboard.isDropTargeted = false
                interaction.dragEnded(dropped: true)
                receiveScreenshots([.file(URL(filePath: parts.dropFirst().joined(separator: ":")))])
            default: break
            }
        }
    }
    #endif
}
