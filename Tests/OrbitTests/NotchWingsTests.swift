import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 9: the camera-flanking compact state. Opt-in, never takes a
// click, yields to the dashboard and Coucou, notched displays only.
// ORBIT_RENDER=1 writes docs/screenshots/m9-wings/*.png.

private func song(_ state: PlaybackState) -> NowPlaying {
    NowPlaying(sourceID: "brave-youtube", appName: "YouTube", title: "Midnight City", artist: "M83", state: state, duration: 244,
               position: 96, positionAt: .now, capabilities: [.playPause], itemID: "1/vid", updatedAt: .now)
}

@Test func wingsShowWhatMattersMostAndStepAside() throws {
    let claude = try #require(AgentID("claude-code"))
    let playing = song(.playing)
    func choose(_ lead: (AgentID, NotchCompanion.Tone)?, _ music: NowPlaying?, dashboard: Bool = false,
                owner: NotchCoordination.Owner = .orbit, notch: Bool = true) -> WingContent? {
        WingContent.choose(lead: lead.map { (agent: $0.0, tone: $0.1) }, music: music, dashboardOpen: dashboard, owner: owner, hasNotch: notch)
    }
    #expect(choose((claude, .attention), playing) == .agent(claude, .attention))  // an agent waiting beats music
    #expect(choose((claude, .working), playing) == .agent(claude, .working))
    #expect(choose((claude, .finished), playing) == .music(playing))  // finished work doesn't hold the wings
    #expect(choose(nil, song(.paused)) == nil)  // paused music: clean
    #expect(choose(nil, nil) == nil)
    #expect(choose((claude, .attention), playing, dashboard: true) == nil)  // the dashboard is open
    #expect(choose((claude, .attention), playing, owner: .coucou) == nil)  // Coucou has the notch
    #expect(choose((claude, .attention), playing, notch: false) == nil)  // no notch: the pills stay
}

@Test func wingsFlankTheNotchAtItsHeight() throws {
    let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
    let left = CGRect(x: 0, y: 924, width: 645, height: 32), right = CGRect(x: 825, y: 924, width: 645, height: 32)
    let frame = try #require(WingGeometry.frame(screen: screen, left: left, right: right))
    #expect(frame.minX == 645 - WingGeometry.width && frame.maxX == 825 + WingGeometry.width)
    #expect(frame.maxY == screen.maxY && frame.height == 32)  // flush with the top, the notch's height
    #expect(WingGeometry.frame(screen: screen, left: nil, right: right) == nil)  // no notch
    #expect(WingGeometry.frame(screen: screen, left: right, right: left) == nil)  // nonsense areas
}

@MainActor @Test func theWingsWindowNeverTakesTheMouse() {
    let panel = NotchWingsPanel(wings: NotchWings())
    #expect(panel.ignoresMouseEvents && !panel.canBecomeKey && !panel.canBecomeMain)
    #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))  // not over full-screen apps
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces))
    panel.refreshVisibility()
    #expect(!panel.isVisible)  // nothing to show: off screen
}

@MainActor @Test func wingsRender() throws {
    let claude = try #require(AgentID("claude-code"))
    let wings = NotchWings()
    wings.reduceMotion = true
    for (content, name) in [(WingContent.agent(claude, .attention), "agent-needs-you"), (.agent(claude, .working), "agent-working"),
                            (.music(song(.playing)), "music")] {
        wings.show(content)
        let view = ZStack(alignment: .top) {
            LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.62, blue: 0.55)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            // The hardware notch, for the picture only.
            UnevenRoundedRectangle(bottomLeadingRadius: 10, bottomTrailingRadius: 10).fill(.black).frame(width: 180, height: 32)
            NotchWingsView(wings: wings, notchWidth: 180).frame(width: 180 + 2 * WingGeometry.width, height: 32)
        }
        .frame(width: 420, height: 70)
        .environment(\.hubStaticRender, true)
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.cgImage)
        guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
        let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m9-wings").standardized
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
    }
}
