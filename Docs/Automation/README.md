# SnipSnipSnip Automation

## Automation reliability checks

The bundled CLI sends its original JSON argument array through the dedicated
`execute command line` Apple Event (`SSSaCLIR`, `argumentsJSON`/`SSja`) to the
shared `AutomationCLIParser`. This event uses the existing narrow scripting
access group and the same validation/execution service. It preserves the
command-line source and unattended interaction policy; the helper no longer
maintains a second parser or generates per-command AppleScript. Use the helper
from the same app version. Malformed transport responses fail with exit 70;
Apple Events denial uses exit 77. Busy/unavailable Guide states use exit 69 and Guide finalization failure uses exit 74. Status reports the actual microphone authorization without prompting. The helper waits up to five minutes for output.

AppleScript samples use the dictionary's spaced command names, such as
`automation status` and `export current screenshot`. Camel-case Swift method
names are not scripting terms. Sample variables must not shadow dictionary
parameter names. CLI argument values retain spaces, quotes, Unicode, and
backslashes. Unknown, duplicate, inapplicable, missing-value, and conflicting
output options fail with `invalidRequest` (exit 64). Export format identifiers
are case-insensitive. Rectangle input must contain exactly four finite numbers.
Duplicate or valueless URL query parameters and malformed preset UUIDs are
rejected before execution.

Overlapping mutating automation requests return `busy` (CLI exit 69), including
while an interactive capture is pending. Status and preset listing remain
available. This prevents one caller from exporting another caller's capture.

Opening a document waits for successful loading and any permitted unsaved-work
decision before producing output. Unattended opening returns
`confirmationRequired` when the current document is unsaved; cancellation returns
`userCancelled`. A failed or cancelled open never exports the previous document.
Interactive region/window capture retains its requested output, appearance, and
Private Capture choice until selection completes. Cancellation clears that
operation; a later capture cannot inherit its output. Interactive-only repeats
return `confirmationRequired` to unattended callers.
Capture failures return specific permission/target errors without opening a
recovery sheet, and unattended capture does not start permission remediation. Saved-window
presets and repeat commands check Screen Recording before resolving their targets.
Diagnostic summaries omit document paths, source titles, and preset names;
explicit JSON results still include the output URLs required by callers.

Sample 26 uses `app-default` appearance, so a valid Comparison or Steps document
can export HTML without first configuring Polish. Its URL sample percent-encodes
the output path and supports `OUTPUT_DIR`, including spaces and ampersands.


Screenshot capture and editor changes preserve the clipboard. Clipboard delivery requires an explicit copy output or a Capture Preset with Copy to Clipboard as its outcome. The retired global Auto Copy preference is ignored, including during automated captures. Existing copy commands, result fields, and sample-script procedures remain unchanged.

SnipSnipSnip exposes one automation contract through four external interfaces:
the `snipsnipsnipctl` command-line helper, AppleScript, the
`snipsnipsnip://` URL scheme, and App Intents for Apple Shortcuts and Spotlight.
Use the CLI or AppleScript when callers need JSON results. Use URL routes for
launchers, links, and other user-triggered actions that do not need a structured
response. Use App Intents when users want native Shortcuts actions.

## Interface Choice

Capture Text and Fit to Text are interactive tools, not new v1 automation commands. The editor's session-only Output Size choice does not change CLI, AppleScript, URL, App Intent, preset, or editable-document output. Automation continues using its existing explicit appearance and output contracts. No sample-script procedure or route changed.

- CLI: best for shell scripts, CI-style local workflows, launch agents, and
  tools that want exit codes plus JSON.
- AppleScript: best for Shortcuts, Script Editor, Automator, and Mac apps that
  already use Apple Events.
- URL scheme: best for links, launcher buttons, and fire-and-forget triggers.
- App Intents: best for Apple Shortcuts, Spotlight, Siri-capable system
  surfaces, and user-authored automations that should appear as native actions.

