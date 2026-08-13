# SnipSnipSnip Feature List

Last reviewed: 2026-08-13

This document is the source of truth for what SnipSnipSnip and SnipSnipSnip Pro currently ship, what is only partially complete, and what is still missing. It is based on the current app source, shipped Help content, public docs, and test suite, not on older roadmap text.

SnipSnipSnip is already much larger than a screenshot MVP. It is a real screenshot app with a strong non-destructive editor and Snip Library, plus a usable first-generation Video recording and trim workflow. SnipSnipSnip Pro is the expanded product tier for Accessibility-assisted capture workflows: Guide creation, scrolling capture, connected iPhone/iPad screenshot capture, and UI Map capture. The strongest completed areas are screenshot capture, screenshot editing, editable document persistence, history/recovery, privacy defaults, multi-capture composition, screenshot presentation styling, drag-out sharing, practical MP4/GIF/APNG Video export, first-generation automation, accessibility foundations, and user-triggered support diagnostics export. The largest unfinished areas are Pro capture hardening, advanced Video polish, richer integrations and automation destinations, and full localization.

## Status Legend

- `✓ Done`: shipped, user-reachable, and meaningfully implemented in the current app.
- `~ Partial`: shipped in some form, but still limited, brittle, or missing important adjacent behavior.
- `x Not done`: no user-facing implementation was found in the current app.
- A `✓ Done` row does not mean best-in-class or feature-complete against premium competitors. It means the feature is genuinely present and useful today.

## Review Basis

This revision was checked against:

- App source in `SnipSnipSnip/App`, `Archive`, `Automation`, `Capture`, `Clipboard`, `Document`, `Editor`, `Export`, `Guide`, `Preview`, `Support`, and `Video`.
- Tests in `SnipSnipSnipTests`.
- User-facing Help in `SnipSnipSnip/App/HelpGuideView.swift`.
- Canonical product vocabulary in `Docs/WorkflowLexicon.md`.
- Public docs in `README.md`, `Docs/Automation/README.md`, `Docs/AutomationServicePlan.md`, `Docs/sssguide-format.md`, `sss-format.md`, `sssvideo-format.md`, `PERFORMANCE_PROFILING.md`, and `FASTLANE.md`.

The comparison lens for the "remaining gap" column is still the premium macOS capture market: CleanShot X, Shottr, Snagit, Loom, Kap, and Screen Studio. The status markers themselves are about the SnipSnipSnip product family only.

## Product Editions

This repo currently represents two related products:

- **SnipSnipSnip**: the App Store local-first screenshot and Video app. It includes Region, Window, Frontmost Window, Screen, Repeat Last, and timer screenshot capture; the screenshot editor; shared multi-capture Comparison, Steps, Combined Image, and interactive HTML workflows; Snip Library/history/recovery; Clipboard History; Screen Ruler; Screen Inspector; floating references; local export and sharing; and Region, Window, and Screen Video recording. It can open, edit, save, recover, and export existing `.sssguide` documents, but cannot record new Guides.
- **SnipSnipSnip Pro**: the advanced capture tier. It includes the same composition and presentation workflow, plus Guide creation and recording, scrolling capture, connected iPhone/iPad screenshot capture, and UI Map capture.

The current source also contains partial Pro connected-device recording plumbing. This is tracked separately from the standard recording product because the named Pro capture additions are scrolling capture and connected iPhone/iPad screenshot capture.

When a feature is Pro-only, this document calls that out explicitly. Shared features apply to both products.

## Executive Summary

SnipSnipSnip already ships all of the following in meaningful form:

- Screenshot capture for Region, Window, Frontmost Window, Screen, Repeat Last, timer, live window thumbnails, on-screen Window picking, three explicit Region commit modes, full-screen Spaces, and multi-display desktop composition.
- Intent-driven screenshot creation with durable Screenshot, Comparison, Steps, and Combined Image purposes; contextual Capture After, Add Step, and Add Image actions; reusable layouts; independent item and whole-result annotations; and offline interactive HTML.
- A discovery-focused capture home that groups Quick Capture, Create, Record, Screen Tools, and Clipboard History, previews each action on pointer or keyboard focus, and keeps Timer, Cursor, Private Capture, and Auto Copy state visible.
- Screen Ruler with multiple floating horizontal and vertical pixel rulers, configurable ticks and origins, live pointer distance, and capture-visible overlays.
- Screen Inspector as a floating live magnifier with 2x, 4x, 8x, and 16x zoom, optional pixel grid and crosshair, display-local pixel coordinates, center-pixel color readout, one-line point-to-point distance measurement, HEX/RGB copy shortcuts, freeze, resize, and Snip-to-editor.
- A non-destructive screenshot editor with crop, rectangle, ellipse, line, Arrow, Numbered Arrow, Status Mark, freehand, highlighter, highlight, text, callouts, ruler measurements, spotlight/dim, color sampling, OCR-backed Copy Text, image overlays, rotation, grouping, alignment, snapping, and blur/pixelate/solid redaction.
- Floating reference screenshots that pin rendered editor or history snapshots in lightweight always-on-top windows with opacity, visible zoom percentage, 1:1 actual size, fit, zoom, pan, resize-window-for-zoom, multiple-reference, and close-all controls.
- Editable `.sss` screenshot packages with base image, preview, JSON session state, undo/redo history, search metadata, and image overlay assets.
- Local-first Snip Library and recovery with autosave checkpoints, Recent Snips, Recycle Bin, archive size limits, custom archive location, OCR-backed search metadata, and Private Capture.
- Optional local-first Clipboard History for copied text, links, images, files, and SnipSnipSnip screenshots. It is off by default and requires an explicit onboarding or Settings opt-in before monitoring or Keychain-backed history access begins.
- Video recording for Region, Window, and Screen, with current-display, selected-display, and all-displays modes for Screen, plus MP4 capture, cursor and click options, live system-audio and microphone controls, storage guardrails, recoverable `.sssvideo` checkpoints, trim editing, poster frames, timeline thumbnails, and quality or size-limited MP4 export.
- Shared `.sssguide` document editing, recovery, saving, and export, with Guide creation for Window, App, single-display Region, and Display workflows available in Pro.

SnipSnipSnip Pro adds the following advanced capture workflows:

- Guide creation and recording with automatic action steps, optional source video/audio, local captions, recovery, and dedicated Guide automation.
- Scrolling capture with a dedicated scrolling overlay, Accessibility-driven target resolution, image stitching, cancel/done controls, partial-result handling, repeat support, and `.sss` scrolling metadata.
- Connected iPhone/iPad screenshot capture for trusted USB devices, with a live AVFoundation preview and normal screenshot editor, copy, save, history/archive, and Private Capture behavior through the existing screenshot pipeline.
- UI Map capture, a Pro-only structured screenshot workflow that saves available Accessibility metadata and local OCR supplement text into editable `.sss` documents for selected Window captures. Instead of treating a screenshot as pixels only, UI Map records visible interface element names, roles, identifiers, hierarchy, and geometry so the user can search the captured UI, inspect controls, export JSON, pin element overlays, and render those pinned overlays during copy, share, and export. This is a unique differentiator versus conventional screenshot tools.

The biggest unfinished areas are now clear:

- Pro scrolling capture works, but it is still a `~ Partial` feature because compatibility and diagnostics are not hardened enough to call it fully done.
- Pro connected iPhone/iPad screenshot capture works in the feature-gated build, but it remains `~ Partial` because it uses self-release capture plumbing and needs broader device, orientation, stream-interruption, and disconnect QA.
- Pro UI Map capture is implemented and intentionally Pro-only. It is still dependent on Accessibility availability and target-app AX quality, but the workflow is already user-reachable and materially different from pixel-only capture tools.
- Screenshot polish is first-class and shipped: goal-focused Arrange, Comparison, and Steps content stages feed an optional Polish stage with native Looks and SVG Mockups, reusable built-in and user templates, transparent/solid/gradient/spotlight/blurred backgrounds, browser/macOS/phone/tablet wrappers, WYSIWYG output, interactive HTML, and rendered drag-out sharing.
- Video recording is useful and now has explicit Finishing, unexpected-stop salvage, quit/restart decisions, and last-session recovery. Advanced post-production is still mostly `x Not done`: webcam, keystrokes, zooms, captions, aspect-ratio layouts, video overlays, speed controls, volume editing, and multi-clip editing.
- Workflow automation now has a first-generation external contract: customizable Global Shortcuts, a centralized Shortcuts settings tab, editor tool shortcuts, Clipboard History, a shared automation service layer, URL scheme routes, AppleScript commands, App Intents for Apple Shortcuts and Spotlight, and a bundled `snipsnipsnipctl` helper exist. Cloud/upload workflows, annotation mutation automation, Video automation, and richer automation destinations remain absent.
- Non-functional readiness is improved: privacy is strong, docs are solid for screenshots, performance profiling and local diagnostics export exist, and the accessibility foundation now covers semantic controls, keyboard annotation manipulation, synthetic canvas elements, video trim values, announcements, and visual-environment QA. Full localization and crash reporting remain open.

