# SnipSnipSnip Automation

SnipSnipSnip exposes one automation contract through four external interfaces:
the `snipsnipsnipctl` command-line helper, AppleScript, the
`snipsnipsnip://` URL scheme, and App Intents for Apple Shortcuts and Spotlight.
Use the CLI or AppleScript when callers need JSON results. Use URL routes for
launchers, links, and other user-triggered actions that do not need a structured
response. Use App Intents when users want native Shortcuts actions.

## Interface Choice

- CLI: best for shell scripts, CI-style local workflows, launch agents, and
  tools that want exit codes plus JSON.
- AppleScript: best for Shortcuts, Script Editor, Automator, and Mac apps that
  already use Apple Events.
- URL scheme: best for links, launcher buttons, and fire-and-forget triggers.
- App Intents: best for Apple Shortcuts, Spotlight, Siri-capable system
  surfaces, and user-authored automations that should appear as native actions.

The v1 CLI transport uses AppleScript and Apple Events. The app does not expose
XPC or a local HTTP server in v1.

## Permissions

Screenshot automation follows the same macOS permissions as the app UI:

- Screen Recording is required for screenshot capture.
- Accessibility may be needed for frontmost-window workflows and future advanced
  window targeting.
- Apple Events permission is required for `snipsnipsnipctl` because it talks to
  SnipSnipSnip through the AppleScript suite.
- App Intents and Shortcuts use the same app permissions. Interactive actions
  and outputs that present UI continue in SnipSnipSnip before running.

Use `snipsnipsnipctl --json status` or `automation status` in AppleScript to
preflight capabilities and permissions before running unattended scripts.

## Privacy And Redaction Safety

`--private` requests Private Capture behavior where supported. It prevents the
capture from being retained in app history-style surfaces.

Rendered outputs flatten annotations and redactions:

- Clipboard image
- PNG
- JPEG
- PDF

Editable `.sss` documents keep the original screenshot pixels plus annotation
state. An unattended request that tries to save an editable `.sss` document when
redactions require confirmation fails with `confirmationRequired`. Use rendered
output for irreversible sharing.

## CLI Setup

Release builds copy the helper into the app bundle:

```bash
/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl --json status
```

For local development builds, point `SSSCTL` at the built helper:

```bash
export SSSCTL="/path/to/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl"
```

You may also create a shell alias:

```bash
alias snipsnipsnipctl="/Applications/SnipSnipSnip.app/Contents/Library/Helpers/snipsnipsnipctl"
```

### CLI Commands

```bash
snipsnipsnipctl --json status
snipsnipsnipctl presets list
snipsnipsnipctl presets run --id UUID --copy
snipsnipsnipctl presets run --name "Daily Clip" --output ~/Desktop/capture.png --format png --overwrite
snipsnipsnipctl capture fullscreen --output ~/Desktop/fullscreen.png --format png --overwrite
snipsnipsnipctl capture frontmost-window --open-editor
snipsnipsnipctl capture region --rect 100,100,640,480 --output ~/Desktop/region.png --format png --overwrite
snipsnipsnipctl capture region --interactive --open-editor
snipsnipsnipctl capture window --interactive --copy
snipsnipsnipctl repeat-last --json --open-editor
snipsnipsnipctl export current --output ~/Desktop/current.png --format png --overwrite
snipsnipsnipctl open --file ~/Desktop/example.sss --output ~/Desktop/example.png --format png --overwrite
snipsnipsnipctl guide start --target window
snipsnipsnipctl guide pause
snipsnipsnipctl guide resume
snipsnipsnipctl guide add-step
snipsnipsnipctl guide stop
snipsnipsnipctl guide export --format pdf
```

### Guide Commands

Guide uses the same contract on every automation surface:

- `guide start --target window|app|region|display`
- `guide pause`, `guide resume`, `guide add-step`, and `guide stop`
- `guide export --format pdf|gif|apng|mp4-full|mp4-highlights|mp4-slideshow|images|zip`
- URL routes mirror these at `snipsnipsnip://v1/guide/start`, `/pause`, `/resume`, `/add-step`, `/stop`, and `/export`.
- AppleScript uses `guide given action:"…"`, with optional `target`, `format`, and `privateCapture` parameters.
- App Intents exposes the same actions through Control SnipSnipSnip Guide.

Guide start requires Screen Recording and Accessibility. Region start is interactive and the selected Guide region is constrained to the display where the drag begins; cross-display Guide regions are rejected, while ordinary screenshot-region capture is unchanged. Window and app Guide targets follow source geometry changes automatically. URL exports are trigger-oriented and use the default Downloads destination. Explicit errors include `noActiveGuide`, `guideAlreadyActive`, `guideHasNoSteps`, `guideSourceMediaUnavailable`, and `guideFinalizationFailed`.

Private Guide skips archive/search/indexing and background OCR or AI refinement. Automation never receives screenshot, OCR, caption, window-title, or path content in diagnostics.

Supported flags:

- `--json`: request machine-readable JSON output.
- `--interactive`: allow region or window selection UI.
- `--copy`: copy rendered output to the clipboard.
- `--open-editor`: open the result in the editor.
- `--float`: create a floating reference.
- `--output PATH`: save to a file path.
- `--format png|jpeg|pdf|sss`: choose rendered or editable output format.
- `--overwrite`: replace an existing output file.
- `--private`: request Private Capture behavior.

### CLI Exit Codes

- `0`: succeeded or accepted.
- `64`: invalid request or command syntax.
- `69`: unavailable feature, target, or Pro requirement.
- `70`: internal or unknown automation failure.
- `74`: output failed.
- `77`: permission denied or confirmation required.
- `130`: user cancelled.

