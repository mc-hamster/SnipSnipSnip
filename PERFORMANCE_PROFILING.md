# Performance Profiling

This guide defines the repeatable release-profiling loop for SnipSnipSnip. The
checked-in budgets live in `PerformanceBudgetCatalog`; changing a gate requires
updating the catalog, its tests, and this document together.

## What Is Measured

The focused profiling command runs every test listed here. Keep this list and
`PERF_TESTS` in `bin/profile-performance` identical.

Existing scalable paths:

- `EditorRendererTests/testRenderPerformanceDenseAnnotationScene`
- `EditorRendererTests/testRenderPerformanceCommonAnnotationScene`
- `AppModelPerformanceTests/testCaptureEntryPointPerformance`
- `AppModelPerformanceTests/testScreenshotRenderAndStreamingExportBudget`
- `AppModelPerformanceTests/testArchiveIndexedSearchBudget`
- `AppModelPerformanceTests/testVideoExportPlanningAndStorageBudget`
- `ScrollingStitcherTests/testAppendPerformanceLongScrollingSession`
- `ScrollingStitcherTests/testAppendPerformanceManySmallScrollingFrames`

Multi-Capture Composition release paths:

- `CompositionPerformanceTests/testLayoutP95BudgetAcrossDeterministicCountsAndModes`
- `CompositionPerformanceTests/testCappedAppend4KPreviewFixtureMeetsWarmAndColdBudgets`
- `CompositionPerformanceTests/testTwoItem4KComparisonPreviewAt1800PixelCapBudget`
- `CompositionPerformanceTests/testTwelveItem1080pGridPreviewAt1800PixelCapBudget`
- `CompositionPerformanceTests/testFourItem1080pFullPNGExportBudget`
- `CompositionPerformanceTests/testTwelveItem1080pExportStaysWithinPeakMemoryGate`
- `CompositionPerformanceTests/testCompositionPreviewBenchmarkMetrics`
- `CompositionPerformanceTests/testRepeatedCompositionPreviewCyclesStayWithinPeakMemoryGate`

XCTest benchmark methods record wall-clock, CPU, and memory metrics. Named gate
tests also make explicit wall-clock or resident-memory assertions, so the run
fails instead of relying only on a manually compared Xcode baseline.

The composition layout test uses deterministic mixed-aspect fixtures containing
2, 10, 50, and 200 items. It exercises Auto, Compare, Steps, Row, Column, Grid,
and Freeform. The result bundle contains a CSV attachment with each count and
layout’s p95, maximum duration, output size, and accounted item count.

Preview renderer fixtures pass full-resolution item images with an explicit
1,800-pixel target. They enforce that composition assembly scales directly into
the capped bitmap instead of allocating a full-resolution composite and
downsampling afterward. The append fixture measures cold decode plus capped
assembly and the warm cached path. Release sign-off must additionally trace the
end-to-end Add Capture workflow in the UI; an on-screen preview must never
create or cache a full-resolution composite before its final downsample.

## Composition Release Gates

Run these gates on the CI reference Mac with no other SnipSnipSnip process
running:

| Workload | Gate |
|---|---:|
| Layout, 200 mixed-aspect items, every layout | under 16 ms p95 |
| Append one captured 4K item to a visible preview | under 250 ms warm; under 500 ms cold |
| Two 4K-source comparison preview, 1,800 px cap | under 250 ms p95 |
| Twelve 1080p-source grid preview, 1,800 px cap | under 500 ms p95 |
| Four 1080p items, full PNG render and write | under 3 seconds |
| Preview resident-memory increase | at most 256 MiB |
| Twelve-item export resident-memory increase | at most 512 MiB |
| Repeated preview/export cycles | no retained growth after caches stabilize |

Time gates are hard assertions in `CompositionPerformanceTests`. The preview
memory gate is sampled across 20 render cycles. The export fixtures sample
resident-memory growth while rendering and writing both four- and twelve-item
full-resolution PNGs. XCTest’s resident-memory sampler establishes the ceiling,
but Instruments is the authority for distinguishing a retained allocation from
an allocator cache. Compare the stable post-warm-up generations, not a cold
process launch against a warm process.

## One-Command Profiling

Before running, quit any user-owned SnipSnipSnip copy. The test target is
app-hosted and the product intentionally permits only one process. The script
checks this invariant and exits without terminating the running app.

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
./bin/profile-performance build/profiling/composition-release-1 /private/tmp/SnipSnipSnip-PerfDD
```

The default destination is the concrete local Mac:
`platform=macOS,arch=$(uname -m),name=My Mac`. Override it only when the release
reference machine needs a different concrete destination:

```sh
SNIP_PERF_DESTINATION='platform=macOS,arch=arm64,name=My Mac' ./bin/profile-performance
```

The script runs the shared scheme nonparallel in one app-host process and
writes:

- performance test result bundle (`PerformanceTests.xcresult`)
- raw build and test log (`performance-tests.log`)
- Time Profiler trace (`time-profiler.trace`) when `xctrace` is available
- Allocations trace (`allocations.trace`) when `xctrace` is available
- trace diagnostics (`xctrace-*.log`)

## Baseline Workflow

1. Record the Mac model, processor, memory, macOS build, Xcode build, build
   configuration, and commit SHA with the profiling artifacts.
2. Run the script on current `main` into a named output folder.
3. Run it again from the candidate build using the same machine and idle-state
   conditions.
4. Compare median and p95 clock time, CPU time, peak memory, top self-time
   symbols, and persistent allocation generations.
5. Investigate any meaningful movement even when a broad hard ceiling still
   passes. A gate is a release limit, not a regression allowance.
6. Complete end-to-end Add Capture, comparison, grid-preview, and export traces.
   Confirm preview work is capped before composition assembly.

## Regression Triage Checklist

- If composition layout regresses, inspect candidate enumeration, caption and
  number reservation, Freeform normalization, and repeated dictionary creation.
- If append or preview regresses, verify thumbnails are decoded at the requested
  cell size, per-item preview caches are keyed by asset/edit revision and cell
  size, and the full-resolution composite is never created for display.
- If comparison regresses, separate registration cost from compositing cost and
  confirm registration work is reused while framing is unchanged.
- If export regresses, inspect intermediate canvas lifetimes, PNG streaming, and
  whether item edits are rendered more than once.
- If renderer time regresses, inspect `EditorRenderer` draw/export paths and
  redaction processing.
- If stitcher time regresses, inspect `ScrollingStitcher.bestMatch`
  coarse/refined loops and `GrayImage` conversion.
- If archive search regresses, inspect `DocumentRecoveryStore` search-index
  loading and checkpoint metadata updates before adding UI-side filtering.
- If video budget checks regress, inspect `VideoStorageGuardrails` temp-file
  scanning and avoid walking unrelated directories.
- If memory regresses, verify cache costs, autorelease-pool boundaries, image
  provider ownership, and intermediate image lifetimes.
- Confirm behavior remains unchanged with the corresponding functional and
  pixel-golden tests before optimizing.