The v1 CLI transport uses AppleScript and Apple Events. The app does not expose
XPC or a local HTTP server in v1. The sandboxed helper has an embedded bundle
identity and is limited to SnipSnipSnip's dedicated automation scripting access
group; it does not receive general Apple Events access to other apps.

AppleScript commands, and therefore the CLI helper, wait for the authoritative
automation result. A successful file result means the export exists at the
returned URL; composition mutation failures and output errors are returned
directly. Interactive region/window selection and other workflows that require
continued user input are the only commands that may return
`acceptedInteractiveWorkflow` before pixels are produced.

Composition rendering rejects conflicting image item identities, including
excluded items, without terminating the app. Copy reports `outputFailed` through
the existing contract and leaves the clipboard and editable document unchanged.

Capture Preview is an interactive screenshot preference, not an automation output mode.
Automated captures retain their existing editor/output routing, including interactive
region and window requests. Clipboard output checks the actual pasteboard write;
a rejected write is an output failure, never a successful copy. No command names,
result fields, or sample-script procedures change.

## Permissions

Screenshot automation follows the same macOS permissions as the app UI:

- Screen Recording is required for screenshot capture.
- The App Store edition never requests Accessibility. SnipSnipSnip Pro requires
  it for Guide creation, scrolling capture, UI Map, and other
  Accessibility-assisted workflows.
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
- GIF
- APNG
- MP4
- self-contained interactive HTML

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
snipsnipsnipctl presets run --name "Daily Clip" --output ~/Downloads/capture.png --format png --overwrite
snipsnipsnipctl capture fullscreen --output ~/Downloads/fullscreen.png --format png --overwrite
snipsnipsnipctl capture frontmost-window --open-editor
snipsnipsnipctl capture region --rect 100,100,640,480 --output ~/Downloads/region.png --format png --overwrite
snipsnipsnipctl capture region --interactive --open-editor
snipsnipsnipctl capture window --interactive --copy
snipsnipsnipctl capture fullscreen --destination append --after-item-id UUID --appearance plain --open-editor
snipsnipsnipctl capture frontmost-window --destination replace --replace-item-id UUID --open-editor
snipsnipsnipctl composition layout --layout steps --axis vertical
snipsnipsnipctl composition compare --mode wipe --first-item-id UUID --second-item-id UUID --wipe-position 0.4
snipsnipsnipctl composition template --id builtin.numbered-steps
snipsnipsnipctl repeat-last --json --open-editor
snipsnipsnipctl export current --output ~/Downloads/current.png --format png --overwrite
snipsnipsnipctl export current --output ~/Downloads/comparison.html --format html --appearance styled --overwrite
snipsnipsnipctl open --file ~/Downloads/example.sss --output ~/Downloads/example.png --format png --overwrite
snipsnipsnipctl guide start --target window
snipsnipsnipctl guide pause
snipsnipsnipctl guide resume
snipsnipsnipctl guide add-step
snipsnipsnipctl guide stop
snipsnipsnipctl guide export --format pdf
```

### Multi-capture Composition

Capture, preset-run, and repeat-last commands accept a composition destination:

- `--destination new` keeps the existing behavior and opens a new document.
- `--destination append` adds the result to the current composition.
- `--destination append --after-item-id UUID` inserts immediately after one
  active composition item. When omitted, append keeps the existing behavior and
  inserts after the selected item, or at the normal append position when no
  composition item is selected.
- `--destination replace --replace-item-id UUID` replaces one exact item.

`new` is the compatibility default. Replace always requires a replacement item
UUID. An append-after UUID is accepted only for `append`, and a replacement UUID
is accepted only for `replace`, so unattended scripts cannot silently
reinterpret one destination as another. Both IDs must resolve in the active
composition before capture starts. If that document generation or target item
changes while capture is in flight, the result reports `staleDestination`; the
generation token still prevents pixels from entering a different document.
New automated captures open as Screenshot documents. Append inherits an
existing Comparison, Steps, or Combined Image purpose; because automation
cannot answer the interactive first-add question, appending to a one-image
Screenshot deterministically promotes it to Combined Image with Auto
arrangement. Compare commands select Comparison, Steps layouts select Steps,
and Auto/Row/Column/Grid/Freeform layouts or compatible templates select
Combined Image. These purpose changes reuse the existing public command and
result schemas. Layout and compatible-template commands may activate Steps or
Combined Image directly from a one-image Screenshot as one undoable change;
Comparison still requires two included images.
Appending a Private Capture taints the entire composition as private; private
compositions stay out of Snip History, recovery, search, OCR/AI indexing, clipboard
history, and recent-item surfaces.

Layout automation uses:

- `composition layout --layout auto|compare|steps|row|column|grid|freeform`
- optional `--axis horizontal|vertical`
- `--grid-columns`, `--target-aspect-ratio`, and paired
  `--freeform-width`/`--freeform-height` layout geometry
- `--step-numbering` (`none`, `decimal`, uppercase/lowercase letters, or
  uppercase/lowercase Roman numerals), `--step-start-index`,
  `--step-captions`, and `--step-connector` sequence presentation

Comparison automation uses:

- `--mode side-by-side|overlay|wipe|blink|difference|change-highlight`
- optional `--first-item-id` and `--second-item-id` as a pair
- `--axis`, `--wipe-position`, `--overlay-opacity`, `--blink-interval`,
  `--difference-intensity`, `--highlight-color`, `--highlight-threshold`,
  `--primary-label`, and `--secondary-label`

Positions, opacity, and threshold use values from `0` through `1`; highlight
colors use `#RRGGBB` or `#RRGGBBAA`. The active pair is used when item IDs are
omitted. Composition results use the `composition` payload and can fail with
`noActiveComposition`, `compositionItemNotFound`,
`compositionRequiresMultipleItems`, or `incompatibleCompositionItems`.
Capture destinations can additionally fail with `staleDestination` when the
target document or insertion/replacement item changes after capture starts.

