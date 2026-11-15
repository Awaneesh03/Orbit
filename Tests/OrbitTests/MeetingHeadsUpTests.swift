import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 14: the next meeting in the notch wings. Mock calendar only; no
// test reads the real calendar or asks for access.
// ORBIT_RENDER=1 writes docs/screenshots/m14-meeting/*.png.

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)
private func meeting(_ title: String, inMinutes start: Double, length: Double = 30, allDay: Bool = false, calendar: String = "work") -> AgendaEvent {
    let begin = t0.addingTimeInterval(start * 60)
    return AgendaEvent(id: "\(title)@\(start)", title: title, start: begin, end: begin.addingTimeInterval(length * 60), isAllDay: allDay,
                       calendarID: calendar, calendarTitle: calendar, color: nil)
}

@Test func theCueEscalatesAndThenLeaves() {
    let settings = MeetingCue.Settings()  // 30 / 5 / 5
    func phase(_ minutes: Double) -> MeetingCue.Phase? {
        MeetingCue.current(from: [meeting("Standup", inMinutes: minutes)], now: t0, settings: settings)?.phase
    }
    #expect(phase(45) == nil)  // too far off: the wings stay as they were
    #expect(phase(30) == .upcoming)
    #expect(phase(12) == .upcoming)
    #expect(phase(5) == .soon)
    #expect(phase(0.5) == .soon)
    #expect(phase(0) == .started)
    #expect(phase(-4) == .started)
    #expect(phase(-5) == nil)  // started a while ago: gone, never permanent
    #expect(phase(-40) == nil)  // over
}

@Test func allDayCancelledAndFinishedEventsNeverShow() {
    let settings = MeetingCue.Settings()
    #expect(MeetingCue.current(from: [meeting("Holiday", inMinutes: 10, allDay: true)], now: t0, settings: settings) == nil)
    #expect(MeetingCue.current(from: [meeting("Done", inMinutes: -31)], now: t0, settings: settings) == nil)
    // Cancelled occurrences are dropped where EventKit is read (EventKitStore.events: status != .canceled).
}

@Test func theNearestMeetingWins() {
    let events = [meeting("Later", inMinutes: 25), meeting("Sooner", inMinutes: 3), meeting("Holiday", inMinutes: 1, allDay: true)]
    let cue = MeetingCue.current(from: events, now: t0, settings: .init())
    #expect(cue?.title == "Sooner" && cue?.phase == .soon)
    // A meeting that just started beats one 20 minutes off.
    let both = MeetingCue.current(from: [meeting("Now", inMinutes: -2), meeting("Next", inMinutes: 20)], now: t0, settings: .init())
    #expect(both?.title == "Now" && both?.phase == .started)
}

@Test func timingsAreConfigurable() {
    let settings = MeetingCue.Settings(noticeMinutes: 15, urgentMinutes: 2)
    #expect(MeetingCue.current(from: [meeting("A", inMinutes: 20)], now: t0, settings: settings) == nil)
    #expect(MeetingCue.current(from: [meeting("A", inMinutes: 10)], now: t0, settings: settings)?.phase == .upcoming)
    #expect(MeetingCue.current(from: [meeting("A", inMinutes: 4)], now: t0, settings: settings)?.phase == .upcoming)
    #expect(MeetingCue.current(from: [meeting("A", inMinutes: 2)], now: t0, settings: settings)?.phase == .soon)
}

@Test func theWatcherWakesAtTheNextBoundaryOnly() {
    let events = [meeting("Standup", inMinutes: 40)]
    // Next change: entering the 30-minute window, 10 minutes from now.
    #expect(MeetingCue.nextChange(after: t0, events: events, settings: .init()) == t0.addingTimeInterval(600))
    #expect(MeetingCue.nextChange(after: t0, events: [], settings: .init()) == nil)
}

@Test func countdownReadsNaturally() {
    let cue = MeetingCue(eventID: "x", title: "Standup", start: t0.addingTimeInterval(12 * 60 - 20), phase: .upcoming)
    #expect(cue.countdown(at: t0) == "in 12 min")
    #expect(cue.countdown(at: t0.addingTimeInterval(11 * 60 + 30)) == "in 1 min")
    #expect(cue.countdown(at: t0.addingTimeInterval(13 * 60)) == "now")
}

