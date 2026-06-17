# Presentation Scene SVG Format

`SnipSnipSnip` Presentation Scenes are SVG templates used by screenshot Presentation mode. They are plain SVG files with a small SnipSnipSnip metadata block and slot markers that tell the app where to place the rendered screenshot and editable text values.

Presentation Scenes are intentionally local, inspectable, and non-executable:

- Scenes live as `.svg` files on disk.
- Scene identity comes from SVG metadata, not the filename.
- Scene source files are validated and sanitized before use.
- Applying a scene stores a sanitized SVG snapshot inside the `.sss` document.
- Loading a saved `.sss` document does not require the original scene file to still exist.

## Relationship To Presentation Styles

Presentation mode has two layers:

- **Presentation Styles** are native Swift settings for fast polish such as backgrounds, spacing, rounded corners, and shadows.
- **Presentation Scenes** are SVG templates for richer layouts that place the rendered screenshot into a designed scene.

When a scene is applied, SnipSnipSnip renders the screenshot and annotations, then substitutes that rendered image into the selected Presentation Scene. Native Presentation Style output is used when no scene is applied.

## Scenes Folder Layout

The default scenes root is:

```text
~/Library/Application Support/SnipSnipSnip/Presentation Scenes/
```

The root contains two scene folders:

```text
Presentation Scenes/
  Bundled/
    .snipsnipsnip-bundled-scenes.json
    safari-browser-light.svg
    phone-story-dark.svg
    social-card-clean.svg
    mac-window-light.svg
  User/
    my-custom-scene.svg
```

- `Bundled` is app-managed. SnipSnipSnip mirrors the scenes shipped with the app into this folder.
- `User` is user-owned. Custom scene files should normally be added here.
- Settings can point SnipSnipSnip at a different scenes root folder.

## Current Schema

- `schema`: `com.oontz.snipsnipsnip.presentation-scene`
- `schemaVersion`: `1`

The SVG must include a `<metadata id="snipsnipsnip-scene">` element containing JSON metadata.

```xml
<metadata id="snipsnipsnip-scene">
{
  "schema": "com.oontz.snipsnipsnip.presentation-scene",
  "schemaVersion": 1,
  "id": "builtin.safari-browser-light",
  "name": "Safari Browser Light",
  "version": 2,
  "author": "SnipSnipSnip",
  "description": "Polished light Safari-style browser frame on a quiet neutral canvas.",
  "canvas": { "width": 1600, "height": 900 },
  "slots": [
    { "id": "primaryScreenshot", "type": "image", "required": true, "label": "Screenshot" },
    { "id": "browserAddress", "type": "text", "label": "Address", "defaultValue": "example.com" }
  ]
}
</metadata>
```

## Metadata Fields

- `schema`: required stable schema identifier.
- `schemaVersion`: required schema version. Current value is `1`.
- `id`: required stable scene identifier.
- `name`: required human-readable scene name.
- `version`: required positive integer scene version.
- `author`: optional scene author.
- `description`: optional scene description.
- `canvas`: required output canvas size in pixels.
- `slots`: required array of scene slots.

### `canvas`

`canvas` contains:

- `width`: positive integer output width.
- `height`: positive integer output height.

The app uses this size as the scene render size and export canvas size.

### `slots`

Every slot contains:

- `id`: stable slot identifier.
- `type`: `image` or `text`.
- `required`: optional Boolean. Defaults to `false`.
- `label`: optional UI label. Defaults to the slot ID when absent.
- `defaultValue`: optional default text value for text slots.
- `defaultFraming`: optional screenshot framing preset for image slots. Defaults to `auto`.
- `allowUserOverride`: optional Boolean for screenshot slot controls. Defaults to `true`.
- `minScale`: optional minimum user scale multiplier. Defaults to `0.25`.
- `maxScale`: optional maximum user scale multiplier. Defaults to `3`.
- `maxAutoEnlargement`: optional maximum automatic enlargement before Auto prefers Actual Size. Defaults to `1.5`.

V1 requires exactly one image slot with:

```json
{
  "id": "primaryScreenshot",
  "type": "image",
  "required": true,
  "label": "Screenshot",
  "defaultFraming": "auto"
}
```

The `primaryScreenshot` slot receives the rendered screenshot content. V1 supports one screenshot image slot plus optional text slots.

Supported `defaultFraming` values are `auto`, `showFull`, `fillFrame`, `focusTop`, `focusBottom`, `focusLeft`, `focusRight`, and `actualSize`.

## Scene IDs And Versions

Scene IDs are stable identifiers and should not depend on filenames.

