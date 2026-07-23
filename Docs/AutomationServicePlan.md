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
- GitHub-only sample scripts under `Docs/Automation/SampleScripts`.

## Goals

- Provide a stable, product-level automation contract for capture, presets,
  export, clipboard, document opening, and permission preflight.
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
    case guide(GuideAutomationCommand)
}
```

Guide v1 adds start (window, app, interactive region, or display), pause, resume, manual step, stop, open `.sssguide`, and export (PDF, GIF, APNG, three MP4 variants, images, or ZIP). Interactive Guide regions are constrained to the display where selection begins and cross-display rectangles are rejected; normal screenshot-region automation remains unchanged. Window and app Guides resolve and follow the current source geometry without changing the persisted automation command. All adapters use the same Guide payload and explicit errors for no active Guide, an already-active Guide, no steps, unavailable source media, and failed finalization. Guide control does not add a parallel service or bypass busy-state, permission, privacy, or configured-destination rules.

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
}
```

`saveEditableDocument(.sss)` must preserve the existing redaction warning
semantics. When the request has `interactionPolicy == .never` and the document
contains redactions, the service should fail with `confirmationRequired` instead
of saving an editable package that retains original pixels.

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
snipsnipsnipctl export current --format png --output ~/Downloads/current.png
```

Exit code guidance:

- `0`: success
- `64`: invalid request
- `69`: feature or target unavailable
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
  Internally, command handlers should bridge to async service execution without
  blocking long-running work on detached global state.
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
snipsnipsnip://v1/capture/region?rect=100,100,640,480&output=editor
snipsnipsnip://v1/capture/region?interactive=1&output=editor
snipsnipsnip://v1/capture/window?output=clipboard
snipsnipsnip://v1/repeat-last?output=editor
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
  repeat-last workflows, or outputs that present UI such as `openEditor` and
  `floatReference`.
- Register the live `AutomationIntentClient` with
  `AppDependencyManager.shared` during app startup.

Initial App Intents:

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

Supporting types:

- `CapturePresetEntity` is backed by `AutomationService.listCapturePresets`.
- App enums map Shortcuts choices to existing automation output, export format,
  fullscreen display, delay, cursor, and UI Map values.
- File output accepts an absolute POSIX path or `file://` URL string, then maps
  to the existing `AutomationOutput` file validation. The sandboxed App Store
  build rejects unattended destinations outside Downloads with
  `permissionDenied`; interactive save panels and the unsandboxed
  direct-download Pro build retain their existing destination behavior.
- `AppShortcutsProvider` advertises common capture phrases and uses
  `AppIntents.AppShortcut` explicitly so it does not collide with the in-app
  keyboard shortcut catalog.
- Opening `.sss` documents uses `IntentFile` with the SnipSnipSnip document
  package type.

## Permission And Privacy Rules

- Never capture pixels without Screen Recording permission.
- Never attempt scrolling capture or UI Map metadata capture without the
  Accessibility permission required by the existing feature.
- Never start Guide without Screen Recording and Accessibility permission.
- Do not grant extra permission because a request came from CLI, AppleScript,
  URL, or App Intents.
- Do not persist screenshots, OCR text, clipboard content, annotation text, or
  UI Map content in automation logs.
- Private Capture should be available as an automation option for screenshot
  requests that should skip archive checkpoints, recycle-bin retention, and
  background OCR indexing.
- Editable `.sss` output retains base screenshot pixels, annotation state, and
  hidden UI Map metadata. External automation docs must tell callers to use
  flattened image/PDF output when privacy flattening matters.

## Testing Strategy

- Unit-test request decoding for CLI JSON, AppleScript records, URL paths, and
  App Intent parameter mapping.
- Unit-test permission preflight decisions for each capture target and output.
- Unit-test result mapping so adapters preserve error codes.
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
- Complete: keep URL outputs to editor, clipboard, float, or none.
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
