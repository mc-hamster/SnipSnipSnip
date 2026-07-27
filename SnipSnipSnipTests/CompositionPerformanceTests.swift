import CoreGraphics
import Darwin
import Foundation
import XCTest
@testable import SnipSnipSnip

/// Deterministic release fixtures for Multi-Capture Composition.
///
/// These tests intentionally separate fixture construction from timing. The
/// layout matrix covers every layout at 2, 10, 50, and 200 items. Preview
/// fixtures retain distinct encoded sources in `CompositionAssetRepository`
/// and require descriptor-first rendering to downsample each placed item
/// before editing. Export fixtures continue to use full-resolution images.
final class CompositionPerformanceTests: XCTestCase {
    private static let previewPixelCap = 1_800

    func testLayoutP95BudgetAcrossDeterministicCountsAndModes() throws {
        let counts = [2, 10, 50, 200]
        let modes = CompositionLayoutMode.allCases
        var reportLines = [
            "count,mode,p95_ms,maximum_ms,canvas_width,canvas_height,item_count",
        ]

        for count in counts {
            for mode in modes {
                let fixture = makeLayoutFixture(itemCount: count, mode: mode)

                // Warm caches and one-time framework initialization before the
                // samples that decide the release gate.
                for _ in 0..<3 {
                    _ = try CompositionLayoutEngine.layout(
                        composition: fixture.composition,
                        assetDescriptors: fixture.descriptors
                    )
                }

                var samples: [TimeInterval] = []
                var finalLayout: CompositionRenderLayout?
                for _ in 0..<25 {
                    let start = DispatchTime.now().uptimeNanoseconds
                    finalLayout = try CompositionLayoutEngine.layout(
                        composition: fixture.composition,
                        assetDescriptors: fixture.descriptors
                    )
                    let end = DispatchTime.now().uptimeNanoseconds
                    samples.append(TimeInterval(end - start) / 1_000_000_000)
                }

                let layout = try XCTUnwrap(finalLayout)
                XCTAssertEqual(
                    layout.items.count + layout.omittedItemIDs.count,
                    count,
                    "\(mode.rawValue) must account for every deterministic fixture item"
                )

                let p95 = percentile95(samples)
                let maximum = samples.max() ?? 0
                reportLines.append(
                    [
                        String(count),
                        mode.rawValue,
                        milliseconds(p95),
                        milliseconds(maximum),
                        String(Int(layout.canvasSize.width.rounded())),
                        String(Int(layout.canvasSize.height.rounded())),
                        String(layout.items.count),
                    ].joined(separator: ",")
                )

                if count == 200 {
                    XCTAssertTrue(
                        PerformanceBudgetCatalog.compositionLayout200ItemP95.contains(p95),
                        "\(mode.rawValue) layout p95 was \(milliseconds(p95)) ms; "
                            + "the 200-item gate is "
                            + "\(milliseconds(PerformanceBudgetCatalog.compositionLayout200ItemP95.maximumSeconds)) ms"
                    )
                }
            }
        }

        attachReport(
            reportLines.joined(separator: "\n"),
            name: "Composition layout performance matrix"
        )
    }

