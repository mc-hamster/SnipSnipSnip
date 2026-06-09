# SnipSnipSnip Feature List

Last reviewed: 2026-06-09

This document is the source of truth for what SnipSnipSnip and SnipSnipSnip Pro currently ship, what is only partially complete, and what is still missing. It is based on the current app source, shipped Help content, public docs, and test suite, not on older roadmap text.

SnipSnipSnip is already much larger than a screenshot MVP. It is a real screenshot app with a strong non-destructive editor and archive system, plus a usable first-generation screen recording and trim workflow. SnipSnipSnip Pro is the expanded product tier for advanced capture workflows: scrolling capture, connected iPhone/iPad screenshot capture, and UI Map capture. The strongest completed areas are screenshot capture, screenshot editing, editable document persistence, archive/history/recovery, privacy defaults, screenshot presentation styling, drag-out sharing, practical MP4/GIF/APNG recording export, and user-triggered support diagnostics export. The largest unfinished areas are richer screenshot presentation templates, Pro capture hardening, advanced video polish, automation/integrations, accessibility depth, and localization.

## Status Legend

- `✓ Done`: shipped, user-reachable, and meaningfully implemented in the current app.
- `~ Partial`: shipped in some form, but still limited, brittle, or missing important adjacent behavior.
- `x Not done`: no user-facing implementation was found in the current app.
- A `✓ Done` row does not mean best-in-class or feature-complete against premium competitors. It means the feature is genuinely present and useful today.

## Review Basis

This revision was checked against:

- App source in `SnipSnipSnip/App`, `Capture`, `Document`, `Editor`, `Export`, `Preview`, `Support`, and `Video`.
- Tests in `SnipSnipSnipTests`.
- User-facing Help in `SnipSnipSnip/App/HelpGuideView.swift`.
- Public docs in `README.md`, `sss-format.md`, `PERFORMANCE_PROFILING.md`, and `FASTLANE.md`.

The comparison lens for the "remaining gap" column is still the premium macOS capture market: CleanShot X, Shottr, Snagit, Loom, Kap, and Screen Studio. The status markers themselves are about the SnipSnipSnip product family only.

## Product Editions

This repo currently represents two related products:

- **SnipSnipSnip**: the standard local-first screenshot and screen recording app. It includes region, window, frontmost-window, fullscreen, repeat, and timer screenshot capture; the screenshot editor; archive/history/recovery; Clipboard History; Screen Inspector; floating references; local export and sharing; and region, window, and fullscreen screen recording.
- **SnipSnipSnip Pro**: the advanced capture tier. It includes everything in SnipSnipSnip, plus scrolling capture, connected iPhone/iPad screenshot capture, and UI Map capture.

The current source also contains partial Pro connected-device recording plumbing. This is tracked separately from the standard recording product because the named Pro capture additions are scrolling capture and connected iPhone/iPad screenshot capture.

When a feature is Pro-only, this document calls that out explicitly. Shared features apply to both products.

## Executive Summary

SnipSnipSnip already ships all of the following in meaningful form:

- Screenshot capture for region, window, frontmost window, fullscreen, repeat, timer, live window thumbnails, on-screen window picking, and multi-display desktop composition.
- Screen Inspector as a floating live magnifier with 2x, 4x, 8x, and 16x zoom, optional pixel grid and crosshair, display-local pixel coordinates, center-pixel color readout, one-line point-to-point distance measurement, HEX/RGB copy shortcuts, freeze, resize, and Snip-to-editor.
- A non-destructive screenshot editor with crop, rectangle, ellipse, line, arrow, freehand, highlight, text, callouts, ruler measurements, spotlight/dim, color sampling, OCR-backed Copy Text, image overlays, rotation, grouping, alignment, snapping, and blur/pixelate/solid redaction.
- Floating reference screenshots that pin rendered editor or history snapshots in lightweight always-on-top windows with opacity, zoom, pan, multiple-reference, and close-all controls.
- Editable `.sss` screenshot packages with base image, preview, JSON session state, undo/redo history, search metadata, and image overlay assets.
- Local-first archive/history/recovery with autosave checkpoints, recent snips, recycle bin, archive size limits, custom archive location, OCR-backed search metadata, and Private Capture.
- Local-first Clipboard History for copied text, links, images, files, and SnipSnipSnip screenshots, including non-private snips even when Auto Copy is off.
- Screen recording for region, window, and fullscreen, with current-display, selected-display, and all-displays modes for fullscreen, plus MP4 capture, cursor and click options, system audio, microphone narration, storage guardrails, `.sssvideo` packages, trim editing, poster frames, timeline thumbnails, and quality or size-limited MP4 export.

SnipSnipSnip Pro adds the following advanced capture workflows:

- Scrolling capture with a dedicated scrolling overlay, Accessibility-driven target resolution, image stitching, cancel/done controls, partial-result handling, repeat support, and `.sss` scrolling metadata.
- Connected iPhone/iPad screenshot capture for trusted USB devices, with a live AVFoundation preview and normal screenshot editor, copy, save, history/archive, and Private Capture behavior through the existing screenshot pipeline.
- UI Map capture, a Pro-only structured screenshot workflow that saves available Accessibility metadata and local OCR supplement text into editable `.sss` documents for selected Window captures. Instead of treating a screenshot as pixels only, UI Map records visible interface element names, roles, identifiers, hierarchy, and geometry so the user can search the captured UI, inspect controls, export JSON, pin element overlays, and render those pinned overlays during copy, share, and export. This is a unique differentiator versus conventional screenshot tools.

