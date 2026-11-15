import AppKit
import SwiftUI
import Testing
@testable import Orbit

// Milestone 16 screenshots, drawn by AppKit in a real (never shown) window, as on screen.
// ORBIT_RENDER=1 writes docs/screenshots/m16/*.png.

@MainActor private func capture(_ view: some View, size: CGSize, name: String) throws {
    let host = NSHostingView(rootView: view.frame(width: size.width, height: size.height))
    let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: .borderless, backing: .buffered, defer: false)
    window.contentView = host
    window.displayIfNeeded()
    CATransaction.flush()
    let rep = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
    host.cacheDisplay(in: host.bounds, to: rep)
    guard ProcessInfo.processInfo.environment["ORBIT_RENDER"] == "1" else { return }
    let folder = URL(filePath: #filePath).deletingLastPathComponent().appending(path: "../../docs/screenshots/m16").standardized
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try rep.representation(using: .png, properties: [:])?.write(to: folder.appending(path: "\(name).png"))
}

private struct Card<Content: View>: View {
    let content: Content
    var body: some View {
        content.padding(14).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Color(red: 0.13, green: 0.14, blue: 0.19), in: .rect(cornerRadius: 18))
            .padding(10)
            .background(LinearGradient(colors: [Color(red: 0.22, green: 0.26, blue: 0.40), Color(red: 0.40, green: 0.30, blue: 0.36)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing))
            .environment(\.colorScheme, .dark)
    }
}

/// Steady draws (Safari 1.8 W, Music 0.5 W, Terminal 0.3 W) over real elapsed time.
private final class StaticReader: ProcessReading, @unchecked Sendable {
    private let start = Date()
    func samples() -> [ProcessSample] {
        let elapsed = Date().timeIntervalSince(start)
        return [("/Applications/Safari.app", 1.8, 0.25), ("/System/Applications/Music.app", 0.5, 0.08),
                ("/System/Applications/Utilities/Terminal.app", 0.3, 0.05)].enumerated().map { index, entry in
            ProcessSample(pid: pid_t(100 + index), ppid: 1, path: entry.0 + "/Contents/MacOS/x", energyNJ: UInt64(entry.1 * elapsed * 1e9),
                          cpuNs: UInt64(entry.2 * elapsed * 1e9), wakeups: UInt64(elapsed * 40))
        }
    }
}

@MainActor @Test func batteryWidgetRenders() async throws {
    let energy = EnergyMonitor(reader: StaticReader(), interval: .milliseconds(30))
    energy.start(client: "render")
    for _ in 0 ..< 100 { if case .ready = energy.state { break }; try await Task.sleep(for: .milliseconds(10)) }
    let states: [(BatteryStatus, String)] = [
        (BatteryStatus(percent: 64, isCharging: false, isPluggedIn: false), "on-battery"),
        (BatteryStatus(percent: 47, isCharging: true, isPluggedIn: true), "charging"),
        (BatteryStatus(percent: 80, isCharging: false, isPluggedIn: true), "plugged-not-charging"),
        (BatteryStatus(percent: 100, isCharging: false, isPluggedIn: true, isCharged: true), "charged"),
        (BatteryStatus(percent: 12, isCharging: false, isPluggedIn: false), "low"),
    ]
    for (status, name) in states {
        let widget = BatteryWidget(read: { status }, energy: energy)
        widget.refresh()
        try capture(Card(content: widget.content(.compact)), size: CGSize(width: 300, height: 200), name: "battery-\(name)")
    }
    let expanded = BatteryWidget(read: { states[1].0 }, energy: energy)
    expanded.refresh()
    try capture(Card(content: expanded.content(.expanded)), size: CGSize(width: 440, height: 300), name: "battery-expanded")
    energy.stop(client: "render")
}

@MainActor @Test func brightnessWidgetRenders() throws {
    let displays = [DisplayBrightness(id: 1, name: "Built-in Retina Display", isBuiltIn: true, level: 0.62),
                    DisplayBrightness(id: 2, name: "LF27T35", isBuiltIn: false, level: nil)]
    try capture(Card(content: BrightnessList(displays: displays, compact: false)), size: CGSize(width: 380, height: 180), name: "brightness")
    for (level, band) in [(0.12, "low"), (0.5, "medium"), (0.93, "high")] {
        try capture(Card(content: BrightnessList(displays: [DisplayBrightness(id: 1, name: "Built-in Retina Display", isBuiltIn: true, level: level)],
                                                 compact: true)), size: CGSize(width: 300, height: 90), name: "brightness-\(band)")
    }
}

@MainActor @Test func launcherRenders() throws {
    let apps = [LauncherItem(id: "app:/Applications/Safari.app", kind: .app, title: "Safari", subtitle: "/Applications", path: "/Applications/Safari.app"),
                LauncherItem(id: "app:/System/Applications/Calendar.app", kind: .app, title: "Calendar", subtitle: "/System/Applications",
                             path: "/System/Applications/Calendar.app")]
    let model = LauncherModel(file: nil, files: nil, apps: apps)
    model.sources = {
        [LauncherItem(id: "project:/p/Orbit", kind: .project, title: "Orbit", subtitle: "Git repository · ~/Developer/Orbit", path: "/p/Orbit"),
         LauncherItem(id: "agent:claude-code:1", kind: .agent, title: "Orbit", subtitle: "Claude Code · running · Orbit"),
         LauncherItem(id: "task:1", kind: .task, title: "Write the Orbit report", subtitle: "Task · due Nov 16"),
         LauncherItem(id: "setting:launcher", kind: .setting, title: "Launcher Settings", subtitle: "Orbit Settings"),
         LauncherItem(id: "workspace:1", kind: .workspace, title: "Development", subtitle: "Active workspace · Return opens its apps and projects")]
    }
    model.query = "or"
    try capture(LauncherView(model: model, run: { _, _ in }, close: {}).padding(20)
                    .background(LinearGradient(colors: [Color(red: 0.86, green: 0.90, blue: 0.97), Color(red: 0.98, green: 0.88, blue: 0.80)],
                                               startPoint: .topLeading, endPoint: .bottomTrailing)),
                size: CGSize(width: LauncherPanel.size.width + 40, height: LauncherPanel.size.height + 40), name: "launcher")
}
