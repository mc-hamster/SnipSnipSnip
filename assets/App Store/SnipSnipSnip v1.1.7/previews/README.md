# App Store previews — SnipSnipSnip 1.1.7

The current three-video set, archived alongside the versioned App Store screenshots. **Use the three MP4s in `output/` for delivery.** Videos 01 and 03 are unchanged; video 02 is the faster screenshot-and-video revision. The files are exact, SHA-256-verified copies of the delivered exports, not newly encoded replacements.

| Video | Story | Private viewing/download link |
| --- | --- | --- |
| 01 — Make feedback clear | Screenshot annotation, redaction, Polish, copy | [Google Drive](https://drive.google.com/file/d/1OEx6lSWU2V4UITmsG2UF1Vq9Lo4_CCZy/view?usp=drivesdk) |
| 02 — Capture it in motion v2 | Capture, annotate, copy; record, trim, preview, MP4 export | [Google Drive](https://drive.google.com/file/d/1wPvX3W634G3ZdONkvLWtmIa53_fWJ96J/view?usp=drivesdk) |
| 03 — Find it, reuse it | Clipboard History search, edit, collections, copy | [Google Drive](https://drive.google.com/file/d/1qG34sVgwuLnb047N8UnwwPQy5M7Yt_9_/view?usp=drivesdk) |

All three: 30 seconds, 1920 × 1080, constant 30 fps, H.264 High level 4.0, BT.709, approximately 11 Mbps, stereo AAC 48 kHz, fast-start MP4. No App Store submission is performed by these scripts. Approval remains Apple's decision.

## Retrieve the exact videos

No rendering or npm installation is needed. Node.js 22 or newer is sufficient. From this directory:

```sh
node scripts/retrieve.mjs --verify
node scripts/retrieve.mjs --to "/path/to/delivery-folder"
```

This copies all three original MP4s, verifies their byte counts and SHA-256 hashes, and never replaces a different existing file. Without `--to`, it verifies the originals in `output/`. `--verify` checks every archived source clip, soundtrack, poster, and final export against `assets.sha256`.

The private Drive copies provide a second retrieval route:

```sh
node scripts/retrieve.mjs --links
node scripts/retrieve.mjs --from-drive --to "/path/to/delivery-folder"
```

For scripted Drive downloads, supply `GOOGLE_DRIVE_ACCESS_TOKEN` through your local environment with read access to the files. Do not put a token in this repository, a command argument, or a committed environment file. The script stores no credentials, does not make the videos public, rejects failed or corrupt downloads, and checks the final hash before publishing a downloaded file. Existing verified destination files are reused. Browser downloads through the links above require no token setup and use your signed-in Google account. Live authenticated download was not repeated while archiving; its success/error paths are covered by mocked tests. The prior uploads were verified with Drive metadata readback.

## Recreate or revise the videos

The folder is self-contained: no Desktop paths, Codex runtime, active app, or cloud account are required for rendering. Use macOS with Helvetica available for matching typography, Node.js 22+, and `ffmpeg`/`ffprobe` on `PATH`. `FFMPEG` and `FFPROBE` may override their executable paths.

```sh
npm ci --ignore-scripts
npm run render
node scripts/validate.mjs build
node scripts/compare-rebuild.mjs
```

Render one video with `node scripts/render.mjs 02` (or `01`, `03`). Rebuilds go to ignored `build/`, never over the approved `output/` files. Edit `videos.json` to change timing or captions. Codec/font versions can affect re-encoded bytes; use retrieval, not rendering, when an exact copy is needed.

Regenerate the two original, sample-free instrumental soundtracks with:

```sh
node scripts/make-quiet-score.mjs
node scripts/make-energetic-score.mjs
```

Make a visual review sheet with:

```sh
node scripts/contact-sheet.mjs "build/02-Capture-it-in-motion-v2.mp4" "build/02-contact.png" 1 0 30
```

## Contents and provenance

- `output/`: the three exact final MP4s, actual-frame poster PNGs, technical validation report.
- `sources/`: 21 selected, already-cropped live-action clips; lossless H.264 in Matroska containers. These are editing sources, **not** App Store uploads. Only reviewed intervals/pixels are retained. No rehearsal footage, unrelated desktop edges, or save-dialog file listings are archived.
- `audio/`: the two original 30-second WAV scores.
- `videos.json`: captions, cut timing, original take/time/crop provenance, layout, audio levels, output hashes, and Drive IDs.
- `assets.sha256`: the complete binary asset inventory and checksums.
- `scripts/`: portable rendering, retrieval, integrity checks, technical validation, contact sheets, soundtrack generation, and tests. `import-production.mjs` documents the one-time import from the former Desktop production folder; it is not required for normal use. `compact-sources.mjs` losslessly compresses sources and verifies decoded pixels before replacing them; do not run it concurrently with rendering.
- `filming/`: original native recording/control helper sources, historical action plans, a fictional demo document, and refilming cautions. These are not automatically executed.

Filmed on September 12, 2026 from the already-running **sandboxed App Store Release build 1.1.7 (171)**, not the Pro build. The app source was not changed. Footage is actual UI interaction, with fictional Orbit demo content. Video 02's floating recording controls and selection overlays were excluded by the app from screen capture; the edit shows the visible controls, live activity, and actual resulting editor/export states rather than inventing overlays. Idle time was cut; no generated interface, still-frame slideshow, or crossfades were used.

The original production folders and old video 02 remain untouched. This archive contains the current three-video set only. Source compression is pixel-lossless relative to the selected decoded takes, not a claim that the original screen recordings were uncompressed.

## Checks

```sh
npm test
npm run verify
npm run validate
```

Retrieval tests cover exact copying, repeated retrieval, no-clobber behavior, corruption, authentication failure, oversized responses, temporary-file cleanup, and archive path containment. Validation fully decodes each output and checks duration, every frame timestamp, 900 frames, dimensions, progressive scan, codec/profile/level, color tags, bitrates, audio, file size, and fast-start ordering. `compare-rebuild.mjs` compares rebuilt and approved video pixels with a 0.995 SSIM regression threshold; intentional creative changes may fail that comparison. Review revised videos visually before submission.

Apple references: [creative guidance](https://developer.apple.com/app-store/app-previews/) and [upload specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications/). The saved settings reflect the production check; recheck Apple's requirements before a future release.
