import Foundation
import OrbitBridge

// Claude Code (Phase 2; docs/AI_HUB_SPEC.md §3, §13 D1): observe-only. Maps
// the documented hook payloads (code.claude.com/docs/en/hooks) into events.
// Orbit never answers anything for Claude Code: no PermissionRequest hook, no
// AskUserQuestion answers — NotchBuddy owns those. When Claude is waiting for
// the user, that's only *inferred* from its Notification / AskUserQuestion
// events and labelled as such. Payload shapes beyond the documented fields are
// UNVERIFIED until checked against a real session.

struct ClaudeCodeAdapter: AgentAdapter {
    let manifest = AgentManifest(id: AgentID("claude-code")!, displayName: "Claude Code", capabilities: .observe)

    /// The hook events Orbit observes (all non-blocking; never PermissionRequest).
    static let observedEvents = [
        "SessionStart", "SessionEnd", "UserPromptSubmit", "PreToolUse", "PostToolUse", "PostToolUseFailure",
        "Stop", "StopFailure", "SubagentStart", "SubagentStop", "Notification", "PreCompact",
    ]
    /// Claude's notification types that mean "waiting for the user".
    static let waitingNotifications: Set<String> = ["permission_prompt", "idle_prompt", "elicitation_dialog", "agent_needs_input"]
    static let editingTools: Set<String> = ["Write", "Edit", "MultiEdit", "NotebookEdit"]

    func normalise(_ envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> [AgentEvent] {
        let payload = envelope.payload
        guard let session = payload["session_id"]?.stringValue.flatMap({ SessionKey(agent: agent, nativeID: $0) }) else { return [] }
        let tool = Redactor.line(payload["tool_name"]?.stringValue, limit: 64)
        let input = payload["tool_input"]?.objectValue ?? [:]
        let files = Self.files(in: input, cwd: payload["cwd"]?.stringValue)
        let discriminator = payload["tool_use_id"]?.stringValue.flatMap { Redactor.line($0, limit: 80) }
            ?? String(Int64(envelope.sentAt.timeIntervalSince1970 * 1000))
        func event(_ kind: AgentEvent.Kind, _ summary: String?, files: [String] = [], suffix: String = "") -> AgentEvent {
            AgentEvent(id: UUID(), session: session, kind: kind, nativeName: envelope.event, occurredAt: envelope.sentAt,
                       receivedAt: receivedAt, cwd: AgentEnvelope.sanitizedPath(payload["cwd"]?.stringValue), tool: tool,
                       summary: Redactor.line(summary, limit: 160), files: files,
                       dedupeKey: "\(session)|\(envelope.event)\(suffix)|\(discriminator)")
        }
        let detail = { (key: String) in Redactor.line(payload[key]?.stringValue, limit: 40) }
        switch envelope.event {
        case "SessionStart":
            return [event(.sessionStarted, "Session started" + (detail("source").map { " (\($0))" } ?? ""))]
        case "SessionEnd":
            return [event(.sessionEnded, "Session ended" + (detail("reason").map { " (\($0))" } ?? ""))]
        case "UserPromptSubmit":
            return [event(.promptSubmitted, "Prompt submitted")]  // the prompt's text isn't kept (§7 privacy default)
        case "PreToolUse":
            var events = [event(.toolStarted, Self.describe(tool, input), files: files)]
            if tool == "AskUserQuestion" {
                events.append(event(.waitingForUser, "Asked a question (inferred; Orbit doesn't answer it)", suffix: ".wait"))
            }
            return events
        case "PostToolUse":
            var events = [event(.toolCompleted, Self.describe(tool, input), files: files)]
            if let tool, Self.editingTools.contains(tool), !files.isEmpty {
                events.append(event(.fileChanged, "Changed \(files.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "))",
                                    files: files, suffix: ".file"))
            }
            return events
        case "PostToolUseFailure":
            return [event(.toolFailed, (tool ?? "Tool") + " failed", files: files)]
        case "Stop":
            return [event(.turnCompleted, "Turn finished")]
        case "StopFailure":
            return [event(.error, "Turn failed" + (detail("error").map { ": \($0)" } ?? ""))]
        case "SubagentStart", "SubagentStop":
            let started = envelope.event == "SubagentStart"
            return [event(.notification, (started ? "Subagent started" : "Subagent finished") + (detail("agent_type").map { " (\($0))" } ?? ""))]
        case "Notification":
            if let type = payload["notification_type"]?.stringValue, Self.waitingNotifications.contains(type) {
                return [event(.waitingForUser, "Waiting for you (inferred from Claude's notification)")]
            }
            return [event(.notification, payload["message"]?.stringValue ?? "Notification")]
        case "PreCompact", "PostCompact":
            return [event(.notification, "Compacting the conversation")]
        default:
            return [event(.notification, envelope.event)]
        }
    }

    /// Paths named by a tool's input (absolute, or relative to the session's cwd).
    static func files(in input: [String: JSONValue], cwd: String?) -> [String] {
        ["file_path", "notebook_path", "path"].compactMap { key -> String? in
            guard let value = input[key]?.stringValue else { return nil }
            if value.hasPrefix("/") { return AgentEnvelope.sanitizedPath(value) }
            guard let cwd = AgentEnvelope.sanitizedPath(cwd) else { return nil }
            return AgentEnvelope.sanitizedPath(cwd + "/" + value)
        }
    }

    /// One redacted line about a tool call, without file contents.
    static func describe(_ tool: String?, _ input: [String: JSONValue]) -> String {
        let name = tool ?? "Tool"
        let text = { (key: String) in input[key]?.stringValue }
        switch name {
        case "Bash": return "Bash: " + (text("description") ?? text("command")?.split(separator: "\n").first.map(String.init) ?? "")
        case "Read", "Write", "Edit", "MultiEdit", "NotebookEdit":
            return "\(name) " + ((text("file_path") ?? text("notebook_path")).map { ($0 as NSString).lastPathComponent } ?? "")
        case "Grep", "Glob": return "\(name) " + (text("pattern") ?? "")
        case "WebFetch": return "WebFetch " + (text("url").flatMap { URL(string: $0)?.host() } ?? "")
        case "WebSearch": return "WebSearch"
        case "Task", "Agent": return "\(name): " + (text("description") ?? "")
        default: return name
        }
    }
}
