# 1.2 Functionality Audit

This audit starts with presentation and extends through the application's existing
functionality. Its scope is correctness, privacy, data retention, and regression
coverage. It preserves the product's workflows and design; changes correct
confirmed broken behavior rather than introduce new features.

## Coverage

| Area | Review and validation scope |
| --- | --- |
| Look | All backgrounds; Original, preset and custom canvases; fit, alignment, scale, offset; corners and shadows; native browser, window, phone and tablet frames; light/dark chrome; bounded previews versus full output. |
| Mockup | Bundled and user SVGs; framing presets and manual adjustments; embedded text; source-size preservation; SVG affine transforms and viewBox mapping; safe local references; defaults, library reload and saved-document state. |
| Compositions | Auto, Row, Column, Grid, Freeform, Comparison and Steps; captions, titles, badges, connectors, weights, clipping, ordering, item editing, selection and undo/redo. |
| Comparison | Side by Side, Wipe, Overlay, Blink, Difference and Highlight Changes; registration, opacity, intensity, threshold, cue styles, poster selection and animation. |
| Output | PNG, JPEG, PDF, GIF, APNG, MP4, editable documents and Interactive HTML; transparency, redactions, pagination, cancellation, replacement failures, file promises, print and drag delivery. |
| Video | Preview/export geometry, shadow presets, cursor visibility, zoom targets, overlapping cuts, trim, audio, source rebasing, Save/Undo and media replacement. |
| Screenshot capture and editing | Region, Window, Screen, repeat, timer/presets, scrolling, connected-device and UI Map paths; privacy/context ownership, cancellation and retries; annotation batching, layering, snapping, grouping, cropping and redaction. |
| Guide | Setup, interactive automation privacy, start/cancel/finalize, private recovery exclusions, advanced-edit assets, duplicate/import undo, export cleanup and conflicting actions. |
| Documents and recovery | Save races, stale asynchronous completions, dirty-state tracking, History Open/Undo, private exit decisions, verified Recent Snips checkpoints, video recovery and retained editor state. |
| Supporting features | Clipboard and permissions, automation contracts and samples, Quick Controls, ruler, Screen Inspector, Settings search, launch behavior, updates and sanitized diagnostics. |

## Confirmed fixes

- Presentation previews preserve logical geometry while using bounded rasters;
  pointer offsets use the same coordinates as exported content. Polish edits no
  longer reset the viewport during a drag, and Escape cancels the gesture.
- Invisible shadows no longer reserve margins. Oversized subjects respect
  alignment. Device decorations and native title text remain visible in their
  intended positions.
- Captions use the allocated width and correct drawing coordinates. Above-image
  captions also shift comparison dividers and step badges. Difference controls
  honor intensity and cue choices, and comparison rasters respect rounded clips.
- PDF uses the selected Blink poster. HTML does not apply baked Difference
  intensity twice. Animated comparison exports generate transition frames on
  demand instead of retaining every full-size frame simultaneously.
- Composition, Video and promised-file output use replacement staging so failed
  encoding does not delete an existing destination. Imported templates reject
  unsafe numeric values before layout or numbering.
- Video shadow presets apply their actual parameters. Cursor playback resumes
  correctly after a gap, and overlapping cuts use the same kept ranges in
  preview and export.
- Annotation duplication and extreme layer ordering retain atomic undo behavior
  and stable selection order. Preset outcomes belong to one capture attempt and
  cannot leak into an unrelated capture after cancellation or failure.
- Saving records the state actually written, leaves newer edits dirty, and
  cannot relabel a replacement editor. Video saving retains editor state and
  Undo. History switching verifies outgoing recovery before replacement.
- Guide advanced edits, including redactions, travel with duplicated/imported
  steps. Private Region automation keeps its requested privacy. Conflicting
  actions retain a private or unsuccessfully checkpointed Guide.
- Rotated annotations/redactions use the same geometry in preview and export;
  processed redactions retain source alignment and include lower annotation
  layers. Curved arrow rendering and hit testing share one path. Measurement labels retain source-pixel lengths at every zoom, and their shared bounds keep labels inside Auto Crop.
- Private image Copy publishes concealment with its pixels; accepted concealed
  Paste makes the destination permanently Private before snapshot publication.
- Screen Inspector stops protected sampling when access is unavailable.
  Diagnostics use safe categories instead of arbitrary error messages that may
  contain document names.

## Validation record

Work stopped at the requested usage boundary after completing active fixes and their closing checks. No partial implementation remains. App-hosted suites run serially and respect the lifetime
lock and `LSMultipleInstancesProhibited`. An exact source snapshot under
`/private/tmp` avoids granting test hosts access to the user's Documents folder.

The initial presentation baselines passed 215 tests. The first combined corrected
presentation/Video/editor batch passed 220 tests. Integration covered performance
budgets, persistence, printing, drag output, WebKit HTML behavior and Video layout:
72 passed and two optional external-browser checks were skipped. The native
layout/editing walkthrough passed after the initial automation startup timeout
was resolved by the host's access change; no Developer Mode change was made.

The complete unit-target sweep ran 1,385 distinct cases in fresh serial batches:
1,382 passed, one newly added Undo fixture assertion failed, and two optional
external-browser tests were skipped. The fixture was corrected to compare the
editor's actual initialized state and passed in the closing regressions. Chrome
was then enabled explicitly and its isolated real-browser check passed; Firefox
is not installed.

Closing validation passed 211 rendering/save checks and 229 affected workflow
checks. The focused 96-case new-regression batch initially had one private-Paste
timing assertion; its corrected nonnil-editor wait passed in the 229-case run.
The final production sources compiled successfully in Debug and universal App
Store Release (Intel and Apple silicon). Release permission declarations and the
single-instance prohibition were verified. Repository hygiene, identity safety,
string-catalog parsing and 20 Python tooling tests passed.

A native layout/editing walkthrough passed. The subsequent complete 24-case
native presentation suite was cancelled at the user's request to stop; it is not
counted as completed. Before cancellation, its first-add chooser test hit an
intermittent XCTest hittability assertion: the chooser and button existed and
were visible in the recorded frame. A focused rerun passed on the unchanged
build. The UI runs also logged a SwiftUI view-update publishing warning; no new
UI refactor was started after the cutoff. Its fixture app and test runner both
exited. Result bundles
and generated images remain outside Git. The final usage check showed 7%
remaining; no usage reset was consumed.

## Boundaries of automated verification

- Mockup CSS transforms and nested SVG viewports continue rendering. Their
  direct-drag mapping is intentionally unavailable; the inspector remains usable
  and Help explains this limitation. Standard SVG affine transforms are mapped.
- Unit tests use deterministic services for native consent, capture hardware,
  connected-device trust and filesystem failure conditions. They do not certify
  first-grant macOS dialogs, every real display/device, or every external volume.
- Complete the native consent checks in `Tools/README.md` and the sandboxed
  destination checks in `Docs/ImageExportValidation.md` on the shipping build.
  Preserve the user's ordinary TCC state; use a clean test account for first-grant
  cases.

## Follow-up found at the usage boundary

The native Look preference-template audit remained read-only when the requested
usage threshold was reached. Preference templates currently bypass the numeric
validation used for `.sss` imports. Malformed/extreme saved padding, scale or
custom-canvas values can reach unsafe integer conversion/allocation paths.
No partial fix was started; follow up with shared native-value validation and
bounded rendering/diagnostic formatting while preserving valid capped outputs.
