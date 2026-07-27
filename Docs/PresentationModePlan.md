# Presentation Mode Plan

> Historical implementation record. The user-facing Presentation workspace is
> superseded by the intent-driven Screenshot, Comparison, Steps, Collection,
> and optional Polish workflow. `ScreenshotPresentation`, Styles, and Scenes
> remain compatible internal rendering and persistence types; the primary UI
> calls them Look and Mockup under Polish.

## Current Phase

- Phases 0 through 6 are implemented for the underlying screenshot presentation engine.
- The current user-facing phase separates content purpose from optional finishing treatment and replaces generic Presentation navigation with intent-specific stages.
- This document remains the phase checklist and compatibility reference for future presentation work.

## Invariants

- Presentation is a screenshot export workflow, not an annotation tool.
- Presentation styling wraps the rendered screenshot and annotation output. It does not flatten into the base screenshot or annotation state.
- Applied presentation settings remain part of the editable document snapshot and continue to flow through undoable document commands.
- Presentation Styles are native Swift settings for simple polish. Presentation Scenes are sanitized SVG templates stored on disk and embedded into `.sss` as applied snapshots.
- Screenshot, Comparison, Steps, and Collection determine acquisition, arrangement, and editing controls. Polish contains Look and Mockup, and routine output follows the visible stage.
- User-facing workflow or label changes must be reflected in the in-app Help guide in the same change.
- Video presentation styling is out of scope for this plan.

## Phase 0: Planning Doc

Acceptance criteria:

- Complete: this file exists and lists the phased Presentation mode roadmap.
- Complete: the current phase is clear enough that implementation can resume without re-reading chat history.
- Complete: the invariants above remain explicit.

## Phase 1: First-Class Presentation Mode

Acceptance criteria:

- Complete: add `EditorWorkspaceMode` with `.edit` and `.presentation`; do not add Presentation to `EditorTool`.
- Complete: add a toolbar button labeled `Presentation` using existing toolbar button styles.
- Complete: entering Presentation mode selects the Select tool and shows the rendered presentation result as the main canvas.
- Complete: the inspector switches to a dedicated Presentation inspector while Presentation mode is active.
- Complete: Plain, Canvas, and Drop Shadow are built-in visual template tiles using the current screenshot preview.
- Complete: Copy, Share, drag-out, Float, and Export follow the active workspace and use the existing rendered output path.
- Complete: Help describes Presentation as a first-class editor workflow.

## Phase 2: User-Saved Presentation Templates

Acceptance criteria:

- Complete: add a `PresentationTemplate` model with `id`, `name`, `presentation`, `createdAt`, `updatedAt`, and `isBuiltIn`.
- Complete: built-in templates remain static; user templates persist globally outside `.sss` documents.
- Complete: add Save Current as Template, Rename, Duplicate, Delete, and Set as Default actions.
- Complete: applying a template routes through `SetPresentationCommand`.
- Complete: template library changes are app preferences, not document undo operations.

## Phase 3: Canvas Sizes And Backgrounds

Acceptance criteria:

- Complete: add a `PresentationCanvas` value for Original, Square, 4:5, 16:9, 9:16, 1.91:1, and custom pixel size.
- Complete: add subject fit, alignment, and scale controls.
- Complete: keep older documents compatible by decoding missing canvas fields to Original.
- Complete: expand backgrounds to Transparent, Solid, Two-Color Gradient, Radial Spotlight, and Blurred Screenshot.
- Complete: preserve existing `.transparent` and `.solid` behavior.

## Phase 4: Rendered Frames

Acceptance criteria:

- Complete: add `PresentationFrame` with None, Browser, macOS Window, Phone, and Tablet.
- Complete: render frames in code with CoreGraphics shapes; do not bundle external device or browser frame image assets.
- Complete: browser frames support editable title/address, light/dark chrome, traffic lights, and clean toolbar styling.
- Complete: macOS window frames support titlebar, traffic lights, light/dark titlebar, and screenshot screen insets.
- Complete: phone and tablet frames are generic vector devices with orientation, bezel color, screen radius, optional sensor housing, and rendered shadow.

## Phase 5: Presentation Workflow Polish

Acceptance criteria:

- Complete: add direct manipulation for subject placement and scale in Presentation mode.
- Complete: add center/safe-margin snapping and reset placement.
- Complete: keep Back to Edit first, label Presentation — Layout/Style/Scene persistently, and use simple WYSIWYG output labels instead of competing Plain and Styled command sets.
- Deferred by design: add template search/filter only if the built-in plus user-saved list becomes large enough to need it.
- Complete: update `FEATURE_LIST.md` now that Presentation mode has graduated from partial/deep-inspector status.

## Phase 6: Presentation Styles And SVG Scenes

Acceptance criteria:

- Complete: split native presentation state into `PresentationStyle` and optional `AppliedPresentationScene`.
- Complete: keep existing `.sss` files compatible by decoding missing `style` values from the older flat presentation fields.
- Complete: add `PresentationSceneStore` with configurable root, `Bundled` and `User` folders, bundled resource sync, manifest hashing, duplicate diagnostics, and user-modified bundled preservation.
- Complete: bundled scene identity comes from SVG metadata, not filenames.
- Complete: validate scene metadata, required `primaryScreenshot` image slot, `data-sss-slot` references, and `snipsnipsnip:` slot references.
- Complete: reject remote URLs, file URLs, embedded data URLs in source SVGs, scripts, event-handler attributes, `foreignObject`, and animation tags.
- Complete: add bundled example SVG scenes for Safari Browser Light, Phone Story Dark, Social Card Clean, and Mac Window Light.
- Complete: add Settings > General > Editor controls for choosing, revealing, resetting, and reloading the scenes folder.
- Complete: add Style and Scene tabs to the Presentation inspector with scene slot editing and diagnostics.
- Complete: render applied scenes from the embedded sanitized SVG snapshot so documents do not depend on the original source file.
- Complete: update Help, `sss-format.md`, and `FEATURE_LIST.md`.

## Phase 7: Intent-Driven Creation And Polish

Acceptance criteria:

- Complete: add transactional Create setup for Screenshot, Comparison, Process, and Combine Images while retaining direct one-action capture shortcuts.
- Complete: persist an undoable screenshot-document purpose and a non-dirty workflow resume stage with backward-compatible v7 defaults.
- Complete: replace the generic capture row with a contextual session row while a screenshot document is open.
- Complete: ask once when Screenshot receives its first additional source, then inherit purpose for later additions.
- Complete: filter content controls by purpose and expose the existing Style and Scene engines as Look and Mockup under optional Polish.
- Complete: keep routine output stage-based and WYSIWYG; preserve explicit Plain and Styled automation behavior.
- Complete: remove persistent item bounds until the Arrange canvas has explicit manipulation focus.
- Complete: update Help, accessibility QA, design language, format documentation, tests, and localization together.

## Test Checklist

- Complete: controller tests cover mode switching, Presentation state, Select-tool activation, template application, and template preference behavior.
- Complete: template tests cover save, rename, duplicate, delete, default, corrupt preference fallback, and built-in deletion rules.
- Complete: document tests cover backward-compatible presentation decoding and new field round-tripping.
- Complete: renderer tests cover canvas output size, transparent PNG behavior, expanded backgrounds, and rendered frames.
- Complete: scene tests cover bundled example validation, unsafe SVG rejection, bundled sync and update behavior, user-modified bundled preservation, scene rendering, and applied scene document round-tripping.
- Complete: Help and UI text cover goal-and-stage session labels, Back to Content navigation, the one-time first-add chooser, and stage-based WYSIWYG output behavior.
