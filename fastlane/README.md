fastlane documentation
----

# Installation

Make sure you have the latest version of the Xcode command line tools installed:

```sh
xcode-select --install
```

For _fastlane_ installation instructions, see [Installing _fastlane_](https://docs.fastlane.tools/#installing-fastlane)

# Available Actions

## Mac

### mac doctor

```sh
[bundle exec] fastlane mac doctor
```

Validate the local fastlane and App Store Connect setup

### mac internal_testing

```sh
[bundle exec] fastlane mac internal_testing
```

Build and upload a macOS package to TestFlight for internal testers

### mac external_testing

```sh
[bundle exec] fastlane mac external_testing
```

Build and upload a macOS package to TestFlight for external testers

### mac clear_external_review

```sh
[bundle exec] fastlane mac clear_external_review
```

Clear the current external beta review submission for a version

### mac release

```sh
[bundle exec] fastlane mac release
```

Build, upload, and optionally submit a macOS package for App Store review

### mac self_release

```sh
[bundle exec] fastlane mac self_release
```

Build a website-distribution package with Self Release feature flags

### mac submit_review

```sh
[bundle exec] fastlane mac submit_review
```

Submit an already uploaded build for App Store review without rebuilding

----

This README.md is auto-generated and will be re-generated every time [_fastlane_](https://fastlane.tools) is run.

More information about _fastlane_ can be found on [fastlane.tools](https://fastlane.tools).

The documentation of _fastlane_ can be found on [docs.fastlane.tools](https://docs.fastlane.tools).
