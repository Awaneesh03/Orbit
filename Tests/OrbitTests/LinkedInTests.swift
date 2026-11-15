import Foundation
import Testing
@testable import Orbit

// Milestone 4: LinkedIn analytics. No real LinkedIn call is made in tests;
// the official response shapes (docs, 2026-10) are replayed. These pin that
// nothing is invented, every failure has its own state, and the token is
// only sent to LinkedIn.

/// Thread-safe: a refresh's requests can overlap a cancelled one's last request.
private final class LinkedInStub: LinkedInHTTP, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [URLRequest] = []
    let respond: @Sendable (URLRequest) -> (Data, Int)
    init(_ respond: @escaping @Sendable (URLRequest) -> (Data, Int)) { self.respond = respond }
    var requests: [URLRequest] { lock.withLock { recorded } }
    func send(_ request: URLRequest) async throws -> (Data, Int) {
        lock.withLock { recorded.append(request) }
        return respond(request)
    }
}

private func json(_ text: String) -> Data { Data(text.utf8) }
private let now = Date(timeIntervalSince1970: 1_794_650_000)  // 2026-11-14

/// Totals by metric (current period), half of it in the previous one, and two daily points.
private func healthyLinkedIn(_ request: URLRequest) -> (Data, Int) {
    let url = request.url!.absoluteString
    if url.hasSuffix("/v2/userinfo") { return (json(#"{"sub":"abc123","name":"Ada Lovelace"}"#), 200) }
    let counts = ["IMPRESSION": 1200, "MEMBERS_REACHED": 800, "REACTION": 60, "COMMENT": 12, "RESHARE": 6]
    let metric = counts.keys.first { url.contains("queryType=\($0)&") }!
    if url.contains("aggregation=DAILY") {
        // The older object form of metricType: both shapes must parse.
        return (json("""
            {"elements":[{"count":5,"metricType":{"com.linkedin.adsexternalapi.memberanalytics.v1.CreatorPostAnalyticsMetricTypeV1":"\(metric)"},
              "dateRange":{"start":{"year":2026,"month":11,"day":2},"end":{"year":2026,"month":11,"day":3}}},
             {"count":9,"metricType":"\(metric)","dateRange":{"start":{"year":2026,"month":11,"day":1},"end":{"year":2026,"month":11,"day":2}}}],
             "paging":{"count":10,"start":0,"links":[]}}
            """), 200)
    }
    // The previous period starts 56 days back: it had half as much.
    let isPrevious = url.contains("dateRange=(start:(day:19,month:9,year:2026)")
    let count: Int = isPrevious ? counts[metric]! / 2 : counts[metric]!
    return (json(#"{"elements":[{"count":\#(count),"metricType":"\#(metric)"}],"paging":{"count":10,"start":0}}"#), 200)
}

@Test func analyticsRequestsFollowTheOfficialContract() {
    let url = LinkedInAPI.analyticsURL(metric: .impressions, daily: true,
                                       range: LinkedInAPI.dateRange(from: DateComponents(year: 2024, month: 5, day: 4),
                                                                    to: DateComponents(year: 2024, month: 5, day: 6)))
    #expect(url.absoluteString == "https://api.linkedin.com/rest/memberCreatorPostAnalytics?q=me&queryType=IMPRESSION&aggregation=DAILY&dateRange=(start:(day:4,month:5,year:2024),end:(day:6,month:5,year:2024))")
    let request = LinkedInAPI.request(url, token: "t0k")
    #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer t0k")
    #expect(request.value(forHTTPHeaderField: "LinkedIn-Version") == LinkedInAPI.version)
    #expect(request.value(forHTTPHeaderField: "X-Restli-Protocol-Version") == "2.0.0")
    #expect(request.httpMethod == "GET")
}

@Test func periodsAreTheLast28FullDaysAndThe28Before() {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let client = LinkedInClient(http: LinkedInStub { _ in (Data(), 500) }, calendar: calendar)
    let periods = client.periods(now: now)
    #expect(periods.current == "(start:(day:17,month:10,year:2026),end:(day:14,month:11,year:2026))")
    #expect(periods.previous == "(start:(day:19,month:9,year:2026),end:(day:17,month:10,year:2026))")
}

@Test func fetchReadsTotalsTrendsAndProfile() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let stub = LinkedInStub(healthyLinkedIn)
    let analytics = try await LinkedInClient(http: stub, calendar: calendar).fetch(token: "secret", now: now)
    #expect(analytics.profile == LinkedInProfile(id: "abc123", name: "Ada Lovelace"))
    #expect(analytics.totals[.impressions] == 1200 && analytics.totals[.comments] == 12)
    #expect(analytics.previousTotals[.impressions] == 600)
    #expect(analytics.change(.impressions) == 1.0)  // doubled
    let expectedRate: Double = 78.0 / 1200.0  // reactions + comments + reposts over impressions
    #expect(analytics.engagementRate == expectedRate)
    #expect(analytics.dailyImpressions.map(\.count) == [9, 5])  // sorted by day, both metricType shapes read
    // The token goes only to LinkedIn, over HTTPS.
    let hosts = Set(stub.requests.compactMap { $0.url?.host() })
    let schemes = Set(stub.requests.compactMap { $0.url?.scheme })
    #expect(hosts == ["api.linkedin.com"] && schemes == ["https"])
    let expectedCalls = 13  // profile, two periods × five metrics, two daily series
    #expect(stub.requests.count == expectedCalls)
}

@Test func everyFailureHasItsOwnMeaning() async {
    #expect(LinkedInAPI.error(status: 200, body: Data()) == nil)
    #expect(LinkedInAPI.error(status: 401, body: Data()) == .unauthorized)
    #expect(LinkedInAPI.error(status: 403, body: json(#"{"message":"Not enough permissions to access: memberCreatorPostAnalytics"}"#))
        == .notApproved("Not enough permissions to access: memberCreatorPostAnalytics"))
    #expect(LinkedInAPI.error(status: 429, body: Data()) == .rateLimited)
    #expect(LinkedInAPI.error(status: 500, body: Data()) == .failed("LinkedIn returned an error (500)."))
    #expect(throws: LinkedInError.self) { try LinkedInAPI.points(json("<html>")) }

    // An app without the analytics product: the profile works, analytics are refused.
    let unapproved = LinkedInStub { request in
        request.url!.path().hasSuffix("userinfo") ? (json(#"{"sub":"x","name":"X"}"#), 200) : (json(#"{"message":"denied"}"#), 403)
    }
    await #expect(throws: LinkedInError.notApproved("denied")) { try await LinkedInClient(http: unapproved).fetch(token: "t") }
    let expired = LinkedInStub { _ in (Data(), 401) }
    await #expect(throws: LinkedInError.unauthorized) { try await LinkedInClient(http: expired).fetch(token: "t") }
}

@Test func analyticsWithoutHistoryClaimNoTrend() {
    var analytics = LinkedInAnalytics(fetchedAt: now)
    analytics.totals = [.impressions: 0, .reactions: 3]
    analytics.previousTotals = [.impressions: 0]
    #expect(analytics.change(.impressions) == nil)  // nothing to compare: no made-up percentage
    #expect(analytics.change(.reactions) == nil)
    #expect(analytics.engagementRate == nil)  // no impressions: no rate
}

@MainActor @Test func widgetConnectsShowsAndDisconnects() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let store = MemoryCredentialStore()
    var opened: [URL] = []
    let widget = LinkedInWidget(store: store, client: LinkedInClient(http: LinkedInStub(healthyLinkedIn), calendar: calendar),
                                clock: { now }, open: { opened.append($0) })
    #expect(widget.phase == .disconnected && !widget.isConnected)
    widget.start()  // nothing to do without a token
    #expect(widget.phase == .disconnected)
    widget.tokenDraft = "   "
    widget.connect()
    #expect(!widget.isConnected)  // blank is ignored
    widget.tokenDraft = "  real-token \n"
    widget.connect()
    #expect(store.read() == "real-token" && widget.tokenDraft.isEmpty)
    await widget.refresh()?.value
    guard case .ready(let analytics) = widget.phase else { Issue.record("not ready: \(widget.phase)"); return }
    #expect(analytics.totals[.impressions] == 1200)
    widget.disconnect()
    #expect(widget.phase == .disconnected && store.read() == nil)
    #expect(opened.isEmpty)
}

@MainActor @Test func anExpiredTokenAsksForANewOne() async {
    let widget = LinkedInWidget(store: MemoryCredentialStore(), client: LinkedInClient(http: LinkedInStub { _ in (Data(), 401) }))
    widget.tokenDraft = "old"
    widget.connect()
    await widget.refresh()?.value
    #expect(widget.phase == .failed(.unauthorized))
    #expect(widget.state == .ready)  // its own reconnect form, not the host's generic state
}

@MainActor @Test func keychainStoreRoundTripsAndDeletes() throws {
    // A unique service so nothing real is touched; removed at the end.
    let store = KeychainCredentialStore(service: "com.awaneeshgupta.orbit.tests.\(UUID().uuidString)", account: "linkedin")
    defer { store.delete() }
    #expect(store.read() == nil)
    do {
        try store.write("first")
    } catch {
        // The test runner may have no data-protection Keychain access (ad-hoc signing, D3); nothing to check then.
        return
    }
    #expect(store.read() == "first")
    try store.write("second")  // replaces, never duplicates
    #expect(store.read() == "second")
    store.delete()
    #expect(store.read() == nil)
}

// MARK: Rendering (ORBIT_RENDER=1 writes docs/screenshots/m4-linkedin/*.png)

import AppKit
import SwiftUI

@MainActor @Test func everyLinkedInStateRenders() async throws {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    let disconnected = LinkedInWidget(store: MemoryCredentialStore())
    try renderWidget(disconnected, "disconnected")

    let refused = LinkedInWidget(store: MemoryCredentialStore(), client: LinkedInClient(http: LinkedInStub { request in
        request.url!.path().hasSuffix("userinfo") ? (json(#"{"sub":"x","name":"X"}"#), 200)
            : (json(#"{"message":"Not enough permissions to access: memberCreatorPostAnalytics.FINDER-me"}"#), 403)
    }))
    refused.tokenDraft = "t"
    refused.connect()
    await refused.refresh()?.value
    try renderWidget(refused, "not-approved")

    // FIXTURE data (the documented response shape), for the design only: not a live LinkedIn result.
    let fixture = LinkedInWidget(store: MemoryCredentialStore(), client: LinkedInClient(http: LinkedInStub(healthyLinkedIn), calendar: calendar),
                                 clock: { now })
    fixture.tokenDraft = "t"
    fixture.connect()
    await fixture.refresh()?.value
    try renderWidget(fixture, "dashboard-FIXTURE")
}

@MainActor
private func renderWidget(_ widget: LinkedInWidget, _ name: String) throws {
    let view = WidgetHost(widget: widget, presentation: .expanded)
        .frame(width: 468, height: 340).padding(16).background(Color.black)
        .environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
        .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage, "\(name) didn't render")
    #expect(image.width == 500 * 2)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m4-linkedin").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}

@Test func aCancelledRefreshStopsCallingLinkedIn() async throws {
    let stub = LinkedInStub(healthyLinkedIn)
    let task = Task { try await LinkedInClient(http: stub).fetch(token: "t", now: now) }
    task.cancel()
    _ = await task.result
    #expect(stub.requests.count <= 1)  // at most the call already in flight
}
