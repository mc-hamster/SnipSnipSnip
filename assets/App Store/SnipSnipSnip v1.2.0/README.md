# SnipSnipSnip 1.2.0 — App Store assets

English (US) submission materials for the Mac App Store edition. Prepared from
1.2.0 (179), commit `d02d4920b27c56eb46cc566afb4f39b5c33ae59a`, on October 6, 2026.

## Upload files

- `screenshots/en-US/`: nine ordered 1440 × 900, opaque RGB PNGs.
- `previews/en-US/SnipSnipSnip-1.2.0-Create.mp4`: a 25.5-second App Preview,
  1920 × 1080, H.264 High Profile Level 4.0, 30 fps, with silent stereo AAC.
- `metadata/en-US/`: name, subtitle, description, promotional text, keywords,
  What's New (`release_notes.txt`), and existing website/support/privacy URLs.
- `metadata/review_notes.txt`: suggested App Review notes. Preserve the existing
  contact information in App Store Connect; no account is required.
- `metadata/copyright.txt`: existing copyright attribution.

`review/Contact-Sheet.png` and `review/Preview-Poster.png` are for review, not
additional screenshot uploads. Set the App Preview poster to approximately
7 seconds, where the Comparison is settled. The preview is understandable
without sound; it contains no music or voiceover.

## Screenshot order

| Order | Feature | Headline |
| --- | --- | --- |
| 01 | Capture home | More than a screenshot. |
| 02 | Annotation | Make your point clear. |
| 03 | Polish | Ready for the spotlight. |
| 04 | Video | Show it in motion. |
| 05 | Comparison | Show what changed. |
| 06 | Steps | One step at a time. |
| 07 | Combined Image | Bring every view together. |
| 08 | Clipboard History | Find it. Reuse it. |
| 09 | Screen Ruler and Screen Inspector | Get the details right. |

## Applying the update

1. In App Store Connect, open SnipSnipSnip's macOS **1.2.0** version.
2. Replace the English screenshots with the numbered PNGs, in order.
3. Replace outdated 1.1.7 previews with the new Create preview, or omit previews.
   Do not carry forward footage of the old Clipboard History or Video UI.
4. Paste the matching plain-text metadata files. Keep the current categories,
   pricing, review contact, and privacy answers unless the release audit requires
   a change. The package does not change those account settings.
5. Recheck the Help and visual UI against the final selected build if it differs
   from build 179. Confirm the support and privacy URLs in a browser.
6. Select the final release build only after the separate release/test gates pass.

Nothing in this package has been uploaded or submitted for review. The existing
Fastlane release lanes skip metadata and screenshots, so running them does not
apply these files. This package is not a signed app build or a release-test gate.

## Reproduction and validation

From the repository root:

```sh
npm ci --prefix 'assets/App Store'
node 'assets/App Store/SnipSnipSnip v1.2.0/render.mjs'
node 'assets/App Store/SnipSnipSnip v1.2.0/render-preview.mjs'
python3 'assets/App Store/SnipSnipSnip v1.2.0/validate.py'
python3 Tools/check-identity-safety.py
```

The renderers use the pinned `sharp` dependency and shared lockfile in
`assets/App Store`. Installed `node_modules` stay local and are ignored by Git.
The preview renderer also requires `ffmpeg`; validation uses `ffprobe`.
`validation.json` records dimensions, encoding, metadata counts, and upload-file
SHA-256 hashes. Preview render intermediates are regenerated locally. Create
submission ZIPs and their checksum files under the ignored `build/` directory;
the individual submission assets remain the tracked source of truth.

For fresh captures, first coordinate an exclusive app window with other
automations and verify that SnipSnipSnip has exited. Never terminate a user-owned
copy or bypass its lifetime lock. Export the selected commit with `git archive`
to a disposable directory, excluding `assets`, and run
`capture-support/prepare.py /absolute/path/to/snapshot`. Build/run the focused
`App Store Screenshots` scheme there with separate DerivedData,
`SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG APP_STORE_BUILD'`,
`SNIP_BUILD_TARGET=Release`, and `-parallel-testing-enabled NO`. Run only
`SnipSnipSnipUITests/AppStoreScreenshotAssetUITests`.

The capture helper is for a **fresh disposable source snapshot only**. It injects
fictional demo content, updates stale capture-test selectors, and isolates
recovery. It is not a shipping source patch. Export named PNG attachments with
`xcresulttool export attachments` and place them in `captures/`. Keep the complete
test result outside the repository because diagnostic attachments can contain
desktop pixels. Retain only reviewed app-window captures and cropped footage.

## Sources and edition boundaries

Product claims follow `README.md`, `Docs/WorkflowLexicon.md`, and the current
feature matrix. What's New covers changes since 1.1.7 and explicitly explains
the removal of Auto Copy and the Copy to Clipboard Capture Preset replacement.
No live Guide creation, Scrolling Capture, Connected Device Capture, UI Map
capture, or keyboard-shortcut recording is advertised for this edition. Existing
Guide-document editing/export support is described separately.

Technical constraints were checked against Apple's
[screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications),
[App Preview specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/app-preview-specifications),
and [platform metadata limits](https://developer.apple.com/help/app-store-connect/reference/app-information/platform-version-information).
The existing identity, subtitle, and copyright were checked against the
[public listing](https://apps.apple.com/us/app/snipsnipsnip/id6761775175?mt=12).
