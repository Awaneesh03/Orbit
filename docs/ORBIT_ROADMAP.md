# Orbit Roadmap — Control Center expansion (from 2026-11-14)

This file tracks the work after AI Hub Milestones 1–4 (see `docs/AI_HUB_SPEC.md`
§20–23, which stay the historical record for those). Each milestone below adds
a dated section; earlier sections are never rewritten, only appended to.

Status words used throughout:

- **Implemented**: works end to end and has automated tests.
- **Partial**: some of it works; the gap is named.
- **Simulated**: works against Orbit's simulated agents or fixtures only.
- **Unverified**: the code exists but nobody has run it against the real thing.
- **Blocked**: needs an external decision, credential or approval.
- **Not possible (public API)**: macOS offers no public API; the alternative is named.

---

## M0. Baseline (2026-11-14)

- `scripts/test.sh`: **558 tests, 0 failures** on the working tree as found
  (one run before any change). The known Sonic Pulse flake
  (`SonicPulseTests.turningItOffStopsEverythingAndOnRestoresIt`) did not fire.
- The untracked `Orbit/` folder at the repo root is an old (Nov 5) copy of the
  project. It is not part of the package and is left untouched.
- `docs/ORBIT_ROADMAP.md` did not exist; this file starts it.

## M1. Research and architecture audit (2026-11-14)

### Sources read

- Sapphire: `github.com/cshariq/Sapphire` (AGPL-3.0) and `sapphire-app.tech`;
  third-party review (favtray.com) for v3.0 additions and permissions.
- Coucou: `github.com/Louis-CFM/coucou` README (Mac 0.6.0, 2026-11-12) and
  the earlier read-only audit in `AI_HUB_SPEC.md` §20.
- LinkedIn: Member Post Analytics API (`/rest/memberCreatorPostAnalytics`,
  scope `r_member_postAnalytics`, part of the Community Management API
  product, launched July 2025), Microsoft Learn docs.

### Architecture as found

| Layer | What exists | Reuse rule |
|---|---|---|
| Dashboard | `DashboardSection` tabs → `DashboardModel` → widgets from `WidgetRegistry.builtIn` | New features are widgets in an existing or new category; adding one is one line in `builtIn`. |
| Widget contract | `DashboardWidget`: metadata, `WidgetState`, `start()/stop()` lifecycle (work only while visible), `content(_:)` | Every new widget follows it: no polling while hidden. |
| Persistence | `JSONFile`/`Persisted` (atomic, tolerant decoding), per-feature JSON files | New settings get their own file; no shared mega-file. |
| Briefing | `BriefingPreferences` (briefing.json, versioned, migrates v1 lists) | Calendar → News swap is a version bump with a migration. |
| Notch | `NotchPanel` (dashboard), `MusicIsland`, `SystemHUDPanel` (Sonic Pulse volume HUD), `NotchCoordination` (Coucou priority), `NotchCompanion` | Keep `NotchCoordination` as the single arbiter of who owns the notch. |
| AI Hub | `AgentRegistry`, adapters, `HubStore` (SQLite), `AgentBridgeServer` (Unix socket), `ApprovalManager`, `AgentSessionsView` | Identity changes go through `AgentStyle`/`AgentAvatar` only (10 call sites). |
| Pet | `PetModel`, `PetRig` (SwiftUI shapes), `DesktopPetPanel`, `NotchCompanion` | Replace the renderer, keep the model/behaviour API. |

### Feature comparison

Sapphire's paid AI tiers (Blip Agent, Circle to Search, Gemini Live, sports
feeds) and features that need private frameworks or Screen Recording are
listed so the gap is explicit, but are not targets.

| Feature | Sapphire / Coucou capability | Orbit status (found) | Required work |
|---|---|---|---|
| Volume HUD | Sapphire: HUD with Spotify controls | Implemented (Sonic Pulse) | Restyle with the notch redesign |
| Brightness HUD / XDR boost | Sapphire: HUD + 1,600-nit boost | Missing | **Not possible (public API)**: no public brightness read/write or key interception without Accessibility event taps; XDR boost uses private EDR tricks. Alternative: none shipped |
| Wi-Fi details & networks | Sapphire: Bluetooth connect notices; no Wi-Fi list found | Online/offline only | CoreWLAN interface details, scan, known-network marking (Location permission), IP/gateway/DNS via SystemConfiguration |
| Bluetooth devices | Sapphire: Fast Connect, connect banners | Missing | IOBluetooth paired-device list, connection state |
| Per-app volume, 10-band EQ | Sapphire: Pro Audio Mixer | Missing | **Not possible (public API) without a driver**: system-wide EQ needs an installed audio server plug-in (HAL driver) or process taps + an aggregate device. Alternative: output/input device picker (public Core Audio) |
| Audio device switching | Sapphire: device EQ, multi-device | Volume read only | Core Audio default input/output switching |
| Battery details | Sapphire: 80 % charge limit, cycle wear | Percent and charging only | Cycle count, health, condition, temperature, time remaining (IOKit, public). Charge limit: **not possible (public API)** (SMC writes); link to System Settings › Battery |
| File Shelf | Both | Screenshot Vault (images only) | General file shelf (any file, bookmarks, AirDrop via `NSSharingService`) |
| Clipboard history | Sapphire: infinite history | Missing | `NSPasteboard.changeCount` sampling only while enabled; concealed/transient types skipped; local file |
| Quick Notes | Sapphire | Missing | Notes widget (notes.json) |
| Keep Awake | Both (Caffeinate) | Missing | `IOPMAssertionCreateWithName`, with timer |
| Snap Zones | Sapphire | Missing | Needs Accessibility permission (AXUIElement). Deferred: high-permission feature, asked separately |
| Music, lyrics, visualiser | Sapphire: waveform, lyrics | Implemented (Music Island, equalizer, Apple Music + Brave YouTube) | Lyrics: no licensed public lyrics API; not shipped |
| Camera Mirror | Sapphire | Missing | AVCaptureSession preview (Camera permission, on demand only) |
| Focus / Pomodoro | Coucou: Coucoudoro | Implemented (Pomodoro widget) | Reuse |
| Eye-break 20-20-20 | Sapphire | Missing | Timer + notch banner, off by default |
| App switcher | Sapphire 3.0 | Missing | Replacing ⌘-Tab needs an event tap (Accessibility). Not shipped |
| Menu bar customisation | Sapphire | Missing | Hiding other apps' items needs private APIs/Accessibility. **Not shipped**; Orbit keeps the menu bar untouched (user rule) |
| App lock / Face ID | Sapphire | Missing | Third-party "Face ID" is camera ML with no Secure Enclave guarantee. **Not shipped**; Touch ID via LocalAuthentication if an Orbit feature needs gating |
| Calendar | Sapphire | Implemented (EventKit) | Removed from Briefing per request; stays a widget |
| Weather | Both | Implemented (Open-Meteo) | Reuse |
| Lock-screen widgets | Sapphire | Missing | **Not possible (public API)** on the macOS lock screen |
| Nearby Share (Android) | Sapphire | Missing | Out of scope (network listener, D2) |
| Tech news | — | Missing | RSS/Atom reader, curated sources, cache, dedupe |
| LinkedIn analytics | — | Missing | OAuth (ASWebAuthenticationSession), Keychain tokens, Member Post Analytics API; **Blocked** on LinkedIn app approval |
| Multi-agent hub | Coucou: 12 agents, pills | Implemented (Milestones 1–4) | Reuse |
| Agent identity | Coucou: per-agent pill/colour | Two-letter monograms ("CC") | Official icon of the vendor app installed on this Mac, original glyph fallback (no bundled trademarks) |
| Approvals / questions | Coucou: Allow/Deny/Always, AskUserQuestion | Simulated agents only (D1 keeps Claude observe-only) | Unchanged by decision D1 |
| Live diff ticker | Coucou | Implemented (Changes tab, live Git diff) | Reuse |
| Weekly recap / usage | Coucou: weekly recap, plan usage | Partial (Insights) | Weekly recap from HubStore (local data only) |
| Plan usage (Claude/Codex limits) | Coucou (GitHub build, relay) | Missing | Needs Coucou's relay or undocumented endpoints. **Not shipped** |
| Terminal jump | Coucou | Missing | Activating the terminal app by PID is public (`NSRunningApplication`); exact tab needs Apple Events |
| Chat | Coucou: many providers | Implemented (ChatService) | Reuse |
| Phone companion | Coucou: CloudKit + APNs relay | Architecture only (`CompanionProtocol`) | D2: no listener without approval |
| Dictation / notetaker | Coucou Flow | Missing | Out of scope for a notch control centre (Mic permission, large model download) |
| WhatsApp / Mail / Stripe pills | Coucou | Missing | Out of scope (unofficial gateways, credentials, D3) |
| Desktop pet | Coucou: Mochi (Canvas, drawn in code) | Implemented (SwiftUI-shape cat) | Redesign: see M7 |

### Pet asset pipeline findings

- **OpenHiggsfield / Fanimate**: generative video tools. They produce video
  sequences, not rigged characters. Using them means uploading reference
  images to a hosted model and shipping video frames; neither fits a
  battery-light, local, photo-private pet. Not used.
- **Rive / Spine / Live2D**: good runtimes, but each adds a large third-party
  runtime and an authoring tool Orbit's environment does not have. Not added.
