import Foundation
import OrbitBridge

// Agents whose hooks send JSON on stdin (Phase 6; docs/AI_HUB_SPEC.md §3): one
// adapter driven by a declarative mapping of where each agent puts the session
// ID, folder, tool and files, and which of its events mean what. The mappings
// below follow each agent's documented hook payloads (UNVERIFIED against real
// sessions until each agent's hooks are installed with the user's approval).
// Manifests advertise `observe` only: answering is implemented (the mapping's
// permission event and outputs) but not advertised or installed until verified.

struct HookAdapter: AgentAdapter {
    /// Declarative: the same shape third-party manifests use (Phase 12).
    struct Mapping: Codable, Equatable, Sendable {
        /// Dotted paths, first present wins; "[0]" indexes an array (e.g. "workspace_roots[0]").
        var session: [String]
        var cwd: [String]
        var tool: [String]
        var toolInput: [String]
        var toolUse: [String]
        /// Inside the tool input (or the payload): paths a tool reads or writes.
        var files: [String]
        /// Native event name → Orbit's kind.
        var events: [String: AgentEvent.Kind]
        /// Events after which the named files changed (an edit tool or a file-edit event).
        var editEvents: [String]
        var editTools: [String]
        /// A tool-input key holding an apply_patch-style patch ("*** Update File: path").
        var patch: String?
        /// The blocking event Orbit could answer, and the agent's output for each answer.
        var permissionEvent: String?
        var allowOutput: [String: JSONValue]?
        var denyOutput: [String: JSONValue]?
    }

    let manifest: AgentManifest
    let mapping: Mapping

