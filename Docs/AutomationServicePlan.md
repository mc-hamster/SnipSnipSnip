# Automation Service Plan

## Status

This document is the architecture and interface plan for external automation and
the reference checklist for the v1 implementation.

The goal is to create one stable automation service contract inside
SnipSnipSnip, then expose that contract through command line, AppleScript, URL
scheme, and App Intents adapters. The adapters must not call `AppModel`,
SwiftUI views, menu actions, or editor controllers directly.

Implemented v1 coverage:

- Shared `SnipSnipSnip/Automation` request, result, validation, URL, AppleScript,
  and CLI parser layer.
- App-hosted service execution for status, presets, fullscreen, frontmost
  window, fixed region, interactive region/window, repeat last capture, document
  open, and current editor export.
- URL routes under `snipsnipsnip://v1/...`, while preserving
  `snipsnipsnip://import-pasteboard`.
- AppleScript suite commands returning JSON text.
- `snipsnipsnipctl` CLI helper source using AppleScript/Apple Events as the v1
  transport. The sandboxed executable embeds its own bundle identity and is
  entitled only for SnipSnipSnip's dedicated scripting access group.
- App Intents for macOS Shortcuts, Spotlight, and system automation surfaces,
  backed by the same automation request/result contract.
- Multi-capture composition contract coverage across CLI, AppleScript, URL, and
  App Intents: new/append/replace capture destinations, exact append-after and
  replacement item targeting, layout and comparison mutation, explicit output
  appearance, composition payloads/errors, and PNG/JPEG/PDF/GIF/APNG/MP4/HTML/SSS
  format identifiers.
- GitHub-only sample scripts under `Docs/Automation/SampleScripts`.

## Goals

- Provide a stable, product-level automation contract for capture, composition,
  presets, export, clipboard, document opening, and permission preflight.
- Keep automation requests separate from internal UI implementation details.
- Make Capture Presets the safest first-class automation target.
- Support structured success, warning, and error results.
- Keep automation sandbox-friendly and local-first.
- Keep external interfaces conservative enough that privacy-sensitive actions
  are explicit and auditable.

## Non-Goals

- No cloud upload, webhook, S3, issue tracker, or third-party destination in the
  first automation framework.
- No arbitrary remote-control API for moving annotations or mutating editor
  state directly.
- No unauthenticated local HTTP server.
- No promise that URL scheme calls can return rich data. URL scheme automation
  is a trigger surface, not the main query surface.
- No bypass of existing Screen Recording, Accessibility, microphone, or
  Pro-feature requirements.

## Existing Entry Points

- Menu commands and global hotkeys currently call `AppModel` methods directly.
- Capture Presets are persisted in app preferences and can rerun saved region,
  window, frontmost-window, and fullscreen screenshot targets.
- `snipsnipsnip://import-pasteboard` already exists for share-extension image
  import.
- `AppModel+Automation.swift` currently contains hotkey and history-search
  helpers; the new service should live in a separate Automation module to avoid
  turning that file into a broad automation facade.

## Architecture

The `SnipSnipSnip/Automation` module folder has these roles:

- `AutomationService`
  - The only in-process API that external adapters call.
  - Validates requests, preflights capabilities, dispatches execution, and
    returns structured results.
- `AutomationHost`
  - A narrow protocol implemented by `AppModel` or a small adapter around it.
  - Contains only the app operations the service needs.
- `AutomationRequestRouter`
  - Parses adapter-specific input into service requests.
  - Converts service results back into JSON, AppleScript records, or URL
    callbacks.
- `AutomationPermissionPreflight`
  - Checks Screen Recording, Accessibility, microphone/system audio, and
    feature flags before execution.
- `AutomationOutputWriter`
  - Owns file, clipboard, open-in-editor, floating-reference, and JSON-result
    output behavior.
- `AutomationAuditLog`
  - Records local, privacy-safe automation events for diagnostics without
    screenshot pixels, OCR text, clipboard content, or annotation text.

The dependency direction should be:

```text
CLI / AppleScript / URL / App Intents adapters
        |
        v
AutomationRequestRouter
        |
        v
AutomationService
        |
        +--> AutomationPermissionPreflight
        +--> AutomationOutputWriter
        +--> AutomationHost
```

Menu commands and hotkeys can continue to call current app actions at first.
Longer term, commands that map cleanly to automation should call the same
service so behavior stays consistent.

## Core Contract

