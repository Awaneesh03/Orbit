import Foundation
import OrbitBridge

// AI Hub adapters (docs/AI_HUB_SPEC.md §4): each maps one agent's hook
// payloads into AgentEvents. Adapters are pure and Sendable: they run on the
// bridge's queue, never the main thread (P1-4), and everything they extract
// from a payload is sanitised here, because payloads are untrusted.

protocol AgentAdapter: Sendable {
    var manifest: AgentManifest { get }
    /// Whether this adapter speaks for `agent` (by default, its manifest's ID).
    func accepts(_ agent: AgentID) -> Bool
    /// The events in one envelope; empty when it can't be attributed to a session.
    func normalise(_ envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> [AgentEvent]
    // Requirements (not just extension methods), so adapters' own versions are called through `any AgentAdapter`.
    func approval(from envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> ApprovalDraft?
    func output(for decision: ApprovalDecision, to draft: ApprovalDraft) -> [String: JSONValue]?
}

extension AgentAdapter {
    func accepts(_ agent: AgentID) -> Bool { agent == manifest.id }
    /// A blocking request as an approval (Phase 4); nil: this adapter can't be answered.
    func approval(from envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> ApprovalDraft? { nil }
    /// The agent's own hook output for a decision; nil prints nothing (the agent asks the user itself).
    func output(for decision: ApprovalDecision, to draft: ApprovalDraft) -> [String: JSONValue]? { nil }
}

/// A request waiting for the user, as the bridge hands it over.
struct ApprovalDraft: Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case permission, question }
    let session: SessionKey
    let kind: Kind
    let nativeName: String
    let tool: String?
    let summary: String
    /// A question's choices (permissions: allow once / deny only).
    let options: [String]
    let createdAt: Date
    /// When Orbit stops offering it (before the helper gives up).
    let expiresAt: Date
    /// Exactly what would be allowed: the full input (redacted, every line, capped with a visible marker).
    var detail: String? = nil
    /// Structured questions (§23): several, each with labelled choices; empty for a plain choice or a permission.
    var questions: [ApprovalQuestion] = []

    /// The capability an adapter needs to answer this request.
    var capability: AgentCapabilities { kind == .permission ? .answerPermissions : .answerQuestions }
}

/// One structured question: a short unique header, the question, its choices.
struct ApprovalQuestion: Equatable, Sendable {
    struct Option: Equatable, Sendable {
        let label: String
        var detail: String? = nil
    }

    static let maxQuestions = 4
    static let maxOptions = 6

    let header: String
    let prompt: String
    let options: [Option]
    var multiSelect = false

    /// Untrusted payload → questions: objects with `header`, `question`, `options` (strings or
    /// `{label, description}`) and `multiSelect`. Every text is one redacted line; headers and labels
    /// must be unique; anything malformed is dropped, and nothing left means no structured question.
    static func parse(_ value: JSONValue?) -> [ApprovalQuestion] {
        var seen = Set<String>()
        return (value?.arrayValue ?? []).prefix(maxQuestions * 2).compactMap { item -> ApprovalQuestion? in
            guard let object = item.objectValue, let header = Redactor.line(object["header"]?.stringValue, limit: 40),
                  let prompt = Redactor.line(object["question"]?.stringValue, limit: 200), seen.insert(header).inserted else { return nil }
            var labels = Set<String>()
            let options = (object["options"]?.arrayValue ?? []).compactMap { option -> Option? in
                let label = Redactor.line(option.stringValue ?? option.objectValue?["label"]?.stringValue, limit: 60)
                guard let label, labels.insert(label).inserted else { return nil }
                return Option(label: label, detail: Redactor.line(option.objectValue?["description"]?.stringValue, limit: 120))
            }
            guard options.count >= 2 else { return nil }
            if case .bool(true) = object["multiSelect"] {
                return ApprovalQuestion(header: header, prompt: prompt, options: Array(options.prefix(maxOptions)), multiSelect: true)
            }
            return ApprovalQuestion(header: header, prompt: prompt, options: Array(options.prefix(maxOptions)))
        }
        .prefix(maxQuestions).map { $0 }
    }