- App-shipped scenes must use the `builtin.` prefix.
- User-created scenes must not use the `builtin.` prefix.
- Scene versions must be positive integers.
- Increment `version` whenever a scene update should win over an older copy with the same ID.

If multiple valid scenes use the same ID, SnipSnipSnip exposes only one winner:

1. Highest `version` wins.
2. If versions tie, `User` wins over user-modified `Bundled`.
3. If still tied, user-modified `Bundled` wins over app-managed `Bundled`.

Duplicate scene IDs are reported in diagnostics.

## Slot Conventions

A scene connects SVG elements to metadata slots with `data-sss-slot`.

### Screenshot Slot

The required screenshot slot must be an `<image>` element with:

- `data-sss-slot="primaryScreenshot"`
- `href="snipsnipsnip:primaryScreenshot"`
- numeric `x`, `y`, `width`, and `height`
- optional `preserveAspectRatio`
- optional SVG clipping, masks, filters, shadows, or surrounding frame geometry

```xml
<image
  id="primary-screenshot"
  data-sss-slot="primaryScreenshot"
  href="snipsnipsnip:primaryScreenshot"
  x="112"
  y="176"
  width="1376"
  height="638"
  preserveAspectRatio="xMidYMid slice"
  clip-path="url(#screen-clip)"/>
```

At render time, SnipSnipSnip treats the SVG image rectangle as a screenshot slot. The app computes screenshot placement inside that rectangle, creates a transparent slot-sized PNG, replaces `href` with that PNG data URI, and sets `preserveAspectRatio="none"` so the SVG renderer does not perform a second fit.

Scene authors define slot geometry and clipping; SnipSnipSnip owns screenshot fitting inside the slot. Users can save framing overrides in the `.sss` document.

Framing behavior:

- `auto`: chooses Show Full, Fill, or Actual Size based on screenshot/slot aspect ratio and enlargement risk.
- `showFull`: contains the full screenshot in the slot.
- `fillFrame`: fills the slot and may crop the screenshot.
- `focusTop`, `focusBottom`, `focusLeft`, `focusRight`: fill the slot and bias cropping toward that edge.
- `actualSize`: places the screenshot at 1:1 scene pixels unless the user adjusts scale.

### Text Slots

Text slots use SVG `<text>` elements with `data-sss-slot="<slotID>"`.

```xml
<text
  id="browser-address"
  data-sss-slot="browserAddress"
  x="817"
  y="133"
  text-anchor="middle">example.com</text>
```

At render time, SnipSnipSnip replaces the element text content with the applied text slot value. Text styling remains in the SVG element attributes.

## Supported SVG Usage

Scenes may use regular static SVG drawing features that AppKit can rasterize, including:

- `rect`, `circle`, `ellipse`, `line`, `path`, `polygon`, and `polyline`
- `text`
- `image` for the `primaryScreenshot` slot
- `defs`
- gradients
- filters
- clipping paths
- masks
- groups and transforms
- local fragment references such as `url(#shadow)` or `clip-path="url(#screen-clip)"`

The practical renderer is AppKit SVG rasterization, so scene authors should visually test scenes in SnipSnipSnip instead of assuming every browser SVG feature will render identically.

## Safety And Validation Rules

SnipSnipSnip rejects scenes that fail validation. Current validation rules:

- SVG text must be valid UTF-8.
- SVG must parse as XML.
- SVG must not declare a DTD.
- Metadata block `id="snipsnipsnip-scene"` is required.
- Metadata JSON must decode successfully.
- `schema` and `schemaVersion` must match the current schema.
- `id`, `name`, and positive `version` are required.
- `canvas.width` and `canvas.height` must be positive.
- Slot IDs must be non-empty and unique.
- Exactly one required `primaryScreenshot` image slot must appear in metadata.
- Exactly one SVG `<image data-sss-slot="primaryScreenshot">` element must appear in the SVG.
- Every `data-sss-slot` value must match a declared metadata slot.
- Every `snipsnipsnip:<slotID>` reference must match a declared metadata slot.
- Bundled scene IDs must start with `builtin.`.
- User scene IDs must not start with `builtin.`.

The following content is rejected:

- `script`
- `foreignObject`
- animation elements: `animate`, `animateMotion`, `animateTransform`, and `set`
- event-handler attributes such as `onclick` or `onload`
- remote URLs containing `http://` or `https://`
- `file:` URLs
- embedded source `data:` URLs
- unknown SnipSnipSnip slot references

Source SVG files cannot embed arbitrary local, remote, or data URI assets. The app generates the only data URI during render when substituting the screenshot slot.

## Bundled Scene Sync

