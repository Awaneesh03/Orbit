import Foundation
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phase 1, step 2: the agent envelope. Synthetic messages in memory;
// no socket, no helper.

private let now = Date(timeIntervalSince1970: 1_763_040_000)

private func envelope(agent: String = "demo-alpha", event: String = "PostToolUse",
                      origin: AgentEnvelope.Origin = .init(bundleID: "com.apple.Terminal", termProgram: "Apple_Terminal", ppid: 4242),
                      payload: [String: JSONValue] = ["session_id": .string("s1")]) throws -> AgentEnvelope {
    try #require(AgentEnvelope(agent: agent, event: event, sentAt: now.addingTimeInterval(-1), origin: origin, payload: payload))
}

/// A valid envelope's JSON object, changed by `change`, as bytes.
private func raw(_ change: (inout [String: Any]) -> Void) throws -> Data {
    var object = try #require(try JSONSerialization.jsonObject(with: envelope().encoded()) as? [String: Any])
    change(&object)
    return try JSONSerialization.data(withJSONObject: object)
}

private func rejects(_ data: Data, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation) {
    #expect(throws: AgentEnvelopeError(reason), sourceLocation: sourceLocation) { try AgentEnvelope.decode(data, now: now) }
}

// MARK: Valid messages

@Test func theAgentSocketIsBesideTheBraveSocketAndFitsAUnixPath() {
    #expect(UnixSocket.agentsPath.hasSuffix("/Library/Application Support/Orbit/Bridge/agents.sock"))
    #expect(UnixSocket.agentsPath != UnixSocket.defaultPath)
    #expect(UnixSocket.agentsPath.utf8.count < 104)  // sockaddr_un.sun_path
}

