# Accessibility Release QA

Use this checklist for every SnipSnipSnip release. Test the standard and Pro capability sets. Record the macOS version, build target, display arrangement, appearance, input devices, and any skipped item with its reason.

## Release gate

- [ ] Every essential workflow can be completed without a pointer.
- [ ] No actionable control has an empty label or announces a raw SF Symbol name.
- [ ] Focus order follows the visible macOS reading order.
- [ ] Opening and dismissing a sheet, popover, inspector, or auxiliary window transfers and restores focus predictably.
- [ ] Selection, permission, capture, progress, error, and export state changes are announced once.
- [ ] Help describes the shipped labels, Settings paths, and keyboard behavior.
- [ ] Automated accessibility, rendering, geometry, preference migration, and command tests pass in one non-parallel app host.

## Test environments

Repeat the essential workflow pass with:

- [ ] VoiceOver.
- [ ] Full Keyboard Access.
- [ ] Keyboard only, with VoiceOver off.
- [ ] Increase Contrast.
- [ ] Differentiate Without Color.
- [ ] Reduce Motion.
- [ ] Reduce Transparency.
- [ ] Light, Dark, and automatic appearance.
- [ ] Smallest supported main, Settings, inspector, and auxiliary-window sizes.
- [ ] One display and a mixed-scale multi-display arrangement.

## Onboarding and permissions

- [ ] A new install follows the three-step Capture Access, Clipboard History, and Ready sequence with an announced Step 1 of 3 progress value.
- [ ] First-run completion requires Screen Recording and an explicit Enable or Keep Off Clipboard History choice.
- [ ] Clipboard History uses a native radio group whose selected state is visible and announced; enabling it reveals “Also add screenshots that were not copied,” which defaults on for new and reset installations.
- [ ] A permission restart resumes at Clipboard History without losing choices.
- [ ] Replay presents one setup-summary page, reflects current choices, and never blocks on the Clipboard decision.
- [ ] The optional More Tools disclosure lists only workflows present in the build.
- [ ] The main-window discovery stage exposes each available action through pointer hover, keyboard focus, and VoiceOver without duplicating that guidance in a separate content card.
- [ ] The empty capture screen exposes the full permission card.
- [ ] An open screenshot, video, or Guide shows the compact permission strip; selecting it or attempting capture expands diagnostics.
- [ ] Permission status changes are announced.

## Capture surfaces

- [ ] Region capture announces instructions, dimensions, commit mode, Capture, and Cancel or precision controls.
- [ ] Keyboard creation, movement, and resizing remain usable in each region commit mode.
- [ ] Window and display targets expose names, selected state, and capture actions.
- [ ] Scrolling capture announces progress, pause or interruption, partial-result choices, and recovery actions.
- [ ] Screen Inspector exposes live or frozen state, zoom, coordinates, color, measurement, Snip, Set Up, Help, and Check Again.
- [ ] Missing Screen Recording never prevents ordinary keyboard access to remediation.

## Screenshot editor

- [ ] Tool, Fit, Layers, Redaction, color, selected-state, goal, stage, and Polish controls announce semantic labels and values.
- [ ] Tab and Shift-Tab traverse annotations from front to back.
- [ ] Space selects exclusively; Shift-Space toggles additive selection; Escape returns focus to the canvas.
- [ ] Return starts editing text and callouts.
- [ ] Every tool split control exposes named choices under a stable group name, and its main button visibly labels and announces the last-selected variant.
- [ ] A Numbered Arrow announces its number, selection state, layer position, and geometry; Move Earlier, Move Later, and Resequence are usable without relying on color.
- [ ] Resequence announces progress, supports Cancel and Done from the keyboard, and does not change layer order.
- [ ] Arrow keys move by 1 px; Shift-arrows move by 10 px.
- [ ] Option-arrows resize by 1 px; Shift-Option-arrows resize by 10 px without crossing minimum size.
- [ ] VoiceOver custom actions cover select, toggle, edit, delete, duplicate, layer ordering, and group or ungroup where applicable.
- [ ] Accessibility frames remain aligned after zoom, pan, crop, and window resize.
- [ ] Annotation type, visible text, selection, layer position, and geometry are announced.
- [ ] Redacted pixels and hidden redaction content are never announced.
- [ ] Layers remains fully usable for selection, ordering, grouping, and deletion.