    /// True when `answers` answers every question exactly: offered labels only, one each unless multi-select, nothing extra.
    static func valid(_ answers: [String: [String]], for questions: [ApprovalQuestion]) -> Bool {
        guard !questions.isEmpty, Set(answers.keys) == Set(questions.map(\.header)) else { return false }
        return questions.allSatisfy { question in
            let chosen = answers[question.header] ?? []
            let offered = Set(question.options.map(\.label))
            return !chosen.isEmpty && Set(chosen).count == chosen.count && chosen.allSatisfy(offered.contains)
                && (question.multiSelect || chosen.count == 1)
        }
    }

    /// For the audit history: "Database: SQLite; Extras: Seed data, Indexes".
    static func describe(_ answers: [String: [String]], for questions: [ApprovalQuestion]) -> String {
        questions.map { "\($0.header): \((answers[$0.header] ?? []).joined(separator: ", "))" }.joined(separator: "; ")
    }
}

extension Redactor {
    /// Multi-line text kept multi-line, every line redacted, capped with a visible marker.
    static func block(_ value: String?, limit: Int = 2000) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let lines = value.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            redact(String(line.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) && $0 != "\t" ? " " : String($0) }.joined()))
        }
        let text = lines.joined(separator: "\n")
        return text.count > limit ? String(text.prefix(limit)) + "\n… (\(text.count - limit) more characters not shown)" : text
    }
}

enum ApprovalDecision: Equatable, Sendable {
    case allowOnce, deny
    case answer(String)
    /// Structured questions: chosen labels by question header.
    case answers([String: [String]])
}

struct AgentRegistry: Sendable {
    let adapters: [any AgentAdapter]

    /// Phase 1: Orbit's own vocabulary, for the simulated agents only.
    static let phaseOne = AgentRegistry(adapters: [OrbitEventAdapter.demo])
    /// Every implemented adapter (Claude Code observe-only; the hook agents of Phase 6).
    static let standard = AgentRegistry(adapters: [
        ClaudeCodeAdapter(), HookAdapter.codex, HookAdapter.copilot, HookAdapter.cursor, HookAdapter.gemini, HookAdapter.antigravity,
        OrbitEventAdapter.demo,
    ])

    func adapter(for agent: AgentID) -> (any AgentAdapter)? { adapters.first { $0.accepts(agent) } }
}

/// Orbit's own event vocabulary: the event name is an `AgentEvent.Kind` and
/// the payload carries `session_id`, and optionally `cwd`, `tool`, `summary`,
/// `files` and `event_id`. Used by the demo agents (and the basis of a
/// generic adapter later, Phase 12).
struct OrbitEventAdapter: AgentAdapter {
    let manifest: AgentManifest
    private let matches: @Sendable (AgentID) -> Bool

    static let demo = OrbitEventAdapter(
        // Verified end to end with the simulated agents (Phase 4, §23): the only adapter that may be answered today.
        manifest: AgentManifest(id: AgentID("demo-agent")!, displayName: "Simulated agent",
                                capabilities: [.observe, .answerPermissions, .answerQuestions]),
        matches: { $0.isDemo })

    func accepts(_ agent: AgentID) -> Bool { matches(agent) }

