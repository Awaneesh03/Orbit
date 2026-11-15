import AppKit
import ImageIO
import SwiftUI
import Testing
import UniformTypeIdentifiers
@testable import Orbit

// Milestone 18: the charging animation. When it runs, the one-time completion, the layers
// themselves, and a frame sequence of the real widget (ORBIT_RENDER=1 → docs/screenshots/m18/).

private let t0 = Date(timeIntervalSinceReferenceDate: 800_000_000)

@Test func theEnergyFlowRunsOnlyWhileActuallyCharging() {
    typealias S = ChargeAnimationState
    #expect(S.effect(.charging, shown: true, enabled: true, reduceMotion: false) == .charging)
    #expect(S.effect(.pluggedInNotCharging, shown: true, enabled: true, reduceMotion: false) == .none)  // a charger isn't charging
    #expect(S.effect(.charged, shown: true, enabled: true, reduceMotion: false) == .none)
    #expect(S.effect(.onBattery, shown: true, enabled: true, reduceMotion: false) == .none)
    #expect(S.effect(nil, shown: true, enabled: true, reduceMotion: false) == .none)  // unavailable
    #expect(S.effect(.charging, shown: false, enabled: true, reduceMotion: false) == .none)  // dashboard hidden
    #expect(S.effect(.charging, shown: true, enabled: true, reduceMotion: true) == .none)  // Reduce Motion
    #expect(S.effect(.charging, shown: true, enabled: false, reduceMotion: false) == .none)  // setting off
}

@Test func theCompletionPlaysOnceAndNeverAtLaunch() {
    var state = ChargeAnimationState()
    let played1 = state.observe(.charged, at: t0)
    #expect(!played1)  // launched with a full battery: nothing
    let played2 = state.observe(.charged, at: t0 + 60)
    #expect(!played2)
    var charging = ChargeAnimationState()
    charging.observe(.charging, at: t0)
    let played3 = charging.observe(.charged, at: t0 + 300)
    #expect(played3 && charging.completions == 1)
    let played4 = charging.observe(.charged, at: t0 + 360)
    #expect(!played4 && charging.completions == 1)  // later refreshes: no repeat
    // Unplug, plug back in, charge to full again: a new cycle, one more completion.
    charging.observe(.onBattery, at: t0 + 3600)
    charging.observe(.charging, at: t0 + 3700)
    charging.observe(.pluggedInNotCharging, at: t0 + 3800)  // e.g. paused at the limit, then topped up
    let played5 = charging.observe(.charged, at: t0 + 3900)
    #expect(played5 && charging.completions == 2)
    var stale = ChargeAnimationState()
    stale.observe(.charging, at: t0)
    let played6 = stale.observe(.charged, at: t0 + ChargeAnimationState.completionWindow + 1)
    #expect(!played6)  // seen full long after: just full
    var stopped = ChargeAnimationState()
    stopped.observe(.charging, at: t0)
    let played7 = stopped.observe(.onBattery, at: t0 + 10)
    #expect(!played7)  // charging stopped by unplugging: no completion
}

@MainActor @Test func theWidgetFollowsRealReadingsOnly() {
    var reading: BatteryStatus? = BatteryStatus(percent: 97, isCharging: true, isPluggedIn: true)
    var clock = t0
    let widget = BatteryWidget(read: { reading }, energy: EnergyMonitor(reader: LibprocReader(), interval: .seconds(60)), now: { clock })
    widget.refresh()
    #expect(widget.status?.percent == 97 && widget.chargeAnimation.completions == 0)
    reading = BatteryStatus(percent: 98, isCharging: true, isPluggedIn: true)
    clock += 120
    widget.refresh()
    #expect(widget.status?.percent == 98)  // the fill and number move to the new reading, nothing in between
    reading = BatteryStatus(percent: 100, isCharging: false, isPluggedIn: true, isCharged: true)
    clock += 120
    widget.refresh()
    widget.refresh()
    #expect(widget.status?.chargeState == .charged && widget.chargeAnimation.completions == 1)
    reading = nil
    widget.refresh()
    #expect(widget.state == .unavailable("No battery"))
}

@Test func theFillIsTheLevelNotTheDecoration() {
    let inner = BatteryGlyph.size.width - 2 * BatteryGlyph.inset
    #expect(BatteryGlyph.fillWidth(0.5) == inner / 2 && BatteryGlyph.fillWidth(1) == inner && BatteryGlyph.fillWidth(1.4) == inner)
    #expect(BatteryGlyph.fillWidth(0) == 3)  // a sliver, so an empty battery is still drawn
    #expect(BatteryGlyph.symbol(.charging) == "bolt.fill" && BatteryGlyph.symbol(.pluggedInNotCharging) == "powerplug.fill")
    #expect(BatteryGlyph.symbol(.charged) == "checkmark" && BatteryGlyph.symbol(.onBattery) == nil)
}

@MainActor private func inWindow<V: NSView>(_ view: V, size: CGSize) -> NSWindow {
    view.frame = CGRect(origin: .zero, size: size)
    let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = view
    view.layoutSubtreeIfNeeded()
    return window
}

