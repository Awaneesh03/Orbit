# Orbit — Project Specification

Orbit is a personal, native macOS Control Center anchored to the MacBook
notch: hidden by default, it opens a large dashboard of modular widgets when
the pointer moves into the camera housing. Inspired by Sapphire and modern
macOS productivity dashboards. (Design source: Orbit Master Blueprint v1.1 —
not stored in this repository; the interaction below follows the approved
Stage 1 redesign brief.)

## Platform & toolchain

| Item | Decision |
|---|---|
| Device | MacBook Air M4 (Apple Silicon, arm64, notched display) |
| OS target | macOS 26.0 minimum (enables Liquid Glass APIs) |
| Language | Swift 6 (Swift 6 language mode) |
| UI | SwiftUI |
| Window management | AppKit (one `NSPanel`: notch trigger that grows into the dashboard) |
| Build | Swift Package Manager + `scripts/run.sh` (assembles and ad-hoc signs `Orbit.app`) |
| Editor / agent | VS Code + Claude Code |
| Persistence | UserDefaults for settings; SwiftData or SQLite once a module stores real data |
| Tests | Swift Testing (`import Testing`). XCTest is not available in Command Line Tools |

### Hard constraints

- No full Xcode install — Command Line Tools only.
- No `sudo`, no external dependencies, no modification of macOS system settings.
- Do not replace or modify the native macOS menu bar.
- Request only permissions a shipped feature actually needs.
- Never overwrite existing files without checking.
- Disk space is limited (~13 GB free at project start).

### Known Command Line Tools limitations

- No asset catalogs (`actool` requires Xcode): colors live in code, the icon
  is a `.icns` built with `iconutil`.
- No SwiftUI Previews, Interface Builder or Instruments GUI.
- Ad-hoc signing changes identity every build, so privacy (TCC) grants such
  as Accessibility or Desktop access reset on rebuild. Fix when first needed:
  a self-signed code-signing certificate created in Keychain Access.
- Distribution beyond this Mac would need a Developer ID and notarization.
- Swift Build intermittently fails to resolve the swift-testing macro plugin
  (`plugin for module 'TestingMacros' not found`). `scripts/test.sh` loads it
  explicitly; always run tests through it.
- SwiftPM's linker prints two harmless `ld: warning: search path … not found`
  lines (Xcode-only directories).
- **SwiftUI macros are unavailable.** Their plugin (`SwiftUIMacros`) ships only
  with full Xcode. On the macOS 27 SDK even `@State` is a macro, so **do not
  write `@State`**. Keep view state in an `@Observable` model (the dashboard
  keeps all of it in `DashboardModel`), or store `State(initialValue:)`
  directly as a last resort.
  `@Entry` and `#Preview` are unavailable too. Observation's `@Observable`
  works (its plugin ships with the toolchain).
- VS Code's Swift extension "Debug Orbit" launch configuration
  (`.vscode/launch.json`) runs the bare binary without the `.app` bundle, so
  Orbit gets a Dock icon there. Use `scripts/run.sh` for real runs.

## Architecture

- **Accessory app** (`LSUIElement`): no Dock icon, no app menu bar. The
  `AppDelegate` owns the notch panel, the interaction state, preferences and
  the Settings window. The SwiftUI `Settings` scene is an empty placeholder
  SwiftUI requires; ⌘, is routed to Orbit's own Settings window instead.
- **AppKit owns the window, SwiftUI owns the content.** A single borderless,
  non-activating `NotchPanel` at `.statusBar` level (above ordinary windows
  and the menu bar) hosts `DashboardView`.
  - **Idle:** the panel is an invisible 179×32pt hover trigger exactly over
    the camera housing (`auxiliaryTopLeftArea.maxX … auxiliaryTopRightArea.minX`).
    On screens without a notch it falls back to a 200pt top-centre strip the
    height of the menu bar (min 24pt). Nothing is drawn.
  - **Open:** the same panel grows to the 740×420pt dashboard (680×380
    until Step 5), hanging from
    the top edge and centred on the notch. The dashboard rect always contains
    the trigger rect, so moving from the notch into the dashboard never leaves
    the window — no flicker by construction.
- **Interaction state machine** (`NotchInteraction`, `@MainActor @Observable`):
  `hidden → open` on pointer enter; `open → closing` on pointer exit, then
  `hidden` after 1s unless the pointer returns; `close()` (Escape, click
  outside, Space change) is immediate. Pointer events come from an
  `NSTrackingArea` (`.activeAlways`, `.inVisibleRect`); outside clicks from a
  global mouse-down monitor (no permission needed).
- **Keyboard focus:** the panel can become key only while open, and only via
  a click inside it; hovering never takes focus. On close it is ordered out
  and back in, which returns focus to the frontmost app. Escape and ⌘Q are
  handled in the panel's `sendEvent`.
- **First click:** `FirstMouseHostingView` returns `acceptsFirstMouse = true`.
- **Right-click:** `FirstMouseHostingView` shows a native `NSMenu`
  (**Quit Orbit**) from `rightMouseDown`, independent of key status.
- **Spaces and full-screen apps:** `.canJoinAllSpaces`,
  `.fullScreenAuxiliary`, `.stationary`, `.ignoresCycle`. Orbit works on
  every Space, **including full-screen Spaces** (decision 2026-10-31: hiding
  in full screen only made sense for the old permanent bar). On a notched
  display a full-screen app starts below the camera housing, so the idle
  trigger sits in the black strip and never covers app content (measured:
  trigger y 0–32, app content from y 33). Any Space change closes an open
  dashboard so it never follows the user to another Space.
  - History: a `.statusBar`-level window joining all Spaces is shown on
    full-screen Spaces even without `.fullScreenAuxiliary` (measured);
    `.fullScreenAuxiliary` is now set explicitly so this does not rely on
    that side effect. Full-screen *detection* was removed with the
    restriction; if ever needed again, the only reliable signal found was the
    private `CGSCopyManagedDisplaySpaces` Space type (4 = full-screen) — on
    notched displays a full-screen window has the same frame as a maximised
    one, and `currentSystemPresentationOptions` only reports Orbit's own
    options.
- **Termination:** SIGTERM is routed through `NSApp.terminate` (a
  `DispatchSource` signal handler), so `applicationWillTerminate` runs.
- **Debug hook (debug builds only):** a distributed notification
  `com.awaneeshgupta.orbit.debug` with object `hover`, `leave`, `close` or
  `state` drives the same paths as the pointer, for scripted UI verification.
- **Widgets** (Step 4): every dashboard card is a `DashboardWidget` with
  metadata, a load state and a visibility lifecycle, registered in
  `WidgetRegistry` and arranged by a persisted `WidgetLayout`. There are no
  always-visible bar widgets. See "Widget architecture (Step 4)".
- **Modules with background work** (Screenshot Vault, Clipboard History, …)
  add their own service and storage when built. They store data under
  `~/Library/Application Support/Orbit/`.
- **Targets:** `Orbit` (the app), `OrbitBridge` (framing, validation and the
  local socket, shared with the helper; `package` access only) and
  `OrbitBraveHelper` (Brave's native messaging host). Split a widget into its
  own target only when it brings heavy dependencies.

## Roadmap

### Stage 1 — Foundation (current)

1. ✅ Package, accessory app entry point, Info.plist, build/run script, spec.
2. ✅ ~~Permanent full-width top bar~~ — **superseded** by the notch
   interaction redesign: invisible notch hover trigger, interaction state
   machine (hover open, 1s delayed hide with cancellation, Escape, outside
   click, Space change), works in normal and full-screen Spaces, right-click
   Quit, graceful SIGTERM handling. Dashboard is a placeholder shell (section tabs only).
3. ✅ Dashboard shell and navigation: six section tabs; Overview with live
   greeting/clock/date and battery, sample weather/events/tasks, and quick
   actions; a shared "planned" page for the other five sections. See
   "Dashboard (Step 3)" below.
4. ✅ Widget architecture: `DashboardWidget` protocol, metadata, validated
   registry, persisted layout (enable/disable, order, compact/expanded),
   uniform loading/empty/error/unavailable states, visibility lifecycle. The
   six existing Overview cards were converted; no new widgets. See "Widget
   architecture (Step 4)" below.
5. ✅ Initial widget expansion: Tasks, Daily goals, Focus timer, Calendar
   UI (sample), Projects, GitHub (sample), Screenshot Vault foundation,
   CPU & memory, Storage, Network, AI Hub (sample replies). Section pages now
   host their category's widgets. See "Widgets (Step 5)" below.
6. ✅ Native Settings window: General, Appearance, Widgets, Privacy &
   Permissions, Storage, About. See "Settings window (Step 6)" below.
7. Version control (`git init`) — decided separately.

### Notch interaction — behavior and acceptance criteria

| # | Situation | Expected behavior | Verified |
|---|---|---|---|
| 1 | Idle | Nothing visible; native menu bar untouched; only an invisible 179×32pt window over the camera housing | Live (window list + screenshot) |
| 2 | Pointer enters the notch (desktop, normal app window, or full-screen app) | Large dashboard opens immediately above the app, anchored to the notch, no intermediate island, focus not taken | Live with real pointer events (tables below) |
| 3 | Pointer moves notch → dashboard | Stays open (trigger ⊂ dashboard) | Unit test (geometry) + live |
| 4 | Pointer leaves | Hides ~1s later | Unit test + live (≈1.05–1.3s) |
| 5 | Pointer returns within 1s | Hide cancelled | Unit test + live |
| 6 | Escape (after a click inside) / click outside | Closes immediately; keyboard focus returns to the app | Unit test + live (Escape); click-outside is unit-tested only |
| 7 | First click inside | Registers (tab switches on one click); panel becomes key only now | Live (screenshot) |
| 8 | Space change while open (incl. entering/leaving full screen) | Closes; hover works on the new Space | Live |
| 9 | Right-click Orbit | Native menu → Quit Orbit → clean exit | Live (screenshot + `terminating`) |
| 10 | ⌘Q | Quits while the dashboard is key (after a click inside) | Live (`terminating`) |
| 11 | `scripts/run.sh` relaunch | Old instance runs `applicationWillTerminate`; exactly one Orbit remains | Live (log shows `terminating`) |
| 12 | Idle in a full-screen app | Trigger only in the black strip above the app; app content untouched | Live (window list) |

**Verified with real pointer events (2026-10-31)** — every row: opens on
notch hover, stays open moving into the dashboard, closes ~1.1–1.3s after the
pointer leaves, `key=false` (no focus taken on hover).

| Frontmost app | Space |
|---|---|
| Safari, Chrome, Finder (normal windows) | Desktop |
| Desktop only | Desktop |
| VS Code | Full-screen (screenshot) |
| Brave Browser | Full-screen |
| Claude | Full-screen |
| Chrome (toggled with ⌃⌘F, then restored) | Full-screen (screenshot) |
| Test helper app | Full-screen — also first click, Escape, right-click Quit, ⌘Q |

**Full-screen vs maximised on a notched MacBook.** A full-screen app starts
below the camera housing and its menu bar collapses into a black strip, so it
looks almost identical to a maximised window. The 2026-10-31 report "Orbit
does not open over VS Code / Brave / Claude" was exactly this: those apps
were in full-screen Spaces, which Orbit then ignored by design. That
restriction has since been removed.

**Limitations**
- **Sapphire conflict:** Sapphire (if running) owns a window over the same
  notch at the same window level; whichever window is frontmost receives the
  hover. Quit Sapphire while using Orbit.
- In a full-screen app, moving the pointer to the top edge *through* the notch
  to reveal the app's menu bar also opens Orbit; it closes ~1s after the
  pointer leaves.
- Escape works only after a click inside the dashboard (the panel becomes
  key on click, never on hover). A global key monitor would require the
  Accessibility permission.
- While open, the 740pt dashboard covers the centre of the menu bar,
  including some status items right of the notch.
- The physical notch is not interactive; Orbit's transparent window over it
  is. Window frames snap to whole points (trigger x = 645 instead of 645.5).
- Primary display only. On a display without a notch the fallback trigger
  strip is untested on real hardware.
- **Maximized windows** cannot be prevented from extending under Orbit's
  window (no public API to reserve screen space). With the hidden-by-default
  design this only matters while the dashboard is open.
- `scripts/run.sh` falls back to SIGKILL if Orbit has not exited 5s after
  SIGTERM; that fallback path has not been exercised.

**Manual checks (by hand; most are also verified with synthetic events)**
1. Hover: move the pointer up into the camera housing → dashboard opens.
   Move into the dashboard → stays open. Move away → closes after ~1s.
   Move away and back quickly → stays open.
2. Click outside the dashboard → closes. Click inside (e.g. a section tab,
   which must respond to the first click), then press Escape → closes.
3. Full screen: in a full-screen app (VS Code, Brave, Chrome), hover the
   notch → opens above the app; typing still goes to the app until you click
   inside the dashboard.
4. Spaces: swipe between desktops and full-screen apps → hovering works on
   each; an open dashboard closes on the swipe.
5. Right-click inside the dashboard (or on the notch while idle) → **Quit
   Orbit** → Orbit exits. Relaunch with `scripts/run.sh`, open the
   dashboard, click inside, press ⌘Q → Orbit exits.

### Dashboard (Step 3)

**Source layout**

```
Sources/Orbit/
  OrbitApp.swift            app delegate: owns NotchInteraction, DashboardModel, NotchPanel
  Notch/                    window + interaction (approved in Step 2)
    NotchPanel.swift          panel, NotchGeometry, FirstMouseHostingView
    NotchInteraction.swift    hover state machine
  Dashboard/                UI and its state
    DashboardView.swift       shell: glass panel, section tabs, section routing
    DashboardSection.swift    the 6 sections + metadata (title, symbol, planned features)
    DashboardModel.swift      @Observable state: section + widget layout (Step 4)
    OverviewSection.swift     Overview: the widget grid (Step 4)
    (PlannedSection.swift     placeholder pages; removed in Step 5 — sections host widgets)
    WidgetCard.swift          reusable widget container + button style
    Theme.swift               colour/spacing tokens
  Widgets/                  widget system + built-in widgets (Step 4, see below)
  Services/                 system access and data sources, no UI
    BatteryStatus.swift       IOKit power sources
    QuickAction.swift         app launchers
    MockData.swift            ALL sample data
```

**Data policy**

| Overview item | Source | Permission |
|---|---|---|
| Greeting, time, date | Live (`TimelineView(.everyMinute)`, `NSFullUserName`) | None |
| Battery | Live (IOKit `IOPSCopyPowerSourcesInfo`); since Step 4 updated by IOKit power-source notifications while visible — no polling | None |
| Quick actions (Screenshot, Settings, Calendar, Activity Monitor) | Live: launch app bundles | None |
| Weather | `MockData`, **SAMPLE** badge | Real service needs location — later stage |
| Up next (events) | `MockData`, **SAMPLE** badge | EventKit needs Calendar permission — later stage |
| Today (tasks) | `MockData`, **SAMPLE** badge; ticking is in-memory only. **Since Step 5: real, persisted Tasks** | None |

- Every sample value lives in `Services/MockData.swift`. Since Step 4 the
  SAMPLE badge comes from the widget's metadata (`availability: .sample`);
  swapping in a real service means switching that widget to `.live`.
- **Privacy lesson (2026-10-31):** a "Downloads" quick action that called
  `NSWorkspace.open(~/Downloads)` triggered a macOS *Downloads folder* privacy
  prompt for Orbit, because the folder is touched from Orbit's process. It was
  replaced by "Settings" (since Step 6 it opens Orbit Settings), and the test `quickActionsOnlyLaunchApps` now
  forbids non-app targets. If that prompt was allowed, the grant can be
  removed in System Settings › Privacy & Security › Files & Folders.
- Views hold no state of their own (no `@State`, see toolchain limits); the
  model lives in the app delegate, so the selected tab and ticked tasks
  survive closing the dashboard (not relaunching).

**Size:** kept at 680×380. Overview fits three columns (greeting + quick
actions, weather + battery, events + tasks) without truncation; revisit when
real widgets need more room.

**Verified (2026-10-31)**
- Opens over full-screen VS Code (screenshot), a full-screen test app, and a
  normal Chrome window; closes ~1s after the pointer leaves; re-entry cancels
  the hide; never takes focus on hover.
- All six tabs switch on the first click (logged section changes, screenshots
  of Developer Hub and AI Hub).
- Ticking a task updates the model (done count 1 → 2).
- Activity quick action opens Activity Monitor, closes the dashboard, and
  causes no privacy (TCC) request.
- Battery card matches `pmset` (86%, on battery).

### Widget architecture (Step 4)

```
Widgets/
  DashboardWidget.swift   protocol + WidgetMetadata, WidgetCategory, WidgetAvailability,
                          WidgetPresentation, WidgetState
  WidgetRegistry.swift    validated registry, discovery, the built-in list
  WidgetLayout.swift      WidgetLayout (+ normalisation), WidgetLayoutStore, WidgetGridPacking
  WidgetHost.swift        WidgetHost (card, states, lifecycle), WidgetGrid, StatusMessage
  ClockWidget.swift  WeatherWidget.swift  BatteryWidget.swift
  QuickActionsWidget.swift  EventsWidget.swift  TasksWidget.swift
```

**Layers:** services (`BatteryStatus`, `QuickAction`, `MockData`) → widget
class (owns data, state, lifecycle; `@Observable` when data changes) → view
struct (renders values only) → `WidgetHost` (card chrome, non-ready states,
start/stop) → `WidgetGrid` → `OverviewSection`. `DashboardView` stays a tab
shell and knows nothing about individual widgets.

**Protocol** — `@MainActor protocol DashboardWidget: AnyObject`:
`metadata`, `state`, `start()`, `stop()` (default no-ops), and
`content(_ presentation) -> AnyView`, rendered only while `state == .ready`.

**Metadata** — `id`, `title`, `description`, `symbol`, `category`
(`general | productivity | developer | screenshots | system | ai`, for future
section pages), `availability` (`live | sample`; `sample` ⇒ SAMPLE badge),
supported `presentations`, `isEnabledByDefault`.

**Registration and discovery** — `WidgetRegistry` validates once and throws
on an empty id, a duplicate id, or a widget without a compact presentation.
Built-ins are listed in `WidgetRegistry.builtIn`; lookup by id or category.

**Adding a widget:** create `Widgets/<Name>Widget.swift` with a class
conforming to `DashboardWidget` and a private view struct, then add one line
to `WidgetRegistry.builtIn`. Existing users get it appended to their layout
automatically (normalisation).

**Layout** — `WidgetLayout` is an ordered list of `{id, isEnabled,
presentation}`. It is always normalised against the registry: unknown and
duplicate ids are dropped, unsupported presentations fall back to compact,
newly registered widgets are appended. `WidgetLayoutStore` reads and writes
JSON through two closures; the app uses UserDefaults
(`com.awaneeshgupta.orbit` / `widgetLayout`), tests use memory. Corrupt data
falls back to defaults. `DashboardModel` exposes `setEnabled`, `move(to:)`,
`setPresentation`, `resetLayout`; the Step 6 Settings window uses exactly these.

**Presentation** — compact = one grid cell, expanded = two cells wide. The
Overview grid has 3 columns; packing keeps the user's order (a widget that
doesn't fit starts the next row); two rows fill the dashboard and further rows
scroll. Expanded support: Quick actions (one row of four), Up next, Today.

**States** — `loading`, `ready`, `empty(msg)`, `failed(msg)`,
`unavailable(reason)`. `WidgetHost` renders all non-ready states uniformly
inside the widget's card (spinner, or icon + message).

**Lifecycle and background work** — `WidgetHost` calls `start()` on appear
and `stop()` on disappear. Disabled widgets, other tabs and a closed dashboard
therefore do no work. The battery widget no longer polls: while visible it
subscribes to IOKit power-source notifications (`IOPSNotificationCreateRunLoopSource`)
and unsubscribes on `stop()`. The clock relies on `TimelineView(.everyMinute)`,
which only ticks while on screen.

**Design decisions**
- Class-based widgets behind a protocol + `AnyView` for content: the only way
  to keep a heterogeneous, independently registered list without a central
  switch. `AnyView` costs nothing measurable at 6–20 widgets.
- UserDefaults, not a database: the layout is a few dozen bytes.
- Normalise instead of reject for user data (layout); reject at launch for
  programmer data (registry) — a bad registry is a bug, a stale layout is not.
- No `@State`/SwiftUI macros (unavailable without Xcode); widget state lives
  in the widget classes, layout state in `DashboardModel`.
- Debug-only layout commands (`enable:<id>`, `disable:<id>`, `expand:<id>`,
  `compact:<id>`, `move:<id>:<index>`, `reset`) on the debug notification, for
  scripted verification (the same API as Settings › Widgets).

**Verified live (2026-10-31, real pointer and click events, full-screen test app)**
- Default grid renders 3×2: Clock, Weather, Battery / Quick actions, Up next,
  Today; SAMPLE only on Weather, Up next, Today.
- Battery lifecycle: `observing=true` on the Overview, `false` on another
  tab, `true` on return, `false` when the dashboard closes; never started
  after a relaunch until shown. Value matched `pmset` (83%).
- Layout: `disable:weather`, `expand:quickActions`, `move:tasks:0` produced
  Today, Clock, Battery / Quick actions (2 cells, one row of four), Up next;
  the layout survived a relaunch; `reset` restored the default.
- Tabs, task ticking and the Activity quick action still work; the quick
  action closes the dashboard and causes no privacy (TCC) request.
- `ProgressView` renders grey whenever the panel isn't key (always, while
  hovering), so the battery bar is drawn with two capsules instead.