The biggest unfinished areas are now clear:

- Pro scrolling capture works, but it is still a `~ Partial` feature because compatibility and diagnostics are not hardened enough to call it fully done.
- Pro connected iPhone/iPad screenshot capture works in the feature-gated build, but it remains `~ Partial` because it uses self-release capture plumbing and needs broader device, orientation, stream-interruption, and disconnect QA.
- Pro UI Map capture is implemented and intentionally Pro-only. It is still dependent on Accessibility availability and target-app AX quality, but the workflow is already user-reachable and materially different from pixel-only capture tools.
- Screenshot presentation styling is useful and shipped: padding, solid or transparent backgrounds, rounded corners, shadows, live preview, and rendered drag-out sharing are present. Richer frames, gradients, pinned screenshots, and multi-capture composition remain open.
- Video recording is useful, but advanced post-production is still mostly `x Not done`: webcam, keystrokes, zooms, captions, aspect-ratio layouts, video overlays, speed controls, volume editing, and multi-clip editing.
- Workflow automation is still shallow: customizable global hotkeys and a Clipboard History opener exist, but App Intents, URL schemes, and cloud/upload workflows are absent.
- Non-functional readiness is mixed: privacy is strong, docs are solid for screenshots, performance profiling and local diagnostics export exist, but accessibility depth, localization, and crash reporting are still not done.

## Functional Feature Matrix

### Capture

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Region screenshot capture | ✓ Done | `ScreenCaptureService.captureRegion`, `RegionSelectionOverlay`, desktop composite snapshots, and drag selection are implemented. | Add aspect-ratio lock, saved regions, keyboard nudging, and explicit dimension entry. |
| Window screenshot capture | ✓ Done | Window listing, live thumbnails, picker UI, and direct window capture are implemented. | Better handling for sheets, transient popovers, transparent windows, and unusual shadow cases. |
| Frontmost window capture | ✓ Done | Dedicated frontmost-window capture flow exists in menus and hotkeys. | Improve user feedback when the frontmost app has no eligible window. |
| Fullscreen screenshot capture | ✓ Done | Captures a desktop composite across connected displays. | Add explicit current-display vs selected-display vs all-displays choices. |
| Live window picker and thumbnails | ✓ Done | Main window picker supports refresh and auto-refresh; menu bar quick menu shows top windows with thumbnails. | Expand richer window grouping and edge-case targeting. |
| Pick-on-screen window targeting | ✓ Done | On-screen window picking flow exists in capture UI. | Better feedback for transient windows and ambiguous hits. |
| Multi-display support | ✓ Done | Desktop composite snapshots track capture and overlay coordinate transforms; tests cover offsets and adjacent displays. | Broader manual QA for rotated displays, Stage Manager, Spaces, and hot-plug changes. |
| Retina correctness | ✓ Done | Per-display and per-window scale handling exists, with geometry tests covering pixel mapping. | Add more visual regression coverage for mixed-scale outputs. |
| Pixel loupe during region capture | ✓ Done | Crosshair and magnifying-glass overlay modes are configurable. | Screen Inspector covers standalone inspection; the region-selection loupe still lacks live color readout and keyboard movement while selecting. |
| Screen Inspector floating magnifier | ✓ Done | Menu bar, Capture menu, and customizable global hotkey open a resizable always-on-top live inspector with 2x, 4x, 8x, and 16x zoom, optional pixel grid and crosshair, display-local top-left pixel coordinates, center-pixel HEX/RGB readout, copy shortcuts, freeze, close shortcuts, one-line point-to-point distance measurement with Option-Command-M, and Snip-to-editor. Grid and crosshair default off. | Broaden manual QA across mixed-scale multi-monitor seams, rotated displays, Spaces, and permission edge cases. |
| Adjustable region before commit | ~ Partial | Region capture can require explicit confirmation when action controls are enabled. | No explicit resize handles or numeric size adjustment before the shot is committed. |
| Timer capture | ✓ Done | `CaptureDelay` supports off, 3, 5, and 10 seconds from menus. | No custom delay value or countdown overlay UI. |
| Repeat last capture | ✓ Done | Repeats region, window, frontmost window, and fullscreen capture when the target can still be resolved. SnipSnipSnip Pro also repeats scrolling capture when the target can still be resolved. | No saved presets or named capture targets. |
| Explicit per-display screenshot selection | x Not done | Fullscreen screenshots capture the desktop composite rather than a user-selected display mode. | Add selected display/current display/all displays options. |
| Cursor capture in screenshots | ✓ Done | Optional cursor capture adds the current pointer as a non-destructive image overlay for region, window, frontmost-window, fullscreen, and repeat screenshots. The overlay can be moved, resized, faded, or deleted; Scrolling Capture excludes it while stitching. | Consider cursor-style replacement presets and click indicators. |
| Desktop clutter hiding | x Not done | No desktop icon or window-clutter hiding workflow was found. | Needed for polished demo-style capture. |
| Capture presets | x Not done | Capture actions are fixed menu commands plus settings values. | Add saved mode/timer/destination/audio/cursor presets. |

