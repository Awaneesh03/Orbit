import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 6: Orbit's notch language. The shape's geometry, and renders of
// every notch surface (ORBIT_RENDER=1 writes docs/screenshots/m6-notch/).

@Test func notchShapeGrowsOutOfTheTopEdge() {
    let rect = CGRect(x: 0, y: 0, width: 300, height: 100)
    let path = NotchShape(shoulder: 10, bottomRadius: 20).path(in: rect)
    #expect(path.boundingRect == rect)  // the shoulders reach the frame's top corners
    #expect(path.contains(CGPoint(x: 150, y: 50)))  // body
    #expect(path.contains(CGPoint(x: 5, y: 0.5)))  // the shoulder fillet, just under the edge
    #expect(!path.contains(CGPoint(x: 2, y: 3)))  // concave: below the fillet curve is outside
    #expect(!path.contains(CGPoint(x: 2, y: 60)))  // below the shoulder: outside (the body is inset)
    #expect(!path.contains(CGPoint(x: 12, y: 99)))  // the rounded bottom corner
    // Degenerate sizes never produce an invalid path.
    #expect(!NotchShape(shoulder: 50, bottomRadius: 90).path(in: CGRect(x: 0, y: 0, width: 20, height: 10)).isEmpty)
    #expect(NotchShape(shoulder: 8, bottomRadius: 8).path(in: .zero).boundingRect.isEmpty)
}

private func item(_ state: PlaybackState) -> NowPlaying {
    NowPlaying(sourceID: "brave-youtube", appName: "YouTube", title: "Midnight City", artist: "M83", state: state, duration: 244,
               position: 96, positionAt: .now, capabilities: [.playPause, .seek], itemID: "1/vid", updatedAt: .now)
}

@MainActor @Test func everyNotchSurfaceRenders() async throws {
    let island = MusicIsland()
    island.refresh(item: item(.playing), enabled: true, dashboardOpen: false)
    try write(MusicIslandView(island: island, perform: { _, _ in }), size: MusicIslandGeometry.compactSize, "island-compact")
    island.tap()
    try write(MusicIslandView(island: island, perform: { _, _ in }), size: MusicIslandGeometry.expandedSize, "island-expanded")
    // The volume HUD's meter and speaker are Core Animation views, which offscreen
    // renders can't draw: it renders (checked) but isn't saved as a screenshot.
    let device = VolumeState(device: 1, name: "MacBook Air Speakers", volume: 0.62, isMuted: false, canSetVolume: true)
    let renderer = ImageRenderer(content: SonicPulseCapsule(state: device, pulse: 0, showsDevice: true, reduceMotion: true))
    #expect(renderer.cgImage != nil)
}

@MainActor
private func write(_ view: some View, size: CGSize, _ name: String) throws {
    let framed = view.frame(width: size.width, height: size.height)
        .padding(24)
        .background(LinearGradient(colors: [Color(red: 0.36, green: 0.42, blue: 0.62), Color(red: 0.78, green: 0.62, blue: 0.55)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing))
        .environment(\.colorScheme, .dark).environment(\.hubStaticRender, true)
    let renderer = ImageRenderer(content: framed)
    renderer.scale = 2
    let image = try #require(renderer.cgImage, "\(name) didn't render")
    #expect(image.width == Int((size.width + 48) * 2))
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m6-notch").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
    try png.write(to: folder.appending(path: "\(name).png"))
}