Template automation uses `composition template --id TEMPLATE_ID` or
`composition template --name "Template Name"`. Stable IDs are preferred for
durable scripts. Built-ins use IDs such as `builtin.clean-grid`,
`builtin.side-by-side`, `builtin.numbered-steps`, and
`builtin.freeform-board`; saved user templates retain their generated ID.
Templates are resolved and item-count compatibility is checked before the
single undoable application command runs.

Rendered automation accepts `--appearance app-default|plain|styled`.
`app-default` preserves the existing behavior: styled output is used when a
Presentation style is configured, otherwise output is plain. `plain` and
`styled` make the choice deterministic; `styled` fails when no Presentation
style is configured.

Composition export supports static PNG, JPEG, and PDF; animated GIF and APNG;
MP4; editable `.sss`; and self-contained interactive HTML. HTML embeds the
fully rendered, redacted pixels and comparison controls it needs and does not
depend on a server or remotely loaded resources. Embedded images retain their
full pixel dimensions in universally compatible PNG while screenshot-oriented
lossless filtering and strong compression reduce the single-file payload.
Independent frames encode concurrently within a bounded working-memory budget,
and the completed HTML is installed atomically. Its outer page uses the app's
subtle line-and-dot motif, and a small embedded app logo sits beside the quiet
Created with SnipSnipSnip footer. The product name links to the canonical
website, but viewing the file makes no network request; navigation occurs only
when the link is chosen. Comparison HTML opens in the configured view and its
Compare Using menu exposes Side by Side, Wipe, Overlay, Blink, Difference, and
Highlight Changes. It also provides synchronized Fit and Zoom controls, direct
Wipe dragging, and URL-fragment viewer state without browser storage. Without
JavaScript, the configured static view remains visible. GIF/APNG/MP4 require
Compare → Blink and preserve its interval, crossfade, and loop configuration;
animated output uses a disclosed 4,096 px longest-side cap. HTML requires
Compare or Steps. Incompatible animation/HTML requests return
`unsupportedComparisonOutput`, and raster requests that exceed the safe output
budget return `oversizedOutput`.

