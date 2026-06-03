# Coordinate Contract

SnipSnipSnip uses explicit, named coordinate spaces. Geometry may move between
spaces only through the transform types in
`SnipSnipSnip/Support/CoordinateSpaceContract.swift`.

## Canonical Spaces

- `capture-global-points-top-left-y-down-v2`
  - Logical screen points from ScreenCaptureKit and `CGDisplayBounds`.
  - Origin: top-left.
  - Axis: y-down.
  - Used for capture source rects, desktop union bounds, window frames, and
    scrolling viewport source rects.
- `overlay-screen-points-y-up-v1`
  - AppKit screen points for overlay window placement.
  - Origin: bottom-left.
  - Axis: y-up.
- `overlay-local-points-y-down-v1`
  - Local overlay view points.
  - Origin: top-left.
  - Axis: y-down.
  - Used for hit testing, drag state, loupe placement, and overlay drawing.
- `preview-pixels-top-left-v1`
  - Pixel coordinates inside per-display preview images.
  - Origin: top-left.
  - Axis: y-down.
- `document-pixels-top-left-v1`
  - Canonical editor geometry space for the full captured image.
  - Origin: top-left.
  - Axis: y-down.
  - Used for crop rects, annotations, selection, OCR regions, snapping, and
    persisted editor geometry.
- `render-output-pixels-top-left-v1`
  - Pixel coordinates in the rendered export image after crop origin
    subtraction.
  - Origin: top-left.
  - Axis: y-down.
- `accessibility-screen-points-y-up-v1`
  - Screen points used for Accessibility scrolling targets and synthetic input.
  - Origin: bottom-left.
  - Axis: y-up.

## Required Contracts

- `CapturedScreenshot.sourceRect` is always in
  `capture-global-points-top-left-y-down-v2` for new captures. Legacy documents
  retain their explicit `capture-global-points-y-up-v1` descriptor.
- `EditorSnapshot.cropRect` and every persisted annotation geometry value are
  always in `document-pixels-top-left-v1`.
- Preview drawing and export drawing must both derive from
  `DocumentProjection`.
- `CGImage.gscCropped(topLeftPixelRect:)` accepts only top-left, y-down pixel
  rects. It never performs an implicit Y flip.
- Scrolling capture output keeps `sourceViewportRect` in capture-global space
  and derives output size from the stitched image. Source viewport and output
  image bounds are not interchangeable.

## Allowed Transforms

- `CaptureScreenTransform`
  - Quartz capture global <-> display-local capture points.
- `AppKitOverlayTransform`
  - AppKit global <-> overlay-local points.
- `CaptureDisplayTransform`
  - Composes the explicit capture-screen and overlay transforms where an
    overlay bridges both spaces.
- `CapturePreviewTransform`
  - Capture geometry -> preview pixel rects and AppKit crop rects.
- `CompositeCaptureDrawTransform`
  - Capture global rects -> composite preview draw rects.
- `CaptureAccessibilityTransform`
  - Capture global rects/points -> Accessibility screen points.
- `DocumentProjection`
  - Document image space <-> canvas/view space and render output space.

No other helper is allowed to reinterpret origin direction, display offsets, or
pixel scale implicitly.

## Persistence Rules

- Document package format `4` and later must persist
  `DocumentCoordinateContract` in `document.json`.
- Format `4` packages missing `coordinateContract` are invalid.
- Legacy package formats `1...3` load through the explicit
  `legacyDocumentPackageV1ToV3` migration contract. They do not silently
  default to the current contract.
- New packages write `capture.sourceRect` and do not write the legacy
  `capture.bounds` field.

## Normalization Rules

- Standardize and integral-round only at explicit boundaries:
  capture source rect creation, preview crop rect creation, document snapshot
  initialization, and final export crop clipping.
- Do not store mixed logical-point and pixel units in the same field.
- Do not use booleans such as `flipY` to change the meaning of a rect
  parameter. Different coordinate meanings require different APIs.
- Do not add compatibility aliases such as `capture.bounds` for screenshot
  geometry. Use the canonical property name for the canonical space.
