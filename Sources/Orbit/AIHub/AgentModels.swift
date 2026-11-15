import Foundation
import OrbitBridge

// AI Hub (Phase 1): the normalised vocabulary every agent adapter maps into
// (docs/AI_HUB_SPEC.md §5, §14). Value types only: nothing here talks to an
// agent, a socket or a database.

/// An agent's identifier, e.g. "claude-code". 1–32 of a–z, 0–9 and "-";
/// the `demo-` prefix is reserved for Orbit's simulated agents.
struct AgentID: Hashable, Codable, Sendable, CustomStringConvertible {
    static let demoPrefix = "demo-"
    let rawValue: String

    init?(_ rawValue: String) {
        guard AgentEnvelope.isValidAgentID(rawValue) else { return nil }  // one rule for the bridge and Orbit
        self.rawValue = rawValue
    }

    /// Simulated: never mixed with real agents' data (§14, P1-2).
    var isDemo: Bool { rawValue.hasPrefix(Self.demoPrefix) }
    var description: String { rawValue }

    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        guard let id = AgentID(try container.decode(String.self)) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Invalid agent ID")
        }
        self = id
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

/// One agent session: the agent plus the agent's own session ID.
struct SessionKey: Hashable, Codable, Sendable, CustomStringConvertible {
    static let maxNativeIDLength = 128
    let agent: AgentID
    let nativeID: String

    /// nil for an empty, overlong or control-character native ID.
    init?(agent: AgentID, nativeID: String) {
        guard !nativeID.isEmpty, nativeID.count <= Self.maxNativeIDLength,
              !nativeID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        self.agent = agent
        self.nativeID = nativeID
    }

    /// Stable text form, e.g. "claude-code:3f2a…" (the store's primary key).
    var description: String { "\(agent):\(nativeID)" }

    private enum CodingKeys: String, CodingKey { case agent, nativeID }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let agent = try container.decode(AgentID.self, forKey: .agent)
        guard let key = SessionKey(agent: agent, nativeID: try container.decode(String.self, forKey: .nativeID)) else {
            throw DecodingError.dataCorruptedError(forKey: .nativeID, in: container, debugDescription: "Invalid native session ID")
        }
        self = key
    }
}

/// What an agent may be asked to do through Orbit. A capability is added only
/// by the phase that implements and verifies it (§4); Phase 1 observes.
struct AgentCapabilities: OptionSet, Hashable, Codable, Sendable {
    let rawValue: Int
    static let observe = AgentCapabilities(rawValue: 1 << 0)
    /// Allow once / deny through Orbit (Milestone 4, §23): only adapters verified end to end declare it.
    static let answerPermissions = AgentCapabilities(rawValue: 1 << 1)
    /// Questions (choices, or structured questions) answered through Orbit; same rule.
    static let answerQuestions = AgentCapabilities(rawValue: 1 << 2)
}

/// What an adapter declares about its agent.
struct AgentManifest: Equatable, Sendable {
    let id: AgentID
    let displayName: String
    let capabilities: AgentCapabilities
}

/// A normalised event. Phase 1 has observation kinds only: permission and
/// question requests arrive with the Approval Center (Phase 4; never for
/// Claude Code under D1).
struct AgentEvent: Identifiable, Equatable, Sendable {
    /// Raw values are stored in the database: never rename one.
    enum Kind: String, Codable, CaseIterable, Sendable {
        case sessionStarted, sessionEnded, promptSubmitted, turnCompleted
        case toolStarted, toolCompleted, toolFailed, fileChanged
        case notification, error
        /// The agent says it's waiting for the user (a prompt or question in
        /// its own UI). Always inferred from what it reports; Orbit can't answer.
        case waitingForUser
    }

    let id: UUID
    let session: SessionKey
    let kind: Kind
    /// The agent's own name for it, e.g. "PostToolUse".
    let nativeName: String
    /// When the agent says it happened, if it does.
    let occurredAt: Date?
    let receivedAt: Date
    let cwd: String?
    let tool: String?
    /// One redacted line, at most.
    let summary: String?
    /// Absolute paths.
    let files: [String]
    /// Equal keys within the dedupe window are one event.
    let dedupeKey: String
    /// Where the hook ran (from the envelope; never trusted beyond display and
    /// "open the app"). Set by the bridge, not the adapter.
    var origin: AgentOrigin?
}

/// The app an agent session runs in, as reported by its hook helper.
struct AgentOrigin: Equatable, Sendable {
    var bundleID: String?
    var pid: Int32?
}

struct AgentSession: Identifiable, Equatable, Sendable {
    /// Raw values are stored in the database: never rename one.
    enum Status: String, Codable, CaseIterable, Sendable {
        case running, idle, completed, failed, ended, stale
        /// Inferred from `waitingForUser`: shown as "waiting in the terminal".
        case waiting

        var isActive: Bool { self == .running || self == .idle || self == .waiting }
    }

    let key: SessionKey
    var title: String?
    var cwd: String?
    var model: String?
    var status: Status
    let startedAt: Date
    var lastEventAt: Date
    var endedAt: Date?
    /// The terminal or editor app (bundle ID) and the hook's parent process.
    var originBundleID: String?
    var originPID: Int32?

    var id: SessionKey { key }
    var isDemo: Bool { key.agent.isDemo }
}