## Intent-driven creation and multi-capture

- [ ] Create asks what to make before what to capture, uses native radio selection, reveals only relevant conditional questions, announces its live summary, and exposes exactly one default action plus Cancel.
- [ ] Direct Region, Window, and Screen shortcuts bypass Create as Screenshot without losing one-action behavior.
- [ ] While a screenshot document is open, the contextual session row announces purpose, progress, and one primary next action; global screenshot shortcuts retain their new-document meaning.
- [ ] The secondary Create entry remains keyboard- and VoiceOver-accessible with an open screenshot, and configured Polish is announced on its content-stage action without changing visible output.
- [ ] Adding the first extra image asks Compare, Add as Step, or Combine once. Cancel and capture failure return focus without changing purpose, content, or selection; later additions do not ask again.
- [ ] Screenshot exposes no layout controls; Comparison exposes no Grid or Steps controls; Steps exposes no comparison or general Combined Image tiles; Combined Image exposes Auto, Row, Column, Grid, Freeform, and compatible templates.
- [ ] Arrange draws no Polish subject frame or persistent unselected-item outlines. A selected boundary appears only after explicit canvas focus, hover remains neutral, and Differentiate Without Color preserves the distinction.
- [ ] Every item's accessibility frame is contained by and aligned with its rendered panel after zoom, pan, resize, Look changes, and Mockup wrapping.
- [ ] Arrange items announce caption or safe title, selected and shown state, order, Before/After role or step number, framing mode, and source-error state.
- [ ] Tab and Shift-Tab traverse items in export order, or front to back in Freeform; Space selects and Shift-Space toggles additive selection.
- [ ] Structured-layout arrows move spatial focus. In Freeform, arrows move by 1 px, Shift-arrows move by 10 px, Option-arrows resize by 1 px, and Shift-Option-arrows resize by 10 px.
- [ ] Return enters Edit Selected Capture, Option-Return enters Adjust Framing, Delete removes an item when more than one remains, and Command-D duplicates.
- [ ] Edit Selected Capture and Annotate Result announce their scope, move focus into the editor, expose Done, and return to the focused goal stage with the prior item selection, inspector position, viewport, and canvas focus restored.
- [ ] Edit Selected Capture exposes only that source's crop and annotations. Annotate Result exposes whole-canvas annotations and does not present Crop as if it changed an item.
- [ ] Items and Layers provide complete alternatives for reorder, resize, framing, replace, recapture, duplicate, include or exclude, and removal.
- [ ] The Layers window announces its Items, Result, and Capture scope picker; changing Capture with Previous, Next, or its picker updates the announced source without losing keyboard focus.
- [ ] Each Layers row exposes only currently valid VoiceOver actions. Move controls announce their direction, excluded and missing items announce their state without color, and Remove is unavailable when it would delete the final item.
- [ ] Structured-layout dividers expose adjustable values and keyboard increments. Freeform move and resize guides remain understandable with Differentiate Without Color.
- [ ] Comparison consistently announces Before and After. Show Both, Highlight Changes, Alternate, Overlay opacity, Wipe position and axis, Difference intensity, Blink poster, interval, playback, and Before/After controls expose semantic labels, values, and increments.
- [ ] Reduce Motion prevents automatic Blink playback while preserving manual Before and After controls and exported animation.
- [ ] Steps announces automatic number, caption, order, inclusion, and navigation. Reorder, exclusion, and removal announce the new numbering once.
- [ ] Private Composition is announced when first tainted and remains visibly and semantically Private after the source that caused it is removed.
- [ ] Cancelled add or replacement restores focus and makes no selection or document announcement implying success.
- [ ] Partial batch-import failure announces the exact Added and Failed counts, then exposes Retry Failed and Details without discarding successful items.
- [ ] Interactive HTML is tested in Safari with VoiceOver and keyboard only: heading structure, static numbered links, Previous/Next, Left/Right Arrow step navigation, Compare Using, comparison sliders, Wipe direction and direct-drag divider, Blink Play/Pause and manual sides, shared Zoom Out/Fit/Zoom In, focus visibility, Dark appearance, and browser zoom all remain usable.
- [ ] The Created with SnipSnipSnip footer link has an understandable accessible name, visible keyboard focus, and opens the canonical product website without replacing the exported composition.
- [ ] The embedded footer logo is decorative and omitted from the accessibility tree. Increased Contrast, forced colors, and print remove the outer line-and-dot background without changing content or navigation.
- [ ] Reloading or sharing an interactive comparison file with its URL fragment restores the chosen comparison view, zoom, and view-specific settings without browser storage.
- [ ] Interactive HTML honors `prefers-reduced-motion`, contains useful static navigation without JavaScript, and does not depend on color alone for Difference output.