## Functional Feature Matrix

### Capture

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Capture home and workflow discovery | ✓ Done | With no document open, the main header groups Quick Capture, Create, Record, Screen Tools, and Clipboard History. Pointer hover after a short dwell or keyboard focus shows an animated explanation of the selected action; Reduce Motion uses a resolved static scene. Timer, Cursor, Private Capture, and Auto Copy state remains visible beside Ready. | Continue QA for minimum-size windows, keyboard focus, localization growth, and reduced-motion or reduced-transparency environments. |
| Region screenshot capture | ✓ Done | `ScreenCaptureService.captureRegion`, `RegionSelectionOverlay`, desktop composite snapshots, and drag selection are implemented. The nonactivating selection overlay remains usable above full-screen Spaces. Settings > Capture presents Capture Immediately, Show Capture & Cancel, and Show Precision Controls as one commit-mode choice while retaining compatibility with existing stored booleans and presets. Precision mode adds resize handles, width and height fields, aspect-ratio lock, arrow-key nudging, Return, and Escape. | No standalone saved-region library separate from capture presets. |
| Window screenshot capture | ✓ Done | Window listing, live thumbnails, picker UI, and direct window capture are implemented. | Better handling for sheets, transient popovers, transparent windows, and unusual shadow cases. |
| Frontmost window capture | ✓ Done | Dedicated Capture Frontmost Window flow exists in menus and Global Shortcuts. | Improve user feedback when the frontmost app has no eligible Window. |
| Capture Screen | ✓ Done | Screen screenshots support Current Display, Selected Display, and All Displays modes from Screenshot Capture settings. Missing selected displays fall back to the current display. Capture overlays remain nonactivating and usable in full-screen Spaces. | Broader manual QA for hot-plugged displays, rotated displays, Spaces, and mixed scaling. |
| Live window picker and thumbnails | ✓ Done | Main window picker supports refresh and auto-refresh; menu bar quick menu shows top windows with thumbnails. | Expand richer window grouping and edge-case targeting. |
| Pick-on-screen window targeting | ✓ Done | On-screen Window picking uses a nonactivating overlay that remains available above full-screen Spaces. | Better feedback for transient windows and ambiguous hits. |
| Multi-display support | ✓ Done | Desktop composite snapshots track capture and overlay coordinate transforms; tests cover offsets and adjacent displays. | Broader manual QA for rotated displays, Stage Manager, Spaces, and hot-plug changes. |
| Retina correctness | ✓ Done | Per-display and per-window scale handling exists, with geometry tests covering pixel mapping. | Add more visual regression coverage for mixed-scale outputs. |
| Pixel loupe during region capture | ✓ Done | Crosshair and magnifying-glass overlay modes are configurable. | Screen Inspector covers standalone inspection; the region-selection loupe still lacks live color readout and keyboard movement while selecting. |
| Screen Ruler | ✓ Done | Screen Tools and the menu bar can add multiple always-on-top Horizontal and Vertical rulers. Rulers support drag positioning, blue resize grips, click-to-cycle tick-edge and zero-origin placement, live pointer distance, and shared settings for opacity, tick spacing, major ticks, half markers, and mouse-distance labels. Visible rulers intentionally appear in Region and Screen captures. | No snapping, persistent named ruler layouts, guide lines, or calibrated units beyond pixels. |
| Screen Inspector floating magnifier | ✓ Done | Menu bar, Capture menu, and a customizable Global Shortcut open a resizable always-on-top live inspector with 2x, 4x, 8x, and 16x zoom, optional pixel grid and crosshair, display-local top-left pixel coordinates, center-pixel HEX/RGB readout, copy shortcuts, freeze, close shortcuts, one-line point-to-point distance measurement with Option-Command-M, and Snip-to-editor. Grid and crosshair default off. | Broaden manual QA across mixed-scale multi-monitor seams, rotated displays, Spaces, and permission edge cases. |
| Adjustable region before commit | ✓ Done | Optional precision region controls can pause after drag for handle resizing, numeric width/height entry, aspect-ratio lock, arrow-key nudging, Return to capture, and Escape to cancel. The default capture flow still captures on mouse-up. | No standalone saved-region library separate from capture presets. |
| Timer capture | ✓ Done | `CaptureDelay` supports off, 3, 5, and 10 seconds from menus. | No custom delay value or countdown overlay UI. |
| Repeat Last Capture | ✓ Done | Repeats Region, Window, Frontmost Window, and Screen capture when the target can still be resolved. Screen repeat uses the configured Current Display, Selected Display, or All Displays screenshot mode. SnipSnipSnip Pro also repeats Scrolling Capture when the target can still be resolved. Capture Presets provide named reusable targets for Region, Window, Frontmost Window, and Screen screenshots. | Scrolling and Connected Device captures cannot currently be saved as presets. |
| Explicit per-display screenshot selection | ✓ Done | Screenshot Capture settings expose Current Display, Selected Display, and All Displays modes for Capture Screen, with a selected-display picker only when needed. | More manual QA for display hot-plug and unusual arrangements. |
| Cursor capture in screenshots | ✓ Done | Optional cursor capture adds the current pointer as a non-destructive image overlay for Region, Window, Frontmost Window, Screen, and Repeat Last screenshots. The overlay can be moved, resized, faded, or deleted; Scrolling Capture excludes it while stitching. | Consider cursor-style replacement presets and click indicators. |
| Desktop cleanup for screenshots | x Not done | Standard screenshot workflows do not hide desktop icons or unrelated Window clutter. SnipSnipSnip Pro Guide has its own scoped Hide Desktop Icons option, but it does not apply to ordinary Screenshots. | A general screenshot cleanup workflow is still needed for polished demo-style capture. |
| Capture presets | ✓ Done | Presets can be created from the last eligible screenshot capture through the menu bar Presets menu, renamed, reordered, deleted, and managed from Settings > Presets. They rerun saved Region, Window, Frontmost Window, or Screen targets with the timer, cursor, display, Region, and Window UI Map options captured when the preset was created. Region presets fall back to repositioning when the saved display geometry is unavailable; Window presets can prompt for a replacement target when the saved Window is no longer available. | No preset-specific Global Shortcuts, import/export, destination rules, audio/Video preset support, Scrolling Capture presets, or Connected Device presets. |

### Pro Capture

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Scrolling capture | ~ Partial | SnipSnipSnip Pro includes a dedicated scrolling overlay, Accessibility-driven target resolution, image stitching, cancel/done controls, partial-result handling, repeat support, and `.sss` scrolling metadata, with stitcher tests. | Needs app/browser compatibility hardening, clearer user diagnostics, better fallback paths, and a broader manual QA matrix. |
| Connected iPhone/iPad screenshot capture | ~ Partial | SnipSnipSnip Pro lists trusted USB iPhone/iPad sources, distinguishes USB-connected devices that macOS is not exposing as streams, opens a live AVFoundation preview, captures the latest frame into the normal screenshot editor, and supports copy, save, editor opening, history/archive behavior, Private Capture rules, runtime interruption reporting, and support diagnostics summaries through the existing screenshot pipeline. | Uses self-release capture plumbing, supports one active connected-device session, depends on macOS exposing the trusted/unlocked device stream, does not use private device services, and still needs broader device/orientation/disconnect/manual QA. |
| UI Map window capture | ✓ Done | SnipSnipSnip Pro Window captures can asynchronously save available names, labels, identifiers, roles, positions, sizes, parent hierarchy, owning app, and OCR supplement text into `.sss` documents when the UI Map user setting is enabled. Capture is intentionally limited to selected Window captures and uses the captured Window identity rather than scanning Region or Screen captures. | Accessibility availability and target-app AX quality still determine how complete the element hierarchy is; broader manual QA across app frameworks is still needed. |

