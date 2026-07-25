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

- [ ] A new install follows Welcome, Capture Access, Try Your First Snip, Clipboard History, Discover More, Keep Ready, and Ready.
- [ ] First-run completion requires Screen Recording and an explicit Enable or Keep Off Clipboard History choice.
- [ ] Skip Tutorial bypasses only the guided capture.
- [ ] A permission restart resumes at First Snip without losing choices.
- [ ] Replay reflects current choices and never blocks on the Clipboard decision.
- [ ] Capability cards and Accessibility setup appear only for workflows present in the build.
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

- [ ] Tool, Fit, Layers, Redaction, color, selected-state, and Presentation controls announce semantic labels and values.
- [ ] Tab and Shift-Tab traverse annotations from front to back.
- [ ] Space selects exclusively; Shift-Space toggles additive selection; Escape returns focus to the canvas.
- [ ] Return starts editing text and callouts.
- [ ] Arrow keys move by 1 px; Shift-arrows move by 10 px.
- [ ] Option-arrows resize by 1 px; Shift-Option-arrows resize by 10 px without crossing minimum size.
- [ ] VoiceOver custom actions cover select, toggle, edit, delete, duplicate, layer ordering, and group or ungroup where applicable.
- [ ] Accessibility frames remain aligned after zoom, pan, crop, and window resize.
- [ ] Annotation type, visible text, selection, layer position, and geometry are announced.
- [ ] Redacted pixels and hidden redaction content are never announced.
- [ ] Layers remains fully usable for selection, ordering, grouping, and deletion.

## Plain and Styled output

- [ ] Edit prioritizes Copy Plain, Plain output groups, Float Plain, and Drag Plain.
- [ ] Presentation prioritizes Styled actions and exposes Plain alternatives.
- [ ] Styled is unavailable until a Presentation style or scene is configured.
- [ ] Transparent Styled output forces PNG; Plain JPEG and PDF remain available.
- [ ] Plain filenames end in `-edited`; Styled filenames end in `-styled`.
- [ ] Save panels identify Plain or Styled output.
- [ ] Export completion announces format, appearance, destination, and provides Reveal.
- [ ] Automation resolves Styled only when Presentation is enabled and otherwise resolves Plain.

## Video and Guide

- [ ] Video play or pause, trim start, trim end, and playhead expose time values.
- [ ] Adjustable video controls respond to keyboard increments and stay clamped.
- [ ] Guide steps expose inclusion, order, duration, caption, markers, and selection.
- [ ] Guide reordering, multi-selection, marker adjustment, and export are keyboard reachable.
- [ ] Guide export reports progress, cancellation, completion, and errors without color-only cues.

## Library, Settings, and auxiliary windows

- [ ] Settings tabs are General, Capture, Presets, Editor & Output, Shortcuts, Recording, Guide, Library, and Privacy.
- [ ] Library Snips and Clipboard pages preserve their selected state and expose all controls in reading order.
- [ ] Retention accepts 1 and 180 days, rejects or clamps out-of-range values, and Reset Defaults restores 30 days.
- [ ] Capture shortcuts shown in menus and the reference match current preferences.
- [ ] Known macOS shortcut conflicts produce nonblocking text warnings.
- [ ] Native Open and Save panel shortcuts win while a panel is active.
- [ ] Command-W minimizes eligible windows, orders out auxiliary windows, closes Clipboard History, and never terminates or discards a document.
- [ ] History and Clipboard previews expose semantic content, pin or collection state, filters, restore, and destructive-action context.

## Sign-off

- [ ] Standard edition automated suite.
- [ ] Pro edition automated suite.
- [ ] Capability-combination build matrix.
- [ ] VoiceOver owner sign-off.
- [ ] Keyboard-only owner sign-off.
- [ ] Visual accessibility owner sign-off.
- [ ] Help and documentation owner sign-off.
