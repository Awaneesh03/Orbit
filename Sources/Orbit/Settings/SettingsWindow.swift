import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case welcome, general, launcher, workspaces, suggestions, contextInspector, appearance, pet, aiHub, widgets, calendar, weather, privacy, storage, about
    var id: Self { self }

    /// Words that find a section in the sidebar search and the launcher (Milestone 16).
    var keywords: String {
        switch self {
        case .welcome: "get started onboarding introduction shortcuts permissions"
        case .suggestions: "suggestions proactive suggested for you snooze learning history focus briefing categories"
        case .contextInspector: "context inspector diagnostics debug events rules engine"
        case .general: "notch hide delay music island volume brightness hud compact wings pill status meeting heads-up automations battery energy charging animation"
        case .launcher: "launcher search shortcut spotlight files apps recent history keyboard"
        case .workspaces: "workspace profile development college fixkaru personal projects apps layout"
        case .appearance: "theme dark light opacity spacing reduce motion"
        case .pet: "cat dog companion desktop character coat"
        case .aiHub: "agents claude codex alerts quiet hours notifications coucou hooks chat"
        case .widgets: "overview briefing layout widgets"
        case .calendar: "events calendars eventkit meetings join"
        case .weather: "forecast city units location"
        case .privacy: "permissions location bluetooth calendar privacy data"
        case .storage: "vault screenshots disk cleanup export"
        case .about: "version licences credits"
        }
    }

    var title: String {
        switch self {
        case .welcome: "Get Started"
        case .suggestions: "Suggestions"
        case .contextInspector: "Context Inspector"
        case .launcher: "Launcher"
        case .workspaces: "Workspaces"
        case .general: "General"
        case .appearance: "Appearance"
        case .pet: "Pet"
        case .aiHub: "AI Hub"
        case .widgets: "Widgets"
        case .calendar: "Calendar"
        case .weather: "Weather"
        case .privacy: "Privacy & Permissions"
        case .storage: "Storage"
        case .about: "About Orbit"
        }
    }

    var symbol: String {
        switch self {
        case .welcome: "hand.wave"
        case .suggestions: "lightbulb"
        case .contextInspector: "stethoscope"
        case .launcher: "magnifyingglass"
        case .workspaces: "square.stack.3d.up"
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .pet: "pawprint"
        case .aiHub: "sparkles"
        case .widgets: "square.grid.2x2"
        case .calendar: "calendar"
        case .weather: "cloud.sun"
        case .privacy: "hand.raised"
        case .storage: "internaldrive"
        case .about: "info.circle"
        }
    }
}

/// Settings state. Widgets are edited through the dashboard's own model and
/// registry, so there is one layout and one source of truth.
@MainActor @Observable
final class SettingsModel {
    var section = SettingsSection.general
    let dashboard: DashboardModel
    let preferences: PreferencesModel
    let briefing: BriefingPreferencesModel
    let dataDirectory: URL
    let exportRoot: URL
    let aiHub: AIHubService?
    /// For the automations' recent runs (set by the app).
    var automations: Automations?
    /// Milestone 17 (set by the app).
    var context: ContextEngine?
    /// Milestone 16 (set by the app).
    var workspaces: Workspaces?
    var launcher: LauncherModel?
    /// nil: no shortcut chosen; false: another app holds it.
    var launcherShortcutAvailable: Bool?
    @ObservationIgnored var useCurrentLayout: @MainActor () -> WidgetLayout? = { nil }
    @ObservationIgnored var activateWorkspace: @MainActor (UUID?) -> Void = { _ in }
    @ObservationIgnored var openWorkspace: @MainActor (UUID) -> Void = { _ in }
    /// The sidebar's search.
    var search = ""
    var editingWorkspace: UUID?

    /// Sections whose title or keywords match the sidebar search.
    var visibleSections: [SettingsSection] {
        let words = search.lowercased().split(separator: " ")
        guard !words.isEmpty else { return SettingsSection.allCases }
        return SettingsSection.allCases.filter { section in
            let text = (section.title + " " + section.keywords).lowercased()
            return words.allSatisfy { text.contains($0) }
        }
    }
    private(set) var storage: StorageReport?
    private(set) var loginEnabled = false
    private(set) var loginMessage: String?
    private(set) var cleanupMessage: String?
    var confirmingRebuild = false
    private(set) var rebuildFeedback: VaultWidget.Feedback?

    init(dashboard: DashboardModel, preferences: PreferencesModel,
         briefing: BriefingPreferencesModel = BriefingPreferencesModel(file: nil), dataDirectory: URL,
         exportRoot: URL = ScreenshotVault.exportRoot, aiHub: AIHubService? = nil) {
        self.aiHub = aiHub
        self.dashboard = dashboard
        self.preferences = preferences
        self.briefing = briefing
        self.dataDirectory = dataDirectory
        self.exportRoot = exportRoot
    }

    var vaultWidget: VaultWidget? { dashboard.registry.widget("vault") as? VaultWidget }
    var vault: ScreenshotVault? { vaultWidget?.vault }

    /// Only after the user confirms; see `ScreenshotVault.rebuild`.
    func rebuildVault() {
        rebuildFeedback = vaultWidget?.rebuildIndex()
        refresh()
    }

    /// Re-reads what can change behind Orbit's back (disk usage, Login Items).
    func refresh() {
        storage = StorageInspector.report(vault: vault, exportRoot: exportRoot)
        loginEnabled = LoginItem.isEnabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            try LoginItem.set(enabled)
            loginMessage = LoginItem.needsApproval ? "Approve Orbit in System Settings › General › Login Items." : nil
        } catch {
            loginMessage = "macOS didn't accept the change: \(error.localizedDescription)"
        }
        loginEnabled = LoginItem.isEnabled
    }

    /// Removes expired drag copies only (temporary folder); never Vault screenshots.
    func cleanUpDragCopies(olderThan maxAge: TimeInterval = 600) {
        let removed = ScreenshotVault.removeExports(in: exportRoot, olderThan: maxAge)
        cleanupMessage = removed == 0 ? "No expired drag copies." : "Removed \(removed) expired drag cop\(removed == 1 ? "y" : "ies")."
        storage = StorageInspector.report(vault: vault, exportRoot: exportRoot)
    }
}

