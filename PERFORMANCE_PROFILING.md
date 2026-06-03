# Performance Profiling

This guide adds a repeatable profiling loop for the macOS 26 API modernization pass.

## What Is Measured

Focused performance tests cover the highest-cost and highest-risk paths:

- `EditorRendererTests/testRenderPerformanceDenseAnnotationScene`
- `EditorRendererTests/testRenderPerformanceCommonAnnotationScene`
- `AppModelPerformanceTests/testCaptureEntryPointPerformance`
- `AppModelPerformanceTests/testScreenshotRenderAndStreamingExportBudget`
- `AppModelPerformanceTests/testArchiveIndexedSearchBudget`
- `AppModelPerformanceTests/testVideoExportPlanningAndStorageBudget`
- `ScrollingStitcherTests/testAppendPerformanceLongScrollingSession`
- `ScrollingStitcherTests/testAppendPerformanceManySmallScrollingFrames`

Each test records:

- wall clock time (`XCTClockMetric`)
- CPU cost (`XCTCPUMetric`)
- memory pressure (`XCTMemoryMetric`)

## One-Command Profiling

Run:

```sh
./bin/profile-performance
```

Optional arguments:

```sh
./bin/profile-performance <output-dir> <derived-data-path>
```

Example:

```sh
./bin/profile-performance build/profiling/macos26-pass-1 /private/tmp/SnipSnipSnip-PerfDD
```

The script writes:

- performance test result bundle (`PerformanceTests.xcresult`)
- raw xcodebuild log (`performance-tests.log`)
- Time Profiler trace (`time-profiler.trace`) when `xctrace` is available
- Allocations trace (`allocations.trace`) when `xctrace` is available

## Baseline Workflow

1. Run the script on current `main` and save artifacts under a named folder.
2. Re-run after each modernization batch.
3. Compare:
   - median clock time for each test in Xcode test reports
   - named budget failures from `PerformanceBudgetCatalog`
   - top self-time symbols in `time-profiler.trace`
   - persistent allocation growth in `allocations.trace`

## Regression Triage Checklist

- If renderer time regresses: inspect `EditorRenderer` draw/export paths and redaction processing.
- If stitcher time regresses: inspect `ScrollingStitcher.bestMatch` coarse/refined loops and `GrayImage` conversion.
- If archive search regresses: inspect `DocumentRecoveryStore` search-index loading and checkpoint metadata update paths before adding UI-side filtering work.
- If video budget checks regress: inspect `VideoStorageGuardrails` temp-file scanning and avoid walking unrelated directories.
- If memory regresses: verify image cache behavior and intermediate image lifetimes.
- Confirm behavior remains unchanged with existing functional tests before optimizing.