@MainActor @Test func theWatcherReadsOnlyWithAccessAndTheWidgetConnected() {
    let store = MockCalendarStore()
    store.set { $0.events = [meeting("Standup", inMinutes: 4), meeting("Private", inMinutes: 3, calendar: "home")] }
    var choice = CalendarSettings()
    let watcher = MeetingWatcher(store: store, calendarSettings: { choice }, clock: { t0 })

    watcher.start()
    #expect(watcher.cue == nil && store.requests == 0)  // no access: nothing, and never asks
    store.set { $0.access = .granted }
    watcher.refresh()
    #expect(watcher.cue?.title == "Private")  // all calendars: the nearest
    choice.selectedCalendarIDs = ["work"]
    watcher.refresh()
    #expect(watcher.cue?.title == "Standup" && watcher.cue?.phase == .soon)  // the widget's chosen calendars only
    store.set { $0.events = [] }
    store.simulateChange()  // the calendar changed: re-read
    // The handler hops to the main actor; refresh directly for a deterministic check.
    watcher.refresh()
    #expect(watcher.cue == nil)
    store.set { $0.events = [meeting("Standup", inMinutes: 4)] }
    choice.isEnabled = false  // Calendar widget › Disconnect
    watcher.refresh()
    #expect(watcher.cue == nil)
    choice.isEnabled = true
    watcher.refresh()
    #expect(watcher.cue != nil)
    watcher.stop()
    #expect(watcher.cue == nil && !watcher.isRunning)
    #expect(store.requests == 0)
}

@Test func meetingsTakeTheWingsByUrgency() throws {
    let claude = try #require(AgentID("claude-code"))
    let music = NowPlaying(sourceID: "brave-youtube", appName: "YouTube", title: "Song", artist: nil, state: .playing, duration: 200,
                           position: 10, positionAt: .now, capabilities: [.playPause], itemID: "1/v", updatedAt: .now)
    let upcoming = MeetingCue(eventID: "m", title: "Standup", start: t0, phase: .upcoming)
    let soon = MeetingCue(eventID: "m", title: "Standup", start: t0, phase: .soon)
    let started = MeetingCue(eventID: "m", title: "Standup", start: t0, phase: .started)
    func choose(_ tone: NotchCompanion.Tone?, _ cue: MeetingCue?, dashboard: Bool = false) -> WingContent? {
        WingContent.choose(lead: tone.map { (agent: claude, tone: $0) }, music: music, meeting: cue, dashboardOpen: dashboard,
                           owner: .orbit, hasNotch: true)
    }
    #expect(choose(.attention, soon) == .agent(claude, .attention))  // an agent waiting on you comes first
    #expect(choose(.failed, started) == .agent(claude, .failed))
    #expect(choose(.working, soon) == .meeting(soon))  // about to start beats a working agent
    #expect(choose(.working, started) == .meeting(started))
    #expect(choose(.working, upcoming) == .agent(claude, .working))  // a heads-up yields to work in progress
    #expect(choose(nil, upcoming) == .meeting(upcoming))  // and beats music
    #expect(choose(.finished, nil) == .music(music))
    #expect(choose(nil, soon, dashboard: true) == nil)  // the dashboard is open
}

@Test func meetingPreferencesDecodeTolerantlyAndClamp() throws {
    var prefs = OrbitPreferences()
    #expect(prefs.meetingHeadsUp && prefs.meetingNoticeMinutes == 30 && prefs.meetingUrgentMinutes == 5)
    prefs.meetingNoticeMinutes = 500
    prefs.meetingUrgentMinutes = 0
    let clamped = prefs.clamped()
    #expect(clamped.meetingNoticeMinutes == 60 && clamped.meetingUrgentMinutes == 1)
    let old = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"compactStyle":"beside","meetingNoticeMinutes":"x"}"#.utf8))
    #expect(old.compactStyle == .beside && old.meetingNoticeMinutes == 30 && old.meetingHeadsUp)
}

@MainActor @Test func meetingWingsRender() throws {
    let wings = NotchWings()
    wings.reduceMotion = true
    let now = Date.now
    for (cue, name) in [(MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(24 * 60), phase: .upcoming), "upcoming"),
                        (MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(4 * 60), phase: .soon), "soon"),
                        (MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(-60), phase: .started), "started")] {
        wings.show(.meeting(cue))
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.62, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 180, height: 32)
            NotchWingsView(wings: wings, notchWidth: 180).frame(width: 180 + 2 * WingGeometry.width, height: 32)
        }
        .frame(width: 420, height: 70)
        .environment(\.hubStaticRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m14-meeting").standardized
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
    }
}
