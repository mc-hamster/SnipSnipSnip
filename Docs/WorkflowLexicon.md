---
description: "Canonical product terminology for SnipSnipSnip workflows, actions, stages, statuses, libraries, and outputs."
status: active
last_reviewed: 2026-07-28
---

# SnipSnipSnip Workflow Lexicon

## Purpose and Authority

This document defines the product language used across SnipSnipSnip. Its purpose is to make every workflow feel like part of one app rather than a separate product with a competing vocabulary.

Use this lexicon for all user-visible language:

- Windows, sheets, menus, buttons, labels, tooltips, notifications, and completion messages.
- Help, onboarding, empty states, Settings, and permission explanations.
- Accessibility labels, descriptions, and action names.
- User-visible App Intent and automation names.
- Tests that assert user-visible text.

This is the canonical terminology reference. `Docs/DesignLanguage.md` defines the interaction and visual principles that this vocabulary supports.

Internal type names, persisted values, migration keys, and raw automation identifiers may retain older terminology when changing them would create compatibility risk. Those internal names must not leak into user-visible copy.

## Product-Language Model

SnipSnipSnip uses one shared language model:

1. A person chooses what they want to **create**.
2. They choose a **source** or begin an activity.
3. The app uses a workflow-specific **stage** to say what comes next.
4. Clear **status** language explains any ongoing activity.
5. Consistent **lifecycle** and **output** verbs finish the work.

The same word should represent the same kind of concept everywhere:

- **Nouns** name things, sources, destinations, or states.
- **Verbs** name actions.
- **Stages** name the work the person is doing now or should do next.
- **Statuses** describe an ongoing system activity.

Do not use one term as both a product object and an unrelated action when a clearer verb exists.

## Things People Create

These nouns identify the major outputs and workflows.

| Canonical term | Meaning | Do not substitute |
| --- | --- | --- |
| **Screenshot** | A single still image captured from the screen or imported into the editor. | Snip, capture, image, or shot when naming the resulting object. |
| **Comparison** | A before-and-after visual composed for comparison. | Before/after capture as the workflow name. |
| **Steps** | An ordered, captioned sequence of still images. | Collection, guide, or walkthrough. |
| **Combined Image** | Multiple still images arranged into one composed image. | Collection, collage, or combined capture. |
| **Guide** | A procedure created by recording interactions or building steps manually. | Recording when naming the resulting guide. |
| **Video** | A full-motion screen recording. | Recording when naming the resulting object or workflow. |

### Important distinctions

- A **Screenshot** is the thing created; **Capture** is the action that creates it.
- **Steps** are an ordered still-image output. A **Guide** is a procedural document that may be recorded from interactions or built manually.
- A **Combined Image** is one arranged visual output. It is not a generic collection of saved items.
- **Video** is the product object. **Recording** describes the activity that produces it.

### Creation goals

When asking what someone wants to make, use:

- Create a Screenshot
- Create a Comparison
- Create Steps
- Create a Combined Image
- Create a Guide
- Create a Video

Guide entry choices use:

- Record a Guide
- Build Steps Manually

## Sources

Source nouns describe where content comes from. They are not action labels by themselves.

| Canonical source | Meaning | Notes |
| --- | --- | --- |
| **Region** | A selected rectangular area of the screen. | Pair with **Capture** for an action. |
| **Window** | A selected app window. | Pair with **Capture** for an action. |
| **Screen** | The full visible contents of a screen. | Use instead of Full, Full Screen, or Fullscreen in product copy. |
| **App** | The application observed while recording a Guide. | Use for Guide recording scope. |
| **Display** | A physical monitor selected from available hardware. | Reserve this term for hardware selection. |
| **Scrolling Content** | Content captured beyond the currently visible viewport. | The explanatory workflow name **Scrolling Capture** may remain. |
| **Connected Device** | A supported external device used as the capture source. | Pair with **Capture** for an action. |
| **Existing Image** | An image already available in a file, photo source, or library. | Use instead of Add Existing. |
| **Clipboard** | Content currently available to paste. | Pair with **Paste** for an action. |

Use **More Ways to Capture** as the umbrella for less common capture sources.

