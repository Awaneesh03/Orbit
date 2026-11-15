import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 15: one contextual interface on any display. Deterministic display fixtures
// (no real screen is changed), the wings/pill decision, the pill's model and window,
// the slot priorities and Coucou. ORBIT_RENDER=1 writes docs/screenshots/m15-pill/*.png.

/// The MacBook Air 13" (M4) built-in display, as macOS reports it: notch between the two top areas.
private let airPrimary = DisplayProfile(frame: CGRect(x: 0, y: 0, width: 1470, height: 956), visible: CGRect(x: 0, y: 0, width: 1470, height: 923),
                                        left: CGRect(x: 0, y: 924, width: 645.5, height: 32), right: CGRect(x: 824.5, y: 924, width: 645.5, height: 32))
/// The Samsung LF27T35 (1920×1080, 1× scale), main display, 25 pt menu bar, no notch.
private let samsungPrimary = DisplayProfile(frame: CGRect(x: 0, y: 0, width: 1920, height: 1080), visible: CGRect(x: 0, y: 0, width: 1920, height: 1055), scale: 1)
/// A 27" 4K at "looks like 2560×1440" (2×), main display placed to the right of the laptop (non-zero origin).
private let fourKOffset = DisplayProfile(frame: CGRect(x: 1470, y: -200, width: 2560, height: 1440), visible: CGRect(x: 1470, y: -200, width: 2560, height: 1415))
/// A small 1280×800 display at 1× with the menu bar set to hide automatically (visible frame reaches the top).
private let autoHide = DisplayProfile(frame: CGRect(x: 0, y: 0, width: 1280, height: 800), visible: CGRect(x: 0, y: 0, width: 1280, height: 800), scale: 1)

@Test func notchesAreFoundOnlyWhereTheyAre() {
    #expect(airPrimary.hasNotch)
    #expect(!samsungPrimary.hasNotch && !fourKOffset.hasNotch && !autoHide.hasNotch)
    #expect(airPrimary.trigger == CGRect(x: 645.5, y: 924, width: 179, height: 32))  // the camera housing
    #expect(samsungPrimary.trigger.height == 25 && samsungPrimary.trigger.midX == 960)  // the menu bar's centre, no fake notch
}

@Test func thePresenterFollowsTheMainDisplayAndTheSettings() {
    func presenter(_ display: DisplayProfile, _ mode: StatusDisplay = .automatic, _ style: CompactStyle = .beside) -> StatusPresenter {
        StatusPresenter.choose(mode, compactStyle: style, hasNotch: display.hasNotch)
    }
    #expect(presenter(airPrimary) == .wings)  // notched main display, Beside the camera
    #expect(presenter(airPrimary, .automatic, .below) == .pill)  // "Below the notch": the pill hangs below it
    #expect(presenter(samsungPrimary) == .pill)  // no notch: never wings
    #expect(presenter(fourKOffset) == .pill && presenter(autoHide) == .pill)
    #expect(presenter(airPrimary, .pill) == .pill)  // "Floating pill on every display"
    #expect(presenter(samsungPrimary, .off) == .none && presenter(airPrimary, .off) == .none)
    // Plugging in the Samsung as main, closing the lid, unplugging it: wings → pill → pill → wings.
    let sequence = [airPrimary, samsungPrimary, samsungPrimary, airPrimary].map { presenter($0) }
    #expect(sequence == [.wings, .pill, .pill, .wings])
}

@MainActor @Test func thePillSitsBelowTheMenuBarOrNotchOnEveryDisplay() {
    for display in [airPrimary, samsungPrimary, fourKOffset, autoHide] {
        let compact = ContextPillGeometry.rect(CGSize(width: 220, height: ContextPillGeometry.height), display: display)
        let expanded = ContextPillGeometry.rect(ContextPillGeometry.expandedSize, display: display)
        for rect in [compact, expanded] {
            #expect(display.frame.contains(rect))  // on the display, wherever it is in the arrangement
            #expect(rect.maxY == display.trigger.minY - MusicIslandGeometry.gap)  // just below: never over the menu bar or notch
            #expect(abs(rect.midX - display.trigger.midX) < 0.5)  // centred on the notch, or the menu bar's centre
        }
    }
    let width = ContextPillGeometry.compactWidth(title: "Design review", detail: "in 4 min")
    #expect(width > ContextPillGeometry.minWidth && width < 260)
    #expect(ContextPillGeometry.compactWidth(title: String(repeating: "Quarterly planning ", count: 10), detail: "in 24 min") == ContextPillGeometry.maxWidth)
    #expect(ContextPillGeometry.compactWidth(title: "1:1", detail: "") == ContextPillGeometry.minWidth)
}