@MainActor @Test func theChargingLayersAnimateInTheWindowServer() {
    let effects = ChargingEffectsView(mode: .charging)
    let window = inWindow(effects, size: CGSize(width: 36, height: 16))
    #expect(effects.activeAnimations == ["flow", "surface", "breathe"] && effects.particles.birthRate == 1)
    effects.mode = .completion  // charging finished
    effects.layoutSubtreeIfNeeded()
    #expect(!effects.isAnimating && effects.activeAnimations.contains("flash") && effects.activeAnimations.contains("complete"))
    #expect(effects.completionPlayed && effects.particles.birthRate == 0)
    let glow = ChargingGlowView()
    let glowWindow = inWindow(glow, size: CGSize(width: 62, height: 38))
    #expect(glow.isAnimating)
    let empty = ChargingEffectsView(mode: .charging)
    let emptyWindow = inWindow(empty, size: CGSize(width: 4, height: 16))
    #expect(empty.particles.birthRate == 0)  // nearly empty: no particles squeezed into a sliver
    _ = (window, glowWindow, emptyWindow)
}

@MainActor @Test func theLiquidSurfaceLoopsSeamlessly() {
    let path = ChargingEffectsView.wavePath(width: 60, height: 16, wavelength: 25.6)
    let box = path.boundingBox
    #expect(box.minY == 0 && box.maxY > 16 * 0.58 && box.maxY < 16 * 0.75)  // a gentle surface in the fill, never above it
}

// MARK: Screenshots and a frame sequence of the real widget

@MainActor private func findViews<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
    (view as? T).map { [$0] } ?? [] + view.subviews.flatMap { findViews(type, in: $0) }
}

@MainActor @Test func chargingAnimationRecording() throws {
    let states: [(BatteryStatus, String)] = [
        (BatteryStatus(percent: 62, isCharging: true, isPluggedIn: true), "charging"),
        (BatteryStatus(percent: 80, isCharging: false, isPluggedIn: true), "plugged-not-charging"),
        (BatteryStatus(percent: 100, isCharging: false, isPluggedIn: true, isCharged: true), "charged"),
        (BatteryStatus(percent: 54, isCharging: false, isPluggedIn: false), "on-battery"),
    ]
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m18").standardized
    let rendering = ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1"
    if rendering { try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true) }
    for (dark, mode) in [(true, "dark"), (false, "light")] {
        for (status, name) in states {
            let widget = BatteryWidget(read: { status }, energy: EnergyMonitor(reader: LibprocReader(), interval: .seconds(60)))
            widget.showsEnergy = false
            widget.start()  // shown: the animation may run
            let size = CGSize(width: 220, height: 84)
            // The dashboard is always dark (DashboardView forces it); "light" is its 85 % surface over a light wallpaper.
            let wallpaper = dark ? Color(red: 0.10, green: 0.11, blue: 0.16) : Color(red: 0.90, green: 0.92, blue: 0.97)
            let view = widget.content(.compact).padding(16).frame(width: size.width, height: size.height, alignment: .topLeading)
                .background(Color(red: 0.07, green: 0.08, blue: 0.10).opacity(0.85))
                .background(wallpaper)
                .environment(\.colorScheme, .dark)
            let host = NSHostingView(rootView: view)
            let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
            window.contentView = host
            window.displayIfNeeded()
            CATransaction.flush()
            let effects = findViews(ChargingEffectsView.self, in: host)
            #expect(effects.isEmpty == (status.chargeState != .charging))  // the energy layers exist only while charging
            let frames: [TimeInterval] = status.chargeState == .charging && dark ? stride(from: 0, to: 2.6, by: 0.1).map { $0 } : [0.7]
            var images: [CGImage] = []
            for t in frames {
                effects.forEach { $0.pose(at: t) }
                findViews(ChargingGlowView.self, in: host).forEach { glow in
                    glow.glow.removeAllAnimations()
                    glow.glow.shadowOpacity = Float(0.25 + 0.5 * (1 - cos(t / 1.2 * .pi)) / 2)
                }
                CATransaction.flush()
                guard let layer = host.layer, let context = CGContext(data: nil, width: Int(size.width * 3), height: Int(size.height * 3), bitsPerComponent: 8,
                                                                       bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                                                       bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { continue }
                context.translateBy(x: 0, y: size.height * 3)  // the hosting view is flipped
                context.scaleBy(x: 3, y: -3)
                layer.render(in: context)
                if let image = context.makeImage() { images.append(image) }
            }
            widget.stop()
            guard rendering, let first = images.first else { continue }
            try NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])?
                .write(to: folder.appending(path: "battery-\(name)-\(mode).png"))
            if images.count > 1 {
                for (index, image) in images.enumerated() where index % 6 == 0 {
                    try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?.write(to: folder.appending(path: "frame-\(index).png"))
                }
                let url = folder.appending(path: "charging.gif") as CFURL
                guard let gif = CGImageDestinationCreateWithURL(url, UTType.gif.identifier as CFString, images.count, nil) else { continue }
                CGImageDestinationSetProperties(gif, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFLoopCount: 0]] as CFDictionary)
                for image in images {
                    CGImageDestinationAddImage(gif, image, [kCGImagePropertyGIFDictionary: [kCGImagePropertyGIFDelayTime: 0.1]] as CFDictionary)
                }
                #expect(CGImageDestinationFinalize(gif))
            }
        }
    }
}