    func normalise(_ envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> [AgentEvent] {
        let payload = envelope.payload
        guard let kind = AgentEvent.Kind(rawValue: envelope.event),
              let session = payload["session_id"]?.stringValue.flatMap({ SessionKey(agent: agent, nativeID: $0) })
        else { return [] }
        let files = (payload["files"]?.arrayValue ?? []).prefix(50).compactMap { AgentEnvelope.sanitizedPath($0.stringValue) }
        let discriminator = payload["event_id"]?.stringValue.flatMap { Redactor.line($0, limit: 64) }
            ?? String(Int64(envelope.sentAt.timeIntervalSince1970 * 1000))
        return [AgentEvent(
            id: UUID(), session: session, kind: kind, nativeName: envelope.event, occurredAt: envelope.sentAt,
            receivedAt: receivedAt, cwd: AgentEnvelope.sanitizedPath(payload["cwd"]?.stringValue),
            tool: Redactor.line(payload["tool"]?.stringValue, limit: 64),
            summary: Redactor.line(payload["summary"]?.stringValue, limit: 200), files: Array(files),
            dedupeKey: "\(session)|\(envelope.event)|\(discriminator)")]
    }

    /// `permissionRequested` / `questionAsked` requests, with `tool`, `summary` and `options`.
    func approval(from envelope: AgentEnvelope, agent: AgentID, receivedAt: Date) -> ApprovalDraft? {
        let payload = envelope.payload
        guard envelope.kind == .request, let deadline = envelope.deadline,
              let kind = ["permissionRequested": ApprovalDraft.Kind.permission, "questionAsked": .question][envelope.event],
              let session = payload["session_id"]?.stringValue.flatMap({ SessionKey(agent: agent, nativeID: $0) }) else { return nil }
        let options = (payload["options"]?.arrayValue ?? []).prefix(8).compactMap { Redactor.line($0.stringValue, limit: 60) }
        let questions = kind == .question ? ApprovalQuestion.parse(payload["questions"]) : []
        guard kind == .permission || !options.isEmpty || !questions.isEmpty else { return nil }
        return ApprovalDraft(session: session, kind: kind, nativeName: envelope.event, tool: Redactor.line(payload["tool"]?.stringValue, limit: 64),
                             summary: Redactor.line(payload["summary"]?.stringValue, limit: 200) ?? envelope.event,
                             options: kind == .question && questions.isEmpty ? options : [], createdAt: receivedAt,
                             expiresAt: min(deadline, receivedAt.addingTimeInterval(AgentEnvelope.maxWait)).addingTimeInterval(-2),
                             questions: questions)
    }

    func output(for decision: ApprovalDecision, to draft: ApprovalDraft) -> [String: JSONValue]? {
        switch (draft.kind, decision) {
        case (.permission, .allowOnce): ["decision": .string("allow")]
        case (.permission, .deny): ["decision": .string("deny")]
        case (.question, .answer(let text)) where draft.options.contains(text): ["answer": .string(text)]
        case (.question, .answers(let answers)) where ApprovalQuestion.valid(answers, for: draft.questions):
            ["answers": .object(answers.mapValues { .array($0.map(JSONValue.string)) })]
        default: nil
        }
    }
}

/// Makes agent text safe to show and store: one line, no control characters,
/// capped, with likely secrets replaced by "[redacted]".
enum Redactor {
    static let mask = "[redacted]"

    private nonisolated(unsafe) static let patterns: [(NSRegularExpression, String)] = [
        (#"-----BEGIN [A-Z ]*PRIVATE KEY-----.*"#, mask),  // the key's body too (text here is one line)
        (#"(?i)\b(authorization)(\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s'"]+"#, "$1$2\(mask)"),
        (#"(?i)\b(bearer)\s+[^\s'"]+"#, "$1 \(mask)"),
        // GITHUB_TOKEN=…, DATABASE_PASSWORD: …, "password":"…", api-key=…
        (#"(?i)([\w-]*(?:password|passwd|pwd|secret|token|api[_-]?key|access[_-]?key)[\w-]*["']?)(\s*[=:]\s*["']?)[^\s"',]+"#, "$1$2\(mask)"),
        (#"sk-[A-Za-z0-9_\-]{12,}"#, mask),
        (#"gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}"#, mask),
        (#"xox[abprs]-[A-Za-z0-9\-]{10,}"#, mask),
        (#"AKIA[0-9A-Z]{16}"#, mask),
        (#"AIza[0-9A-Za-z_\-]{30,}"#, mask),
    ].map { (try! NSRegularExpression(pattern: $0.0), $0.1) }

    static func redact(_ text: String) -> String {
        patterns.reduce(text) { text, entry in
            entry.0.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: entry.1)
        }
    }

    /// One line of at most `limit` characters, or nil if nothing's left.
    static func line(_ value: String?, limit: Int) -> String? {
        guard let value else { return nil }
        let flat = value.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let redacted = redact(String(flat.prefix(limit * 2)))  // redact before cutting, so a secret isn't left half-visible
        let capped = redacted.count > limit ? String(redacted.prefix(limit - 1)) + "…" : redacted
        return capped.isEmpty ? nil : capped
    }
}