### Screenshot Editor And Annotation

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Non-destructive annotation model | ✓ Done | Base screenshot pixels, crop, and annotations are separate in `EditorSnapshot`, `Annotation`, renderer inputs, and `.sss`. | Keep this separation intact as new presentation features are added. |
| Command-based mutations | ✓ Done | `DocumentCommand` types drive add, update, delete, group, selection, and crop changes. | User-visible undo labels and future layer commands are still open. |
| Undo/redo | ✓ Done | `EditorController` keeps undo and redo stacks capped at 100 snapshots, persists their truncation state in `.sss`, and prunes composition assets no longer referenced after bounded history is loaded or trimmed. | More explicit user-facing Change History labels or grouping could still help. |
| Open existing image in the editor | ✓ Done | File > Import Image opens common image formats directly into the screenshot editor. | Could expand into batch or multi-page import later. |
| Rectangle | ✓ Done | Rectangle tool includes style editing, rounded corners, fill presets, and dashed or dotted strokes. | More style presets could still be added. |
| Ellipse | ✓ Done | Ellipse tool, style editing, and rendering are present. | Could add forced-circle behavior and more presets. |
| Line | ✓ Done | Line tool, model, hit testing, and rendering are present. | No elbow or curved connector variant. |
| Arrow | ✓ Done | Arrow tool supports curved arrows, single or double heads, multiple head styles, and inspector-managed labels. | No bend handles or richer direct manipulation for label geometry. |
| Numbered Arrow | ✓ Done | Numbered Arrow draws from a numbered tail badge toward its target and maintains a contiguous sequence per Screenshot, source-capture editing scope, or assembled result. The inspector supports badge styles, Move Earlier, Move Later, and a keyboard-accessible Resequence workflow. Numbering persists in `.sss` and renders through normal copy, export, share, and interactive HTML output. | It shares the regular Arrow geometry limits and has no separate direct-manipulation handle for badge placement. |
| Status Mark | ✓ Done | Status Mark provides Checkmark and X symbols with Circled, Cartoon, and Vintage treatments plus normal color controls. Marks remain editable and persist and render through the standard annotation pipeline. | The symbol and treatment library is intentionally small; there are no custom status glyphs. |
| Freehand | ✓ Done | Freehand drawing exists, with smoothing and simplification controls in the inspector. | No eraser mode, pressure styling, or point-editing workflow. |
| Highlighter | ✓ Done | Highlighter draws marker-style translucent freehand strokes and uses the shared smoothing, simplification, style, persistence, hit-testing, and rendering pipeline. | No pressure styling, eraser mode, or point-editing workflow. |
| Highlight | ✓ Done | Highlight tool renders rounded highlight regions. | No text-aware highlight mode. |
| Text | ✓ Done | Text annotations support typing, alignment, resizing-to-fit, and style editing. | No font family chooser, rich text spans, or spellcheck. |
| Callouts | ✓ Done | Numbered callouts support auto-increment, auto-renumber after deletion, text editing, leader lines, and step-guide copy. | Could add more layouts and more direct anchor editing. |
| Ruler measurement | ✓ Done | Measurement annotations support endpoint handles and rendered pixel labels. | No calibrated real-world units yet. |
| Spotlight/dim tool | ✓ Done | Spotlight annotation dims outside a focused oval or rectangle. | No presentation presets beyond the current effect controls. |
| Copy Text OCR tool | ✓ Done | OCR-backed Copy Text lets the user drag a screenshot region, review normalized text, and copy it. | No QR detection, language controls, or confidence review. |
| UI Map inspection and pinning | ✓ Done | SnipSnipSnip Pro UI Map documents expose a floating UI Map panel with hierarchy tree, search, type and Pinned Only filters, keyboard navigation, metadata details, JSON export, Show All, and pin/unpin controls. The UI Map Inspect toolbar tool shows selectable outlines on the screenshot; clicking pins or unpins an element, pinned overlays render in copy, share, and export, and typing after a pinned element starts a text annotation near it. AX elements render blue and OCR supplement text renders orange. | UI Map quality depends on the captured window's Accessibility exposure; non-window captures intentionally do not create new UI Map metadata. |
| Redaction: blur | ✓ Done | Non-destructive blur redaction is rendered and tested. Explicit editable `.sss` save/save-as warns once per editor session that original pixels remain and offers flattened PNG export. | No strip-redactions-from-editable-package workflow. |
| Redaction: pixelate | ✓ Done | Non-destructive pixelate redaction is rendered and tested. | No separate block-size control beyond current effect settings. |
| Redaction: solid | ✓ Done | Solid redaction mode is implemented, with the same editable `.sss` save warning as other redaction modes. | No strip-redactions-from-editable-package workflow. |
| Multi-select | ✓ Done | Marquee selection and additive or toggle selection are supported. Arrow keys nudge selected annotations by 1 px and Shift-arrow nudges by 10 px through undoable editor commands. | More keyboard-first selection expansion would help. |
| Group/ungroup | ✓ Done | Group IDs and group-aware selection behavior exist. | No visible layer tree or nested group UI. |
| Alignment | ✓ Done | Geometric alignment and text alignment are supported in the inspector. | No distribute-spacing, match-size, or align-to-canvas actions. |
| Distribution and equal-size layout tools | x Not done | Only core alignment commands are present. | Add distribute, match-size, and align-to-canvas actions. |
| Snapping | ✓ Done | Snap guides and rect snapping exist during move, resize, and draw. | No grid toggle, guide preferences, or snap strength controls. |
| Grid and custom guides | x Not done | No grid or custom guide system was found. | Add user-visible grid and guide controls. |
| Crop | ✓ Done | Crop Image supports canvas handles, numeric X/Y/Width/Height editing, Freeform plus fixed landscape/portrait aspect presets (1:1, 3:2, 2:3, 4:3, 3:4, 16:9, 9:16), Auto Crop, Padded auto-crop, reset crop, crop-aware export, crop refocus, and moving the crop with Select. | No canvas rotation, arbitrary canvas padding, or resize-canvas workflow. |
| Crop context aids | ✓ Done | Crop editing shows a loupe while dragging and supports dimming plus out-of-capture crosshatch settings. | These are editor-only aids, not screenshot presentation output. |
| Zoom and pan | ✓ Done | Zoom in/out, fit, actual size, pinch, scroll-wheel zoom, panning, and visible scroll tracks are implemented. | No minimap or per-document zoom restore. |
| Rotation | ✓ Done | Annotation rotation persists, renders, hit-tests correctly, and is editable in the inspector. | No direct on-canvas rotation handle. |
| Color picker | ✓ Done | Inspector-driven color sampling reads from the base screenshot and applies to stroke or fill. | No live capture-time color readout. |
| Image overlays | ✓ Done | Pasteboard and imported image overlays are editable annotations with resize, rotation, opacity, archive assets, and export/render support. | No blend modes or replace-image action. |
| Layer order / reorder | ✓ Done | Bring Forward (`⌘]`), Send Backward (`⌘[`), Bring to Front (`⌥⌘]`), and Send to Back (`⌥⌘[`) commands with Arrange menu, undo/redo support, multi-selection block reordering, and a standalone Layers window with selection sync, drag reorder, group/ungroup, z-order buttons, delete, and empty states. | Visibility toggles and layer locking are intentionally deferred until annotation metadata, `.sss` schema, rendering, hit-testing, and export behavior support them additively. |
| Combine screenshots on one canvas | ✓ Done | Create asks whether the user wants a Screenshot, Comparison, manual Steps sequence, or Combined Image. The selected purpose persists with the `.sss`, drives a contextual session bar, and filters the inspector to relevant controls. Capture, Import, Paste, Drag, Recent Snips, Snip History, and editable `.sss` sources remain available. Combined Image owns Auto, Row, Column, Grid, and Freeform; Comparison owns Side by Side, Overlay, Wipe, Difference, Highlight Changes, and Blink; Steps owns ordered captions, numbering, connectors, and pagination. Items retain independent crop and annotations plus a separate whole-result annotation layer. Adding any Private source permanently marks the document Private. | Keep purpose, destination, and layout compatibility in the release matrix as new sources and outputs are added. |
| Background and presentation tool | ✓ Done | The optional Polish stage contains Look and Mockup. Look provides transparent/solid/gradient/spotlight/blurred backgrounds, spacing, corners, and shadows; Mockup uses the existing sanitized SVG Scene engine. Content stages and Polish expose the same neutral WYSIWYG output actions, while explicit Plain and Styled terminology remains automation-only. | Add preset search/filter only if the built-in plus user-saved libraries become large enough to need it; continue visual QA for mockups and third-party destinations. |
| Floating or pinned screenshots | ✓ Done | Current rendered screenshots and history/recent/recycle-bin snapshots can be opened as always-on-top floating reference windows. Multiple references can be shown at once; each supports resizing, explicit handle-based moving, one-click close, opacity adjustment, visible zoom percentage, 1:1 actual size, pinch/scroll zoom, panning, fit/zoom controls, Resize Window for Zoom, and close-all from the Reference menu or menu bar extra. | Future work could add named reference sets, saved layouts, and a reference board. |

