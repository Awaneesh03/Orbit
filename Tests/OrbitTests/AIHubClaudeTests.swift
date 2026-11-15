import Foundation
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phase 2: Claude Code, observe-only (D1). Synthetic payloads shaped
// after the documented hooks (real-session verification is pending); the
// installer only ever touches temporary files here.

private let claude = AgentID("claude-code")!

private func normalise(_ event: String, _ payload: [String: JSONValue]) -> [AgentEvent] {
    var full: [String: JSONValue] = ["session_id": .string("abc"), "cwd": .string("/Users/me/Orbit"), "hook_event_name": .string(event)]
    full.merge(payload) { $1 }
    return ClaudeCodeAdapter().normalise(AgentEnvelope(agent: "claude-code", event: event, sentAt: .now, payload: full)!,
                                         agent: claude, receivedAt: .now)
}

@Test func claudeLifecycleEventsAreObserved() throws {
    #expect(normalise("SessionStart", ["source": .string("resume")]).map(\.summary) == ["Session started (resume)"])
    #expect(normalise("SessionEnd", ["reason": .string("logout")]).map(\.kind) == [.sessionEnded])
    let prompt = try #require(normalise("UserPromptSubmit", ["prompt": .string("my secret plan sk-ant-abcdefghijklmnop")]).first)
    #expect(prompt.kind == .promptSubmitted && prompt.summary == "Prompt submitted")  // the prompt's text isn't kept
    #expect(normalise("Stop", [:]).map(\.kind) == [.turnCompleted])
    #expect(normalise("StopFailure", ["error": .string("rate_limit")]).map(\.summary) == ["Turn failed: rate_limit"])
    #expect(normalise("SubagentStart", ["agent_type": .string("Explore")]).map(\.summary) == ["Subagent started (Explore)"])
    #expect(normalise("SomethingNew", [:]).map(\.kind) == [.notification])  // future events still show up
    #expect(ClaudeCodeAdapter().normalise(AgentEnvelope(agent: "claude-code", event: "Stop", sentAt: .now, payload: [:])!,
                                          agent: claude, receivedAt: .now).isEmpty)  // no session_id: not attributable
    #expect(normalise("Stop", [:]).first?.session.description == "claude-code:abc")
}

@Test func toolCallsAreSummarisedWithoutContentsAndSecrets() throws {
    let bash = try #require(normalise("PreToolUse", ["tool_name": .string("Bash"), "tool_use_id": .string("toolu_1"),
                                                     "tool_input": .object(["command": .string("curl -H 'Authorization: Bearer abc123' x\nrm -rf y")])]).first)
    #expect(bash.kind == .toolStarted && bash.tool == "Bash" && bash.summary == "Bash: curl -H 'Authorization: [redacted]' x")
    #expect(bash.dedupeKey == "claude-code:abc|PreToolUse|toolu_1")
    let edit = normalise("PostToolUse", ["tool_name": .string("Edit"), "tool_use_id": .string("toolu_2"),
                                         "tool_input": .object(["file_path": .string("Sources/App.swift"), "new_string": .string("secret body")]),
                                         "tool_response": .object(["filePath": .string("/Users/me/Orbit/Sources/App.swift")])])
    #expect(edit.map(\.kind) == [.toolCompleted, .fileChanged])
    #expect(edit[1].files == ["/Users/me/Orbit/Sources/App.swift"] && edit[1].summary == "Changed App.swift")
    #expect(!edit.contains { $0.summary?.contains("secret body") == true })
    #expect(Set(edit.map(\.dedupeKey)).count == 2)
    let read = normalise("PreToolUse", ["tool_name": .string("Read"), "tool_input": .object(["file_path": .string("/etc/../Users/me/a.txt")])])
    #expect(read.first?.files == ["/Users/me/a.txt"] && read.first?.summary == "Read a.txt")
    #expect(normalise("PostToolUseFailure", ["tool_name": .string("Bash")]).map(\.kind) == [.toolFailed])
}

@Test func waitingIsOnlyInferredAndNeverAnswered() throws {
    let asked = normalise("PreToolUse", ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("q1"),
                                         "tool_input": .object(["questions": .array([])])])
    #expect(asked.map(\.kind) == [.toolStarted, .waitingForUser])
    #expect(asked[1].summary?.contains("inferred") == true)
    let prompt = normalise("Notification", ["notification_type": .string("permission_prompt"), "message": .string("Claude needs permission")])
    #expect(prompt.map(\.kind) == [.waitingForUser] && prompt[0].summary?.contains("inferred") == true)
    #expect(normalise("Notification", ["notification_type": .string("auth_success"), "message": .string("Signed in")]).map(\.kind) == [.notification])
    #expect(ClaudeCodeAdapter().manifest.capabilities == .observe)  // D1: nothing else, ever, while NotchBuddy owns permissions
    #expect(!ClaudeCodeAdapter.observedEvents.contains("PermissionRequest"))
}

