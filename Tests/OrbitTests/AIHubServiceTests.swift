import Foundation
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phase 1, steps 7–8: the service end to end (real socket, real
// SQLite, simulated agents driven by a fake scheduler), in throwaway folders.

@MainActor
private final class Hub {
    let temp = TemporaryDirectory()
    let folder = FileManager.default.temporaryDirectory.appending(path: "os-\(UUID().uuidString.prefix(8))")
    let scheduler = FakeScheduler()
    let service: AIHubService
    var demoAgents: DemoAgents?

    init(storeFolder: URL? = nil) {
        let paths = AIHubService.Paths(socket: folder.appending(path: "a.sock").path(percentEncoded: false),
                                       store: (storeFolder ?? temp.url.appending(path: "AIHub")).appending(path: "hub.sqlite"),
                                       demoStore: temp.url.appending(path: "AIHub/demo.sqlite"))
        var made: DemoAgents?
        let scheduler = scheduler
        service = AIHubService(paths: paths, scheduler: scheduler,
                               discover: { [AgentDiscovery.Found(id: "codex", name: "OpenAI Codex", path: "/opt/homebrew/bin/codex")] },
                               makeDemoAgents: { path in
                                   let agents = DemoAgents(socketPath: path, scheduler: scheduler, interval: .seconds(1))
                                   made = agents
                                   return agents
                               })
        demoAgentsSource = { made }
    }

    private var demoAgentsSource: () -> DemoAgents? = { nil }
    var demo: DemoAgents? { demoAgentsSource() }
    var socket: String { service.paths.socket }
    var storeFile: String { service.paths.store.path(percentEncoded: false) }
    var demoFile: String { service.paths.demoStore.path(percentEncoded: false) }

    func set(_ enabled: Bool, demo: Bool = false) async {
        service.set(enabled: enabled, demo: demo)
        await service.settled()
    }

    func close() async {
        await set(false)
        service.shutdown()
        temp.cleanup()
        try? FileManager.default.removeItem(at: folder)
    }
}

/// Lets socket deliveries reach the main actor (real time, 3 s at most).
@MainActor
private func eventually(_ condition: () -> Bool) async -> Bool {
    for _ in 0 ..< 300 {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private func exists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }

@MainActor @Test func offByDefaultNothingExists() async {
    let hub = Hub()
    await hub.set(false)
    #expect(!hub.service.isEnabled && hub.service.health.bridge == .off)
    #expect(!exists(hub.socket) && !exists(hub.storeFile) && !exists(hub.demoFile))
    #expect(!hub.service.real.hasPendingTimer && hub.service.agents.isEmpty)
    await hub.close()
}

@MainActor @Test func onItListensSavesAndFindsAgentsAndOffItCleansUp() async throws {
    let hub = Hub()
    await hub.set(true)
    #expect(hub.service.isEnabled && hub.service.health.bridge == .listening && hub.service.health.store == .ok)
    #expect(exists(hub.socket) && exists(hub.storeFile) && !exists(hub.demoFile))
    #expect(try FileManager.default.attributesOfItem(atPath: hub.socket)[.posixPermissions] as? Int == 0o600)
    #expect(hub.service.agents.map(\.id) == ["codex"])
    for _ in 0 ..< 5 {  // rapid toggling, in order, settled each time or not
        hub.service.set(enabled: false, demo: false)
        hub.service.set(enabled: true, demo: false)
    }
    await hub.service.settled()
    #expect(hub.service.isEnabled && exists(hub.socket))
    #expect(AgentHookClient.send(AgentEnvelope(agent: "demo-x", event: "sessionStarted", sentAt: .now,
                                               payload: ["session_id": .string("s")])!, socketPath: hub.socket) == .sent)
    await hub.set(false)
    #expect(!exists(hub.socket) && hub.service.health.bridge == .off && hub.service.real.sessions.isEmpty)
    #expect(exists(hub.storeFile))  // history stays on disk
    await hub.close()
}

