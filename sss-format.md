# `.sss` Editable Screenshot Format

`SnipSnipSnip` saves editable screenshot documents as `.sss` macOS file
packages. A package is a directory that Finder presents as a single file.

The format is open, local-first, and non-destructive:

- Immutable capture pixels are stored separately from item edits and
  composition edits.
- A composition can contain multiple references to the same immutable asset.
- Item annotations use source-image coordinates. Composition annotations use
  the assembled canvas coordinate space and may carry stable anchors.
- The optional user-facing Polish stage wraps the completed content with the
  internal Presentation Style or single-slot Presentation Scene model. It does
  not own the multi-item layout.
- A flattened `preview.png` supports history and file previews without decoding
  editable state.
- The initial, current, undo, and redo snapshots are all durable. Every source
  or overlay asset referenced by any of those snapshots is retained.

The rendering order is:

```text
source pixels
  → item crop, UI Map, annotations, overlays, and redactions
  → item framing and composition layout
  → title, captions, numbering, connectors, and composition annotations
  → optional Polish Look or Mockup (Presentation Style or Scene)
  → copy/export
```

## Package Layout

```text
example.sss/
  document.json
  base.png
  preview.png
  assets/
    captures/
      <capture-asset-id>.png
    image-overlays/
      <overlay-asset-id>.png
```

`assets/captures` is present when a v7 document contains composition source
assets. `assets/image-overlays` is present only when an item or composition
annotation references an image overlay.

`base.png` remains the original primary capture for compatibility. Composition
source pixels are independently identified by `assets.captures`; consumers must
not infer composition membership or order from filenames or directory order.

## Versioning

- `formatIdentifier`: `com.oontz.snipsnipsnip.document`
- Current `formatVersion`: `7`
- Accepted `formatVersion` values: `6` and `7`

Version 7 adds immutable composition capture assets, composition state and
document purpose in every editor snapshot, optional workflow-resume metadata,
permanent document privacy provenance, and the validation rules described
below. These intent fields are additive within v7 and do not require a format
version bump.

Version 6 remains read-only compatible. Loading v6 does not rewrite it. It
loads as the legacy single-capture document state, and the editor treats that
capture as the deterministic one-item source when composition is first used.
The first explicit save writes a v7 package; callers that need to preserve the
v6 file must save to a different destination. A failed save does not alter the
readable v6 package.

Within v7, newer writers may add fields. Current readers provide locked defaults
for v7 composition manifests written before the expanded comparison, step,
typography, semantic-role, z-order, and annotation-anchor fields were added.

## Top-Level `document.json`

The root object contains:

- `formatIdentifier`: stable package identifier.
- `formatVersion`: currently `7`.
- `savedAt`: ISO-8601 save timestamp.
- `coordinateContract`: coordinate spaces used by the legacy primary capture
  and editor geometry.
- `assets`: package asset records.
- `capture`: legacy-compatible primary capture metadata.
- `session`: editable snapshots, undo/redo, tool styles, and saved
  presentations.
- `workflow`: optional resume-only navigation metadata.
- `privacy`: v7 permanent privacy provenance.
- `metadata`: optional local search metadata; absent for private documents.

The manifest is written only after its referenced assets and `preview.png` are
durable. Normal saves assemble a temporary package and atomically promote or
replace the destination.

## Asset Records

### `assets`

- `baseImage`: normally `base.png`.
- `previewImage`: normally `preview.png`.
- `captures`: optional array of immutable composition capture records.
- `imageOverlays`: optional array of annotation overlay records.

### `assets.captures`

Each record contains:

- `id`: UUID; it must equal `descriptor.id`.
- `filename`: package-relative PNG path. Normal documents use
  `assets/captures/<id>.png`.
- `descriptor`: immutable source identity and coordinate metadata.
- `uiMap`: optional UI Map snapshot associated with this exact source.

Each `descriptor` contains:

- `id`
- `pixelWidth`, `pixelHeight`
- `sourceName`
- `capturedAt`: optional ISO-8601 timestamp
- `accessibilityLabel`: optional source description
- `captureKind`: optional capture-kind raw value
- `sourceRect`: optional source bounds
- `coordinateContract`: the coordinate contract for this asset
- `isPrivate`: whether the source originated as a Private Capture

The descriptor dimensions must match the decoded PNG. An asset ID is immutable:
writing different encoded pixels for an already stored ID is an error. Duplicate
composition items may share an asset ID without duplicating pixels.

If an included capture is missing or corrupt, the reader retains its descriptor,
item panel, title, and caption and marks its availability as missing or corrupt.
Editable save and export then fail explicitly until the user locates, replaces,
excludes, or removes the asset. A placeholder is never silently exported.

### `assets.imageOverlays`

Each image overlay record contains:

- `id`: UUID referenced by an `imageOverlay` annotation.
- `filename`: package-relative path such as
  `assets/image-overlays/<id>.png`.

Overlay assets referenced by any initial, current, undo, or redo item or
composition annotation are stored. Missing required overlay assets make the
document invalid.

## Primary Capture and UI Map

### `capture`

- `kind`: `region`, `window`, `fullscreen`, or `scrolling`.
- `sourceName`: human-readable capture source label.
- `sourceRect`: original bounds in
  `coordinateContract.captureSourceRectSpace`.
- `capturedAt`: ISO-8601 timestamp.
- `uiMap`: optional UI Map metadata for the legacy primary capture.

### UI Map records

UI Map metadata is additive and may be absent. A snapshot contains:

- `capturedAt`
- `sourceRect`
- `elements`: hierarchical accessible interface elements

Each element contains:

- `id`
- optional `name`, `accessibilityLabel`, `accessibilityIdentifier`
- optional `role`, `roleDescription`, `valueDescription`
- `documentRect`
- optional `owningApplication`, `bundleIdentifier`
- `children`

Composition assets store their UI Map alongside their capture record rather
than in the top-level primary `capture`.

## Session and Snapshot Schema

`session` contains:

- `initialSnapshot`
- `currentSnapshot`
- `undoStack`
- `redoStack`
- `toolStyles`
- optional `savedPresentations`

Pixels are never serialized into these snapshots. UUID references connect
snapshots to immutable capture and overlay records.

Each editor snapshot contains:

- `cropRect`, `annotations`, `selectedAnnotationIDs`, `nextCalloutNumber`:
  legacy single-capture editor state
- optional `pinnedUIMapElementIDs`
- optional `documentPurpose`: `screenshot`, `comparison`, `steps`, or
  `collection`
- optional `composition`: v7 multi-capture state
- optional `presentation`: the global Presentation state applied after the
  editable content or composition

All item, layout, comparison, step, and composition-annotation mutations use
the same chronological snapshot history. Assets referenced only by
`initialSnapshot`, `undoStack`, or `redoStack` remain part of the document.

`documentPurpose` is editable content state, so purpose changes participate in
the same chronological undo history. Missing or unknown values are inferred
from composition activation and layout: dormant or one-item content becomes
`screenshot`, Compare becomes `comparison`, Steps becomes `steps`, and another
active multi-item layout becomes `collection`.

## Workflow Resume Metadata

The optional top-level `workflow` record stores where the user should resume
without turning navigation into an edit:

- `stage`: `editing`, `awaitingComparisonAfter`, `collecting`, `arranging`,
  `reviewingComparison`, or `polishing`
- optional `returnStage`: the content stage restored when leaving `polishing`

Workflow navigation is intentionally outside editor snapshots. Moving between
content and Polish does not enter undo history or make the document dirty, but
explicit saves and recovery checkpoints retain it. Missing, incompatible, or
unknown values normalize to the purpose's canonical stage. A Screenshot
resumes in Edit; an incomplete Comparison waits for After; a ready Comparison
resumes in Review; Steps resumes in Collect; and an active Collection resumes
in Arrange.

## Composition Schema

### Snapshot

`composition` contains:

- `items`: ordered editable item records; a composition is never empty
- `selectedItemIDs`: unique IDs from `items`
- `layout`
- `comparison`
- `steps`
- `canvas`

