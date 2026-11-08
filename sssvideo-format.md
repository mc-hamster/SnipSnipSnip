# `.sssvideo` Format

`SnipSnipSnip` saves editable video documents as `.sssvideo` macOS file packages. A package is a directory that Finder presents as a single file.

The format is local-first and non-destructive for edit metadata:

- The original recorded movie is stored separately from editor trim state.
- A poster frame image is stored for quick previews.
- Recording metadata and editor session values are stored as JSON.

## Package Layout

```text
example.sssvideo/
  document.json
  media.mp4
  poster.png
```

## Current Version

- `formatIdentifier`: `com.oontz.snipsnipsnip.video-document`
- `formatVersion`: `3`

The loader accepts format versions `2...3`. Version 1 remains unsupported. Version 3 ensures older readers do not silently discard editable effects or omit a separately rendered cursor. Version 2 opens with its original trim state and no added effects.

## Top-Level `document.json`

- `formatIdentifier`: stable package identifier.
- `formatVersion`: current value is `3`.
- `savedAt`: ISO-8601 timestamp for the save operation.
- `assets`: package-relative media and poster filenames.
- `recording`: recording metadata.
- `session`: editable video editor session state.

### `assets`

- `media`: usually `media.mp4`.
- `posterImage`: usually `poster.png`.

### `recording`

- `kind`: `region`, `window`, or `fullscreen`.
- `sourceName`: human-readable source label shown in the UI.
- `bounds`: recorded source bounds in display coordinates.
- `recordedAt`: ISO-8601 timestamp for recording start.
- `duration`: recording duration in seconds.
- `preferences`: recording settings used at capture time.
- `interactions`: optional local cursor samples (`time`, normalized top-left `position`, `visible`), clicks (`time`, `position`), and keyboard shortcut labels (`time`, `label`). Times refer to the original movie, with paused recording segments removed. Absence means the cursor may already be part of the source pixels and cannot be separately edited.

#### `recording.preferences`

- `quality`: `compact`, `balanced`, or `high`.
- `frameRate`: `15`, `30`, or `60`.
- `fullscreenDisplayMode`: `currentDisplay`, `selectedDisplay`, or `allDisplays`.
- `selectedFullscreenDisplayID`: optional display ID when selected-display mode is used.
- `recordsSystemAudio`: boolean.
- `recordsMicrophone`: boolean.
- `showsCursor`: boolean.
- `showsMouseClicks`: boolean.
- `recordsKeyboardShortcuts`: optional boolean, off when absent. Only explicitly enabled command/control shortcut labels are retained; ordinary typing and secure input are excluded.

### `session`

- `trimStartSeconds`: trim start time in seconds.
- `trimEndSeconds`: trim end time in seconds.
- `posterTimeSeconds`: poster-frame timestamp in seconds.
- `removedRanges`: optional ranges (`id`, `start`, `end`) excluded non-destructively from preview playback and every export. Overlapping ranges are merged by the shared timing map.
- `effects`: optional presentation state, zooms, cursor visibility/smoothing/scale, click and shortcut visibility, audio volume, and motion blur. Zooms store identity, source start/end times, scale, follow-cursor choice, normalized focus point, and transition duration. Presentation reuses the screenshot presentation model; all exporters use the same video frame renderer.

On load, trim, poster, removed ranges, and zoom times are normalized to the current media duration. Source `media.mp4` is never flattened or overwritten by editing. `poster.png` is rendered with the current effects.

## Compatibility Notes

- Files with an unknown `formatIdentifier` are rejected.
- Files with `formatVersion` outside the supported range are rejected.
- Missing `document.json` or `media` assets are treated as invalid packages.
- Missing poster data is recoverable for editing, but save requires a valid poster image.
