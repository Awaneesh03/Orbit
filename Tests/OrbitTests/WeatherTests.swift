import Foundation
import Synchronization
import SwiftUI
import Testing
@testable import Orbit

// Stage 3.6: Open-Meteo weather over a mock HTTP layer (no real requests) and
// a mock location provider (no real permission prompts).

/// Scripted Open-Meteo: forecast and geocoding replies, call log, optional delay.
private final class MockHTTP: WeatherHTTP, @unchecked Sendable {
    struct State {
        var forecast: Result<(Data, Int), URLError> = .success((forecastJSON(), 200))
        var geocoding: (Data, Int) = (Data(geocodingJSON.utf8), 200)
        var urls: [URL] = []
        var delay: Duration = .zero
    }
    let state = Mutex(State())

    func get(_ url: URL) async throws -> (Data, Int) {
        let (reply, delay): (Result<(Data, Int), URLError>, Duration) = state.withLock {
            $0.urls.append(url)
            return (url.host() == "geocoding-api.open-meteo.com" ? .success($0.geocoding) : $0.forecast, $0.delay)
        }
        if delay > .zero { try await Task.sleep(for: delay) }
        return try reply.get()
    }

    func set(_ change: (inout State) -> Void) { state.withLock { change(&$0) } }
    var urls: [URL] { state.withLock { $0.urls } }
    var forecastCalls: Int { urls.filter { $0.host() == "api.open-meteo.com" }.count }
}

@MainActor
private final class MockLocation: LocationProvider {
    var status = LocationAccess.notDetermined
    var grant = true
    var requests = 0
    func access() -> LocationAccess { status }
    func currentCoordinate() async throws -> (latitude: Double, longitude: Double) {
        if status == .notDetermined { requests += 1; status = grant ? .authorized : .denied }
        guard status == .authorized else { throw DataSourceError.needsAccess("no") }
        return (18.520430, 73.856743)
    }
}

private let pune = WeatherPlace(name: "Pune", admin1: "Maharashtra", country: "India", countryCode: "IN",
                                latitude: 18.51957, longitude: 73.85535)

/// A forecast shaped like Open-Meteo's (unix times starting at `start`).
private func forecastJSON(start: Int = Int(Date.now.timeIntervalSince1970) / 3600 * 3600, code: Int = 2) -> Data {
    let hours = (0..<24).map { start + $0 * 3600 }
    let days = (0..<5).map { start + $0 * 86_400 }
    let json: [String: Any] = [
        "timezone": "Asia/Kolkata",
        "current": ["time": start, "temperature_2m": 24.4, "apparent_temperature": 26.1, "relative_humidity_2m": 61,
                    "weather_code": code, "wind_speed_10m": 12.6, "is_day": 1],
        "hourly": ["time": hours, "temperature_2m": hours.indices.map { 24 + Double($0) / 10 },
                   "precipitation_probability": hours.indices.map { $0 == 3 ? 40 : 0 },
                   "weather_code": hours.map { _ in 61 }, "is_day": hours.map { _ in 1 }],
        "daily": ["time": days, "weather_code": [2, 61, 95, 0, 3], "temperature_2m_max": [27.4, 26, 25, 28, 29],
                  "temperature_2m_min": [19.2, 19, 18, 20, 21], "precipitation_probability_max": [10, 80, 90, 0, NSNull()]],
    ]
    return try! JSONSerialization.data(withJSONObject: json)
}

/// Two Springfields (and an exact duplicate), as the geocoder returns them.
private let geocodingJSON = """
    {"results":[
     {"id":4250542,"name":"Springfield","latitude":39.80172,"longitude":-89.64371,"country":"United States","country_code":"US","admin1":"Illinois"},
     {"id":4409896,"name":"Springfield","latitude":37.21533,"longitude":-93.29824,"country":"United States","country_code":"US","admin1":"Missouri"},
     {"id":4250543,"name":"Springfield","latitude":39.80173,"longitude":-89.64372,"country":"United States","country_code":"US","admin1":"Illinois"}
    ]}
    """

