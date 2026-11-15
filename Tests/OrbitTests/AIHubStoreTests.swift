import Foundation
import SQLite3
import Synchronization
import Testing
@testable import Orbit

// AI Hub Phase 1, step 4: the SQLite store. Throwaway folders; a settable clock.

private final class Clock: Sendable {
    private let time = Mutex(Date(timeIntervalSince1970: 1_763_040_000))
    var now: Date { time.withLock { $0 } }
    func advance(_ seconds: TimeInterval) { time.withLock { $0 += seconds } }
}

private func store(_ temp: TemporaryDirectory, _ clock: Clock, name: String = "hub.sqlite") -> HubStore {
    HubStore(url: temp.url.appending(path: "AIHub/\(name)"), clock: { clock.now })
}

private func session(_ native: String, agent: String = "claude-code", at time: Date, status: AgentSession.Status = .running) -> AgentSession {
    AgentSession(key: SessionKey(agent: AgentID(agent)!, nativeID: native)!, title: "Fix \(native)", cwd: "/Users/me/p",
                 model: nil, status: status, startedAt: time, lastEventAt: time)
}

private func event(_ session: AgentSession, _ kind: AgentEvent.Kind, at time: Date, files: [String] = []) -> AgentEvent {
    AgentEvent(id: UUID(), session: session.key, kind: kind, nativeName: "PostToolUse", occurredAt: time, receivedAt: time,
               cwd: nil, tool: "Edit", summary: "Edit main.swift", files: files, dedupeKey: "\(session.key)|\(UUID())")
}

private func files(_ temp: TemporaryDirectory) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: temp.url.appending(path: "AIHub").path(percentEncoded: false)).sorted()) ?? []
}

// MARK: Opening and saving

@Test func aFreshStoreCreatesSchemaOneAndRoundTrips() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let hub = store(temp, clock)
    #expect(await hub.open() == .ok)
    var first = session("s1", at: clock.now)
    let edit = event(first, .fileChanged, at: clock.now, files: ["/Users/me/p/a.swift", "/Users/me/p/b.swift"])
    #expect(await hub.save(sessions: [first], events: [edit]) == .ok)
    first.status = .completed
    first.endedAt = clock.now.addingTimeInterval(60)
    first.lastEventAt = clock.now.addingTimeInterval(60)
    #expect(await hub.save(sessions: [first], events: [edit]) == .ok)  // upsert; the same event isn't duplicated
    await hub.close()
    #expect(!files(temp).contains { $0.contains("backup") })  // nothing to back up for a new file

    let reopened = store(temp, clock)
    #expect(await reopened.open() == .ok)
    #expect(await reopened.recentSessions() == [first])
    let events = await reopened.events(for: first.key)
    #expect(events.count == 1 && events[0].files == edit.files && events[0].kind == .fileChanged && events[0].summary == edit.summary)
    #expect(await reopened.counts() == (1, 1))
    await reopened.close()
    let attributes = try FileManager.default.attributesOfItem(atPath: temp.url.appending(path: "AIHub/hub.sqlite").path(percentEncoded: false))
    #expect((attributes[.posixPermissions] as? Int) == 0o600)
}

@Test func retentionKeepsThirtyDaysOfEventsAndNinetyOfSessions() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let hub = store(temp, clock)
    await hub.open()
    let old = session("old", at: clock.now)
    let busy = session("busy", at: clock.now)
    await hub.save(sessions: [old, busy], events: [event(old, .toolStarted, at: clock.now), event(busy, .toolStarted, at: clock.now)])
    clock.advance(31 * 86400)
    var updated = busy
    updated.lastEventAt = clock.now
    await hub.save(sessions: [updated], events: [event(busy, .toolCompleted, at: clock.now)])
    try await hub.prune()
    #expect(await hub.counts() == (2, 1))  // both sessions kept; the 31-day-old events gone
    clock.advance(60 * 86400)  // `old` idle 91 days, `busy` 60
    try await hub.prune()
    #expect(await hub.recentSessions().map(\.key.nativeID) == ["busy"])
    await hub.close()
}

// MARK: Recovery (S1) and degraded mode (S2)

@Test func anUnreadableDatabaseIsMovedAsideUnderAFreshNameNeverOverwritten() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let folder = temp.url.appending(path: "AIHub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let garbage = Data("this is not a database, just bytes".utf8)
    for round in 0 ..< 3 {  // same second each time: the names must still differ
        try garbage.write(to: folder.appending(path: "hub.sqlite"))
        try Data("wal \(round)".utf8).write(to: folder.appending(path: "hub.sqlite-wal"))
        let hub = store(temp, clock)
        #expect(await hub.open() == .ok)
        await hub.save(sessions: [session("s\(round)", at: clock.now)], events: [])
        await hub.close()
        try FileManager.default.removeItem(at: folder.appending(path: "hub.sqlite-wal"))  // the fresh store's own
        try? FileManager.default.removeItem(at: folder.appending(path: "hub.sqlite-shm"))
    }
    let aside = files(temp).filter { $0.contains("unreadable") && !$0.hasSuffix("-wal") }
    #expect(aside == ["hub.unreadable-20251113-132000-1.sqlite", "hub.unreadable-20251113-132000-2.sqlite",
                      "hub.unreadable-20251113-132000.sqlite"])
    for name in aside {
        #expect(try Data(contentsOf: folder.appending(path: name)) == garbage)  // the original bytes, untouched
    }
    #expect(try Data(contentsOf: folder.appending(path: "hub.unreadable-20251113-132000-2.sqlite-wal")) == Data("wal 2".utf8))
}

