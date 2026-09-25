# 1.2 Usability Refinement Backlog

Originally reviewed September 24, 2026 against commit `817bb9a`, including the pending Auto Crop improvements. The user subsequently approved implementation of items **1 through 7**. Those changes are now implemented in the working tree; the numbered findings below preserve the original evidence and acceptance criteria.

The revised order separates release blockers from the usability improvements worth funding. The original six P1 / six P2 split overstated the required scope and gave specialized Guide defects too much weight relative to the everyday screenshot workflow. The ranks below are a strict execution order, with no ties.

**Only #1 and #2 should block shipment:** sharing unrelated or stale output, and saving failures that users cannot see. Resolve those two first. **The planned usability scope is #3 through #5:** a clear screenshot completion path, usable windows on smaller displays, and Guide Save that preserves editing context. These are the three investments that should define the refinement work in this backlog.

**Original cut line: after #5; approved scope now includes #6 and #7.** Both are implemented as small corrections alongside #1–#5. Items #8 through #11 belong after 1.2. Item #12 needs user validation before deciding whether to change it at all. If capacity shrinks, preserve #3 as the primary usability outcome, narrow #4 to ensuring controls remain onscreen, and move #5 to the next update. The proposed ranks are product judgments based on the code paths; reach and frequency have not been measured with usage data.

Effort is relative: S is a focused correction and M crosses a few collaborators. The former large layout proposal is deliberately narrowed for this release; a full responsive-layout overhaul is outside the committed scope.

This pass inspected capture, screenshot output, document switching, composition intake, Clipboard History, Settings, video review, Guide editing/export, and recovery code. The Mac was locked, so no live walkthrough was possible. Source-confirmed behavior is distinguished from usability hypotheses below. An existing app process was left running; no app-hosted tests were launched. A standalone Swift check confirmed the filtered-reorder index problem.

| Order | Release decision | Work | Why it earns this position | Effort |
| --- | --- | --- | --- | --- |
| 1 | Block shipment | Bind Guide Share to the current document and revision | Can silently deliver the wrong content; the recipient may see an older version or another Guide | M |
| 2 | Block shipment | Show Guide autosave failures and a recovery action | A failed save needs an immediate explanation so people can preserve their work | S–M |
| 3 | Main 1.2 outcome | Finish a screenshot and return to Capture without a destructive detour | Improves the common capture → annotate → copy → capture cycle; strongest expected recurring benefit | M |
| 4 | Bounded 1.2 fix | Keep windows and essential actions inside the available display area | Affects users whose work area cannot accommodate the current minimums; controls must remain reachable | M |
| 5 | Planned 1.2 fix | Preserve Guide undo, selection, and search through Save | Saving is a routine action and should not interrupt editing; narrower reach than the screenshot loop | M |
| 6 | Approved small correction | Guard drag reordering while Guide search is active | Incorrect behavior, but a specific path with an undo/clear-search workaround; use a small guard before a full reorder redesign | S for guard |
| 7 | Approved small correction | Rename exported “Internal Note” | Cheap correction of a misleading label; does not justify expanding release scope | S |
| 8 | After 1.2 | Keep the current document until Open/Import succeeds | Requires a discard-then-cancel sequence; less frequent than normal completion and Save | M |
| 9 | After 1.2 | Navigate Settings search to the matching control | Helpful during configuration, with manual browsing already available | M |
| 10 | After 1.2 | Keep Guide setup/export choices temporary until committed | Surprising Cancel behavior, but less recurring than the editing actions above | M |
| 11 | After 1.2 | Add zoom/pan to Guide review | Helps precision work on a subset of Guides; useful but not necessary for the first refinement release | M |
| 12 | Validate first | Return focus after keyboard clipboard copy | Current stay-open behavior is intentional; changing it may inconvenience repeated-copy users | S–M if validated |

## Implementation status