private final class Clock: @unchecked Sendable {
    let time = Mutex(Date.now)
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 = $0.addingTimeInterval(seconds) } }
}

@MainActor
private func makeWidget(_ http: MockHTTP, place: WeatherPlace? = pune, folder: URL? = nil, location: MockLocation = MockLocation(),
                        clock: Clock = Clock()) -> WeatherWidget {
    let settings = WeatherSettingsModel(file: folder.map { JSONFile(url: $0.appending(path: "weather.json")) })
    if let place { settings.setPlace(place) }
    let cache: DataCache<Forecast> = folder.map { DataCache(file: JSONFile(url: $0.appending(path: "weather-cache.json"))) } ?? .memoryOnly()
    return WeatherWidget(client: OpenMeteo(http: http), settings: settings, cache: cache, location: location, clock: { clock.now })
}

@MainActor
private func settle(_ widget: WeatherWidget) async {
    if widget.refresher.isRefreshing { await widget.refresher.refresh().value }
}

// MARK: Open-Meteo

@Test func cityResultsKeepSimilarNamesApartAndDropDuplicates() async throws {
    let http = MockHTTP()
    let places = try await OpenMeteo(http: http).search("  Springfield ")
    #expect(places.map(\.detail) == ["Illinois, United States", "Missouri, United States"])
    #expect(http.urls.first?.absoluteString.contains("name=Springfield") == true)
    #expect(http.urls.first?.scheme == "https")
    http.set { $0.geocoding = (Data(#"{"generationtime_ms":0.3}"#.utf8), 200) }  // no matches: no "results" key
    #expect(try await OpenMeteo(http: http).search("Nowhereville").isEmpty)
    #expect(try await OpenMeteo(http: http).search("P").isEmpty)  // too short: nothing sent
    #expect(http.urls.count == 2)
}

@Test func forecastRequestSendsOnlyRoundedCoordinatesAndUnits() {
    let url = OpenMeteo.forecastURL(for: pune, unit: .fahrenheit).absoluteString
    #expect(url.hasPrefix("https://api.open-meteo.com/v1/forecast?"))
    #expect(url.contains("latitude=18.52") && url.contains("longitude=73.86"))
    #expect(url.contains("temperature_unit=fahrenheit") && url.contains("wind_speed_unit=mph"))
    #expect(!url.contains("Pune") && !url.contains("Maharashtra"))  // no names or other data
    #expect(OpenMeteo.forecastURL(for: pune, unit: .celsius).absoluteString.contains("temperature_unit=celsius"))
}

@Test func forecastDecodesCurrentHourlyDailyAndRain() throws {
    let start = 1_800_000_000 / 3600 * 3600
    let response = try JSONDecoder().decode(ForecastResponse.self, from: forecastJSON(start: start))
    let forecast = try response.forecast(place: pune, unit: .celsius)
    #expect(forecast.current.temperature == 24.4 && forecast.current.apparent == 26.1)
    #expect(forecast.current.humidity == 61 && forecast.current.wind == 12.6 && forecast.current.isDay)
    #expect(forecast.hourly.count == 24 && forecast.daily.count == 5)
    #expect(forecast.hourly[3].rainChance == 40)
    #expect(forecast.daily.map(\.rainChance) == [10, 80, 90, 0, nil])  // a missing value stays missing
    #expect(forecast.today?.high == 27.4 && forecast.today?.low == 19.2)
    let now = Date(timeIntervalSince1970: TimeInterval(start + 2 * 3600 + 600))
    #expect(forecast.nextHours(6, from: now).map(\.time.timeIntervalSince1970) == (2..<8).map { TimeInterval(start + $0 * 3600) })
}

@Test func weatherCodesMapToConditionsWithoutGuessing() {
    let expected: [(Int, WeatherCondition)] = [
        (0, .clear), (1, .mainlyClear), (2, .partlyCloudy), (3, .overcast), (45, .fog), (48, .fog), (51, .drizzle),
        (56, .freezingDrizzle), (61, .rain), (65, .heavyRain), (66, .freezingRain), (67, .freezingRain), (71, .snow),
        (77, .snowGrains), (80, .rainShowers), (85, .snowShowers), (86, .snowShowers), (95, .thunderstorm), (99, .thunderstormHail),
    ]
    for (code, condition) in expected { #expect(WeatherCondition(code: code) == condition, "\(code)") }
    #expect(WeatherCondition(code: 42) == .unknown && WeatherCondition(code: 42).title == "Conditions unavailable")
    #expect(WeatherCondition.clear.symbol(isDay: true) == "sun.max.fill" && WeatherCondition.clear.symbol(isDay: false) == "moon.stars.fill")
    #expect(WeatherCondition.partlyCloudy.symbol(isDay: false) == "cloud.moon.fill")
    for (_, condition) in expected {
        for isDay in [true, false] {
            #expect(NSImage(systemSymbolName: condition.symbol(isDay: isDay), accessibilityDescription: nil) != nil, "\(condition)")
        }
    }
}

@Test func unitConversionChangesEveryValueTogether() throws {
    let forecast = try JSONDecoder().decode(ForecastResponse.self, from: forecastJSON()).forecast(place: pune, unit: .celsius)
    let fahrenheit = forecast.converted(to: .fahrenheit)
    #expect(fahrenheit.unit == .fahrenheit)
    #expect(abs(fahrenheit.current.temperature - (24.4 * 9 / 5 + 32)) < 0.001)
    #expect(abs(fahrenheit.daily[0].high - (27.4 * 9 / 5 + 32)) < 0.001 && abs(fahrenheit.hourly[0].temperature - 75.2) < 0.001)
    #expect(abs(fahrenheit.current.wind - 12.6 / 1.609344) < 0.001)
    let back = fahrenheit.converted(to: .celsius)
    #expect(abs(back.current.temperature - 24.4) < 0.0001 && abs(back.daily[4].low - 21) < 0.0001)
    #expect(forecast.converted(to: .celsius) == forecast)
}

@Test func httpErrorsAndBadJSONAreFailuresAndOfflineIsOffline() async throws {
    let http = MockHTTP()
    let client = OpenMeteo(http: http)
    http.set { $0.forecast = .success((Data("oops".utf8), 500)) }
    await #expect(throws: DataSourceError.failed("Open-Meteo returned an error (HTTP 500).")) { try await client.forecast(for: pune, unit: .celsius) }
    http.set { $0.forecast = .success((Data("{\"current\": 1}".utf8), 200)) }
    await #expect(throws: DataSourceError.failed("Couldn't read the forecast.")) { try await client.forecast(for: pune, unit: .celsius) }
    http.set { $0.forecast = .failure(URLError(.notConnectedToInternet)) }
    await #expect(throws: DataSourceError.offline) { try await client.forecast(for: pune, unit: .celsius) }
}

// MARK: Widget

@MainActor @Test func withoutACityNothingIsFetched() async throws {
    let http = MockHTTP()
    let location = MockLocation()
    let widget = makeWidget(http, place: nil, location: location)
    widget.start()
    #expect(widget.state == .empty("Choose a city to see the weather."))
    #expect(widget.stateAction?.title == "Choose City")
    #expect(http.urls.isEmpty && location.requests == 0)
}

@MainActor @Test func fetchesWhenShownOnlyIfStaleAndNeverTwiceAtOnce() async throws {
    let http = MockHTTP()
    http.set { $0.delay = .milliseconds(30) }
    let clock = Clock()
    let widget = makeWidget(http, clock: clock)
    widget.start()
    widget.refresher.refresh()  // a second request while one runs: joined
    await settle(widget)
    #expect(http.forecastCalls == 1 && widget.state == .ready)
    #expect(widget.forecast?.current.temperature == 24.4)
    widget.stop()
    clock.advance(20 * 60)  // reopened 20 minutes later, switching sections: no new request
    widget.start()
    widget.stop()
    widget.start()
    #expect(http.forecastCalls == 1)
    widget.stop()
    clock.advance(11 * 60)  // past 30 minutes
    widget.start()
    await settle(widget)
    #expect(http.forecastCalls == 2)
    widget.stop()
}

@MainActor @Test func offlineShowsCachedWeatherWithANoteAndRetryWorks() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let http = MockHTTP()
    let clock = Clock()
    let first = makeWidget(http, folder: temp.url, clock: clock)
    first.start()
    await settle(first)
    first.stop()

    http.set { $0.forecast = .failure(URLError(.notConnectedToInternet)) }
    clock.advance(3600)
    let relaunched = makeWidget(http, folder: temp.url, clock: clock)  // a later launch, offline
    #expect(relaunched.state == .ready && relaunched.forecast != nil)  // shown at once from the disk cache
    relaunched.start()
    await settle(relaunched)
    #expect(relaunched.forecast?.current.temperature == 24.4)  // a failed refresh keeps the old forecast
    #expect(relaunched.statusNote?.text.contains("Offline") == true)
    http.set { $0.forecast = .success((forecastJSON(code: 0), 200)) }
    try #require(relaunched.stateAction).perform()
    await settle(relaunched)
    #expect(relaunched.forecast?.current.code == 0 && relaunched.statusNote == nil)
    relaunched.stop()
}

@MainActor @Test func hidingCancelsARunningRequest() async throws {
    let http = MockHTTP()
    http.set { $0.delay = .milliseconds(200) }
    let widget = makeWidget(http)
    widget.start()
    widget.stop()
    try await Task.sleep(for: .milliseconds(300))
    #expect(widget.forecast == nil && widget.refresher.error == nil)
}

@MainActor @Test func choosingACityPersistsItAndReplacesTheForecast() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let http = MockHTTP()
    let widget = makeWidget(http, folder: temp.url)
    widget.start()
    await settle(widget)
    widget.searchText = "Springfield"
    widget.search()
    for _ in 0..<50 where widget.isSearching { try await Task.sleep(for: .milliseconds(10)) }
    #expect(widget.searchResults.count == 2)
    widget.choose(widget.searchResults[1])
    #expect(widget.forecast == nil)  // Pune's forecast is never shown under the new city
    await settle(widget)
    #expect(widget.forecast?.place.detail == "Missouri, United States")
    #expect(http.urls.last?.absoluteString.contains("latitude=37.22") == true)
    let saved = try #require(try JSONFile<WeatherSettings>(url: temp.url.appending(path: "weather.json")).load())
    #expect(saved.place?.admin1 == "Missouri" && saved.unit == .celsius)
    let files = try FileManager.default.contentsOfDirectory(atPath: temp.url.path(percentEncoded: false)).sorted()
    #expect(files == ["weather-cache.json", "weather.json"])  // weather only
    widget.stop()
}

@MainActor @Test func switchingUnitsNeverMixesThem() async throws {
    let http = MockHTTP()
    let widget = makeWidget(http)
    widget.start()
    await settle(widget)
    widget.setUnit(.fahrenheit)
    #expect(widget.forecast?.unit == .fahrenheit)  // the cached Celsius forecast is converted as a whole
    await settle(widget)
    #expect(http.urls.last?.absoluteString.contains("temperature_unit=fahrenheit") == true)
    #expect(widget.settings.value.unit == .fahrenheit)
    widget.stop()
}

@MainActor @Test func aCacheForAnotherPlaceOrACorruptCacheIsIgnored() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let cacheFile: JSONFile<CachedValue<Forecast>> = JSONFile(url: temp.url.appending(path: "weather-cache.json"))
    let london = WeatherPlace(name: "London", latitude: 51.5, longitude: -0.12)
    let forecast = try JSONDecoder().decode(ForecastResponse.self, from: forecastJSON()).forecast(place: london, unit: .celsius)
    try cacheFile.save(CachedValue(value: forecast, storedAt: .now))
    let widget = makeWidget(MockHTTP(), folder: temp.url)  // set to Pune
    #expect(widget.forecast == nil)  // London's forecast is never shown for Pune

    try Data("{ broken".utf8).write(to: cacheFile.url)
    #expect(makeWidget(MockHTTP(), folder: temp.url).forecast == nil)  // a cache miss, not a crash
}

@MainActor @Test func corruptWeatherSettingsAreNotOverwritten() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file = temp.url.appending(path: "weather.json")
    try Data("not json".utf8).write(to: file)
    let settings = WeatherSettingsModel(file: JSONFile(url: file))
    #expect(settings.problem != nil && settings.value.place == nil)
    settings.setPlace(pune)
    #expect(try Data(contentsOf: file) == Data("not json".utf8))
    let tolerant = try JSONDecoder().decode(WeatherSettings.self, from: Data(#"{"unit":"kelvin","place":{"name":5}}"#.utf8))
    #expect(tolerant.unit == .celsius && tolerant.place == nil)
}

// MARK: Location

@MainActor @Test func locationIsAskedOnlyOnClickAndNeverTwice() async throws {
    let http = MockHTTP()
    let location = MockLocation()
    let widget = makeWidget(http, place: nil, location: location)
    widget.start()
    #expect(location.requests == 0)  // never on its own
    await widget.useMyLocation()
    #expect(location.requests == 1)
    let place = try #require(widget.settings.value.place)
    #expect(place.isCurrentLocation && place.latitude == 18.52 && place.longitude == 73.86)  // rounded, not precise

    let denied = MockLocation()
    denied.grant = false
    let other = makeWidget(http, place: pune, location: denied)
    await other.useMyLocation()
    #expect(other.locationMessage?.contains("wasn't allowed") == true && other.settings.value.place == pune)  // city kept
    await other.useMyLocation()
    #expect(denied.requests == 1 && other.locationMessage?.contains("System Settings") == true)  // no second prompt
    for status in [LocationAccess.restricted, .servicesOff] {
        let blocked = MockLocation()
        blocked.status = status
        let widget = makeWidget(http, place: nil, location: blocked)
        await widget.useMyLocation()
        #expect(blocked.requests == 0 && widget.locationMessage != nil && widget.settings.value.place == nil)
    }
}

// MARK: Rendering and attribution

@MainActor @Test func compactAndExpandedRenderWithAttribution() async throws {
    #expect(OpenMeteo.attribution == "Weather data by Open-Meteo")
    #expect(OpenMeteo.attributionURL.absoluteString == "https://open-meteo.com/")
    #expect(OpenMeteo.geocodingCredit.contains("GeoNames"))
    let widget = makeWidget(MockHTTP())
    widget.start()
    await settle(widget)
    let compact = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: CGSize(width: 229, height: 160)))
    let expanded = try #require(render(WidgetHost(widget: widget, presentation: .expanded), size: CGSize(width: 468, height: 160)))
    let still = try #require(render(WidgetHost(widget: widget, presentation: .compact).environment(\.orbitReduceMotion, true),
                                    size: CGSize(width: 229, height: 160)))
    let attribution = try #require(render(WeatherAttribution(), size: CGSize(width: 140, height: 14)))
    #expect(attribution.pixels.contains { $0 > 60 })  // the credit draws
    #expect(compact.width == 229 && expanded.width == 468 && still.width == 229)

    if let folder = ProcessInfo.processInfo.environment["ORBIT_RENDER_DIR"] {
        for (name, presentation, width) in [("weather-compact", WidgetPresentation.compact, 229.0), ("weather-expanded", .expanded, 468.0)] {
            let renderer = ImageRenderer(content: WidgetHost(widget: widget, presentation: presentation)
                .frame(width: width, height: 160).background(Color.black).environment(\.colorScheme, .dark))
            renderer.scale = 2
            if let tiff = renderer.nsImage?.tiffRepresentation,
               let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) {
                try png.write(to: URL(filePath: folder).appending(path: "\(name).png"))
            }
        }
    }
    widget.stop()
}