**Quick Capture** names the main-window group of one-action Screenshot sources and actions: Region, Window, Screen, Scroll when available, Repeat Last, and Presets. **Scroll** is the compact header label for Capture Scrolling Content, **Repeat Last** is the compact header label for Repeat Last Capture, and **Presets** remains a menu because it contains a variable set of named targets. **Create Something** names the adjacent guided area with direct Comparison, Steps, and Combined Image entries; each opens setup with that result selected so the user only chooses its source and options. Direct Screenshot setup is omitted because Quick Capture already provides the primary one-click Screenshot paths. **Record** names the adjacent activity area with direct Region, Window, Screen, Guide when available, and connected-device entries. These are navigation group labels, not new workflow or output nouns.

## Action Verbs

Actions should start with a verb. Choose the verb that accurately describes how content enters or changes the workflow.

| Canonical verb | Use it for | Examples |
| --- | --- | --- |
| **Capture** | Creating still content from a screen, window, region, scrolling surface, or connected device. | Capture Region; Capture Window; Capture Screen. |
| **Add** | Extending the current composition or sequence with another item. | Add Step; Add Image. |
| **Import** | Bringing an existing file into the app. | Import Image. |
| **Paste** | Bringing clipboard content into the app. | Paste from Clipboard. |
| **Choose** | Selecting an existing item from a library or picker. | Choose Existing Image. |
| **Record** | Beginning an observed, time-based activity. | Record a Guide; Record Video. |
| **Inspect** | Examining screen or interface information without making it the primary output. | Inspect Screen. |
| **Edit** | Modifying content or annotations. | Edit Screenshot; Edit Guide. |
| **Crop** | Adjusting the visible image bounds without changing source pixels. | Crop Image. |
| **Arrange** | Positioning multiple visual items spatially. | Arrange Images. |
| **Review** | Checking a prepared result before finishing. | Review Comparison. |
| **Polish** | Applying optional finishing or presentation treatment. | Polish Screenshot. |

### Capture actions

Use these constructions:

- Capture Region
- Capture Window
- Capture Screen
- Capture Frontmost Window
- Capture Scrolling Content
- Capture Connected Device
- Repeat Last Capture

**Capture** may be an umbrella label when the destination or source is supplied by surrounding context. Do not use a bare source noun such as **Region** as an action when the control needs to stand on its own.

### Source-specific intake

Do not use **Add** for every way content can enter the app:

- Use **Capture** for content created from a live screen source.
- Use **Import** for a file.
- Use **Paste** for clipboard content.
- Use **Choose** for an existing item selected from a library or picker.
- Use **Add** after the content is part of the current workflow.

## Workflow Stages

Stage names should describe the current task or the next meaningful task. They should not read like vague completion states.

| Workflow | Canonical stages or next actions | Meaning |
| --- | --- | --- |
| Screenshot | **Edit** → optional **Polish** | Annotate or adjust the screenshot, then optionally apply presentation treatment. |
| Comparison | **Capture After** → **Review** → optional **Polish** | Acquire the second state, check the comparison, then optionally finish its presentation. |
| Steps | **Add Step** → **Order & Caption** → optional **Polish** | Collect the next still, organize the sequence, and add explanatory text. |
| Combined Image | **Add Image** → **Arrange** → optional **Polish** | Add visual material, position it, then optionally apply finishing treatment. |
| Guide | **Record a Guide** or **Build Steps Manually** → **Edit Guide** | Create the procedure, then refine its steps and explanation. |
| Video | **Record Video** → **Trim Video** | Record full-motion content, then adjust its bounds. |

Use singular stage labels such as **Add Step** and **Add Image** when the immediate action adds one item. Use the plural product noun, such as **Steps**, when naming the workflow or result.

After a repeatable Before capture, the Comparison stage uses **Repeat Last Capture for After** as its primary action. This preserves the canonical **Repeat Last Capture** action while naming the After destination that completes the pair. If Before cannot be repeated, use **Capture After** and let the source menu default to Region.

## Activity Statuses

Statuses describe what the app is doing now. They must identify the activity when a generic status would be ambiguous.

