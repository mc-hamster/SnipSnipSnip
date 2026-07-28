---
description: "Canonical native macOS design language for SnipSnipSnip SwiftUI and AppKit interfaces."
status: active
last_reviewed: 2026-07-26
---

# SnipSnipSnip Design Language

This document is the required design reference for user-visible SwiftUI and AppKit work. It describes the shipped interface, not a visual aspiration. Apple system components and current Human Interface Guidelines remain authoritative when platform behavior changes.

## Principles

1. **Start with macOS structure.** Prefer windows, toolbars, sidebars, lists, forms, sheets, menus, popovers, inspectors, and standard controls before custom presentation.
2. **Keep layers distinct.** Content is the screenshot, video, guide, history, settings, or explanatory information. Navigation and controls sit above content. Transient overlays float above both.
3. **Use adaptive semantics.** Use system backgrounds, semantic label colors, SF Symbols, native focus, and the user's macOS accent color. Do not simulate semantic colors with fixed RGB values or white-opacity text.
4. **Use Glass functionally.** Liquid Glass belongs to system navigation and control layers or to an approved floating overlay. It is not a generic card background.
5. **Keep color meaningful.** Use the accent color for selection and primary interaction, red for destructive/error states, orange for warnings or setup attention, and green for success or allowed states. Product areas do not receive decorative rainbow identities.
6. **Make state redundant.** Selection, warnings, success, and disabled states use labels, symbols, shape, or placement as well as color.
7. **Adapt to the person.** Custom presentation must respect Light and Dark appearance, Increase Contrast, Reduce Transparency, Differentiate Without Color, Reduced Motion, keyboard access, and VoiceOver.
8. **Keep authored dark surfaces content-driven.** Fixed dark presentation is reserved for media, screenshot canvases, and desktop overlays where darkness materially supports the content.

## Workflow Language

Use one product vocabulary across the main window, setup flows, menus, editors, floating controls, Settings, Help, tooltips, accessibility labels, and completion notices.

`Docs/WorkflowLexicon.md` is the canonical detailed reference for these terms, their definitions, the from/to migration ledger, intentional exceptions, and maintenance rules.

### Things people make

- **Screenshot** is one captured or imported image.
- **Comparison** is a Before and After pair reviewed together.
- **Steps** is a manually assembled set of ordered, captioned screenshots.
- **Combined Image** is multiple captures or images arranged as one result. `Collection` may remain the internal model term for this composition purpose, but it is not its user-facing name. Clipboard History may still use collection for its unrelated item-organizing feature.
- **Guide** is a workflow captured into action-aware editable steps, with optional source video.
- **Video** is a time-based screen recording.
- Create may ask goal-oriented questions such as Capture a screenshot, Compare two versions, Explain a process, and Combine images. When Explain a process branches, name the durable destinations explicitly as **Record a Guide** and **Build Steps manually**.

### Sources and acquisition

- Use **Region**, **Window**, and **Screen** consistently for the primary still, Guide, and video sources. Use **App** only where Guide follows one app across its windows.
- Use **Display** only when identifying or configuring a physical monitor inside a Screen choice. Do not use Full, Full Screen, Fullscreen, Screen, and Display as interchangeable visible labels.
- Use **Scrolling Content**, **Connected Device**, and **Existing Image** for the other source concepts. Group Screen Inspector and specialized paths under **More ways to capture** because they are acquisition methods rather than peers of Region, Window, and Screen.
- **Scrolling Capture** may name the permission-dependent scrolling-and-stitching workflow in explanatory, status, and troubleshooting copy. Its source and action labels remain **Scrolling Content** and **Capture Scrolling Content**; the compact capture header may abbreviate the action to **Scroll**.
- **Capture** acquires a still image. **Add** brings content into an existing document. **Import** reads a file. **Paste** adds clipboard content. **Record** acquires time-based media. **Inspect** reads information without primarily creating a document.
- The **Capture** command menu may group the app's acquisition workflows, just as other macOS command-menu titles group related actions. Commands inside it still use the specific action verbs above.

### Stages, lifecycle, and output

