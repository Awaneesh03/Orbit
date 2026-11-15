import Darwin
import Foundation
import Synchronization
import Testing
import OrbitBridge

// AI Hub Phase 1, step 3: the hook helper's client. Real sockets and pipes in
// short temporary folders; nothing reaches Orbit's real socket.

/// A short folder for a socket (paths are limited to 103 bytes).
private func socketPath() -> (path: String, cleanup: () -> Void) {
    let folder = FileManager.default.temporaryDirectory.appending(path: "oa-\(UUID().uuidString.prefix(8))")
    return (folder.appending(path: "a.sock").path(percentEncoded: false), { try? FileManager.default.removeItem(at: folder) })
}

/// A descriptor to read `data` from, then end of file: a temporary file (a
/// pipe would block the writer past 64 KiB). `keepOpen`: a pipe that never ends.
private func input(_ data: Data, keepOpen: Bool = false) -> (fd: Int32, close: () -> Void) {
    if keepOpen {
        var fds: [Int32] = [0, 0]
        pipe(&fds)
        _ = data.withUnsafeBytes { write(fds[1], $0.baseAddress, data.count) }
        return (fds[0], { close(fds[0]); close(fds[1]) })
    }
    let file = FileManager.default.temporaryDirectory.appending(path: "in-\(UUID().uuidString).json")
    try? data.write(to: file)
    let fd = open(file.path(percentEncoded: false), O_RDONLY)
    return (fd, { close(fd); try? FileManager.default.removeItem(at: file) })
}

private func json(_ object: [String: Any]) -> Data { try! JSONSerialization.data(withJSONObject: object) }

/// Runs `send` while accepting on `path`; returns the outcome and every frame received before end of stream.
private func exchange(_ path: String, _ send: @escaping @Sendable () -> AgentHookClient.Outcome) throws
    -> (outcome: AgentHookClient.Outcome, frames: [Data]) {
    let listener = try UnixSocket.listen(at: path)
    defer { close(listener) }
    let result = Mutex<AgentHookClient.Outcome?>(nil)
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        let outcome = send()
        result.withLock { $0 = outcome }
        done.signal()
    }
    let fd = try #require(UnixSocket.accept(listener))
    defer { close(fd) }
    var decoder = FrameDecoder()
    var frames: [Data] = []
    while let chunk = UnixSocket.readChunk(fd) {  // until the client closes
        decoder.append(chunk)
        while let frame = try decoder.next() { frames.append(frame) }
    }
    done.wait()
    return (try #require(result.withLock { $0 }), frames)
}

private let origin = AgentEnvelope.Origin(bundleID: "com.apple.Terminal", termProgram: "Apple_Terminal", ppid: 4242)

// MARK: Sending

@Test func validInputBecomesExactlyOneFramedEnvelope() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let stdin = input(json(["session_id": "s1", "hook_event_name": "PostToolUse", "tool_input": ["command": "ls\npwd"]]))
    defer { stdin.close() }
    let fd = stdin.fd
    let (outcome, frames) = try exchange(path) {
        AgentHookClient.send(agent: "claude-code", event: "PostToolUse", input: fd, origin: origin, socketPath: path)
    }
    #expect(outcome == .sent && frames.count == 1)
    let envelope = try AgentEnvelope.decode(frames[0])
    #expect(envelope.agent == "claude-code" && envelope.event == "PostToolUse" && !envelope.truncated)
    #expect(envelope.payload["session_id"]?.stringValue == "s1")
    #expect(envelope.payload["tool_input"]?.objectValue?["command"]?.stringValue == "ls\npwd")
    #expect(envelope.origin == origin)
}

@Test func aLargeButReadablePayloadIsReducedToFitOneFrame() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let stdin = input(json(["session_id": "s1", "tool_response": ["content": String(repeating: "x", count: 200_000)]]))
    defer { stdin.close() }
    let fd = stdin.fd
    let (outcome, frames) = try exchange(path) {
        AgentHookClient.send(agent: "claude-code", event: "PostToolUse", input: fd, origin: origin, socketPath: path)
    }
    let envelope = try AgentEnvelope.decode(try #require(frames.first))
    #expect(outcome == .sent && frames.count == 1 && frames[0].count <= BridgeFraming.maxMessageBytes)
    #expect(envelope.reducedKeys == ["tool_response"] && envelope.payload["session_id"]?.stringValue == "s1")
}