### Screenshot Output And Sharing

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Clipboard-first workflow | ✓ Done | Auto Copy retains its existing trigger behavior and uses the visible stage whenever it runs. Copy, export, share, float, and drag-out follow the visible Edit, Arrange, Review, Steps, or Polish stage; automation retains explicit Plain and Styled parameters. | No copy-as-file, copy-as-markdown, or cloud-link workflow. |
| Clipboard History manager | ✓ Done | Clipboard History is optional and off by default, with explicit onboarding and Settings opt-in before monitoring or Keychain-backed history access. The floating manager preserves compatible rich/plain representations and multi-item payloads for text, links, images, PDFs, and files; offers OCR-backed search, type/date/source/collection filters, a detail preview and text editor, semantic text recognition, pins, named collections, confirmed clearing, and Copy actions that preserve compatible original representations. | Source-app attribution remains best-effort because macOS does not identify the source of every copy. |
| Clipboard History shortcuts | ✓ Done | Command-Return copies the selected item, arrows move selection while search is focused, Escape clears search then closes, and Option-1 through Option-9 copy visible items. | These are intentionally local shortcuts; global item-number shortcuts would conflict with frontmost apps. |
| PNG export | ✓ Done | `ImageExporter` supports PNG output. | No destination presets or export rules. |
| JPEG export | ✓ Done | JPEG export uses the Settings > Editor & Output JPEG quality control, defaulting to 90%. A transparent Polish preview forces PNG without disabling JPEG or PDF while viewing a content stage. | No auto format choice, destination rules, or reusable export presets. |
| PDF export | ✓ Done | Single-image PDF export exists. | No vector-preserving annotation export. |
| Composition output | ✓ Done | Plain and Styled PNG/JPEG/PDF share the composition render pipeline; oversized rasters are preflighted with Scale to Fit or streamed one-step-per-page PDF choices. Steps also supports a reusable Steps per Page PDF setting. Blink static output defaults to After and deterministic GIF/APNG/MP4 preserves interval, crossfade, and loop choices with a disclosed 4,096 px animated cap. Comparison and Steps export as one offline interactive HTML file with losslessly optimized full-dimension PNGs, real progress and cancellation, atomic replacement, print/no-script fallbacks, metadata-stripped pixels, no source paths or capture metadata, no remote resources, and a hash-pinned deny-by-default Content Security Policy. The Comparison viewer supports Compare Using Side by Side, Wipe, Overlay, Blink, Difference, and Highlight Changes; Show Both/Before/After focus, synchronized zoom and Fit, persisted adjustments, Reduced Motion behavior, exact redaction-safe rendered results, and secondary Created with SnipSnipSnip attribution. | Keep raster-size, animation determinism, browser, VoiceOver, keyboard, reduced-motion, and large-file guardrail coverage in the release matrix. |
| Native share sheet | ✓ Done | Uses `NSSharingServicePicker` for rendered screenshot sharing. | No upload destinations. |
| Drag-and-drop export affordance | ✓ Done | Screenshot and video editors expose compact promised-file drag handles. JPEG screenshot drag-out uses the same JPEG quality setting as Export JPEG, and Polish drag-out uses the same renderer as the visible Polish preview. | Validate compatibility with more third-party destinations over time. |
| Metadata stripping and privacy-safe export | ✓ Done | PNG, JPEG, and PDF outputs are re-encoded and tests confirm source EXIF, TIFF, GPS, IPTC, and user metadata are not preserved. | Future upload flows should add destination-aware privacy confirmations. |
| Filename templates | ✓ Done | Save As and export suggestions use `ScreenshotFilenameTemplate` tokens for kind, source, time, width, height, and format. Content output uses `-edited` or composition-aware naming; Polish retains the compatible `-presentation` suffix on disk. | No per-destination rules or reusable export presets. |
| Cloud upload and share links | x Not done | No cloud backend or upload destination exists in the current app. | Add optional privacy-preserving upload workflows only if needed. |

### Persistence, History, Search, And Recovery

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Editable screenshot package | ✓ Done | `.sss` stores base image, preview, editable state, undo/redo, search metadata, and overlay assets. | More migration fixtures would further harden the format. |
| UI Map metadata persistence | ✓ Done | `.sss` documents preserve UI Map snapshots, element source (`accessibility` or `ocrSupplement`), capture diagnostics, and pinned UI Map element IDs. Documents with UI Map metadata continue to open safely when UI Map UI is unavailable or disabled. | Additional migration fixtures and large-hierarchy package tests would further harden long-term compatibility. |
| Public `.sss` format documentation | ✓ Done | `sss-format.md` documents format version 3, schema, overlay assets, privacy semantics, and compatibility rules. | Could still use sample package trees and more examples. |
| Undo/redo persistence | ✓ Done | `.sss` round-trips up to 100 undo and redo snapshots, records when older undo history was truncated, and excludes composition assets no longer referenced by the retained state. | No named checkpoints, snapshot diff view, or history compaction beyond the fixed bound. |
| Autosave checkpoints | ✓ Done | `DocumentRecoveryStore` keeps per-session checkpoints. | No richer checkpoint reason/diff labeling yet. |
| Last-session recovery | ✓ Done | Screenshot autosave checkpoints and Guide recovery remain available through their existing workflows, while Recover Last Session surfaces the last unsaved Video. Active Video quit and restart flows can keep recording in the background, cancel, or stop first; stop enters Finishing, salvages usable segments, writes a recovery checkpoint, and exits only after the checkpoint succeeds. Unsaved Video recovery remains until Save or explicit Discard. | Recovery keeps one last Video session rather than a browsable set of Video checkpoints; more UI-level interrupted-exit coverage would still help. |
| Recent Snips | ✓ Done | Shelved unsaved work remains available from the main UI and editor inspector. | No favorites, tags, or projects yet. |
| Snip History | ✓ Done | Archive-backed Snip History entries persist across sessions and support search. | Filtering by type, date, and source app is still missing. |
| Clipboard screenshot timeline | ✓ Done | Users can separately opt in to adding non-private completed screenshots to enabled Clipboard History, including when Auto Copy is disabled. Both Clipboard History and uncopied screenshot insertion are off by default. Private Capture screenshots are excluded. | Reveal-in-editor depends on the backing recoverable capture still being available. |
| Clipboard item persistence and pruning | ✓ Done | Versioned history metadata and representation assets are encrypted with AES-GCM using a Keychain-protected device key, migrated from the earlier plaintext format, excluded from Spotlight and backup, deduplicated without collapsing distinct rich representations, and pruned by retention, unpinned item count, storage target, and per-item size while preserving pinned entries. Damaged indexes are preserved and reported. | No iCloud sync or cross-device history by design. |
| Search annotation text | ✓ Done | Search metadata includes annotation text. | Search is still simple and could use indexing at large scale. |
| OCR-backed history search | ✓ Done | Background Vision OCR indexes captures for search, and Private Capture skips that indexing. | No QR detection, OCR language selection, or OCR confidence UI. |
| Recycle Bin | ✓ Done | Deleted entries move to the Recycle Bin and can be restored, permanently deleted, or emptied. New installs and Reset Defaults retain them for 30 days; Settings > Snip Library > Snips accepts 1–180 days, with load-time and runtime clamping plus legacy-default migration. | Could add stronger privacy/storage warnings. |
| Archive size cap | ✓ Done | Oldest checkpoints are pruned when the configured cap is exceeded. | No user-facing maintenance log yet. |
| Archive folder selection | ✓ Done | Custom archive location uses security-scoped bookmarks. | Repair tooling for stale bookmarks would help. |
| Private Capture | ✓ Done | Private Capture skips archive checkpoints, recycle-bin retention, Clipboard History ingestion, background OCR indexing, and content diagnostics for that session. Adding any Private source permanently taints its composition Private, including after the source is removed; the `.sss` retains that state while explicit save and export remain available. | Keep privacy labels and export reminders aligned across every new source and destination. |
| Editable video package | ✓ Done | `.sssvideo` stores source media, poster frame, trim state, and recording metadata. | Keep compatibility notes and migration examples current as the schema evolves. |
| Public `.sssvideo` format documentation | ✓ Done | `sssvideo-format.md` now documents package layout, schema, versioning, and compatibility behavior. | Add concrete sample package fixtures over time. |

### Guide