    func testCappedAppend4KPreviewFixtureMeetsWarmAndColdBudgets() throws {
        let existingPNG = try autoreleasepool {
            try ImageExporter.pngData(
                for: makeCoordinateImage(
                    width: 3_840,
                    height: 2_160,
                    pattern: .weighted(
                        xMultiplier: 7,
                        yMultiplier: 13,
                        includeBlueSum: true
                    )
                )
            )
        }
        let appendedPNG = try autoreleasepool {
            try ImageExporter.pngData(
                for: makeCoordinateImage(
                    width: 3_840,
                    height: 2_160,
                    pattern: .weighted(
                        xMultiplier: 11,
                        yMultiplier: 17,
                        includeBlueSum: false
                    )
                )
            )
        }
        let existingAssetID = deterministicUUID(10_001)
        let appendedAssetID = deterministicUUID(10_002)
        let repository = CompositionAssetRepository(storedAssets: [
            storedAsset(
                id: existingAssetID,
                width: 3_840,
                height: 2_160,
                encodedPNG: existingPNG,
                name: "Existing 4K"
            ),
            storedAsset(
                id: appendedAssetID,
                width: 3_840,
                height: 2_160,
                encodedPNG: appendedPNG,
                name: "Appended 4K"
            ),
        ])
        let existingItem = CompositionItem(
            id: deterministicUUID(20_001),
            assetID: existingAssetID
        )
        let appendedItem = CompositionItem(
            id: deterministicUUID(20_002),
            assetID: appendedAssetID
        )
        let composition = CompositionSnapshot(
            items: [existingItem, appendedItem],
            layout: CompositionLayoutConfiguration(
                mode: .row,
                targetAspectRatio: 16 / 9
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )

        // Existing content is already visible, so its item preview is warm.
        let existingComposition = CompositionSnapshot(
            items: [existingItem],
            layout: CompositionLayoutConfiguration(mode: .auto),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        _ = try CompositionRenderer.renderPreview(
            composition: existingComposition,
            assetRepository: repository,
            options: previewOptions
        )
        repository.resetDiagnostics()

        let coldElapsed = try PerformanceBudgetTimer.measure {
            let result = try CompositionRenderer.renderPreview(
                composition: composition,
                assetRepository: repository,
                options: previewOptions
            )
            XCTAssertLessThanOrEqual(result.image.width, Self.previewPixelCap)
        }
        XCTAssertTrue(
            PerformanceBudgetCatalog.compositionAppend4KPreviewCold.contains(coldElapsed),
            "Cold capped append preview took \(milliseconds(coldElapsed)) ms; "
                + "the gate is "
                + "\(milliseconds(PerformanceBudgetCatalog.compositionAppend4KPreviewCold.maximumSeconds)) ms"
        )

        let warmElapsed = try PerformanceBudgetTimer.measure {
            let result = try CompositionRenderer.renderPreview(
                composition: composition,
                assetRepository: repository,
                options: previewOptions
            )
            XCTAssertLessThanOrEqual(result.image.width, Self.previewPixelCap)
        }
        XCTAssertTrue(
            PerformanceBudgetCatalog.compositionAppend4KPreviewWarm.contains(warmElapsed),
            "Warm capped append preview took \(milliseconds(warmElapsed)) ms; "
                + "the gate is "
                + "\(milliseconds(PerformanceBudgetCatalog.compositionAppend4KPreviewWarm.maximumSeconds)) ms"
        )
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 0)
        XCTAssertGreaterThanOrEqual(
            repository.diagnostics.renderedPreviewCacheHitCount,
            2,
            "The existing item and then the complete warm composition should reuse bounded item previews."
        )

        attachReport(
            """
            path,elapsed_ms,budget_ms
            cold,\(milliseconds(coldElapsed)),\(milliseconds(PerformanceBudgetCatalog.compositionAppend4KPreviewCold.maximumSeconds))
            warm,\(milliseconds(warmElapsed)),\(milliseconds(PerformanceBudgetCatalog.compositionAppend4KPreviewWarm.maximumSeconds))
            """,
            name: "Composition append preview performance"
        )
    }

    func testTwoItem4KComparisonPreviewAt1800PixelCapBudget() throws {
        let fixture = try makeComparisonPreviewFixture()

        // Warm Core Graphics and registration helpers.
        _ = try CompositionRenderer.renderPreview(
            composition: fixture.composition,
            assetRepository: fixture.repository,
            options: previewOptions
        )

        let elapsed = try measuredP95(iterations: 5) {
            let result = try CompositionRenderer.renderPreview(
                composition: fixture.composition,
                assetRepository: fixture.repository,
                options: previewOptions
            )
            XCTAssertEqual(max(result.image.width, result.image.height), Self.previewPixelCap)
        }
        XCTAssertEqual(fixture.repository.diagnostics.fullResolutionDecodeCount, 0)

        XCTAssertTrue(
            PerformanceBudgetCatalog.compositionComparison4KPreview.contains(elapsed),
            "Two-item 4K comparison preview p95 took \(milliseconds(elapsed)) ms; "
                + "the gate is "
                + "\(milliseconds(PerformanceBudgetCatalog.compositionComparison4KPreview.maximumSeconds)) ms"
        )
        attachReport(
            """
            path,p95_ms,budget_ms
            two_4k_comparison,\(milliseconds(elapsed)),\(milliseconds(PerformanceBudgetCatalog.compositionComparison4KPreview.maximumSeconds))
            """,
            name: "Composition comparison preview performance"
        )
    }

    func testTwelveItem1080pGridPreviewAt1800PixelCapBudget() throws {
        let fixture = try makeTwelveItemPreviewFixture()

        _ = try CompositionRenderer.renderPreview(
            composition: fixture.composition,
            assetRepository: fixture.repository,
            options: previewOptions
        )
        let elapsed = try measuredP95(iterations: 5) {
            let result = try CompositionRenderer.renderPreview(
                composition: fixture.composition,
                assetRepository: fixture.repository,
                options: previewOptions
            )
            XCTAssertEqual(result.image.width, Self.previewPixelCap)
            XCTAssertLessThanOrEqual(result.image.height, Self.previewPixelCap)
        }

        XCTAssertTrue(
            PerformanceBudgetCatalog.compositionTwelveItemPreview.contains(elapsed),
            "Twelve-item preview p95 took \(milliseconds(elapsed)) ms; "
                + "the gate is "
                + "\(milliseconds(PerformanceBudgetCatalog.compositionTwelveItemPreview.maximumSeconds)) ms"
        )
        attachReport(
            """
            path,p95_ms,budget_ms
            twelve_1080p_grid,\(milliseconds(elapsed)),\(milliseconds(PerformanceBudgetCatalog.compositionTwelveItemPreview.maximumSeconds))
            """,
            name: "Composition grid preview performance"
        )
    }

    func testFourItem1080pFullPNGExportBudget() async throws {
        let fixture = makeFourItemExportFixture()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("composition-performance-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sampler = ResidentMemorySampler()
        sampler.start()
        var didStopSampler = false
        defer {
            if !didStopSampler {
                _ = sampler.stop()
            }
        }
        let start = DispatchTime.now().uptimeNanoseconds
        let result = try CompositionRenderer.render(
            composition: fixture.composition,
            renderedItemImages: fixture.images
        )
        try await ImageExporter.write(
            result.image,
            format: .png,
            to: outputURL,
            mode: .direct
        )
        let elapsed = TimeInterval(
            DispatchTime.now().uptimeNanoseconds - start
        ) / 1_000_000_000
        let peakIncrease = sampler.stop()
        didStopSampler = true

        XCTAssertEqual(result.image.width, 3_840)
        XCTAssertEqual(result.image.height, 2_160)
        XCTAssertGreaterThan(
            (try FileManager.default.attributesOfItem(atPath: outputURL.path)[.size] as? NSNumber)?.intValue ?? 0,
            0
        )
        XCTAssertTrue(
            PerformanceBudgetCatalog.compositionFourItemPNGExport.contains(elapsed),
            "Four-item 1080p PNG export took \(milliseconds(elapsed)) ms; "
                + "the gate is "
                + "\(milliseconds(PerformanceBudgetCatalog.compositionFourItemPNGExport.maximumSeconds)) ms"
        )
        XCTAssertLessThanOrEqual(
            peakIncrease,
            UInt64(PerformanceBudgetCatalog.compositionTwelveItemExportPeakMemoryBytes),
            "Four-item export raised resident memory by \(mebibytes(peakIncrease)) MiB; "
                + "the twelve-item release ceiling is "
                + "\(mebibytes(UInt64(PerformanceBudgetCatalog.compositionTwelveItemExportPeakMemoryBytes))) MiB"
        )
        attachReport(
            """
            path,elapsed_ms,budget_ms,peak_increase_mib,memory_budget_mib
            four_1080p_png,\(milliseconds(elapsed)),\(milliseconds(PerformanceBudgetCatalog.compositionFourItemPNGExport.maximumSeconds)),\(mebibytes(peakIncrease)),\(mebibytes(UInt64(PerformanceBudgetCatalog.compositionTwelveItemExportPeakMemoryBytes)))
            """,
            name: "Composition PNG export performance"
        )
    }

    func testTwelveItem1080pExportStaysWithinPeakMemoryGate() async throws {
        let fixture = makeTwelveItemExportFixture()
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("composition-memory-\(UUID().uuidString)")
            .appendingPathExtension("png")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let sampler = ResidentMemorySampler()
        sampler.start()
        var didStopSampler = false
        defer {
            if !didStopSampler {
                _ = sampler.stop()
            }
        }

        let result = try CompositionRenderer.render(
            composition: fixture.composition,
            renderedItemImages: fixture.images
        )
        try await ImageExporter.write(
            result.image,
            format: .png,
            to: outputURL,
            mode: .direct
        )
        let peakIncrease = sampler.stop()
        didStopSampler = true

        XCTAssertEqual(result.image.width, 7_680)
        XCTAssertEqual(result.image.height, 3_240)
        XCTAssertLessThanOrEqual(
            peakIncrease,
            UInt64(PerformanceBudgetCatalog.compositionTwelveItemExportPeakMemoryBytes),
            "Twelve-item export raised resident memory by \(mebibytes(peakIncrease)) MiB; "
                + "the gate is "
                + "\(mebibytes(UInt64(PerformanceBudgetCatalog.compositionTwelveItemExportPeakMemoryBytes))) MiB"
        )
        attachReport(
            """
            path,peak_increase_mib,memory_budget_mib
            twelve_1080p_png,\(mebibytes(peakIncrease)),\(mebibytes(UInt64(PerformanceBudgetCatalog.compositionTwelveItemExportPeakMemoryBytes)))
            """,
            name: "Composition twelve-item export memory"
        )
    }

    func testCompositionPreviewBenchmarkMetrics() throws {
        let fixture = try makeTwelveItemPreviewFixture()
        let options = XCTMeasureOptions.default
        options.iterationCount = 5

        measure(
            metrics: [XCTClockMetric(), XCTCPUMetric(), XCTMemoryMetric()],
            options: options
        ) {
            do {
                let result = try CompositionRenderer.renderPreview(
                    composition: fixture.composition,
                    assetRepository: fixture.repository,
                    options: previewOptions
                )
                XCTAssertEqual(result.image.width, Self.previewPixelCap)
            } catch {
                XCTFail("Composition preview benchmark failed: \(error)")
            }
        }
    }

    func testRepeatedCompositionPreviewCyclesStayWithinPeakMemoryGate() throws {
        let fixture = try makeTwelveItemPreviewFixture()
        let sampler = ResidentMemorySampler()
        sampler.start()
        var didStopSampler = false
        defer {
            if !didStopSampler {
                _ = sampler.stop()
            }
        }

        for _ in 0..<20 {
            try autoreleasepool {
                let result = try CompositionRenderer.renderPreview(
                    composition: fixture.composition,
                    assetRepository: fixture.repository,
                    options: previewOptions
                )
                XCTAssertEqual(result.image.width, Self.previewPixelCap)
            }
        }

        let peakIncrease = sampler.stop()
        didStopSampler = true
        XCTAssertLessThanOrEqual(
            peakIncrease,
            UInt64(PerformanceBudgetCatalog.compositionPreviewPeakMemoryBytes),
            "Repeated preview cycles raised resident memory by \(mebibytes(peakIncrease)) MiB; "
                + "the gate is "
                + "\(mebibytes(UInt64(PerformanceBudgetCatalog.compositionPreviewPeakMemoryBytes))) MiB"
        )
        XCTAssertEqual(fixture.repository.diagnostics.fullResolutionDecodeCount, 0)
        attachReport(
            """
            cycles,peak_increase_mib,memory_budget_mib
            20,\(mebibytes(peakIncrease)),\(mebibytes(UInt64(PerformanceBudgetCatalog.compositionPreviewPeakMemoryBytes)))
            """,
            name: "Composition repeated preview memory"
        )
    }

    // MARK: - Fixtures

    private struct LayoutFixture {
        let composition: CompositionSnapshot
        let descriptors: [UUID: CompositionAssetDescriptor]
    }

    private struct RenderFixture {
        let composition: CompositionSnapshot
        let images: [UUID: CGImage]
    }

    private struct PreviewFixture {
        let composition: CompositionSnapshot
        let repository: CompositionAssetRepository
    }

    private var previewOptions: CompositionRenderOptions {
        CompositionRenderOptions(
            maximumPixelDimension: 16_384,
            maximumPixelCount: 134_217_728,
            targetMaximumPixelDimension: Self.previewPixelCap
        )
    }

    private func makeLayoutFixture(
        itemCount: Int,
        mode: CompositionLayoutMode
    ) -> LayoutFixture {
        let sourceSizes: [CGSize] = [
            CGSize(width: 3_840, height: 2_160),
            CGSize(width: 1_440, height: 2_560),
            CGSize(width: 2_880, height: 1_800),
            CGSize(width: 1_024, height: 1_024),
            CGSize(width: 1_280, height: 3_200),
            CGSize(width: 5_120, height: 1_440),
            CGSize(width: 1_600, height: 900),
        ]
        let items = (0..<itemCount).map { index in
            let assetID = deterministicUUID(100_000 + index)
            let column = index % 10
            let row = index / 10
            return CompositionItem(
                id: deterministicUUID(200_000 + index),
                assetID: assetID,
                framing: CompositionItemFraming(
                    contentMode: index.isMultiple(of: 3) ? .fill : .contain
                ),
                weight: CGFloat((index % 5) + 1),
                title: "Capture \(index + 1)",
                caption: index.isMultiple(of: 3)
                    ? "Deterministic step \(index + 1)"
                    : nil,
                freeformFrame: CGRect(
                    x: CGFloat(column * 260 - (index.isMultiple(of: 9) ? 18 : 0)),
                    y: CGFloat(row * 180 - (index.isMultiple(of: 11) ? 12 : 0)),
                    width: CGFloat(220 + (index % 4) * 12),
                    height: CGFloat(130 + (index % 3) * 10)
                ),
                zIndex: index
            )
        }
        let descriptors = Dictionary(
            uniqueKeysWithValues: items.enumerated().map { index, item in
                let size = sourceSizes[index % sourceSizes.count]
                return (
                    item.assetID,
                    CompositionAssetDescriptor(
                        id: item.assetID,
                        pixelWidth: Int(size.width),
                        pixelHeight: Int(size.height),
                        sourceName: "Fixture \(index + 1)"
                    )
                )
            }
        )
        var appearance = CompositionCanvasAppearance()
        appearance.insets = CompositionInsets(12)
        appearance.itemSpacing = 8
        appearance.captionFontSize = 13
        let comparison = CompositionComparisonSettings(
            mode: .wipe,
            axis: .horizontal,
            primaryItemID: items.first?.id,
            secondaryItemID: items.dropFirst().first?.id,
            registrationMode: .disabled
        )
        let steps = CompositionStepsSettings(
            axis: .vertical,
            flow: .grid,
            gridColumns: 4,
            numberingStyle: .decimal,
            startIndex: 1,
            showsCaptions: true,
            connectorStyle: .arrow
        )
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(
                mode: mode,
                gridColumns: 5,
                targetAspectRatio: 16 / 9,
                freeformCanvasSize: nil,
                sizingMode: .weighted,
                orientation: .landscape
            ),
            comparison: comparison,
            steps: steps,
            canvas: CompositionCanvasState(
                title: "Composition performance fixture",
                appearance: appearance
            )
        )
        return LayoutFixture(composition: composition, descriptors: descriptors)
    }

    private func makeComparisonPreviewFixture() throws -> PreviewFixture {
        let firstImage = makeCoordinateImage(
            width: 3_840,
            height: 2_160,
            pattern: .weighted(xMultiplier: 5, yMultiplier: 11, includeBlueSum: true)
        )
        let secondImage = makeCoordinateImage(
            width: 3_840,
            height: 2_160,
            pattern: .weighted(xMultiplier: 7, yMultiplier: 13, includeBlueSum: true)
        )
        let firstItem = CompositionItem(
            id: deterministicUUID(300_001),
            assetID: deterministicUUID(310_001),
            semanticRole: .before
        )
        let secondItem = CompositionItem(
            id: deterministicUUID(300_002),
            assetID: deterministicUUID(310_002),
            semanticRole: .after
        )
        let composition = CompositionSnapshot(
            items: [firstItem, secondItem],
            layout: CompositionLayoutConfiguration(
                mode: .compare,
                targetAspectRatio: 16 / 9
            ),
            comparison: CompositionComparisonSettings(
                mode: .wipe,
                axis: .horizontal,
                primaryItemID: firstItem.id,
                secondaryItemID: secondItem.id,
                registrationMode: .automatic
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let repository = CompositionAssetRepository(storedAssets: [
            storedAsset(
                id: firstItem.assetID,
                width: firstImage.width,
                height: firstImage.height,
                encodedPNG: try ImageExporter.pngData(for: firstImage),
                name: "Comparison A"
            ),
            storedAsset(
                id: secondItem.assetID,
                width: secondImage.width,
                height: secondImage.height,
                encodedPNG: try ImageExporter.pngData(for: secondImage),
                name: "Comparison B"
            ),
        ])
        return PreviewFixture(
            composition: composition,
            repository: repository
        )
    }

    private func makeTwelveItemPreviewFixture() throws -> PreviewFixture {
        // A four-column grid starts as a 7680×3240 full-resolution layout and
        // must be rendered directly into an exact 1800 px preview.
        let items = (0..<12).map {
            CompositionItem(
                id: deterministicUUID(400_000 + $0),
                assetID: deterministicUUID(410_000 + $0)
            )
        }
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .grid, gridColumns: 4),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let storedAssets = try items.enumerated().map { index, item in
            try autoreleasepool {
                let image = makeCoordinateImage(
                    width: 1_920,
                    height: 1_080,
                    pattern: .weighted(
                        xMultiplier: 3 + index * 2,
                        yMultiplier: 7 + index * 2,
                        includeBlueSum: index.isMultiple(of: 2)
                    )
                )
                return storedAsset(
                    id: item.assetID,
                    width: image.width,
                    height: image.height,
                    encodedPNG: try ImageExporter.pngData(for: image),
                    name: "Grid source \(index + 1)"
                )
            }
        }
        return PreviewFixture(
            composition: composition,
            repository: CompositionAssetRepository(storedAssets: storedAssets)
        )
    }

    private func makeFourItemExportFixture() -> RenderFixture {
        let items = (0..<4).map {
            CompositionItem(
                id: deterministicUUID(500_000 + $0),
                assetID: deterministicUUID(510_000 + $0)
            )
        }
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .grid, gridColumns: 2),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        return RenderFixture(
            composition: composition,
            images: Dictionary(
                uniqueKeysWithValues: items.enumerated().map { index, item in
                    (
                        item.id,
                        makeCoordinateImage(
                            width: 1_920,
                            height: 1_080,
                            pattern: .weighted(
                                xMultiplier: 5 + index * 2,
                                yMultiplier: 13 + index * 2,
                                includeBlueSum: index.isMultiple(of: 2)
                            )
                        )
                    )
                }
            )
        )
    }

    private func makeTwelveItemExportFixture() -> RenderFixture {
        let items = (0..<12).map {
            CompositionItem(
                id: deterministicUUID(600_000 + $0),
                assetID: deterministicUUID(610_000 + $0)
            )
        }
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .grid, gridColumns: 4),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        return RenderFixture(
            composition: composition,
            images: Dictionary(
                uniqueKeysWithValues: items.enumerated().map { index, item in
                    (
                        item.id,
                        makeCoordinateImage(
                            width: 1_920,
                            height: 1_080,
                            pattern: .weighted(
                                xMultiplier: 3 + index * 2,
                                yMultiplier: 11 + index * 2,
                                includeBlueSum: !index.isMultiple(of: 3)
                            )
                        )
                    )
                }
            )
        )
    }

