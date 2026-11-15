import CryptoKit
import Foundation
import Testing
@testable import Orbit
import OrbitBridge

// AI Hub Phases 8, 11, 12: integrations (credential-gated), the companion
// protocol (no transport, D2) and third-party adapter manifests.

@Test func integrationsAreListedHonestlyAndDeveloperFirst() {
    let all = IntegrationRegistry.all
    #expect(all.count == 11 && all.prefix(6).allSatisfy { $0.category == .developer })
    #expect(all.allSatisfy { $0.status == .waitingForCredentials })  // nothing pretends to be connected (D3)
    #expect(Set(all.map(\.id)) == ["github", "gitlab", "vercel", "linear", "jira", "n8n", "notion", "stripe", "slack", "discord", "telegram"])
}

// MARK: Companion (Phase 11)

@Test func companionMessagesAreSealedAndOpenedOnlyByThePairedDevice() throws {
    let mac = Curve25519.KeyAgreement.PrivateKey()
    let phone = Curve25519.KeyAgreement.PrivateKey()
    let onMac = try CompanionChannel(local: mac, peer: phone.publicKey)
    var onPhone = try CompanionChannel(local: phone, peer: mac.publicKey)
    let nonce = Data((0 ..< 32).map { _ in UInt8.random(in: 0 ... 255) })
    let commitment = CompanionChannel.commitment(phone.publicKey, nonce: nonce)  // sent before the Mac's key is seen
    #expect(CompanionChannel.verify(commitment, key: phone.publicKey, nonce: nonce))
    #expect(!CompanionChannel.verify(commitment, key: Curve25519.KeyAgreement.PrivateKey().publicKey, nonce: nonce))  // a swapped key fails
    #expect(!CompanionChannel.verify(commitment, key: phone.publicKey, nonce: Data(nonce.prefix(8))))
    #expect(CompanionChannel.pairingCode(mac.publicKey, phone.publicKey, nonce: nonce) == CompanionChannel.pairingCode(phone.publicKey, mac.publicKey, nonce: nonce))
    #expect(CompanionChannel.pairingCode(mac.publicKey, phone.publicKey, nonce: nonce).count == 6)
    let message = CompanionMessage(id: UUID(), sentAt: Date(timeIntervalSince1970: 1_763_040_000),
                                   body: .approvalRequest(id: UUID(), agent: "codex", summary: "Run tests", options: [], expiresAt: Date(timeIntervalSince1970: 1_763_040_060)))  // the wire keeps milliseconds
    let sealed = try onMac.seal(message, sequence: 1)
    #expect(!sealed.ct.contains("Run tests"))  // encrypted
    #expect(try onPhone.receive(sealed) == message)  // both sides derived the same key
    #expect(throws: CompanionError.replayed) { try onPhone.receive(sealed) }  // the same message again
    var flipped = Data(base64Encoded: try onMac.seal(message, sequence: 2).ct)!
    flipped[flipped.count - 1] ^= 0x01
    #expect(throws: CompanionError.tampered) { try onPhone.receive(SealedMessage(v: 1, kid: sealed.kid, n: 2, ct: flipped.base64EncodedString())) }
    #expect(throws: CompanionError.tampered) {  // a different sequence number than it was sealed with
        try onPhone.receive(SealedMessage(v: 1, kid: sealed.kid, n: 5, ct: try onMac.seal(message, sequence: 3).ct))
    }
    #expect(throws: CompanionError.revoked) { try onPhone.receive(try onMac.seal(message, sequence: 4), revoked: [onMac.localKeyID]) }
    let stranger = try CompanionChannel(local: Curve25519.KeyAgreement.PrivateKey(), peer: phone.publicKey)
    #expect(throws: CompanionError.unknownDevice) { try onPhone.receive(try stranger.seal(message, sequence: 9)) }
    #expect(throws: CompanionError.badVersion) { try onPhone.receive(SealedMessage(v: 2, kid: sealed.kid, n: 10, ct: sealed.ct)) }
}

// MARK: Manifests (Phase 12)