| Feature | Status | Current behavior | Remaining scope |
| --- | --- | --- | --- |
| First-class Guide workflow | ✓ Done | SnipSnipSnip Pro places Guide beside Screenshot and Record, supports Window, App, single-display Region, and Display setup, automatically follows moving/resized app windows across mixed-scale and rotated displays, and includes a noncapturable HUD, pause/resume, Manual Step, Undo Last, recovery, and a dedicated three-pane editor. The App Store edition hides creation and retains the editor for existing `.sssguide` documents. | Continue Pro compatibility testing across third-party apps and transient system UI. |
| Editable `.sssguide` format | ✓ Done | Format v1 keeps base PNGs separate from step sessions and optional pause-aware media segments, validates package paths/assets/dimensions, uses atomic replacement for user saves, incrementally commits recovery manifests, and has a public format specification. Segment capture rectangles preserve mixed-scale and rotated-display geometry. | Future versions must retain explicit compatibility gates. |
| Action-to-step capture | ✓ Done | Passive event observation classifies clicks, double-click coalescing, selections, scroll bursts, swipes, modifier shortcuts, manual steps, and coalesced non-secure text-entry bursts while ignoring repeats, own-app UI, out-of-source actions, and secure input. Printable typing works in custom/web editors; exposed field-value changes also detect paste, dictation, and input-method edits. Pre-event frames retain controls that close on action. Typed characters and secure values are never stored in the step caption. | Signed App Store builds still need broad cross-app validation because sandboxed event delivery and Accessibility quality vary by target app. |
| Local captions and privacy | ✓ Done | In Pro capture, safe Accessibility metadata creates immediate deterministic captions; Vision OCR is a fallback and Foundation Models can refine metadata/OCR text on device without receiving screenshots. Secure fields never retain values and receive editable solid masks. Private Guide disables OCR/AI refinement and content indexing. The App Store edition contains an unavailable caption backend and makes no Accessibility calls. | English-only; localization is intentionally not implemented. |
| Guide editing and design | ✓ Done | Shared by both editions: search, reorder, multi-select, duplicate, delete/restore, include/exclude, duration changes, draggable marker handles, redactions, screenshot Advanced Edit, reusable themes, logos, branding, and command-based undo/redo remain non-destructive. | Continue keyboard, VoiceOver, high-contrast, reduced-motion, and long-caption QA. |
| Guide export | ✓ Done | Shared by both editions for existing documents: PDF, Word, GIF, APNG, PNG/JPEG step images, ZIP/Markdown, Full Motion MP4, Action Highlights MP4, and Step Slideshow MP4 use shared rendering/media helpers, honest progress, disk-headroom checks, incremental rendering, streaming ZIP64, cancellation, and atomic output replacement. | Continue visual snapshot coverage on unusual third-party display/codec combinations. |
| Guide automation | ✓ Done | Identifiers remain decodable on every surface. In Pro, CLI, URL routes, AppleScript, and App Intents share start, pause, resume, Manual Step, stop, and dedicated export commands. In the App Store edition those dedicated requests return `proFeatureRequired` before permission or capture work, while generic `.sssguide` opening remains supported and the Guide App Shortcut is not advertised. | URL routes remain trigger-oriented. |
| macOS back-deployment | x Not done | Guide follows the app minimum of macOS 26 and uses the current ScreenCaptureKit, Vision, Accessibility, and Foundation Models stack. | macOS 14 back-deployment is intentionally not implemented. |

### Video Recording

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Record Region | ✓ Done | ScreenCaptureKit Region recording is implemented, with a single-display constraint for Region bounds. | No saved Regions, presets, or resize-before-record workflow. |
| Record Window | ✓ Done | Desktop-independent Window recording is implemented. | No robust retargeting when a Window moves, relaunches, or changes identity. |
| Record Screen | ✓ Done | Record Screen uses the configured Current Display, Selected Display, or All Displays mode. | Broader manual QA for hot-plugged displays, rotated displays, Spaces, and mixed scaling. |
| Explicit display selection for Video | ✓ Done | Record Screen supports Current Display, Selected Display, and All Displays modes from Video settings. | Broaden manual QA coverage for mixed scaling, rotated displays, and Spaces arrangements. |
| MP4 H.264 recording | ✓ Done | Recording writes MP4 through native ScreenCaptureKit recording output. | No HEVC or ProRes choice. |
| Quality presets | ✓ Done | Compact, Balanced, and High presets are implemented. | No user-facing bitrate estimator or custom preset editor. |
| Frame rate options | ✓ Done | 15, 30, and 60 fps are supported. | No custom fps or adaptive export-specific fps logic. |
| Cursor visibility | ✓ Done | Video settings expose cursor visibility. | No cursor replacement, smoothing, or idle-hide behavior. |
| Click highlighting | ✓ Done | Video settings expose mouse-click rings. | No custom styles, colors, or per-click editing. |
| System audio | ✓ Done | Optional system audio recording includes a live signal meter and a per-Video switch in the floating recording control, allowing the source to be included or muted during the active session without changing its default. | No app/source choice, mixing, gain, or post-recording audio editing. |
| Microphone narration | ✓ Done | Optional microphone recording includes permission flow, a live signal meter, and a per-Video switch in the floating recording control. | No input-device selection, gain, noise cleanup, or post-recording audio editing. |
| Floating recording control | ✓ Done | Recording a Video shows a floating control excluded from capture with elapsed time, Recording/Paused/Finishing status, Pause, Resume, Stop, live System Audio and Mic meters, and per-session audio switches. | Add keyboard stop/pause shortcuts and optional cancel-delete flow. |
| Pause/resume recording | ✓ Done | Active recordings support pause and resume from the floating recording control. | Add manual QA coverage for long pause/resume sessions with audio enabled. |
| Storage guardrails | ✓ Done | Temp cleanup plus minimum free-space checks exist before recording and export, and active recordings run live disk-pressure checks that safely stop and finalize when temporary storage drops below the safety floor. | Deeper ScreenCaptureKit stream reconstruction can still be added if macOS exposes more recoverable failure modes. |
| Unexpected-stop salvage | ✓ Done | If ScreenCaptureKit stops unexpectedly, the Video enters Finishing, validates captured segments, merges the usable set when possible, falls back to the longest usable segment if merging fails, and opens recovered footage instead of leaving a false Recording state. | A broken capture stream is finalized rather than reconnected in place; broader codec, audio, and long-session interruption QA remains useful. |
| Quit, restart, and Video recovery | ✓ Done | Quit during Recording or Paused offers Stop & Quit, Keep Recording in Background, or Cancel; restart offers Stop & Restart or Cancel. Stop waits for Finishing and a recoverable `.sssvideo` checkpoint before exit. Unsaved Videos are also checkpointed on normal exit and reopen from Recover Last Session until saved or explicitly discarded. | Recovery retains one last unsaved Video, not a multi-session Video recovery browser. |
| GIF and APNG export | ✓ Done | The video editor can export trimmed recordings as native animated GIF or APNG loops with preset-based frame sampling and ImageIO encoding. | Tuned for short documentation/demo loops; long-form video should stay MP4. |
| Webcam or camera overlay | x Not done | No camera or PiP layer was found. | Needed for more premium async/demo use cases. |
| Keystroke overlay | x Not done | No keystroke visualizer exists. | Useful for tutorials and product demos. |
| Auto zoom | x Not done | No cursor-analysis or click-driven zoom system exists. | Large gap versus polished demo recorders. |
| Manual zoom timeline | x Not done | No zoom track or zoom keyframe model exists. | Needed for professional demo editing. |
| Cursor smoothing and motion polish | x Not done | Recording relies on raw ScreenCaptureKit cursor output. | Add post-processing or overlay-based cursor rendering. |
| Captions or transcription | x Not done | No transcription or caption editor was found. | Needed for accessibility and sharing polish. |
| Background studio and device frames | x Not done | Video export preserves the recording frame directly. | Add aspect-ratio canvas, background, rounded device frame, and shadow systems. |

### Pro Recording

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Connected iPhone/iPad recording | ~ Partial | SnipSnipSnip Pro currently has feature-gated connected-device recording plumbing that opens the same live USB device preview, starts and stops MP4 recording from the device stream, reports runtime preview interruptions, then opens the result in the normal video editor for trimming, poster frames, timeline thumbnails, `.sssvideo` packaging, and export. | This is not part of the core SnipSnipSnip product, and it is separate from the named Pro screenshot capture additions. It uses self-release capture plumbing, supports one active connected-device session, does not forward touch input, does not guarantee protected-content capture, and needs more manual QA for disconnects, orientation, stream interruptions, and device availability edge cases. |