### Guide

- Starting Guide
- Guide Capturing
- Guide Paused
- Finishing Guide
- Discarding Guide

Use **capturing** for the observed interaction activity because a Guide is not a video recording.

### Video

- Recording
- Paused
- Finishing

Within an explicitly identified Video workflow, the shorter statuses are sufficient. Use **Video Recording** only when surrounding context does not establish that the activity is video.

### Clipboard

- Monitoring
- Monitoring Paused

Clipboard history observes new clipboard content; it does not record the screen. Never describe clipboard monitoring as **Recording**.

### Permission terminology

**Screen Recording** is the macOS permission name and must remain unchanged when referring to that system permission, even when the app feature is Capture, Guide, or Video.

## Lifecycle Verbs

Lifecycle verbs have consistent consequences across workflows.

| Canonical verb | Meaning |
| --- | --- |
| **Back** | Return to the preceding choice without completing the current workflow. |
| **Cancel** | Stop the current temporary operation without accepting it. |
| **Done** | Accept the current work and leave the editing or arrangement stage. |
| **Stop** | End an ongoing capture, recording, or monitoring session while retaining the result when applicable. |
| **Discard** | Abandon the current unsaved result. |
| **Close** | Dismiss a window or presentation without implying deletion. |
| **Restore** | Return an item from the Recycle Bin or recovery state. |
| **Delete** | Move an item to the Recycle Bin when recovery is available. |
| **Empty** | Remove all items from the Recycle Bin. |
| **Permanently Delete** | Irreversibly remove a specific item. |

Do not use **Clear** as a synonym for irreversible deletion. Do not use **Done** to end an ongoing recording when **Stop** states the consequence more clearly.

## Output Verbs

| Canonical verb | Meaning |
| --- | --- |
| **Save** | Write the result to a chosen or configured storage destination. |
| **Copy** | Put the result on the clipboard. |
| **Export** | Produce a file or alternate format from the current result. |
| **Share** | Send the result through the macOS sharing system. |
| **Float** | Keep the result visible in a floating presentation. |
| **Drag** | Provide the result as a draggable item for another destination. |
| **Reveal in Finder** | Show an existing file in Finder. |

Use **Reveal in Finder**, not **Open in Finder**, when Finder selects and displays an existing file rather than opening the file itself.

### Interactive HTML comparison controls

Use **Compare Using** for the exported Comparison view selector. Its choices are **Side by Side**, **Wipe**, **Overlay**, **Blink**, **Difference**, and **Highlight Changes**. Use **Show Both**, **Before**, and **After** for the Side by Side focus controls. Use **Reveal After**, **After Opacity**, **Time Per Image**, and **Result Visibility** for mode-specific adjustments. Shared inspection uses **Zoom Out**, **Fit**, and **Zoom In**. **Fit** means the complete active comparison area is kept in view; the branding footer is not part of the fit calculation.

When Reduce Motion is enabled, Blink starts paused. Use **Play Anyway** for the explicit action that begins Blink despite that preference. Explain the paused start as a respectful default, not an error, and keep **Before** and **After** available for manual inspection.

Keep **Before**, **After**, **Difference**, and **Highlight Changes** labels above screenshot pixels in every exported comparison mode. Do not overlay these labels on captured content.

Keep these labels action-oriented and concrete. Do not expose implementation terms such as comparison mode, blend amount, poster frame, or rendered result in the exported viewer.

Use **Created with SnipSnipSnip** for the exported HTML attribution, with only **SnipSnipSnip** linked to the canonical product website. A small decorative app logo may sit beside the attribution. Keep both visually secondary, open the product page separately, and send no referrer. Do not replace them with a promotional call to action, badge, or large logo.

### Interactive HTML export progress

Use **Exporting Interactive HTML** for the active export title and **Cancel Export** for its cancellation action.

Use short, literal stage labels beneath the progress bar:

- **Preparing Interactive HTML…**
- **Rendering images…**
- **Encoding images…** and **Encoding image _x_ of _y_…**
- **Building Interactive HTML…**
- **Saving Interactive HTML…**
- **Finishing Interactive HTML export…**
- **Cancelling Interactive HTML export…**