@Test func unreadableInputIsSentWithItsPayloadWithheld() throws {
    for bad in [Data("{\"session_id\": ".utf8), Data("[1, 2]".utf8), Data(), Data("not json".utf8)] {
        let (path, cleanup) = socketPath()
        defer { cleanup() }
        let stdin = input(bad)
        defer { stdin.close() }
        let fd = stdin.fd
        let (outcome, frames) = try exchange(path) {
            AgentHookClient.send(agent: "codex", event: "Stop", input: fd, origin: origin, socketPath: path)
        }
        let envelope = try AgentEnvelope.decode(try #require(frames.first))
        #expect(outcome == .sent && envelope.payload.isEmpty && envelope.reducedKeys == [AgentEnvelope.wholePayload])
    }
}

@Test func anOversizedInputIsNotReadPastTheLimit() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let file = FileManager.default.temporaryDirectory.appending(path: "big-\(UUID().uuidString).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try Data(repeating: 0x20, count: AgentHookClient.maxInputBytes + 1).write(to: file)  // a file: poll is always ready
    let fd = open(file.path(percentEncoded: false), O_RDONLY)
    defer { close(fd) }
    let (outcome, frames) = try exchange(path) {
        AgentHookClient.send(agent: "codex", event: "Stop", input: fd, origin: origin, socketPath: path)
    }
    let envelope = try AgentEnvelope.decode(try #require(frames.first))
    #expect(outcome == .sent && envelope.reducedKeys == [AgentEnvelope.wholePayload])
}

@Test func stdinThatNeverEndsCantHoldTheAgent() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let stdin = input(Data("{\"a\":".utf8), keepOpen: true)
    defer { stdin.close() }
    let fd = stdin.fd
    let elapsed = Mutex<Duration>(.zero)
    let (outcome, frames) = try exchange(path) {
        let start = ContinuousClock.now  // the client's own time, not the test's scheduling under load
        let outcome = AgentHookClient.send(agent: "codex", event: "Stop", input: fd, origin: origin, socketPath: path, deadline: 0.1)
        elapsed.withLock { $0 = ContinuousClock.now - start }
        return outcome
    }
    #expect(elapsed.withLock { $0 } < .seconds(1))  // the 0.1 s deadline held (the default is 2 s)
    #expect(outcome == .sent)
    #expect(try AgentEnvelope.decode(try #require(frames.first)).reducedKeys == [AgentEnvelope.wholePayload])
}

// MARK: Orbit unavailable

@Test func withoutOrbitItGivesUpAtOnce() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let missing = input(json(["session_id": "s1"]))
    defer { missing.close() }
    var start = ContinuousClock.now
    #expect(AgentHookClient.send(agent: "codex", event: "Stop", input: missing.fd, origin: origin, socketPath: path) == .orbitUnavailable)
    #expect(ContinuousClock.now - start < .milliseconds(50))  // no socket at all

    close(try UnixSocket.listen(at: path))  // a stale socket file: nobody listening
    let stale = input(json(["session_id": "s1"]))
    defer { stale.close() }
    start = ContinuousClock.now
    #expect(AgentHookClient.send(agent: "codex", event: "Stop", input: stale.fd, origin: origin, socketPath: path) == .orbitUnavailable)
    #expect(ContinuousClock.now - start < .milliseconds(50))
}

// MARK: The helper's main

@Test func mainExitsZeroAndSilentWhateverHappensToTheEvent() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let stdin = input(json(["session_id": "s1", "token": "sk-ant-SECRET-42"]))
    defer { stdin.close() }
    var errors: [String] = []
    let status = AgentHookClient.main(
        arguments: ["--agent", "claude-code", "--event", "Stop"], input: stdin.fd, stdinIsTerminal: false,
        environment: ["__CFBundleIdentifier": "com.apple.Terminal"], parentPID: 99, socketPath: path,
        writeError: { errors.append($0) })
    #expect(status == 0 && errors.isEmpty)  // Orbit not running: nothing printed, exit 0
}

@Test func runByHandOrMisconfiguredItPrintsOnlyUsageAndExits64() {
    var errors: [String] = []
    func run(_ arguments: [String], terminal: Bool = false) -> Int32 {
        AgentHookClient.main(arguments: arguments, input: -1, stdinIsTerminal: terminal, environment: [:], parentPID: 1,
                             socketPath: "/nonexistent/a.sock", writeError: { errors.append($0) })
    }
    #expect(run(["--agent", "codex", "--event", "Stop"], terminal: true) == AgentHookClient.usageStatus)
    for bad in [[], ["--agent", "codex"], ["--agent", "Codex", "--event", "Stop"], ["--agent", "codex", "--event", "1x"],
                ["--agent", "codex", "--agent", "codex"], ["--agent", "codex", "--event", "Stop", "--extra"],
                ["--event", "Stop", "--secret", "sk-ant-SECRET"]] {
        #expect(run(bad) == AgentHookClient.usageStatus, "\(bad)")
    }
    #expect(errors.count == 8 && errors.allSatisfy { $0 == AgentHookClient.usage })  // usage only, never an argument echoed
}

@Test func argumentsMayComeInEitherOrder() throws {
    let (path, cleanup) = socketPath()
    defer { cleanup() }
    let stdin = input(json(["session_id": "s1"]))
    defer { stdin.close() }
    let fd = stdin.fd
    let (_, frames) = try exchange(path) {
        let status = AgentHookClient.main(arguments: ["--event", "SessionStart", "--agent", "copilot-cli"], input: fd,
                                          stdinIsTerminal: false, environment: ["TERM_PROGRAM": "vscode"], parentPID: 77,
                                          socketPath: path, writeError: { _ in })
        return status == 0 ? .sent : .invalidArguments
    }
    let envelope = try AgentEnvelope.decode(try #require(frames.first))
    #expect(envelope.agent == "copilot-cli" && envelope.event == "SessionStart")
    #expect(envelope.origin == AgentEnvelope.Origin(termProgram: "vscode", ppid: 77))
}
