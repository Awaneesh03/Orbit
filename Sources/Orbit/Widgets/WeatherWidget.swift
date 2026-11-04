import SwiftUI

/// Weather for the place chosen in Settings › Weather (a searched city or,
/// optionally, the current location), from Open-Meteo (see WeatherService).
/// The last forecast is cached on disk (weather only) and shown at once;
/// it's refreshed only when the widget appears and it's over 30 minutes old.
@MainActor @Observable
final class WeatherWidget: DashboardWidget {
    let metadata = WidgetMetadata(
        id: "weather", title: "Weather", description: "Current conditions and forecast",
        symbol: "cloud.sun", category: .general, availability: .live, presentations: [.compact, .expanded])
    let settings: WeatherSettingsModel
    let refresher: Refresher<Forecast>
    var searchText = ""
    private(set) var searchResults: [WeatherPlace] = []
    private(set) var isSearching = false
    private(set) var searchMessage: String?
    private(set) var isLocating = false
    private(set) var locationMessage: String?
    @ObservationIgnored private let client: OpenMeteo
    @ObservationIgnored private let cache: DataCache<Forecast>
    @ObservationIgnored let location: any LocationProvider
    @ObservationIgnored private let request: WeatherRequest
    @ObservationIgnored private var searchTask: Task<Void, Never>?

    init(client: OpenMeteo, settings: WeatherSettingsModel, cache: DataCache<Forecast>, location: any LocationProvider,
         clock: @escaping () -> Date = { .now }) {
        self.client = client
        self.settings = settings
        self.cache = cache
        self.location = location
        // A cached forecast for another place is dropped, never shown.
        if let cached = cache.latest, settings.value.place.map(cached.value.place.isSameLocation) != true { cache.clear() }
        let request = WeatherRequest()
        request.set(place: settings.value.place, unit: settings.value.unit)
        self.request = request
        refresher = Refresher(source: ForecastSource(client: client, request: request), policy: .init(maxAge: 30 * 60),
                              cache: cache, clock: clock)
    }

    /// The forecast in the chosen unit throughout (converted as a whole until a refresh fetches that unit).
    var forecast: Forecast? { refresher.value?.converted(to: settings.value.unit) }

    var state: WidgetState {
        guard settings.value.place != nil else { return .empty("Choose a city to see the weather.") }
        return refresher.widgetState()
    }

    var statusNote: WidgetNote? { settings.value.place == nil ? nil : refresher.statusNote }

    var stateAction: WidgetAction? {
        guard settings.value.place != nil else {
            return WidgetAction(title: "Choose City", symbol: "magnifyingglass") {
                NotificationCenter.default.post(name: SettingsWindowController.showRequest, object: SettingsSection.weather.rawValue)
            }
        }
        return refresher.retryAction
    }

    func start() { if settings.value.place != nil { refresher.becameVisible() } }
    func stop() { refresher.becameHidden() }

    // MARK: Settings actions

    /// Searches only when asked (Return or Search), so typing sends nothing.
    func search() {
        searchTask?.cancel()
        let query = searchText
        isSearching = true
        searchMessage = nil
        searchTask = Task { [client] in
            defer { isSearching = false }
            do {
                let places = try await client.search(query)
                guard !Task.isCancelled else { return }
                searchResults = places
                searchMessage = places.isEmpty ? "No cities found for “\(query)”." : nil
            } catch is CancellationError {
            } catch DataSourceError.offline {
                searchMessage = "You're offline."
            } catch {
                searchMessage = "Couldn't search right now."
            }
        }
    }

    /// The user picked a place: it replaces the old one and its forecast.
    func choose(_ place: WeatherPlace) {
        settings.setPlace(place)
        searchResults = []
        searchText = ""
        request.set(place: place, unit: settings.value.unit)
        cache.clear()
        refresher.reset()
        refresher.markStale()  // loads now if the widget is on screen, otherwise when it appears
    }

    func setUnit(_ unit: TemperatureUnit) {
        settings.setUnit(unit)
        request.set(place: settings.value.place, unit: unit)
        refresher.markStale()
    }

    func clearCache() {
        cache.clear()
        refresher.reset()
        refresher.markStale()
    }

    /// Only after the user clicks Use My Location. macOS prompts once; after a
    /// denial Orbit explains instead of asking again.
    func useMyLocation() async {
        locationMessage = nil
        switch location.access() {
        case .denied:
            locationMessage = "Location access is off for Orbit. Turn it on in System Settings, or search for a city."
            return
        case .restricted:
            locationMessage = "Location access is restricted on this Mac. Search for a city instead."
            return
        case .servicesOff:
            locationMessage = "Location Services are off. Search for a city instead."
            return
        case .notDetermined, .authorized:
            break
        }
        isLocating = true
        defer { isLocating = false }
        do {
            let coordinate = try await location.currentCoordinate()
            func rounded(_ value: Double) -> Double { (value * 100).rounded() / 100 }  // about a kilometre
            choose(WeatherPlace(name: "Current Location", latitude: rounded(coordinate.latitude),
                                longitude: rounded(coordinate.longitude), isCurrentLocation: true))
        } catch {
            locationMessage = location.access() == .authorized
                ? "Couldn't find your location. Search for a city instead."
                : "Location access wasn't allowed. Search for a city instead."
        }
    }

