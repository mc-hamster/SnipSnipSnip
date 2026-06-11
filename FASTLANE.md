# Fastlane Deployment Guide

This repository now has a project-local Fastlane setup for the `SnipSnipSnip` macOS app.

This guide assumes Fastlane is already installed locally, `fastlane/.env` is already configured, the App Store Connect API key file is in place, and Xcode signing already works for the `Release` configuration.

## Build Tooling License Note

SnipSnipSnip does not currently bundle third-party app libraries. The shipped app targets use Apple frameworks from the macOS SDK.

The repository does use Fastlane and its Ruby gem dependencies as build and release tooling, pinned by [Gemfile](Gemfile) and [Gemfile.lock](Gemfile.lock). Those tools are not copied into the app bundle. If this repository ever vendors those gems, distributes a prebuilt build environment, or adds runtime app dependencies, include the relevant third-party license notices with that distribution.

It is designed for:

- building the `SnipSnipSnip` release archive and exporting a Mac App Store package
- building a website-distribution archive with `SNIP_BUILD_TARGET=Self Release`
- publishing website-distribution builds to GitHub Releases
- uploading a build to TestFlight for internal testers
- uploading a build to TestFlight for external testers
- uploading and submitting a build to the App Store for release
- submitting an already-uploaded build to App Review later without rebuilding

## Lanes

### Validate local setup

```bash
./bin/fastlane mac doctor
```

This checks:

- the configured Xcode project exists
- the App Store Connect API key env vars are present
- the `.p8` key file is present
- the current app version and build number can be read

## Easy commands by target

### Internal testing

Use this to build a new archive, upload it, and make it available to internal TestFlight testers:

```bash
./bin/fastlane mac internal_testing
```

Common variations:

```bash
./bin/fastlane mac internal_testing version:1.0.14
./bin/fastlane mac internal_testing changelog:"Bug fixes and editor polish"
./bin/fastlane mac internal_testing version:1.0.14 changelog:"Bug fixes and editor polish"
```

What to expect:

1. Fastlane uses the current marketing version unless you pass `version:...`.
2. Fastlane bumps the build number automatically.
3. Fastlane builds the Release archive with `SNIP_BUILD_TARGET=Internal` and uploads it to TestFlight.
4. The build is uploaded for internal testing without submitting it for external beta review.

### Upload for internal testing

```bash
./bin/fastlane mac internal_testing version:1.0.1 changelog:"Phase 3 polish and bug fixes"
```

If you omit `changelog`, Fastlane generates one from git commits since the last successful Fastlane upload for that lane and stores the upload state in `~/Library/Caches/SnipSnipSnip/fastlane/upload_state.json` by default.

Fastlane build products default to `~/Library/Caches/SnipSnipSnip/fastlane` and `~/Library/Developer/Xcode/DerivedData/SnipSnipSnip-fastlane` so archive/signing does not inherit file-provider metadata from a synced Documents folder.

What it does:

1. optionally sets `MARKETING_VERSION` if you pass `version:...`
2. increments the build number above the current local and TestFlight build numbers
3. builds the `Release` archive with `SNIP_BUILD_TARGET=Internal`
4. exports a Mac App Store package
5. uploads it to TestFlight

### Upload for external testing

Use this to build a new archive and submit it to the `External Testers` TestFlight group:

```bash
./bin/fastlane mac external_testing
```

This repo already defaults `TESTFLIGHT_GROUPS` to `External Testers` in `fastlane/.env`, so the plain command is usually enough. Fastlane builds this archive with `SNIP_BUILD_TARGET=External`, which disables internal/dev-only feature flags.

To distribute to tor
nal testers:

```bash
TESTFLIGHT_GROUPS="External Testers" \
TESTFLIGHT_NOTIFY_EXTERNAL_TESTERS=true \
./bin/fastlane mac external_testing version:1.0.1 changelog:"Release candidate 1"
```

`TESTFLIGHT_GROUPS` is required for external distribution.

If the build was already uploaded earlier and you only want to distribute that processed build to external testers, reuse it instead of uploading a new binary:

```bash
./bin/fastlane mac external_testing distribute_only:true version:1.0.13 build_number:18
```

If App Store Connect says another build is already in beta review for the same version, clear the older blocking build and retry:

```bash
./bin/fastlane mac clear_external_review version:1.0.13
./bin/fastlane mac external_testing distribute_only:true version:1.0.13 build_number:18
```

What `clear_external_review` actually does:

- It finds builds for that version that are stuck in external beta review.
- It expires the older blocking build so a newer build can be submitted.
- It does not rebuild anything.

### Build, upload, and submit to App Review

Use this to create a production upload and submit it for App Review:

```bash
./bin/fastlane mac release
```

```bash
./bin/fastlane mac release version:1.0.1
```

If you omit `version`, the `release` lane automatically increments the patch version from the current marketing version before building.

Fastlane builds App Store archives with `SNIP_BUILD_TARGET=Release` and adds the Swift compilation condition `APP_STORE_BUILD`, which disables internal/dev-only feature flags and compiles out the Accessibility-backed scrolling implementation from the App Store binary.