**Limitations**
- Grid rows have a fixed height (half the content area); a widget whose
  content is taller than its cell is clipped — keep compact content short.
- The battery widget passes an unretained pointer to IOKit; safe because
  widgets live for the app's lifetime and `stop()` removes the source.

### Widgets (Step 5)

**Architecture additions**
- **Section pages host widgets.** Every section except the Overview shows
  its category's widgets in registry order (`DashboardModel.sectionWidgets`,
  `CategorySection`), at each widget's `sectionPresentation`; a section with
  one widget (Screenshot Vault, AI Hub) gives it the whole page. Section
  pages ignore the Overview on/off switch. New widgets are off on the
  Overview by default, so existing layouts are unchanged.
- **Persistence:** `JSONFile` (atomic JSON) and `Persisted` in
  `~/Library/Application Support/Orbit/` (no permission). If a file exists
  but can't be decoded, the widget shows `.failed`, and every later change is
  refused so the unreadable file is never overwritten. No database: a handful
  of small lists. Files: `tasks.json`, `goals.json`, `pomodoro.json`,
  `ai.json`, `Vault/index.json` + `Vault/*.png`. None exist until first use.
- **Reference-counted visibility:** `WidgetVisibility` starts a widget on its
  first visible host and stops it after the last, so a widget shown in two
  places (Battery: Overview + System) is never stopped while still on screen.
