# Contributing

Thanks for your interest in Orbit. It's a personal project in active development, so please open an issue to discuss a change before starting larger work. Note that the code doesn't have a license yet.

## Set up

1. Install the Xcode Command Line Tools (`xcode-select --install`); you need Swift 6.2 or later and macOS 26 or later.
2. `git clone https://github.com/Awaneesh03/Orbit.git && cd Orbit`
3. `scripts/run.sh` to build and launch; `scripts/test.sh` to run the tests.

See [Installation](INSTALLATION.md) and [Architecture](ARCHITECTURE.md), which includes how to add a widget, a Context Engine source or an AI Hub adapter.

## Ground rules

These keep Orbit what it is:

- **Free and local.** No paid services, APIs or assets; no analytics; network use only where a feature needs it.
- **Public APIs only.** No private frameworks or undocumented SPI.
- **No new permissions** without discussion, and never Accessibility, Input Monitoring or Screen Recording as a workaround.
- **Command Line Tools only.** No `xcodebuild`, asset catalogs or Interface Builder; no SwiftUI macros (`@State`, `#Preview`).
- **AI Hub decisions:** Claude Code stays observe-only (D1); no network listener or remote control (D2); no stored credentials (D3). See [the AI Hub specification](AI_HUB_SPEC.md#13-approved-decisions-2026-11-13).
- **Honest UI.** Don't show a value Orbit can't read; label estimates and sample data.

## Code

- Swift 6 language mode; `@MainActor` models with `@Observable`; AppKit for windows, SwiftUI for content, Core Animation for continuous effects.
- New widgets are off by default so existing users' Overviews don't change.
- Persist through `JSONFile`/`Persisted` with tolerant decoding: a missing or invalid field takes its default.
- Keep comments about *why*; match the style around your change.

## Tests

- Every change comes with tests (Swift Testing). Run the whole suite with `scripts/test.sh` before opening a pull request.
- Tests never touch real user data, the real calendar or real permissions; use the existing fakes and temporary directories.
- For visual changes, render the view in a test (`ORBIT_RENDER=1` writes to `docs/screenshots/`) and check the image.

## Pull requests

Keep each pull request focused on one change, describe what you verified (tests, a live check, screenshots), and note anything you couldn't verify.