The contract should be Codable where possible. CLI and URL adapters can use JSON
directly; AppleScript can map the same model to a scripting dictionary.

```swift
@MainActor
protocol AutomationService {
    func perform(_ request: AutomationRequest) async -> AutomationResultEnvelope
    func capabilities(requestID: UUID) async -> AutomationResultEnvelope
    func listCapturePresets(requestID: UUID) async -> AutomationResultEnvelope
}

@MainActor
protocol AutomationOutputWriter {
    func writeAutomationOutput(_ output: AutomationOutput) async throws -> [AutomationOutputResult]
}
```

### Request Envelope

```swift
struct AutomationRequest: Codable, Sendable, Identifiable {
    var id: UUID
    var source: AutomationSource
    var command: AutomationCommand
    var interactionPolicy: AutomationInteractionPolicy
    var privacy: AutomationPrivacyOptions
    var captureDestination: AutomationCaptureDestination
    var appendAfterCompositionItemID: UUID?
    var replaceCompositionItemID: UUID?
    var appearance: AutomationOutputAppearance
    var output: AutomationOutput
}
```

`id` is supplied by adapters when possible so logs and callbacks can correlate
the request and result.

`source` should include the adapter kind and best-effort caller name:

```swift
enum AutomationSourceKind: String, Codable, Sendable {
    case commandLine
    case appleScript
    case urlScheme
    case appIntent
    case internalCommand
}
```

### Interaction Policy

Automation should make user interaction explicit:

```swift
enum AutomationInteractionPolicy: String, Codable, Sendable {
    case never
    case promptIfNeeded
    case requireUserSelection
}
```

- `never`: fail if the action needs a picker, save panel, permission prompt, or
  interactive region selection.
- `promptIfNeeded`: allow permission remediation, missing-window replacement,
  save panels, or confirmation dialogs.
- `requireUserSelection`: explicitly start an interactive region or window
  selection workflow.

CLI defaults to `never` unless a flag such as `--interactive` is present.
AppleScript defaults to `promptIfNeeded`. URL scheme defaults to
`promptIfNeeded` and should ask for confirmation for sensitive actions.

### Commands

```swift
enum AutomationCommand: Codable, Sendable {
    case status
    case listPresets
    case runPreset(RunPresetAutomationCommand)
    case capture(CaptureAutomationCommand)
    case repeatLastCapture
    case openDocument(OpenDocumentAutomationCommand)
    case exportCurrent(ExportCurrentAutomationCommand)
    case composition(CompositionAutomationCommand)
    case guide(GuideAutomationCommand)
}
```

Capture destination is request-level so direct captures, preset runs, and repeat
last share one deterministic behavior. `new` is the legacy decode and
construction default. `append` accepts an optional exact active item UUID and
inserts after it; when omitted, the selected-item/default append behavior is
preserved. `replace` requires an exact item UUID. Append-after and replacement
IDs are rejected outside their matching destinations. If the target document
generation or item changes while capture is in flight, execution returns
`staleDestination` rather than redirecting pixels into a different document.
Output appearance similarly defaults to `appDefault`, preserving
styled-when-configured behavior, while `plain` and `styled` are explicit.
New automated captures initialize the internal Screenshot purpose. Append
inherits an existing Comparison, Steps, or Collection purpose; an unattended
append to a one-image Screenshot promotes it deterministically to Collection
with Auto layout because no interactive goal chooser is available. Compare
commands set Comparison purpose, Steps layout sets Steps purpose, and
Auto/Row/Column/Grid/Freeform layouts or matching templates set Collection
purpose. This synchronization is internal document state and does not change
the v1 automation schema. Layout and compatible-template commands can activate
Steps or Collection directly from a one-image Screenshot as one undoable
change; Comparison continues to require two included images.

Composition commands set one of the stable layout identifiers
`auto|compare|steps|row|column|grid|freeform` or one of the comparison
identifiers
`sideBySide|overlay|wipe|blink|difference|changeHighlight`. Comparison payloads
can include an explicit item pair, horizontal/vertical axis, wipe position,
overlay opacity, blink interval, difference intensity, change-highlight
color/threshold, and primary/secondary labels. Layout payloads also cover grid
columns, target aspect ratio, paired freeform canvas dimensions, and complete
step numbering (decimal, letter, or Roman), caption, and connector settings.
They also apply built-in or user-saved composition templates by stable ID or
exact display name. Template commands store no image data and reject
incompatible item counts before committing one undoable change.