## AppleScript Examples

```applescript
tell application id "com.oontz.SnipSnipSnip"
    automationStatus
    listCapturePresets
    runCapturePreset given name:"Daily Clip", output:"clipboard"
    captureFullscreen given outputPath:"/Users/me/Desktop/fullscreen.png", format:"png", overwrite:true
    captureFrontmostWindow given output:"editor"
    captureRegion given rect:"100,100,640,480", outputPath:"/Users/me/Desktop/region.png", format:"png", overwrite:true
    captureRegion given interactive:true, output:"editor"
    captureWindow given interactive:true, output:"clipboard"
    repeatLastCapture given output:"editor"
    exportCurrentScreenshot given outputPath:"/Users/me/Desktop/current.png", format:"png", overwrite:true
end tell
```

Commands return JSON text.

## URL Routes

URL routes are versioned and trigger-oriented. They do not return structured
data to the caller. URL outputs are limited to `editor`, `clipboard`, `float`,
and `none`.

```text
snipsnipsnip://v1/status
snipsnipsnip://v1/presets/run?id=UUID&output=clipboard
snipsnipsnip://v1/presets/run?name=Daily%20Clip&output=editor
snipsnipsnip://v1/capture/fullscreen?output=clipboard
snipsnipsnip://v1/capture/frontmost-window?output=editor
snipsnipsnip://v1/capture/region?rect=100,100,640,480&output=editor
snipsnipsnip://v1/capture/region?interactive=true&output=editor
snipsnipsnip://v1/capture/window?output=clipboard
snipsnipsnip://v1/repeat-last?output=editor
```

The existing `snipsnipsnip://import-pasteboard` route remains reserved for
share-extension pasteboard imports.

## App Intents / Shortcuts

SnipSnipSnip registers App Intents as a native macOS automation adapter over the
same `AutomationService` contract used by CLI, AppleScript, and URL routes.
Status and preset-listing intents summarize results as Shortcuts dialogs instead
of returning the full JSON envelope. Capture and export actions complete
silently unless Shortcuts itself is configured to show result UI or the action
needs foreground interaction.

Available actions:

- Get SnipSnipSnip Automation Status
- List SnipSnipSnip Capture Presets
- Run SnipSnipSnip Capture Preset
- Capture SnipSnipSnip Fullscreen
- Capture SnipSnipSnip Frontmost Window
- Capture SnipSnipSnip Region
- Capture SnipSnipSnip Window
- Repeat Last SnipSnipSnip Capture
- Open SnipSnipSnip Document
- Export Current SnipSnipSnip Screenshot

Shortcut suggestions include high-value capture actions for fullscreen, region,
window, frontmost window, repeat last capture, and running a capture preset.

Foreground/background behavior:

- Passive actions such as status and preset listing run in the background.
- Capture and export actions can run in the background when all required inputs
  and permissions are already available.
- Interactive region/window capture, repeat-last workflows, `openEditor`, and
  `floatReference` outputs continue in SnipSnipSnip before completing.
- File output accepts an absolute POSIX path such as
  `/Users/me/Downloads/output.png` or a `file://` URL, then uses the same
  overwrite and format validation as other automation interfaces.
- Opening a `.sss` document uses an `IntentFile` constrained to the
  SnipSnipSnip document package type.

## Result JSON

The CLI and AppleScript interfaces return an `AutomationResultEnvelope`.

Status responses use the `preflight` payload so scripts can check capabilities
and permissions before starting a capture:

```json
{
  "requestID": "00000000-0000-0000-0000-000000000001",
  "status": "succeeded",
  "payload": {
    "preflight": {
      "_0": {
        "capabilities": {
          "supportsURLScheme": true,
          "supportsAppleScript": true,
          "supportsCLI": true,
          "supportsAppIntents": true,
          "supportsCapturePresets": true,
          "supportsPrivateCapture": true,
          "supportsUIMap": true,
          "supportsScrollingCapture": false,
          "supportsConnectedDeviceCapture": false,
          "supportsCurrentEditorExport": true
        },
        "permissions": {
          "hasScreenRecording": true,
          "hasAccessibility": false,
          "hasMicrophone": false
        }
      }
    }
  },
  "outputs": [
    {
      "kind": "none"
    }
  ],
  "warnings": [],
  "error": null
}
```

```json
{
  "requestID": "00000000-0000-0000-0000-000000000001",
  "status": "succeeded",
  "payload": {
    "capture": {
      "_0": {
        "kind": "fullscreen",
        "sourceName": null,
        "acceptedInteractiveWorkflow": false
      }
    }
  },
  "outputs": [
    {
      "kind": "savedFile",
      "url": "file:///Users/me/Desktop/fullscreen.png",
      "format": "png",
      "message": null
    }
  ],
  "warnings": [],
  "error": null
}
```

Consumers should key off `status`, `error.code`, `outputs`, and the payload case
instead of parsing human-readable messages.

## Maintenance Requirement

When any automation command, option, URL route, AppleScript term, App Intent
action, App Entity, App Shortcut phrase, result field, error code, or output
behavior changes, update these files in the same change:

- `Docs/AutomationServicePlan.md`
- `Docs/Automation/README.md`
- affected scripts in `Docs/Automation/SampleScripts`

The sample scripts are GitHub-only and are not shipped in the app build. They
must still be maintained and syntax-checked whenever exposed automation changes.
Sample basenames must remain procedure-stable across languages: matching CLI,
AppleScript, and URL filenames should perform the same workflow through their
respective interface. CLI and AppleScript samples keep full procedure parity;
URL samples use matching basenames for the subset supported by v1 URL routes.
