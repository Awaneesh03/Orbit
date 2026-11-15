import Darwin
import Foundation

// The AI Hub hook helper's whole job (docs/AI_HUB_SPEC.md §6, §14): read one
// hook payload from stdin, wrap it in an AgentEnvelope, send it to Orbit's
// agents.sock as one frame, close, exit. One shot: no retries, no queue on
// disk, no reply awaited (non-blocking only; no decisions, D1). It never
// writes to stdout, and to stderr only its usage text: an agent may read
// either, and nothing here may look like hook output.

package enum AgentHookClient {
    package enum Outcome: Equatable, Sendable {
        /// One frame written and the connection closed.
        case sent
        /// No socket, nobody listening, or not ours: Orbit isn't running its AI Hub.
        case orbitUnavailable
        /// Orbit was there but the frame couldn't be written in time.
        case sendFailed
        /// Missing or invalid `--agent` / `--event`.
        case invalidArguments
    }

    /// Exit statuses: 0 whatever happens to the event (the agent must never be
    /// disturbed), 64 for a usage error (wrong arguments or a terminal on stdin).
    package static let usageStatus: Int32 = 64
    /// Payloads larger than this aren't parsed; the event is sent with its payload withheld.
    package static let maxInputBytes = 8 * 1024 * 1024
    /// How long stdin may take to arrive and close.
    package static let inputDeadline: TimeInterval = 2

    package static let usage = """
        usage: OrbitAgentHook --agent <id> --event <name> [--wait <seconds>]
        Run by an AI coding agent's hook with the event's JSON on stdin; sends it to Orbit's AI Hub.
        It always exits 0. Without --wait it prints nothing. With --wait (never for Claude Code) it
        waits up to that long for the user's answer in Orbit and prints it; no answer prints nothing.

        """

    /// The helper's main: returns the exit status. `stdinIsTerminal`: run by hand.
    package static func main(arguments: [String], input: Int32, stdinIsTerminal: Bool,
                             environment: [String: String], parentPID: Int32, socketPath: String,
                             now: Date = .now, writeError: (String) -> Void, writeOutput: (Data) -> Void = { _ in }) -> Int32 {
        guard !stdinIsTerminal, let (agent, event, wait) = parse(arguments) else {
            writeError(usage)
            return usageStatus
        }
        let origin = AgentEnvelope.Origin(bundleID: environment["__CFBundleIdentifier"],
                                          termProgram: environment["TERM_PROGRAM"], ppid: parentPID)
        if let wait, agent != "claude-code" {  // D1: Claude Code is observed only, never answered
            let payload = readPayload(input, deadline: inputDeadline)
            guard let envelope = AgentEnvelope(kind: .request, agent: agent, event: event, sentAt: now, deadline: now.addingTimeInterval(wait),
                                               origin: origin, payload: payload ?? [:],
                                               reducedKeys: payload == nil ? [AgentEnvelope.wholePayload] : []) else { return usageStatus }
            if let printable = request(envelope, socketPath: socketPath)?.printable { writeOutput(printable) }
            return 0
        }
        let outcome = send(agent: agent, event: event, input: input, origin: origin, socketPath: socketPath, now: now)
        return outcome == .invalidArguments ? usageStatus : 0
    }

    /// Sends a request and waits (until its deadline) for Orbit's decision on
    /// the same connection. nil: Orbit isn't there, didn't answer in time, or
    /// sent something invalid; the agent then asks the user itself.
    package static func request(_ envelope: AgentEnvelope, socketPath: String) -> AgentDecision? {
        guard envelope.kind == .request, let deadline = envelope.deadline,
              let fd = try? UnixSocket.connect(to: socketPath) else { return nil }
        defer { close(fd) }
        guard UnixSocket.writeAll(fd, BridgeFraming.frame(envelope.encoded())) else { return nil }
        var decoder = FrameDecoder()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count > 0 else { return nil }  // Orbit closed: no answer
            decoder.append(Data(buffer[..<count]))
            do {
                if let frame = try decoder.next() { return try? AgentDecision.decode(frame) }  // else: wait for the rest
            } catch {
                return nil
            }
        }
    }

    /// Reads stdin, builds the envelope and sends it.
    package static func send(agent: String, event: String, input: Int32, origin: AgentEnvelope.Origin,
                             socketPath: String, now: Date = .now, deadline: TimeInterval = inputDeadline) -> Outcome {
        let payload = readPayload(input, deadline: deadline)
        let envelope = AgentEnvelope(agent: agent, event: event, sentAt: now, origin: origin,
                                     payload: payload ?? [:], reducedKeys: payload == nil ? [AgentEnvelope.wholePayload] : [])
        guard let envelope else { return .invalidArguments }
        return send(envelope, socketPath: socketPath)
    }

    /// One framed envelope over a fresh connection. Fails fast when nothing
    /// listens (connect is refused at once on a Unix socket); a stuck reader
    /// is cut off by the socket's 1 s send timeout.
    package static func send(_ envelope: AgentEnvelope, socketPath: String) -> Outcome {
        guard let fd = try? UnixSocket.connect(to: socketPath) else { return .orbitUnavailable }
        defer { close(fd) }
        return UnixSocket.writeAll(fd, BridgeFraming.frame(envelope.encoded())) ? .sent : .sendFailed
    }

    // MARK: Input

    /// `--agent <id> --event <name> [--wait <seconds>]`, each once, nothing else.
    static func parse(_ arguments: [String]) -> (agent: String, event: String, wait: TimeInterval?)? {
        guard arguments.count == 4 || arguments.count == 6 else { return nil }
        var values: [String: String] = [:]
        for index in stride(from: 0, to: arguments.count, by: 2) {
            let flag = arguments[index]
            guard ["--agent", "--event", "--wait"].contains(flag), values[flag] == nil else { return nil }
            values[flag] = arguments[index + 1]
        }
        guard let agent = values["--agent"], let event = values["--event"],
              AgentEnvelope.isValidAgentID(agent), AgentEnvelope.isValidEventName(event) else { return nil }
        guard let text = values["--wait"] else { return (agent, event, nil) }
        guard let wait = TimeInterval(text), wait >= 1, wait <= AgentEnvelope.maxWait else { return nil }
        return (agent, event, wait)
    }

    /// The JSON object on `input`, or nil (payload withheld) if it's not an
    /// object within the envelope's limits, is over `maxInputBytes`, or doesn't
    /// finish within `deadline`.
    static func readPayload(_ input: Int32, deadline: TimeInterval) -> [String: JSONValue]? {
        guard let data = readAll(input, limit: maxInputBytes, deadline: deadline),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        var nodes = 0
        return (try? JSONValue(foundation: object, depth: 0, nodes: &nodes))?.objectValue
    }

    /// Everything until end of file, or nil past `limit` bytes or `deadline` seconds.
    static func readAll(_ fd: Int32, limit: Int, deadline: TimeInterval) -> Data? {
        let end = Date.now.addingTimeInterval(deadline)
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let remaining = end.timeIntervalSinceNow
            guard remaining > 0 else { return nil }
            var poller = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&poller, 1, Int32(min(remaining * 1000, 60_000).rounded(.up)))
            if ready < 0, errno == EINTR { continue }
            guard ready > 0 else { return nil }
            let count = read(fd, &buffer, buffer.count)
            if count < 0, errno == EINTR || errno == EAGAIN { continue }
            guard count >= 0 else { return nil }
            if count == 0 { return data }
            data.append(contentsOf: buffer[..<count])
            guard data.count <= limit else { return nil }
        }
    }
}