@Test func aDatabaseFromANewerOrbitIsLeftAloneAndTheStoreDegrades() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let hub = store(temp, clock)
    await hub.open()
    await hub.close()
    let path = temp.url.appending(path: "AIHub/hub.sqlite").path(percentEncoded: false)
    var db: OpaquePointer?
    sqlite3_open(path, &db)
    sqlite3_exec(db, "PRAGMA user_version = 99", nil, nil, nil)
    sqlite3_close(db)
    let before = try Data(contentsOf: URL(filePath: path))
    let newer = store(temp, clock)
    guard case .degraded = await newer.open() else { Issue.record("expected degraded"); return }
    #expect(await newer.save(sessions: [session("s", at: clock.now)], events: []) != .ok)  // memory only
    #expect(try Data(contentsOf: URL(filePath: path)) == before)
}

@Test func anOlderDatabaseIsBackedUpBeforeItsMigration() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let folder = temp.url.appending(path: "AIHub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(folder.appending(path: "hub.sqlite").path(percentEncoded: false), &db)
    sqlite3_exec(db, "CREATE TABLE note (text TEXT); INSERT INTO note VALUES ('kept')", nil, nil, nil)  // version 0, with data
    sqlite3_close(db)
    let hub = store(temp, clock)
    #expect(await hub.open() == .ok)
    await hub.close()
    let backups = files(temp).filter { $0.contains("backup-v0") }
    #expect(backups == ["hub.backup-v0-20251113-132000.sqlite"])
    var copy: OpaquePointer?
    sqlite3_open(folder.appending(path: backups[0]).path(percentEncoded: false), &copy)
    var statement: OpaquePointer?
    sqlite3_prepare_v2(copy, "SELECT text FROM note", -1, &statement, nil)
    #expect(sqlite3_step(statement) == SQLITE_ROW && String(cString: sqlite3_column_text(statement, 0)) == "kept")
    sqlite3_finalize(statement)
    sqlite3_close(copy)
}

@Test func anUnavailableLocationLeavesTheStoreDegradedNotCrashed() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    try Data("a file where the folder should be".utf8).write(to: temp.url.appending(path: "AIHub"))
    let hub = store(temp, Clock())
    guard case .degraded(let reason) = await hub.open() else { Issue.record("expected degraded"); return }
    #expect(!reason.isEmpty)
    #expect(await hub.save(sessions: [session("s", at: .now)], events: []) == .degraded(reason))
    #expect(await hub.recentSessions().isEmpty)
}

@Test func theDemoStoreCanBeRemovedCompletely() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let real = store(temp, clock)
    let demo = store(temp, clock, name: "demo.sqlite")
    await real.open()
    await demo.open()
    await real.save(sessions: [session("r", at: clock.now)], events: [])
    await demo.save(sessions: [session("d", agent: "demo-alpha", at: clock.now)], events: [])
    await demo.removeAll()
    #expect(!files(temp).contains { $0.hasPrefix("demo") })
    #expect(await real.recentSessions().map(\.key.nativeID) == ["r"])  // real history untouched
    await real.close()
}

@Test func schemaOneIsMigratedToTwoAfterABackup() async throws {
    let temp = TemporaryDirectory()
    defer { temp.cleanup() }
    let clock = Clock()
    let folder = temp.url.appending(path: "AIHub")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    var db: OpaquePointer?
    sqlite3_open(folder.appending(path: "hub.sqlite").path(percentEncoded: false), &db)
    sqlite3_exec(db, """
        CREATE TABLE sessions (key TEXT PRIMARY KEY, agent TEXT NOT NULL, native_id TEXT NOT NULL, title TEXT, cwd TEXT, model TEXT,
          status TEXT NOT NULL, started_at REAL NOT NULL, last_event_at REAL NOT NULL, ended_at REAL);
        CREATE TABLE events (id TEXT PRIMARY KEY, session_key TEXT NOT NULL REFERENCES sessions(key) ON DELETE CASCADE, kind TEXT NOT NULL,
          native_name TEXT NOT NULL, tool TEXT, summary TEXT, files TEXT, occurred_at REAL, received_at REAL NOT NULL, dedupe_key TEXT NOT NULL);
        INSERT INTO sessions VALUES ('codex:v1', 'codex', 'v1', 'Old', '/p', NULL, 'ended', 1763040000, 1763040000, 1763040000);
        PRAGMA user_version = 1;
        """, nil, nil, nil)
    sqlite3_close(db)
    let hub = store(temp, clock)
    #expect(await hub.open() == .ok)
    #expect(files(temp).contains("hub.backup-v1-20251113-132000.sqlite"))
    var old = try #require(await hub.recentSessions().first)
    #expect(old.key.description == "codex:v1" && old.originBundleID == nil)
    old.originBundleID = "com.apple.Terminal"
    old.originPID = 4242
    await hub.save(sessions: [old], events: [])
    await hub.close()
    let reopened = store(temp, clock)
    await reopened.open()
    let saved = await reopened.recentSessions().first
    #expect(saved?.originBundleID == "com.apple.Terminal" && saved?.originPID == 4242)
    await reopened.close()
}