- Use workflow-specific stage verbs: Edit for a Screenshot, Capture After and Review for a Comparison, Add Step and Order & Caption for Steps, Add Image and Arrange for a Combined Image, Capture and Edit Guide for a Guide, and Record and Trim for Video. Polish is the optional presentation stage shared by screenshot documents.
- **Back** navigates while preserving state. **Cancel** leaves an uncommitted setup or operation. **Done** commits or leaves a nested editing scope. **Stop** ends active acquisition and keeps the result. **Discard** abandons acquired unsaved work. **Close** closes a utility or completed window. **Restore** recovers stored work. **Delete** moves recoverable work to the Recycle Bin; **Empty** or **Permanently Delete** names irreversible removal.
- **Save** preserves editable work. **Copy** puts the visible result on the clipboard. **Export** creates a distributable file or file set. **Share** invokes macOS sharing. **Float** creates a temporary reference. **Drag** delivers the current output by dragging. **Reveal in Finder** locates an existing file.
- Status language distinguishes subsystems: Guide is Capturing, Video is Recording, and Clipboard History is Monitoring. Each may be Paused; never label clipboard monitoring as Recording. Keep **Screen Recording** unchanged when naming the macOS permission.

### Snip Library and recovery

- **Snip Library** is the user-facing umbrella for reusable and recoverable screenshot work.
- **Recent Snips** contains recently available work. **Snip History** contains searchable sessions and checkpoints. **Change History** is scoped to the currently open document. **Recycle Bin** contains deleted but recoverable snips. **Recover Last Session** is the transient interrupted-work path.
- Archive remains an internal storage concept. Settings may expose **Snip History Storage** for location, size, and cleanup, but Archive is not a peer user goal or source beside Recent Snips and Snip History.

## Layer and Material Decisions

| Context | Required treatment | Glass policy |
| --- | --- | --- |
| Window content, forms, inspectors, lists, Help, settings | Adaptive system background, `Form`, `List`, `Section`, `GroupBox`, or standard material | No custom Glass |
| Native toolbar, sidebar, sheet controls | Standard SwiftUI/AppKit component | Let the system provide Glass |
| Primary completion action | Native prominent button style | Prominent Glass is allowed |
| Secondary action | Native standard, bordered, plain, or ordinary Glass button by context | Do not add custom tint layers |
| Screenshot/video/desktop overlay control | Narrowly scoped floating overlay style | Custom Glass allowed only if registered below |
| Media or screenshot canvas | Content-appropriate neutral or dark background | Not app chrome; preserve content fidelity |
| Status or permission banner | Adaptive semantic background plus symbol, label, and action | Standard material; opaque with Reduce Transparency |

## Approved App Patterns

### Onboarding

- Keep first-run setup to the smallest sequence of required decisions. Use a compact native progress indicator for short linear setup flows instead of dedicating window width to a persistent sidebar.
- Present replay as a single grouped-form setup summary so existing users can review or update choices without repeating the first-run sequence.
- Use one accent color for selection and primary actions.
- Show On/Off, Allowed/Needs Setup, or other status text when a step has meaningful state.
- Keep Back and Continue in a functional footer. Continue is the sole prominent action, and permission setup or restart replaces Continue when it is required.
- Place optional capability discovery behind a native disclosure during setup and follow first-run completion with a concise, dismissible exploration card in the main capture window.
- Do not use full-window decorative gradients, colored glow fields, per-step accent themes, or content Glass cards.

### Sheets and setup flows

- Use a grouped `Form` and native controls.
- Keep Cancel secondary and provide only one prominent completion action.
- Use radio groups or pickers for mutually exclusive choices and show contextual detail near the selection.

### Main window and editors