### Pro Capture

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Scrolling capture | ~ Partial | SnipSnipSnip Pro includes a dedicated scrolling overlay, Accessibility-driven target resolution, image stitching, cancel/done controls, partial-result handling, repeat support, and `.sss` scrolling metadata, with stitcher tests. | Needs app/browser compatibility hardening, clearer user diagnostics, better fallback paths, and a broader manual QA matrix. |
| Connected iPhone/iPad screenshot capture | ~ Partial | SnipSnipSnip Pro lists trusted USB iPhone/iPad sources, distinguishes USB-connected devices that macOS is not exposing as streams, opens a live AVFoundation preview, captures the latest frame into the normal screenshot editor, and supports copy, save, editor opening, history/archive behavior, Private Capture rules, runtime interruption reporting, and support diagnostics summaries through the existing screenshot pipeline. | Uses self-release capture plumbing, supports one active connected-device session, depends on macOS exposing the trusted/unlocked device stream, does not use private device services, and still needs broader device/orientation/disconnect/manual QA. |
| UI Map window capture | ✓ Done | SnipSnipSnip Pro Window captures can asynchronously save available names, labels, identifiers, roles, positions, sizes, parent hierarchy, owning app, and OCR supplement text into `.sss` documents when the UI Map user setting is enabled. Capture is intentionally limited to selected Window captures and uses the captured window identity rather than scanning region or fullscreen captures. | Accessibility availability and target-app AX quality still determine how complete the element hierarchy is; broader manual QA across app frameworks is still needed. |

### Screenshot Editor And Annotation

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Non-destructive annotation model | ✓ Done | Base screenshot pixels, crop, and annotations are separate in `EditorSnapshot`, `Annotation`, renderer inputs, and `.sss`. | Keep this separation intact as new presentation features are added. |
| Command-based mutations | ✓ Done | `DocumentCommand` types drive add, update, delete, group, selection, and crop changes. | User-visible undo labels and future layer commands are still open. |
| Undo/redo | ✓ Done | Undo/redo stacks exist in `EditorController` and persist in `.sss`. | Consider bounded history or more explicit history UI over time. |
| Open existing image in the editor | ✓ Done | File > Import Image opens common image formats directly into the screenshot editor. | Could expand into batch or multi-page import later. |
| Rectangle | ✓ Done | Rectangle tool includes style editing, rounded corners, fill presets, and dashed or dotted strokes. | More style presets could still be added. |
| Ellipse | ✓ Done | Ellipse tool, style editing, and rendering are present. | Could add forced-circle behavior and more presets. |
| Line | ✓ Done | Line tool, model, hit testing, and rendering are present. | No elbow or curved connector variant. |
| Arrow | ✓ Done | Arrow tool supports curved arrows, single or double heads, multiple head styles, and inspector-managed labels. | No bend handles or richer direct manipulation for label geometry. |
| Freehand | ✓ Done | Freehand drawing exists, with smoothing and simplification controls in the inspector. | No eraser mode, pressure styling, or point-editing workflow. |
| Highlight | ✓ Done | Highlight tool renders rounded highlight regions. | No text-aware highlight mode. |
| Text | ✓ Done | Text annotations support typing, alignment, resizing-to-fit, and style editing. | No font family chooser, rich text spans, or spellcheck. |
| Callouts | ✓ Done | Numbered callouts support auto-increment, auto-renumber after deletion, text editing, leader lines, and step-guide copy. | Could add more layouts and more direct anchor editing. |
| Ruler measurement | ✓ Done | Measurement annotations support endpoint handles and rendered pixel labels. | No calibrated real-world units yet. |
| Spotlight/dim tool | ✓ Done | Spotlight annotation dims outside a focused oval or rectangle. | No presentation presets beyond the current effect controls. |
| Copy Text OCR tool | ✓ Done | OCR-backed Copy Text lets the user drag a screenshot region, review normalized text, and copy it. | No QR detection, language controls, or confidence review. |
| UI Map inspection and pinning | ✓ Done | SnipSnipSnip Pro UI Map documents expose a floating UI Map panel with hierarchy tree, search, type and Pinned Only filters, keyboard navigation, metadata details, JSON export, Show All, and pin/unpin controls. The UI Map Inspect toolbar tool shows selectable outlines on the screenshot; clicking pins or unpins an element, pinned overlays render in copy, share, and export, and typing after a pinned element starts a text annotation near it. AX elements render blue and OCR supplement text renders orange. | UI Map quality depends on the captured window's Accessibility exposure; non-window captures intentionally do not create new UI Map metadata. |
| Redaction: blur | ✓ Done | Non-destructive blur redaction is rendered and tested. | Add stronger user warnings around sharing editable documents with redactions. |
| Redaction: pixelate | ✓ Done | Non-destructive pixelate redaction is rendered and tested. | No separate block-size control beyond current effect settings. |
| Redaction: solid | ✓ Done | Solid redaction mode is implemented. | Could add stronger privacy affordances before sharing editable docs. |
| Multi-select | ✓ Done | Marquee selection and additive or toggle selection are supported. | More keyboard-first selection control would help. |
| Group/ungroup | ✓ Done | Group IDs and group-aware selection behavior exist. | No visible layer tree or nested group UI. |
| Alignment | ✓ Done | Geometric alignment and text alignment are supported in the inspector. | No distribute-spacing, match-size, or align-to-canvas actions. |
| Distribution and equal-size layout tools | x Not done | Only core alignment commands are present. | Add distribute, match-size, and align-to-canvas actions. |
| Snapping | ✓ Done | Snap guides and rect snapping exist during move, resize, and draw. | No grid toggle, guide preferences, or snap strength controls. |
| Grid and custom guides | x Not done | No grid or custom guide system was found. | Add user-visible grid and guide controls. |
| Crop | ✓ Done | Crop tool supports canvas handles, numeric X/Y/Width/Height editing, Freeform plus fixed landscape/portrait aspect presets (1:1, 3:2, 2:3, 4:3, 3:4, 16:9, 9:16), reset crop, crop-aware export, crop refocus, and moving crop with the select tool. | No canvas rotation, padding canvas, or resize-canvas workflow. |
| Crop context aids | ✓ Done | Crop editing shows a loupe while dragging and supports dimming plus out-of-capture crosshatch settings. | These are editor-only aids, not screenshot presentation output. |
| Zoom and pan | ✓ Done | Zoom in/out, fit, actual size, pinch, scroll-wheel zoom, panning, and visible scroll tracks are implemented. | No minimap or per-document zoom restore. |
| Rotation | ✓ Done | Annotation rotation persists, renders, hit-tests correctly, and is editable in the inspector. | No direct on-canvas rotation handle. |
| Color picker | ✓ Done | Inspector-driven color sampling reads from the base screenshot and applies to stroke or fill. | No live capture-time color readout. |
| Image overlays | ✓ Done | Pasteboard and imported image overlays are editable annotations with resize, rotation, opacity, archive assets, and export/render support. | No blend modes or replace-image action. |
| Layer order / reorder | ✓ Done | Bring Forward (`⌘]`), Send Backward (`⌘[`), Bring to Front (`⌥⌘]`), and Send to Back (`⌥⌘[`) commands with Arrange menu, undo/redo support, multi-selection block reordering, and a standalone Layers window with selection sync, drag reorder, group/ungroup, z-order buttons, delete, and empty states. | Visibility toggles and layer locking are intentionally deferred until annotation metadata, `.sss` schema, rendering, hit-testing, and export behavior support them additively. |
| Combine screenshots on one canvas | x Not done | Screenshot documents still have one base image. | Add multi-capture composition or add-capture-as-layer workflow. |
| Background and presentation tool | ~ Partial | The inspector now includes screenshot presentation presets plus controls for transparent or solid background, padding, rounded corners, and export shadows. Transparent shadow output is preserved on alpha for PNG copy, share, and export. | Add gradients, browser chrome, device frames, social aspect ratios, and a richer on-canvas preview workflow. |
| Floating or pinned screenshots | ✓ Done | Current rendered screenshots and history/recent/recycle-bin snapshots can be opened as always-on-top floating reference windows. Multiple references can be shown at once; each supports resizing, explicit handle-based moving, one-click close, opacity adjustment, pinch/scroll zoom, panning, fit/zoom buttons, and close-all from the Reference menu or menu bar extra. | Future work could add named reference sets, saved layouts, and a reference board. |

