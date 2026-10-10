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

`check-repository-hygiene.py` rejects tracked installed dependencies, build and
packaging output, files matching repository ignore rules, compiled executables,
and identical sibling copies with copy-style names. It checks Git-controlled
files rather than scanning local output folders, and it does not apply personal
or global ignore settings as repository policy. Original artwork, reviewed
submission media, source scripts, and required resource variants remain allowed.

```sh
python3 Tools/check-repository-hygiene.py
python3 Tools/check-repository-hygiene.py --staged
python3 -m unittest discover -s Tools/tests -p 'test_repository_hygiene.py'
```

The default check uses current tracked working-tree files, allowing pending
cleanup deletions. `--staged` checks index contents so a local deletion cannot
hide an artifact that would still be committed. The standalone Repository Hygiene
workflow runs on every branch push and pull request. The macOS CI suite and the
release gate also run the guard before building; force-adding an ignored file
does not bypass it.

`check-identity-safety.py` rejects duplicate-key trapping dictionary
constructors in the app, CLI, and Share Extension Swift sources. It checks
tokens conservatively, including generic and inferred initializers. Derived
lookups must specify a duplicate-key policy; conflicting document identities
must be rejected at the shared validation boundary without discarding content.
Tests may deliberately construct invalid fixtures and are outside this scan.
The release gate runs this check before building, and CI tests the checker.

```sh
python3 Tools/check-identity-safety.py
python3 -m unittest discover -s Tools/tests -p 'test_identity_safety.py'
```

`run-release-test-gate.sh` builds every app-hosted XCTest product and runs the
unit and UI targets serially in one host at a time. It uses an installed Apple
Development identity when one is available. On certificate-free CI runners it
falls back to ad-hoc signing and prepares only the generated developer-only
UI-test wrapper for launch. It refuses to start while a user-owned copy in the selected configuration’s
namespace is running. Debug tests can run alongside a shipping copy.

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

## Automation sample matrix

`validate-automation-samples.py` executes the existing CLI, AppleScript, or URL sample
procedures against the disposable Debug automation fixture. It refuses to run
unless exactly one Dev app process has both test launch arguments below. It never
launches or quits the app itself. Follow the single-instance rules first.

Launch a Debug build normally with `open -a "/path/to/SnipSnipSnip Dev.app" --args
--snipsnipsnip-composition-ui-testing --snipsnipsnip-automation-audit`, then run:

```sh
python3 Tools/validate-automation-samples.py \
  --cli "/path/to/SnipSnipSnip Dev.app/Contents/Library/Helpers/snipsnipsnipctl" \
  --output '/tmp/SnipSnipSnip Automation/CLI' --surface cli --matrix

python3 Tools/validate-automation-samples.py \
  --cli "/path/to/SnipSnipSnip Dev.app/Contents/Library/Helpers/snipsnipsnipctl" \
  --output '/tmp/SnipSnipSnip Automation/AppleScript' --surface applescript
```

Use `--surface url` for URL samples; their results are verified through observable
document, clipboard, and file effects because URL routes return no JSON.

The optional matrix covers all layouts, comparison modes, built-in templates,
eight export formats, output files, quoting, Unicode, privacy, overwrite,
missing targets, invalid numeric values, and Pro capability errors. JSON reports
record each outcome. Samples 11–12 remain separate interactive picker checks;
the runner reports them explicitly rather than counting acceptance as completed
capture. `AutomationSampleScriptTests` also runs all 49 shell samples through
transport spies into the production CLI/URL parsers without capturing a desktop.


## Permission release validation

`FeatureVisibilityTests` covers saved Pro preference visibility, capability-aware Help, Create method descriptions, and extracted Guide App Intent discoverability. Inspect both App Store and Self Release `Metadata.appintents/extract.actionsdata`: Guide stays registered, with `isDiscoverable` false in App Store builds and true in Pro. The App Store build must also omit the Guide shortcut tile.

Apple guidance is the basis for permission behavior:

| Apple reference | SSS behavior |
| --- | --- |
| [Privacy HIG](https://developer.apple.com/design/human-interface-guidelines/privacy/) | Request access for a selected feature or explicit setup action; use clear purpose strings and let macOS present consent. Recovery is separate from the system alert. Optional Microphone, Camera, and Accessibility remain tied to their features. |
| [ScreenCaptureKit sample](https://developer.apple.com/documentation/screencapturekit/capturing-screen-content-in-macos) | First Screen Recording grant requires relaunch, as the sample documents. Managing an existing grant does not start that first-grant flow. A failed content query alone does not prove denial. |
| [Pasteboard access behavior](https://developer.apple.com/documentation/appkit/nspasteboard/accessbehavior-swift.enum) | Follow the reported policy; default and ask do not authorize unattended reads. Read Clipboard Once is explicit. A one-time approval does not authorize later monitoring. |
| [Security-scoped access](https://developer.apple.com/documentation/foundation/nsurl/startaccessingsecurityscopedresource()) and [release](https://developer.apple.com/documentation/foundation/nsurl/stopaccessingsecurityscopedresource()) | Acquire custom-folder access before I/O, retain it while the store uses the folder, and release every successfully acquired scope. A plain path cannot replace a failed capability. |
| [Bookmark resolution](https://developer.apple.com/documentation/foundation/url/init(resolvingbookmarkdata:options:relativeto:bookmarkdataisstale:)-3ic6f) | Renew stale bookmarks using the resolved URL. Failed restoration preserves the saved choice and offers folder selection again. |

The readiness cache, Check Again action, and visible default-storage fallback are
SSS recovery policies. Apple does not prescribe those custom states. Keep passive
checks at workflow entry and protected service boundaries, where selection or
other asynchronous work may allow access to change. Reuse the refreshed result
inside a synchronous permission request instead of stacking extra checks. Keep
ScreenCaptureKit content queries tied to Check Again or actual capture work;
do not use them as background permission polling.

Permission status refresh, app foregrounding, and unattended automation must use
non-prompting status APIs. Only explicit setup, Check Again, or a requested capture
operation may call a consent-capable API. Never reset a developer's normal TCC
state to run this checklist; use a clean macOS test account for first-grant cases.

The regression coverage is in `PermissionWorkflowModelTests`,
`PermissionRecoveryTests`, `CapturePermissionStatusTests`, `AppModelTests`,
`AutomationContractTests`, `ClipboardAppModelTests`, and `TransactionalIntakeTests`.
Run app-hosted tests serially with the shared scheme and only after the existing
app copy in that namespace exits. Keep the lifetime lock and `LSMultipleInstancesProhibited` intact.
If source-reading tests block on Documents-folder access, build and test an exact
source snapshot under `/private/tmp`, including current uncommitted files, instead
of granting the test host broader folder access.

Before submitting 1.2, check these native OS flows in the shipping build:

| Flow | Expected result |
| --- | --- |
| First-run Screen Recording: deny, cancel setup, retry | No false Restart Required; settings opens only on request; optional permissions are not requested. |
| Screen Recording: grant and relaunch | Onboarding resumes; a fresh non-private pending action can offer Continue; no capture begins automatically. |
| Allowed Screen Recording: Manage | System Settings opens; capture remains ready and no restart is demanded. |
| Accessibility missing with Screen Recording allowed (Pro) | Recovery stays visible; Continue resumes explicitly; Capture Without UI Map preserves the saved preference. |
| Microphone denial | Open Microphone Settings, Try Again, and Record Without Microphone are available; retry stays in Video and saved preferences remain unchanged. |
| Camera denial with a connected device (Pro) | Camera recovery opens the appropriate settings pane; retry keeps screenshot versus recording intent. |
| Clipboard access denied or set to ask, where macOS enforces it | Monitoring reports Blocked or Needs Access and stops background reads; saved items remain available. |
| Revocation while the app is running | A newly negative system status clears cached readiness, including during a pending verification; no background permission prompt or capture is triggered. |
| Cancel or fail while loading Video windows | Preparation releases its busy state immediately; a late discovery result cannot reopen or overwrite a newer picker. |
| Copy a saved item or Capture Text with clipboard access set to ask | Copy succeeds without requesting access to the old clipboard; a write failure reports failure. |
| Concealed or ignored-source clipboard content | Monitoring discards it before reading its payload. |
| Clipboard denial during a read or pending processing | Further background reads stop immediately and pending content is discarded; explicit Paste remains available. |
| Resume Capture Frontmost Window after setup | Choose Window reconfirms the target so System Settings is not captured as the new frontmost app. |
| Unattended Guide (Pro) | Missing access returns permissionDenied without UI; Region returns invalidRequest because target selection requires interaction. |
| Cancel or restart with private/document-specific work | Existing work and normal recovery safeguards are preserved; no private acquisition or stale editor destination is persisted for replay. |

App Store builds must omit Camera and Accessibility setup, keep microphone optional,
and keep the camera usage key absent. OS consent dialogs, managed restrictions,
and physical iPhone/iPad trust must be checked on real supported systems; mocked
permission states and hosted UI renders do not certify those platform behaviors.


The permission audit regression cases also cover `ArchiveFolderAccessTests`:
failed bookmark persistence is atomic, stale bookmarks renew, custom scopes are
acquired before recovery reads and held by the store, and unavailable custom
folders produce an explicit safe-storage fallback without removing old history.
Check clipboard behavior with and without the documented privacy preview on
legacy systems and on macOS releases where that preview switch has been removed.
Read Clipboard Once must retain an approved item while `.ask` still blocks later
background reads. Check Again with a transient ScreenCaptureKit error must keep
usable access and show a retry message, not Restart Required. Recovering a Video
after an actual permission denial must retain permission setup and the saved Video.

The disposable Debug automation fixture uses SnipSnipSnip Dev (`com.oontz.SnipSnipSnip.Dev` and `snipsnipsnip-dev://`). The validator checks only that identity and selects Dev for URL and AppleScript samples.

Run `python3 -m unittest discover -s Tools/tests -p 'test_automation_namespace.py'` to verify that audit fixtures refuse a shipping CLI, a missing Dev app, or ambiguous Dev processes before dispatching commands.