Guide v1 keeps start (window, app, interactive region, or display), pause, resume, manual step, stop, open `.sssguide`, and export identifiers stable on every surface. Guide creation and dedicated control/export are Pro-only. The App Store edition decodes those requests and returns `proFeatureRequired` before permission or capture work; generic `.sssguide` opening remains shared. In Pro, interactive Guide regions are constrained to the display where selection begins and cross-display rectangles are rejected; normal screenshot-region automation remains unchanged. Window and app Guides resolve and follow the current source geometry without changing the persisted automation command.

Initial capture targets:

```swift
enum CaptureAutomationTarget: Codable, Sendable {
    case fullscreen(FullscreenCaptureTarget)
    case frontmostWindow
    case region(RegionCaptureSelector)
    case interactiveRegion
    case interactiveWindow
}
```

`interactiveRegion` and `interactiveWindow` require
`interactionPolicy == .requireUserSelection` or `promptIfNeeded`.

Unsupported first-version targets should return `unsupportedFeature` instead of
silently falling back:

- scrolling capture presets
- connected-device capture presets
- connected-device recording
- arbitrary video post-production automation

### Options

Automation options should preserve product concepts instead of exposing
controller flags:

```swift
struct CaptureAutomationOptions: Codable, Sendable {
    var delay: AutomationCaptureDelay
    var includesCursor: Bool?
    var windowUIMap: AutomationTriState
    var fullscreenDisplayMode: ScreenshotFullscreenDisplayMode?
}

enum AutomationCaptureDelay: Codable, Sendable {
    case appDefault
    case immediate
    case seconds(Int)
}

enum AutomationTriState: String, Codable, Sendable {
    case appDefault
    case enabled
    case disabled
}
```

The service should reject unsupported delay values until custom timer support is
implemented. That keeps external behavior honest while leaving room for a later
custom timer.

### Output

```swift
enum AutomationOutput: Codable, Sendable {
    case appDefault
    case openEditor
    case copyRenderedImage
    case saveFile(AutomationFileOutput)
    case saveEditableDocument(AutomationFileOutput)
    case floatReference
    case none
}

struct AutomationFileOutput: Codable, Sendable {
    var url: URL?
    var format: AutomationExportFormat
    var overwrite: Bool
    var revealInFinder: Bool
}

enum AutomationExportFormat: String, Codable, Sendable {
    case png
    case jpeg
    case pdf
    case sss
    case gif
    case apng
    case mp4
    case html
}
```

GIF/APNG/MP4 are composition-aware Blink outputs with deterministic timing,
crossfade, loop behavior, and a disclosed 4,096 px longest-side cap. HTML is a
self-contained interactive Compare or Steps artifact built only from rendered,
redacted pixels, with embedded assets and no runtime server or network
dependency. Side-by-side Comparison HTML provides Show Both, Before, and After
controls. Every Comparison HTML opens in the configured view and provides a
Compare Using selector for Side by Side, Wipe, Overlay, Blink, Difference, and
Highlight Changes, plus synchronized Fit and Zoom controls. Wipe supports
direct divider dragging, and the URL fragment preserves viewer state without
using browser storage. Without JavaScript, the configured static view remains
visible.

`saveEditableDocument(.sss)` must preserve the existing redaction warning
semantics. When the request has `interactionPolicy == .never` and the document
contains redactions or Private captures, the service should fail with
`confirmationRequired` instead of saving an editable package that retains
original pixels.

### Result

```swift
struct AutomationResultEnvelope: Codable, Sendable {
    var requestID: UUID
    var status: AutomationStatus
    var payload: AutomationPayload?
    var outputs: [AutomationOutputResult]
    var warnings: [AutomationWarning]
    var error: AutomationError?
}

enum AutomationPayload: Codable, Sendable {
    case preflight(AutomationPermissionPreflight)
    case capabilities(AutomationCapabilities)
    case presets([AutomationPresetSummary])
    case capture(AutomationCaptureSummary)
    case export(AutomationExportSummary)
    case composition(AutomationCompositionSummary)
    case permissionStatus(AutomationPermissionSummary)
    case none
}

struct AutomationPermissionPreflight: Codable, Sendable {
    var capabilities: AutomationCapabilities
    var permissions: AutomationPermissionSummary
    var isCaptureReady: Bool
}

enum AutomationStatus: String, Codable, Sendable {
    case succeeded
    case failed
    case cancelled
}
```