### Screenshot Output And Sharing

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Clipboard-first workflow | ✓ Done | Auto Copy and explicit Copy use the current rendered screenshot result. | No copy-as-file, copy-as-markdown, or cloud-link workflow. |
| Clipboard History manager | ✓ Done | A floating Clipboard History window opens from the menu bar, stores local history for text, links, images, file URLs, and SnipSnipSnip snips, and supports search, type filters, thumbnails, pinned items, delete, clear unpinned, Copy, and Copy & Paste back into the previously active app while keeping the history window open. | Plain-text paste for rich text and deeper metadata previews can still be expanded. |
| Clipboard History shortcuts | ✓ Done | Return triggers Copy & Paste for the selected item, arrow keys move selection, and Option-1 through Option-9 copy the matching visible item while the Clipboard History window is focused. | These are intentionally local shortcuts; global item-number shortcuts would conflict with frontmost apps. |
| PNG export | ✓ Done | `ImageExporter` supports PNG output. | No destination presets or export rules. |
| JPEG export | ✓ Done | JPEG export exists with fixed compression. | No quality slider or auto format choice. |
| PDF export | ✓ Done | Single-image PDF export exists. | No vector-preserving annotation export. |
| Native share sheet | ✓ Done | Uses `NSSharingServicePicker` for rendered screenshot sharing. | No upload destinations. |
| Drag-and-drop export affordance | ✓ Done | Screenshot and video editors expose compact promised-file drag handles, and the large presentation preview is draggable. | Validate compatibility with more third-party destinations over time. |
| Metadata stripping and privacy-safe export | ✓ Done | PNG, JPEG, and PDF outputs are re-encoded and tests confirm source EXIF, TIFF, GPS, IPTC, and user metadata are not preserved. | Future upload flows should add destination-aware privacy confirmations. |
| Filename templates | ✓ Done | Save As and export suggestions use `ScreenshotFilenameTemplate` tokens for kind, source, time, width, height, and format. | No per-destination rules or reusable template presets. |
| Cloud upload and share links | x Not done | No cloud backend or upload destination exists in the current app. | Add optional privacy-preserving upload workflows only if needed. |

