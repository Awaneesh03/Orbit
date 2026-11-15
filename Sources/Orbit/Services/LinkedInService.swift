import Foundation
import Security

// LinkedIn analytics for the Briefing (Milestone 4). Official APIs only:
// - Member Post Analytics, `GET /rest/memberCreatorPostAnalytics`
//   (scope r_member_postAnalytics, Community Management API product; needs
//   LinkedIn's approval of the user's developer app);
// - OpenID Connect `GET /v2/userinfo` (scopes openid profile; self-serve).
// No scraping, no password, nothing bypassed. Until decision D3 (a stable
// signing identity, so Keychain items survive rebuilds) is approved, the
// token lives in memory only; `KeychainCredentialStore` is ready for then.
// No loopback OAuth listener either (D2): the token comes from LinkedIn's
// own developer-portal Token Generator, pasted by the user.

enum LinkedInMetric: String, CaseIterable, Codable, Sendable {
    case impressions = "IMPRESSION", reached = "MEMBERS_REACHED", reactions = "REACTION",
         comments = "COMMENT", reshares = "RESHARE"

    var title: String {
        switch self {
        case .impressions: "Impressions"
        case .reached: "Members reached"
        case .reactions: "Reactions"
        case .comments: "Comments"
        case .reshares: "Reposts"
        }
    }
}

struct LinkedInDay: Codable, Equatable, Sendable {
    let date: DateComponents
    let count: Int
}

struct LinkedInProfile: Codable, Equatable, Sendable {
    let id: String
    let name: String
}

/// What the dashboard shows: totals for the last 28 days and the 28 before
/// (for the trend), and daily impressions and reactions.
struct LinkedInAnalytics: Codable, Equatable, Sendable {
    var profile: LinkedInProfile?
    var totals: [LinkedInMetric: Int] = [:]
    var previousTotals: [LinkedInMetric: Int] = [:]
    var dailyImpressions: [LinkedInDay] = []
    var dailyReactions: [LinkedInDay] = []
    var fetchedAt: Date

    /// Change against the previous period, nil when there's nothing to compare.
    func change(_ metric: LinkedInMetric) -> Double? {
        guard let now = totals[metric], let before = previousTotals[metric], before > 0 else { return nil }
        return Double(now - before) / Double(before)
    }

    /// Reactions + comments + reposts per impression.
    var engagementRate: Double? {
        guard let impressions = totals[.impressions], impressions > 0 else { return nil }
        let engaged = [LinkedInMetric.reactions, .comments, .reshares].compactMap { totals[$0] }.reduce(0, +)
        return Double(engaged) / Double(impressions)
    }
}

enum LinkedInError: Error, Equatable, Sendable {
    /// 401: expired or revoked token.
    case unauthorized
    /// 403: the token or app lacks a scope or product approval.
    case notApproved(String)
    case rateLimited
    case failed(String)
}

// MARK: Requests

enum LinkedInAPI {
    /// LinkedIn-Version (YYYYMM). Versions are supported for about a year;
    /// 202610 is the documented default as of 2026-11-14.
    static let version = "202610"
    static let base = URL(string: "https://api.linkedin.com")!
    static let userInfo = URL(string: "https://api.linkedin.com/v2/userinfo")!

    /// The Rest.li `dateRange` value: start inclusive, end exclusive.
    static func dateRange(from start: DateComponents, to end: DateComponents) -> String {
        func part(_ c: DateComponents) -> String { "(day:\(c.day ?? 1),month:\(c.month ?? 1),year:\(c.year ?? 1970))" }
        return "(start:\(part(start)),end:\(part(end)))"
    }

    /// Rest.li values contain ( ) , : which must stay literal, so the query is
    /// built by hand (all its parts are fixed ASCII; nothing user-typed).
    static func analyticsURL(metric: LinkedInMetric, daily: Bool, range: String) -> URL {
        let query = "q=me&queryType=\(metric.rawValue)&aggregation=\(daily ? "DAILY" : "TOTAL")&dateRange=\(range)"
        return URL(string: "https://api.linkedin.com/rest/memberCreatorPostAnalytics?\(query)")!
    }

    static func request(_ url: URL, token: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue(version, forHTTPHeaderField: "LinkedIn-Version")
        request.setValue("2.0.0", forHTTPHeaderField: "X-Restli-Protocol-Version")
        return request
    }

    static func error(status: Int, body: Data) -> LinkedInError? {
        switch status {
        case 200..<300: return nil
        case 401: return .unauthorized
        case 403:
            let message = (try? JSONSerialization.jsonObject(with: body) as? [String: Any])?["message"] as? String
            return .notApproved(message ?? "LinkedIn refused this request for your app.")
        case 429: return .rateLimited
        default: return .failed("LinkedIn returned an error (\(status)).")
        }
    }