### Guide Commands

Guide creation and dedicated Guide automation are Pro-only. The identifiers
remain decodable on every automation surface so existing workflows stay
compatible:

- `guide start --target window|app|region|display`
- `guide pause`, `guide resume`, `guide add-step`, and `guide stop`
- `guide export --format pdf|gif|apng|mp4-full|mp4-highlights|mp4-slideshow|images|zip`
- URL routes mirror these at `snipsnipsnip://v1/guide/start`, `/pause`, `/resume`, `/add-step`, `/stop`, and `/export`.
- AppleScript uses `guide given action:"…"`, with optional `target`, `format`, and `privateCapture` parameters.
- App Intents exposes the same actions through Control SnipSnipSnip Guide in
  Pro. The App Store edition does not advertise that App Shortcut.

In Pro, Guide start requires Screen Recording and Accessibility. Region start is interactive and the selected Guide region is constrained to the display where the drag begins; cross-display Guide regions are rejected, while ordinary screenshot-region capture is unchanged. Window and app Guide targets follow source geometry changes automatically. URL exports are trigger-oriented and use the default Downloads destination. Explicit errors include `noActiveGuide`, `guideAlreadyActive`, `guideHasNoSteps`, `guideSourceMediaUnavailable`, and `guideFinalizationFailed`.

In the App Store edition, every dedicated Guide start/control/export request
returns `proFeatureRequired` before permission or capture work. Generic document
opening still accepts `.sssguide`, and an opened Guide can be edited, saved, and
exported through the normal document workflow. An explicit UI Map capture
option likewise returns `proFeatureRequired`; ordinary Window capture is
unchanged.

Private Guide skips Snip History, search, indexing, and background OCR or AI refinement. Automation never receives screenshot, OCR, caption, window-title, or path content in diagnostics.

Interactive Window selection and the click-to-select shortcut in interactive Region selection include visible app-owned normal windows, floating panels, modal dialogs, utility windows, and custom levels below Dock. Desktop surfaces, system UI owners, and higher menu/overlay levels remain excluded; Window candidates retain the existing 60 × 40 point minimum; Screen Recording permission remains required, with no Accessibility requirement. Saved-window presets and Repeat Last Capture can resolve those explicitly selected panels. Automatic frontmost-window capture remains restricted to normal-level windows. Interactive Region and Window selection refresh the eligible window list before presentation and share the same capture-space window bounds and front-to-back ordering for hover and click selection. Window selection does not substitute cross-application Accessibility hit tests or cached carousel geometry; its keyboard and VoiceOver targets remain available. Commands, interaction policies, result fields, and output formats are unchanged. Command names, routes, result fields, and output formats are unchanged.

Supported flags:

- `--json`: request machine-readable JSON output.
- `--interactive`: allow region or window selection UI.
- `--copy`: copy rendered output to the clipboard.
- `--open-editor`: open the result in the editor.
- `--float`: create a floating reference.
- `--output PATH`: save to a file path.
- `--format png|jpeg|pdf|sss|gif|apng|mp4|html`: choose rendered, animated,
  video, interactive, or editable output.
- `--overwrite`: replace an existing output file.
- `--private`: request Private Capture behavior, including repeat-last.
- `--delay 0|3|5|10`, `--include-cursor`, and `--ui-map`: explicit capture options. UI Map remains Pro-only.
- `--reveal`: reveal a successful file output in Finder; requires `--output`.
- `--destination new|append|replace`: choose the capture document destination.
- `--after-item-id UUID`: identify the insertion item for an append
  destination.
- `--replace-item-id UUID`: identify the item for a replace destination.
- `--appearance app-default|plain|styled`: choose the rendered appearance.

The sandboxed App Store build accepts unattended file destinations only inside
the current user's Downloads folder. This matches the app's Downloads
entitlement and fails early with `permissionDenied` instead of attempting a
write macOS will reject. Interactive exports can use a location chosen in the
save panel. The direct-download Pro build can use other writable absolute paths.

