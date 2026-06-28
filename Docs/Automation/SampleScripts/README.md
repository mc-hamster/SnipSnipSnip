# Automation Sample Scripts

These samples demonstrate the script-file v1 automation surfaces exposed by
SnipSnipSnip: CLI, AppleScript, and URL scheme. App Intents are documented as
native Shortcuts actions in `Docs/Automation/README.md` rather than as GitHub
sample scripts.

The scripts are GitHub-only examples. They are not copied into the app bundle
and are not part of shipped build products.

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
procedure supported by v1 URL routes; URL intentionally omits file-output,
list, open-document, export-current, and private-capture procedures because
those are not exposed by the v1 URL contract. App Intents expose native
Shortcuts actions and are not part of this filename parity matrix.

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

Set these environment variables as needed:

```bash
export SSSCTL="/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl"
export OUTPUT_DIR="$HOME/Desktop"
export PRESET_ID="00000000-0000-0000-0000-000000000000"
export PRESET_NAME="Daily Clip"
export SSS_DOCUMENT="$HOME/Desktop/example.sss"
```