/// The single Settings window. It is created once and reused (not released
/// on close), so it can't be duplicated, and closing it doesn't quit Orbit.
@MainActor
final class SettingsWindowController {
    /// Posted by a widget to open Settings at a pane (object: the section's raw value).
    static let showRequest = Notification.Name("com.awaneeshgupta.orbit.showSettings")

    let model: SettingsModel
    private(set) var window: NSWindow?

    init(model: SettingsModel) {
        self.model = model
    }

    @discardableResult
    func prepareWindow() -> NSWindow {
        if let window { return window }
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 780, height: 520),
            styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
            backing: .buffered, defer: true)
        window.title = "Orbit Settings"
        window.isReleasedWhenClosed = false
        // Opens on the current Space, including over a full-screen app.
        window.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        window.contentViewController = NSHostingController(rootView: SettingsView(model: model))
        window.setContentSize(NSSize(width: 780, height: 520))
        window.appearance = model.preferences.value.appearance.nsAppearance
        window.center()
        self.window = window
        return window
    }

    /// An explicit request from the user, so Orbit activates for it.
    func show(section: SettingsSection? = nil) {
        if let section { model.section = section }
        let window = prepareWindow()
        model.refresh()
        NSApp.activate()
        window.makeKeyAndOrderFront(nil)
    }

    func apply(_ appearance: AppearancePreference) {
        window?.appearance = appearance.nsAppearance
    }
}

private struct SettingsView: View {
    let model: SettingsModel

    var body: some View {
        NavigationSplitView {
            List(model.visibleSections, selection: Binding(
                get: { model.section }, set: { if let section = $0 { model.section = section } }
            )) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .searchable(text: Binding(get: { model.search }, set: { model.search = $0 }), placement: .sidebar, prompt: "Search Settings")
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch model.section {
                case .welcome: WelcomeSettings(model: model)
                case .suggestions: SuggestionSettings(model: model)
                case .contextInspector: ContextInspectorSettings(model: model)
                case .launcher: LauncherSettings(model: model)
                case .workspaces: WorkspaceSettings(model: model)
                case .general: GeneralSettings(model: model)
                case .appearance: AppearanceSettings(preferences: model.preferences)
                case .pet: PetSettings(preferences: model.preferences)
                case .aiHub: AIHubSettings(preferences: model.preferences, hub: model.aiHub)
                case .widgets: WidgetSettings(dashboard: model.dashboard, briefing: model.briefing)
                case .privacy: PrivacySettings()
                case .storage: StorageSettings(model: model)
                case .about: AboutSettings(model: model)
                case .weather: WeatherSettingsPane(widget: model.dashboard.registry.widget("weather") as? WeatherWidget)
                case .calendar: CalendarSettingsPane(widget: model.dashboard.registry.widget("events") as? EventsWidget)
                }
            }
            .formStyle(.grouped)
            .navigationTitle(model.section.title)
        }
        .frame(minWidth: 780, minHeight: 520)
    }
}

private struct GeneralSettings: View {
    let model: SettingsModel

    var body: some View {
        let preferences = model.preferences
        Form {
            if let problem = preferences.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("Changes aren't saved until you reset. The unreadable file is kept beside the new one.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Reset All Preferences") { preferences.resetAll() }
                }
            }
            Section("Startup") {
                Toggle("Launch Orbit at login", isOn: Binding(
                    get: { model.loginEnabled }, set: { model.setLaunchAtLogin($0) }))
                if let message = model.loginMessage {
                    Text(message).font(.callout).foregroundStyle(.secondary)
                }
            }
            Section("Dashboard") {
                LabeledContent("Opens", value: "When the pointer enters the notch")
                Slider(value: Binding(get: { preferences.value.hideDelay },
                                      set: { value in preferences.update { $0.hideDelay = value } }),
                       in: OrbitPreferences.hideDelayRange, step: 0.1) {
                    Text("Close delay")
                }
                Text(String(format: "Closes %.1f s after the pointer leaves. Escape, a click outside or a Space change close it at once.",
                            preferences.value.hideDelay))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Music Island") {
                Toggle("Announce new tracks below the notch", isOn: Binding(
                    get: { preferences.value.musicIsland }, set: { value in preferences.update { $0.musicIsland = value } }))
                Slider(value: Binding(get: { preferences.value.musicIslandSeconds },
                                      set: { value in preferences.update { $0.musicIslandSeconds = value } }),
                       in: OrbitPreferences.musicIslandSecondsRange, step: 1) {
                    Text("Hide after")
                }
                .disabled(!preferences.value.musicIsland)
                Text(String(format: "When a track or video starts, a small player appears for %.0f s; click it for the full player. Playback, the Now Playing widget and the dashboard aren't affected.",
                            preferences.value.musicIslandSeconds))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Compact Notch") {
                Picker("Compact style", selection: Binding(get: { preferences.value.compactStyle },
                                                           set: { value in preferences.update { $0.compactStyle = value } })) {
                    ForEach(CompactStyle.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Beside the camera: what's playing and which agent needs you sit in two small wings either side of the notch, which never take a click. Hover the notch for everything else. Notched Macs only.")
                    .font(.callout).foregroundStyle(.secondary)
                Picker("Status display", selection: Binding(get: { preferences.value.statusDisplay },
                                                            set: { value in preferences.update { $0.statusDisplay = value } })) {
                    ForEach(StatusDisplay.allCases, id: \.self) { Text($0.title).tag($0) }
                }
                Text("Meetings and agents that need you. Automatic: the wings beside the camera when the main display has a notch and the style above is “Beside the camera”; otherwise a small floating pill below the menu bar (an external display has no notch, so Orbit doesn't draw one). Click the pill for Join, Calendar or the agent.")
                    .font(.callout).foregroundStyle(.secondary)
                Toggle("Next meeting heads-up", isOn: Binding(
                    get: { preferences.value.meetingHeadsUp }, set: { value in preferences.update { $0.meetingHeadsUp = value } }))
                    .disabled(preferences.value.statusDisplay == .off)
                Stepper(value: Binding(get: { preferences.value.meetingNoticeMinutes },
                                       set: { value in preferences.update { $0.meetingNoticeMinutes = value } }),
                        in: OrbitPreferences.meetingNoticeRange, step: 5) {
                    Text("Heads-up \(preferences.value.meetingNoticeMinutes) min before")
                }
                .disabled(preferences.value.statusDisplay == .off || !preferences.value.meetingHeadsUp)
                Stepper(value: Binding(get: { preferences.value.meetingUrgentMinutes },
                                       set: { value in preferences.update { $0.meetingUrgentMinutes = value } }),
                        in: OrbitPreferences.meetingUrgentRange) {
                    Text("Reminder \(preferences.value.meetingUrgentMinutes) min before")
                }
                .disabled(preferences.value.statusDisplay == .off || !preferences.value.meetingHeadsUp)
                Text("Uses the calendars chosen in the Calendar widget, only if Orbit already has calendar access. All-day, cancelled and finished events never show; a meeting leaves the wings a few minutes after it starts. A meeting with a Google Meet, Zoom, Teams or other https link gets a Join button (in the pill and the dashboard's suggestions); it opens only when you click it.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Toggle(isOn: Binding(get: { preferences.value.batteryEnergy }, set: { value in preferences.update { $0.batteryEnergy = value } })) {
                    Text("Apps Using Significant Energy")
                    Text("In the Battery widget: macOS's own per-process energy estimate, grouped by app, sampled every 5 seconds only while the widget is on screen.")
                }
                Toggle(isOn: Binding(get: { preferences.value.chargingAnimation }, set: { value in preferences.update { $0.chargingAnimation = value } })) {
                    Text("Charging animation")
                    Text("A quiet current through the battery while the Mac is actually charging (not just plugged in). Off with Reduce Motion.")
                }
                LabeledContent {
                    Button(model.dashboard.layout.items.first { $0.id == "brightness" }?.isEnabled == true ? "On the Overview" : "Add to Overview") {
                        model.dashboard.setEnabled("brightness", true)
                    }
                    .disabled(model.dashboard.layout.items.first { $0.id == "brightness" }?.isEnabled == true)
                } label: {
                    Text("Brightness")
                    Text("Shows the built-in display's real brightness level (read-only; macOS doesn't let apps change it). External displays report brightness over DDC/CI, which needs a private macOS interface, so they show as not readable.")
                }
            } header: {
                Text("Battery and Brightness")
            }
            AutomationsSection(preferences: preferences, runs: model.automations?.history ?? [])
            Section("Volume and Brightness") {
                Toggle("Show Volume HUD", isOn: Binding(
                    get: { preferences.value.volumeHUD }, set: { value in preferences.update { $0.volumeHUD = value } }))
                Toggle("Show Brightness HUD", isOn: Binding(
                    get: { preferences.value.brightnessHUD }, set: { value in preferences.update { $0.brightnessHUD = value } }))
                Slider(value: Binding(get: { preferences.value.hudSeconds }, set: { value in preferences.update { $0.hudSeconds = value } }),
                       in: OrbitPreferences.hudSecondsRange, step: 0.5) {
                    Text("Stay for")
                }
                .disabled(!preferences.value.volumeHUD && !preferences.value.brightnessHUD)
                Text(String(format: "Shows the volume, mute or screen brightness below the notch when they change, for %.1f s. They never cover the dashboard or the full player. Orbit only shows these levels; it doesn't change them (macOS offers apps no way to set brightness).",
                            preferences.value.hudSeconds))
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section {
                Button("Reset General Settings") { preferences.resetGeneral() }
            }
        }
    }
}

private struct AppearanceSettings: View {
    let preferences: PreferencesModel