Item order is the structured-layout insertion and reading order. Freeform paint
order additionally uses `zIndex`.

### Items

Each item contains:

- `id`: stable item UUID
- `assetID`: immutable capture asset UUID
- `editState`
- `framing`
- `opacity`
- `weight`
- `title`
- optional `caption`
- optional `accessibilityLabel`
- optional `freeformFrame`
- `isIncluded`
- `semanticRole`: `standard`, `before`, `after`, or `step`
- `zIndex`

Replacing source pixels preserves the item ID and changes its `assetID`.
Duplicating an item may retain the same `assetID`. Removing an item from the
current snapshot does not remove its source while history still references it.

`editState` contains:

- optional `cropRect` in source-image coordinates
- item-local `annotations`
- `selectedAnnotationIDs`
- `nextCalloutNumber`
- `pinnedUIMapElementIDs`

`framing` contains:

- `contentMode`: `contain`, `fill`, or `actualSize`
- `horizontalAlignment`: `leading`, `center`, or `trailing`
- `verticalAlignment`: `top`, `center`, or `bottom`
- `scale`
- `offset`
- optional `linkGroupID` for linked framing

### Layout

`layout` contains:

- `mode`: `auto`, `compare`, `steps`, `row`, `column`, `grid`, or `freeform`
- optional `gridColumns`
- `targetAspectRatio`
- optional `freeformCanvasSize`
- `sizingMode`: `equal` or `weighted`
- `orientation`: `automatic`, `landscape`, `portrait`, `square`, or `custom`

Structured layouts use item order, inclusion, and positive section weights.
Freeform uses each included item's frame and z-index.

### Comparison

`comparison` contains:

- `mode`: `sideBySide`, `overlay`, `wipe`, `blink`, `difference`, or
  `changeHighlight`
- `axis`
- optional `primaryItemID` and `secondaryItemID`
- `wipePosition`, `overlayOpacity`, and `blinkInterval`
- `differenceIntensity`, `changeThreshold`, and `changeHighlightColor`
- `primaryLabel`, `secondaryLabel`, and `showsLabels`
- `keepsViewsLinked`
- `registrationMode`: `automatic`, `manual`, or `disabled`
- `manualRegistrationOffset` and `registrationSensitivity`
- `unchangedContentOpacity`
- `differenceCueStyle`: `luminance`, `outline`, `pattern`, or
  `outlineAndPattern`
- `blinkCrossfadeDuration` and `blinkLoops`
- `posterFrame`: `primary` or `secondary`

The two selectors are either both absent or both present and distinct. Compare
layout requires explicit A/B selectors that reference included items.
Additional items remain stored but are not comparison participants.

### Steps

`steps` contains:

- `axis`
- `flow`: `row`, `column`, or `grid`
- `gridColumns`
- `numberingStyle`: `none`, `decimal`, `uppercaseLetters`,
  `lowercaseLetters`, `uppercaseRoman`, or `lowercaseRoman`
- `startIndex`
- `showsCaptions`
- `connectorStyle`: `none`, `line`, or `arrow`
- optional `itemsPerPage`

### Canvas and Appearance

`canvas` contains:

- `title`
- `appearance`
- composition-level `annotations`
- `selectedAnnotationIDs`
- `nextCalloutNumber`
- `annotationAnchors`, keyed by composition annotation UUID

Appearance stores:

- transparent or solid-color canvas fill
- outer insets and item spacing
- item fill, border, corner radius, and shadow
- caption colors, font size, optional font name, weight, alignment, placement,
  and insets
- title colors, font size, optional font name, weight, alignment, and insets
- step badge colors and diameter
- connector and comparison-divider colors and widths

Composition annotations render above all items and below optional Polish.
Redactions at this scope therefore redact the assembled content before internal
Style or Scene rendering.

### Composition Annotation Anchors

An annotation may define a primary anchor and an optional secondary anchor.
This allows arrows, lines, and measurements to attach each endpoint
independently.

Each anchor stores:

- `target`: one of:
  - a normalized canvas point
  - an item ID plus normalized source point
  - a detached absolute canvas point
- `lastCanvasPoint`: the last resolved top-left composition coordinate

The anchor map key must identify an existing composition annotation. Item
targets must identify an item in the same snapshot, and normalized coordinates
must be within `0...1`. Replacing an item's source preserves item anchors.
Deleting an item detaches its anchors at their last visible positions before
the resulting snapshot is committed.

## Presentation Schema

`presentation` is the persisted internal model behind the optional Polish
stage. Plain automation output renders the full editable content or composition
without this wrapper. Styled automation output renders the same content and
then applies this state. In the interactive app, Copy, Export, Share, Float, and
Drag follow the visible stage: content stages use unwrapped pixels and Polish
uses the visible Look or Mockup.

Presentation contains:

- `isEnabled`
- optional `style`
- optional embedded `scene`
- `background`
- optional `canvas`
- optional `subjectPlacement`
- optional `frame`
- `padding`, `cornerRadius`, and shadow fields

The flat fields remain for compatibility. When `scene` is present, the reader
renders the completed content and substitutes it into the Scene's
`primaryScreenshot` slot. A Scene never reads composition items directly and
does not provide a second multi-slot layout system.

An embedded Scene record contains:

- `sceneID`, `name`, `version`
- `sanitizedSVGText`
- `textSlotValues`
- `screenshotSlotSettings`

See `presentation-scene-format.md` for the SVG schema, sanitization rules, slot
conventions, and rendering pipeline.

Saved presentation variants contain:

- `id`
- `name`
- `presentation`
- `createdAt`
- `updatedAt`

They are document metadata and are separate from snapshot undo history.

## Annotation Schema

Every annotation contains:

- `id`
- optional `groupID`
- `kind`
- `rotationDegrees`
- `style`

Supported `kind` values are:

- `rectangle`: `rect`
- `ellipse`: `rect`
- `line`: `start`, `end`
- `arrow`: `start`, `end`
- `freehand`: `points`
- `highlight`: `rect`
- `text`: `rect`, `text`, `textAlignment`
- `callout`: `rect`, `number`, `text`, `textAlignment`
- `measurement`: `start`, `end`
- `spotlight`: `rect`, `isEllipse`
- `imageOverlay`: `rect`, `assetID`, `opacity`
- `redaction`: `rect`, `redactionMode`

Supported `redactionMode` values are `blur`, `pixelate`, and `solid`.

## Privacy

`.sss` is an editable source format. It can retain original pixels hidden by
crop, exclusion, layout, or non-destructive redactions.

Version 7 stores `privacy.isPrivate`. Privacy is permanent provenance:

- A true document privacy bit remains true.
- Any `assets.captures[].descriptor.isPrivate` value also makes the effective
  document private, even if the top-level bit is false or absent.
- Removing the visible private item does not clear privacy because initial,
  undo, or redo snapshots may retain its pixels.
- Private saves omit `metadata.search`.
- Search/OCR helpers return no content for an effectively private document.

The app excludes private documents from recovery, archive, recent/capture
history, recycle-bin presentation, clipboard-history ingestion, OCR/search
indexing, and content diagnostics. Explicit editable save, copy, and export are
still user-authorized operations.

Flattened output is re-encoded and does not retain source EXIF, TIFF, GPS, IPTC,
UI Map, OCR, source paths, hidden items, or undo history. Redactions become
pixels only during rendering.

## Recovery Storage

Recovery uses the same v7 manifest semantics but deduplicates immutable pixels
within one recovery session:

```text
Recovery/
  sessions/
    <session-id>/
      session.json
      base.png
      capture-assets/
        <capture-asset-id>.png
      checkpoints/
        checkpoint-<checkpoint-id>.sss/
          document.json
          preview.png
          assets/
            image-overlays/
              <overlay-asset-id>.png
```

Checkpoint capture records use
`../../capture-assets/<capture-asset-id>.png`; the base record uses
`../../base.png`. These paths are trusted only when the package is opened by
the recovery store in its verified session location. Opening an ordinary `.sss`
with either path is rejected.

