# `.sss` Format

`SnipSnipSnip` saves editable screenshot documents as `.sss` macOS file packages. A package is a directory that Finder presents as a single file.

The format is intentionally open and local-first:

- The original screenshot is stored separately from annotations.
- A flattened preview is stored for fast history and Finder-style display, including any active presentation wrapper.
- Editable state, undo/redo stacks, search metadata, and style defaults are stored as JSON.
- Image overlay bytes are stored as package assets and referenced by stable asset IDs.

## Package Layout

```text
example.sss/
  document.json
  base.png
  preview.png
  assets/
    image-overlays/
      <asset-id>.png
```

`assets/image-overlays` is present only when the document contains image overlay annotations.

## Current Version

- `formatIdentifier`: `com.oontz.snipsnipsnip.document`
- `formatVersion`: `6`

Version 6 stores explicit coordinate-space metadata, image overlay assets, and additive screenshot presentation fields. New captures use Quartz-style top-left, y-down capture-global points. Existing documents retain their persisted coordinate descriptor when resaved.

## Top-Level `document.json`

- `formatIdentifier`: stable package identifier.
- `formatVersion`: current value is `6`.
- `savedAt`: ISO-8601 timestamp for the save operation.
- `coordinateContract`: explicit coordinate-space descriptors used by capture and editor geometry.
- `assets`: package-relative asset filenames.
- `capture`: source capture metadata.
- `session`: editable editor state and history.
- `metadata`: optional search metadata.

### `assets`

- `baseImage`: usually `base.png`.
- `previewImage`: usually `preview.png`.
- `imageOverlays`: optional array of image overlay asset records.

Each image overlay asset record contains:

- `id`: UUID referenced by `imageOverlay` annotations.
- `filename`: package-relative path such as `assets/image-overlays/<id>.png`.

### `capture`

- `kind`: `region`, `window`, `fullscreen`, or `scrolling`.
- `sourceName`: human-readable capture source label.
- `sourceRect`: original capture bounds in the coordinate space named by `coordinateContract.captureSourceRectSpace`.
- `capturedAt`: ISO-8601 timestamp of the original capture.
- `uiMap`: optional UI Map metadata captured with the screenshot when the build-target flag and user preference are enabled.

### `capture.uiMap`

UI Map metadata is additive and may be absent. Documents containing it remain valid when the UI Map feature is disabled in a future build target.

- `capturedAt`: ISO-8601 timestamp for the UI Map collection.
- `sourceRect`: capture source bounds associated with the UI Map.
- `elements`: hierarchical accessible interface elements.

Each UI Map element contains:

- `id`: stable UUID within the document.
- `name`: optional element name or title.
- `accessibilityLabel`: optional accessibility label.
- `accessibilityIdentifier`: optional accessibility identifier.
- `role`: optional accessibility role such as `AXButton`.
- `roleDescription`: optional human-readable role.
- `valueDescription`: optional value description when available.
- `documentRect`: element bounds in screenshot document-image space.
- `owningApplication`: optional app name.
- `bundleIdentifier`: optional app bundle identifier.
- `children`: nested visible child elements.

### `metadata.search`

- `annotationText`: text and callout content collected from annotations.
- `recognizedText`: optional OCR text used for history search.
- `searchableText`: combined search text used by archive and recent snip search.
- UI Map text may be included in `searchableText` only when UI Map metadata is present and enabled in the running build.

Private Capture sessions skip archive checkpoint creation and OCR indexing, so private captures should not create persisted search metadata unless the user explicitly saves a `.sss` package.

## Session Schema

`session` contains:

- `initialSnapshot`: editor state at document creation.
- `currentSnapshot`: active editor state at save time.
- `undoStack`: prior snapshots.
- `redoStack`: redo snapshots.
- `toolStyles`: per-tool style defaults.
- `savedPresentations`: optional document-scoped saved presentation variants.

Each snapshot contains:

- `cropRect`
- `annotations`
- `selectedAnnotationIDs`
- `nextCalloutNumber`
- `presentation`: optional export presentation state. Missing values default to plain output.

`presentation` contains:

- `isEnabled`
- `style`: optional native Presentation Style record. Newer writers include this as the canonical native style state.
- `scene`: optional applied Presentation Scene snapshot. When present, it contains the scene ID, name, version, sanitized SVG text, text slot values, and screenshot slot fit settings.
- `background`: `transparent`, `solid`, `twoColorGradient`, `radialSpotlight`, or `blurredScreenshot`
- `canvas`: optional legacy/native canvas sizing record. Missing values decode as `original`.
- `subjectPlacement`: optional legacy/native fit, alignment, scale, and offset record. Missing values decode as centered contain placement.
- `frame`: optional legacy/native rendered frame record. Missing values decode as `none`.
- `padding`
- `cornerRadius`
- `shadow`: `off`, `soft`, `medium`, `strong`, or `drop`
- `shadowBlurRadius`: optional custom shadow blur radius. Missing values use the selected `shadow` preset default.
- `shadowOffsetX`: optional custom horizontal shadow offset. Missing values use the selected `shadow` preset default.
- `shadowOffsetY`: optional custom vertical shadow offset. Missing values use the selected `shadow` preset default.
- `shadowOpacity`: optional custom shadow opacity from `0` to `1`. Missing values use the selected `shadow` preset default.

