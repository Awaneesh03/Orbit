import AppKit
import Foundation
import Testing
@testable import Orbit

// Milestone 16: Apps Using Significant Energy and the battery's five states.

private func sample(_ pid: pid_t, _ path: String?, energy: UInt64, cpu: UInt64, ppid: pid_t = 1, wakeups: UInt64 = 0) -> ProcessSample {
    ProcessSample(pid: pid, ppid: ppid, path: path, energyNJ: energy, cpuNs: cpu, wakeups: wakeups)
}

private let brave = "/Applications/Brave Browser.app"
private let code = "/Applications/Visual Studio Code.app"

@Test func helpersCountForTheirAppAndToolsForTheAppThatStartedThem() {
    #expect(EnergyAttribution.appPath(brave + "/Contents/Frameworks/Brave Browser Framework.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/x") == brave)
    #expect(EnergyAttribution.appPath("/usr/bin/yes") == nil && EnergyAttribution.appPath(nil) == nil)
    let before = [sample(10, brave + "/Contents/MacOS/Brave Browser", energy: 0, cpu: 0),
                  sample(11, brave + "/Contents/Frameworks/x.framework/Helpers/Brave Browser Helper (Renderer).app/Contents/MacOS/r", energy: 0, cpu: 0),
                  sample(20, code + "/Contents/MacOS/Electron", energy: 0, cpu: 0),
                  sample(21, "/bin/zsh", energy: 0, cpu: 0, ppid: 20),
                  sample(22, "/opt/homebrew/bin/node", energy: 0, cpu: 0, ppid: 21),
                  sample(30, "/System/Library/CoreServices/launchservicesd", energy: 0, cpu: 0),
                  sample(40, "/Applications/Notes.app/Contents/MacOS/Notes", energy: 0, cpu: 0)]
    let after = [sample(10, brave + "/Contents/MacOS/Brave Browser", energy: 1_000_000_000, cpu: 1_000_000_000),  // 0.2 W
                 sample(11, before[1].path, energy: 9_000_000_000, cpu: 4_000_000_000),  // +1.8 W in its renderer
                 sample(20, code + "/Contents/MacOS/Electron", energy: 500_000_000, cpu: 0),
                 sample(21, "/bin/zsh", energy: 0, cpu: 0, ppid: 20),
                 sample(22, "/opt/homebrew/bin/node", energy: 4_000_000_000, cpu: 2_500_000_000, ppid: 21),  // a tool run from VS Code's terminal
                 sample(30, "/System/Library/CoreServices/launchservicesd", energy: 50_000_000_000, cpu: 0),  // a system daemon: not an app
                 sample(40, "/Applications/Notes.app/Contents/MacOS/Notes", energy: 100_000_000, cpu: 0),  // 0.02 W: not significant
                 sample(50, "/Applications/New.app/Contents/MacOS/New", energy: 90_000_000_000, cpu: 0)]  // appeared mid-interval: no rate yet
    let ranked = EnergyAttribution.rank(previous: before, current: after, interval: 5)
    #expect(ranked.measured)
    #expect(ranked.apps.map(\.name) == ["Brave Browser", "Visual Studio Code"])
    #expect(abs((ranked.apps[0].watts ?? 0) - 2.0) < 0.001 && ranked.apps[0].processes == 2 && ranked.apps[0].level == .high)
    #expect(abs((ranked.apps[1].watts ?? 0) - 0.9) < 0.001 && ranked.apps[1].level == .moderate && ranked.apps[1].processes == 3)
}

@Test func withoutEnergyCountersTheRankingSaysItsCPU() {
    let before = [sample(1, code + "/Contents/MacOS/Electron", energy: 0, cpu: 0)]
    let after = [sample(1, code + "/Contents/MacOS/Electron", energy: 0, cpu: 4_000_000_000)]  // 80% of a core, no energy reported
    let ranked = EnergyAttribution.rank(previous: before, current: after, interval: 5)
    #expect(!ranked.measured && ranked.apps.first?.watts == nil && ranked.apps.first?.level == .high)
    #expect(EnergyAttribution.rank(previous: after, current: before, interval: 5).apps.isEmpty)  // counters went backwards: a reused pid, skipped
    #expect(EnergyAttribution.rank(previous: before, current: after, interval: 0).apps.isEmpty)
}

