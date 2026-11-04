import CoreGraphics
import Testing
@testable import Orbit

// Values measured on the MacBook Air M4 (1470×956, 33pt menu bar, 179pt notch).
private let screen = CGRect(x: 0, y: 0, width: 1470, height: 956)
private let visible = CGRect(x: 0, y: 85, width: 1470, height: 838)
private let left = CGRect(x: 0, y: 924, width: 645.5, height: 32)
private let right = CGRect(x: 824.5, y: 924, width: 645.5, height: 32)

@Test func triggerCoversCameraHousing() {
    let trigger = NotchGeometry.triggerRect(screen: screen, visible: visible, left: left, right: right)
    #expect(trigger == CGRect(x: 645.5, y: 924, width: 179, height: 32))
    #expect(trigger.maxY == screen.maxY)
}

@Test func triggerFallsBackToTopCentreWithoutNotch() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let below = CGRect(x: 0, y: 0, width: 1920, height: 1055)
    let trigger = NotchGeometry.triggerRect(screen: display, visible: below, left: nil, right: nil)
    #expect(trigger == CGRect(x: 860, y: 1055, width: 200, height: 25))
}

@Test func fallbackTriggerKeepsMinimumHeightWhenMenuBarAutoHides() {
    let display = CGRect(x: 0, y: 0, width: 1920, height: 1080)
    let trigger = NotchGeometry.triggerRect(screen: display, visible: display, left: nil, right: nil)
    #expect(trigger.height == NotchGeometry.fallbackTriggerMinHeight)
    #expect(trigger.maxY == display.maxY)
}

@Test func dashboardHangsFromTopCentredOnNotch() {
    let trigger = NotchGeometry.triggerRect(screen: screen, visible: visible, left: left, right: right)
    let dashboard = NotchGeometry.dashboardRect(trigger: trigger, screen: screen)
    #expect(dashboard.maxY == screen.maxY)
    #expect(dashboard.midX == trigger.midX)
    #expect(dashboard.size == NotchGeometry.dashboardSize)
    // Moving from the notch into the dashboard never leaves the window.
    #expect(dashboard.contains(trigger))
}

@Test func dropZoneSitsJustBelowTheNotchClearOfTheTopEdge() {
    let trigger = NotchGeometry.triggerRect(screen: screen, visible: visible, left: left, right: right)
    let zone = NotchGeometry.dropZone(trigger: trigger, screen: screen)
    #expect(zone == CGRect(x: 525, y: 844, width: 420, height: 80))  // 32–112 pt below the top
    #expect(zone.midX == trigger.midX)
    #expect(zone.maxY == screen.maxY - 32)          // never touches the top edge
    #expect(!zone.intersects(trigger))               // below the camera housing
    #expect(zone.contains(CGPoint(x: trigger.midX, y: screen.maxY - 50)))
    let dashboard = NotchGeometry.dashboardRect(trigger: trigger, screen: screen)
    #expect(dashboard.contains(zone))                // the opened dashboard covers it: drop right there
}

@Test func dashboardStaysOnScreenNearEdges() {
    let narrow = CGRect(x: 0, y: 0, width: 800, height: 600)
    let trigger = CGRect(x: 10, y: 576, width: 100, height: 24)
    let dashboard = NotchGeometry.dashboardRect(trigger: trigger, screen: narrow)
    #expect(dashboard.minX == narrow.minX)
    #expect(dashboard.maxX <= narrow.maxX)
}
