import AppKit
import XCTest
@testable import SnipSnipSnip

@MainActor
final class MeasurementRenderingRegressionTests: XCTestCase {
    func testSourcePixelLabelAndAllMetricsRemainStableThroughPreviewZoom() {
        for length: CGFloat in [0, 5, 50, 120, 1_234.6] {
            for fontSize: CGFloat in [12, 18, 32] {
                var style = AnnotationStyle.default(for: .measure)
                style.fontSize = fontSize
                let shape = MeasurementShape(start: CGPoint(x: 20, y: 40), end: CGPoint(x: 20 + length, y: 40))
                let source = MeasurementAnnotationGeometry.label(for: shape, style: style)
                XCTAssertEqual(source.text, "\(Int(length.rounded())) px")
                for scale: CGFloat in [0.25, 0.5, 1, 2, 3] {
                    let transform = CGAffineTransform(scaleX: scale, y: scale)
                    let preview = source.projected(rect: { $0.applying(transform) }, scale: scale)
                    XCTAssertEqual(preview.text, source.text, "Zoom must not change the measured pixel length")
                    XCTAssertEqual(preview.font.pointSize, source.font.pointSize * scale, accuracy: 0.001)
                    assertRectsEqual(preview.rect, source.rect.applying(transform), accuracy: 0.001)
                }
            }
        }
    }

    func testMeasurementBoundsAndHitRegionContainShortAndLongLabelsThroughRotation() {
        for length: CGFloat in [6, 30, 180] {
            for fontSize: CGFloat in [12, 48] {
                var style = AnnotationStyle.default(for: .measure)
                style.fontSize = fontSize
                let shape = MeasurementShape(start: CGPoint(x: 200, y: 160), end: CGPoint(x: 200, y: 160 + length))
                let label = MeasurementAnnotationGeometry.label(for: shape, style: style)
                let unrotated = MeasurementAnnotationGeometry.bounds(for: shape, style: style)
                XCTAssertLessThanOrEqual(unrotated.width, label.rect.width + 2, "Vertical measurements should not reserve a fixed 92-pixel label")
                for angle: CGFloat in [-45, 0, 35] {
                    let annotation = Annotation(id: UUID(), groupID: nil, kind: .measurement(shape),
                        style: style, rotationDegrees: angle)
                    let labelBounds = gscRotatedBoundingRect(label.rect, degrees: angle)
                    XCTAssertTrue(annotation.boundingRect.contains(labelBounds))
                    let labelPoint = gscPoint(CGPoint(x: label.rect.minX + 4, y: label.rect.midY),
                        rotatedByDegrees: angle, around: unrotated.center)
                    XCTAssertTrue(annotation.contains(labelPoint), "The rendered label must remain selectable")
                }
            }
        }
    }

    func testCroppedExportUsesSharedTightLabelFrameAtMultipleFontSizesAndRotations() throws {
        let base = makeSolidImage(width: 400, height: 400,
            color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        let crop = CGRect(x: 100, y: 100, width: 200, height: 200)
        let shape = MeasurementShape(start: CGPoint(x: 200, y: 196), end: CGPoint(x: 200, y: 204))
        for fontSize: CGFloat in [12, 32, 48] {
            var style = AnnotationStyle.default(for: .measure)
            style.strokeColor = .clear
            style.fillColor = .redactionFill
            style.fontSize = fontSize
            let label = MeasurementAnnotationGeometry.label(for: shape, style: style)
            let center = MeasurementAnnotationGeometry.bounds(for: shape, style: style).center
            for angle: CGFloat in [-35, 0, 35] {
                let annotation = Annotation(id: UUID(), groupID: nil, kind: .measurement(shape),
                    style: style, rotationDegrees: angle)
                let image = try XCTUnwrap(EditorRenderer.render(baseImage: base,
                    snapshot: makeEditorSnapshot(cropRect: crop, annotations: [annotation])))
                let inside = gscPoint(CGPoint(x: label.rect.minX + 10, y: label.rect.midY), rotatedByDegrees: angle, around: center)
                let outside = gscPoint(CGPoint(x: label.rect.minX - 5, y: label.rect.midY), rotatedByDegrees: angle, around: center)
                XCTAssertLessThan(samplePixel(in: image, topLeftX: Int((inside.x - crop.minX).rounded()),
                    topLeftY: Int((inside.y - crop.minY).rounded())).red, 100)
                XCTAssertGreaterThan(samplePixel(in: image, topLeftX: Int((outside.x - crop.minX).rounded()),
                    topLeftY: Int((outside.y - crop.minY).rounded())).red, 240)
            }
        }
    }

    func testAutoCropKeepsEntireRotatedMeasurementLabel() {
        let name = "MeasurementRenderingRegressionTests.\(UUID())"
        let defaults = makeDefaults(named: name)
        defer { defaults.removePersistentDomain(forName: name) }
        let base = makeSolidImage(width: 400, height: 300,
            color: PixelSample(red: 255, green: 255, blue: 255, alpha: 255))
        var style = AnnotationStyle.default(for: .measure)
        style.fontSize = 48
        let annotation = Annotation.makeMeasurement(from: CGPoint(x: 200, y: 145), to: CGPoint(x: 200, y: 155), style: style)
            .updatingRotationDegrees(35)
        let snapshot = makeEditorSnapshot(cropRect: CGRect(x: 0, y: 0, width: 400, height: 300), annotations: [annotation])
        let controller = EditorController(capture: makeCapturedScreenshot(image: base),
            session: makeEditorDocumentSession(initialSnapshot: snapshot), defaults: defaults)
        controller.autoCropCurrentCrop()
        XCTAssertLessThan(controller.snapshot.cropRect.width, 400)
        XCTAssertLessThan(controller.snapshot.cropRect.height, 300)
        XCTAssertTrue(controller.snapshot.cropRect.contains(annotation.boundingRect))
        controller.undo()
        XCTAssertEqual(controller.snapshot.cropRect, snapshot.cropRect)
    }
}