@Test func aValidEnvelopeRoundTripsThroughAFrame() throws {
    let original = try envelope(payload: [
        "session_id": .string("s1"), "cwd": .string("/Users/me/project"), "count": .number(3), "ok": .bool(true),
        "nothing": .null, "tool_input": .object(["command": .string("ls -la\nexit")]), "list": .array([.number(1), .string("x")]),
    ])
    var decoder = FrameDecoder()
    decoder.append(BridgeFraming.frame(original.encoded()))
    let decoded = try AgentEnvelope.decode(try #require(try decoder.next()), now: now)
    #expect(decoded == original && !decoded.truncated)
    #expect(decoded.origin == AgentEnvelope.Origin(bundleID: "com.apple.Terminal", termProgram: "Apple_Terminal", ppid: 4242))
    #expect(decoded.payload["tool_input"]?.objectValue?["command"]?.stringValue == "ls -la\nexit")  // payload text is data: newlines kept
}

@Test func agentIDsFollowOneRuleOnBothSides() {
    for value in ["claude-code", "demo-alpha", "x", "", "Claude", "a b", String(repeating: "a", count: 33)] {
        #expect((AgentID(value) != nil) == AgentEnvelope.isValidAgentID(value), "\(value)")
    }
}

// MARK: Malformed messages

@Test func onlyVersionOneHookEnvelopesAreAccepted() throws {
    rejects(try raw { $0["v"] = 2 }, "unsupported version")
    rejects(try raw { $0["v"] = "1" }, "unsupported version")
    rejects(try raw { $0["v"] = true }, "unsupported version")
    rejects(try raw { $0["v"] = nil }, "unsupported version")
    rejects(try raw { $0["type"] = "decision" }, "unsupported type")  // nothing asks Orbit for a decision
    rejects(try raw { $0["extra"] = 1 }, "unexpected or missing fields")
    rejects(try raw { $0["origin"] = nil }, "unexpected or missing fields")
    rejects(Data("[1]".utf8), "not a JSON object")
    rejects(Data("{\"v\":1".utf8), "not a JSON object")
    rejects(Data(), "not a JSON object")
}

@Test func agentAndEventNamesAreChecked() throws {
    for agent in ["", "Claude", "claude code", "../x", String(repeating: "a", count: 33)] {
        rejects(try raw { $0["agent"] = agent }, "invalid agent")
    }
    rejects(try raw { $0["agent"] = 7 }, "invalid agent")
    for event in ["", "1Start", "Post Tool", "a/b", "x\n", String(repeating: "E", count: 65)] {
        rejects(try raw { $0["event"] = event }, "invalid event")
    }
    #expect(AgentEnvelope.isValidEventName("session.idle") && AgentEnvelope.isValidEventName("Post_Tool2"))
    #expect(AgentEnvelope(agent: "Bad", event: "X", sentAt: now, payload: [:]) == nil)
}

@Test func timestampsMustBeWholeMillisecondsCloseToNow() throws {
    let millis = { (date: Date) in Int64(date.timeIntervalSince1970 * 1000) }
    rejects(try raw { $0["sentAt"] = millis(now.addingTimeInterval(-24 * 3600 - 1)) }, "sentAt out of range")
    rejects(try raw { $0["sentAt"] = millis(now.addingTimeInterval(5 * 60 + 1)) }, "sentAt out of range")
    rejects(try raw { $0["sentAt"] = 1.5 }, "invalid sentAt")
    rejects(try raw { $0["sentAt"] = "now" }, "invalid sentAt")
    rejects(try raw { $0["sentAt"] = false }, "invalid sentAt")
    #expect(try AgentEnvelope.decode(raw { $0["sentAt"] = millis(now.addingTimeInterval(4 * 60)) }, now: now).event == "PostToolUse")
}

@Test func originMetadataIsNeverTrusted() throws {
    let decoded = try AgentEnvelope.decode(raw {
        $0["origin"] = ["bundleID": "com.evil app\n", "termProgram": "line\nbreak", "ppid": -3]
    }, now: now)
    #expect(decoded.origin == AgentEnvelope.Origin())  // invalid fields dropped, the event kept
    for ppid: Any in [0, true, 1.5, 9_999_999_999] {
        #expect(try AgentEnvelope.decode(raw { $0["origin"] = ["ppid": ppid] }, now: now).origin.ppid == nil)
    }
    #expect(try AgentEnvelope.decode(raw { $0["origin"] = ["bundleID": 5, "termProgram": ["x"]] }, now: now).origin == .init())
    rejects(try raw { $0["origin"] = "Terminal" }, "invalid origin")
    let long = String(repeating: "a", count: 156)
    #expect(try AgentEnvelope.decode(raw { $0["origin"] = ["bundleID": long, "termProgram": String(repeating: "t", count: 65)] }, now: now).origin == .init())
}

@Test func payloadsMustBeBoundedObjects() throws {
    rejects(try raw { $0["payload"] = ["a", "b"] }, "invalid payload")
    rejects(try raw { $0["payload"] = "text" }, "invalid payload")
    var deep: Any = "leaf"
    for _ in 0 ..< 40 { deep = ["k": deep] }
    rejects(try raw { $0["payload"] = deep }, "invalid payload")
    rejects(try raw { $0["payload"] = ["many": Array(repeating: 0, count: 17_000)] }, "invalid payload")
    rejects(try raw { $0["payload"] = [String(repeating: "k", count: 257): 1] }, "invalid payload")
    rejects(try raw { $0["payload"] = ["": 1] }, "invalid payload")
}

@Test func truncationMustBeConsistent() throws {
    rejects(try raw { $0["truncated"] = true }, "invalid truncation")  // truncated, but nothing listed
    rejects(try raw { $0["reducedKeys"] = ["tool_input"] }, "invalid truncation")  // listed, but not marked
    rejects(try raw { $0["truncated"] = true; $0["reducedKeys"] = ["session_id"] }, "invalid truncation")  // listed and still present
    rejects(try raw { $0["truncated"] = true; $0["reducedKeys"] = ["a", "a"] }, "invalid truncation")
    rejects(try raw { $0["truncated"] = 1; $0["reducedKeys"] = ["a"] }, "invalid truncation")
    let marked = try AgentEnvelope.decode(raw { $0["truncated"] = true; $0["reducedKeys"] = ["tool_response"] }, now: now)
    #expect(marked.truncated && marked.reducedKeys == ["tool_response"])
}

@Test func errorsNeverEchoPayloadContents() throws {
    let secret = "sk-ant-SECRET-123"
    let bad = try raw { $0["payload"] = [String(repeating: "k", count: 300): secret]; $0["event"] = secret }
    do {
        _ = try AgentEnvelope.decode(bad, now: now)
        Issue.record("accepted")
    } catch {
        #expect(!error.description.contains(secret) && !error.description.contains("SECRET"))
    }
}

@Test func anOversizedFrameIsRefusedBeforeParsing() {
    rejects(Data(repeating: 0x20, count: BridgeFraming.maxMessageBytes + 1), "too large")
}

// MARK: Payload reduction

@Test func anOversizedPayloadDropsWholeBulkyValuesAndSaysWhich() throws {
    let big = String(repeating: "x", count: 90_000)
    let original = try envelope(payload: [
        "session_id": .string("s1"), "hook_event_name": .string("PostToolUse"), "cwd": .string("/Users/me/p"),
        "tool_name": .string("Write"), "tool_use_id": .string("toolu_1"),
        "tool_response": .object(["content": .string(big)]), "tool_input": .object(["file_path": .string("/Users/me/p/a.swift")]),
    ])
    let data = original.encoded()
    #expect(data.count <= BridgeFraming.maxMessageBytes)
    _ = BridgeFraming.frame(data)  // fits a frame (frame() would trap otherwise)
    let decoded = try AgentEnvelope.decode(data, now: now)
    #expect(decoded.truncated && decoded.reducedKeys == ["tool_response"])  // only what had to go, largest first
    for key in ["session_id", "hook_event_name", "cwd", "tool_name", "tool_use_id", "tool_input"] {
        #expect(decoded.payload[key] == original.payload[key], "\(key)")  // never altered, only whole values removed
    }
}

@Test func aPayloadThatFitsIsNeverReduced() throws {
    let long = String(repeating: "y", count: 20_000)  // over 1 KiB, but the envelope fits
    let original = try envelope(payload: ["session_id": .string("s1"), "last_assistant_message": .string(long)])
    let decoded = try AgentEnvelope.decode(original.encoded(), now: now)
    #expect(decoded == original && !decoded.truncated)
}

@Test func manySmallValuesAreListedUpToTheLimit() throws {
    var payload: [String: JSONValue] = [:]
    for index in 0 ..< 750 { payload["key\(index)"] = .string(String(repeating: "v", count: 80)) }  // ~69 KiB: a few dozen go
    let data = try envelope(payload: payload).encoded()
    #expect(data.count <= BridgeFraming.maxMessageBytes)
    let decoded = try AgentEnvelope.decode(data, now: now)
    #expect(decoded.truncated && decoded.reducedKeys.count <= AgentEnvelope.maxReducedKeys)
    #expect(decoded.payload.count + decoded.reducedKeys.count == 750 && decoded.reducedKeys != [AgentEnvelope.wholePayload])
    #expect(Set(decoded.reducedKeys).isDisjoint(with: decoded.payload.keys))
    for (key, value) in decoded.payload { #expect(value == payload[key]) }
}

@Test func pastTheLimitTheWholePayloadIsWithheldAndSaysSo() throws {
    var payload: [String: JSONValue] = [:]
    for index in 0 ..< 4000 { payload["key\(index)"] = .string(String(repeating: "v", count: 40)) }  // too many keys to list
    let data = try envelope(payload: payload).encoded()
    #expect(data.count <= BridgeFraming.maxMessageBytes)
    let decoded = try AgentEnvelope.decode(data, now: now)
    #expect(decoded.payload.isEmpty && decoded.reducedKeys == [AgentEnvelope.wholePayload] && decoded.event == "PostToolUse")
    // "*" means everything withheld only on its own, with nothing delivered.
    rejects(try raw { $0["truncated"] = true; $0["reducedKeys"] = ["*"] }, "invalid truncation")  // payload still has session_id
    rejects(try raw { $0["truncated"] = true; $0["reducedKeys"] = ["*", "x"]; $0["payload"] = [String: Any]() }, "invalid truncation")
    let tooMany = (0 ... AgentEnvelope.maxReducedKeys).map { "k\($0)" }
    rejects(try raw { $0["truncated"] = true; $0["reducedKeys"] = tooMany }, "invalid truncation")
}

// MARK: Paths

@Test func agentPathsAreSanitisedNotTrusted() {
    #expect(AgentEnvelope.sanitizedPath("/Users/me/project/./src/../main.swift") == "/Users/me/project/main.swift")
    #expect(AgentEnvelope.sanitizedPath("/../../etc/passwd") == "/etc/passwd")  // lexical only, can't climb above /
    #expect(AgentEnvelope.sanitizedPath("//Users//me/") == "/Users/me")
    #expect(AgentEnvelope.sanitizedPath("/") == "/")
    for invalid in [nil, "", "relative/path", "~/x", "/a\u{0}b", "/a\nb", "/" + String(repeating: "a", count: 1024)] {
        #expect(AgentEnvelope.sanitizedPath(invalid) == nil, "\(String(describing: invalid))")
    }
}

@Test func nonFiniteNumbersAreRefusedNotCrashedOn() throws {
    // -1e999 parses as -inf; JSONSerialization can't write it (and raises uncatchably).
    let text = String(decoding: try envelope().encoded(), as: UTF8.self)
        .replacingOccurrences(of: #""payload":{"session_id":"s1"}"#, with: #""payload":{"n":-1e999}"#)
    rejects(Data(text.utf8), "invalid payload")
    let envelope = try #require(AgentEnvelope(agent: "codex", event: "Stop", sentAt: now, payload: ["n": .number(-.infinity), "ok": .string("x")]))
    #expect(!envelope.encoded().isEmpty)  // built in code with infinity: encoded without raising (withheld)
}