The flat presentation fields remain present for compatibility with older readers. Readers that understand `style` should prefer it for native style state when no `scene` is applied. Native canvas sizing, subject placement, and rendered frame records are retained for file compatibility; current user-facing browser, window, phone, tablet, social, and fixed-layout presentation work should be represented as `scene` snapshots. When `scene` is present, readers should render the screenshot and annotations, then substitute that rendered content into the embedded SVG scene snapshot.

Scene records use:

- `sceneID`
- `name`
- `version`
- `sanitizedSVGText`: the sanitized SVG template snapshot embedded in the document.
- `textSlotValues`: string values keyed by scene text slot ID.
- `screenshotSlotSettings`: selected screenshot slot framing preset, resolved fit, alignment, scale multiplier, x/y offset, and manual adjustment flag. Older fit-only records decode as `showFull` or `fillFrame`.

See `presentation-scene-format.md` for the SVG metadata schema, slot conventions, validation rules, bundled scene sync policy, and rendering pipeline used by `sanitizedSVGText`.

Saved variant records use:

- `id`: UUID for the saved presentation inside this document.
- `name`: user-facing variant name.
- `presentation`: full `ScreenshotPresentation` state, including style and optional embedded scene snapshot.
- `createdAt`: creation timestamp.
- `updatedAt`: last update timestamp.

Saved variants are stored in the `.sss` document, not global preferences. Applying a saved variant copies its `presentation` value into the active snapshot through the normal presentation command path. Renaming, duplicating, updating, or deleting saved variant records changes document metadata and should mark the document dirty, but those saved-list library edits are separate from snapshot undo history.

Background records use:

- `transparent`: `kind`
- `solid`: `kind`, `color`
- `twoColorGradient`: `kind`, `start`, `end`
- `radialSpotlight`: `kind`, `base`, `spotlight`
- `blurredScreenshot`: `kind`, `tint`

Canvas records use:

- `original`: `kind`
- `preset`: `kind`, `preset`, where `preset` is `square`, `portraitFourFive`, `widescreen`, `story`, or `landscapeWide`
- `custom`: `kind`, `width`, `height`

Frame records use:

- `none`: `kind`
- `browser`: `kind`, `browser`, where `browser` contains `title`, `address`, `scheme`, and `showsTrafficLights`
- `macOSWindow`: `kind`, `macOSWindow`, where `macOSWindow` contains `title`, `scheme`, and `showsTrafficLights`
- `phone` or `tablet`: `kind`, `device`, where `device` contains `orientation`, `bezelColor`, `screenCornerRadius`, `showsSensorHousing`, and `castsDeviceShadow`

## Annotation Schema

Every annotation contains:

- `id`
- `groupID`
- `kind`
- `rotationDegrees`
- `style`

`rotationDegrees` defaults to `0` when missing, which preserves v1/v2 compatibility.

Supported `kind` values:

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

Supported `redactionMode` values:

- `blur`
- `pixelate`
- `solid`

## Compatibility Rules

- Readers must reject unknown `formatIdentifier` values.
- Readers must reject `formatVersion` values outside the supported range.
- Readers should default missing `presentation` values to plain output.
- Readers should default missing presentation `canvas` values to `original`.
- Readers should default missing presentation `subjectPlacement` values to centered contain placement.
- Readers should default missing presentation `frame` values to `none`.
- Readers should decode missing presentation `style` values from the flat compatibility fields.
- Readers should default missing presentation `scene` values to style-only presentation output.
- Readers should render an applied presentation scene from the embedded `sanitizedSVGText`; the original scene file is not required to load the document.
- Readers should default missing `savedPresentations` values to an empty list.
- Readers should default missing `rotationDegrees` to `0`.
- Readers should default missing spotlight `isEllipse` to `true`.
- Readers should default missing image overlay `opacity` to `1`.
- Readers must resolve `imageOverlay.assetID` through `assets.imageOverlays`; missing overlay assets make the document invalid.
- Future versions should prefer additive JSON fields over renaming or reinterpreting existing fields.

## Privacy Notes

- `.sss` packages are editable source documents, not privacy-flattened output. They retain the base screenshot and non-destructive annotation state.
- UI Map metadata, when present, is local editable document metadata. It is not included in flattened PNG/JPEG/PDF exports unless the user intentionally renders visible overlays or annotations.
- Redactions are flattened only when copying, exporting, or sharing rendered PNG/JPEG/PDF output.
- PNG/JPEG/PDF export paths re-encode rendered output and do not preserve source EXIF, TIFF, GPS, IPTC, or user metadata.

## Interop Notes

- Other apps can read `base.png` directly even if they do not understand the editor JSON.
- Other tools can read `preview.png` for display without executing SnipSnipSnip code.
- Editable interoperability requires parsing `document.json` plus any referenced overlay assets.