- **Chosen**: a vector rig drawn with Core Graphics in a single `Canvas`
  (one draw per frame, paused when hidden), with layered shading, fur
  gradients and spring-damped secondary motion (tail, ears, breathing), the
  same technique Coucou's Mochi uses. Photo personalisation samples colours
  locally and never uploads the photo.

### Milestone order

1. Research and audit (this section).
2. System tab: network, Bluetooth, audio devices, battery health, Keep Awake.
3. Briefing: technology news replaces Calendar.
4. LinkedIn integration (architecture + unavailable state until approved).
5. AI Hub: agent identity.
6. Notch redesign.
7. Desktop pet redesign.
8. Productivity additions: clipboard history, quick notes, eye-break.
9. Integration, performance, security testing.
10. Polish and docs.

---

## M2. System tab (2026-11-14) — Implemented

The System tab is now a page with a rail: **Overview** (the existing CPU &
memory, Storage, Network, Battery widgets plus a new Keep Awake widget),
**Wi-Fi**, **Bluetooth**, **Sound**, **Power**.

| Feature | Status | API / permission |
|---|---|---|
| Current Wi-Fi: name, RSSI, noise/SNR, Tx rate, channel, band, security, power toggle | Implemented | CoreWLAN; the **name needs Location** (macOS rule); shown as "Network name hidden" with an Allow button until granted |
| Scan: networks merged by name, strongest wins, current → known → signal | Implemented | CoreWLAN scan (names need Location) |
| Known networks marked | Implemented | `CWConfiguration.networkProfiles` (names only; passwords never read) |
| Join | Partial | Known/open networks join with the password macOS keeps; anything needing a password opens Wi-Fi Settings (native flow). **Manual verification needed** |
| IP, router, DNS | Implemented | SystemConfiguration dynamic store + getifaddrs; no permission |
| Diagnostics (radio → signal → address → router → DNS → lookup time → internet) | Implemented | One system DNS lookup of apple.com, user-initiated |
| Live updates | Implemented | CoreWLAN events + NWPathMonitor while the pane is visible; scans only on open/Refresh |
| Bluetooth paired devices, connect/disconnect, Apple HID battery | Implemented, **unverified** (permission not granted in this session) | IOBluetooth; Bluetooth permission asked only on "Show Devices" (`NSBluetoothAlwaysUsageDescription` added) |
| Bluetooth power toggle | **Not possible (public API)** | Links to Bluetooth Settings |
| Audio output/input device switching, volume sliders | Implemented | Core Audio, no permission |
| Battery: maximum capacity, cycles, condition, time remaining, adapter watts | Implemented | IOKit registry + IOPS, no permission |
| Charge limit | **Not possible (public API)** | Explained, links to Battery Settings |
| Keep Awake (15 min / 1 h / 2 h / until off) | Implemented | `IOPMAssertionCreateWithName` (released on stop, expiry and quit) |

New controls in the design system: `OrbitSwitch`, `OrbitSlider`,
`OrbitLinkButton` (native AppKit-backed controls look inactive in the
non-key panel and can't be drawn offscreen). `WidgetGrid` and `HubScroll`
are now offscreen-render aware.

Screenshots (rendered offscreen from the live app, real data): `docs/screenshots/m2-system/`.

Bugs found by the new tests and fixed: Keep Awake's timer measured from the
injected clock instead of the real one; a fixed 400 ms wait flaked under
full-suite load (now polls).

## M3. Briefing: Tech News replaces Calendar (2026-11-14) — Implemented

- Sources (official public feeds, all HTTPS, checked live 2026-11-14):
  OpenAI, Google DeepMind, MIT Technology Review, Ars Technica, The Verge
  (tech), TechCrunch, Wired (AI tag; its main feed is mostly reviews), Hacker
  News, GitHub Blog, Krebs on Security, Apple Newsroom, Microsoft.
  **Anthropic publishes no feed** (404); its news arrives via the outlets.
- Shown: headline, source, category, relative time (exact on hover), the
  feed's own description (never generated), link opens in the browser
  (http/https only). Categories: AI, Software, Startups, Security, Tech
  (dedicated sources keep their subject; others by headline keywords).
- De-duplication: canonical links (tracking parameters, `www.`, fragments
  stripped) and near-identical headlines across outlets. No outlet floods
  the top (each extra story from one source counts as 3 h older).
- Refresh: when shown if older than 30 min, every 30 min while visible,
  Refresh button; cached to `news-cache.json` so it opens offline; partial
  feed failures are named, total failure shows offline/retry.
- Briefing layout (briefing.json **version 3**): the first expanded widget
  is the feature, two cells wide and both rows tall. Default: Weather and
  Tasks beside Tech News, no scrolling (the 3.8 "fits without scrolling"
  rule holds). Daily Goals, Clock and LinkedIn are offered in Settings ›
  Widgets › Daily Briefing. Calendar is no longer offered there (it remains
  a normal widget). Migration: a version-2 preset file moves to the new
  preset; a customised list swaps Calendar for Tech News in place, keeping
  its size.

Screenshot: `docs/screenshots/m3-briefing/briefing.png` (live feeds).

## M4. LinkedIn (2026-11-14) — Architecture implemented, **Blocked** on LinkedIn approval

- API: `GET /rest/memberCreatorPostAnalytics?q=me` (LinkedIn-Version 202610,
  Rest.li 2.0) for IMPRESSION, MEMBERS_REACHED, REACTION, COMMENT, RESHARE;
  last 28 full days vs the 28 before, daily impressions and reactions;
  `GET /v2/userinfo` for the name. Both `metricType` response shapes
  (pre- and post-202605) parse.
- Shown: four metric tiles with change vs the previous period, daily
  impressions, engagement rate, members reached, link to LinkedIn's own
  creator analytics. Off by default; enable in Settings › Daily Briefing.
- States: not connected (instructions + token field), token expired (401),
  **app not approved (403)**, rate-limited, offline, ready. No sample data.
- **What you must do** (external): create a LinkedIn developer app, request
  the *Community Management API* product (Member Post Analytics,
  `r_member_postAnalytics`); LinkedIn reviews it. Add *Sign In with LinkedIn
  using OpenID Connect* for your name. Then generate a token in the
  developer portal's Token Generator (openid, profile,
  r_member_postAnalytics) and paste it into the widget.
- **Per-post list ("latest posts") is not implemented**: listing a member's
  own posts needs `r_member_social`, which LinkedIn restricts to approved
  partners. The widget links to LinkedIn's creator analytics instead.
- Decisions respected: **D3**: the token is kept in memory only
  (`MemoryCredentialStore`); `KeychainCredentialStore` (data-protection
  Keychain, this device only) is implemented and tested, switched on once a
  stable signing identity is approved. **D2**: no loopback OAuth listener;
  the in-app OAuth flow needs a one-shot 127.0.0.1 listener (RFC 8252) and
  waits for that approval.
- Screenshots: `docs/screenshots/m4-linkedin/` (`disconnected`,
  `not-approved`, and `dashboard-FIXTURE.png`, which uses the documented
  response shape, **not live data**).

## M5. AI Hub agent identity (2026-11-14) — Implemented

- Two-letter monograms removed. Each agent shows the **vendor's own app
  icon read from the installed app** (as Finder does; Orbit bundles no
  logos): Claude Code → Claude.app, Codex → Codex/ChatGPT app, Copilot CLI →
  GitHub Desktop, Cursor → Cursor.app, Gemini CLI → Gemini app,
  Antigravity → Antigravity. Without the app: an original SF Symbol glyph on
  the agent's colour (asterisk, curly braces, airplane, cursor rays,
  sparkle, up-arrow, terminal). Simulated agents always use the glyph with a
  dashed ring.
- Fixed: Antigravity installed as "Antigravity IDE.app" wasn't discovered.
- Coucou parity items not repeated here are already implemented (Milestones
  1–4) or listed as not shipped in M1's table with the reason.

## M6. Notch visual redesign (2026-11-14) — Implemented (visual language), live check pending

Directions considered:
- **A. Glass pills below the notch** (roughly the previous look): rejected.
  Detached from the hardware, reads grey on light wallpapers.
- **B. Hardware extension** (**chosen**): every surface is true black and
  grows out of the notch: concave shoulders where it meets the menu bar,
  generous bottom corners, a single rim of light along the lower edge.
  Colour only from content (artwork accent, agent identity, state).
- **C. Ambient halo** (a glow under the notch): rejected as primary.
  Too little information, and a constant animation costs battery.

Implemented: `NotchShape` + `notchSurface()` (attached: dashboard,
Notch Companion) and `islandSurface()` (floating: Music Island, volume HUD),
in `Sources/Orbit/Notch/NotchSurface.swift`. Window frames and the 740×420
dashboard are unchanged (the shoulders sit inside the frame), so
`NotchCoordination`, Coucou coexistence and every geometry test are
untouched. The dashboard keeps the user's opacity setting (over Liquid
Glass when below 1).

Not done (next step, needs a geometry change and its own review): a
Dynamic-Island-style "wings" compact state that flanks the camera instead
of hanging below it.

Screenshots: `docs/screenshots/m6-notch/dashboard-briefing.png` (whole
dashboard, live data), `island-compact.png`, `island-expanded.png`, and the
re-rendered companion states in `docs/screenshots/notch-companion/`.
The volume HUD's meter and speaker are Core Animation views that offscreen
renders can't draw: **the HUD needs a live visual check**.

## M7. Desktop pet (2026-11-14) — Implemented, live check pending