@MainActor @Test func demoModeRunsSimulatedSessionsApartFromRealOnes() async throws {
    let hub = Hub()
    await hub.set(true, demo: true)
    let demo = try #require(hub.demo)
    #expect(hub.service.isDemoEnabled && demo.isRunning && exists(hub.demoFile))
    for _ in 0 ..< 4 { hub.scheduler.advance(.seconds(1)) }  // four ticks: two agents each
    #expect(await eventually { hub.service.demo.recentEvents.values.map(\.count).reduce(0, +) == 8 })
    #expect(hub.service.demo.sessions.count == 2 && hub.service.demo.sessions.keys.allSatisfy(\.agent.isDemo))
    #expect(hub.service.demo.recentEvents.values.flatMap { $0 }.allSatisfy { $0.summary?.hasPrefix("Simulated") == true })
    #expect(hub.service.real.sessions.isEmpty && hub.service.health.lastEvent.isEmpty)  // never counted as a real agent's
    #expect(hub.service.demo.sessions.values.allSatisfy { $0.cwd?.hasPrefix("/Simulated/") == true })

    await hub.set(true, demo: false)
    #expect(!demo.isRunning && hub.service.demo.sessions.isEmpty && exists(hub.demoFile))  // off: out of view, kept on disk
    await hub.set(true, demo: true)
    #expect(hub.service.demo.sessions.count == 2)  // back from demo.sqlite

    await hub.service.clearDemoData()
    #expect(hub.service.demo.sessions.isEmpty && hub.service.isDemoEnabled && hub.service.isDemoRunning)
    let real = HubStore(url: hub.service.paths.store)
    #expect(await real.open() == .ok)
    let counts = await real.counts()
    #expect(counts.sessions == 0 && counts.events == 0)  // nothing simulated ever reached hub.sqlite
    await real.close()
    await hub.close()
}

@MainActor @Test func clearingDemoDataRemovesTheDemoStore() async {
    let hub = Hub()
    await hub.set(true, demo: true)
    hub.scheduler.advance(.seconds(1))
    #expect(await eventually { hub.service.demo.sessions.count == 2 })
    await hub.set(true, demo: false)
    await hub.service.clearDemoData()
    #expect(!exists(hub.demoFile) && hub.service.demo.sessions.isEmpty && !hub.service.isDemoEnabled)
    await hub.close()
}

@MainActor @Test func realSessionsComeBackAfterARelaunch() async throws {
    let hub = Hub()
    let store = HubStore(url: hub.service.paths.store)
    await store.open()
    let claude = try #require(AgentID("claude-code"))
    let key = try #require(SessionKey(agent: claude, nativeID: "s1"))
    await store.save(sessions: [AgentSession(key: key, title: "Orbit", cwd: "/Users/me/Orbit", model: nil, status: .ended,
                                             startedAt: .now, lastEventAt: .now, endedAt: .now)], events: [])
    await store.close()
    await hub.set(true)
    #expect(hub.service.real.sessions[key]?.title == "Orbit" && hub.service.demo.sessions.isEmpty)
    await hub.close()
}

@MainActor @Test func anUnavailableStoreLeavesTheHubRunningInMemory() async throws {
    let blocked = FileManager.default.temporaryDirectory.appending(path: "blocked-\(UUID().uuidString)")
    try Data("a file, not a folder".utf8).write(to: blocked)
    defer { try? FileManager.default.removeItem(at: blocked) }
    let hub = Hub(storeFolder: blocked.appending(path: "AIHub"))
    await hub.set(true, demo: true)
    guard case .degraded = hub.service.health.store else { Issue.record("expected degraded"); return }
    #expect(hub.service.health.isDegraded && hub.service.health.bridge == .listening)
    hub.scheduler.advance(.seconds(1))
    #expect(await eventually { hub.service.demo.sessions.count == 2 })  // still working, in memory
    await hub.close()
}

@MainActor @Test func aTakenSocketPathIsReportedNotFatal() async throws {
    let hub = Hub()
    try FileManager.default.createDirectory(at: hub.folder, withIntermediateDirectories: true)
    try Data("not a socket".utf8).write(to: URL(filePath: hub.socket))
    await hub.set(true)
    guard case .failed = hub.service.health.bridge else { Issue.record("expected failed"); return }
    #expect(hub.service.isEnabled && hub.service.health.isDegraded && hub.service.health.store == .ok)
    #expect(try Data(contentsOf: URL(filePath: hub.socket)) == Data("not a socket".utf8))  // left alone
    await hub.close()
}

@MainActor @Test func theDemoScriptIsLabelledAndUsesItsOwnNamespace() {
    let agents = DemoAgents(socketPath: "/nonexistent.sock", scheduler: FakeScheduler(), send: { _, _ in })
    let envelopes = (0 ..< 30).flatMap { agents.envelopes(at: $0) }
    #expect(envelopes.allSatisfy { $0.agent.hasPrefix(AgentID.demoPrefix) })
    #expect(envelopes.allSatisfy { $0.payload["summary"]?.stringValue?.hasPrefix("Simulated") == true })
    #expect(Set(envelopes.compactMap { $0.payload["session_id"]?.stringValue }).count >= 3)  // sessions end and new ones begin
    #expect(Set(envelopes.map(\.event)).isSubset(of: Set(AgentEvent.Kind.allCases.map(\.rawValue))))
}