- **Typing keeps the dashboard open:** while a text field is being edited
  (the panel's first responder is the field editor), pointer exit doesn't
  start the hide delay; Escape, outside clicks and Space changes still close it.
- **Size 740×420** (was 680×380) to fit text fields, chat and previews.
- Debug-only `section:<name>` command switches pages for scripted
  screenshots without injecting input.

**Features**

| Section | Widget | Data source | Permission | Notes |
|---|---|---|---|---|
| Productivity | Tasks — add, complete, delete | Your data, `tasks.json` | None | Replaced the Step 3 sample list (same id, keeps Overview position) |
| Productivity | Daily goals — up to 3 | Your data, `goals.json` | None | A new local day starts an empty list |
| Productivity | Focus timer — start, pause, resume, reset; focus 25 → break 5 | Your data, `pomodoro.json` | None | No timer runs anywhere: the countdown is derived from `endsAt`; a run that ends while hidden is settled when shown; no notification when it ends (would need the Notifications permission) |
| Productivity | Calendar — next 2 (Overview), day agenda with past dimmed (section) | **SAMPLE** (`MockData.agenda`, relative to now) | None (EventKit later) | Sample day can cross midnight |
| Developer Hub | Projects — open in VS Code / Terminal / Finder | Live folder list of `~/Developer` (Git repos flagged), rescanned when shown | None (`~/Developer` isn't protected) | Never reads project contents; folders in Desktop/Documents are not listed (protected) |
| Developer Hub | GitHub — PRs, reviews, CI | **SAMPLE** (`MockData.githubActivity`) | None | No API, no token |
| Screenshot Vault | Inbox + preview; Paste, Keep/Unkeep, Delete, Clear inbox, Recently Deleted, Show in Finder | Your data, `Vault/` | None | Import by **dragging onto the notch** (see "Screenshot Vault drag-and-drop") or the system `PasteButton` (user-initiated, so no clipboard-privacy alert). No folder watching, no screen recording. Only ever copies in and deletes its own copies (path-checked). Since Stage 2 Step 1, Delete and Clear inbox are recoverable for 30 days (see "Screenshot Vault safety (Stage 2, Step 1)") |
| System | CPU & memory | Live, Mach `host_statistics`/`host_statistics64` | None | Sampled every 3 s **only while visible**; memory = Activity Monitor's "Memory Used" (app + wired + compressed) |
| System | Storage | Live, volume resource values | None | Read when shown |
| System | Network | Live, `NWPathMonitor` (push, no polling) | None | No Wi-Fi name (needs Location) |
| System | Battery | Live (Step 4) | None | Also on the Overview |
| AI Hub | Model choice + chat | **SAMPLE** replies (`MockData.aiReply`) | None | Nothing is sent; no API keys; model choice saved, conversations not |

**Platform findings**
- macOS 15.4+ shows a privacy alert for *programmatic* reads of the general
  pasteboard; access that is user-originated and paste-related (the system
  `PasteButton`, ⌘V) is exempt. Hence the vault's paste import uses `PasteButton`,
  which also disables itself when the clipboard holds no image.
- `#expect` can't call mutating methods; capture the result first.
- On this macOS, `vm_stat` labels internal pages "Anonymous pages".

**Verified live (2026-10-31)**
- Overview (unchanged layout; Tasks now live and unbadged) and Productivity
  rendered inside a full-screen app; Developer Hub, Screenshot Vault,
  System and AI Hub rendered on the desktop with Finder frontmost, via the
  debug `section:` command (no injected input).
- System values matched the machine: battery 77% (`pmset`), storage 13.17 GB
  free of 245.11 GB (`df`: 12 GiB of 228 GiB), memory consistent with
  `vm_stat`, network Online · Wi-Fi.
- Projects listed `~/Developer/Orbit` with all three open actions.
- 0 privacy (TCC) requests from Orbit during the session; no Orbit data
  files were created (nothing was added through the UI).
- **Not verified live:** typing into fields, Focus timer buttons, Paste
  import, project open actions and AI send. Automated input was stopped when
  the user started using the Mac during the test; these are covered by unit
  tests and the manual checks below.

**Manual checks**
1. Productivity → type a task, Return; tick it; delete it with ✕. Move the
   pointer away while typing — the dashboard stays open; Escape closes it.
2. Add three goals; a fourth field doesn't appear. Tomorrow the list is empty.
3. Focus timer: Start → Pause → Resume → Reset. Start, close the dashboard,
   reopen later: the countdown continued.
4. Take a screenshot with ⌃⇧⌘4, open Screenshot Vault, press Paste: it
   appears with a preview and no privacy alert. Keep it, Clear inbox (it
   stays), Delete it. Show in Finder opens `…/Orbit/Vault`.
5. Developer Hub → Orbit → each of VS Code, Terminal, Finder opens the folder.
6. AI Hub → pick Gemini, send a message → a labelled sample reply. Relaunch:
   Gemini is still selected, the chat is empty.

**Limitations**
- No notifications (focus timer end, etc.) — would need the Notifications
  permission.
- Calendar, GitHub and AI replies are sample data.
- Projects only scans `~/Developer`; protected folders (Desktop, Documents)
  would trigger privacy prompts, so they are deliberately not scanned.
- The vault has no automatic import (no folder monitoring, by scope); drag-and-drop onto the notch is the primary path.
- Grid cells are fixed-height; long lists scroll inside their card.

### Screenshot Vault drag-and-drop (Step 5 fix)

**Root cause of the original gap:** Orbit had no drag destination at all
(no `registerForDraggedTypes`, no `NSDraggingDestination`, no SwiftUI drop
modifier), so the notch window ignored every drag; the only import path was
the Paste button.

**How it works**
- `FirstMouseHostingView` (the notch window's content view, present in the
  idle 179×32pt trigger and the open dashboard) registers for
  `ScreenshotDrag.draggedTypes` and overrides the `NSDraggingDestination`
  methods (`NSHostingView` implements them itself for SwiftUI drops; the
  override makes the notch window's drop behaviour entirely Orbit's). It
  forwards to `NotchPanel` (`NotchDropHandler`).
- **Drag enters** with an image → `DashboardModel.isDropTargeted` +
  `NotchInteraction.dragEntered()`: the dashboard opens and shows a dashed
  "Drop to save to Screenshot Vault" target that *replaces* the content (so
  no text field can capture the drop). Non-image drags are refused and don't
  open anything. The panel never becomes key: no focus is taken.
- **During the drag** the dashboard stays open (pointer tracking is ignored
  while dragging).
- **Drag away** → normal 1 s hide. **Drop** → import, switch to Screenshot
  Vault with the new item selected, notice "Screenshot saved to Vault" (top
  right, 2.5 s), dashboard lingers ~3 s; moving the pointer in keeps it open.
- Every drag logs its pasteboard **type identifiers** (never content or
  paths) and every import its outcome, e.g.
  `drag entered (accepted: true); types: public.file-url, …` /
  `drop: file(.png)` / `vault import: saved 1200x750 public.png`.

**Supported representations** (per dragged item, in order of preference)
1. `public.file-url` to an image file — read once, never moved/modified/deleted.
2. Image data: `public.png`, `public.tiff`, `public.jpeg`, `public.heic`.
3. File promises (`NSFilePromiseReceiver`) with an image type — only when
   nothing else is offered; the sender writes a copy into a temporary staging
   folder of Orbit's own, which is imported and then removed.

Which one the macOS floating screenshot thumbnail offers is not documented;
Orbit accepts all three and the log records the real types on first use.

**Import lifecycle** (`ScreenshotVault`)
1. Size check (≤ 100 MB, before reading a file).
2. Decode + validate: ImageIO type must be PNG, TIFF, JPEG or HEIC
   (anything else → "unsupported"); full decode; end-marker check for PNG
   (`IEND`) and JPEG (`FF D9`) because ImageIO happily decodes truncated
   files (measured).
3. TIFF is stored as PNG; PNG/JPEG/HEIC are kept byte for byte.
4. SHA-256 of the stored bytes; an identical image already in the vault is
   reported as "Already in your Vault" and nothing is written.
5. Write a new `<UUID>.<ext>` (never overwrites; atomic), then the index.
   If the index write fails, the new file is removed — no orphan, no half
   entry. Permanent removal (purge, Stage 2) updates the index first, then
   removes only Orbit's own files (path-checked to stay inside `Vault/`).
6. Metadata stored per item: pixel size, format, byte count, SHA-256, source,
   import time. Previews are generated on demand with ImageIO thumbnails.
   Indexes written before this fix (without metadata) still load.

**Storage:** unchanged — `~/Library/Application Support/Orbit/Vault/`
(`index.json` + images). No database.

**Privacy guarantees:** no folder monitoring, no screen recording, no
Accessibility, no Files & Folders permission requested, no general-clipboard
access for drops, no network. Originals are only read. Verified: 0 privacy
(TCC) requests during testing; a dropped test file was byte-identical with
the same modification date afterwards.

**Verified live (2026-10-31, debug stand-ins, no injected input)** — the
debug commands `dragenter`, `dragexit` and `dropfile:<path>` drive the same
code paths a real drag uses after AppKit delivers it: drop target shown;
drag away hides after 1 s; drop → Vault selected with preview, metadata
1200×750 PNG, notice, ~3.3 s linger; second drop → "Already in your Vault";
non-image → "Screenshot not saved" + reason. The existing kept screenshot
was unaffected; the test item was removed afterwards.
**Not yet verified:** a real drag of the macOS floating thumbnail onto the
notch (needs the user's pointer) — see manual checks.

**Manual checks (drag-and-drop)**
1. Take a screenshot with ⇧⌘4 (or ⇧⌘3 / ⇧⌘5). The floating thumbnail
   appears only when saving to a file; ⌃⇧⌘4 copies to the clipboard and
   shows no thumbnail — use Paste for those.
2. Drag the thumbnail up into the notch: the dashboard opens with the dashed
   drop target. Drag away: it closes after ~1 s. Drag back and drop.
3. Screenshot Vault opens with the new screenshot selected and
   "Screenshot saved to Vault" appears. No Paste needed.
4. The screenshot still lands on the Desktop (or your save location)
   unchanged.
5. Drop the same screenshot again → "Already in your Vault".
6. Copy a screenshot (⌃⇧⌘4), press Paste in the Vault → still works.
7. Hover, dismissal, full-screen apps and other widgets behave as before.

**Real-drag result (2026-10-31, user test):** the floating thumbnail offers
a file promise **and** `public.file-url` (a copy in
`/var/folders/…/TemporaryItems/NSIRD_screencaptureui_*`, not the Desktop — so
no privacy prompt), `public.png` and `public.tiff`; Orbit used the file URL
and saved 2940×1912 PNGs.

**Mission Control after a drop (investigation, unresolved)**
- Logs show WindowManager entering Mission Control (`clientToggle`, not a
  gesture) 100–190 ms after the drag reached the notch, both times; the
  screenshot UI was dismissed by it, the drop landed on Orbit's scaled window
  inside Mission Control, and Mission Control ended the moment Orbit's
  panel was ordered out/front on close.
- The Dock announces the thumbnail drag as a *drag window*
  (`SendDragWindowMessage`), and WindowManager has a top-edge window-drag →
  Mission Control path (`enableTopEdgeDrag`, `fromTopEdge`, `dragWindow`).
- Two explanations fit the logs: (A) macOS opens Mission Control whenever the
  thumbnail is dragged to the top edge, Orbit or not; (B) Orbit resizing its
  panel at the top edge mid-drag is read as a window drag. Deciding needs
  one test with Orbit quit (see the report); the fix differs completely.
- Tried and reverted: a permanently 740×420, mostly transparent panel
  (no resizing). Tracking areas proved geometric (the pointer below the notch
  opened Orbit), and click/drag pass-through was unproven — too risky.
- Kept: Space changes are ignored during a drag (`spaceChanged()`), so
  Mission Control can no longer close and reopen Orbit mid-drag.
- **Resolved (2026-11-01):** the user confirmed Mission Control opens when the
  thumbnail is dragged to the top edge *with Orbit quit* — macOS behaviour
  (explanation A). Fix: `DragApproachWatcher` opens the drop target when an
  image drag enters `NotchGeometry.dropZone` — 420×80 pt centred on the notch,
  **32–112 pt below the top edge** (on the MacBook Air: x 525–945, Cocoa
  y 844–924). The opened dashboard covers that zone, so the drop lands there
  without touching the top edge. The watcher wakes only on a mouse press
  (global mouse monitor, no permission), polls every 50 ms only while the
  button is held, and reads only the drag pasteboard's type names (never the
  general clipboard, never content). Hover and the notch drop target are
  unchanged.

**Outbound drag (Vault → other apps, 2026-11-01)**
- Thumbnails and the large preview are drag sources (SwiftUI `.onDrag`);
  a click still selects. Each drag offers a file URL of the screenshot's own
  type (`public.png`, `public.jpeg`, …) with its original name when known
  (e.g. "Screenshot 2026-10-31 at 8.46.04 AM.png"), else
  "Orbit Screenshot <date>.<ext>".
- The file offered is a **fresh APFS clone** in
  `$TMPDIR/OrbitExports/<UUID>/` (instant, no extra space or memory), never
  the vault file: Finder moves same-volume drags by default, and the clone
  makes any destination behaviour harmless. Each export folder holds only
  that one file; exports older than 10 min are removed on the next drag.
- Drags that start in Orbit are ignored by the notch drop target (no
  re-import). The dashboard doesn't hide while the mouse button is held, so
  dragging out doesn't pull the source away; it closes normally afterwards.
- Tests: identical bytes, vault file unchanged after the export is removed,
  original/dated names, only one file exposed, multiple and 3000×2000
  exports, cleanup, provider type. Destination compatibility (Finder,
  ChatGPT, Claude, WhatsApp, Mail) awaits the user's manual check.

**Limitations**
- The floating-thumbnail drag format is unverified until the manual test;
  if it turns out to need something else, the log shows the offered types.
- Duplicate detection covers items imported after this fix (older entries
  have no SHA-256).
- A full decode is done for validation, so very large images briefly use
  more memory during import.
- If an image file dropped from a protected folder (Desktop, Documents)
  turns out to trigger a macOS privacy prompt for Orbit, that will show in
  the manual test; drag-and-drop normally carries the user's permission.

### Settings window (Step 6)

**Opening.** One reused `NSWindow` (`SettingsWindowController`, created on
first open, `isReleasedWhenClosed = false`, so it can never be duplicated and
closing it doesn't quit Orbit). Opened from the dashboard's **Settings** quick
action, the notch's right-click menu (**Orbit Settings…**), ⌘, while Orbit is
active, and by opening Orbit again while it runs (`open .build/Orbit.app`,
Finder) via `applicationShouldHandleReopen`. `collectionBehavior =
[.moveToActiveSpace, .fullScreenAuxiliary]`: it opens on the current Space,
including over a full-screen app. Orbit activates only on these explicit
requests. The window title follows the selected pane, as in System Settings.

**Panes** (`NavigationSplitView` sidebar, grouped `Form`s, native controls):
- *General:* launch at login (`SMAppService.mainApp`, user-initiated toggle
  only; macOS may require approval in Login Items), how the dashboard opens,
  close delay 0.3–3 s (default 1 s), reset.
- *Appearance:* Dark (default) / Light / Follow System for Orbit's windows;
  the notch dashboard stays dark so it blends with the camera housing.
  Dashboard background opacity 0.6–1 (default 0.85), widget spacing
  Compact 6 / Regular 10 (default) / Comfortable 14 pt, reduce motion
  (removes dashboard animations). Restore defaults.
- *Widgets:* every registered widget with SAMPLE badge, show-on-Overview
  switch, move up/down, Compact/Expanded where supported, restore default
  layout. Edits go straight through `DashboardModel` (same registry, same
  `widgetLayout` store), so the dashboard updates immediately.
- *Privacy & Permissions:* Required (none), Optional (Calendars, Location —
  future, sample data today), Not Used (Accessibility, Screen Recording,
  Files & Folders). Status comes only from non-prompting calls:
  `EKEventStore.authorizationStatus`, `AXIsProcessTrusted`,
  `CGPreflightScreenCaptureAccess`. tccd logs these as checks ("not
  prompting"); Orbit never requests a permission. A button opens Privacy &
  Security.
- *Storage:* data folder (Show in Finder), Vault screenshot count (kept),
  Vault size, drag-copy count and size, **Remove Expired Drag Copies**
  (only `$TMPDIR/OrbitExports` folders older than 10 min; the Vault is never
  touched by any general cleanup).
- *About:* name, version (Info.plist), requirements, this Mac's macOS, data
  location, documentation placeholders.

**Preferences** — `~/Library/Application Support/Orbit/preferences.json`:
`{"hideDelay":1,"appearance":"dark","dashboardOpacity":0.85,"widgetSpacing":"regular","reduceMotion":false}`.
Missing file → defaults (the approved design). Each field decodes on its own:
an invalid or missing field takes its default, valid ones are kept, numbers
are clamped. An unreadable (non-JSON) file is never overwritten: Settings
shows the problem and changes aren't saved until **Reset All Preferences**,
which first moves the file aside to `preferences.unreadable-<time>.json`.
Changes apply live: `PreferencesModel.onChange` → `NotchInteraction.hideDelay`,
`DashboardModel.preferences` (opacity, spacing via the `widgetSpacing`
environment value, reduce motion) and the Settings window's appearance.

**Debug commands** (debug builds): `settings`, `settings:<pane>`
(`general`, `appearance`, `widgets`, `privacy`, `storage`, `about`),
`closesettings`; `state` also logs Settings visibility, frame and where ⌘,
is routed.

**Limitations**
- Launch at login registers the app at its current path
  (`.build/Orbit.app`, ad-hoc signed). Rebuilding re-signs it, and macOS may
  then show the login item as needing re-approval; moving the app breaks it.
  A stable install location and a real signature come later.
- Appearance doesn't restyle the notch dashboard (deliberately dark).
- Reduce motion is Orbit's own toggle; it doesn't yet follow the system
  Accessibility › Reduce motion setting.

### Screenshot Vault safety (Stage 2, Step 1)

Implemented. Everything else in Stage 2 (collections, tags, favorites UI,
search, OCR, the Vault window, folder monitoring) is **planned, not built**.

**Files in `~/Library/Application Support/Orbit/Vault/`**
- `index.json` — still a bare JSON array of `VaultItem`. New optional fields:
  `isFavorite`, `collectionID`, `tagIDs`, `deletedAt`. They are left out of
  the JSON while unset, so Stage 1 indexes load unchanged and an untouched
  item keeps its old shape. Loading never writes.
- `library.json` — `{"version":2,"collections":[],"tags":[]}`, reserved for
  collections and tags (planned). Missing = empty. It is created on the first
  write and then never rewritten by this version; an unreadable one is left
  as it is and the Vault keeps working.
- `index.v1-backup.json` — on the first write by this version (index exists
  as a regular file, no `library.json` yet), the existing index is copied
  here first. An existing backup is never replaced; if the copy fails,
  nothing is written.
- `index.corrupt-<date>-<id>.json` — an unreadable index moved aside by an
  explicit rebuild.

**Recently Deleted.** Delete sets `deletedAt`; the image file stays. Restore
clears it (the item comes back exactly as it was). Re-importing the same
image restores it instead of storing it twice. "Delete Now…" (with an inline
confirmation) purges one item permanently. At launch, items deleted at least
30 days ago are purged — only if their file is directly inside the Vault; a
deletion date in the future is never "expired". Purging writes the index
first, then removes the file: a failure leaves the entry and its file, at
worst an unreferenced file, never an entry without a file. A file that is
already missing just has its entry removed. Recently Deleted is shown inside
the Vault section (trash button with a count; "‹ Vault" goes back). Deleted
items can't be dragged out.

**Clear inbox.** Asks first, inline in the Vault ("Move N screenshots to
Recently Deleted?"); asking writes nothing, closing the dashboard cancels.
It moves only items that are not kept, not organised (favorite, collection
or tag set) and not already deleted; no file is removed.

**Duplicates.** The legacy item without a SHA-256 is compared by hashing its
file (read only) on import; nothing is written for a duplicate.

**Rebuild index** (Settings › Storage, shown only when `index.json` can't be
read, with a confirmation). Never automatic. Scans only the files directly in
`Vault/` (no subfolders, no symbolic links, hidden and `.json` files
ignored), validates each like an import, and accepts only PNG, JPEG and HEIC
whose extension matches the content; nothing is moved, renamed or rewritten.
The unreadable index is moved aside first and put back if the new index
can't be written. Can't be recovered from images: Keep, source and original
name (drag-out names fall back to a dated name), import dates (the file date
is used), Recently Deleted and future organisation fields. Recovered items
are therefore marked **Kept**, so Clear inbox can't touch them.

**Debug commands** (debug builds): `vaultrestore:<id>`, `vaultpurge:<id>`
(Recently Deleted items only), and UI-only `vault:deleted`, `vault:inbox`,
`vault:clear` (shows the confirmation), `vault:cancel`. `vaultdelete:<id>`
now moves to Recently Deleted.

**Limitations**
- If removing a purged file fails after the index was written, the file stays
  as an unreferenced file; nothing lists or removes it yet, and Rebuild is
  offered only for an unreadable index.
- A missing (not corrupt) `index.json` loads as an empty Vault; images still
  on disk aren't offered for rebuild.
- (Resolved in Step 2: import, thumbnails and previews now run off the main
  actor.)
- An older Orbit build would read the new index (unknown keys are ignored) but
  drop the new fields on its next write.

### Screenshot Vault performance (Stage 2, Step 2)

Implemented. Same JSON files, same behaviour, same layout.

**Background import.** `VaultWidget.importData/importFile` are `async`.
Imports go through one serial queue (each waits for the one queued before
it), so order and duplicate detection are predictable even when several
arrive at once (a multi-item drop is reported in drop order). Per import:
reading the file (100 MB limit checked first), validating, decoding, hashing
and TIFF→PNG conversion run in a detached task; the duplicate check / restore
from Recently Deleted happens on the main actor; the image file is written in
a detached task; then the item is registered on the main actor
(`ScreenshotVault.register`), which re-checks for a duplicate and removes the
new file if the index can't be written. Cancelling the caller (only possible
in code; there is no cancel button) stops before writing, or removes the
unregistered file if it was already written; "Import cancelled." is not shown
as an error. The vault value itself is only ever changed on the main actor.
The synchronous `ScreenshotVault.importImage` is built from the same steps.

**Thumbnails.** Loaded by each cell's `.task(id:)` (cancelled when the cell
goes away) with ImageIO's downsampling thumbnail API at 240 px, decoded off
the main actor up front (`kCGImageSourceShouldCacheImmediately`). Kept in
`ThumbnailCache`, an LRU bounded at 24 MB of decoded pixels (about 160
typical thumbnails); an image larger than the whole cache is never kept. A
failed decode (missing/corrupt file) shows the placeholder and isn't retried
until a rebuild; a cancelled load is retried next time the cell appears.

**Preview.** Decoded off the main actor at up to 2048 px on the long edge
(more than twice the preview's on-screen size; smaller images are full
resolution and never enlarged). The stored file is untouched; drag-out uses
the file. Only one preview is held: the previous one is released when the
selection changes and when the dashboard closes (`stop()`); a result for an
item that is no longer selected is dropped. While it decodes, the thumbnail
is shown in its place; an undecodable file shows "Preview unavailable".

**Hash backfill (launch).** Items without `sha256` have their file (only
files directly in the Vault) read and validated off the main actor; then one
index write fills in `sha256` and any other missing `format`, `byteCount`,
pixel size. Existing values are never replaced; nothing is written if
nothing was found. Missing, unreadable or invalid files are skipped and
tried again next launch. Once saved, nothing is redone.

**Drag copies (launch).** Expired copies (older than 10 minutes, by creation
date) are removed off the main actor at launch, in addition to the next
drag-out and Settings › Storage. Only folders with UUID names directly in
`$TMPDIR/OrbitExports` (the ones Orbit creates) whose creation date can be
read are considered.

**Measured** (MacBook Air M4, `scripts/test.sh --filter VaultPerformanceTests`,
tests running in parallel; wall clock, single runs):
- 37 MB 4000×3000 incompressible PNG import: 51.5 ms total; the main actor
  kept ticking (longest gap 19.7 ms). Validation + hashing alone took 15.9 ms;
  in Step 1 all of the import ran on the main actor.
- Thumbnail of a 17 MB 2940×1912 PNG: 83 ms off the main actor, 240×156 px,
  146 KB in the cache.
- Preview of the 37 MB PNG: 148 ms, decoded at 2048×1536.
- Simulated 1,000-screenshot Vault (336 KB index): load 3.2 ms; lists 0.8 ms;
  expiry scan 0.2 ms; one index write 3.8–4.2 ms; 200 thumbnails (1440×900)
  1.0–1.3 s sequentially, cache settled at 174 entries / 23 MB of 24 MB; a new
  import 5–8 ms.
- Real launch: hash backfill of the legacy item 5.4 ms; drag-copy cleanup
  0.24 ms.

**Limitations**
- Index writes still happen on the main actor (about 4 ms at 1,000 items;
  grows with the index).
- Imports are one at a time: several large drops finish one after another.
- ImageIO can't be interrupted mid-decode; cancellation only skips work that
  hasn't started.
- A file that can't be hashed is re-read at every launch.
- `prepare` took about as long as hashing alone on a 37 MB file, which
  suggests ImageIO's "full decode" check there is not decoding every pixel;
  truncated files are still caught by the end-marker checks and tests.
  Worth confirming separately.
- A JPEG dropped as `….jpg` is stored as `.jpeg`, so its drag-out name falls
  back to a dated name (existing behaviour, not changed here).

### Orbit Glass design system (Stage 3, Step 2)

Implemented in `Sources/Orbit/Dashboard/OrbitGlass.swift` (it replaces
`WidgetCard.swift`); applied to every dashboard widget. Same 740×420
dashboard, same grid, sizes, order, data and notch behaviour.

**Principle.** The panel is already Liquid Glass. Cards are *lit translucent
layers* made of static gradients (no blur, no offscreen work); real Liquid
Glass (`glassEffect`, macOS 26) is used only for interactive controls, inside
`GlassEffectContainer`s: the selected section tab, Quick Action tiles,
Pomodoro buttons and the selected AI provider. Native bordered controls and
`ProgressView` are avoided because they take their inactive (grey) look
while the panel isn't key; the glass button style draws its own glass and
only dims while pressed. The panel's content is pinned to dark appearance
(the dashboard is dark by design), so glass never turns light under white
text if macOS switches to Light.

**Tokens.** Card: 18 pt continuous corners; fill white 7.5% → 2.8% top to
bottom; specular rim (1 pt, white 26% at the top fading out by 40%); 0.5 pt
hairline white 7.5%; radial sheen near the upper left (white 5.5%); shadow
black 32%, 8 pt, 3 pt down; padding 14. Inner surface: white 5%, 0.5 pt
stroke white 6%, 12 pt corners. Chip: white 9% capsule with hairline.
Colours: `Theme.accent` indigo unchanged; semantic `warning` (amber) and
`critical` (coral) only where meaningful (errors, low battery). Type (SF Pro):
eyebrow 10 semibold tracked caps; hero 30 rounded semibold tabular; metric 22;
title 13; body 12; caption 10.5.

**Components.** `OrbitGlassCard` (used by `WidgetHost`), `OrbitWidgetHeader`,
`OrbitGlassChip`, `.orbitSurface(radius:)`, `OrbitGlassButtonStyle`
(capsule or any shape, optional accent tint), `OrbitGlassButton`,
`OrbitGlassMetric` (rolling digits), `MeterBar` (glossy: inset track,
gradient fill, 1 pt highlight), `StatusMessage` (empty/unavailable, warning
tone for errors), `OrbitLoadingView` (static outline, no spinner, no
shimmer). Needs-access and stale/offline styles are deferred to the step that
adds those states (no widget has them yet).

**Motion.** One restrained spring (0.35 s, bounce 0.12) for state changes,
numeric text transitions, meter changes; hover brightens a card's rim and
sheen (0.18 s ease-out) without scaling; nothing loops. Reduce Motion is
Orbit's setting **or** macOS's (Accessibility › Display), passed down as
`orbitReduceMotion`; with it, animations and digit rolls are off.
Hover state lives in `OrbitHover` (views can't hold `@State` with this
toolchain: the SwiftUI macro plugin is missing).

**Measured.** Orbit's process at 0.0% CPU in 1 s `top` samples with the
dashboard closed and open (Overview, Productivity) at idle; 97 MB resident.
Liquid Glass is composited by the window server, so its GPU cost isn't in
Orbit's process numbers.

### Shared widget infrastructure (Stage 3, Step 3)

Implemented; no widget uses it yet (Weather, Calendar and Music will). Existing
widgets are unchanged: the new protocol members default to nil.

**States.** `WidgetState` gains `.needsAccess(reason)` (a permission the user
can grant: lock icon) next to `.unavailable` (the source doesn't exist: slash
icon). `DashboardWidget` gains `statusNote: WidgetNote?` (a caption under
ready content: "Updated 2 hr ago · Offline") and `stateAction: WidgetAction?`
(a glass button under a non-ready state, e.g. Retry). Stale data stays on
screen with a note instead of an error screen.

**Data sources** (`Services/WidgetData.swift`). `DataSource` (async, Sendable,
cancellable) per provider; explicit `DataSourceError`: `needsAccess`,
`unavailable`, `offline`, `failed`. `DataSourceError.from` maps thrown errors
(cancellation is not a failure; URL connectivity errors are `offline`).

**Refresher.** One per widget, driven by its `start()`/`stop()` (i.e. by
`WidgetVisibility`, so two hosts count once): refreshes on appearing only if
stale (older than `maxAge`, or `markStale()`d by an observer while hidden);
one refresh at a time (asking again joins it); hiding cancels a running
refresh (unless `cancelsWhenHidden` is false) and its late result is
dropped; an optional `interval` runs only while visible; a failure keeps the
previous value and sets the note; Retry for offline/failed only. Maps itself
to `widgetState(empty:)`, `statusNote` and `retryAction`. No global loop.

**Cache.** `DataCache<Value>`: memory, plus an optional JSON file
(`{"value": …, "storedAt": …}`) for data that's safe at rest; `memoryOnly()`
for anything personal (calendar, music). Expiry via `value(notOlderThan:)`;
`latest` keeps an expired value to show as stale. An unreadable cache file is
a miss and is replaced on the next store; nothing is written until a store.
No cache file exists yet.

**briefing.json** (`Settings/BriefingPreferences.swift`): version 1 was
`{"version":1,"dailyBriefingEnabled":false,"widgets":["clock","weather","events","tasks"],"options":{}}`;
Step 3.8-1 moved it to version 2 (see "Daily Briefing model"). Off by default. Tolerant decoding (bad fields default, unknown keys
ignored, ids de-duplicated); `Persisted` gives atomic writes, no write until
a change, and an unreadable file is kept until an explicit reset moves it
aside. Separate from preferences.json and the widget layout. Not yet shown in
Settings; no file is created until something changes it.

### Today: tasks and goals (Stage 3, Step 4)

**Data (same files, compatible).** `tasks.json` items gain optional
`priority` (`high`/`low`; normal is absent), `dueDate` (start of a local day)
and `completedAt`; all left out while unset, decoded tolerantly (an unknown
priority reads as normal). Completing records `completedAt`, reopening clears
it; renaming keeps the id; an unchanged edit writes nothing. `goals.json`
gains optional `history` (`[{day, items}]`, newest first, 60 days): at the
daily reset the previous day's goals move there instead of being discarded;
still three goals per day. Before this version's first write to either file
it is copied once to `tasks.v1-backup.json` / `goals.v1-backup.json`
(`Persisted(backupName:)`; an existing backup is never replaced; if the copy
fails nothing is written and the widget shows the problem). Unreadable files
are never overwritten (as before).

**Today plan** (`TodayPlan`). Open tasks: overdue, due today, due later
(soonest first), undated; high → normal → low within each; otherwise list
order. Completed tasks listed separately, most recent first. Progress =
completed today ÷ (open tasks due by today or undated + completed today);
tasks due later, or completed on an earlier day (or before completion times
existed) don't count. Shown as "N of M today" with `OrbitProgressRing`
(indigo; goals use mint), never a percentage; nothing due is an empty ring.

**Tasks widget.** Compact: ring and counts (overdue in coral), the next two
tasks (complete with the circle), add field. Expanded: rings for tasks and
today's goals (tick goals there), the full list (high priority: coral circle
and flag; "Overdue · 1 Nov" / "Today" / "Tue 4 Nov"), a Completed group,
add field; click a title to edit it in place: title + Done, High/Normal/Low,
due date (Today, Tomorrow, Next week, No due date, plus a date field), delete.
Leaving the dashboard saves an edit in progress. Compact list: every open task in a
bounded ScrollView between the fixed progress header and the add field
(system overlay scroller, soft bottom fade); the card keeps its cell size.
Debug builds honour `ORBIT_DATA_DIR` to run on a disposable data folder for UI
checks (release builds always use Application Support). "Today" is re-read whenever
the dashboard opens; no timers. Daily goals: click a title to edit; mint ring.

**Fix.** `WidgetGrid` clamps cell and row sizes to zero: the first layout
pass can measure zero, and the negative widths caused SwiftUI "Invalid frame
dimension" faults (4 per dashboard opening, since Stage 1).

### Calendar (Stage 3, Step 5)

**EventKit, read-only** (`Services/CalendarService.swift`). `CalendarStore`
protocol with `EventKitStore` (real) and a mock in tests. Full access is
requested with `requestFullAccessToEvents()` (macOS 14+) **only** from an
explicit Connect Calendar click (widget or Settings); never at launch, on
opening the dashboard or on creating the widget. No write, no Reminders.
Info.plist has `NSCalendarsFullAccessUsageDescription`. Status checks use
`EKEventStore.authorizationStatus` (tccd logs them as checks, not prompts).

**States.** Not asked: Needs Access + Connect Calendar ("See today's agenda
here, read-only."). Denied or write-only: Needs Access + Open Privacy
Settings (macOS won't prompt twice). Restricted: Unavailable. Disconnected in
Orbit: Needs Access + Connect (no prompt if already granted). Connected:
Ready / Empty ("Nothing on your calendar today.") / Failed with Retry. No
sample events any more (the Calendar widget is live; `MockData.agenda`
removed).

**Agenda** (`Agenda`). Today = [local start of day, next start of day) in
`Calendar.autoupdatingCurrent` (23/25 h across DST). All-day events apart;
timed events by start, end, title, id. Event id = EventKit identifier + the
occurrence's start (recurring and same-titled events stay distinct). Never a
past event as next; "Happening now" while in progress; events from an
earlier day show "Until 2:00 AM", into tomorrow "11:00 PM – tomorrow".
Compact: date, the current or next event with a countdown ("in 25 min"),
"+N more today · N all-day". Expanded: date and next/now summary, all-day
section, every timed event (past dimmed, Now/Next badges, calendar colour).
The countdown is a `TimelineView(.everyMinute)`: on screen only, no timers.

**Refresh and lifecycle.** `Refresher` over `AgendaSource` (off the main
actor). Showing the widget re-reads access (revocation is caught here and on
every change notification) and loads; hiding cancels and **releases the
events** (`Refresher.reset()`), so personal data isn't held while closed.
`EKEventStoreChanged`, time-zone and day changes are observed once per
widget and only mark the agenda stale (re-read at once if visible). Access
lost: all events and calendars dropped immediately.

**Settings › Calendar.** Status, Connect / Disconnect / Open Privacy &
Security, a toggle per calendar (colour, name, account), Include All
Calendars, and a privacy note. `calendar.json` = `{"isEnabled":…,
"selectedCalendarIDs":[…]}` (identifiers only; `selectedCalendarIDs` absent =
every calendar including new ones; once customised new calendars stay off and
missing ones are skipped). Nothing is written until something changes.
Disconnect stops Orbit reading; the macOS permission itself is managed in
System Settings.

**Privacy.** Events are never written to disk or a cache and never leave the
Mac; tests check that only identifiers reach calendar.json.

### Weather (Stage 3, Step 6)

**Provider.** Open-Meteo (`Services/WeatherService.swift`), HTTPS via an
ephemeral URLSession (10 s request timeout, no cookies or shared cache).
Forecast: `GET https://api.open-meteo.com/v1/forecast` with `latitude` /
`longitude` (rounded to 2 decimals, about 1 km), `current=temperature_2m,
apparent_temperature,relative_humidity_2m,weather_code,wind_speed_10m,is_day`,
`hourly=temperature_2m,precipitation_probability,weather_code,is_day`,
`daily=weather_code,temperature_2m_max,temperature_2m_min,
precipitation_probability_max`, `temperature_unit` (celsius/fahrenheit),
`wind_speed_unit` (kmh/mph), `timezone=auto`, `timeformat=unixtime`,
`forecast_days=5`. City search: `GET https://geocoding-api.open-meteo.com/v1/search`
with `name`, `count=8`, `language=en`, only on Return or Search. Nothing else
is sent. HTTP errors, 429, bad JSON, offline and cancellation map to
`DataSourceError`.

**Licensing.** Verified on open-meteo.com/en/terms: the free API is for
non-commercial use (under 10,000 calls a day, 5,000 an hour, 600 a minute;
apps with subscriptions or ads are commercial) and data is CC BY 4.0.
Every weather view shows "Weather data by Open-Meteo" linking to
https://open-meteo.com/; city search credits Open-Meteo Geocoding / GeoNames
(CC BY 4.0). **A commercial build of Orbit needs an Open-Meteo subscription or
another licensed provider.**

**Widget.** Unconfigured: "Choose a city to see the weather." + Choose City
(opens Settings › Weather). Compact: city, icon, temperature, condition,
high/low, feels-like, credit. Expanded: current (incl. humidity, wind), the
next 6 hours (rain chance shown from 10%), 4 days (high/low, rain chance),
credit. WMO codes → SF Symbols with day/night variants; unknown codes say
"Conditions unavailable" (nothing invented).

**Units.** Settings › Weather: Celsius/Fahrenheit (`weather.json`); requests
ask Open-Meteo for that unit; a cached forecast in the other unit is converted
as a whole for display until the next refresh, so units never mix.

**Cache and refresh.** `Refresher` (max age 30 min) over `ForecastSource` and
a disk `DataCache` (`weather-cache.json`: the forecast for the chosen place
only). Shown at once on launch; refreshed only when the widget appears and the
data is stale (section switches and reopenings within 30 min send nothing);
one request at a time; hiding cancels; offline/failed keeps the old forecast
with "Updated … · Offline"/"Couldn't refresh" and Retry. A cache for another
place is dropped; Settings › Clear Cached Weather.

**Location (optional).** "Use My Location" in Settings, explained before the
button; `CLLocationManager` at reduced (~3 km) accuracy, permission asked only
then and only if never asked; denied / restricted / Location Services off show
a message and never re-prompt; the place is saved as "Current Location" with
coordinates rounded to 2 decimals; searching a city switches back. Info.plist
has `NSLocationUsageDescription` and `NSLocationWhenInUseUsageDescription`.

### Now Playing foundation + Apple Music, read-only (Stage 3, Step 7B)

**Architecture** (`Services/NowPlaying.swift`). `NowPlaying` (source id, app
name, title, artist, album, `PlaybackState` playing/paused/stopped/unknown,
duration, position + timestamp, `PlaybackCapabilities`, optional
`ArtworkReference` for later sources, update time); `PlaybackCommand`
(toggle, next, previous, seek: defined for later, unsupported now);
`PlaybackSource` protocol (`start(onChange:)`, `stop()`, `perform`; status
`.inactive` / `.waiting` / `.playing(NowPlaying)`); `PlaybackCoordinator`
(register, start/stop, picks the item to show: playing > paused > unknown >
stopped, ties to the most recent update; repeats of the same track and state
are dropped; prepared for pinning later). Everything is in memory; nothing is
written to disk.

**Apple Music** (`AppleMusicSource`). Listens to the public
`com.apple.Music.playerInfo` distributed notification with
`suspensionBehavior: .deliverImmediately` (AppKit otherwise holds them while
the app is inactive, which Orbit almost always is). Whether Music is running
comes from `NSRunningApplication` (never launches it); launch/quit come from
NSWorkspace notifications for Music only. Fields read, each optional and
type-checked: `Name`, `Artist`, `Album`, `Player State`
(Playing/Paused/Stopped, anything else = unknown), `Total Time`
(milliseconds, ignored unless 0 < t < 48 h). A stopped player carries no track.
Music only reports *changes*: while it's open and nothing has arrived, the
widget says so ("Play, pause or change a track to show it here") instead of
"nothing playing". No AppleScript, no Apple Events, no permission, no
Info.plist key; no artwork, position or controls yet.

**Widget** (`NowPlayingWidget`, id `nowPlaying`, off on the Overview by default:
Settings › Widgets). Compact: Music's icon, app name, title, artist, status.
Expanded: plus album and duration. Waiting and stopped states as above; Music
not running: "Music isn't open." The coordinator starts at launch (Music reports
changes, so listening only while visible would miss them). The app icon is
read from disk via NSWorkspace and drawn as an 8-bit sRGB bitmap (the icon is
HDR-capable).

### YouTube in Brave (Stage 3, Step 7D)

Three pieces, all installed by the user, none silently:

1. **Extension** (`BraveExtension/`, MV3, "Orbit for YouTube", 1.1.0).
   Permissions: `nativeMessaging`, `scripting`, and host access to
   `https://www.youtube.com/*` and `https://music.youtube.com/*` only (the
   same two sites as its content script). `scripting` + host access exist
   only to attach the content script to YouTube tabs that were already open
   when the extension was installed or reloaded. No `tabs` or history. The manifest's `key` fixes the ID
   at `iejmobaapejgfmjnecdgnmclnkpilpaf` wherever it's loaded from (the private
   key was discarded; it's only needed to pack a .crx).
   - `content.js`: capturing listeners on `document` for the main player's
     media events (`#movie_player`, `#shorts-player`, `ytmusic-player` only;
     hover previews are ignored). State, position, duration and rate come from
     the `<video>`; title, channel, album and artwork from
     `navigator.mediaSession.metadata`, falling back to the page's title and
     channel elements and `i.ytimg.com/vi/<id>/hqdefault.jpg`. Ads are flagged
     (`.ad-showing`). No polling and no DOM observers: it reads the page only
     when a media event or `yt-navigate-finish` fires, plus one re-read 1.5 s
     after a video starts (YouTube sets the Media Session late). Position is
     sent as a timestamped anchor (`position`, `rate`, `at`) on play, pause,
     seek, rate change and buffering, never on `timeupdate`. Leaving a video
     while paused sends `gone`.
   - `background.js`: one port per YouTube tab (top frame only); adds the tab
     id and Brave's `audible` flag (`tabs.onUpdated`, needs no permission);
     connects to the native host when the first YouTube tab reports and
     disconnects when the last one closes, so the helper only runs while
     YouTube is open. Replays every tab after a reconnect. A failed or lost
     native connection is retried on a timer (2, 5, 15, 30, then every 60 s)
     while a tab has something to show; it doesn't wait for the next media
     event. The content script reports again (1 s, doubling to 60 s) when its
     port drops because Brave stopped the idle service worker, steps aside
     when injected a second time, and stops when the extension is reloaded. Commands from Orbit
     go only to the tab they name.
2. **Helper** (`OrbitBraveHelper` executable, `OrbitBridge` library shared
   with Orbit; no dependencies). Chrome native messaging on stdin/stdout:
   32-bit little-endian length + JSON, capped at 64 KiB (a bad length ends the
   helper; Brave restarts it on the next update). Every message is decoded
   strictly and validated (`BridgeMessage.decode`): tab ids 0…Int32.max,
   finite positions/durations below ~115 days, rate 0…16, text trimmed,
   control characters removed and capped (300/200 chars), video ids
   `[A-Za-z0-9_-]{1,32}`, artwork only `https` on `ytimg.com`, `ggpht.com` or
   `googleusercontent.com`. Forwards to Orbit over a Unix socket, retrying
   every 3 s while Orbit isn't running, and replays its tabs on connect.
   Exits when Brave closes stdin. Refuses to run unless started with Orbit's
   extension origin and a non-terminal stdin. Logs (stderr) never include
   what's playing.
3. **Orbit** (`Services/BraveYouTube.swift`). `BrowserBridgeServer` listens at
   `<data>/Bridge/brave.sock` = `~/Library/Application Support/Orbit/Bridge/brave.sock`
   (folder 0700, socket 0600, `getpeereid` must match the current user on both
   ends; a live socket or a non-socket at that path is never replaced; removed
   on stop). No network port. At most 4 helper connections; invalid messages
   are dropped, a bad frame drops the connection. `BraveYouTubeSource`
   (`PlaybackSource`, id `brave-youtube`) keeps one entry per tab, per
   connection; a closed connection removes its tabs. Tab choice: playing and
   audible (not muted) first; then silent tabs (muted or paused) by most
   recent update, so pausing your video doesn't hand the widget to a muted
   autoplay elsewhere; ended last. Mapping: title → title, channel → artist,
   Media Session album → album, thumbnail → `ArtworkReference.url`, position +
   `at` + rate → `position`/`positionAt`/`playbackRate`, playing/paused/ended →
   playing/paused/stopped, `site` → "YouTube" / "YouTube Music". The
   coordinator's rules across apps are unchanged (Apple Music still works the
   same way).

**Fix after the first real install (3.7D).** Brave never started the helper:
the only update was sent on a media event; when that one `connectNative`
failed (helper installed after the extension first reported, or the service
worker restarted) the error was swallowed and nothing retried while the video
kept playing, and tabs open before the extension never got the content
script. Fixed by the retries, re-reports and injection above.

**Diagnostics** (never titles, URLs or other tabs):
- Extension service worker console (brave://extensions › Orbit for YouTube ›
  service worker): `[Orbit]` tab connected/closed, first player update,
  connecting, disconnected with Brave's reason (e.g. "Specified native
  messaging host not found."), retry delays, commands.
- YouTube tab console: `[Orbit] watching this tab's YouTube player (player found | no player yet)`.
- Unified log, `log stream --predicate 'subsystem == "com.awaneeshgupta.orbit"'`:
  helper (`brave-helper`) launched/refused (with the arguments it got),
  first valid message, invalid messages with the reason, Orbit
  reachable/connected/closed, commands, exit; Orbit (`app`) listening, helper
  connected, first message decoded, invalid messages, which tab is shown,
  disconnected with message count. The helper never writes to stdout except
  protocol frames.

**Controls.** −10 s, play/pause, +10 s (`gobackward.10`, `play.fill` /
`pause.fill`, `goforward.10`, circular `OrbitGlassButtonStyle`, play/pause
prominent and in the middle) in both the compact and expanded layouts, for
sources that take commands (none for Apple Music, which shows no buttons).
The seek buttons are disabled (dimmed, with a tooltip saying why) during ads,
live streams and before the duration is known
(`PlaybackControls.availability`). Path: button → `PlaybackCoordinator.perform(_:on:)`
with the item *as displayed* → the source of that item →
`BraveYouTubeSource.perform`, which refuses the command unless that item is
still what it shows (`NowPlaying.itemID` = tab + video id), then sends it to
that tab's helper connection only, carrying the video id (a tab that has
moved to another video ignores it too). `.skip(±10)` is worked out from
where playback is now (`elapsed(at:)`: last position moved on at the rate),
clamped to 0…duration, sent as an absolute seek, and shown at once (the
tab's position is updated before Brave confirms; the tab's own `seeked`
report follows within ~50 ms). No next/previous (YouTube's own Media Session
actions can't be called from a content script). Debug builds: the
`com.awaneeshgupta.orbit.debug` hook takes `playback:toggle` and
`playback:skip:<seconds>`, which send the buttons' command on the item on
screen.

**Widget.** Brave's icon and "YOUTUBE · BRAVE" (or "YOUTUBE MUSIC · BRAVE"),
the thumbnail (16:9; square for YouTube Music; Brave's icon when there is
none), title, channel, state ("Ad" during ads), a progress bar with elapsed
and total time ("Live" without a duration). The bar is extrapolated from the
last anchor (`NowPlaying.elapsed(at:)`) by a `TimelineView` ticking once a
second only while playing and on screen; no messages are needed for it.
Thumbnails are fetched only when the widget is shown, through an ephemeral
`URLSession` (no disk cache, no cookies), only from YouTube's image hosts
(also after redirects), at most 2 MB, downscaled to 320 px, the last 6 kept in
memory (`ArtworkLoader`). This is the only network request: it tells
YouTube's image server which thumbnail is shown, nothing more. Empty state:
"Nothing is playing in Music or on YouTube."

**Install** (by the user):

1. `scripts/install-brave-helper.sh` builds the helper (release), installs it
   at `~/Library/Application Support/Orbit/BraveHelper/OrbitBraveHelper`
   (ad-hoc signed) and writes
   `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.awaneeshgupta.orbit.brave.json`
   (`type: stdio`, `allowed_origins` = exactly
   `chrome-extension://iejmobaapejgfmjnecdgnmclnkpilpaf/`), then validates it
   (JSON, file name = host name, name, description, type, absolute helper
   path, helper executable, arm64, signature, exact origin) and prints where
   it registered. Idempotent; won't overwrite a manifest that isn't Orbit's;
   `--uninstall` removes only Orbit's files.
   **Why Chrome's folder:** Brave on macOS overrides Chromium's native
   messaging folders at startup (`brave_main_delegate`, found in Brave
   1.96.60's code: `PathService::OverrideAndCreateIfNeeded(DIR_USER_NATIVE_MESSAGING,
   ~/Library/Application Support/Google/Chrome/NativeMessagingHosts)` and
   `DIR_NATIVE_MESSAGING` → `/Library/Google/Chrome/NativeMessagingHosts`), so
   hosts installed for Chrome work in Brave. It never reads
   `BraveSoftware/Brave-Browser/NativeMessagingHosts/`; the first installer
   wrote there and Brave answered "Specified native messaging host not
   found." (the installer now removes that copy). Chrome reads the same
   folder, but the manifest admits only Orbit's extension ID.
2. `brave://extensions` › Developer mode › Load unpacked › `BraveExtension/`.
   Check that the ID reads `iejmobaapejgfmjnecdgnmclnkpilpaf`.
3. Reload any YouTube tabs that were already open.
4. Settings › Widgets › Now Playing.

**Permissions.** None on macOS (no Automation, Accessibility, Screen
Recording or Microphone; no Info.plist key; no MediaRemote). In Brave:
native messaging, scripting, and read/change on the two YouTube hosts.

**Verified with real Brave** (2 Nov 2026, Brave 1.96.60): Brave launched the
helper with the origin as its only argument, the helper connected to Orbit,
Orbit decoded the tabs, and the widget showed a real YouTube video (title,
channel, thumbnail, paused state, 0:20 / 3:13). Controls verified the same
day on a real video, through the buttons' command path (debug hook; the
dashboard stayed open): +10 s → the tab reported 137.6 s, −10 s → 129.6 s,
pause → paused, play → playing, and the widget moved 2:28 → 2:38 in place.
Still assumptions: YouTube Music's player selector, ad detection and
`play()` from a background tab.

### Music Island (Stage 3, Step 7E)

Two separate experiences: the **Control Center** (the 740 × 420 dashboard,
`NotchPanel`, unchanged: hover the notch to open it, Now Playing stays a
widget inside it, music never opens or resizes it) and the **Music Island**
(`Notch/MusicIsland.swift`, `Notch/MusicIslandPanel.swift`), a small player
below the notch with its own panel and state.

**State** (`MusicIsland`, pure, tested). Contextual, not permanent: it
announces playback, then gets out of the way.
- `hidden`: nothing playing or paused (stopped, ended, unknown, nothing).
- `compact`: playback just started or a new track/video began; dismisses
  itself after the configured time (default 4 s), unless clicked. One timer
  per announcement (a `Task`, cancelled on expand, hide, quit); if the pointer
  is over the island when it fires, it waits until the pointer leaves (+1.5 s).
- `expanded`: after a click; no timer; stays until an outside click, Escape,
  its close button or a Space change, then goes to `dismissed`.
- `dismissed` (until the next track): the same track is still playing or
  paused but has had its moment. Position updates, pausing and resuming never
  bring the island back; only a track not yet announced since playback last
  stopped does (`trackKey`: source + tab/video for YouTube, or title, artist
  and album for Music; the last 20 are remembered, in memory, so switching
  back to another tab's video isn't "new"), or playback starting again after
  it stopped.
- Found already paused (e.g. Orbit launched mid-video), or the setting turned
  on mid-track: no pop-up. A track that starts while the dashboard is open is
  shown in its widget, not afterwards by the island. Opening the dashboard
  over an open player collapses it first (no overlap). Dismissing never
  touches playback.
`AppDelegate` feeds it with `withObservationTracking` on
`coordinator.current`, `preferences.musicIsland` and `interaction.isOpen`
(every position update re-runs it; only a new key announces). The
coordinator runs whether or not the Now Playing widget is on the Overview.

**Window** (`MusicIslandPanel`): borderless, non-activating `NSPanel` at
`.statusBar`, separate from `NotchPanel`. Centred on the notch, 6 pt below the
menu bar (`MusicIslandGeometry`: compact 300 × 42, expanded 384 × 172, same
top edge, kept on screen): it never covers the menu bar or the notch (whose
hover still opens the dashboard), and the open dashboard covers it entirely,
hence hidden then. Off the screen (`orderOut`) whenever it's hidden or
dismissed, so nothing covers the browser's tab bar between announcements;
the frame always matches what's drawn (grown before the expand animation). Never key while compact; key only while expanded (the
user just clicked it), so Escape reaches it; `orderOut` on collapse hands
focus back. Outside clicks: a global mouse-down monitor (no permission), only
while expanded. `.canJoinAllSpaces`, `.stationary`, `.ignoresCycle`, but not
`.fullScreenAuxiliary`: it doesn't appear over full-screen apps (it would cover
their content). Primary display only, like the dashboard.