    private func storedAsset(
        id: UUID,
        width: Int,
        height: Int,
        encodedPNG: Data,
        name: String
    ) -> CompositionStoredAsset {
        CompositionStoredAsset(
            descriptor: CompositionAssetDescriptor(
                id: id,
                pixelWidth: width,
                pixelHeight: height,
                sourceName: name
            ),
            encodedPNG: encodedPNG
        )
    }

    // MARK: - Measurement

    private func measuredP95(
        iterations: Int,
        operation: () throws -> Void
    ) rethrows -> TimeInterval {
        var samples: [TimeInterval] = []
        samples.reserveCapacity(iterations)
        for _ in 0..<iterations {
            let start = DispatchTime.now().uptimeNanoseconds
            try operation()
            let end = DispatchTime.now().uptimeNanoseconds
            samples.append(TimeInterval(end - start) / 1_000_000_000)
        }
        return percentile95(samples)
    }

    private func percentile95(_ samples: [TimeInterval]) -> TimeInterval {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(
            max(Int(ceil(Double(sorted.count) * 0.95)) - 1, 0),
            sorted.count - 1
        )
        return sorted[index]
    }

    private func deterministicUUID(_ value: Int) -> UUID {
        UUID(
            uuidString: String(
                format: "00000000-0000-4000-8000-%012llX",
                UInt64(value)
            )
        )!
    }