@MainActor @Test func aWaitingSessionResumesWhenTheAgentMovesOn() throws {
    let manager = AgentSessionManager(scheduler: FakeScheduler())
    manager.apply(normalise("PreToolUse", ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("q1")]))
    let key = try #require(SessionKey(agent: claude, nativeID: "abc"))
    #expect(manager.sessions[key]?.status == .waiting && manager.sessions[key]?.title == "Orbit")
    manager.apply(normalise("PostToolUse", ["tool_name": .string("AskUserQuestion"), "tool_use_id": .string("q1")]))
    #expect(manager.sessions[key]?.status == .running)
}

// MARK: Installer (temporary files only)

/// Synthetic settings shaped like this Mac's: another tool's hooks on many events, including PermissionRequest.
private let existing = Data("""
{"model":"opus","permissions":{"allow":["Bash(ls:*)"]},"enabledPlugins":{"x@y":true},
 "hooks":{
  "PermissionRequest":[{"hooks":[{"type":"command","command":"/Users/me/Library/Application Support/OtherApp/hook","timeout":120}]}],
  "PreToolUse":[{"hooks":[{"type":"command","command":"/Users/me/OtherApp/hook"}]},
                {"matcher":"AskUserQuestion","hooks":[{"type":"command","command":"/Users/me/OtherApp/ask"}]}],
  "Stop":[{"hooks":[{"type":"command","command":"/Users/me/OtherApp/hook"}]}]
 }}
""".utf8)

