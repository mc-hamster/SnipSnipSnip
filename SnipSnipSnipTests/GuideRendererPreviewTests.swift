import CoreGraphics
import XCTest
@testable import SnipSnipSnip

final class GuideRendererPreviewTests: XCTestCase {
    func testVeryTallGuidePreviewHasBoundedRasterAndFullLogicalGeometry() throws {
        let image = makeCoordinateImage(width: 8, height: 140_000)
        let step = makeStep(image: image)
        let preview = try XCTUnwrap(GuideRenderer.renderStepPreview(step: step, image: image, theme: GuideTheme()))
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 2048)
        XCTAssertEqual(preview.logicalSize.width, 1440)
        XCTAssertGreaterThan(preview.logicalSize.height, 140_000)
        XCTAssertEqual(preview.screenshotRect, CGRect(x: 72, y: 72, width: 8, height: 140_000))
        XCTAssertLessThan(preview.image.bytesPerRow * preview.image.height, 4 * 2048 * 2048)
    }

    func testBoundedGuidePreviewKeepsExportPlacementWithCaptionAndNote() throws {
        let image = makeCoordinateImage(width: 60, height: 4000)
        var step = makeStep(image: image)
        step.note = "This note remains below the screenshot."
        let preview = try XCTUnwrap(GuideRenderer.renderStepPreview(step: step, image: image, theme: GuideTheme()))
        let exported = try XCTUnwrap(GuideRenderer.renderStepCard(step: step, image: image, theme: GuideTheme()))
        XCTAssertEqual(preview.logicalSize, CGSize(width: exported.width, height: exported.height))
        XCTAssertEqual(preview.screenshotRect, CGRect(x: 72, y: 72, width: 60, height: 4000))
    }

    func testAdvancedEditPreviewKeepsCropGeometryWithoutFullHeightRaster() throws {
        let image = makeCoordinateImage(width: 32, height: 100_000)
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 20_000, width: 32, height: 70_000))
        let advanced = makeEditableDocument(capture: makeCapturedScreenshot(image: image), session: makeEditorDocumentSession(initialSnapshot: snapshot))
        let preview = try XCTUnwrap(GuideRenderer.renderStepPreview(step: makeStep(image: image), image: image, theme: GuideTheme(), advancedEdit: advanced))
        XCTAssertLessThanOrEqual(max(preview.image.width, preview.image.height), 2048)
        XCTAssertEqual(preview.screenshotRect.size, snapshot.cropRect.size)
    }

    func testBoundedAnnotationRenderPreservesRedactionAtLogicalCoordinates() throws {
        let image = makeSolidImage(width: 100, height: 4000, color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 100, height: 4000), annotations: [
            Annotation.makeSolidRedaction(in: CGRect(x: 0, y: 1000, width: 100, height: 1000))
        ])
        let preview = try XCTUnwrap(EditorRenderer.render(baseImage: image, snapshot: snapshot, maxPixelDimension: 1000))
        XCTAssertEqual(preview.width, 25)
        XCTAssertEqual(preview.height, 1000)
        let protectedPixel = samplePixel(in: preview, topLeftX: 12, topLeftY: 375)
        // Both paths convert the style's color into sRGB. Compare the actual
        // export pixel, not the unconverted RGBAColor component values.
        let full = try XCTUnwrap(EditorRenderer.render(baseImage: image, snapshot: snapshot))
        let expected = samplePixel(in: full, topLeftX: 50, topLeftY: 1500)
        XCTAssertEqual(protectedPixel, expected)
        XCTAssertEqual(samplePixel(in: preview, topLeftX: 12, topLeftY: 600), PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
    }

    func testBoundedProcessedRedactionsSampleLateRowsInRasterCoordinates() throws {
        let image = makeRGBAImage(width: 128, height: 4000) { x, y in
            let component: UInt8 = ((x / 8 + y / 8) % 2 == 0) ? 0 : 255
            return PixelSample(red: component, green: component, blue: component, alpha: 255)
        }
        let crop = CGRect(x: 0, y: 0, width: 128, height: 4000)
        let plain = try XCTUnwrap(EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: crop), maxPixelDimension: 1000))
        for mode in [EditorTool.blur, .pixelate] {
            var style = AnnotationStyle.default(for: mode)
            style.effectRadius = 20
            style.lineWidth = 0
            let rect = CGRect(x: 8, y: 3000, width: 112, height: 800)
            let annotation = mode == .blur ? Annotation.makeBlur(in: rect, style: style) : Annotation.makePixelate(in: rect, style: style)
            let output = try XCTUnwrap(EditorRenderer.render(baseImage: image, snapshot: makeEditorSnapshot(cropRect: crop, annotations: [annotation]), maxPixelDimension: 1000))
            var changed = 0
            for y in 790..<830 {
                for x in 8..<24 {
                    if samplePixel(in: output, topLeftX: x, topLeftY: y) != samplePixel(in: plain, topLeftX: x, topLeftY: y) { changed += 1 }
                }
            }
            XCTAssertGreaterThan(changed, 100, "\(mode) must process the protected late rows, not skip a crop beyond the raster height")
            XCTAssertEqual(samplePixel(in: output, topLeftX: 12, topLeftY: 400), samplePixel(in: plain, topLeftX: 12, topLeftY: 400))
        }
    }

    private func makeStep(image: CGImage) -> GuideStep {
        GuideStep(sequence: 1, eventKind: .manual, caption: "Review the scrolling image.",
                  session: GuideStepSession(sourceCoordinateRect: CGRect(x: 0, y: 0, width: 800, height: 600), sourcePixelSize: CGSize(width: image.width, height: image.height)))
    }
}
