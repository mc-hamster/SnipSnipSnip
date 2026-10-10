# Automation Sample Scripts

These samples demonstrate the script-file v1 automation surfaces exposed by
SnipSnipSnip: CLI, AppleScript, and URL scheme. App Intents are documented as
native Shortcuts actions in `Docs/Automation/README.md` rather than as GitHub
sample scripts.

The scripts are GitHub-only examples. They are not copied into the app bundle
and are not part of shipped build products.

Guide procedures 17–22 require SnipSnipSnip Pro. The App Store edition keeps
the same parsers and identifiers, but returns `proFeatureRequired` before
permission or capture work so old scripts fail predictably instead of becoming
invalid.

Maintenance rule: maintain these samples whenever any shared automation command,
option, URL route, AppleScript term, App Intent action, App Entity, App Shortcut
phrase, result field, error code, or output behavior changes. Update the
affected sample scripts and `Docs/Automation/README.md` in the same change.
Do not add App Intent sample scripts unless a new shared command, option, route,
term, result field, or output behavior requires script parity. Keep shell
samples valid with `bash -n`.

Script parity rule: the same basename identifies the same procedure across
languages. For example, `06-capture-fullscreen-to-clipboard.sh` and
`06-capture-fullscreen-to-clipboard.applescript` must exercise the same
automation workflow through different interfaces. CLI and AppleScript samples
must keep full procedure parity. URL samples must use the same basename for each
procedure supported by v1 URL routes; URL intentionally omits list,
open-document, private-capture, and general file-output procedures. The
dedicated v1 current-export route is represented because it has explicit
destination validation. App Intents expose native Shortcuts actions and are not
part of this filename parity matrix.

Procedures 11 and 12 can select eligible app dialogs, floating panels, and utility windows, including untitled panels. Procedure 13 can repeat a selected panel, and saved-window presets can retain it. Menus, desktop surfaces, and system overlays remain excluded. Frontmost-window procedures 08 and 27 continue selecting ordinary windows. The existing command and result contracts are unchanged.

Current procedure matrix:

| Basename | CLI | AppleScript | URL |
| --- | --- | --- | --- |
| `01-status` | yes | yes | yes |
| `02-list-presets` | yes | yes | no |
| `03-run-preset-by-id-to-editor` | yes | yes | yes |
| `04-run-preset-by-name-to-clipboard` | yes | yes | yes |
| `05-run-preset-by-id-to-file` | yes | yes | no |
| `06-capture-fullscreen-to-clipboard` | yes | yes | yes |
| `07-capture-fullscreen-to-file` | yes | yes | no |
| `08-capture-frontmost-window-to-editor` | yes | yes | yes |
| `09-capture-fixed-region-to-editor` | yes | yes | yes |
| `10-capture-fixed-region-to-file` | yes | yes | no |
| `11-capture-interactive-region-to-editor` | yes | yes | yes |
| `12-capture-interactive-window-to-clipboard` | yes | yes | yes |
| `13-repeat-last-to-editor` | yes | yes | yes |
| `14-export-current-to-file` | yes | yes | no |
| `15-private-fullscreen-to-file` | yes | yes | no |
| `16-open-document-to-file` | yes | yes | no |
| `17-start-guide-window` (Pro) | yes | yes | yes |
| `18-pause-guide` (Pro) | yes | yes | yes |
| `19-resume-guide` (Pro) | yes | yes | yes |
| `20-add-guide-step` (Pro) | yes | yes | yes |
| `21-stop-guide` (Pro) | yes | yes | yes |
| `22-export-guide-pdf` (Pro) | yes | yes | yes |
| `23-append-fullscreen-to-composition` | yes | yes | yes |
| `24-set-composition-layout-steps` | yes | yes | yes |
| `25-set-composition-compare-wipe` | yes | yes | yes |
| `26-export-current-html` | yes | yes | yes |
| `27-replace-frontmost-window-in-composition` | yes | yes | yes |
| `28-apply-composition-template` | yes | yes | yes |

Set these environment variables as needed:

```bash
export SSSCTL="/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl"
export OUTPUT_DIR="$HOME/Downloads"
export PRESET_ID="00000000-0000-0000-0000-000000000000"
export PRESET_NAME="Daily Clip"
export SSS_DOCUMENT="$HOME/Downloads/example.sss"
export AFTER_ITEM_ID="00000000-0000-0000-0000-000000000001"
export FIRST_ITEM_ID="00000000-0000-0000-0000-000000000001"
export SECOND_ITEM_ID="00000000-0000-0000-0000-000000000002"
export ITEM_ID="00000000-0000-0000-0000-000000000001"
export TEMPLATE_ID="builtin.numbered-steps"
```

## Repeatable validation

Run `python3 Tools/validate-automation-samples.py --help` from the repository root.
The live runner refuses to use ordinary user state: first start exactly one
Debug app normally with `--snipsnipsnip-composition-ui-testing
--snipsnipsnip-automation-audit`. That existing fixture isolates preferences and
storage, provides synthetic pixels and a disposable Daily Clip preset, and uses
the App Store capability set. Pass its bundled helper with `--cli`, a disposable
folder with `--output`, and `--surface cli`, `--surface applescript`, or `--surface url`.
AppleScript fixture copies change only input IDs and output locations.

The CLI/AppleScript runner verifies authoritative results and existence of returned files.
URL validation compares document snapshots, clipboard changes, and exported files;
status and rejected Guide routes verify dispatch and an unchanged document, with
their error contract checked through the other adapters. `--matrix` additionally
exercises layouts, comparison settings, templates, all eight formats, and failure
boundaries.
Guide samples exercise `proFeatureRequired`; frontmost-window requests use a
synthetic disposable window. Missing-window and denied-permission paths are
covered separately by hosted tests. Samples 11–12 require separate picker completion
and are explicitly reported as manual. Hosted tests also execute all 49 shell
samples through transport spies into the production CLI/URL parsers, including
paths and names containing spaces, ampersands, and Unicode.

AppleScript uses spaced dictionary commands, and variables in samples 23 and 25
avoid colliding with scripting parameter names. Sample 26 exports the current
Comparison or Steps using `app-default` appearance and does not require Polish.
Samples 11–12 retain the requested output and Private Capture choice through
selection; output occurs only after successful completion.
CLI callers must select one output destination; invalid or ambiguous options
fail rather than being silently ignored. Save unsaved work before unattended
sample 16; a cancelled or failed open does not export the previous document.

## Development and shipping namespaces

Xcode Debug builds use `com.oontz.SnipSnipSnip.Dev` (**SnipSnipSnip Dev**), while TestFlight, App Store, and GitHub builds retain `com.oontz.SnipSnipSnip`. Each permits one process, and Dev can run alongside a distributed copy. Dev has independent permissions, preferences, keychain encryption keys, and default app-owned storage (`~/Library/Application Support/SnipSnipSnip Dev`). Shipping paths and existing data stay unchanged. Do not select the same custom history folder in both apps.

The Debug bundle's CLI targets Dev; the shipping CLI targets the shipping app. Set `SSSCTL` to the Debug bundle's `Contents/Library/Helpers/snipsnipsnipctl` when running CLI samples against Dev. AppleScript addresses Dev with `tell application id "com.oontz.SnipSnipSnip.Dev"`. Dev registers `snipsnipsnip-dev://`; shipping retains `snipsnipsnip://`. URL samples accept `SSS_URL_SCHEME=snipsnipsnip-dev` with unchanged procedure basenames and parameters. The Share extension follows its containing app's namespace. Document formats remain compatible across builds.

The disposable automation sample validator targets Dev and substitutes that identity into AppleScript fixtures. The serial XCTest gate checks the selected configuration's namespace, so a shipping copy may remain open during Debug tests. Grant Dev access once and keep Apple Development signing and team stable for subsequent rebuilds; macOS may ask again if the code-signing identity changes. No permission resets or shipping-data migration occur. The system clipboard and global shortcut registrations remain shared macOS resources; assign different shortcuts if both copies are active.

The Debug product is **SnipSnipSnip Dev.app**, with executable **SnipSnipSnip Dev**, so Finder and macOS permission setup can distinguish it from the shipping **SnipSnipSnip.app**. The Swift module remains `SnipSnipSnip`. When adding Dev manually to a permission list, select the Dev product in Xcode’s DerivedData.