    /// One response's data points. `metricType` is a plain string from
    /// 202605 and a one-key object before; only `count` and the date are read.
    static func points(_ data: Data) throws -> [(count: Int, start: DateComponents?)] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let elements = root["elements"] as? [[String: Any]] else { throw LinkedInError.failed("Unexpected response from LinkedIn.") }
        return elements.map { element in
            let count = (element["count"] as? NSNumber)?.intValue ?? 0
            let start = ((element["dateRange"] as? [String: Any])?["start"] as? [String: Any]).map {
                DateComponents(year: $0["year"] as? Int, month: $0["month"] as? Int, day: $0["day"] as? Int)
            }
            return (count, start)
        }
    }

    static func profile(_ data: Data) -> LinkedInProfile? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = object["sub"] as? String else { return nil }
        return LinkedInProfile(id: id, name: object["name"] as? String ?? "LinkedIn member")
    }
}

protocol LinkedInHTTP: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, Int)
}

struct URLSessionLinkedInHTTP: LinkedInHTTP {
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral  // no cookies, no cache: the token never lands on disk
        configuration.timeoutIntervalForRequest = 15
        return URLSession(configuration: configuration)
    }()

    func send(_ request: URLRequest) async throws -> (Data, Int) {
        let (data, response) = try await Self.session.data(for: request)
        return (data, (response as? HTTPURLResponse)?.statusCode ?? 0)
    }
}

struct LinkedInClient: Sendable {
    let http: any LinkedInHTTP
    var calendar = Calendar(identifier: .gregorian)

    /// The last 28 full days (ending yesterday) and the 28 before them.
    func periods(now: Date) -> (current: String, previous: String) {
        let today = calendar.startOfDay(for: now)
        func day(_ offset: Int) -> DateComponents {
            calendar.dateComponents([.year, .month, .day], from: calendar.date(byAdding: .day, value: offset, to: today)!)
        }
        return (LinkedInAPI.dateRange(from: day(-28), to: day(0)), LinkedInAPI.dateRange(from: day(-56), to: day(-28)))
    }

    func fetch(token: String, now: Date = .now) async throws -> LinkedInAnalytics {
        var analytics = LinkedInAnalytics(fetchedAt: now)
        // Who: optional (needs the openid + profile scopes); only a 401 matters here.
        let (who, whoStatus) = try await http.send(LinkedInAPI.request(LinkedInAPI.userInfo, token: token))
        if whoStatus == 401 { throw LinkedInError.unauthorized }
        if (200..<300).contains(whoStatus) { analytics.profile = LinkedInAPI.profile(who) }

        let (current, previous) = periods(now: now)
        for metric in LinkedInMetric.allCases {
            analytics.totals[metric] = try await total(metric, range: current, token: token)
            analytics.previousTotals[metric] = try await total(metric, range: previous, token: token)
        }
        analytics.dailyImpressions = try await daily(.impressions, range: current, token: token)
        analytics.dailyReactions = try await daily(.reactions, range: current, token: token)
        return analytics
    }

    private func get(_ url: URL, token: String) async throws -> Data {
        try Task.checkCancellation()  // a superseded refresh stops here instead of spending the app's daily quota
        let (data, status) = try await http.send(LinkedInAPI.request(url, token: token))
        if let error = LinkedInAPI.error(status: status, body: data) { throw error }
        return data
    }

    private func total(_ metric: LinkedInMetric, range: String, token: String) async throws -> Int {
        let data = try await get(LinkedInAPI.analyticsURL(metric: metric, daily: false, range: range), token: token)
        return try LinkedInAPI.points(data).reduce(0) { $0 + $1.count }
    }

    private func daily(_ metric: LinkedInMetric, range: String, token: String) async throws -> [LinkedInDay] {
        let data = try await get(LinkedInAPI.analyticsURL(metric: metric, daily: true, range: range), token: token)
        let days = try LinkedInAPI.points(data).compactMap { point in point.start.map { LinkedInDay(date: $0, count: point.count) } }
        return days.sorted { (calendar.date(from: $0.date) ?? .distantPast) < (calendar.date(from: $1.date) ?? .distantPast) }
    }
}

// MARK: Credentials

/// Where an access token is kept. Never a file, never UserDefaults, never logged.
@MainActor
protocol CredentialStore: AnyObject {
    func read() -> String?
    func write(_ secret: String) throws
    func delete()
}

/// For the length of this launch only (decision D3, until stable signing).
@MainActor
final class MemoryCredentialStore: CredentialStore {
    private var secret: String?
    func read() -> String? { secret }
    func write(_ secret: String) { self.secret = secret }
    func delete() { secret = nil }
}

/// The data-protection Keychain, this device only, after first unlock.
/// Switched on once D3 (a stable signing identity) is approved.
@MainActor
final class KeychainCredentialStore: CredentialStore {
    let service: String
    let account: String

    init(service: String, account: String) {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account,
         kSecUseDataProtectionKeychain as String: true]
    }

    func read() -> String? {
        var item: CFTypeRef?
        var search = query
        search[kSecReturnData as String] = true
        search[kSecMatchLimit as String] = kSecMatchLimitOne
        guard SecItemCopyMatching(search as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func write(_ secret: String) throws {
        delete()
        var add = query
        add[kSecValueData as String] = Data(secret.utf8)
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess else { throw LinkedInError.failed("Couldn't save to the Keychain (\(status)).") }
    }

    func delete() { SecItemDelete(query as CFDictionary) }
}
