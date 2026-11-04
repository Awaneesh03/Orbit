import CoreLocation
import Foundation
import Synchronization

// Weather from Open-Meteo (https://open-meteo.com/): the free API is for
// NON-COMMERCIAL use only (terms: under 10,000 calls a day; apps with
// subscriptions or ads count as commercial) and its data is CC BY 4.0, so it
// is always credited. A commercial build needs an Open-Meteo subscription or
// another licensed provider. Only the chosen place's coordinates (rounded to
// about a kilometre) and weather parameters are sent; nothing else.

enum TemperatureUnit: String, Codable, CaseIterable, Identifiable, Sendable {
    case celsius, fahrenheit
    var id: Self { self }
    var title: String { self == .celsius ? "Celsius (°C)" : "Fahrenheit (°F)" }
    var windUnit: String { self == .celsius ? "km/h" : "mph" }
    var apiWindUnit: String { self == .celsius ? "kmh" : "mph" }
}

/// A place to show weather for: a city from search, or the user's current location.
struct WeatherPlace: Codable, Equatable, Sendable {
    var name: String
    var admin1: String?
    var country: String?
    var countryCode: String?
    var latitude: Double
    var longitude: Double
    var isCurrentLocation = false

    /// "Maharashtra, India": what tells two Puris or Springfields apart.
    var detail: String { [admin1, country].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ") }

    func isSameLocation(as other: WeatherPlace) -> Bool {
        abs(latitude - other.latitude) < 0.01 && abs(longitude - other.longitude) < 0.01
    }
}

/// WMO weather codes as Open-Meteo reports them, with SF Symbols.
enum WeatherCondition: Equatable, Sendable {
    case clear, mainlyClear, partlyCloudy, overcast, fog, drizzle, freezingDrizzle, rain, heavyRain, freezingRain,
         snow, snowGrains, rainShowers, snowShowers, thunderstorm, thunderstormHail, unknown

    init(code: Int) {
        switch code {
        case 0: self = .clear
        case 1: self = .mainlyClear
        case 2: self = .partlyCloudy
        case 3: self = .overcast
        case 45, 48: self = .fog
        case 51, 53, 55: self = .drizzle
        case 56, 57: self = .freezingDrizzle
        case 61, 63: self = .rain
        case 65: self = .heavyRain
        case 66, 67: self = .freezingRain
        case 71, 73, 75: self = .snow
        case 77: self = .snowGrains
        case 80, 81, 82: self = .rainShowers
        case 85, 86: self = .snowShowers
        case 95: self = .thunderstorm
        case 96, 99: self = .thunderstormHail
        default: self = .unknown  // never guessed
        }
    }

    var title: String {
        switch self {
        case .clear: "Clear"
        case .mainlyClear: "Mainly clear"
        case .partlyCloudy: "Partly cloudy"
        case .overcast: "Overcast"
        case .fog: "Fog"
        case .drizzle: "Drizzle"
        case .freezingDrizzle: "Freezing drizzle"
        case .rain: "Rain"
        case .heavyRain: "Heavy rain"
        case .freezingRain: "Freezing rain"
        case .snow: "Snow"
        case .snowGrains: "Snow grains"
        case .rainShowers: "Rain showers"
        case .snowShowers: "Snow showers"
        case .thunderstorm: "Thunderstorm"
        case .thunderstormHail: "Thunderstorm with hail"
        case .unknown: "Conditions unavailable"
        }
    }