### Video Editor And Export

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Playback preview | ✓ Done | `AVPlayerView`-based playback preview exists in a polished preview stage with status metadata and spacebar playback. | Keyboard coverage beyond playback is still light. |
| Trim start and end | ✓ Done | Timeline handles edit normalized trim bounds non-destructively. | No split, delete-range, or ripple editing. |
| Timeline thumbnails | ✓ Done | Timeline filmstrip thumbnails are generated from the recording duration. | More adaptive caching and long-video tuning would help. |
| Poster frame | ✓ Done | Poster frame generation and persistence exist in `.sssvideo`. | No arbitrary export thumbnail workflow beyond current poster logic. |
| MP4 quality export | ✓ Done | Quality-based MP4 export exists for Compact, Balanced, and High. | No HEVC or export queueing. |
| MP4 size-limited export | ✓ Done | Deterministic size-capped MP4 export exists for 25 MB, 100 MB, and 250 MB targets. | UI-side estimates before export would help. |
| Export progress | ✓ Done | Export progress is surfaced in the UI for MP4 and animated exports, including a cancel action for in-flight exports. | No background export handling. |
| Export cancellation | ✓ Done | The export progress overlay now allows canceling an active export operation. | Add regression coverage for repeated cancel/retry flows across quality and size-limited exports. |
| Aspect-ratio export layouts | x Not done | Exports keep the original recording frame. | Add 16:9, 9:16, 1:1, 4:3, 3:4, Auto, and custom layouts. |
| Speed controls | x Not done | No speed-up or slow-down segments were found. | Add time remapping for dead air and demos. |
| Volume editing | x Not done | No per-track gain, mute, fade, or cleanup tools were found. | Add audio editing if recording becomes a stronger product pillar. |
| Video callouts and annotations | x Not done | Screenshot annotation tools are not applied over the video timeline. | Add timed overlays, highlights, arrows, and redaction. |
| Multi-clip projects | x Not done | One recording maps to one `.sssvideo` document. | Add clip lists and timeline composition only if product scope expands. |

### Automation, Integrations, And Workflow

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Menu bar app | ✓ Done | SnipSnipSnip runs as a menu bar app with capture actions, Screen Ruler, Screen Inspector, Clipboard History, and window presentation. | Could still be streamlined for power users. |
| Main-window workflow navigation | ✓ Done | Quick Capture, Create, Record, Screen Tools, and Clipboard History provide direct access to primary workflows; Capture, Help, Open, Import Image, Save, Export, Share, and pasteboard commands remain available in the app menus. The no-document state explains focused or hovered actions without opening another sheet. | Tool-by-tool command coverage is still incomplete. |
| Global Shortcuts | ✓ Done | Global capture and Screen Inspector shortcuts remain background-only and are user-customizable per action from Settings > Shortcuts. | Consider optional frontmost behavior toggles for power users later. |
| In-app shortcuts | ~ Partial | Capture, open, save, export, share, copy, select all, group, ungroup, layer ordering, help shortcuts, single-key editor tool shortcuts, and arrow-key annotation nudging exist. Settings and Help share a centralized shortcut catalog covering capture, app, editor, layers, Screen Inspector, and Clipboard History shortcuts. | Fully customizable in-app editor/app shortcuts remain intentionally out of scope. |
| Settings window | ✓ Done | Settings is task-oriented: General, Capture, Presets, Editor & Output, Shortcuts, Video, Guide, Snip Library, and Privacy. Snip Library has Snips and Clipboard pages; Reset Settings is in General; UI Map is under Capture > Advanced; direct Presets navigation remains available. | Deeper workflow automation settings are still limited. |
| Clipboard ignored-app workflow | ✓ Done | Clipboard settings can ignore currently running apps, choose an app bundle from Applications, or ignore recent clipboard source apps with one click. Default ignored apps include Apple Passwords and common password managers such as 1Password, Bitwarden, Dashlane, LastPass, KeePassXC, Keeper, RoboForm, Enpass, mSecure, NordPass, Proton Pass, KeeWeb, MacPass, Strongbox, Secrets, Buttercup, and SafeInCloud. | Source-app detection is best-effort because macOS pasteboard data does not reliably expose origin for every copy. |
| Permission diagnostics and remediation buttons | ✓ Done | Settings and main UI expose permission diagnostics plus remediation buttons, Help guidance, and a local Export Diagnostics flow for support. | Keep the diagnostics schema current as more support-relevant subsystems are added. |
| Drag-out sharing | ✓ Done | Screenshot and video editors expose compact promised-file drag handles. Screenshot drag-out flattens current edits and presentation styling; video drag-out exports the current trimmed MP4 with the remembered preset after the drop is accepted. | Add richer destinations only if local file drag-out proves insufficient. |
| Floating reference workflow | ✓ Done | Reference > Float Current Screenshot and the editor Float button create lightweight always-on-top views without duplicating files or modifying documents. History preview overlays can float archived snapshots for comparison or active reference work. | Add saved reference layouts only if active workspace referencing becomes a larger product area. |
| Automation service contract | ✓ Done | `SnipSnipSnip/Automation` defines a shared v1 automation contract for requests, commands, outputs, result envelopes, payloads, permission preflight, privacy options, validation, error codes, host dispatch, and output writing. Capture, preset, and repeat commands can create a document, append to the active composition, or replace an exact item. Composition commands set layouts, configure A/B comparison, apply templates, and export Plain or Styled PNG/JPEG/PDF/GIF/APNG/MP4/HTML output or an editable SSS document, with structured composition results. Guide control/export remains available where supported. Sandboxed App Store unattended file output is validated against Downloads before writing. | V1 intentionally does not expose annotation mutation, Scrolling Capture presets, Connected Device capture, recording a Video, cloud upload, or direct Window lookup by title/name. |
| CLI automation | ✓ Done | The `snipsnipsnipctl` helper target is embedded under `Contents/Library/Helpers` and uses the AppleScript/Apple Events bridge as the v1 return-capable transport. The sandboxed executable has its own bundle identity and a narrow scripting access group limited to SnipSnipSnip. It supports JSON output; capture append/replace destinations; composition layout, compare, template, and current-export commands; the existing screenshot and Guide commands; privacy and overwrite controls; and documented exit codes. | Requires Apple Events permission and is documented for full-path invocation or user-created shell aliases rather than installing into `/usr/local/bin`. |
| AppleScript automation | ✓ Done | `SnipSnipSnipAutomation.sdef` exposes matching capture destination/item, composition layout, comparison, template, and export parameters alongside status, preset, repeat, document, screenshot, and Guide commands. Every command maps to the same shared automation contract. | AppleScript returns JSON text for structured results and does not expose annotation mutation. |
| URL scheme automation | ✓ Done | Versioned `snipsnipsnip://v1/...` capture routes accept append/replace destinations and item identifiers; composition layout, compare, template, and current-export routes expose the same validated model. Existing status, preset, capture, repeat-last, and Guide routes remain available, and `snipsnipsnip://import-pasteboard` remains reserved for share-extension imports. | URL automation is trigger-oriented; callers needing structured results should use CLI or AppleScript. |
| App Shortcuts and App Intents | ✓ Done | `SnipSnipSnip/Automation/AppIntents` registers dedicated Add Capture to Composition, Replace Composition Item, Set Composition Layout, Apply Composition Template, Configure Comparison, and Export Composition intents over the shared automation service, alongside status, preset, capture, repeat, document, screenshot-export, and Guide intents. The App Store edition retains the Guide intent identifier for compatibility but does not advertise its App Shortcut; invoking it returns `proFeatureRequired`. | V1 App Intents do not expose annotation mutation, Scrolling Capture presets, Connected Device capture, recording a Video, cloud upload, or direct Window lookup by title/name. |
| Upload integrations | x Not done | No S3, Slack, issue tracker, webhook, or cloud destination integration exists. | Keep optional and privacy-preserving if added later. |
| Template workflows and Polish presets | ✓ Done | Combine Images exposes compatible arrangement templates. The optional Polish stage contains reusable Look presets, document-saved variants, and SVG Mockups loaded from Bundled and User folders under a configurable Presentation Scenes root. Applying editable content or Polish state is undoable; library management remains outside annotation editing. | Video brand templates remain separate future work. |
| In-app Help guide | ✓ Done | Help is rich, searchable, user-facing, and maintained alongside the Create goals, contextual screenshot sessions, Polish, recording, Clipboard History, UI Map, automation, permission, and troubleshooting behavior. | Stronger troubleshooting diagnostics and guided support flows could still be added. |
| README and product docs | ✓ Done | `README.md` covers features, privacy, permissions, formats, and build/test instructions. | Add release/download assets and more visuals when distribution stabilizes. |
| Public `.sss` format docs | ✓ Done | `sss-format.md` documents the screenshot package format clearly. | Keep current as format evolves. |
| Public `.sssvideo` format docs | ✓ Done | `sssvideo-format.md` now documents the editable video package format. | Keep docs aligned with any future format version bumps. |