    var body: some View {
        Form {
            Section("Theme") {
                Picker("Appearance", selection: Binding(
                    get: { preferences.value.appearance }, set: { value in preferences.update { $0.appearance = value } })) {
                    ForEach(AppearancePreference.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Text("Applies to Orbit's windows. The notch dashboard stays dark so it blends with the camera housing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Dashboard") {
                Slider(value: Binding(get: { preferences.value.dashboardOpacity },
                                      set: { value in preferences.update { $0.dashboardOpacity = value } }),
                       in: OrbitPreferences.opacityRange) {
                    Text("Background")
                } minimumValueLabel: { Text("Glassier") } maximumValueLabel: { Text("Solid") }
                Picker("Widget spacing", selection: Binding(
                    get: { preferences.value.widgetSpacing }, set: { value in preferences.update { $0.widgetSpacing = value } })) {
                    ForEach(WidgetSpacing.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Reduce motion", isOn: Binding(
                    get: { preferences.value.reduceMotion }, set: { value in preferences.update { $0.reduceMotion = value } }))
            }
            Section {
                Button("Restore Default Appearance") { preferences.resetAppearance() }
            }
        }
    }
}

/// Settings › Pet: the master switch and the two experiences. Each keeps its
/// own choice while the master is off, so turning it back on restores them.
private struct PetSettings: View {
    let preferences: PreferencesModel

    var body: some View {
        let master = preferences.value.orbitPet
        Form {
            if let problem = preferences.problem {
                Section {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("These switches can't change until you reset preferences in General.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
            Section {
                Toggle(isOn: binding(\.orbitPet)) {
                    Text("Enable Orbit Pet")
                    Text("A small cat that keeps you company. Turning it off hides it everywhere and keeps the choices below.")
                }
            }
            Section {
                Toggle(isOn: binding(\.desktopPet)) {
                    Text("Desktop Pet")
                    Text("Lives on your desktop, behind your windows. It wanders now and then, and you can click or drag it. Never over full-screen apps.")
                }
                Toggle(isOn: binding(\.notchCompanion)) {
                    Text("Notch Companion")
                    Text("Peeks out below the notch and shows what your AI agents are doing; click it for sessions, files and diffs. Steps aside for the dashboard, the music island, the volume HUD and Coucou, and stands in for agent alerts.")
                }
            } header: {
                Text("Where It Appears")
            } footer: {
                if !master { Text("Turn on Orbit Pet to use these.") }
            }
            .disabled(!master)
            Section {
                let look = preferences.value.petLook
                let library = PetCharacterLibrary.shared
                let characters = library.available(includeTest: look.showTestCharacters)
                HStack(alignment: .top, spacing: 14) {
                    if let preview = PetSelection.preview(look, library: library) {
                        Image(decorative: preview, scale: 2).resizable().interpolation(.high).scaledToFit()
                            .frame(width: 72, height: 72)
                            .accessibilityLabel("Preview of the selected pet")
                    }
                    VStack(alignment: .leading, spacing: 6) {
                        Picker("Pet", selection: Binding(get: { look.character ?? PetLook.builtIn },
                                                         set: { id in preferences.update { $0.petLook.character = id } })) {
                            ForEach(characters, id: \.manifest.id) { entry in
                                Text("\(entry.manifest.name) (\(entry.manifest.species.rawValue))\(entry.manifest.production ? "" : " · test")")
                                    .tag(entry.manifest.id)
                            }
                            Text("Orbit illustrated (choose a coat below)").tag(PetLook.builtIn)
                        }
                        switch PetSelection.resolve(look, library: library) {
                        case .fallback(_, let reason):
                            Label("\(reason) Orbit's illustrated pet is shown instead.", systemImage: "exclamationmark.triangle")
                                .font(.callout).foregroundStyle(.orange)
                        case .character(let id, _):
                            if let entry = characters.first(where: { $0.manifest.id == id }) {
                                Text("\(entry.manifest.licence.type) · \(entry.manifest.licence.attribution)")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                        case .builtIn:
                            EmptyView()
                        }
                    }
                }
                TextField("Name", text: Binding(get: { look.name }, set: { name in preferences.update { $0.petLook.name = String(name.prefix(40)) } }),
                          prompt: Text("Optional"))
                Toggle("Show test characters", isOn: Binding(get: { look.showTestCharacters },
                                                             set: { on in preferences.update { $0.petLook.showTestCharacters = on } }))
            } header: {
                Text("Pet")
            } footer: {
                Text("The same pet appears on the desktop and below the notch. Characters come with Orbit or from ~/Library/Application Support/Orbit/Pets; if one can't be loaded, Orbit's illustrated pet is shown and the reason appears here.")
            }
            if (preferences.value.petLook.character ?? PetLook.builtIn) == PetLook.builtIn {
                Section {
                    let look = preferences.value.petLook
                    Picker("Coat", selection: Binding(get: { look.coat }, set: { coat in preferences.update { $0.petLook.coat = coat } })) {
                        Section("Cats") {
                            ForEach(PetAppearance.presets.filter { $0.appearance.species == .cat }, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        Section("Dogs") {
                            ForEach(PetAppearance.presets.filter { $0.appearance.species == .dog }, id: \.id) { Text($0.name).tag($0.id) }
                        }
                        if look.photoPrimary != nil {
                            Text("From your photo (\(look.photoSpecies == .dog ? "dog" : "cat"))").tag("photo")
                        }
                    }
                    HStack {
                        Button("Use a Photo of a Cat…") { choosePhoto(.cat) }
                        Button("Use a Photo of a Dog…") { choosePhoto(.dog) }
                    }
                } header: {
                    Text("Coat (Orbit illustrated)")
                } footer: {
                    Text("A photo is read on this Mac to pick your pet's coat colours. Only the colours are kept; the photo is never stored or sent anywhere.")
                }
            }
            Section {
                let behavior = preferences.value.petLook.behavior
                Toggle("Wander around the desktop", isOn: Binding(get: { behavior.roaming },
                                                                  set: { on in preferences.update { $0.petLook.behavior.roaming = on } }))
                Toggle("Idle gestures (blinks, stretches, looking around)", isOn: Binding(get: { behavior.idleGestures },
                                                                                          set: { on in preferences.update { $0.petLook.behavior.idleGestures = on } }))
                Picker("Liveliness", selection: Binding(get: { behavior.liveliness },
                                                        set: { value in preferences.update { $0.petLook.behavior.liveliness = value } })) {
                    Text("Calm").tag(PetBehavior.Liveliness.calm)
                    Text("Normal").tag(PetBehavior.Liveliness.normal)
                    Text("Lively").tag(PetBehavior.Liveliness.lively)
                }
                Button("Reset Pet Customisation") { preferences.update { $0.petLook = PetLook() } }
            } header: {
                Text("Behaviour")
            } footer: {
                Text("Reduce Motion (Orbit's or the system's) keeps the pet still whatever is chosen here.")
            }
        }
    }

    private func choosePhoto(_ species: PetAppearance.Species) {
        Task { @MainActor in
            guard let look = await PetPhotoPalette.chooseLook(species: species) else { return }
            preferences.update { $0.petLook = look }
        }
    }

    private func binding(_ key: WritableKeyPath<OrbitPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.value[keyPath: key] }, set: { value in preferences.update { $0[keyPath: key] = value } })
    }
}

/// Settings › AI Hub (docs/AI_HUB_SPEC.md §14, P1-1): the master switch, the
/// bridge's health, agents found on this Mac and demo mode. Simulated
/// sessions are always labelled; nothing here connects a real agent yet.
private struct AIHubSettings: View {
    let preferences: PreferencesModel
    let hub: AIHubService?

    var body: some View {
        let value = preferences.value
        Form {
            Section("General") {
                Toggle(isOn: Binding(get: { value.aiHub }, set: { on in preferences.update { $0.aiHub = on } })) {
                    Text("Enable AI Hub")
                    Text("Lets AI coding agents on this Mac report their activity to Orbit over a private local socket. No network, no accounts. Agents are connected in a later update.")
                }
            }
            if let hub, value.aiHub {
                Section("Connection Health") {
                    LabeledContent("Agent bridge", value: bridgeText(hub.health.bridge))
                    LabeledContent("History", value: storeText(hub.health.store))
                    let counters = hub.health.counters
                    LabeledContent("Events received", value: "\(counters.accepted)")
                    if counters.invalid + counters.rateLimited + counters.refusedConnections + counters.unattributed + counters.unanswerable + hub.health.unsavedEvents > 0 {
                        LabeledContent("Rejected or dropped", value: "\(counters.invalid) invalid · \(counters.unattributed) unknown · \(counters.rateLimited + counters.refusedConnections) over limits · \(counters.unanswerable) requests Orbit can't answer · \(hub.health.unsavedEvents) unsaved")
                    }
                }
                Section("Notifications") {
                    Toggle(isOn: Binding(get: { value.aiHubAlerts }, set: { on in preferences.update { $0.aiHubAlerts = on } })) {
                        Text("Agent alerts below the notch")
                        Text("A short note when an agent needs approval, is waiting for you, fails or finishes. Never over the dashboard, the music island or the volume HUD.")
                    }
                    if value.aiHubAlerts {
                        AgentAlertRulesForm(preferences: preferences, alerts: hub.alerts)
                    }
                    LabeledContent {
                        Text(hub.coucou.summary).foregroundStyle(.secondary)
                    } label: {
                        Text("Coucou")
                        Text(hub.coucou.isRunning
                             ? "Coucou has the notch: Orbit's alerts, companion, music island and volume HUD stay out of it while it runs. Open the dashboard with \(DashboardHotKey.label)."
                             : "Another notch companion. When it runs, Orbit steps aside in the notch (the dashboard opens with \(DashboardHotKey.label)). Orbit never changes it.")
                    }
                }
                Section {
                    ForEach(hub.agents) { agent in
                        LabeledContent {
                            Text(agent.isInstalled ? "Installed" : "Not found").foregroundStyle(.secondary)
                        } label: {
                            Text(agent.name)
                            if let path = agent.path { Text(path) }
                        }
                    }
                } header: {
                    Text("Agent Integrations")
                } footer: {
                    Text("Found by their usual install locations only; Orbit doesn't run them or change their settings. Installed doesn't mean connected.")
                }
                ClaudeHooksSection(hub: hub)
                Section {
                    if hub.manifests.adapters.isEmpty && hub.manifests.problems.isEmpty {
                        Text("None. Put an adapter manifest (.json) in the Adapters folder, then turn the AI Hub off and on.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    ForEach(hub.manifests.adapters.values.sorted { $0.id < $1.id }, id: \.id) { manifest in
                        LabeledContent(manifest.name, value: "\(manifest.id) \(manifest.version) · observe only")
                    }
                    ForEach(hub.manifests.problems.sorted { $0.key < $1.key }, id: \.key) { file, problem in
                        LabeledContent(file, value: "Skipped: \(problem)").foregroundStyle(.orange)
                    }
                    Button("Show Adapters Folder") {
                        try? FileManager.default.createDirectory(at: AdapterManifests.folder, withIntermediateDirectories: true)
                        NSWorkspace.shared.open(AdapterManifests.folder)
                    }
                } header: {
                    Text("Third-Party Adapters")
                } footer: {
                    Text("Declarative manifests only: no code runs. They can watch an agent's hook events, never answer for it. Remove one by deleting its file.")
                }
                Section {
                    Toggle(isOn: Binding(get: { value.aiHubDemo }, set: { on in preferences.update { $0.aiHubDemo = on } })) {
                        Text("Demo mode")
                        Text("Two simulated agents send made-up activity, labelled SIMULATED. Kept apart from real agents' history and never counted as theirs.")
                    }
                    LabeledContent("Simulated sessions", value: "\(hub.demoSessionCount)")
                    Button("Clear Demo Data", role: .destructive) { Task { await hub.clearDemoData() } }
                } header: {
                    Text("Demo Mode")
                }
                Section {
                    ForEach(hub.chat.providers) { state in
                        LabeledContent(state.provider.name, value: state.available ? "Running · \(state.models.count) model\(state.models.count == 1 ? "" : "s")" : "Not running")
                    }
                    ForEach(ChatService.cloudProviders, id: \.self) { name in
                        LabeledContent(name, value: "Needs an API key · not yet supported").foregroundStyle(.secondary)
                    }
                    Button("Check Local Servers") { Task { await hub.chat.refresh() } }
                } header: {
                    Text("Chat Providers")
                } footer: {
                    Text("Chat talks only to model servers on this Mac (Ollama on port 11434, LM Studio on 1234). Cloud models wait until Orbit can store API keys safely.")
                }
                Section {
                    LabeledContent("Kept on this Mac", value: "Sessions 90 days · events 30 days · approvals 180 days")
                    LabeledContent("Never stored", value: "Prompt text, file contents, tokens (redacted)")
                    LabeledContent("Simulated data", value: "Kept apart; never counted in Insights")
                } header: {
                    Text("Usage and Privacy")
                } footer: {
                    Text("Costs and plan limits aren't shown: Orbit has no reliable source for them without API keys.")
                }
                Section {
                    ForEach(IntegrationRegistry.all) { integration in
                        LabeledContent {
                            Text("Not connected").foregroundStyle(.secondary)
                        } label: {
                            Text(integration.name)
                            Text("\(integration.shows). Needs: \(integration.auth).")
                        }
                    }
                } header: {
                    Text("Service Integrations")
                } footer: {
                    Text(IntegrationRegistry.waitingReason)
                }
            }
        }
        .onAppear { hub?.refreshAgents() }
    }

    private func bridgeText(_ bridge: AgentHealth.Bridge) -> String {
        switch bridge {
        case .off: "Off"
        case .listening: "Listening (this Mac only)"
        case .failed(let reason): "Not available: \(reason)"
        }
    }

    private func storeText(_ store: HubStore.Health) -> String {
        switch store {
        case .closed: "Closed"
        case .ok: "Saved on this Mac"
        case .degraded(let reason): "Degraded: \(reason)"
        }
    }
}

/// Claude Code's hooks: status, and install/remove only after the user
/// confirms the exact change (observe-only, D1).
private struct ClaudeHooksSection: View {
    let hub: AIHubService

    var body: some View {
        let confirming = hub.confirmingClaudeHooks
        let count = hub.claudeHooks.count
        let total = ClaudeCodeAdapter.observedEvents.count
        Section {
            LabeledContent("Hooks", value: count == 0 ? "Not installed" : count == total ? "Installed (observe-only)" : "Partly installed (\(count) of \(total))")
            HStack {
                Button(count == total ? "Reinstall Hooks…" : "Install Hooks…") { hub.confirmingClaudeHooks = .install }
                if count > 0 { Button("Remove Hooks…", role: .destructive) { hub.confirmingClaudeHooks = .remove } }
            }
            if let message = hub.claudeHookMessage { Text(message).font(.callout).foregroundStyle(.secondary) }
        } header: {
            Text("Claude Code")
        } footer: {
            Text("Orbit only watches Claude Code: it never answers its permission prompts or questions (Coucou, installed as NotchBuddy, and the terminal do). Nothing is installed until you confirm.")
        }
        .onAppear { hub.refreshClaudeHooks() }
        .confirmationDialog(confirming == .remove ? "Remove Orbit's Claude Code hooks?" : "Install Orbit's Claude Code hooks?",
                            isPresented: Binding(get: { hub.confirmingClaudeHooks != nil }, set: { if !$0 { hub.confirmingClaudeHooks = nil } }),
                            titleVisibility: .visible, presenting: confirming) { action in
            switch action {
            case .install: Button("Install") { hub.installClaudeHooks() }
            case .remove: Button("Remove", role: .destructive) { hub.removeClaudeHooks() }
            }
            Button("Cancel", role: .cancel) {}
        } message: { action in
            switch action {
            case .install: Text(hub.claudeHookPreview())
            case .remove: Text("Takes out only Orbit's entries from ~/.claude/settings.json, after backing it up. Other tools' hooks stay.")
            }
        }
    }
}

/// Settings › Widgets › Daily Briefing: the Briefing tab's own widgets and
/// sizes (briefing.json). Nothing here touches the Overview's layout.
private struct BriefingSettings: View {
    let dashboard: DashboardModel
    let briefing: BriefingPreferencesModel

    var body: some View {
        let value = briefing.value
        Section {
            Toggle("Show the Briefing tab", isOn: Binding(
                get: { value.dailyBriefingEnabled }, set: { on in briefing.update { $0.dailyBriefingEnabled = on } }))
            if let problem = briefing.problem {
                Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(BriefingPreferences.availableWidgets, id: \.self) { id in
                if let meta = dashboard.registry.widget(id)?.metadata { row(id: id, meta: meta, value: value) }
            }
            Button("Reset Briefing") { briefing.resetAll() }
        } header: {
            Text("Daily Briefing")
        } footer: {
            Text("The Briefing tab has its own widgets and sizes. Changing them never changes the Overview.")
        }
    }

    private func row(id: WidgetID, meta: WidgetMetadata, value: BriefingPreferences) -> some View {
        let canExpand = meta.presentations.contains(.expanded)
        return HStack(spacing: 10) {
            Image(systemName: meta.symbol).frame(width: 18).foregroundStyle(.secondary)
            Text(meta.title)
            Spacer()
            Picker("Size", selection: Binding(
                get: { canExpand ? value.presentation(for: id) : .compact },
                set: { size in briefing.update { $0.setPresentation(size, for: id) } })) {
                Text("Compact").tag(WidgetPresentation.compact)
                Text("Expanded").tag(WidgetPresentation.expanded)
            }
            .labelsHidden()
            .fixedSize()
            .disabled(!canExpand)
            .help(canExpand ? "Size in the Briefing" : "\(meta.title) has one size")
            Toggle("Show in the Briefing", isOn: Binding(
                get: { value.isShown(id) }, set: { shown in briefing.update { $0.setShown(id, shown) } }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct WidgetSettings: View {
    let dashboard: DashboardModel
    let briefing: BriefingPreferencesModel

    var body: some View {
        let items = dashboard.layout.items
        Form {
            Section {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    if let meta = dashboard.registry.widget(item.id)?.metadata {
                        row(item: item, meta: meta, index: index, isLast: index == items.count - 1)
                    }
                }
            } header: {
                Text("Overview")
            } footer: {
                Text("Choose which widgets the Overview shows, their order and size. Every widget always appears in its own section.")
            }
            Section {
                Button("Restore Default Layout") { dashboard.resetLayout() }
            }
            BriefingSettings(dashboard: dashboard, briefing: briefing)
        }
    }

    private func row(item: WidgetLayout.Item, meta: WidgetMetadata, index: Int, isLast: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: meta.symbol).frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(meta.title)
                    if meta.availability == .sample {
                        Text("SAMPLE").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                Text(meta.description).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if meta.presentations.count > 1 {
                Picker("Size", selection: Binding(
                    get: { item.presentation }, set: { dashboard.setPresentation(item.id, $0) })) {
                    Text("Compact").tag(WidgetPresentation.compact)
                    Text("Expanded").tag(WidgetPresentation.expanded)
                }
                .labelsHidden()
                .fixedSize()
            }
            ControlGroup {
                Button { dashboard.move(item.id, to: index - 1) } label: { Image(systemName: "chevron.up") }
                    .disabled(index == 0)
                    .help("Move up")
                Button { dashboard.move(item.id, to: index + 1) } label: { Image(systemName: "chevron.down") }
                    .disabled(isLast)
                    .help("Move down")
            }
            .fixedSize()
            Toggle("Show on Overview", isOn: Binding(
                get: { item.isEnabled }, set: { dashboard.setEnabled(item.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
    }
}

private struct PrivacySettings: View {
    var body: some View {
        let permissions = PermissionCatalog.current()
        Form {
            Section("Required") {
                Text("None. Orbit works without any macOS permission.").foregroundStyle(.secondary)
            }
            ForEach([PermissionInfo.Need.optional, .unused], id: \.self) { need in
                Section(need.rawValue) {
                    ForEach(permissions.filter { $0.need == need }) { permission in
                        LabeledContent {
                            Text(permission.status).foregroundStyle(.secondary)
                        } label: {
                            Text(permission.name)
                            Text(permission.purpose)
                        }
                    }
                }
            }
            Section {
                Button("Open Privacy & Security…") { NSWorkspace.shared.open(PermissionCatalog.privacySettingsURL) }
                Text("Orbit never asks for a permission on its own. Manage any grant in System Settings.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }
}

private struct StorageSettings: View {
    let model: SettingsModel

    var body: some View {
        Form {
            Section("Location") {
                LabeledContent("Orbit data") {
                    Text(ProjectsWidget.abbreviated(model.dataDirectory)).textSelection(.enabled)
                }
                Button("Show in Finder") {
                    try? FileManager.default.createDirectory(at: model.dataDirectory, withIntermediateDirectories: true)
                    NSWorkspace.shared.open(model.dataDirectory)
                }
            }
            if let problem = model.vaultWidget?.problem {
                Section("Screenshot Vault") {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("""
                        Rebuilding scans only the Vault folder and lists every valid PNG, JPEG or HEIC \
                        image again. The unreadable index is kept beside the new one. Keep, original \
                        names, import dates and Recently Deleted can't be recovered from the images: \
                        recovered screenshots come back marked Kept, dated by their file.
                        """)
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Rebuild Index from Images…") { model.confirmingRebuild = true }
                }
            }
            if let feedback = model.rebuildFeedback {
                Section {
                    Text(feedback.text).foregroundStyle(feedback.isError ? Color.red : .secondary)
                }
            }
            if let storage = model.storage, model.vaultWidget?.problem == nil {
                Section("Screenshot Vault") {
                    LabeledContent("Screenshots", value: "\(storage.screenshotCount) (\(storage.keptCount) kept)")
                    LabeledContent("Recently deleted", value: "\(storage.deletedCount), removed after 30 days")
                    LabeledContent("Space used", value: storage.vaultBytes.formatted(.byteCount(style: .file)))
                }
                Section {
                    LabeledContent("Copies", value: "\(storage.exportCopies)")
                    LabeledContent("Space used", value: storage.exportBytes.formatted(.byteCount(style: .file)))
                    Button("Remove Expired Drag Copies") { model.cleanUpDragCopies() }
                    if let message = model.cleanupMessage {
                        Text(message).font(.callout).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("Temporary Drag Copies")
                } footer: {
                    Text("Made when you drag a screenshot out of the Vault. Copies older than 10 minutes expire and are cleared on the next drag, or here. Vault screenshots are never removed here.")
                }
            }
        }
        .onAppear { model.refresh() }
        .confirmationDialog("Rebuild the Vault index from its images?", isPresented: Binding(
            get: { model.confirmingRebuild }, set: { model.confirmingRebuild = $0 }), titleVisibility: .visible) {
            Button("Rebuild Index") { model.rebuildVault() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No image is moved, renamed or changed, and the unreadable index is kept.")
        }
    }
}

private struct AboutSettings: View {
    let model: SettingsModel

    var body: some View {
        let info = Bundle.main.infoDictionary ?? [:]
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "circle.circle.fill").font(.system(size: 40)).foregroundStyle(Theme.accent)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Orbit").font(.title2.weight(.semibold))
                        Text("A personal control centre around the notch").foregroundStyle(.secondary)
                    }
                }
            }
            Section {
                LabeledContent("Version", value: "\(info["CFBundleShortVersionString"] as? String ?? "—") (\(info["CFBundleVersion"] as? String ?? "—"))")
                LabeledContent("Requires", value: "macOS 26 or later, on a Mac with a notch")
                LabeledContent("This Mac", value: ProcessInfo.processInfo.operatingSystemVersionString)
                LabeledContent("Data", value: ProjectsWidget.abbreviated(model.dataDirectory))
            }
            Section("Documentation") {
                LabeledContent("Project specification", value: "PROJECT_SPEC.md in the Orbit source folder")
                LabeledContent("User guide", value: "Coming later")
            }
        }
    }
}

private struct CalendarSettingsPane: View {
    let widget: EventsWidget?

    var body: some View {
        Form {
            if let widget {
                Section("Connection") {
                    LabeledContent("Status", value: status(widget))
                    if widget.isConnected {
                        Button("Disconnect") { widget.disconnect() }
                        Text("Orbit stops reading your calendars. To revoke the permission itself, use System Settings › Privacy & Security › Calendars.")
                            .font(.callout).foregroundStyle(.secondary)
                    } else if widget.settings.value.isEnabled && (widget.access == .denied || widget.access == .writeOnly) {
                        Button("Open Privacy & Security…") { NSWorkspace.shared.open(EventsWidget.privacyURL) }
                    } else if widget.access != .restricted {
                        Button(widget.isConnecting ? "Connecting…" : "Connect Calendar") { Task { await widget.connect() } }
                            .disabled(widget.isConnecting)
                    }
                }
                if widget.isConnected {
                    Section {
                        if widget.calendars.isEmpty {
                            Text("No calendars on this Mac.").foregroundStyle(.secondary)
                        }
                        ForEach(widget.calendars) { calendar in
                            Toggle(isOn: Binding(get: { widget.selectedCalendarIDs.contains(calendar.id) },
                                                 set: { widget.setCalendar(calendar.id, selected: $0) })) {
                                HStack(spacing: 8) {
                                    Circle().fill(calendar.color?.color ?? .accentColor).frame(width: 9, height: 9)
                                    Text(calendar.title)
                                    Text(calendar.source)
                                }
                            }
                        }
                        if widget.settings.value.selectedCalendarIDs != nil {
                            Button("Include All Calendars") { widget.selectAllCalendars() }
                        }
                    } header: {
                        Text("Calendars")
                    } footer: {
                        Text(widget.settings.value.selectedCalendarIDs == nil
                             ? "All calendars are shown, including ones you add later."
                             : "Only the calendars you chose are shown; new calendars stay off.")
                    }
                }
                Section("Privacy") {
                    Text("Orbit reads events on this Mac only to show today's agenda. It never changes or deletes events, never sends them anywhere and never saves them; it remembers only which calendars you chose.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }
        }
        .onAppear { widget?.refreshAccess() }
    }

    private func status(_ widget: EventsWidget) -> String {
        if !widget.settings.value.isEnabled { return "Disconnected" }
        switch widget.access {
        case .granted: return "Connected"
        case .notDetermined: return "Not connected"
        case .denied, .writeOnly: return "Access off in System Settings"
        case .restricted: return "Restricted on this Mac"
        }
    }
}

private struct WeatherSettingsPane: View {
    let widget: WeatherWidget?

    var body: some View {
        Form {
            if let widget {
                let place = widget.settings.value.place
                Section {
                    LabeledContent("Showing", value: place.map { [$0.name, $0.detail].filter { !$0.isEmpty }.joined(separator: ", ") } ?? "No place chosen")
                    HStack {
                        TextField("City", text: Binding(get: { widget.searchText }, set: { widget.searchText = $0 }),
                                  prompt: Text("Search for a city"))
                            .labelsHidden()
                            .onSubmit { widget.search() }
                        Button(widget.isSearching ? "Searching…" : "Search") { widget.search() }
                            .disabled(widget.isSearching || widget.searchText.trimmingCharacters(in: .whitespaces).count < 2)
                    }
                    if let message = widget.searchMessage { Text(message).foregroundStyle(.secondary) }
                    ForEach(Array(widget.searchResults.enumerated()), id: \.offset) { _, result in
                        Button { widget.choose(result) } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(result.name)
                                    Text(result.detail.isEmpty ? String(format: "%.2f, %.2f", result.latitude, result.longitude) : result.detail)
                                        .font(.callout).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "plus.circle")
                            }
                            .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("City")
                } footer: {
                    Text(OpenMeteo.geocodingCredit)
                }
                Section {
                    Text("Instead of a city, Orbit can use your Mac's approximate location (about 3 km). macOS asks once, only after you click; Orbit sends only rounded coordinates to Open-Meteo.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button(widget.isLocating ? "Finding your location…" : "Use My Location") { Task { await widget.useMyLocation() } }
                        .disabled(widget.isLocating)
                    if let message = widget.locationMessage { Text(message).foregroundStyle(.secondary) }
                } header: {
                    Text("Current Location (optional)")
                }
                Section("Units") {
                    Picker("Temperature", selection: Binding(get: { widget.settings.value.unit }, set: { widget.setUnit($0) })) {
                        ForEach(TemperatureUnit.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    LabeledContent("Last updated", value: widget.refresher.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    Button("Clear Cached Weather") { widget.clearCache() }
                    Link(OpenMeteo.attribution, destination: OpenMeteo.attributionURL)
                } header: {
                    Text("Data")
                } footer: {
                    Text("Forecasts come from Open-Meteo's free API, for non-commercial use, under CC BY 4.0. Only the place's coordinates are sent. A cached forecast is kept for offline use.")
                }
            }
        }
    }
}

/// Settings › AI Hub › Notifications (Milestone 14): what shows and when, and what happened lately.
private struct AgentAlertRulesForm: View {
    let preferences: PreferencesModel
    let alerts: AgentAlerts

    private func rule<T>(_ key: WritableKeyPath<AgentAlertRules, T>) -> Binding<T> {
        Binding(get: { preferences.value.agentAlerts[keyPath: key] }, set: { value in preferences.update { $0.agentAlerts[keyPath: key] = value } })
    }

    private func time(_ key: WritableKeyPath<AgentAlertRules, Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.startOfDay(for: .now).addingTimeInterval(TimeInterval(preferences.value.agentAlerts[keyPath: key] * 60)) },
                set: { date in
                    let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                    preferences.update { $0.agentAlerts[keyPath: key] = (parts.hour ?? 0) * 60 + (parts.minute ?? 0) }
                })
    }

    var body: some View {
        Toggle("Show when an agent finishes", isOn: rule(\.showFinished))
        Toggle(isOn: rule(\.sound)) {
            Text("Play a sound")
            Text("A system sound when an agent needs you or fails. Never during quiet hours.")
        }
        Toggle(isOn: rule(\.quietHours)) {
            Text("Quiet hours")
            Text("Only “needs you” alerts show: an agent waiting on you is work on hold. Everything still reaches the AI Hub.")
        }
        if preferences.value.agentAlerts.quietHours {
            DatePicker("From", selection: time(\.quietStart), displayedComponents: .hourAndMinute)
            DatePicker("Until", selection: time(\.quietEnd), displayedComponents: .hourAndMinute)
        }
        DisclosureGroup("Agents") {
            ForEach(AgentDiscovery.known, id: \.id) { agent in
                Toggle(agent.name, isOn: Binding(
                    get: { !preferences.value.agentAlerts.mutedAgents.contains(agent.id) },
                    set: { on in preferences.update { rules in
                        rules.agentAlerts.mutedAgents.removeAll { $0 == agent.id }
                        if !on { rules.agentAlerts.mutedAgents.append(agent.id) }
                    } }))
            }
        }
        DisclosureGroup("Recent alerts") {
            if alerts.history.isEmpty {
                Text("None yet. Kept in memory only, until Orbit quits.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(alerts.history.prefix(12)) { record in
                LabeledContent {
                    Text("\(Self.outcome(record.outcome)) · \(record.at.formatted(date: .omitted, time: .shortened))").foregroundStyle(.secondary)
                } label: {
                    Text((record.isSimulated ? "Simulated: " : "") + record.text).lineLimit(1)
                }
            }
        }
    }

    static func outcome(_ outcome: AgentAlerts.Record.Outcome) -> String {
        switch outcome {
        case .shown: "Shown"
        case .grouped: "Grouped"
        case .muted: "Muted"
        case .quiet: "Quiet hours"
        case .expired: "Expired"
        case .dropped: "Too many at once"
        case .hidden: "Alerts off"
        }
    }
}

/// Settings › General › Automations (Milestone 14): "when this happens, do that", from fixed menus.
private struct AutomationsSection: View {
    let preferences: PreferencesModel
    let runs: [Automations.Run]

    private func rule<T>(_ id: UUID, _ key: WritableKeyPath<AutomationRule, T>) -> Binding<T> {
        Binding(get: { (preferences.value.automations.first { $0.id == id } ?? AutomationRule(trigger: .meetingSoon, action: .pauseMusic))[keyPath: key] },
                set: { value in preferences.update { prefs in
                    if let index = prefs.automations.firstIndex(where: { $0.id == id }) { prefs.automations[index][keyPath: key] = value }
                } })
    }

    var body: some View {
        Section {
            ForEach(preferences.value.automations) { item in
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Toggle("On", isOn: rule(item.id, \.isEnabled)).labelsHidden()
                        Picker("When", selection: rule(item.id, \.trigger)) {
                            ForEach(AutomationRule.Trigger.allCases, id: \.self) { Text($0.title).tag($0) }
                        }
                        Button(role: .destructive) {
                            preferences.update { $0.automations.removeAll { $0.id == item.id } }
                        } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove automation")
                    }
                    Picker("Only", selection: rule(item.id, \.condition)) {
                        ForEach(AutomationRule.Condition.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                    Picker("Do", selection: rule(item.id, \.action)) {
                        ForEach(AutomationRule.Action.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            Button("Add Automation") {
                preferences.update { $0.automations.append(AutomationRule(trigger: .meetingSoon, action: .pauseMusic)) }
            }
            if !runs.isEmpty {
                DisclosureGroup("Recent runs") {
                    ForEach(runs.prefix(10)) { run in
                        LabeledContent {
                            Text({ if case .skipped(let why) = run.outcome { "Skipped: \(why)" } else { "Done" } }() + " · "
                                 + run.at.formatted(date: .omitted, time: .shortened)).foregroundStyle(.secondary)
                        } label: { Text(run.text).lineLimit(1) }
                    }
                }
            }
        } header: {
            Text("Automations")
        } footer: {
            Text("Orbit's own signals only, and a fixed list of things it can already do. Nothing runs commands or scripts, simulated agents never trigger anything, and each automation runs at most once a minute. Meeting automations use the Calendar widget's calendars, if Orbit already has access.")
        }
    }
}