@MainActor @Test func thePillShowsDismissesAndEscalates() {
    let pill = ContextPill()
    let upcoming = MeetingCue(eventID: "m", title: "Standup", start: .now.addingTimeInterval(1200), phase: .upcoming)
    let soon = MeetingCue(eventID: "m", title: "Standup", start: .now.addingTimeInterval(240), phase: .soon)
    pill.show(.meeting(upcoming))
    #expect(pill.isShowing)
    pill.toggle()
    #expect(pill.isExpanded)
    pill.dismiss()
    #expect(pill.content == nil && !pill.isExpanded)
    pill.show(.meeting(upcoming))
    #expect(pill.content == nil)  // dismissed: stays away in that phase
    pill.show(.meeting(soon))
    #expect(pill.content == .meeting(soon))  // but comes back when it escalates
    pill.slotIsFree = false
    #expect(!pill.isShowing && pill.content != nil)  // waits while a HUD or the island has the slot
    pill.slotIsFree = true
    pill.toggle()
    pill.show(nil)
    #expect(!pill.isExpanded)  // nothing to show: collapsed too
}

@Test func thePillCarriesOnlyWhatsUrgentOrTimely() throws {
    let claude = try #require(AgentID("claude-code"))
    let cue = MeetingCue(eventID: "m", title: "Standup", start: .now, phase: .soon)
    func pill(_ tone: NotchCompanion.Tone?, _ meeting: MeetingCue?, owner: NotchCoordination.Owner = .orbit, dashboard: Bool = false) -> WingContent? {
        WingContent.pill(lead: tone.map { (agent: claude, tone: $0) }, meeting: meeting, dashboardOpen: dashboard, owner: owner)
    }
    #expect(pill(.attention, cue) == .agent(claude, .attention))
    #expect(pill(.failed, nil) == .agent(claude, .failed))
    #expect(pill(.working, cue) == .meeting(cue))  // work in progress never holds the pill
    #expect(pill(.working, nil) == nil && pill(.finished, nil) == nil)
    #expect(pill(.attention, cue, owner: .coucou) == nil)  // Coucou has the notch: Orbit stays out
    #expect(pill(.attention, cue, dashboard: true) == nil)
}

@Test func oneSlotOnePriorityOrder() {
    typealias Inputs = NotchCoordination.Inputs
    #expect(NotchCoordination.Surface.allCases == [.dashboard, .expandedMusic, .volumeHUD, .brightnessHUD, .compactMusic, .agentAlert, .eyeBreak,
                                                   .statusPill, .companion])
    #expect(NotchCoordination.holder(Inputs(statusPill: true, companion: true)) == .statusPill)  // the pill before the companion
    #expect(NotchCoordination.holder(Inputs(alert: true, statusPill: true)) == .agentAlert)  // a 4 s alert first, then the pill returns
    #expect(NotchCoordination.holder(Inputs(brightnessHUD: true, statusPill: true)) == .brightnessHUD)
    #expect(NotchCoordination.holder(Inputs(island: .compact, statusPill: true)) == .compactMusic)
    #expect(NotchCoordination.holder(Inputs(volumeHUD: true, eyeBreak: true)) == .volumeHUD)  // the eye break waits for a HUD now
    #expect(NotchCoordination.holder(Inputs(eyeBreak: true, statusPill: true)) == .eyeBreak)
    #expect(NotchCoordination.holder(Inputs(dashboardOpen: true, statusPill: true)) == .dashboard)
    // Coucou: nothing of Orbit's in the notch but the dashboard.
    #expect(NotchCoordination.holder(Inputs(owner: .coucou, eyeBreak: true, statusPill: true)) == nil)
    #expect(!NotchCoordination.permits(.statusPill, owner: .coucou) && !NotchCoordination.permits(.eyeBreak, owner: .coucou))
}

