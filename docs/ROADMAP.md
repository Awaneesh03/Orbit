# Roadmap

What's built, what's next and what's being explored. The detailed engineering log, with every milestone's decisions and measurements, is in [ORBIT_ROADMAP.md](ORBIT_ROADMAP.md).

## Completed

- **Notch dashboard** with sections, a customisable widget Overview and the Briefing.
- **One notch slot** shared by the Music Island, volume and brightness HUDs, agent alerts and reminders, with Coucou coexistence.
- **Display awareness:** camera wings on notched displays, a floating pill elsewhere.
- **Meetings:** reminders with countdown and Join links from your calendar.
- **AI Hub:** observe-only agent monitoring with timelines, diffs, insights, alerts, jump to agent and local chat.
- **Context Engine:** explained, ranked suggestions with local learning and an inspector.
- **Universal Launcher** and **Workspace Profiles**.
- **Productivity:** tasks, goals, focus timer, clipboard, quick note, File Shelf, Screenshot Vault, This Week, Daily Digest.
- **System:** Wi-Fi, Bluetooth, sound, power, Keep Awake, battery energy estimates, charging animation, brightness.
- **Desktop pet** with free cat and dog characters and a notch companion.
- **Automations** from a fixed list of safe actions.
- **Notch redesign (Milestone 21):** the dashboard grows out of the notch, a header beside the camera with icon tabs, roomier cards, a notch on/off switch and click-to-open, Low Power Mode awareness, and charging, timer and colour-picker notes.
- **Sapphire parity (Milestone 20):** Bluetooth device notices, lyrics, an interactive month grid, AirDrop from the File Shelf, a launcher calculator and Apple Shortcuts, and a Productivity settings pane. See the comparison in [FEATURES.md](FEATURES.md#compared-with-sapphire).

## In progress

- Live verification on more display setups (external displays as the main display).
- LinkedIn: the integration is built and waits on API access from LinkedIn.

## Planned

- Meeting reminders in the compact pill on notched displays with the *Below the notch* style.
- Dragging a File Shelf item onto an agent session.
- More automation triggers (a focus run ending, a display connecting).
- A Markdown export of the weekly summary.
- Lyrics in the expanded Music Island as well as the Now Playing widget.
- Swipe gestures on the open notch (switch sections, dismiss).
- A stable signing identity, which would allow storing credentials in the Keychain and therefore cloud chat providers.

## Research and exploration

- Apple's on-device Foundation Models for the Daily Digest (no download, Apple Intelligence Macs).
- Optional macOS notifications for an agent that needs you (would need notification permission).
- Following Focus modes for quiet hours (would need Focus status permission).
- Developer ID signing and notarization for distribution.
