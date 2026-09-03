# Screenshot export permission regression

## Failure mechanism

The build 166 report describes PNG, JPEG, and PDF export failures. The original
`ImageExporter` streamed encoded output into a hidden temporary sibling of the
selected destination. A save-panel sandbox grant can cover the selected file
without allowing arbitrary siblings. ImageIO returned a generic encoding error
when it could not create that temporary output; PDF creation failed as well.

The project disables App Sandbox in Debug and enables it in Release. A successful
Debug export therefore does not exercise the release permission boundary.
Downloads also has an explicit read/write entitlement, so it is a useful control
but not a sufficient regression destination.

`ImageExportFileWriter` now obtains a system replacement directory on the
destination volume, encodes there, then installs the complete file. Destination
security-scoped access remains active throughout. Encoding failure or cancellation
before installation preserves an existing destination and removes staging.
No new permissions, output formats, or automation contracts are introduced.

Apple references:

- [Accessing files from the macOS App Sandbox](https://developer.apple.com/documentation/security/accessing-files-from-the-macos-app-sandbox)
- [Replacing a file using a temporary directory on its volume](https://developer.apple.com/documentation/foundation/filemanager/replaceitemat(_:withitemat:backupitemname:options:))

## Automated coverage

`ImageExportFileWriterTests` covers creation and replacement of readable PNG,
JPEG, and PDF files, PDF page bounds matching the image size, staging outside
the destination folder, preservation after encoding failure and cancellation,
and cleanup after installation failure.

An isolated exporter probe also reproduced the original failures with writes
denied under a fixture destination directory except for the three exact output
filenames. The patched exporter created and replaced all three outputs under
the same restriction. This validates the file-permission mechanism; it does not
establish the reporter's actual destination or OS-specific behavior.

The probe also found that the existing PDF writer never set the page media box,
so every page inherited the constructor default of US Letter and screenshots
larger than 612 x 792 points were clipped in viewers. The PDF writers now pass
an image-sized media box to the PDF context, and `ImageExportFileWriterTests`
asserts that the exported page bounds match the image for both the data-based
and staged file writers.

## Release validation

1. Follow the single-instance rules in `AGENTS.md`: quit the existing app with the
   user's permission before launching a sandboxed release or app-hosted XCTest.
   Use build-only validation while a user-owned copy remains running.
2. Run a sandboxed release, with a fresh process and a destination folder that
   has not previously been granted folder access. Do not use Downloads alone.
3. Capture a small non-sensitive screenshot. Export PNG, JPEG, and PDF through
   the save panel into a local folder, then repeat with existing output names.
4. Open each exported file and verify content. Confirm no temporary siblings
   remain and no encoding alert appears.
5. Repeat with iCloud Drive, an external volume, and a network share when
   available. Record any skipped destination.
6. Check Copy and Drag separately; their in-memory/direct-write paths are
   unchanged. Run `ImageExportFileWriterTests`, `DragOutSharingTests`, and
   `EditorRendererTests` in one non-parallel app host.

For the original report, request the exact macOS version/build, app distribution
(App Store or Pro), destination type, whether Downloads works, and whether Copy
works. A sanitized Settings > Privacy > Export Diagnostics report is useful;
the user's screenshot content is not needed to investigate this permission bug.
