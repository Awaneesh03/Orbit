# Features

**Status key:** *Implemented* works today. *Sample* shows mock data and is labelled in the app. *Optional* needs a permission or another app you choose to use. *Not available* can't be done with public macOS APIs.

## Dashboard and notch

| Feature | Status | Notes |
|---|---|---|
| Notch dashboard | Implemented | Hover (or click, if you choose) the notch, or press ⌃⌥⌘O. It grows out of the camera housing with a spring and folds back into it. The row beside the camera shows the time, battery and a running timer, and the section icons: Overview, Briefing, Productivity, Developer, Vault, System, AI Hub. |
| Notch on/off | Implemented | Settings › Notch › Use the notch. Off: no hover dashboard, island, HUDs, alerts or notes in the notch; the dashboard still opens with ⌃⌥⌘O. |
| Energy | Implemented | Nothing drawn while closed; the open and close motion runs in the window server. Follows Low Power Mode (a plain fade, decorative motion off) unless you turn that off. |
| Customisable Overview | Implemented | Choose, order and size widgets in Settings › Widgets. |
| Music Island | Implemented | A compact player below the notch when a track starts; expands for controls. Apple Music; YouTube in Brave with the optional extension. |
| Volume and brightness HUDs | Implemented | Shown below the notch when the level changes. Brightness is observed, never set. |
| Wings and floating pill | Implemented | Agent status and meeting reminders beside the camera on a notched display, or in a pill below the menu bar elsewhere. |
| Eye-break reminder | Implemented | The 20-20-20 rule; display sleep and a locked screen count as a break. Off by default. |
| Charging and battery notes | Implemented | Charger connected or removed, fully charged, low battery at 20 % and 10 %: a 3-second note below the notch. Event-driven. |
| Quick timer | Implemented | Type `timer 10m tea` in the launcher; the time left shows in the dashboard header, a note and a sound when it's done. |
| Colour picker | Implemented | "Pick a Colour" in the launcher: macOS's own loupe (no permission); the hex is copied and shown below the notch. |
| Bluetooth device notices | Optional | A 3-second note below the notch when a paired device connects or disconnects, with the battery when an Apple accessory reports one. Works once Bluetooth access is granted (from System › Bluetooth); never asks for it. |
| Lyrics | Optional | Off by default. In the expanded Now Playing widget, from LRCLIB (free, no account). Synced for YouTube in Brave; Apple Music doesn't report its position, so its lyrics show as text. |
| Coucou coexistence | Implemented | While Coucou runs, Orbit's notch surfaces step aside; the dashboard opens with ⌃⌥⌘O. |

## Intelligent workspace

