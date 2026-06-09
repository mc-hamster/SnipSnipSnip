# SnipSnipSnip

SnipSnipSnip is a local-first macOS screenshot, annotation, history, OCR, and screen recording app. SnipSnipSnip Pro adds advanced capture workflows, including scrolling capture, connected iPhone/iPad capture, and UI Map.

## Features

- Region, window, frontmost window, fullscreen, repeat, and timer screenshot capture.
- SnipSnipSnip Pro scrolling screenshot capture and connected iPhone/iPad capture.
- Non-destructive screenshot editor with crop, rectangle, ellipse, line, arrow, freehand, highlight, text, callouts, ruler measurements, spotlight/dim, image overlays, rotation, layer ordering, grouping, alignment, snapping, and blur/pixelate/solid redaction.
- Local OCR for capture-history search and selectable Copy Text from a dragged screenshot region.
- SnipSnipSnip Pro UI Map capture for saving visible interface element names, roles, identifiers, hierarchy, and geometry in editable `.sss` documents. UI Map turns a Window screenshot into a searchable, inspectable structured capture instead of pixels only.
- PNG, JPEG, and PDF screenshot export with re-encoded metadata-stripped output.
- Drag-out sharing for rendered screenshots, styled presentation previews, and trimmed video exports.
- Floating reference screenshots for pinning rendered editor or history snapshots in lightweight always-on-top windows.
- Editable `.sss` screenshot packages with base image, preview, annotations, undo/redo history, search metadata, and image overlay assets.
- Region, window, and fullscreen screen recording with current-display, selected-display, and all-displays fullscreen modes, cursor/click options, system audio, microphone narration, pause/resume controls, trim editing, `.sssvideo` packages, MP4 export presets, and short-loop GIF/APNG export.
- Autosave checkpoints, recent snips, archive search, recycle bin, archive size limits, and custom archive location.

For the detailed current feature inventory, partial features, and known gaps, see [FEATURE_LIST.md](FEATURE_LIST.md).

## Privacy Posture

SnipSnipSnip processes screenshots, annotations, OCR, rendering, and any SnipSnipSnip Pro UI Map metadata locally. Editable `.sss` packages retain the original base screenshot, annotation state, and any captured UI Map metadata, so share rendered exports when redactions must be flattened or editable metadata should not travel.

Private Capture skips archive checkpoints, recent-snips recovery, recycle-bin retention, and background OCR indexing for that capture session. Exported/copied PNG, JPEG, and PDF output is re-encoded and does not carry source EXIF, TIFF, GPS, IPTC, or user metadata forward.

## Permissions

- Screen Recording: required for screenshot capture, window thumbnails, and screen recording pixels.
- Accessibility: required in SnipSnipSnip Pro for Scrolling Capture, where the app must scroll the selected target, and for UI Map Window capture, where visible interface metadata can be read during the user-initiated capture workflow.
- Microphone: required only when microphone narration is enabled for recording.

The app Settings screen includes permission diagnostics, remediation buttons, and a local sanitized diagnostics export for support. Standard region, window, and fullscreen capture do not require Accessibility.

### Accessibility Permission For Xcode Builds

When testing Pro Scrolling Capture or UI Map from Xcode, macOS grants Accessibility access to the exact `.app` bundle that Xcode launched. Development builds usually run from DerivedData, so granting access to a copied app in `/Applications` will not grant access to the debug build.

If SnipSnipSnip is not listed in **System Settings > Privacy & Security > Accessibility**:

1. Run SnipSnipSnip from Xcode.
2. In SnipSnipSnip, open the Accessibility permission help and choose **Reveal App**.
3. In Finder, select the revealed `SnipSnipSnip.app`.
4. In **System Settings > Privacy & Security > Accessibility**, click `+` and choose that exact revealed app.
5. Toggle SnipSnipSnip on if macOS adds it disabled.
6. Quit and relaunch SnipSnipSnip from Xcode.

If Finder cannot navigate to the hidden Library folder, press `Cmd + Shift + G` and paste the DerivedData path, such as:

```text
/Users/<you>/Library/Developer/Xcode/DerivedData
```

## Filename Templates

Screenshot Save As and export suggestions use `ScreenshotFilenameTemplate`. The default is:

```text
SnipSnipSnip-{source}-{yyyy-MM-dd-HH-mm-ss}
```

Supported tokens include `{kind}`, `{source}`, `{width}`, `{height}`, `{format}`, and date/time tokens such as `{yyyy-MM-dd-HH-mm-ss}`.

## Document Formats

- `.sss`: editable screenshot package. See [sss-format.md](sss-format.md).
- `.sssvideo`: editable video package containing source media, trim state, poster frame, and recording metadata. See [sssvideo-format.md](sssvideo-format.md).

## Build And Test

Open `SnipSnipSnip.xcodeproj` in Xcode, or run:

```sh
xcodebuild test -project SnipSnipSnip.xcodeproj -scheme SnipSnipSnip -destination 'platform=macOS,arch=arm64,name=My Mac' -derivedDataPath /private/tmp/SnipSnipSnip-DerivedData
```

The test suite uses `/private/tmp` for DerivedData so build artifacts stay out of the repo.

## Performance Profiling

Use the profiling guide in [PERFORMANCE_PROFILING.md](PERFORMANCE_PROFILING.md).

Run a focused profiling pass with:

```sh
./bin/profile-performance
```
