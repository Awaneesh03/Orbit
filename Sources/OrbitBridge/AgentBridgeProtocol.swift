import Foundation

// The AI Hub's agent bridge (docs/AI_HUB_SPEC.md §6, §14): what an agent's
// hook helper (OrbitAgentHook) and Orbit's demo agents send to Orbit over
// agents.sock, one envelope per frame, using the Brave bridge's framing.
// Everything decoded here is untrusted; errors name fields, never contents.

extension UnixSocket {
    /// ~/Library/Application Support/Orbit/Bridge/agents.sock
    package static var agentsPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Application Support/Orbit/Bridge/agents.sock").path(percentEncoded: false)
    }
}

/// A JSON value from an agent's payload, kept as data (never interpreted here).
package enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    package var stringValue: String? { if case .string(let value) = self { value } else { nil } }
    package var objectValue: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
    package var arrayValue: [JSONValue]? { if case .array(let value) = self { value } else { nil } }

    /// Strings, numbers, booleans and null.
    var isScalar: Bool {
        switch self {
        case .array, .object: false
        default: true
        }
    }
}

package struct AgentEnvelopeError: Error, Equatable, CustomStringConvertible {
    package let description: String
    package init(_ description: String) { self.description = description }
}

/// One hook event from an agent. A `hook` is fire-and-forget; a `request`
/// (Phase 4) waits on the same connection for Orbit's `AgentDecision` until
/// `deadline`, and no answer means the agent asks the user itself. Requests
/// are never accepted from Claude Code (D1).
package struct AgentEnvelope: Equatable, Sendable {
    package enum Kind: String, Sendable { case hook, request }
    package static let version = 1
    package static let type = "hook"
    /// A request's deadline: at most this long after it was sent.
    package static let maxWait: TimeInterval = 600
    /// Every envelope fits one frame (`BridgeFraming.maxMessageBytes`).
    package static let maxEncodedBytes = BridgeFraming.maxMessageBytes
    /// A top-level string longer than this is reduced when the envelope doesn't fit.
    package static let maxReducedStringBytes = 1024
    static let maxDepth = 32
    static let maxNodes = 16_384
    static let maxKeyBytes = 256
    /// At most this many keys are listed as reduced; past it the whole payload is withheld.
    package static let maxReducedKeys = 256
    /// `reducedKeys == [wholePayload]` with an empty payload: none of the payload was delivered.
    package static let wholePayload = "*"
    /// How far `sentAt` may be from Orbit's clock: the helper sends at once, on this Mac.
    static let maxAge: TimeInterval = 24 * 3600
    static let maxSkew: TimeInterval = 5 * 60

    package struct Origin: Equatable, Sendable {
        /// The app the agent runs in (`__CFBundleIdentifier`), e.g. com.apple.Terminal.
        package var bundleID: String?
        /// `TERM_PROGRAM`, e.g. Apple_Terminal or vscode.
        package var termProgram: String?
        /// The hook helper's parent: the agent, or a shell it started.
        package var ppid: Int32?

        package init(bundleID: String? = nil, termProgram: String? = nil, ppid: Int32? = nil) {
            self.bundleID = bundleID
            self.termProgram = termProgram
            self.ppid = ppid
        }
    }

    package let kind: Kind
    package let agent: String
    package let event: String
    package let sentAt: Date
    /// Requests only: when the helper stops waiting.
    package let deadline: Date?
    package let origin: Origin
    package let payload: [String: JSONValue]
    /// The top-level payload keys whose values were removed to fit a frame.
    /// A listed key means "present but not delivered", never "absent";
    /// `[wholePayload]` means none of the payload was delivered.
    package let reducedKeys: [String]
    package var truncated: Bool { !reducedKeys.isEmpty }

    /// nil when `agent` or `event` isn't valid; origin fields that aren't
    /// valid are dropped.
    package init?(kind: Kind = .hook, agent: String, event: String, sentAt: Date, deadline: Date? = nil, origin: Origin = Origin(),
                  payload: [String: JSONValue], reducedKeys: [String] = []) {
        guard Self.isValidAgentID(agent), Self.isValidEventName(event) else { return nil }
        let rounded = { (date: Date) in Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000) }
        if kind == .request {
            guard agent != "claude-code", let deadline, deadline > sentAt, deadline.timeIntervalSince(sentAt) <= Self.maxWait else { return nil }
            self.deadline = rounded(deadline)
        } else {
            guard deadline == nil else { return nil }
            self.deadline = nil
        }
        self.kind = kind
        self.agent = agent
        self.event = event
        self.sentAt = Date(timeIntervalSince1970: (sentAt.timeIntervalSince1970 * 1000).rounded() / 1000)
        self.origin = Self.sanitized(origin)
        self.payload = payload
        self.reducedKeys = reducedKeys.sorted()
    }

    // MARK: Rules shared with Orbit

    /// 1–32 of a–z, 0–9 and "-" (`AgentID` uses the same rule).
    package static func isValidAgentID(_ value: String) -> Bool {
        (1 ... 32).contains(value.utf8.count)
            && value.utf8.allSatisfy { (0x61 ... 0x7A).contains($0) || (0x30 ... 0x39).contains($0) || $0 == 0x2D }
    }

    /// A letter, then up to 63 letters, digits, "." or "_" (e.g. PostToolUse, session.idle).
    package static func isValidEventName(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        guard (1 ... 64).contains(bytes.count), isLetter(bytes[0]) else { return false }
        return bytes.allSatisfy { isLetter($0) || (0x30 ... 0x39).contains($0) || $0 == 0x2E || $0 == 0x5F }
    }

    /// An agent-supplied path made safe to show or compare: absolute, no
    /// control characters, "." and ".." resolved lexically (the file system
    /// isn't touched), at most 1,024 bytes. nil if it can't be.
    package static func sanitizedPath(_ value: String?) -> String? {
        guard let value, value.hasPrefix("/"), value.utf8.count <= 1024,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        var parts: [Substring] = []
        for part in value.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": if !parts.isEmpty { parts.removeLast() }
            default: parts.append(part)
            }
        }
        return "/" + parts.joined(separator: "/")
    }

    // MARK: Encoding (helper and demo agents)

    /// The envelope as one frame's JSON, reduced if needed so it always fits:
    /// first top-level arrays, objects and strings over 1 KiB are removed
    /// (largest first), then any remaining values (largest first). Each
    /// removed key is listed in `reducedKeys`; nothing is cut mid-value. If
    /// more than `maxReducedKeys` would go, the whole payload is withheld.
    package func encoded() -> Data {
        guard let full = try? serialized() else { return withheld() }
        if full.count <= Self.maxEncodedBytes { return full }
        // Bytes each top-level entry takes ("key":value,) and its entry in reducedKeys ("key",).
        func size(_ object: Any) -> Int {
            guard JSONSerialization.isValidJSONObject(object) else { return Self.maxEncodedBytes }
            return (try? JSONSerialization.data(withJSONObject: object)).map { $0.count - 1 } ?? Self.maxEncodedBytes
        }
        let cost = Dictionary(uniqueKeysWithValues: payload.map { ($0.key, size([$0.key: $0.value.foundation])) })
        let bulky = payload.keys.filter { key in
            let value = payload[key]!
            return !value.isScalar || (value.stringValue?.utf8.count ?? 0) > Self.maxReducedStringBytes
        }
        let order = bulky.sorted { cost[$0]! > cost[$1]! }
            + payload.keys.filter { !bulky.contains($0) }.sorted { cost[$0]! > cost[$1]! }
        var payload = payload
        var reduced = Set(reducedKeys)
        var estimate = full.count
        for key in order {
            guard reduced.count < Self.maxReducedKeys else { break }
            payload[key] = nil
            reduced.insert(key)
            estimate += size([key]) - cost[key]!
            guard estimate <= Self.maxEncodedBytes else { continue }  // serialise only once it should fit
            if let data = try? AgentEnvelope(unchecked: self, payload: payload, reducedKeys: reduced.sorted()).serialized(),
               data.count <= Self.maxEncodedBytes { return data }
        }
        return withheld()
    }

    /// Only the envelope's own fields, which always fit.
    private func withheld() -> Data {
        (try? AgentEnvelope(unchecked: self, payload: [:], reducedKeys: [Self.wholePayload]).serialized()) ?? Data("{}".utf8)
    }

    private init(unchecked base: AgentEnvelope, payload: [String: JSONValue], reducedKeys: [String]) {
        kind = base.kind
        deadline = base.deadline
        agent = base.agent
        event = base.event
        sentAt = base.sentAt
        origin = base.origin
        self.payload = payload
        self.reducedKeys = reducedKeys
    }

    private func serialized() throws -> Data {
        var originObject: [String: Any] = [:]
        if let bundleID = origin.bundleID { originObject["bundleID"] = bundleID }
        if let termProgram = origin.termProgram { originObject["termProgram"] = termProgram }
        if let ppid = origin.ppid { originObject["ppid"] = Int(ppid) }
        var object: [String: Any] = [
            "v": Self.version, "type": kind.rawValue, "agent": agent, "event": event,
            "sentAt": Int64((sentAt.timeIntervalSince1970 * 1000).rounded()),
            "origin": originObject, "payload": JSONValue.object(payload).foundation,
            "truncated": truncated, "reducedKeys": reducedKeys,
        ]
        if let deadline { object["deadline"] = Int64((deadline.timeIntervalSince1970 * 1000).rounded()) }
        guard JSONSerialization.isValidJSONObject(object) else { throw AgentEnvelopeError("not serialisable") }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }

    // MARK: Decoding (Orbit)

    private static let fields: Set<String> = ["v", "type", "agent", "event", "sentAt", "origin", "payload", "truncated", "reducedKeys"]

    /// Decodes and validates one frame. Rejects anything that isn't exactly a
    /// version-1 hook envelope: unknown or missing fields, a bad agent or event
    /// name, a time far from `now`, a payload that isn't a bounded JSON object,
    /// or `truncated` that disagrees with `reducedKeys`. Invalid origin fields
    /// are dropped, not trusted.
    package static func decode(_ data: Data, now: Date = .now) throws(AgentEnvelopeError) -> AgentEnvelope {
        guard data.count <= maxEncodedBytes else { throw AgentEnvelopeError("too large") }
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw AgentEnvelopeError("not a JSON object")
        }
        guard let version = object["v"] as? NSNumber, !isBool(version), version.doubleValue == Double(Self.version) else {
            throw AgentEnvelopeError("unsupported version")
        }
        guard let kind = (object["type"] as? String).flatMap(Kind.init(rawValue:)) else { throw AgentEnvelopeError("unsupported type") }
        guard Set(object.keys) == (kind == .request ? fields.union(["deadline"]) : fields) else {
            throw AgentEnvelopeError("unexpected or missing fields")
        }
        guard let agent = object["agent"] as? String, isValidAgentID(agent) else { throw AgentEnvelopeError("invalid agent") }
        guard let event = object["event"] as? String, isValidEventName(event) else { throw AgentEnvelopeError("invalid event") }
        guard let millis = object["sentAt"] as? NSNumber, !isBool(millis), millis.doubleValue.isFinite,
              millis.doubleValue == millis.doubleValue.rounded() else { throw AgentEnvelopeError("invalid sentAt") }
        let sentAt = Date(timeIntervalSince1970: millis.doubleValue / 1000)
        guard sentAt >= now.addingTimeInterval(-maxAge), sentAt <= now.addingTimeInterval(maxSkew) else {
            throw AgentEnvelopeError("sentAt out of range")
        }
        guard let origin = object["origin"] as? [String: Any] else { throw AgentEnvelopeError("invalid origin") }
        var nodes = 0
        guard let payload = (try? JSONValue(foundation: object["payload"] as Any, depth: 0, nodes: &nodes))?.objectValue else {
            throw AgentEnvelopeError("invalid payload")
        }
        guard let truncated = object["truncated"] as? NSNumber, isBool(truncated),
              let reducedKeys = object["reducedKeys"] as? [String],
              reducedKeys.count <= maxReducedKeys, reducedKeys.allSatisfy({ (1 ... maxKeyBytes).contains($0.utf8.count) && payload[$0] == nil }),
              Set(reducedKeys).count == reducedKeys.count, truncated.boolValue == !reducedKeys.isEmpty,
              !reducedKeys.contains(wholePayload) || (reducedKeys == [wholePayload] && payload.isEmpty)
        else { throw AgentEnvelopeError("invalid truncation") }
        let ppid = (origin["ppid"] as? NSNumber).flatMap { isBool($0) ? nil : Int32(exactly: $0.doubleValue) }
        var deadline: Date?
        if kind == .request {
            guard let value = object["deadline"] as? NSNumber, !isBool(value), value.doubleValue.isFinite else {
                throw AgentEnvelopeError("invalid deadline")
            }
            deadline = Date(timeIntervalSince1970: value.doubleValue / 1000)
        }
        let envelope = AgentEnvelope(
            kind: kind, agent: agent, event: event, sentAt: sentAt, deadline: deadline,
            origin: Origin(bundleID: origin["bundleID"] as? String, termProgram: origin["termProgram"] as? String, ppid: ppid),
            payload: payload, reducedKeys: reducedKeys)
        guard let envelope else { throw AgentEnvelopeError("invalid envelope") }
        return envelope
    }

    // MARK: Helpers

    private static func sanitized(_ origin: Origin) -> Origin {
        Origin(bundleID: origin.bundleID.flatMap(bundleIdentifier), termProgram: origin.termProgram.flatMap(printable),
               ppid: origin.ppid.flatMap { $0 > 0 ? $0 : nil })
    }

    /// Reverse-DNS characters only, 1–155 bytes (the macOS bundle ID limit).
    private static func bundleIdentifier(_ value: String) -> String? {
        let ok = (1 ... 155).contains(value.utf8.count) && value.utf8.allSatisfy {
            isLetter($0) || (0x30 ... 0x39).contains($0) || $0 == 0x2E || $0 == 0x2D
        }
        return ok ? value : nil
    }

    /// 1–64 bytes without control characters.
    private static func printable(_ value: String) -> String? {
        guard (1 ... 64).contains(value.utf8.count),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return nil }
        return value
    }

    private static func isLetter(_ byte: UInt8) -> Bool { (0x41 ... 0x5A).contains(byte) || (0x61 ... 0x7A).contains(byte) }

    static func isBool(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
}