| Item | Implemented behavior | Regression coverage |
| --- | --- | --- |
| 1 | Guide export receipts carry editor-session identity and content revision. Share/Copy/Reveal recheck the receipt synchronously; edits and session switches invalidate it, and late completions cannot attach to another Guide. | Current revision, reopened project, document close/switch, late completion, logo replacement, and Advanced Step Edit tests. |
| 2 | Persistent, announced Guide Changes Not Saved banner with Retry and Save As. Save errors preserve edits and pause automatic retries. | Failed write, recovery to a new destination, preserved edits/undo, and accessible recovery-action layout tests. |
| 3 | Back to Capture writes and verifies a Recent Snips checkpoint before closing. Explicit Discard remains in Screenshot Actions. Private Capture retains Save/Discard/Cancel. Failure or a concurrent edit keeps the editor open. | Unsaved and saved screenshots, editable-state round trip, private work, storage failure, and concurrent edit tests. |
| 4 | Main-window minimums and frames fit the available display, including title-bar space. Guide setup, Advanced Step Edit, Guide export, and Video export sheets have bounded sizes and reachable completion controls. Screenshot/Video exit and output actions remain outside secondary horizontal scrolling. | Small/offset display and sheet geometry tests; hosted screenshot command-row and Guide error-banner checks at smaller sizes. |
| 5 | Guide writes run serially off the main actor. Save/Save As retain the active controller, selection, search, and undo history while rebasing media and recording the saved revision. Newer edits remain dirty and get a subsequent autosave. | Save/Save As, undo/redo, media rebasing after removing the source, concurrent editing, and switching Guides during a save. |
| 6 | Drag and arrow reordering are disabled during Guide search. Clear Search restores normal reordering. | Guarded filtered move, clear-search reorder, and Undo. |
| 7 | Step Note replaces Internal Note and explicitly says that it appears in previews and exports. Output behavior is unchanged. | Help, Workflow Lexicon, inspector wording, and string-catalog consistency review. |

Help, Design Language, and Workflow Lexicon match the implementation. Existing Auto Crop work is preserved. Items #8–#12 remain outside this change.

Validation: the app and unit/UI test targets compile with `xcodebuild build-for-testing`. Thirteen isolated checks using the production layout policies and export-receipt model pass without launching an app. `git diff --check` and string-catalog JSON validation pass. App-hosted tests and a live visual walkthrough are still pending because the user-owned app process remains running; the repository’s single-instance guard was preserved. Compilation does not establish that those runtime acceptance checks pass. The relevant new suites are `GuideUsabilityTests`, `ScreenshotCompletionTests`, and `UsabilityLayoutTests`, alongside the expanded `DocumentWindowPresenterTests` and existing Guide/recovery suites.

The original numbered details follow in the same strict priority order.

## 1. Bind Guide sharing to the current document and revision

**User path:** Export Guide A, revise its caption or redactions, then use Share. Alternatively, open Guide B and use the still-available Share menu. The action uses previously exported files, without identifying their document or revision.

`lastGuideExportURLs` is cleared when a new export starts and filled when it finishes. Installing another Guide and editing the current Guide do not clear or invalidate it. Share and Copy Files use that array directly. The toolbar is enabled solely because the array is nonempty. An export that completes after switching documents has the same association problem.

**Refinement:** Track the originating Guide and revision. Either export the current revision before sharing or clearly identify the action as sharing the previous export. Never present another Guide's files as the current Guide's output.

**Acceptance:** Export A, edit A, open B, and finish an A export while B is open. Each path must identify the correct output and cannot silently share stale or unrelated files.

Evidence: [Guide output state and actions](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+GuideExport.swift), [Guide installation](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+GuidePersistence.swift), [toolbar](../SnipSnipSnip/Guide/UI/GuideEditorView.swift). Key lines: GuideExport 55, 91, 125–132; GuidePersistence 59–78; GuideEditorView 838–853.

## 2. Surface Guide autosave failures with recovery actions

**User path:** Edit a saved Guide whose destination becomes unavailable or unwritable.

The autosave catch assigns `controller.notice = "Autosave paused: …"`. The Guide editor does not render `notice`; its only other use in the inspected source is an export-success assignment. The edited-state indicator may remain, but the person gets no explanation that saving failed or what to do next.

**Refinement:** Present a persistent, accessible save-status notice with Retry and Save As. Clear it only after successful recovery or explicit dismissal, and preserve edits throughout.

**Acceptance:** Inject a write failure, verify a visible and announced warning, recover to a writable destination, and confirm the saved state and notice update correctly.

