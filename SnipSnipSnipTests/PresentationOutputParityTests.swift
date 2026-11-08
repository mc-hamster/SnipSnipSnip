import CoreGraphics
import Foundation
import ImageIO
import XCTest
@testable import SnipSnipSnip

final class PresentationOutputParityTests: XCTestCase {
    func testCappedStyledNativeFramesKeepExportProportionsAndPixels() throws {
        for frame in [PresentationFrame.browser(.default), .macOSWindow(.default)] {
            let presentation = ScreenshotPresentation(isEnabled: true,
                background: .solid(RGBAColor(red: 1, green: 1, blue: 1, alpha: 1)),
                frame: frame, padding: 64, cornerRadius: 0, shadow: .off)
            let fixture = try fixture(presentation: presentation)
            let logical = try CompositionLayoutEngine.layout(composition: try XCTUnwrap(fixture.input.snapshot.composition),
                assetDescriptors: fixture.repository.descriptors).canvasSize
            let fullLayout = ScreenshotPresentationRenderer.layout(contentSize: logical, presentation: presentation)
            for cap in [300, 600] {
                let image = try CompositionOutputExporter.staticImage(fixture.input, maximumOutputDimension: cap)
                let scale = CGFloat(cap) / max(fullLayout.canvasSize.width, fullLayout.canvasSize.height)
                XCTAssertEqual(image.width, Int((fullLayout.canvasSize.width * scale).rounded()))
                XCTAssertEqual(image.height, Int((fullLayout.canvasSize.height * scale).rounded()))
                let pixel = samplePixel(in: image, topLeftX: Int(fullLayout.contentRect.midX * scale), topLeftY: Int(fullLayout.contentRect.midY * scale))
                XCTAssertLessThan(pixel.red, 10)
                XCTAssertLessThan(pixel.green, 10)
                XCTAssertGreaterThan(pixel.blue, 245)
            }
            XCTAssertEqual(fixture.repository.diagnostics.fullResolutionDecodeCount, 0)
            XCTAssertGreaterThan(fixture.repository.diagnostics.downsampledDecodeCount, 0)
        }
    }

    func testCappedStyledSceneActualSizePreservesVisibleScreenshotPixels() throws {
        let fixture = try fixture(presentation: actualSizeScene())
        let image = try CompositionOutputExporter.staticImage(fixture.input, maximumOutputDimension: 120)
        XCTAssertEqual(image.width, 120)
        XCTAssertEqual(image.height, 40)
        // Original content is taller than the slot. A 60×2 preview must not be
        // mistaken for Actual Size and centered into a mostly empty slot.
        let pixel = samplePixel(in: image, topLeftX: 60, topLeftY: 6)
        XCTAssertLessThan(pixel.red, 10)
        XCTAssertLessThan(pixel.green, 10)
        XCTAssertGreaterThan(pixel.blue, 245)
        XCTAssertEqual(fixture.repository.diagnostics.fullResolutionDecodeCount, 0)
    }

    func testAnimatedStyledSceneKeepsActualSizeForBothBlinkEndpoints() async throws {
        let fixture = try fixture(presentation: actualSizeScene())
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("SceneEndpointParity-\(UUID()).png")
        defer { try? FileManager.default.removeItem(at: url) }
        _ = try await CompositionOutputExporter.export(fixture.input, format: .apng, to: url)
        let source = try XCTUnwrap(CGImageSourceCreateWithURL(url as CFURL, nil))
        XCTAssertEqual(CGImageSourceGetCount(source), 2)
        for index in 0..<2 {
            let image = try XCTUnwrap(CGImageSourceCreateImageAtIndex(source, index, nil))
            XCTAssertEqual(image.width, 600)
            XCTAssertEqual(image.height, 200)
            let pixel = samplePixel(in: image, topLeftX: 300, topLeftY: 25)
            XCTAssertLessThan(pixel.green, 10, "Downsampled sources must not introduce a white letterbox")
            if index == 0 { XCTAssertGreaterThan(pixel.red, 245); XCTAssertLessThan(pixel.blue, 10) }
            else { XCTAssertGreaterThan(pixel.blue, 245); XCTAssertLessThan(pixel.red, 10) }
        }
        XCTAssertEqual(fixture.repository.diagnostics.fullResolutionDecodeCount, 0)
    }