    func symbol(isDay: Bool) -> String {
        switch self {
        case .clear: isDay ? "sun.max.fill" : "moon.stars.fill"
        case .mainlyClear: isDay ? "sun.max" : "moon"
        case .partlyCloudy: isDay ? "cloud.sun.fill" : "cloud.moon.fill"
        case .overcast: "cloud.fill"
        case .fog: "cloud.fog.fill"
        case .drizzle: "cloud.drizzle.fill"
        case .freezingDrizzle, .freezingRain: "cloud.sleet.fill"
        case .rain: "cloud.rain.fill"
        case .heavyRain: "cloud.heavyrain.fill"
        case .snow, .snowGrains: "cloud.snow.fill"
        case .rainShowers: isDay ? "cloud.sun.rain.fill" : "cloud.moon.rain.fill"
        case .snowShowers: "cloud.snow.fill"
        case .thunderstorm, .thunderstormHail: "cloud.bolt.rain.fill"
        case .unknown: "cloud"
        }
    }
}

/// A forecast as Orbit keeps it (cached on disk: weather only, no personal data).
struct Forecast: Codable, Equatable, Sendable {
    struct Current: Codable, Equatable, Sendable {
        var time: Date, temperature: Double, apparent: Double, humidity: Int, wind: Double, code: Int, isDay: Bool
    }
    struct Hour: Codable, Equatable, Sendable {
        var time: Date, temperature: Double, rainChance: Int?, code: Int, isDay: Bool
    }
    struct Day: Codable, Equatable, Sendable {
        var date: Date, code: Int, high: Double, low: Double, rainChance: Int?
    }

    var place: WeatherPlace
    var unit: TemperatureUnit
    var timeZone: String
    var current: Current
    var hourly: [Hour]
    var daily: [Day]

    /// The next `count` hours from `now` (the current hour included).
    func nextHours(_ count: Int, from now: Date) -> [Hour] {
        Array(hourly.filter { $0.time > now.addingTimeInterval(-3600) }.prefix(count))
    }

    var today: Day? { daily.first }

    /// The whole forecast in one unit, so a display never mixes °C and °F
    /// (used until a refresh fetches the new unit).
    func converted(to target: TemperatureUnit) -> Forecast {
        guard target != unit else { return self }
        func temperature(_ value: Double) -> Double { target == .fahrenheit ? value * 9 / 5 + 32 : (value - 32) * 5 / 9 }
        func wind(_ value: Double) -> Double { target == .fahrenheit ? value / 1.609344 : value * 1.609344 }
        var copy = self
        copy.unit = target
        copy.current.temperature = temperature(current.temperature)
        copy.current.apparent = temperature(current.apparent)
        copy.current.wind = wind(current.wind)
        copy.hourly = hourly.map { var hour = $0; hour.temperature = temperature($0.temperature); return hour }
        copy.daily = daily.map { var day = $0; day.high = temperature($0.high); day.low = temperature($0.low); return day }
        return copy
    }
}

// MARK: Open-Meteo

/// The network seam (URLSession in the app, fixtures in tests).
protocol WeatherHTTP: Sendable {
    func get(_ url: URL) async throws -> (Data, Int)
}

struct URLSessionWeatherHTTP: WeatherHTTP {
    /// Ephemeral: no cookies, no shared cache; 10 s per request.
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 20
        configuration.httpAdditionalHeaders = ["User-Agent": "Orbit (macOS; personal, non-commercial)"]
        return URLSession(configuration: configuration)
    }()

