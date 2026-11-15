import Foundation
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phase 6: the hook agents and OpenCode's event stream, with synthetic
// payloads shaped after each agent's documentation (UNVERIFIED against real
// sessions: that needs each agent's hooks installed, an approval gate).

private func run(_ adapter: HookAdapter, _ event: String, _ payload: [String: JSONValue]) -> [AgentEvent] {
    adapter.normalise(AgentEnvelope(agent: adapter.manifest.id.rawValue, event: event, sentAt: .now, payload: payload)!,
                      agent: adapter.manifest.id, receivedAt: .now)
}

@Test func codexToolCallsAndPatchesAreMapped() throws {
    let start = run(.codex, "SessionStart", ["session_id": .string("t1"), "cwd": .string("/Users/me/api"), "source": .string("startup")])
    #expect(start.map(\.kind) == [.sessionStarted] && start[0].session.description == "codex:t1" && start[0].cwd == "/Users/me/api")
    let patch = "*** Begin Patch\n*** Update File: src/a.ts\n@@\n-x\n+y\n*** Add File: src/b.ts\n+z\n*** End Patch"
    let edit = run(.codex, "PostToolUse", ["session_id": .string("t1"), "cwd": .string("/Users/me/api"), "tool_name": .string("apply_patch"),
                                           "tool_use_id": .string("c1"), "tool_input": .object(["command": .string(patch)])])
    #expect(edit.map(\.kind) == [.toolCompleted, .fileChanged])
    #expect(edit[1].files == ["/Users/me/api/src/a.ts", "/Users/me/api/src/b.ts"] && edit[0].summary == "apply_patch: *** Begin Patch")
    #expect(run(.codex, "PermissionRequest", ["session_id": .string("t1")]).map(\.kind) == [.waitingForUser])
    #expect(run(.codex, "Unknown", ["session_id": .string("t1")]).isEmpty && run(.codex, "Stop", [:]).isEmpty)
}