### CLI Exit Codes

- `0`: succeeded or accepted.
- `64`: invalid request or command syntax.
- `69`: busy app, unavailable feature/target, Pro requirement, or unavailable Guide state/source.
- `70`: internal or unknown automation failure.
- `74`: output or Guide finalization failed.
- `77`: permission denied or confirmation required.
- `130`: user cancelled.

## AppleScript Examples

```applescript
tell application id "com.oontz.SnipSnipSnip"
    automation status
    list capture presets
    run capture preset given name:"Daily Clip", output:"clipboard"
    capture fullscreen given outputPath:"/Users/me/Downloads/fullscreen.png", format:"png", overwrite:true
    capture frontmost window given output:"editor"
    capture region given rect:"100,100,640,480", outputPath:"/Users/me/Downloads/region.png", format:"png", overwrite:true
    capture region given interactive:true, output:"editor"
    capture window given interactive:true, output:"clipboard"
    capture fullscreen given destination:"append", afterItemID:"00000000-0000-0000-0000-000000000001", appearance:"plain", output:"editor"
    set composition layout given layout:"steps", axis:"vertical"
    set composition compare mode given mode:"wipe", firstItemID:"00000000-0000-0000-0000-000000000001", secondItemID:"00000000-0000-0000-0000-000000000002", wipePosition:0.4
    apply composition template given id:"builtin.numbered-steps"
    repeat last capture given output:"editor"
    export current screenshot given outputPath:"/Users/me/Downloads/current.png", format:"png", overwrite:true
    export current screenshot given outputPath:"/Users/me/Downloads/comparison.html", format:"html", appearance:"styled", overwrite:true
end tell
```

Commands return JSON text.

## URL Routes

URL routes are versioned and trigger-oriented. They do not return structured
data to the caller. Capture URLs support `editor`, `clipboard`, `float`, and
`none`; the explicit export route also supports `output=file` with
`outputPath`, `format`, and `overwrite`. Capture routes use `destination`,
`after` for an append insertion item UUID, and canonical `item` for a
replacement item UUID. The older `replaceItemID` spelling remains accepted as a
compatibility alias.

```text
snipsnipsnip://v1/status
snipsnipsnip://v1/presets/run?id=UUID&output=clipboard
snipsnipsnip://v1/presets/run?name=Daily%20Clip&output=editor
snipsnipsnip://v1/capture/fullscreen?output=clipboard
snipsnipsnip://v1/capture/fullscreen?destination=append&after=UUID&appearance=plain&output=editor
snipsnipsnip://v1/capture/frontmost-window?destination=replace&item=UUID&output=editor
snipsnipsnip://v1/capture/frontmost-window?output=editor
snipsnipsnip://v1/capture/region?rect=100,100,640,480&output=editor
snipsnipsnip://v1/capture/region?interactive=true&output=editor
snipsnipsnip://v1/capture/window?output=clipboard
snipsnipsnip://v1/repeat-last?output=editor
snipsnipsnip://v1/composition/layout?layout=steps&axis=vertical
snipsnipsnip://v1/composition/compare?mode=wipe&firstItemID=UUID&secondItemID=UUID&wipePosition=0.4
snipsnipsnip://v1/composition/template?id=builtin.numbered-steps
snipsnipsnip://v1/export/current?format=html&output=file&outputPath=/Users/me/Downloads/comparison.html&appearance=styled&overwrite=true
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
- Capture SnipSnipSnip Screen
- Capture SnipSnipSnip Frontmost Window
- Capture SnipSnipSnip Region
- Capture SnipSnipSnip Window
- Repeat Last SnipSnipSnip Capture
- Open SnipSnipSnip Document
- Export Current SnipSnipSnip Screenshot
- Add Capture to SnipSnipSnip Composition
- Replace SnipSnipSnip Composition Item
- Export SnipSnipSnip Composition
- Set SnipSnipSnip Composition Layout
- Set SnipSnipSnip Comparison Mode
- Apply SnipSnipSnip Composition Template
- Control SnipSnipSnip Guide (Pro only; the identifier remains compatible in
  the App Store edition but is not advertised)

Shortcut suggestions stay within the macOS ten-suggestion limit and focus on
fullscreen, region, window, presets, composition add/replace/export,
layout/comparison, and Guide. Other registered actions remain discoverable in
the Shortcuts action library.

Foreground/background behavior:

- Passive actions such as status and preset listing run in the background.
- Capture and export actions can run in the background when all required inputs
  and permissions are already available.
- Interactive region/window capture, connected-device or scrolling repeat
  workflows, `openEditor`, and `floatReference` outputs continue in
  SnipSnipSnip before completing. Repeating a fixed region, saved window,
  frontmost window, or fullscreen capture waits for capture and requested file
  output before returning.
- File output accepts an absolute POSIX path such as
  `/Users/me/Downloads/output.png` or a `file://` URL, then uses the same
  overwrite and format validation as other automation interfaces. The
  sandboxed App Store build restricts unattended output to Downloads.