**Look** (dark Orbit Glass: black 0.82 + `glassEffect` tinted black + the rim
stroke; dark appearance). Compact pill: artwork or thumbnail (Brave/Music icon
when none), title, artist/channel, a `waveform` glyph with the system's
variable-colour effect while playing (`pause.fill` when paused; still with
Reduce Motion), a 2 pt progress hairline (ticks once a second only while
playing and on screen), 2 % hover lift. Expanded player: 72 pt artwork, source
label, title, artist, album, a close button (✕; playback continues), progress
with elapsed/total, state, and the source's controls (YouTube in Brave: −10 s, play/pause, +10 s; Music: none),
through `PlaybackCoordinator.perform(_:on:)` like the widget. Compact ⇄
expanded morph from the top centre (spring 0.35 s); no animation with Orbit's
or the system's Reduce Motion. No colour extraction or visualizer yet.

**Settings** › General › Music Island: "Announce new tracks below the notch"
(on by default, `OrbitPreferences.musicIsland`) and "Hide after" 2–10 s
(default 4, `musicIslandSeconds`, clamped); both tolerant to older or bad
files and reset with General. Off hides only the island: the widget and
playback detection carry on. There is no permanent compact mode.

**Debug hook** (debug builds): `island:tap`, `island:collapse` (the outside-
click path); `state` logs the island's phase, frame, visibility and key status.

