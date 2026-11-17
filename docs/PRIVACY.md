# Privacy

Orbit is designed to keep your data on your Mac. This page lists, feature by feature, what it stores, what it sends over the network and which permissions it can ask for. It describes the current code; it isn't a guarantee or an audit.

## Where data is stored

Everything Orbit saves is in `~/Library/Application Support/Orbit/`: small JSON files for settings and widgets (tasks, goals, notes, workspaces, launcher history, suggestion feedback…), SQLite files for the AI Hub's history, and folders for the Screenshot Vault and File Shelf copies. Deleting the folder resets Orbit.

## Network use

| Feature | Contacts | When |
|---|---|---|
| Weather | Open-Meteo (`api.open-meteo.com`, `geocoding-api.open-meteo.com`) | While the widget shows, for the city you chose or your location if you allowed it |
| Tech News | Public RSS/Atom feeds (Wired, The Verge, Ars Technica, TechCrunch, Hacker News and others) | While the widget shows |
| LinkedIn | `api.linkedin.com` | Only after you connect your own developer app's token |
| Local AI (chat, Daily Digest) | `127.0.0.1` / `localhost` only | Only if you turn it on; other hosts are refused |
| Meeting links | The meeting's own site | Only when you click Join |
| Lyrics | LRCLIB (`lrclib.net`): the track's title, artist and length | Only if you turn Lyrics on (off by default), once per new track |

Orbit has no analytics, telemetry or account, and runs no network listener: the agent bridge is a Unix socket in Orbit's folder.

## Feature by feature

- **Clipboard history:** off until you turn it on; text only, kept in memory, never written to disk. Only the on/off choice and the size are saved (in `preferences.json`).
- **Lyrics:** off by default; lyrics are kept in memory for the session and never written to disk.
- **Bluetooth device notices:** use IOBluetooth's connect and disconnect notifications for paired devices, only once Bluetooth access is granted; nothing is stored.
- **Notch notes for power, timers and colours:** power changes come from macOS's power-source notification; the colour picker is macOS's own loupe, so Orbit doesn't need Screen Recording and sees only the one colour you click; nothing is stored.
- **AirDrop:** the File Shelf hands files to macOS's own AirDrop sheet; you choose the recipient there.
- **Apple Shortcuts:** the launcher reads shortcut names from `shortcuts list` and runs one only when you press Return on it.
- **Screenshots:** the Screenshot Vault stores its own copies of screenshots you give it; originals are never moved, modified or deleted, and deleting an item moves it to Recently Deleted until purged. Orbit never records or captures the screen and doesn't request Screen Recording.
- **Clipboard:** passwords that apps mark as private are skipped.
- **AI Hub:** off by default. Agent events are validated, and tokens, keys and passwords in them are redacted before anything is shown or stored. For Claude Code, Orbit only observes: it never answers prompts, and changes to `~/.claude/settings.json` are shown first and written only with your approval.
- **Launcher:** file results come from Spotlight's index (names only); Orbit doesn't open files to search them. Spotlight leaves out protected folders (Desktop, Documents, Downloads) unless you've given Orbit access. History is kept in `launcher.json`.
- **Context Engine:** reads Orbit's own models; stores only your clicks on suggestions (`suggestions.json`); no keystrokes, screen contents or browser history. The inspector's event log is in memory only and can be turned off.
- **Battery energy:** reads macOS's per-process energy counters for your own processes, only while the Battery widget is on screen.
- **Credentials:** none are stored on disk. The LinkedIn token lives in memory for the session.

## Permissions

Orbit asks only when you use the feature that needs it:

| Permission | Used for |
|---|---|
| Calendar | The Calendar widget, meeting reminders (asked when you click Connect) |
| Location | Wi-Fi network names, and weather for where you are (each asked when you choose it) |
| Bluetooth | The System › Bluetooth pane and device notices (asked when you click Show Devices) |

Orbit doesn't request Accessibility, Input Monitoring or Screen Recording. Global shortcuts use Carbon hotkeys, which need no permission.

## Limits

- Builds are signed ad hoc, so macOS may ask for permissions again after a rebuild.
- Optional integrations (Brave, Ollama, LM Studio, LinkedIn) are separate software with their own privacy terms.
