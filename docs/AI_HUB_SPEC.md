# Orbit AI Hub — Technical Specification

The single authoritative document for the AI Hub. Orbit's general spec stays
in `PROJECT_SPEC.md`; this file covers only the AI Hub.

| Phase | Title | Status |
|---|---|---|
| 0 | Architecture and compatibility audit | **Approved and closed** (2026-11-13); decisions in §13 |
| 1 | Foundation | **Implemented and verified** (2026-11-13); §14, results in §15 |
| 2 | Claude Code (observe-only, D1) | **Implemented; real-session check blocked** by the hook-installation gate (§16) |
| 3 | Unified session dashboard | **Implemented**; screenshots pending an idle moment (§16) |
| 4 | Approval Center | **Implemented and verified with simulated agents**; real agents need hooks installed (gate) (§16) |
| 5 | Code intelligence | **Implemented and verified** on throwaway repositories (§16) |
| 6 | Additional adapters | **Implemented, observe-only, UNVERIFIED** against real agents (gate) (§16) |
| 7 | AI Chat and providers | **Local providers implemented** (Ollama, OpenAI-compatible/LM Studio) — UNVERIFIED live (none installed); cloud providers blocked by D3 (§17) |
| 8 | Developer integrations | **Blocked by D3**: registry lists each with its auth needs; none connected (§17) |
| 9 | Usage and analytics | **Implemented** (local, real agents only); provider usage/limits blocked by D3 (§17) |
| 10 | Notch integration | **Implemented**: agent alerts in the free slot below the notch (§17) |
| 11 | Phone companion | **Protocol and encryption only** (D2: no transport, no iOS project, no port) (§17) |
| 12 | Extensions, optimisation, release | **Implemented**: observe-only manifests; security review; docs (§17) |

Conventions: **VERIFIED** = read in official docs or observed on this Mac;
**UNVERIFIED** = plausible but not confirmed. Capabilities are advertised in
the UI only after they're implemented *and* verified on this Mac.

---

## 1. Current state (Phase 0 audit)

**AI Hub today** (`Sources/Orbit/Widgets/AIChatWidget.swift`, 153 lines): a
SAMPLE widget. Provider picker (ChatGPT/Claude/Gemini) saved to `ai.json`;
replies come from `MockData.aiReply`; nothing is sent; no keys; conversations
not saved. Dashboard section `.ai` ("AI Hub") hosts it full-page. Tests:
`AIChatTests`. `GitHubWidget` is also SAMPLE (`MockData.githubActivity`).

**Reusable Orbit foundations**

| Need | Existing | Reuse |
|---|---|---|
| Local IPC | `OrbitBridge` target: `UnixSocket` (folder 0700, socket 0600, `getpeereid` same-UID check, stale-socket replacement, 1 s send timeout, `FD_CLOEXEC`), `BridgeFraming` (u32 length + JSON, 64 KiB cap), `FrameDecoder`, validating `BridgeMessage.decode` | Yes: same framing and socket rules, a second socket |
| Helper binary | `OrbitBraveHelper` executable target + `scripts/install-brave-helper.sh` (explicit, user-run, writes only named paths, `--uninstall`) | Yes: template for `OrbitAgentHook` + installers |
| Server side | `BrowserBridgeServer` (DispatchSource accept/read, current user only) | Yes: pattern for `AgentBridgeServer` |
| JSON prefs | `JSONFile` / `Persisted` (unreadable file never overwritten; explicit reset moves it aside) | Yes, for AI Hub preferences |
| Settings | `SettingsSection` + grouped `Form` panes; `PreferencesModel` tolerant decoding | Yes: an "AI Hub" pane |
| Overlay slot | `NotchOverlayCoordinator` (`NotchOverlay`: none / musicIsland / volumeHUD; dashboard > expanded player > HUD > compact island) | Phase 10 only, with approval |
| Timers in tests | `HUDScheduler` / `FakeScheduler` | Yes |
| Projects | `Projects.projects(in:)` lists `~/Developer` folders, flags `.git` | Yes for project association |

**Absent (greenfield, all in the macOS SDK, no new dependency):** SQLite
(`import SQLite3`; system 3.54.0, header in the CLT SDK), Keychain
(`Security`), running `git` (`/usr/bin/git` via `Process`), user notifications
(`UserNotifications`).

**This Mac (read-only checks, 2026-11-13)**

| Agent | Installed | Notes |
|---|---|---|
| Claude Code | 2.1.294 (`~/.local/bin/claude`) | `~/.claude/settings.json` already has **NotchBuddy** hooks on 12 events incl. `PermissionRequest` (timeout 120 s) and `PreToolUse[AskUserQuestion]` |
| Codex | `/opt/homebrew/bin/codex` — **broken** (native binary ENOENT) | `~/.codex/config.toml` `notify` slot already used by Codex Computer Use |
| OpenCode | 1.4.3 (**V1**; V2 is current) | — |
| Copilot CLI | 1.0.5 | — |
| Cursor, Gemini CLI, Antigravity | Not installed | — |
| `gh` | 2.83.2, signed in (keyring) | Orbit must not reuse gh's token |

---

## 2. Architecture

Orbit is a monitor and control surface for agents the user already runs. It
never runs an autonomous agent of its own and never edits projects itself.

```
┌─────────────────────────────── Orbit.app (MainActor UI) ─────────────────────────────┐
│ AI Hub section · Settings › AI Hub · notch indicators (Ph10)                         │
│        ▲ @Observable stores: AgentSessionStore, ApprovalCenter, ActivityFeed         │
├────────┼─────────────────────────────────────────────────────────────────────────────┤
│ AIHubService (owns everything below; off unless enabled)                             │
│  AgentEventRouter (actor) ─ normalise → validate → dedupe → fan out (AsyncStream)    │
│     ├─ AgentSessionManager   ├─ ApprovalManager   ├─ ActivityTimeline                │
│     ├─ CodeChangeService (git, on demand, Ph5)    └─ HubStore (SQLite actor)         │
│  AgentRegistry: [AgentAdapter] with capability manifests                             │
│     ├─ HookAdapters (Claude, Codex, Copilot, Cursor, Antigravity, Gemini)            │
│     ├─ OpenCodeServerAdapter (local SSE + REST)                                      │
│     └─ HostedAdapters (ACP client / Codex app-server / Claude stream-json) (later)   │
│  AIProviderRegistry + AIChatService (Ph7) · IntegrationRegistry (Ph8)                │
│  UsageService (Ph9) · NotificationService (Ph10)                                     │
├──────────────────────────────────────────────────────────────────────────────────────┤
│ AgentBridgeServer — Unix socket ~/Library/Application Support/Orbit/Bridge/agents.sock│
└────────▲─────────────────────────────────────────────────────────────────────────────┘
         │ framed JSON (same-UID only)
   OrbitAgentHook (tiny helper, run by each agent's command hook)
```

**Two integration modes** (decided by what agents officially offer):

1. **Observe user-launched sessions → hooks.** Every agent except OpenCode
   documents command hooks that receive JSON on stdin. One helper,
   `OrbitAgentHook`, is the hook for all of them; it forwards the payload to
   Orbit and, for blocking events, waits for Orbit's decision. This is the
   only official way to see terminal/IDE sessions the user started.