private let helper = "/Users/me/Library/Application Support/Orbit/AgentHook/OrbitAgentHook"
private func parsed(_ data: Data) throws -> NSDictionary { try #require(try JSONSerialization.jsonObject(with: data) as? NSDictionary) }

@Test func installingAddsObserveOnlyHooksAndKeepsEverythingElse() throws {
    let installed = try ClaudeHookInstaller.installing(into: existing, helper: helper)
    let root = try parsed(installed)
    let before = try parsed(existing)
    for key in ["model", "permissions", "enabledPlugins"] { #expect(root[key] as? NSObject == before[key] as? NSObject) }
    let hooks = try #require(root["hooks"] as? [String: [[String: Any]]])
    #expect((hooks["PermissionRequest"] as NSArray?) == (before.value(forKeyPath: "hooks.PermissionRequest") as? NSArray))  // untouched
    #expect(ClaudeHookInstaller.installedEvents(in: installed, helper: helper) == Set(ClaudeCodeAdapter.observedEvents))
    #expect(hooks["PreToolUse"]?.count == 3 && hooks["Stop"]?.count == 2)  // the other tool's entries first, kept
    let orbit = try #require(hooks["Stop"]?.last?["hooks"] as? [[String: Any]])
    #expect(orbit.count == 1 && orbit[0]["type"] as? String == "command" && orbit[0]["timeout"] as? Int == 5)
    #expect(orbit[0]["command"] as? String == "\"\(helper)\" --agent claude-code --event Stop")
    #expect(try ClaudeHookInstaller.installing(into: installed, helper: helper) == installed)  // idempotent
    let removed = try ClaudeHookInstaller.removing(from: installed, helper: helper)
    #expect(try parsed(removed) == before)  // exactly the original structure back
    #expect(ClaudeHookInstaller.installedEvents(in: removed, helper: helper).isEmpty)
}

@Test func theInstallerRefusesFilesItCantUnderstand() throws {
    #expect(throws: ClaudeHookInstaller.Failure.self) { try ClaudeHookInstaller.installing(into: Data("{not json".utf8), helper: helper) }
    #expect(throws: ClaudeHookInstaller.Failure.self) { try ClaudeHookInstaller.installing(into: Data("[1]".utf8), helper: helper) }
    #expect(throws: ClaudeHookInstaller.Failure.self) { try ClaudeHookInstaller.installing(into: Data(#"{"hooks":[]}"#.utf8), helper: helper) }
    let fresh = try parsed(ClaudeHookInstaller.installing(into: nil, helper: helper))
    #expect((fresh["hooks"] as? [String: Any])?.count == ClaudeCodeAdapter.observedEvents.count)
}

@Test func applyingBacksUpFirstAndNeverOverwritesABackup() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let url = temp.url.appending(path: "settings.json")
    try existing.write(to: url)
    let time = Date(timeIntervalSince1970: 1_763_040_000)
    let first = try ClaudeHookInstaller.installing(into: existing, helper: helper)
    let backup1 = try #require(try ClaudeHookInstaller.apply(first, to: url, now: time))
    let backup2 = try #require(try ClaudeHookInstaller.apply(ClaudeHookInstaller.removing(from: first, helper: helper), to: url, now: time))
    #expect(backup1.lastPathComponent == "settings.json.orbit-backup-20251113-132000")
    #expect(backup2.lastPathComponent == "settings.json.orbit-backup-20251113-132000-1")
    #expect(try Data(contentsOf: backup1) == existing && Data(contentsOf: backup2) == first)
    #expect(try parsed(Data(contentsOf: url)) == parsed(existing))
}

@MainActor @Test func claudeEventsFlowIntoTheRealRegistryNotTheDemoOne() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = FileManager.default.temporaryDirectory.appending(path: "oc-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: folder) }
    let service = AIHubService(paths: .init(socket: folder.appending(path: "a.sock").path(percentEncoded: false),
                                            store: temp.url.appending(path: "hub.sqlite"), demoStore: temp.url.appending(path: "demo.sqlite")),
                               scheduler: FakeScheduler(), discover: { [] })
    service.set(enabled: true, demo: false)
    await service.settled()
    let envelope = AgentEnvelope(agent: "claude-code", event: "SessionStart", sentAt: .now,
                                 payload: ["session_id": .string("live"), "cwd": .string("/Users/me/Orbit"), "source": .string("startup")])!
    #expect(AgentHookClient.send(envelope, socketPath: service.paths.socket) == .sent)
    for _ in 0 ..< 300 where service.real.sessions.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
    #expect(service.real.sessions.keys.map(\.description) == ["claude-code:live"] && service.demo.sessions.isEmpty)
    #expect(service.health.lastEvent.keys.map(\.rawValue) == ["claude-code"])
    service.set(enabled: false, demo: false)
    await service.settled()
    let store = HubStore(url: service.paths.store)
    await store.open()
    #expect(await store.recentSessions().map(\.key.description) == ["claude-code:live"])
    await store.close()
}

@MainActor @Test func theServiceInstallsAndRemovesOnlyWhereItsTold() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let service = AIHubService(paths: .init(socket: "/nonexistent/a.sock", store: temp.url.appending(path: "h.sqlite"),
                                            demoStore: temp.url.appending(path: "d.sqlite")), scheduler: FakeScheduler(), discover: { [] })
    service.claudeSettingsURL = temp.url.appending(path: "claude/settings.json")
    service.claudeHelperPath = temp.url.appending(path: "Orbit/AgentHook/OrbitAgentHook").path(percentEncoded: false)
    try FileManager.default.createDirectory(at: temp.url.appending(path: "claude"), withIntermediateDirectories: true)
    try existing.write(to: service.claudeSettingsURL)
    let source = temp.url.appending(path: "helper")
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: source)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: source.path(percentEncoded: false))
    #expect(service.claudeHookPreview().contains("Adds 12 observe-only hooks") && service.claudeHookPreview().contains("Keeps the 4 hook entries"))
    service.installClaudeHooks(helperSource: source)
    #expect(service.claudeHooks == Set(ClaudeCodeAdapter.observedEvents))
    #expect(FileManager.default.isExecutableFile(atPath: service.claudeHelperPath))
    #expect(service.claudeHookMessage?.hasPrefix("Installed. Backup: settings.json.orbit-backup-") == true)
    service.removeClaudeHooks()
    let restored = try parsed(Data(contentsOf: service.claudeSettingsURL))
    #expect(try service.claudeHooks.isEmpty && restored == parsed(existing))
    service.installClaudeHooks(helperSource: temp.url.appending(path: "missing"))  // no helper in this build: nothing written
    #expect(service.claudeHooks.isEmpty && service.claudeHookMessage == "Orbit's hook helper isn't in this build of Orbit")
}


@Test func aSymlinkedSettingsFileKeepsItsLinkAndGetsARealBackup() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let dotfile = temp.url.appending(path: "dotfiles/claude-settings.json")
    try FileManager.default.createDirectory(at: dotfile.deletingLastPathComponent(), withIntermediateDirectories: true)
    try existing.write(to: dotfile)
    let link = temp.url.appending(path: "settings.json")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: dotfile)
    let backup = try #require(try ClaudeHookInstaller.apply(ClaudeHookInstaller.installing(into: existing, helper: helper), to: link))
    #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link.path(percentEncoded: false)) == dotfile.path(percentEncoded: false))
    #expect(try Data(contentsOf: backup) == existing)  // a real copy, not a link to the live file
    #expect(ClaudeHookInstaller.installedEvents(in: try Data(contentsOf: dotfile), helper: helper).count == 12)
}
