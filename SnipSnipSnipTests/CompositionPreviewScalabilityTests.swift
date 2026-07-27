import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class CompositionPreviewScalabilityTests: XCTestCase {
    func testPrivatePerformanceDiagnosticsNeverEvaluateContentContext() async {
        let recorder = ContentDiagnosticEvaluationRecorder()

        PresentationPerformanceMetrics.withLoggingSuppressed(true) {
            PresentationPerformanceMetrics.logEvent(
                "private.preview",
                context: recorder.context()
            )
            _ = PresentationPerformanceMetrics.measure(
                "private.render",
                context: recorder.context()
            ) {
                1
            }
        }

        await PresentationPerformanceMetrics.withLoggingSuppressed(true) {
            await Task {
                PresentationPerformanceMetrics.logEvent(
                    "private.child",
                    context: recorder.context()
                )
            }.value
        }

        XCTAssertEqual(recorder.evaluationCount, 0)
    }

    func testThumbnailDownsamplesEncodedPixelsWithoutFullResolutionDecode() throws {
        let assetID = UUID()
        let repository = try repository(
            assets: [(assetID, 1_200, 800, 5, 11)]
        )

        let thumbnail = try repository.thumbnail(
            for: assetID,
            maxPixelDimension: 160
        )

        XCTAssertEqual(max(thumbnail.width, thumbnail.height), 160)
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 0)
        XCTAssertEqual(repository.diagnostics.downsampledDecodeCount, 1)
    }

    func testEditedItemPreviewCacheHitsAndInvalidatesByPixelEditFingerprint() throws {
        let assetID = UUID()
        let itemID = UUID()
        let repository = try repository(
            assets: [(assetID, 1_200, 800, 7, 13)]
        )
        var item = CompositionItem(id: itemID, assetID: assetID)
        let options = CompositionRenderOptions(
            targetMaximumPixelDimension: 300
        )

        func render(_ item: CompositionItem) throws -> CGImage {
            try CompositionRenderer.renderPreview(
                composition: CompositionSnapshot(
                    items: [item],
                    layout: CompositionLayoutConfiguration(mode: .auto),
                    canvas: CompositionCanvasState(appearance: .pixelPreserving)
                ),
                assetRepository: repository,
                options: options
            ).image
        }

        let original = try render(item)
        _ = try render(item)
        XCTAssertEqual(repository.diagnostics.renderedPreviewCacheMissCount, 1)
        XCTAssertEqual(repository.diagnostics.renderedPreviewCacheHitCount, 1)

        item.title = "Metadata does not change the item pixels"
        _ = try render(item)
        XCTAssertEqual(
            repository.diagnostics.renderedPreviewCacheHitCount,
            2,
            "Non-pixel item metadata should reuse the edited item preview."
        )

        item.editState.annotations = [
            Annotation.makeSolidRedaction(
                in: CGRect(x: 120, y: 100, width: 360, height: 240)
            ),
        ]
        let redacted = try render(item)
        XCTAssertEqual(repository.diagnostics.renderedPreviewCacheMissCount, 2)
        XCTAssertNotEqual(
            samplePixel(in: original, topLeftX: 60, topLeftY: 50),
            samplePixel(in: redacted, topLeftX: 60, topLeftY: 50)
        )

        item.editState.annotations = []
        _ = try render(item)
        XCTAssertEqual(
            repository.diagnostics.renderedPreviewCacheHitCount,
            3,
            "Returning to an earlier edit fingerprint should reuse its bounded preview."
        )
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 0)
    }

    func testComparePreviewDecodesOnlyPlacedABItems() throws {
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        let storedButUnusedAssetID = UUID()
        let repository = try repository(
            assets: [
                (firstAssetID, 960, 540, 3, 7),
                (secondAssetID, 960, 540, 5, 11),
                (storedButUnusedAssetID, 960, 540, 13, 17),
            ]
        )
        let first = CompositionItem(assetID: firstAssetID)
        let second = CompositionItem(assetID: secondAssetID)
        let unused = CompositionItem(assetID: storedButUnusedAssetID)
        let composition = CompositionSnapshot(
            items: [first, second, unused],
            layout: CompositionLayoutConfiguration(mode: .compare),
            comparison: CompositionComparisonSettings(
                mode: .wipe,
                primaryItemID: first.id,
                secondaryItemID: second.id,
                registrationMode: .disabled
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )

        let result = try CompositionRenderer.renderPreview(
            composition: composition,
            assetRepository: repository,
            options: CompositionRenderOptions(
                targetMaximumPixelDimension: 480
            )
        )

        XCTAssertEqual(result.layout.items.map(\.itemID), [first.id, second.id])
        XCTAssertEqual(repository.diagnostics.downsampledDecodeCount, 2)
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 0)
    }

    func testDownsampledEditedPreviewTracksFullResolutionReferenceAtTargetSize() throws {
        let assetID = UUID()
        // Use a smooth, screen-like gradient here. The modulo coordinate
        // fixture used by exact crop tests contains subpixel-frequency seams,
        // so two valid high-quality resampling passes can intentionally alias
        // to very different colors without indicating spatial drift.
        let source = makeSmoothCoordinateImage(width: 1_200, height: 800)
        let stored = CompositionStoredAsset(
            descriptor: CompositionAssetDescriptor(
                id: assetID,
                pixelWidth: source.width,
                pixelHeight: source.height,
                sourceName: "Fidelity reference"
            ),
            encodedPNG: try ImageExporter.pngData(for: source)
        )
        let repository = CompositionAssetRepository(storedAssets: [stored])
        var editState = ScreenshotEditState(
            cropRect: CGRect(x: 120, y: 80, width: 960, height: 640)
        )
        editState.annotations = [
            Annotation.makeSolidRedaction(
                in: CGRect(x: 480, y: 280, width: 240, height: 160)
            ),
        ]
        let item = CompositionItem(
            assetID: assetID,
            editState: editState
        )
        let composition = CompositionSnapshot(
            items: [item],
            layout: CompositionLayoutConfiguration(mode: .auto),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let options = CompositionRenderOptions(
            targetMaximumPixelDimension: 300
        )
        let reference = try CompositionRenderer.render(
            composition: composition,
            assets: [
                assetID: CompositionAsset(
                    id: assetID,
                    image: source,
                    sourceName: "Fidelity reference"
                ),
            ],
            options: options
        ).image
        let preview = try CompositionRenderer.renderPreview(
            composition: composition,
            assetRepository: repository,
            options: options
        ).image

        XCTAssertEqual(preview.width, reference.width)
        XCTAssertEqual(preview.height, reference.height)
        for y in stride(from: 20, to: preview.height - 20, by: 24) {
            for x in stride(from: 20, to: preview.width - 20, by: 24) {
                let expected = samplePixel(
                    in: reference,
                    topLeftX: x,
                    topLeftY: y
                )
                let actual = samplePixel(
                    in: preview,
                    topLeftX: x,
                    topLeftY: y
                )
                XCTAssertLessThanOrEqual(
                    maximumChannelDelta(expected, actual),
                    12,
                    "Cell-size downsampling diverged at \(x),\(y)."
                )
            }
        }
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 0)
    }

    func testFullResolutionRendererStillUsesImmutableSourcePixels() throws {
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        let repository = try repository(
            assets: [
                (firstAssetID, 640, 360, 3, 7),
                (secondAssetID, 640, 360, 5, 11),
            ]
        )
        let first = CompositionItem(assetID: firstAssetID)
        let second = CompositionItem(assetID: secondAssetID)
        let composition = CompositionSnapshot(
            items: [first, second],
            layout: CompositionLayoutConfiguration(mode: .row),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )

        let result = try CompositionRenderer.render(
            composition: composition,
            assets: repository.assets(
                for: Set([firstAssetID, secondAssetID])
            )
        )

        XCTAssertEqual(result.image.width, 1_280)
        XCTAssertEqual(result.image.height, 360)
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 2)
    }

    func testDocumentPreviewCapsPresentationWrappedOversizedCompositionWithoutFullResolutionDecode() throws {
        let firstAssetID = UUID()
        let secondAssetID = UUID()
        let repository = try repository(
            assets: [
                (firstAssetID, 1_200, 800, 3, 7),
                (secondAssetID, 1_200, 800, 5, 11),
            ]
        )
        let first = CompositionItem(
            assetID: firstAssetID,
            freeformFrame: CGRect(x: 0, y: 0, width: 1_200, height: 800)
        )
        let second = CompositionItem(
            assetID: secondAssetID,
            freeformFrame: CGRect(
                x: 18_800,
                y: 0,
                width: 1_200,
                height: 800
            )
        )
        let composition = CompositionSnapshot(
            items: [first, second],
            layout: CompositionLayoutConfiguration(
                mode: .freeform,
                freeformCanvasSize: CGSize(width: 20_000, height: 800)
            ),
            canvas: CompositionCanvasState(appearance: .pixelPreserving)
        )
        let baseImage = makeCoordinateImage(width: 80, height: 60)
        let snapshot = EditorSnapshot(
            cropRect: CGRect(
                origin: .zero,
                size: CGSize(width: baseImage.width, height: baseImage.height)
            ),
            annotations: [],
            selectedAnnotationIDs: [],
            nextCalloutNumber: 1,
            presentation: ScreenshotPresentationPreset.lifted.settings,
            composition: composition
        )

        repository.removeDecodedImages()
        repository.resetDiagnostics()
        let preview = try CompositionDocumentPreviewRenderer.render(
            CompositionDocumentPreviewInput(
                baseImage: baseImage,
                snapshot: snapshot,
                assetRepository: repository
            )
        )

        XCTAssertLessThanOrEqual(
            max(preview.width, preview.height),
            CompositionDocumentPreviewRenderer.maximumPixelDimension
        )
        XCTAssertEqual(repository.diagnostics.downsampledDecodeCount, 2)
        XCTAssertEqual(repository.diagnostics.fullResolutionDecodeCount, 0)
    }

    private func repository(
        assets: [(UUID, Int, Int, Int, Int)]
    ) throws -> CompositionAssetRepository {
        let stored = try assets.enumerated().map {
            index,
            fixture -> CompositionStoredAsset in
            let (id, width, height, xMultiplier, yMultiplier) = fixture
            let image = makeCoordinateImage(
                width: width,
                height: height,
                pattern: .weighted(
                    xMultiplier: xMultiplier,
                    yMultiplier: yMultiplier,
                    includeBlueSum: index.isMultiple(of: 2)
                )
            )
            return CompositionStoredAsset(
                descriptor: CompositionAssetDescriptor(
                    id: id,
                    pixelWidth: width,
                    pixelHeight: height,
                    sourceName: "Preview fixture \(index + 1)"
                ),
                encodedPNG: try ImageExporter.pngData(for: image)
            )
        }
        return CompositionAssetRepository(storedAssets: stored)
    }

    private func maximumChannelDelta(
        _ first: PixelSample,
        _ second: PixelSample
    ) -> Int {
        [
            abs(Int(first.red) - Int(second.red)),
            abs(Int(first.green) - Int(second.green)),
            abs(Int(first.blue) - Int(second.blue)),
            abs(Int(first.alpha) - Int(second.alpha)),
        ].max() ?? 0
    }

    private func makeSmoothCoordinateImage(width: Int, height: Int) -> CGImage {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var pixels = [UInt8](repeating: 0, count: height * bytesPerRow)
        let maximumX = max(width - 1, 1)
        let maximumY = max(height - 1, 1)

        for y in 0..<height {
            for x in 0..<width {
                let offset = y * bytesPerRow + x * bytesPerPixel
                pixels[offset] = UInt8(20 + x * 200 / maximumX)
                pixels[offset + 1] = UInt8(25 + y * 190 / maximumY)
                pixels[offset + 2] = UInt8(
                    30 + x * 80 / maximumX + y * 80 / maximumY
                )
                pixels[offset + 3] = 255
            }
        }

        let provider = CGDataProvider(data: Data(pixels) as CFData)!
        return CGImage(
            width: width,
            height: height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo(
                rawValue: CGImageAlphaInfo.last.rawValue
            ),
            provider: provider,
            decode: nil,
            shouldInterpolate: true,
            intent: .defaultIntent
        )!
    }
}

private final class ContentDiagnosticEvaluationRecorder:
    @unchecked Sendable
{
    private let lock = NSLock()
    private var count = 0

    var evaluationCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }

    func context() -> String {
        lock.lock()
        count += 1
        lock.unlock()
        return "private-content-context"
    }
}
