---
name: sss-validation
description: Build and validate SnipSnipSnip macOS changes using its repository checks, serial app-hosted XCTest gate, edition boundaries, and documentation requirements. Use when implementing or reviewing SSS changes or diagnosing its build, test, or release failures; does not authorize publishing a release.
---

# SSS Validation

Use the SnipSnipSnip checkout attached to the current task. A worktree or another user-selected checkout takes precedence over any other local copy. Confirm `SnipSnipSnip.xcodeproj` and `Tools/run-release-test-gate.sh` exist before executing repository commands. Commands below run from that checkout.

## Read the current repository contract

- Read `AGENTS.md`, relevant nested instructions, and `git status --short`; preserve unrelated work. Use current repository instructions and tooling rather than treating this skill as a frozen copy of them.
- Read `Tools/README.md` for validation procedures. Inspect the gate's implementation or `--help` when its options matter.
- Before UI changes, read `Docs/DesignLanguage.md`. Before terminology or user-facing copy changes, read `Docs/WorkflowLexicon.md`. Check the matching updates in `SnipSnipSnip/App/HelpGuideView.swift`; new concepts must also be reflected in the lexicon and affected surfaces. Reusable visual patterns or exceptions require corresponding design-language updates.
- Automation changes require coordinated updates to `Docs/AutomationServicePlan.md`, `Docs/Automation/README.md`, affected `Docs/Automation/SampleScripts`, and contract tests. Preserve procedure basenames and parity across CLI, AppleScript, and supported URL routes; keep samples out of app build products.

## Choose validation that matches the change

Run hygiene and identity guards before submitting source changes:

```sh
python3 Tools/check-repository-hygiene.py
python3 Tools/check-identity-safety.py
```

After staging, also run `python3 Tools/check-repository-hygiene.py --staged` against the exact pending commit. Do not stage unrelated files just to run this check. If a guard fails on pre-existing work, identify the failure and its relationship to this task rather than silently repairing unrelated changes.

- Geometry, commands, rendering, selection, and persistence: extend the nearest relevant regression suite and reuse shared fixtures. Preserve non-destructive base images and annotation state; undoable editor changes belong in commands. Reject ambiguous identities through `EditorIdentityIntegrity`; never silently drop screenshot content.
- Startup or lock changes: include `SingleInstanceCoordinatorTests` and relevant platform/startup coverage, including built-product configuration. Preserve both `LSMultipleInstancesProhibited` and the lifetime lock acquired before `AppModel` or services. Restart must wait for the current PID to exit; keep the lock descriptor close-on-exec.
- Automation: include the affected contract/sample suites and run `bash -n` on changed shell samples. Use the existing `Tools/validate-automation-samples.py` only when runtime sample verification is relevant, after reading its fixture requirements. It mutates document, clipboard, and file state; run only against the disposable Debug audit fixture, never ordinary user documents.
- HTML export: read the composition browser matrix in `Tools/README.md` and use the existing validator when applicable. The complete CI gate requires installed Chrome and Firefox with `SSS_RUN_EXTERNAL_HTML_BROWSER_TESTS=1` and `SSS_REQUIRE_EXTERNAL_HTML_BROWSERS=1`.
- Performance: use `PERFORMANCE_PROFILING.md` and `bin/profile-performance` when a performance change or regression warrants profiling; keep artifacts outside Git.
- Documentation-only work: verify links, terminology, and referenced commands. Do not launch an app or run a full XCTest suite solely for prose changes.

## Preserve the single-instance test host

Before every app launch or app-hosted test run, check `pgrep -x SnipSnipSnip`. A match means an active instance; distinguish it from permission/tool errors.

If a user-owned instance is running, continue build-only validation. Ask the user to quit it when runtime tests are required, citing the current `AGENTS.md` rule. Do not terminate it without permission. Never bypass the guard with `open -n`, direct execution of the app's `Contents/MacOS/SnipSnipSnip`, or changes to its lock or Info.plist. Recheck before proceeding after an instance exits.

Build-only example (choose `build-for-testing` when test compilation is needed):

```sh
xcodebuild build-for-testing \
  -project SnipSnipSnip.xcodeproj -scheme SnipSnipSnip \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath /private/tmp/SnipSnipSnip-SkillValidation
```

When no instance is running, prefer the repository's existing serial gate. For focused diagnosis, append repeatable `--only-testing SnipSnipSnipTests/SuiteName` arguments using verified suite names. For complete release validation, omit these filters:

```sh
Tools/run-release-test-gate.sh \
  --derived-data /private/tmp/SnipSnipSnip-SkillValidation \
  --result-bundle /private/tmp/SnipSnipSnip-SkillValidation.xcresult
```

Use fresh result-bundle paths and distinct output directories for concurrent checkouts. Run app-hosted suites in one host process without parallel test workers. The gate owns signing preparation for the developer test runner; do not transfer its signing adjustments to shipped app bundles. Do not label successful test compilation as passing runtime tests.

## Check edition and release boundaries when affected

Read `FASTLANE.md`, current build settings, and the relevant release workflow. Validate App Store and Self Release branches when touching permissions, build flags, capture backends, feature visibility, or automation routing. `APP_STORE_BUILD` is the authoritative App Store compile condition; preserve ordinary capture without Accessibility and preservation of existing Guide/UI Map document content. Use the current signed-candidate QA checklist rather than assuming Debug tests prove release behavior.

Validation does not authorize upload, release publication, notarization submission, App Review submission, permission resets, or destructive cleanup. Do not set release confirmation variables to claim unperformed checks or bypass release gates. Carry out such actions only within the user's actual authorization.

## Report evidence

State what changed, which checks passed, and any failed, skipped, or deferred checks with their reason. Distinguish source/build validation, runtime tests, and signed-candidate manual QA. After relevant checks pass, repeat or broaden them only for new changes, failures, or unresolved concerns.
