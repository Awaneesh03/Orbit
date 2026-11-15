import Foundation
import OrbitBridge

// OpenCode (Phase 6; docs/AI_HUB_SPEC.md §3): unlike the hook agents, OpenCode
// runs a local server with an event stream (Server-Sent Events) and REST
// endpoints. This is the pure part: parsing the stream and mapping its events.
// Connecting is pending: it needs the user to run `opencode serve` (or the V2
// background service), the server's password is a credential (D3), and the
// event names below are from the V2 docs, UNVERIFIED against this Mac's V1
// (1.4.3). The client only ever talks to 127.0.0.1; Orbit opens no port.

enum OpenCodeEvents {
    /// Splits an SSE stream into the JSON of its `data:` fields, one per event.
    struct Parser {
        private var buffer = ""
        private var data: [String] = []

        mutating func append(_ text: String) -> [String] {
            // Swift treats "\r\n" as one Character, so normalise it (after joining: a pair can span two chunks).
            buffer = (buffer + text).replacingOccurrences(of: "\r\n", with: "\n")
            var events: [String] = []
            while let newline = buffer.firstIndex(of: "\n") {
                let line = String(buffer[..<newline])
                buffer = String(buffer[buffer.index(after: newline)...])
                if line.isEmpty {
                    if !data.isEmpty { events.append(data.joined(separator: "\n")) }
                    data = []
                } else if line.hasPrefix("data:") {
                    data.append(String(line.dropFirst(5)).trimmingCharacters(in: CharacterSet(charactersIn: " ")))
                }  // id:, event:, retry: and comments (":") aren't needed
                if buffer.utf8.count > 1 << 20 { buffer = ""; data = [] }  // a runaway line: start over
            }
            return events
        }
    }

    static let agent = AgentID("opencode")!

    /// One event's JSON as Orbit events (empty: not one Orbit shows).
    static func events(from json: String, receivedAt: Date) -> [AgentEvent] {
        guard json.utf8.count <= AgentEnvelope.maxEncodedBytes,
              let object = try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
              let type = object["type"] as? String else { return [] }
        var nodes = 0
        let properties = (try? JSONValue(foundation: object["properties"] ?? [:], depth: 0, nodes: &nodes))?.objectValue ?? [:]
        let sessionID = HookAdapter.string(properties, ["sessionID", "info.id", "part.sessionID", "session.id"])
        guard let sessionID, let session = SessionKey(agent: agent, nativeID: String(sessionID.prefix(128))) else { return [] }
        let tool = Redactor.line(HookAdapter.string(properties, ["tool", "part.tool", "name"]), limit: 64)
        let kind: AgentEvent.Kind?
        switch type {
        case "session.created": kind = .sessionStarted
        case "session.deleted": kind = .sessionEnded
        case "session.idle": kind = .turnCompleted
        case "session.status":
            kind = HookAdapter.string(properties, ["status", "status.type"]) == "idle" ? .turnCompleted : .notification
        case "session.tool.called": kind = .toolStarted
        case "session.tool.success": kind = .toolCompleted
        case "session.tool.failed", "session.execution.failed": kind = .toolFailed
        case "session.error": kind = .error
        case "permission.asked", "permission.updated": kind = .waitingForUser
        case "filesystem.changed", "file.edited": kind = .fileChanged
        default: kind = nil
        }
        guard let kind else { return [] }
        let file = AgentEnvelope.sanitizedPath(HookAdapter.string(properties, ["file", "path"]))
        let discriminator = HookAdapter.string(properties, ["id", "part.id", "callID", "requestID"]) ?? "\(receivedAt.timeIntervalSince1970)"
        return [AgentEvent(id: UUID(), session: session, kind: kind, nativeName: type, occurredAt: nil, receivedAt: receivedAt,
                           cwd: AgentEnvelope.sanitizedPath(HookAdapter.string(properties, ["directory", "info.directory"])), tool: tool,
                           summary: kind == .waitingForUser ? "Waiting for your permission in OpenCode" :
                               HookAdapter.summary(kind, tool: tool, input: [:], payload: properties, native: type),
                           files: file.map { [$0] } ?? [], dedupeKey: "\(session)|\(type)|\(Redactor.line(discriminator, limit: 80) ?? "")")]
    }
}