Recovery writes immutable assets first, the checkpoint package manifest last,
and `session.json` only after the checkpoint is durable. A reused asset ID must
have byte-identical PNG data. Recycle Bin checkpoints retain their asset
references. Permanent deletion and archive pruning remove a shared asset only
after no retained checkpoint references its ID.

## Validation and Resource Limits

Readers and writers validate before exposing or committing editable state:

- identifier and supported version
- manifest byte limit
- package-relative path containment and symlink resolution
- exact trusted recovery paths
- every image file's logical byte length before reading it
- ImageIO header dimensions and decoded pixel counts for the base image,
  overlays, and composition captures before decoding any image
- descriptor/pixel agreement plus aggregate encoded-byte, decoded-pixel, and
  eager-decoding budgets across the base image, overlays, and captures
- duplicate capture, item, annotation, overlay, and UI Map IDs
- every item and overlay reference
- non-empty compositions and valid selections
- finite, bounded rectangles, sizes, points, offsets, colors, opacity, weights,
  typography, comparison values, and normalized anchors
- crop containment within source dimensions
- compare A/B selector validity
- Presentation Style, custom-canvas, subject-framing, embedded Scene, and output
  geometry before preview or source-image decoding
- aggregate snapshot, item-reference, annotation, freehand-point, UI Map, and
  text budgets across initial/current/undo/redo

The current defensive limits are implementation guardrails for untrusted
packages, not normal-workflow UI limits:

- 64 MiB manifest
- 65,536 pixels per image side and 268,435,456 decoded pixels per image
- 1 GiB encoded bytes per base, overlay, or composition image
- 2 GiB aggregate encoded bytes across all base, overlay, and composition images
- 1,073,741,824 aggregate decoded source pixels
- 402,653,184 eagerly decoded base-and-overlay pixels
- 512 MiB stored preview image
- 10,000 declared composition assets
- 16,384 pixels per fixed custom or Scene output side and 134,217,728 pixels per
  fixed output
- 131,072 pixels per computed Presentation output side and 536,870,912 pixels
  per computed output
- 4 MiB per embedded applied-Scene SVG
- 4,096 undo/redo snapshots
- 250,000 aggregate composition item references
- 250,000 aggregate annotations
- 2,000,000 aggregate annotation path points
- 32 MiB aggregate composition text
- geometry magnitude at most 1,000,000

Corrupt packages are never partially opened or rewritten. Missing or corrupt
composition captures that pass the package resource preflight retain their
panel state so the user can locate, replace, exclude, or remove them.

## Compatibility Rules

- Reject unknown `formatIdentifier` values.
- Reject versions outside `6...7`.
- Do not mutate a v6 package merely by loading it.
- Default a missing v7 `composition` to the legacy single-capture state.
- Default a missing or unknown `documentPurpose` through deterministic
  composition inference.
- Default a missing, unknown, or purpose-incompatible `workflow` value to the
  canonical stage inferred from purpose and composition.
- Default missing expanded v7 fields to their locked model defaults.
- Default missing `presentation` to plain output.
- Default missing presentation canvas to `original`, placement to centered
  contain, frame to `none`, style from the flat compatibility fields, and scene
  to style-only output.
- Render an applied Scene from embedded `sanitizedSVGText`; the source Scene
  file is not required.
- Default missing `savedPresentations` to an empty list.
- Default missing annotation `rotationDegrees` to `0`, spotlight `isEllipse` to
  `true`, and image-overlay `opacity` to `1`.
- Resolve every `imageOverlay.assetID` through `assets.imageOverlays`.
- Prefer additive fields in future versions rather than renaming or
  reinterpreting existing fields.

## Interoperability

- Tools that do not understand editable state may display `preview.png`.
- `base.png` remains available for legacy single-capture interoperability.
- Editable composition interoperability requires `document.json`, all capture
  records, and all overlay records referenced by every retained snapshot.
- Asset UUIDs are identities, not content hashes; consumers must preserve them
  when retaining annotation anchors or history relationships.
