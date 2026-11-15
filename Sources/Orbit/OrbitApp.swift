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
        dashboard: dashboard, preferences: preferences, briefing: briefing, dataDirectory: OrbitStorage.directory, aiHub: aiHub))
    /// The AI Hub (docs/AI_HUB_SPEC.md): nothing runs until Settings › AI Hub turns it on.
    private lazy var aiHub = AIHubService(paths: .standard)
    private var panel: NotchPanel?
    private let island = MusicIsland()
    private var islandPanel: MusicIslandPanel?
    private let systemVolume = SystemVolume()
    private let overlay = NotchOverlayCoordinator(hud: VolumeHUD())
    private var hudPanel: SystemHUDPanel?
    private var sonicPulse: SonicPulseController?
    /// Orbit Pet: off by default; Settings › Pet sets its toggles (`apply`).
    /// Debug builds can still turn it on in memory (`pet:desktop:on`) until
    /// the next preference change.
    private let petActivity = PetActivity()
    private lazy var pet = PetModel(activity: petActivity)
    private var desktopPet: DesktopPet?
    private var alertPanel: AgentAlertPanel?
    /// Coucou, the other notch companion: looked at, never touched (docs/AI_HUB_SPEC.md §21).
    private let coucou = CoucouPresence()
    /// The Notch Companion (§22): Orbit Pet below the notch, telling what the agents do.
    private lazy var companion = NotchCompanion(scheduler: TaskHUDScheduler())
    private var companionPanel: NotchCompanionPanel?
    private var companionCharacter: PetCharacter?
    private var companionGeneration = 0
    /// ⌃⌥⌘O: the dashboard without the notch (the way in while Coucou has it).
    private var hotKey: DashboardHotKey?
    private var hudCoversIsland = false
    /// The camera-flanking wings (Milestone 9; only with Compact style › Beside the camera).
    private let wings = NotchWings()
    private var wingsPanel: NotchWingsPanel?
    /// The next meeting for the wings (Milestone 14), over the Calendar widget's store and choices.
    private var meetings: MeetingWatcher?
    /// The floating status pill (Milestone 15): meetings and agents that need you where the wings can't show.
    private let contextPill = ContextPill()
    private var contextPillPanel: ContextPillPanel?
    /// Milestone 16: the Universal Launcher and Workspace Profiles.
    private let workspaces = Workspaces(file: JSONFile(url: OrbitStorage.directory.appending(path: Workspaces.fileName)))
    private lazy var launcher = LauncherModel(file: JSONFile(url: OrbitStorage.directory.appending(path: "launcher.json")))
    private var launcherPanel: LauncherPanel?
    private var launcherHotKey: GlobalHotKey?
    private var launcherShortcut: LauncherShortcut?
    /// Milestone 17: the Context Engine (reads existing models; suggests, never acts by itself).
    private let context = ContextEngine(file: JSONFile(url: OrbitStorage.directory.appending(path: "suggestions.json")))
    /// Light automations (Milestone 14): rules from Settings › General, actions from a fixed safe list.
    private lazy var automations = Automations { [weak self] action in self?.runAutomation(action) ?? false }
    private var lastMeetingTrigger: String?
    private var wingsGeneration = 0
    private var eyeBreakPanel: EyeBreakPanel?
    /// What the pet renderers last showed (diagnostics: `pet:selection`).
    private var petSelection = PetSelection.builtIn
    private var terminationSignal: DispatchSourceSignal?

    func applicationDidFinishLaunching(_ notification: Notification) {
        dashboard.aiHub = aiHub
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
        startWings()
        startEyeBreak()
        startAgentAlerts()
        connectShelf()
        startAutomations()
        startLauncher()
        startContextEngine()
        showOnboardingIfNeeded()
        startDesktopPet()
        startNotchCompanion()
        coucou.onChange = { [weak self] in self?.coucouChanged($0) }
        coucou.start()
        followAgentMood()
        let hotKey = DashboardHotKey { [weak self] in self?.panel?.toggleFromKeyboard() }
        log.notice("dashboard shortcut \(DashboardHotKey.label, privacy: .public): \(hotKey.register() ? "registered" : "unavailable (another app holds it)", privacy: .public)")
        self.hotKey = hotKey
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
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(screensChanged), name: NSWorkspace.screensDidWakeNotification, object: nil)
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
        overlay.brightness.reduceMotion = value.reduceMotion
        overlay.hud.dismissDelay = .milliseconds(Int(value.hudSeconds * 1000))
        overlay.brightness.dismissDelay = .milliseconds(Int(value.hudSeconds * 1000))
        petActivity.setReduceMotion(value.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        pet.toggles = value.petToggles  // the Desktop Pet follows the model's toggles
        let look = value.petLook.appearance
        desktopPet?.rig.setAppearance(look)
        companionCharacter?.rig.setAppearance(look)
        pet.behavior = value.petLook.behavior
        applyCharacter(value.petLook)
        aiHub.set(enabled: value.aiHub, demo: value.aiHubDemo)
        aiHub.alerts.reduceMotion = value.reduceMotion
        aiHub.alerts.rules = value.agentAlerts
        automations.rules = value.automations
        if let battery = dashboard.registry.widget("battery") as? BatteryWidget {
            battery.showsEnergy = value.batteryEnergy
            battery.chargingAnimation = value.chargingAnimation
        }
        if context.preferences != value.suggestions { context.preferences = value.suggestions }
        if launcherPanel != nil {
            launcher.searchesFiles = value.launcherFiles
            if value.launcherShortcut != launcherShortcut { applyLauncherShortcut(value.launcherShortcut) }
        }
        updateNotchPolicy(value)  // alerts, the volume HUD (at launch startSonicPulse applies it), the island, the trigger
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
        desktopPet?.stop()
        alertPanel?.stop()
        companion.shutdown()
        companionPanel?.stop()
        companionCharacter?.stop()
        hotKey?.unregister()
        coucou.stop()
        aiHub.shutdown()
        pet.shutdown()
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

    /// Displays added, removed or rearranged, the main display changed (the lid, a monitor), resolution or
    /// scaling changed, or the displays woke: every panel goes to the current primary display, and the wings vs
    /// pill decision is made again (whether there's a notch isn't observable, so it must be re-read here).
    @objc private func screensChanged() {
        context.refresh()  // displays aren't observable: re-read them now
        wingsPanel?.reposition()
        contextPillPanel?.reposition()
        if wingsPanel != nil {
            wingsGeneration += 1
            followWings(wingsGeneration)
        }
        eyeBreakPanel?.reposition()
        panel?.reposition()
        islandPanel?.reposition()
        hudPanel?.reposition()
        alertPanel?.reposition()
        companionPanel?.reposition()
        desktopPet?.screensChanged()
    }

    @objc private func spaceChanged() {
        interaction.spaceChanged()
        island.spaceChanged()
        overlay.spaceChanged()
        desktopPet?.spaceChanged()
        companion.spaceChanged()
        refreshCompanion()  // on a full-screen Space the companion isn't there: nothing animates
    }

    /// The Desktop Pet (5.4): its window only while enabled. The activity
    /// model hears display sleep, fast user switching and Reduce Motion from
    /// public notifications; the controller adds occlusion and full screen.
    private func startDesktopPet() {
        let desktopPet = DesktopPet(model: pet, rig: PetRig(appearance: preferences.value.petLook.appearance, size: 96),
                                    store: JSONFile(url: OrbitStorage.directory.appending(path: "desktop-pet.json")))
        self.desktopPet = desktopPet
        desktopPet.start()
        applyCharacter(preferences.value.petLook)
        let workspace = NSWorkspace.shared.notificationCenter
        let inputs: [(Notification.Name, @MainActor (PetActivity) -> Void)] = [
            (NSWorkspace.screensDidSleepNotification, { $0.setDisplayAsleep(true) }),
            (NSWorkspace.screensDidWakeNotification, { $0.setDisplayAsleep(false) }),
            (NSWorkspace.sessionDidResignActiveNotification, { $0.setSessionLocked(true) }),
            (NSWorkspace.sessionDidBecomeActiveNotification, { $0.setSessionLocked(false) }),
            (NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, { [weak self] activity in
                activity.setReduceMotion((self?.preferences.value.reduceMotion ?? false)
                                         || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
                HubAppearance.shared.increasedContrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
                if let self, self.wingsPanel != nil {  // the wings and pill take the new Reduce Motion at once
                    self.wingsGeneration += 1
                    self.followWings(self.wingsGeneration)
                }
            }),
        ]
        for (name, input) in inputs {
            workspace.addObserver(forName: name, object: nil, queue: .main) { [weak self, petActivity] _ in
                MainActor.assumeIsolated {
                    input(petActivity)
                    self?.refreshCompanion()  // display sleep and lock hide the companion too
                }
            }
        }
    }

    /// Sonic Pulse: the volume HUD in the slot below the notch, fed by the
    /// default output device's volume and mute (listeners, no polling). It
    /// covers a compact island for a moment and never the dashboard or the
    /// expanded player (`NotchOverlayCoordinator`).
    /// Agent alerts take the slot below the notch only while nothing else wants it (Phase 10).
    private func startAgentAlerts() {
        alertPanel = AgentAlertPanel(alerts: aiHub.alerts) { [weak self] in self?.slotHolder(.agentAlert) == .agentAlert }
    }

    /// Everything that wants the slot below the menu bar or notch, read live (Observation tracks it). One place,
    /// so every surface sees the same picture (before Milestone 15 the alert didn't see the brightness HUD and the
    /// eye break saw only the dashboard and the expanded player).
    private func slotInputs(skipping skipped: NotchCoordination.Surface? = nil) -> NotchCoordination.Inputs {
        var inputs = NotchCoordination.Inputs(owner: notchOwner, dashboardOpen: interaction.isOpen, island: island.phase,
                                              volumeHUD: overlay.overlay == .volumeHUD, brightnessHUD: overlay.overlay == .brightnessHUD)
        if skipped != .agentAlert { inputs.alert = aiHub.alerts.current != nil }
        if skipped != .eyeBreak, let model = (dashboard.registry.widget("eyeBreak") as? EyeBreakWidget)?.model,
           case .resting = model.phase { inputs.eyeBreak = true }
        if skipped != .statusPill { inputs.statusPill = contextPill.content != nil }
        if skipped != .companion { inputs.companion = companionWanted }
        return inputs
    }

    /// Who holds the slot if `surface` wants it now.
    private func slotHolder(_ surface: NotchCoordination.Surface) -> NotchCoordination.Surface? {
        var inputs = slotInputs(skipping: surface)
        switch surface {
        case .agentAlert: inputs.alert = true
        case .eyeBreak: inputs.eyeBreak = true
        case .statusPill: inputs.statusPill = true
        case .companion: inputs.companion = true
        default: break
        }
        return NotchCoordination.holder(inputs)
    }

    private var notchOwner: NotchCoordination.Owner { .init(coucouRunning: coucou.state.isRunning) }

    /// Coucou launched or quit (or Orbit's first look). While it runs it has the
    /// notch: everything Orbit shows there steps aside (§22) except the
    /// dashboard, which opens from ⌃⌥⌘O; monitoring and history carry on.
    private func coucouChanged(_ state: CoucouPresence.State) {
        aiHub.coucou = state
        aiHub.coucouAnswersClaude = state.isRunning
            && ClaudeHookInstaller.coucouAnswersPermissions(in: try? Data(contentsOf: aiHub.claudeSettingsURL))
        updateNotchPolicy(preferences.value)  // the companion follows coucou.state itself
        log.notice("coucou: \(state.summary, privacy: .public); notch owner \(self.notchOwner.rawValue, privacy: .public); answers Claude \(self.aiHub.coucouAnswersClaude, privacy: .public)")
    }

    private var companionWanted: Bool { pet.toggles.pet && pet.toggles.companion }

    /// What follows from who has the notch and the preferences: agent alerts (not
    /// while Coucou runs, nor while the Notch Companion says it instead), the
    /// volume HUD and the music island (not while Coucou runs, §22), and the
    /// dashboard's notch trigger (Coucou's while it runs).
    private func updateNotchPolicy(_ value: OrbitPreferences) {
        let owner = notchOwner
        aiHub.alerts.isEnabled = value.aiHubAlerts && NotchCoordination.permits(.agentAlert, owner: owner) && !companionWanted
        companion.announces = companionWanted && owner == .orbit
        setSystemHUDs(value)
        if !NotchCoordination.permits(.expandedMusic, owner: owner), island.phase == .expanded { island.collapse() }
        updateIslandCover()
        panel?.yieldsTrigger = owner == .coucou
        if wingsPanel != nil {  // the owner isn't observable: re-follow on each policy change
            wingsGeneration += 1
            followWings(wingsGeneration)
        }
    }

    /// The music island's window: covered by a system HUD for a moment, while Coucou has the notch, and
    /// while the wings stand in for the compact pill (the expanded player still opens below the notch).
    private func updateIslandCover() {
        islandPanel?.setCovered(hudCoversIsland || !NotchCoordination.permits(.compactMusic, owner: notchOwner)
                                || (wingsActive && island.phase == .compact))
    }

    /// Compact style › Beside the camera, on a display with a notch.
    private var wingsActive: Bool { presenter == .wings }

    /// Wings, the floating pill or nothing, for the current primary display and settings.
    private var presenter: StatusPresenter {
        StatusPresenter.choose(preferences.value.statusDisplay, compactStyle: preferences.value.compactStyle,
                               hasNotch: wingsPanel?.hasNotch ?? false)
    }

    /// The eye-break reminder (Milestone 9): its pill waits while the dashboard or the full player is
    /// open, or Coucou has the notch; display sleep and a locked screen count as a break.
    /// The selected character on the desktop pet and the notch companion (the same on both),
    /// or Orbit's illustrated pet, never another character (`PetSelection`, Milestone 10.1).
    private func applyCharacter(_ look: PetLook) {
        let rigs = [desktopPet?.rig, companionCharacter?.rig].compactMap { $0 }
        let selection = PetSelection.apply(look, to: rigs, library: .shared)
        petSelection = selection
        switch selection {
        case .fallback(let id, let reason):
            log.error("pet character \(id, privacy: .public) not shown: \(reason, privacy: .public); Orbit's illustrated pet instead")
        case .character(let id, let species):
            log.notice("pet character \(id, privacy: .public) (\(species.rawValue, privacy: .public)) on \(rigs.count, privacy: .public) renderer(s)")
        case .builtIn:
            log.notice("pet: Orbit illustrated on \(rigs.count, privacy: .public) renderer(s)")
        }
    }

    private func startEyeBreak() {
        guard let model = (dashboard.registry.widget("eyeBreak") as? EyeBreakWidget)?.model else { return }
        model.canShow = { [weak self] in self?.slotHolder(.eyeBreak) == .eyeBreak }
        eyeBreakPanel = EyeBreakPanel(model: model)
        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.screensDidSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { model.systemRested() }
            }
        }
    }

    /// The File Shelf and the AI Hub (Milestone 14): sessions list the project's shelved files, and the shelf
    /// groups by the projects agents work in and the Projects folder (by path only; nothing read from disk).
    private func connectShelf() {
        connectQuickActions()
        if let digest = dashboard.registry.widget("digest") as? DailyDigestWidget {  // what the Daily Digest summarises
            digest.inputs = { [weak self] in
                guard let self else { return .init() }
                let registry = dashboard.registry
                let agenda = (registry.widget("events") as? EventsWidget)?.refresher.value
                var inputs = DailyDigest.Inputs(forecast: (registry.widget("weather") as? WeatherWidget)?.forecast,
                                                events: agenda.map { $0.allDay + $0.timed } ?? [],
                                                tasks: (registry.widget("tasks") as? TasksWidget)?.items ?? [],
                                                news: (registry.widget("news") as? NewsWidget)?.stories ?? [],
                                                insights: aiHub.isEnabled ? aiHub.insights : nil)
                if preferences.value.suggestions.dailyBriefing {  // the Daily Intelligence Briefing (Milestone 17)
                    let s = context.snapshot
                    inputs.workspace = s.workspace?.name
                    inputs.goals = s.goals
                    inputs.agentsWaiting = Array(Set(s.waitingAgents.map(\.name))).sorted()
                    inputs.agentsDoneToday = s.agents.filter { ($0.status == .completed || $0.status == .ended)
                        && Calendar.current.isDateInToday($0.lastEventAt) }.map(\.name)
                    inputs.focusSessionsToday = s.focusSessionsToday
                    inputs.suggestions = context.shown.map(\.suggestion.title)
                }
                return inputs
            }
        }
        if let weekly = dashboard.registry.widget("weekly") as? WeeklyInsightsWidget {  // This Week's coding rows
            weekly.codingInsights = { [weak self] in self?.aiHub.isEnabled == true ? self?.aiHub.insights : nil }
            weekly.refreshCoding = { [weak self] in if self?.aiHub.isEnabled == true { await self?.aiHub.refreshInsights() } }
        }
        guard let shelf = (dashboard.registry.widget("fileShelf") as? FileShelfWidget)?.shelf else { return }
        aiHub.shelf = shelf
        shelf.projectRoots = { [weak self] in
            let cwds = (self?.aiHub.real.sessions.values.compactMap(\.cwd)) ?? []
            return (Array(Set(cwds)), [FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer").path(percentEncoded: false)])
        }
    }

    // MARK: Context Engine (Milestone 17)

    /// The sources read models Orbit already keeps current; nothing new is monitored.
    private func startContextEngine() {
        let registry = dashboard.registry
        let tasksWidget = registry.widget("tasks") as? TasksWidget
        let goalsWidget = registry.widget("goals") as? GoalsWidget
        let pomodoro = registry.widget("pomodoro") as? PomodoroWidget
        let events = registry.widget("events") as? EventsWidget
        let coordinator = (registry.widget("nowPlaying") as? NowPlayingWidget)?.coordinator
        let shelf = (registry.widget("fileShelf") as? FileShelfWidget)?.shelf
        context.register(ContextSource(id: "dashboard", name: "Dashboard") { [interaction] _ in _ = interaction.isOpen })  // opening re-reads
        context.register(ContextSource(id: "workspaces", name: "Workspaces") { [workspaces] s in
            s.workspace = workspaces.active
            s.workspaces = workspaces.profiles
        })
        context.register(ContextSource(id: "aiHub", name: "AI Hub") { [aiHub] s in
            guard aiHub.isEnabled else { return }
            let recent = Date.now.addingTimeInterval(-86_400)
            s.agents = aiHub.real.sessions.values.filter { $0.lastEventAt > recent }.sorted { $0.lastEventAt > $1.lastEventAt }.map { session in
                ContextSnapshot.Agent(key: "\(session.key.agent):\(session.key.nativeID)", name: AgentDiscovery.displayName(for: session.key.agent),
                                      project: session.cwd.map { ($0 as NSString).lastPathComponent }, folder: session.cwd,
                                      status: session.status, lastEventAt: session.lastEventAt, canJump: session.originBundleID != nil)
            }
        })
        context.register(ContextSource(id: "calendar", name: "Calendar") { [weak self] s in
            s.meeting = self?.meetings?.cue
            if let agenda = events?.refresher.value, Calendar.current.isDateInToday(agenda.day) { s.todayEvents = agenda.allDay + agenda.timed }
        })
        context.register(ContextSource(id: "tasks", name: "Tasks and goals") { s in
            let items = tasksWidget?.items ?? []
            s.openTasks = items.filter { !$0.isDone }
            s.doneToday = items.filter { $0.isDone && ($0.completedAt.map(Calendar.current.isDateInToday) ?? false) }
            s.goals = goalsWidget?.goals ?? []
        })
        context.register(ContextSource(id: "focus", name: "Focus") { s in
            guard let timer = pomodoro?.timer else { return }
            switch timer.status {
            case .idle: s.focus = timer.phase == .focus ? .idle : .resting
            case .running(let ends): s.focus = timer.phase == .focus ? .running(endsAt: ends, length: timer.focusLength) : .resting
            case .paused(let remaining): s.focus = timer.phase == .focus ? .paused(remaining: remaining) : .resting
            }
            s.focusSessionsToday = (timer.focusLog ?? []).filter(Calendar.current.isDateInToday).count
        })
        context.register(ContextSource(id: "battery", name: "Battery and energy") { s in
            s.battery = BatteryStatus.current()  // one IOKit read; the dashboard opening triggers it
            if case .ready(let apps, _, let at) = EnergyMonitor.shared.state, Date.now.timeIntervalSince(at) < 60 {
                s.energyHog = apps.first { $0.level == .high }?.name
            }
        })
        context.register(ContextSource(id: "music", name: "Music") { s in
            if let item = coordinator?.current, item.state == .playing { s.music = item.title ?? item.appName }
        })
        context.register(ContextSource(id: "shelf", name: "File Shelf") { s in s.shelfNewest = shelf?.items.first?.name })
        context.register(ContextSource(id: "displays", name: "Displays") { s in
            s.displays = NSScreen.screens.count
            s.externalDisplay = NSScreen.screens.contains { screen in
                (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) == 0 } ?? false
            }
        })
        context.register(ContextSource(id: "automations", name: "Automations") { [preferences] s in s.automations = preferences.value.automations })
        context.perform = { [weak self] action in self?.performSuggestion(action) }
        context.onPreferencesChange = { [weak self] value in self?.preferences.update { $0.suggestions = value } }
        context.preferences = preferences.value.suggestions
        dashboard.context = context
        settings.model.context = context
        settings.model.automations = automations
        context.start()
    }

    /// A suggestion's action, after the user clicked it.
    private func performSuggestion(_ action: Suggestion.Action) {
        func session(_ key: String) -> AgentSession? { aiHub.real.sessions.values.first { "\($0.key.agent):\($0.key.nativeID)" == key } }
        switch action {
        case .goToAgent(let key):
            if let found = session(key), aiHub.openOrigin(of: found) { interaction.close(); return }
            fallthrough
        case .reviewAgent(let key):
            if case .reviewAgent = action, let found = session(key) {
                aiHub.browser.select(found, in: aiHub)
                aiHub.browser.detailTab = .changes
            }
            dashboard.section = .ai
        case .openAIHub: dashboard.section = .ai
        case .joinMeeting(let url): MeetingLink.open(url); interaction.close()
        case .openCalendar: QuickAction.calendar.perform(); interaction.close()
        case .pauseMusic: _ = runAutomation(.pauseMusic)
        case .switchWorkspace(let id): activateWorkspace(id)
        case .openProductivity: dashboard.section = .productivity
        case .startFocus(let minutes): (dashboard.registry.widget("pomodoro") as? PomodoroWidget)?.startFocus(minutes: minutes)
        case .resumeFocus: (dashboard.registry.widget("pomodoro") as? PomodoroWidget)?.resume()
        case .batterySettings: SystemSettingsLink.battery.open(); interaction.close()
        case .activityMonitor: QuickAction.activityMonitor.perform(); interaction.close()
        }
    }

    // MARK: Launcher and workspaces (Milestone 16)

    private func startLauncher() {
        launcher.searchesFiles = preferences.value.launcherFiles
        launcher.sources = { [weak self] in self?.launcherSources() ?? [] }
        launcher.boosted = { [weak self] in Set((self?.workspaces.active).map { $0.projects + $0.apps } ?? []) }
        launcherPanel = LauncherPanel(model: launcher) { [weak self] item, alternate in self?.openLauncherItem(item, alternate: alternate) }
        settings.model.workspaces = workspaces
        settings.model.launcher = launcher
        settings.model.useCurrentLayout = { [weak self] in self?.dashboard.layout }
        settings.model.activateWorkspace = { [weak self] id in self?.activateWorkspace(id) }
        settings.model.openWorkspace = { [weak self] id in self?.openWorkspace(id) }
        if let battery = dashboard.registry.widget("battery") as? BatteryWidget,
           let coordinator = (dashboard.registry.widget("nowPlaying") as? NowPlayingWidget)?.coordinator {
            // Context for a browser row only (what's playing), never energy attribution.
            battery.browserMedia = { coordinator.current.flatMap { $0.sourceID == "brave-youtube" ? "\($0.title ?? "a video") on YouTube in Brave" : nil } }
        }
        applyLauncherShortcut(preferences.value.launcherShortcut)
    }

    private func applyLauncherShortcut(_ shortcut: LauncherShortcut) {
        launcherHotKey?.unregister()
        launcherHotKey = nil
        launcherShortcut = shortcut
        guard let combination = shortcut.combination else {
            settings.model.launcherShortcutAvailable = nil
            return
        }
        let hotKey = GlobalHotKey(id: 2, keyCode: combination.keyCode, modifiers: combination.modifiers) { [weak self] in self?.toggleLauncher() }
        let registered = hotKey.register()
        launcherHotKey = hotKey
        settings.model.launcherShortcutAvailable = registered
        log.notice("launcher shortcut \(shortcut.label, privacy: .public): \(registered ? "registered" : "unavailable (another app holds it)", privacy: .public)")
    }

    private func toggleLauncher() {
        interaction.close()
        launcherPanel?.toggle()
    }

    /// Orbit's own searchable things, read when the launcher searches (all in memory already).
    private func launcherSources() -> [LauncherItem] {
        let registry = dashboard.registry
        var items: [LauncherItem] = []
        func abbreviated(_ path: String) -> String { (path as NSString).abbreviatingWithTildeInPath }
        for project in (registry.widget("projects") as? ProjectsWidget)?.projects ?? [] {
            items.append(LauncherItem(id: "project:" + project.id, kind: .project, title: project.name,
                                      subtitle: (project.isGitRepository ? "Git repository · " : "") + abbreviated(project.id), path: project.id))
        }
        if aiHub.isEnabled {
            let recent = Date.now.addingTimeInterval(-14 * 86_400)
            for session in aiHub.real.sessions.values where session.lastEventAt > recent {
                let agent = AgentDiscovery.displayName(for: session.key.agent)
                let project = session.cwd.map { ($0 as NSString).lastPathComponent }
                items.append(LauncherItem(id: "agent:\(session.key.agent):\(session.key.nativeID)", kind: .agent,
                                          title: session.title ?? project ?? agent,
                                          subtitle: [agent, session.status.rawValue, project,
                                                     "active " + session.lastEventAt.formatted(.relative(presentation: .named))]
                                            .compactMap { $0 }.joined(separator: " · "),
                                          keywords: agent + " " + (session.cwd ?? ""), action: "\(session.key.agent)|\(session.key.nativeID)"))
            }
        }
        for item in (registry.widget("fileShelf") as? FileShelfWidget)?.shelf.items ?? [] {
            items.append(LauncherItem(id: "shelf:\(item.id)", kind: .shelf, title: item.name, subtitle: "File Shelf · " + abbreviated(item.sourcePath),
                                      path: item.sourcePath, action: item.id.uuidString))
        }
        let active = workspaces.active
        for task in (registry.widget("tasks") as? TasksWidget)?.items ?? [] where !task.isDone {
            let owner = workspaces.profiles.first { $0.owns(task: task.title) }
            items.append(LauncherItem(id: "task:\(task.id)", kind: .task, title: task.title,
                                      subtitle: ["Task", task.dueDate.map { "due " + $0.formatted(date: .abbreviated, time: .omitted) }, owner?.name]
                                        .compactMap { $0 }.joined(separator: " · "),
                                      keywords: owner?.id == active?.id ? (active?.name ?? "") : ""))
        }
        for goal in (registry.widget("goals") as? GoalsWidget)?.goals ?? [] {
            items.append(LauncherItem(id: "goal:\(goal.id)", kind: .goal, title: goal.title, subtitle: goal.isDone ? "Today's goal · done" : "Today's goal"))
        }
        if let agenda = (registry.widget("events") as? EventsWidget)?.refresher.value {
            for event in agenda.allDay + agenda.timed where event.end > .now {
                items.append(LauncherItem(id: "event:" + event.id, kind: .event, title: event.title,
                                          subtitle: (event.isAllDay ? "Today, all day" : "Today " + event.start.formatted(date: .omitted, time: .shortened))
                                            + (event.meetingURL.flatMap(MeetingLink.service(of:)).map { " · \($0) link" } ?? ""),
                                          action: event.meetingURL.map { "join|" + $0.absoluteString } ?? ""))
            }
        }
        for section in SettingsSection.allCases {
            items.append(LauncherItem(id: "setting:" + section.rawValue, kind: .setting, title: section.title + " Settings",
                                      subtitle: "Orbit Settings", keywords: section.keywords, action: section.rawValue))
        }
        for section in DashboardSection.allCases {
            items.append(LauncherItem(id: "orbit:section:" + section.rawValue, kind: .orbit, title: section.title,
                                      subtitle: "Open in the Orbit dashboard", keywords: "dashboard", action: "section:" + section.rawValue))
        }
        let features: [(String, String, String)] = [
            ("Keep Awake for an Hour", "keepAwake", "caffeinate sleep"), ("Start a Focus Session", "focus", "pomodoro timer"),
            ("Pause Music", "pause", "play stop"), ("Battery Settings", "battery", "energy power charging"),
            ("Display Settings", "displays", "brightness monitor resolution"), ("Activity Monitor", "activity", "energy cpu processes"),
            ("Clear Launcher History", "clearHistory", "recent"),
        ]
        for (title, action, keywords) in features {
            items.append(LauncherItem(id: "orbit:" + action, kind: .orbit, title: title, subtitle: "Orbit action", keywords: keywords, action: action))
        }
        for profile in workspaces.profiles {
            let isActive = profile.id == active?.id
            items.append(LauncherItem(id: "workspace:\(profile.id)", kind: .workspace, title: profile.name,
                                      subtitle: isActive ? "Active workspace · Return opens its apps and projects" : "Switch to this workspace",
                                      keywords: "workspace profile", action: profile.id.uuidString))
        }
        return items
    }

    /// Return (or ⌘Return for the alternate) in the launcher. Only what the user chose; nothing is run from a file.
    private func openLauncherItem(_ item: LauncherItem, alternate: Bool) {
        let registry = dashboard.registry
        if [.app, .file, .folder, .project, .shelf].contains(item.kind), !LauncherModel.exists(item.path) {
            launcher.forget(item, because: "\(item.title) is no longer there.")
            return
        }
        // Items that open an app, a file, a link or Finder let that app take focus; the rest give it back.
        let opensSomething: Bool = switch item.kind {
        case .app, .file, .folder, .project, .event, .agent: true
        case .shelf, .task, .goal, .setting, .orbit, .workspace: alternate && item.kind == .shelf
        }
        launcherPanel?.dismiss(restoreFocus: !opensSomething)
        launcher.remember(item)
        func reveal(_ path: String) { NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)]) }
        switch item.kind {
        case .app:
            if let path = item.path {
                if alternate { reveal(path) } else { NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: .init()) }
            }
        case .file, .folder:
            guard let path = item.path else { return }
            if alternate || (item.kind == .file && LauncherModel.isRunnable(path)) { reveal(path) } else { NSWorkspace.shared.open(URL(filePath: path)) }
        case .project:
            guard let path = item.path else { return }
            let url = URL(filePath: path)
            if alternate || !ProjectAction.editor.isAvailable {
                NSWorkspace.shared.open(url)
            } else {
                ProjectAction.editor.open(Project(name: item.title, url: url, modified: .now))
            }
        case .agent:
            let parts = item.action.split(separator: "|").map(String.init)
            if parts.count == 2, let session = aiHub.real.sessions.values.first(where: { "\($0.key.agent)" == parts[0] && $0.key.nativeID == parts[1] }),
               !alternate, aiHub.openOrigin(of: session) { return }
            openDashboard(.ai)
        case .shelf:
            guard let shelf = (registry.widget("fileShelf") as? FileShelfWidget)?.shelf,
                  let entry = shelf.items.first(where: { $0.id.uuidString == item.action }) else { return }
            if alternate { shelf.reveal(entry) } else { shelf.copyPathForAgent(entry) }
        case .task, .goal:
            openDashboard(.productivity)
        case .event:
            if item.action.hasPrefix("join|"), !alternate, let url = URL(string: String(item.action.dropFirst(5))) {
                MeetingLink.open(url)
            } else {
                QuickAction.calendar.perform()
            }
        case .setting:
            interaction.close()
            settings.show(section: SettingsSection(rawValue: item.action))
        case .orbit:
            runOrbitAction(item.action)
        case .workspace:
            guard let id = UUID(uuidString: item.action) else { return }
            if workspaces.active?.id == id { openWorkspace(id) } else { activateWorkspace(id) }
        }
    }

    private func runOrbitAction(_ action: String) {
        if action.hasPrefix("section:"), let section = DashboardSection(rawValue: String(action.dropFirst(8))) { return openDashboard(section) }
        switch action {
        case "keepAwake": _ = runAutomation(.keepAwakeHour)
        case "focus": _ = runAutomation(.startFocus)
        case "pause": _ = runAutomation(.pauseMusic)
        case "battery": SystemSettingsLink.battery.open()
        case "displays": SystemSettingsLink.displays.open()
        case "activity": QuickAction.activityMonitor.perform()
        case "clearHistory": launcher.clearHistory()
        default: break
        }
    }

    /// Switches workspace: Orbit's layout and ranking, plus what the profile asks for (pause music, focus, keep awake).
    /// Never opens or closes apps by itself.
    private func activateWorkspace(_ id: UUID?) {
        workspaces.setActive(id)
        guard let profile = workspaces.active else { return log.notice("workspace: none") }
        if let layout = profile.layout { dashboard.useLayout(layout) }
        if profile.music == .pause { _ = runAutomation(.pauseMusic) }
        if profile.keepAwake { _ = runAutomation(.keepAwakeHour) }
        if profile.startFocus { _ = runAutomation(.startFocus) }
        log.notice("workspace: \(profile.name, privacy: .public) active")
    }

    /// "Open Workspace": its apps and projects, on request. Missing ones are skipped.
    private func openWorkspace(_ id: UUID) {
        guard let profile = workspaces.profiles.first(where: { $0.id == id }) else { return }
        for app in profile.apps where FileManager.default.fileExists(atPath: app) {
            NSWorkspace.shared.openApplication(at: URL(filePath: app), configuration: .init())
        }
        for project in profile.projects where FileManager.default.fileExists(atPath: project) {
            let url = URL(filePath: project)
            if ProjectAction.editor.isAvailable {
                ProjectAction.editor.open(Project(name: url.lastPathComponent, url: url, modified: .now))
            } else {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// The Get Started page, once (first launch, or the first launch after this update).
    private func showOnboardingIfNeeded() {
        guard !preferences.value.onboardingSeen else { return }
        preferences.update { $0.onboardingSeen = true }
        settings.show(section: .welcome)
    }

    /// Suggested quick actions (Milestone 14): read from Orbit's own state when the dashboard shows them.
    private func connectQuickActions() {
        guard let quick = dashboard.registry.widget("quickActions") as? QuickActionsWidget else { return }
        // One place for suggestions: while "Suggested for You" shows, the chips step aside.
        quick.hidesSuggestions = { [weak self] in !(self?.context.shown.isEmpty ?? true) }
        let events = dashboard.registry.widget("events") as? EventsWidget
        let peekMeetings = meetings ?? events.map { events in MeetingWatcher(store: events.store, calendarSettings: { events.settings.value }) }
        quick.context = { [weak self] in
            guard let self else { return QuickContext() }
            let sessions = aiHub.isEnabled ? Array(aiHub.real.sessions.values) : []
            let latest = sessions.filter { $0.cwd != nil }.max { $0.lastEventAt < $1.lastEventAt }
            return QuickContext(waiting: sessions.filter { $0.status == .waiting }.max { $0.lastEventAt < $1.lastEventAt },
                                meeting: peekMeetings?.peek(),
                                playing: (dashboard.registry.widget("nowPlaying") as? NowPlayingWidget)?.coordinator.current,
                                project: latest?.cwd,
                                shelfItem: (dashboard.registry.widget("fileShelf") as? FileShelfWidget)?.shelf.items.first,
                                focusIdle: (dashboard.registry.widget("pomodoro") as? PomodoroWidget).map { $0.timer.status == .idle && $0.timer.phase == .focus } ?? false,
                                keepingAwake: KeepAwakeModel.shared.isActive,
                                suggestedWorkspace: workspaces.suggestion(at: .now),
                                activeWorkspace: workspaces.active,
                                energyHog: {
                                    if case .ready(let apps, _, let at) = EnergyMonitor.shared.state, Date.now.timeIntervalSince(at) < 60 {
                                        return apps.first { $0.level == .high }?.name
                                    }
                                    return nil
                                }(),
                                lowBattery: (dashboard.registry.widget("battery") as? BatteryWidget)?.status.map { $0.chargeState == .onBattery && $0.percent <= 20 } ?? false,
                                externalDisplay: NSScreen.screens.contains { screen in
                                    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber).map { CGDisplayIsBuiltin($0.uint32Value) == 0 } ?? false
                                })
        }
        quick.run = { [weak self] action in
            guard let self else { return }
            switch action {
            case .goToAgent(let session): aiHub.openOrigin(of: session)
            case .join(_, let url): MeetingLink.open(url)
            case .openCalendar: _ = runAutomation(.openCalendar)  // the automations' actions: one implementation
            case .keepAwake: _ = runAutomation(.keepAwakeHour); return
            case .startFocus: _ = runAutomation(.startFocus); return
            case .switchWorkspace(let profile): activateWorkspace(profile.id); return
            case .openWorkspace(let profile): openWorkspace(profile.id)
            case .activityMonitor: QuickAction.activityMonitor.perform()
            case .batterySettings: SystemSettingsLink.battery.open()
            case .displaySettings: SystemSettingsLink.displays.open()
            case .pause:
                _ = runAutomation(.pauseMusic)
                return  // pausing keeps the dashboard open
            case .revealProject(let path):
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: path, isDirectory: &isFolder), isFolder.boolValue {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(filePath: path)])
                }
            case .copyShelfPath(let item):
                (dashboard.registry.widget("fileShelf") as? FileShelfWidget)?.shelf.copyPathForAgent(item)
                return
            }
            interaction.close()
        }
    }

    private func startWings() {
        wingsPanel = NotchWingsPanel(wings: wings)
        contextPillPanel = ContextPillPanel(pill: contextPill) { [weak self] action in self?.performPill(action) }
        if let events = dashboard.registry.widget("events") as? EventsWidget {
            meetings = MeetingWatcher(store: events.store, calendarSettings: { events.settings.value })
            followCalendarChoice(events)
        }
        wingsGeneration += 1
        followWings(wingsGeneration)
    }

    /// The pill's buttons. Each is an explicit click; Join opens only a validated link.
    private func performPill(_ action: ContextPill.Action) {
        switch action {
        case .join(let url): MeetingLink.open(url)
        case .openCalendar: QuickAction.calendar.perform()
        case .goToAgent(let agent):
            let session = aiHub.real.sessions.values.filter { $0.key.agent == agent }.max { $0.lastEventAt < $1.lastEventAt }
            if let session, aiHub.openOrigin(of: session) { break }
            openDashboard(.ai)
        case .openHub: openDashboard(.ai)
        }
        contextPill.collapse()
    }

    private func openDashboard(_ section: DashboardSection) {
        dashboard.section = section
        if !interaction.isOpen { panel?.toggleFromKeyboard() }
    }

    /// The meeting watcher re-reads when the Calendar widget's access or chosen calendars change.
    private func followCalendarChoice(_ events: EventsWidget) {
        withObservationTracking {
            _ = (events.access, events.settings.value)
        } onChange: { [weak self] in
            Task { @MainActor in
                self?.meetings?.refresh()
                self?.followCalendarChoice(events)
            }
        }
    }

    /// The meeting watcher runs only while its cue could show: wings on a notched display, heads-up on.
    private func updateMeetingWatcher(hasNotch: Bool) {
        guard let meetings else { return }
        let value = preferences.value
        meetings.settings = MeetingCue.Settings(noticeMinutes: value.meetingNoticeMinutes, urgentMinutes: value.meetingUrgentMinutes)
        let contextWantsMeetings = value.suggestions.enabled && !value.suggestions.disabledCategories.contains(.calendar)
        if (value.meetingHeadsUp && presenter != .none) || automations.listens(for: .meetingSoon) || contextWantsMeetings {
            meetings.start()
        } else {
            meetings.stop()
        }
    }

    /// Automations: a meeting turning "soon" (once per meeting) and the AI Hub's real alerts.
    private func startAutomations() {
        automations.rules = preferences.value.automations
        settings.model.automations = automations
        aiHub.alerts.onAlert = { [weak self] kind in
            guard let self, kind != .failed else { return }
            automations.fire(kind == .needsYou ? .agentNeedsYou : .agentFinished, context: automationContext(),
                             reason: kind == .needsYou ? "An agent reported it needs you" : "An agent finished")
        }
        automations.onRun = { [weak self] run in
            let outcome: String = if case .skipped(let why) = run.outcome { "skipped: \(why)" } else { "done" }
            self?.context.noteAutomation("Automation “\(run.text)” \(outcome)" + (run.reason.isEmpty ? "" : " — \(run.reason)"))
        }
        followMeetingTrigger()
    }

    private func followMeetingTrigger() {
        let cue = withObservationTracking { meetings?.cue } onChange: { [weak self] in
            Task { @MainActor in self?.followMeetingTrigger() }
        }
        guard let cue, cue.phase == .soon, cue.eventID != lastMeetingTrigger else { return }
        lastMeetingTrigger = cue.eventID
        automations.fire(.meetingSoon, context: automationContext(), reason: "“\(cue.title)” starts \(cue.countdown(at: .now))")
    }

    private func automationContext() -> Automations.Context {
        let playing = (dashboard.registry.widget("nowPlaying") as? NowPlayingWidget)?.coordinator.current
        let focusRunning: Bool = if case .running(let ends, _) = context.snapshot.focus { ends > .now } else { false }
        return Automations.Context(musicPlaying: playing?.state == .playing,
                                   onBattery: BatteryStatus.current()?.chargeState == .onBattery, focusRunning: focusRunning)
    }

    /// The fixed, safe actions. false: nothing to do.
    private func runAutomation(_ action: AutomationRule.Action) -> Bool {
        switch action {
        case .pauseMusic:
            guard let coordinator = (dashboard.registry.widget("nowPlaying") as? NowPlayingWidget)?.coordinator,
                  let item = coordinator.current, item.state == .playing, item.capabilities.contains(.playPause) else { return false }
            Task { try? await coordinator.perform(.togglePlayPause, on: item) }
            return true
        case .keepAwakeHour:
            guard !KeepAwakeModel.shared.isActive else { return false }  // never shortens one already on
            KeepAwakeModel.shared.start(.oneHour)
            return true
        case .startFocus:
            guard let pomodoro = dashboard.registry.widget("pomodoro") as? PomodoroWidget,
                  pomodoro.timer.status == .idle, pomodoro.timer.phase == .focus else { return false }
            pomodoro.startTimer()
            return true
        case .openCalendar:
            QuickAction.calendar.perform()
            return true
        }
    }

    /// The wings follow the agents, playback, meetings, the dashboard, Coucou and the setting (Observation; no polling).
    private func followWings(_ registered: Int) {
        guard registered == wingsGeneration, let wingsPanel else { return }
        updateMeetingWatcher(hasNotch: wingsPanel.hasNotch)
        let (content, pillContent, pillFree) = withObservationTracking { () -> (WingContent?, WingContent?, Bool) in
            let meeting = preferences.value.meetingHeadsUp ? meetings?.cue : nil
            switch presenter {
            case .wings:
                return (WingContent.choose(lead: agentLead(), music: island.item, meeting: meeting, dashboardOpen: interaction.isOpen,
                                           owner: notchOwner, hasNotch: wingsPanel.hasNotch), nil, false)
            case .pill:
                return (nil, WingContent.pill(lead: agentLead(), meeting: meeting, dashboardOpen: interaction.isOpen, owner: notchOwner),
                        slotHolder(.statusPill) == .statusPill)
            case .none:
                return (nil, nil, false)
            }
        } onChange: { [weak self] in
            Task { @MainActor in self?.followWings(registered) }
        }
        let reduceMotion = preferences.value.reduceMotion || NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        wings.reduceMotion = reduceMotion
        wings.show(content)
        wingsPanel.refreshVisibility()
        contextPill.reduceMotion = reduceMotion
        if contextPill.slotIsFree != pillFree { contextPill.slotIsFree = pillFree }
        contextPill.show(pillContent)
        updateIslandCover()
    }

    /// The most urgent live agent session: needs you, then failed (recently), then working.
    private func agentLead() -> (agent: AgentID, tone: NotchCompanion.Tone)? {
        let sessions = Array(aiHub.real.sessions.values) + (aiHub.isDemoEnabled ? Array(aiHub.demo.sessions.values) : [])
        let now = Date.now
        let ranked = sessions.compactMap { session -> (AgentSession, NotchCompanion.Tone)? in
            switch session.status {
            case .waiting: (session, .attention)
            case .failed where now.timeIntervalSince(session.lastEventAt) < NotchCompanion.recent: (session, .failed)
            case .running: (session, .working)
            default: nil
            }
        }
        let best = ranked.min { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.lastEventAt > $1.0.lastEventAt }
        return best.map { ($0.0.key.agent, $0.1) }
    }

    /// The Notch Companion (§22): Orbit Pet below the notch, on agent activity.
    private func startNotchCompanion() {
        let rig = PetRig(appearance: preferences.value.petLook.appearance, size: CompanionGeometry.catSize)
        companionCharacter = PetCharacter(model: pet, rig: rig)
        defer { applyCharacter(preferences.value.petLook) }
        companion.onCue = { [weak rig] in rig?.play($0) }
        aiHub.onEvents = { [weak self] in self?.companion.receive($0) }
        companion.timeline = { [weak self] session in await self?.aiHub.timeline(for: session) ?? [] }
        companionPanel = NotchCompanionPanel(companion: companion, hub: aiHub, rig: rig, actions: CompanionActions(
            openApp: { [weak self] in _ = self?.aiHub.openOrigin(of: $0) },
            showProject: { [weak self] in _ = self?.aiHub.revealProject(of: $0) },
            openInHub: { [weak self] in self?.openInHub($0) },
            attach: { [weak self] urls, session in self?.attach(urls, to: session) }))
        refreshCompanion()
    }

    /// Files dropped on a session (§23): their paths, quoted, on the clipboard, and the session's app in
    /// front to paste them. Orbit never reads, copies or sends the files.
    private func attach(_ urls: [URL], to session: AgentSession) {
        let result: Result<[String], SessionAttachment.Refusal> = session.isDemo ? .failure(.simulated) : SessionAttachment.paths(urls)
        switch result {
        case .failure(let refusal):
            companion.say(refusal.description)
        case .success(let paths):
            SessionAttachment.copy(paths)
            let app = aiHub.originName(of: session)
            _ = aiHub.openOrigin(of: session)
            companion.say("Copied \(paths.count == 1 ? "1 path" : "\(paths.count) paths"): paste into \(app ?? "the session") with ⌘V")
        }
        log.notice("companion attach: \(urls.count, privacy: .public) dropped, \((try? result.get())?.count ?? 0, privacy: .public) copied")
    }

    /// The expanded companion's "AI Hub": the dashboard on that session.
    private func openInHub(_ session: AgentSession) {
        companion.collapse()
        dashboard.section = .ai
        aiHub.browser.select(session, in: aiHub)
        if !interaction.isOpen { panel?.toggleFromKeyboard() }
    }

    /// Re-reads the companion's inputs now (also on display sleep, wake and lock,
    /// which aren't observable), then whenever one changes. Older registrations
    /// see a stale generation and stop.
    private func refreshCompanion() {
        companionGeneration += 1
        followCompanion(companionGeneration)
    }

    private func followCompanion(_ registered: Int) {
        guard registered == companionGeneration, companionPanel != nil else { return }
        let (available, sessions, events, requests) = withObservationTracking {
            let holder = NotchCoordination.holder(slotInputs())
            let demo = aiHub.isDemoEnabled
            _ = (aiHub.coucouAnswersClaude, pet.agentMood)
            // Beside the camera, the wings carry agent status; the pill below stands aside.
            return (holder == .companion && petActivity.isAwake && !wingsActive,
                    Array(aiHub.real.sessions.values) + (demo ? Array(aiHub.demo.sessions.values) : []),
                    aiHub.real.recentEvents.merging(demo ? aiHub.demo.recentEvents : [:]) { real, _ in real },
                    aiHub.approvals.pending.map(\.draft))
        } onChange: { [weak self] in
            Task { @MainActor in self?.followCompanion(registered) }
        }
        companion.update(available: available, sessions: sessions, events: events, requests: requests, waiting: aiHub.waitingPlace(of:))
        syncCompanionPet()
    }

    /// The cat below the notch follows the pet while the companion is on this
    /// Space; otherwise the pet model counts it as unseen, so nothing animates.
    private func syncCompanionPet() {
        let seen = companion.phase != .hidden && (companionPanel?.isOnActiveSpace ?? false)
        petActivity.setCompanionOccluded(!seen)
        if seen { companionCharacter?.start() } else { companionCharacter?.stop() }
        companionCharacter?.rig.setMood(pet.agentMood)
    }

    /// The pet hears what the agents are doing (a later stage shows it; same cat).
    /// ponytail: a failure ages out at the next session change, not on a timer.
    private func followAgentMood() {
        pet.agentMood = withObservationTracking { AgentMood.of(aiHub.real.sessions.values) } onChange: { [weak self] in
            Task { @MainActor in self?.followAgentMood() }
        }
    }

    private func startSonicPulse() {
        let hudPanel = SystemHUDPanel(coordinator: overlay)
        hudPanel.onCoverIsland = { [weak self] covered in
            self?.hudCoversIsland = covered
            self?.updateIslandCover()
        }
        self.hudPanel = hudPanel
        // One brightness monitor for the HUD and the Brightness widget (each runs it only while it needs it).
        let brightness = BrightnessMonitor()
        (dashboard.registry.widget("brightness") as? BrightnessWidget)?.monitor = brightness
        sonicPulse = SonicPulseController(volume: systemVolume, overlay: overlay, panel: hudPanel,
                                          brightness: brightness) { [island, interaction] in
            (island.phase, interaction.isOpen)
        }
        setSystemHUDs(preferences.value)
    }

    /// Settings › General › Show Volume / Brightness HUD, at once (`SonicPulseController`).
    private func setSystemHUDs(_ value: OrbitPreferences) {
        let owner = notchOwner
        setVolumeHUD(value.volumeHUD && NotchCoordination.permits(.volumeHUD, owner: owner),
                     brightness: value.brightnessHUD && NotchCoordination.permits(.brightnessHUD, owner: owner))
    }

    private func setVolumeHUD(_ enabled: Bool, brightness: Bool? = nil) {
        guard let sonicPulse else { return }
        let brightnessWanted = brightness ?? sonicPulse.brightnessOn
        guard enabled != sonicPulse.volumeOn || brightnessWanted != sonicPulse.brightnessOn else { return }
        sonicPulse.set(volume: enabled, brightness: brightnessWanted)
        log.notice("system huds: volume \(enabled ? "on" : "off", privacy: .public), brightness \(brightnessWanted ? "on" : "off", privacy: .public)")
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
    /// Real-session checks through the session detail's own paths (docs/AI_HUB_SPEC.md §21):
    /// aihub:select:<native ID prefix>, aihub:diff:<relative path>, aihub:open,
    /// aihub:finder[:<relative path>], aihub:render:<absolute .png path>. Results go to the log.
    private func aiHubCheck(_ parts: [String]) -> Bool {
        let browser = aiHub.browser
        let selected = browser.selected.flatMap { aiHub.real.sessions[$0] }
        func logFront(after action: String) {
            Task {
                try? await Task.sleep(for: .seconds(1.5))
                log.notice("aihub check \(action, privacy: .public): front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-", privacy: .public)")
            }
        }
        switch (parts.first, parts.count) {
        case ("select", 2):
            guard let session = aiHub.real.sessions.values.first(where: { $0.key.nativeID.hasPrefix(parts[1]) }) else {
                log.notice("aihub check select: no real session \(parts[1], privacy: .public)")
                return true
            }
            browser.select(session, in: aiHub)
            Task {
                for _ in 0 ..< 100 where browser.changes == nil { try? await Task.sleep(for: .milliseconds(100)) }
                let changes = browser.changes
                let mine = changes?.files.filter(\.touchedBySession).map { "\($0.status.trimmingCharacters(in: .whitespaces)) \($0.path) +\($0.additions ?? 0)/-\($0.deletions ?? 0)" } ?? []
                log.notice("""
                    aihub check select \(session.key.description, privacy: .public) status=\(session.status.rawValue, privacy: .public) \
                    origin=\(session.originBundleID ?? "-", privacy: .public) app=\(self.aiHub.originName(of: session) ?? "-", privacy: .public) \
                    events=\(browser.timeline.count, privacy: .public) paths=\(Set(browser.timeline.flatMap(\.files)).count, privacy: .public) \
                    root=\(changes?.root ?? "-", privacy: .public) refused=\(changes?.refused ?? "-", privacy: .public) \
                    branch=\(changes?.branch ?? "-", privacy: .public) files=\(changes?.files.count ?? -1, privacy: .public) \
                    +\(changes?.additions ?? 0, privacy: .public)/-\(changes?.deletions ?? 0, privacy: .public) \
                    bySession=[\(mine.joined(separator: "; "), privacy: .public)]
                    """)
            }
        case ("diff", 2):
            browser.detailTab = .changes
            browser.showDiff(parts[1])
            Task {
                for _ in 0 ..< 100 where browser.diffText == nil { try? await Task.sleep(for: .milliseconds(100)) }
                let lines = (browser.diffText ?? "").split(separator: "\n", omittingEmptySubsequences: false)
                let added = lines.filter { $0.hasPrefix("+") && !$0.hasPrefix("+++") }.count
                let removed = lines.filter { $0.hasPrefix("-") && !$0.hasPrefix("---") }.count
                log.notice("aihub check diff \(parts[1], privacy: .public): \(lines.count, privacy: .public) lines +\(added, privacy: .public)/-\(removed, privacy: .public) first=\(lines.first.map(String.init) ?? "-", privacy: .public)")
            }
        case ("open", 1):
            guard let selected else { return true }
            log.notice("aihub check open \(selected.originBundleID ?? "-", privacy: .public): \(self.aiHub.openOrigin(of: selected), privacy: .public)")
            logFront(after: "open")
        case ("finder", 1):
            guard let selected else { return true }
            log.notice("aihub check finder project: \(self.aiHub.revealProject(of: selected), privacy: .public)")
            logFront(after: "finder")
        case ("finder", 2):
            guard let root = browser.changes?.root else { return true }
            aiHub.revealFile(parts[1], in: root)
            logFront(after: "finder file")
        case ("render", 2):
            let view = AIHubPage(hub: aiHub, chat: []).frame(width: 708, height: 330).padding(16)
                .background(HubTokens.canvas).environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let written = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
                .map { (try? $0.write(to: URL(filePath: parts[1]))) != nil } ?? false
            log.notice("aihub check render \(parts[1], privacy: .public): \(written, privacy: .public)")
        default:
            return false
        }
        return true
    }

    private func renderDashboard(_ section: DashboardSection, to path: String) {
        if section == .briefing { dashboard.briefing.dailyBriefingEnabled = true }
        dashboard.section = section
        interaction.pointerEntered()
        let widgets = dashboard.sectionWidgets(section)
        widgets.forEach { WidgetVisibility.appeared($0.widget) }
        Task {
            try? await Task.sleep(for: .seconds(6))
            let size = NotchGeometry.dashboardSize
            let view = ZStack(alignment: .top) {
                LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.62, blue: 0.55)],
                               startPoint: .topLeading, endPoint: .bottomTrailing)
                DashboardView(interaction: interaction, model: dashboard, topInset: 32)
                    .frame(width: size.width, height: size.height)
            }
            .frame(width: size.width + 80, height: size.height + 40)
            .environment(\.hubStaticRender, true)
            writePNG(view, to: path, label: "dashboard")
            widgets.forEach { WidgetVisibility.disappeared($0.widget) }
            interaction.close()
        }
    }

    private func renderBriefing(to path: String) {
        dashboard.briefing.dailyBriefingEnabled = true
        let widgets = dashboard.briefingWidgets
        widgets.forEach { WidgetVisibility.appeared($0.widget) }
        Task {
            try? await Task.sleep(for: .seconds(8))
            let view = BriefingSection(widgets: widgets)
                .frame(width: 708, height: 340).padding(16)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .background(Color.black).environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
            writePNG(view, to: path, label: "briefing")
            widgets.forEach { WidgetVisibility.disappeared($0.widget) }
        }
    }

    private func writePNG(_ view: some View, to path: String, label: String) {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let written = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
            .map { (try? $0.write(to: URL(filePath: path))) != nil } ?? false
        log.notice("render \(label, privacy: .public) \(path, privacy: .public): \(written, privacy: .public)")
    }

    private func renderSystem(_ pane: SystemPane, to path: String) {
        let services = dashboard.system
        services.pane = pane
        switch pane {
        case .wifi: services.wifi.start()
        case .bluetooth: services.bluetooth.refresh()
        case .sound: services.audio.refresh()
        case .power: services.readPower()
        case .overview: break
        }
        Task {
            try? await Task.sleep(for: .seconds(pane == .wifi ? 6 : 1))
            if pane == .wifi, parts(path).contains("diag") {
                services.wifi.showingDiagnostics = true
                services.wifi.diagnose()
                try? await Task.sleep(for: .seconds(2))
            }
            let view = SystemPage(services: services, widgets: dashboard.sectionWidgets(.system))
                .frame(width: 708, height: 340).padding(16)
                .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                .background(Color.black).environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
            let renderer = ImageRenderer(content: view)
            renderer.scale = 2
            let written = renderer.cgImage.flatMap { NSBitmapImageRep(cgImage: $0).representation(using: .png, properties: [:]) }
                .map { (try? $0.write(to: URL(filePath: path))) != nil } ?? false
            log.notice("render system \(pane.rawValue, privacy: .public) \(path, privacy: .public): \(written, privacy: .public)")
            if pane == .wifi { services.wifi.stop() }
        }
        func parts(_ path: String) -> String { URL(filePath: path).lastPathComponent }
    }

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
                aihub=\(self.aiHub.isEnabled, privacy: .public)/\(String(describing: self.aiHub.health.bridge), privacy: .public)/\(String(describing: self.aiHub.health.store), privacy: .public)/real=\(self.aiHub.real.sessions.count, privacy: .public)/demo=\(self.aiHub.isDemoEnabled, privacy: .public):\(self.aiHub.demo.sessions.count, privacy: .public)/accepted=\(self.aiHub.health.counters.accepted, privacy: .public)/invalid=\(self.aiHub.health.counters.invalid, privacy: .public) \
                pet=\(self.pet.state.rawValue, privacy: .public)/\(NSStringFromRect(self.desktopPet?.panel?.frame ?? .zero), privacy: .public)/visible=\(self.desktopPet?.panel?.isVisible ?? false, privacy: .public)/onSpace=\(self.desktopPet?.panel?.isOnActiveSpace ?? false, privacy: .public)/occluded=\(self.petActivity.conditions.desktopOccluded, privacy: .public)/moving=\(self.desktopPet?.mover?.isMoving ?? false, privacy: .public)/window=\(self.desktopPet?.panel?.windowNumber ?? 0, privacy: .public) \
                hud=\(String(describing: self.overlay.overlay), privacy: .public)/\(String(describing: self.overlay.hud.phase), privacy: .public)/\(self.overlay.hud.shown.map { "\($0.name ?? "-"):\($0.volume.map { String(format: "%.2f", $0) } ?? "nil"):\($0.isMuted.map(String.init) ?? "nil")" } ?? "-", privacy: .public)/pulse=\(self.overlay.hud.pulse, privacy: .public)/visible=\(self.hudPanel?.isVisible ?? false, privacy: .public)/covered=\(self.islandPanel?.isCovered ?? false, privacy: .public)/listeners=\(self.systemVolume.listenerCount, privacy: .public) \
                frame=\(NSStringFromRect(self.panel?.frame ?? .zero), privacy: .public) \
                key=\(self.panel?.isKeyWindow ?? false, privacy: .public) \
                front=\(NSWorkspace.shared.frontmostApplication?.localizedName ?? "-", privacy: .public) \
                pointer=\(NSStringFromPoint(NSEvent.mouseLocation), privacy: .public) \
                settings=\(self.settings.window?.isVisible ?? false, privacy: .public)/\(self.settings.model.section.rawValue, privacy: .public) \
                settingsFrame=\(NSStringFromRect(self.settings.window?.frame ?? .zero), privacy: .public) \
                cmdComma=\(NSApp.mainMenu?.items.flatMap { $0.submenu?.items ?? [] }.first { $0.keyEquivalent == "," }?.action.map(NSStringFromSelector) ?? "-", privacy: .public)
                """)
        case "pill:state":
            let display = DisplayProfile.primary
            log.notice("pill presenter=\(String(describing: self.presenter), privacy: .public) content=\(self.contextPill.content.map { ContextPillGeometry.text($0).title } ?? "-", privacy: .public) expanded=\(self.contextPill.isExpanded, privacy: .public) free=\(self.contextPill.slotIsFree, privacy: .public) visible=\(self.contextPillPanel?.isVisible ?? false, privacy: .public) frame=\(NSStringFromRect(self.contextPillPanel?.frame ?? .zero), privacy: .public) display=\(NSStringFromRect(display?.frame ?? .zero), privacy: .public) menuBarBottom=\(display?.visible.maxY ?? 0, privacy: .public) notch=\(display?.hasNotch ?? false, privacy: .public) wings=\(self.wingsPanel?.isVisible ?? false, privacy: .public) island=\(String(describing: self.island.phase), privacy: .public) pillWindows=\(NSApp.windows.filter { $0 is ContextPillPanel }.count, privacy: .public) wingWindows=\(NSApp.windows.filter { $0 is NotchWingsPanel }.count, privacy: .public)")
        case "screens:changed": screensChanged()  // the system's display-change path, without changing any display
        case let command? where command.hasPrefix("display:"):
            // display:<compactStyle>:<statusDisplay> for live checks (the caller restores the user's values).
            let parts = command.split(separator: ":").map(String.init)
            if parts.count == 3, let style = CompactStyle(rawValue: parts[1]), let status = StatusDisplay(rawValue: parts[2]) {
                preferences.update { $0.compactStyle = style; $0.statusDisplay = status }
            }
        case "battery:state":
            let battery = dashboard.registry.widget("battery") as? BatteryWidget
            func find<T: NSView>(_ type: T.Type, in view: NSView?) -> [T] {
                guard let view else { return [] }
                return ((view as? T).map { [$0] } ?? []) + view.subviews.flatMap { find(type, in: $0) }
            }
            let effects = find(ChargingEffectsView.self, in: panel?.contentView)
            let glows = find(ChargingGlowView.self, in: panel?.contentView)
            log.notice("battery state=\(battery?.status.map { "\($0.percent)% \($0.chargeState)" } ?? "-", privacy: .public) shown=\(battery?.isShown ?? false, privacy: .public) animation=\(battery?.chargingAnimation ?? false, privacy: .public) completions=\(battery?.chargeAnimation.completions ?? -1, privacy: .public) effects=\(effects.map { "\($0.activeAnimations)/particles:\($0.particles.birthRate)/\(Int($0.bounds.width))x\(Int($0.bounds.height))" }.joined(separator: ","), privacy: .public) glows=\(glows.map(\.isAnimating), privacy: .public)")
        case "context:state":
            context.refresh()
            log.notice("context updates=\(self.context.updates, privacy: .public) took=\(self.context.lastDuration, privacy: .public) sources=\(self.context.sources.count, privacy: .public) errors=\(self.context.errors.keys.sorted().joined(separator: ","), privacy: .public) workspace=\(self.context.snapshot.workspace?.name ?? "-", privacy: .public) agents=\(self.context.snapshot.agents.count, privacy: .public) tasks=\(self.context.snapshot.openTasks.count, privacy: .public) focus=\(ContextDiff.describe(self.context.snapshot.focus), privacy: .public) battery=\(self.context.snapshot.battery.map { "\($0.percent)" } ?? "-", privacy: .public) shown=\(self.context.shown.map { "\($0.suggestion.kind)(\($0.score))" }.joined(separator: ","), privacy: .public) held=\(self.context.suppressed.map { "\($0.suggestion.kind):\($0.reason)" }.joined(separator: "; "), privacy: .public) events=\(self.context.events.count, privacy: .public)")
        case "launcher:open": launcherPanel?.present()
        case "launcher:close": launcherPanel?.dismiss()
        case let command? where command.hasPrefix("launcher:query:"):
            launcher.query = String(command.dropFirst("launcher:query:".count))
            Task { @MainActor [launcher, launcherPanel] in
                try? await Task.sleep(for: .milliseconds(900))
                log.notice("launcher visible=\(launcherPanel?.isVisible ?? false, privacy: .public) key=\(launcherPanel?.isKeyWindow ?? false, privacy: .public) query=\(launcher.query, privacy: .public) took=\(launcher.lastSearchDuration, privacy: .public) results=\(launcher.results.prefix(8).map { "\($0.kind.rawValue):\($0.title)" }.joined(separator: " | "), privacy: .public)")
            }
        case "brightness:displays":
            let widget = dashboard.registry.widget("brightness") as? BrightnessWidget
            widget?.start()
            Task { @MainActor in
                try? await Task.sleep(for: .milliseconds(400))
                log.notice("brightness displays=\(widget?.displays.map { "\($0.name):\($0.isBuiltIn ? "built-in" : "external"):\($0.level.map { String(format: "%.3f", $0) } ?? "unreadable")" }.joined(separator: ", ") ?? "-", privacy: .public) monitor=\(widget?.monitor?.isRunning ?? false, privacy: .public)")
                widget?.stop()
                log.notice("brightness after stop monitor=\(widget?.monitor?.isRunning ?? false, privacy: .public)")
            }
        case "energy:start": EnergyMonitor.shared.start(client: "debug")
        case "energy:stop": EnergyMonitor.shared.stop(client: "debug")
        case "energy:state":
            let text: String = switch EnergyMonitor.shared.state {
            case .ready(let apps, let measured, _):
                (measured ? "measured " : "cpu-estimate ") + apps.map { "\($0.name)=\($0.watts.map { String(format: "%.2fW", $0) } ?? "-")/\(String(format: "%.0f%%", $0.cpuPercent))/\($0.processes)p/\($0.level.rawValue)" }.joined(separator: ", ")
            default: String(describing: EnergyMonitor.shared.state)
            }
            log.notice("energy running=\(EnergyMonitor.shared.isRunning, privacy: .public) took=\(EnergyMonitor.shared.lastSampleDuration, privacy: .public) \(text, privacy: .public)")
        case "pill:expand": contextPill.toggle()
        case "pill:collapse": contextPill.collapse()
        case let command? where command.hasPrefix("pill:render:"):
            // The pill's own window, captured from its layer (no screen recording): what's on screen now.
            if let view = contextPillPanel?.contentView, let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) {
                view.cacheDisplay(in: view.bounds, to: rep)
                let ok = (try? rep.representation(using: .png, properties: [:])?.write(to: URL(filePath: String(command.dropFirst("pill:render:".count))))) != nil
                log.notice("pill render \(ok, privacy: .public)")
            }
        case "quick:state":
            let quick = dashboard.registry.widget("quickActions") as? QuickActionsWidget
            log.notice("quick suggested=\(quick.map { ContextAction.suggest($0.context()).map(\.title).joined(separator: "|") } ?? "-", privacy: .public)")
        case "meeting:state":
            log.notice("meeting watcher=\(self.meetings?.isRunning ?? false, privacy: .public) cue=\(self.meetings?.cue.map { "\($0.phase):\($0.countdown(at: .now))" } ?? "-", privacy: .public) wings=\(self.wings.content.map { String(describing: $0).prefix(40) } ?? "-", privacy: .public) visible=\(self.wingsPanel?.isVisible ?? false, privacy: .public)")
        case let command? where command.hasPrefix("meeting:"):
            meetings?.debugSimulate(minutes: Double(command.dropFirst("meeting:".count)))
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
            // brightness:<0…1> simulates a reading; brightness:state logs the level and which sources noticed changes.
            if parts.first == "brightness", parts.count == 2, let monitor = sonicPulse?.brightness {
                if let value = Double(parts[1]) { monitor.debugSimulate(value); return }
                log.notice("brightness state running=\(monitor.isRunning, privacy: .public) level=\(monitor.level.map { String(format: "%.3f", $0) } ?? "none", privacy: .public) presses=\(monitor.presses, privacy: .public) noticed=\(monitor.noticed.map { "\($0.key.rawValue):\($0.value)" }.sorted().joined(separator: ","), privacy: .public) hud=\(String(describing: self.overlay.brightness.phase), privacy: .public) overlay=\(String(describing: self.overlay.overlay), privacy: .public)")
                return
            }
            if parts.first == "volumehud", parts.count == 2 { setVolumeHUD(parts[1] == "on"); return }
            // The cat rig's preview window: pet:preview[:single], pet:state:<idle|playful|…>,
            // pet:reducemotion:on|off, pet:fidget, pet:react, pet:face:left|right, pet:close.
            // The Desktop Pet, in memory only: pet:desktop:on|off, pet:walk, pet:run, pet:click.
            if parts == ["pet", "desktop", "on"] || parts == ["pet", "desktop", "off"] {
                let on = parts[2] == "on"
                pet.toggles.pet = on
                pet.toggles.desktop = on
                pet.toggles.companion = false  // not built yet (a later stage)
                return
            }
            // pet:character:<id|none>: attach a character in memory (preferences untouched); pet:skin logs what it did.
            if parts.count == 3, parts[0] == "pet", parts[1] == "character" {
                var look = preferences.value.petLook
                look.character = parts[2] == "none" ? nil : parts[2]
                applyCharacter(look)
                return
            }
            // pet:select:<id>: the Settings picker's path (preferences update → both renderers → saved).
            if parts.count == 3, parts[0] == "pet", parts[1] == "select" {
                preferences.update { $0.petLook.character = parts[2] }
                return
            }
            // pet:uncovered: as if no window covered the pet (occlusion off, in memory), to test wandering.
            if parts == ["pet", "uncovered"] { petActivity.setDesktopOccluded(false); return }
            if parts == ["pet", "selection"] {
                let look = preferences.value.petLook
                log.notice("pet selection saved=\(look.character ?? "nil", privacy: .public) coat=\(look.coat, privacy: .public) shown=\(String(describing: self.petSelection), privacy: .public) desktop=\(self.desktopPet?.rig.skin?.characterID ?? "illustrated", privacy: .public) notch=\(self.companionCharacter?.rig.skin?.characterID ?? "illustrated", privacy: .public)")
                return
            }
            if parts == ["pet", "skin"] {
                let skin = desktopPet?.rig.skin as? RivePetSkin
                log.notice("pet skin \(skin?.characterID ?? "none", privacy: .public) playing=\(skin?.isPlaying ?? false, privacy: .public) link=\(skin?.displayLinkRunning ?? false, privacy: .public) state=\(skin?.state?.rawValue ?? "-", privacy: .public) applied=\(skin?.applied.suffix(6).joined(separator: ",") ?? "-", privacy: .public) cached=\(PetCharacterLibrary.shared.cachedCount, privacy: .public)")
                return
            }
            if parts == ["pet", "walk"] || parts == ["pet", "run"] { pet.startMoving(running: parts[1] == "run"); return }
            // The Notch Companion, in memory: pet:companion:on|off, companion:state|tap|collapse|next,
            // and dashboard:toggle (the ⌃⌥⌘O path).
            if parts.count == 3, parts[0] == "pet", parts[1] == "companion" {
                pet.toggles.pet = parts[2] == "on" || pet.toggles.desktop && pet.toggles.pet
                pet.toggles.companion = parts[2] == "on"
                updateNotchPolicy(preferences.value)
                return
            }
            if parts == ["dashboard", "toggle"] { panel?.toggleFromKeyboard(); return }
            // render:system:<pane>:<absolute .png path>: the System tab's pane, drawn offscreen
            // (no Screen Recording needed). Reads live data first, then renders after the scan.
            // render:dashboard:<section>:<path>: the whole open dashboard over a wallpaper-like backdrop.
            if parts.count == 4, parts[0] == "render", parts[1] == "dashboard", let section = DashboardSection(rawValue: parts[2]) {
                renderDashboard(section, to: parts[3])
                return
            }
            // render:briefing:<path>: the Briefing tab with live data (widgets started first).
            if parts.count == 3, parts[0] == "render", parts[1] == "briefing" {
                renderBriefing(to: parts[2])
                return
            }
            if parts.count == 4, parts[0] == "render", parts[1] == "system", let pane = SystemPane(rawValue: parts[2]) {
                renderSystem(pane, to: parts[3])
                return
            }
            if parts.first == "companion", parts.count == 2 {
                switch parts[1] {
                case "tap": companion.tap()
                case "collapse": companion.collapse()
                case "next": companion.selectNext(1)
                default:
                    let row = companion.selectedRow
                    log.notice("""
                        companion state \(self.companion.phase.rawValue, privacy: .public) rows=\(self.companion.rows.count, privacy: .public) \
                        lead=\(self.companion.lead.map { "\($0.session.key.agent):\($0.tone):\($0.headline)" } ?? "-", privacy: .public) \
                        selected=\(row?.session.title ?? "-", privacy: .public) changes=\(self.companion.changes?.files.count ?? -1, privacy: .public) \
                        diff=\(self.companion.diffPath ?? "-", privacy: .public) flash=\(self.companion.flash.map { "\($0.tone)" } ?? "-", privacy: .public) \
                        panel=\(NSStringFromRect(self.companionPanel?.frame ?? .zero), privacy: .public)/visible=\(self.companionPanel?.isVisible ?? false, privacy: .public)/onSpace=\(self.companionPanel?.isOnActiveSpace ?? false, privacy: .public)/key=\(self.companionPanel?.isKeyWindow ?? false, privacy: .public) \
                        occluded=\(self.petActivity.conditions.companionOccluded, privacy: .public) cat=\(self.companionCharacter?.isFollowing ?? false, privacy: .public)/\(self.pet.state.rawValue, privacy: .public)/cues=\(self.companionCharacter?.rig.cuesPlayed ?? 0, privacy: .public)/anims=\(self.companionCharacter?.rig.animationCount ?? 0, privacy: .public)/repeating=\(self.companionCharacter?.rig.repeatingAnimationCount ?? 0, privacy: .public) \
                        mood=\(self.pet.agentMood.rawValue, privacy: .public) alerts=\(self.aiHub.alerts.isEnabled, privacy: .public) owner=\(self.notchOwner.rawValue, privacy: .public) \
                        trigger=\(self.panel?.ignoresMouseEvents ?? false ? "yielded" : "orbit", privacy: .public) dashboard=\(self.interaction.isOpen, privacy: .public)
                        """)
                }
                return
            }
            if parts == ["pet", "click"] { pet.click(); return }
            // The AI Hub, in memory only (Settings › AI Hub saves): aihub:on|off, aihub:demo:on|off|clear.
            if parts == ["aihub", "on"] || parts == ["aihub", "off"] { aiHub.set(enabled: parts[1] == "on", demo: aiHub.isDemoEnabled); return }
            if parts == ["aihub", "demo", "clear"] { Task { await aiHub.clearDemoData() }; return }
            if parts.count == 3, parts[0] == "aihub", parts[1] == "page", let page = AgentBrowser.Page(rawValue: parts[2].capitalized) {
                aiHub.browser.page = page
                return
            }
            if parts.count == 3, parts[0] == "aihub", parts[1] == "demo" { aiHub.set(enabled: aiHub.isEnabled, demo: parts[2] == "on"); return }
            if parts.first == "aihub", aiHubCheck(Array(parts.dropFirst())) { return }
            // coucou:watch:<bundle ID>|default: which app counts as Coucou, in memory (to try launch/quit live
            // with a harmless app); coucou:state: what Orbit makes of it.
            if parts.count == 3, parts[0] == "coucou", parts[1] == "watch" {
                coucou.bundleIDs = parts[2] == "default" ? CoucouPresence.bundleIDs : [parts[2]]
                coucou.refresh(force: true)
                return
            }
            if parts == ["coucou", "state"] {
                log.notice("""
                    coucou state \(self.coucou.state.kind.rawValue, privacy: .public) installed=\(self.coucou.state.installed.map { $0.path(percentEncoded: false) }.joined(separator: ","), privacy: .public) \
                    owner=\(self.notchOwner.rawValue, privacy: .public) alerts=\(self.aiHub.alerts.isEnabled, privacy: .public) \
                    companionOccluded=\(self.petActivity.conditions.companionOccluded, privacy: .public) answersClaude=\(self.aiHub.coucouAnswersClaude, privacy: .public) \
                    alertVisible=\(self.alertPanel?.isVisible ?? false, privacy: .public) mood=\(self.pet.agentMood.rawValue, privacy: .public)
                    """)
                return
            }
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
