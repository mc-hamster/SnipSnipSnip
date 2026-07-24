# Contributing to SnipSnipSnip

Thanks for helping improve SnipSnipSnip. Bug reports, focused feature proposals, documentation fixes, tests, and code contributions are welcome.

## Before You Start

- Search [existing issues](https://github.com/mc-hamster/SnipSnipSnip/issues) before opening a new one.
- Use the repository's issue forms so reports include the details needed to act on them.
- Discuss substantial features or architectural changes in an issue before investing in an implementation.
- Never post private screenshots, recordings, clipboard contents, UI Map data, or unreviewed diagnostics in a public issue.

## Development Setup

SnipSnipSnip requires macOS 26 or later and a current Xcode installation. Clone the repository, open `SnipSnipSnip.xcodeproj`, and select the `SnipSnipSnip` scheme.

Run the test suite with:

```sh
xcodebuild test -project SnipSnipSnip.xcodeproj -scheme SnipSnipSnip -destination 'platform=macOS,arch=arm64,name=My Mac' -derivedDataPath /private/tmp/SnipSnipSnip-DerivedData
```

SnipSnipSnip permits only one app process at a time, including one app-hosted XCTest process. The shared scheme therefore runs tests in a single host. Quit any running copy before launching from Xcode or running app-hosted tests. If the current copy must remain open, use `xcodebuild build` or `xcodebuild build-for-testing` for compile-only verification, then run the tests after that copy exits. Do not use `open -n` or invoke the app executable directly to bypass the guard.

## Project Expectations

- Keep the app runnable after every change.
- Keep the base screenshot separate from non-destructive annotation state.
- Route undoable editor changes through command types.
- Keep capture, preview, editing, rendering, export, and support responsibilities separated.
- Add or update tests when changing geometry, commands, rendering, parsing, permissions, privacy, or automation behavior.
- Update the in-app Help guide whenever user-visible behavior, workflows, or labels change.
- Update the automation documentation, samples, and contract tests together when automation behavior changes.

See [AGENTS.md](AGENTS.md) for the complete workspace guidance.

## Pull Requests

Keep pull requests focused and explain:

- What changed and why.
- Which user workflow is affected.
- How the change was tested.
- Any privacy, permission, compatibility, export, or automation implications.
- Whether in-app Help or public documentation changed.

Avoid mixing cleanup with behavior changes unless the cleanup is required for the feature or fix.

## Reporting Security Problems

Do not open a public issue for a suspected security or privacy vulnerability. Follow [SECURITY.md](SECURITY.md) instead.
