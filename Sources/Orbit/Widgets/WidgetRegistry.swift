import Foundation

enum WidgetRegistryError: Error, Equatable {
    case emptyID
    case duplicateID(WidgetID)
    case missingCompactPresentation(WidgetID)
    case unsupportedSectionPresentation(WidgetID)
}

/// Every widget Orbit knows about, validated once. A widget registers by being
/// listed in `builtIn`; other code discovers widgets by id or category.
@MainActor
struct WidgetRegistry {
    let widgets: [any DashboardWidget]

    init(_ widgets: [any DashboardWidget]) throws(WidgetRegistryError) {
        var seen = Set<WidgetID>()
        for widget in widgets {
            let meta = widget.metadata
            guard !meta.id.isEmpty else { throw .emptyID }
            guard seen.insert(meta.id).inserted else { throw .duplicateID(meta.id) }
            // Every widget must fit a single grid cell.
            guard meta.presentations.contains(.compact) else { throw .missingCompactPresentation(meta.id) }
            guard meta.presentations.contains(meta.sectionPresentation) else {
                throw .unsupportedSectionPresentation(meta.id)
            }
        }
        self.widgets = widgets
    }

    var metadata: [WidgetMetadata] { widgets.map(\.metadata) }

    func widget(_ id: WidgetID) -> (any DashboardWidget)? {
        widgets.first { $0.metadata.id == id }
    }

    /// In registry order, which is also the section page order.
    func widgets(in category: WidgetCategory) -> [any DashboardWidget] {
        widgets.filter { $0.metadata.category == category }
    }

    /// The built-in widgets. Order matters twice: widgets enabled by default
    /// form the default Overview (in this order), and within a category this is
    /// the section page order. Adding a widget = one line here.
    static func builtIn(dataDirectory: URL, projectsRoot: URL,
                        perform: @escaping @MainActor (QuickAction) -> Void,
                        didLaunch: @escaping @MainActor () -> Void) -> WidgetRegistry {
        func file<Value>(_ name: String) -> JSONFile<Value> { JSONFile(url: dataDirectory.appending(path: name)) }
        let goals = GoalsWidget(file: file("goals.json"))
        let tasks = TasksWidget(file: file("tasks.json"), goals: goals)
        let pomodoro = PomodoroWidget(file: file("pomodoro.json"))
        do {
            return try WidgetRegistry([
                ClockWidget(),
                WeatherWidget(client: OpenMeteo(http: URLSessionWeatherHTTP()),
                              settings: WeatherSettingsModel(file: file(WeatherSettingsModel.fileName)),
                              cache: DataCache(file: file("weather-cache.json")), location: CoreLocationProvider()),
                BatteryWidget(),
                QuickActionsWidget(perform: perform),
                tasks,
                pomodoro,
                goals,
                WeeklyInsightsWidget(tasks: tasks, goals: goals, pomodoro: pomodoro),
                DailyDigestWidget(file: file("digest.json")),
                ClipboardWidget(),
                QuickNoteWidget(file: file("quicknote.json")),
                EyeBreakWidget(model: EyeBreakModel(file: file("eyebreak.json"))),
                FileShelfWidget(shelf: FileShelf(file: file("shelf.json"),
                                                 folder: dataDirectory.appending(path: "Shelf", directoryHint: .isDirectory))),
                EventsWidget(store: EventKitStore(), settings: CalendarSettingsModel(file: file(CalendarSettingsModel.fileName))),
                NewsWidget(source: NewsFeedSource(sources: NewsSource.curated, http: URLSessionWeatherHTTP()),
                           cache: DataCache(file: file("news-cache.json"))),
                LinkedInWidget(),
                ProjectsWidget(root: projectsRoot, didLaunch: didLaunch),
                GitHubWidget(),
                VaultWidget(directory: dataDirectory.appending(path: "Vault", directoryHint: .isDirectory)),
                SystemWidget(),
                BrightnessWidget(),
                StorageWidget(),
                NetworkWidget(),
                KeepAwakeWidget(),
                AIChatWidget(file: file("ai.json")),
                NowPlayingWidget(coordinator: {
                    let coordinator = PlaybackCoordinator()
                    coordinator.register(AppleMusicSource())
                    // The helper connects to <data>/Bridge/brave.sock (the default data folder).
                    coordinator.register(BraveYouTubeSource(
                        socketPath: dataDirectory.appending(path: "Bridge/brave.sock").path(percentEncoded: false)))
                    return coordinator
                }()),
            ])
        } catch {
            // Programmer error in the list above; WidgetRegistryTests catches it first.
            fatalError("Invalid built-in widget registry: \(error)")
        }
    }
}