### Persistence, History, Search, And Recovery

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Editable screenshot package | ✓ Done | `.sss` stores base image, preview, editable state, undo/redo, search metadata, and overlay assets. | More migration fixtures would further harden the format. |
| UI Map metadata persistence | ✓ Done | `.sss` documents preserve UI Map snapshots, element source (`accessibility` or `ocrSupplement`), capture diagnostics, and pinned UI Map element IDs. Documents with UI Map metadata continue to open safely when UI Map UI is unavailable or disabled. | Additional migration fixtures and large-hierarchy package tests would further harden long-term compatibility. |
| Public `.sss` format documentation | ✓ Done | `sss-format.md` documents format version 3, schema, overlay assets, privacy semantics, and compatibility rules. | Could still use sample package trees and more examples. |
| Undo/redo persistence | ✓ Done | `.sss` round-trips undo and redo history. | Watch package size growth for very large histories. |
| Autosave checkpoints | ✓ Done | `DocumentRecoveryStore` keeps per-session checkpoints. | No richer checkpoint reason/diff labeling yet. |
| Crash recovery | ✓ Done | Pending recovery sessions are surfaced on relaunch. | More edge-case tests would still help. |
| Recent snips | ✓ Done | Shelved unsaved work remains available from the main UI and editor inspector. | No favorites, tags, or projects yet. |
| Capture history | ✓ Done | Archive entries persist across sessions and support search. | Filtering by type, date, and source app is still missing. |
| Clipboard screenshot timeline | ✓ Done | Every non-private completed screenshot is inserted into Clipboard History as a snip entry with preview/copy payloads and capture metadata, even when Auto Copy is disabled. Private Capture screenshots are excluded. | Reveal-in-editor depends on the backing recoverable capture still being available. |
| Clipboard item persistence and pruning | ✓ Done | Clipboard history stores local metadata plus image/snip preview assets under Application Support, deduplicates by content hash, and prunes by configured item count and storage size while preserving pinned entries. | No iCloud sync or cross-device history by design. |
| Search annotation text | ✓ Done | Search metadata includes annotation text. | Search is still simple and could use indexing at large scale. |
| OCR-backed history search | ✓ Done | Background Vision OCR indexes captures for search, and Private Capture skips that indexing. | No QR detection, OCR language selection, or OCR confidence UI. |
| Recycle bin | ✓ Done | Deleted entries move to recycle bin and can be restored, deleted, or emptied. | Could add stronger privacy/storage warnings. |
| Archive size cap | ✓ Done | Oldest checkpoints are pruned when the configured cap is exceeded. | No user-facing maintenance log yet. |
| Archive folder selection | ✓ Done | Custom archive location uses security-scoped bookmarks. | Repair tooling for stale bookmarks would help. |
| Private Capture | ✓ Done | Private Capture skips archive checkpoints, recycle-bin retention, and background OCR indexing for that session. | Could add stronger history badging and more export-time privacy reminders. |
| Editable video package | ✓ Done | `.sssvideo` stores source media, poster frame, trim state, and recording metadata. | Keep compatibility notes and migration examples current as the schema evolves. |
| Public `.sssvideo` format documentation | ✓ Done | `sssvideo-format.md` now documents package layout, schema, versioning, and compatibility behavior. | Add concrete sample package fixtures over time. |

### Screen Recording

