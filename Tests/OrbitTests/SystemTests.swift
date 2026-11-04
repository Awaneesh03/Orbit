import Foundation
import Testing
@testable import Orbit

@Test func cpuUsageIsBusyShareOfElapsedTicks() {
    let a = CPUTicks(busy: 100, total: 1000)
    #expect(SystemStats.cpuUsage(from: a, to: CPUTicks(busy: 150, total: 1200)) == 0.25)
    #expect(SystemStats.cpuUsage(from: a, to: a) == nil)  // no time passed
    #expect(SystemStats.cpuUsage(from: a, to: CPUTicks(busy: 90, total: 1100)) == nil)  // counter reset
}

@Test func memoryUsedMatchesActivityMonitorFormula() {
    let usage = SystemStats.memoryUsage(internalPages: 1000, purgeablePages: 200, wiredPages: 300,
                                        compressedPages: 100, pageSize: 16384, total: 1 << 34)
    #expect(usage.used == (800 + 300 + 100) * 16384)
    // Never negative and never more than physical memory.
    #expect(SystemStats.memoryUsage(internalPages: 1, purgeablePages: 5, wiredPages: 0,
                                    compressedPages: 0, pageSize: 4096, total: 100).used == 0)
    #expect(SystemStats.memoryUsage(internalPages: 999, purgeablePages: 0, wiredPages: 0,
                                    compressedPages: 0, pageSize: 4096, total: 100).used == 100)
}

@Test func liveReadersReturnPlausibleValues() throws {
    let ticks = try #require(SystemStats.cpuTicks())
    #expect(ticks.total >= ticks.busy)
    let memory = try #require(SystemStats.memory())
    #expect(memory.used > 0 && memory.used <= memory.total)
    #expect(memory.total == ProcessInfo.processInfo.physicalMemory)
    let storage = try #require(SystemStats.storage())
    #expect(storage.available > 0 && storage.available <= storage.total)
}

@MainActor @Test func systemWidgetSamplesOnlyWhileVisible() async throws {
    var busy: UInt64 = 0
    var total: UInt64 = 0
    let widget = SystemWidget(
        interval: .milliseconds(20),
        readTicks: {
            busy += 30
            total += 100
            return CPUTicks(busy: busy, total: total)
        },
        readMemory: { MemoryUsage(used: 4, total: 16) })
    #expect(widget.state == .loading)
    widget.start()
    #expect(widget.isSampling)
    #expect(widget.state == .ready)
    #expect(widget.cpu == nil)  // one sample isn't enough for a percentage
    // Wait for a second sample (the main actor can be busy with parallel tests).
    for _ in 0..<100 where widget.cpu == nil { try await Task.sleep(for: .milliseconds(20)) }
    #expect(widget.cpu == 0.3)
    #expect(widget.memory == MemoryUsage(used: 4, total: 16))

    widget.stop()
    #expect(!widget.isSampling)
    let ticksAfterStop = total
    try await Task.sleep(for: .milliseconds(100))
    #expect(total == ticksAfterStop)  // no sampling while hidden
}

@MainActor @Test func systemWidgetReportsUnavailableStats() {
    let widget = SystemWidget(readTicks: { nil }, readMemory: { nil })
    widget.start()
    defer { widget.stop() }
    #expect(widget.state == .unavailable("System statistics unavailable"))
}

@MainActor @Test func storageWidgetReadsOnStart() {
    let widget = StorageWidget(read: { StorageUsage(available: 50, total: 200) })
    #expect(widget.state == .loading)
    widget.start()
    #expect(widget.state == .ready)
    #expect(widget.usage == StorageUsage(available: 50, total: 200))
    let broken = StorageWidget(read: { nil })
    broken.start()
    #expect(broken.state == .unavailable("Disk information unavailable"))
}

@MainActor @Test func networkWidgetMonitorsOnlyWhileVisible() {
    let widget = NetworkWidget()
    #expect(widget.state == .loading)
    widget.start()
    #expect(widget.isMonitoring)
    widget.start()  // idempotent
    widget.stop()
    #expect(!widget.isMonitoring)
}

@Test func networkSummaryDescribesTheConnection() {
    let wifi = NetworkSummary(isOnline: true, link: .wifi, isExpensive: false, isLowData: false)
    #expect(wifi.title == "Online")
    #expect(wifi.detail == "Wi-Fi")
    #expect(wifi.symbol == "wifi")
    let hotspot = NetworkSummary(isOnline: true, link: .wifi, isExpensive: true, isLowData: true)
    #expect(hotspot.detail == "Wi-Fi · metered · Low Data Mode")
    let offline = NetworkSummary(isOnline: false, link: nil, isExpensive: false, isLowData: false)
    #expect(offline.title == "Offline")
    #expect(offline.detail == "No connection")
    #expect(offline.symbol == "wifi.slash")
}