    func testCappedDocumentRenderingUsesTheSameLogicalPolishBoundary() throws {
        let presentation = ScreenshotPresentation(isEnabled: true, background: .transparent,
            frame: .macOSWindow(.default), padding: 64, cornerRadius: 0, shadow: .off)
        let fixture = try fixture(presentation: presentation)
        let image = try CompositionDocumentRenderer.renderImage(baseImage: fixture.input.baseImage,
            snapshot: fixture.input.snapshot, compositionAssets: fixture.assets,
            compositionOptions: CompositionRenderOptions(comparisonPhase: .secondary, targetMaximumPixelDimension: 300))
        let exported = try CompositionOutputExporter.staticImage(fixture.input, maximumOutputDimension: 300)
        XCTAssertEqual(image.width, exported.width)
        XCTAssertEqual(image.height, exported.height)
        XCTAssertEqual(samplePixel(in: image, topLeftX: image.width / 2, topLeftY: image.height / 2),
            samplePixel(in: exported, topLeftX: exported.width / 2, topLeftY: exported.height / 2))
    }

    private func fixture(presentation: ScreenshotPresentation) throws -> (input: CompositionOutputInput, repository: CompositionAssetRepository, assets: [UUID: CompositionAsset]) {
        let repository = CompositionAssetRepository()
        var items: [CompositionItem] = []
        var assets: [UUID: CompositionAsset] = [:]
        for color in [PixelSample(red: 255, green: 0, blue: 0, alpha: 255), PixelSample(red: 0, green: 0, blue: 255, alpha: 255)] {
            let capture = makeCapturedScreenshot(image: makeSolidImage(width: 6_000, height: 200, color: color))
            let id = try repository.add(capture: capture, isPrivate: false)
            items.append(CompositionItem(assetID: id))
            assets[id] = CompositionAsset(descriptor: try XCTUnwrap(repository.descriptors[id]), image: capture.image)
        }
        let comparison = CompositionComparisonSettings(mode: .blink, primaryItemID: items[0].id,
            secondaryItemID: items[1].id, showsLabels: false, registrationMode: .disabled, posterFrame: .secondary)
        let composition = CompositionSnapshot(items: items, layout: CompositionLayoutConfiguration(mode: .compare), comparison: comparison)
        var snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 6_000, height: 200), presentation: presentation)
        snapshot.composition = composition
        repository.resetDiagnostics()
        let input = CompositionOutputInput(baseImage: makeCoordinateImage(width: 1, height: 1), snapshot: snapshot,
            compositionAssets: [:], compositionAssetRepository: repository, appearance: .styled)
        return (input, repository, assets)
    }

    private func actualSizeScene() throws -> ScreenshotPresentation {
        let svg = """
        <svg xmlns="http://www.w3.org/2000/svg" width="600" height="200" viewBox="0 0 600 200">
        <metadata id="snipsnipsnip-scene">{"schema":"\(PresentationSceneMetadata.schema)","schemaVersion":1,"id":"builtin.actual-parity","name":"Actual Size Parity","version":1,"canvas":{"width":600,"height":200},"slots":[{"id":"primaryScreenshot","type":"image","required":true,"label":"Screenshot","defaultFraming":"actualSize"}]}</metadata>
        <rect width="600" height="200" fill="white"/>
        <image data-sss-slot="primaryScreenshot" href="snipsnipsnip:primaryScreenshot" x="20" y="20" width="560" height="160"/>
        </svg>
        """
        let validated = try PresentationSceneValidator.validate(svgText: svg, source: .bundled)
        let scene = AppliedPresentationScene(definition: PresentationSceneDefinition(metadata: validated.metadata,
            sanitizedSVGText: validated.sanitizedSVGText, source: .bundled,
            fileURL: URL(fileURLWithPath: "/tmp/actual-parity.svg"), isUserModifiedBundled: false))
        return ScreenshotPresentation(isEnabled: true, style: .plain, scene: scene)
    }
}