SnipSnipSnip ships example scenes as app resources and mirrors them into the configured scenes root under `Bundled`.

On launch or reload:

- The app ensures `Bundled` and `User` folders exist.
- Missing bundled scenes are copied into `Bundled`.
- Unchanged app-managed bundled scenes are replaced when the app ships a newer version or changed source.
- User-modified bundled scene files are preserved.
- If a bundled scene was user-modified, the newly shipped copy is written beside it with a unique filename such as `Scene Name (Bundled v2).svg`.
- Modified bundled files and duplicate scene IDs are reported in diagnostics.

The bundled manifest is:

```text
Bundled/.snipsnipsnip-bundled-scenes.json
```

Each manifest record stores:

- bundled scene ID
- bundled scene version
- mirrored filename
- SHA-256 of the app-shipped SVG text last copied
- app version last synced

The manifest is implementation metadata for safe sync. Scene identity still comes from the SVG metadata block.

## Applied Scene Records In `.sss`

When a scene is applied to a document, the `.sss` document stores an applied scene snapshot:

- `sceneID`
- `name`
- `version`
- `sanitizedSVGText`
- `textSlotValues`
- `screenshotSlotSettings`

`sanitizedSVGText` is the validated XML string at the time the scene was applied. This makes saved documents portable and reproducible even if the source SVG changes, is deleted, or is no longer installed.

`screenshotSlotSettings` stores the selected framing preset, resolved fit, alignment, scale multiplier, x/y offset, and whether manual adjustment is active. Older records that only contain `fit: contain` or `fit: cover` migrate to `showFull` or `fillFrame`.

## Rendering Pipeline

The scene renderer:

1. Validates the embedded sanitized SVG text.
2. Locates the `primaryScreenshot` image slot rectangle.
3. Computes Auto or preset screenshot placement inside that slot.
4. Draws the rendered screenshot and annotations into a transparent slot-sized PNG.
5. Replaces the `primaryScreenshot` image `href` with the slot PNG data URI and sets `preserveAspectRatio="none"`.
6. Replaces text slot contents from `textSlotValues`.
7. Rasterizes the prepared SVG to the metadata canvas size using AppKit SVG support.

In DEBUG builds, scene preparation, slot substitution, and rasterization emit performance diagnostics.

## Minimal Scene Example

```xml
<svg xmlns="http://www.w3.org/2000/svg" width="1200" height="675" viewBox="0 0 1200 675">
  <metadata id="snipsnipsnip-scene">
{
  "schema": "com.oontz.snipsnipsnip.presentation-scene",
  "schemaVersion": 1,
  "id": "example.simple-card",
  "name": "Simple Card",
  "version": 1,
  "author": "Example Author",
  "description": "A simple card scene with one screenshot and one title.",
  "canvas": { "width": 1200, "height": 675 },
  "slots": [
    { "id": "primaryScreenshot", "type": "image", "required": true, "label": "Screenshot" },
    { "id": "title", "type": "text", "label": "Title", "defaultValue": "Screenshot" }
  ]
}
  </metadata>
  <defs>
    <filter id="shadow" x="-10%" y="-10%" width="120%" height="130%">
      <feDropShadow dx="0" dy="24" stdDeviation="24" flood-color="#0f172a" flood-opacity="0.20"/>
    </filter>
    <clipPath id="shot-clip">
      <rect x="160" y="170" width="880" height="420" rx="28"/>
    </clipPath>
  </defs>
  <rect width="1200" height="675" fill="#f8fafc"/>
  <text data-sss-slot="title" x="600" y="108" text-anchor="middle"
        font-family="-apple-system, BlinkMacSystemFont, Helvetica, Arial, sans-serif"
        font-size="42" font-weight="700" fill="#0f172a">Screenshot</text>
  <g filter="url(#shadow)">
    <rect x="160" y="170" width="880" height="420" rx="28" fill="#ffffff"/>
    <image data-sss-slot="primaryScreenshot"
           href="snipsnipsnip:primaryScreenshot"
           x="160" y="170" width="880" height="420"
           preserveAspectRatio="xMidYMid slice"
           clip-path="url(#shot-clip)"/>
  </g>
</svg>
```

## Interop Notes

- Scene files are standard static SVG plus SnipSnipSnip metadata and slot attributes.
- Tools that do not understand SnipSnipSnip slots may show a missing image for `snipsnipsnip:primaryScreenshot`; SnipSnipSnip replaces that value before rendering.
- Custom scenes should be authored as static, self-contained SVG and tested through the Presentation Scene picker.
- Future schema versions should add metadata fields and slot types additively where possible.
