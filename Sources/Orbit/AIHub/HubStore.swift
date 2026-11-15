import Foundation
import SQLite3

// AI Hub history (docs/AI_HUB_SPEC.md §7, §14): sessions and events in SQLite.
// One actor per database file (hub.sqlite for real agents, demo.sqlite for
// simulated ones); the C handle never leaves it. Nothing here is fatal: if the
// database can't be opened, migrated or written, the store reports itself
// degraded and the AI Hub carries on in memory (S2). An unreadable or
// pre-migration file is moved or copied aside under a name that's never
// reused, and never deleted (S1).

actor HubStore {
    enum Health: Equatable, Sendable {
        case closed
        case ok
        /// History isn't being saved; `reason` is safe to show.
        case degraded(String)
    }

    static let schemaVersion: Int32 = 4
    static let eventRetention: TimeInterval = 30 * 86400
    static let sessionRetention: TimeInterval = 90 * 86400
    static let approvalRetention: TimeInterval = 180 * 86400

    let url: URL
    private let clock: @Sendable () -> Date
    private var db: OpaquePointer?
    private(set) var health = Health.closed

    init(url: URL, clock: @escaping @Sendable () -> Date = { .now }) {
        self.url = url
        self.clock = clock
    }

    // MARK: Lifecycle

    /// Opens (creating the folder and file), checks, migrates and prunes.
    @discardableResult
    func open() -> Health {
        guard db == nil else { return health }
        let folder = url.deletingLastPathComponent()
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return degrade("Can't create the AI Hub folder")
        }
        var existed = FileManager.default.fileExists(atPath: path(url))
        // Checked before a normal open, which could rewrite or delete its journal files.
        if existed, !isHealthy() {
            guard moveAside(prefix: "unreadable") != nil else {
                return degrade("The history database is unreadable and couldn't be set aside")
            }
            existed = false
        }
        guard let handle = connect() else { return degrade("Can't open the history database") }
        db = handle
        do {
            try execute("PRAGMA journal_mode = WAL")
            try execute("PRAGMA foreign_keys = ON")
            try migrate(existed: existed)
            try prune()
        } catch let failure as Failure {
            close()
            return degrade(failure.reason)
        } catch {
            close()
            return degrade("The history database failed")
        }
        health = .ok
        return health
    }

    func close() {
        guard let db else { return }
        sqlite3_close_v2(db)
        self.db = nil
        if health == .ok { health = .closed }
    }

    /// Closes and deletes the database and its journal files (demo data only;
    /// Orbit never calls this for hub.sqlite).
    func removeAll() {
        close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: path(url) + suffix) }
        health = .closed
    }

    // MARK: Writing

    /// Upserts `sessions` and inserts `events` in one transaction. A failure
    /// leaves the store degraded; the next successful save restores it.
    @discardableResult
    func save(sessions: [AgentSession], events: [AgentEvent]) -> Health {
        guard db != nil else { return health }
        do {
            try execute("BEGIN IMMEDIATE")
            do {
                let upsert = """
                    INSERT INTO sessions (key, agent, native_id, title, cwd, model, status, started_at, last_event_at, ended_at,
                        origin_bundle, origin_pid)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    ON CONFLICT(key) DO UPDATE SET title = excluded.title, cwd = excluded.cwd, model = excluded.model,
                        status = excluded.status, last_event_at = excluded.last_event_at, ended_at = excluded.ended_at,
                        origin_bundle = excluded.origin_bundle, origin_pid = excluded.origin_pid
                    """
                for session in sessions {
                    try execute(upsert, [.text(session.key.description), .text(session.key.agent.rawValue),
                                         .text(session.key.nativeID), .optionalText(session.title), .optionalText(session.cwd),
                                         .optionalText(session.model), .text(session.status.rawValue),
                                         .real(session.startedAt.timeIntervalSince1970),
                                         .real(session.lastEventAt.timeIntervalSince1970),
                                         .optionalReal(session.endedAt?.timeIntervalSince1970),
                                         .optionalText(session.originBundleID), .optionalInteger(session.originPID.map(Int64.init))])
                }
                let insert = """
                    INSERT OR IGNORE INTO events (id, session_key, kind, native_name, tool, summary, files,
                        occurred_at, received_at, dedupe_key)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
                for event in events {
                    let files = event.files.isEmpty ? nil : String(decoding: try JSONEncoder().encode(event.files), as: UTF8.self)
                    try execute(insert, [.text(event.id.uuidString), .text(event.session.description), .text(event.kind.rawValue),
                                         .text(event.nativeName), .optionalText(event.tool), .optionalText(event.summary),
                                         .optionalText(files), .optionalReal(event.occurredAt?.timeIntervalSince1970),
                                         .real(event.receivedAt.timeIntervalSince1970), .text(event.dedupeKey)])
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
            health = .ok
        } catch {
            health = .degraded("History isn't being saved: the database couldn't be written")
        }
        return health
    }

    /// Records one approval outcome (audit history).
    @discardableResult
    func save(approval record: ApprovalManager.Record) -> Health {
        guard db != nil else { return health }
        do {
            try execute("""
                INSERT OR IGNORE INTO approvals (id, agent, session_key, kind, tool, summary, outcome, answer, created_at, decided_at)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                """, [.text(record.id.uuidString), .text(record.draft.session.agent.rawValue), .text(record.draft.session.description),
                       .text(record.draft.kind.rawValue), .optionalText(record.draft.tool), .text(record.draft.summary),
                       .text(record.outcome.rawValue), .optionalText(record.answer), .real(record.draft.createdAt.timeIntervalSince1970),
                       .real(record.decidedAt.timeIntervalSince1970)])
        } catch {
            health = .degraded("History isn't being saved: the database couldn't be written")
        }
        return health
    }

    // MARK: Insights (Phase 9) — real agents only: this is hub.sqlite's data

    struct AgentTotals: Equatable, Sendable {
        let agent: String
        let sessions: Int
        let events: Int
        /// Sum of each session's first-to-last event span, capped at 12 h per session.
        let activeSeconds: Double
    }

    // MARK: Weekly recap (Milestone 9)

    /// Distinct files named by events in [from, to) (the `files` JSON column; bounded scan).
    func filesTouched(from: Date, to: Date = .distantFuture, limit: Int = 20_000) -> Int {
        let rows = (try? query("SELECT files FROM events WHERE files IS NOT NULL AND received_at >= ? AND received_at < ? LIMIT ?",
                               [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970), .integer(Int64(limit))]) { $0.text(0) }) ?? []
        var paths = Set<String>()
        for json in rows {
            if let list = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) { paths.formUnion(list) }
        }
        return paths.count
    }

    /// Events received in [from, to).
    func eventCount(from: Date, to: Date) -> Int {
        (try? query("SELECT COUNT(*) FROM events WHERE received_at >= ? AND received_at < ?",
                    [.real(from.timeIntervalSince1970), .real(to.timeIntervalSince1970)]) { Int($0.integer(0)) })?.first ?? 0
    }

    /// When the recorded history starts (the oldest event kept), nil when empty.
    func firstEventAt() -> Date? {
        (try? query("SELECT MIN(received_at) FROM events", []) { $0.isNull(0) ? nil : Date(timeIntervalSince1970: $0.real(0)) })?.first
    }

    /// The longest session active since `since`: agent, project folder, first-to-last event span.
    func longestSession(since: Date) -> (agent: String, cwd: String?, seconds: Double)? {
        (try? query("""
            SELECT agent, cwd, last_event_at - started_at AS span FROM sessions
            WHERE last_event_at >= ? ORDER BY span DESC LIMIT 1
            """, [.real(since.timeIntervalSince1970)]) { ($0.text(0) ?? "", $0.text(1), $0.real(2)) })?.first
    }

    /// Events per local calendar day since `since` ("yyyy-MM-dd", count), oldest first.
    func eventsPerDay(since: Date) -> [(day: String, count: Int)] {
        (try? query("""
            SELECT date(received_at, 'unixepoch', 'localtime') AS day, COUNT(*) FROM events
            WHERE received_at >= ? GROUP BY day ORDER BY day
            """, [.real(since.timeIntervalSince1970)]) { ($0.text(0) ?? "", Int($0.integer(1))) }) ?? []
    }

    func agentTotals(since: Date) -> [AgentTotals] {
        (try? query("""
            SELECT s.agent, COUNT(DISTINCT s.key),
                   (SELECT COUNT(*) FROM events e JOIN sessions s2 ON e.session_key = s2.key WHERE s2.agent = s.agent AND e.received_at >= ?),
                   SUM(MIN(MAX(s.last_event_at - s.started_at, 0), 43200))
            FROM sessions s WHERE s.last_event_at >= ? GROUP BY s.agent ORDER BY 2 DESC
            """, [.real(since.timeIntervalSince1970), .real(since.timeIntervalSince1970)]) {
            AgentTotals(agent: $0.text(0) ?? "", sessions: Int($0.integer(1)), events: Int($0.integer(2)), activeSeconds: $0.real(3))
        }) ?? []
    }

    /// The most used tools (by tool calls started), most first.
    func toolCounts(since: Date, limit: Int = 6) -> [(tool: String, count: Int)] {
        (try? query("""
            SELECT tool, COUNT(*) FROM events WHERE tool IS NOT NULL AND kind = 'toolStarted' AND received_at >= ?
            GROUP BY tool ORDER BY 2 DESC LIMIT ?
            """, [.real(since.timeIntervalSince1970), .integer(Int64(limit))]) { ($0.text(0) ?? "", Int($0.integer(1))) }) ?? []
    }

    /// Sessions active since `since`, by their status now.
    func statusCounts(since: Date) -> [String: Int] {
        Dictionary((try? query("SELECT status, COUNT(*) FROM sessions WHERE last_event_at >= ? GROUP BY status",
                                [.real(since.timeIntervalSince1970)]) { ($0.text(0) ?? "", Int($0.integer(1))) }) ?? [], uniquingKeysWith: +)
    }

    /// The busiest project folders (by sessions), most first.
    func projectCounts(since: Date, limit: Int = 5) -> [(project: String, sessions: Int)] {
        (try? query("""
            SELECT cwd, COUNT(*) FROM sessions WHERE cwd IS NOT NULL AND last_event_at >= ? GROUP BY cwd ORDER BY 2 DESC LIMIT ?
            """, [.real(since.timeIntervalSince1970), .integer(Int64(limit))]) { ($0.text(0) ?? "", Int($0.integer(1))) }) ?? []
    }

    func approvalOutcomes(since: Date) -> [String: Int] {
        Dictionary((try? query("SELECT outcome, COUNT(*) FROM approvals WHERE decided_at >= ? GROUP BY outcome",
                                [.real(since.timeIntervalSince1970)]) { ($0.text(0) ?? "", Int($0.integer(1))) }) ?? [], uniquingKeysWith: +)
    }

    // MARK: Chat (Phase 7)

    @discardableResult
    func save(conversation: ChatConversation) -> Health {
        guard db != nil else { return health }
        do {
            try execute("BEGIN IMMEDIATE")
            do {
                try execute("""
                    INSERT INTO conversations (id, title, provider, model, created_at, updated_at) VALUES (?, ?, ?, ?, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET title = excluded.title, provider = excluded.provider, model = excluded.model,
                        updated_at = excluded.updated_at
                    """, [.text(conversation.id.uuidString), .text(conversation.title), .text(conversation.provider), .text(conversation.model),
                           .real(conversation.createdAt.timeIntervalSince1970), .real(conversation.updatedAt.timeIntervalSince1970)])
                for message in conversation.messages {
                    try execute("""
                        INSERT INTO messages (id, conversation_id, role, content, created_at) VALUES (?, ?, ?, ?, ?)
                        ON CONFLICT(id) DO UPDATE SET content = excluded.content
                        """, [.text(message.id.uuidString), .text(conversation.id.uuidString), .text(message.role.rawValue),
                               .text(message.content), .real(message.createdAt.timeIntervalSince1970)])
                }
                try execute("COMMIT")
            } catch {
                try? execute("ROLLBACK")
                throw error
            }
        } catch {
            health = .degraded("Chats aren't being saved: the database couldn't be written")
        }
        return health
    }

    /// Most recent first, with their messages.
    func conversations(limit: Int = 100) -> [ChatConversation] {
        let rows = (try? query("SELECT id, title, provider, model, created_at, updated_at FROM conversations ORDER BY updated_at DESC LIMIT ?",
                               [.integer(Int64(limit))]) { row -> ChatConversation? in
            guard let id = UUID(uuidString: row.text(0) ?? "") else { return nil }
            return ChatConversation(id: id, title: row.text(1) ?? "", provider: row.text(2) ?? "", model: row.text(3) ?? "", messages: [],
                                    createdAt: Date(timeIntervalSince1970: row.real(4)), updatedAt: Date(timeIntervalSince1970: row.real(5)))
        }) ?? []
        return rows.map { conversation in
            var conversation = conversation
            conversation.messages = (try? query("SELECT id, role, content, created_at FROM messages WHERE conversation_id = ? ORDER BY created_at, rowid",
                                                [.text(conversation.id.uuidString)]) { row -> HubChatMessage? in
                guard let id = UUID(uuidString: row.text(0) ?? ""), let role = HubChatMessage.Role(rawValue: row.text(1) ?? "") else { return nil }
                return HubChatMessage(id: id, role: role, content: row.text(2) ?? "", createdAt: Date(timeIntervalSince1970: row.real(3)))
            }) ?? []
            return conversation
        }
    }

    func deleteConversation(_ id: UUID) {
        try? execute("DELETE FROM conversations WHERE id = ?", [.text(id.uuidString)])  // its messages go with it
    }

    /// Outcomes, newest first.
    func approvals(limit: Int = 200) -> [(outcome: String, summary: String, decidedAt: Date)] {
        (try? query("SELECT outcome, summary, decided_at FROM approvals ORDER BY decided_at DESC LIMIT ?", [.integer(Int64(limit))]) { row in
            (row.text(0) ?? "", row.text(1) ?? "", Date(timeIntervalSince1970: row.real(2)))
        }) ?? []
    }

    /// Deletes events older than 30 days and sessions idle for 90 (their events go with them).
    func prune() throws {
        let now = clock().timeIntervalSince1970
        try execute("DELETE FROM sessions WHERE last_event_at < ?", [.real(now - Self.sessionRetention)])
        try execute("DELETE FROM events WHERE received_at < ?", [.real(now - Self.eventRetention)])
        try execute("DELETE FROM approvals WHERE decided_at < ?", [.real(now - Self.approvalRetention)])
    }

    // MARK: Reading

    /// Most recently active first.
    func recentSessions(limit: Int = 500) -> [AgentSession] {
        (try? query("""
            SELECT key, agent, native_id, title, cwd, model, status, started_at, last_event_at, ended_at, origin_bundle, origin_pid
            FROM sessions ORDER BY last_event_at DESC LIMIT ?
            """, [.integer(Int64(limit))]) { row in
            guard let agent = AgentID(row.text(1) ?? ""), let key = SessionKey(agent: agent, nativeID: row.text(2) ?? ""),
                  let status = AgentSession.Status(rawValue: row.text(6) ?? "") else { return nil }
            return AgentSession(key: key, title: row.text(3), cwd: row.text(4), model: row.text(5), status: status,
                                startedAt: Date(timeIntervalSince1970: row.real(7)),
                                lastEventAt: Date(timeIntervalSince1970: row.real(8)),
                                endedAt: row.isNull(9) ? nil : Date(timeIntervalSince1970: row.real(9)),
                                originBundleID: row.text(10), originPID: row.isNull(11) ? nil : Int32(truncatingIfNeeded: row.integer(11)))
        }) ?? []
    }

    /// Oldest first.
    func events(for session: SessionKey, limit: Int = 1000) -> [AgentEvent] {
        (try? query("""
            SELECT id, kind, native_name, tool, summary, files, occurred_at, received_at, dedupe_key
            FROM events WHERE session_key = ? ORDER BY received_at ASC LIMIT ?
            """, [.text(session.description), .integer(Int64(limit))]) { row in
            guard let id = UUID(uuidString: row.text(0) ?? ""), let kind = AgentEvent.Kind(rawValue: row.text(1) ?? "") else { return nil }
            let files = row.text(5).flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) } ?? []
            return AgentEvent(id: id, session: session, kind: kind, nativeName: row.text(2) ?? "", occurredAt: row.isNull(6) ? nil
                                  : Date(timeIntervalSince1970: row.real(6)),
                              receivedAt: Date(timeIntervalSince1970: row.real(7)), cwd: nil, tool: row.text(3),
                              summary: row.text(4), files: files, dedupeKey: row.text(8) ?? "")
        }) ?? []
    }

    func counts() -> (sessions: Int, events: Int) {
        let sessions = (try? query("SELECT COUNT(*) FROM sessions", []) { Int($0.integer(0)) }.first) ?? 0
        let events = (try? query("SELECT COUNT(*) FROM events", []) { Int($0.integer(0)) }.first) ?? 0
        return (sessions, events)
    }

    // MARK: Schema

    private func migrate(existed: Bool) throws {
        let version = try query("PRAGMA user_version", []) { Int32($0.integer(0)) }.first ?? 0
        guard version <= Self.schemaVersion else {
            throw Failure("The history database is from a newer Orbit; it's left untouched")
        }
        guard version < Self.schemaVersion else { return }
        if existed, backupCopy(version: version) == nil { throw Failure("Couldn't back up the history database before updating it") }
        try execute("BEGIN IMMEDIATE")
        do {
            if version < 1 {
                try execute("""
                    CREATE TABLE sessions (
                      key TEXT PRIMARY KEY, agent TEXT NOT NULL, native_id TEXT NOT NULL,
                      title TEXT, cwd TEXT, model TEXT, status TEXT NOT NULL,
                      started_at REAL NOT NULL, last_event_at REAL NOT NULL, ended_at REAL)
                    """)
                try execute("CREATE INDEX sessions_recent ON sessions(last_event_at DESC)")
                try execute("CREATE INDEX sessions_agent ON sessions(agent, status)")
                try execute("""
                    CREATE TABLE events (
                      id TEXT PRIMARY KEY,
                      session_key TEXT NOT NULL REFERENCES sessions(key) ON DELETE CASCADE,
                      kind TEXT NOT NULL, native_name TEXT NOT NULL, tool TEXT, summary TEXT, files TEXT,
                      occurred_at REAL, received_at REAL NOT NULL, dedupe_key TEXT NOT NULL)
                    """)
                try execute("CREATE INDEX events_session ON events(session_key, received_at)")
                try execute("CREATE INDEX events_received ON events(received_at)")
            }
            if version < 2 {  // Phase 3: where a session runs, for "open the terminal"
                try execute("ALTER TABLE sessions ADD COLUMN origin_bundle TEXT")
                try execute("ALTER TABLE sessions ADD COLUMN origin_pid INTEGER")
            }
            if version < 3 {  // Phase 4: the approval audit history (no prompt or command text beyond the redacted summary)
                try execute("""
                    CREATE TABLE approvals (
                      id TEXT PRIMARY KEY, agent TEXT NOT NULL, session_key TEXT NOT NULL, kind TEXT NOT NULL,
                      tool TEXT, summary TEXT, outcome TEXT NOT NULL, answer TEXT, created_at REAL NOT NULL, decided_at REAL NOT NULL)
                    """)
                try execute("CREATE INDEX approvals_recent ON approvals(decided_at DESC)")
            }
            if version < 4 {  // Phase 7: chat conversations (used by chat.sqlite)
                try execute("""
                    CREATE TABLE conversations (
                      id TEXT PRIMARY KEY, title TEXT NOT NULL, provider TEXT NOT NULL, model TEXT NOT NULL,
                      created_at REAL NOT NULL, updated_at REAL NOT NULL)
                    """)
                try execute("""
                    CREATE TABLE messages (
                      id TEXT PRIMARY KEY, conversation_id TEXT NOT NULL REFERENCES conversations(id) ON DELETE CASCADE,
                      role TEXT NOT NULL, content TEXT NOT NULL, created_at REAL NOT NULL)
                    """)
                try execute("CREATE INDEX messages_conversation ON messages(conversation_id, created_at)")
            }
            try execute("PRAGMA user_version = \(Self.schemaVersion)")
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    // MARK: Recovery (S1)

    /// Moves the database and its journal files aside; the name is new.
    private func moveAside(prefix: String) -> URL? {
        guard let target = freeName(prefix) else { return nil }
        do {
            try FileManager.default.moveItem(at: url, to: target)  // refuses to replace an existing file
        } catch {
            return nil
        }
        var moved: [String] = []
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: path(url) + suffix) {
            do {
                try FileManager.default.moveItem(atPath: path(url) + suffix, toPath: path(target) + suffix)
                moved.append(suffix)
            } catch {
                // A journal left behind would be deleted by a fresh database here: put everything back and give up.
                for suffix in moved { try? FileManager.default.moveItem(atPath: path(target) + suffix, toPath: path(url) + suffix) }
                try? FileManager.default.moveItem(at: target, to: url)
                return nil
            }
        }
        return target
    }

    /// A consistent copy before a migration (`VACUUM INTO` refuses an existing file).
    private func backupCopy(version: Int32) -> URL? {
        guard let target = freeName("backup-v\(version)") else { return nil }
        let quoted = path(target).replacingOccurrences(of: "'", with: "''")
        return (try? execute("VACUUM INTO '\(quoted)'")) == nil ? nil : target
    }

    /// `<name>.<prefix>-<yyyyMMdd-HHmmss>[-n].sqlite`, the first that doesn't exist.
    private func freeName(_ prefix: String) -> URL? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = "\(url.deletingPathExtension().lastPathComponent).\(prefix)-\(formatter.string(from: clock()))"
        let folder = url.deletingLastPathComponent()
        for n in 0 ..< 1000 {
            let candidate = folder.appending(path: n == 0 ? "\(base).sqlite" : "\(base)-\(n).sqlite")
            let taken = ["", "-wal", "-shm"].contains { FileManager.default.fileExists(atPath: path(candidate) + $0) }
            if !taken { return candidate }
        }
        return nil
    }

    // MARK: SQLite

    private struct Failure: Error {
        let reason: String
        init(_ reason: String) { self.reason = reason }
    }

    enum Value {
        case text(String), optionalText(String?), real(Double), optionalReal(Double?), integer(Int64), optionalInteger(Int64?)
    }

    struct Row {
        fileprivate let statement: OpaquePointer
        func text(_ column: Int32) -> String? { sqlite3_column_text(statement, column).map { String(cString: $0) } }
        func real(_ column: Int32) -> Double { sqlite3_column_double(statement, column) }
        func integer(_ column: Int32) -> Int64 { sqlite3_column_int64(statement, column) }
        func isNull(_ column: Int32) -> Bool { sqlite3_column_type(statement, column) == SQLITE_NULL }
    }

    private func degrade(_ reason: String) -> Health {
        health = .degraded(reason)
        return health
    }

    private func connect() -> OpaquePointer? {
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path(url), &handle, flags, nil) == SQLITE_OK, let handle else {
            sqlite3_close_v2(handle)
            return nil
        }
        sqlite3_busy_timeout(handle, 1000)
        chmod(path(url), 0o600)
        return handle
    }

    /// `PRAGMA quick_check` on the file opened immutable and read-only, so
    /// nothing (the file, its -wal or -shm) is written or removed by checking.
    /// A file that isn't a database fails here.
    private func isHealthy() -> Bool {
        var handle: OpaquePointer?
        var statement: OpaquePointer?
        defer {
            sqlite3_finalize(statement)
            sqlite3_close_v2(handle)
        }
        let uri = URL(filePath: path(url)).absoluteString + "?immutable=1"
        guard sqlite3_open_v2(uri, &handle, SQLITE_OPEN_READONLY | SQLITE_OPEN_URI, nil) == SQLITE_OK, let handle,
              sqlite3_prepare_v2(handle, "PRAGMA quick_check", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW, let text = sqlite3_column_text(statement, 0) else { return false }
        return String(cString: text) == "ok"
    }

    private func execute(_ sql: String, _ values: [Value] = []) throws {
        _ = try query(sql, values) { _ in () }
    }

    private func query<T>(_ sql: String, _ values: [Value], _ map: (Row) -> T?) throws -> [T] {
        guard let db else { throw Failure("The history database is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw Failure("The history database rejected a statement")
        }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        for (index, value) in values.enumerated() {
            let position = Int32(index + 1)
            switch value {
            case .text(let text): sqlite3_bind_text(statement, position, text, -1, transient)
            case .optionalText(let text?): sqlite3_bind_text(statement, position, text, -1, transient)
            case .real(let number): sqlite3_bind_double(statement, position, number)
            case .optionalReal(let number?): sqlite3_bind_double(statement, position, number)
            case .integer(let number), .optionalInteger(let number?): sqlite3_bind_int64(statement, position, number)
            case .optionalText(nil), .optionalReal(nil), .optionalInteger(nil): sqlite3_bind_null(statement, position)
            }
        }
        var rows: [T] = []
        while true {
            switch sqlite3_step(statement) {
            case SQLITE_ROW: if let row = map(Row(statement: statement)) { rows.append(row) }
            case SQLITE_DONE: return rows
            default: throw Failure("The history database couldn't be read or written")
            }
        }
    }

    private nonisolated func path(_ url: URL) -> String { url.path(percentEncoded: false) }
}