@MainActor @Test func thePillWindowFollowsTheDisplayAndNeverStealsFocus() {
    let pill = ContextPill()
    pill.slotIsFree = false  // keep it off this Mac's screen during the test
    let panel = ContextPillPanel(pill: pill) { _ in }
    #expect(!panel.canBecomeKey && !panel.canBecomeMain)
    #expect(panel.collectionBehavior.contains(.canJoinAllSpaces) && !panel.collectionBehavior.contains(.fullScreenAuxiliary))  // not over full screen
    #expect(panel.level == .statusBar)
    pill.show(.meeting(MeetingCue(eventID: "m", title: "Design review", start: .now.addingTimeInterval(240), phase: .soon)))
    for display in [airPrimary, samsungPrimary, fourKOffset, airPrimary] {  // switching main displays: no stale coordinates
        panel.reposition(display)
        let frame = panel.targetFrame
        #expect(frame.map(display.frame.contains) == true)
    }
    pill.toggle()
    #expect(panel.targetFrame?.size == ContextPillGeometry.expandedSize)
    panel.reposition(nil)  // no display at all (lid closed, nothing attached)
    #expect(panel.targetFrame == nil)
    pill.show(nil)
    #expect(panel.targetFrame == nil && !panel.isVisible)
}

@MainActor @Test func thePillIsAccessible() {
    let cue = MeetingCue(eventID: "m", title: "Design review", start: Date(timeIntervalSinceReferenceDate: 800_000_000), phase: .soon,
                         joinURL: URL(string: "https://meet.google.com/abc-defg-hij"))
    #expect(ContextPillView.label(.meeting(cue)).hasSuffix("join link available"))
    #expect(ContextPillView.subtitle(.meeting(cue), now: cue.start.addingTimeInterval(-240)).hasSuffix("in 4 min · Google Meet"))
}

@MainActor @Test func pillRenders() throws {
    let claude = try #require(AgentID("claude-code"))
    let now = Date.now
    let link = URL(string: "https://zoom.us/j/123456789")
    let cases: [(WingContent, Bool, String)] = [
        (.meeting(MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(24 * 60 - 1), phase: .upcoming)), false, "upcoming"),
        (.meeting(MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(4 * 60 - 1), phase: .soon, joinURL: link)), false, "soon"),
        (.meeting(MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(-60), phase: .started, joinURL: link)), false, "started"),
        (.agent(claude, .attention), false, "agent"),
        (.meeting(MeetingCue(eventID: "a", title: "Design review", start: now.addingTimeInterval(4 * 60 - 1), phase: .soon, joinURL: link)), true, "expanded"),
    ]
    for dark in [false, true] {
        for (contrast, suffix) in [(false, ""), (true, "-contrast")] where !(contrast && !dark) {
            for (content, expanded, name) in cases {
                let pill = ContextPill()
                pill.reduceMotion = true
                pill.show(content)
                if expanded { pill.toggle() }
                let text = ContextPillGeometry.text(content)
                let size = expanded ? ContextPillGeometry.expandedSize
                    : CGSize(width: ContextPillGeometry.compactWidth(title: text.title, detail: text.detail), height: ContextPillGeometry.height)
                let wallpaper = dark ? [Color(red: 0.10, green: 0.12, blue: 0.20), Color(red: 0.26, green: 0.18, blue: 0.30)]
                                     : [Color(red: 0.86, green: 0.90, blue: 0.97), Color(red: 0.98, green: 0.88, blue: 0.80)]
                let view = ZStack(alignment: .top) {
                    LinearGradient(colors: wallpaper, startPoint: .topLeading, endPoint: .bottomTrailing)
                    Rectangle().fill(dark ? Color.black.opacity(0.35) : Color.white.opacity(0.55)).frame(height: 25)  // an external display's menu bar
                    ContextPillView(pill: pill, perform: { _ in }, contrast: contrast)
                        .frame(width: size.width, height: size.height).padding(.top, 25 + MusicIslandGeometry.gap)
                }
                .frame(width: 440, height: expanded ? 140 : 70)
                // Drawn by AppKit in a real (never shown) window, as on screen: ImageRenderer dims app icons.
                let host = NSHostingView(rootView: view)
                let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 440, height: expanded ? 140 : 70), styleMask: .borderless,
                                      backing: .buffered, defer: false)
                window.contentView = host
                window.displayIfNeeded()
                CATransaction.flush()
                let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
                host.cacheDisplay(in: host.bounds, to: rep)
                guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { continue }
                let image = try #require(rep.cgImage)
                let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m15-pill").standardized
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])?
                    .write(to: folder.appending(path: "\(dark ? "dark" : "light")-\(name)\(suffix).png"))
            }
        }
    }
}