- Capture actions expose New Document, Append to Current Composition, and
  Replace Composition Item destinations, optional **Append After Composition
  Item ID** targeting, and explicit Plain/Styled appearance. Every capture
  action uses the same destination validation.
- Dedicated Add, Replace, and Export Composition actions keep common
  multi-capture Shortcuts low-friction while mapping to the same shared
  destination and export commands.
- Composition layout, comparison, and template actions expose the same
  layouts, modes, item-pair selection, settings, and stable template selectors
  as CLI and AppleScript.
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
          "supportsCurrentEditorExport": true,
          "supportsGuide": true,
          "supportsComposition": true
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
      "url": "file:///Users/me/Downloads/fullscreen.png",
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

Composition payloads include `documentID`, `itemCount`, `layout`, privacy state,
and comparison mode when applicable. Append and replace capture results also
include `itemID`, which is the exact inserted or replaced item—not whichever
item happens to be selected when the response is encoded. `selectedItemID`
remains available as editor-state context for compatibility.

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

## 1.2.0 automation audit (2026-10-06)

- Complete unit target: 1,291 tests, zero failures, one skip (Firefox is not installed).
  The opt-in Google Chrome HTML check passed. The final saved-window permission
  preflight adjustment also passed the 48-test automation regression set.
- The final universal Release build passed for Intel and Apple silicon. The app,
  CLI, and Share extension passed the App Store forbidden-symbol check. This was
  a build-only check without distribution signing or a new TestFlight upload.
- All 77 checked-in sample scripts were exercised: 28 CLI, 28 AppleScript,
  and 21 URL samples. The repeatable runner passed 97 CLI sample/matrix checks,
  26 noninteractive AppleScript samples, and 19 noninteractive URL samples.
  Procedures 11 and 12 were completed through native pickers for each interface.
- Window-to-Clipboard completion increased the clipboard change counter once
  per interface. Cancelling a private Window capture left it unchanged.
- Four concurrent CLI captures produced one success and three `busy` responses;
  rejected requests created no output files. Cancelling a pending picker released
  the guard and allowed a subsequent export.
- The matrix wrote PNG, JPEG, PDF, SSS, GIF, APNG, MP4, and HTML; exercised every
  layout and comparison mode, built-in templates, quoting/Unicode, overwrite,
  missing targets, invalid numbers, malformed arguments, privacy guards, and
  App Store rejection of Pro-only Guide/UI Map requests.

The live interface runs used the isolated Debug automation fixture and synthetic
pixels, with real Apple Events, URL dispatch, and native selection UI. They do
not replace signed TestFlight permission QA, physical-device testing, or live
Pro Guide recording. Guide model/export tests and App Intents contracts run in the hosted test suite;
user-authored Shortcuts and OS permission-reset flows were not exercised.
Use the scripts and test commands above to repeat the audit on a new candidate.
