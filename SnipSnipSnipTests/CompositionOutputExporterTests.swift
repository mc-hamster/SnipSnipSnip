import AVFoundation
import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SnipSnipSnip

final class CompositionOutputExporterTests: XCTestCase {
    func testHTMLItemSizingUsesResourceBudgetRatherThanItemCountLimit() {
        XCTAssertEqual(
            CompositionOutputExporter.htmlItemMaximumDimension(
                renderedImageCount: 1
            ),
            4_096
        )
        XCTAssertLessThan(
            CompositionOutputExporter.htmlItemMaximumDimension(
                renderedImageCount: 200
            ),
            1_000
        )
        XCTAssertGreaterThanOrEqual(
            CompositionOutputExporter.htmlItemMaximumDimension(
                renderedImageCount: 10_000
            ),
            1
        )
    }

    func testBlinkStaticPosterDefaultsToAfter() throws {
        let fixture = makeComparisonFixture(mode: .blink)

        let image = try CompositionOutputExporter.staticImage(fixture.input)

        XCTAssertEqual(
            samplePixel(in: image, topLeftX: image.width / 2, topLeftY: image.height / 2),
            PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )
    }

    @MainActor
    func testPresentationPreviewDefaultsToPosterButAcceptsExplicitLiveBlinkPhase() throws {
        let primaryCapture = makeCapturedScreenshot(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
            ),
            sourceName: "Before"
        )
        let secondaryCapture = makeCapturedScreenshot(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
            ),
            sourceName: "After"
        )
        let repository = CompositionAssetRepository()
        let primaryAssetID = try repository.add(
            capture: primaryCapture,
            isPrivate: false
        )
        let secondaryAssetID = try repository.add(
            capture: secondaryCapture,
            isPrivate: false
        )
        let items = [
            CompositionItem(assetID: primaryAssetID),
            CompositionItem(assetID: secondaryAssetID),
        ]
        var comparison = CompositionComparisonSettings(
            mode: .blink,
            primaryItemID: items[0].id,
            secondaryItemID: items[1].id
        )
        comparison.showsLabels = false
        comparison.posterFrame = .secondary
        var snapshot = makeEditorSnapshot()
        snapshot.composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: comparison
        )
        let suiteName = "CompositionOutputExporterTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let controller = EditorController(
            capture: primaryCapture,
            session: makeEditorDocumentSession(initialSnapshot: snapshot),
            defaults: defaults,
            capabilities: testCapabilities,
            compositionStoredAssets: repository.storedAssets()
        )

        let poster = try XCTUnwrap(
            controller.presentationPreviewRenderInput()?.contentImage
        )
        let primary = try XCTUnwrap(
            controller.presentationPreviewRenderInput(
                comparisonPhase: .primary
            )?.contentImage
        )
        XCTAssertEqual(
            samplePixel(
                in: poster,
                topLeftX: poster.width / 2,
                topLeftY: poster.height / 2
            ),
            PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )
        XCTAssertEqual(
            samplePixel(
                in: primary,
                topLeftX: primary.width / 2,
                topLeftY: primary.height / 2
            ),
            PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        )
        XCTAssertEqual(
            controller.effectiveCompositionComparisonPreviewPhase,
            .secondary
        )

        controller.setCompositionComparisonPreviewPhase(.primary)

        XCTAssertEqual(
            controller.effectiveCompositionComparisonPreviewPhase,
            .primary
        )
        XCTAssertFalse(controller.isCompositionBlinkPreviewPlaying)
    }

    func testAnimationFramePlanIsDeterministicAndIncludesLoopCrossfade() {
        let primary = makeSolidImage(
            width: 8,
            height: 6,
            color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
        )
        let secondary = makeSolidImage(
            width: 8,
            height: 6,
            color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )

        let first = CompositionOutputExporter.animationFrames(
            primary: primary,
            secondary: secondary,
            interval: 0.75,
            crossfade: 0.2,
            loops: true
        )
        let second = CompositionOutputExporter.animationFrames(
            primary: primary,
            secondary: secondary,
            interval: 0.75,
            crossfade: 0.2,
            loops: true
        )

        XCTAssertEqual(first.count, 14)
        XCTAssertEqual(first.map(\.duration), second.map(\.duration))
        XCTAssertEqual(first.first?.duration ?? -1, 0.55, accuracy: 0.000_001)
        XCTAssertEqual(first[7].duration, 0.55, accuracy: 0.000_001)
        XCTAssertEqual(
            samplePixel(in: first[7].image, topLeftX: 4, topLeftY: 3),
            PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
        )
    }

    func testAnimatedOutputRejectsNonBlinkComparisonWithStructuredError() async throws {
        let fixture = makeComparisonFixture(mode: .wipe)
        let url = temporaryURL(extension: "gif")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            _ = try await CompositionOutputExporter.export(
                fixture.input,
                format: .gif,
                to: url
            )
            XCTFail("Expected unsupported comparison output.")
        } catch {
            XCTAssertEqual(
                error as? CompositionOutputError,
                .blinkComparisonRequired(format: .gif)
            )
        }
    }

    func testGIFAndAPNGEncodeDeterministicBlinkFrames() async throws {
        let fixture = makeComparisonFixture(mode: .blink)

        for format in [CompositionOutputFormat.gif, .apng] {
            let url = temporaryURL(extension: format.fileExtension)
            defer { try? FileManager.default.removeItem(at: url) }

            let result = try await CompositionOutputExporter.export(
                fixture.input,
                format: format,
                to: url
            )
            let source = try XCTUnwrap(
                CGImageSourceCreateWithURL(url as CFURL, nil)
            )

            XCTAssertEqual(CGImageSourceGetCount(source), 2)
            XCTAssertEqual(result.format, format)
            XCTAssertFalse(result.wasScaledToAnimatedLimit)
        }
    }

    func testMP4EncodesCompleteBlinkCycle() async throws {
        let fixture = makeComparisonFixture(mode: .blink)
        let url = temporaryURL(extension: "mp4")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await CompositionOutputExporter.export(
            fixture.input,
            format: .mp4,
            to: url
        )
        let duration = try await AVURLAsset(url: url).load(.duration)

        XCTAssertEqual(duration.seconds, 1.5, accuracy: 0.05)
    }

    func testStepsPDFUsesItemsPerPage() async throws {
        let assets = [
            CompositionAsset(
                image: makeSolidImage(
                    width: 20,
                    height: 12,
                    color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
                )
            ),
            CompositionAsset(
                image: makeSolidImage(
                    width: 20,
                    height: 12,
                    color: PixelSample(red: 0, green: 255, blue: 0, alpha: 255)
                )
            ),
            CompositionAsset(
                image: makeSolidImage(
                    width: 20,
                    height: 12,
                    color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
                )
            ),
        ]
        let items = assets.map {
            CompositionItem(assetID: $0.descriptor.id, caption: "Instruction")
        }
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .steps),
            steps: CompositionStepsSettings(
                flow: .column,
                itemsPerPage: 1
            )
        )
        let input = outputInput(
            composition: composition,
            assets: assets
        )
        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await CompositionOutputExporter.export(
            input,
            format: .pdf,
            to: url
        )
        let document = try XCTUnwrap(
            CGPDFDocument(url as CFURL)
        )

        XCTAssertEqual(result.pageCount, 3)
        XCTAssertEqual(document.numberOfPages, 3)
    }

    func testPreflightFindsOversizedFreeformWithoutAllocatingComposite() throws {
        let asset = CompositionAsset(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 20, green: 80, blue: 180, alpha: 255)
            )
        )
        let item = CompositionItem(
            assetID: asset.descriptor.id,
            freeformFrame: CGRect(x: 0, y: 0, width: 40_000, height: 20_000)
        )
        let input = outputInput(
            composition: CompositionSnapshot(
                items: [item],
                layout: CompositionLayoutConfiguration(mode: .freeform)
            ),
            assets: [asset]
        )

        let preflight = try CompositionOutputExporter.preflight(
            input,
            format: .png
        )

        XCTAssertTrue(preflight.isOversized)
        XCTAssertGreaterThan(preflight.estimatedPixelSize.width, 16_384)
        XCTAssertNotNil(preflight.recommendedMaximumOutputDimension)
        XCTAssertFalse(preflight.canUsePaginatedPDF)
    }

    func testExplicitSafetyScaleRendersDirectlyAtBoundedSize() async throws {
        let asset = CompositionAsset(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 20, green: 80, blue: 180, alpha: 255)
            )
        )
        let item = CompositionItem(
            assetID: asset.descriptor.id,
            freeformFrame: CGRect(x: 0, y: 0, width: 20_000, height: 100)
        )
        let input = outputInput(
            composition: CompositionSnapshot(
                items: [item],
                layout: CompositionLayoutConfiguration(mode: .freeform)
            ),
            assets: [asset]
        )
        let url = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }

        let result = try await CompositionOutputExporter.export(
            input,
            format: .png,
            to: url,
            maximumOutputDimension: 1_024
        )

        XCTAssertLessThanOrEqual(result.pixelSize?.width ?? .greatestFiniteMagnitude, 1_024)
        XCTAssertTrue(result.wasScaledToRasterSafetyLimit)
        XCTAssertFalse(result.wasScaledToAnimatedLimit)
    }

    func testPreflightAndBoundedExportKeepRepositoryAssetsLazy() async throws {
        let source = makeSolidImage(
            width: 20,
            height: 12,
            color: PixelSample(
                red: 20,
                green: 80,
                blue: 180,
                alpha: 255
            )
        )
        let repository = CompositionAssetRepository()
        let assetID = try repository.add(
            capture: makeCapturedScreenshot(
                image: source,
                sourceName: "Lazy Source"
            ),
            isPrivate: false
        )
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(
                    assetID: assetID,
                    freeformFrame: CGRect(
                        x: 0,
                        y: 0,
                        width: 20_000,
                        height: 100
                    )
                ),
            ],
            layout: CompositionLayoutConfiguration(mode: .freeform)
        )
        let input = CompositionOutputInput(
            baseImage: source,
            snapshot: EditorSnapshot(
                cropRect: CGRect(
                    x: 0,
                    y: 0,
                    width: source.width,
                    height: source.height
                ),
                annotations: [],
                selectedAnnotationIDs: [],
                nextCalloutNumber: 1,
                presentation: .plain,
                composition: composition
            ),
            compositionAssets: [:],
            compositionAssetRepository: repository,
            appearance: .plain
        )
        repository.resetDiagnostics()

        let preflight = try CompositionOutputExporter.preflight(
            input,
            format: .png
        )
        XCTAssertTrue(preflight.isOversized)
        XCTAssertEqual(
            repository.diagnostics.fullResolutionDecodeCount,
            0
        )

        let url = temporaryURL(extension: "png")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await CompositionOutputExporter.export(
            input,
            format: .png,
            to: url,
            maximumOutputDimension: 1_024
        )

        XCTAssertLessThanOrEqual(
            result.pixelSize?.width ?? .greatestFiniteMagnitude,
            1_024
        )
        XCTAssertEqual(
            repository.diagnostics.fullResolutionDecodeCount,
            0
        )
        XCTAssertGreaterThan(
            repository.diagnostics.downsampledDecodeCount,
            0
        )
    }

    func testForcedPaginationOverridesDocumentWithoutMutatingIt() async throws {
        let assets = (0..<3).map { index in
            CompositionAsset(
                image: makeSolidImage(
                    width: 20,
                    height: 12,
                    color: PixelSample(
                        red: UInt8(40 + index * 50),
                        green: 90,
                        blue: 170,
                        alpha: 255
                    )
                )
            )
        }
        let composition = CompositionSnapshot(
            items: assets.map {
                CompositionItem(assetID: $0.descriptor.id)
            },
            layout: CompositionLayoutConfiguration(mode: .steps)
        )
        let input = outputInput(composition: composition, assets: assets)
        let preflight = try CompositionOutputExporter.preflight(
            input,
            format: .pdf
        )
        XCTAssertTrue(preflight.canUsePaginatedPDF)

        let url = temporaryURL(extension: "pdf")
        defer { try? FileManager.default.removeItem(at: url) }
        let result = try await CompositionOutputExporter.export(
            input,
            format: .pdf,
            to: url,
            forcedPDFItemsPerPage: 1
        )

        XCTAssertEqual(result.pageCount, 3)
        XCTAssertNil(input.snapshot.composition?.steps.itemsPerPage)
    }

    func testStepsHTMLContainsOnlyRenderedIncludedPixelsAndUserCaption() async throws {
        let included = CompositionAsset(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
            ),
            sourceName: "/Users/example/Private/source.png",
            accessibilityLabel: "Secret window title"
        )
        let excluded = CompositionAsset(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
            ),
            sourceName: "Hidden capture metadata"
        )
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(
                    assetID: included.descriptor.id,
                    title: "/Users/example/Private/source.png",
                    caption: "Choose Continue."
                ),
                CompositionItem(
                    assetID: excluded.descriptor.id,
                    title: "Hidden capture metadata",
                    isIncluded: false
                ),
            ],
            layout: CompositionLayoutConfiguration(mode: .steps)
        )
        let input = outputInput(
            composition: composition,
            assets: [included, excluded]
        )
        let url = temporaryURL(extension: "html")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await CompositionOutputExporter.export(
            input,
            format: .html,
            to: url
        )
        let html = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(html.contains("Choose Continue."))
        XCTAssertTrue(html.contains("Step 1"))
        XCTAssertFalse(html.contains("/Users/example"))
        XCTAssertFalse(html.contains("Secret window title"))
        XCTAssertFalse(html.contains("Hidden capture metadata"))
        XCTAssertEqual(
            html.components(separatedBy: "src=\"data:image/png;base64,").count - 1,
            1
        )
    }

    func testStepsHTMLPreservesRomanLabelsAndHiddenCaptionSetting() async throws {
        let assets = [
            CompositionAsset(
                image: makeSolidImage(
                    width: 20,
                    height: 12,
                    color: PixelSample(red: 220, green: 60, blue: 60, alpha: 255)
                )
            ),
            CompositionAsset(
                image: makeSolidImage(
                    width: 20,
                    height: 12,
                    color: PixelSample(red: 60, green: 90, blue: 220, alpha: 255)
                )
            ),
        ]
        let composition = CompositionSnapshot(
            items: [
                CompositionItem(
                    assetID: assets[0].descriptor.id,
                    title: "Private source title",
                    caption: "Hidden caption one"
                ),
                CompositionItem(
                    assetID: assets[1].descriptor.id,
                    title: "Another source title",
                    caption: "Hidden caption two"
                ),
            ],
            layout: CompositionLayoutConfiguration(mode: .steps),
            steps: CompositionStepsSettings(
                numberingStyle: .uppercaseRoman,
                startIndex: 4,
                showsCaptions: false
            )
        )
        let url = temporaryURL(extension: "html")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await CompositionOutputExporter.export(
            outputInput(composition: composition, assets: assets),
            format: .html,
            to: url
        )
        let html = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(html.contains("data-step-label=\"IV\""))
        XCTAssertTrue(html.contains("data-step-label=\"V\""))
        XCTAssertTrue(html.contains(">Step IV<"))
        XCTAssertTrue(html.contains(">Step V<"))
        XCTAssertFalse(html.contains("Hidden caption one"))
        XCTAssertFalse(html.contains("Hidden caption two"))
        XCTAssertFalse(html.contains("Private source title"))
        XCTAssertFalse(html.contains("Another source title"))
    }

    func testChangeHighlightHTMLUsesExactRenderedPosterPixelsAndMode() async throws {
        let fixture = makeComparisonFixture(mode: .changeHighlight)
        let expected = try CompositionOutputExporter.staticImage(fixture.input)
        let url = temporaryURL(extension: "html")
        defer { try? FileManager.default.removeItem(at: url) }

        _ = try await CompositionOutputExporter.export(
            fixture.input,
            format: .html,
            to: url
        )
        let html = try String(contentsOf: url, encoding: .utf8)
        let embeddedImages = try embeddedImages(in: html)
        let renderedPoster = try XCTUnwrap(embeddedImages.last)

        XCTAssertTrue(html.contains("data-comparison-mode=\"change-highlight\""))
        XCTAssertTrue(html.contains("<figcaption>Change Highlight</figcaption>"))
        XCTAssertTrue(html.contains("Rendered change highlight between Before and After"))
        XCTAssertEqual(embeddedImages.count, 3)
        XCTAssertEqual(renderedPoster.width, expected.width)
        XCTAssertEqual(renderedPoster.height, expected.height)
        for (x, y) in [
            (0, 0),
            (expected.width / 2, expected.height / 2),
            (expected.width - 1, expected.height - 1),
        ] {
            XCTAssertEqual(
                samplePixel(
                    in: renderedPoster,
                    topLeftX: x,
                    topLeftY: y
                ),
                samplePixel(
                    in: expected,
                    topLeftX: x,
                    topLeftY: y
                )
            )
        }
    }

    private func makeComparisonFixture(
        mode: CompositionComparisonMode
    ) -> (input: CompositionOutputInput, items: [CompositionItem]) {
        let primary = CompositionAsset(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 255, green: 0, blue: 0, alpha: 255)
            )
        )
        let secondary = CompositionAsset(
            image: makeSolidImage(
                width: 20,
                height: 12,
                color: PixelSample(red: 0, green: 0, blue: 255, alpha: 255)
            )
        )
        let items = [
            CompositionItem(assetID: primary.descriptor.id),
            CompositionItem(assetID: secondary.descriptor.id),
        ]
        var comparison = CompositionComparisonSettings(
            mode: mode,
            primaryItemID: items[0].id,
            secondaryItemID: items[1].id
        )
        comparison.showsLabels = false
        comparison.posterFrame = .secondary
        let composition = CompositionSnapshot(
            items: items,
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: comparison
        )
        return (
            outputInput(
                composition: composition,
                assets: [primary, secondary]
            ),
            items
        )
    }

    private func outputInput(
        composition: CompositionSnapshot,
        assets: [CompositionAsset]
    ) -> CompositionOutputInput {
        let baseImage = assets[0].image
        return CompositionOutputInput(
            baseImage: baseImage,
            snapshot: EditorSnapshot(
                cropRect: CGRect(
                    x: 0,
                    y: 0,
                    width: baseImage.width,
                    height: baseImage.height
                ),
                annotations: [],
                selectedAnnotationIDs: [],
                nextCalloutNumber: 1,
                presentation: .plain,
                composition: composition
            ),
            compositionAssets: Dictionary(
                uniqueKeysWithValues: assets.map { ($0.descriptor.id, $0) }
            ),
            appearance: .plain
        )
    }

    private func temporaryURL(extension pathExtension: String) -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent(
            "CompositionOutputExporterTests-\(UUID().uuidString).\(pathExtension)"
        )
    }

    private func embeddedImages(in html: String) throws -> [CGImage] {
        let marker = "src=\"data:image/png;base64,"
        return try html.components(separatedBy: marker).dropFirst().map { suffix in
            let encoded = String(suffix.prefix { $0 != "\"" })
            let data = try XCTUnwrap(Data(base64Encoded: encoded))
            let source = try XCTUnwrap(
                CGImageSourceCreateWithData(data as CFData, nil)
            )
            return try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, 0, nil))
        }
    }
}