**Verified in the real app** (2 Nov 2026, live YouTube in Brave): resuming
the real video showed the compact island (13:28:56.108) and it dismissed
itself at 13:29:00.148 (4.04 s), taking the window off the screen (tab bar
clear); pause, resume and further playback didn't bring it back; a new video
(a second, scripted helper connection through the real helper and Orbit)
showed it again; `island:tap` → expanded (key; no timer: still open 4.5 s
later); `island:collapse` (the outside-click path) → dismissed, window gone;
the scripted tab going away didn't re-announce the real one; hovering the
notch opened the unchanged dashboard. The real video kept playing throughout
(38 s → 122 s). Not yet checked by hand: real clicks, Escape from the
keyboard, a real track change, a video ending, full-screen Spaces.

### Artwork and source identity (Stage 3, Step 7F-1)

**`PlaybackSourceIdentity`** (`Services/PlaybackSourceIdentity.swift`): one
table for how each source is presented: source id, display name, the app
whose icon stands in for artwork (bundle id; read from disk, never launched),
a fallback SF Symbol, the label's host ("YouTube · Brave"), and the artwork
shape (Music square; YouTube 16:9; YouTube Music square, by app name). Apple
Music and YouTube in Brave read their ids, names and bundle ids from it; the
widget's and island's labels, icons and artwork shapes too. An unknown id gets
a neutral identity. Spotify later = one entry.

**`ArtworkLoader`** (shared by the widget and the island; memory only):
- Thumbnails decoded to at most 480 px (was 320), at most 6 kept, 2 MB
  download limit, YouTube's image hosts only (also after redirects),
  ephemeral session (no disk cache, no cookies), fetched only while shown.
- A URL that failed (bad status, network error, too large, not an image, not
  an allowed host) is remembered for the session (up to 100) and never
  fetched again; it shows the source's app icon, dimmed, on a neutral tile.
  A download cancelled because the view went away isn't a failure.
- Track changes: while the new thumbnail loads, the artwork already on screen
  stays (no placeholder flash), then the view cross-fades (0.3 s; none with
  Reduce Motion; the image is keyed by its URL). Only the latest requested
  thumbnail may replace what's shown, so a slower download for a track
  already skipped never takes over. After a track whose thumbnail failed, the
  next one starts from the placeholder, never an older track's picture.
- Apple Music: still its app icon (its notification carries no artwork; no
  AppleScript, MediaRemote or lookups).
- Debug `state` adds `artwork=<cached>cached/<failed>failed/<requests>requests`.

**Measured** (2 Nov 2026, real app, a scripted helper tab with ten public
YouTube thumbnails then a missing one): RSS 78.7 MB before → 90.5 MB after the
ten changes → 88.9 MB 10 s later; 6 cached, 1 failed, one request per
thumbnail (the failed one not retried); 0.0 % CPU once dismissed.

### Music visualizer (Stage 3, Step 7F-2)

`Notch/MusicEqualizer.swift`: four bars, decorative (a playback indicator,
not a level meter: it knows nothing about the audio; no microphone, capture or
other permission). Replaces the animated `waveform` symbol in the compact
island (14 × 12 pt) and sits beside the state in the expanded player
(11 × 9 pt). Island sizes unchanged (300 × 42, 384 × 172).