Research outcome (see M1): generative tools (OpenHiggsfield, Fanimate)
output video, not a rig, and would need uploads and installs; Rive, Spine
and Live2D add large runtimes and an authoring tool. The existing Core
Animation rig (render-server animation, rasterized parts, no timers,
measured cheap in Stage 5.3) is the right engine; this milestone upgrades
what it draws and does.

- **Cat and dog.** Dogs: floppy ears hung in front of the head, a snout,
  a dark nose, round pupils, a thicker tail that wags. Cats gain cheek ruffs.
- **Six coats**: Ginger, Tuxedo, Silver Tabby (cats); Golden Retriever,
  Beagle, Grey & White (dogs). Settings › Pet › Character.
- **Your photo**: "Use a Photo of a Cat/Dog…" reads the picture on this Mac
  (Vision lifts the animal from the background), takes the typical fur
  colour and its light markings, and keeps only those two colours in
  preferences.json. The photo is never stored, copied or uploaded.
- **New behaviour**: every fourth idle fidget adds a bigger gesture:
  looking around (eyes lead the head), a full stretch, or sitting down for a
  moment. One-shots under 2.6 s; still in between; none with Reduce Motion.
  Existing walk, run, sleep, play, drag, blink, ear and tail cues kept.
- Runtime look changes rebuild the rig in place (state kept).
- Tried and removed: a fur-grain texture. It looked like sackcloth and
  relied on a blend mode offscreen renders ignore.

Honest limit: this is a better illustrated character, not a photoreal
one. A photoreal pet needs generated sprite sequences (a pipeline that
installs/runs external tools and may upload reference images), which is
your decision.

Screenshots: `docs/screenshots/m7-pet/` (every coat: idle, happy, sleeping).

## M8. Productivity additions (2026-11-14) — Implemented

| Feature | Problem it solves | Public API / permission | Privacy & performance |
|---|---|---|---|
| Clipboard history (Productivity tab, widget) | Re-copying something you copied minutes ago | NSPasteboard; none | **Off by default**; memory only, never on disk; skips items apps mark concealed/transient (password managers); checks the change count every 1.5 s only while on |
| Quick Note (widget) | A scratch pad one hover away | none | quicknote.json, saved 0.6 s after typing pauses and when hidden |
| Keep Awake (M2) | Long builds and downloads | IOPMAssertion | released on stop/expiry/quit |

Prioritised next additions (not built): **eye-break 20-20-20 reminder**
(timer + notch banner, off by default); **terminal jump** for agent
sessions (activate the terminal app by PID); **weekly agent recap** from
HubStore; **file shelf** for any file type (extend Screenshot Vault).
Considered and declined: app switcher / menu-bar hiding / app lock (need
Accessibility or private APIs, or are security theatre), lyrics (no
licensed public API), Nearby Share (network listener, D2).

## M9. Verification (2026-11-14)

- Full suite: see the final runs below. New suites: SystemControlsTests,
  NewsTests, LinkedInTests, AgentIdentityTests, NotchSurfaceTests,
  PetLookTests, ClipboardNoteTests (plus updated Briefing, registry and
  settings tests).
- A **SIGSEGV** in one full run was root-caused: the LinkedIn test double
  wasn't thread-safe, and a cancelled refresh kept calling LinkedIn
  because `LinkedInClient` never checked cancellation. Both fixed; a test
  now pins that a cancelled refresh stops calling the API.

### Manual verification still needed

- Wi-Fi: grant Location, then check names, known networks, Join on a known
  network, the power switch.
- Bluetooth: "Show Devices" (permission prompt), connect/disconnect.
- Sound: switching output/input; the sliders.
- Volume HUD and Music Island in the new style on light and dark wallpapers.
- Pet: each coat live on the desktop, the gestures, "Use a Photo…".
- Clipboard history while copying from a password manager.
- LinkedIn: with an approved app and token.

### External decisions / authorisations needed

1. **D3**: approve a stable local signing identity so LinkedIn (and other)
   tokens can live in the Keychain across rebuilds.
2. **D2**: approve a one-shot loopback (127.0.0.1) listener for in-app
   LinkedIn OAuth, or keep pasting tokens from the Token Generator.
3. **LinkedIn**: create the developer app and request the Community
   Management API (Member Post Analytics).
4. **Pet**: whether to pursue a photoreal sprite pipeline (external tools).

### Final runs (2026-11-14)