| Feature | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Region recording | ✓ Done | ScreenCaptureKit region recording is implemented, with a single-display constraint for region bounds. | No saved regions, presets, or resize-before-record workflow. |
| Window recording | ✓ Done | Desktop-independent window recording is implemented. | No robust retargeting when a window moves, relaunches, or changes identity. |
| Fullscreen recording | ✓ Done | Current-display fullscreen recording is implemented. | No selected-display or all-displays mode selection. |
| Explicit display selection for recording | ✓ Done | Fullscreen recording now supports Current Display, Selected Display, and All Displays modes from Recording settings. | Broaden manual QA coverage for mixed scaling, rotated displays, and Spaces arrangements. |
| MP4 H.264 recording | ✓ Done | Recording writes MP4 through native ScreenCaptureKit recording output. | No HEVC or ProRes choice. |
| Quality presets | ✓ Done | Compact, Balanced, and High presets are implemented. | No user-facing bitrate estimator or custom preset editor. |
| Frame rate options | ✓ Done | 15, 30, and 60 fps are supported. | No custom fps or adaptive export-specific fps logic. |
| Cursor visibility | ✓ Done | Recording settings expose show cursor. | No cursor replacement, smoothing, or idle-hide behavior. |
| Click highlighting | ✓ Done | Recording settings expose mouse-click rings. | No custom styles, colors, or per-click editing. |
| System audio | ✓ Done | Optional system audio recording is supported. | No level meters, source choice, or audio editing tools. |
| Microphone narration | ✓ Done | Optional microphone recording is supported, with permission flow. | No input-device selection, levels, or cleanup tools. |
| Floating stop overlay | ✓ Done | Recording shows a floating control excluded from the capture, displays elapsed time, and now supports Pause, Resume, and Stop. | Add keyboard stop/pause shortcuts and optional cancel-delete flow. |
| Pause/resume recording | ✓ Done | Active recordings support pause and resume from the floating recording control. | Add manual QA coverage for long pause/resume sessions with audio enabled. |
| Storage guardrails | ✓ Done | Temp cleanup plus minimum free-space checks exist before recording and export. | No live in-recording low-storage monitoring yet. |
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
| Main-window command menus | ✓ Done | Capture, Help, Open, Import Image, Save, Export, Share, and pasteboard commands are present. | Tool-by-tool command coverage is still incomplete. |
| Global hotkeys | ✓ Done | Global capture and Screen Inspector hotkeys remain background-only and are now user-customizable per action from Settings > General. | Consider optional frontmost behavior toggles for power users later. |
| In-app shortcuts | ~ Partial | Capture, open, save, export, share, copy, select all, group, ungroup, layer ordering (bring forward/backward, bring to front, send to back), and help shortcuts exist. | Missing broader tool shortcuts, richer editor navigation shortcuts, and user customization. |
| Settings window | ✓ Done | The app has General, Recording, Archive, Clipboard, and Privacy settings tabs. In SnipSnipSnip Pro, General settings include Window UI Map enablement and default pinned UI Map overlay options; Clipboard settings include history enablement, item/storage limits, clear history, ignored-app management, and restore-default ignored apps. | No capture preset system or deeper workflow automation settings yet. |
| Clipboard ignored-app workflow | ✓ Done | Clipboard settings can ignore currently running apps, choose an app bundle from Applications, or ignore recent clipboard source apps with one click. Default ignored apps include Apple Passwords and common password managers such as 1Password, Bitwarden, Dashlane, LastPass, KeePassXC, Keeper, RoboForm, Enpass, mSecure, NordPass, Proton Pass, KeeWeb, MacPass, Strongbox, Secrets, Buttercup, and SafeInCloud. | Source-app detection is best-effort because macOS pasteboard data does not reliably expose origin for every copy. |
| Permission diagnostics and remediation buttons | ✓ Done | Settings and main UI expose permission diagnostics plus remediation buttons, Help guidance, and a local Export Diagnostics flow for support. | Keep the diagnostics schema current as more support-relevant subsystems are added. |
| Drag-out sharing | ✓ Done | Screenshot and video editors expose compact promised-file drag handles. Screenshot drag-out flattens current edits and presentation styling; video drag-out exports the current trimmed MP4 with the remembered preset after the drop is accepted. | Add richer destinations only if local file drag-out proves insufficient. |
| Floating reference workflow | ✓ Done | Reference > Float Current Screenshot and the editor Float button create lightweight always-on-top views without duplicating files or modifying documents. History preview overlays can float archived snapshots for comparison or active reference work. | Add saved reference layouts only if active workspace referencing becomes a larger product area. |
| App Shortcuts or App Intents | x Not done | `AppShortcuts.swift` only defines shortcut modifiers; no App Intents implementation was found. | Add Shortcuts support only if automation becomes a product priority. |
| URL scheme or external API | x Not done | No URL scheme or external automation API was found. | Add only if power-user automation is in scope. |
| Upload integrations | x Not done | No S3, Slack, issue tracker, webhook, or cloud destination integration exists. | Keep optional and privacy-preserving if added later. |
| Template workflows and style presets | x Not done | No reusable screenshot beautify or video brand template system exists. | Add only after presentation layers exist. |
| In-app Help guide | ✓ Done | Help is rich, user-facing, and appears maintained alongside major screenshot and recording behavior. | Could add search and stronger troubleshooting diagnostics. |
| README and product docs | ✓ Done | `README.md` covers features, privacy, permissions, formats, and build/test instructions. | Add release/download assets and more visuals when distribution stabilizes. |
| Public `.sss` format docs | ✓ Done | `sss-format.md` documents the screenshot package format clearly. | Keep current as format evolves. |
| Public `.sssvideo` format docs | ✓ Done | `sssvideo-format.md` now documents the editable video package format. | Keep docs aligned with any future format version bumps. |

## Non-Functional Requirements

### Privacy And Security

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Local-first processing | ✓ Done | README and current architecture explicitly position capture, OCR, rendering, export, history, and document handling as local-first; there is no cloud dependency in the current app. | If cloud is ever added, keep it strictly opt-in. |
| Permission clarity | ✓ Done | Settings and Help explain Screen Recording, Accessibility, and microphone/system-audio permissions, and the app exposes remediation actions plus support diagnostics export. | Keep troubleshooting copy aligned with macOS permission UI changes. |
| Redaction safety | ✓ Done | Redactions stay non-destructive in the editor and flatten only on copy, export, or share. Docs warn that editable packages retain original content. | Add a stronger pre-share warning for editable documents if needed. |
| Archive privacy | ✓ Done | Archive and recycle-bin behavior are documented, and Private Capture suppresses checkpoints, recycle-bin retention, and background OCR indexing. | Could add clearer privacy badging in history. |
| Clipboard privacy | ✓ Done | Clipboard History is local-only, skips concealed and transient pasteboard types, excludes Private Capture screenshots, and ignores Apple Passwords plus common password managers by default. Ignored apps can be managed through automated app-picker and recent-source flows rather than manual bundle ID entry. | Pasteboard source app attribution remains best-effort on macOS. |
| UI Map privacy | ✓ Done | SnipSnipSnip Pro UI Map capture is build-flagged, user-controlled, Window-only, and user-initiated. Region, fullscreen, scrolling, recording, connected-device, and Screen Inspector captures do not request Accessibility because of UI Map. Hidden UI Map metadata stays local to `.sss`; flattened image exports exclude hidden metadata, while pinned UI Map overlays are visible pixels by design. | Future editable-document sharing flows could add explicit strip-UI-Map export choices. |
| Security-scoped archive access | ✓ Done | Custom archive locations use bookmarks. | Add repair flow for stale bookmarks over time. |
| Sensitive logging hygiene | ✓ Done | Internal logging exists for scrolling capture, thumbnail history preview loading, and video export. The user-triggered diagnostics export includes sanitized app, permission, display, storage, editor, connected-device, launch-at-login, and status summaries without screenshots, OCR text, clipboard contents, annotation text, document data, window titles, or raw paths. | Keep new diagnostics fields summary-only and redacted by default. |

