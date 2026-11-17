# Installation

Orbit is built from source with Swift Package Manager and the Xcode Command Line Tools. Full Xcode isn't needed (and `xcodebuild` isn't used).

## Requirements

| | |
|---|---|
| macOS | 26 or later (the package's minimum, `platforms: [.macOS(.v26)]`) |
| Mac | Apple Silicon. Verified on a MacBook Air M4 with macOS 27.2. Intel is untested. |
| Tools | Xcode Command Line Tools with Swift 6.2 or later. Install with `xcode-select --install`; check with `swift --version`. |
| Network | Needed for the first build, to download the Rive runtime package. |

## Build and run

```sh
git clone https://github.com/Awaneesh03/Orbit.git
cd Orbit
scripts/run.sh
```

`scripts/run.sh` builds Orbit, assembles `.build/Orbit.app` (adding `Info.plist`, the pet resources and the embedded `RiveRuntime.framework`), signs it ad hoc, stops any copy of this build that's already running and launches it. Orbit has no Dock icon: hover the notch, or the top-centre of the screen on a display without a notch, or press ⌃⌥⌘O.

```sh
scripts/run.sh release    # optimised build, same steps
```

Quit Orbit from its right-click menu on the notch, or with `pkill -x Orbit`.

Don't use `swift run`: it starts the bare executable without `Info.plist`, so Orbit gets a Dock icon and macOS shows no permission prompts.

## Test

```sh
scripts/test.sh                       # the whole suite
scripts/test.sh --filter Launcher     # tests whose names match
ORBIT_RENDER=1 scripts/test.sh        # also write the rendered screenshots to docs/screenshots
```

`scripts/test.sh` wraps `swift test` and loads the Swift Testing macro plugin explicitly, which works around an intermittent "plugin for module 'TestingMacros' not found" error with Command Line Tools.

## Packaging

`scripts/run.sh release` leaves a signed `Orbit.app` in `.build/`. It's signed ad hoc, so:

- It runs on the Mac that built it. Copying it to another Mac would need a Developer ID signature and notarization, which aren't set up.
- macOS ties permissions (Calendar, Location, Bluetooth) to the signature, which changes with each build, so a rebuild can ask again.

## Optional: YouTube in Brave

The Now Playing widget and the Music Island can show YouTube playing in Brave through a small extension and a native-messaging helper.

1. In Brave, open `brave://extensions`, turn on Developer mode, choose **Load unpacked** and select the `BraveExtension` folder. Its ID is fixed by the key in its manifest, so there's nothing to copy.
2. Register the helper: `scripts/install-brave-helper.sh`. It builds `OrbitBraveHelper` (release), copies it to `~/Library/Application Support/Orbit/BraveHelper/` and writes the native-messaging manifest Brave reads, which admits only Orbit's extension. Remove both with `scripts/install-brave-helper.sh --uninstall`.

See "YouTube in Brave" in the [project specification](../PROJECT_SPEC.md) for details.

## Optional: AI Hub

The AI Hub is off by default. Turn it on in Settings › AI Hub. To observe Claude Code, Settings › AI Hub shows the exact hook changes for `~/.claude/settings.json` and writes them only when you approve. Local chat needs Ollama (port 11434) or LM Studio's local server (port 1234) running with a model you installed; Orbit never downloads models.
