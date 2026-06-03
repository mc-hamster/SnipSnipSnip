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

Version 6 stores explicit coordinate-space metadata and image overlay assets. New captures use Quartz-style top-left, y-down capture-global points. Existing documents retain their persisted coordinate descriptor when resaved.

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

### `metadata.search`

- `annotationText`: text and callout content collected from annotations.
- `recognizedText`: optional OCR text used for history search.
- `searchableText`: combined search text used by archive and recent snip search.

Private Capture sessions skip archive checkpoint creation and OCR indexing, so private captures should not create persisted search metadata unless the user explicitly saves a `.sss` package.

## Session Schema

`session` contains:

- `initialSnapshot`: editor state at document creation.
- `currentSnapshot`: active editor state at save time.
- `undoStack`: prior snapshots.
- `redoStack`: redo snapshots.
- `toolStyles`: per-tool style defaults.

Each snapshot contains:

- `cropRect`
- `annotations`
- `selectedAnnotationIDs`
- `nextCalloutNumber`
- `presentation`: optional export presentation state. Missing values default to plain output.

`presentation` contains:

- `isEnabled`
- `background`: `transparent` or `solid` with an optional color record
- `padding`
- `cornerRadius`
- `shadow`: `off`, `soft`, `medium`, `strong`, or `drop`
- `shadowBlurRadius`: optional custom shadow blur radius. Missing values use the selected `shadow` preset default.
- `shadowOffsetX`: optional custom horizontal shadow offset. Missing values use the selected `shadow` preset default.
- `shadowOffsetY`: optional custom vertical shadow offset. Missing values use the selected `shadow` preset default.
- `shadowOpacity`: optional custom shadow opacity from `0` to `1`. Missing values use the selected `shadow` preset default.

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
- Readers should default missing `rotationDegrees` to `0`.
- Readers should default missing spotlight `isEllipse` to `true`.
- Readers should default missing image overlay `opacity` to `1`.
- Readers must resolve `imageOverlay.assetID` through `assets.imageOverlays`; missing overlay assets make the document invalid.
- Future versions should prefer additive JSON fields over renaming or reinterpreting existing fields.

## Privacy Notes

- `.sss` packages are editable source documents, not privacy-flattened output. They retain the base screenshot and non-destructive annotation state.
- Redactions are flattened only when copying, exporting, or sharing rendered PNG/JPEG/PDF output.
- PNG/JPEG/PDF export paths re-encode rendered output and do not preserve source EXIF, TIFF, GPS, IPTC, or user metadata.

## Interop Notes

- Other apps can read `base.png` directly even if they do not understand the editor JSON.
- Other tools can read `preview.png` for display without executing SnipSnipSnip code.
- Editable interoperability requires parsing `document.json` plus any referenced overlay assets.