- Capture is the main window's persistent workflow, so its primary actions belong in a compact in-content header rather than the title-bar toolbar. With no screenshot document open, the adaptive header keeps the product name and textual readiness status above Create, Region, Window, Screen, conditional Scroll, Repeat, Presets, conditional Guide capture, and Record, with Auto Copy aligned separately. Region, Window, Screen, and their global shortcuts remain one-action new Screenshot paths. Guide creation appears only when the build exposes `guideCapture`; opening and editing an existing `.sssguide` document remains a shared document workflow and does not add a capture-header action in the App Store edition.
- The capture header uses semantic system backgrounds, native bordered controls, and an explicit status badge. It is not Glass. While a screenshot document is open, replace the generic source row with one contextual session row that names the durable goal, summarizes progress, and exposes the single most useful next action such as Capture After, Add Step, or Add Image. Keep a secondary Create entry in the header identity row for starting a different goal; new-document capture also remains available through the Capture menu and shortcuts.
- Create uses a native grouped setup form. Ask what the person wants to make before asking where pixels come from, reveal only conditional questions relevant to that goal, keep optional capture settings under Fine-tune, show a live summary, and provide one prominent completion action. Direct capture shortcuts bypass setup as Screenshot. Setup state is transactional: Cancel, permission failure, and capture cancellation must not mutate preferences or the open document.
- Reserve the native window toolbar for intentional Guide and video actions. Screenshot and composition editing do not install a native toolbar; their Inspector control belongs in the stable in-content command rows. Do not promote an entire workflow into title-bar chrome or depend on toolbar overflow for primary commands.
- Keep the main window title bar transparent and suppress its automatic separator. The in-content capture header and editor command boundaries already provide the hierarchy; with a trailing inspector, AppKit's otherwise-visible toolbar baseline stops at the inspector edge and reads as an accidental partial line.
- Keep the screenshot, guide, or video as the dominant content.
- Present contextual properties in a native trailing inspector when appropriate. Screenshot and Guide inspectors use a 280 point minimum, 320 point ideal, and 380 point maximum width and remember visibility per scene.
- Preserve spatial memory in the screenshot editor with two stable in-content command rows. The first row starts with Discard or Cancel and exposes each editing tool as a direct icon button in a consistent position, visibly clustered into Selection, Shapes, Drawing and Highlight, Text and Callout, Redaction, and Recognition and Image groups. The second row keeps History, Layers and Arrangement, Zoom, Inspector, Workspace, Output, and References and Drag Out as distinct visual groups in workflow order without a separating expanse of empty space.
- Direct output is WYSIWYG. Edit, Arrange, Steps, and Comparison Review use the simple Copy, Export, Share, Float, and Drag labels for the visible unwrapped content. Polish uses those same labels for the visible Look or Mockup preview. Do not make Plain and Styled competing choices in routine editor chrome; those remain explicit data-model and automation terms. Edit Selected Capture and Annotate Result hide document output and reference actions because their temporary editing canvases are not document export previews.
- Editor command groups use a narrowly scoped adaptive system-background container and semantic separator boundary. The group is structural—not decorative Glass—and must retain its accessibility label and stronger Increase Contrast boundary.
- Direct tool selection must show a filled background and a stronger boundary, expose a text label to VoiceOver and Help, and never rely on color alone. Use a menu only where it selects a variant of a direct command, such as redaction mode or export format—not to hide the primary tool palette behind broad categories.
- At constrained widths, preserve the direct controls and their order with horizontal access rather than replacing them with unrelated category menus or collapsing them into title-bar overflow.
- Compact auxiliary windows may use an adaptive in-content command bar when their complete command set cannot fit reliably in a title-bar toolbar. The Layers window uses Arrange and Group menus plus a separate destructive Delete action.
- Provide a labeled Inspector toggle immediately after Zoom in both screenshot command layouts, plus the View-menu Show/Hide Inspector command with Command-Option-I. Both controls share the same scene-restored visibility state.
- Guide uses a standard navigation sidebar, content detail, native trailing inspector, and native export toolbar actions. Video uses native window toolbar actions and keeps only the player stage dark.

### Multi-capture composition

