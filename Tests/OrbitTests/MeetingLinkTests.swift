import Foundation
import Testing
@testable import Orbit

// Milestone 15: Join links. Found locally in the event's URL, location and notes; validated;
// opened only on a click (not tested here: nothing is opened in tests).

@Test func knownMeetingLinksAreFoundInEventText() {
    let meet = MeetingLink.find(url: nil, location: "Google Meet", notes: "Agenda…\nJoin: https://meet.google.com/abc-defg-hij\nThanks")
    #expect(meet?.absoluteString == "https://meet.google.com/abc-defg-hij" && meet.flatMap(MeetingLink.service(of:)) == "Google Meet")
    let zoom = MeetingLink.find(url: nil, location: "https://us02web.zoom.us/j/81234567890?pwd=abc", notes: nil)
    #expect(zoom.flatMap(MeetingLink.service(of:)) == "Zoom")
    let teams = MeetingLink.find(url: nil, location: nil,
                                 notes: "Microsoft Teams meeting <https://teams.microsoft.com/l/meetup-join/19%3ameeting_abc%40thread.v2/0>")
    #expect(teams.flatMap(MeetingLink.service(of:)) == "Microsoft Teams")
    let webex = MeetingLink.find(url: nil, location: nil, notes: "https://acme.webex.com/acme/j.php?MTID=m123")
    #expect(webex.flatMap(MeetingLink.service(of:)) == "Webex")
    // The event's own URL field: any plain https link (e.g. a company's own video service), preferred over notes.
    let own = MeetingLink.find(url: URL(string: "https://video.example.org/room/42"), location: nil, notes: "https://meet.google.com/x")
    #expect(own?.host() == "video.example.org" && own.flatMap(MeetingLink.service(of:)) == nil)
}

@Test func unsafeOrUnknownLinksAreRefused() {
    let bad = ["http://meet.google.com/abc", "javascript:alert(1)", "file:///Applications/Calculator.app", "zoommtg://zoom.us/join?confno=1",
               "https://user:pass@meet.google.com/abc", "https://meet.google.com:8443/abc", "https://localhost/abc", "https://10.0.0.1/abc",
               "https://meet.google.com.evil.example/abc", "https://evilzoom.us/j/1"]
    for text in bad {
        #expect(MeetingLink.find(url: nil, location: nil, notes: "Join here: \(text)") == nil, "notes: \(text)")
    }
    for text in bad.prefix(7) {  // the event's URL field is only "any https": still no http, schemes, credentials, odd ports, bare hosts
        #expect(URL(string: text).flatMap { MeetingLink.find(url: $0, location: nil, notes: nil) } == nil, "url: \(text)")
    }
    #expect(MeetingLink.find(url: nil, location: "Room 4B", notes: "Bring snacks. See https://docs.example.com/agenda") == nil)  // not a video link
    #expect(MeetingLink.find(url: nil, location: nil, notes: nil) == nil)
    #expect(MeetingLink.find(url: nil, location: nil, notes: String(repeating: "x", count: 30_000) + " https://meet.google.com/a") == nil)  // huge text: skipped
    let long = URL(string: "https://meet.google.com/" + String(repeating: "a", count: 3000))!
    #expect(MeetingLink.validate(long, requireKnownHost: true) == nil)
}

@Test func theCueCarriesTheEventsLink() {
    let start = Date(timeIntervalSinceReferenceDate: 800_000_000)
    let event = AgendaEvent(id: "e", title: "Standup", start: start.addingTimeInterval(240), end: start.addingTimeInterval(1800), isAllDay: false,
                            calendarID: "w", calendarTitle: "Work", color: nil, meetingURL: URL(string: "https://meet.google.com/abc-defg-hij"))
    #expect(MeetingCue.current(from: [event], now: start, settings: .init())?.joinURL == event.meetingURL)
}

@Test func meetingActionsAreSuggestedButNeverRun() {
    let link = URL(string: "https://zoom.us/j/1")!
    let soon = MeetingCue(eventID: "m", title: "Standup", start: .now.addingTimeInterval(240), phase: .soon, joinURL: link)
    let song = NowPlaying(sourceID: "apple-music", appName: "Music", title: "Song", artist: nil, state: .playing, duration: 200,
                          position: 10, positionAt: .now, capabilities: [.playPause], itemID: "1", updatedAt: .now)
    let near = ContextAction.suggest(QuickContext(meeting: soon, playing: song, project: "/p", focusIdle: true))
    #expect(near.map(\.symbol) == ["video.fill", "calendar", "pause.fill", "cup.and.saucer"])  // four while a meeting is near
    #expect(near[0].title == "Join Zoom")
    let upcoming = MeetingCue(eventID: "m", title: "Standup", start: .now.addingTimeInterval(1500), phase: .upcoming)
    #expect(ContextAction.suggest(QuickContext(meeting: upcoming, focusIdle: true)).map(\.symbol) == ["calendar", "cup.and.saucer", "timer"])
    #expect(ContextAction.suggest(QuickContext(meeting: upcoming, focusIdle: true, keepingAwake: true)).map(\.symbol) == ["calendar", "timer"])
    #expect(ContextAction.suggest(QuickContext(meeting: soon, focusIdle: true)).map(\.symbol) == ["video.fill", "calendar", "cup.and.saucer"])  // no focus 4 min out
    #expect(ContextAction.suggest(QuickContext(focusIdle: true)).isEmpty)  // no meeting: no meeting actions
}