2. **Host sessions Orbit launches → ACP / Codex app-server / Claude
   stream-json.** Gives messaging, interrupt and resume, but only for sessions
   Orbit spawned (ACP's client launches the agent as a subprocess; attaching to
   a running TUI isn't documented for any agent). Deferred to Phase 6+ and
   opt-in.

OpenCode is the exception: its local server (`opencode serve` / the V2
background service) exposes SSE events plus REST permission/question/prompt
endpoints for sessions the user started.

**Naming decision:** keep the proposed names; none collide with existing
types (`AIProvider`/`AIChatWidget` stay until Phase 7 replaces them).
`AIProvider` (existing enum) will be superseded by `AIProviderRegistry`, not
duplicated.

**Concurrency (revised in Phase 1 planning, P1-4 in §14):** socket accept and
read, framing, JSON decoding, validation, payload reduction and
normalisation run off the main thread (a private serial queue / nonisolated
code); only validated, normalised events reach the main actor, delivered in
batches through an `AsyncStream`. `AgentEventRouter` may be `@MainActor`
initially (dedupe, session updates, health) but does no parsing there;
`AgentSessionManager` and all UI state are `@MainActor @Observable`. SQLite
runs on its own actor (serial). No polling: sockets, SSE and hooks are push;
git runs on demand. (Unlike `BrowserBridgeServer`, which reads on the main
queue, the agent bridge must not.)

**Feature flag:** `aiHub.enabled` (off by default) in Orbit preferences. Off:
no socket, no store opened, the existing SAMPLE widget unchanged.

---

## 3. Agent compatibility matrix (Phase 0 research, 2026-11-13)

Levels follow §8: **Observe** (events), **Inspect** (files/diffs),
**Respond** (permissions/questions), **Control** (send/interrupt/resume).

| | Claude Code | Codex | Copilot CLI | Cursor | Antigravity | Gemini CLI | OpenCode |
|---|---|---|---|---|---|---|---|
| Discovery | hooks; transcripts `~/.claude/projects/` | hooks; `~/.codex` | hooks; `~/.copilot/session-state/` | hooks | hooks | hooks; `~/.gemini/tmp/` | local server `GET /session/active` (V2) |
| Install | edit `~/.claude/settings.json` **or** a plugin | `~/.codex/hooks.json` + **user must trust each hook in `/hooks`** (hash-bound) | drop-in `~/.copilot/hooks/orbit.json` | `~/.cursor/hooks.json` | `~/.gemini/config/hooks.json` | `~/.gemini/settings.json` `hooks` | none (server); plugin optional |
| Events | 33 (session, prompt, tool pre/post/fail, subagent, compact, notification, FileChanged, Stop…) | 14 | 15 | 21 (editor) | 6 | 11 | SSE: session.*, tool.*, permission.*, form.*, filesystem.changed |
| Session ID | `session_id`, `transcript_path`, `cwd` | `session_id`(thread), `turn_id` | `sessionId`, `cwd` | `conversation_id`, `generation_id` | `conversationId`, `workspacePaths` | `session_id`, `cwd` | `sessionID` |
| File changes | PostToolUse Write/Edit (`tool_response.filePath`), FileChanged | apply_patch in tool_input | postToolUse | `afterFileEdit` with edits | PostToolUse | AfterTool, telemetry | `filesystem.changed`, tool events |
| Permissions | **Yes**: `PermissionRequest` → `decision.behavior allow/deny` (+ optional `updatedPermissions`) | **Yes**: `PermissionRequest` allow/deny; deny wins; no decision → native prompt | **Yes**: `permissionRequest` allow/deny; timeout fails open (30 s default) | **Yes**: `before*`/`preToolUse` → `permission allow/deny` (`ask` not enforced on preToolUse) | **Yes**: `PreToolUse` decision allow/deny/ask… (30 s default) | Partial: `BeforeTool` allow/deny, no `ask`; order vs. confirmation UNVERIFIED | **Yes**: `POST …/permission/{id}/reply` once/always/reject |
| Questions | **Yes**: `AskUserQuestion` via PreToolUse/PermissionRequest `updatedInput.answers` (interactive TUI UNVERIFIED) | Hosted only (`tool/requestUserInput`, experimental) | No hook (UNVERIFIED) | Hosted only (ACP `cursor/ask_question`) | Hosted only (ACP elicitation) | No (`ask_user` off in ACP) | **Yes**: form reply endpoint |
| Control of user-launched session | Channels (research preview, needs launch flag); `Stop` block-with-reason | No | `agentStop` block-with-reason | No | No | No | **Yes**: prompt / interrupt endpoints |
| Control of Orbit-launched session | stream-json / Agent SDK | app-server (experimental) / `exec --json` | ACP (preview) / SDK | ACP / SDK / Cloud API | ACP (`agy acp`) | ACP (`gemini --acp`) | ACP / server |
| Auth | user's own login | user's own | Copilot subscription | user's own | Google OAuth/API key | Code Assist / API key | server password or pairing token |
| Reliability | High (mature hooks) | Medium (app-server experimental; local install broken) | Medium (also reads `.claude/settings.json` hooks → double fire) | Medium (CLI hook subset UNVERIFIED) | Medium (new; per-surface matrix undocumented) | Low priority: consumer users moved to Antigravity CLI (2026-06-18) | Medium (HttpApi experimental; V1→V2 break; local is V1) |
| macOS | Yes | Yes | Yes | Yes | Yes | Yes | Yes |
| Complexity | Medium | Medium–High | Low–Medium | Medium | Medium | Medium | Medium–High |

Key cross-agent facts:
- No agent documents answering an already-displayed native prompt from
  outside except via a *blocking hook that decides before the prompt* (or
  OpenCode's server). Orbit never simulates clicks or types into terminals.
- Hooks fail **open** on timeout in Claude, Codex, Copilot and Cursor (the tool
  falls through to the native prompt or, in some cases, runs) — so Orbit's
  helper must always reply *before* the agent's timeout, and "no answer" must
  mean "native prompt", never "allow".
- Copilot CLI also executes hooks from `.claude/settings.json`; the helper
  must identify the agent from the payload shape (snake_case `session_id` +
  `hook_event_name` vs camelCase `sessionId`), not only from argv.
- Codex hooks need per-hook trust in Codex's own `/hooks` UI; Orbit can't (and
  mustn't) bypass that.

Doc sources: code.claude.com/docs/en/hooks.md, channels.md, headless.md;
learn.chatgpt.com/docs/hooks.md, app-server.md, non-interactive-mode.md;
docs.github.com/en/copilot/reference/hooks-reference, …/acp-server;
cursor.com/docs/hooks, cursor.com/docs/cli/acp; antigravity.google/docs/hooks,
…/ide/extensions/acp; github.com/google-gemini/gemini-cli docs/hooks/reference.md,
docs/cli/acp-mode.md; opencode.ai/docs/api, opencode.ai/docs/server (V1);
agentclientprotocol.com/protocol/overview.

---

## 4. Adapter contract

```swift
struct AgentCapabilities: OptionSet, Codable { // per adapter, per installed version
    static let observe, inspectFiles, answerPermissions, answerQuestions,
               scopedAllow, sendMessage, interrupt, resume, openOrigin
}
protocol AgentAdapter: Sendable {
    var id: AgentID { get }                         // "claude-code", "codex", …
    var manifest: AgentManifest { get }             // name, versions supported, capabilities, install kind, docs URL
    func detect() async -> AgentInstallation?       // binary path + version, read-only
    func integrationStatus() async -> IntegrationStatus // notInstalled / hookMissing / needsTrust / connected / error
    func normalise(_ raw: HookPayload) throws -> [AgentEvent]  // pure, tested with recorded fixtures
    func respond(_ decision: ApprovalDecision, to request: ApprovalRequest) -> HookReply? // encodes the agent's own reply schema
    func installPlan() -> ConfigChangePlan?         // shown as a diff; applied only after explicit consent
}
```

`AgentManifest.capabilities` lists only what's implemented and verified; the
UI derives every button from it. Third-party adapters (Phase 12) supply a
declarative manifest + a hook payload mapping; no arbitrary code is loaded.

---

## 5. Data models

### Event (normalised)

```swift
struct AgentEvent: Sendable, Codable {
    let id: UUID                    // Orbit's own
    let agent: AgentID
    let sessionKey: SessionKey      // agent + native session id
    let kind: Kind                  // sessionStarted, sessionEnded, promptSubmitted, turnCompleted,
                                    // toolStarted, toolCompleted, toolFailed, fileChanged,
                                    // permissionRequested, questionAsked, notification,
                                    // subagentStarted, subagentStopped, compacted, error
    let nativeName: String          // e.g. "PostToolUse"
    let occurredAt: Date?           // from payload when present
    let receivedAt: Date
    let cwd: String?
    let tool: ToolRef?              // name, useID, one-line redacted summary
    let files: [String]             // absolute paths inside cwd only
    let dedupeKey: String           // agent|session|nativeName|toolUseID-or-turnID-or-payloadDigest
    let source: Source              // hook(pid chain, bundle id) / server / hosted
}
```

Dedupe: identical `dedupeKey` within 5 s is dropped (Copilot + Claude
double-fire, reconnect replays).

### Session

`AgentSession { key, agent, nativeID, title, cwd, repoRoot?, branch?, model?,
status (running | waitingApproval | waitingQuestion | idle | completed |
failed | ended | stale), startedAt, lastEventAt, endedAt?, origin (terminal
bundle id + pid from the hook's process ancestry; heuristic), capabilities }`.
`stale` = no event for 30 min and the recorded pid is gone. Reconnection after
Orbit restart: sessions reload from SQLite; the next hook event re-attaches.

### Approval

`ApprovalRequest { id (random 128-bit), agent, sessionKey, kind (permission |
question), nativeRequestID, tool, summary (redacted), options (only those the
agent supports), createdAt, expiresAt, state (pending | allowed | denied |
answered | expired | fellThrough | superseded), decidedAt?, decidedVia
(orbit | nativePrompt | phone) }`.

Rules: one decision per request; the reply travels only on the hook
connection that is still waiting; `expiresAt` = agent hook timeout − 5 s (≤ the
helper's own deadline); after expiry or Orbit quitting the helper exits with
no decision → the agent shows its own prompt. Orbit never auto-approves and
never creates allow rules of its own; "always allow" is offered only when the
agent supports it and passes the agent's own suggestion back unchanged.

---

## 6. Local event bridge

- **Helper `OrbitAgentHook`** (new SPM executable target beside
  `OrbitBraveHelper`, depends on `OrbitBridge`): `OrbitAgentHook --agent <id>
  --event <name> [--blocking]`. Reads stdin (cap 1 MiB, truncated payloads are
  marked), adds `getppid` ancestry + `__CFBundleIdentifier`/`TERM_PROGRAM`, frames
  to `agents.sock`.
  - Non-blocking events: write and exit (target < 10 ms; Orbit not running →
    connect fails → exit 0 silently).
  - Blocking events: wait for one reply frame until its deadline, print the
    agent-specific JSON the adapter produced, exit 0. Any failure → print
    nothing, exit 0 (native prompt). Never exit 2 unless the user chose Deny.
- **Server `AgentBridgeServer`**: same rules as `UnixSocket.listen` (0700/0600,
  peer UID), per-connection 256 KiB frame cap, bounded queue (drop-oldest for
  observation events, never for approvals), one in-flight approval per
  connection.
- **Protocol**: `{"v":1,"type":"hook","agent":…,"event":…,"blocking":bool,
  "payload":{…},"origin":{…}}` → Orbit replies `{"v":1,"type":"decision",
  "output":{…}}` or closes.
- **Why not Claude's HTTP hooks?** They need a TCP listener; the Unix socket
  keeps "no network ports".
- **OpenCode**: `OpenCodeServerAdapter` connects to `127.0.0.1` only (V1 `GET
  /event`, V2 `GET /api/event`), password from Keychain; detects V1/V2 from the
  OpenAPI document.

---

## 7. SQLite store

`~/Library/Application Support/Orbit/AIHub/hub.sqlite`, WAL, `foreign_keys=ON`,
`PRAGMA user_version` migrations (forward-only, each in a transaction; a
`VACUUM INTO` backup before any migration). Opened only when the AI Hub is on.

```sql
CREATE TABLE sessions (
  key TEXT PRIMARY KEY, agent TEXT NOT NULL, native_id TEXT NOT NULL,
  title TEXT, cwd TEXT, repo_root TEXT, branch TEXT, model TEXT,
  status TEXT NOT NULL, origin_bundle TEXT, origin_pid INTEGER,
  started_at REAL NOT NULL, last_event_at REAL NOT NULL, ended_at REAL);
CREATE INDEX sessions_recent ON sessions(last_event_at DESC);
CREATE INDEX sessions_agent ON sessions(agent, status);

CREATE TABLE events (
  id TEXT PRIMARY KEY, session_key TEXT NOT NULL REFERENCES sessions(key) ON DELETE CASCADE,
  kind TEXT NOT NULL, native_name TEXT NOT NULL, tool TEXT, summary TEXT,
  files TEXT,                       -- JSON array
  occurred_at REAL, received_at REAL NOT NULL, dedupe_key TEXT NOT NULL,
  raw TEXT);                        -- redacted payload, NULL unless "keep raw events" is on
CREATE INDEX events_session ON events(session_key, received_at);
CREATE UNIQUE INDEX events_dedupe ON events(dedupe_key);

CREATE TABLE approvals (
  id TEXT PRIMARY KEY, session_key TEXT NOT NULL REFERENCES sessions(key),
  kind TEXT NOT NULL, tool TEXT, summary TEXT, options TEXT,
  state TEXT NOT NULL, created_at REAL NOT NULL, expires_at REAL NOT NULL,
  decided_at REAL, decided_via TEXT);
CREATE INDEX approvals_pending ON approvals(state, expires_at);

CREATE TABLE file_changes (
  session_key TEXT NOT NULL REFERENCES sessions(key) ON DELETE CASCADE,
  path TEXT NOT NULL, first_seen REAL NOT NULL, last_seen REAL NOT NULL,
  additions INTEGER, deletions INTEGER, PRIMARY KEY (session_key, path));

CREATE VIRTUAL TABLE session_search USING fts5(title, cwd, prompts, content='');
-- Phase 7: conversations, messages · Phase 9: usage_samples · Phase 11: devices
```

- **Retention** (Settings): events 30 days, sessions 90, approvals audit 180;
  pruned at launch and daily.
- **Backup**: daily `VACUUM INTO hub.backup-<n>.sqlite`, keep 3.
- **Corruption**: `PRAGMA quick_check` on open; failure → file moved aside
  (never deleted), fresh store, notice in Settings (same policy as
  `Persisted`). Recovery names are collision-safe and never overwrite (S1,
  §14).
- **Unavailable**: if SQLite can't be opened or written, the AI Hub keeps
  running in memory only and health shows "degraded" (S2, §14).
- **Demo data** lives in a separate store file (P1-2, §14), never in
  `hub.sqlite`.
- **Privacy default**: prompts and assistant text are **not** stored (only
  counts and titles); opt-in "keep prompt text" for search.

---

## 8. Security and privacy

Capability tiers, each a separate opt-in per agent: **Observe** (default
when the AI Hub is on) → **Inspect** (git diffs, on demand) → **Respond**
(approvals/questions) → **Control** (send/interrupt; hosted or OpenCode).
Claude Code is capped at Observe + Inspect while NotchBuddy owns its
permission handling (D1, §13).

| Threat | Mitigation |
|---|---|
| Another local user connects | Folder 0700, socket 0600, `getpeereid` UID check (existing code) |
| Same-user process forges events | Can only *add* events/requests; can't read or receive others' decisions (replies go only on the requesting connection). Events marked by origin; unknown shapes rejected |
| Forged/duplicated approval | Random IDs, single use, bound to connection + session + tool_use_id, expiry |
| Stale approval acted on | Expiry < agent timeout; UI disables the buttons when the connection closes |
| Prompt injection via payloads | Payloads rendered as plain text, never executed, links never auto-opened; untrusted-text caps |
| Secrets in tool input / env | Redaction before storage and display (API-key, token, password, `Authorization:`, `.env` values patterns); raw payloads off by default |
| Hook makes agents slow or stuck | Native helper, fail-silent, deadlines shorter than agent timeouts; never exit 2 by accident |
| Config damage while installing hooks | Explicit consent + diff preview; atomic write; timestamped backup; marker on Orbit entries; uninstall removes only Orbit's entries; other tools' hooks (NotchBuddy) untouched |
| Credential theft | Keychain only; never read other apps' tokens (gh, Claude, Codex auth files) |
| Network exposure | No TCP listeners; OpenCode client connects to 127.0.0.1 only |
| DoS by flood | Frame cap, bounded queues, per-connection rate limit, DB write batching |

No private APIs, no Accessibility or Input Monitoring, no simulated input.

---

## 9. Skills, plugins and tools (assessed 2026-11-13)

Use: `claude-code-guide` agent (Claude Code hooks/SDK questions);
`ecc:swift-reviewer`, `ecc:swift-concurrency-6-2`, `ecc:swift-actor-persistence`,
`ecc:swift-protocol-di-testing` (Swift 6 actors, DI, tests);
`ecc:security-reviewer` / `securitymaxxing:threat-model` (Phases 4, 11, 12);
`claude-api` skill (Phase 7 Anthropic provider); `gh` CLI for GitHub research
(the GitHub MCP server failed to connect this session).
Not needed: database-reviewer (Postgres-focused). Missing but optional: none
blocking. Note: the claude-mem memory observer is failing (expired key);
project notes live in this file instead.

---

## 10. Phase dependency map

```
0 Audit ─► 1 Foundation (flag, socket, router, SQLite, demo agents)
              ├─► 2 Claude Code hooks ─► 3 Session dashboard ─► 4 Approval Center
              │                                  ├─► 5 Code intelligence (git)
              │                                  └─► 10 Notch (needs 3+4; touches NotchOverlayCoordinator)
              ├─► 6 More adapters (needs 2's helper; 4 for Respond)
              ├─► 7 Chat & providers (needs Keychain decision) ─► 9 Usage (needs 6+7)
              └─► 8 Integrations (Keychain)
   11 Phone (needs 3+4+10; iOS toolchain decision) ─► 12 Extensions, audit, release
```

Recommended Phase 6 order: Copilot CLI (drop-in file) → Codex hooks → OpenCode
server → Cursor → Antigravity → Gemini CLI (lowest, consumer users moved) →
generic manifest adapter. Hosted (ACP / app-server) mode as a separate
approval after Phase 6.

Phase 1's approved scope and acceptance criteria are in §14. Under §13:
Phase 2 is Observe-only; Phase 4's real-agent verification needs a
non-Claude adapter (or demo agents first); Phases 7–8 cloud credentials wait
for D3; Phase 11 stays conditional (D2).

---

## 11. Risks and open decisions

| Risk | Impact | Mitigation / decision needed |
|---|---|---|
| **NotchBuddy already owns Claude `PermissionRequest`** | Two apps answering one prompt; race order UNVERIFIED | **Decided (D1):** Claude Code is Observe-only; no Orbit `PermissionRequest` hook |
| **Phase 11 needs an iOS app** | Requires full Xcode + Apple developer account (APNs), conflicting with "CLT only" | **Decided (D2):** Phase 11 conditional and deferred; protocol designed now, no iOS project, listener or Xcode requirement |
| **Keychain with ad-hoc signing** | Each rebuild changes the code signature → Keychain access prompts | **Decided (D3):** investigate a stable local signing identity before any persistent credential storage |
| Codex install broken; Cursor/Gemini/Antigravity absent | Can't verify those adapters on this Mac | User reinstalls/installs before Phase 6 |
| OpenCode V1 locally, V2 current | Two APIs | Detect version; support V1 first if that's what's installed |
| Agent APIs change fast (Codex app-server, OpenCode HttpApi marked experimental) | Adapter breakage | Versioned manifests, recorded payload fixtures in tests, "unsupported version" state |
| Hook latency on every tool call | Slower agents | Native helper; measure in Phase 2 (target < 10 ms non-blocking) |
| Subscription usage/limits | No official API for consumer plans | Show "not available"; never estimate from guesses |
| UserNotifications | Needs a permission prompt | Prefer in-notch (Phase 10); system notifications opt-in |

---

## 12. Rollback plan (all phases)

`aiHub.enabled = false` stops the socket and closes the store; uninstallers
remove Orbit's hook entries from each agent's config (backups kept); deleting
`AIHub/` removes all history. Existing Orbit modules are untouched by every
phase unless a phase explicitly says otherwise.

---

## 13. Approved decisions (2026-11-13)

**D1 — Claude Code is Observe-only while NotchBuddy owns permissions.**
- Orbit installs **no** `PermissionRequest` hook and never answers
  `AskUserQuestion` for Claude Code. Its Claude hooks are non-blocking
  observers only (e.g. `SessionStart`/`End`, `UserPromptSubmit`,
  `PreToolUse`/`PostToolUse`/`PostToolUseFailure` without a decision, `Stop`,
  `StopFailure`, `Subagent*`, `Notification`, `FileChanged`); they print
  nothing and always exit 0, so they can't affect NotchBuddy's decisions.
- "Waiting for approval" is shown from observed signals only:
  `Notification` with `permission_prompt` (fires after ~6 s, per docs) or a
  `PreToolUse` with no matching `PostToolUse`. Labelled "Waiting in the
  terminal", with no Allow/Deny buttons.
- The Claude manifest advertises `observe` (+ `inspectFiles` after Phase 5)
  and `openOrigin` once verified; never `answerPermissions` or
  `answerQuestions` under D1. Revisiting D1 needs a separate approval (e.g.
  if NotchBuddy is removed).

**D2 — Phone companion (Phase 11) is conditional and deferred.**
- Now: only a platform-independent, transport-agnostic protocol on paper —
  versioned JSON envelopes (`{v, type, id, ts, body}`) carrying the same
  session/event/approval models as §5; end-to-end encryption designed on
  CryptoKit primitives (Curve25519 key agreement, ChaCha20-Poly1305), pairing
  by an out-of-band code, per-device keys, revocation list, replay protection
  (message IDs + timestamps).
- Not until separately approved: an iOS project, any network listener
  (Bonjour/TCP/WebSocket), push notifications, a relay, or an Xcode
  requirement. Nothing in Phases 1–10 opens a port.

**D3 — Stable signing before persistent credentials.**
- Before any persistent API-credential storage (Phase 7 cloud providers,
  Phase 8 integrations, the OpenCode server password), investigate a stable
  local signing identity so Keychain item access doesn't break on each
  rebuild. Creating a certificate or changing `scripts/run.sh` signing needs
  its own approval.
- Until then: no plaintext credentials anywhere (files, `UserDefaults`, SQLite,
  logs), and Orbit never reads or reuses CLI tokens (`gh`, Claude, Codex,
  Copilot, Gemini auth files).

**Consequences**
- **Phase 2** shrinks to Observe-only Claude hooks; installing them adds
  entries to `~/.claude/settings.json` beside NotchBuddy's (consent + backup +
  marker, as §8), or ships as a plugin — chosen in Phase 2's plan.
- **Phase 4** (Approval Center) can't be verified with Claude Code. Its first
  real responder must be another agent (Copilot CLI hooks, OpenCode server or
  Codex hooks) — pulling one adapter from Phase 6 forward, or verifying Phase
  4 with demo agents first and real ones in Phase 6. To be decided at Phase 4.
- **Phase 7** can start with key-less local providers (Ollama, LM Studio);
  cloud providers wait for D3.
- **Phase 8** integrations needing tokens wait for D3; OpenCode's server
  password (Phase 6) too, unless the server runs without one locally.
- **Phase 10/11** notch and phone show Claude sessions as status only.

---

## 14. Phase 1: Foundation — approved plan (2026-11-13)

### Scope

In: the `aiHub` flag (off by default); the agent socket; the shared envelope
and its validation; the `OrbitAgentHook` helper (built and tested, **not
installed**); off-main decoding and normalisation; dedupe and routing; the
session registry; SQLite for sessions and events; read-only agent discovery;
bridge and per-agent health; demo agents; a minimal Settings › AI Hub pane.

Out (later phases): any real agent integration or hook installation (2),
dashboard UI (3), approvals or blocking envelopes (4, and D1), git/diffs (5),
credentials (D3), network ports and the phone (D2), notch (10). The existing
SAMPLE AI Hub widget and dashboard section are unchanged.

### Decisions

- **P1-1 Settings pane: approved.** Settings › AI Hub: master switch (off by
  default), bridge health, detected agents, demo mode switch, Clear Demo
  Data. Nothing else.
- **P1-2 Demo mode: approved.** User-controlled, off by default. Simulated
  sessions are always labelled as simulated (in every view, including the
  Settings pane and debug state line) and never presented as real agent
  activity. Demo records are separated from real data: demo agents use the
  reserved `demo-` agent-ID namespace, the router sends them to a separate
  store (`AIHub/demo.sqlite`, same schema) and a separate in-memory registry
  view; real agents can't use the `demo-` prefix and demo events can't land
  in `hub.sqlite`. Clear Demo Data removes all demo sessions, events and the
  demo store. Analytics (Phase 9) read `hub.sqlite` only.
- **P1-3 OrbitAgentHook: approved.** Built and tested in Phase 1; not
  installed, not registered with any agent, no agent configuration touched.
  First real installation is a Phase 2 decision. Non-blocking envelopes only.
- **P1-4 Concurrency: approved with adjustment.** As revised in §2: socket
  reading, decoding, validation and other potentially expensive work off the
  main thread; `AgentSessionManager` and observable UI state on the main
  actor; router may be `@MainActor` initially but does no parsing; Swift 6
  strict concurrency throughout (SQLite handles confined to the store actor).
- **P1-5 Discovery: approved.** Known executable paths and app bundles only
  (e.g. `~/.local/bin/claude`, `/opt/homebrew/bin/codex`,
  `~/.opencode/bin/opencode`, `/opt/homebrew/bin/copilot`,
  `/Applications/Cursor.app`). No executing agent binaries, no version
  commands, no external processes.
- **P1-6 Retention and backups: approved.** Events 30 days, sessions 90 days
  (fixed in Phase 1, pruned at launch); a backup before every migration; no
  scheduled backups in Phase 1.

### Safeguards and additional requirements

- **S1 Corruption recovery preserves the original.** The unreadable database
  and its `-wal`/`-shm` files are moved, never deleted or rewritten, to
  `hub.unreadable-<yyyyMMdd-HHmmss>[-n].sqlite` (`-n` increments until the
  name is free; the move itself refuses to replace an existing file).
  Pre-migration backups use the same collision-safe naming.
- **S2 Memory-only degraded mode.** If SQLite can't be opened, migrated or
  written (including disk full), the AI Hub keeps working in memory only and
  health shows "Degraded: history isn't being saved" with the reason, until
  the store recovers or Orbit relaunches.
- **S3 Flood resistance.** Decoding, validation and persistence can't freeze
  the UI: bounded queues, a global rate cap with counted drops, batched
  main-actor delivery and batched SQLite writes; flood tests prove bounded
  memory and off-main decoding; a manual measurement checks main-thread
  responsiveness during a flood.
- **S4 Demo isolation** (P1-2): demo data never reaches real sessions,
  `hub.sqlite` or analytics.
- **S5** D1–D3 and the §8 security boundaries hold: no permission handling,
  no hooks installed, no credentials, no network ports.
- **S6** Phase 1 only: nothing from Phase 2+, nothing installed.

### Envelope (v1, Phase 1)

`{v:1, type:"hook", agent, event, sentAt, origin{bundleID?, termProgram?,
ppid}, payload{…}, truncated}`. Validation: `v == 1`; `agent` matches
`[a-z0-9-]{1,32}` (`demo-` reserved for Orbit's demo agents); `event` matches
`[A-Za-z._]{1,64}`; `payload` is a JSON object; strings stripped of control
characters and capped; paths absolute and standardised or dropped. Frames stay
within the existing 64 KiB `BridgeFraming` limit: the helper reduces an
oversized payload to its short top-level fields and sets `truncated`
(`FrameDecoder` unchanged). Limits: 32 connections, 16 frames per connection,
200 events/s global (drops counted in health); a bad frame closes the
connection. Summaries are redacted (token, API-key, `Authorization:`,
password patterns); raw payloads aren't stored.

### Schema v1

`sessions` and `events` from §7 only, plus `PRAGMA user_version = 1`.
Approvals, file changes and search arrive with later migrations. The same
schema serves `hub.sqlite` and `demo.sqlite`.

### Files

New: `Sources/OrbitBridge/AgentBridgeProtocol.swift`,
`Sources/OrbitBridge/AgentHookClient.swift`, `Sources/OrbitAgentHook/main.swift`,
`Sources/Orbit/AIHub/{AgentModels, AgentRegistry, AgentBridgeServer,
AgentEventRouter, AgentSessionManager, HubStore, AgentDiscovery, AgentHealth,
DemoAgents, AIHubService}.swift`, `Tests/OrbitTests/AIHub*Tests.swift`.
Modified: `Package.swift` (helper target; `sqlite3` linking only if the build
needs it), `Settings/Preferences.swift` (`aiHub`, `aiHubDemo`, tolerant),
`Settings/SettingsWindow.swift` (AI Hub pane), `OrbitApp.swift` (service
lifecycle, `aihub:*` debug commands, state line), this document. Untouched:
existing modules, the SAMPLE AI Hub widget, `NotchOverlayCoordinator`,
`FrameDecoder`/Brave code, `.vscode/`, the nested `Orbit/` folder, every
agent's configuration.

### Steps

Progress: **Step 1 done** (2026-11-13): `Sources/Orbit/AIHub/AgentModels.swift`
(`AgentID`, `SessionKey`, `AgentCapabilities` with `observe` only,
`AgentManifest`, `AgentEvent`, `AgentSession`), `OrbitPreferences.aiHub`
(off, tolerant), `Tests/OrbitTests/AIHubModelTests.swift` (9 tests; suite 421
passing). `aiHubDemo` moved to Step 7, where demo mode is built.
**Step 2 done** (2026-11-13): `Sources/OrbitBridge/AgentBridgeProtocol.swift`
(`UnixSocket.agentsPath`, `JSONValue`, `AgentEnvelope` encode / decode /
validation / reduction, `sanitizedPath`); `AgentID` now uses the envelope's
agent-ID rule (one rule for both sides); `Tests/OrbitTests/AIHubProtocolTests.swift`
(16 tests; suite 437 passing). Existing `BridgeProtocol`, `FrameDecoder`,
`UnixSocket` and Brave code unchanged. Additions to the envelope rules below:
`reducedKeys` lists at most 256 keys; past that the whole payload is
withheld as `reducedKeys == ["*"]` with an empty payload (accepted only in
exactly that form); `sentAt` must be whole milliseconds within 24 h before /
5 min after Orbit's clock; envelope fields are an exact set (unknown or
missing fields rejected); payload limits: depth 32, 16,384 values, keys
1–256 bytes; payload text is kept as data (agents' newlines are legitimate),
sanitising happens where Orbit extracts values (Step 5).
**Step 3 done** (2026-11-13): `Sources/OrbitBridge/AgentHookClient.swift`,
`Sources/OrbitAgentHook/main.swift`, `OrbitAgentHook` executable target in
`Package.swift`; `Tests/OrbitTests/AIHubHookClientTests.swift` (9 tests; suite
446 passing). Behaviour: `OrbitAgentHook --agent <id> --event <name>` reads
stdin (≤ 8 MiB, ≤ 2 s; poll-based, can't hang the agent), sends one frame,
closes, exits 0 — no retries, no disk queue, nothing on stdout, nothing on
stderr except usage. Unreadable/oversized/late input is still sent, with the
payload withheld (`["*"]`). Run from a terminal or with bad arguments: usage
on stderr, exit 64. Origin from `__CFBundleIdentifier`, `TERM_PROGRAM`,
`getppid()`. Debug builds only: `ORBIT_AGENT_SOCKET` overrides the socket path
(like `ORBIT_DATA_DIR`), so checks never touch the real socket. Measured with
the built binary: no socket → exit 0, empty stdout/stderr, 7–10 ms per run
including process spawn (first launch of a fresh build ~0.6 s: macOS
signature check); valid input → exactly one v1 frame; terminal → exit 64.

1. Models + `aiHub` preference + tests (`aiHubDemo` with Step 7).
2. Envelope and validation in `OrbitBridge` + tests.
3. `AgentHookClient` + `OrbitAgentHook` target + tests.
4. `HubStore` (SQLite3 build check first; schema v1; migrations with backup;
   S1 recovery; S2 degraded mode; retention) + tests.
5. Off-main socket server, router, session manager + real-socket tests.
6. Registry, adapter protocol, discovery, health + tests.
7. Demo agents, demo store, Clear Demo Data + tests.
8. `AIHubService` wiring, debug commands, Settings › AI Hub pane.
9. Three consecutive `./scripts/test.sh` runs, manual verification, this
   document updated, stop.

### Acceptance criteria

1. With `aiHub` off (default): no socket, no database file, no timers or
   observers; Orbit behaves exactly as before; all existing tests pass.
2. With `aiHub` on: `agents.sock` exists with folder 0700 / socket 0600 and
   accepts only the current user; turning it off removes the socket and
   closes the store; repeated toggling leaves no duplicate sockets,
   observers or timers.
3. A valid envelope (from `AgentHookClient` or the built helper fed by hand)
   becomes a normalised event, updates a session and is persisted; invalid,
   oversized or flooding input is rejected or dropped and counted, never
   crashing or blocking.
4. Decoding and validation run off the main thread (tested); a 1,000-event
   flood keeps memory bounded (tested) and the UI responsive (measured).
5. Sessions and events survive an Orbit relaunch; retention prunes events
   > 30 days and sessions > 90 days (tested with an injected clock).
6. Migrations back up first; a corrupt database is moved aside under a
   collision-safe name and never overwritten (tested); an unavailable store
   puts the AI Hub in memory-only mode with degraded health shown (tested).
7. The helper exits 0 without output when Orbit isn't listening (< 50 ms) and
   never writes to stdout; run from a terminal it prints usage to stderr and
   exits 64.
8. Discovery reports agents from known paths only and launches no process
   (tested with a fake folder).
9. Demo mode: two simultaneous labelled simulated sessions; demo data only in
   `demo.sqlite` and the demo view; Clear Demo Data removes all of it; real
   sessions and `hub.sqlite` untouched (tested).
10. Settings › AI Hub shows the master switch, bridge health (including
    degraded), detected agents, demo switch and Clear Demo Data.
11. `~/.claude/settings.json`, NotchBuddy's hooks and every other agent
    configuration are byte-for-byte unchanged (checked manually).
12. `./scripts/test.sh` passes three consecutive times; idle CPU and memory
    with the AI Hub on vs off are measured on this Mac and recorded here.


---

## 15. Phase 1 results (2026-11-13)

Autonomous implementation authorised by the user on 2026-11-13 ("implement the
complete 13-phase roadmap… within the approval gates").

**Steps 4–9.** `HubStore` (SQLite, WAL, `user_version` migrations, retention,
S1 recovery, S2 degraded), `AgentRegistry` (adapter protocol, Orbit's own
event vocabulary for demo agents, `Redactor`), `AgentDiscovery` (known paths
only), `AgentBridgeServer` (private serial queue, limits, batching),
`AgentSessionManager` (status, one stale timer, bounded), `AgentEventRouter`
(+ `AgentHealth`, `StoreWriter`), `DemoAgents`, `AIHubService` (ordered
reconciliation of the two switches), `OrbitPreferences.aiHubDemo`, Settings ›
AI Hub, `OrbitApp` wiring and debug commands (`aihub:on|off`,
`aihub:demo:on|off|clear`, `aihub=` in the state line).

**Decisions made while implementing**
- `events.dedupe_key` is a plain index, not UNIQUE (§7 said unique): dedupe
  is time-windowed in the router; a unique key would drop legitimate repeats.
- An existing database is checked with SQLite's `immutable=1` read-only open
  *before* any normal open: a normal open of an unreadable file deleted its
  `-wal` (found by test), which would break S1.
- `UnixSocket.listen` gained a `backlog` parameter (default 4, Brave
  unchanged); the agent socket uses 64. With 4, parallel hooks were refused by
  the kernel before Orbit could accept them (found by test).
- `Authorization: Bearer <token>` redaction fixed: the first pattern masked
  only the word "Bearer" (found by test).
- Demo data: `demo-` agents → a separate `AgentSessionManager`, `StoreWriter`
  and `demo.sqlite`; `AgentHealth.lastEvent` counts real agents only.
- Clear Demo Data with demo mode on keeps it running with a fresh, empty
  `demo.sqlite`.

**Tests.** 472 passing, three consecutive full runs. AI Hub suites: models 9,
protocol 16, hook client 9, store 7, pipeline 11, service 8. Real sockets and
SQLite in throwaway folders; fake schedulers for demo agents and stale timers.

**Manual verification on this Mac** (debug build, toggled in memory by debug
command; the user was actively using the Mac, so CPU figures are indicative):

| State | Orbit CPU (20 s) | Footprint |
|---|---|---|
| AI Hub off (default): no socket, no `AIHub/` folder | 0.00 % | 37 MB |
| On, idle: socket `srw-------`, folders `drwx------`, `hub.sqlite` `-rw-------` | 0.00 % | 38 MB |
| On + demo mode (2 simulated sessions, 6 events in 8 s) | 0.20 % | 38 MB |
| Off again: socket removed | 0.00 % | 38 MB |

The built helper fed by hand (`claude-code`, no adapter in Phase 1) exited 0,
printed nothing and wasn't accepted. `~/.claude/settings.json` (NotchBuddy's
hooks), `~/.codex/config.toml`, `~/.copilot/settings.json` and
`~/.config/opencode/opencode.json` were byte-for-byte unchanged (SHA-256
before/after). Left on disk: an empty `AIHub/hub.sqlite` from the check.

**Still manual for the user:** Settings › AI Hub with the real switches (the
check used debug commands); Clear Demo Data from the button.


---

## 16. Phases 2–6 results (2026-11-13)

**Phase 2 — Claude Code, observe-only (D1).** `ClaudeCodeAdapter` maps the
documented hook payloads (SessionStart/End, UserPromptSubmit — prompt text not
kept —, Pre/PostToolUse, PostToolUseFailure, Stop, StopFailure, Subagent*,
Notification, PreCompact) into events; tool summaries are one redacted line,
never file contents. New event kind `waitingForUser` and session status
`waiting`: **inferred** from `Notification` (`permission_prompt`,
`idle_prompt`, `elicitation_dialog`, `agent_needs_input`) or a `PreToolUse`
of `AskUserQuestion`, and always labelled "inferred; answer it there".
`ClaudeHookInstaller` builds the change to `~/.claude/settings.json`:
12 non-blocking command hooks (never `PermissionRequest`), every other key and
hook (NotchBuddy's) kept, recognised and removed by the helper's path,
idempotent, backup `settings.json.orbit-backup-<time>[-n]` before writing.
Settings › AI Hub › Claude Code shows status and installs/removes **only
after a confirmation dialog** that states the change. `scripts/run.sh` now
bundles and signs `OrbitAgentHook` in `Orbit.app/Contents/MacOS`; installing
copies it to `~/Library/Application Support/Orbit/AgentHook/`.
**Blocked by the approval gate:** installing the hooks into the user's real
settings and checking a real Claude session (all payload shapes UNVERIFIED
until then). Tested on synthetic settings shaped like this Mac's (NotchBuddy
entries kept byte-for-byte in structure; removal restores the original).

**Phase 3 — Session dashboard.** Dashboard › AI Hub has *Agents · Approvals ·
Chat*. Agents: real/simulated scopes (simulated always labelled), search
(title, path, agent), filters (All/Active/Waiting/Finished), rows with status,
agent, relative time; inspector with status (waiting marked inferred),
project, times, merged timeline (saved + live), **Open <app>** (activates the
session's terminal/editor by its reported bundle ID — the most public API
allows; not a specific tab) and **Show in Finder**; summary with counts when
nothing's selected. Sessions now carry their origin (bundle ID, hook parent
PID): schema v2 (`origin_bundle`, `origin_pid`), migrated after a backup.
Screenshots: queued for an idle moment (`docs/screenshots/ai-hub/`).

**Phase 4 — Approval Center.** Protocol: `request` envelopes (`deadline`
≤ 10 min, refused from `claude-code` at the envelope, the helper and the
server) answered on the same connection with an `AgentDecision` (the agent's
own hook-output JSON, or nothing). Helper: `--wait <seconds>` prints the
decision, or nothing on timeout/no answer (`claude-code` never waits). Server:
request connections stay open until answered or expired. `ApprovalManager`:
random IDs, one request per connection, single-use decisions, answers must be
offered options, expiry 2 s before the helper's deadline, `withdrawn` when the
agent stops waiting or the AI Hub stops (every waiting agent then asks its
user), bounded history, audit rows in `approvals` (schema v3; demo outcomes in
`demo.sqlite`; kept 180 days). Orbit never decides by itself and never creates
"always allow" rules. Verified end to end with simulated agents (permission
and question round trips; withdrawal on shutdown). Found by test: adapter
methods declared only in a protocol extension were statically dispatched
through `any AgentAdapter` (never called) — now protocol requirements.

**Phase 5 — Code intelligence.** `CodeChangeService`: branch, commit,
`status --porcelain -z`, `diff --numstat -z HEAD`, one file's diff (200 KB
cap), the session's own files first (symlink-safe comparison). Runs
`/usr/bin/git` without a shell, off the main thread, 5 s timeout, capped
output, `core.fsmonitor=false`, `diff.external=`, `--no-ext-diff`,
`--no-textconv`, `GIT_CONFIG_NOSYSTEM`, no prompts, no optional locks; paths
can't leave the repository. Tested: a repository configured to run a program
via fsmonitor, external diff and textconv ran nothing. Inspector › Changes
with click-to-diff and Open (in the session's editor if known).

**Phase 6 — Additional agents.** `HookAdapter` with declarative, Codable
`Mapping`s for Codex (apply_patch files parsed), Copilot CLI (JSON-string
`toolArgs` opened), Cursor (`afterFileEdit`), Gemini CLI, Antigravity
(`toolCall.name/args`); each knows its permission event and allow/deny output
format (implemented, **not advertised**: manifests say `observe` only).
OpenCode: SSE parser + event mapping (`OpenCodeEvents`); connecting needs
`opencode serve` running and possibly its password (D3) — pending. Found by
test: CRLF SSE lines weren't split (Swift's `\r\n` is one Character).
**All Phase 6 payload shapes UNVERIFIED** against real agents; installing their
hooks is an approval gate (Copilot: drop-in `~/.copilot/hooks/orbit.json`;
Codex: `~/.codex/hooks.json` + the user trusting each hook in `/hooks`;
Cursor `~/.cursor/hooks.json`; Gemini `~/.gemini/settings.json`; Antigravity
`~/.gemini/config/hooks.json`). Codex's local install is broken; Cursor,
Gemini CLI and Antigravity aren't installed.

**Review fixes (Phase 1 code, independent Swift/security review):** the helper
aborted (exit 134) on a payload containing `-1e999` (non-finite numbers are now
refused; stderr via `fputs`); redaction missed `GITHUB_TOKEN=`-style names,
JSON `"password":"…"` and PEM bodies; a failed `-wal` move during recovery
could lose the journal (now rolled back, store degrades); late events could
reopen an ended session; a clock stepping back froze the rate window; three
lifecycle races (shutdown, Clear Demo Data during a toggle, late batches after
stop).

**Tests:** 503 passing (full suite).


---

## 17. Phases 7–12 results (2026-11-13)

**Phase 7 — Chat.** `ChatService` with `ChatProvider`s: Ollama
(`/api/tags`, streaming `/api/chat` NDJSON) and OpenAI-compatible local
servers (LM Studio `/v1/models`, streaming `/v1/chat/completions` SSE).
Every request goes only to `127.0.0.1`/`localhost`/`::1` over http (refused
otherwise, before any request); streaming with cancellation (Stop keeps what
arrived); model discovery on demand (no polling); text-file attachments
(UTF-8, ≤ 100 KB); conversations in `AIHub/chat.sqlite` (schema v4
`conversations`, `messages`). Chat works only while the AI Hub is on (off: the
old SAMPLE widget, no database). **UNVERIFIED live**: neither Ollama nor LM
Studio is installed on this Mac; tested through a stub `URLProtocol`.
**Blocked (D3):** Anthropic, OpenAI and Gemini need API keys.

**Phase 8 — Integrations.** `IntegrationRegistry`: GitHub, GitLab, Vercel,
Linear, Jira, n8n (developer first), Notion, Stripe, Slack, Discord, Telegram,
each with the credential it needs and what it would show. **All blocked by
D3**; Orbit never reuses `gh`'s or any CLI's token. Settings › AI Hub lists
them as "Not connected" with the reason.

**Phase 9 — Insights.** From `hub.sqlite` only (simulated data is in its own
store): events per day (7 days), per-agent sessions, events and active time
(first-to-last event per session, capped at 12 h), approval outcomes, and a
copyable weekly summary. Costs and plan limits are shown as not available —
no reliable source without keys (D3); nothing is estimated.

**Phase 10 — Notch.** `AgentAlerts` + `AgentAlertPanel`: a short capsule in
the compact island's place for approval requests, inferred waiting, failures
and finished turns (per session at most once a minute), 4 s each, queue of 3,
simulated ones labelled. Lowest priority: shown only when the slot is free —
no dashboard, no compact or expanded music island, no volume HUD — and gone
the moment one appears. `NotchOverlayCoordinator` is unchanged (read, not
modified); its decisions are re-tested. Setting: Settings › AI Hub › "Agent
alerts below the notch" (`aiHubAlerts`, on).

**Phase 11 — Companion (D2).** Protocol only: `CompanionMessage` (versioned;
sessions, approval request/decision, ping) inside `SealedMessage`s: X25519
agreement, HKDF-SHA256 over both public keys (sorted), ChaCha20-Poly1305 with
AAD binding version, sender key ID and sequence number; strictly increasing
sequence (replay refused), revocation by key ID, a 6-digit pairing code both
screens show. Standard algorithms so non-Apple clients can implement it.
**Not built (D2):** transport, listener, pairing UI, iOS app.

**Phase 12 — Extensions and release.** Third-party adapters as JSON
manifests in `AIHub/Adapters/` (≤ 64 KiB, ≤ 50 files) using the same
`HookAdapter.Mapping`; declarative only (no code loaded); always observe-only
(answering fields dropped); can't shadow built-in or `demo-` IDs; bad files
are listed with the reason and skipped. Settings › AI Hub lists them and opens
the folder. Debug command `aihub:page:<agents|approvals|insights|chat>`.

**Tests.** 513 in the full suite. Three consecutive full runs passed at the
end; across 14 full runs today, `SonicPulseTests.turningItOffStopsEverythingAndOnRestoresIt`
(an approved, pre-existing Sonic Pulse test with real-time sleeps) failed 3
times under load: it counted 3 island-cover calls instead of 2 in one show.
Not caused by AI Hub code (which only reads the overlay coordinator); left
unchanged per the "don't modify Sonic Pulse" boundary and reported.


---

## 18. Final review, verification and open items (2026-11-14)

**Security review of Phases 2–12** (independent, findings reproduced in scratch
repositories) — all fixed and regression-tested:
1. *High:* git could still run a repository's program via a clean filter,
   `.git/hooks/post-index-change` or `log.showSignature` + `gpg.program`. Now:
   `core.hooksPath=/dev/null`, `log.showSignature=false`, `--no-show-signature`,
   and a preflight that **refuses** a repository whose local/worktree config
   sets `filter.*`, `gpg.*`, `diff.*.command|textconv`, `core.hooksPath`,
   `fsmonitor`, `worktree`, `sshCommand`, `attributesFile`, `gitProxy`,
   `include*`, or that has `.git/info/attributes` (the inspector says why).
2. *Medium:* "Open" on a changed file could launch an agent-written
   executable → now **Show in Finder** only.
3. *Medium:* approval cards showed only a command's first line → the full
   input (every line, redacted, capped with a visible marker) is shown.
4. *Low-medium:* chat followed redirects off the Mac → its own session
   refuses every redirect, and responses must come from the requested host.
5. *Low-medium (dormant):* the pairing code was open to a birthday search →
   commit-then-reveal (`commitment`, `verify`, nonce in the code).
6. *Low:* a symlinked `settings.json` lost its link and got a link as backup →
   the real file is backed up and written; the link is kept.
7. *Low:* a symlink/FIFO manifest could hang launch → regular files only,
   capped read.
8. *Low:* hook approvals now cap the wait at 10 min; at most 8 requests wait at
   once; the helper no longer honours `ORBIT_AGENT_SOCKET` (an agent's
   environment can't redirect its events).
Confirmed by the review: D1 holds at three layers; decisions are single-use
and reach only the asking connection; the installer never adds
PermissionRequest and keeps other tools' hooks; manifests can't answer or
shadow built-ins; untrusted text is rendered as plain text.

**Tests:** 516, three consecutive full runs passing (2026-11-14).

**Final measurements** (release of this build as a debug app, user idle 290 s):

| State | Orbit CPU (30 s) | Footprint |
|---|---|---|
| AI Hub off | 0.00 % | 18 MB |
| On, idle | 0.00 % | 18 MB |
| On + demo mode (4 simulated sessions, 27 events in 30 s, approvals, alerts) | 1.03 % | 21 MB |

Agent configuration files byte-for-byte unchanged (SHA-256); no hooks or
helper installed anywhere.

**Screenshots:** not captured. This session's process lost macOS Screen
Recording access (even a region capture fails); granting it is the user's
decision. The idle-gated script is ready to rerun.

**Blocked on the user's approval (gates):**
- Installing hooks: Claude Code (observe-only; the Settings button does it after
  confirmation), Copilot, Codex (+ trust in `/hooks`), Cursor, Gemini CLI,
  Antigravity. Needed to verify every real-agent payload (all UNVERIFIED).
- Installing/repairing agents: Codex (broken), Cursor, Gemini CLI, Antigravity;
  OpenCode V2 and running `opencode serve`.
- D3 signing identity → API keys (Anthropic, OpenAI, Gemini), integrations
  (GitHub…), provider usage/limits, OpenCode's server password.
- D2 phone transport, iOS app, any network listener.
- Local model servers (Ollama / LM Studio) to verify chat live.
- Screen Recording for screenshots.

**Known issue (not AI Hub):** `SonicPulseTests.turningItOffStopsEverythingAndOnRestoresIt`
intermittently counts 3 island-cover calls instead of 2 under load (3 of ~20
full runs); approved module, left unchanged.

---

## 19. AI Hub 2.0 — UI/UX redesign (2026-11-14)

**Direction.** Native macOS developer command centre inside the notch
dashboard's real content area (~708 × 330 pt; the dashboard stays dark, an
existing Orbit decision; Settings follows the Appearance preference).
Graphite surfaces instead of glass on glass, one accent (Orbit indigo),
colour reserved for agent identity and state, every state shown with icon +
words (never colour alone), restrained motion that respects Reduce Motion.

**Design system** (`AIHub/AIHubDesign.swift`): `HubTokens` (surfaces, text,
state colours, 4-pt spacing, concentric radii 6/10/14, type scale, motion
durations), `AgentStyle` (per-agent colour + monogram; simulated agents get a
dashed ring), `HubStatus` (label + symbol + colour; "Needs you · inferred",
"Disconnected" when the bridge is down), components `AgentAvatar`,
`StatusPill`, `HubTag`, `HubPanel`, `HubSectionHeader`, `HubMetric`,
`HubEmptyState` (with a real next action), `HubButtonStyle` (primary,
secondary, destructive, quiet; hover, press, disabled), `HubRowStyle` (hover,
selected), `HubFormat`, and render-safe `HubScroll`/`HubField`.
(`@State` is used as a plain `State` value: the macro plugin isn't in the
Command Line Tools.)

**Navigation.** Orbit's section tabs stay on top; the AI Hub's own navigation
is a slim vertical rail (Overview · Agents · Approvals with a pending badge ·
Insights · Chat; ⌘1–⌘5) with the bridge state at its foot. The old second
tab row is gone. Agents pushes into a session detail (back: ⌘[).

**Screens.** Overview (command centre: active / need-you / finished today /
agents on this Mac; live sessions; needs-attention list of approvals and
inferred waiting; recent events; system status incl. "Integrations: none
connected"; onboarding when off). Agents (search, scope Agents/Simulated,
filters; cards with identity, project, current activity, status, duration,
last activity). Session detail (identity, project, start, duration, status,
Open <terminal>, Show in Finder; Timeline with a connected rail; Changes with
file list and a coloured unified diff; refused repositories say why).
Approvals (prominent cards with agent bar, session, what's requested, full
input, per-second expiry, Allow Once/Deny or the offered answers — never for
Claude Code; History with outcome badges). Insights (sessions, finished,
failed, approvals; events per day; active time by agent; most used tools;
busiest projects; copyable weekly summary; real agents only; empty state
until there's data). Chat (conversation list, provider status, model menu,
messages, composer with attach/stop, D3-disabled cloud tags, empty states).
Settings › AI Hub regrouped: General · Connection Health · Notifications ·
Agent Integrations (+ Claude Code hooks, third-party adapters) · Demo Mode ·
Chat Providers · Usage and Privacy · Service Integrations. Notch alert:
agent identity mark, state-coloured symbol, short enter/exit.

**Backend changes (read-only additions only):** `HubStore.toolCounts`,
`statusCounts`, `projectCounts`; `Insights` gained `tools`, `statuses`,
`projects` and is settable for fixtures; `AgentAlerts.Alert.agent`. No schema,
protocol or integration change.

**Visual QA.** Screen Recording is unavailable to this session, so every
screen is rendered in-process with `ImageRenderer` at the real size with
realistic fixtures (`Tests/OrbitTests/AIHubRenderTests.swift`;
`ORBIT_RENDER=1 ./scripts/test.sh --filter Renders` writes
`docs/screenshots/ai-hub-2/*.png`). Two refinement passes from those renders
fixed: a wrapping timeline time column, an approval card hiding the second
line of a command, Insights overflowing the page, unreadable middle-truncated
project paths. Limits of this method: no hover/focus states, no live
scrolling, no real panel glass behind the content.

**Tests:** 518, three consecutive full runs passing.

**Measurements** (debug build, user idle 480 s): AI Hub off 0.00 % CPU /
18 MB; on + demo, dashboard closed 1.05 % / 21 MB; dashboard open on Overview
with live demo activity 1.60 % / 41 MB; on Approvals with pending requests
(1-s countdowns) 3.50 % / 52 MB.

**Independent design and accessibility review** (rendered screens and code) —
applied: Overview fits its 330 pt (scroll as a fallback; quieter System panel);
totals count real agents only, simulated ones noted ("+1 sim.") and tagged
everywhere; two-letter agent marks (CC, CX, GH, CU, GE, AG, OC, Sx) so identity
is never colour-only, agent names on attention and history rows; tertiary
text and quiet states raised to ≥ 4.5:1, a lighter destructive red; clearer
times ("active 20 seconds ago · 39 min long", no "0 min"); subtitle shows
agent · parent folder without mid-word cuts; one radius scale (tiles match
panels, rows concentric inside panels); button font is a style parameter;
24 pt minimum control height; overlay scroll indicators; approval cards name
the session, show the full input only when it adds something, disable buttons
once expired, and have complete VoiceOver labels; chat bubbles say "You" /
"Model"; the notch alert is announced to VoiceOver and shows "INFERRED" as a
tag (fits the real 300 pt capsule); filter-specific empty states with "Show
All Sessions"; "+N more" cues; one vocabulary ("Needs you"; scope "Real /
Simulated"); "Claude Code asks in its own terminal; Orbit only observes it".
Not changed (noted): Orbit's own Reduce Motion preference isn't passed to the
notch alert (it follows the system setting); no Increase Contrast variant;
"Copied" feedback and per-decision error messages aren't shown.

**Final:** 518 tests, three consecutive full runs passing after the review
fixes; Orbit relaunched with this build.

**Accessibility follow-ups (2026-11-14):**
- Notch alerts honour Orbit's own Reduce Motion preference as well as the
  system's (`AgentAlerts.reduceMotion`, set from preferences;
  `effectiveReduceMotion`).
- Increase Contrast: `HubAppearance` (observable) follows macOS's setting
  (updated on `accessibilityDisplayOptionsDidChangeNotification`); `HubTokens`
  surfaces, borders, text and the failure colour strengthen (text ≥ 7:1 in
  that mode) and views redraw at once. Render:
  `docs/screenshots/ai-hub-2/10-overview-increased-contrast.png`.
- "Copied" feedback: Copy Weekly Summary changes to "✓ Copied" for 2 s and is
  announced to VoiceOver (`AgentBrowser.copy`, pasteboard injectable so tests
  never touch the user's clipboard).
- Approval decision failures: `AgentBrowser.decide` explains why (answered,
  expired or withdrawn; or an answer that wasn't offered) in a dismissible
  banner on Approvals, also announced to VoiceOver; a successful decision
  clears it.
- Tests: 4 new (522 total), three consecutive full runs passing.

---

## 20. AI Hub 3.0 — Milestone 1: Coucou audit (2026-11-14, read-only)

Scope: source and architecture audit of Coucou (github.com/Louis-CFM/coucou,
shallow clone at `0d7fe58`, 2026-11-13, Mac 0.6.0; tag `v0.2.2` fetched for
comparison) against Orbit, plus identity of the NotchBuddy installed on this
Mac. Nothing was changed: no source, hooks, settings, permissions,
installations, credentials or listeners. D1–D3 unchanged. **Decision pending
(§20.5); the notch state machine is not started.**

**Correction to §18:** "no hooks or helper installed anywhere" is out of date.
Orbit's observe-only Claude hooks are now in `~/.claude/settings.json`
(12 events, none `PermissionRequest`; helper at
`~/Library/Application Support/Orbit/AgentHook/OrbitAgentHook`, 5 s timeout),
next to NotchBuddy's entries. Observed 2026-11-14.

### 20.1 Coucou source architecture

- **Repository:** `NotchBuddy/` (macOS app + iPhone app + widgets, XcodeGen,
  Swift 6 strict concurrency, macOS 15+, one package: FluidAudio 0.17.7),
  `windows/` (Tauri, Windows/Linux), `android/`, `relay/` (Cloudflare Worker
  holding the APNs key). ~74 k Swift lines in `NotchBuddy/Sources`.
- **Licence:** code MIT. The names Coucou/Mochi, the Mochi character (design,
  expressions, animations), icons, sounds and media are **all rights
  reserved** (`LICENSE-ASSETS.md`). Orbit may learn from the architecture;
  it must not reuse the character, sounds, icons or names. Copied code needs
  the MIT notice.
- **`Sources/CoucouKit`** (shared with iPhone, 5.2 k lines): `BotEngine`
  (tween + particle engine, per-state configs, ported from an HTML
  prototype), `MochiOutfitDrawing`/`Wardrobe`, `MochiMood` (CPU, heat,
  memory, battery → expressions), `PillCatalog`, `IslandTypes`, `DiffEngine`,
  `QuestionPayload`, `ReviewPolicy`, turn/service snapshots,
  `MochiActivityState` (Live Activity payload: agent, state, counts only).
- **`Sources/App`** (Mac): `AppState.shared` (one `ObservableObject`, ~1 k
  lines), `IslandWindowController` (2.3 k), `IslandViewContent` +
  `IslandRootView` (6.3 k of views), `HookServer` (4.7 k), `SettingsView`
  (2.7 k), services, voice, notes, phone and Android links.
- **`PillCatalog.swift`:** single source of truth: 4 categories (workspace,
  agent, AI, service), 30 stable IDs (11 agents/workspaces incl. Claude Code,
  Cursor, Codex, Gemini, Antigravity, Copilot, Muse, OpenCode, Amp, Hermes,
  Claude Desktop; 5 AI providers; 14 services). IDs are contract values
  (Keychain, UserDefaults, hook routing).
- **Island state machine:** `IslandMode {hidden, compact, expanded}` ×
  `IslandView` (24 cases: overview, approval, question, error, finished,
  upload, mail, prompt, searching, result, note, settings, greeting, wardrobe,
  recap, listening, voiceResult, capture, update, whatsNew, launch, …) ×
  `BotState` (11) + `BotEmote`. Transitions are imperative
  (`setMode`, `expand(to:)`, `collapse(allowPendingApproval:)`), not a table;
  a pending approval can't be folded except by Escape. One `NSPanel` at
  `mainMenu + 3`, all Spaces, full-screen auxiliary, mouse pass-through
  toggled by hit rect; placement notch or a corner; screen choice; drag to
  desktop.
- **Agent integration:** one relay (`nb-hook` sh → `nb-hook.py` →
  `nb.sock`; 1 MB cap, 5 s receive timeout, 32 connections). Installers with
  preview diff + dated backup for Claude Code, Gemini, Antigravity, Codex,
  Copilot, Muse; plugins for OpenCode, Amp, Hermes; Claude status line relay
  for plan limits. Claude: fail-open (no output → the terminal asks);
  Copilot: fail-closed `ask`.
- **Sessions:** board sessions keyed by session + pill + cwd; per-pill
  registry; host from `term_program`/`bundle_id` (VS Code, Cursor,
  terminals); 0.6.0 adds launching a Claude Code session from the notch and
  dropping a file on a session.
- **Approvals and questions:** `ApprovalQueue`/`QuestionQueue` hold the hook
  connection open (one DispatchSource each to see the client hang up); head
  on the card; allow / always (`updatedPermissions` from suggestions) / deny;
  `AskUserQuestion` answered via a dedicated `PreToolUse --ask` hook
  (130 s) with `updatedInput`; plan approval; Codex auto-review detection.
  Routing: VS Code/Cursor sessions always get a card; terminal sessions only
  with a setting (HEAD) or never (0.2.2) — otherwise `ask`.
- **Diffs and activity:** `DiffEngine` (LCS with size guards) from hook
  `tool_input` (Edit/MultiEdit/Write old/new strings) — no git. `RecapStore`
  keeps turn drafts and a weekly recap (`recap.json`).
- **AI chat:** `ClaudeService` with 8 API providers, keys in Keychain
  (`WhenUnlockedThisDeviceOnly`); `CLIRelay` "use my subscription" runs the
  official CLI (claude, gemini/antigravity, codex, cursor, copilot) isolated
  (no resume, user hooks/MCP off where possible).
- **Services:** pollers for GitHub, n8n, Stripe, Vercel, Resend, Cal.com,
  Notion; Mail with triage rules and plans; WhatsApp via a local gateway;
  Spotify/Apple Music; crypto portfolio (exchange credentials); Coucoudoro.
- **Voice and dictation:** "OK Coucou" (`VoiceEngine`: wake window, VAD,
  stall watchdog, rate-limited rebuilds; `IntentParser`, `VoiceBrain` on
  FoundationModels (macOS 26), `ClaudeVoiceBrain`); `MacDictation` (up to
  three `SFSpeechRecognizer`s at once); Flow dictation (hold a key, paste
  anywhere; Parakeet on the Neural Engine via FluidAudio, models downloaded
  on request).
- **Notetaker:** records mic + system audio, live transcript, Parakeet +
  diarizer, summary via a Claude key or Apple Intelligence; audio deleted
  after transcription; stored in `Application Support/NotchBuddy/Notes`.
- **Desktop companion:** `DesktopMochi` panel, 10 fps asleep, paused on
  lock; dragging Mochi out of the notch moves it to the desktop.
- **Phone:** iPhone app over CloudKit (private DB; snapshot in an encrypted
  field); Live Activity when the Mac locks, pushed through the user's
  Cloudflare relay; Android over a TLS `NWListener` + Bonjour (self-signed
  certificate, protocol v1).
- **Other:** screen capture to Claude, self-updater + What's new, demo engine,
  16 languages.

### 20.2 Feature comparison

Status: **Parity** (equivalent exists), **Partial**, **Gap** (absent),
**Blocked** (by D1/D2/D3 or a gate), **N/A** (out of scope).

| Feature | Coucou implementation | Orbit implementation | Status | Dependencies | Proposed solution |
|---|---|---|---|---|---|
| Notch window | One panel, `mainMenu+3`, hit-rect pass-through, notch/corner, screen choice | `NotchPanel` dashboard, Music Island, volume HUD, agent alert panel (`.statusBar`) | Parity (different design) | — | Keep Orbit's panels |
| Island state machine | Mode × 24 views × bot state, imperative | `NotchOverlayCoordinator` (none/music/HUD, pure `decide`), `NotchInteraction`, `MusicIsland.Phase`; agent alerts lowest priority | Partial | Coexistence decision; coordinator is an approved module | Pure transition table wrapping the coordinator (M2) |
| Pill catalog | `PillCatalog`, 30 stable IDs | `AgentRegistry` + manifests; `AgentStyle` monograms | Partial | — | Keep registry; no pills UI until needed |
| Character engine | `BotEngine` Canvas tweens + particles, 11 states, emotes, outfits | `PetModel` table (hidden/idle/playful/walking/running/sleeping/dragged), `PetRig` cat | Partial (no agent states) | Original character only (licence) | Add agent-aware states to Orbit's own pet |
| Machine mood | CPU/heat/memory/battery → expressions | `SystemStats`, `BatteryStatus` exist; not wired to the pet | Gap | — | Later, small |
| Desktop companion | Desktop Mochi, drag notch ↔ desktop | Desktop Pet (Stage 5.4); Notch Companion toggle, no window yet | Partial | Notch state machine | Notch Companion after M2 |
| Claude Code hooks | 13 entries incl. `PermissionRequest`, `--ask` | 12 observe-only entries, installed; real events received | Parity for observing | D1 | Keep |
| Other agents | 10 installers/plugins, approvals for Codex/Copilot/Muse/Hermes | `HookAdapter` mappings for Codex, Copilot, Cursor, Gemini, Antigravity; OpenCode SSE; observe-only, not installed | Partial, **unverified** | Install gates | Unchanged; verify per agent when approved |
| Sessions | Board per session/pill/cwd; host detection; launch from notch; file drop | `AgentSessionManager`, origin bundle/PID, search/filters, timeline (working) | Partial | — | Launch/file drop later (launch writes to terminals → its own approval) |
| Approvals | Holds hook open; allow/always/deny; queue | `ApprovalManager` (single-use, expiry, audit), demo-verified; never Claude | Blocked for Claude (D1) | D1 / Option B | Option B only |
| Questions | `--ask` PreToolUse, `updatedInput` answers | Inferred "Needs you" only | Blocked for Claude (D1) | D1 / Option B | Option B only |
| Diffs | From hook `tool_input`, LCS | Git (`CodeChangeService`, hardened); **Code Changes not yet verified live** | Partial | Privacy choice: Orbit keeps one-line summaries, not contents | Verify git path first; per-edit diffs only if approved |
| Activity / recap | Steps, turn drafts, weekly recap | Timeline, Insights, weekly summary | Parity | — | — |
| Plan usage | Status line relay of `rate_limits` | Not available (D3 noted) | Gap | Status line change to user settings | Possible without credentials; needs approval |
| AI chat (API) | 8 providers, Keychain | Local Ollama/LM Studio only (unverified live) | Blocked | D3 | After D3 |
| Chat via subscription CLI | `CLIRelay` runs official CLIs | None | Gap | Decision: does running `claude -p` respect D3? | Ask before building |
| Services | GitHub, Stripe, Vercel, Notion, n8n, Mail, WhatsApp… | Registry lists them "Not connected"; GitHub widget is SAMPLE | Blocked | D3 | After D3 |
| Music | Spotify, Apple Music | Now Playing (Apple Music, Brave YouTube), Music Island | Parity | — | — |
| Voice "OK …" | Wake word, intents, FoundationModels | None | Gap | Microphone + Speech permissions | Separate milestone |
| Dictation | Flow (hold key, paste), Parakeet | None | Gap | Mic, Accessibility (paste), model download | Separate milestone |
| Notetaker | Mic + system audio, diarization, summary | None | Gap | Mic, screen/system-audio capture, summary provider (D3) | Last; heavy |
| Screen capture | ⌘⇧S → Claude | Screenshot Vault (drag/drop) | Partial | Screen Recording permission | Later |
| iPhone | CloudKit + Live Activity via relay | Protocol only (`CompanionProtocol`) | Blocked | D2, Apple developer account | After D2 |
| Android | TLS listener + Bonjour | None | Blocked | D2 (network listener) | After D2 |
| Updater / What's new | GitHub updater | None | N/A | — | Skip |
| Demo mode | `DemoEngine` | Demo agents, separate store | Parity | — | — |

### 20.3 Installed NotchBuddy identity (verified)

| Check | Evidence | Result |
|---|---|---|
| App path | `/Applications/Coucou.app`; second copy `~/Desktop/Coucou 2.app` (binary byte-identical) | Coucou |
| Bundle | `CFBundleIdentifier fr.louisraille.NotchBuddy`, executable `Coucou`, version 0.2.2 (13) | Matches `v0.2.2` `project.yml` (`fr.louisraille.NotchBuddy`, 0.2.2, build 13) |
| Signature | Developer ID Application: LOUIS RAILLE (256AUJ9555), notarized, stapled; Gatekeeper accepts | Team ID matches repo `DEVELOPMENT_TEAM` |
| Hook relay | `nb-hook` (sh, "Coucou hook relay") and `nb-hook.py` in `~/Library/Application Support/NotchBuddy/` | **Identical** to the `nbHookShellWrapper` / `nbHookPythonGitHub` literals in `v0.2.2` `HookServer.swift` (SHA-256 of `nb-hook.py` `b60b17db…e1aecfe48e`); differs from HEAD (0.6.0) |
| Binary | Contains "Coucou hook relay" and the `nb.sock` path | Writes these scripts at launch (`installHookScript`) |
| Running | No `Coucou`/NotchBuddy process; no launchd job | **Not running.** `nb.sock` and prefs last written 2026-10-27 15:38 (stale socket) |
| Preferences | `fr.louisraille.NotchBuddy.plist`: 28 keys (values of secret-like keys not read); `iPhoneSyncEnabled = true` | Phone sync on when it runs |
| Claude hooks | 13 `nb-hook` entries in `~/.claude/settings.json` (incl. `PermissionRequest` 120 s, `PreToolUse` `AskUserQuestion --ask` 130 s); no Coucou status line | Installed by Coucou |

**Conclusion:** the installed NotchBuddy **is Coucou 0.2.2**, the public
repository's `v0.2.2` release.

**Who owns what now:** with Coucou not running, `nb-hook.py` fails to connect
and prints nothing, so Claude Code shows its own permission prompt and
question UI: **Claude Code owns them today, not NotchBuddy.** When Coucou runs,
it owns `PermissionRequest` and `AskUserQuestion` for Claude sessions in
VS Code/Cursor (terminal sessions get `ask` in 0.2.2) and draws its island in
the notch. Orbit owns its own notch panels in both cases.

### 20.4 Notch and hook conflicts

1. **Notch drawing:** Coucou's panel (`mainMenu+3` = 27) sits above Orbit's
   (`.statusBar` = 25); both open on the notch, so Coucou would cover Orbit's
   dashboard top, Music Island, volume HUD and agent alerts. Orbit's overlay
   coordinator doesn't know Coucou exists.
2. **Duplicate alerts:** both announce finished turns, failures and waiting
   approvals for the same Claude session.
3. **Misleading "waiting" copy:** while Coucou holds a `PermissionRequest`
   (≤ 120 s), Orbit's inferred "answer it there / in the terminal" points at
   the wrong place: the card is in Coucou's notch. (Inferred; not observed
   live.)
4. **Hooks:** no decision conflict — Orbit prints nothing on every event, so
   D1 holds. Each of 12 events runs both helpers in parallel; while Coucou is
   off, every event also spawns `python3` for a refused connection (cheap,
   not measured).
5. **Version drift:** if Coucou updates or relaunches, it rewrites its
   scripts; 0.6.0's App Store build moves them to `~/.claude/coucou/`. Orbit's
   installer recognises only its own entries, so this stays safe.
6. **Two app copies** with the same bundle ID (Applications, Desktop).
7. **No conflict:** keyboard shortcuts (Orbit registers none globally),
   sockets (different paths), data stores.

### 20.5 Decision required: coexist or replace

**A. Coexist.** Orbit detects Coucou (`NSWorkspace` running applications and
launch/terminate notifications for `fr.louisraille.NotchBuddy`; no
permission, no polling) and yields: no Orbit agent alerts in the notch while
Coucou runs (AI Hub dashboard still shows them), "Answer in Coucou" when the
session's host is VS Code/Cursor, otherwise "in the terminal". D1 unchanged;
nothing of Coucou's is touched. Cost: two notch apps can still both be
visible; Orbit can't answer Claude.

**B. Replace.** Orbit becomes the only notch companion and answers Claude's
permissions and questions through its existing `ApprovalManager`. Needs, each
approved separately: the user quits Coucou (and optionally removes it);
removing the 13 `nb-hook` entries from `~/.claude/settings.json` (backup
first) or via Coucou's own uninstall; revising D1 (Orbit adds a blocking
`PermissionRequest` hook and an `AskUserQuestion` `PreToolUse` hook for
Claude); deciding what happens to Coucou's iPhone sync. D2/D3 still apply.

**Recommendation:** decide B or A for the product, but build **A's detection
first in either case**: Coucou can be relaunched at any time (two copies are
installed), so Orbit must recognise it even under B. The notch state machine
takes "foreign notch owner" as an input, so B later only flips policy.

### 20.6 Recommended sequence (after the decision)

1. Finish baseline verification: Code Changes and full session detail with a
   real Claude session in a git repo (read-only).
2. M2: notch state machine + Coucou detection (§20.8).
3. Notch Companion window on top of it; agent-aware states for Orbit's own
   pet (working, needs you, finished, error, sleeping).
4. Option B only: D1 revision → Claude approvals and questions in the notch.
5. Plan usage via a status-line relay (settings change → approval).
6. Per-edit diffs from hook payloads (privacy decision first).
7. Dictation, then voice, then Notetaker (permissions each).
8. D3: chat providers and services. D2: phone.

### 20.7 Dependencies and blocked features

- **D1:** Claude approvals and questions (B only).
- **D2:** iPhone, Android, any listener, relay, Live Activity.
- **D3:** API chat providers, service integrations, Notetaker summaries via
  a cloud model; signing identity first.
- **Open question:** chat through the user's own CLI (`claude -p` and others)
  reads no token itself — does D3 allow it?
- **Permissions (each needs consent):** Microphone, Speech Recognition,
  Accessibility (paste), Screen/system-audio capture.
- **Install gates:** other agents' hooks; Codex install broken; Cursor, Gemini
  CLI, Antigravity not installed; local model servers.
- **Approved-module boundary:** `NotchOverlayCoordinator` and Sonic Pulse are
  read-only so far; M2 wraps them unless a change is approved.
- **Licence:** no Mochi design, Coucou sounds, icons or names in Orbit.

### 20.8 Proposed Milestone 2 scope (not started)

- **In:** `NotchStateMachine`, a pure, table-driven model (like `PetModel`)
  above `NotchOverlayCoordinator`: inputs dashboard open, Music Island phase,
  volume HUD, agent alert queue, companion visibility, foreign notch owner;
  output one owner of the slot below the notch. Priorities: dashboard >
  expanded music > volume HUD > agent alert > compact music > companion.
  `CoucouPresence` (`NSWorkspace`, injectable for tests). Alert policy and
  "Answer in Coucou/terminal" copy. Settings › AI Hub: "When Coucou is
  running: hide Orbit's agent alerts in the notch" (default on). Tests:
  exhaustive transition table, presence launch/terminate, alert routing; full
  suite three times.
- **Out:** any hook or settings change, Claude approvals, Notch Companion
  window, voice/dictation/Notetaker, chat, services, phone, changes to
  Coucou.

---

## 21. Milestone 2: Coucou coexistence and notch coordination (2026-11-14)

**Decision (user, 2026-11-14): A — coexistence.** Coucou keeps its Claude Code
permission and question handling; Orbit never competes with it or changes its
configuration. D1–D3 unchanged. The full expanded island is **not** started.

### 21.1 Real Claude Code verification (finishes §20.6 step 1)

Driven through the session detail's own code paths with DEBUG-only commands
(`aihub:select|diff|open|finder|render`, results in Orbit's log), on real
sessions recorded by the installed observe-only hooks:

| Check | Session | Result |
|---|---|---|
| Code Changes | this Claude Code session (VS Code, `/Users/…/Orbit`) | **Verified.** Repository found and inspected (not refused), branch `main`, 42–45 changed files, the session's own files listed first |
| File diff | same, `Sources/Orbit/OrbitApp.swift` | **Verified.** +100/−1, later +144/−1, equal to `git diff --numstat HEAD` each time |
| Untracked file diff | same, `docs/AI_HUB_SPEC.md` | **Bug found and fixed:** git prints nothing for an untracked file and the panel was blank; now "No diff (new or binary file)." (verified live) |
| Terminal navigation | earlier real session in Terminal (`orbit-hook-test`) | **Verified.** "Open Terminal" → frontmost `com.apple.Terminal` |
| Editor navigation | this session | **Verified.** "Open Visual Studio Code" → frontmost `com.microsoft.VSCode` |
| Finder navigation | both sessions | **Verified.** Project folder, `hello.txt`, and a changed file in the Orbit repo → frontmost `com.apple.finder` |

The first attempt ran while the screen was locked (frontmost `loginwindow`);
the calls succeeded but couldn't come to the front. All rows above are from
the retry after unlock. Render of the real Changes tab:
§21.4 (the QA harness fix).

### 21.2 What was built

- **`AIHub/CoucouPresence.swift`** — read-only detection by bundle ID
  (`fr.louisraille.NotchBuddy`, App Store `fr.louisraille.Coucou`): installed
  copies from Launch Services, running copies from `NSWorkspace`. States
  *not installed* / *installed, not running (n copies)* / *running · path*.
  Launch and quit followed by KVO on `runningApplications` (no polling);
  Launch Services is asked only when Coucou's running copies change.
  Look-alike names or folders never count. Also `WaitingPlace`: where a waiting
  Claude session is answered.
- **`Notch/NotchCoordination.swift`** — the table. Owner: Orbit, or Coucou
  while it runs. Surfaces, highest first: dashboard, expanded player, volume
  HUD, compact island (NotchOverlayCoordinator's order, never yielded), agent
  alert, Notch Companion (both yield to Coucou). `holder(inputs)` = first that
  wants the notch and is permitted. `NotchOverlayCoordinator`, Music Island and
  Sonic Pulse are unchanged.
- **Wiring (`OrbitApp`)** — the alert panel shows only when the table gives it
  the notch (replaces `AgentAlertPanel.shouldShow`). On each Coucou change:
  agent alerts off while it runs (no capsule, no VoiceOver announcement; the
  preference is kept), Notch Companion occluded via Orbit Pet's existing
  `companionOccluded` input, `coucouAnswersClaude` = running **and** its
  `nb-hook` is Claude's PermissionRequest hook (settings read, never written).
  Monitoring, the store, timelines, Insights, the dashboard, Music Island and
  Sonic Pulse are untouched.
- **Where to answer** — Claude Code waiting sessions show **"Answer in Coucou"**
  when Coucou answers Claude and the session runs in VS Code or Cursor (what
  Coucou 0.2.2 cards), otherwise **"Waiting in terminal"**: status pill,
  detail banner, Overview's attention list, Approvals note. Other agents keep
  "Needs you · inferred". The adapter's two waiting summaries are now
  place-neutral ("Asked a question (inferred; Orbit doesn't answer it)",
  "Waiting for you (inferred from Claude's notification)"); stored rows keep
  their old text.
- **Orbit Pet** — `AgentMood` (needs you > recent failure (10 min) > working >
  none; real sessions only) on the existing `PetModel.agentMood`, followed
  through Observation. No state, timer or drawing changes yet: a later stage
  shows it on the same cat. No second mascot: the Notch Companion steps aside
  while Coucou has the notch; the Desktop Pet isn't in the notch.
- **Settings › AI Hub › Notifications** — a Coucou row with its state and what
  Orbit does about it; the Claude hooks note names Coucou.
- **Debug only** — `coucou:state`, `coucou:watch:<bundle ID>|default` (which app
  counts as Coucou, in memory), and the `aihub:` checks above.

### 21.3 Tests

`NotchCoordinationTests` (9): both installed copies, which copy runs, App
Store ID, look-alikes refused; launch/quit reported once each, unrelated apps
ignored without a Launch Services lookup, deletion; the table equals
`NotchOverlayCoordinator.decide` for every input combination under both
owners; only alert and companion yield; the alert's free-slot rule (moved from
`theAlertOnlyTakesAFreeSlot`); alerts suppressed while monitoring continues;
"Answer in Coucou" / "Waiting in terminal" routing incl. Cursor, Terminal,
other agents; Coucou hook detection; pet mood and companion occlusion.
`AIHubRenderTests.whereToAnswerAndChangesRender` (1). Full suite: **532 tests,
three consecutive runs passing.**

### 21.4 Visual QA and live checks

- Renders (`ORBIT_RENDER=1`): `docs/screenshots/ai-hub-2/11-session-answer-in-coucou.png`,
  `12-overview-answer-in-coucou.png`, `13-session-waiting-in-terminal.png`,
  `14-session-changes-diff.png`; all 1–10 re-rendered unchanged. Plus the
  live app's real Changes tab rendered in-process.
- QA harness fix: `HubScroll`'s static render let long content overflow and
  centre (the real diff showed its middle); it now takes the space it's given
  like a ScrollView.
- Live: Orbit reports *installed, not running (2 copies)* —
  `/Applications/Coucou.app/`, `~/Desktop/Coucou 2.app/`. Transitions tried
  live with Chess standing in (`coucou:watch:com.apple.Chess`, demo mode on in
  memory for alert traffic): launch → owner `coucou`, alerts off, companion
  occluded, no alert shown for 12 s of demo traffic; quit → owner `orbit`,
  alerts back and shown. Restored with `coucou:watch:default`.
- Coucou untouched: `nb-hook`/`nb-hook.py` hashes as in §20.3, `nb-hook`,
  `nb.sock` and its preferences still dated 2026-10-27, 13 `nb-hook` entries
  in `~/.claude/settings.json` (Orbit's 12, none `PermissionRequest`), both
  copies' signatures valid. Coucou was never launched.
- Orbit idle CPU after relaunch: 0.0 % (5 samples).

### 21.5 Known limits

- **Dashboard hover:** both apps open on a hover at the notch; Coucou's island
  draws above Orbit's dashboard. Not changed: a click-only Orbit would be
  unreachable while Coucou captures the pointer there.
- **Music Island and volume HUD are not suppressed** while Coucou runs (they
  don't duplicate Coucou and sit below the notch); Coucou's expanded card can
  cover them. One row in the table if they should yield too.
- **Routing matches Coucou 0.2.2.** Newer versions can card terminal sessions
  (a Coucou setting Orbit doesn't read); those would still say "Waiting in
  terminal".
- **A permission Coucou holds isn't seen by Orbit** (no PermissionRequest hook,
  D1): such a session shows "Working" until Claude reports waiting.
  "Answer in Coucou" with Coucou actually running is verified by tests and a
  stand-in app only — Coucou itself was not launched.
- Untracked files show +0/−0 in the file list (numstat vs HEAD); "this
  session" marks files it read as well as changed.
- The pet's failure mood ages out at the next session change, not on a timer.
- Live checks added simulated sessions to `demo.sqlite` (demo store only).

### 21.6 Files

New: `Sources/Orbit/AIHub/CoucouPresence.swift`,
`Sources/Orbit/Notch/NotchCoordination.swift`,
`Tests/OrbitTests/NotchCoordinationTests.swift`, renders 11–14.
Changed: `OrbitApp.swift` (wiring, debug checks), `AIHubService.swift`,
`AgentAlerts.swift` (`shouldShow` removed), `AgentSessionsView.swift`
(wording, empty-diff fix), `AIHubDesign.swift` (`HubStatus` waiting label,
`HubScroll` static render), `ClaudeHookInstaller.swift` (read-only Coucou
check), `ClaudeCodeAdapter.swift` (two summaries), `PetModel.swift`
(`AgentMood`), `SettingsWindow.swift`, `AIHubAlertsInsightsTests.swift`,
`AIHubRenderTests.swift`, this file. Not touched: `.vscode/launch.json`,
`Orbit/`, anything of Coucou's. Nothing committed or pushed.

---

## 22. Milestone 3: Orbit Notch Companion (2026-11-14)

Builds on §21 (decision A). Product decisions given for this milestone:
Coucou owns the notch while it runs (companion and alerts stay suppressed);
Music Island and the volume HUD only where Coucou can't overlap or cover
them; the dashboard stays reachable without the notch trigger; Orbit's own
idle/compact/expanded states when Coucou is absent; Orbit Pet is the only
character. D1–D3 unchanged; nothing of Coucou's touched or launched.

### 22.1 What was built

- **`Pet/NotchCompanion.swift`** — the island model. Table-driven phases
  `hidden → idle (the cat peeks) → compact (one line of live activity) →
  expanded (after a click)`; events `available`, `active`, `tap`, `collapse`,
  `spaceChanged`; anything not in the table is ignored. Rows: active sessions
  plus finished/failed ones for 10 min, most urgent first (needs you >
  failed > working > finished > quiet, then most recent), at most 6, real and
  simulated (labelled). Headline per row: "Answer in Coucou" / "Waiting in
  terminal" (§21) for waiting Claude sessions, the latest tool summary while
  working, the error while failed. A finished turn or a failure shows for 5 s
  (the only timer, event-driven). Expanded: session switching (click or ← →,
  wrapping), the selected session's repository through `CodeChangeService`
  (hardened git, off the main thread), its own files first and one file's diff.
  VoiceOver announcements for needs-you, finished and failed while it stands
  in for agent alerts.
- **`Pet/NotchCompanionPanel.swift`** — its window (non-activating, sized to
  the phase, not on full-screen Spaces, key only while expanded, Escape and
  ← →, outside click collapses; grows at once, shrinks after the collapse
  animation) and the views: idle cat; compact cat + agent mark + session +
  headline + tone symbol + "+N"; expanded session chips, status pill, Open
  <app>, Show in Finder, "AI Hub" (opens the dashboard on that session), file
  chips and a coloured diff from the first hunk. HubTokens throughout, so
  Increase Contrast applies; every state is symbol + words; Reduce Motion
  (Orbit's or the system's) turns transitions into fades and the cat still.
- **The cat** (`PetRig`) — the same Orbit Pet and the same `PetModel` as the
  Desktop Pet (no second mascot). New: `AgentCue` one-shots (tail flick on
  tool activity, at most every 2 s; ears and a small hop when it needs you; a
  happy hop when finished; a shake when failed), each under a second, never
  repeating, none while hidden or with Reduce Motion; and the agents' mood as
  a still rest pose (focused, perked up, a little down). The Desktop Pet's rig
  keeps no mood.
- **NotchCoordination** — the companion is last in line (dashboard >
  expanded player > volume HUD > compact island > agent alert > companion).
  Under Coucou only the dashboard is left: Music Island and the volume HUD now
  yield too (decision 2 — Orbit can't see Coucou's island state without
  polling another app's windows, so it steps aside while Coucou runs). The
  app applies it: Sonic Pulse off (listeners removed), the island's window
  covered (its state untouched; an open player collapses), alerts off,
  companion hidden. On quit everything comes back.
- **Dashboard entry point** — `Notch/DashboardHotKey.swift`: **⌃⌥⌘O** opens
  or closes the dashboard (Carbon `RegisterEventHotKey`: no permission; Coucou
  uses ⌘⇧N and ⌃⌥+key). While Coucou runs, Orbit's closed notch trigger
  ignores the pointer and approaching drags, so only Coucou answers hover and
  drops at the notch.
- **Agent alerts** — while the companion is on, it says what the alerts would
  (alerts off); with the companion off, alerts work as before.
- **Wiring** (`OrbitApp`) — inputs through Observation, with a generation
  guard so display sleep, wake and lock (not observable) refresh without
  stacking observers; `AIHubService.onEvents` feeds the companion each batch;
  the pet model counts the companion as unseen when it's hidden or not on the
  active Space, so nothing animates unseen. Settings › Pet and the Coucou row
  describe it. Debug commands: `pet:companion:on|off`,
  `companion:state|tap|collapse|next`, `dashboard:toggle`.

### 22.2 Verification

- **Tests:** `NotchCompanionTests` (11): the full transition table; the
  lifecycle with no timers at rest or while working; finished/failed moments
  ending by themselves, cue throttling, shutdown leaving nothing; multi-agent
  ranking, Coucou/terminal headlines, switching and wrap, a vanished
  selection, the row cap, approvals; files newest first; geometry on a
  notched display, an external display without a notch and at a screen edge;
  Space change collapsing, display sleep and occlusion hiding (pet stops, no
  timers); Coucou launch hiding an expanded island and quit restoring it; the
  priority ladder and Coucou's; cues as one-shots, mood as a still pose,
  Reduce Motion; renders of every phase with a **real git diff**.
  `NotchCoordinationTests` updated for decision 2. Full suite **543 tests,
  three consecutive passes**. Of 9 full runs this milestone, 2 failed only on
  the known `SonicPulseTests.turningItOffStopsEverythingAndOnRestoresIt` flake
  (§17/§18: real-time sleeps under load; unmodified approved module; 5/5 alone).
- **Renders** (`ORBIT_RENDER=1`): `docs/screenshots/notch-companion/`
  1-idle, 2-compact-working, 3-compact-needs-you, 4-compact-finished,
  5-expanded-diff, 6-expanded-increased-contrast, 7-expanded-other-session.
  QA fixed: the cat's still was upside down, the expanded header touched the
  top edge, the preview spent lines on git headers.
- **Live** (pet and companion turned on in memory only; preferences
  untouched; relaunched on saved settings afterwards): shortcut registered;
  the companion showed this Claude session compact, expanded with the Orbit
  repository's 52 changed files and a diff; agent alerts off while it's on;
  hidden while the display slept. Coucou transitions with Chess standing in
  (`coucou:watch`): launch → companion hidden, volume HUD off (0 listeners),
  island covered, trigger yielded, ⌃⌥⌘O opened the dashboard; quit → companion
  compact, HUD on (3 listeners), island uncovered, trigger back.
- **Measurements** (debug build, 20 s CPU-time deltas, the Mac unattended):

  | State | CPU | Footprint |
  |---|---|---|
  | Companion off (hidden) | 0.05 % | 26 MB |
  | Compact, cat asleep (user away) | 0.00 % | 26 MB |
  | Compact, cat awake (2 cues played) | 0.00 % | 26 MB |
  | Expanded, diff shown | 0.00 % | 28 MB |

  No repeating animations in any state.

### 22.3 Known limits

- **Key status not verified live.** The checks ran while the screen was
  locked (frontmost `loginwindow`), when no app's window can become key. The
  expanded companion and ⌃⌥⌘O use the same `makeKey` path as the music island;
  a real click makes the panel key. Escape and ← → are unverified live.
- **Space changes and full screen** were tested, not driven live (that needs
  input automation, i.e. a new permission).
- After Orbit relaunches, a session's own files are known only from new
  events (they're in memory), so the first diff shown may be another changed
  file until the session touches one.
- Music Island and the volume HUD are off for as long as Coucou runs, even
  when Coucou's island is small (no window polling).
- The companion and the Desktop Pet are one pet (one `PetModel`): with both
  on, the notch cat mirrors the desktop cat's state (pre-existing design).
- Primary display only, like the dashboard and the music island.

### 22.4 Files

New: `Sources/Orbit/Pet/NotchCompanion.swift`, `Sources/Orbit/Pet/NotchCompanionPanel.swift`,
`Sources/Orbit/Notch/DashboardHotKey.swift`, `Tests/OrbitTests/NotchCompanionTests.swift`,
`docs/screenshots/notch-companion/` (7 renders). Changed: `PetRig.swift`
(mood pose, cues), `PetModel.swift` (`AgentCue`), `NotchCoordination.swift`
(music and HUD yield), `NotchPanel.swift` (trigger yield, keyboard toggle),
`AIHubService.swift` (`onEvents`), `OrbitApp.swift`, `SettingsWindow.swift`,
`NotchCoordinationTests.swift`, this file. Not touched: Coucou, hooks,
`~/.claude/settings.json`, `.vscode/launch.json`, `Orbit/`. Nothing committed.

---

## 23. Milestone 4: Advanced agent interactions (2026-11-14)

Builds on §21–22. D1 (Claude Code observe-only), D2, D3 unchanged; Coucou
untouched; no new permission, installation, credential, listener or command
execution.

### 23.1 Answering only where an adapter is verified

- **Found:** the bridge accepted blocking requests from the real hook
  adapters (Codex, Copilot CLI, Cursor, Gemini CLI, Antigravity) and the UI
  would have offered Allow/Deny, although their reply formats were never
  verified against those agents (§16) and §4 says buttons come only from
  verified capabilities.
- **Now:** `AgentCapabilities.answerPermissions` / `.answerQuestions`. Only the
  simulated agents declare them (verified end to end in Phase 4). Claude Code
  stays `observe` (D1); the hook adapters stay `observe` until verified with
  the user's approval. Three locks: the bridge closes an unanswerable request
  at once (the agent asks its user immediately, counted as `unanswerable` in
  Settings › Connection Health); `ApprovalManager.supports` refuses to list or
  decide it; the AI Hub card and the companion show no buttons for it.

### 23.2 Structured questions

`ApprovalQuestion` (header, question, choices with optional descriptions,
multi-select): at most 4 questions × 6 choices, every text one redacted line,
headers and labels unique, malformed entries dropped. `ApprovalDecision.answers`
is sent only when every question is answered with offered choices (one each
unless multi-select, nothing extra); the audit records "Database: SQLite;
Extras: Seed data, Indexes". Only Orbit's own vocabulary carries them — i.e.
the simulated agents today (every other demo question is structured). Among
real agents only OpenCode documents a form reply (§3), and it isn't connected;
Claude's AskUserQuestion stays Coucou's/the terminal's (D1). `QuestionForm`
(radio or checkbox choices, Send Answers once valid) is shared by the AI Hub's
Approvals page and the companion.

### 23.3 The companion, session by session

- **Switching:** compact shows the lead session plus up to three other
  sessions' marks (tone dot; click opens that session expanded). Expanded:
  chips (← →, or 1–6 by position), a request lock on sessions asking.
  Sessions that send a request before any event get their own row.
- **Per session:** tabs Activity · Changes · Requests (opens on Requests when
  the session is asking, else Changes). Activity = the session's saved and
  live events (`AIHubService.timeline`), newest first; this also restores the
  session's own files after Orbit relaunches (fixes §22.3). Changes = the
  repository with the session's files first; ↑ ↓ step through files; **live**:
  a file change from the selected session reloads the diff (one git reload at
  a time, one more if edits arrived meanwhile), keeping the file being read.
- **Requests:** a card per waiting request (agent, every line of the input,
  SwiftUI-driven countdown — no timer of Orbit's — Deny / Allow Once, choices,
  or the structured form), decision errors, and the session's last four
  outcomes. Claude Code sessions say where Claude asks (Coucou or its
  terminal); never buttons.
- **Keys** (expanded): ← → 1–6 ↑ ↓, Return opens the session's app, Escape.
  VoiceOver: chips, tabs, file chips and choices carry their state
  (`isSelected`); request cards read the full input. Increase Contrast and
  Reduce Motion as §22.

### 23.4 Files dropped on a session (investigated, minimal)

Weighed: typing into the terminal/editor (needs Accessibility — refused);
an agent-supported "attach" input for a session Orbit didn't start (none
documented, §3; Claude is observe-only); copying files into the project
(writes where the agent works); window-context capture (out of scope).
Built: `SessionAttachment` — drop files on the compact island (lead session),
a chip or the details column: local file URLs only, at most 10, must exist,
no control characters in the name, deduplicated and standardised; their paths
go on the clipboard in POSIX single quotes (`$(…)`, backticks and quotes stay
inert), the session's app comes forward, and the island says "Copied 2 paths:
paste into Terminal with ⌘V". Orbit never reads, copies, moves, uploads or
runs the files; simulated sessions refuse. Known: an *image* dragged close to
the notch still opens the dashboard's screenshot drop zone, as before.

### 23.5 Verification

- **Tests:** `AgentInteractionTests` (15): only verified adapters declare
  answering; the Approval Center refuses and replies at once; the real bridge
  closes a Codex request in under 3 s with no answer and counts it; structured
  questions parsed defensively (secrets redacted, duplicates, bad shapes,
  caps); answer validation and output; readable audit; malformed requests
  refused; requests ranking sessions incl. request-only ones, opening on
  Requests, number keys; expiry and withdrawal clearing rows; activity from the
  saved timeline plus live events; the live diff following a real git edit and
  ↑ ↓ wrapping; drop safety and quoting on a private pasteboard; the drop
  notice; under Coucou the companion is hidden while the AI Hub still answers;
  renders. `NotchCompanionTests` updated for per-session requests. Full suite
  **558 tests**; four full runs: one failed only on the known
  `SonicPulseTests.turningItOffStopsEverythingAndOnRestoresIt` flake, then
  **three consecutive passes**.
- **Renders** (`docs/screenshots/notch-companion/`): 8-compact-several-sessions,
  9-expanded-permission, 10-expanded-structured-question, 11-expanded-activity,
  12-expanded-claude-observe-only, 13-ai-hub-structured-question (and 1–7
  re-rendered). QA fixed: drop targets drew as "unsupported" boxes in
  ImageRenderer (skipped in static renders), sessions with a real request said
  "Needs you · inferred" (now "Request waiting"), a crowded compact line, and
  identical "Sim…" chips for untitled sessions (now their session ID).
- **Live** (companion and demo mode on in memory; relaunched on saved settings
  after): simulated requests reached the companion as attention rows and led
  the compact line; expanded on them; 36 messages accepted, 0 invalid.
  Coucou unchanged (hashes, dates, 13 entries; Orbit 12, none
  PermissionRequest).

### 23.6 Known limits

- No real agent can be answered yet: that needs a verified adapter (its hooks
  installed with the user's approval and checked end to end).
- Dropping a file is a clipboard hand-off, not an upload; the user pastes it.
- Keyboard control of the expanded companion is still unverified live (§22.3:
  the checks ran with the screen locked).
- Pending simulated requests outlive demo mode until they expire (≤ 60 s), as
  in the AI Hub.

### 23.7 Files

New: `Sources/Orbit/AIHub/SessionAttachment.swift`,
`Tests/OrbitTests/AgentInteractionTests.swift`, renders 8–13. Changed:
`AgentModels.swift` (capabilities), `AgentRegistry.swift` (structured
questions, `.answers`, demo capabilities), `HookAdapter.swift` (`.answers` →
no output), `AgentBridgeServer.swift` (refusal, counter), `ApprovalManager.swift`
(`supports`, structured answers), `AIHubService.swift` (`canAnswer`),
`AIHubDesign.swift` (`QuestionForm`), `AgentSessionsView.swift` (approval
card gating and form), `DemoAgents.swift` (structured question),
`SettingsWindow.swift` (counter), `NotchCompanion.swift`,
`NotchCompanionPanel.swift`, `OrbitApp.swift` (wiring, attach),
`NotchCompanionTests.swift`, this file. Not touched: Coucou, hooks,
`~/.claude/settings.json`, `.vscode/launch.json`, `Orbit/`. Nothing committed.

## 24. Agent identity (2026-11-14, Control Center expansion M5)

Recorded in full in `docs/ORBIT_ROADMAP.md` (M5). Summary: `AgentAvatar` no
longer shows two-letter monograms. It shows the vendor's own app icon read
from the installed app via Launch Services (`AgentIcons`, cached, misses
remembered; Orbit bundles no logos), else an original SF Symbol glyph on
the agent's colour (`AgentStyle.glyph`). Simulated agents always show the
glyph with a dashed ring. Antigravity installed as "Antigravity IDE.app" is
now discovered. D1, D2 and D3 are unchanged: Claude Code stays observe-only,
no listener was added, and no credentials are persisted.

## 25. Jump to agent and weekly recap (2026-11-14, Control Center Milestone 9)

Recorded in `docs/ORBIT_ROADMAP.md` (M10 §4–5). `AIHubService.openOrigin`
now goes through `AgentJump` (editor project window by fixed URL scheme →
exact terminal process by PID → app → project folder); no Accessibility,
no Apple Events, no shell; nothing from an event picks what runs. Insights
gained active sessions, files touched, zero-filled days, a week-over-week
trend only when the previous week was recorded, highlights, and a
"history starts" notice. D1, D2 and D3 are unchanged.

## 26. Contextual integration (2026-11-15, Milestone 14)

- **Alert rules** (`AgentAlertRules`, Settings › AI Hub › Notifications):
  priority needs-you › failed › finished; simultaneous finishes grouped (real
  and simulated never mixed); per-agent mute; finished on/off; quiet hours
  (needs-you still shows); queued alerts expire after 30 s; optional system
  sound for needs-you/failed (never in quiet hours); last 30 outcomes in
  memory. Display rules are unchanged: lowest priority in the notch slot,
  none while Coucou runs, no approval buttons.
- **Automations** listen to real alerts (`AgentAlerts.onAlert`, before the
  display rules, never for simulated agents): agent needs you / finishes →
  a fixed, local action. Nothing taken from an agent's text is ever run.
- **Shelf in session detail**: files on the File Shelf inside the session's
  working folder; a click copies the shell-quoted path. Orbit never types,
  sends or runs anything in the agent.
- **Suggested quick action** "Go to <agent>" for a waiting session uses
  AgentJump (§25), as precise as public APIs allow.
- **This Week** and the **Daily Digest** read `Insights` (§25) only while the
  AI Hub is on; estimates say "about".

## 27. One notch slot for everything (2026-11-15, Milestone 15)

`NotchCoordination` gains two rows: the eye-break reminder and the status
pill (meetings, agents that need you or failed, on displays without wings).
Order: dashboard › expanded player › volume HUD › brightness HUD › compact
island › agent alert › eye break › status pill › companion. Every surface now
reads the same live inputs (one function), so none can overlap another. All
but the dashboard yield to Coucou (§22, unchanged). The pill's agent actions
are "Go to <agent>" (AgentJump, §25) and "AI Hub"; never an answer or an
approval (D1).

## 28. Agent sessions in the launcher (2026-11-15, Milestone 16)

The Universal Launcher lists real (never simulated) agent sessions active in
the last 14 days; Return goes to the session's app through AgentJump (§25),
else opens the AI Hub. Workspaces count a session as theirs when its folder
is one of the workspace's projects. Nothing here answers, approves or sends
anything to an agent (D1); no network (D2); nothing stored beyond the
launcher's recents (ids and titles, launcher.json) (D3).

## 29. Agents in the Context Engine (2026-11-15, Milestone 17)

The engine reads real sessions (never simulated) from the last day: waiting
→ "needs you" (opens the session's app via AgentJump, else its detail),
failed → "inspect" (the session's detail in the AI Hub), finished → "review"
(its Changes tab), working during an upcoming meeting → "check it first".
Suggestions only open things in Orbit or the agent's own app; nothing is
answered or approved (D1), nothing leaves the Mac (D2), only click outcomes
are stored (D3). Automations still never fire for simulated agents.