Use **Interactive HTML export cancelled.** for the non-error completion notice after cancellation.

## Library and History Terms

Library terms identify distinct scopes. Do not shorten them to generic **Library** or **History** when the scope would become ambiguous.

| Canonical term | Meaning | Do not substitute |
| --- | --- | --- |
| **Snip Library** | The main place for browsing saved SnipSnipSnip content. | Library. |
| **Recent Snips** | A limited, recent subset of captured content. | Recent captures. |
| **Snip History** | The historical list of saved snips. | Capture History, Archive History, or visible Archive. |
| **Change History** | Prior editable versions or autosaved states of an item. | Autosave History. |
| **Recycle Bin** | Recoverable deleted items. | Trash when naming the app feature. |
| **Recover Last Session** | Recovery of work from the most recent interrupted session. | Restore session or crash archive. |
| **Snip History Storage** | Settings that control retention or storage for Snip History. | Archive settings. |

**Archive** may remain an internal storage or implementation term. It should not name the general user-facing history experience.

## Editor Annotation Terms

| Term | Canonical meaning | Avoid as a synonym |
| --- | --- | --- |
| **Arrow** | The regular free-form arrow annotation and the fixed label for its split-control family. | Pointer, connector, or leader when naming the tool. |
| **Numbered Arrow** | An arrow annotation with an automatically assigned sequence number in a badge at its tail. | Step Arrow or numbered Callout. |
| **Sequence** | The contiguous semantic order of Numbered Arrows in the current annotation scope. It is independent of layer order. | Layers, z-order, or Steps. |
| **Resequence** | Select every Numbered Arrow in the order its number should appear. | Rearrange Layers or renumber manually. |

Use **Move Earlier** and **Move Later** for changing one Numbered Arrow's sequence position. Use **Resequence…** for the canvas mode that assigns the complete order. A Screenshot, an individual source capture, and the assembled result each maintain their own Numbered Arrow sequence.

## Canonical From/To Ledger

The left side contains prior, competing, or ambiguous language. The right side is the canonical product language.

### Nouns and destinations

| From | To |
| --- | --- |
| Full | Screen |
| Full Screen | Screen |
| Fullscreen | Screen |
| Collection | Combined Image |
| Add Existing | Existing Image |
| Recording, when naming a workflow or result | Video |
| Video Recording, when naming a workflow or result | Video |
| Library | Snip Library |
| Capture History | Snip History |
| Archive History | Snip History |
| Archive, when visible as the history destination | Snip History |
| Autosave History | Change History |
| Archive, when naming retention settings | Snip History Storage |
| recycle bin | Recycle Bin |
| Hotkeys | Global Shortcuts |
| Global Hotkeys | Global Shortcuts |
| Global Capture Hotkeys | Global Shortcuts |
| Screen, when naming physical monitor hardware | Display |
| Fullscreen Display | Display |
| source recording | source video |
| full recording | full-motion source video |

### Actions

| From | To |
| --- | --- |
| Snip | Capture |
| Region Capture | Capture Region |
| Window Capture | Capture Window |
| Full Screen Capture | Capture Screen |
| Capture Fullscreen | Capture Screen |
| Frontmost Window Capture | Capture Frontmost Window |
| Scrolling Capture, when naming a source | Scrolling Content |
| Scrolling Capture, when naming an action | Capture Scrolling Content |
| Connected Device, when used as an action | Capture Connected Device |
| Guide | Record a Guide |
| Create a Guide | Record a Guide |
| Record as I work | Record a Guide |
| Add captures myself | Build Steps Manually |
| Add, as a generic intake action | Import, Paste, Choose, or Capture according to the source |
| Capture Next Step | Add Step |
| Search captures | Search Snip History |
| Open in Finder | Reveal in Finder |
| Resume Clipboard | Resume Monitoring |
| Pause Clipboard | Pause Monitoring |
| Clear | Permanently Delete |
| Delete Forever | Permanently Delete |
| Empty Now | Empty Recycle Bin |

### Stages

