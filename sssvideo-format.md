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
- `formatVersion`: `1`

The loader accepts format versions `1...1`.

## Top-Level `document.json`

- `formatIdentifier`: stable package identifier.
- `formatVersion`: current value is `1`.
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

#### `recording.preferences`

- `quality`: `compact`, `balanced`, or `high`.
- `frameRate`: `15`, `30`, or `60`.
- `fullscreenDisplayMode`: `currentDisplay`, `selectedDisplay`, or `allDisplays`.
- `selectedFullscreenDisplayID`: optional display ID when selected-display mode is used.
- `recordsSystemAudio`: boolean.
- `recordsMicrophone`: boolean.
- `showsCursor`: boolean.
- `showsMouseClicks`: boolean.

### `session`

- `trimStartSeconds`: trim start time in seconds.
- `trimEndSeconds`: trim end time in seconds.
- `posterTimeSeconds`: poster-frame timestamp in seconds.

On load, trim and poster times are normalized to the current media duration.

## Compatibility Notes

- Files with an unknown `formatIdentifier` are rejected.
- Files with `formatVersion` outside the supported range are rejected.
- Missing `document.json` or `media` assets are treated as invalid packages.
- Missing poster data is recoverable for editing, but save requires a valid poster image.
