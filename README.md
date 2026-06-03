# SnipSnipSnip

SnipSnipSnip is a local-first macOS screenshot, annotation, history, OCR, and screen recording app.

## Features

- Region, window, frontmost window, fullscreen, repeat, and scrolling screenshot capture.
- Non-destructive screenshot editor with crop, rectangle, ellipse, line, arrow, freehand, highlight, text, callouts, ruler measurements, spotlight/dim, image overlays, rotation, grouping, alignment, snapping, and redaction.
- Local OCR for capture-history search and selectable Copy Text from a dragged screenshot region.
- PNG, JPEG, and PDF screenshot export with newly encoded metadata-stripped output.
- Drag-out sharing for rendered screenshots, styled presentation previews, and trimmed MP4 recordings.
- Editable `.sss` screenshot packages with base image, preview, annotations, undo/redo history, search metadata, and image overlay assets.
- Region, window, and fullscreen screen recording with cursor/click options, system audio, microphone narration, trim editing, `.sssvideo` packages, and MP4 export presets.
- Autosave checkpoints, recent snips, archive search, recycle bin, archive size limits, and custom archive location.

## Privacy Posture

SnipSnipSnip processes screenshots, annotations, OCR, and rendering locally. Editable `.sss` packages retain the original base screenshot and annotation state, so share rendered exports when redactions must be flattened.

Private Capture skips archive checkpoints, recent-snips recovery, recycle-bin retention, and background OCR indexing for that capture session. Exported/copied PNG, JPEG, and PDF output is re-encoded and does not carry source EXIF, TIFF, GPS, IPTC, or user metadata forward.

## Permissions

- Screen Recording: required for screenshot capture, window thumbnails, and screen recording pixels.
- Accessibility: required only for Scrolling Capture, where the app must scroll the selected target.
- Microphone: required only when microphone narration is enabled for recording.

The app Settings screen includes permission diagnostics and remediation buttons. Region and fullscreen capture do not require Accessibility.

### Accessibility Permission For Xcode Builds

When testing Scrolling Capture from Xcode, macOS grants Accessibility access to the exact `.app` bundle that Xcode launched. Development builds usually run from DerivedData, so granting access to a copied app in `/Applications` will not grant access to the debug build.

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
xcodebuild test -project SnipSnipSnip.xcodeproj -scheme SnipSnipSnip -destination platform=macOS -derivedDataPath /private/tmp/SnipSnipSnip-DerivedData
```

The test suite uses `/private/tmp` for DerivedData so build artifacts stay out of the repo.

## Performance Profiling

Use the profiling guide in [PERFORMANCE_PROFILING.md](PERFORMANCE_PROFILING.md).

Run a focused profiling pass with:

```sh
./bin/profile-performance
```
