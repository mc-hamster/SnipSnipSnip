# Tools

Developer-only utilities that are not part of the SnipSnipSnip app target.

## Clean Sweep

`clean-sweep-snipsnipsnip.sh` resets local SnipSnipSnip state for permission
onboarding tests. It deletes app-owned preferences/support/cache/container
files and resets macOS privacy decisions with `tccutil`.

If SnipSnipSnip is running, the script requests a normal app quit and clicks the
in-app `Quit` confirmation with System Events when the dialog appears. This
keeps Xcode debug sessions out of signal handling while still allowing
hands-off cleanup. If macOS blocks the click, grant Accessibility to the
terminal app running the script or close SnipSnipSnip manually and rerun.

Dry-run first:

```sh
Tools/clean-sweep-snipsnipsnip.sh
```

The dry run ends with a safety summary and the exact `--apply` command to run.
It reports `SAFE app-scoped cleanup` unless the selected options include a
known broad system reset such as `--reset-background-items`.

Apply the cleanup:

```sh
Tools/clean-sweep-snipsnipsnip.sh --apply
```

Optional cleanup for a fuller local reset:

```sh
Tools/clean-sweep-snipsnipsnip.sh --apply --remove-apps --derived-data
```

`--reset-background-items` is intentionally opt-in because macOS only exposes a
broad `sfltool resetbtm` reset for background/login item state.

## Composition HTML browser matrix

`validate-composition-html-browser.py` opens a generated composition HTML file
in a disposable headless Google Chrome or Firefox profile. It verifies that the
real `file:` document loads its embedded images, makes no external resource
requests, keeps the deny-by-default Content Security Policy, and supports
Previous/Next and keyboard step navigation.

Run it directly against an exported Steps file:

```sh
Tools/validate-composition-html-browser.py \
  --browser chrome \
  --html /path/to/composition.html

Tools/validate-composition-html-browser.py \
  --browser firefox \
  --html /path/to/composition.html
```

The XCTest matrix is opt-in because launching separately installed browsers is
not appropriate for every local or CI run:

```sh
xcodebuild test \
  -scheme SnipSnipSnip \
  -only-testing:SnipSnipSnipTests/CompositionHTMLLocalFileBrowserTests \
  SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS=1
```

Each browser receives a new temporary profile that is deleted afterward. The
validator never opens a real browser profile and disables external networking.
Missing browsers are reported as explicit XCTest skips. Override discovery on
a test machine with `SSS_GOOGLE_CHROME_BINARY` or `SSS_FIREFOX_BINARY`.
Release CI also sets `SSS_REQUIRE_EXTERNAL_HTML_BROWSERS=1`, which turns a
missing browser into a failing gate instead of a skip.

## Release test gate

`run-release-test-gate.sh` builds every app-hosted XCTest product and runs the
unit and UI targets serially in one host at a time. It uses an installed Apple
Development identity when one is available. On certificate-free CI runners it
falls back to ad-hoc signing and prepares only the generated developer-only
UI-test wrapper for launch. It refuses to start while a user-owned
SnipSnipSnip copy is running.

Run the complete gate:

```sh
Tools/run-release-test-gate.sh \
  --derived-data /tmp/SnipSnipSnipReleaseTestGate
```

Release CI requires the external Chrome and Firefox HTML checks:

```sh
SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS=1 \
SSS_REQUIRE_EXTERNAL_HTML_BROWSERS=1 \
Tools/run-release-test-gate.sh \
  --derived-data /tmp/SnipSnipSnipReleaseTestGate \
  --result-bundle /tmp/SnipSnipSnipReleaseTests.xcresult
```

For a focused local diagnosis, repeat `--only-testing` with XCTest identifiers.
The generated runner is a developer-only build product; its certificate-free
CI signing change never affects the shipped application or release archives.
