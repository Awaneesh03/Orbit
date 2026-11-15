import Darwin
import Foundation
import OrbitBridge

// Orbit's end of agents.sock (docs/AI_HUB_SPEC.md §6, §14). Everything that
// touches the untrusted bytes runs on one private serial queue, never the
// main thread (P1-4, S3): accepting, reading, framing, decoding, validation,
// rate limiting and normalisation by the agent's adapter. Only normalised
// events leave, in batches, through `deliver` (called on that queue).

final class AgentBridgeServer: @unchecked Sendable {  // all mutable state is confined to `queue`
    struct Limits: Sendable {
        var maxConnections = 32
        var maxFramesPerConnection = 16
        var eventsPerSecond = 200
        /// A connection that hasn't finished by then is closed.
        var idleTimeout: TimeInterval = 5
        /// How long events wait to be delivered together.
        var batchDelay: TimeInterval = 0.05
        var maxBatch = 256
        /// Requests waiting for a decision at once (they're exempt from the idle timeout).
        var maxWaitingRequests = 8
    }

    /// What happened to incoming messages since the last batch.
    struct Counters: Equatable, Sendable {
        var accepted = 0
        /// Bad frames or envelopes (the connection is closed).
        var invalid = 0
        /// Valid envelopes from agents Orbit has no adapter for, or without a session.
        var unattributed = 0
        var rateLimited = 0
        var refusedConnections = 0
        /// Accepted, but the helper couldn't read the agent's payload (`["*"]`).
        var withheldPayloads = 0
        /// Blocking requests from agents whose adapter can't be answered (§23): closed at once, the agent asks itself.
        var unanswerable = 0

        var isEmpty: Bool { self == Counters() }

        static func += (lhs: inout Counters, rhs: Counters) {
            lhs.accepted += rhs.accepted
            lhs.invalid += rhs.invalid
            lhs.unattributed += rhs.unattributed
            lhs.rateLimited += rhs.rateLimited
            lhs.refusedConnections += rhs.refusedConnections
            lhs.withheldPayloads += rhs.withheldPayloads
            lhs.unanswerable += rhs.unanswerable
        }
    }

    struct Batch: Sendable {
        let events: [AgentEvent]
        let counters: Counters
        /// Requests now waiting for an answer, by connection.
        var requests: [(connection: Int, draft: ApprovalDraft)] = []
        /// Request connections that closed or expired unanswered.
        var closedRequests: [Int] = []
    }

    let path: String
    private let registry: AgentRegistry
    private let limits: Limits
    private let now: @Sendable () -> Date
    private let deliver: @Sendable (Batch) -> Void
    private let queue = DispatchQueue(label: "com.awaneeshgupta.orbit.agent-bridge", qos: .utility)

    private final class Connection {
        let fd: Int32
        let source: DispatchSourceRead
        var decoder = FrameDecoder()
        var frames = 0
        /// A request is waiting on this connection for Orbit's decision.
        var awaiting: ApprovalDraft?
        init(fd: Int32, source: DispatchSourceRead) {
            self.fd = fd
            self.source = source
        }
    }

    // Confined to `queue`.
    private var listener: DispatchSourceRead?
    private var connections: [Int: Connection] = [:]
    private var nextID = 0
    private var pending: [AgentEvent] = []
    private var pendingRequests: [(connection: Int, draft: ApprovalDraft)] = []
    private var closedRequests: [Int] = []
    private var counters = Counters()
    private var flushScheduled = false
    private var generation = 0
    private var windowStart = Date.distantPast
    private var windowCount = 0

    init(path: String, registry: AgentRegistry, limits: Limits = Limits(),
         now: @escaping @Sendable () -> Date = { .now }, deliver: @escaping @Sendable (Batch) -> Void) {
        self.path = path
        self.registry = registry
        self.limits = limits
        self.now = now
        self.deliver = deliver
    }

    var isListening: Bool { queue.sync { listener != nil } }
    var connectionCount: Int { queue.sync { connections.count } }

