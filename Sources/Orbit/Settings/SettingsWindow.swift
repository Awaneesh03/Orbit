import SwiftUI

enum SettingsSection: String, CaseIterable, Identifiable {
    case general, appearance, pet, widgets, calendar, weather, privacy, storage, about
    var id: Self { self }

    var title: String {
        switch self {
        case .general: "General"
        case .appearance: "Appearance"
        case .pet: "Pet"
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
        case .general: "gearshape"
        case .appearance: "paintbrush"
        case .pet: "pawprint"
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
    private(set) var storage: StorageReport?
    private(set) var loginEnabled = false
    private(set) var loginMessage: String?
    private(set) var cleanupMessage: String?
    var confirmingRebuild = false
    private(set) var rebuildFeedback: VaultWidget.Feedback?

    init(dashboard: DashboardModel, preferences: PreferencesModel,
         briefing: BriefingPreferencesModel = BriefingPreferencesModel(file: nil), dataDirectory: URL,
         exportRoot: URL = ScreenshotVault.exportRoot) {
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
            List(SettingsSection.allCases, selection: Binding(
                get: { model.section }, set: { if let section = $0 { model.section = section } }
            )) { section in
                Label(section.title, systemImage: section.symbol).tag(section)
            }
            .navigationSplitViewColumnWidth(200)
        } detail: {
            Group {
                switch model.section {
                case .general: GeneralSettings(model: model)
                case .appearance: AppearanceSettings(preferences: model.preferences)
                case .pet: PetSettings(preferences: model.preferences)
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
            Section("Volume") {
                Toggle("Show Volume HUD", isOn: Binding(
                    get: { preferences.value.volumeHUD }, set: { value in preferences.update { $0.volumeHUD = value } }))
                Text("Shows the volume and mute below the notch when they change, for a moment. It never covers the dashboard or the full player, and it doesn't change the volume.")
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
                    Text("Peeks out below the notch. Coming in a later update; your choice is saved now.")
                }
            } header: {
                Text("Where It Appears")
            } footer: {
                if !master { Text("Turn on Orbit Pet to use these.") }
            }
            .disabled(!master)
        }
    }

    private func binding(_ key: WritableKeyPath<OrbitPreferences, Bool>) -> Binding<Bool> {
        Binding(get: { preferences.value[keyPath: key] }, set: { value in preferences.update { $0[keyPath: key] = value } })
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
            ForEach(BriefingPreferences.defaultWidgets, id: \.self) { id in
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