extension JSONValue {
    /// Converts `JSONSerialization` output, refusing anything deeper than 32
    /// levels, larger than 16,384 values or with keys over 256 bytes.
    package init(foundation value: Any, depth: Int, nodes: inout Int) throws(AgentEnvelopeError) {
        nodes += 1
        guard depth <= AgentEnvelope.maxDepth, nodes <= AgentEnvelope.maxNodes else { throw AgentEnvelopeError("payload too complex") }
        switch value {
        case is NSNull: self = .null
        case let number as NSNumber:
            // -1e999 parses as -inf, which JSONSerialization can't write (it raises, uncatchably).
            guard AgentEnvelope.isBool(number) || number.doubleValue.isFinite else { throw AgentEnvelopeError("payload number out of range") }
            self = AgentEnvelope.isBool(number) ? .bool(number.boolValue) : .number(number.doubleValue)
        case let string as String: self = .string(string)
        case let array as [Any]:
            var values: [JSONValue] = []
            for element in array { values.append(try JSONValue(foundation: element, depth: depth + 1, nodes: &nodes)) }
            self = .array(values)
        case let object as [String: Any]:
            var values: [String: JSONValue] = [:]
            for (key, element) in object {
                guard (1 ... AgentEnvelope.maxKeyBytes).contains(key.utf8.count) else { throw AgentEnvelopeError("payload key too long") }
                values[key] = try JSONValue(foundation: element, depth: depth + 1, nodes: &nodes)
            }
            self = .object(values)
        default: throw AgentEnvelopeError("payload isn't JSON")
        }
    }