Release safety checks are now enabled by default for `release` and `submit_review`. Before either lane can continue, set these environment variables to `true`:

- `RELEASE_METADATA_READY`
- `RELEASE_TESTS_CONFIRMED`
- `RELEASE_MANUAL_QA_CONFIRMED`

You can disable the gate only for emergencies with:

```bash
RELEASE_SAFETY_CHECKS=false
```

The `release` lane also runs a deterministic release test gate by default using `-only-testing` targets:

- `SnipSnipSnipTests/CaptureModelsTests`
- `SnipSnipSnipTests/GeometrySupportTests`
- `SnipSnipSnipTests/EditorControllerTests/testPresentationCornerRadiusClampsToOneHundred`
- `SnipSnipSnipTests/EditorControllerTests/testPresentationDefaultsToTransparentBackground`
- `SnipSnipSnipTests/EditorControllerTests/testPresentationPresetChangesAreUndoable`
- `SnipSnipSnipTests/EditorControllerTests/testPresentationShadowDirectionControlsSignedOffsets`

Override the list with a comma-separated value in `RELEASE_TEST_ONLY`, or skip the gate entirely (for example when CI already ran it) with:

```bash
RELEASE_SKIP_TESTS=true
```

### Build for website distribution

Use this to build a release archive with website-only feature flags enabled:

```bash
./bin/fastlane mac self_release
```

```bash
./bin/fastlane mac self_release version:1.0.1
```

This lane builds the `Release` configuration with `SNIP_BUILD_TARGET=Self Release` using a Developer ID export profile for website distribution. It does not upload to App Store Connect, it explicitly clears `APP_STORE_BUILD`, and it stamps the app display name as `SnipSnipSnip Pro` for the website-distribution binary.

By default, `self_release` also notarizes and staples the generated `.pkg` so downloaded installs should open without requiring users to manually clear quarantine attributes.

Self Release signing prerequisites on the build Mac:

- `Developer ID Application` certificate for team `8RN882MNR5`
- `Developer ID Installer` certificate for team `8RN882MNR5`

If either certificate is missing, Fastlane now stops before building with a clear error instead of failing later during notarization.

If you need to skip notarization temporarily (for example while debugging local signing), use:

```bash
SELF_RELEASE_NOTARIZE=false \
./bin/fastlane mac self_release
```

To build and publish the package to https://github.com/mc-hamster/SnipSnipSnip/releases:

```bash
GITHUB_TOKEN=ghp_xxx \
./bin/fastlane mac self_release_publish
```

Common variations:

```bash
GITHUB_TOKEN=ghp_xxx \
./bin/fastlane mac self_release_publish version:1.0.18

GITHUB_TOKEN=ghp_xxx \
./bin/fastlane mac self_release_publish version:1.0.18 changelog:"Website release with scrolling capture fixes"

GITHUB_TOKEN=ghp_xxx \
./bin/fastlane mac self_release_publish version:1.0.18
```

You can also publish through `self_release` directly:

```bash
GITHUB_TOKEN=ghp_xxx \
./bin/fastlane mac self_release publish:true
```

Publishing details:

1. Fastlane increments the local build number and builds with `SNIP_BUILD_TARGET=Self Release`.
2. Fastlane notarizes and staples the `.pkg` by default.
3. Fastlane discovers the newest `.pkg` in the build artifacts directory (or uses `asset_path:...` if provided).
4. Fastlane creates or updates a GitHub release (default repo `mc-hamster/SnipSnipSnip`).
5. Fastlane uploads the `.pkg` asset to that release.

Self Release GitHub releases default to pre-release and explicitly avoid being marked as Latest. Promote known-good builds to Latest manually from GitHub.

Optional publish parameters:

- `repository:owner/name` to override the destination repo (default `mc-hamster/SnipSnipSnip`)
- `tag:v1.0.18-self.123` to override the generated tag
- `release_name:"SnipSnipSnip Pro 1.0.18 Website"` to override the release title
- `draft:true` for draft release state
- `prerelease:false` only if you intentionally want to publish a Self Release as a normal release
- `asset_path:/absolute/path/to/SnipSnipSnip.pkg` to upload a specific package

### Build target feature flags

The app reads `SnipBuildTarget` from its bundle Info.plist. Local Xcode `Debug` builds default to `Dev`, local Xcode `Release` builds default to `Release`, and Fastlane can stamp shipped builds as `Internal`, `External`, `Release`, or `Self Release`.

Current gated features:

- Presentation export styling is currently enabled for `Dev` and disabled for `Internal`, `External`, `Release`, and `Self Release`.
- Scrolling Capture and Accessibility automation are enabled only for `Self Release`.
- Scrolling Capture and Accessibility automation are disabled for `Dev`, `Internal`, `External`, and `Release`.
- Local Xcode `Debug` / `Dev` builds and Fastlane `Self Release` builds run without App Sandbox so Accessibility-backed UI Map and self-distributed Pro automation can read cross-app accessibility trees after user consent.
- Fastlane `Internal`, `External`, and App Store `Release` builds all keep App Sandbox and `APP_STORE_BUILD`, so the Accessibility-backed scrolling implementation is compiled out of those binaries and extra self-distribution capabilities do not ship to App Store builds.

