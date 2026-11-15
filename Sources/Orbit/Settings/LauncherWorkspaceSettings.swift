import AppKit
import SwiftUI

// Settings › Get Started, Launcher and Workspaces (Milestone 16).

struct WelcomeSettings: View {
    let model: SettingsModel

    var body: some View {
        let shortcut = model.preferences.value.launcherShortcut
        Form {
            Section {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Welcome to Orbit").font(.title2.weight(.semibold))
                    Text("A control centre that lives in your notch (or just below the menu bar on a display without one). Everything stays on this Mac.")
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            }
            Section("Ways in") {
                LabeledContent("Dashboard", value: "Hover the notch, or \(DashboardHotKey.label)")
                LabeledContent("Launcher", value: shortcut == .off ? "Off (Settings › Launcher)" : shortcut.label)
                LabeledContent("Settings", value: "Right-click the notch, or search Settings here")
            }
            Section {
                LabeledContent("Calendar", value: "Only if you click Connect in the Calendar widget")
                LabeledContent("Location", value: "Only if you choose “Use my location” for Weather")
                LabeledContent("Bluetooth", value: "Only when you open System › Bluetooth")
                LabeledContent("Never asked for", value: "Accessibility, Input Monitoring, Screen Recording")
            } header: {
                Text("Permissions")
            } footer: {
                Text("Orbit works without any of these. The launcher searches files through Spotlight's index (names only), and battery and brightness readings need no permission.")
            }
            Section("Try") {
                HStack {
                    Button("Set Up Workspaces") { model.section = .workspaces }
                    Button("Launcher Settings") { model.section = .launcher }
                    Button("Choose Widgets") { model.section = .widgets }
                }
            }
        }
    }
}

struct LauncherSettings: View {
    let model: SettingsModel

