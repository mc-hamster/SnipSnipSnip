# Scrolling capture validation

Manual Scroll is available in every edition and uses Screen Recording permission.
The person scrolls normally and chooses Stop. Speed changes, pauses, and
reversals do not require a special input rhythm. A stationary viewport is not evidence of completion in
this mode. Auto Scroll is Pro-only and additionally needs Accessibility access.
Both modes share alignment, accepted strips, output bounds, and partial results.

## Deterministic replay gate

`ScrollingReplayTests` replays variable distances, idle frames, sticky headers,
short final movements, reverse motion, missed overlap, local layout changes, and
200 one-pixel increments. Successful sequences compare every output pixel to a
known page; rejected frames must leave accepted pixels intact. The existing
`ScrollingStitcherTests` also cover repeated rows, blank pages, color-only motion,
changed viewport sizes, output limits, and interactive performance budgets.

Independent overlap-band checks reject locally inconsistent movement even when
the whole-overlap average is plausible. Accepted strips own their bitmap storage;
a tiny increment must not retain an entire additional captured viewport.

Run the focused suites serially through `Tools/run-release-test-gate.sh`, with
`--only-testing SnipSnipSnipTests/ScrollingReplayTests` and the stitcher, capture
service, manual capture, scrolling workflow, and viewport suites. Check the Dev
namespace before starting the host. The shipping app can remain running.

## Local real-app replay corpus

Set `SSS_SCROLL_REPLAY_CORPUS` to an absolute JSON manifest path when running
`ScrollingReplayTests/testExternalCaptureCorpus`. It is explicitly skipped when
no corpus is provided. Captured frames and outputs stay outside Git. Use synthetic
documents or explicitly approved screenshots; do not collect ordinary private
pages, window titles, or document content for diagnostics.

All image paths below are relative to the manifest directory. Images are lossless
PNG. Every case compares its final output pixel-for-pixel; individual frames may
also name an expected accumulated output. Results are `appended`, `unchanged`,
`lowConfidence`, or `reachedMaximumHeight`.

```json
{
  "cases": [{
    "name": "synthetic browser page, slow wheel",
    "first": "first.png",
    "maximumHeight": 100000,
    "frames": [
      {"image": "second.png", "result": "appended"},
      {"image": "second.png", "result": "unchanged", "expected": "stitched.png"}
    ],
    "expected": "stitched.png"
  }]
}
```

## Live compatibility matrix

These are required follow-up observations, not claims established by unit tests.
Record OS, app version, edition, display scale, mode, output dimensions, completion
reason, and whether every seam was checked. No real-app combination is certified
by the deterministic replay suite alone.

| Target | Content and interaction | Required result |
| --- | --- | --- |
| Safari, Chrome, Firefox | Long local text, sticky header, lazy-loaded images | Exact seams or an explicit retained partial result |
| Native text and PDF viewers | Trackpad inertia, scrollbar drag, short final scroll | No duplicate tail or missing final rows |
| Nested browser panels | Pointer inside selected pane; outer page stationary | Correct selected viewport; safe interruption on mismatch |
| Repeated lists and blank sections | Equal-looking rows, long blank region | No invented motion; ambiguous movement remains unaccepted |
| Dynamic pages | Caret blink, animated image, layout reflow | No unsafe seam accepted solely on global similarity |
| Manual Scroll without Accessibility | Focus the source app, pause, resume scrolling, Stop, Cancel | Idle does not finish; progress remains visible and controls remain operable while the source app is active |
| Pro Auto Scroll | Non-settable AX scrollbar, delayed positions | Safe retries without skipping accepted content |
| Long captures | Narrow result beyond 65,536 px; wide result at pixel budget | Readable navigation, editable save/reopen, supported exports |
| Multiple displays | Retina/non-Retina and negative display origins | Stable viewport geometry and correct pixel coordinates |

App Store and Pro builds must both compile. Signed-candidate Screen Recording
consent and sandboxed export checks require live validation; do not reset the
user's privacy permissions to obtain these results.

## Implementation validation — 2026-11-14

The development regression passes exercised 580 distinct test cases: 579 passed
on their closing run and the optional external frame corpus was explicitly
skipped. Early failures were corrected: architecture assertions now inspect the
extracted dependency file, the Quick Controls assertion expects Manual Scroll in
the standard edition, and advanced Guide preview geometry uses uncapped logical
presentation dimensions. The final 90-case Guide/renderer run passed completely,
including full-resolution controls for redaction pixels. Repository hygiene,
identity safety, string-catalog parsing, and whitespace checks pass.

Debug app/test targets and the universal App Store Release build compile. Both
built products retain the single-instance prohibition and distinct Dev/shipping
bundle identifiers. No release was published and the running shipping app was
not terminated.

A live Dev attempt exercised mode selection, manual instructions, region
selection, cancellation, and early Stop with a visible retained-result warning.
The computer-use foreground controls interfered with the intended Safari region;
the resulting image was not a valid Safari stitching sample. It is not counted
as cross-app stitching success. The Dev session and disposable browser tab were
closed. The live matrix above, including exact seams on real browser/native
content, remains unverified; no real-app frame corpus was collected.

## Natural manual scrolling follow-up

Manual Scroll now uses a native screen-only stream at a requested 60 frames per
second, with an in-memory frame queue bounded to eight frames and a nominal
64 MiB budget (one frame minimum). It records no video or audio. Platforms without
a streaming implementation use the screenshot adapter. Processing does not wait
for identical frames. It tracks direction and the connected captured interval,
so reversals revisit existing rows and upward movement can extend the beginning.
Detected fixed headers are kept once when extending upward. Preview generation
is throttled independently of frame acquisition.

A mismatch no longer interrupts manual capture. The last connected reference is
retained while new frames are examined; reconnecting clears the status. Stop
drains queued frames and discloses any still-unconnected content. No guessed
seam is used to bridge missing screen content. Cancel stops the stream and returns
no result. User-facing guidance is simply “Scroll normally. Click Stop when
finished.” The manual segment default permits one-row increments all the way to
the image-height budget rather than imposing a short capture-duration limit.

`ManualScrollingAccumulatorTests` covers continuous/variable motion, reversals,
upward extension, sticky headers, animated-corner changes, reconnecting after
mismatch, byte-bounded frame buffering, capacity boundaries, and text-page
matching cost. `ManualScrollingStreamTests` verifies use of the screen-only
stream, own-app/cursor exclusion requests, draining on Stop, cancellation during
processing, idle cancellation, and failure cleanup. Live cross-app certification
remains separate from these deterministic cases.

Follow-up validation: 144 distinct affected tests passed on their closing runs;
the optional external corpus was skipped. This includes the existing automatic
stitching/permission/workflow suites and the new continuous manual capture tests.
A sparse text-row alias discovered by the continuous-page test was corrected by
verifying plausible moving matches against every overlap row before ambiguity
resolution. The measured manual text-page case meets the existing 250 ms frame
processing budget. Debug app/test compilation, repository hygiene, identity
safety, string-catalog parsing, and profiling-script syntax checks pass.
The final universal App Store Release build also passed. Live cross-app tests
remain unverified; these results do not claim arbitrary applications or unseen
content can always be reconstructed.