    func get(_ url: URL) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(from: url)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct OpenMeteo: Sendable {
    let http: any WeatherHTTP

    static let attributionURL = URL(string: "https://open-meteo.com/")!
    static let attribution = "Weather data by Open-Meteo"
    static let geocodingCredit = "City search by Open-Meteo Geocoding, using GeoNames data (CC BY 4.0)"

    /// Up to 8 matches for a city name, without duplicates.
    func search(_ name: String) async throws -> [WeatherPlace] {
        let query = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else { return [] }
        var url = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")!
        url.queryItems = [.init(name: "name", value: query), .init(name: "count", value: "8"),
                          .init(name: "language", value: "en"), .init(name: "format", value: "json")]
        struct Response: Decodable {
            struct Result: Decodable {
                let name: String, latitude: Double, longitude: Double
                let admin1: String?, country: String?, country_code: String?
            }
            let results: [Result]?  // absent when nothing matches
        }
        let response: Response = try await decode(url.url!)
        var places: [WeatherPlace] = []
        for result in response.results ?? [] {
            let place = WeatherPlace(name: result.name, admin1: result.admin1, country: result.country,
                                     countryCode: result.country_code, latitude: result.latitude, longitude: result.longitude)
            if !places.contains(where: { $0.name == place.name && $0.detail == place.detail && $0.isSameLocation(as: place) }) {
                places.append(place)
            }
        }
        return places
    }

    static func forecastURL(for place: WeatherPlace, unit: TemperatureUnit) -> URL {
        var url = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        url.queryItems = [
            .init(name: "latitude", value: String(format: "%.2f", place.latitude)),
            .init(name: "longitude", value: String(format: "%.2f", place.longitude)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day"),
            .init(name: "hourly", value: "temperature_2m,precipitation_probability,weather_code,is_day"),
            .init(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            .init(name: "temperature_unit", value: unit.rawValue),
            .init(name: "wind_speed_unit", value: unit.apiWindUnit),
            .init(name: "timezone", value: "auto"),
            .init(name: "timeformat", value: "unixtime"),
            .init(name: "forecast_days", value: "5"),
        ]
        return url.url!
    }

    func forecast(for place: WeatherPlace, unit: TemperatureUnit) async throws -> Forecast {
        let response: ForecastResponse = try await decode(Self.forecastURL(for: place, unit: unit))
        return try response.forecast(place: place, unit: unit)
    }

    private func decode<T: Decodable>(_ url: URL) async throws -> T {
        let (data, status): (Data, Int)
        do {
            (data, status) = try await http.get(url)
        } catch {
            if let mapped = DataSourceError.from(error) { throw mapped }
            throw CancellationError()
        }
        guard (200..<300).contains(status) else {
            throw DataSourceError.failed(status == 429 ? "Open-Meteo is busy. Try again later." : "Open-Meteo returned an error (HTTP \(status)).")
        }
        do {
            return try JSONDecoder().decode(T.self, from: data)
        } catch {
            throw DataSourceError.failed("Couldn't read the forecast.")
        }
    }
}

/// Open-Meteo's forecast JSON (unix times, parallel arrays).
struct ForecastResponse: Decodable {
    struct Current: Decodable {
        let time: Int, temperature_2m: Double, apparent_temperature: Double, relative_humidity_2m: Int
        let weather_code: Int, wind_speed_10m: Double, is_day: Int
    }
    struct Hourly: Decodable {
        let time: [Int], temperature_2m: [Double], precipitation_probability: [Int?]?, weather_code: [Int], is_day: [Int]
    }
    struct Daily: Decodable {
        let time: [Int], weather_code: [Int], temperature_2m_max: [Double], temperature_2m_min: [Double]
        let precipitation_probability_max: [Int?]?
    }
    let timezone: String?
    let current: Current
    let hourly: Hourly
    let daily: Daily

    func forecast(place: WeatherPlace, unit: TemperatureUnit) throws -> Forecast {
        let hourCount = [hourly.time.count, hourly.temperature_2m.count, hourly.weather_code.count, hourly.is_day.count].min() ?? 0
        let dayCount = [daily.time.count, daily.weather_code.count, daily.temperature_2m_max.count, daily.temperature_2m_min.count].min() ?? 0
        func date(_ seconds: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(seconds)) }
        return Forecast(
            place: place, unit: unit, timeZone: timezone ?? "UTC",
            current: .init(time: date(current.time), temperature: current.temperature_2m, apparent: current.apparent_temperature,
                           humidity: current.relative_humidity_2m, wind: current.wind_speed_10m, code: current.weather_code,
                           isDay: current.is_day == 1),
            hourly: (0..<hourCount).map { i in
                .init(time: date(hourly.time[i]), temperature: hourly.temperature_2m[i],
                      rainChance: hourly.precipitation_probability?[safe: i] ?? nil, code: hourly.weather_code[i], isDay: hourly.is_day[i] == 1)
            },
            daily: (0..<dayCount).map { i in
                .init(date: date(daily.time[i]), code: daily.weather_code[i], high: daily.temperature_2m_max[i],
                      low: daily.temperature_2m_min[i], rainChance: daily.precipitation_probability_max?[safe: i] ?? nil)
            })
    }
}

extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// What the widget asks for; read off the main actor by the data source.
final class WeatherRequest: Sendable {
    private let state = Mutex<(place: WeatherPlace?, unit: TemperatureUnit)>((nil, .celsius))
    var current: (place: WeatherPlace?, unit: TemperatureUnit) { state.withLock { $0 } }
    func set(place: WeatherPlace?, unit: TemperatureUnit) { state.withLock { $0 = (place, unit) } }
}

struct ForecastSource: DataSource {
    let client: OpenMeteo
    let request: WeatherRequest

    func fetch() async throws -> Forecast {
        let (place, unit) = request.current
        guard let place else { throw DataSourceError.unavailable("Choose a city to see the weather.") }
        return try await client.forecast(for: place, unit: unit)
    }
}

// MARK: Settings (weather.json: the place and unit only)

struct WeatherSettings: Codable, Equatable, Sendable {
    var place: WeatherPlace?
    var unit = TemperatureUnit.celsius

    init() {}

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        place = try? container.decodeIfPresent(WeatherPlace.self, forKey: .place)
        unit = (try? container.decode(TemperatureUnit.self, forKey: .unit)) ?? .celsius
    }
}

@MainActor @Observable
final class WeatherSettingsModel {
    static let fileName = "weather.json"
    private var stored: Persisted<WeatherSettings>