Evidence: [autosave failure](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+GuidePersistence.swift), line 102; [notice declaration](../SnipSnipSnip/Guide/Editor/GuideEditorController.swift), line 14; [Guide UI](../SnipSnipSnip/Guide/UI/GuideEditorView.swift).

## 3. Give the common screenshot loop a safe completion path

**User path:** Capture, annotate, Copy or Export, then return to Capture. The screenshot/video exit control is Discard, which invokes the unsaved-changes workflow. A new screenshot remains unsaved as an editable document even after successful rendered output. Guide uses Back for the same close handler, adding a terminology difference.

The underlying distinction between editable Save and rendered Export is valid. The friction is requiring that distinction to be resolved on the routine path back to capture.

**Refinement:** Make the ordinary non-private screenshot return path retain recoverable work and offer a clear way back. Keep deliberate Discard separate, and retain explicit decisions for private work. Do not mark editable documents saved merely because output succeeded. Video/Guide changes require their own durable retention semantics first.

**Acceptance:** Capture → annotate → copy → return → capture again without a confusing destructive decision, while the previous non-private screenshot remains recoverable. Explicit editable saves and Private Capture retain their documented meaning.

Evidence: [Discard labels](../SnipSnipSnip/Editor/EditorView.swift), lines 400–405; [close and unsaved-state logic](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+EditorSession.swift), lines 129–132 and 410–434; [Guide Back](../SnipSnipSnip/Guide/UI/GuideEditorView.swift), around line 777.

## 4. Fit the available work area and keep completion actions visible

Screenshot and video windows enforce a 1240 × 600 point minimum; Guides enforce 1280 × 800. The minimum-size bridge expands the frame to that minimum even when it exceeds the display's visible area. Guide setup also uses a fixed 760 × 730 sheet. This constrains smaller/scaled displays and side-by-side work.

The screenshot command rows separately use fixed-width content in horizontal scroll views with hidden indicators. Output follows history, arrangement, zoom, and inspector controls, so reducing the window minimum alone would leave important actions offscreen.

**1.2 scope:** Clamp windows and setup sheets to the visible work area and ensure Copy/Export, confirmation/cancellation, and exit actions remain reachable. Use existing inspector visibility and scrolling/overflow patterns where possible. Treat the existing minimum as a preferred comfortable size. A comprehensive rearrangement of every toolbar and polished side-by-side layouts are deferred.

**Acceptance:** Exercise a 1280 × 720 display and a smaller scaled work area. Windows fit, all sheets remain completable, and essential output/exit actions are visibly available. Check side-by-side use to document remaining constraints without making a full compact-editor redesign a release gate.

Evidence: [minimums and enforcement](../SnipSnipSnip/App/Presentation/DocumentWindowPresenter.swift), lines 5–17 and 233–278; [command rows](../SnipSnipSnip/Editor/EditorView.swift), lines 698–819; [Guide setup](../SnipSnipSnip/Guide/UI/GuideQuickStartView.swift), line 50.

## 5. Make Save preserve Guide editing context

**User path:** Edit a later step, press Command-S, then try Undo or continue editing that step.

Manual Save writes and reloads the package, constructs a new `GuideEditorController`, and installs it. The new controller initializes empty undo/redo stacks, an empty search query, and selection at the first step. Saving therefore changes the editing session, rather than simply preserving it on disk.

**Refinement:** Retain the active controller and history while updating persisted media references and the saved baseline. Preserve selected steps, search, and editing context through Save and Save As.

**Acceptance:** Edit step 5, save, and undo the edit; step 5 remains selected. Repeat with a search and multiselection active. Verify media URLs still refer to the saved package correctly.

Evidence: [manual Save](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+GuidePersistence.swift), lines 30–46; [controller initialization](../SnipSnipSnip/Guide/Editor/GuideEditorController.swift), lines 13, 22–23, 43.

## 6. Guard filtered Guide reordering

**User path:** Search for a subset of Guide steps and drag one result to reorder it.

The list displays `visibleSteps`, but its move handler passes the filtered offsets directly to a controller that moves entries in the full `project.steps` array. For `[A, B match, C, D match]`, dragging visible row 1 (`D match`) before visible row 0 passes source index 1. The current controller moves `B match`, leaving D unmoved.