Common error codes:

```swift
enum AutomationErrorCode: String, Codable, Sendable {
    case invalidRequest
    case busy
    case permissionDenied
    case confirmationRequired
    case userCancelled
    case targetUnavailable
    case featureUnavailable
    case proFeatureRequired
    case unsupportedOutput
    case outputFailed
    case internalError
    case noActiveComposition
    case compositionItemNotFound
    case compositionRequiresMultipleItems
    case incompatibleCompositionItems
    case unsupportedComparisonOutput
    case oversizedOutput
    case staleDestination
}
```

Adapters should preserve `error.code` as the primary machine-readable result.
Localized strings are secondary.

## Adapter Design

### CLI

Ship a `snipsnipsnipctl` command-line helper. The helper should talk to the
running app through the automation service transport, launch the app when
needed, and return structured JSON when requested.

The transport can start simple but should keep the contract stable:

- Phase 1: helper invokes the app through a local automation request broker and
  waits for a JSON result.
- Phase 2: replace the broker with XPC if we need stronger bidirectional
  request/result behavior.

Proposed commands:

```sh
snipsnipsnipctl status --json
snipsnipsnipctl presets list --json
snipsnipsnipctl presets run --id <uuid> --copy
snipsnipsnipctl presets run --name "Docs Header" --output ~/Downloads/header.png
snipsnipsnipctl capture fullscreen --display current --copy
snipsnipsnipctl capture frontmost-window --output ~/Downloads/frontmost.png
snipsnipsnipctl capture region --rect 100,120,800,450 --output ~/Downloads/region.png
snipsnipsnipctl capture region --interactive --open-editor
snipsnipsnipctl capture fullscreen --destination append --after-item-id <uuid> --appearance plain --open-editor
snipsnipsnipctl composition layout --layout steps --axis vertical
snipsnipsnipctl composition compare --mode wipe --first-item-id <uuid> --second-item-id <uuid> --wipe-position 0.4
snipsnipsnipctl export current --format png --output ~/Downloads/current.png
snipsnipsnipctl export current --format html --appearance styled --output ~/Downloads/comparison.html
```

Exit code guidance:

- `0`: success
- `64`: invalid request
- `69`: feature, target, or capture destination unavailable/stale
- `70`: internal error
- `74`: output or file-system failure
- `77`: permission denied or confirmation required
- `130`: user cancelled

CLI best practices:

- Prefer `presets run` over hard-coded region coordinates.
- Use `--json` for scripts and parse `status`, `outputs`, and `error.code`.
- Use unique output paths or `--overwrite` explicitly.
- In the sandboxed App Store build, keep unattended file output inside
  Downloads. Interactive save panels may grant access elsewhere, while the
  direct-download Pro build can use other writable absolute paths.
- Run `status --json` before unattended workflows.
- Use `--interactive` only for workflows where a picker or region overlay is
  acceptable.
- Use flattened PNG/JPEG/PDF output for redacted content. Do not automate
  editable `.sss` sharing when redactions are present unless the caller
  explicitly accepts that editable packages retain original pixels.

### AppleScript

Expose a small scriptable suite backed by `AutomationService`. Use an `.sdef`
dictionary and `NSScriptCommand` handlers that translate AppleScript commands to
`AutomationRequest`.

Initial command vocabulary:

```applescript
tell application "SnipSnipSnip"
    automationStatus
    listCapturePresets
    runCapturePreset given name:"Docs Header", output:"clipboard"
    captureFullscreen given display:"current", outputPath:"/Users/me/Downloads/fullscreen.png", format:"png", overwrite:true
    captureFrontmostWindow given output:"editor"
    captureRegion given rect:"100,100,640,480", outputPath:"/Users/me/Downloads/region.png", format:"png", overwrite:true
    captureWindow given interactive:true, output:"clipboard"
    captureFullscreen given destination:"append", afterItemID:"…", appearance:"plain", output:"editor"
    setCompositionLayout given layout:"steps", axis:"vertical"
    setCompositionCompareMode given mode:"wipe", firstItemID:"…", secondItemID:"…", wipePosition:0.4
    repeatLastCapture given output:"editor"
    exportCurrentScreenshot given outputPath:"/Users/me/Downloads/current.png", format:"png", overwrite:true
end tell
```

AppleScript commands return JSON text using the same
`AutomationResultEnvelope` shape as the CLI.