### Performance And Scalability

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Repeatable profiling workflow | ✓ Done | `PERFORMANCE_PROFILING.md` and `./bin/profile-performance` provide a profiling loop around renderer, export, archive search, storage-budget, capture, and scrolling stitcher performance paths, plus optional traces. | Keep baselines current as hardware, OS, and capture APIs change. |
| Broad performance budgets and coverage | ✓ Done | `PerformanceBudgetCatalog` defines named budgets for capture entry, screenshot render/export, indexed archive search, video export planning, and live storage checks; tests exercise these alongside dense renderer and scrolling stitcher metrics. | Budget values should be tuned from release profiling runs over time. |
| Large archive scalability | ✓ Done | Archive history maintains a persistent `search-index.json`; search, presentation refresh, recycle-bin views, and pending-recovery summaries use indexed checkpoint metadata instead of rescanning every package. | Future work can add richer token ranking or faceted filters if the archive UI grows. |
| Long recording resilience | ✓ Done | Recording still performs preflight cleanup/free-space checks, and active recordings now run live disk-pressure checks that safely stop and finalize when temporary storage drops below the safety floor. | Deeper ScreenCaptureKit stream reconstruction can still be added if macOS exposes more recoverable failure modes. |
| Memory management | ✓ Done | Screenshot file export streams PNG/JPEG/PDF writes through temporary files instead of materializing full export data in memory; renderer caches, thumbnail downsampling, temp cleanup, and video guardrails remain in place. | Continue profiling unusually large captures and long videos as part of release validation. |
| Async correctness and cancellation | ✓ Done | Archive refresh/search, autosave writes, document package writes, auto-copy rendering, screenshot export rendering, and streaming file writes propagate cancellation to their detached work and ignore stale search generations. | Continue auditing new async work as features are added. |

### Reliability And Data Integrity

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Build and test discipline | ~ Partial | The repo has active build/test commands, targeted tests, and profiling guidance. | This document cannot guarantee enforcement of the process by itself. |
| Editable document round-trip tests | ✓ Done | `.sss` and `.sssvideo` round-trip coverage exists. | More cross-version migration fixtures would help. |
| Recovery tests | ✓ Done | Recovery, recycle-bin, and archive pruning tests exist. | More UI-level recovery flow coverage would help. |
| Rendering tests | ✓ Done | Renderer behavior is tested, including privacy-sensitive redaction output. | Broader snapshot-style image comparison could still help. |
| Capture tests | ~ Partial | Geometry, permissions, scrolling stitcher, and document behavior are tested. | Live ScreenCaptureKit and Accessibility capture flows still rely heavily on manual QA. |
| Video export tests | ~ Partial | Planning, format handling, capped-size export behavior, and temp cleanup have test coverage. | More end-to-end media export coverage would help where CI permits. |
| Error recovery UX | ~ Partial | The app surfaces many errors and guardrails. | More retry and recovery affordances inside the UI would help. |

### Accessibility, Internationalization, And UX Polish

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| Keyboard-only workflows | ~ Partial | Core app commands and some editor actions have shortcuts. | More tool shortcuts, focus movement, and keyboard canvas manipulation are still missing. |
| VoiceOver and accessibility coverage | ~ Partial | A small amount of accessibility labeling is present, and many SwiftUI controls inherit native behavior. | There is no evidence of a full accessibility audit across overlays, canvas, inspector, or video timeline. |
| High contrast and reduced motion support | x Not done | No explicit support for reduced motion or high-contrast behavior was found. | Needed before wider accessibility claims. |
| Localization infrastructure | x Not done | User-facing strings are effectively hard-coded English today. | Add a string catalog before any serious localization pass. |
| Responsive window layout | ~ Partial | The app uses adaptive SwiftUI layout patterns in places. | More QA is still needed for small windows and future localized text growth. |
| Native macOS polish | ~ Partial | The app is native and functional, with solid command/menu integration. | Visual hierarchy and premium feel still lag behind high-end macOS capture tools. |

### Observability, Support, And Release Readiness

| Requirement | Status | Current implementation | Remaining gap or limitation |
| --- | --- | --- | --- |
| In-app support links | ✓ Done | Help links to the website, privacy policy, and Discord support. | Add support flows that gather useful diagnostics. |
| Internal diagnostics logging | ~ Partial | Internal logging exists for scrolling capture, history preview loading, and video export. | This is not yet a support-grade diagnostics system. |
| User-facing diagnostics bundle export | ✓ Done | Settings > Privacy > Export Diagnostics writes a local JSON report with sanitized app/build target, macOS, feature flags, permissions, display summaries, archive/clipboard/video-relevant storage summaries, connected-device state, launch-at-login state, and recent sanitized statuses. | Extend carefully as support needs grow; do not include screenshots, OCR text, clipboard contents, annotation text, document data, window titles, or raw paths. |
| Crash reporting | x Not done | No crash reporting integration was found. | Keep privacy-first if added. |
| Product analytics | x Not done | No analytics integration was found. | Keep opt-in and local-first if ever added. |
| Release automation | ~ Partial | `FASTLANE.md` and project-local Fastlane lanes exist for doctoring, TestFlight, and release submission. | Production release automation is still documented as not fully proven end-to-end in this repo. |
| Documentation coverage | ~ Partial | Help, README, screenshot format docs, video format docs, performance profiling docs, and Fastlane docs are in place. | Broader release-facing visuals and walkthrough media are still missing. |