**Small correction if capacity allows:** Disable drag reorder while search is active, with an explanation to clear the search first. The complete follow-up resolves source and destination from visible step IDs and defines how a move relates to hidden steps. Do not let that broader work displace the screenshot completion or display-fit work.

**Acceptance:** With search active, the guarded list does not accept an unsafe drag. Clearing the search restores normal reordering and Undo. For the later identity-based solution, search, drag one or several matching steps, clear the search, and undo; only the intended step IDs move. The standalone Swift check reproduced the incorrect current array operation; native drag behavior still needs live verification.

Evidence: [filtered list and move binding](../SnipSnipSnip/Guide/UI/GuideEditorView.swift), lines 46–49 and 93; [reorder implementation](../SnipSnipSnip/Guide/Editor/GuideEditorController.swift), lines 115–117.

## 7. Rename exported “Internal Note”

The step inspector calls the field Internal Note, while its subtitle says it is included with the step. The shared renderer includes the note in the visible card and still-image exports, and the export package includes it in Markdown. “Internal” suggests a private authoring note even though it is output content.

**Refinement:** Use a name such as Step Note and explicitly state that it appears in exports. Preserve current output behavior; a private-notes feature is not necessary for this refinement.

**Acceptance:** The editor label, Help, and exported preview agree that recipients can see the note.

Evidence: [field label](../SnipSnipSnip/Guide/UI/GuideEditorView.swift), lines 306–312; [shared renderer](../SnipSnipSnip/Guide/Rendering/GuideRenderer.swift), lines 26–39; [package Markdown](../SnipSnipSnip/Guide/Export/GuideExporter.swift), around line 1100.

## 8. Keep the current document until Open/Import succeeds

**User path:** With an unsaved screenshot open, choose File > Open or Import Image, choose Discard Changes, then cancel the file chooser. The active document has already been discarded before the chooser appears.

The Open/Import entry points call `performAfterHandlingUnsavedChanges` before presenting their panels. `discardChangesAndContinue` clears the current document before invoking the continuation. This need not permanently lose a non-private screenshot stored in history, but cancelling the proposed replacement still loses the active editing context.

**Refinement:** Select and validate the replacement first. Commit the switch only when a usable replacement exists, with the required unsaved/private-document decision at that point. Reuse the transactional behavior already present in creation intake.

**Acceptance:** Cancel the chooser or select an unreadable file after starting replacement. The original document, selection, and undo remain active; no recovery browsing is required.

Evidence: [Open/Import entry points](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+FileOperations.swift), lines 13–35; [discard continuation](../SnipSnipSnip/App/Workflows/Document/DocumentWorkflowModel+EditorSession.swift), lines 109–118. Existing transactional example: [creation intake](../SnipSnipSnip/App/Workflows/Creation/DocumentWorkflowModel+IntentCreation.swift), around line 318.

## 9. Make Settings search land on the setting

Search filters nine category names and manually maintained keyword strings. It does not search individual controls, highlight matches, scroll to a matching setting, or select a nested scope. Searching “clipboard” can select Snip Library while leaving its Snips page visible. Wording not in the category keywords can miss an existing control.

**Refinement:** Index control labels and useful synonyms, then navigate to the exact category, nested page, and section. Keep the search field, but make its results specific enough to act on.

**Acceptance:** Search “clipboard,” “auto copy,” “include cursor,” and “JPEG quality.” Each query exposes the corresponding control without a second manual search through the page.

Evidence: [search filtering/navigation](../SnipSnipSnip/App/CaptureAutomationSettingsView.swift), lines 54–57 and 120–126; [nested Snip Library selection](../SnipSnipSnip/App/CaptureAutomationSettingsView.swift), line 767; [keyword catalog](../SnipSnipSnip/App/SettingsNavigation.swift).

## 10. Make Guide Cancel discard the setup draft

Guide setup mixes local draft state with direct bindings to persisted `capturePreferences`. For example, changing Mask Secure Fields or Hide Desktop Icons and then cancelling still saves those defaults. The export sheet also changes `project.exportSettings.formats` through undoable document commands immediately; Cancel does not revert them and saved Guides can autosave the changes.