AppleScript best practices:

- Prefer preset names for user-authored workflows and preset IDs for durable
  generated scripts.
- Use `with user interaction` only when a picker, permission prompt, or missing
  target replacement is expected.
- Treat returned records as authoritative; do not parse user-visible alert text.
- Avoid unattended AppleScript captures that require Accessibility unless the
  script first checks `get automation status`.

Implementation notes:

- AppleScript commands are synchronous from the script author's perspective.
  `NSScriptCommand.suspendExecution()` bridges to async service execution and
  `resumeExecution(withResult:)` returns the authoritative envelope only after
  non-interactive composition mutations and exports complete. The CLI's Apple
  Event therefore has the same completion guarantee. Only genuinely
  interactive workflows return `acceptedInteractiveWorkflow`.
- The scripting dictionary should avoid exposing internal object graphs. Use
  records and scalar values instead of scriptable editor objects.
- Add tests for command decoding and result mapping without launching
  AppleScript.

### URL Scheme

Extend the existing `snipsnipsnip` scheme with versioned automation paths while
preserving `snipsnipsnip://import-pasteboard`.

Proposed URLs:

```text
snipsnipsnip://v1/presets/run?id=<uuid>&output=clipboard
snipsnipsnip://v1/presets/run?name=Docs%20Header&output=editor
snipsnipsnip://v1/capture/fullscreen?display=current&output=clipboard
snipsnipsnip://v1/capture/frontmost-window?output=editor
snipsnipsnip://v1/capture/frontmost-window?destination=replace&item=<uuid>&output=editor
snipsnipsnip://v1/capture/region?rect=100,100,640,480&output=editor
snipsnipsnip://v1/capture/region?interactive=1&output=editor
snipsnipsnip://v1/capture/window?output=clipboard
snipsnipsnip://v1/repeat-last?output=editor
snipsnipsnip://v1/composition/layout?layout=steps&axis=vertical
snipsnipsnip://v1/composition/compare?mode=wipe&firstItemID=<uuid>&secondItemID=<uuid>&wipePosition=0.4
snipsnipsnip://v1/composition/template?id=builtin.numbered-steps
snipsnipsnip://v1/export/current?format=html&output=file&outputPath=/Users/me/Downloads/comparison.html&appearance=styled&overwrite=true
snipsnipsnip://v1/status
```

URL scheme behavior:

- URL calls are best for launchers, links, and fire-and-forget triggers.
- URL calls should not be the primary interface for returning large structured
  data.
- File output from URL calls should be conservative. Prefer `output=editor`,
  `output=clipboard`, or a save panel over accepting arbitrary file paths from
  another app.
- Sensitive actions should either show confirmation or require an existing
  trusted setting before running without UI.
- Results can be surfaced through app UI. Optional callback URLs can be added
  later, but they need explicit design to avoid leaking private filenames or
  capture metadata to untrusted callers.

URL best practices:

- Use URL scheme automation for user-triggered actions from launchers or docs.
- Use CLI or AppleScript when the caller needs structured result data.
- Include a version path (`/v1/...`) so future URL grammar can evolve.
- Keep query values simple and percent-encoded.

### App Intents / Shortcuts

Register App Intents as a native macOS adapter over `AutomationService`, not as
a separate command path. Intent types translate parameters into
`AutomationRequest` and call a Sendable `AutomationIntentClient`. Passive
intents summarize `AutomationResultEnvelope` responses as App Intent dialogs;
capture and export actions complete without success dialogs unless Shortcuts is
configured to show result UI or foreground interaction is required.

macOS 26 implementation rules:

- Use `supportedModes` for background/foreground behavior. Do not use the
  deprecated `openAppWhenRun` property.
- Passive intents such as status and preset listing support `.background`.
- Action intents support `[.background, .foreground(.dynamic)]`.
- Call `continueInForeground` before interactive region/window workflows,
  connected-device or scrolling repeat workflows, or outputs that present UI
  such as `openEditor` and `floatReference`. Fixed-region, saved-window,
  frontmost-window, and fullscreen repeats still await their capture and file
  output before returning.
- Register the live `AutomationIntentClient` with
  `AppDependencyManager.shared` during app startup.

Initial App Intents:

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

Supporting types:

- `CapturePresetEntity` is backed by `AutomationService.listCapturePresets`.
- App enums map Shortcuts choices to existing automation output, export format,
  fullscreen display, delay, cursor, UI Map, composition destination, output
  appearance, layout, comparison mode, and axis values. Every capture-producing
  intent exposes the optional append-after item UUID alongside the replacement
  item UUID.
- File output accepts an absolute POSIX path or `file://` URL string, then maps
  to the existing `AutomationOutput` file validation. The sandboxed App Store
  build rejects unattended destinations outside Downloads with
  `permissionDenied`; interactive save panels and the unsandboxed
  direct-download Pro build retain their existing destination behavior.
- `AppShortcutsProvider` advertises common capture phrases and uses
  `AppIntents.AppShortcut` explicitly so it does not collide with the in-app
  keyboard shortcut catalog. The Guide App Shortcut is compiled only into Pro
  and development builds; the intent identifier remains decodable in the App
  Store edition for stable `proFeatureRequired` results.
- Opening `.sss` documents uses `IntentFile` with the SnipSnipSnip document
  package type.

## Permission And Privacy Rules

- Never capture pixels without Screen Recording permission.
- In the App Store edition, return `proFeatureRequired` for explicit UI Map and
  dedicated Guide requests before any permission preflight. Do not request or
  direct the user to Accessibility.
- In Pro, never attempt scrolling capture or UI Map metadata capture without
  Accessibility permission.
- In Pro, never start Guide without Screen Recording and Accessibility
  permission.
- Do not grant extra permission because a request came from CLI, AppleScript,
  URL, or App Intents.
- Do not persist screenshots, OCR text, clipboard content, annotation text, or
  UI Map content in automation logs.
- Private Capture should be available as an automation option for screenshot
  requests that should skip archive checkpoints, recycle-bin retention, and
  background OCR indexing.
- Appending any private capture taints the whole composition as private. The
  composition must then stay out of archive, recovery, recent items, search,
  OCR/AI indexing, clipboard history, and external-drag staging.
- Editable `.sss` output retains base screenshot pixels, annotation state, and
  hidden UI Map metadata. External automation docs must tell callers to use
  flattened image/PDF output when privacy flattening matters.
- Generic document opening preserves `.sssguide` compatibility in both
  editions. Dedicated Guide export automation remains Pro-only.

## Testing Strategy

- Unit-test request decoding for CLI JSON, AppleScript records, URL paths, and
  App Intent parameter mapping.
- Unit-test permission preflight decisions for each capture target and output.
- Unit-test result mapping so adapters preserve error codes.
- Unit-test legacy decode defaults, destination invariants, composition
  parameter ranges, exact append-after targeting, stale generation/item errors,
  layout/mode coverage, and every export format identifier.
- Unit-test App Intent preset entity queries with a fake
  `AutomationIntentClient`.
- Add architecture tests that keep App Intent files behind
  `AutomationService`/`AutomationIntentClient` and away from app/workflow
  internals.
- Add AppModel adapter tests for preset listing, missing preset handling,
  missing window target handling, and region fallback behavior.
- Add no-UI tests for URL parsing that preserve the existing
  `import-pasteboard` behavior.
- Add documentation examples that are checked by lightweight parser tests where
  practical.
- Syntax-check all `.sh` samples with `bash -n`.
- Verify docs mention the automation sample maintenance rule and maintain expectations.

## Documentation And Sample Maintenance

When any automation command, option, URL route, AppleScript term, App Intent
action, App Entity, App Shortcut phrase, result field, error code, or output
behavior changes, update all affected contract surfaces in the same change:

- `Docs/AutomationServicePlan.md`
- `Docs/Automation/README.md`
- affected scripts in `Docs/Automation/SampleScripts`

The sample scripts are committed for GitHub users only. They are not shipped in
the app bundle and must not be added to app build products.

Sample basenames must stay procedure-stable across languages. Matching CLI,
AppleScript, and URL sample filenames identify the same workflow. CLI and
AppleScript samples must keep full procedure parity; URL samples must use the
same basename for every workflow supported by the v1 URL route contract.

App Intents are documented as native Shortcuts actions rather than GitHub sample
scripts unless a new shared command, option, route, term, result field, or
output behavior is added.

## Implementation Phases

### Phase 0: Documentation

- Complete: add this plan and user-facing automation docs.
- Complete: add GitHub-only sample scripts.

### Phase 1: In-Process Service Contract