- Composition follows a durable document purpose: Screenshot, Comparison, Steps, or Combined Image. Purpose determines acquisition language, the focused inspector, the next action, and the content stage. Do not expose Compare and Steps as peer geometry tiles beside Row or Grid.
- Adding the first extra image to Screenshot asks once whether to Compare, add a Step, or Combine. The choice and successful addition commit atomically; cancellation leaves Screenshot unchanged. Later additions inherit that purpose and use contextual labels rather than repeating setup.
- Comparison owns Before/After, registration, change highlighting, overlay, wipe, difference, and blink. Steps owns ordered items, captions, numbering, connectors, and pagination. Combined Image owns Auto, Row, Column, Grid, Freeform, and compatible composition templates. Screenshot exposes no layout controls.
- Polish is an optional finishing stage shared by every screenshot-document purpose. Look owns native backgrounds, spacing, borders, corners, shadows, effects, and presets. Mockup owns the existing single-slot Scene engine. Entering Polish does not apply treatment automatically, and leaving Polish returns to the prior content stage and plain visible output. When a treatment is saved, the content-stage Polish action shows a non-color-only configured indicator and announces the treatment without applying it.
- Keep the three editing scopes explicit. Arrange changes item order, size, framing, and placement; Edit Selected Capture changes one source's crop and annotations; Annotate Result changes annotations above the assembled content. Use visible Done and scope labels when leaving either annotation scope; do not overload selection state to infer which model the annotation tools mutate.
- Use native grouped inspector sections and a compact ordered item list. Small visual previews remain appropriate for choosing geometry within Combined Image or plain-language comparison outcomes within Comparison; they must include text labels, selected state beyond color, and keyboard focus.
- Canvas appearance uses a compact native Apply Theme menu for fast complete styling, with the full panel, shadow, typography, badge, connector, and divider model in an Advanced Appearance disclosure. Theme application is an undoable appearance change; user templates remain the reusable layout-plus-appearance mechanism.
- Direct manipulation must have a complete non-pointer equivalent. Reorder indicators, resize handles, comparison dividers, and framing modes expose the same actions through Items, Layers, menus, keyboard commands, and VoiceOver custom actions.
- Arrange does not show the Polish subject-placement frame or persistent outlines around unselected items. Hover uses a neutral hairline. A correctly aligned accent boundary and handles appear only after explicit canvas selection while direct manipulation has focus; logical selection alone must not fill the canvas with persistent blue bounds. The visual and accessibility frames must share the same viewport transform and remain inside the canvas after pan, zoom, resize, and Mockup wrapping. Composition-level annotations always remain above items; per-item annotations stay inside their source item.
- Steps is a manually assembled screenshot-document purpose, not a second Guide editor. Guide remains the action-aware capture, media, and tutorial workflow; labels and Help must keep that distinction explicit.
- Interactive HTML is a portable offline output, not a hosted mini-site. It uses native-looking semantic structure, responsive reflow, keyboard-operable step and comparison controls, reduced-motion behavior, metadata-stripped embedded images, escaped user text, and a deny-by-default Content Security Policy with no remote resources.
- Keep composition-specific output inside the current goal stage's Export menu. Still formats remain first; Blink animation and interactive HTML follow separators and stay visibly disabled until the current purpose is compatible. Name the 4,096 px animated safety cap in help and disclose any applied scaling in the completion notice.
- Preflight oversized raster output before opening the save operation. Use a native warning with Scale to Fit as the safe default, Paginated PDF when a Steps document can be streamed by page, and Cancel. Never wait for a failed full-resolution allocation before explaining the limit.
- A Private source permanently marks the whole composition Private. Pair the persistent Private Composition label with a privacy symbol and explanatory text; removing the source must never visually imply that the privacy state was cleared.

### Settings, Help, lists, and empty states

- Use native forms, lists, sections, search, and selection.
- Keep each standalone grouped section's heading, supporting text, and controls inside one native grouped boundary so the heading clearly belongs to its content. This applies to main-window empty states, onboarding, Help, and editor and Guide inspectors; retain native external section headers in forms and lists.
- Prefer `ContentUnavailableView` or a small native empty-state composition.
- Avoid card grids when a list, outline, form, or disclosure group communicates the same structure.

### Status and permission UI

- Pair every semantic color with a symbol and text.
- Keep permission setup visible in a neutral adaptive banner or form section, not inside decorative chrome. Confine warning color to the symbol or short status label instead of tinting a large reading surface.
- Use an opaque semantic fallback when Reduce Transparency is enabled.

## Color, Type, Shape, and Spacing

- Use `Color.primary`, `Color.secondary`, semantic AppKit colors, and `.accentColor` instead of fixed app-chrome RGB values.
- Use system text styles such as title, headline, body, subheadline, and caption. Rounded display type is limited to brief branding, not long-form reading.
- Let native controls and containers determine most corner radii, padding, row heights, and hit targets.
- Normal text must reach 4.5:1 contrast. Large text, meaningful icons, control boundaries, and selected states must reach 3:1.
- Disabled controls may be less prominent, but active controls must remain identifiable without relying on a faint hairline border.

## Accessibility Behavior

- **Reduce Transparency:** custom overlay backgrounds become opaque using semantic system colors.
- **Increase Contrast:** boundaries, focus, and selected-state indicators become stronger without changing meaning.
- **Differentiate Without Color:** color-coded state gains a checkmark, label, pattern, or shape indicator.
- **Reduced Motion:** suppress decorative transitions, morphing, and nonessential animation. Preserve only motion needed to explain direct manipulation or progress.
- **Keyboard and VoiceOver:** every icon-only action has a label and help text; controls participate in native focus order; primary and cancel actions use the appropriate keyboard shortcuts.
- **Overlay interaction:** decorative backgrounds, borders, shadows, and status ornaments must be click-through so floating HUD buttons and toggles retain their full native hit targets.