## Current stage output

- [ ] Edit, Arrange, Steps, and Comparison Review expose simple Copy, Export, Share, Float, and Drag actions for the visible unwrapped content without Styled terminology.
- [ ] Polish exposes those same actions for the visible Look or Mockup and announces Polish once in the contextual session row.
- [ ] Edit Selected Capture and Annotate Result hide document output, Add Image, and reference actions until Done returns to the focused goal stage.
- [ ] Polish without a configured Look or Mockup exports the visible unwrapped content instead of failing.
- [ ] Transparent Polish output forces PNG while content-stage JPEG and PDF remain available.
- [ ] Content filenames retain the edited/composition convention; Polish filenames use the presentation convention for compatibility.
- [ ] Routine save and output controls describe the visible stage without presenting competing Plain or Styled choices.
- [ ] Export completion announces format, appearance, destination, and provides Reveal.
- [ ] Interactive HTML export announces completion and identifies the result as a single offline file.
- [ ] Automation retains explicit Plain and Styled behavior independently of the interactive stage vocabulary.

## Video and Guide

- [ ] Video play or pause, trim start, trim end, and playhead expose time values.
- [ ] Adjustable video controls respond to keyboard increments and stay clamped.
- [ ] Guide steps expose inclusion, order, duration, caption, markers, and selection.
- [ ] Guide reordering, multi-selection, marker adjustment, and export are keyboard reachable.
- [ ] Guide export reports progress, cancellation, completion, and errors without color-only cues.

## Snip Library, Settings, and auxiliary windows

- [ ] Settings tabs are General, Capture, Presets, Editor & Output, Shortcuts, Video, Guide, Snip Library, and Privacy.
- [ ] Snip Library Snips and Clipboard pages preserve their selected state and expose all controls in reading order.
- [ ] Retention accepts 1 and 180 days, rejects or clamps out-of-range values, and Reset Defaults restores 30 days.
- [ ] Global shortcuts shown in menus and the reference match current preferences.
- [ ] Known macOS shortcut conflicts produce nonblocking text warnings.
- [ ] Native Open and Save panel shortcuts win while a panel is active.
- [ ] Command-W minimizes eligible windows, orders out stateless auxiliary windows, closes Clipboard History and active Screen Tools, and never terminates or discards a document.
- [ ] History and Clipboard previews expose semantic content, pin or collection state, filters, restore, and destructive-action context.

## Sign-off

- [ ] Standard edition automated suite.
- [ ] Pro edition automated suite.
- [ ] Capability-combination build matrix.
- [ ] VoiceOver owner sign-off.
- [ ] Keyboard-only owner sign-off.
- [ ] Visual accessibility owner sign-off.
- [ ] Help and documentation owner sign-off.