    var body: some View {
        let preferences = model.preferences
        Form {
            Section {
                Picker("Shortcut", selection: Binding(get: { preferences.value.launcherShortcut },
                                                      set: { value in preferences.update { $0.launcherShortcut = value } })) {
                    ForEach(LauncherShortcut.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                if model.launcherShortcutAvailable == false {
                    Label("Another app already uses \(preferences.value.launcherShortcut.label). Choose another.", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
                LabeledContent("Dashboard", value: DashboardHotKey.label)
            } header: {
                Text("Shortcuts")
            } footer: {
                Text("Global shortcuts need no permission: Orbit registers one key combination with macOS and sees no other keys.")
            }
            Section {
                Toggle(isOn: Binding(get: { preferences.value.launcherFiles }, set: { value in preferences.update { $0.launcherFiles = value } })) {
                    Text("Search files and folders")
                    Text("Asks Spotlight's index for names in your home folder. Orbit doesn't open files to search them; scripts and apps you find are shown in Finder, never run.")
                }
                LabeledContent("Also searched", value: "Apps, projects, agent sessions, the File Shelf, tasks, goals, today's events, Settings, Orbit actions, workspaces")
            } header: {
                Text("What it searches")
            }
            Section {
                LabeledContent("Remembered", value: "\(model.launcher?.memory.recentItems.count ?? 0) items, \(model.launcher?.memory.recentQueries.count ?? 0) searches")
                Button("Clear History") { model.launcher?.clearHistory() }
                    .disabled((model.launcher?.memory.recentItems.isEmpty ?? true) && (model.launcher?.memory.recentQueries.isEmpty ?? true))
            } header: {
                Text("History")
            } footer: {
                Text("Kept in launcher.json in Orbit's folder, on this Mac only. Keys: ↑↓ to move, Return to open, ⌘Return to reveal, Tab or ⌘1–⌘8 for categories, Escape to close.")
            }
        }
    }
}

struct WorkspaceSettings: View {
    let model: SettingsModel
    static let symbols = ["square.stack.3d.up", "chevron.left.forwardslash.chevron.right", "graduationcap", "wrench.and.screwdriver",
                          "house", "briefcase", "book", "paintbrush", "music.note", "heart"]

    var body: some View {
        if let workspaces = model.workspaces {
            let editing = model.editingWorkspace.flatMap { id in workspaces.profiles.first { $0.id == id } } ?? workspaces.active ?? workspaces.profiles.first
            Form {
                Section {
                    Picker("Active workspace", selection: Binding(get: { workspaces.active?.id }, set: { model.activateWorkspace($0) })) {
                        Text("None").tag(UUID?.none)
                        ForEach(workspaces.profiles) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } footer: {
                    Text("Switching changes Orbit only: the Overview layout it remembers, what the launcher ranks first, and, if you chose, pausing music, a focus session or Keep Awake. Apps are never closed and no file or system setting is changed.")
                }
                Section("Workspaces") {
                    ForEach(workspaces.profiles) { profile in
                        HStack {
                            Label(profile.name, systemImage: profile.symbol)
                            if profile.id == workspaces.active?.id { Text("Active").font(.caption).foregroundStyle(.secondary) }
                            Spacer()
                            Button("Edit") { model.editingWorkspace = profile.id }.disabled(profile.id == editing?.id)
                            Button("Duplicate") { model.editingWorkspace = workspaces.duplicate(profile.id)?.id }
                            Button(role: .destructive) { workspaces.delete(profile.id) } label: { Image(systemName: "trash") }
                                .accessibilityLabel("Delete \(profile.name)")
                        }
                    }
                    Button("New Workspace") { model.editingWorkspace = workspaces.create().id }
                }
                if let editing { editor(editing, workspaces: workspaces) }
            }
        } else {
            Form { Text("Workspaces load with Orbit.").foregroundStyle(.secondary) }
        }
    }

    private func field<T>(_ key: WritableKeyPath<WorkspaceProfile, T>, of profile: WorkspaceProfile, in workspaces: Workspaces) -> Binding<T> {
        let id = profile.id
        return Binding(get: { workspaces.profiles.first { $0.id == id }?[keyPath: key] ?? profile[keyPath: key] },
                       set: { value in workspaces.update(id) { $0[keyPath: key] = value } })
    }

    @ViewBuilder private func editor(_ profile: WorkspaceProfile, workspaces: Workspaces) -> some View {
        let id = profile.id
        Section("Edit “\(profile.name)”") {
            TextField("Name", text: field(\.name, of: profile, in: workspaces))
            Picker("Symbol", selection: field(\.symbol, of: profile, in: workspaces)) {
                ForEach(Self.symbols, id: \.self) { Image(systemName: $0).tag($0) }
            }
            pathList("Projects", paths: profile.projects, add: "Add Project…", folders: true) { paths in workspaces.update(id) { $0.projects = paths } }
            pathList("Apps", paths: profile.apps, add: "Add App…", folders: false) { paths in workspaces.update(id) { $0.apps = paths } }
            TextField("Task words", text: Binding(get: { profile.taskKeywords.joined(separator: ", ") },
                                                  set: { text in workspaces.update(id) { $0.taskKeywords = text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty } } }),
                      prompt: Text("e.g. assignment, exam"))
            Picker("Music", selection: field(\.music, of: profile, in: workspaces)) { ForEach(WorkspaceProfile.Music.allCases, id: \.self) { Text($0.title).tag($0) } }
            Toggle("Start a focus session", isOn: field(\.startFocus, of: profile, in: workspaces))
            Toggle("Keep the Mac awake for an hour", isOn: field(\.keepAwake, of: profile, in: workspaces))
            LabeledContent("Overview layout") {
                HStack {
                    Text(profile.layout == nil ? "Leave as it is" : "Saved").foregroundStyle(.secondary)
                    Button("Use Current") { workspaces.update(id) { $0.layout = model.useCurrentLayout() } }
                    if profile.layout != nil { Button("Forget") { workspaces.update(id) { $0.layout = nil } } }
                }
            }
            Toggle("Suggest on a schedule", isOn: Binding(get: { profile.schedule != nil },
                                                         set: { on in workspaces.update(id) { $0.schedule = on ? WorkspaceProfile.Schedule() : nil } }))
            if let schedule = profile.schedule {
                HStack(spacing: 4) {
                    ForEach(1 ... 7, id: \.self) { day in
                        Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                            get: { schedule.weekdays.contains(day) },
                            set: { on in workspaces.update(id) { profile in
                                var days = Set(profile.schedule?.weekdays ?? [])
                                if on { days.insert(day) } else { days.remove(day) }
                                profile.schedule?.weekdays = days.sorted()
                            } }))
                        .toggleStyle(.button)
                    }
                }
                Stepper("From \(schedule.startHour):00", value: Binding(get: { schedule.startHour },
                                                                       set: { value in workspaces.update(id) { $0.schedule?.startHour = value } }), in: 0 ... 23)
                Stepper("Until \(schedule.endHour):00", value: Binding(get: { schedule.endHour },
                                                                      set: { value in workspaces.update(id) { $0.schedule?.endHour = value } }), in: 0 ... 23)
                Text("Orbit suggests switching in the dashboard's Suggested actions at these times; it never switches by itself.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Activate") { model.activateWorkspace(id) }.disabled(workspaces.active?.id == id)
                Button("Open Workspace") { model.openWorkspace(id) }.disabled(profile.apps.isEmpty && profile.projects.isEmpty)
                    .help("Opens its apps and projects now")
            }
        }
    }

    private func pathList(_ title: String, paths: [String], add: String, folders: Bool, set: @escaping ([String]) -> Void) -> some View {
        LabeledContent(title) {
            VStack(alignment: .trailing, spacing: 4) {
                ForEach(paths, id: \.self) { path in
                    HStack(spacing: 6) {
                        Text(((path as NSString).lastPathComponent as NSString).deletingPathExtension).lineLimit(1)
                        if !FileManager.default.fileExists(atPath: path) { Text("missing").font(.caption).foregroundStyle(.orange) }
                        Button { set(paths.filter { $0 != path }) } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).accessibilityLabel("Remove")
                    }
                }
                Button(add) {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = folders
                    panel.canChooseFiles = !folders
                    panel.allowsMultipleSelection = true
                    if folders {
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appending(path: "Developer")
                    } else {
                        panel.directoryURL = URL(filePath: "/Applications")
                        panel.allowedContentTypes = [.application]
                    }
                    guard panel.runModal() == .OK else { return }
                    let added = panel.urls.map { $0.path(percentEncoded: false) }.map { $0.hasSuffix("/") && $0.count > 1 ? String($0.dropLast()) : $0 }
                    set(paths + added.filter { !paths.contains($0) })
                }
            }
        }
    }
}