Before relying on `release`, verify all of the following manually in App Store Connect and Xcode:

1. The app record is fully configured for App Store release, not just TestFlight.
2. The app already has required App Store metadata, pricing, categories, and screenshots in App Store Connect.
3. The Release build signs correctly for App Store distribution on this Mac.
4. The export compliance answer is correct in `fastlane/.env` via `USES_NON_EXEMPT_ENCRYPTION=false` for this app.
5. A valid editable App Store version exists in App Store Connect or can be created by the upload.

Important limitation: the `release` and `submit_review` lanes intentionally use `skip_metadata: true` and `skip_screenshots: true`, so they do not upload store listing content. That content must already be complete in App Store Connect.

By default this lane:

- increments the build number
- builds and uploads a new package
- submits the uploaded build for review
- does not automatically release after approval
- skips metadata and screenshots uploads

To enable automatic release after approval:

```bash
APP_STORE_AUTOMATIC_RELEASE=true \
./bin/fastlane mac release version:1.0.1
```

Recommended first production test:

```bash
./bin/fastlane mac doctor
RELEASE_METADATA_READY=true \
RELEASE_TESTS_CONFIRMED=true \
RELEASE_MANUAL_QA_CONFIRMED=true \
./bin/fastlane mac release version:1.0.14
```

Then confirm in App Store Connect that the build attached to the intended App Store version and that submission succeeded before treating this lane as production-ready.

### Submit an already-uploaded build later

If you already uploaded a build earlier and just want to submit it for review:

```bash
./bin/fastlane mac submit_review build_number:42
```

If you omit `build_number`, Fastlane will try to submit the latest processed build for the current editable version.

## Common release flow

### TestFlight first, then App Store

Use this when you want to test a build before production:

```bash
./bin/fastlane mac internal_testing version:1.0.1 changelog:"Release candidate"
```

Wait for the build to finish processing in App Store Connect, then either:

```bash
./bin/fastlane mac submit_review
```

or:

```bash
./bin/fastlane mac submit_review build_number:42
```

`submit_review` has the same prerequisites and safety confirmations as `release`: App Store metadata/screenshots must already be complete in App Store Connect, and release confirmations must be set.

### Direct App Store submission

Use this when you want Fastlane to build, upload, and submit immediately:

```bash
RELEASE_METADATA_READY=true \
RELEASE_TESTS_CONFIRMED=true \
RELEASE_MANUAL_QA_CONFIRMED=true \
./bin/fastlane mac release version:1.0.1
```

## CI automation

Three GitHub Actions workflows are included:

- `.github/workflows/ci-tests.yml`: runs `xcodebuild test` on pull requests and pushes to `main`.
- `.github/workflows/release-app-store.yml`: manual (`workflow_dispatch`) App Store release workflow with:
	- preflight test gate
	- environment approval gate (`app-store-production`)
	- Fastlane doctor + release execution
	- App Store Connect API key loaded from GitHub Secrets
- `.github/workflows/release-self-release.yml`: manual (`workflow_dispatch`) website release workflow that builds with `SNIP_BUILD_TARGET=Self Release` and publishes the package to GitHub Releases.

Required repository secrets for the release workflow:

- `APP_STORE_CONNECT_API_KEY_KEY_ID`
- `APP_STORE_CONNECT_API_KEY_ISSUER_ID`
- `APP_STORE_CONNECT_API_KEY_P8_BASE64`

The website release workflow uses the built-in `GITHUB_TOKEN` with `contents: write` permissions and does not require App Store Connect secrets.

## Encryption flag

The app now declares export compliance directly in [SnipSnipSnip-Info.plist](SnipSnipSnip-Info.plist) with `ITSAppUsesNonExemptEncryption=false`, so TestFlight and App Store uploads include the answer from the app bundle metadata.

If the app ever starts using non-exempt encryption, change that plist value to `true` and keep the Fastlane environment flag aligned:

```bash
USES_NON_EXEMPT_ENCRYPTION=false
```

Set it to `true` if the app really does use non-exempt encryption.

## Notes about versioning

- `MARKETING_VERSION` is the user-facing version, for example `1.0.1`.
- `CURRENT_PROJECT_VERSION` is the build number.
- The Fastlane lanes auto-increment the build number before each upload.
- If you pass `version:...`, Fastlane updates `MARKETING_VERSION` before building.

## Troubleshooting

### `fastlane` command not found

Use Bundler:

```bash
gem install bundler
bundle install
./bin/fastlane mac doctor
```

Or install the Homebrew formula:

```bash
brew install fastlane
fastlane mac doctor
```

### Signing or provisioning errors

This setup relies on Xcode-managed signing. Open Xcode, fix signing for the `Release` configuration, then rerun the lane.

### Build uploads but cannot update tester distribution info

The App Store Connect account or API key role is too limited. Use an account with `App Manager` or `Admin` permissions.

### App Store submission needs metadata

The current lanes intentionally skip metadata and screenshots uploads. Manage those in App Store Connect for now, or extend Fastlane later with `fastlane/metadata`.