    /// Listens at `path` (folder 0700, socket 0600, current user only).
    func start() throws {
        try queue.sync {
            guard listener == nil else { return }
            let fd = try UnixSocket.listen(at: path, backlog: 64)  // agents fire hooks in parallel
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.acceptAll(fd) }
            source.setCancelHandler { close(fd) }
            source.resume()
            listener = source
            generation += 1
        }
    }

    /// Stops listening, removes the socket and closes every connection.
    /// Events not yet delivered are dropped.
    func stop() {
        queue.sync {
            guard let listener else { return }
            listener.cancel()
            self.listener = nil
            unlink(path)
            for id in Array(connections.keys) { drop(id) }
            pending = []
            pendingRequests = []
            closedRequests = []
            counters = Counters()
            generation += 1  // a scheduled flush from before is ignored
            flushScheduled = false
        }
    }

    // MARK: Queue

    private func acceptAll(_ listener: Int32) {
        while let fd = UnixSocket.accept(listener) {
            guard connections.count < limits.maxConnections else {
                close(fd)
                counters.refusedConnections += 1
                scheduleFlush()
                continue
            }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            nextID += 1
            let id = nextID
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
            source.setEventHandler { [weak self] in self?.read(id) }
            source.setCancelHandler { close(fd) }
            connections[id] = Connection(fd: fd, source: source)
            source.resume()
            let current = generation
            queue.asyncAfter(deadline: .now() + limits.idleTimeout) { [weak self] in
                guard let self, self.generation == current, self.connections[id]?.awaiting == nil else { return }
                self.drop(id)
            }
        }
    }

    private func read(_ id: Int) {
        guard let connection = connections[id] else { return }
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        let count = Darwin.read(connection.fd, &buffer, buffer.count)
        if count < 0, errno == EAGAIN || errno == EINTR { return }
        guard count > 0 else { return drop(id) }
        connection.decoder.append(Data(buffer[..<count]))
        do {
            while let frame = try connection.decoder.next() {
                connection.frames += 1
                guard connection.frames <= limits.maxFramesPerConnection else {
                    counters.invalid += 1
                    return finish(id)
                }
                guard receive(frame, on: id) else { return finish(id) }
            }
        } catch {
            counters.invalid += 1
            finish(id)
        }
    }

    /// Answers a waiting request (nil output: "no answer", the agent asks the user) and closes it.
    func reply(to connection: Int, output: [String: JSONValue]?) {
        queue.async { [weak self] in
            guard let self, let open = self.connections[connection], open.awaiting != nil else { return }
            _ = UnixSocket.writeAll(open.fd, BridgeFraming.frame(AgentDecision(output: output).encoded()))
            open.awaiting = nil
            self.drop(connection)
        }
    }

    /// False when the frame is invalid (the connection should close).
    private func receive(_ frame: Data, on connection: Int) -> Bool {
        let time = now()
        guard let envelope = try? AgentEnvelope.decode(frame, now: time) else {
            counters.invalid += 1
            return false
        }
        let elapsed = time.timeIntervalSince(windowStart)
        if elapsed >= 1 || elapsed < 0 {  // a clock that stepped back starts a new window
            windowStart = time
            windowCount = 0
        }
        guard windowCount < limits.eventsPerSecond else {
            counters.rateLimited += 1
            scheduleFlush()
            return true
        }
        windowCount += 1
        guard let agent = AgentID(envelope.agent), let adapter = registry.adapter(for: agent) else {
            counters.unattributed += 1
            scheduleFlush()
            return true
        }
        if envelope.kind == .request {
            guard let open = connections[connection], open.awaiting == nil, open.frames == 1,
                  connections.values.filter({ $0.awaiting != nil }).count < limits.maxWaitingRequests,
                  let draft = adapter.approval(from: envelope, agent: agent, receivedAt: time) else {
                counters.unattributed += 1
                scheduleFlush()
                return false  // not answerable here: closing means "no answer"
            }
            // Only adapters verified end to end may be answered (§4, §23): the rest ask their user at once.
            guard adapter.manifest.capabilities.contains(draft.capability) else {
                counters.unanswerable += 1
                scheduleFlush()
                return false
            }
            counters.accepted += 1
            open.awaiting = draft
            pendingRequests.append((connection, draft))
            let current = generation
            queue.asyncAfter(deadline: .now() + max(0, draft.expiresAt.timeIntervalSince(time))) { [weak self] in
                guard let self, self.generation == current, self.connections[connection]?.awaiting != nil else { return }
                self.drop(connection)  // expired: the helper gets no answer
            }
            flush()
            return true
        }
        let origin = AgentOrigin(bundleID: envelope.origin.bundleID, pid: envelope.origin.ppid)
        let events = adapter.normalise(envelope, agent: agent, receivedAt: time).map { event in
            var event = event
            event.origin = origin.bundleID == nil && origin.pid == nil ? nil : origin
            return event
        }
        if envelope.reducedKeys == [AgentEnvelope.wholePayload] { counters.withheldPayloads += 1 }
        if events.isEmpty {
            counters.unattributed += 1
        } else {
            counters.accepted += 1
            pending.append(contentsOf: events)
        }
        if pending.count >= limits.maxBatch { flush() } else { scheduleFlush() }
        return true
    }

    private func finish(_ id: Int) {
        scheduleFlush()
        drop(id)
    }

    private func drop(_ id: Int) {
        guard let connection = connections.removeValue(forKey: id) else { return }
        connection.source.cancel()  // closes the socket
        if connection.awaiting != nil {
            closedRequests.append(id)
            scheduleFlush()
        }
    }

    private func scheduleFlush() {
        guard !flushScheduled else { return }
        flushScheduled = true
        let current = generation
        queue.asyncAfter(deadline: .now() + limits.batchDelay) { [weak self] in
            guard let self, self.generation == current else { return }
            self.flush()
        }
    }

    private func flush() {
        flushScheduled = false
        guard !pending.isEmpty || !counters.isEmpty || !pendingRequests.isEmpty || !closedRequests.isEmpty else { return }
        let batch = Batch(events: pending, counters: counters, requests: pendingRequests, closedRequests: closedRequests)
        pending = []
        pendingRequests = []
        closedRequests = []
        counters = Counters()
        deliver(batch)
    }
}