| Feature | Status | Notes |
|---|---|---|
| Universal Launcher | Implemented | ⌃⌥Space by default (configurable). Apps, files and folders (Spotlight's index, names only), projects, agent sessions, File Shelf, tasks, goals, today's events, Settings, Orbit actions, workspaces. |
| Launcher calculator | Implemented | Type a sum (`12*4+3`, `2^10`, `(5+3)/2`); Return copies the answer. A small arithmetic parser: nothing is evaluated as code. |
| Apple Shortcuts in the launcher | Implemented | Your shortcuts by name, from macOS's own `shortcuts` tool. Return runs the one you chose; ⌘Return opens it in Shortcuts. Can be turned off. |
| Workspace Profiles | Implemented | Projects, apps, task words, music and focus choices, an Overview layout, a suggestion schedule. Never switches, opens or closes anything by itself. |
| Context Engine and suggestions | Implemented | "Suggested for You" on the Overview, with reasons; dismiss, snooze, not relevant, per-category switches; local learning from clicks only. |
| Context Inspector | Implemented | Settings › Context Inspector: current context, ranked and held-back suggestions with reasons, recent events (memory only). |
| Quick Actions | Implemented | App shortcuts plus contextual suggestions. |
| Automations | Implemented | *When* (meeting soon, agent needs you, agent finishes) *→ do* (pause music, keep awake, start focus, open Calendar). No scripts. |

## AI Hub

| Feature | Status | Notes |
|---|---|---|
| Agent monitoring | Optional | Off by default. Sessions, timelines, files changed and diffs, insights, weekly recap. Agents report through local hooks or adapters. |
| Claude Code | Optional, observe-only | Hooks are written to `~/.claude/settings.json` only after you approve; Orbit never answers its prompts. |
| Other agents | Optional | OpenAI Codex, GitHub Copilot CLI, Gemini CLI, OpenCode and others through adapter manifests; detection by known install paths. |
| Agent alerts | Implemented | Priority, grouping, quiet hours, per-agent mute, optional sound, history. |
| Jump to agent | Implemented | Brings the agent's editor window or terminal forward, as precisely as public APIs allow. |
| Local chat | Optional | Talks only to Ollama or LM Studio on `localhost`. |
| Cloud chat | Not available yet | Needs secure credential storage, which waits on a stable signing identity. |
| AI Hub chat widget | Sample | The Overview widget shows sample conversations. |

## Productivity

| Feature | Status | Notes |
|---|---|---|
| Tasks and daily goals | Implemented | Priorities, due dates, goal history. |
| Focus timer | Implemented | Focus and break lengths in Settings › Productivity; sessions are dated for insights. |
| Calendar and meetings | Optional | Needs Calendar access (asked only when you click Connect). Meeting reminders; Join for Google Meet, Zoom, Teams, Webex and other https links, opened only on a click. |
| Month | Implemented | An interactive month grid: move between months, pick a day to see its events. Event dots and lists need Calendar access already given; the grid works without it. Off the Overview by default. |
| Clipboard history | Implemented | Off until you turn it on (the choice is remembered); keeps the last 20, 40, 100 or 200 texts, in memory only. |
| Quick Note | Implemented | Saves as you type. |
| File Shelf | Implemented | Shelve a reference or an explicit copy; search, project filter, Quick Look, quoted paths for agents, AirDrop (one item or all shown, through macOS's own sheet). Originals are never moved or modified. |
| Screenshot Vault | Implemented | A local inbox for screenshots dropped on the notch. |
| This Week | Implemented | Tasks, goals, focus and agent activity over seven days. |
| Daily Digest | Implemented, model optional | A plain summary from your data; a local model can rewrite it, rejected if it adds numbers not in the facts. |
| Briefing | Implemented | Weather (Open-Meteo), tech news from public feeds, tasks. |
| LinkedIn | Optional, limited | Needs your own LinkedIn developer app with API access LinkedIn must approve; token in memory only. |

## System

| Feature | Status | Notes |
|---|---|---|
| Battery and charge states | Implemented | On battery, charging, plugged in not charging, full, unavailable. |
| Apps Using Significant Energy | Implemented (estimate) | macOS's per-process energy counters grouped by app; CPU energy only; no per-website breakdown. |
| Charging animation | Implemented | Only while actually charging and visible; respects Reduce Motion. |
| Brightness | Implemented, read-only | Built-in display only. |
| External monitor brightness | Not available | Needs DDC/CI through private interfaces. |
| Setting brightness | Not available | Needs private frameworks. |
| Wi-Fi details and diagnostics | Implemented | Network names need Location access (asked when you choose to). |
| Bluetooth devices | Optional | Needs Bluetooth access (asked when you open the pane). |
| Sound, Power, Keep Awake | Implemented | Audio devices and volume, battery health, a timed keep-awake. |
| CPU, memory, storage, network widgets | Implemented | |
| Developer Hub | Implemented | Projects in `~/Developer` opened in VS Code, Terminal or Finder. The GitHub widget is a *Sample*. |

## Personal

| Feature | Status | Notes |
|---|---|---|
| Desktop pet | Implemented | Cat or dog (CC0 artwork) or the illustrated pet; walks, rests, sleeps; behaviour settings. Off by default. |
| Notch companion | Implemented | A small pet below the notch showing agent activity. |
| Appearance | Implemented | Dashboard opacity, spacing, Reduce Motion; respects Increase Contrast. |

## Compared with other open-source notch apps

Checked against [boring.notch](https://github.com/TheBoredTeam/boring.notch), [Atoll](https://github.com/Ebullioscopic/Atoll) and [DynamicNotch](https://github.com/jackson-storm/DynamicNotch):

| Their feature | In Orbit |
|---|---|
| Music controls, visualizer, lyrics | Yes |
| HUD replacement (volume, brightness) | Yes (observed levels; Orbit doesn't set brightness) |
| File shelf with AirDrop, calendar, weather | Yes |
| Battery and charging live activity | Yes (charging and battery notes) |
| Bluetooth live activity | Yes |
| Timer | Yes (quick timer from the launcher) |
| Colour picker, clipboard history | Yes |
| System stats (CPU, memory, network, disk) | Yes (System widgets) |
| Floating capsule on displays without a notch | Yes (the status pill) |
| Spring "jelly" opening animation | Yes (the dashboard grows out of the notch) |
| Mirror (camera) | Not added: it needs the Camera permission |
| Screen-recording and privacy indicators, Focus live activity | Not added: they need Screen Recording or Focus status permissions |
| Downloads live activity | Not added: reading Downloads needs Files and Folders access |
| Lock-screen widgets | Not available: they need private window-server interfaces |
| CPU temperature and GPU stats | Not available without the SMC or private IOReport interfaces |
| Swipe gestures on the notch | Not yet |

## Compared with Sapphire

[Sapphire](https://github.com/cshariq/Sapphire) is another notch app. Orbit covers what public macOS APIs allow without new permissions:

| Sapphire feature | In Orbit |
|---|---|
| Now Playing, music controls, lyrics | Yes (lyrics optional, from LRCLIB) |
| Weather, calendar, interactive calendar grid | Yes |
| Bluetooth connect notices, Bluetooth fast connect | Yes (connect and disconnect from System › Bluetooth) |
| Caffeinate | Yes (Keep Awake) |
| File Shelf with AirDrop | Yes |
| Clipboard history, quick notes, eye-break reminders, shortcuts and automation | Yes |
| Volume HUD | Yes (the Sonic Pulse HUD; media controls are in the Music Island) |
| Quick camera mirror | Not added: it would need the Camera permission |
| Snap Zones (window management) | Not available: needs Accessibility, which Orbit never asks for |
| Circle to Search, screen-aware AI | Not available: needs Screen Recording |
| Face ID unlock, lock-screen widgets | Not available: no public API |
| System notification banners in the notch | Not available: other apps' notifications aren't readable with public APIs |
| Per-app volume and EQ | Not available without an audio-capture permission or a driver |
| XDR brightness boost, charge limit | Not available: needs private interfaces or a privileged helper |
| Android Nearby Share | Not added: a large protocol implementation, outside Orbit's scope for now |
| Live sports and finance | Not added: no free, keyless and terms-compatible data source |
