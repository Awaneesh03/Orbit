import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 14: suggested quick actions from what's going on. Pure rule; nothing is performed here.
// ORBIT_RENDER=1 writes docs/screenshots/m14-quick-actions/suggested.png.

private func session(_ agent: String, status: AgentSession.Status, origin: String? = "com.apple.Terminal", cwd: String? = "/Users/me/Developer/Orbit") -> AgentSession {
    var session = AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: "s")!, title: nil, cwd: cwd, model: nil, status: status,
                               startedAt: .now, lastEventAt: .now)
    session.originBundleID = origin
    return session
}

private let song = NowPlaying(sourceID: "apple-music", appName: "Music", title: "Song", artist: nil, state: .playing, duration: 200,
                              position: 10, positionAt: .now, capabilities: [.playPause], itemID: "1", updatedAt: .now)
private let shelfItem = ShelfItem(id: UUID(), name: "spec.md", storage: .reference, bookmark: nil, path: "/tmp/spec.md", size: 3,
                                  isFolder: false, typeIdentifier: nil, addedAt: .now)

@Test func suggestionsFollowWhatsGoingOnMostPressingFirst() {
    #expect(ContextAction.suggest(QuickContext()).isEmpty)  // nothing going on: no row at all
    let meeting = MeetingCue(eventID: "m", title: "Standup", start: .now.addingTimeInterval(240), phase: .soon)
    let all = QuickContext(waiting: session("claude-code", status: .waiting), meeting: meeting, playing: song,
                           project: "/Users/me/Developer/Orbit", shelfItem: shelfItem)
    let suggested = ContextAction.suggest(all)
    #expect(suggested.map(\.symbol) == ["hand.raised", "calendar", "pause.fill", "cup.and.saucer"])  // four while a meeting is near, urgent first
    #expect(suggested[0].title == "Go to Claude Code" && suggested[1].title == "Meeting in 4 min")

    let calm = QuickContext(playing: song, project: "/Users/me/Developer/Orbit", shelfItem: shelfItem)
    #expect(ContextAction.suggest(calm).map(\.title) == ["Pause", "Orbit", "Copy spec.md"])
}

@Test func suggestionsOnlyOfferWhatCanBeDone() {
    var paused = song
    paused.state = .paused
    var noControl = song
    noControl.capabilities = []
    #expect(ContextAction.suggest(QuickContext(playing: paused)).isEmpty)
    #expect(ContextAction.suggest(QuickContext(playing: noControl)).isEmpty)  // the source can't be paused from Orbit
    #expect(ContextAction.suggest(QuickContext(waiting: session("claude-code", status: .waiting, origin: nil))).isEmpty)  // nowhere to jump
    #expect(ContextAction.suggest(QuickContext(waiting: session("demo-alpha", status: .waiting))).isEmpty)  // simulated
}

@MainActor @Test func suggestedQuickActionsRender() throws {
    let widget = QuickActionsWidget(perform: { _ in })
    widget.context = {
        QuickContext(waiting: session("claude-code", status: .waiting),
                     meeting: MeetingCue(eventID: "m", title: "Standup", start: .now.addingTimeInterval(300), phase: .soon), playing: song)
    }
    let view = widget.content(.expanded).padding(14).frame(width: 420)
        .background(Color(red: 0.11, green: 0.12, blue: 0.16)).environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
    let renderer = ImageRenderer(content: view)
    renderer.scale = 2
    let image = try #require(renderer.cgImage)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m14-quick-actions").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "suggested.png"))
}