- `MusicEqualizer` (`NSViewRepresentable`) → `EqualizerBarsView`: four reused
  `CALayer`s. Playing: one repeating `transform.scale.y` animation per bar
  (0.39–0.61 s, auto-reversing, phase-offset so they never move in step),
  run by Core Animation in the render server: no SwiftUI state per frame, no
  timers. Paused: animations removed, bars settle (0.25 s) into a still,
  dimmed (55 %) arrangement. Stopped, or out of a window (the island hid):
  no animations; back in a window: they resume. Reduce Motion (Orbit's or the
  system's): still bars. `apply` is idempotent: repeated SwiftUI updates and
  colour changes never add or restart animations.
- Colour: the artwork accent when F-3 provides one (`accent`), otherwise the
  theme's (`OrbitGlass.goal`).
- Debug hook: `reducemotion:on|off` sets the island's Reduce Motion in memory
  only (not saved).

**Measured** (2 Nov 2026, real app, scripted helper tab, no audio): hidden
0.0 %; compact, playing with the bars bouncing 0.0 % (vs 7.6–12.4 % for the
old symbol effect). The compact-paused, expanded and Reduce Motion samples of
that run are void: the user was using the Mac (the dashboard opened and their
own full-screen video took over), so the island wasn't on screen; to be
re-measured on an idle Mac.

**Pause/resume investigation (after F-2).** Reported: the bars animate once,
then don't react to pause or resume. Traced end to end: Brave's content
script reports every pause/play as an update (verified in the log), the
source and coordinator pass each state change through (same video id
included: the dedupe compares state), `MusicIsland` updates its item, and
the equalizer settles/restarts. Verified in the real panel with the real
Brave tab: paused → bars still and dimmed, resumed → moving again, the
island's state `compact/paused` → `compact/playing`. No defect in the update
path. What the user saw: the bars only exist while the island is on screen,
and it wasn't when they paused: the compact island dismisses itself after
4 s, the expanded player collapses on any click outside it (clicking Brave to
pause is one: the log shows expanded → dismissed 4.6 s later with no player
command), and resuming the same track never re-announces it (by design,
3.7E). Changes: the app delegate's observation loop moved into
`MusicIsland.follow(_:)` (same behaviour, now covered by tests); the debug
`state` line shows the island's item state. Decision (user, 2 Nov 2026):
keep the lifecycle as is; pause and resume from the expanded player's own
button to see the bars react.

### Adaptive artwork colours (Stage 3, Step 7F-3)

`Notch/ArtworkAccent.swift` + `ArtworkLoader`: the Music Island takes a calm
accent from the YouTube artwork on screen.

- **Extraction:** Core Image `areaAverage` on a copy shrunk to 64 px, averaged
  in linear light, read as one sRGB pixel. A short-lived CPU-renderer context
  per extraction, caches cleared after (a shared context kept ~40 MB more for
  the session in a benchmark). It runs off the main thread together with the
  thumbnail decode (`Task.detached`, utility; the decode left the main thread
  too), once per thumbnail; only the 480 px thumbnail and the colour come back.
- **Clamping:** HSB, saturation 0.35–0.65, brightness 0.62–0.85; near-grey
  artwork (saturation < 0.08) gets no accent.
- **Cache:** the accent lives beside its image in the 6-image cache and is
  evicted with it; memory only. `accent(for:)` returns the colour of the
  artwork actually on screen (while a new thumbnail loads, the previous one's),
  so an older, slower download can't colour a newer track; a failed thumbnail
  has none. Progress, play-state and title updates are the same artwork: no
  new work.
- **Look:** an 18 % tint of the accent between the black glass and the content
  (never replacing it), fading over 0.6 s (the animation is scoped to that
  layer; instant with Reduce Motion); the equalizer takes the accent, its
  colour fading over 0.6 s under its own Core Animation key, so the bounce is
  never restarted. No accent (Apple Music, which has no artwork; a missing or
  greyish thumbnail): no tint, mint bars. The dashboard widget is unchanged.

**Measured** (2 Nov 2026, real app, scripted helper tab, Mac idle): ten
compact track changes: RSS 79.0 → 102.2 MB (F-1's same run: 78.7 → 90.5),
footprint 18 → 37 MB, 6 cached, one request per thumbnail, 0.0 % CPU after.
Extraction ≈ 1.2 ms per thumbnail (benchmark). Expanded: 7.9 % CPU during the
expand animation, then ~1 %. The roughly 10 MB over F-1 is Core Image's
first use; a Core Graphics average would cost less (benchmark: ~13 vs ~23 MB)
if that matters.

### Music Island motion (Stage 3, Step 7F-4)

`Notch/ProgressTrack.swift` plus small changes in the island views. Island
only: the dashboard widget keeps its look.

- **`IslandMotion`**: every island animation in one place (morph spring 0.35 s,
  hover, tint 0.6 s, press 0.12 s, play/pause symbol replace); with Reduce
  Motion (Orbit's or the system's) each is nil / identity and the press scale
  is 1. Progress keeps moving (information, not decoration).
- **Progress** (`ProgressTrack`, compact 2 pt line and expanded 6 pt bar):
  Core Animation runs the fill linearly from where playback is to the end at
  the playback rate (`bounds.size.width`, linear), in the render server: no
  per-frame SwiftUI work, no timers. Restarted only when the position really
  changes (speed change = pause, resume or rate; a position more than 0.75 s of
  playback away = seek, which jumps rather than slides), never for updates that
  agree with the bar (re-sent snapshots, late titles) or for layout passes at
  the same width. Paused: still at its position. Live streams, unknown
  durations and ads: no bar (the expanded times still read "Live"). Out of a
  window: no animation; back in: from where playback is now. The elapsed /
  total times tick once a second only while playing (as before).
- **Play/pause**: the icon swaps with the system's replace effect; it always
  shows the reported state, so rapid clicks can't strand it (each click asks
  for what the reported state needs).
- **Press feedback** (`IslandPressStyle`): Orbit Glass plus a 0.94 scale while
  pressed (0.12 s), restored on release; layout and hit target unchanged;
  commands aren't delayed. Island controls only.
- **Unchanged and kept**: the artwork cross-fade, retention and stale
  protection (F-1), the accent fade (F-3), the equalizer (F-2: not restarted by
  artwork, metadata, progress or colour), the compact ⇄ expanded spring and the
  island lifecycle.

**Measured** (2 Nov 2026, real app, scripted helper tab, Mac idle): expanded
with the bar running 0.2–0.5 % CPU (F-3: 7.9 % during the expand animation,
then 1.3 %); 0.0 % once dismissed; footprint 17 → 32 MB, RSS 78.7 → 99.7 MB
(two videos, expanded), in line with F-3. Screenshots: progress moving in
step with the clock, paused frames identical 1 s apart, the equalizer still
under Reduce Motion while progress continues.

### Daily Briefing model (Stage 3, Step 8-1)

Model only; the Briefing tab (3.8-2) and its Settings (3.8-3) come later.
The Briefing will be a separate dashboard tab, shown only while enabled; the
Overview, its `widgetLayout` and every other preference are never touched.

- **`briefing.json` v2**: `{"version":2,"dailyBriefingEnabled":false,
  "widgets":["weather","events","clock","goals","tasks"],
  "options":{"events":{"presentation":"expanded"}}}`. Two rows of three cells:
  Weather (compact) + Calendar (expanded); Clock, Daily Goals, Tasks (compact;
  expanded Tasks already lists the goals). Sizes live in the existing
  `options[id]["presentation"]` strings (absent = compact), so the format is
  unchanged. `presentation(for:)` / `setPresentation(_:for:)`.
- **Migration** (in memory, on decoding): a version 1 or unversioned file whose
  list is version 1's default (it was never shown in Settings) takes the new
  list and the new sizes, keeping its other options and never overwriting a
  size it sets; a customised list is kept; a newer version is left alone.
  Nothing is written by migrating: the file changes only with a real change.
  No briefing.json existed on the development Mac.
- **Writes**: `BriefingPreferencesModel.update` saves only when the value
  actually changes (no-op updates write nothing); `resetAll` touches only
  briefing.json (an unreadable one is moved aside first, as before).
- **`DashboardModel.briefing` / `briefingWidgets`**: the briefing is pushed in
  like `preferences`; `briefingWidgets` lists its widgets in order as the same
  instances the registry holds (one data source each), at the briefing's
  sizes, skipping unknown, empty and repeated ids, falling back to compact
  for a size a widget lacks. It never reads or writes `layout`;
  `WidgetVisibility` already starts a widget shown on two tabs once and stops
  it when its last host goes.

### Daily Briefing tab (Stage 3, Step 8-2)

- **Tab**: `DashboardSection.briefing` ("Briefing"), right after the Overview;
  the other tabs keep their order. `DashboardModel.visibleSections` shows it
  only while `briefing.dailyBriefingEnabled`; selecting it while off stays on
  the Overview, and turning it off while selected returns to the Overview
  (the briefing's configuration is kept). `sectionWidgets(.briefing)` =
  `briefingWidgets`.
- **View**: `BriefingSection` (`Dashboard/OverviewSection.swift`) puts
  `briefingWidgets` on the existing `WidgetGrid` (3 columns, rows = half the
  height): Weather + Calendar (expanded); Clock, Daily Goals, Tasks. Two rows
  fill the 740 × 420 dashboard exactly: no scrolling. The order and sizes come
  only from briefing.json; the view holds none of its own. Nothing to show:
  "Nothing in your briefing".
- **Widgets**: the registry's single instances through `WidgetHost`, so each
  keeps its own states, actions and refresh rules (Weather: no city → "Choose
  City", offline notes, retry; Calendar: Connect Calendar / Open Privacy
  Settings / restricted, never asked automatically; Tasks and Goals: local
  files, editing as in their widgets). A widget on both tabs (Weather,
  Calendar, Clock, Tasks by default) keeps running across a switch, with or
  without Reduce Motion (the section transition keeps the old host until the
  new one appears); a widget only on one tab starts and stops with it.
- **App**: `AppDelegate` reads briefing.json at launch (`BriefingPreferencesModel`,
  read-only: nothing is written) into `dashboard.briefing`. Off by default, so
  the tab is hidden until Settings (3.8-3) can turn it on. Debug hook:
  `briefing:on|off` (in memory only, briefing.json untouched; `section:briefing`
  selects it).
- **Not preserved**: a tab's scroll position when switching (every tab is
  rebuilt on selection, as before).

**Verified** (2 Nov 2026, real app, Mac idle): Overview before and after
Briefing on/off identical (only the clock's minute differs); the Briefing with
the user's real data (Weather, Calendar's real "Connect Calendar" state, Clock,
empty Goals, one task) fits exactly; isolated runs (`ORBIT_DATA_DIR` scratch
folders; the real tasks.json/goals.json untouched): an empty folder (Choose
City, empty goals, "Nothing due today") and synthetic fixtures (1 of 3 goals,
2 of 4 tasks with a flagged one). CPU: 0.0 % steady on either tab (one 23 %
sample on the first switch, not reproduced); footprint 18 MB closed, 49 MB
Overview open, 46 MB Briefing open.

### Daily Briefing settings (Stage 3, Step 8-3)

Settings › Widgets › **Daily Briefing** (`BriefingSettings` in
`Settings/SettingsWindow.swift`), below the Overview list:
"Show the Briefing tab"; a row per briefing widget (Weather, Calendar,
Clock, Daily Goals, Tasks, in the approved order) with a Compact/Expanded
picker (disabled for widgets with one size: Clock, Daily Goals) and a
"Show in the Briefing" switch; **Reset Briefing**; footer: the Briefing has
its own widgets and sizes and never changes the Overview.

- Every control writes briefing.json through `BriefingPreferencesModel.update`
  (saved only on a real change); `onChange` fires after each real change and
  after `resetAll`, and `AppDelegate` pushes the value into `dashboard.briefing`,
  so the tab appears, disappears (returning to the Overview if selected) and
  re-lays out at once. `SettingsModel.briefing` is the same model.
- `BriefingPreferences.isShown(_:)` / `setShown(_:_:)`: hiding removes the id
  from `widgets` but keeps its size; showing puts it back in its place in the
  approved order; unknown ids stay where they are.
- Reset: the approved defaults (off; Weather, Calendar expanded, Clock,
  Goals, Tasks) in briefing.json only. The `briefing:on|off` debug hook still
  sets the value in memory only; the next Settings change replaces it with the
  saved value.

### Daily Briefing final check (Stage 3, Step 8-4)

No defects found; no code changes. Verified 4 Nov 2026 in the real app (the
user's briefing.json: enabled, defaults), Mac idle, data read-only: the
two-row layout at 740 × 420 with consistent Orbit Glass cards (Weather
23° Gorakhpur; Calendar's real "Connect Calendar" state; Clock; Goals and
Tasks with completed items); Settings › Widgets › Daily Briefing (toggle,
five rows, one-size pickers disabled, Reset, footer); the Overview unchanged
after switching back; the Music Island's state unchanged throughout. Empty and
populated states: the isolated 3.8-2 runs (widget code unchanged since).
Offline weather and Calendar denied / restricted / no events: covered by
WeatherTests, CalendarTests and the Briefing state-rendering test (not
reproduced on the real Mac: no network or permission changes).

Measured (Orbit running 5 min after the user's relaunch): dashboard closed
94 MB footprint, 0.0 % CPU; Overview open 106 MB, 0.2–0.8 % (Now Playing's
progress ticking while a video plays); Briefing open 105 MB, 0.0 %. Ten
open → Briefing → Overview → close cycles: 97 → 106 → 100 MB, 98 MB after
30 s idle: no growth (most of it is ordinary heap from what the session had
opened: Settings, dashboard, island artwork).

### System volume service (Stage 4, Step 1-1)

`Services/SystemVolume.swift`: the default output device's volume and mute
for the Sonic Pulse HUD (4.1-2 onward). Public CoreAudio HAL only, no
permission, no polling, no UI; nothing sets the volume yet. Solar Glow
(brightness) stays in the design backlog: Apple Silicon has no public
brightness API (no `IODisplayConnect` services; DisplayServices is private;
CoreDisplay ships no headers).

- **Reads** (`CoreAudioHardware`): `kAudioHardwarePropertyDefaultOutputDevice`
  on the system object (global scope); the device's `kAudioObjectPropertyName`;
  `kAudioDevicePropertyVolumeScalar` (output scope) on the main element, or,
  when the device has none, on its `kAudioDevicePropertyPreferredChannelsForStereo`
  channels (the development Mac's "CX80U" output has volume on channels 1 and
  2 only, mute on main); `kAudioDevicePropertyMute` (output scope, main);
  `AudioObjectIsPropertySettable`. Failed reads return nil, never a guess.
- **State** (`SystemVolumeStatus`): `.stopped`, `.noOutputDevice`, or
  `.device(VolumeState)` with the device id, name, volume 0…1 (the loudest
  channel; clamped; nil without software volume or for a non-finite reading),
  mute (nil without a mute control) and whether it could be set.
- **Listeners** (`AudioObjectAddPropertyListenerBlock` on the main queue): the
  system object's default device, and on the device each volume element plus
  mute. A device change removes the old device's listeners and adds the new
  one's; the same device again just re-reads. `stop()` removes everything.
  Each callback carries the generation it was registered in and the device,
  so late deliveries after a switch or stop are ignored. A listener that
  can't be added is logged and counted (`listenerFailures`); readings still
  work.
- **Feedback loops**: a later volume control must set values through this
  service and ignore its own echo; not needed yet.
- **Not yet**: no setter, no per-device memory. Started by
  `AppDelegate.startSonicPulse()` (4.1-3).

### Volume HUD logic and overlay arbitration (Stage 4, Step 1-2)

`Notch/VolumeHUD.swift`, logic only: no window or view yet, and nothing in the
app is wired to it (wiring the island to it before the HUD window exists
would hide a compact island on volume changes with nothing in its place; that
comes with the window in 4.1-3, and is now done there).

- **`VolumeHUD`** (state machine, injectable `HUDScheduler`; the real one is a
  sleeping `Task` per timer): `hidden` → `visible` (a change) → `updating`
  (further changes: the interaction expansion, `isExpanded`, off with Reduce
  Motion) → `pendingDismissal` (no change for 0.3 s) → `hidden` 1.5 s after the
  last change. Every change restarts both timers (one of each at most). Only a
  change of device, volume (beyond 0.001) or mute shows it: the first reading
  (a baseline), repeats, name changes, a device appearing after "no output",
  and `expectOrbitChange` echoes (for a later volume control) don't. A device
  without software volume shows with no level. Changes while suppressed are
  noted but not shown (so closing the dashboard doesn't replay them).
  Generations make late timers harmless; `shutdown()` stops everything.
- **`NotchOverlayCoordinator`**: one owner for the slot below the notch.
  `decide`: an open dashboard → nothing (it covers the slot; the HUD is
  suppressed); the expanded player → the island (HUD suppressed); a visible
  HUD → the HUD (covering a compact island: `coversIsland`); a compact island →
  the island; otherwise nothing. It follows its inputs (volume status, island
  phase, dashboard open) and the HUD's own timers through Observation, never
  changes the island's state: a covered island comes back if still compact,
  one that dismissed itself meanwhile stays dismissed. `spaceChanged()` hides
  the HUD (as the island does); full screen is handled by the window (no
  full-screen auxiliary, like the island). `shutdown()` stops following.

### Sonic Pulse volume HUD (Stage 4, Step 1-3)

`Notch/SystemHUDPanel.swift`: the window and view for `VolumeHUD`, wired in
`AppDelegate.startSonicPulse()` (`SystemVolume` → `NotchOverlayCoordinator` →
`SystemHUDPanel`, which hands the compact island's slot over through
`MusicIslandPanel.setCovered`). The setting and the Core Animation motion
came in 4.1-4 (below).

- **Window** (`SystemHUDPanel`, created once): borderless non-activating
  panel at `.statusBar`, `[.canJoinAllSpaces, .stationary, .ignoresCycle]` (no
  `.fullScreenAuxiliary`: not on full-screen Spaces, like the island),
  ignores the mouse, never key or main, primary display only. Its frame is the
  compact island's (300 × 42, 6 pt below the notch) widened by 16 × 6 pt so the
  expansion isn't clipped; same top edge and centre. It follows the
  coordinator's `overlay` and `isSuppressed` through Observation: ordered
  front for `.volumeHUD`; otherwise the 320 ms dismissal plays and then it is
  ordered out, and only then does the island get its slot back. When the
  dashboard or the expanded player takes the slot it is ordered out at once,
  even mid-fade, so it never sits over them. Off the screen whenever hidden.
- **Island hand-over**: `MusicIslandPanel.setCovered` orders a compact island
  out and back without touching `MusicIsland`'s state (its auto-dismiss keeps
  running; one dismissed meanwhile stays dismissed); the compact island's own
  order-front paths respect `isCovered`. The expanded player is never covered.
- **View** (`SonicPulseView` / `SonicPulseCapsule`): 300 × 42 capsule, black
  Orbit Glass like the island (0.82 black, `.regular` glass tinted 0.55, the
  rim) plus a specular highlight along the top; the speaker symbol
  (`speaker.slash.fill` muted, `speaker.fill` at 0, `speaker.wave.1/2/3.fill`
  below ⅓ / ⅔ / above, `hifispeaker.fill` for a device without software
  volume) with `.symbolEffect(.replace)`; a 12-segment meter in Orbit's accent
  (dimmed to 0.35 when muted; at least one segment for any audible level);
  the percentage (or "Muted") with a numeric text transition; the device's
  name above it when the change was a switch of output device; a device
  without software volume says "<name> sets its own volume" with no meter or
  number. One accessibility element: "<device>: Volume 60 percent" / "Volume
  muted" / "Volume is set on the device".
- **Motion** (as of 4.1-3; moved to Core Animation in 4.1-4, same look):
  appears from the top centre (scale 0.85 + opacity, spring 0.3 s) and leaves
  the same way; grows to 1.04 while changes keep arriving
  (`isExpanded`); the meter eases over 0.18 s; one Core Animation ring
  (`PulseRingView`) expands and fades from the speaker per shown change
  (`VolumeHUD.pulse`), 0.6 s, removed on completion, replacing one still
  running, none until it's in a window, none left when removed. Reduce
  Motion (Orbit's setting or the system's): no ring, no expansion, no
  symbol/number transitions, instant meter and appearance.
- **Cost**: no polling and no timers while hidden (the HUD's two timers exist
  only while it shows; the ring is render-server animation); the window is
  never recreated. Quitting shuts the coordinator down, stops the panel and
  the volume listeners.
- **Debug** (debug builds): the `state` line adds
  `hud=<overlay>/<phase>/<name:volume:muted>/pulse=/visible=/covered=/listeners=`;
  `reducemotion:on|off` also sets the HUD's; `volume:<0…1>|mute|none|real`
  feeds the HUD a simulated reading (the real volume is never changed;
  `real` re-reads it); `volumehud:on|off` is the setting, in memory only.

**Measured** (4 Nov 2026, real app, CX80U output, Mac idle, small CoreAudio
nudges of +1/16 restored to the exact original levels): hidden 0.0 % CPU,
footprint 18 MB at launch; visible (one step) 9.7–19.3 %; rapid (14 changes
at 110 ms) 20.1–29.0 %; back to 0.0 % once hidden; footprint 26 → 41 → 39 MB
over the HUD runs, 51 MB after a further run with the dashboard opened.
Four listeners throughout (system, channels 1 and 2, mute). Each change
counted once (`pulse`), a change with the dashboard open not shown or
replayed, Reduce Motion fully drawn at 120 ms with no ring. Screenshots: the
step (24 %, three segments, `speaker.wave.1`), rapid (rolling number), muted
(slashed speaker, dimmed meter). The visible cost is SwiftUI re-rendering the
glass capsule through its transitions (the island's expand: 7.9 %); it lasts
only while the HUD shows.

### Sonic Pulse settings and performance (Stage 4, Step 1-4)

- **Setting**: Settings › General › Volume › "Show Volume HUD"
  (`OrbitPreferences.volumeHUD`, default on, in preferences.json; a file
  without it, or with an invalid value, reads as on and keeps every other
  field; "Reset General Settings" turns it back on). It applies at once via
  `AppDelegate.apply` → `SonicPulseController.setEnabled`: off orders the HUD
  out at once (mid-fade too), hands the island its slot back, shuts the
  coordinator down (no timers) and stops `SystemVolume` (every listener
  removed); the window is kept, not following anything. On starts all of it
  again; the first reading is a baseline, so turning it on shows nothing.
  Quitting is `setEnabled(false)`.
- **Echo expectation** (`VolumeHUD.expectOrbitChange`, for a later volume
  control): used up by the next change whatever it is (shown if it isn't the
  echo), and expires after `echoWindow` (1 s) if no echo comes, so it can
  never hide an unrelated change later; cleared by `shutdown()`, ignored while
  off.
- **Performance**: a profile (`sample`, rapid changes) showed the main
  thread busy in SwiftUI's CPU-rendered interpolated drawings (the
  `numericText` digits and the symbol replace, with a CPU blur) and in
  re-resolving the glass material while the capsule's scale animated. The
  motion now runs in Core Animation and SwiftUI only draws the static glass
  capsule: `SonicPulseStage` (appear 0.85 → 1 spring with a fade, the 1.04
  expansion, leaving 0.25 s; a `sublayerTransform` about the top centre and
  an opacity on a plain layer above the hosting view); `SegmentMeterView` (12
  layers, explicit 0.18 s colour fades, only the segments that change);
  `LevelTextView` (a text layer; the new value pushes in from below when the
  level rises, from above when it falls, clipped like rolling digits); the
  speaker in an `NSImageView` with the system replace transition; the pulse
  ring as before. The panel follows `isExpanded` and Reduce Motion
  (Orbit's or the system's: everything instant). After hiding, the stage is
  reset: no animation left on any layer.
- **Measured** (4 Nov 2026, real app, Mac idle, simulated readings through
  the debug hook, so the real volume was never changed; CPU seconds Orbit used
  per fixed sequence, three rounds): two separate appearances in 4.3 s:
  0.33–0.36 s (≈ 8 %) before → 0.05–0.09 s (1.2–2.1 %); 14 rapid changes and
  the dismissal: 0.62–0.74 s (≈ 16 %) before → 0.24–0.28 s (5.6–6.6 %).
  Turning off only the two text transitions (an experiment, not kept) gave
  0.25 / 0.44 s, so both halves mattered. Hidden, dismissed, turned off, and
  the dashboard open: 0.0 %. Listeners: 0 off, 4 on. Footprint 18 MB off,
  21–26 MB hidden, 68–74 MB while the HUD is on screen (render surfaces),
  back to 26 MB a few seconds after it hides, steady over six cycles (no
  growth). Screenshots: settled, rapid (expanded, ring), muted, a device
  without software volume, 0 %, gone, and no HUD over the open dashboard.

### Orbit Pet: decisions (Stage 5.1, approved)

A customizable animated cat, local-first, off by default.

1. A clean 2D vector character (Core Animation shape layers with gradients
   and Orbit-style highlights), drawn in code: one rig, so every pose looks
   the same cat.
2. A cat first; a dog template later.
3. The Desktop Pet sits just above the desktop icons, behind application
   windows.
4. It follows the user across Spaces but never appears over full-screen
   apps.
5. The Notch Companion peeks below the notch with the lowest overlay
   priority (below the compact Music Island).
6. Photo personalization extracts appearance, palette and markings with
   local Vision processing; no ImageCreator.
7. A click is a playful reaction.
8. Orbit Pet is off by default; the Desktop Pet and the Notch Companion have
   independent toggles.

Brightness (Solar Glow) stays in the backlog: no public API reads or
observes the built-in display's brightness on Apple Silicon (Stage 4.2-1).

### Pet model and state machine (Stage 5.2)

`Pet/PetModel.swift` and `Pet/PetActivity.swift`: behaviour only; no
graphics, windows, settings or persistence yet, and nothing in the app
creates them.

- **States**: hidden (initial), idle, playful, walking, running, sleeping,
  dragged. `PetModel.next(state, event, canMove:, canDrag:)` is the whole
  table; anything it rejects leaves the state alone:
  hidden → idle on show; any shown state → hidden on hide; a click from idle,
  playful (restarts it), walking, running or sleeping → playful, which returns
  to idle after 1.2 s (0.5 s with Reduce Motion); idle ⇄ walking ⇄ running
  when the pet can move, back to idle when the mover finishes (or after an
  8 s safety limit); idle → sleeping when the user is inactive, back on
  activity; dragged from any shown state but itself when the Desktop Pet is
  on screen, back to idle on release, and nothing else while held.
- **Experiences**: `Toggles` (master `pet`, off; `desktop` and `companion`,
  on). The Desktop Pet is visible with the master on, its toggle on, the Mac
  awake and unlocked, no full-screen app, and its window not occluded; the
  companion likewise with its own toggle and occlusion. Either alone is
  enough; neither visible → hidden. Moving and dragging need the Desktop Pet
  (the companion only reacts to clicks); turning the desktop off mid-walk or
  mid-drag returns to idle (or hidden). A Space change ends a walk or a drag.
- **Activity** (`PetActivity`): injected inputs for display sleep, session
  lock, full screen, each experience's occlusion and Reduce Motion, plus
  user activity and Space changes; `onChange` tells the model. Inactivity
  (default 120 s) uses one timer set for when the threshold would pass,
  given the injected "seconds since last input" (the real source is
  `CGEventSource.secondsSinceLastEventType`: a timestamp only, no event
  content, no monitoring, no permission); at the check it re-reads and either
  marks the user inactive or waits for the rest. An activity event counts as
  "just now" whatever the timestamp says, so a wake never bounces back to
  sleep. No timer while inactive, asleep or locked, or while the pet is
  hidden (`setTracking`). Waking is event-driven: user activity, display
  wake, unlock, a Space change or a click.
- **Scheduling** (the shared `HUDScheduler`): idle has a low-frequency
  `fidget` cue (every 8 s; the renderer will play one blink or tail flick per
  change) and, on the desktop, a `wander` (45 s) that starts a walk or a run
  (injected choice); the fidget never delays the wander. Playful has one
  reaction timer; walking and running a safety limit; hidden, sleeping and
  dragged none. Entering a state cancels the old state's timers and bumps a
  generation, so late callbacks do nothing. Reduce Motion: no walking or
  running (a walk in progress ends), no fidgets or wander, the click reaction
  kept but brief. `shutdown()` hides it, cancels everything, stops the
  activity model and ignores every later input.

### Pet character rig (Stage 5.3)

`Pet/PetRig.swift` (rig, hosting view, model follower) and, debug builds
only, `Pet/PetPreview.swift`. Orbit Pet is an interactive companion, not an
AI assistant: no chat, agents or AI features anywhere in it.

- **Character**: a side-on ginger cat with a front-facing head, drawn in code
  in a 120 × 100 design space (y down) and scaled to any width (28 pt for the
  notch, 48–120 pt on the desktop). Soft top-to-bottom gradients, a thin
  darker edge so it reads on dark and light wallpapers, highlights along the
  back and head, cream muzzle, chest, socks and tail tip, pink nose, inner
  ears and blush, green eyes with a radial iris, pupil and two highlights,
  whiskers, a small mouth, a soft ground shadow. Transparent; no text.
- **Rig**: one layer tree built once and reused; every part a layer whose
  anchor is its joint (head at the neck, legs at hip and shoulder, the body
  from the belly, ears at their base, the tail at its root, lids from the
  top). Parts: body, head, two ears, two eyes with lids, happy (^ ^) and
  closed eyes, mouth, whiskers, tail (one cubic, so every tail shape morphs
  into every other), four legs with paws (far ones a shade darker), the
  shadow, and an empty accessory mount at the neck. `PetAppearance`
  (primary, secondary, eye and pink colours; muzzle, bib, socks and tail-tip
  markings; proportions of head, ears, tail and legs; accessory) is the
  customization surface for later stages; `PetFacing` mirrors it.
- **States** (`PetModel` stays the only state machine; `PetCharacter` follows
  its state, `fidgets` and `reactions` through Observation with a generation
  guard): each state has a `PetPose` (`PetRig.pose(for:)`) eased in over
  0.28 s, plus its motion: idle breathes, sways its tail and plays one cue
  per model fidget (a blink with an ear twitch, head tilt or tail flick in
  turn); playful shows the happy face and, per click, two hops with a tail
  wag and shadow; walking and running swing diagonal leg pairs (0.72 s /
  0.36 s strides) with body and head bob and tail sway; sleeping is a loaf
  (legs tucked, head down, eyes closed, tail around the paws) breathing
  slowly; dragged hangs still (legs and tail down), nothing fighting the
  drag; hidden removes every animation and hides the layer tree. The same
  state again restarts nothing; a new state removes the old one's motion and
  one-shots, so nothing stale carries over; fidgets and reactions play only
  in their own state.
- **Reduce Motion** (Orbit's or the system's, set on the follower, or the
  model's condition): no continuous motion, no hops or cues, poses placed
  instantly with a 0.2 s crossfade; the click still shows the happy face.
- **Rendering cost**: all motion is Core Animation in the render server; no
  SwiftUI animation, no timers in the rig. The tail sways by rotating (its
  path changes only between poses). The moving parts (body, head, tail,
  legs) are rasterized at screen scale: measured, their masked gradients
  were otherwise re-rendered offscreen every frame.
- **Preview** (debug builds, `orbitctl pet:preview` or `pet:preview:single`):
  a titled window (not a desktop or notch window) with the cat at 28, 48, 72
  and 120 pt on dark and light strips and at 300 pt for detail; a state
  picker (idle, playful, walking, running, sleeping, dragged), Reduce
  Motion, Fidget, Click and Turn. Also `pet:state:<name>`,
  `pet:reducemotion:on|off`, `pet:fidget`, `pet:react`,
  `pet:face:left|right`, `pet:close`. It drives the rig directly; it has no
  model.
- **Measured** (5 Nov 2026, real app, Mac idle; CPU seconds over fixed
  windows, still vs animated alternating, four rounds): Orbit 0.0 % in every
  state, preview open or closed. WindowServer with one 96 pt cat: still
  ≈ 23–25 %; animated, as first built, ≈ 40 % (idle) / 43 % (running); with
  the rotating tail alone no change; with the moving parts rasterized
  ≈ 29.6 % (idle) / 29.1 % (running), i.e. about +4–5 points over still,
  close to a control (one 20 pt layer spinning in its own window: +3.3).
  WindowServer's baseline varies with whatever else is on screen, so only
  the alternating comparison is meaningful, and it depends on that too: on
  an otherwise quiet screen (WindowServer 8.8 % with no preview, 8.7 % with
  a still cat) the animated cat measured 23.8–26.3 %, about +15 points: any
  continuous animation keeps the compositor drawing frames. A lower
  preferred frame rate for the calm loops showed no measurable change and
  was not kept. Footprint: 26 → 27 MB with the single preview, 27 MB with
  all ten cats. Stage 5.4 should keep idle motion in short bursts (around
  the model's fidget cues) rather than continuous, so a pet that sits for
  hours costs nothing between them.
- **Future tricks** (sit, wave, high five, jump, stretch, play, celebrate,
  think, listen, sleep): the rig takes each as a named pose plus a one-shot
  on the same joints. Sleep and play exist; jump is the playful hop. The
  others need the model to carry an action: a transient `performing(action)`
  state (or an action on playful) with a duration and a trigger (a menu or
  double-click for wave and high five; tasks or the calendar for
  celebrate; reminders for stretch). Not added to the 5.2 model yet.

### Running tests

```sh
scripts/test.sh
```

Never use bare `swift test`: it intermittently fails with
`plugin for module 'TestingMacros' not found` on Command Line Tools.
`scripts/test.sh` runs
`swift test -Xswiftc -load-plugin-library -Xswiftc "$(xcode-select -p)/usr/lib/swift/host/plugins/testing/libTestingMacros.dylib"`,
which passed 11 consecutive runs, including forced recompiles and runs from
another working directory. Extra arguments are passed through, e.g.
`scripts/test.sh --filter notch`.

Suites: `NotchGeometryTests` (trigger and dashboard placement),
`NotchInteractionTests` (states, enter/exit, delayed hide, cancellation,
close and reopen), `DashboardModelTests` (default layout, enable/order/
presentation through the model, persistence across relaunch, reset, section
order and metadata), `WidgetRegistryTests` (built-in order and metadata,
SAMPLE honesty, discovery, duplicate/empty id and missing-compact rejection),
`WidgetLayoutTests` (defaults, enable/disable, move clamping, normalisation of
invalid layouts, store round-trip and corrupt data, grid packing),
`WidgetLifecycleTests` (battery loading → ready, subscribe/unsubscribe,
idempotent start/stop, unavailable without a battery; events refresh and
empty; tasks toggle and empty; greeting), `ServicesTests` (battery parsing,
quick actions launch apps only, targets exist). Step 5 added
`PersistenceTests` (JSON round-trip, corrupt data, refuse-to-overwrite),
`ProductivityTests` (checklist rules, tasks add/complete/delete/persist and
corrupt file, goals limit and daily rollover, day key, pomodoro
start/pause/resume/reset/finish/settle/format and relaunch catch-up),
`SystemTests` (CPU and memory formulas, live readers, sampling only while
visible, unavailable states, network monitor lifecycle and summary),
`VaultTests` (PNG import, copy never touches the original, keep/clear inbox
persistence, refusal to delete outside the vault, widget failure isolation),
`DeveloperTests` (folder scan, Git flag, rescan, empty state),
`AIChatTests` (send + sample reply, empty/duplicate sends, clear, provider
saved but chats not), plus visibility ref-counting and typing hold-open.
The drag-and-drop fix rewrote `VaultTests` (byte-for-byte PNG + metadata +
preview, TIFF→PNG and JPEG kept, unsupported GIF, invalid/empty/truncated
PNG/JPEG/TIFF, size limit, file import leaves the original's bytes and
modification date untouched, duplicates by data and by file, failed image
write and failed index write leave no trace, legacy index loads, widget
outcomes, drop receiving) and added `ScreenshotDragTests` (file URL vs data
preference, rejecting text and non-image files, registered types; private
named pasteboards, never the user's clipboard), drag interaction tests and
notice timing; outbound drag added export-copy tests. Step 6 added
`SettingsTests` (defaults equal the approved design; tolerant decoding and
clamping; missing file → defaults; changes persist; resets; corrupt file
never overwritten and moved aside only on Reset All; widget enable/order/
size/reset through the dashboard model; storage report; expired-copy cleanup
never touches Vault files; window created once, reused after close, Space
behaviour, appearance). Tests that waited a fixed time for async work now
wait for the condition, because main-actor work in parallel tests (creating
the Settings window) could delay them. Stage 2 Step 1 added
`VaultSafetyTests` (legacy index loads with no write; new fields round-trip
and are omitted while unset; backup exactly once and never overwritten; no
backup for a new vault; missing/unreadable library; corrupt index untouched;
legacy duplicate without a hash; soft delete/restore/re-import restore;
30-day purge eligibility incl. future dates; purge only from Recently Deleted,
missing file, failed purge, outside-vault refusal; Clear Inbox protection
rules and confirmation; widget delete/restore/permanent delete; rebuild from
valid images, refusal of invalid/unsupported/mislabelled/nested/symlinked
files, widget rebuild only when unreadable, a failed backup leaves the index
untouched, dropping a screenshot that is in Recently Deleted restores it).
`VaultCopyLifecycleTests` runs the whole lifecycle on disposable *copies* of a
real Vault and is skipped unless pointed at them
(`ORBIT_VAULT_COPY_LEGACY=<copy of a pre-Stage-2 Vault>`,
`ORBIT_VAULT_COPY_CURRENT=<copy of a migrated Vault>`); it refuses any path
inside Orbit's real data folder. "Eventually hidden" notch tests now wait for
the state instead of a fixed sleep. Stage 2 Step 2 added `VaultPerformanceTests`
(main-actor responsiveness during a large import, queued order, simultaneous
duplicates, cancellation, failed writes, formats/metadata/originals, 100 MB
limit, thumbnail size and cache LRU/limits, missing/corrupt images, cancelled
thumbnail work, bounded and released previews, rapid selection, hash backfill
once/never replacing/skipping bad files, launch drag-copy cleanup, a
1,000-screenshot library; `PERF` lines print measurements), and the migrated
copy lifecycle now covers the backfill. `VaultDuplicateTests` drive duplicates
through the real drop path (`receive` → queue → notice): the same file twice,
after relaunch, from Recently Deleted, inside a multi-screenshot drop, as file /
data / Paste, PNG/JPEG/TIFF/HEIC; and a recapture of the same screen (one pixel
different) is saved as a new screenshot. A duplicate means byte-identical
stored bytes (SHA-256); two screenshots of the same screen taken seconds apart
differ (clock, pointer) and are both kept. Stage 3 Step 2 added
`OrbitGlassTests` (tokens; Reduce Motion rule incl. the system setting; hover
tracking; ImageRenderer pixel checks: 18 pt corners cut away, top highlight
brighter than the body, card stays dark, identical in Light and Dark, hover
brightens without scaling, meter fill, every widget state framed by the
card). Stage 3 Step 3 added `WidgetInfrastructureTests` (state mapping and
rendering incl. needs-access vs unavailable, Retry, stale note; built-in
widgets unaffected; refresh only when stale; joined simultaneous refreshes;
failure keeps data; cancellation on hide drops late results; mark-stale while
hidden; interval only while visible; WidgetVisibility counting; error
mapping; cache expiry, disk write-on-store, corruption; refresher seeded from
cache; briefing defaults, tolerant decoding, atomic persistence, corrupt file
never overwritten). Stage 3 Step 4 added `TodayTests` (legacy decoding and
shape, new fields and unknown values, completion times, editing identity,
ordering incl. stable order, today's progress and zero tasks, create/edit/
delete persistence, one-time backup, failed backup, unreadable files, goals
editing and history at the reset, history cap, compact/expanded rendering,
ring under Reduce Motion; `todayCopyMigration` runs on copies of real files
when `ORBIT_TODAY_COPY` is set). ImageRenderer doesn't draw ScrollView
contents or text fields, so the expanded list and editor are checked in the
app. Stage 3 Step 5 added `CalendarTests` (no request before Connect;
denied/restricted/write-only; revocation drops data; disconnect and
reconnect; ordering, all-day, multi-day labels, recurring occurrences,
duplicate titles, now/next/past, countdown; DST 23/25 h days and time-zone
changes; selection default/customised/new/missing calendars and persistence;
changes while hidden vs visible, one observer across openings; hiding cancels
and releases; empty day; no event data on disk; compact/expanded/connect
rendering incl. Reduce Motion). ImageRenderer also can't draw Liquid Glass
(glass buttons are checked in the app). Stage 3 Step 6 added `WeatherTests`
(geocoding, similar names and duplicates, request contents, forecast decoding,
WMO mapping incl. symbols existing, unit conversion, HTTP/JSON/offline
errors, unconfigured state, stale-only fetching and joined requests, offline
cache with note and retry, cancellation, city persistence, unit switching,
cache for another place / corrupt cache, corrupt settings, location prompts
once and only on click, rendering, attribution) with a mock HTTP layer and
mock location: no real requests. Stage 3.7B added `NowPlayingTests`
(payload parsing incl. missing/odd fields and states, duration bounds,
waiting before the first notification, Music launch/quit and other apps
ignored, observer removal and no doubling on restart, duplicate updates,
playing-over-paused and most-recent tie-break, coordinator lifecycle,
widget states and rendering) with a mock feed and mock sources; nothing talks
to Music.app. Stage 3.7D added `BraveYouTubeTests` (framing split byte by
byte, empty and oversized lengths, message validation and round trip,
playback mapping, tab selection across several tabs and helpers, Music and
YouTube in the coordinator, the socket's permissions, connect/disconnect and
bad frames, commands reaching only the selected tab, the helper relaying both
ways, reconnecting to a restarted Orbit and exiting with Brave, progress
maths, widget rendering) over real sockets and pipes in a temporary folder;
nothing talks to Brave. `BraveExtensionTests` run the extension's own
`background.js` and `content.js` in JavaScriptCore with mocked `chrome.*`/DOM
objects and fake timers (native retry with backoff, replay after reconnect,
release with the last tab, injection into open tabs, re-report after a
service worker restart, re-injection, orphaned copies, manifest
permissions). Seek controls: skipping from the extrapolated position both
ways, clamping at 0 and the end, the immediate update, refusal during ads,
live streams and for a stale video or tab (nothing reaches the browser), no
buttons for Music, and commands reaching only the tab on screen.
`MusicIslandTests`: playback starting shows it and it hides after the
configured time (and not before a longer one), position updates every 10 ms
don't extend it, pause/resume and progress never reopen it, found-paused
never pops up, a new video or a restart after stopping announces again (a
late title or switching back to another tab's video doesn't), Music tracks by
name, the expanded player has no timer, follows playback and stays until
dismissed and never reopens for the same track, hovering holds off the
dismissal, dismissing sends no command (playback and the widget carry on),
the setting (on, 4 s, clamped, older files) hides only the island, dashboard
and island state stay separate (an open player collapses under the notch
hover; nothing pops up after the dashboard closes), Space changes and
quitting cancel everything, geometry, the panel's frames, focus, Escape (a
real key event), outside-click monitor and leaving the screen, rendering.
`ArtworkTests` (3.7F-1): identity mapping, labels and shapes, unknown
sources; failed thumbnails (404, offline, too large, not an image, wrong host)
fetched once and shown as the placeholder; cancellation isn't a failure; the
previous artwork kept while the next loads and dropped after a failure; a
slower, skipped download never replaces the current one; six images at most,
480 px, never enlarged. `MusicEqualizerTests` (3.7F-2): four out-of-step
repeating animations while playing, inside the frame; paused still and
dimmed; stopped and out-of-window leave none (and resume in a window); Reduce
Motion still; twenty updates, a colour change and five re-appearances never
stack or restart animations; the accent falls back to the theme.
`EqualizerPropagationTests`: end to end through the real socket, source,
coordinator, `MusicIsland.follow` and the hosted view: five pause/resume
cycles on the same video id, progress and late-title updates not restarting
the bars, a rapid flurry settling on the last state, Reduce Motion and
hiding. (`intervalRefreshesRunOnlyWhileVisible` now lets an already-started
fetch land before counting: a test race, not a product change.)
`ArtworkAccentTests` (3.7F-3): the average of known images (solid, split
halves, teal, grey → none, large → shrunk), the saturation/brightness band,
each thumbnail analysed once, a slower older thumbnail never colouring a newer
track, eviction and failures leaving no stale colour, no artwork and Apple
Music neutral with mint bars, and the bars' colour fade (0.6 s, own key, the
bounce untouched; instant with Reduce Motion; nothing for the same colour).
`MotionPolishTests` (3.7F-4): linear progress to the end at the playback rate
(2× halves it), paused still, end-of-video full and still, live/unknown/ads no
bar, agreeing updates and layout passes never restarting while a seek jumps
and pause/resume restart, hiding stopping and showing resuming from now (one
animation, never stacked, none outside a window), Reduce Motion turning off
the morph, hover, tint, press scale, icon swap and artwork fade, the press
scale 0.94 → 1, and rapid play/pause clicks following the reported state.
`BriefingModelTests` (3.8-1): the default order and sizes (exactly two rows
of three), version 1 migration (old list, unversioned, a kept size, a
customised list, a newer version), unknown/empty/repeated ids and unsupported
sizes, on/off never changing the Overview's layout bytes or widgets, writes
only to briefing.json and only on a real change (migration rewrites nothing),
resetting independently of the Overview and preferences, and shared widget
instances started once across two tabs. `BriefingTabTests` (3.8-2): the tab
only while enabled (selecting it while off stays on the Overview; turning it
off while selected returns there; configuration kept), the real registry's
order, sizes and two-row packing, switching never touching the Overview's
layout, no scrolling in the real `DashboardView` at 740 × 420, shared widgets
never restarted across a switch (with and without Reduce Motion) and stopped
with their last host, every widget state rendering in compact and expanded,
and the real widgets keeping their own states (no city → Choose City; Calendar
whatever this Mac allows, never asked). `BriefingSettingsTests` (3.8-3):
hiding/showing keeps the approved order and sizes (unknown ids stay, never
twice), Settings changes reaching the tab at once and surviving a relaunch,
one-size widgets staying compact, turning it off while viewing returning to
the Overview, reset restoring the defaults in briefing.json only
(preferences.json and the layout byte-identical), and the in-memory debug
hook alongside saved settings. `SystemVolumeTests` (4.1-1): a fake audio layer
for the initial state, volume and mute changes (clamped; non-finite → none),
switching between a main-element device, a stereo-channel device, one without
software volume or mute, and none (old listeners removed, new ones added),
late callbacks after a switch or stop ignored, start/stop balanced with no
duplicates, unreadable properties and refused listeners; plus a read-only
check of this Mac's real default device. `VolumeHUDTests` (4.1-2): a manual
clock and fake inputs for the baseline and repeats, show → settle →
dismiss at 1.5 s, mute/unmute, rapid changes restarting one pair of timers
(expansion off with Reduce Motion), device switches and devices without
volume, Orbit's own echo, late timers and shutdown, suppressed changes not
replayed, every priority combination, the HUD covering and handing back a
compact island (a dismissed one stays dismissed), dashboard and expanded
player suppression, rapid transitions settling on the rules' answer, and
nothing following after shutdown. `SonicPulseTests` (4.1-3): meter
segments, the speaker symbol, text and accessibility labels (never an
invented level), one pulse per shown change and the device named on a
switch, the ring playing once per value (deferred until in a window, none
with Reduce Motion, one at a time, nothing left when removed), Reduce Motion
turning off the expansion, the window's configuration and geometry (no
full-screen auxiliary), show → fade → order out → island handed back, a
change during the fade keeping the same window, the dashboard and the
expanded player taking the slot at once (even mid-fade), a real
`MusicIslandPanel` covered and restored (a dismissed one not brought back),
Space changes, devices without volume and no output, and shutdown. Real
windows are kept at alpha 0; the real volume is never touched. 4.1-4 adds
the setting (on by default, old and invalid files, persistence, General
reset), turning Sonic Pulse off and on with a fake CoreAudio layer
(listeners removed and re-added in balance, nothing shown by turning it on,
one follow loop however often it's toggled, off mid-show and mid-fade), the
echo expectation used up or expiring, the meter's layers (one fade per
changed segment, none for repeats or with Reduce Motion), the level's slide
direction, the stage's appear/grow/leave/reset about the top centre, Reduce
Motion with no animations, and nothing left running once hidden. `PetModelTests` (5.2), on a manual
clock with a fake idle source: every valid transition and the rejection of
all others, off by default, the independent experiences, the click
reaction (and restarting it), walking and running (the wander, the safety
limit, never on the companion), inactivity to sleep and activity to wake
(one timer, re-read at the threshold, nothing while asleep), dragging on the
desktop only (Space changes, turning the desktop off mid-drag), display
sleep and lock, full screen and occlusion, Reduce Motion, stale callbacks,
and shutdown. `PetRigTests` (5.3), offscreen: the rig built once with every
part and its joints, never rebuilt; size, facing and scale (contents and
rasterization); appearance, markings and proportions; each state's pose and
motion (diagonal strides, faster running, a still drag); fidgets and
reactions as one-shots in their own state only, restarted not stacked, and
none carried into the next state; Reduce Motion (no loops, no eased poses,
a crossfade, the happy face kept); hidden removing everything; repeated
states restarting nothing; and the follower with a real `PetModel` on a
manual clock. 392 tests (3 skipped by default). File tests use throwaway folders under `$TMPDIR`. Tests never touch
UserDefaults (they use an in-memory `WidgetLayoutStore`): `cfprefsd` writes
suite plists into `~/Library/Preferences` lazily, so throwaway suites left
empty files behind even after deleting them.

### Future modules (not yet implemented)

**Screenshot Vault — Stage 2 (planned)**
- Favorites (protected from Clear inbox), a separate Vault management window,
  collections, tags, search and filters.
- OCR (Vision, on device) — opt-in, **disabled by default**.
- Optional screenshot-folder monitoring — opt-in, disabled by default, needs a
  user-chosen folder; not designed for implementation yet.

**Smart Screenshot OCR**
- On-device text recognition (Vision framework) for vaulted screenshots.
- Searchable screenshot text, copy text out of an image.

**Daily Briefing**
- One dashboard view summarizing the day: calendar, weather, focus goals,
  reminders and relevant system/dev status.

**Universal Quick Launcher**
- Keyboard-driven launcher for apps, files, actions, tools and AI prompts.

**Smart File Shelf**
- Drag-and-drop holding area for files in transit between apps and Spaces.

**Workspace Profiles**
- Named setups (e.g. Coding, Study, Meeting) that switch widgets, apps,
  window layout and focus settings together.

**Productivity Center**
- Notes, Focus sessions, eye-break reminders, Calendar, Clipboard history.

**Developer Hub**
- GitHub activity, developer tools, project shortcuts, build/CI status.

**System Monitor**
- CPU, RAM, storage, battery, network, Bluetooth.

**Quick Tools**
- Music player controls, audio output/volume, weather, small utilities.

**AI Hub**
- Fast access to ChatGPT, Claude and Gemini from the dashboard.

**Orbit Agent Bridge**
- A local interface that lets Claude Code and future AI agents talk to
  Orbit — e.g. surface agent status and notifications in the dashboard, and expose
  Orbit context or actions to agents. Local-only and explicitly opt-in.

**Window Management**
- Window layout and resizing (requires the Accessibility permission, so it
  depends on stable code signing).

## Build & run

```sh
scripts/run.sh            # debug build → .build/Orbit.app, signed, relaunched
scripts/run.sh release    # optimized build
scripts/test.sh           # run the Swift Testing suite
scripts/install-brave-helper.sh [--uninstall]   # Brave helper; see "YouTube in Brave"
```

Always launch through `scripts/run.sh`. `swift run` runs the bare binary
without Info.plist, so Orbit would show a Dock icon.