    /// The `JSONSerialization` form.
    package var foundation: Any {
        switch self {
        case .null: NSNull()
        case .bool(let value): value
        case .number(let value): value
        case .string(let value): value
        case .array(let values): values.map(\.foundation)
        case .object(let values): values.mapValues(\.foundation)
        }
    }
}

/// Orbit's answer to a `request` envelope, on the same connection: the JSON
/// the helper prints for its agent (that agent's own hook-output format), or
/// nothing (the agent then asks the user itself).
package struct AgentDecision: Equatable, Sendable {
    package let output: [String: JSONValue]?

    package init(output: [String: JSONValue]?) { self.output = output }

    package func encoded() -> Data {
        var object: [String: Any] = ["v": AgentEnvelope.version, "type": "decision"]
        object["output"] = output.map { JSONValue.object($0).foundation } ?? NSNull()
        guard JSONSerialization.isValidJSONObject(object), let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              data.count <= AgentEnvelope.maxEncodedBytes else { return Data(#"{"output":null,"type":"decision","v":1}"#.utf8) }
        return data
    }

    package static func decode(_ data: Data) throws(AgentEnvelopeError) -> AgentDecision {
        guard data.count <= AgentEnvelope.maxEncodedBytes,
              let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              Set(object.keys) == ["v", "type", "output"], (object["v"] as? NSNumber)?.intValue == AgentEnvelope.version,
              object["type"] as? String == "decision" else { throw AgentEnvelopeError("invalid decision") }
        if object["output"] is NSNull { return AgentDecision(output: nil) }
        var nodes = 0
        guard let output = (try? JSONValue(foundation: object["output"] as Any, depth: 0, nodes: &nodes))?.objectValue else {
            throw AgentEnvelopeError("invalid decision")
        }
        return AgentDecision(output: output)
    }

    /// What the helper prints (one line of JSON), or nil for nothing.
    package var printable: Data? {
        guard let output, JSONSerialization.isValidJSONObject(JSONValue.object(output).foundation) else { return nil }
        return (try? JSONSerialization.data(withJSONObject: JSONValue.object(output).foundation, options: [.sortedKeys])).map { $0 + Data("\n".utf8) }
    }
}

/// Codable for declarative adapter manifests (Phase 12); non-finite numbers aren't JSON and fail.
extension JSONValue: Codable {
    package init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if let value = try? container.decode([JSONValue].self) { self = .array(value) }
        else if let value = try? container.decode([String: JSONValue].self) { self = .object(value) }
        else { throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a JSON value") }
    }

    package func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .number(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .array(let values): try container.encode(values)
        case .object(let values): try container.encode(values)
        }
    }
}