private let mapping = #"""
{"session":["sid"],"cwd":["dir"],"tool":["tool"],"toolInput":["args"],"toolUse":["call"],"files":["file"],
 "events":{"start":"sessionStarted","tool":"toolStarted","done":"turnCompleted"},"editEvents":[],"editTools":[],
 "permissionEvent":"tool","allowOutput":{"ok":true},"denyOutput":{"ok":false}}
"""#

@Test func manifestsLoadAsObserveOnlyAdaptersAndBadOnesAreSkipped() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = temp.url.appending(path: "Adapters")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    func write(_ name: String, _ json: String) throws { try json.write(to: folder.appending(path: name), atomically: true, encoding: .utf8) }
    try write("good.json", #"{"id":"my-agent","name":"My Agent","version":"1.0","mapping":\#(mapping)}"#)
    try write("builtin.json", #"{"id":"codex","name":"Fake Codex","version":"1","mapping":\#(mapping)}"#)
    try write("demo.json", #"{"id":"demo-x","name":"Fake","version":"1","mapping":\#(mapping)}"#)
    try write("dup.json", #"{"id":"my-agent","name":"Again","version":"2","mapping":\#(mapping)}"#)
    try write("future.json", #"{"id":"next-agent","name":"Next","version":"1","minOrbitSchema":2,"mapping":\#(mapping)}"#)
    try write("broken.json", "{not json")
    try Data(repeating: 0x20, count: AdapterManifest.maxBytes + 1).write(to: folder.appending(path: "huge.json"))
    try write("notes.txt", "ignored")
    let reserved = Set(AgentRegistry.standard.adapters.map(\.manifest.id.rawValue))
    let loaded = AdapterManifests.load(from: folder, reserved: reserved)
    #expect(Array(loaded.adapters.keys) == ["my-agent"])
    #expect(loaded.problems["builtin.json"] == "codex is already taken" && loaded.problems["demo.json"] == "Invalid agent ID")
    #expect(loaded.problems["future.json"] == "Needs a newer Orbit" && loaded.problems["broken.json"] == "Not a valid adapter manifest")
    #expect(loaded.problems["huge.json"] != nil && loaded.problems["notes.txt"] == nil && loaded.problems.count == 6)
    let adapter = AdapterManifests.adapter(try #require(loaded.adapters["my-agent"]))
    #expect(adapter.manifest.capabilities == .observe && adapter.mapping.permissionEvent == nil && adapter.mapping.allowOutput == nil)
    let events = adapter.normalise(AgentEnvelope(agent: "my-agent", event: "tool", sentAt: .now,
                                                 payload: ["sid": .string("s1"), "tool": .string("deploy"), "dir": .string("/Users/me/x")])!,
                                   agent: AgentID("my-agent")!, receivedAt: .now)
    #expect(events.map(\.kind) == [.toolStarted] && events[0].session.description == "my-agent:s1" && events[0].tool == "deploy")
    let request = AgentEnvelope(kind: .request, agent: "my-agent", event: "tool", sentAt: .now, deadline: .now + 10, payload: ["sid": .string("s1")])!
    #expect(adapter.approval(from: request, agent: AgentID("my-agent")!, receivedAt: .now) == nil)  // can't answer, ever
    let registry = AgentRegistry.standard.adding([try #require(loaded.adapters["my-agent"])])
    #expect(registry.adapter(for: AgentID("my-agent")!) != nil && registry.adapters.last?.manifest.id.rawValue == "demo-agent")
    #expect(registry.adapter(for: AgentID("codex")!)?.manifest.displayName == "OpenAI Codex")  // built-ins can't be replaced
    #expect(AdapterManifests.load(from: temp.url.appending(path: "missing"), reserved: reserved) == AdapterManifests.Loaded())
}


@Test func aSymlinkedManifestIsSkippedNotRead() throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let folder = temp.url.appending(path: "Adapters")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try FileManager.default.createSymbolicLink(atPath: folder.appending(path: "zero.json").path(percentEncoded: false), withDestinationPath: "/dev/zero")
    let loaded = AdapterManifests.load(from: folder, reserved: [])
    #expect(loaded.adapters.isEmpty && loaded.problems["zero.json"] == "Too large or unreadable")  // returns at once
}
