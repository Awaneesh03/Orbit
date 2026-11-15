import Foundation
import Testing
@testable import Orbit

// AI Hub Phase 1, step 1: the normalised models and the master switch.

private func agent(_ raw: String) throws -> AgentID { try #require(AgentID(raw)) }
private func key(_ raw: String, _ nativeID: String) throws -> SessionKey {
    try #require(SessionKey(agent: agent(raw), nativeID: nativeID))
}

// MARK: Agent IDs and session keys

@Test func agentIDsAcceptOnlyTheDocumentedCharacters() {
    for valid in ["claude-code", "codex", "a", "copilot-cli", "demo-alpha", String(repeating: "x", count: 32)] {
        #expect(AgentID(valid)?.rawValue == valid, "\(valid)")
    }
    for invalid in ["", "Claude", "claude code", "claude_code", "claude.code", "cläude", "../x", String(repeating: "x", count: 33)] {
        #expect(AgentID(invalid) == nil, "\(invalid)")
    }
}

@Test func theDemoPrefixMarksSimulatedAgentsOnly() throws {
    #expect(try #require(AgentID("demo-alpha")).isDemo)
    #expect(try !#require(AgentID("claude-code")).isDemo)
    #expect(try !#require(AgentID("demo")).isDemo)  // the prefix includes the dash
    #expect(try !#require(AgentID("codex-demo-")).isDemo)
}

@Test func sessionKeysRejectUnsafeNativeIDs() throws {
    let agent = try #require(AgentID("claude-code"))
    #expect(SessionKey(agent: agent, nativeID: "3f2a-91")?.description == "claude-code:3f2a-91")
    #expect(SessionKey(agent: agent, nativeID: String(repeating: "a", count: SessionKey.maxNativeIDLength)) != nil)
    for invalid in ["", "a\nb", "tab\there", "nul\u{0}", String(repeating: "a", count: SessionKey.maxNativeIDLength + 1)] {
        #expect(SessionKey(agent: agent, nativeID: invalid) == nil)
    }
}

@Test func idsAndKeysRoundTripAndRejectInvalidJSON() throws {
    let key = try key("demo-alpha", "abc-123")
    let data = try JSONEncoder().encode(key)
    #expect(String(decoding: data, as: UTF8.self).contains(#""agent":"demo-alpha""#))
    #expect(try JSONDecoder().decode(SessionKey.self, from: data) == key)
    #expect(try JSONDecoder().decode([AgentID].self, from: Data(#"["codex"]"#.utf8)) == [AgentID("codex")])
    #expect(throws: DecodingError.self) { try JSONDecoder().decode(AgentID.self, from: Data(#""Codex""#.utf8)) }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionKey.self, from: Data(#"{"agent":"codex","nativeID":""}"#.utf8))
    }
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SessionKey.self, from: Data(#"{"agent":"no way","nativeID":"x"}"#.utf8))
    }
}

// MARK: Events, sessions, capabilities

@Test func storedRawValuesNeverChange() {
    // These strings are written to the database (Step 4): renaming one would orphan history.
    #expect(AgentEvent.Kind.allCases.map(\.rawValue) == [
        "sessionStarted", "sessionEnded", "promptSubmitted", "turnCompleted",
        "toolStarted", "toolCompleted", "toolFailed", "fileChanged", "notification", "error", "waitingForUser",
    ])
    #expect(AgentSession.Status.allCases.map(\.rawValue) == ["running", "idle", "completed", "failed", "ended", "stale", "waiting"])
    #expect(AgentSession.Status.allCases.filter(\.isActive) == [.running, .idle, .waiting])
}

@Test func sessionsKnowWhetherTheyAreSimulated() throws {
    func session(_ agent: String) throws -> AgentSession {
        AgentSession(key: try key(agent, "s1"), status: .running, startedAt: .distantPast, lastEventAt: .distantPast)
    }
    #expect(try session("demo-alpha").isDemo)
    #expect(try !session("claude-code").isDemo)
    #expect(try session("codex").id.description == "codex:s1")
}

@Test func phaseOneAdvertisesObservationOnly() throws {
    // A capability exists only once a phase implements and verifies it (§4); D1 keeps Claude Code observe-only.
    let manifest = AgentManifest(id: try #require(AgentID("claude-code")), displayName: "Claude Code", capabilities: .observe)
    #expect(manifest.capabilities == [.observe])
    #expect(try JSONDecoder().decode(AgentCapabilities.self, from: JSONEncoder().encode(manifest.capabilities)) == .observe)
}

// MARK: Master switch

@Test func theAIHubIsOffByDefaultAndInOlderFiles() throws {
    #expect(!OrbitPreferences().aiHub)
    let older = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"hideDelay": 2, "orbitPet": true}"#.utf8))
    #expect(!older.aiHub && older.hideDelay == 2 && older.orbitPet)  // a file from before the AI Hub keeps everything else
    let invalid = try JSONDecoder().decode(OrbitPreferences.self, from: Data(#"{"aiHub": "yes", "volumeHUD": false}"#.utf8))
    #expect(!invalid.aiHub && !invalid.volumeHUD)  // an invalid value takes the default, valid neighbours stay
}

@MainActor @Test func theAIHubSwitchPersistsBesideOtherPreferences() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let file: JSONFile<OrbitPreferences> = temp.file("preferences.json")
    let model = PreferencesModel(file: file)
    model.update { $0.hideDelay = 2; $0.orbitPet = true }
    model.update { $0.aiHub = true }
    let reloaded = PreferencesModel(file: file)
    #expect(reloaded.value.aiHub && reloaded.value.hideDelay == 2 && reloaded.value.orbitPet)
    model.update { $0.aiHub = false }
    #expect(!PreferencesModel(file: file).value.aiHub)
}
