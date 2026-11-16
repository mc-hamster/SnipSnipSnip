# Capture provenance

The app UI is from SnipSnipSnip **1.2.0 (179)** at commit
`d02d4920b27c56eb46cc566afb4f39b5c33ae59a`. A `git archive` snapshot under
`/private/tmp/SnipSnipSnip120Assets/source` kept concurrent automation edits out
of the capture build. The shared checkout's shipping code was not changed by
the asset task.

The dedicated UI-test build uses `DEBUG APP_STORE_BUILD` and
`SNIP_BUILD_TARGET=Release`, with the real App Store edition gates. Debug enables
deterministic inputs; this ad-hoc capture build is **not sandbox validation** or
the signed submission candidate. `LSMultipleInstancesProhibited` and the early
lifetime lock were retained. One app host ran at a time, with parallel testing
disabled. The separate automation released its own app before these tests and
was notified when exclusive access ended.

## Source selection

| Capture | Result bundle | Notes |
| --- | --- | --- |
| `01-screenshot-edit.png` | Campaign-03 | Real editor and tool properties |
| `03-comparison.png` | Campaign-03 | Unobstructed Before/After review |
| `04-steps.png` | Campaign-06 | Ordered images with the demo annotation |
| `05-combined-image.png` | Campaign-06 | Arrange controls and two demo images |
| `06-polish.png` | Campaign-06 | Built-in Canvas Look, with an editable annotation |
| `07-capture-home.png` | Campaign-06 | Video recovery isolated; no unrelated recovery banner |
| `08-clipboard-history.png` | Campaign-06 | Fictional, seeded clipboard items |
| `08-clipboard-preview.png` | Campaign-06 | Additional source, not an upload screenshot |
| `09-screen-ruler.png` | Campaign-06 | App's actual floating ruler |
| `10-screen-inspector.png` | Campaign-06 | App's actual inspector with deterministic sample pixels |
| `11-video-review.png` | Campaign-06 | Additional source, not used in the final sequence |
| `12-video-trim.png` | Campaign-06 | Real Video editor with Trim visible |

Campaign-03 and Campaign-06 passed. The final screenshot package uses only
unobstructed captures: two Campaign-06 frames containing another foreground
window were rejected and overwritten with the reviewed Campaign-03 versions.
The complete result bundles stay outside the repository. Earlier harness runs
found stale window selectors; one later launch attempt failed during a temporary
system-wide file-access stall. None of those failures indicates a product-test
pass or release readiness.

## Sample content and isolation

The Orbit project is fictional artwork authored for the existing campaign.
Its SVG sources are included in `demo/`; they depict the content being captured,
not a reconstructed SnipSnipSnip interface. The demo video is a local fixture
used inside the real Video editor. The screenshot, Clipboard History, preference,
and final Video recovery stores use temporary data. The user's pre-existing
Video recovery file was not discarded, opened, or changed.

The capture helper changes only the disposable snapshot: demo inputs, test
commands, stale test selectors, an ordinary editable Arrow annotation, and test
store isolation. The normal renderers and editing commands produce all app
pixels. No AI-generated app interface is used.

## App Preview

`captures/preview-source.mp4` contains three continuous excerpts from the
Campaign-01 XCTest screen recording of the **same 1.2.0 (179) app UI**. This run
captured the creation workflows successfully before encountering the obsolete
Screen Ruler selector later. Only the reviewed creation footage is retained:

- Comparison: 9.5–18.0 seconds in the original recording.
- Steps: 21.6–30.1 seconds.
- Combined Image: 32.9–41.4 seconds.

The 3024 × 1964 desktop recording was cropped to the app interior at
`x=244, y=266, width=2536, height=1376` before saving the source asset. The crop
excludes desktop, menu-bar, and external-window pixels. It is conformed to
30 fps at original speed, with straight cuts and campaign captions. The final
preview is 25.5 seconds long, 1920 × 1080, H.264 High Profile Level 4.0, with
silent stereo AAC at 48 kHz. There is no recorded desktop audio.

## Composition and verification

`render.mjs` adds campaign typography and a warm parchment background. It fits
real app-window images without changing UI labels or controls. A rounded alpha
mask removes pixels outside native window corners. The Screen Ruler slide crops
to the actual ruler face, omitting the desktop behind its floating close button.
Final screenshot PNGs are opaque RGB at 1440 × 900. The contact sheet is separate
from the nine upload files.

`validate.py` checks filename order, source presence, screenshot format and
dimensions, metadata field limits (including keyword UTF-8 bytes), preview
encoding, frame rate, duration, size, and checksums. The asset task also runs the
repository identity-safety checker. These checks complement visual review and
do not replace the separate signed-build release test gate.
