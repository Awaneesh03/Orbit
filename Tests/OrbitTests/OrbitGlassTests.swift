import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Orbit Glass: tokens, hover and motion rules, and pixel checks of the real
// components rendered with ImageRenderer (card corners, top highlight, meter
// fill, every widget state).

@MainActor
private func card(_ id: String = "test") -> some View {
    OrbitGlassCard(id: id, title: "Weather", symbol: "cloud.sun", badge: "SAMPLE") { Color.clear }
}

// MARK: Tokens and rules

@Test func tokensMatchTheApprovedDesign() {
    #expect(OrbitGlass.cardRadius == 18)
    #expect(Theme.cardRadius == 18)
    #expect(OrbitGlass.innerRadius == 12)
    #expect(Theme.accent == Color(red: 0.56, green: 0.62, blue: 1.0))  // Orbit's indigo, unchanged
}

@Test func reducedMotionMeansNoAnimation() {
    #expect(OrbitMotion.animation(.orbitSpring, reduced: true) == nil)
    #expect(OrbitMotion.animation(.orbitSpring, reduced: false) == .orbitSpring)
    #expect(DashboardView.reducesMotion(preference: false, system: false) == false)
    #expect(DashboardView.reducesMotion(preference: true, system: false))   // Orbit's setting
    #expect(DashboardView.reducesMotion(preference: false, system: true))   // macOS Reduce motion
}

@MainActor @Test func hoverTracksOneCardAtATime() {
    let hover = OrbitHover()
    hover.pointer(inside: true, card: "a")
    #expect(hover.card == "a")
    hover.pointer(inside: true, card: "b")   // moved straight into the next card
    hover.pointer(inside: false, card: "a")  // a's late exit must not clear b
    #expect(hover.card == "b")
    hover.pointer(inside: false, card: "b")
    #expect(hover.card == nil)
}

// MARK: Rendering

@MainActor @Test func cardRendersAtCompactAndExpandedSizesWithRoundedCornersAndATopHighlight() throws {
    for size in [CGSize(width: 229, height: 160), CGSize(width: 468, height: 160)] {
        let image = try #require(render(card(), size: size))
        #expect(image.width == Int(size.width) && image.height == Int(size.height))
        let rim = image.brightness(image.width / 2, 0)
        let body = image.brightness(image.width / 2, image.height - 30)
        #expect(rim > body + 15, "the top highlight must be clearly brighter (\(rim) vs \(body))")
        #expect(image.brightness(1, 1) < 8, "the 18 pt corner must be cut away")
        #expect(body < 40, "the card must stay dark glass, not a bright slab (\(body))")
    }
}

@MainActor @Test func cardLooksTheSameInLightAndDarkSettings() throws {
    // The dashboard is dark by design; Settings › Appearance styles Orbit's windows.
    let size = CGSize(width: 229, height: 160)
    let dark = try #require(render(card(), size: size, scheme: .dark))
    let light = try #require(render(card(), size: size, scheme: .light))
    // Same rim, body and corners; allow for antialiasing noise in text and symbols.
    for (x, y) in [(dark.width / 2, 0), (dark.width / 2, dark.height - 30), (1, 1), (dark.width - 2, dark.height - 2)] {
        #expect(abs(dark.brightness(x, y) - light.brightness(x, y)) < 2, "(\(x), \(y))")
    }
    let differing = zip(dark.pixels, light.pixels).filter { abs(Int($0) - Int($1)) > 24 }.count
    #expect(differing < dark.pixels.count / 200, "\(differing) channel values differ")
}

@MainActor @Test func hoveredCardIsSlightlyBrighterAndNotScaled() throws {
    let size = CGSize(width: 229, height: 160)
    let resting = try #require(render(card("hovered"), size: size))
    OrbitHover.shared.pointer(inside: true, card: "hovered")
    defer { OrbitHover.shared.pointer(inside: false, card: "hovered") }
    let lit = try #require(render(card("hovered"), size: size))
    #expect(lit.width == resting.width && lit.height == resting.height)  // no scaling
    #expect(lit.brightness(40, 20) > resting.brightness(40, 20))         // sheen near the upper left
    #expect(lit.brightness(1, 1) < 8)                                    // still within its corners
}

@MainActor @Test func meterShowsItsFractionAndNothingAtZero() throws {
    let size = CGSize(width: 200, height: 6)
    let empty = try #require(render(MeterBar(fraction: 0), size: size))
    let half = try #require(render(MeterBar(fraction: 0.5), size: size))
    #expect(half.brightness(50, 3) > empty.brightness(50, 3) + 40)         // filled part
    #expect(abs(half.brightness(160, 3) - empty.brightness(160, 3)) < 3)   // the rest is just track
}

@MainActor @Test func everyWidgetStateRendersInTheCard() throws {
    let size = CGSize(width: 229, height: 160)
    let widget = FakeWidget("state")
    var rendered: [(WidgetState, [UInt8])] = []
    for state in [WidgetState.loading, .ready, .empty("Nothing yet"), .failed("Couldn't read"), .unavailable("No battery")] {
        widget.state = state
        let image = try #require(render(WidgetHost(widget: widget, presentation: .compact), size: size))
        #expect(image.brightness(1, 1) < 8, "\(state): the glass card frames every state")
        rendered.append((state, image.pixels))
    }
    func pixels(_ state: WidgetState) -> [UInt8]? { rendered.first { $0.0 == state }?.1 }
    #expect(pixels(.loading) != pixels(.ready))  // the outline placeholder shows
    #expect(pixels(.failed("Couldn't read")) != pixels(.empty("Nothing yet")))
}