| From | To |
| --- | --- |
| Editing | Edit |
| Before Captured | Capture After |
| Ready | Review |
| Collecting Steps | Add Step |
| Arranging Steps | Order & Caption |
| Collecting Combined | Add Image |
| Arranging Combined | Arrange |

### Statuses

| From | To |
| --- | --- |
| Guide Recording | Guide Capturing |
| Guide Paused | Guide Paused |
| Video Recording, inside the Video workflow | Recording |
| Recording Paused, inside the Video workflow | Paused |
| Clipboard Recording | Monitoring |
| Clipboard Paused | Monitoring Paused |
| Finalizing Guide | Finishing Guide |
| Finishing Recording | Finishing |

Rows with an unchanged destination document an intentional retained phrase.

## Intentional Exceptions

- **fullscreen** may remain as a raw automation value, URL parameter, command option, persisted identifier, or code symbol. User-facing copy should say **Screen**.
- **Screen Recording** remains the macOS privacy permission name.
- **Display** is reserved for physical monitor hardware, even though macOS APIs may use “screen” internally.
- **Scrolling Capture** may remain as the explanatory name of the overall technique or workflow. Its source is **Scrolling Content**, and its action is **Capture Scrolling Content**.
- **Archive** may remain in internal storage, recovery, service, and type names.
- **Collection** may remain in internal data models or in a distinct feature name such as **Clipboard History Collection** when it truly represents organization rather than the Combined Image workflow.
- Existing automation contract identifiers must remain stable unless the automation version or compatibility plan explicitly permits a change.

An exception permits the minimum necessary legacy usage. It does not make the legacy term an acceptable synonym in new product copy.

## Construction and Style Rules

### Labels

- Start actions with a verb: **Capture Region**, not **Region Capture**.
- Use a noun for a destination or object: **Snip Library**, not **Browse Snips** when naming the destination itself.
- Use the shortest label that remains unambiguous in its immediate context.
- Use Title Case for control labels, section headings, workflow names, and menu commands.
- Use sentence case for explanations, descriptions, guidance, and status detail.
- Capitalize canonical product concepts when they name a specific SnipSnipSnip workflow or destination.

### Descriptions

- Explain consequences, not merely restate the label.
- Identify whether an action captures live content, imports a file, pastes clipboard content, or chooses an existing item.
- Avoid generic **recording**, **history**, **library**, **collection**, and **screen** when context does not establish the specific meaning.
- Use the same term in the heading, primary action, progress status, completion message, Help text, and accessibility text for one concept.

### Accessibility

- Accessibility labels should name the same action shown visually.
- Accessibility descriptions may add consequences or keyboard behavior, but must not introduce a competing term.
- When an icon has no visible label, its accessibility label must use the canonical action or noun from this document.

## Adding or Changing Terminology

Before shipping a new user-visible term:

1. Identify whether it is an object, source, action, stage, status, destination, lifecycle verb, or output verb.
2. Confirm that an existing canonical term does not already represent the concept.
3. Check whether the proposed word conflicts with a meaning already reserved here.
4. Add the term and its definition to this document.
5. Update the relevant workflow table and from/to ledger when replacing prior language.
6. Update `Docs/DesignLanguage.md` if the change alters a broader product-language principle.
7. Update in-app Help, onboarding, Settings, accessibility text, localization, and text assertions in the same change.
8. If an automation command, option, route, term, result, error, or output changes, follow the automation-maintenance requirements in `AGENTS.md`.

## Review Checklist

For any workflow-language change, verify:

- The workflow name uses the canonical object noun.
- Every action begins with the correct source-specific verb.
- Stages describe meaningful work rather than generic readiness.
- Ongoing activities use the correct Guide, Video, or Clipboard status vocabulary.
- Lifecycle verbs accurately communicate retention or deletion consequences.
- Output verbs match what the app actually does.
- Menus, windows, sheets, Help, onboarding, Settings, notifications, tooltips, and accessibility use the same terms.
- User-visible App Intent and automation labels agree with the UI while raw compatibility identifiers remain stable.
- Localization entries and text-based tests reflect the canonical wording.
- No internal legacy term has leaked into new user-facing copy.