## Non-Functional Requirements

### Privacy And Security

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Local-first processing | ✓ Done | README and current architecture explicitly position capture, OCR, rendering, export, history, and document handling as local-first; there is no cloud dependency in the current app. | If cloud is ever added, keep it strictly opt-in. |
| Permission clarity | ✓ Done | Settings and Help explain Screen Recording and Pro-only Accessibility, microphone, and system-audio permissions. The App Store edition reports Accessibility as unavailable, never prompts for it, and removes Guide/UI Map/scrolling setup surfaces. | Keep troubleshooting copy aligned with macOS permission UI changes. |
| Redaction safety | ✓ Done | Redactions stay non-destructive in the editor and flatten only on copy, export, or share. Docs warn that editable packages retain original content, and explicit editable `.sss` save/save-as prompts once per editor session when redactions are present. | No strip-redactions-from-editable-package workflow. |
| Archive privacy | ✓ Done | Archive and recycle-bin behavior are documented, and Private Capture suppresses checkpoints, recycle-bin retention, and background OCR indexing. | Could add clearer privacy badging in history. |
| Composition privacy taint | ✓ Done | A composition becomes permanently Private when any Private Capture source is added. Removing that source does not clear the document flag. Private compositions skip archive checkpoints, Recent Snips, Recycle Bin, Clipboard History ingestion, OCR indexing, diagnostics, and telemetry; interactive HTML remains offline and omits source paths and capture metadata. | Keep future import and automation sources from bypassing the same document-wide taint rule. |
| Clipboard privacy | ✓ Done | Clipboard History is local-only, optional, and off by default. It does not monitor clipboard changes or load/request its Keychain-protected history key until enabled, skips concealed and transient pasteboard types, excludes Private Capture screenshots, and ignores Apple Passwords plus common password managers by default. Ignored apps can be managed through automated app-picker and recent-source flows rather than manual bundle ID entry. | Pasteboard source app attribution remains best-effort on macOS. |
| UI Map privacy | ✓ Done | SnipSnipSnip Pro UI Map capture is build-flagged, user-controlled, Window-only, and user-initiated. Region, Screen, Scrolling Content, Video, Connected Device, and Screen Inspector captures do not request Accessibility because of UI Map. Hidden UI Map metadata stays local to `.sss`; flattened image exports exclude hidden metadata, while pinned UI Map overlays are visible pixels by design. | Future editable-document sharing flows could add explicit strip-UI-Map export choices. |
| Security-scoped archive access | ✓ Done | Custom archive locations use bookmarks. | Add repair flow for stale bookmarks over time. |
| Sensitive logging hygiene | ✓ Done | Internal logging exists for scrolling capture, thumbnail history preview loading, and video export. The user-triggered diagnostics export includes sanitized app, permission, display, storage, editor, connected-device, launch-at-login, and status summaries without screenshots, OCR text, clipboard contents, annotation text, document data, window titles, or raw paths. | Keep new diagnostics fields summary-only and redacted by default. |

### Performance And Scalability

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Repeatable profiling workflow | ✓ Done | `PERFORMANCE_PROFILING.md` and `./bin/profile-performance` run the same declared profiling set around renderer, export, archive search, storage-budget, capture, scrolling stitcher, and multi-capture composition paths, plus optional traces. The script preserves the single-instance contract and runs one nonparallel app-host. | Keep reference-machine baselines current as hardware, OS, and capture APIs change. |
| Broad performance budgets and coverage | ✓ Done | `PerformanceBudgetCatalog` defines named budgets for capture entry, screenshot render/export, indexed archive search, video export planning, live storage checks, 200-item composition layout, capped 4K append/comparison previews, twelve-item grid preview, full PNG composition export, and preview/export memory. Deterministic fixtures cover 2, 10, 50, and 200 mixed-aspect items across every composition layout. | Treat hard ceilings as release limits rather than regression allowances; retain Instruments traces with release sign-off. |
| Large archive scalability | ✓ Done | Archive history maintains a persistent `search-index.json`; search, presentation refresh, recycle-bin views, and pending-recovery summaries use indexed checkpoint metadata instead of rescanning every package. | Future work can add richer token ranking or faceted filters if the archive UI grows. |
| Long recording resilience | ✓ Done | Recording still performs preflight cleanup/free-space checks, and active recordings now run live disk-pressure checks that safely stop and finalize when temporary storage drops below the safety floor. | Deeper ScreenCaptureKit stream reconstruction can still be added if macOS exposes more recoverable failure modes. |
| Memory management | ✓ Done | Screenshot file export streams PNG/JPEG/PDF writes through temporary files instead of materializing full export data in memory; renderer caches, thumbnail downsampling, temp cleanup, and video guardrails remain in place. | Continue profiling unusually large captures and long videos as part of release validation. |
| Async correctness and cancellation | ✓ Done | Archive refresh/search, autosave writes, document package writes, auto-copy rendering, screenshot export rendering, and streaming file writes propagate cancellation to their detached work and ignore stale search generations. | Continue auditing new async work as features are added. |

### Reliability And Data Integrity

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Build and test discipline | ✓ Done | Local release automation, pull-request CI, main-branch CI, and the App Store release preflight run the complete unit/contract suite by default. Targeted-test overrides remain available only for local diagnosis. Build-number alignment is contract-tested across the app and Share extension. | Signed ScreenCaptureKit, Accessibility, microphone, Share extension, and sandbox behavior still require the documented TestFlight manual gate. |
| Editable document round-trip tests | ✓ Done | `.sss` and `.sssvideo` round-trip coverage exists. | More cross-version migration fixtures would help. |
| Recovery tests | ✓ Done | Recovery, recycle-bin, and archive pruning tests exist. | More UI-level recovery flow coverage would help. |
| Rendering tests | ✓ Done | Renderer behavior is tested, including privacy-sensitive redaction output. | Broader snapshot-style image comparison could still help. |
| Capture tests | ~ Partial | Geometry, permissions, scrolling stitcher, and document behavior are tested. | Live ScreenCaptureKit and Accessibility capture flows still rely heavily on manual QA. |
| Video export tests | ~ Partial | Planning, format handling, capped-size export behavior, and temp cleanup have test coverage. | More end-to-end media export coverage would help where CI permits. |
| Error recovery UX | ~ Partial | The app surfaces many errors and guardrails. | More retry and recovery affordances inside the UI would help. |

### Accessibility, Internationalization, And UX Polish

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Keyboard-only workflows | ✓ Done | Annotation traversal, selection, movement, resizing, deletion, duplication, ordering, grouping, region capture, and adjustable video trim controls have keyboard operations; native text commands are contextually validated. | Continue release-by-release keyboard QA as controls are added. |
| VoiceOver and accessibility coverage | ✓ Done | Icon-only controls have semantic labels and state; the annotation canvas exposes ordered synthetic children with geometry and custom actions; redaction contents stay private; Layers remains a full alternative; capture, permission, selection, export, video, Guide, history, and specialized surfaces expose meaningful values and announcements. | Continue the repeatable VoiceOver checklist for every release and add coverage alongside new surfaces. |
| High contrast and reduced motion support | ✓ Done | Custom overlay surfaces define opaque Reduce Transparency fallbacks, stronger Increase Contrast boundaries, non-color state cues, and reduced nonessential motion. | Keep deterministic visual tests and manual environment testing in the release gate. |
| Localization infrastructure | ~ Partial | An English String Catalog now owns the accessibility-specific strings and establishes the localization path. | Full product localization is intentionally deferred. |
| Responsive window layout | ~ Partial | The app uses adaptive SwiftUI layout patterns, horizontal overflow for dense editor command rows, content-specific minimum sizes for Screenshot, Video, and Guide documents, and a capture-home minimum that is restored after discarding a document while keeping the window inside the visible display frame. | More QA is still needed for small displays, minimum-size transitions, and future localized text growth. |
| Native macOS polish | ~ Partial | The app has solid command/menu integration, a task-focused capture header with keyboard-aware discovery previews, native inspectors and materials, and split editor tool controls that keep the active tool's label visible. | Visual hierarchy and premium feel still lag behind high-end macOS capture tools in some secondary and edge-case surfaces. |

