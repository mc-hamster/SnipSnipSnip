# SnipSnipSnip 1.1.3 Screenshot Provenance

## Product Build

- Marketing version: 1.1.3
- Build number: 157
- Edition gate: `APP_STORE_BUILD`
- App sandbox entitlement: enabled
- Bundle identifier: `com.oontz.SnipSnipSnip`

The optimized Release App Store build was built and inspected separately. The
raw campaign screenshots were captured by the focused `App Store Screenshots`
UI-test scheme with `DEBUG APP_STORE_BUILD`. `DEBUG` enables the app's
privacy-safe deterministic demo inputs; `APP_STORE_BUILD` applies the same
edition gates as the shipping Mac App Store app.

## Capture Conditions

- One app-host process
- Parallel UI testing disabled
- Isolated UI-test data
- Privacy-safe generated demo images
- App Store-safe fixture names with no UI-test terminology
- Transient editor notices fully dismissed before capture
- Deterministic Light appearance
- Privacy-safe seeded Clipboard History entries
- Deterministic Screen Inspector sample pixels
- No Pro-only live Guide creation, Scrolling Capture, Connected Device Capture,
  or UI Map capture
- XCTest window screenshots exported from the passing result bundle

## Asset Construction

The source app pixels in `capture-1.1.3` come from XCTest screenshots. The
Screen Tools source deterministically composites the captured main window,
Screen Ruler, and Screen Inspector panels to exclude unrelated desktop edges.
The final 1440 × 900 PNGs add campaign typography, the warm parchment
presentation background, and a near-white product stage. No generated or
reconstructed app interface is used.
