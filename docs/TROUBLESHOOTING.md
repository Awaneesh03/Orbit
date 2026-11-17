# Troubleshooting

## Building and testing

| Problem | Fix |
|---|---|
| `plugin for module 'TestingMacros' not found` | Run tests with `scripts/test.sh`, which loads the plugin explicitly, rather than `swift test`. |
| `ld: warning: search path '…/CommandLineTools/Developer/…' not found` | Harmless: SwiftPM looks for Xcode-only folders. |
| `@State`, `#Preview` or `@Entry` don't compile | These SwiftUI macros ship only with full Xcode. Keep view state in an `@Observable` model. |
| The first build fails while resolving packages | It needs the network to download the Rive runtime. Try again online; later builds use the cache. |
| `swift: command not found` or an old Swift | Install or update the Command Line Tools (`xcode-select --install`) and check `swift --version` (6.2 or later). |

## Running

| Problem | Fix |
|---|---|
| Orbit shows a Dock icon, or no permission prompts appear | It was started with `swift run` or from the editor. Use `scripts/run.sh`. |
| macOS asks for a permission again after a rebuild | Expected with ad-hoc signing: each build has a new signature. |
| Nothing appears at the notch | Hover the very top of the screen at the notch, or the top-centre strip on a display without a notch, or press ⌃⌥⌘O. Check Orbit is running: `pgrep -x Orbit`. |
| The wings don't show | They appear only on a notched main display with Settings › General › Compact style set to *Beside the camera*. Elsewhere the floating pill is used. |
| The launcher shortcut does nothing | Another app may own it: Settings › Launcher says so. Choose another shortcut. |
| Launcher file results miss Desktop, Documents or Downloads | Spotlight hides protected folders from apps without access to them. |
| Brightness shows "Not readable" for an external display | Expected: reading it needs private interfaces. |
| YouTube in Brave doesn't show | Load the extension and run `scripts/install-brave-helper.sh`; see [Installation](INSTALLATION.md#optional-youtube-in-brave). |
| Local chat or the Digest finds no model | Start Ollama or LM Studio with a model installed; Orbit never downloads one. |

## Logs

Orbit logs to the unified log under the subsystem `com.awaneeshgupta.orbit`:

```sh
log stream --predicate 'subsystem == "com.awaneeshgupta.orbit"'
```