## Implementation Strengths

- Screenshot architecture is correctly non-destructive: base image, annotation state, crop, export, and persistence are separate concepts.
- Editor mutations are command-driven and testable.
- Screenshot history, autosave, recovery, recycle bin, OCR indexing, and archive management are far more complete than a simple capture tool.
- Clipboard History is integrated as a first-class local timeline rather than a separate utility: it includes normal clipboard items and SnipSnipSnip screenshots, with privacy filters and password-manager ignores built in.
- The `.sss` package is open, documented, and easy to inspect.
- Privacy posture is strong for a local-first screenshot tool: metadata-stripped exports, non-destructive redaction in-editor, and Private Capture controls are already shipped.
- Pro UI Map is a distinctive structured screenshot workflow: it can preserve searchable interface metadata and element geometry beside the screenshot, then let users inspect, pin, export, and render those elements without flattening them into the base image.
- Pro scrolling capture has a real service boundary with dedicated diagnostics logging, stitching logic, partial-result handling, and tests.
- The video stack is real, not placeholder: native ScreenCaptureKit recording, editable packages, trim state, poster frames, and size-constrained MP4 exports are all present.
- In-app Help is unusually complete and appears to move with the product rather than lag behind it.

## Implementation Risks And Clear Gaps

- Pro scrolling capture is implemented, but still not hardened enough to treat as fully complete across the app landscape.
- Pro connected iPhone/iPad screenshot capture is implemented in the self-release capture path and now reports runtime stream interruptions, but still needs broader device compatibility validation.
- Screenshot presentation styling is shipped for polished static output, but richer gradients, frames, social layouts, pinned screenshots, and multi-capture composition are still absent.
- Video editing is still a trim-and-export workflow, not a full demo-editor workflow.
- Global hotkeys are customizable but intentionally background-only while the app is active, which may surprise power users.
- Clipboard History source-app filtering is inherently best-effort because macOS pasteboard changes do not always include reliable origin metadata.
- Layer ordering commands and the standalone Layers window are shipped, including drag reorder; visibility toggles and locking are still intentionally deferred until the annotation model and package format support them.
- `.sssvideo` documentation is now published; keep it current with schema updates.
- Accessibility depth and localization infrastructure are both behind the rest of the product.
- User-facing diagnostics export is shipped; crash reporting is still absent.
- The old phase roadmap is no longer an accurate representation of the shipped product and should not be treated as planning truth.

## Major Not-Done Areas

### Tier 1: Close The Screenshot Product Gap

- Richer screenshot presentation/export layers: gradients, browser or device frames, social aspect ratios, and reusable templates.
- Layer visibility toggles and locking, building on the shipped standalone Layers window.
- Capture presets and richer shortcut behavior for power users.
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
- Video overlays, speed controls, volume editing, export cancellation, and eventually multi-clip editing if scope expands.

### Tier 3: Workflow And Ecosystem Depth

- App Intents, Shortcuts, and URL scheme automation.
- Optional upload destinations and share links.
- Collections, tags, favorites, or projects in history.
- Stronger support workflows built on the shipped local diagnostics bundle.
- More polished preset and template workflows for screenshots and videos.

### Tier 4: Harden SnipSnipSnip Pro

- Scrolling capture hardening across more apps, browsers, sticky headers, dynamic content, and virtualized lists.
- Connected iPhone/iPad screenshot capture QA across device families, orientations, trust/unlock state, stream interruptions, disconnects, and no-device empty states.
- Clearer Pro diagnostics and fallback messaging when Accessibility scrolling or connected-device streams are unavailable.

## Suggested Engineering Priorities

1. Treat `FEATURE_LIST.md` as the truth source and archive or rewrite the obsolete phase roadmap.
2. Keep screenshot and video format docs versioned and in sync with schema changes.
3. Extend the shipped screenshot presentation/export model with gradients, frames, reusable templates, and aspect ratios.
4. Add layer visibility and locking metadata to the existing Layers window, with additive `.sss` schema, renderer, hit-testing, export, and migration behavior.
5. Harden SnipSnipSnip Pro capture with diagnostics, compatibility coverage, and fallback flows.
6. Add conflict detection and keyboard-capture UX polish for customizable global hotkeys.
7. Introduce a richer video timeline model before attempting zooms, captions, overlays, or multi-clip work.
8. Add stronger privacy-oriented share warnings for editable redaction documents and keep support diagnostics fields current.
9. Build accessibility and localization foundations before broader distribution.

## Current Product Position

SnipSnipSnip is already a strong local-first screenshot product with a meaningful editor, archive system, presentation styling, and local drag-out sharing. It also has a real, useful first-generation recording stack. SnipSnipSnip Pro extends that product with advanced capture workflows: scrolling capture, connected iPhone/iPad screenshot capture, and UI Map capture. The overall product family is not yet an ultra-premium capture suite because richer screenshot templates, advanced video polish, automation depth, Pro capture hardening, and support readiness are still behind the rest of the app.

That is now the accurate state of the product family: standard screenshot capture, editing, presentation styling, local diagnostics export, and drag-out sharing are largely real and shipped; Pro UI Map is implemented as a unique structured screenshot workflow; Pro scrolling capture and connected iPhone/iPad screenshot capture are still partial; richer presentation templates, advanced video editing, automation, localization, and accessibility depth are still not done.