- Final code: run 1 **608/609**: the known Sonic Pulse flake
  (`turningItOffStopsEverythingAndOnRestoresIt`, line 399, a 30 ms timing
  count in the show logic; this work changed only that view's background).
  Runs 2, 3, 4: **609/609, three consecutive passes**.
- Baseline was 558; 51 tests added.
- Idle after launch (dashboard closed, pet off by default): **0.0 % CPU,
  88 MB RSS** (`ps`). New background work exists only while a feature is
  visible or on: Wi-Fi events while its pane shows; news refresh every
  30 min while visible; clipboard check every 1.5 s only when turned on.

---

## M10. Milestone 9 — HUDs, compact notch, productivity, agents (2026-11-14)

Baseline before starting: **609/609**. After: **641/641, three consecutive
passes** (32 tests added). Idle after launch: 0.0–0.1 % CPU, ~80 MB RSS,
energy impact 0.1 (`top`), ~40 idle wakeups/s of which 4/s are the
brightness safety poll (only while the brightness HUD is on).

### 1. Brightness HUD — observation implemented; key detection needs your one press

Research (measured on this MacBook Air M4, macOS 27):

| Question | Answer | Evidence |
|---|---|---|
| **Control** brightness | **Not possible with public API.** `IODisplayGetFloatParameter`/`SetFloatParameter` return `kIOReturnUnsupported` (0xe00002c7) on Apple Silicon; the working setters (DisplayServices, CoreDisplay) are private. Orbit never sets brightness. | probe, 2026-11-14 |
| **Observe** brightness | **Yes.** `AppleARMBacklight` publishes `IODisplayParameters.brightness {min 0, max 65536, value}` in the I/O Registry, read with public `IORegistryEntryCreateCFProperty` (16 µs/read). Read live as 0.500 in the running app. | probe + live log |
| Notice a change | Three sources, each logged: IOKit interest notifications on the backlight; a global `.systemDefined` monitor for the brightness keys (NX keys 2/3; **no permission is requested**; macOS delivers or doesn't); a 4 Hz registry read as the safety net. Which of the first two macOS delivers can't be proven without a physical key press. | code + live pipeline check |
| Render the HUD | **Yes.** Same slot, window, motion, priorities and Coucou rule as the volume HUD; warm 16-segment meter, sun symbol, percentage. | renders, live simulated change |

Integration: `NotchOverlay.brightnessHUD`, `NotchCoordination.Surface.brightnessHUD`
(yields to Coucou like volume), the newest system HUD wins the shared slot
(no stacking or flicker), dashboard and full player suppress it, Reduce
Motion and Increase Contrast respected. Settings › General › Volume and
Brightness: Show Brightness HUD (on), Stay for 1–5 s (both HUDs).

**Your check:** press brightness up/down, then run
`log show --last 1m --predicate 'subsystem == "com.awaneeshgupta.orbit"' | grep brightness`.
"noticed by key" or "noticed by interest" means instant; only "noticed by
poll" means up to 250 ms late. Also confirm the % matches Control Center's slider.

Screenshots: `docs/screenshots/m9-brightness/` (low, half, full, increased contrast).

### 2. Camera-flanking compact notch — implemented, opt-in

Settings › General › Compact Notch › **Beside the camera** (default stays
"Below the notch"). One black bar widens out of the notch to the notch's
height: left wing the agent's icon or the artwork, right wing the status
(needs you / failed / working) or the equalizer. Priority: an agent that
needs you, failed or is working, then music while playing. Hidden while the
dashboard is open, under Coucou, or without a notch. The window ignores the
mouse entirely (menu-bar items under it and the notch hover keep working),
not on full-screen Spaces, joins all Spaces. In this mode the compact music
pill and the companion stand aside; the expanded player, HUDs and dashboard
are unchanged. Screenshots: `docs/screenshots/m9-wings/`. **Needs a live
look**, especially how far the wings reach into your menu bar.

### 3. Eye-break reminder — implemented, off by default

20-20-20 by default; work interval 5–90 min, break 10–120 s; pause/resume;
quiet mode (no motion, short text); Snooze (5 min) and Skip. One sleeping
task, no polling. Skips the reminder when you've already been idle for the
break length (public `CGEventSource` idle time, no permission); display
sleep and screen lock count as a break. The reminder is a pill below the
notch (no permission); it waits while the dashboard or full player is open,
or Coucou has the notch. **Focus mode**: apps can't read Focus without the
Focus Status entitlement, and macOS notifications (which do respect Focus)
need a notification permission. Not requested; your decision. Widget: Productivity › Eye Break.

### 4. Jump to agent terminal — implemented (AI Hub session header)

`AgentJump` plans the most precise public option and says which it is:
editors with a folder URL scheme (VS Code, Insiders, Cursor, Windsurf, Zed)
open **the project's window**; terminals (Terminal, iTerm2, Ghostty, Warp…)
activate **the exact process** hosting the session (choosing the tab would
need Apple Events / Automation: not requested); otherwise the app, else
the project folder. The scheme comes from a fixed table, the path must be an
existing folder; no shell, no Accessibility.

### 5. Weekly recap — implemented (AI Hub › Insights)

Sessions, finished, failed, active now, files touched (distinct paths from
the event timeline), events per day (**all 7 days, quiet days as 0**:
previously missing days vanished), week-over-week trend (only when last
week was recorded), active time by agent, tools, projects, highlights
(top agent, busiest day, longest session, top project/tool, failures).
"History starts …" is shown when the week isn't fully recorded. Real
agents only; local. Screenshot: `docs/screenshots/ai-hub-2/6-insights.png` (fixture).

### 6. File Shelf — implemented (Productivity › File Shelf)

Drop files to shelve **references** (bookmarks; originals never moved or
modified; follows a move). "Keep a Copy in Orbit" makes an explicit copy in
`Shelf/<id>/<name>` (one folder per item: never overwrites; ≤ 2 GB; files
only). Drag items out; Quick Look thumbnails; "Copy Path for an Agent"
(shell-quoted, the AI Hub's safe hand-off); Show in Finder. Expiry 1/3/7/30
days (default 7): copies are deleted, references only forgotten. Links
refused; nothing uploaded; originals touched only on your action. Separate
from the Screenshot Vault (the notch's image drop still goes to the Vault).

### 7. Realistic pet — research and proof of concept

| Option | Verdict |
|---|---|
| Open-Higgsfield (MIT front end) | Calls hosted models through Muapi.ai: **paid, uploads**. Produces images/video, not a rig. Usable only as a source of frames, with your approval. |
| "Fanimate" | No such project found. Nearest: AnimateAnyone (code unreleased), Champ, MIMO (research, CUDA GPUs). Not usable on this Mac. |
| **Rive** | MIT runtime, SwiftPM, macOS 13.1+, state machines with blended transitions and bones/meshes: **best route to natural motion.** Needs an authored `.riv` character (artist or licensed asset) and a binary dependency. |
| Live2D Cubism, Spine | Proprietary licences / paid editors. Not chosen. |
| Sprite frames | Works with any frame source. |

Proof of concept (`Sources/Orbit/Pet/SpriteClip.swift`): frames → one
atlas → a discrete `contentsRect` keyframe animation in the render server
(no per-frame work, Reduce Motion shows a still frame). 8 frames at
240 × 200 px cost < 1.6 MB. Strip: `docs/screenshots/m9-pet-poc/atlas-strip.png`.
**Decision needed**: adopt Rive (dependency + a commissioned or licensed
cat/dog `.riv`), or approve generated frames (paid service, uploads).

### 8. Recommended next (prioritised)

1. **Live verification pass** of M9 (brightness keys, wings, eye-break pill, shelf drag-out).
2. **Rive pet** once you choose an asset source (state machine: idle/walk/run/sit/sleep with blends).
3. **Notch drop routing**: dropping non-images on the notch goes to the File Shelf (images stay with the Vault).
4. **Calendar "next meeting" in the wings** (EventKit, already authorised in Calendar widget): a 10-minute heads-up beside the camera.
5. **Focus-aware quiet hours** for all Orbit reminders (needs the notification permission decision).
6. **Per-project agent recap** (Insights filtered by project) and a Monday recap prompt.
Declined again: app switcher, menu-bar hiding, lyrics (see M1).

### Sonic Pulse flake

`turningItOffStopsEverythingAndOnRestoresIt` failed once in a 55-test
filtered run. Isolated: 12/12 passes; 5 loaded reruns: no failure; final
3 × 641: no failure. The changed code path (enable/disable now also
starts/stops the brightness source; brightness inputs are inert in that
rig) was traced and doesn't add a cover call. The assertion now records the
cover sequence, overlay and phase, so the next occurrence names its cause.
Still classified as the pre-existing timing flake, not fixed.

### Permissions and decisions for you

- None was requested by this milestone.
- Optional: notification permission (eye-break via Focus-aware notifications).
- Pet: Rive dependency + asset source, or paid generated frames.
- Earlier ones still open: D3 (Keychain signing), D2 (LinkedIn OAuth listener), LinkedIn app approval.

---

## M11. Milestone 10: Rive pet engine (2026-11-14). Engine done; artwork awaiting approval

Baseline 641/641. Details: `docs/PET_CHARACTERS.md`.

- **Implemented**: Rive 6.29.0 (MIT) via SwiftPM with CLT, embedded and
  signed; manifest-driven characters (bundled + user-installed), validated,
  shared by desktop and notch, released on switch, vector fallback;
  `PetRig` skins with state/gesture/click/agent-cue/mood forwarding;
  behaviour: roaming and idle gestures independent, liveliness, name, test
  characters toggle, reset; tolerant `PetLook` decoding.
- **Energy, measured live** (`ps`, `sample`): pet off 0.0 %; vector idle
  0.0 %; Rive held 0.0 % (no display-link frames); Rive burst ~10 % for
  2.5 s; before the fix ~14 % always and a 0.5 % leak after detaching
  (MetalKit display link; fixed with on-demand MTKView and paused-at-creation
  skins). +10–15 MB RSS with a character; first load 0.37 s.
- **Characters**: free CC BY Rive Marketplace candidates inspected
  (structure via the runtime, listing previews): best free dog Interactive
  Dog (jouri), best free cat Cat Avatar (leonardohernandezmurillo); none is a
  matched production pair with walk/run/sit/sleep. **Paid commission
  awaiting approval**, about $100–650 per character on the market.
- **Not done**: petting gesture and double-click wiring (need a character
  with those inputs), cursor-following eyes (energy), Rive screenshots
  (no offscreen renderer on macOS).

---

## M12. Zero-cost policy and free pet characters (2026-11-14)

**Policy (permanent):** Orbit's budget is $0. No commissions, premium assets,
paid software, subscriptions, hosted AI or paid integrations, now or in any
future milestone. Free, permissive licences only (CC0, MIT, Apache 2.0; CC BY
with attribution), verified for commercial use, modification and in-app
redistribution. Where something can't be done free, the limitation is
documented with a free alternative. **M11's recommendation to commission
artwork is withdrawn.**

**Pet, done for free:**
- Found and verified a matched, professional cat and dog: "Cat & Dog Free
  Sprites" by pzUH (OpenGameArt), **CC0 1.0** (checked on the source page):
  Idle, Walk, Run, Jump, Fall, Hurt, Slide, Dead at 556 × 504 px each.
- Built Orbit characters from it (`scripts/build-pet-atlases.swift`): shared
  crop, 200 px strips, a new sleeping frame (CC0 permits changes), manifests
  and licence files in `Resources/Pets/pzuh-cat` and `pzuh-dog`, bundled by
  `scripts/run.sh`. Unused: Hurt and Dead (X eyes; not right for a companion).
- `SpritePetSkin` plays them in the render server (still frames free, loops
  only while moving). The **Tabby is now the default** character; "Orbit
  illustrated" (coats, photo colours) remains selectable. Rive kept for free
  Rive characters (none suitable found; the CC BY test dog stays a fixture).
- Measured live: settled 0.0 % CPU; ~7.3 MB decoded per character; load
  2–6 ms. Screenshots: `docs/screenshots/m10-pets/`.
- Limits: the art's colours are fixed (no coat recolouring); no `concerned`
  pose; sleeping is one still frame (no breathing, by the energy rule).

---

## M13. Milestone 10.1: dog-selection bug (2026-11-14) — fixed and verified

**Root cause** (found from the saved `preferences.json`: `character: "pzuh-cat"`,
`coat: "golden"`): Settings › Pet had two pickers offering dogs. The *Coat*
picker (Cats/Dogs, incl. Golden Retriever) only styled Orbit's illustrated
pet, which is hidden whenever an animated character is drawn; the
*Character* picker, defaulting to the Tabby since M10, chose what is
actually drawn. The dog choice was saved correctly but applied to the
hidden pet, so the desktop always showed the cat. Preference keys,
persistence, atlases, caching and both renderers were verified correct.

**Fix**
- Settings › Pet: one **Pet** picker first, labelled with species
  ("Tabby (cat)", "Shiba (dog)", "Orbit illustrated"), with a live preview
  of the selected pet and its licence; the Coat section appears only for
  "Orbit illustrated"; a fallback is explained in place.
- `PetSelection` (new): one function resolves and applies the selection to
  the desktop and notch renderers alike and reports `.character`,
  `.builtIn` or `.fallback(reason)`; a character that can't load shows the
  illustrated pet (never the other animal) and logs why.
- One-time migration (`PetLook.selectionVersion` 2): a 10.0 file with the
  default Tabby and a dog coat becomes the Shiba (that was the user's choice).
- `SpritePetView` sizes its sprite on every frame change (not only at the
  next display pass). Diagnostics: `pet:selection`, `pet:select:<id>`.

**Verified**
- Assets: `scripts/build-pet-atlases.swift` rebuilt both characters
  byte-identical; 7 clips each; cat cells 191 × 200, dog 184 × 200; frame
  counts match the manifests; CC0 licence files unchanged.
- Tests (`PetSelectionTests`, 8): cat/dog on both renderers by atlas
  identity, switching both ways, release of the previous files, relaunch via
  `PreferencesModel`, the exact buggy file migrating to the dog, missing /
  corrupt atlas and invalid metadata falling back to the illustrated pet,
  unknown ids, switching while walking and dragged, sleep/wake/hidden cycles,
  agent finished/attention on the selected animal's own jump frames and
  failed doing nothing, desktop and notch hosts holding the same character
  in their real layer trees (rendered: `docs/screenshots/m10-1-selection/`),
  Settings preview.
- Live (this Mac): relaunch restored the dog on desktop and notch
  (`desktop=pzuh-dog notch=pzuh-dog`); switching through the Settings path
  dog → cat → dog updated both renderers immediately and the saved file
  each time; settled CPU 0.0 %, 84 MB.

### M13 follow-up: "the pet never walks, it stays put until dragged" (2026-11-14) — fixed

- **Root cause** (traced live with `state` logs): after 2 minutes without
  input the pet goes to sleep, and only a click or drag on the pet, a
  Space change, display wake or unlock could wake it. Ordinary keyboard and
  pointer use never did (nothing reported it), so a pet that fell asleep
  while you were away stayed asleep in place: no wandering, until a drag
  woke it. Present since Stage 5.3; the sprite dog's lounging sleep frame
  just made it obvious.
- **Fix** (`PetActivity`): while asleep, one idle-time read every 3 s (the
  same public `CGEventSource` call already used; no permission, no event
  monitoring, nothing animating); any input since wakes the pet, and
  wandering resumes. Also: a hidden pet (covered, display asleep, off) now
  hides the character's view instead of leaving a frozen frame.
- **Not a bug, by design:** while windows completely cover the pet
  (macOS occlusion), it pauses entirely; it resumes when uncovered.
- **Verified:** unit test (an hour asleep stays asleep; typing wakes it
  within 3 s without a click); live: woken → idle → a run ~27 s later
  ("lively") moved the window from x 0 to x 423 → idle.

## M14. Milestone 14: contextual intelligence, smart workflows, deep integration (2026-11-15)

Zero-cost throughout: native APIs (EventKit, Quick Look, IOKit power
assertions, NSSound system sounds), Orbit's own data, and optional local
models the user installs themselves. No new permissions, no new
dependencies, no network beyond 127.0.0.1 for the optional model.

### Inventory (audit before building)

| Feature | Current implementation (before M14) | Missing functionality | M14 change |
|---|---|---|---|
| Calendar | EventKit read-only widget, selected calendars, Disconnect switch | Cancelled events not filtered; nothing outside the dashboard | Cancelled occurrences dropped at the source; reused by the heads-up, digest, quick actions, automations |
| Notch wings | Agent status + music beside the camera (M9), click-through | No meetings | **Next-meeting heads-up** (below) |
| Agent alerts | 3-slot FIFO, 4 s each, finished throttled per session | Priority, grouping, mute, quiet hours, expiry, history, sound | All added in `AgentAlerts` (below) |
| File Shelf | References vs copies, quoted path, expiry, thumbnails | Projects, search, recent order, preview, AI Hub link, multi-path | All added (below) |
| Weekly recap | AI Hub insights (agents, files, trend) | Tasks, goals, focus; focus sessions were never dated | **This Week** widget + dated focus log |
| Quick Actions | Four fixed app shortcuts | Context | **Suggested** row (below) |
| Local AI | Chat with Ollama/LM Studio (loopback only) | A briefing | **Daily Digest** widget with plain fallback |
| Automations | None | Everything | Fixed-menu rules in Settings › General |
| Pet selection | Fixed in M13 | — | Closed, untouched |

### 1. Next-meeting heads-up (priority) — `Notch/MeetingHeadsUp.swift`

- `MeetingCue.current`: the nearest timed event that starts within the
  notice window (default 30 min → `upcoming`, grey), within the urgent
  window (default 5 min → `soon`, amber), or started under 5 min ago
  (`started`, amber + camera glyph). All-day, cancelled, finished and
  far-off events never show; a meeting leaves the wings 5 min after it
  starts, so it never occupies the notch.
- Wings priority: agent needs you / failed → meeting soon or started →
  agent working → meeting heads-up → music.
- `MeetingWatcher` reads only with access already granted and the Calendar
  widget connected, from its chosen calendars; never asks for access. It
  sleeps until the next phase boundary (no polling), wakes on EventKit
  changes and on the widget's access/selection changes, and runs only while
  the wings could show it (Beside the camera + heads-up on + notched main
  display) or a meeting automation needs it.
- Left wing: title (truncated to fit the 64 pt wing, kept narrow so menu-bar
  items are never covered); right wing: glyph + countdown, updated on the
  meeting's own minute marks. VoiceOver reads title, start time, countdown.
- Settings › General › Compact Notch: on/off, heads-up 10–60 min, reminder
  1–10 min (tolerant decoding, clamped).
- **Click to open the event: not in the wings.** They are click-through by
  design (M9), so they never block the menu bar. The suggested quick action
  "Meeting in N min" opens Calendar from the dashboard.

### 2. Agent notifications — `AIHub/AgentAlerts.swift`

Priority queue (needs you › failed › finished); simultaneous finishes from
different agents become one "A and N others finished" (real and simulated
never mixed); per-agent mute; "finished" on/off; quiet hours (needs-you
still shows: work on hold); queued alerts expire after 30 s; optional
system sound (Tink/Basso) for needs-you/failed, never in quiet hours, off by
default; history of the last 30 (shown, grouped, muted, quiet, expired,
dropped, alerts off) in Settings › AI Hub › Notifications, memory only.
Still no approval buttons; Coucou rules unchanged.

### 3. File Shelf ↔ AI Hub / Developer Hub — `Widgets/FileShelf.swift`

Search (name or folder, every word), newest first, project filter, "Copy
paths" (each quoted, missing files named, never pasted), Quick Look
(read-only system preview), hover shows origin and project. Copies remember
their original path. Projects come from AI Hub session folders and
~/Developer **by string match only**: walking up the disk for `.git` would
read folders the drop didn't grant (and could raise the Documents/Desktop
prompt). Session detail in the AI Hub lists that project's shelf files; a
click copies the quoted path. Orbit never sends anything to an agent.

### 4. This Week — `Widgets/WeeklyInsights.swift`

Tasks done (dated by `completedAt`), daily goals met (goal history), focus
sessions (new `focusLog`, dated at the session's real end; earlier sessions
weren't dated and the widget says since when), agent sessions/active
hours/files/top project from the AI Hub. Trends only against a non-zero last
week; planned focus minutes and agent hours say "about".

### 5. Suggested quick actions — `Widgets/QuickActionsWidget.swift`

Up to three, urgent first: Go to the waiting agent (AgentJump), Meeting in N
min (opens Calendar), Pause (only if the source supports it), the latest
agent project (Finder), copy the newest shelf file's path. Public APIs only;
no Accessibility or Input Monitoring.

### 6. Daily Digest — `Widgets/DailyDigest.swift`

Facts with their source (weather, today's calendar, tasks due/overdue, top
two headlines, yesterday's agent work); the plain digest is always shown.
Optional local model (off by default): Ollama or LM Studio through
`ChatService`'s loopback-only providers; models are listed, never pulled;
on request or once a day. A grounding check rejects a model's text that
adds numbers not in the facts and keeps the plain digest. Available on the
Overview and the Briefing.

### 7. Automations — `Services/Automations.swift`

Triggers: meeting about to start, agent needs you, agent finishes (real
agents only). Conditions: any time, weekdays, while music plays. Actions:
pause music, keep awake 1 h (never shortens an active one), start a focus
session, open Calendar. Once a minute per rule; recent runs in Settings ›
General. Unknown saved rules (newer versions) are skipped, never run.

### Verification

- 698 tests (660 before): MeetingHeadsUpTests, AgentAlertRulesTests,
  FileShelfTests (+2), WeeklyInsightsTests, ContextActionsTests,
  DailyDigestTests, AutomationsTests; registry, briefing, alert tests updated.
- Renders: `docs/screenshots/m14-meeting/` (upcoming, soon, started),
  `m14-weekly/`, `m14-digest/`.
- Live: build launched; settled CPU 0.0–0.1 %, ~85 MB; meeting watcher off
  when not needed (no calendar reads); `quick:state` suggested "Orbit" (this
  repo's real Claude Code session); preferences restored after testing.

### Not verified here (manual)

- Wings on a notched main display: this Mac's main display is an external
  LF27T35 (no notch), so the wings correctly stay off. The cue, priorities
  and view are covered by tests and renders.
- Glass controls (Suggested row) can't render offscreen and screen capture
  needs Screen Recording (not requested): check the dashboard by eye.
- A real local model: Ollama/LM Studio aren't installed; covered with a
  stub provider (grounding, no-model, remote-URL refusal).
- Quick Look from the shelf's context menu; automation actions end to end.

### Recommendations (research, item 9)

| Idea | Value | Complexity | Privacy | Performance | Notes |
|---|---|---|---|---|---|
| Meeting heads-up in the pill below the notch too | High (main display here has no notch) | Low | Same data | None | Reuse `MeetingCue` in the compact island slot |
| "Join" for meetings with a video link | High | Low–medium | Reads event URL/notes locally | None | Open only https links on known hosts; never auto-join |
| Apple's on-device Foundation Models for the digest | Medium | Medium | On device | Model is the OS's | Free, no download; needs Apple Intelligence and an SDK check under CLT |
| Drag a shelf file onto an AI Hub session | Medium | Low | Clipboard only | None | Same quoted-path rule |
| More automation triggers (focus end, display connect, Wi-Fi network) | Medium | Low | Local | Event-driven | Keep the closed action list |
| Notification Center for needs-you while away | Medium | Low | Local | None | **New permission**: needs explicit approval |
| Focus mode awareness (quiet hours from Focus) | Medium | Low | Local | None | **New permission** (Focus status): needs approval |
| Weekly summary as Markdown to the clipboard | Low | Low | Local | None | |

## M15. Milestone 15: universal display experience, smart meetings, notch polish (2026-11-15)

### Root cause

Every Orbit surface already anchors to `NSScreen.screens.first` (the display
with the menu bar) and repositions on `didChangeScreenParameters`. The problem
was narrower: (1) the meeting heads-up's only presenter was the wings, which
require a notch on that display, so with the Samsung LF27T35 as main display
nothing could show it; (2) whether there's a notch isn't observable, and a
display change only *repositioned* the wings, so switching main displays (lid,
plug, unplug) left the wings vs nothing decision stale until something else
changed. Both fixed.

### Display-aware presentation — `Notch/ContextPill.swift`

- `DisplayProfile`: the primary display as plain values (frame, visible frame,
  camera areas, scale); tests use fixtures, the app reads `screens.first`.
- `StatusPresenter.choose(statusDisplay, compactStyle, hasNotch)`:
  Automatic = wings on a notched main display with "Beside the camera",
  otherwise the floating pill; "Floating pill on every display"; Off.
  Settings › General › Compact Notch › Status display.
- The **context pill**: a floating black capsule (design A of three
  prototypes, `docs/screenshots/m15-pill-prototypes/`), in the shared slot 6 pt
  below the menu bar or notch, centred, so it never covers menu-bar items and
  never imitates a notch on an external display. Adaptive width (132–360 pt
  from its text), its own window shadow, click to expand (Join, Calendar, Go
  to agent, AI Hub, Dismiss), collapses when the pointer leaves. Content:
  meetings (all phases) and agents that need you or failed; never music
  (the island) or work in progress (no permanent obstruction). Dismiss hides
  that item in that phase: a meeting returns when it escalates.
- Display changes: `screensChanged` (also on display wake) repositions every
  panel and re-decides wings vs pill; one pill window and one wings window for
  the app's life (verified: 1 each after repeated changes). Not on full-screen
  Spaces (no `.fullScreenAuxiliary`), on every Space, never key.
- Reduce Motion (opacity only) and Increase Contrast (solid rim, brighter
  text) follow the system live.

### Meetings everywhere

The same `MeetingWatcher` and `MeetingCue` (M14) feed the wings or the pill;
no second engine, no polling. The watcher runs whenever the heads-up can show
(any presenter but Off) or a meeting automation needs it.

### Join — `Services/MeetingLink.swift`

Links read locally from EventKit's URL, location and notes (`NSDataDetector`).
The event's URL field may be any plain https link; free text only Google
Meet, Zoom, Teams, Webex, Whereby, GoTo, Chime, Jitsi, Skype. Refused: http,
other schemes (`javascript:`, `file:`, `zoommtg:`), credentials, non-443
ports, bare/odd hosts, look-alikes (`meet.google.com.evil…`, `evilzoom.us`),
over 2 KB, text over 20 000 characters. Opened only on a click with
`NSWorkspace.open` (default browser, or the app registered for the link).
Join appears in the pill, the dashboard's Suggested row and the Calendar
widget's rows.

### Coordination — `Notch/NotchCoordination.swift`

One slot, one order: dashboard › expanded player › volume HUD › brightness
HUD › compact island › agent alert › **eye break** › **status pill** ›
companion. All surfaces now ask through one function with every live signal
(`slotInputs`): before, the agent alert didn't see the brightness HUD and the
eye break saw only the dashboard and expanded player. Coucou: all of these
yield (only the dashboard stays); unchanged.

### Smart meeting actions

With a meeting near, Suggested shows up to four: Join (with a link),
Calendar, Pause, Keep awake 1 h (not if already on), Focus (only 6+ minutes
out and the timer idle). They run the automations' own actions
(`runAutomation`), only when clicked.

### Sonic Pulse flake — fixed

`turningItOffStopsEverythingAndOnRestoresIt` counted the HUD panel's cover
reports in a 30 ms window; the HUD settles at 40 ms and the panel re-reports
then. Under a loaded full run the 30 ms sleep lasted past 40 ms. Confirmed
deterministically (settle 15 ms → `covers … true, true`, phase
`pendingDismissal`); the test now settles after 5 s. App behaviour was
correct (repeated reports are idempotent).

### Verification

- 712 tests (698 before): DisplayAwareTests (fixtures: Air 13" notched,
  Samsung 1920×1080 1×, 4K at 2× with a non-zero origin, 1280×800 with an
  auto-hidden menu bar; switching sequences; no display), MeetingLinkTests,
  ContextPillPrototypeTests; ContextActions updated.
- Live, built-in Air as main display (the Samsung was disconnected during
  this milestone): pill below the notch at the right place and width, expand,
  auto-dismiss; Automatic+Beside → wings (pill hidden); Floating pill → pill
  (wings hidden); Off → nothing and the watcher stops; the display-change path
  re-run 5× → one window each; preferences restored byte for byte.
- Idle CPU 0.0 % hidden and showing (the countdown redraws once a minute);
  85.5 MB, 90.9 MB once the pill's window has been created.
- Screenshots: `docs/screenshots/m15-pill/` (light, dark, Increase Contrast;
  drawn by AppKit in an offscreen window: ImageRenderer dims app icons),
  `m15-pill-prototypes/`.

### Known limitations

- Keyboard: the pill never becomes key (it must not steal focus), so its
  buttons are for the pointer and VoiceOver (accessibility actions Join,
  Calendar, Dismiss); the keyboard path is ⌃⌥⌘O and the Suggested row.
- While Coucou runs, the pill yields like every other notch surface; Join stays
  in the dashboard.
- External-display-as-main checked with fixtures only this time (not
  connected); the code path is the same as the notched case minus the notch.

## M16. Milestone 16: launcher, workspaces, battery and brightness intelligence (2026-11-15)

### Research (sources read, not only READMEs)

| Project | What its code does | Licence | Used by Orbit |
|---|---|---|---|
| OpenMacBattery (MuratDugan) | `proc_pid_rusage` v4/v6, `ri_billed_energy`/`ri_serviced_energy`; groups helpers by the outermost `.app` and its `CFBundleIdentifier` (`AppGrouping.swift`); optional calibration with `powermetrics` (sudo) | AGPL-3.0 | The approach only (no code): public counters, bundle grouping |
| App Energy Monitor (danwil02) | `psutil` per process + `powermetrics` system power (sudo, a NOPASSWD sudoers rule), split by fixed weights (CPU 60 %, I/O 20 %…) | Non-commercial | Rejected: needs sudo; the split is invented |
| MonitorControl | `Arm64DDC.swift`: `IOAVServiceCreateWithService`, `IOAVServiceReadI2C/WriteI2C` (not in Apple's public SDK; declared by the app), `CoreDisplay_DisplayCreateInfoDictionary` (private), EDID/ioreg scoring to match displays | MIT | Rejected: private interfaces |
| MacBrightnessKit | Built-in: `DisplayServices` (private framework); external: DDC via `IOAVService…` | MIT | Rejected: private |
| OpenDisplay | DisplayServices, SkyLight, DDC/CI with EDID matching; a "PublicAPIOnly" build drops those | GPL-3.0 | Rejected: private; GPL |

Activity Monitor's "Energy Impact" and the Battery menu's "Apps Using
Significant Energy" come from Apple's private power models (`powerd`,
coalitions); there is no public API for either.

### Battery intelligence — `Services/EnergyMonitor.swift`, `Widgets/BatteryWidget.swift`

- **Selected:** `proc_pid_rusage(RUSAGE_INFO_V6)` → `ri_energy_nj` (public libproc
  header, no privileges): the kernel's own per-process energy estimate in
  nanojoules. Measured on this Mac: 524 of 785 processes readable as the user
  (the rest are root/other users: WindowServer, kernel_task — left out, never
  guessed); a CPU load from VS Code's terminal read ≈ 5.9 W, 117 % CPU across
  77 processes, attributed to Visual Studio Code. CPU times in that struct are
  mach ticks: converted with `mach_timebase_info`.
- **Grouping:** outermost `.app` in the executable path; else the nearest app
  among the parent processes (`proc_pidinfo` PROC_PIDTBSDINFO); system daemons
  (/System, /usr, /sbin) aren't apps. This approximates Apple's private
  coalitions.
- **Shown as:** "≈ W", High (≥ 1 W) / Moderate (≥ 0.25 W), "In use" for the
  frontmost app, bring-to-front, Activity Monitor and Battery Settings links,
  and a footnote saying it's macOS's CPU-energy estimate (no display/GPU
  share) and not Activity Monitor's scale. If a Mac reports no energy at
  all, the list ranks by CPU and says "an estimate, not battery use".
- **Cost:** sampled every 5 s only while the Battery widget is on screen (or a
  debug client), off the main thread: 6–15 ms a sample; Orbit 0.0–0.5 % CPU
  while sampling. The last result stays cached.
- **Websites:** not attributable. Chromium's `chrome.processes` (per-tab
  process/CPU) exists only on the Dev channel; stable Brave/Chrome/Safari
  extensions get no energy data, and a browser's renderers are its own. A
  browser row says so; if Orbit's Brave helper is playing YouTube, the
  footnote names what's playing as context only, never as the cause.
- **Charge states:** on battery, charging, plugged in not charging (charge
  limit), fully charged, unavailable (`kIOPSIsChargingKey`,
  `kIOPSPowerSourceStateKey`, `kIOPSIsChargedKey`).
- **Charging animation:** a highlight sweeping through the fill every 1.8 s
  (one `CAGradientLayer` position animation, run by the window server), soft
  glow, bolt. Only while macOS says *charging* and the widget is on screen;
  never with Reduce Motion or the setting off (static glyph instead).

### Brightness — `Widgets/BrightnessWidget.swift`, `Services/Brightness.swift`

- Built-in: the existing public I/O Registry reading (`AppleARMBacklight`
  `IODisplayParameters`), now one monitor shared by the HUD and the new
  Brightness widget (clients; it runs while either needs it). Live reading on
  this Mac: 0.500. Bar, percentage, low/medium/high, per display.
- External: not readable with public APIs (DDC/CI needs `IOAVService…`);
  shown as "Not readable" with the reason. The Samsung LF27T35 wasn't
  connected during this milestone; whether it supports DDC/CI can't be
  checked without those interfaces either.
- Control: none (DisplayServices or DDC writes are private). "Display
  Settings…" opens the real control.

### Universal Launcher — `Launcher/`

⌃⌥Space by default (Settings › Launcher: ⌃⌥⌘L, ⌘⇧Space or off; ⌥Space left
out: it types a non-breaking space). `GlobalHotKey` (Carbon, no permission)
now checks the hotkey ID: before, the dashboard's handler would have answered
any Orbit hotkey. Searches apps (Applications folders, cached 10 min),
files and folders (Spotlight index, names only, debounced 160 ms; icons from
the file type), projects, agent sessions (14 days), the File Shelf, tasks,
goals, today's events, Settings sections (with keywords), Orbit actions and
workspaces. Fuzzy matching (exact › prefix › word start › anywhere › letters
in order, titles only), categories (Tab, ⌘1–⌘8), ↑↓, Return, ⌘Return reveal,
Escape. Recents and recent searches in launcher.json; missing files are
dropped with a note; scripts and executables are revealed, never run.
Measured: 3–11 ms per query on this Mac; 5 000 items under 150 ms in tests.
Spotlight preflights protected folders through `sandboxd` (no prompt):
Downloads, Desktop and Documents results appear only if Orbit already has
that access (verified in tccd's log: preflight, denied, no dialog).

### Workspace Profiles — `Services/Workspaces.swift`, Settings › Workspaces

Development, College, FixKaru, Personal to start; create, edit, duplicate,
delete, activate (launcher, Settings, Suggested). A profile keeps projects,
apps, task words, music (leave/pause), focus, keep awake, an Overview layout
and a schedule that only *suggests* switching. Activating changes Orbit and
does only what the profile asks; "Open Workspace" opens its apps and projects
on request. Nothing is closed, no file or system setting changes.

### Quick Actions, Settings, onboarding

Suggested adds: switch to a scheduled workspace, open the active one,
Activity Monitor when an app's energy is High, Battery Settings at ≤ 20 % on
battery, Display Settings with an external display. Settings: searchable
sidebar (titles and keywords), Get Started (shown once: ways in, every
permission and when it's asked, the ones never asked), Launcher, Workspaces,
General › Battery and Brightness.

### Verification

- 742 tests (712 before): EnergyBatteryTests, LauncherTests,
  WorkspaceBrightnessTests, Milestone16RenderTests; registry order updated.
  Real-hardware tests: this Mac's energy counters, displays, backlight
  reading, and a global hotkey registering.
- Live: shortcuts registered (⌃⌥Space, ⌃⌥⌘O); launcher queries on real data
  ("roadmap" → ORBIT_ROADMAP.md); focus returned to VS Code on close;
  energy attribution under load; brightness 0.500 and the shared monitor
  staying on for the HUD.
- Performance: process start → shortcuts registered ≈ 1 s; idle 0.0–0.1 %
  CPU, physical footprint 36 MB, 8 threads; sampling + brightness 0.0–0.5 %.
- Screenshots: `docs/screenshots/m16/` (battery: 5 states + expanded,
  brightness bands, launcher).

### Limitations

- Typing into the launcher after a real ⌃⌥Space press is a manual check:
  macOS's cooperative activation lets Orbit take focus after a user action,
  which automation here can't produce without Accessibility.
- Energy is CPU energy only; root/system processes are invisible; no
  per-website attribution.
- No external-display brightness; no brightness control.
- Charging animation and live charging states weren't seen live: the Mac was
  on battery at 100 % throughout.

## M17. Milestone 17: Context Engine and proactive intelligence (2026-11-15) — done

Reuse, don't re-monitor. The engine reads models Orbit already keeps current
(AI Hub sessions, MeetingWatcher, the Calendar widget's cached agenda,
Workspaces, Tasks, Goals, Pomodoro, BatteryWidget, EnergyMonitor, the Now
Playing coordinator, the File Shelf, NSScreen, Automations) through
registered **context sources**; Observation tells it when any of them change
(no polling), and it wakes on its own only at a known time (an expiry, a
snooze ending, a focus run ending, the evening goal check).

1. `Context/ContextEngine.swift`: snapshot, sources, change events (diffed,
   so a repeat isn't an event), suggestion rules, ranking, suppression with
   reasons, expiry, a short in-memory event log.
2. `Context/SuggestionFeedback.swift`: local learning (accept, dismiss,
   snooze, irrelevant, categories) in suggestions.json; clear/reset.
3. "Suggested for You" widget on the Overview (cards: title, why, primary +
   secondary action, dismiss/snooze/irrelevant); Quick Actions keeps its chips.
4. Workspace recommendations, smart Focus (25/50 min, resume, end summary),
   Daily Digest facts + separate suggestions, automation conditions and
   explanations from the same context.
5. Settings › Suggestions and Settings › Context Inspector.
6. Tests, screenshots, performance, three full runs.

### M17 results

**Architecture.** `Context/ContextEngine.swift`: `ContextSnapshot` (plain
values) filled by registered `ContextSource`s; `refresh()` reads them under
`withObservationTracking`, so any change in the models they read schedules
one refresh (coalesced 250 ms); `ContextDiff` turns real changes into events
(the same value set again isn't one); `ContextMemory` keeps the facts that
need history (the meeting that started and the workspace then, the focus run
being watched); `SuggestionRules.generate` → `SuggestionRanking.rank`
(shown + held back with reasons); a wake timer only for known moments
(expiry, snooze end, focus end, 15 min after a meeting, 17:00, midnight).

**Sources (11, nothing new monitored).** Dashboard open state, Workspaces,
AI Hub sessions (real, 24 h), Calendar (MeetingWatcher's cue + the Calendar
widget's cached agenda; the watcher also runs while calendar suggestions are
on), Tasks and goals, Focus (Pomodoro), Battery (one IOKit read per refresh)
and Energy (EnergyMonitor's last result, if < 60 s old), Music, File Shelf,
Displays (re-read on display changes), Automations.

**Suggestions.** Agent waiting (100), meeting started (96), low battery
≤ 10 % (94), meeting soon (92) / heads-up (78), agent failed (88, 2 h),
"check the agent before your meeting" (82), resume focus (72), focus summary
(66, 30 min), agent finished → review (60, 1 h), energy High (58), evening
goal (55), workspace recommendation (56 calendar · 50 agent in its project ·
46 schedule · 42 its tasks), back to the workspace after a meeting (50, 15
min), start focus 25/50 min (48), next task for the workspace (36). Each has
a title, detail, reason, symbol, priority, primary and optional secondary
action, and expiry where it matters. Charging: no battery suggestions.

**Ranking.** Score = priority + learning (accepted +3, dismissed −4,
snoozed −2 per time; bounded −30…+12). Held back, with the reason shown in
the inspector: suggestions off, category off, marked not relevant,
dismissed, snoozed (until …), expired, "held during your focus session"
(< 85 while a focus run is on, except focus's own), beyond the 2 (Calm,
default) / 3 / 5 shown.

**Where.** "Suggested for You" at the top of the Overview, only when there's
something (the grid keeps its room otherwise); while it shows, Quick
Actions' chips step aside (one place for suggestions). Never in the notch,
wings, pill, island or AI Hub. Card: icon, title, detail, primary button,
secondary (inline when alone, else first in the … menu), Why, Snooze,
Dismiss, Not Relevant, Turn off category.

**Focus.** 25/50-minute starts (the timer takes the length), resume when
paused, a summary when a run ends (tasks completed and agent sessions
finished *during* it, nothing else), and only urgent suggestions during a
run. Nothing is blocked.

**Daily Intelligence Briefing.** The Daily Digest adds workspace, daily
goals, agents waiting / finished today and focus sessions as facts;
suggestions appear separately as "Suggested (not facts)" and are never sent
to the local model.

**Learning and privacy.** Only clicks are recorded (suggestions.json:
counts per kind, dismissed/snoozed ids, "not relevant" kinds, last 50
titles + outcomes; no paths). Settings › Suggestions › Clear History and
Reset Learning. No keystrokes, screen contents or browser history.

**Automations.** Same engine (Milestone 14): new conditions "While on
battery" and "Not during a focus session" from the engine's context, a
reason on every run, runs shown in the inspector as automations.
Suggestions never execute anything; the one-a-minute rule and the
simulated-agent exclusion are unchanged.

**Context Inspector** (Settings): status, sources and errors, current
context, suggestions with score breakdown, held back with reasons, active
rules, the last 80 events (memory only; a switch turns recording off).

**Verification.** 759 tests (742 before): ContextEngineTests (17: sources,
failures, coalescing, duplicate events, every rule family, ranking and every
suppression reason, expiry, feedback + restart + reset, privacy of the saved
file, diagnostics off, briefing facts vs suggestions, automation conditions,
cost with 300 tasks + 150 agents: < 10 ms per refresh). Live: 11 sources, no
errors, ~1 ms per refresh, refreshes only on change; a simulated meeting
produced "Design review in 4 min" and "Check Claude Code before your meeting"
(this session was really working). Idle CPU 0.0–0.1 %, footprint 41 MB.
Screenshot: `docs/screenshots/m17/suggested-for-you.png`.

**Limitations.** Suggestions show only in the dashboard (by design: no
interruptions). Workspace "recently used" isn't tracked (no behaviour
history beyond clicks). Low battery is re-read when the dashboard opens, not
while it's closed. The energy source knows only what the Battery widget last
measured.

**Test-timing finding (fixed in the test, not the engine).** Under a loaded
full-suite run the main actor is busy, so the 250 ms coalesced refresh can
land later than a fixed 450 ms sleep: the coalescing test now waits for the
refresh, then checks no second one follows. It also showed that
`@Observable` doesn't notify when an `Equatable` property is set to the same
value, so a repeated value costs the engine nothing at all (not even a
refresh). Three consecutive full runs: 759/759.

## M18. Charging animation, redesigned (2026-11-15)

Charging detection was correct and is unchanged (`BatteryStatus.chargeState`).
The look is new (`Widgets/BatteryWidget.swift`):

- **The fill is the level.** A SwiftUI shape whose width is the real
  percentage (`BatteryGlyph.fillWidth`); the number and the fill share one
  curve (`BatteryStyle.levelAnimation`, 0.6 s) and move only between real
  readings (an unchanged reading doesn't touch the view).
- **Energy, all Core Animation** (`ChargingEffectsView`, clipped to the fill):
  a luminous band sweeping left → right (1.8 s), a liquid surface (a sine
  wave translated by exactly one wavelength: seamless, 2.6 s), tiny particles
  drifting toward the leading edge (CAEmitterLayer, 4 a second; none in a
  nearly empty battery), and a breathing glow at the leading edge where the
  charge "arrives" (2.2 s). Around it, the outline's green glow pulses
  (`ChargingGlowView`, 2.4 s) and a light crosses the bolt (`ChargeSweepView`,
  every 3.5 s). These are window-server animations: no per-frame work in
  Orbit.
- **When it runs** (`ChargeAnimationState.effect`): only while macOS says
  *charging*, the widget is on screen, the setting is on and Reduce Motion
  is off. Plugged in but not charging: plug glyph, no movement. Fully
  charged: full green fill and a checkmark. On battery: plain. Unavailable:
  no battery.
- **Completion** (`ChargeAnimationState.observe`): once, when Orbit saw it
  charging and then full within 15 minutes: one bright sweep and a glow that
  settles. Never for a battery already full at launch, never again on later
  refreshes; a new charge cycle can play it again.
- **Layout bug found in the frames and fixed:** the glow view sat in the
  battery's ZStack and stretched the outline; it's a background now.
- Battery glyph 46×22 → 54×26 pt so the effect reads at Overview size.

**Verified.** 765 tests (759 before): ChargingAnimationTests (state rules,
completion once / never at launch / not stale / reconnect cycle, widget
readings, fill = level, the real layers' animations in a window, the
seamless wave, a frame sequence). Frames posed at t (Core Animation runs out
of process, so frames set the layers to the values the animation passes
through; particles don't appear in them): `docs/screenshots/m18/charging.gif`,
`frame-*.png`, every state dark and over a light wallpaper (the dashboard is
always dark). Live, charging at 86 %: the real widget ran flow, surface,
breathe, particles and glow on a 41×20 fill (86 % of the inner width); Orbit
0.0–0.1 % CPU while it animated, WindowServer unchanged (~42 % on this Mac
with or without it); the layers are gone when the dashboard closes. The live
completion needs a charge to 100 %: not seen yet.

## M19. Public showcase and documentation (2026-11-17)

README, `docs/` (Architecture, Installation, Features, Privacy, Troubleshooting,
Contributing, public Roadmap, GitHub presentation notes), issue and pull request
templates, and an unpublished static site (`docs/index.html`). No app changes.

## M20. Sapphire parity, completed settings (2026-11-17)

Sapphire's features (github.com/cshariq/Sapphire, sapphire-app.tech) were listed
and each was built where public APIs allow it without a new permission; the
rest are recorded with the reason in `docs/FEATURES.md` › Compared with
Sapphire. The Quick Mirror was offered and declined (it would add Camera).

- **Bluetooth device notices** (`Notch/DeviceNotices.swift`): IOBluetooth's
  connect/disconnect notifications → a 3 s note in the shared slot, a new row
  in `NotchCoordination` after the eye break (before the status pill). Starts
  only when Bluetooth access is already granted (it follows
  `BluetoothModel.access`); devices connected at start are the baseline, a
  flapping device is announced once per state in 10 s, and a notice that
  can't get the slot is dropped, not queued. Settings › General › Devices.
- **Lyrics** (`Services/Lyrics.swift`): off by default; LRCLIB `/api/search`
  (no key) once per new track, memory cache of 40; YouTube titles cleaned
  ("Artist - Song (Official Video)"); synced lines follow the position
  (YouTube in Brave), plain text for Apple Music (no position). Expanded Now
  Playing widget. Settings › General › Music Island.
- **Month** widget (`Widgets/MonthCalendarWidget.swift`): six-week grid from
  the calendar's first weekday, months back and forward, a day's events with
  Join; reads the Calendar widget's store and calendars only when already
  connected, off the main thread, released when hidden.
- **AirDrop** from the File Shelf (`NSSharingService(.sendViaAirDrop)`): per
  item and "AirDrop All"; missing files skipped.
- **Launcher calculator and Apple Shortcuts** (`Launcher/LauncherExtras.swift`):
  a recursive-descent parser (+ − × ÷ % ^, parentheses, π; bare numbers stay
  searches; a sum is never remembered; Return copies an ungrouped number).
  Shortcuts from `/usr/bin/shortcuts list`, run by name only on Return
  (⌘Return opens it in Shortcuts); Settings › Launcher toggle.
- **Settings completed:** a new Productivity pane (focus and break lengths, eye
  break, clipboard history on/off and size 20/40/100/200, File Shelf expiry
  and clear); the clipboard switch is remembered (history still memory only);
  Privacy now lists Location and Bluetooth with live status (the Location row
  still said "sample data"); About and the AI Hub's stale texts fixed.

**Verified.** 784 tests (765 before; 19 new in `Milestone20Tests`), three
full runs green; debug and release builds clean, no new warnings. Live
(debug build): launcher `12*4+3` → "= 51" first, `2^10` → "= 1,024" (copies
1024); a simulated device notice took the slot (holder deviceNotice),
rendered, and left after 3 s. Not verified live: a real Bluetooth
connect (this ad-hoc build has no Bluetooth grant yet), real lyrics from
LRCLIB, AirDrop's sheet, running a real shortcut, the Month widget with real
calendars.

## M21. Notch redesign, notch switch, live activities (2026-11-17)

Checked against boring.notch, Atoll and DynamicNotch on GitHub (table in
`docs/FEATURES.md`). The notch felt cramped (seven text tabs above a dense
740 × 420 grid), so the shell was redesigned (`Dashboard/DashboardView.swift`):

- **Grows out of the notch.** The surface starts at the camera housing's size
  and springs to the panel (response 0.38, damping 0.8), revealing the content
  through it; closing is a 0.26 s spring without overshoot. Reduce Motion and
  Low Power Mode give a 0.15 s fade.
- **Header beside the camera** (the row was empty): settings, time and date,
  battery (from the event-driven `PowerWatcher`), a running timer; on the
  right, icon tabs with the selected one widening to its name.
- **Roomier:** 860 × 480 (capped to the screen), 20 pt cards with 16 pt
  padding; a row that isn't full shares its width (no empty hole).
- **Less on the Overview:** Clock and Battery are off by default (the header
  shows both; a one-time tidy turned them off in existing layouts, Settings ›
  Widgets brings them back); Now Playing is on.
- **Settings › Notch:** Use the notch (off = owner `.off`, Orbit leaves the
  notch as for Coucou; ⌃⌥⌘O still opens it), open on hover or click, close
  delay, live activities, Save energy in Low Power Mode.
- **Live activities** (`Notch/LiveActivities.swift`, one notch-note slot):
  charger connected or removed, fully charged, 20 % and 10 %; a quick timer
  ("timer 10m tea" in the launcher, header chip, note and sound); a colour
  picker (NSColorSampler, no permission; hex copied).
- A code review (`/code-review`) found 10 issues, all fixed: the timer row
  lost when Spotlight answered, "-2^2", dates as sums, Apple Music titles
  split as "Artist - Song", lyrics kept during an ad, timer labels lowercased,
  Shortcuts listed while off, the header battery up to a minute late, the
  Month widget not reloading, watchers running with the notch off.

**Verified.** 804 tests (784 before), full runs green; debug and release
builds clean. Renders of the redesigned Overview and Productivity pages
(offscreen; text fields draw as placeholders there). Live, release build,
MacBook Air M4: closed 0.0–0.2 % CPU; opening 13.6 % for under a second;
held open 0.0 %; footprint 44 MB. Live (debug): the notch switch (owner off,
pointer ignored, notes suppressed, back on), a 3 s timer's note, a charging
note. Not verified by eye: the opening spring on screen (it can't be
captured without Screen Recording), click-to-open by hand, a real charger
event, the colour loupe.

