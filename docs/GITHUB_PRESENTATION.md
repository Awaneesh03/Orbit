# GitHub presentation: recommendations

Nothing here has been applied on GitHub. Each item needs the repository owner's decision.

## Repository description

> A native macOS control center in the notch: AI agent monitoring, meetings, battery and displays, a universal launcher and workspaces. Swift 6, SwiftUI, AppKit; local-first.

## Topics

`macos`, `swift`, `swiftui`, `appkit`, `notch`, `menu-bar`, `productivity`, `launcher`, `ai-agents`, `claude-code`, `local-first`, `core-animation`

## Social preview

[`docs/assets/social-preview.png`](assets/social-preview.png) (1280×640) is composed from real Orbit renders. Upload it in Settings › General › Social preview.

## README

The README uses only real renders made by the test suite with fixture data. Keep it that way: new screenshots should come from `ORBIT_RENDER=1 scripts/test.sh`, not from the live app, so they never show personal data.

## Templates

Drafts are in `.github/` (bug report, feature request, pull request). They take effect once committed and pushed.

## Badges

None are recommended yet: there's no CI workflow, release or license to report. Add badges only for things that exist.

## License

The repository has no license, so others can't legally reuse the code. Choosing one (for example MIT or Apache-2.0 for permissive use, GPL-3.0 for copyleft) is the owner's decision.

## Documentation website

[`docs/index.html`](index.html) is a static, dependency-free page. GitHub Pages can serve it for free from the `main` branch's `/docs` folder (Settings › Pages). It has no analytics. It isn't published.