**Refinement:** Keep all setup/export choices in a temporary draft and commit at the explicit start/export point. If any setting is deliberately immediate, explain that behavior and use a lifecycle action that matches it. Match the transactional creation sheet and video export sheet patterns.

**Acceptance:** Change each option, cancel, and reopen; prior preferences, document state, and undo history remain unchanged. Starting the requested operation commits exactly one intentional set of changes.

Evidence: [Guide setup bindings and Cancel](../SnipSnipSnip/Guide/UI/GuideQuickStartView.swift), lines 177–193 and 229; [immediate preference persistence](../SnipSnipSnip/App/Workflows/Guide/GuideWorkflowModel.swift), line 60; [export format binding](../SnipSnipSnip/Guide/UI/GuideEditorView.swift), lines 935–944.

## 11. Allow precise Guide review without entering another editor

The main Guide canvas always scales the rendered card to fit. It has draggable action/number handles, but no zoom, actual-size, or pan controls in that review surface. Small interface text and exact marker placement can require opening Edit Screenshot, which previews a different editing scope.

**Refinement:** Reuse the existing preview viewport conventions for Fit, Actual Size, zoom, and pan in Guide review. Provide keyboard-adjustable marker positions as part of the same precision pass.

**Acceptance:** Read small screenshot text and adjust a marker on a large or tall step while remaining in Guide review. Verify pointer, keyboard, and VoiceOver operation, including the rendered card's caption and note.

Evidence: [Guide canvas](../SnipSnipSnip/Guide/UI/GuideEditorView.swift), lines 131–169; marker handles in the same file around line 550.

## 12. Reduce clipboard completion to copy, return, paste

Clipboard History intentionally stays open after copying; Help explicitly tells people to switch to the destination and paste. The window records the previously active application but does not use that value. This adds an app-switch action to a frequent reuse workflow.

**Refinement to validate:** Let the keyboard completion path copy and return focus to the previous application. Preserve a stay-open path for repeated browsing/copying. Returning focus does not require simulated paste or additional Accessibility access.

**Acceptance:** Invoke Clipboard History from another app, search/browse, complete the copy, then Command-V in the original app. Failed copies must keep the palette and explain the failure. Validate this change against people who intentionally make several copies in one palette session.

Evidence: [copy handler](../SnipSnipSnip/Clipboard/ClipboardManagerView.swift), lines 430–440; [recorded previous application](../SnipSnipSnip/Clipboard/ClipboardManagerWindowController.swift), lines 17 and 58; [documented stay-open behavior](../SnipSnipSnip/App/HelpGuideView.swift), around line 346.

## Smaller follow-ups after the ranked work

- **Explain partial image imports.** Guide image import silently skips undecodable images. Retain successful imports and identify failed files with a retry action, following composition intake's existing pattern. Evidence: `GuideEditorView.swift`, lines 118–127.
- **Narrow “Screenshot Format.”** The Settings picker binds to `screenshotDragOutFormat`, while explicit exports choose their format separately. Name the affected delivery path so selecting JPEG does not imply all screenshot exports will become JPEG. Evidence: `CaptureAutomationSettingsView.swift`, line 429; `DocumentWorkflowModel+FileOperations.swift`, lines 57–83.
- **Improve window-picker scanning.** The reusable list offers neither search nor an explicit empty-results explanation; its guidance also says “capture” when reused for Video. Verify this with many windows before prioritizing it. Evidence: `Preview/CaptureWindowPickerView.swift` and the picker wiring in `ContentView.swift`.

## Already addressed and excluded from this backlog

The reviewed tree already contains default editor opening, opt-in Capture Preview, Auto Copy off by default, direct solid Redact, clipboard draft-aware copy and deletion recovery, searchable/paged Snip Library, video review-first controls with preview retry, and pending direct Auto Crop access. These should not be proposed again as missing refinements.

Any implementation that changes workflow labels or behavior must update Help and the Workflow Lexicon in the same change. Layout changes must update the Design Language where they alter a reusable pattern. The persistence, reorder, document-switching, and export-association changes need focused regression coverage; visual and focus behavior still needs a live walkthrough when the Mac is unlocked.