### Release-level accessibility conventions

- Treat the editor canvas as an accessibility group with synthetic annotation children ordered from front to back. Each child reports type, selected state, layer position, visible text when safe, and document geometry. Redaction contents are never exposed.
- Mirror pointer-only annotation operations through keyboard commands and VoiceOver custom actions. Layers remains the complete alternative for selection and arrangement.
- Transfer focus into sheets, popovers, inspectors, and auxiliary windows when they open, then restore it when they close. Announce permission changes, capture completion, selection changes, progress, errors, and export completion.
- Use stable accessibility identifiers for automated coverage and shared formatters for geometry, time, percentages, and color values.
- Add accessibility-specific English strings to the String Catalog when introducing new labels, values, hints, or announcements, even when broader localization is deferred.

### Permission and output status patterns

- On the empty capture screen, missing Screen Recording access uses the full permission card. When a screenshot, video, or Guide is open, retain a one-line action strip so setup remains discoverable without displacing the primary workspace; selecting the strip expands the full diagnostics.
- Screenshot output follows the visible stage. Edit, Arrange, Steps, and Comparison Review export the unwrapped edited or assembled content. Polish exports the visible Look or Mockup, falling back to that same unwrapped content when no treatment is configured. The goal-and-stage label—not repeated Plain or Styled button text—communicates that boundary. Automation continues requiring explicit Plain or Styled parameters. Do not disable content-stage JPEG or PDF merely because a configured Polish treatment needs PNG.
- Nonblocking product maturity labels use a compact accessible badge and contextual Help. Do not interrupt recurring workflows with a startup modal solely to repeat beta status.

## Custom Surface Exception Registry

Every explicit custom Glass or fixed-dark app surface must appear here. New entries require a specific content-driven reason and accessibility behavior.

| Surface and implementation | Exception and rationale | Accessibility behavior |
| --- | --- | --- |
| Guide capture HUD — `Guide/UI/GuideCaptureHUD.swift` | Floats over the desktop while a Guide is being captured and must remain compact without obscuring the source | `sssFloatingOverlaySurface` supplies an opaque semantic background with Reduce Transparency, a stronger outline with Increase Contrast, and disables nonessential animation with Reduced Motion; labels accompany state colors |
| Video recording controls — `Video/RecordingControlOverlay.swift` | Floats above recorded content and needs a distinct transient control layer | Uses the same adaptive floating-overlay behavior as the Guide HUD; recording and paused states include symbol and text |
| Video player and export overlays — `Video/VideoEditorView.swift` | A dark content stage prevents unused player area from competing with video; playback metadata and export progress must float above the media | The stage does not carry application state; overlay panels use the opaque/high-contrast/reduced-motion fallback; controls outside the player use native adaptive chrome |
| Editor, content-stage, and Polish canvas notices — `Editor/EditorView.swift` and `Editor/PresentationModeCanvasView.swift` | A notice must remain legible over arbitrary screenshot pixels | Uses the adaptive floating-overlay behavior and semantic text; canvas colors never communicate application state |
| History preview overlays — `Editor/EditorInspectorView.swift` | Full-size screenshot previews temporarily float over the editor and include an instruction badge and actions | Overlay panels become opaque, strengthen boundaries, retain labeled actions, and suppress nonessential movement under the corresponding accessibility settings |
| Floating screenshot reference controls — `App/FloatingReferenceController.swift` | Controls overlay the referenced screenshot and must stay legible without materially covering it | System materials provide an opaque fallback and increased boundary contrast; every action is labeled and movement is direct-manipulation only |
| Capture feedback and selection overlays — `Capture/CaptureFeedbackOverlay.swift`, `Capture/RegionSelectionOverlay.swift`, `Capture/WindowSelectionOverlay.swift`, `Capture/DisplaySelectionOverlay.swift`, and `Capture/ScrollingCaptureProgressOverlay.swift` | Must remain visible on top of arbitrary desktop pixels during direct manipulation | Use simultaneous border/fill/label cues; strengthen boundaries for Increase Contrast; avoid transparency-dependent meaning; animation is functional progress or direct manipulation |
| Screen Ruler and Screen Inspector — `App/ScreenRulerController.swift` and `App/ScreenInspectorController.swift` | Desktop measurement tools intentionally float over arbitrary content; the inspector magnifier is a fixed-dark content viewport | System materials provide opaque and increased-contrast fallbacks for controls; measurement marks use simultaneous lines and labels; reduced motion removes no information |
| Connected-device preview — `Capture/ConnectedDevicePreviewWindowController.swift` | Unused preview area is black to preserve the connected display's content and aspect ratio | Black is confined to the media viewport; all surrounding controls use adaptive system chrome and labeled state |