    func normalise(_ envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> [AgentEvent] {
        let payload = envelope.payload
        guard let kind = mapping.events[envelope.event],
              let session = Self.string(payload, mapping.session).flatMap({ SessionKey(agent: agent, nativeID: String($0.prefix(SessionKey.maxNativeIDLength))) })
        else { return [] }
        let tool = Redactor.line(Self.string(payload, mapping.tool), limit: 64)
        let input = Self.object(payload, mapping.toolInput) ?? [:]
        let cwd = AgentEnvelope.sanitizedPath(Self.string(payload, mapping.cwd))
        var files = (mapping.files.compactMap { input[$0]?.stringValue ?? payload[$0]?.stringValue })
        if let key = mapping.patch, let patch = input[key]?.stringValue { files += Self.patchFiles(patch) }
        let absolute = Array(Set(files.compactMap { path -> String? in
            path.hasPrefix("/") ? AgentEnvelope.sanitizedPath(path) : cwd.flatMap { AgentEnvelope.sanitizedPath($0 + "/" + path) }
        })).sorted().prefix(50)
        let discriminator = Self.string(payload, mapping.toolUse).flatMap { Redactor.line($0, limit: 80) }
            ?? String(Int64(envelope.sentAt.timeIntervalSince1970 * 1000))
        func event(_ kind: AgentEvent.Kind, _ summary: String?, suffix: String = "") -> AgentEvent {
            AgentEvent(id: UUID(), session: session, kind: kind, nativeName: envelope.event, occurredAt: envelope.sentAt,
                       receivedAt: receivedAt, cwd: cwd, tool: tool, summary: Redactor.line(summary, limit: 160), files: Array(absolute),
                       dedupeKey: "\(session)|\(envelope.event)\(suffix)|\(discriminator)")
        }
        var events = [event(kind, Self.summary(kind, tool: tool, input: input, payload: payload, native: envelope.event))]
        let edited = mapping.editEvents.contains(envelope.event) && (mapping.editTools.isEmpty || mapping.editTools.contains(tool ?? ""))
        if edited, !absolute.isEmpty, kind != .fileChanged {
            events.append(event(.fileChanged, "Changed " + absolute.map { ($0 as NSString).lastPathComponent }.joined(separator: ", "), suffix: ".file"))
        }
        return events
    }

    func approval(from envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> ApprovalDraft? {
        guard envelope.kind == .request, envelope.event == mapping.permissionEvent, let deadline = envelope.deadline,
              let session = Self.string(envelope.payload, mapping.session).flatMap({ SessionKey(agent: agent, nativeID: String($0.prefix(128))) })
        else { return nil }
        let tool = Redactor.line(Self.string(envelope.payload, mapping.tool), limit: 64)
        let input = Self.object(envelope.payload, mapping.toolInput) ?? [:]
        let full = input["command"]?.stringValue ?? input["cmd"]?.stringValue
            ?? input.sorted { $0.key < $1.key }.map { "\($0.key): \($0.value.stringValue ?? String(describing: $0.value))" }.joined(separator: "\n")
        return ApprovalDraft(session: session, kind: .permission, nativeName: envelope.event, tool: tool,
                             summary: Redactor.line(Self.describe(tool, input), limit: 200) ?? envelope.event, options: [],
                             createdAt: receivedAt,
                             expiresAt: min(deadline, receivedAt.addingTimeInterval(AgentEnvelope.maxWait)).addingTimeInterval(-2),
                             detail: Redactor.block(full))
    }

    func output(for decision: ApprovalDecision, to draft: ApprovalDraft) -> [String: JSONValue]? {
        switch decision {
        case .allowOnce: mapping.allowOutput
        case .deny: mapping.denyOutput
        case .answer, .answers: nil
        }
    }

    // MARK: Helpers

    static func summary(_ kind: AgentEvent.Kind, tool: String?, input: [String: JSONValue], payload: [String: JSONValue], native: String) -> String {
        switch kind {
        case .sessionStarted: "Session started"
        case .sessionEnded: "Session ended"
        case .promptSubmitted: "Prompt submitted"  // the prompt's text isn't kept
        case .turnCompleted: "Turn finished"
        case .toolStarted, .toolCompleted: describe(tool, input)
        case .toolFailed: (tool ?? "Tool") + " failed"
        case .fileChanged: "File changed"
        case .error: "Error" + (payload["error"]?.stringValue.map { ": \($0)" } ?? "")
        case .waitingForUser: "Waiting for you in the agent (inferred)"
        case .notification: payload["message"]?.stringValue ?? native
        }
    }

    static func describe(_ tool: String?, _ input: [String: JSONValue]) -> String {
        let name = tool ?? "Tool"
        if let command = input["command"]?.stringValue ?? input["cmd"]?.stringValue {
            return "\(name): " + (command.split(separator: "\n").first.map(String.init) ?? "")
        }
        if let path = input["file_path"]?.stringValue ?? input["path"]?.stringValue ?? input["filePath"]?.stringValue {
            return "\(name) " + (path as NSString).lastPathComponent
        }
        return name
    }

    /// Paths named by an apply_patch patch.
    static func patchFiles(_ patch: String) -> [String] {
        patch.split(separator: "\n").compactMap { line in
            for prefix in ["*** Update File: ", "*** Add File: ", "*** Delete File: ", "*** Move to: "] where line.hasPrefix(prefix) {
                return String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
            }
            return nil
        }
    }

    /// A value by dotted path ("toolCall.name", "workspace_roots[0]"); JSON-in-a-string objects are opened.
    static func value(_ payload: [String: JSONValue], _ path: String) -> JSONValue? {
        var current: JSONValue? = .object(payload)
        for part in path.split(separator: ".") {
            var key = Substring(part)
            var index: Int?
            if key.hasSuffix("]"), let open = key.firstIndex(of: "[") {
                index = Int(key[key.index(after: open) ..< key.index(before: key.endIndex)])
                key = key[..<open]
            }
            current = opened(current)?.objectValue?[String(key)]
            if let index { current = current?.arrayValue.flatMap { $0.indices.contains(index) ? $0[index] : nil } }
        }
        return current
    }

    static func string(_ payload: [String: JSONValue], _ paths: [String]) -> String? {
        paths.lazy.compactMap { value(payload, $0)?.stringValue }.first { !$0.isEmpty }
    }

    static func object(_ payload: [String: JSONValue], _ paths: [String]) -> [String: JSONValue]? {
        paths.lazy.compactMap { opened(value(payload, $0))?.objectValue }.first
    }

    /// A string holding a JSON object (Copilot's toolArgs) as that object.
    private static func opened(_ value: JSONValue?) -> JSONValue? {
        guard case .string(let text)? = value, text.hasPrefix("{"), text.utf8.count <= 256 * 1024,
              let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else { return value }
        var nodes = 0
        return try? JSONValue(foundation: object, depth: 1, nodes: &nodes)
    }
}

extension HookAdapter {
    private static func make(_ id: String, _ name: String, _ mapping: Mapping) -> HookAdapter {
        HookAdapter(manifest: AgentManifest(id: AgentID(id)!, displayName: name, capabilities: .observe), mapping: mapping)
    }

    /// learn.chatgpt.com/docs/hooks.md: snake_case like Claude Code; apply_patch edits name their files in the patch.
    static let codex = make("codex", "OpenAI Codex", Mapping(
        session: ["session_id"], cwd: ["cwd"], tool: ["tool_name"], toolInput: ["tool_input"], toolUse: ["tool_use_id", "turn_id"],
        files: ["file_path", "path"],
        events: ["SessionStart": .sessionStarted, "SessionEnd": .sessionEnded, "UserPromptSubmit": .promptSubmitted,
                 "PreToolUse": .toolStarted, "PostToolUse": .toolCompleted, "Stop": .turnCompleted, "Interrupt": .turnCompleted,
                 "SubagentStart": .notification, "SubagentStop": .notification, "PreCompact": .notification, "PostCompact": .notification,
                 "PermissionRequest": .waitingForUser],
        editEvents: ["PostToolUse"], editTools: ["apply_patch", "Edit", "Write"], patch: "command",
        permissionEvent: "PermissionRequest",
        allowOutput: ["hookSpecificOutput": .object(["hookEventName": .string("PermissionRequest"), "decision": .object(["behavior": .string("allow")])])],
        denyOutput: ["hookSpecificOutput": .object(["hookEventName": .string("PermissionRequest"), "decision": .object(["behavior": .string("deny")])])]))

    /// docs.github.com …/hooks-reference: camelCase; toolArgs is a JSON string.
    static let copilot = make("copilot-cli", "GitHub Copilot CLI", Mapping(
        session: ["sessionId", "session_id"], cwd: ["cwd"], tool: ["toolName", "tool_name"], toolInput: ["toolArgs", "tool_input"],
        toolUse: ["toolCallId", "tool_use_id"], files: ["path", "file_path", "filePath"],
        events: ["sessionStart": .sessionStarted, "sessionEnd": .sessionEnded, "userPromptSubmitted": .promptSubmitted,
                 "preToolUse": .toolStarted, "postToolUse": .toolCompleted, "postToolUseFailure": .toolFailed,
                 "agentStop": .turnCompleted, "subagentStart": .notification, "subagentStop": .notification,
                 "errorOccurred": .error, "notification": .notification, "preCompact": .notification,
                 "permissionRequest": .waitingForUser],
        editEvents: ["postToolUse"], editTools: ["edit", "create", "write", "str_replace_editor"], patch: nil,
        permissionEvent: "permissionRequest",
        allowOutput: ["behavior": .string("allow")], denyOutput: ["behavior": .string("deny")]))

    /// cursor.com/docs/hooks: conversation_id; file edits arrive as afterFileEdit.
    static let cursor = make("cursor", "Cursor", Mapping(
        session: ["conversation_id", "session_id"], cwd: ["cwd", "workspace_roots[0]"], tool: ["tool_name"],
        toolInput: ["tool_input"], toolUse: ["generation_id", "tool_use_id"], files: ["file_path"],
        events: ["sessionStart": .sessionStarted, "sessionEnd": .sessionEnded, "beforeSubmitPrompt": .promptSubmitted,
                 "preToolUse": .toolStarted, "postToolUse": .toolCompleted, "postToolUseFailure": .toolFailed,
                 "beforeShellExecution": .toolStarted, "afterShellExecution": .toolCompleted,
                 "beforeMCPExecution": .toolStarted, "afterMCPExecution": .toolCompleted, "beforeReadFile": .toolStarted,
                 "afterFileEdit": .fileChanged, "stop": .turnCompleted, "subagentStart": .notification, "subagentStop": .notification,
                 "preCompact": .notification],
        editEvents: ["afterFileEdit"], editTools: [], patch: nil,
        permissionEvent: "beforeShellExecution",
        allowOutput: ["permission": .string("allow")], denyOutput: ["permission": .string("deny")]))

    /// github.com/google-gemini/gemini-cli docs/hooks/reference.md (no "ask" decision; consumer use moved to Antigravity).
    static let gemini = make("gemini-cli", "Gemini CLI", Mapping(
        session: ["session_id"], cwd: ["cwd"], tool: ["tool_name"], toolInput: ["tool_input"], toolUse: ["tool_use_id"],
        files: ["file_path", "absolute_path", "path"],
        events: ["SessionStart": .sessionStarted, "SessionEnd": .sessionEnded, "BeforeAgent": .promptSubmitted,
                 "AfterAgent": .turnCompleted, "BeforeTool": .toolStarted, "AfterTool": .toolCompleted,
                 "Notification": .notification, "PreCompress": .notification],
        editEvents: ["AfterTool"], editTools: ["write_file", "replace", "edit"], patch: nil,
        permissionEvent: "BeforeTool",
        allowOutput: ["decision": .string("allow")], denyOutput: ["decision": .string("deny")]))

    /// antigravity.google/docs/hooks: conversationId, toolCall{name,args}.
    static let antigravity = make("antigravity", "Google Antigravity", Mapping(
        session: ["conversationId"], cwd: ["workspacePaths[0]", "cwd"], tool: ["toolCall.name"], toolInput: ["toolCall.args"],
        toolUse: ["stepIdx"], files: ["file_path", "path", "TargetFile", "AbsolutePath"],
        events: ["SessionStart": .sessionStarted, "PreInvocation": .promptSubmitted, "PostInvocation": .turnCompleted,
                 "PreToolUse": .toolStarted, "PostToolUse": .toolCompleted, "Stop": .turnCompleted],
        editEvents: ["PostToolUse"], editTools: [], patch: nil,
        permissionEvent: "PreToolUse",
        allowOutput: ["decision": .string("allow")], denyOutput: ["decision": .string("deny")]))
}
