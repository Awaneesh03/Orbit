import AppKit
import Foundation
import SwiftUI
import Testing
@testable import Orbit

// Milestone 14: the Daily Digest. Facts name their source; the model is local, optional and
// guarded; nothing is downloaded. A stub provider stands in for Ollama (no network in tests).
// ORBIT_RENDER=1 writes docs/screenshots/m14-digest/*.png.

private struct StubProvider: ChatProvider {
    let id = "ollama"
    let name = "Ollama"
    var baseURL = URL(string: "http://127.0.0.1:11434")!
    var installed: [String] = ["llama3.2:3b"]
    var reply = "Partly cloudy, 21°C in Pune. Next up is Standup."
    func models(session: URLSession) async throws -> [String] {
        if installed.isEmpty { throw ChatError.unavailable }
        return installed
    }
    func stream(model: String, messages: [HubChatMessage], session: URLSession) -> AsyncThrowingStream<String, any Error> {
        let reply = reply
        return AsyncThrowingStream { continuation in
            for word in reply.split(separator: " ", omittingEmptySubsequences: false) { continuation.yield(String(word) + " ") }
            continuation.finish()
        }
    }
}

private let now = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func inputs() -> DailyDigest.Inputs {
    let place = WeatherPlace(name: "Pune", admin1: nil, country: nil, countryCode: nil, latitude: 18.5, longitude: 73.8)
    let forecast = Forecast(place: place, unit: .celsius, timeZone: "Asia/Kolkata",
                            current: .init(time: now, temperature: 21.4, apparent: 21, humidity: 50, wind: 5, code: 2, isDay: true),
                            hourly: [], daily: [.init(date: now, code: 2, high: 29.6, low: 17.2, rainChance: 40)])
    let standup = AgendaEvent(id: "s", title: "Standup", start: now.addingTimeInterval(3600), end: now.addingTimeInterval(5400), isAllDay: false,
                              calendarID: "w", calendarTitle: "Work", color: nil)
    var due = ChecklistItem(title: "Ship M14")
    due.dueDate = Calendar.current.startOfDay(for: now)
    return .init(forecast: forecast, events: [standup], tasks: [due, ChecklistItem(title: "Read")])
}

@Test func factsNameTheirSourceAndClaimNothingElse() {
    let facts = DailyDigest.facts(inputs(), now: now)
    #expect(facts.map(\.source) == ["Weather", "Calendar", "Tasks"])
    #expect(facts[0].text == "Partly cloudy, 21°C in Pune; high 30°C, low 17°C, 40% chance of rain")
    #expect(facts[1].text.hasPrefix("1 more event today; next: Standup at "))
    #expect(facts[2].text == "2 open tasks, 1 due today (Ship M14)")
    #expect(DailyDigest.facts(.init(), now: now).isEmpty)  // nothing known: nothing said
    #expect(DailyDigest.plain([]).hasPrefix("Nothing to summarise yet"))
    let messages = DailyDigest.messages(facts, now: now)
    #expect(messages[0].role == .system && messages[0].content.contains("Use ONLY the facts"))
    #expect(messages[1].content.contains("[Weather] Partly cloudy"))
}

@Test func madeUpNumbersAreRejected() {
    let facts = [DigestFact(source: "Calendar", text: "Standup at 10:30"), DigestFact(source: "Tasks", text: "2 open tasks")]
    #expect(DailyDigest.isGrounded("You have 2 tasks and Standup at 10:30.", in: facts))
    #expect(!DailyDigest.isGrounded("You have 3 tasks.", in: facts))  // invented count
    #expect(!DailyDigest.isGrounded("Standup moved to 11:00.", in: facts))  // invented time
    #expect(!DailyDigest.isGrounded("   ", in: facts))
}

@MainActor @Test func theLocalModelIsOptionalNeverDownloadedAndGuarded() async throws {
    let widget = DailyDigestWidget(file: nil, providers: [StubProvider()], now: { now })
    widget.inputs = inputs
    #expect(!widget.settings.useLocalModel && widget.models.isEmpty)  // off by default: localhost isn't even asked
    widget.setUseLocalModel(true)
    await widget.findModels()
    #expect(widget.settings.model == "llama3.2:3b")
    widget.write()
    for _ in 0 ..< 50 where widget.isWriting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(widget.modelSummary?.model == "llama3.2:3b" && widget.modelSummary?.text.contains("Standup") == true)

    let liar = DailyDigestWidget(file: nil, providers: [StubProvider(reply: "Standup at 9:15, then 4 meetings.")], now: { now })
    liar.inputs = inputs
    liar.setUseLocalModel(true)
    await liar.findModels()
    liar.write()
    for _ in 0 ..< 50 where liar.isWriting { try await Task.sleep(for: .milliseconds(10)) }
    #expect(liar.modelSummary == nil && liar.note?.contains("aren't in your data") == true)  // the plain digest stays

    let none = DailyDigestWidget(file: nil, providers: [StubProvider(installed: [])], now: { now })
    none.setUseLocalModel(true)
    await none.findModels()
    #expect(none.models.isEmpty && none.note?.contains("never downloads") == true)

    let remote = DailyDigestWidget(file: nil, providers: [StubProvider(baseURL: URL(string: "http://example.com:11434")!)], now: { now })
    remote.setUseLocalModel(true)
    await remote.findModels()
    #expect(remote.models.isEmpty)  // anything but this Mac is refused
}

@MainActor @Test func dailyDigestRenders() throws {
    let widget = DailyDigestWidget(file: nil, now: { now })
    widget.inputs = inputs
    let view = widget.content(.expanded).padding(14).frame(width: 420)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16)).environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m14-digest").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "plain.png"))
}