@Test func thisMacsEnergyCountersAreReadableWithoutPrivileges() {
    let samples = LibprocReader().samples()
    let mine = samples.first { $0.pid == getpid() }
    #expect(samples.count > 20)  // this user's processes
    #expect(mine != nil && (mine?.cpuNs ?? 0) > 0)
    #expect(samples.contains { $0.energyNJ > 0 })  // Apple Silicon reports per-process energy
}

private final class FakeReader: ProcessReading, @unchecked Sendable {
    private let lock = NSLock()
    private var tick: UInt64 = 0
    func samples() -> [ProcessSample] {
        lock.lock(); defer { lock.unlock() }
        tick += 1
        return [ProcessSample(pid: 7, ppid: 1, path: brave + "/Contents/MacOS/Brave Browser", energyNJ: tick * 2_000_000_000, cpuNs: tick * 1_000_000_000, wakeups: tick)]
    }
}

@MainActor @Test func samplingRunsOnlyWhileSomethingShowsIt() async {
    let monitor = EnergyMonitor(reader: FakeReader(), interval: .milliseconds(40))
    #expect(monitor.state == .idle && !monitor.isRunning)
    monitor.start(client: "battery")
    monitor.start(client: "debug")
    #expect(monitor.state == .measuring)
    for _ in 0 ..< 100 { if case .ready = monitor.state { break }; try? await Task.sleep(for: .milliseconds(10)) }
    guard case .ready(let apps, let measured, _) = monitor.state else { Issue.record("no reading"); return }
    #expect(measured && apps.first?.name == "Brave Browser")
    monitor.stop(client: "battery")
    #expect(monitor.isRunning)  // another client still wants it
    monitor.stop(client: "debug")
    #expect(!monitor.isRunning)
    if case .ready = monitor.state {} else { Issue.record("the last reading should stay cached") }
}

@MainActor @Test func theFiveBatteryStates() {
    #expect(BatteryStatus(percent: 54, isCharging: false, isPluggedIn: false).chargeState == .onBattery)
    #expect(BatteryStatus(percent: 54, isCharging: true, isPluggedIn: true).chargeState == .charging)
    #expect(BatteryStatus(percent: 80, isCharging: false, isPluggedIn: true).chargeState == .pluggedInNotCharging)  // an 80% limit holding
    #expect(BatteryStatus(percent: 100, isCharging: false, isPluggedIn: true).chargeState == .charged)
    #expect(BatteryStatus(percent: 97, isCharging: false, isPluggedIn: true, isCharged: true).chargeState == .charged)
    #expect(BatteryWidget(read: { nil }).status == nil)  // the fifth: unavailable
    let parsed = BatteryStatus(description: ["Type": "InternalBattery", "Current Capacity": 100, "Max Capacity": 100, "Is Charging": false,
                                             "Power Source State": "AC Power", "Is Charged": true])
    #expect(parsed?.chargeState == .charged)
}

@MainActor @Test func theBatteryWidgetSamplesEnergyOnlyWhileShownAndWanted() {
    let monitor = EnergyMonitor(reader: FakeReader(), interval: .seconds(60))
    let widget = BatteryWidget(read: { BatteryStatus(percent: 60, isCharging: true, isPluggedIn: true) }, energy: monitor)
    #expect(!monitor.isRunning)
    widget.start()
    #expect(monitor.isRunning && widget.isShown)
    widget.showsEnergy = false  // Settings › General › Apps Using Significant Energy off
    #expect(!monitor.isRunning)
    widget.showsEnergy = true
    widget.stop()
    #expect(!monitor.isRunning && !widget.isShown)
    #expect(BatteryWidget(read: { nil }).metadata.presentations == [.compact, .expanded])
}

