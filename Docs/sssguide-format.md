# SnipSnipSnip Guide Document Format

`.sssguide` is the editable, local-first package format for Guide projects. Version 1 uses the Uniform Type Identifier `com.oontz.snipsnipsnip.guide-document`. User-directed saves build a temporary package and atomically replace the destination. Capture recovery checkpoints reuse immutable assets in the private recovery package and atomically commit `document.json` last, so an interrupted checkpoint leaves the previous manifest readable.

## Package layout

```text
Example.sssguide/
  document.json
  preview.png                 optional
  brand/
    logo.png                  optional
  steps/
    <lowercase-step-uuid>/
      base.png
      session.json
  media/
    timeline.json             present when source media exists
    segments/
      <lowercase-segment-uuid>.mp4
```

`base.png` is never flattened with markers, annotations, or redactions. `session.json` contains the non-destructive step session. Media segments are pause-aware originals; exporters compose them without rewriting the package assets. A segment may include `sourceCoordinateRect`, the exact capture-global crop used by ScreenCaptureKit. `timeline.sourceCoordinateRect` is the project-level fallback for early version-1 files and segments.

## `document.json`

The root object contains:

| Field | Type | Meaning |
| --- | --- | --- |
| `formatIdentifier` | string | Exactly `com.oontz.snipsnipsnip.guide-document`. |
| `formatVersion` | integer | Exactly `1`. |
| `savedAt` | ISO-8601 date | Package write time. |
| `project` | object | Guide project, theme, export defaults, timeline, ordered steps, and the coordinate contract for captured geometry. |
| `assets` | object | Relative paths for preview, logo, steps, and media. |

Every step asset entry contains `id`, `baseImage`, and `session`. Every media entry contains `id` and `path`. Project steps contain their event kind, caption, note, include/delete state, duration, safe target metadata, timing, and non-destructive session. The project theme can include an organization name, short footer or copyright, and an optional `legalStatement`; the corresponding logo remains the optional self-contained `assets.logo` image.

Example, abbreviated:

```json
{
  "formatIdentifier": "com.oontz.snipsnipsnip.guide-document",
  "formatVersion": 1,
  "savedAt": "2026-07-15T18:30:00Z",
  "project": {
    "id": "AF623A86-4D8A-4A11-A39A-45A7F16C1574",
    "title": "Export a Report",
    "source": { "displays": { "current": {} } },
    "isPrivate": false,
    "steps": [
      {
        "id": "637B74AB-40F7-463D-9088-A64D4629BA7E",
        "sequence": 1,
        "eventKind": "click",
        "caption": "Click Export.",
        "deterministicCaption": "Click Export.",
        "duration": 2,
        "isIncluded": true,
        "isDeleted": false,
        "baseImageAsset": "base.png",
        "session": {
          "sourceCoordinateRect": [[0, 0], [1440, 900]],
          "sourcePixelSize": [2880, 1800],
          "redactions": [],
          "showsCursor": false,
          "annotationSessionAsset": "steps/637b74ab-40f7-463d-9088-a64d4629ba7e/assets/advanced.sss"
        }
      }
    ],
    "timeline": {
      "segments": [],
      "sourceVideoEnabled": false,
      "sourceCoordinateRect": [[0, 0], [1440, 900]]
    }
  },
  "assets": {
    "preview": "preview.png",
    "logo": null,
    "steps": [
      {
        "id": "637B74AB-40F7-463D-9088-A64D4629BA7E",
        "baseImage": "steps/637b74ab-40f7-463d-9088-a64d4629ba7e/base.png",
        "session": "steps/637b74ab-40f7-463d-9088-a64d4629ba7e/session.json"
      }
    ],
    "media": []
  }
}
```

The example is illustrative; Core Graphics values use the platform `Codable` representation produced by the shipping app.

Each step session records crop, marker geometry and visibility, optional still-step cursor visibility, non-destructive redactions, event metadata, timing, source-coordinate mapping, and per-step style overrides. `annotationSessionAsset` is optional and points to an embedded editable `.sss` package. The optional project `coordinateContract` uses the shared `DocumentCoordinateContract`; new Guides write the current contract, while Guides written before this field existed resolve to that same established top-left/y-down capture contract. Optional timeline and segment capture rectangles preserve mixed-scale and rotated-display geometry without depending on the display layout at export time. Export settings preserve PDF paper/orientation/quality, animation timing, PNG/JPEG step-image choice, selected formats, ZIP source-media choice, and filename tokens.

## Compatibility and safety

- Readers validate the identifier and version before decoding or loading assets.
- Unknown versions fail as unsupported and the package is not changed.
- Asset paths must be non-empty, relative, slash-separated paths with no empty, `.` or `..` component and must resolve inside the package after symlink resolution.
- Every project step must have exactly one matching asset and session record. The step ID and session must match the manifest.
- Required assets must exist and decode successfully. Images are limited to 65,536 pixels per dimension and 268,435,456 total pixels.
- Preview and logo are optional. Timeline and media are optional. A Guide without source media can still export PDF, GIF, APNG, images, ZIP, and slideshow MP4.
- Version 1 readers ignore no required validation failures. Additive optional fields must decode safely when absent; required or meaning-changing fields require a future schema strategy or format version.

Private Guide packages are normal user-owned documents when explicitly saved. Automatic Private Guide sessions are excluded from archive, search indexing, diagnostics content, and background OCR/AI refinement.