    private func milliseconds(_ seconds: TimeInterval) -> String {
        String(format: "%.3f", seconds * 1_000)
    }

    private func mebibytes(_ bytes: UInt64) -> String {
        String(format: "%.1f", Double(bytes) / 1_024 / 1_024)
    }

    private func attachReport(_ body: String, name: String) {
        let attachment = XCTAttachment(string: body)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        print("\nCOMPOSITION_PERFORMANCE_REPORT \(name)\n\(body)")
    }
}

private final class ResidentMemorySampler: @unchecked Sendable {
    private let lock = NSLock()
    private let completion = DispatchSemaphore(value: 0)
    private var isRunning = false
    private var baselineBytes: UInt64 = 0
    private var peakBytes: UInt64 = 0

    func start() {
        let baseline = currentResidentBytes()
        lock.lock()
        baselineBytes = baseline
        peakBytes = baseline
        isRunning = true
        lock.unlock()

        let thread = Thread { [self] in
            while sampleIfRunning() {
                usleep(1_000)
            }
            completion.signal()
        }
        thread.name = "Composition performance memory sampler"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func stop() -> UInt64 {
        lock.lock()
        isRunning = false
        lock.unlock()
        completion.wait()

        let finalBytes = currentResidentBytes()
        lock.lock()
        peakBytes = max(peakBytes, finalBytes)
        let increase = peakBytes > baselineBytes ? peakBytes - baselineBytes : 0
        lock.unlock()
        return increase
    }

    private func sampleIfRunning() -> Bool {
        let residentBytes = currentResidentBytes()
        lock.lock()
        defer { lock.unlock() }
        guard isRunning else { return false }
        peakBytes = max(peakBytes, residentBytes)
        return true
    }

    private func currentResidentBytes() -> UInt64 {
        var information = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &information) {
            $0.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) {
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    $0,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(information.resident_size)
    }
}
