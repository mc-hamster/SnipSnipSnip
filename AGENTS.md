---
description: "Workspace instructions for implementing SnipSnipSnip as a phase-scoped macOS screenshot and annotation app."
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

## Current Phase Rules
- Capture modes for this repo are region, window, and fullscreen.
- Phase 2 tools must remain supported.
- Phase 3 adds multi-select, grouping, alignment, snapping, ellipse, line, freehand, highlight, callouts, a style system, and an expanded redaction system.
- Keep the project sandbox-friendly. Accessibility support is optional enhancement, not a hard dependency for region and fullscreen capture.

## Quality
- Prefer small, testable value types for geometry and editor state.
- Add or update tests when changing geometry, command, or rendering logic.
- Prefer helper extraction over repeating shape-switch logic across annotation operations.
- Avoid maintaining parallel display/export implementations when a shared geometry or style helper can express the same behavior.
- Consolidate shared test utilities and factories instead of copying pixel, image, or snapshot helpers across test files.