    func content(_ presentation: WidgetPresentation) -> AnyView {
        guard let forecast else { return AnyView(EmptyView()) }
        return presentation == .compact ? AnyView(WeatherCompactView(forecast: forecast))
            : AnyView(WeatherExpandedView(forecast: forecast))
    }
}

// MARK: Views

private func degrees(_ value: Double) -> String { "\(Int(value.rounded()))°" }

private extension Forecast {
    var zone: TimeZone { TimeZone(identifier: timeZone) ?? .current }
    var condition: WeatherCondition { WeatherCondition(code: current.code) }
    var highLow: String { today.map { "H \(degrees($0.high))  L \(degrees($0.low))" } ?? "" }
}

private struct WeatherCompactView: View {
    let forecast: Forecast

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(forecast.place.name).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: forecast.condition.symbol(isDay: forecast.current.isDay))
                    .symbolRenderingMode(.multicolor)
                    .font(.system(size: 24))
                OrbitGlassMetric(value: degrees(forecast.current.temperature))
            }
            Text(forecast.condition.title).font(OrbitType.body).lineLimit(1)
            Text("\(forecast.highLow) · Feels \(degrees(forecast.current.apparent))")
                .font(OrbitType.caption.monospacedDigit())
                .foregroundStyle(Theme.tertiary)
                .lineLimit(1)
            Spacer(minLength: 0)
            WeatherAttribution()
        }
    }
}

private struct WeatherExpandedView: View {
    let forecast: Forecast

    var body: some View {
        let zone = forecast.zone
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(forecast.place.name).font(OrbitType.caption).foregroundStyle(Theme.secondary).lineLimit(1)
                    HStack(spacing: 6) {
                        Image(systemName: forecast.condition.symbol(isDay: forecast.current.isDay))
                            .symbolRenderingMode(.multicolor)
                            .font(.system(size: 20))
                        OrbitGlassMetric(value: degrees(forecast.current.temperature), font: OrbitType.metric)
                    }
                    Text(forecast.condition.title).font(OrbitType.caption).lineLimit(1)
                    Text("\(forecast.highLow) · Feels \(degrees(forecast.current.apparent))")
                        .font(OrbitType.caption.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
                    Text("Humidity \(forecast.current.humidity)%")
                        .font(OrbitType.caption.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
                    Text("Wind \(Int(forecast.current.wind.rounded())) \(forecast.unit.windUnit)")
                        .font(OrbitType.caption.monospacedDigit()).foregroundStyle(Theme.tertiary).lineLimit(1)
                }
                .frame(width: 150, alignment: .leading)
                Rectangle().fill(OrbitGlass.hairline).frame(width: 0.5)
                VStack(spacing: 6) {
                    HStack(spacing: 0) {
                        ForEach(forecast.nextHours(6, from: .now), id: \.time) { hour in
                            VStack(spacing: 2) {
                                Text(hour.time.formatted(Date.FormatStyle(timeZone: zone).hour()))
                                    .font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
                                Image(systemName: WeatherCondition(code: hour.code).symbol(isDay: hour.isDay))
                                    .symbolRenderingMode(.multicolor).font(.system(size: 12))
                                Text(degrees(hour.temperature)).font(OrbitType.caption.monospacedDigit())
                                RainChance(percent: hour.rainChance)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                    Rectangle().fill(OrbitGlass.hairline).frame(height: 0.5)
                    HStack(spacing: 0) {
                        ForEach(forecast.daily.prefix(4), id: \.date) { day in
                            VStack(spacing: 2) {
                                HStack(spacing: 3) {
                                    Text(day.date.formatted(Date.FormatStyle(timeZone: zone).weekday(.abbreviated)))
                                        .font(.system(size: 9.5, weight: .semibold)).foregroundStyle(Theme.secondary)
                                    Image(systemName: WeatherCondition(code: day.code).symbol(isDay: true))
                                        .symbolRenderingMode(.multicolor).font(.system(size: 11))
                                }
                                HStack(spacing: 3) {
                                    Text("\(degrees(day.high)) \(degrees(day.low))").font(.system(size: 9.5).monospacedDigit())
                                    RainChance(percent: day.rainChance)
                                }
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }
                }
            }
            Spacer(minLength: 0)
            WeatherAttribution()
        }
    }
}

/// "30%" in blue when rain is plausible; nothing below 10%.
private struct RainChance: View {
    let percent: Int?

    var body: some View {
        if let percent, percent >= 10 {
            Text("\(percent)%").font(.system(size: 9, weight: .medium).monospacedDigit())
                .foregroundStyle(Color(red: 0.45, green: 0.72, blue: 1))
        }
    }
}

/// Required credit (CC BY 4.0), linking to Open-Meteo.
struct WeatherAttribution: View {
    var body: some View {
        Link(destination: OpenMeteo.attributionURL) {
            Text(OpenMeteo.attribution).font(.system(size: 9, weight: .medium)).foregroundStyle(Theme.tertiary)
        }
        .buttonStyle(DashboardButtonStyle())
        .help("open-meteo.com")
    }
}