## Prohibited Patterns

- Fixed dark app-chrome backgrounds without a registered content-driven exception.
- Decorative multi-hue glow fields behind reading-heavy content.
- White-opacity text in place of semantic label colors.
- Glass applied to content cards, inspector sections, forms, or ordinary list rows.
- New generic Glass-card, Glass-surface, or tinted-button abstractions.
- Low-opacity borders used as the only affordance for an active control.
- Selection or status conveyed only through hue.
- Mixing text-only and icon-only actions inside one visual toolbar group without a functional reason.
- `ToolbarItemGroup` around labeled Glass actions when it merges distinct commands into a segmented rectangular control.
- Forcing a dense editor or auxiliary-window command set into one non-wrapping window-toolbar row.
- Replacing a familiar direct tool palette with broad category menus when the direct controls fit in the normal window.
- Using a flexible spacer to detach document/output actions from the editor controls that precede them.
- Removing the visible group boundaries that distinguish related direct editor controls.
- Showing the generic new-capture source strip while a screenshot document is open instead of the goal-specific session row. Global shortcuts and the Capture menu must retain their new-document meaning.
- Adding another source without first establishing purpose for a Screenshot document, or asking for purpose again after the document already has Comparison, Steps, or Combined Image purpose.
- Using one ambiguous Edit command for both item annotations and whole-composition annotations.
- Showing document output, Add Image, or Polish navigation while Edit Selected Capture or Annotate Result is displaying a temporary scoped editing canvas.
- Drawing hit regions, unselected item bounds, or the Polish subject-placement frame as persistent Arrange canvas chrome.
- Exposing Presentation, Layout, Style, or Scene as the primary navigation vocabulary when the user-facing goal, content stage, Look, or Mockup label is available.

## UI Review Checklist

- [ ] Uses the appropriate native window, toolbar, sidebar, sheet, list, form, inspector, menu, or popover structure.
- [ ] Keeps Glass out of the content layer unless the exception registry explicitly allows it.
- [ ] Uses semantic text/background colors and the system/user accent.
- [ ] Uses red, orange, and green only for their documented semantic roles.
- [ ] Preserves all actions at minimum window size through reflow, menus, or native toolbar overflow.
- [ ] Keeps distinct labeled commands visually separate; no unintended segmented rectangles appear.
- [ ] Keeps dense command sets usable without depending on a single compressed toolbar row.
- [ ] Preserves stable positions and one-click access for frequently used editor tools.
- [ ] Uses visible, accessibility-labeled groups for related editor tools and command families.
- [ ] Works in Light, Dark, and automatic appearance.
- [ ] Works with every macOS accent color.
- [ ] Works with Increase Contrast, Reduce Transparency, Differentiate Without Color, and Reduced Motion.
- [ ] Meets text and non-text contrast targets.
- [ ] Supports keyboard navigation, native focus rings, VoiceOver labels, default action, and cancel action.
- [ ] Updates in-app Help when navigation, labels, placement, or workflow changes.
- [ ] Updates this document if a reusable pattern or exception changed.

## Apple References

- [Human Interface Guidelines](https://developer.apple.com/design/human-interface-guidelines/)
- [Designing for macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos/)
- [Adopting Liquid Glass](https://developer.apple.com/documentation/TechnologyOverviews/adopting-liquid-glass)
- [Materials](https://developer.apple.com/design/human-interface-guidelines/materials)
- [Color](https://developer.apple.com/design/human-interface-guidelines/color)
- [Accessibility](https://developer.apple.com/design/human-interface-guidelines/accessibility/)
- [Toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars)
- [Windows](https://developer.apple.com/design/human-interface-guidelines/windows)
- [Sidebars](https://developer.apple.com/design/human-interface-guidelines/sidebars)
- [Sheets](https://developer.apple.com/design/human-interface-guidelines/sheets)