@Test func copilotOpensItsJSONStringArguments() throws {
    let events = run(.copilot, "postToolUse", ["sessionId": .string("c-9"), "cwd": .string("/Users/me/web"), "toolName": .string("edit"),
                                               "toolArgs": .string(#"{"path":"index.html","new_str":"<b>secret body</b>"}"#)])
    #expect(events.map(\.kind) == [.toolCompleted, .fileChanged] && events[1].files == ["/Users/me/web/index.html"])
    #expect(events[0].summary == "edit index.html" && !events.contains { $0.summary?.contains("secret body") == true })
    let bash = run(.copilot, "preToolUse", ["sessionId": .string("c-9"), "toolName": .string("bash"),
                                            "toolArgs": .string(#"{"command":"export API_KEY=abc123 && npm test"}"#)])
    #expect(bash.first?.summary == "bash: export API_KEY=[redacted] && npm test")
    #expect(run(.copilot, "errorOccurred", ["sessionId": .string("c-9"), "error": .string("boom")]).first?.summary == "Error: boom")
}

@Test func cursorGeminiAndAntigravityPayloadsAreMapped() throws {
    let cursor = run(.cursor, "afterFileEdit", ["conversation_id": .string("cv"), "generation_id": .string("g1"),
                                                "workspace_roots": .array([.string("/Users/me/app")]), "file_path": .string("/Users/me/app/x.swift")])
    #expect(cursor.map(\.kind) == [.fileChanged] && cursor[0].cwd == "/Users/me/app" && cursor[0].files == ["/Users/me/app/x.swift"])
    #expect(run(.cursor, "beforeShellExecution", ["conversation_id": .string("cv"), "command": .string("ls")]).first?.kind == .toolStarted)
    let gemini = run(.gemini, "AfterTool", ["session_id": .string("gm"), "cwd": .string("/Users/me/g"), "tool_name": .string("write_file"),
                                            "tool_input": .object(["file_path": .string("/Users/me/g/out.md")])])
    #expect(gemini.map(\.kind) == [.toolCompleted, .fileChanged])
    let antigravity = run(.antigravity, "PreToolUse", ["conversationId": .string("ag"), "workspacePaths": .array([.string("/Users/me/ag")]),
                                                       "toolCall": .object(["name": .string("run_command"), "args": .object(["command": .string("make")])])])
    #expect(antigravity.first?.tool == "run_command" && antigravity.first?.summary == "run_command: make" && antigravity.first?.cwd == "/Users/me/ag")
}

@Test func everyAdapterIsObserveOnlyUntilVerifiedAndKnowsItsOutputFormat() throws {
    for adapter in [HookAdapter.codex, .copilot, .cursor, .gemini, .antigravity] {
        #expect(adapter.manifest.capabilities == .observe, "\(adapter.manifest.id)")
        let draft = ApprovalDraft(session: SessionKey(agent: adapter.manifest.id, nativeID: "s")!, kind: .permission, nativeName: "x",
                                  tool: nil, summary: "s", options: [], createdAt: .now, expiresAt: .now + 10)
        #expect(adapter.output(for: .allowOnce, to: draft) != nil && adapter.output(for: .deny, to: draft) != nil)
        #expect(adapter.output(for: .answer("x"), to: draft) == nil)  // hooks have no question answers
    }
    #expect(HookAdapter.copilot.output(for: .allowOnce, to: ApprovalDraft(session: SessionKey(agent: AgentID("copilot-cli")!, nativeID: "s")!,
        kind: .permission, nativeName: "x", tool: nil, summary: "", options: [], createdAt: .now, expiresAt: .now)) == ["behavior": .string("allow")])
    let request = AgentEnvelope(kind: .request, agent: "copilot-cli", event: "permissionRequest", sentAt: .now, deadline: .now + 25,
                                payload: ["sessionId": .string("c"), "toolName": .string("bash"), "toolArgs": .string(#"{"command":"rm -rf build"}"#)])!
    let draft = try #require(HookAdapter.copilot.approval(from: request, agent: AgentID("copilot-cli")!, receivedAt: .now))
    #expect(draft.summary == "bash: rm -rf build" && draft.kind == .permission)
    let sneaky = AgentEnvelope(kind: .request, agent: "copilot-cli", event: "permissionRequest", sentAt: .now, deadline: .now + 25,
                               payload: ["sessionId": .string("c"), "toolName": .string("bash"),
                                         "toolArgs": .string(#"{"command":"ls\nrm -rf ~ && echo token=abc123"}"#)])!
    let shown = try #require(HookAdapter.copilot.approval(from: sneaky, agent: AgentID("copilot-cli")!, receivedAt: .now))
    #expect(shown.summary == "bash: ls" && shown.detail == "ls\nrm -rf ~ && echo token=[redacted]")  // every line is shown before approving
    let long = Redactor.block(String(repeating: "x", count: 2500))
    #expect(long?.hasSuffix("… (500 more characters not shown)") == true)
    #expect(AgentRegistry.standard.adapters.count == 7 && AgentRegistry.standard.adapter(for: AgentID("gemini-cli")!) != nil)
}

@Test func mappingsAreDeclarativeAndRoundTrip() throws {
    let data = try JSONEncoder().encode(HookAdapter.codex.mapping)
    #expect(try JSONDecoder().decode(HookAdapter.Mapping.self, from: data) == HookAdapter.codex.mapping)
    #expect(HookAdapter.value(["a": .object(["b": .array([.string("x"), .string("y")])])], "a.b[1]") == .string("y"))
    #expect(HookAdapter.value(["a": .array([])], "a[3]") == nil && HookAdapter.value([:], "missing.path") == nil)
}

@Test func openCodesEventStreamIsParsedAndMapped() throws {
    var parser = OpenCodeEvents.Parser()
    let first = parser.append("event: x\ndata: {\"type\":\"session.created\",\"properties\":{\"info\":{\"id\":\"oc1\",\"directory\":\"/Users/me/oc\"}}}\n\n: ping\n")
    let second = parser.append("data: {\"type\":\"permission.asked\",\"properties\":{\"sessionID\":\"oc1\",\"id\":\"p1\"}}\r\n\r\ndata: {\"type\":\"unknown\"}\n\n")
    try #require(first.count == 1 && second.count == 2)
    let created = OpenCodeEvents.events(from: first[0], receivedAt: .now)
    #expect(created.map(\.kind) == [.sessionStarted] && created[0].session.description == "opencode:oc1" && created[0].cwd == "/Users/me/oc")
    #expect(OpenCodeEvents.events(from: second[0], receivedAt: .now).map(\.kind) == [.waitingForUser])
    #expect(OpenCodeEvents.events(from: second[1], receivedAt: .now).isEmpty && OpenCodeEvents.events(from: "not json", receivedAt: .now).isEmpty)
}
