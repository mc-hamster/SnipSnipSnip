---
description: "Workspace instructions for implementing SnipSnipSnip as a local-first macOS screenshot, annotation, automation, presentation, clipboard, and screen-recording app."
---

# SnipSnipSnip Instructions

## Scope
- Keep the app runnable after every change.
- Keep cleanup work behavior-preserving unless the task explicitly asks for a feature or UX change.
- If a user-visible feature, workflow, or label changes, update the in-app Help guide in the same change so Help matches the shipped behavior.

## Architecture
- Keep capture, preview, editor, rendering, export, and support code in separate modules.
- Use a non-destructive annotation model. Do not flatten annotations into the screenshot except when copying or exporting.
- Keep the base screenshot separate from annotation state.
- Route undoable editor mutations through command types rather than ad hoc view mutations.
- Keep view, controller, renderer, and app-model responsibilities narrow. Prefer extracting helpers or small collaborator types over growing monolithic files.

## Product Scope
- Treat screenshot capture, annotation, presentation styling, clipboard history, automation, screen recording, connected-device capture, UI Map, screen ruler, screen inspector, recovery, archive, and export workflows as first-class product areas.
- Keep feature areas bounded. Avoid routing new behavior through `AppModel` or `EditorController` when a focused coordinator, service, model, renderer, or store can own the responsibility.
- Screenshot capture includes region, window, frontmost-window, fullscreen, repeat, timer, scrolling, connected-device, and Screen Inspector snips when the relevant build flags allow them.
- Preserve the full existing editor toolset, including multi-select, grouping, alignment, snapping, ellipse, line, freehand, highlighter, highlight, text, callouts, measurement, spotlight, image overlays, style controls, rotation, layer ordering, and blur/pixelate/solid redaction.
- Keep the project sandbox-friendly. Accessibility support powers UI Map, scrolling capture, and accessibility-assisted workflows, but region and fullscreen capture must not depend on Accessibility.

## Automation Maintenance
- If any automation command, option, URL route, AppleScript term, result field, error code, or output behavior changes, update `Docs/AutomationServicePlan.md`, `Docs/Automation/README.md`, and affected scripts in `Docs/Automation/SampleScripts` in the same change.
- Keep automation sample scripts GitHub-only; do not add them to app build products.
- Keep automation sample basenames procedure-stable across languages. CLI and AppleScript samples must keep full procedure parity; URL samples must use the same basename for every procedure exposed by v1 URL routes.
- Keep shell samples syntax-checkable with `bash -n`, and update automation contract tests when parser, route, result, permission, privacy, or output behavior changes.

## Quality
- Prefer small, testable value types for geometry and editor state.
- Add or update tests when changing geometry, command, or rendering logic.
- Prefer helper extraction over repeating shape-switch logic across annotation operations.
- Avoid maintaining parallel display/export implementations when a shared geometry or style helper can express the same behavior.
- Consolidate shared test utilities and factories instead of copying pixel, image, or snapshot helpers across test files.