- Complete: add request, result, error, output, and capability models.
- Complete: add `AutomationService` and `AutomationHost`.
- Complete: implement status, preset listing, and request validation.
- Complete: add unit tests for Codable round trips and validation.

### Phase 2: Preset Execution

- Complete: implement `runPreset` through the service.
- Complete: support output to editor, clipboard, file, floating reference, and
  none.
- Preserve current missing-window replacement and region fallback behavior when
  interaction policy allows prompts.

### Phase 3: Primitive Screenshot Commands

- Complete: implement fullscreen, frontmost-window, fixed region, interactive
  region, and interactive window captures.
- Complete: keep interactive region/window behind explicit interaction policy.
- Return `unsupportedFeature` for scrolling and connected-device automation
  until those workflows have their own hardening pass.

### Phase 4: URL Scheme Adapter

- Complete: add versioned `snipsnipsnip://v1/...` automation parsing.
- Complete: preserve `snipsnipsnip://import-pasteboard`.
- Complete: keep capture URL outputs to editor, clipboard, float, or none; use
  one explicit, validated `/export/current` route for file output.
- Complete: add docs for URL examples and safety rules.

### Phase 5: AppleScript Adapter

- Complete: add scripting dictionary and command handlers.
- Complete: map AppleScript commands to the same request models.
- Complete: return JSON text with status, request ID, output paths, warnings,
  and error codes.

### Phase 6: CLI Helper

- Complete: add `snipsnipsnipctl` source.
- Complete: support status, presets list/run, capture fullscreen,
  frontmost-window, fixed/interactive region, interactive window, repeat last,
  document open, and export current.
- Complete: support `--json`, structured errors, documented exit codes, output
  path handling, overwrite, private capture, editor, clipboard, and float
  outputs.
- Complete: support capture destination, explicit appearance, composition
  layout/comparison/template settings, and composition export format
  identifiers.

### Phase 7: Documentation And Help

- Complete: add user-facing automation documentation with examples.
- Complete: add in-app Help coverage for Apple Shortcuts actions and how they
  differ from keyboard shortcuts.
- Complete: update feature planning documentation when automation ships.

### Phase 8: App Intents

- Complete: add App Intents as a fourth adapter over `AutomationService`.
- Complete: register the intent client through `AppDependencyManager`.
- Complete: add Shortcuts actions and preset entity support for existing v1
  automation commands.

### Phase 9: Multi-Capture Composition Automation

- Complete: add backward-compatible request fields for capture destination,
  optional append-after item targeting, and output appearance.
- Complete: add layout/comparison command models, composition payload/error
  models, and `supportsComposition`.
- Complete: add template application by stable ID or exact name and dedicated
  Add Capture, Replace Item, and Export Composition App Intents.
- Complete: keep CLI, AppleScript, URL, App Intents, docs, and sample contracts
  in exact parity.
- Complete: expose `--after-item-id`, AppleScript `afterItemID`, URL `after`,
  and the matching App Intent parameter across every capture-producing command;
  validate active items and return `staleDestination` for in-flight target
  changes.
- Complete: make AppleScript and CLI await authoritative service completion,
  report the exact affected `itemID`, and reserve accepted results for
  interactive workflows.
- Complete: use URL `item` as the canonical replacement target spelling while
  continuing to accept legacy `replaceItemID`.
- Complete: add GIF, APNG, MP4, and self-contained HTML format identifiers.
- Complete: make side-by-side Comparison HTML interactive with Show Both,
  Before, and After controls while retaining a two-image no-JavaScript
  fallback.
- Complete: route direct, preset, repeat, and interactive capture completion
  through generation-scoped new/append/replace intents, with exact-item
  replacement and verified direct-capture mutation results.
- Complete: dispatch layout/comparison commands through a focused composition
  port as one undoable editor change, returning composition summaries,
  `updatedComposition`, and actionable composition error codes.
- Complete: resolve explicit Plain/Styled appearance in the shared output
  writer; route static, animated, HTML, and editable `.sss` formats to their
  matching exporters; and return structured unsupported-combination and
  oversized-output errors.

## Recommended MVP

The first usable automation release should include:

- `status`
- `listCapturePresets`
- `runPreset`
- `capture fullscreen`
- `capture frontmost window`
- outputs: open editor, copy rendered image, save PNG/JPEG/PDF
- adapters: URL scheme first, then AppleScript, then CLI if structured result
  transport is ready

This gives users useful automation while keeping the service small enough to
test and keep aligned with the existing app model.