    var value: WeatherSettings { stored.value }
    var problem: String? { stored.problem }

    init(file: JSONFile<WeatherSettings>?) {
        stored = file.map { Persisted($0, initial: WeatherSettings()) } ?? Persisted(memory: WeatherSettings())
    }

    func setPlace(_ place: WeatherPlace) {
        guard value.place != place else { return }
        stored.update { $0.place = place }
    }

    func setUnit(_ unit: TemperatureUnit) {
        guard value.unit != unit else { return }
        stored.update { $0.unit = unit }
    }
}

// MARK: Location (optional, only after "Use My Location")

enum LocationAccess: Equatable, Sendable {
    case notDetermined, authorized, denied, restricted, servicesOff
}

@MainActor
protocol LocationProvider: AnyObject {
    func access() -> LocationAccess
    /// Asks once if never asked, then returns an approximate position.
    func currentCoordinate() async throws -> (latitude: Double, longitude: Double)
}

/// CoreLocation at reduced (about 3 km) accuracy; one fix, then it stops.
@MainActor
final class CoreLocationProvider: NSObject, LocationProvider, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var authorization: CheckedContinuation<Void, Never>?
    private var fix: CheckedContinuation<CLLocation, any Error>?

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
    }

    func access() -> LocationAccess {
        guard CLLocationManager.locationServicesEnabled() else { return .servicesOff }
        switch manager.authorizationStatus {
        case .notDetermined: return .notDetermined
        case .authorizedAlways, .authorizedWhenInUse: return .authorized
        case .restricted: return .restricted
        default: return .denied
        }
    }

    func currentCoordinate() async throws -> (latitude: Double, longitude: Double) {
        if access() == .notDetermined {
            await withCheckedContinuation { authorization = $0; manager.requestWhenInUseAuthorization() }
        }
        guard access() == .authorized else { throw DataSourceError.needsAccess("Location access isn't allowed.") }
        let location = try await withCheckedThrowingContinuation { fix = $0; manager.requestLocation() }
        return (location.coordinate.latitude, location.coordinate.longitude)
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        MainActor.assumeIsolated {
            guard status != .notDetermined else { return }
            authorization?.resume()
            authorization = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            guard let location = locations.last else { return }
            fix?.resume(returning: location)
            fix = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: any Error) {
        MainActor.assumeIsolated {
            fix?.resume(throwing: DataSourceError.failed("Couldn't find your location."))
            fix = nil
        }
    }
}
