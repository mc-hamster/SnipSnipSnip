---
description: "Use when editing SnipSnipSnipTests or adding refactor-safety coverage. Covers shared test utilities, fixture reuse, and targeted behavior-preserving regression tests."
applyTo: "SnipSnipSnipTests/**/*.swift"
---

# Test Maintenance Instructions

- Consolidate repeated factories and image/pixel helpers into shared test utilities instead of copying them between test files.
- Add focused coverage around the exact behavior being refactored before making large structural cleanup changes.
- Prefer small test helpers that mirror production concepts such as snapshots, sessions, captures, and coordinate images.
- Keep test fixtures deterministic and cheap to build so behavior-preserving refactors can be validated quickly.
- When renderer, geometry, selection, or autosave logic changes, extend the nearest existing test suite rather than adding broad end-to-end tests by default.