### Observability, Support, And Release Readiness

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| In-app support links | ✓ Done | Help links to the website, privacy policy, and support page. | Add support flows that gather useful diagnostics. |
| Internal diagnostics logging | ~ Partial | Internal logging exists for scrolling capture, history preview loading, and video export. | This is not yet a support-grade diagnostics system. |
| User-facing diagnostics bundle export | ✓ Done | Settings > Privacy > Export Diagnostics writes a local JSON report with sanitized app/build target, macOS, feature flags, permissions, display summaries, archive/clipboard/video-relevant storage summaries, connected-device state, launch-at-login state, and recent sanitized statuses. | Extend carefully as support needs grow; do not include screenshots, OCR text, clipboard contents, annotation text, document data, window titles, or raw paths. |
| Crash reporting | x Not done | No crash reporting integration was found. | Keep privacy-first if added. |
| Product analytics | x Not done | No analytics integration was found. | Keep opt-in and local-first if ever added. |
| Pro app updates | ~ Partial | SnipSnipSnip Pro can manually check the latest GitHub release and send users to GitHub Releases to download the newest package. | This is only a notification/download handoff, not an in-app updater. Add Sparkle appcast-based update installation later. |
| Release automation | ~ Partial | `FASTLANE.md`, project-local Fastlane lanes, and a GitHub App Store workflow cover doctoring, full-suite preflight, archive/upload, TestFlight, and review submission. Every archive is audited for private `_AXUIElementGetWindow`; App Store archives additionally require App Sandbox on every executable and reject AX client and `CGEventTapCreate` imports before upload. | A production submission still depends on App Store Connect metadata/signing state and completion of both manual edition matrices. |
| Documentation coverage | ~ Partial | Help, README, screenshot format docs, video format docs, performance profiling docs, and Fastlane docs are in place. | Broader release-facing visuals and walkthrough media are still missing. |

## Implementation Strengths

- Screenshot architecture is correctly non-destructive: base image, annotation state, crop, export, and persistence are separate concepts.
- Editor mutations are command-driven and testable; bounded history, Numbered Arrow sequencing, Status Marks, and automatic crop variants use the same persistence and rendering architecture.
- Snip History, autosave, last-session recovery, Recycle Bin, OCR indexing, and archive management are far more complete than a simple capture tool.
- Screen Ruler and Screen Inspector make pixel measurement, live color inspection, coordinates, and spacing first-class workflows alongside screenshot capture.
- Clipboard History is integrated as a first-class local timeline rather than a separate utility: it includes normal clipboard items and SnipSnipSnip screenshots, with privacy filters and password-manager ignores built in.
- The `.sss` package is open, documented, and easy to inspect.
- Privacy posture is strong for a local-first screenshot tool: metadata-stripped exports, non-destructive redaction in-editor, and Private Capture controls are already shipped.
- Offline interactive HTML is a real delivery format rather than a static wrapper: it includes a full Comparison viewer, Steps navigation, lossless images, progress and cancellation, accessibility and Reduced Motion behavior, print fallbacks, and a restrictive Content Security Policy.
- Pro UI Map is a distinctive structured screenshot workflow: it can preserve searchable interface metadata and element geometry beside the screenshot, then let users inspect, pin, export, and render those elements without flattening them into the base image.
- Pro scrolling capture has a real service boundary with dedicated diagnostics logging, stitching logic, partial-result handling, and tests.
- The Video stack is real, not placeholder: native ScreenCaptureKit recording, live audio meters and source switches, pause/resume, explicit Finishing, unexpected-stop segment salvage, last-session recovery, editable packages, trim state, poster frames, and size-constrained MP4 exports are all present.
- The automation stack is a real v1 external contract across App Intents, CLI, AppleScript, and URL scheme adapters, all mapped through the same validation and output behavior.
- In-app Help is unusually complete and appears to move with the product rather than lag behind it.

## Implementation Risks And Clear Gaps

- Pro scrolling capture is implemented, but still not hardened enough to treat as fully complete across the app landscape.
- Pro connected iPhone/iPad screenshot capture is implemented in the self-release capture path and now reports runtime stream interruptions, but still needs broader device compatibility validation.
- Intent-driven screenshot creation and multi-capture composition are shipped for static and interactive output, including Comparison, manual Steps, Combined Image layouts, optional Polish Looks and Mockups, user templates, WYSIWYG output, and offline HTML.
- Video editing is still a trim-and-export workflow, not a full demo-editor workflow.
- Global Shortcuts are customizable but intentionally background-only while the app is active, which may surprise power users.
- Clipboard History source-app filtering is inherently best-effort because macOS pasteboard changes do not always include reliable origin metadata.
- Layer ordering commands and the standalone Layers window are shipped, including drag reorder; visibility toggles and locking are still intentionally deferred until the annotation model and package format support them.
- Automation is shipped for capture, preset, document-open, and current-screenshot export workflows, but it is still a v1 surface and does not expose annotation mutation, recording a Video, Connected Device capture, upload destinations, or direct Window lookup.
- `.sssvideo` documentation is now published; keep it current with schema updates.
- Accessibility depth and localization infrastructure are both behind the rest of the product.
- User-facing diagnostics export is shipped; crash reporting is still absent.
- The old phase roadmap is no longer an accurate representation of the shipped product and should not be treated as planning truth.

## Major Not-Done Areas

### Tier 1: Close The Screenshot Product Gap

- Layer visibility toggles and locking, building on the shipped standalone Layers window.
- Preset-specific Global Shortcuts, preset import/export, destination rules, and fully customizable shortcut behavior for power users.
- Better OCR controls: QR detection, language options, confidence review.
- Richer export destinations beyond shipped local drag-out sharing.
- Continue strengthening `.sssvideo` docs with sample package fixtures.

### Tier 2: Make Video Recording Competitive

- Broader video format reach beyond MP4, GIF, and APNG.
- Auto zoom and manual zoom timelines.
- Cursor smoothing, replacement, idle-hide, and richer click styling.
- Keystroke overlays.
- Aspect-ratio export canvases and background studio options.
- Webcam or camera overlay.
- Captions and transcription.
- Video overlays, speed controls, volume editing, background export handling, and eventually multi-clip editing if scope expands.

### Tier 3: Workflow And Ecosystem Depth

- Deeper automation beyond the shipped v1 capture/export contract, including annotation mutation, recording a Video, direct Window lookup, and richer output destinations.
- Optional upload destinations and share links.
- Collections, tags, favorites, or projects in history.
- Stronger support workflows built on the shipped local diagnostics bundle.
- More polished preset and template workflows for videos, plus screenshot template search/filter if user libraries become large.

### Tier 4: Harden SnipSnipSnip Pro

- Scrolling capture hardening across more apps, browsers, sticky headers, dynamic content, and virtualized lists.
- Connected iPhone/iPad screenshot capture QA across device families, orientations, trust/unlock state, stream interruptions, disconnects, and no-device empty states.
- Clearer Pro diagnostics and fallback messaging when Accessibility scrolling or connected-device streams are unavailable.

## Suggested Engineering Priorities

1. Treat `FEATURE_LIST.md` as the truth source and archive or rewrite the obsolete phase roadmap.
2. Keep screenshot and video format docs versioned and in sync with schema changes.
3. Add layer visibility and locking metadata to the existing Layers window, with additive `.sss` schema, renderer, hit-testing, export, and migration behavior.
4. Harden SnipSnipSnip Pro capture with diagnostics, compatibility coverage, and fallback flows.
5. Add conflict detection and keyboard-capture UX polish for customizable Global Shortcuts.
6. Introduce a richer video timeline model before attempting zooms, captions, overlays, or multi-clip work.
7. Keep privacy-oriented redaction warnings and support diagnostics fields current.
8. Build accessibility and localization foundations before broader distribution.

## Current Product Position

SnipSnipSnip is already a strong local-first screenshot product with a meaningful editor, Snip Library, multi-capture composition, presentation styling, local drag-out sharing, and first-generation automation across App Intents, CLI, AppleScript, and URL routes. It also has a real, useful first-generation Video stack with recovery. SnipSnipSnip Pro extends that product with advanced capture workflows: Scrolling Capture, Connected iPhone/iPad capture, and UI Map capture. The remaining premium-suite gaps center on advanced Video polish, deeper integrations, Pro capture hardening, and support readiness.

That is now the accurate state of the product family: standard screenshot capture, editing, composition, presentation styling, local diagnostics export, automation, drag-out sharing, Screen Ruler, Screen Inspector, and the cross-product accessibility foundation are implemented; Pro UI Map is a unique structured screenshot workflow; Pro Scrolling Capture and Connected iPhone/iPad screenshot capture still need hardening; advanced Video editing, richer integrations, and full localization remain open.
